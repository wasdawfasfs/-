// 保留的测试/彩条与映射路径，维持原模式和同步延迟。
//=============================================================================
// remap_test.v : 坐标映射离线验证（不依赖 DDR3 / 相机）
//
// 目的
// ----
// 用**内部生成的棋盘格**充当"源图"，经过 dist_calc 的逆映射后输出。
// 显示器上应看到棋盘格被**反向弯曲**（枕形），弯曲量与标定的桶形畸变相等，
// 从而验证：
//   1. dist_calc 在 1080p 参数下坐标映射正确；
//   2. 定点格式、LUT 索引、主点偏移都没有问题。
//
// 为什么能看出对错
// ----------------
// 源图是"直"的棋盘格。逆映射把输出像素 (x,y) 送到源坐标 (xs,ys)，
// 对桶形畸变（k1<0）而言，越靠边缘的像素会被送到更靠内的源位置，
// 因此输出图像呈现**枕形**（四边向内凹）——这正是我们要的校正方向。
// 若映射正确，弯曲量应与标定值吻合并左右上下对称。
//
// 时序：与厂商 sync_vg 完全一致（1920x1080@60，H_TOTAL=2200, V_TOTAL=1125）
//=============================================================================
module remap_test #(
    
    parameter integer H_TOTAL = 2200,
    
    parameter integer H_SYNC  = 44,
    
    parameter integer H_BP    = 148,
    
    parameter integer H_ACT   = 1920,
    
    parameter integer V_TOTAL = 1125,
    
    parameter integer V_SYNC  = 5,
    
    parameter integer V_BP    = 36,
    
    parameter integer V_ACT   = 1080,
    
    parameter integer CELL    = 64          // 棋盘格边长（源像素）
)(
    input  wire                clk,         // 像素时钟 148.5 MHz
    input  wire                rst_n,

    input  wire signed [23:0]  cx_q,
    input  wire signed [23:0]  cy_q,
    input  wire signed [31:0]  p1q,
    input  wire signed [31:0]  p2q,

    input  wire                lut_we,
    input  wire [9:0]          lut_addr,
    input  wire signed [17:0]  lut_wdata,

    output wire                hs,
    output wire                vs,
    output wire                de,
    output wire [23:0]         rgb,

    // 调试：输出当前映射到的源坐标（供 LED/串口观测）
    output wire [11:0]         dbg_sx,
    output wire [11:0]         dbg_sy
);
    
    localparam integer DELAY = 11;         // dist_calc 7 + /6 1 + *320 1 + ROM 1 + pat_r 1

    //=========================================================================
    // 1) 1080p 时序发生器
    //=========================================================================
    reg [11:0] h_cnt, v_cnt;
    reg        hs_r, vs_r, de_r;
    reg [11:0] x_r, y_r;

    wire hs_act = (h_cnt < H_SYNC);
    wire vs_act = (v_cnt < V_SYNC);
    wire de_act = (h_cnt >= H_SYNC + H_BP) && (h_cnt < H_SYNC + H_BP + H_ACT) &&
                  (v_cnt >= V_SYNC + V_BP) && (v_cnt < V_SYNC + V_BP + V_ACT);

    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt <= 12'd0; v_cnt <= 12'd0;
            hs_r <= 1'b0; vs_r <= 1'b0; de_r <= 1'b0;
            x_r <= 12'd0; y_r <= 12'd0;
        end else begin
            if (h_cnt == H_TOTAL-1) begin
                h_cnt <= 12'd0;
                if (v_cnt == V_TOTAL-1) v_cnt <= 12'd0;
                else                    v_cnt <= v_cnt + 12'd1;
            end else h_cnt <= h_cnt + 12'd1;

            hs_r <= ~hs_act;              // 1080p 为负极性同步
            vs_r <= ~vs_act;
            de_r <= de_act;

            if (de_act) begin
                x_r <= h_cnt - (H_SYNC + H_BP);
                y_r <= v_cnt - (V_SYNC + V_BP);
            end
        end
    end

    //=========================================================================
    // 2) 畸变逆映射
    //=========================================================================
    wire signed [23:0] xs_q, ys_q;
    
    wire               map_valid;

    dist_calc u_dist (
        .clk       (clk),
        .rst_n     (rst_n),
        .cx_q      (cx_q),
        .cy_q      (cy_q),
        .p1q       (p1q),
        .p2q       (p2q),
        .lut_we    (lut_we),
        .lut_addr  (lut_addr),
        .lut_wdata (lut_wdata),
        .u         (x_r),
        .v         (y_r),
        .in_valid  (de_r),
        .xs_q      (xs_q),
        .ys_q      (ys_q),
        .out_valid (map_valid)
    );

    // 源坐标（1080p 域），除以 6 得到 320x180 ROM 地址
    wire [11:0] sx = xs_q[23:12];
    wire [11:0] sy = ys_q[23:12];
    // dbg_sx 
    assign dbg_sx = sx;
    // dbg_sy 
    assign dbg_sy = sy;

    // ---- 两级流水 ----
    // 原来 "/6 -> *320 -> +" 全串在一级里（除法和常数乘法都是长链），
    // 148.5MHz 下 ROM 地址路径 WNS = -2.45 ns（DRM 用到 95% 后布局拥塞更明显）。
    // 拆成：级 A 只做 /6，级 B 只做 *320+sx3，然后再进 ROM。
    reg [11:0] sx3_a, sy3_a;
    reg        in_a;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sx3_a <= 12'd0; sy3_a <= 12'd0; in_a <= 1'b0;
        end else begin
            sx3_a <= sx / 12'd6;
            sy3_a <= sy / 12'd6;
            in_a  <= 1'b1;
        end
    end

    reg [17:0] rom_addr_r;
    reg        in_img_r;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rom_addr_r <= 18'd0;
            in_img_r   <= 1'b0;
        end else begin
            rom_addr_r <= sy3_a * 12'd320 + sx3_a;
            in_img_r   <= in_a && (sx3_a < 12'd320) && (sy3_a < 12'd180);
        end
    end

    wire [15:0] rom_data;
    image_rom u_rom (
        .clk  (clk),
        .addr (rom_addr_r),
        .data (rom_data)
    );

    // RGB565 -> RGB888
    wire [23:0] rom_rgb = {rom_data[15:11], 3'b000,
                           rom_data[10:5],  2'b00,
                           rom_data[4:0],   3'b000};
    wire [23:0] pat = in_img_r ? rom_rgb : 24'h000000;

    // 打一拍，缩短到输出引脚的组合路径
    reg [23:0] pat_r;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pat_r <= 24'h000000;
        else        pat_r <= pat;
    end
    // 4) 同步延迟对齐（dist_calc 6 拍 + 图案组合 1 拍）
    //=========================================================================
    reg [DELAY-1:0] de_d, hs_d, vs_d;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_d <= {DELAY{1'b0}};
            hs_d <= {DELAY{1'b1}};
            vs_d <= {DELAY{1'b1}};
        end else begin
            de_d <= {de_d[DELAY-2:0], de_r};
            hs_d <= {hs_d[DELAY-2:0], hs_r};
            vs_d <= {vs_d[DELAY-2:0], vs_r};
        end
    end

    // hs 
    assign hs  = hs_d[DELAY-1];
    // vs 
    assign vs  = vs_d[DELAY-1];
    // de 
    assign de  = de_d[DELAY-1];
    // rgb 
    assign rgb = de_d[DELAY-1] ? pat_r : 24'h000000;

endmodule
