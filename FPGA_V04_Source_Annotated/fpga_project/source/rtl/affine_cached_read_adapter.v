// 缓存读适配，复用连续或局部访问，处理数据返回有效信号。
// 帧内直映式固定源缓存。不缓存显示读操作、回写校验以及可变帧。
// 每次新任务空闲时执行刷新。
// 512个对齐的128字节缓存行；总容量同样为64KiB；原生适配器保留无RREADY突发保护机制。
module affine_cached_read_adapter(input clk,rst_n,init_done,
 input[27:0] araddr,input arvalid,output arready,
 output[255:0] rdata,output rvalid,output rlast,input rready,output fault,
 output[27:0] native_araddr,output[3:0] native_arid,native_arlen,
 output native_arvalid,input native_arready,
 input[255:0] native_rdata,input[3:0] native_rid,input native_rvalid,native_rlast,
 input flush);
 // 常量定义：用于以下状态编码、位宽或时序参数
 localparam IDLE=0,MISS_CMD=1,MISS_DATA=2,HIT=3,LOOKUP=4,DECIDE=5;
 reg[2:0] state;reg[27:0] address;reg[8:0] index;reg[3:0] beat;reg[4:0] next_read;
 // 
 reg[511:0] valid;reg[11:0] tags[0:511];reg[255:0] memory[0:2047];
 // 
 reg[255:0] hit_data;reg hit_valid,hit_last,local_fault;
 // 
 wire ma_ready,mv,ml,mf;wire[255:0] md;
 // 寄存器化请求，将共享仲裁逻辑与512行标签/有效位查找通路隔离
 // 
 reg[11:0] lookup_tag;reg lookup_valid;
 // 
 wire cache_hit=lookup_valid&&lookup_tag==address[27:16];
 // arready 
 assign arready=(state==IDLE)&&init_done&&!fault&&!flush;
 // rvalid 
 assign rvalid=state==HIT?hit_valid:state==MISS_DATA?mv:1'b0;
 // rdata 
 assign rdata=state==HIT?hit_data:md;assign rlast=state==HIT?hit_last:ml;
 // fault 
 assign fault=local_fault||mf;
 affine_pango_read_adapter #(.BURST_BEATS(4)) native_reader(clk,rst_n,init_done,address,state==MISS_CMD,ma_ready,md,mv,ml,
 (state==MISS_DATA)&&rready,mf,native_araddr,native_arid,native_arlen,native_arvalid,native_arready,native_rdata,native_rid,native_rvalid,native_rlast);
 
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;lookup_tag<=0;lookup_valid<=0;address<=0;index<=0;beat<=0;next_read<=0;valid<=0;hit_valid<=0;hit_last<=0;hit_data<=0;local_fault<=0;end
 else begin
 if(flush)begin valid<=0;if(state!=IDLE)local_fault<=1;end
 
 case(state)
 IDLE:if(arvalid&&arready)begin
  if(araddr[6:0]!=0)local_fault<=1;
  else begin address<=araddr;index<=araddr[15:7];beat<=0;next_read<=0;hit_valid<=0;
   state<=LOOKUP;
  end end
 LOOKUP:begin lookup_tag<=tags[index];lookup_valid<=valid[index];state<=DECIDE;end
 DECIDE:begin
// 源数据不可变更，填充完成前不再接收新请求。
// Cache缺失期间保留原有有效位/标签对；原子提交替换项。
  if(cache_hit)state<=HIT;else state<=MISS_CMD;
 end
 MISS_CMD:if(ma_ready)state<=MISS_DATA;
 MISS_DATA:if(mv&&rready)begin
  memory[{index,beat[1:0]}]<=md;
  if(ml!=(beat==3))local_fault<=1;
  if(ml)begin tags[index]<=address[27:16];valid[index]<=1;state<=IDLE;end else beat<=beat+1;
 end
 HIT:begin
  if(!hit_valid||rready)begin
   if(next_read<4)begin hit_data<=memory[{index,next_read[1:0]}];hit_last<=next_read==3;hit_valid<=1;next_read<=next_read+1;end
   else begin hit_valid<=0;state<=IDLE;end
  end
 end
 default:local_fault<=1;
 endcase
 end end
endmodule

