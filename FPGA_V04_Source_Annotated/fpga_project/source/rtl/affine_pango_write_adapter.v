// 将内部像素写请求转换为 DDR 写命令和数据，保持地址与突发长度一致。
// 在AW地址发出前缓存全部16拍数据。Pango原生写通道没有WVALID输入信号。
// done标志代表原生接口已接收最后一拍，不等于DDR数据可见屏障。

module affine_pango_write_adapter #(parameter [3:0] CLIENT_ID=4'hb)(input clk,rst_n,init_done,
 input cmd_valid,output cmd_ready,input[27:0] cmd_address,
 input beat_valid,output beat_ready,input[255:0] beat_data,input[31:0] beat_strobe,input beat_last,
 output reg done,output reg fault,
 output[27:0] native_awaddr,output[3:0] native_awid,native_awlen,output native_awvalid,input native_awready,
 output[255:0] native_wdata,output[31:0] native_wstrb,input native_wready,input[3:0] native_wid,input native_wlast);

 localparam IDLE=0,RECEIVE=1,COMMAND=2,DATA=3,FAILED=4;
 reg[2:0] state;reg[27:0] address;reg[3:0] fill_index,send_index;
 reg[287:0] memory[0:15];
 // cmd_ready 
 assign cmd_ready=(state==IDLE)&&init_done&&!fault;
 // beat_ready 
 assign beat_ready=(state==RECEIVE)&&!fault;
 // native_awaddr 
 assign native_awaddr={2'b0,address[27:2]};assign native_awid=CLIENT_ID;assign native_awlen=15;
 // native_awvalid 
 assign native_awvalid=state==COMMAND&&!fault;
 // {native_wstrb,native_wdata} 
 assign {native_wstrb,native_wdata}=memory[send_index];
 
 wire command_accept=native_awvalid&&native_awready;
 
 wire data_accept=native_wready&&(native_wid==CLIENT_ID)&&((state==DATA)||command_accept);

 always @(posedge clk)begin
  if(!rst_n)begin state<=IDLE;address<=0;fill_index<=0;send_index<=0;done<=0;fault<=0;end
  else begin done<=0;
   if(cmd_valid&&cmd_ready)begin if(cmd_address[4:0]!=0)begin fault<=1;state<=FAILED;end else begin address<=cmd_address;fill_index<=0;state<=RECEIVE;end end
   if(beat_valid&&beat_ready)begin
    memory[fill_index]<={beat_strobe,beat_data};
    if(beat_last!=(fill_index==15))begin fault<=1;state<=FAILED;end
    else if(fill_index==15)begin send_index<=0;state<=COMMAND;end else fill_index<=fill_index+1;
   end
   if(command_accept)state<=DATA;
   if(data_accept)begin
    if(native_wlast!=(send_index==15))begin fault<=1;state<=FAILED;end
    else if(send_index==15)begin done<=1;state<=IDLE;end else send_index<=send_index+1;
   end
  end
 end
endmodule
