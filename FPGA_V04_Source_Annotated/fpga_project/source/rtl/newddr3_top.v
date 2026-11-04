// 工程综合顶层，连接板卡时钟、复位、DDR、HDMI 与串口接口。
//=============================================================================
// newddr3_top.v : NewDDR3 顶层（基于厂商 5_12_HDMI_IN_DDR3_HDMI_OUT 改造）
//

//
// 按键功能（active-low，板上按下为低）
// ---------------------------------------------------------------------------
//   不按键      : DDR3 通路  —— HDMI IN → DDR3 双帧缓存 → HDMI OUT（厂商原功能）
//   KEY1        : 直通        —— HDMI IN 直接转发到 HDMI OUT（不经 DDR3，可判断输入信号是否正常）
//   KEY2        : 彩条        —— 内部生成 8 色彩条（不依赖输入，验证输出通路）
//   KEY1+KEY2   : 灰阶渐变    —— 内部生成水平灰阶（检查输出数据位宽/线性度）
//
// LED
// ---------------------------------------------------------------------------
//   heart_beat_led : DDR3 未就绪时常亮，就绪后 1 Hz 闪烁
//   ddr_init_done  : DDR3 校准完成
//   init_over_rx   : HDMI 输入芯片（MS7200）初始化完成
//   hdmi_int_led   : HDMI 输出芯片（MS7210）初始化完成
//   led_mode[3:0]  : 当前模式指示  (4=直通 2=彩条 1=灰阶 8=DDR3通路)
//=============================================================================

