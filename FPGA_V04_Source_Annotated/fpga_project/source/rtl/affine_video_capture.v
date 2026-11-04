// 接收 HDMI 有效像素并组织输入帧缓存，遵守 DE 与帧边界。
// 同一时刻只允许一路源帧采集授权，数据流经由跨时钟域FIFO传输。
// 出错/溢出帧会被排空并丢弃，不会标记为正常完成帧对外输出。
module affine_video_capture #(parameter WIDTH=1920,HEIGHT=1080,FIFO_AW=8,GAP_CYCLES=4096)(
 input core_clk,core_rst_n,input start,output ready,input[27:0] frame_base,
 output reg done,aborted,output fault,output reg[31:0] dropped_frames,
 input pixel_clk,pixel_rst_n,input de,input[15:0] pixel,
 output[27:0] awaddr,output[3:0] awid,awlen,output awvalid,input awready,
 output[255:0] wdata,output[31:0] wstrb,input wready,input[3:0] wid,input wlast,output reg captured_tag_valid,output reg[15:0] captured_tag);

 localparam PIXELS=WIDTH*HEIGHT,BEATS=PIXELS/16,BURSTS=BEATS/16;

 localparam IDLE=0,COMMAND=1,FEED=2,WAIT_WRITE=3,COMPLETE=4,DRAIN=5;
 reg req;reg[27:0] base;reg[2:0] state;reg[15:0] burst;reg[3:0] beat;reg aborting,finished_seen;reg finish_baseline;reg[3:0] quiet;
 (* ASYNC_REG="TRUE" *)reg req1,req2,finish1,finish2,bad1,bad2,ack1,ack2;
 reg seen_req,active,bad,finish_toggle;reg[23:0] gap,pixels;reg[3:0] lane;reg[255:0] pack;reg[15:0] line_count;reg de_d;
// 源图像第16行、X坐标16处：48个二进制单元，每单元对应8像素；存放魔数、标识ID、反向ID。
 reg[47:0] frame_tag_shift;
 wire tag_cell=active&&de&&(pixels>=WIDTH*16)&&(pixels<WIDTH*17)&&(line_count>=16)&&(line_count<400)&&(line_count[2:0]==4);
 wire boundary=(gap==GAP_CYCLES-1);

 wire fifo_wr_valid=active&&!bad&&de&&(lane==15);
 wire[255:0] fifo_wr_data={pixel,pack[255:16]};
 wire[FIFO_AW:0] fifo_level;

 wire fifo_wr_ready,fifo_valid,fifo_ready;wire[255:0] fifo_data;
 affine_async_fifo #(.WIDTH(256),.AW(FIFO_AW)) fifo(pixel_clk,pixel_rst_n,fifo_wr_valid,fifo_wr_ready,fifo_wr_data,core_clk,core_rst_n,fifo_valid,fifo_ready,fifo_data,fifo_level);

 always @(posedge pixel_clk or negedge pixel_rst_n)begin
  if(!pixel_rst_n)begin req1<=0;req2<=0;seen_req<=0;active<=0;bad<=0;finish_toggle<=0;gap<=0;pixels<=0;lane<=0;pack<=0;line_count<=0;de_d<=0;frame_tag_shift<=0;end
  else begin
   req1<=req;req2<=req1;de_d<=de;if(tag_cell)frame_tag_shift<={frame_tag_shift[46:0],pixel[15]};
   if(de)gap<=0;else if(gap<GAP_CYCLES)gap<=gap+1;
   if(boundary&&active)begin active<=0;bad<=1;finish_toggle<=~finish_toggle;end
   else if(!active&&!de&&(gap>=GAP_CYCLES-1)&&(req2!=seen_req))begin
    seen_req<=req2;active<=1;bad<=0;pixels<=0;lane<=0;line_count<=0;frame_tag_shift<=0;
   end
   if(active&&de)begin
    pixels<=pixels+1;line_count<=line_count+1;
    if(!bad)begin
     pack<= {pixel,pack[255:16]};lane<=lane+1;
     if(lane==15&&!fifo_wr_ready)bad<=1;
    end
    if(pixels==PIXELS-1)begin active<=0;finish_toggle<=~finish_toggle;end
   end
   if(active&&de_d&&!de)begin if(line_count!=WIDTH)bad<=1;line_count<=0;end
  end
 end
