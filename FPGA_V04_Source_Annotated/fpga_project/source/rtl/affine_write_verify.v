// 保留的写回校验/诊断逻辑，当前硬件功能的一部分，不仅是可删的外部调试脚本。
// 带边界校验队列。在前一段突发回读期间，可接收后续原生写突发。
// 所有使能字节均会参与校验。
// drained标志才是数据可见屏障；permit_write仅代表队列尚有空闲。
module affine_write_verify #(parameter RETRY_DELAY=128,MAX_RETRIES=3,LGDEPTH=3)(
 input clk,rst_n,output permit_write,input aw_accept,input[27:0] awaddr,input[3:0] awid,
 input[255:0] wdata,input[31:0] wstrb,input wready,input[3:0] wid,input wlast,
 output[27:0] araddr,output[3:0] arid,arlen,output arvalid,input arready,
 input[255:0] rdata,input rvalid,rlast,
 output reg verified,output reg fault,output reg[31:0] verified_bursts,retry_bursts,output drained);

 localparam DEPTH=1<<LGDEPTH,IDLE=0,READ_CMD=1,READ_DATA=2,DELAY=3,FAILED=4;
 reg[2:0] state;reg[LGDEPTH-1:0] wp,rp,write_slot;reg[LGDEPTH:0] count;
 reg[DEPTH-1:0] complete;reg collecting;reg[3:0] owner,wbeat,rbeat,retries;
 reg[27:0] addresses[0:DEPTH-1];reg[287:0] storage[0:DEPTH*16-1];

 reg[287:0] expected_q;reg[255:0] observed_q;reg compare_valid,last_q,mismatch;reg[15:0] delay_count;
 integer j;reg different;
 wire push=aw_accept&&permit_write;
 wire[LGDEPTH-1:0] slot=push?wp:write_slot;wire[3:0] wi=push?4'd0:wbeat;
 wire[3:0] write_owner=push?awid:owner;

 wire pop=(state==READ_DATA)&&compare_valid&&last_q&&!mismatch&&!different&&!fault;
 // permit_write 
 assign permit_write=!fault&&!collecting&&(count<DEPTH);
 // drained 
 assign drained=!fault&&(count==0)&&!collecting&&(state==IDLE)&&!compare_valid;
 // araddr 
 assign araddr=addresses[rp];assign arid=4'hf;assign arlen=15;assign arvalid=state==READ_CMD&&!fault;

 always @*begin different=0;for(j=0;j<32;j=j+1)if(expected_q[256+j]&&observed_q[j*8+:8]!==expected_q[j*8+:8])different=1;end

 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;wp<=0;rp<=0;write_slot<=0;count<=0;complete<=0;collecting<=0;owner<=0;wbeat<=0;rbeat<=0;retries<=0;expected_q<=0;observed_q<=0;compare_valid<=0;last_q<=0;mismatch<=0;delay_count<=0;verified<=0;fault<=0;verified_bursts<=0;retry_bursts<=0;end
 else begin
 verified<=0;compare_valid<=0;
 if(aw_accept&&!permit_write)begin fault<=1;state<=FAILED;end
 if(push)begin addresses[wp]<=awaddr;complete[wp]<=0;write_slot<=wp;wp<=wp+1;owner<=awid;wbeat<=0;collecting<=1;end
 if((collecting||push)&&wready)begin
  if(wid!=write_owner||wlast!=(wi==15))begin fault<=1;state<=FAILED;end
  else begin storage[{slot,wi}]<={wstrb,wdata};
   if(wlast)begin complete[slot]<=1;collecting<=0;wbeat<=0;end else wbeat<=wi+1;
  end
 end

 case({push,pop})2'b10:count<=count+1;2'b01:count<=count-1;default:begin end endcase
 if(state==IDLE&&count!=0&&complete[rp])begin state<=READ_CMD;rbeat<=0;retries<=0;mismatch<=0;end
 if(state==READ_CMD&&arready)begin state<=READ_DATA;rbeat<=0;mismatch<=0;end
 if(state==READ_DATA&&rvalid)begin
  if(rlast!=(rbeat==15))begin fault<=1;state<=FAILED;end
  else begin expected_q<=storage[{rp,rbeat}];observed_q<=rdata;last_q<=rlast;compare_valid<=1;rbeat<=rbeat+1;end
 end
 if(state==READ_DATA&&compare_valid)begin
  if(different)mismatch<=1;
  if(last_q)begin
   if(mismatch||different)begin
    if(retries>=MAX_RETRIES)begin fault<=1;state<=FAILED;end
    else begin retries<=retries+1;retry_bursts<=retry_bursts+1;delay_count<=0;state<=DELAY;end
   end else begin verified<=1;verified_bursts<=verified_bursts+1;complete[rp]<=0;rp<=rp+1;state<=IDLE;end
  end
 end
 if(state==DELAY)begin if(delay_count==RETRY_DELAY-1)state<=READ_CMD;else delay_count<=delay_count+1;end
 end end
endmodule
