// 将处理完成的条带/瓦片像素组织为 DDR 写回数据。

// 两组256×32的RGB565结果条带，每个DDR突发拍承载16路像素。
// 条带内部瓦片输出顺序任意；调度器必须保证每个像素仅写入一次。
// 提交校验要求像素总数严格匹配。就绪条带保持不可变更，直到所有行读出完毕。

module affine_stripe_writer(input clk,rst_n,
 input begin_valid,output begin_ready,input begin_bank,input[27:0] begin_frame_base,
 input[11:0] begin_x,begin_y,input[8:0] begin_width,input[5:0] begin_height,
 input pixel_valid,output pixel_ready,input[11:0] pixel_x,pixel_y,input[15:0] pixel_rgb,
 input commit,output reg fault,output reg stripe_done,output reg done_bank,
 output reg cmd_valid,input cmd_ready,output reg[27:0] cmd_address,
 output beat_valid,input beat_ready,output[255:0] beat_data,output[31:0] beat_strobe,output beat_last,input burst_done);

 localparam IDLE=0,PREFETCH=1,COMMAND=2,SEND=3,WAIT_DONE=4;
 reg[2:0] state;reg[1:0] full;reg filling,fill_bank,write_bank;
 reg[27:0] bases[0:1];reg[11:0] ox[0:1],oy[0:1];reg[8:0] widths[0:1];reg[5:0] heights[0:1];reg[13:0] count;

 reg[4:0] row;reg[4:0] fetch_index;reg[3:0] fetched_index,send_index;reg fetched_valid;
 reg[255:0] staging[0:15];wire[255:0] read_word;
 reg[11:0] fill_x,fill_y;reg[8:0] fill_width;reg[5:0] fill_height;reg[13:0] fill_pixels;
 reg[15:0] write_en,write_rgb;reg[9:0] write_address;
 wire[11:0] px=pixel_x-fill_x,py=pixel_y-fill_y;
 wire pixel_inside=pixel_x>=fill_x&&pixel_y>=fill_y&&px<fill_width&&py<fill_height;
 wire[9:0] wa={fill_bank,py[4:0],px[7:4]},ra={write_bank,row,fetch_index[3:0]};
 // begin_ready 
 assign begin_ready=!filling&&!full[begin_bank]&&!((state!=IDLE)&&write_bank==begin_bank)&&!fault;
 // pixel_ready 
 assign pixel_ready=filling&&!fault;
 // Register address, data and lane enables together before the BRAM port.

 always @(posedge clk)begin
  if(!rst_n)begin write_en<=0;write_rgb<=0;write_address<=0;end
  else begin
   write_en<=pixel_valid&&pixel_ready&&pixel_inside ? (16'b1<<px[3:0]) : 16'b0;
   write_rgb<=pixel_rgb;write_address<=wa;
  end
 end
 genvar lane;generate for(lane=0;lane<16;lane=lane+1)begin:LANE
  reg[15:0] mem[0:1023];reg[15:0] q;
 
  always @(posedge clk)begin
   if(write_en[lane])mem[write_address]<=write_rgb;
   if(state==PREFETCH&&fetch_index<16)q<=mem[ra];
  end
  // read_word[lane*16+:16] 
  assign read_word[lane*16+:16]=q;
 end endgenerate
 reg[31:0] strobe;integer k;

 always @*begin strobe=0;for(k=0;k<16;k=k+1)if(send_index*16+k<widths[write_bank])strobe[k*2+:2]=2'b11;end
 // beat_valid 
 assign beat_valid=(state==SEND);assign beat_data=staging[send_index];assign beat_strobe=strobe;assign beat_last=(send_index==15);
 wire[31:0] current_address=bases[write_bank]+((oy[write_bank]+row)*1920+ox[write_bank])*2;

 always @(posedge clk)begin
  if(!rst_n)begin fill_x<=0;fill_y<=0;fill_width<=0;fill_height<=0;fill_pixels<=0;state<=IDLE;full<=0;filling<=0;fill_bank<=0;write_bank<=0;count<=0;row<=0;fetch_index<=0;fetched_index<=0;send_index<=0;fetched_valid<=0;fault<=0;stripe_done<=0;done_bank<=0;cmd_valid<=0;cmd_address<=0;
   bases[0]<=0;bases[1]<=0;ox[0]<=0;ox[1]<=0;oy[0]<=0;oy[1]<=0;widths[0]<=0;widths[1]<=0;heights[0]<=0;heights[1]<=0;
  end else begin
   stripe_done<=0;
   if(begin_valid&&begin_ready)begin
    if(begin_width==0||begin_width>256||begin_height==0||begin_height>32||begin_x+begin_width>1920||begin_y+begin_height>1080||begin_x[7:0]!=0||begin_frame_base[8:0]!=0)fault<=1;
    else begin fill_x<=begin_x;fill_y<=begin_y;fill_width<=begin_width;fill_height<=begin_height;fill_pixels<=begin_width*begin_height;filling<=1;fill_bank<=begin_bank;bases[begin_bank]<=begin_frame_base;ox[begin_bank]<=begin_x;oy[begin_bank]<=begin_y;widths[begin_bank]<=begin_width;heights[begin_bank]<=begin_height;count<=0;end
   end
   if(pixel_valid&&pixel_ready)begin if(!pixel_inside)fault<=1;else count<=count+1;end
   if(commit)begin
    if(!filling||count!=fill_pixels||pixel_valid)fault<=1;
    else begin full[fill_bank]<=1;filling<=0;end
   end

   case(state)
    IDLE:if(full!=0&&!fault)begin write_bank<=full[0]?0:1;row<=0;fetch_index<=0;fetched_valid<=0;state<=PREFETCH;end
    PREFETCH:begin
     fetched_valid<=fetch_index<16;fetched_index<=fetch_index[3:0];if(fetch_index<16)fetch_index<=fetch_index+1;
     if(fetched_valid)begin staging[fetched_index]<=read_word;if(fetched_index==15)begin cmd_address<=current_address[27:0];cmd_valid<=1;fetched_valid<=0;state<=COMMAND;end end
    end
    COMMAND:if(cmd_valid&&cmd_ready)begin cmd_valid<=0;send_index<=0;state<=SEND;end
    SEND:if(beat_valid&&beat_ready)begin if(send_index==15)state<=WAIT_DONE;else send_index<=send_index+1;end
    WAIT_DONE:if(burst_done)begin
     if(row+1>=heights[write_bank])begin full[write_bank]<=0;stripe_done<=1;done_bank<=write_bank;state<=IDLE;end
     else begin row<=row+1;fetch_index<=0;fetched_valid<=0;state<=PREFETCH;end
    end
   endcase
  end
 end
endmodule
