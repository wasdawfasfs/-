// 管理输入、处理和显示的帧缓存所有权，避免读写同一未完成帧。

module affine_frame_manager(input clk,rst_n,input[207:0] current_matrix,
 input capture_start,output capture_ready,output reg[1:0] capture_slot,input capture_done,
 output reg process_valid,input process_ready,output reg[1:0] process_source,process_result,
 output reg[207:0] process_matrix,input process_done,
 output fence_request,input fence_done,
 input display_boundary,output reg display_valid,output reg[1:0] display_slot,
 output reg fault,output reg[31:0] dropped_sources,dropped_results,displayed_frames,input capture_abort,input capture_tag_valid,input[15:0] capture_tag);
 
 localparam IDLE=0,OFFER=1,RUN=2,FENCE=3;
 reg[1:0] state,active_capture,pending_source,pending_result;

 reg capturing,source_pending,result_pending;reg pending_tag_valid,last_tag_valid;reg[15:0] pending_tag,last_tag;
 reg source_free,result_free;reg[1:0] result_choice;integer i;
 
 always @*begin
  source_free=0;capture_slot=0;result_free=0;result_choice=0;
  for(i=2;i>=0;i=i-1)begin
   if(!(capturing&&active_capture==i)&&!(source_pending&&pending_source==i)&&!(state!=IDLE&&process_source==i))begin source_free=1;capture_slot=i;end
   if(!(display_valid&&display_slot==i)&&!(result_pending&&pending_result==i)&&!(state!=IDLE&&process_result==i))begin result_free=1;result_choice=i;end
  end
 end
 // capture_ready 
 assign capture_ready=!capturing&&source_free&&!fault;
 // fence_request 
 assign fence_request=(state==FENCE)&&!fault;

 wire duplicate_pending=pending_tag_valid&&last_tag_valid&&(pending_tag==last_tag)&&(process_matrix==current_matrix);
 wire reserve_process=(state==IDLE)&&source_pending&&result_free&&!fault&&!duplicate_pending;

 always @(posedge clk)begin
  if(!rst_n)begin state<=IDLE;active_capture<=0;pending_source<=0;pending_result<=0;capturing<=0;source_pending<=0;result_pending<=0;process_valid<=0;process_source<=0;process_result<=0;process_matrix<=0;display_valid<=0;display_slot<=0;fault<=0;dropped_sources<=0;dropped_results<=0;displayed_frames<=0;pending_tag_valid<=0;last_tag_valid<=0;pending_tag<=0;last_tag<=0;end
  else begin
   if(state==IDLE&&source_pending&&duplicate_pending)source_pending<=0;

   if(display_boundary&&result_pending)begin display_slot<=pending_result;display_valid<=1;result_pending<=0;displayed_frames<=displayed_frames+1;end
   if(reserve_process)begin
    process_source<=pending_source;process_result<=result_choice;process_matrix<=current_matrix;source_pending<=0;process_valid<=1;state<=OFFER;last_tag_valid<=pending_tag_valid;last_tag<=pending_tag;
   end
   if(state==OFFER&&process_valid&&process_ready)begin process_valid<=0;state<=RUN;end
   if(process_done)begin if(state!=RUN)fault<=1;else state<=FENCE;end
   if(fence_done)begin
    if(state!=FENCE)fault<=1;
    else begin
     if(result_pending&&!display_boundary)dropped_results<=dropped_results+1;
     pending_result<=process_result;result_pending<=1;state<=IDLE;
    end
   end
   if(capture_start&&capture_ready)begin active_capture<=capture_slot;capturing<=1;end
   if(capture_abort)begin if(capturing)begin capturing<=0;dropped_sources<=dropped_sources+1;end else fault<=1;end
   if(capture_done)begin
    if(!capturing)fault<=1;
    else begin
     if(source_pending&&!reserve_process)dropped_sources<=dropped_sources+1;
     pending_source<=active_capture;source_pending<=1;capturing<=0;pending_tag_valid<=capture_tag_valid;pending_tag<=capture_tag;
    end
   end
  end
 end
endmodule