// 完成翻转信号与错误标志保持稳定，直到下一次采集授权启动。

 always @(posedge core_clk or negedge core_rst_n)begin
  if(!core_rst_n)begin finish1<=0;finish2<=0;bad1<=0;bad2<=0;ack1<=0;ack2<=0;end
  else begin finish1<=finish_toggle;finish2<=finish1;bad1<=bad;bad2<=bad1;ack1<=seen_req;ack2<=ack1;end
 end

 wire packet_done,write_fault,cmd_ready,beat_ready;
 wire grant_started=ack2==req;

 wire cmd_valid=(state==COMMAND)&&grant_started&&!aborting&&!bad2;
 wire pad=aborting||bad2;

 wire feed_valid=(state==FEED)&&(fifo_valid||pad);

 wire[255:0] feed_data=fifo_valid?fifo_data:256'd0;

 wire[31:0] feed_strb=fifo_valid?32'hffffffff:32'd0;

 assign fifo_ready=((state==FEED)&&beat_ready)||((state==DRAIN));
 wire[27:0] address=base+{burst,9'b0};
 affine_pango_write_adapter #(.CLIENT_ID(4'h0)) writer(core_clk,core_rst_n,core_rst_n,cmd_valid,cmd_ready,address,feed_valid,beat_ready,feed_data,feed_strb,beat==15,packet_done,write_fault,awaddr,awid,awlen,awvalid,awready,wdata,wstrb,wready,wid,wlast);

 assign ready=(state==IDLE)&&!fault;

 assign fault=write_fault;

 always @(posedge core_clk or negedge core_rst_n)begin
  if(!core_rst_n)begin req<=0;base<=0;state<=IDLE;burst<=0;beat<=0;aborting<=0;finished_seen<=0;finish_baseline<=0;quiet<=0;done<=0;aborted<=0;dropped_frames<=0;captured_tag_valid<=0;captured_tag<=0;end
  else begin
   done<=0;aborted<=0;
   if(state!=IDLE)begin if(finish2!=finish_baseline)finished_seen<=1;if(grant_started&&bad2)aborting<=1;end

   case(state)
    IDLE:if(start&&ready)begin base<=frame_base;req<=~req;burst<=0;beat<=0;aborting<=0;finished_seen<=0;finish_baseline<=finish2;quiet<=0;state<=COMMAND;end
    COMMAND:if(grant_started&&(aborting||bad2))state<=DRAIN;else if(cmd_valid&&cmd_ready)begin beat<=0;state<=FEED;end
    FEED:if(feed_valid&&beat_ready)begin if(beat==15)state<=WAIT_WRITE;else beat<=beat+1;end
    WAIT_WRITE:if(packet_done)begin
     if(aborting||bad2)state<=DRAIN;
     else if(burst==BURSTS-1)state<=COMPLETE;
     else begin burst<=burst+1;state<=COMMAND;end
    end
    COMPLETE:if(finished_seen)begin if(aborting||bad2)state<=DRAIN;else begin done<=1;captured_tag_valid<=(frame_tag_shift[47:32]==16'hA55A)&&(frame_tag_shift[15:0]==~frame_tag_shift[31:16]);captured_tag<=frame_tag_shift[31:16];state<=IDLE;end end
    DRAIN:begin
     if(fifo_valid||!finished_seen)quiet<=0;else if(quiet==7)begin aborted<=1;dropped_frames<=dropped_frames+1;state<=IDLE;end else quiet<=quiet+1;
    end
   endcase
  end
 end
endmodule
