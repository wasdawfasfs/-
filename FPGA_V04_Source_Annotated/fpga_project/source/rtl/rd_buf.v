// 读数据缓冲，连接 DDR 返回数据与视频像素消费端。
`timescale 1ns / 1ps
//=============================================================================
// rd_buf.v  —— 读侧行窗口（替换厂商顺序读实现，端口完全不变）
//
// 厂商版每次只把一整行从 DDR3 抓进 16KB 行缓冲，像素域里拿不到第二行，
// 无法按 (xs,ys) 取任意像素。这里改成 64 行滚动窗口：
//
//   DDR3 --16拍/命令--> 乒乓 stage --32bit/时钟--> 行存储 64x1024x32 --随机--> 输出
//                                                                              ^
//                                               dist_calc(6拍) + 行包络预取
//
// 关键数字（core_clk = 125MHz，行周期 13.5us = 1688 拍）
//   * 行存储 64 行 x 1024 x 32bit = 2.1Mbit -> 恰好 64 个 DRM
//     （36Kb 做 1024x36，每行用 32 位）。器件 155 个 DRM，现用 21.5，
//     本模块 64 -> 合计约 55%，留足余量。
//   * 每条读命令 16 拍（wr_cmd_trans 的下限就是 16，少于 16 会把 len 算错）
//     每行 8 条命令 x 16 拍 = 128 拍，覆盖 2048 像素，只用前 1920
//     地址增量：每命令 128、每行 960（128 拍 x 8 个 4 字节单位）
//   * 排空 1024 字/行 = 1024 拍/行，约 1.6 行/行时；直通档只需 1 行/行时
//
// WARP_EN
//   =0  直通：xs=u, ys=v。整条新管线照跑但输出原图
//       —— 用于在真实硬件上验证新的取数/行存储/随机读架构
//   =1  开畸变校正（该模式的整帧仿真尚有一个 13% 错行的问题未清，勿用）
//

//=============================================================================
// 模块接口：各端口方向与位宽以下方声明为准；与上层实例连接共同决定时钟域。
module rd_buf #(
    
    parameter                     ADDR_WIDTH      = 6'd27,
    
    parameter                     ADDR_OFFSET     = 32'h0000_0000,
    
    parameter                     H_NUM           = 12'd1920,
    
    parameter                     V_NUM           = 12'd1080,
    
    parameter                     DQ_WIDTH        = 12'd32,
    
    parameter                     LEN_WIDTH       = 12'd16,
    
    parameter                     PIX_WIDTH       = 12'd24,
    
    parameter                     LINE_ADDR_WIDTH = 16'd19,
    
    parameter                     FRAME_CNT_WIDTH = 16'd8,
    
    parameter                     WARP_EN         = 1        // 0=直通, 1=畸变校正
)  (
    output [63:0] video_diag,
    input                         ddr_clk,
    input                         ddr_rstn,

    input                         vout_clk,
    input                         rd_fsync,
    input                         rd_en,
    output                        vout_de,
    output [PIX_WIDTH- 1'b1 : 0]  vout_data,

    input                         init_done,

    output                        ddr_rreq,
    output [ADDR_WIDTH- 1'b1 : 0] ddr_raddr,
    output [LEN_WIDTH- 1'b1 : 0]  ddr_rd_len,
    input                         ddr_rrdy,
    input                         ddr_rdone,

    input [8*DQ_WIDTH- 1'b1 : 0]  ddr_rdata,
    input                         ddr_rdata_en
);
    //=========================================================================
    // 常量
    //=========================================================================
    
    localparam integer PIXW     = PIX_WIDTH;   // 16
    
    localparam integer CB       = 16;          // 每条读命令拍数（不能小于 16）
    
    localparam integer NCH      = 8;           // 每行命令数
    
    localparam integer MARGIN   = 4;           // 校正档预取超前量（alpha=0.95 时跨度111.6+4=115.6 <= 127）
    
    localparam integer FL_START = 53;          // 校正档 floor(ymin(v=0))；alpha=0.95 NORM=1.0
    
    localparam integer ID_LEAD  = 32;          // 直通档预取超前量（必须 < 64）
    
    localparam integer CXQ      = 3772163;     // 920.94 px, Q4.12（新镜头）
    
    localparam integer CYQ      = 2183633;     // 533.11 px, Q4.12（新镜头）

    // 映射归一化系数（Q4.12，绕主点缩放整个映射）。
    // 畸变校正天然会放大：x_d = cx + (x_u-cx)*s(r²)，s 从中心 1.000 降到
    // 边缘 0.824，等于把源图中间 84% 铺满画框 -> 边缘放大 1/s ≈ 1.21 倍。
    // 这是"把桶形拉直"的必然代价，不是 bug；中心本身就是 1.000×，放大率随半径增长。
    //
    // 想把放大压回去，必须同时放大"每行需要的源行跨度"（实测，见下）：
    //   NORM    最大跨度    帧首需预取
    //   1.000     56.3 行     60.2 行
    //   1.048     59.0 行     62.9 行
    //   1.075     60.5 行     63.7 行
    //   1.206     67.9 行      —
    // 本设计的 64 行窗口 + MARGIN=4 只能容纳跨度 ≤ 59 行，消隐期 41 行时间
    // 按当前取数能力（~1.5 行/行时）最多预取 ~61 行。因此 NORM 必须 ≤ 1.04，
    // 再大会整帧缺行（仿真实测 1.075 时匹配率从 86% 掉到 54%）。
    // 要真正去掉放大需要 ≈4 倍行存储（2×窗口 × 2×位宽），本器件放不下。
    
    localparam integer NORM_Q   = 4500;        // 1.0986：缩小约10%，完整显示校正画面（上限1.10，见下）

    // 诊断档：=1 时上电把整个行存储扫一遍、每个字写入它自己的地址，然后停写。
    // 屏幕上每个像素显示的就是"它读到的地址"（RGB565 解码），用于把读通路
    // 与 DDR3 取数彻底隔离。正常工作时必须为 0。
    
    localparam integer STORE_TEST = 0;

    //=========================================================================
    // 行存储：64 行 × 1024 × 32bit（1 字 = 2 像素）
    //=========================================================================
    // Four parity banks: same 4Mbit capacity as V7, four reads per pixel.
    // Bank selection = {row[0], word[0]}, address = {row[6:1], word[8:1]}.
    reg [63:0] ls00 [0:16383];
    reg [63:0] ls01 [0:16383];
    reg [63:0] ls10 [0:16383];
    reg [63:0] ls11 [0:16383];
    reg ls_we;
    reg [15:0] ls_wa;
    reg [63:0] ls_wd;
    wire [13:0] store_addr = {ls_wa[15:10],ls_wa[8:1]};
    wire [1:0] store_bank = {ls_wa[9],ls_wa[0]};
    
    always @(posedge ddr_clk) if (ls_we) begin
        
        case(store_bank)
          2'b00: ls00[store_addr] <= ls_wd;
          2'b01: ls01[store_addr] <= ls_wd;
          2'b10: ls10[store_addr] <= ls_wd;
          2'b11: ls11[store_addr] <= ls_wd;
        endcase
    end

    //=========================================================================
    // ddr 域：复位同步 / 帧起始 / 帧选择
    //=========================================================================
    reg [2:0] ddr_rstn_s;
    
    always @(posedge ddr_clk) ddr_rstn_s <= {ddr_rstn_s[1:0], ddr_rstn};
    wire ddr_rst_n = ddr_rstn_s[2];

    reg [2:0] fs_ddr;
    
    always @(posedge ddr_clk) fs_ddr <= {fs_ddr[1:0], rd_fsync};
    wire frm_start_ddr = fs_ddr[2] & ~fs_ddr[1];

    reg [FRAME_CNT_WIDTH-1:0] frame_cnt;
    
    always @(posedge ddr_clk) begin
        if (!ddr_rst_n)         frame_cnt <= 0;
        else if (frm_start_ddr) frame_cnt <= frame_cnt + 1'b1;
    end
    wire frame_sel = frame_cnt[0];

    //=========================================================================
    // 目标行：vout 域 -> ddr 域（翻转握手）
    //=========================================================================
    reg        tgt_tog;
    reg [11:0] tgt_val;
    reg [2:0]  tgt_sync;
    reg        tgt_seen;
    reg [11:0] target;
    wire [11:0] tgt_init = (WARP_EN != 0) ? (FL_START[11:0] + 12'd115)
                                          : FL_START[11:0];

    
    always @(posedge ddr_clk) tgt_sync <= {tgt_sync[1:0], tgt_tog};
    
    always @(posedge ddr_clk) begin
        if (!ddr_rst_n) begin
            tgt_seen <= 1'b0;
            target   <= tgt_init;
        end else if (frm_start_ddr) begin
            // 换帧必须同时把 target 拉回帧首值：否则 fl 会带着上一帧的
            // target(约 1035) 在消隐期一路猛取，覆盖 v=0 要用的行
            tgt_seen <= tgt_sync[2];
            target   <= tgt_init;
        end else if (tgt_sync[2] != tgt_seen) begin
            tgt_seen <= tgt_sync[2];
            target   <= tgt_val;
        end
    end

    //=========================================================================
    // ddr 域：取行指针 / 命令 / 采集 / 排空
    //=========================================================================
    reg [11:0] fl;
    reg [2:0]  fch;
    reg [3:0]  beat_cnt;
    reg        just_issued;   // 防止连续两拍重复发同一条命令
    reg        bank_wr;
    reg        cmd_active;
    reg        rreq_r;
    reg [19:0] addr_lo;
    // (行,命令号) 在发命令时锁存；采集结束只是把它挂到 bank 上
    reg [11:0] cur_line;
    reg [2:0]  cur_ch;

    //=========================================================================
    // 标签 FIFO：发命令时压入 {fl,fch}，采集完成时弹出作为 bank 标签。
    // 之前是在采集结束那一刻直接取 cur_ch —— 但 cur_ch 只保存"最近发出"的那条
    // 命令，乒乓切换时它可能已经被下一条命令改写，于是 chunk 0 的数据被打上
    // chunk 1 的标签写进存储，chunk 0 区域永远保持 64 行前的旧内容（左边竖带）。
    // 发命令与采集完成严格 1:1 且顺序一致，所以 FIFO 能保证标签永不串位。
    //=========================================================================
    reg [14:0] tag_mem [0:3];
    reg [1:0]  tag_wp, tag_rp;
    wire [14:0] tag_head = tag_mem[tag_rp];

    reg [4095:0] stg0, stg1;

    
    reg        b0_ready, b1_ready;
    reg [11:0] b0_line, b1_line;
    reg [2:0]  b0_ch,   b1_ch;

    reg        drn_act;
    reg        drn_sel;
    reg [11:0] cmd_wd;
    reg [5:0]  drn_cnt;                        // 0..63（每命令 64 个 64bit 字）
    wire       chunk_done = drn_act && (drn_cnt == 6'd63);

    // 从 stage 取 32bit 字的位偏移： beat = j/8, sub = j%8  ->  beat*256 + sub*32
    // 字 j 对应 beat j/4 的第 j%4 个 64bit -> beat*256 + sub*64
    wire [11:0] drn_off  = {drn_cnt[5:2], 8'd0} + {drn_cnt[1:0], 6'd0};
    wire [11:0] drn_line = drn_sel ? b1_line : b0_line;
    wire [2:0]  drn_ch   = drn_sel ? b1_ch   : b0_ch;
    // 行存储地址： slot*1024 + chunk*128 + j
    // 行存储地址： slot*512 + chunk*64 + j   (128 行 -> 槽位 7 位)
    wire [15:0] drn_wa   = {drn_line[6:0], 9'd0} + {6'd0, drn_ch, 6'd0}
                         + {10'd0, drn_cnt};

    wire demand   = (fl <= target) && (fl < V_NUM);
    // ddr_rrdy 就是 wr_cmd_trans 的 rd_cmd_ready：一次传输进行中它为 0。
    // 原厂版每行只发一条命令，所以可以不看它；这里每行发 8 条背靠背，
    // 不看就会在 ready 还没恢复时再次触发 rd_cmd_trig，把正在进行的传输
    // 打乱 —— 行存储里全是垃圾，屏幕表现为噪声。仿真的 DDR 模型是理想化的
    // （rrdy 恒 1），所以这个错只会在板子上暴露。
    //
    // !chunk_done 是必须的：fl/fch 在 chunk_done 那一拍自增，而发命令也要读
    // 这两个值。若同一拍既自增又发命令，命令会用到**自增前**的行号/chunk号，
    // 把上一个 chunk 重复取一遍、真正的下一个 chunk 被跳过。
    wire issue_ok = (STORE_TEST == 0) && demand && !cmd_active && !just_issued &&
                    ddr_rrdy && !chunk_done &&
                    (bank_wr ? ~b1_ready : ~b0_ready);

    
    always @(posedge ddr_clk) begin
        if (!ddr_rst_n) begin
            fl <= FL_START[11:0]; fch <= 3'd0;
        end else if (frm_start_ddr) begin
            fl  <= (WARP_EN != 0) ? FL_START[11:0] : 12'd0;
            fch <= 3'd0;
        end else if (issue_ok) begin
            // 指针在**发命令**时前进，而不是在排空完成时。
            // 之前用 chunk_done 推进：换帧时 frm_start_ddr 会把指针重置，而当时
            // 在途的那次排空完成仍会再推一格 -> 指针永久领先一格，每行的
            // chunk 0 被跳过、chunk 1 重复，行存储前 128 字永不更新（左边竖带）。
            if (fch == NCH-1) begin fch <= 3'd0; fl <= fl + 12'd1; end
            else                    fch <= fch + 3'd1;
        end
    end

    
    always @(posedge ddr_clk) begin
        if (!ddr_rst_n) begin
            cmd_active <= 1'b0; rreq_r <= 1'b0; beat_cnt <= 4'd0;
            bank_wr <= 1'b0; addr_lo <= 20'd0;
            cur_line <= 12'd0; cur_ch <= 3'd0;
            b0_ready <= 1'b0; b1_ready <= 1'b0;
            b0_line <= 12'd0; b1_line <= 12'd0;
            b0_ch   <= 3'd0;  b1_ch   <= 3'd0;
            cmd_wd  <= 12'd0;
            tag_wp  <= 2'd0;  tag_rp <= 2'd0;
            just_issued <= 1'b0;
            drn_act <= 1'b0;  drn_sel <= 1'b0; drn_cnt <= 6'd0;
            ls_we   <= 1'b0;  ls_wa   <= 16'd0; ls_wd <= 64'd0;
        end else begin
            rreq_r <= 1'b0;
            just_issued <= 1'b0;

            // ---- 看门狗：命令发出后长时间收不满 16 拍就放弃并重试同一块，
            //      避免 rrdy/数据异常时整个读通路死锁 ----
            if (cmd_active) begin
                if (cmd_wd == 12'hFFF) begin
                    cmd_active <= 1'b0;
                    cmd_wd     <= 12'd0;
                end else begin
                    cmd_wd <= cmd_wd + 12'd1;
                end
            end else begin
                cmd_wd <= 12'd0;
            end

            // ---- 发起命令 ----
            if (issue_ok) begin
                rreq_r     <= 1'b1;
                addr_lo    <= {8'd0, fl} * 20'd960 + {12'd0, fch, 7'd0};
                cur_line   <= fl;
                cur_ch     <= fch;
                tag_mem[tag_wp] <= {fl, fch};   // 标签随命令入队
                tag_wp     <= tag_wp + 2'd1;
                cmd_active <= 1'b1;
                just_issued <= 1'b1;
                beat_cnt   <= 4'd0;
            end

            // ---- 采集 ----
            if (cmd_active && ddr_rdata_en) begin
                if (!bank_wr) stg0[{beat_cnt, 8'd0} +: 256] <= ddr_rdata;
                else          stg1[{beat_cnt, 8'd0} +: 256] <= ddr_rdata;
                beat_cnt <= beat_cnt + 4'd1;
                if (beat_cnt == CB-1) begin
                    cmd_active <= 1'b0;
                    if (!bank_wr) begin
                        b0_ready <= 1'b1;
                        b0_line  <= tag_head[14:3];
                        b0_ch    <= tag_head[2:0];
                    end else begin
                        b1_ready <= 1'b1;
                        b1_line  <= tag_head[14:3];
                        b1_ch    <= tag_head[2:0];
                    end
                    tag_rp  <= tag_rp + 2'd1;
                    bank_wr <= ~bank_wr;
                end
            end

            // ---- 排空 ----
            // b*_ready 必须等排空**做完**才清，否则会写正在被读的 bank
            if (!drn_act) begin
                ls_we <= 1'b0;
                if (b0_ready) begin
                    drn_act <= 1'b1; drn_sel <= 1'b0; drn_cnt <= 6'd0;
                end else if (b1_ready) begin
                    drn_act <= 1'b1; drn_sel <= 1'b1; drn_cnt <= 6'd0;
                end
            end else begin
                ls_we <= (STORE_TEST == 0);
                ls_wa <= drn_wa;
                ls_wd <= drn_sel ? stg1[drn_off +: 64] : stg0[drn_off +: 64];
                drn_cnt <= drn_cnt + 6'd1;
                if (drn_cnt == 6'd63) begin
                    drn_act <= 1'b0;
                    // Next DDR edge must still commit the final (63rd) word.
                    if (drn_sel) b1_ready <= 1'b0;
                    else         b0_ready <= 1'b0;
                end
            end
        end
    end

    // ddr_rreq 
    assign ddr_rreq   = rreq_r;
    // ddr_raddr 
    assign ddr_raddr  = {4'd0, frame_sel, 2'b00, addr_lo}
                      + ADDR_OFFSET[ADDR_WIDTH-1:0];
    // ddr_rd_len 
    assign ddr_rd_len = CB;

    //=========================================================================
    // vout 域：复位 / 帧起始 / 行起止 / 坐标计数
    //=========================================================================
    reg [2:0] vs_rst;
    
    always @(posedge vout_clk) vs_rst <= {vs_rst[1:0], ddr_rstn};
    wire vout_rst_n = vs_rst[2];

    reg [1:0] fs_v;
    
    always @(posedge vout_clk) fs_v <= {fs_v[0], rd_fsync};
    wire frm_start_v = fs_v[1] & ~fs_v[0];

    reg [1:0] en_v;
    
    always @(posedge vout_clk) en_v <= {en_v[0], rd_en};
    // en_v[0] = rd_en 延迟 1 拍，en_v[1] = 延迟 2 拍
    wire line_start = en_v[0] & ~en_v[1];
    wire line_end   = ~en_v[0] & en_v[1];

    reg [11:0] xc, yc;
    
    always @(posedge vout_clk) begin
        if (!vout_rst_n)      xc <= 12'd0;
        else if (!rd_en)      xc <= 12'd0;
        else                  xc <= xc + 12'd1;
    end
    
    always @(posedge vout_clk) begin
        if (!vout_rst_n)      yc <= 12'd0;
        else if (frm_start_v) yc <= 12'd0;
        else if (line_end)    yc <= yc + 12'd1;
    end

    //=========================================================================
    // 像素映射（dist_calc 实例 1）—— 直通档会被综合优化掉
    //=========================================================================
    wire signed [23:0] xs_q, ys_q;
    
    wire               map_valid;

    dist_calc #(.XW(12), .AW(10), .PW(34)) u_pix (
        .clk       (vout_clk),
        .rst_n     (vout_rst_n),
        .cx_q      (CXQ[23:0]),
        .cy_q      (CYQ[23:0]),
        .p1q       (-16'sd276),
        .p2q       (16'sd883),
        .lut_we    (1'b0),
        .lut_addr  (10'd0),
        .lut_wdata (18'sd0),
        .u         (xc),
        .v         (yc),
        .in_valid  (rd_en),
        .xs_q      (xs_q),
        .ys_q      (ys_q),
        .out_valid (map_valid)
    );

    wire [23:0] xs_u = (WARP_EN != 0) ? xs_q : {xc, 12'd0};
    wire [23:0] ys_u = (WARP_EN != 0) ? ys_q : {yc, 12'd0};

    wire in_img = ~xs_u[23] && ~ys_u[23] &&
                  (xs_u < 24'd7864320) && (ys_u < 24'd4423680);
    wire [10:0] xi = xs_u[22:12];
    wire [10:0] yi = ys_u[22:12];

    // 相邻源行/字分布在不同存储体。读取全部四个候选样本，再从每行选出两个像素；图像边缘做限幅处理。
    wire [8:0] word0 = {1'b0,xi[10:2]};
    wire [8:0] even_word = word0[0] ? word0+9'd1 : word0;
    wire [8:0] odd_word  = word0[0] ? word0 : word0+9'd1;
    wire [10:0] even_row = yi[0] ? yi+11'd1 : yi;
    wire [10:0] odd_row  = yi[0] ? yi : yi+11'd1;
    reg [13:0] ra00,ra01,ra10,ra11;
    reg [63:0] q00,q01,q10,q11;
    reg [1:0] sub_a,sub_b,sub_c;
    reg lastx_c,lasty_c;
    reg [63:0] top_word,bot_word,top_next,bot_next;
    reg row_a,row_b,word_a,word_b,lastx_a,lastx_b,lasty_a,lasty_b;
    reg [7:0] fx_a,fx_b,fx_c,fx_d,fy_a,fy_b,fy_c,fy_d;
    
    reg img_a,img_b,img_c,img_d,valid_a,valid_b,valid_c,valid_d;
    reg [15:0] p00,p01,p10,p11;
    
    wire source_valid = (WARP_EN != 0) ? map_valid : rd_en;
    
    always @(posedge vout_clk) begin
        ra00 <= {even_row[6:1],even_word[8:1]};
        ra01 <= {even_row[6:1],odd_word[8:1]};
        ra10 <= {odd_row[6:1],even_word[8:1]};
        ra11 <= {odd_row[6:1],odd_word[8:1]};
        q00 <= ls00[ra00]; q01 <= ls01[ra01];
        q10 <= ls10[ra10]; q11 <= ls11[ra11];
        sub_a <= xi[1:0]; sub_b <= sub_a; sub_c <= sub_b;
        row_a <= yi[0]; row_b <= row_a;
        word_a <= word0[0]; word_b <= word_a;
        lastx_a <= (xi==11'd1919); lastx_b <= lastx_a; lastx_c <= lastx_b;
        lasty_a <= (yi==11'd1079); lasty_b <= lasty_a; lasty_c <= lasty_b;
        fx_a <= xs_u[11:4]; fx_b <= fx_a; fx_c <= fx_b; fx_d <= fx_c;
        fy_a <= ys_u[11:4]; fy_b <= fy_a; fy_c <= fy_b; fy_d <= fy_c;
        img_a <= in_img; img_b <= img_a; img_c <= img_b; img_d <= img_c;
        if(!vout_rst_n) begin valid_a<=0;valid_b<=0;valid_c<=0;valid_d<=0;end
        else begin valid_a<=source_valid;valid_b<=valid_a;valid_c<=valid_b;valid_d<=valid_c;end
        top_word<=top_word_comb;bot_word<=bot_word_comb;top_next<=top_next_comb;bot_next<=bot_next_comb;
        p00 <= sample00; p01 <= sample01; p10 <= sample10; p11 <= sample11;
    end
    wire [63:0] top_even = row_b ? q10:q00;
    wire [63:0] top_odd  = row_b ? q11:q01;
    wire [63:0] bot_even = row_b ? q00:q10;
    wire [63:0] bot_odd  = row_b ? q01:q11;
    wire [63:0] top_word_comb = word_b ? top_odd:top_even;
    wire [63:0] bot_word_comb = word_b ? bot_odd:bot_even;
    wire [63:0] top_next_comb = word_b ? top_even:top_odd;
    wire [63:0] bot_next_comb = word_b ? bot_even:bot_odd;
    wire [15:0] sample00 = top_word >> {sub_c,4'b0};
    wire [15:0] sample01 = lastx_c ? sample00 :
                           (sub_c==3 ? top_next[15:0] : (top_word >> ({1'b0,sub_c,4'b0}+7'd16)));
    wire [15:0] sample10 = lasty_c ? sample00 : (bot_word >> {sub_c,4'b0});
    wire [15:0] sample11 = lasty_c ? sample01 : lastx_c ? sample10 :
                           (sub_c==3 ? bot_next[15:0] : (bot_word >> ({1'b0,sub_c,4'b0}+7'd16)));
    
    wire bil_valid;
    wire [15:0] bil_pixel;
    v8_bilinear565 u_bilinear(.clk(vout_clk),.rst_n(vout_rst_n),
       .valid_in(valid_d),.in_image(img_d),.fx(fx_d),.fy(fy_d),
       .p00(p00),.p01(p01),.p10(p10),.p11(p11),
       .valid_out(bil_valid),.pixel(bil_pixel));
    // vout_de 
    assign vout_de = bil_valid;
    // vout_data 
    assign vout_data = bil_pixel;

    //=========================================================================
    // 行包络（dist_calc 实例 2）—— 直通档会被综合优化掉
    //=========================================================================
    reg [4:0]  env_ph;
    reg        env_iv;
    reg [11:0] env_u, env_v;
    wire signed [23:0] env_xs, env_ys;
    wire               env_ov;

    dist_calc #(.XW(12), .AW(10), .PW(34)) u_env (
        .clk       (vout_clk),
        .rst_n     (vout_rst_n),
        .cx_q      (CXQ[23:0]),
        .cy_q      (CYQ[23:0]),
        .p1q       (-16'sd276),
        .p2q       (16'sd883),
        .lut_we    (1'b0),
        .lut_addr  (10'd0),
        .lut_wdata (18'sd0),
        .u         (env_u),
        .v         (env_v),
        .in_valid  (env_iv),
        .xs_q      (env_xs),
        .ys_q      (env_ys),
        .out_valid (env_ov)
    );

    // 包络取三点：u=0 / u=cx(=921) / u=1919。
    // 径向映射 ys = cy + dy·s(r²)，s 随 r² 单调下降：
    //   dy>0（下半屏）最大值在 r 最小处 -> u=cx
    //   dy<0（上半屏）最大 s->最小 ys，故 ys 最大在 r 最大处 -> 离主点最远的边
    // cx=920.94 < 960，所以右边缘 |dx|=998 比左边 921 更远 —— 只采 u=0 和 u=960
    // 会低估 ymax 最多 4.7 行（60/540 行超过 MARGIN=4），导致 target 提前收手、
    // 每行顶部几行源数据是旧的 -> 屏幕上表现为横向条纹 + 闪烁。
    reg signed [23:0] ys_a, ys_b, ys_c;
    reg        got_a, got_b, got_c;
    reg [11:0] ymin_r, ymax_r;

    wire signed [23:0] ya = ys_a >>> 12;
    wire signed [23:0] yb = ys_b >>> 12;
    wire signed [23:0] yc3 = ys_c >>> 12;
    wire [11:0] ya_c = ya[23]  ? 12'd0 : ((ya  > 24'sd1079) ? 12'd1079 : ya[11:0]);
    wire [11:0] yb_c = yb[23]  ? 12'd0 : ((yb  > 24'sd1079) ? 12'd1079 : yb[11:0]);
    wire [11:0] yc_c = yc3[23] ? 12'd0 : ((yc3 > 24'sd1079) ? 12'd1079 : yc3[11:0]);
    wire [11:0] y_lo = (ya_c < yb_c) ? ((ya_c < yc_c) ? ya_c : yc_c)
                                     : ((yb_c < yc_c) ? yb_c : yc_c);
    wire [11:0] y_hi = (ya_c > yb_c) ? ((ya_c > yc_c) ? ya_c : yc_c)
                                     : ((yb_c > yc_c) ? yb_c : yc_c);

    // 直通档：显示第 v 行就读第 v 行，超前 ID_LEAD(=32) 行（必须 < 窗口 64）
    // 校正档：目标行取包络上界 + 余量
    wire [11:0] tgt_next = (WARP_EN != 0) ? (y_hi + MARGIN) : (yc + ID_LEAD[11:0]);

    
    always @(posedge vout_clk) begin
        if (!vout_rst_n) begin
            env_ph  <= 5'd0;  env_iv <= 1'b0;
            env_u   <= 12'd0; env_v  <= 12'd0;
            got_a   <= 1'b0;  got_b  <= 1'b0; got_c <= 1'b0;
            ys_a    <= 24'sd0; ys_b  <= 24'sd0; ys_c <= 24'sd0;
            ymin_r  <= FL_START[11:0];
            ymax_r  <= FL_START[11:0] + 12'd60;
            tgt_val <= tgt_init;
            tgt_tog <= 1'b0;
        end else begin
            env_iv <= 1'b0;
            if (line_start) begin
                env_ph <= 5'd1;
                env_v  <= yc;
                env_u  <= 12'd0;
                env_iv <= 1'b1;
                got_a  <= 1'b0;
                got_b  <= 1'b0;
                got_c  <= 1'b0;
            end else if (env_ph != 5'd0) begin
                env_ph <= env_ph + 5'd1;
                if (env_ph == 5'd8) begin
                    env_u  <= CXQ[23:12];       // ≈921，主点所在列
                    env_iv <= 1'b1;
                end
                if (env_ph == 5'd15) begin
                    env_u  <= 12'd1919;         // 离主点最远的右边缘
                    env_iv <= 1'b1;
                end
                if (env_ov) begin
                    if (!got_a) begin ys_a <= env_ys; got_a <= 1'b1; end
                    else if (!got_b) begin ys_b <= env_ys; got_b <= 1'b1; end
                    else if (!got_c) begin ys_c <= env_ys; got_c <= 1'b1; end
                end
                if (env_ph == 5'd24) begin
                    env_ph <= 5'd0;
                    ymin_r  <= y_lo;
                    ymax_r  <= y_hi;
                    tgt_val <= tgt_next;
                    tgt_tog <= ~tgt_tog;
                end
            end
        end
    end

reg [31:0] diag_commands;

always @(posedge ddr_clk) begin
 if (!ddr_rst_n) diag_commands <= 0;
 else if (issue_ok) diag_commands <= diag_commands + 1;
end
// video_diag 
assign video_diag = {diag_commands,4'd0,fl,4'd0,target};
endmodule

// 三级RGB565插值，采用Q0.8小数格式，就近舍入。

module v8_bilinear565(input clk,rst_n,valid_in,in_image,input [7:0] fx,fy,
 input [15:0] p00,p01,p10,p11,output reg valid_out,output reg [15:0] pixel);
 wire [8:0] wx0=9'd256-{1'b0,fx}, wx1={1'b0,fx};
 reg [14:0] hr0,hr1,hg0,hg1,hb0,hb1;
 reg [7:0] fy1;
 reg v1,v2,im1,im2;
 reg [23:0] vr0,vr1,vg0,vg1,vb0,vb1;
 wire [8:0] wy0=9'd256-{1'b0,fy1},wy1={1'b0,fy1};
 wire [24:0] sr={1'b0,vr0}+{1'b0,vr1}+25'd32768;
 wire [24:0] sg={1'b0,vg0}+{1'b0,vg1}+25'd32768;
 wire [24:0] sb={1'b0,vb0}+{1'b0,vb1}+25'd32768;
 
 always @(posedge clk) begin
  hr0<=p00[15:11]*wx0+p01[15:11]*wx1;
  hr1<=p10[15:11]*wx0+p11[15:11]*wx1;
  hg0<=p00[10:5]*wx0+p01[10:5]*wx1;
  hg1<=p10[10:5]*wx0+p11[10:5]*wx1;
  hb0<=p00[4:0]*wx0+p01[4:0]*wx1;
  hb1<=p10[4:0]*wx0+p11[4:0]*wx1;
  fy1<=fy; im1<=in_image; im2<=im1;
  vr0<=hr0*wy0;vr1<=hr1*wy1;
  vg0<=hg0*wy0;vg1<=hg1*wy1;
  vb0<=hb0*wy0;vb1<=hb1*wy1;
  if(!rst_n) begin v1<=0;v2<=0;valid_out<=0;pixel<=0;end
  else begin v1<=valid_in;v2<=v1;valid_out<=v2;
   pixel<=im2 ? {sr[20:16],sg[21:16],sb[20:16]}:16'd0;
  end
 end
endmodule
