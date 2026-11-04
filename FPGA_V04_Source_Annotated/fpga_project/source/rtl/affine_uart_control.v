// 解析串口仿射控制帧，校验后通过既有配置邮箱更新，不中途修改正在处理的任务。

// 串口参数115200波特、8N1，板载系统时钟27MHz；位中点采样，停止位校验。
module affine_uart_rx #(parameter CLK_HZ=27000000,BAUD=115200)(
 input clk,rst_n,rx,output reg [7:0] data,output reg valid,output reg framing_error);

 localparam DIV=(CLK_HZ+BAUD/2)/BAUD;
 reg rx_meta=1,rx_sync=1;reg [15:0] count;reg[1:0] state;reg[2:0] bitno;reg[7:0] shift;

 always @(posedge clk)begin rx_meta<=rx;rx_sync<=rx_meta;end

 always @(posedge clk)begin
  if(!rst_n)begin count<=0;state<=0;bitno<=0;data<=0;valid<=0;shift<=0;framing_error<=0;end
  else begin valid<=0;framing_error<=0;

   case(state)
    0:if(!rx_sync)begin count<=DIV/2-1;state<=1;end
    1:if(count!=0)count<=count-1;else if(rx_sync)state<=0;else begin count<=DIV-1;bitno<=0;state<=2;end
    2:if(count!=0)count<=count-1;else begin shift[bitno]<=rx_sync;count<=DIV-1;if(bitno==7)state<=3;else bitno<=bitno+1;end
    3:if(count!=0)count<=count-1;else begin state<=0;if(rx_sync)begin data<=shift;valid<=1;end else framing_error<=1;end
   endcase
  end
 end
endmodule

// 帧头 A5 5A | 版本01 | 大端16位序号 | 六个有符号大端32位系数 | 大端16位CRC。
// CRC16 CCITT-FALSE（多项式0x1021，初始值0xFFFF），校验范围含版本、序号与载荷。
// 错误脉冲不会修改此前已接收生效的数据；数据包超时100毫秒。

module affine_packet_rx #(parameter TIMEOUT_CYCLES=2700000)(
 input clk,rst_n,input[7:0] byte_data,input byte_valid,input ready,
 output reg cfg_valid,output reg[15:0] seq,output reg[191:0] matrix,
 output reg error,output reg busy_reject);

 function [15:0] crc_byte;input[15:0] crc;input[7:0] b;integer j;reg[15:0] c;
 begin c=crc^{b,8'b0};for(j=0;j<8;j=j+1)c=c[15]?(c<<1)^16'h1021:c<<1;crc_byte=c;end endfunction
 reg[1:0] state;reg[5:0] pos;reg[31:0] timer;reg[15:0] crc,seq_work;reg[191:0] payload;reg[7:0] crc_hi;reg version_ok;

 always @(posedge clk)begin
  if(!rst_n)begin state<=0;pos<=0;timer<=0;crc<=16'hffff;seq_work<=0;payload<=0;crc_hi<=0;version_ok<=0;seq<=0;matrix<=0;cfg_valid<=0;error<=0;busy_reject<=0;end
  else begin
   cfg_valid<=0;error<=0;busy_reject<=0;
   if(state!=0)begin
    if(timer==TIMEOUT_CYCLES-1)begin state<=0;timer<=0;error<=1;end else timer<=timer+1;
   end
   if(byte_valid)begin timer<=0;
 
    case(state)
     0:if(byte_data==8'ha5)state<=1;
     1:if(byte_data==8'h5a)begin state<=2;pos<=0;crc<=16'hffff;payload<=0;end else if(byte_data!=8'ha5)state<=0;
     2:begin
      if(pos<=26)crc<=crc_byte(crc,byte_data);
      if(pos==0)version_ok<=byte_data==1;
      if(pos==1)seq_work[15:8]<=byte_data;
      if(pos==2)seq_work[7:0]<=byte_data;
      if(pos>=3&&pos<=26)payload<={payload[183:0],byte_data};
      if(pos==27)crc_hi<=byte_data;
      if(pos==28)begin
       state<=0;
       if(!version_ok||{crc_hi,byte_data}!=crc)error<=1;
       else if(!ready)busy_reject<=1;
       else begin matrix<=payload;seq<=seq_work;cfg_valid<=1;end
      end else pos<=pos+1;
     end
    endcase
   end
  end
 end
endmodule

// 捆绑数据邮箱：源端载荷保持锁存，直到目的端在帧边界应答。
// 系统复位时双方复位信号必须同步置位；不做逐字跨时钟域同步。

module affine_config_cdc(input src_clk,src_rst_n,input send,input[207:0] src_data,
 output ready,output reg acknowledged,
 input dst_clk,dst_rst_n,input frame_start,
 output reg[207:0] active_data,output reg applied);

 localparam[207:0] IDENTITY={16'd0,32'd65536,32'd0,32'd0,32'd0,32'd65536,32'd0};
 reg[207:0] held,shadow;reg req,ack;
 (* ASYNC_REG="TRUE" *) reg ack1,ack2,req1,req2;
 reg waiting,settle;

 assign ready=(req==ack2);

 always @(posedge src_clk)begin
  if(!src_rst_n)begin held<=IDENTITY;req<=0;ack1<=0;ack2<=0;acknowledged<=0;end
  else begin ack1<=ack;ack2<=ack1;acknowledged<=ack1!=ack2;if(send&&ready)begin held<=src_data;req<=~req;end end
 end

 always @(posedge dst_clk)begin
  if(!dst_rst_n)begin req1<=0;req2<=0;ack<=0;waiting<=0;settle<=0;shadow<=IDENTITY;active_data<=IDENTITY;applied<=0;end
  else begin
   req1<=req;req2<=req1;applied<=0;
   if(!waiting&&req2!=ack)begin waiting<=1;settle<=1;end
   else if(waiting&&settle)begin shadow<=held;settle<=0;end
   else if(waiting&&frame_start)begin active_data<=shadow;ack<=req2;waiting<=0;applied<=1;end
  end
 end
endmodule
