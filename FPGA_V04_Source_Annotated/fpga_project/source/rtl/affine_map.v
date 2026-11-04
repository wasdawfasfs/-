// 定点逆仿射坐标流水线；符号扩展、乘积位宽、舍入与 valid 延迟必须一致。
// 通用逆仿射采样器。坐标采用Q12定点，系数采用Q16定点。
// 每个时钟周期接收一路输入；输出延迟三级寄存器。
// 系数在外部寄存，仅在帧边界提交生效。
module affine_map(input clk,input rst_n,input in_valid,
 input signed [23:0] x_q12,y_q12,
 input signed [31:0] a_q16,b_q16,c_q12,d_q16,e_q16,f_q12,
 output reg out_valid,output reg overflow,
 output reg signed [31:0] xs_q12,ys_q12);
 reg signed [55:0] ax,by,dx,ey;
 reg signed [31:0] c1,f1;
 reg signed [56:0] sx,sy;
 reg v1,v2;
 wire signed [56:0] cx={{9{c1[31]}},c1,16'b0};
 wire signed [56:0] fy={{9{f1[31]}},f1,16'b0};

 always @(posedge clk) begin
  if(!rst_n) begin
   v1<=0;v2<=0;out_valid<=0;overflow<=0;
   ax<=0;by<=0;dx<=0;ey<=0;c1<=0;f1<=0;sx<=0;sy<=0;xs_q12<=0;ys_q12<=0;
  end else begin
   ax<=a_q16*x_q12;by<=b_q16*y_q12;dx<=d_q16*x_q12;ey<=e_q16*y_q12;
   c1<=c_q12;f1<=f_q12;v1<=in_valid;
   sx<=$signed({ax[55],ax})+$signed({by[55],by})+cx;
   sy<=$signed({dx[55],dx})+$signed({ey[55],ey})+fy;v2<=v1;
   xs_q12<=sx>>>16;ys_q12<=sy>>>16;out_valid<=v2;
   overflow<=(sx[56:47]!={10{sx[47]}})||(sy[56:47]!={10{sy[47]}});
  end
 end
endmodule

// 同时钟域系数邮箱。跨时钟域传输必须使用握手机制，
// 禁止对每个系数单独做同步；默认值为恒等变换。

module affine_frame_config(input clk,input rst_n,input frame_start,
 input cfg_valid,input [191:0] cfg_data,
 output reg [191:0] active_data,output reg pending,output reg applied);

 localparam [191:0] IDENTITY={32'd65536,32'd0,32'd0,32'd0,32'd65536,32'd0};
 reg [191:0] shadow;

 always @(posedge clk) begin
  if(!rst_n)begin active_data<=IDENTITY;shadow<=IDENTITY;pending<=0;applied<=0;end
  else begin
   applied<=0;
   if(frame_start&&pending)begin active_data<=shadow;pending<=0;applied<=1;end
   if(cfg_valid)begin shadow<=cfg_data;pending<=1;end
  end
 end
endmodule
