// 从输出帧缓存按显示时序取像素；显示刷新不同于新鲜帧率。

// 带纪元/索引标记的有序结果帧扫描，跨CDC FIFO传输。
// 迟到/旧数据字直接丢弃，不偏移到其他像素位置。

module affine_video_display #(parameter WIDTH=1920,HEIGHT=1080,FIFO_AW=8)(
 input core_clk,core_rst_n,input display_valid,input[27:0] display_base,output core_frame_boundary,
 output[27:0] araddr,output[3:0] arid,arlen,output arvalid,input arready,
 input[255:0] rdata,input rvalid,rlast,output urgent,output reg fault,
 input pixel_clk,pixel_rst_n,input frame_start,input hs,vs,de,
 output reg out_hs,out_vs,out_de,output reg[15:0] out_pixel,output reg[31:0] underflow_pixels);

 localparam WORDS=WIDTH*HEIGHT/16,IDLE=0,ISSUE=1,RECEIVE=2;
 reg req;reg[15:0] epoch;reg[23:0] pixel_index;
 (* ASYNC_REG="TRUE" *)reg req1,req2,valid1,valid2;reg[15:0] epoch1,epoch2;

 reg seen_req,pending,context_valid;reg[15:0] context_epoch;reg[27:0] base,address;reg[16:0] word_index;reg[3:0] beat;reg[1:0] state;

 wire[FIFO_AW:0] level;wire fifo_wr_ready,fifo_valid,fifo_ready;wire[288:0] fifo_data;

 wire write_word=(state==RECEIVE)&&rvalid&&!pending&&context_valid;
 wire[16:0] incoming_index=word_index+beat;
 affine_async_fifo #(.WIDTH(289),.AW(FIFO_AW)) fifo(core_clk,core_rst_n,write_word,fifo_wr_ready,{context_epoch,incoming_index,rdata},pixel_clk,pixel_rst_n,fifo_valid,fifo_ready,fifo_data,level);

 assign core_frame_boundary=req2!=seen_req;

 assign araddr={2'b0,address[27:2]};assign arid=0;assign arlen=15;assign arvalid=state==ISSUE;

 assign urgent=context_valid&&(level<64);

 always @(posedge core_clk or negedge core_rst_n)begin
  if(!core_rst_n)begin req1<=0;req2<=0;epoch1<=0;epoch2<=0;seen_req<=0;pending<=0;context_valid<=0;context_epoch<=0;base<=0;address<=0;word_index<=0;beat<=0;state<=IDLE;fault<=0;end
  else begin
   req1<=req;req2<=req1;epoch1<=epoch;epoch2<=epoch1;

   case(state)
    IDLE:if(pending)begin base<=display_base;context_valid<=display_valid;context_epoch<=epoch2;word_index<=0;pending<=0;end
     else if(context_valid&&word_index<WORDS&&level<=((1<<FIFO_AW)-16))begin address<=base+{word_index,5'b0};state<=ISSUE;end
    ISSUE:if(arready)begin beat<=0;state<=RECEIVE;end
    RECEIVE:if(rvalid)begin
     if(write_word&&!fifo_wr_ready)fault<=1;
     if(rlast!=(beat==15))fault<=1;
     if(rlast)begin word_index<=word_index+16;state<=IDLE;end else beat<=beat+1;
    end
   endcase
   if(req2!=seen_req)begin seen_req<=req2;pending<=1;end
  end
 end
 wire[15:0] word_epoch=fifo_data[288:273];wire[16:0] word_number=fifo_data[272:256];
 wire[16:0] desired_word=pixel_index[20:4];

 wire word_matches=fifo_valid&&word_epoch==epoch&&word_number==desired_word;

 assign fifo_ready=fifo_valid&&((word_epoch!=epoch)||(word_number<desired_word)||(de&&word_matches&&pixel_index[3:0]==15));
// 将16选1像素选择器拆分为两级寄存器型4选1选择器。
 reg[63:0] pixel_quad;reg[1:0] pixel_lane;reg pixel_ok,hs_pipe,vs_pipe,de_pipe;

 always @(posedge pixel_clk)begin
  pixel_quad<=fifo_data[255:0]>>{pixel_index[3:2],6'b0};pixel_lane<=pixel_index[1:0];
 end

 always @(posedge pixel_clk or negedge pixel_rst_n)begin
  if(!pixel_rst_n)begin req<=0;epoch<=0;pixel_index<=0;valid1<=0;valid2<=0;out_hs<=0;out_vs<=0;out_de<=0;out_pixel<=0;underflow_pixels<=0;pixel_ok<=0;hs_pipe<=0;vs_pipe<=0;de_pipe<=0;end
  else begin
   valid1<=display_valid;valid2<=valid1;hs_pipe<=hs;vs_pipe<=vs;de_pipe<=de;out_hs<=hs_pipe;out_vs<=vs_pipe;out_de<=de_pipe;pixel_ok<=de&&word_matches;
   out_pixel<=pixel_ok?(pixel_quad>>(pixel_lane*16)):16'd0;
   if(frame_start)begin req<=~req;epoch<=epoch+1;pixel_index<=0;end
   else if(de)begin pixel_index<=pixel_index+1;if(!word_matches&&valid2)underflow_pixels<=underflow_pixels+1;end
  end
 end
endmodule