module newddr3_top (
    output wire uart_txd,
    input wire uart_rxd,
    // ---------------- 时钟与复位 ----------------
    input  wire         sys_clk,          // 27 MHz
    input  wire         clk_p,            // 125 MHz 差分参考
    input  wire         clk_n,
    input  wire         rst_in,           // 板级复位（KEY0，低有效）
    input  wire         key1_n,           // KEY1
    input  wire         key2_n,           // KEY2

    // ---------------- DDR3 ----------------
    output wire         mem_cs_n,
    output wire         mem_rst_n,
    output wire         mem_ck,
    output wire         mem_ck_n,
    output wire         mem_cke,
    output wire         mem_ras_n,
    output wire         mem_cas_n,
    output wire         mem_we_n,
    output wire         mem_odt,
    output wire [14:0]  mem_a,
    output wire [2:0]   mem_ba,
    inout  wire [3:0]   mem_dqs,
    inout  wire [3:0]   mem_dqs_n,
    inout  wire [31:0]  mem_dq,
    output wire [3:0]   mem_dm,

    // ---------------- 状态 LED（与厂商同名同脚）----------------
    output wire         heart_beat_led,
    output wire         ddr_init_done,
    output wire         init_over_rx,
    output wire         rstn_out,
    output wire         hdmi_int_led,

    // ---------------- I2C（HDMI 配置）----------------
    output wire         hd_scl,
    inout  wire         hd_sda,

    // ---------------- HDMI 输入 ----------------
    input  wire         pixclk_in,
    input  wire         vs_in,
    input  wire         hs_in,
    input  wire         de_in,
    input  wire [7:0]   r_in,
    input  wire [7:0]   g_in,
    input  wire [7:0]   b_in,

    // ---------------- HDMI 输出 ----------------
    output wire         pix_clk,
    output wire         vs_out,
    output wire         hs_out,
    output wire         de_out,
    output wire [7:0]   r_out,
    output wire [7:0]   g_out,
    output wire [7:0]   b_out,

    // ---------------- 模式指示 LED ----------------
    output wire [3:0]   led_mode
);
    //=========================================================================
    // 1) 按键同步 + 消抖（sys_clk 27 MHz，20 ms）
    //=========================================================================
    reg [1:0] k1_sync, k2_sync;
    reg [19:0] k1_cnt, k2_cnt;
    reg        k1_down, k2_down;

    
    always @(posedge sys_clk) begin
        k1_sync <= {k1_sync[0], key1_n};
        k2_sync <= {k2_sync[0], key2_n};
    end

    
    always @(posedge sys_clk) begin
        if (k1_sync[1]) begin
            k1_cnt <= 20'd0;
            k1_down <= 1'b0;
        end else if (k1_cnt != 20'd539999) begin      // 20 ms @27MHz
            k1_cnt <= k1_cnt + 20'd1;
        end else begin
            k1_down <= 1'b1;
        end

        if (k2_sync[1]) begin
            k2_cnt <= 20'd0;
            k2_down <= 1'b0;
        end else if (k2_cnt != 20'd539999) begin
            k2_cnt <= k2_cnt + 20'd1;
        end else begin
            k2_down <= 1'b1;
        end
    end

    wire mode_ddr    = !k1_down && !k2_down;   // 默认：DDR3 通路
    wire mode_bypass =  k1_down && !k2_down;   // KEY1：直通
    wire mode_bars   = !k1_down &&  k2_down;   // KEY2：彩条
    wire mode_gray   =  k1_down &&  k2_down;   // 双键：灰阶

    //=========================================================================
    // 2) 厂商设计实例（DDR3 + HDMI 全部原样）
    //=========================================================================
    wire        v_pix_clk, v_vs, v_hs, v_de;
    wire [7:0]  v_r, v_g, v_b;

    wire dump_uart_tx,dump_uart_active,diag_uart_tx;
    // uart_txd 
    assign uart_txd=dump_uart_active?dump_uart_tx:diag_uart_tx;
    wire[319:0] performance_diag;
    wire [63:0] video_diag;
    wire [31:0] preproc_diag;
    wire [95:0] input_diag;
    HDMI_IN_DDR3_HDMI_OUT_top u_ddr_core (
        .dump_uart_tx(dump_uart_tx),.dump_uart_active(dump_uart_active),
        .performance_diag(performance_diag),.video_diag(video_diag),
        .preproc_diag(preproc_diag),.input_diag(input_diag),
        .uart_rxd(uart_rxd),
        .sys_clk        (sys_clk),
        .clk_p          (clk_p),
        .clk_n          (clk_n),
        .rst_in         (rst_in),

        .mem_cs_n       (mem_cs_n),
        .mem_rst_n      (mem_rst_n),
        .mem_ck         (mem_ck),
        .mem_ck_n       (mem_ck_n),
        .mem_cke        (mem_cke),
        .mem_ras_n      (mem_ras_n),
        .mem_cas_n      (mem_cas_n),
        .mem_we_n       (mem_we_n),
        .mem_odt        (mem_odt),
        .mem_a          (mem_a),
        .mem_ba         (mem_ba),
        .mem_dqs        (mem_dqs),
        .mem_dqs_n      (mem_dqs_n),
        .mem_dq         (mem_dq),
        .mem_dm         (mem_dm),

        .heart_beat_led (heart_beat_led),
        .ddr_init_done  (ddr_init_done),
        .init_over_rx   (init_over_rx),
        .rstn_out       (rstn_out),
        .hdmi_int_led   (hdmi_int_led),

        .hd_scl         (hd_scl),
        .hd_sda         (hd_sda),

        .pixclk_in      (pixclk_in),
        .vs_in          (vs_in),
        .hs_in          (hs_in),
        .de_in          (de_in),
        .r_in           (r_in),
        .g_in           (g_in),
        .b_in           (b_in),

        .pix_clk        (v_pix_clk),
        .vs_out         (v_vs),
        .hs_out         (v_hs),
        .de_out         (v_de),
        .r_out          (v_r),
        .g_out          (v_g),
        .b_out          (v_b)
    );

    //=========================================================================
    // 3) 内部图案发生器（彩条 / 灰阶），使用厂商的输出时序
    //=========================================================================
    reg [11:0] h_cnt;
    reg [9:0]  v_cnt;

    
    always @(posedge v_pix_clk) begin
        if (v_hs) begin
            if (v_vs) v_cnt <= 10'd0;
        end
        if (v_de) h_cnt <= h_cnt + 12'd1;
        else      h_cnt <= 12'd0;
    end

    // 8 级彩条（白 黄 青 绿 品 红 蓝 黑）
    reg [23:0] bar_rgb;
    
    always @(*) begin
        
        case (h_cnt[11:8])
            3'd0: bar_rgb = 24'hFFFFFF;
            3'd1: bar_rgb = 24'hFFFF00;
            3'd2: bar_rgb = 24'h00FFFF;
            3'd3: bar_rgb = 24'h00FF00;
            3'd4: bar_rgb = 24'hFF00FF;
            3'd5: bar_rgb = 24'hFF0000;
            3'd6: bar_rgb = 24'h0000FF;
            default: bar_rgb = 24'h000000;
        endcase
    end

    // 灰阶：取列坐标高 8 位
    wire [23:0] gray_rgb = {h_cnt[11:4], h_cnt[11:4], h_cnt[11:4]};

    wire [23:0] pat_rgb = mode_gray ? gray_rgb : bar_rgb;

    //=========================================================================
    // KEY1 模式：坐标映射离线验证（内部棋盘格 + dist_calc 逆映射）
    //   屏幕应显示枕形弯曲的棋盘格，弯曲量与标定的桶形畸变对应
    //=========================================================================
    wire        map_hs, map_vs, map_de;
    wire [23:0] map_rgb;
    wire [11:0] map_sx, map_sy;

    remap_test u_maptest (
        .clk        (v_pix_clk),
        .rst_n      (ddr_init_done),
        .cx_q       (24'sd3772163),   // 920.94 px (新镜头, Q4.12)
        .cy_q       (24'sd2183633),   // 533.11 px (新镜头, Q4.12)
                // 切向系数：p1q/p2q = round(p/f * 2^30)。注意归一化是 p/f（不是 p/f^2），
// 因为前向模型在像素域是 tx = (2*p1*dx*dy + p2*(r^2+2dx^2)) / f。
// p1=-0.000214, p2=+0.000685 -> p1q=-276, p2q=883（角点位移约 2~3 px）。
        // 拿到 p1、p2 后按 round(p/f^2 * 2^30) 填写即可（f = 1103.71）。
        .p1q        (-32'sd276),
        .p2q        (32'sd883),
        .lut_we     (1'b0),
        .lut_addr   (10'd0),
        .lut_wdata  (18'sd0),
        .hs         (map_hs),
        .vs         (map_vs),
        .de         (map_de),
        .rgb        (map_rgb),
        .dbg_sx     (map_sx),
        .dbg_sy     (map_sy)
    );

    //=========================================================================
    // 4) 输出选择
    //=========================================================================
    wire        use_pat = mode_bars || mode_gray;

    // pix_clk 
    assign pix_clk = v_pix_clk;

    // vs_out 
    assign vs_out  = mode_bypass ? map_vs : v_vs;
    // hs_out 
    assign hs_out  = mode_bypass ? map_hs : v_hs;
    // de_out 
    assign de_out  = mode_bypass ? map_de : v_de;

    // r_out 
    assign r_out   = mode_bypass ? map_rgb[23:16] : use_pat ? pat_rgb[23:16] : v_r;
    // g_out 
    assign g_out   = mode_bypass ? map_rgb[15:8]  : use_pat ? pat_rgb[15:8]  : v_g;
    // b_out 
    assign b_out   = mode_bypass ? map_rgb[7:0]   : use_pat ? pat_rgb[7:0]   : v_b;

    //=========================================================================
    // 5) 模式指示
    //=========================================================================
    // led_mode[0] 
    assign led_mode[0] = mode_ddr;
    // led_mode[1] 
    assign led_mode[1] = mode_bypass;
    // led_mode[2] 
    assign led_mode[2] = mode_bars;
    // led_mode[3] 
    assign led_mode[3] = mode_gray;

wire[111:0] fps_in_pixels,fps_out_pixels;
wire[319:0] fps_in_sync,fps_out_sync;
reg[31:0] fps_sys_ticks;

always @(posedge sys_clk or negedge rst_in)if(!rst_in)fps_sys_ticks<=0;else fps_sys_ticks<=fps_sys_ticks+1;
fps_frame_probe fps_input(pixclk_in,rst_in,de_in,{r_in[7:3],g_in[7:2],b_in[7:3]},fps_in_pixels);
fps_frame_probe fps_output(v_pix_clk,rst_in,v_de,{v_r[7:3],v_g[7:2],v_b[7:3]},fps_out_pixels);
performance_snapshot_cdc fps_input_cdc(pixclk_in,rst_in,{208'd0,fps_in_pixels},sys_clk,rst_in,fps_in_sync);
performance_snapshot_cdc fps_output_cdc(v_pix_clk,rst_in,{208'd0,fps_out_pixels},sys_clk,rst_in,fps_out_sync);
wire[255:0] fps_diag={fps_sys_ticks,fps_in_sync[111:0],fps_out_sync[111:0]};
video_diag_uart u_video_uart (.fps_diag(fps_diag),.performance_diag(performance_diag),.clk(sys_clk),.rst_n(rst_in),.pclk(pixclk_in),.vs(vs_in),.de(de_in),.flags({3'b0,video_diag[11],key1_n,key2_n,init_over_rx,ddr_init_done}),.rd_diag(video_diag),.preproc_diag(preproc_diag),.input_diag(input_diag),.tx(diag_uart_tx));
endmodule


module video_diag_uart #(parameter REPORT_CYCLES=27000000,BAUD_RELOAD=233)(input[255:0] fps_diag,input[319:0] performance_diag,input clk,rst_n,pclk,vs,de,input [7:0] flags,input [63:0] rd_diag,input [31:0] preproc_diag,input [95:0] input_diag,output reg tx=1);
reg de_d=0,vs_d=0;reg [15:0] x=0,lines=0,width=0,height=0,frames=0;
reg [12:0] frame_gap=0;

always @(posedge pclk or negedge rst_n) begin
 if(!rst_n) begin de_d<=0;vs_d<=0;x<=0;lines<=0;width<=0;height<=0;frames<=0;frame_gap<=0;end
 else begin de_d<=de;vs_d<=vs;
 if(de) x<=x+1;
 if(de_d&&!de) begin width<=x;x<=0;lines<=lines+1;end
 // Count frames from a long DE gap independently of VS polarity.
 if(de) frame_gap<=0;
 else if(frame_gap!=13'h1fff) frame_gap<=frame_gap+1;
 if(frame_gap==13'd4095) begin height<=lines;lines<=0;frames<=frames+1;end
 end
end
wire[127:0] related_snapshot;
preproc_snapshot_cdc stats_snapshot(pclk,rst_n,{preproc_diag,input_diag},preproc_diag[7:0],clk,rst_n,related_snapshot);
reg[127:0] debug_meta=0,debug_sync=0,probe_snap=0;
reg [159:0] meta=0,sync=0,snap=0;

always @(posedge clk) begin meta<={8'hA3,flags,width,height,frames,rd_diag,preproc_diag};sync<=meta;debug_meta<=related_snapshot;debug_sync<=debug_meta;end
reg[319:0] perf_snap=0;reg[255:0] fps_snap=0;
reg [24:0] timer=0;reg [7:0] pos=0;reg [3:0] bitno=0;reg [7:0] ch=0;reg [8:0] baud=0;reg busy=0,active=0;
wire [3:0] nib=(snap >> ((40-pos)*4));
wire[3:0] probe_nib=(probe_snap>>((75-pos)*4));
wire[3:0] perf_nib=perf_snap>>((158-pos)*4);
wire[3:0] fps_nib=fps_snap>>((225-pos)*4);
wire [7:0] nextch=(pos==161)?8'h46:(pos==226)?8'h0d:(pos==227)?8'h0a:(pos>161)?((fps_nib<10)?8'h30+fps_nib:8'h41+fps_nib-10):(pos==78)?8'h52:(pos==159)?8'h0d:(pos==160)?8'h0a:(pos>78)?((perf_nib<10)?8'h30+perf_nib:8'h41+perf_nib-10):(pos==0)?8'h44:(pos==43)?8'h50:(pos==41||pos==76)?8'h0d:(pos==42||pos==77)?8'h0a:
 (pos<41)?((nib<10)?(8'h30+nib):(8'h41+nib-10)):((probe_nib<10)?(8'h30+probe_nib):(8'h41+probe_nib-10));

always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin timer<=0;pos<=0;bitno<=0;baud<=0;busy<=0;active<=0;tx<=1;snap<=0;ch<=0;probe_snap<=0;end
 else begin
 if(timer==REPORT_CYCLES-1) begin timer<=0;if(!active) begin active<=1;pos<=0;snap<={sync[159:32],debug_sync[127:96]};probe_snap<=debug_sync;perf_snap<=performance_diag;fps_snap<=fps_diag;end end else timer<=timer+1;
 if(active&&!busy) begin ch<=nextch;tx<=0;busy<=1;baud<=BAUD_RELOAD;bitno<=0;end
 else if(busy) begin
 if(baud!=0) baud<=baud-1;
 else begin baud<=BAUD_RELOAD;
 if(bitno<8) begin tx<=ch[bitno];bitno<=bitno+1;end
 else if(bitno==8) begin tx<=1;bitno<=9;end
 else begin busy<=0;if(pos==227) active<=0;else pos<=pos+1;end
 end end end end
endmodule


module performance_snapshot_cdc(input sc,sr,input[319:0] payload,input dc,dr,output reg[319:0] result=0);
reg[319:0] held=0;reg request=0,ack=0;reg[1:0] async_ack=0,async_req=0;

always @(posedge sc or negedge sr)if(!sr)begin held<=0;request<=0;async_ack<=0;end else begin
 async_ack<={async_ack[0],ack};if(async_ack[1]==request)begin held<=payload;request<=~request;end end

always @(posedge dc or negedge dr)if(!dr)begin result<=0;ack<=0;async_req<=0;end else begin
 async_req<={async_req[0],request};if(async_req[1]!=ack)begin result<=held;ack<=async_req[1];end end
endmodule

// 无源1080p扫描/标记新鲜度监测器，位于HDMI发送器前端。
// 中心标记发生变更代表一路新输入标识，并非配置序列。

module fps_frame_probe #(parameter WIDTH=1920,HEIGHT=1080,GAP=4096)(
 input clk,rst_n,de,input[15:0] pixel,output[111:0] snapshot);
reg de_d;reg[12:0] x,lines,gap;reg[23:0] pixels;
reg line_bad,sample_seen,have_previous;reg[15:0] sample,last_sample;
reg[31:0] frames,changes;reg[15:0] bad_frames,repeat_run,max_repeat;
// snapshot 
assign snapshot={frames,changes,bad_frames,last_sample,max_repeat};

always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin de_d<=0;x<=0;lines<=0;gap<=0;pixels<=0;line_bad<=0;sample_seen<=0;have_previous<=0;sample<=0;last_sample<=0;frames<=0;changes<=0;bad_frames<=0;repeat_run<=0;max_repeat<=0;end
 else begin
  de_d<=de;
  if(de)begin
   gap<=0;x<=x+1;pixels<=pixels+1;
   if(x==WIDTH/2&&lines==HEIGHT/2)begin sample<={13'd0,pixel[15],pixel[10],pixel[4]};sample_seen<=1;end
  end else if(gap<GAP)gap<=gap+1;
  if(de_d&&!de)begin if(x!=WIDTH)line_bad<=1;x<=0;lines<=lines+1;end
  if(gap==GAP-1)begin
   if(pixels!=0)begin
    frames<=frames+1;
    if(pixels==WIDTH*HEIGHT&&lines==HEIGHT&&!line_bad&&sample_seen)begin
     if(!have_previous||sample!=last_sample)begin
      if(have_previous)changes<=changes+1;
      repeat_run<=1;last_sample<=sample;have_previous<=1;
     end else begin repeat_run<=repeat_run+1;if(repeat_run+1>max_repeat)max_repeat<=repeat_run+1;end
    end else bad_frames<=bad_frames+1;
   end
   x<=0;lines<=0;pixels<=0;line_bad<=0;sample_seen<=0;
  end
 end
end
endmodule
