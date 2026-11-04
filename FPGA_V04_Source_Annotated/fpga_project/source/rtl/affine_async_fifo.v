// 跨时钟域 FIFO；使用 Gray 指针同步，满空判断用于保证数据不被覆盖或重复读取。
// 模块接口：各端口方向与位宽以下方声明为准；与上层实例连接共同决定时钟域。
module affine_async_fifo #(parameter WIDTH=256,AW=8)(
 input wr_clk,wr_rst_n,input wr_valid,output wr_ready,input[WIDTH-1:0] wr_data,
 input rd_clk,rd_rst_n,output reg rd_valid,input rd_ready,output reg[WIDTH-1:0] rd_data,output[AW:0] wr_level);
 reg[WIDTH-1:0] memory[0:(1<<AW)-1];
 reg[AW:0] wb,wg,rb,rg;reg full;
 (* ASYNC_REG="TRUE" *) reg[AW:0] rg1,rg2,wg1,wg2;
 // wr_ready 
 assign wr_ready=!full;
 // 接口/定点中间量：名称中的 Q 位数表示小数位；valid/ready 应随数据一起解释。
 wire push=wr_valid&&wr_ready;
 wire[AW:0] next_wb=wb+push,next_wg=(next_wb>>1)^next_wb;
 reg[AW:0] synced_rb;integer i;

 always @*begin synced_rb[AW]=rg2[AW];for(i=AW-1;i>=0;i=i-1)synced_rb[i]=synced_rb[i+1]^rg2[i];end
 // wr_level 
 assign wr_level=wb-synced_rb;
 wire empty=(rg==wg2);
 wire[AW:0] next_rb=rb+1'b1;

 always @(posedge wr_clk or negedge wr_rst_n)begin
  if(!wr_rst_n)begin wb<=0;wg<=0;full<=0;rg1<=0;rg2<=0;end
  else begin
   rg1<=rg;rg2<=rg1;
   if(push)memory[wb[AW-1:0]]<=wr_data;
   wb<=next_wb;wg<=next_wg;full<=next_wg=={~rg2[AW:AW-1],rg2[AW-2:0]};
  end
 end

 always @(posedge rd_clk or negedge rd_rst_n)begin
  if(!rd_rst_n)begin rb<=0;rg<=0;wg1<=0;wg2<=0;rd_valid<=0;rd_data<=0;end
  else begin
   wg1<=wg;wg2<=wg1;
   if(!rd_valid||rd_ready)begin
    if(!empty)begin rd_data<=memory[rb[AW-1:0]];rd_valid<=1;rb<=next_rb;rg<=(next_rb>>1)^next_rb;end
    else rd_valid<=0;
   end
  end
 end
endmodule
