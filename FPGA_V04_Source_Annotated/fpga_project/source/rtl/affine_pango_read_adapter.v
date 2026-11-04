// 将内部读请求转换为 Pango DDR 原生突发读时序；原生读数据不具有 AXI RREADY。
// 只读适配器，对接工程实际的Pango DDR原生端口。
// 原生地址单位为32位字（旧行增量960字 → 3840字节）。
// 原生应答无RREADY信号：在输出ready/valid前缓存完整突发。
// ID A预留给变换引擎；外部仲裁逻辑必须保留该ID。
// 模块接口：各端口方向与位宽以下方声明为准；与上层实例连接共同决定时钟域。
module affine_pango_read_adapter #(parameter BURST_BEATS=16)(input clk,rst_n,init_done,
 input[27:0] araddr,input arvalid,output arready,
 output[255:0] rdata,output rvalid,output rlast,input rready,output reg fault,
 output[27:0] native_araddr,output[3:0] native_arid,native_arlen,
 output native_arvalid,input native_arready,
 input[255:0] native_rdata,input[3:0] native_rid,input native_rvalid,native_rlast);
 reg pending;reg[4:0] count;reg[3:0] wp,rp,beats;reg[256:0] fifo[0:15];
 wire aligned=(araddr[4:0]==0);
 wire can_issue=init_done&&!pending&&(count==0)&&!fault&&aligned;
 // native_araddr 
 assign native_araddr={2'b0,araddr[27:2]};assign native_arid=4'ha;assign native_arlen=BURST_BEATS-1;
 // native_arvalid 
 assign native_arvalid=arvalid&&can_issue;assign arready=native_arready&&can_issue;
 // rvalid 
 assign rvalid=count!=0;assign {rlast,rdata}=fifo[rp];
 
 wire push=native_rvalid&&(native_rid==4'ha)&&pending;
 
 wire pop=rvalid&&rready;

 always @(posedge clk)begin
  if(!rst_n)begin pending<=0;count<=0;wp<=0;rp<=0;beats<=0;fault<=0;end
  else begin
   if(arvalid&&!aligned)fault<=1;
   if(native_arvalid&&native_arready)begin pending<=1;beats<=0;end
   if(native_rvalid&&native_rid==4'ha&&!pending)fault<=1;
   if(push)begin
    if(count==16&&!pop)fault<=1;
    else begin fifo[wp]<={native_rlast,native_rdata};wp<=wp+1;end
    if(native_rlast!=(beats==BURST_BEATS-1))fault<=1;
    if(native_rlast)pending<=0;else beats<=beats+1;
   end
   if(pop)rp<=rp+1;

   case({push,pop})2'b10:if(count!=16)count<=count+1;2'b01:count<=count-1;default:begin end endcase
  end
 end
endmodule
