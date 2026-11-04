// 调度瓦片工作单元，完成目标画面的分块处理。
// 完整瓦片任务：逆仿射+镜头畸变扫描、精确边界判定、DDR读取、双线性插值。
// 使用DDR抽象字节地址；输出结果流仍需要帧写入器与调度器处理。
module affine_tile_engine(output[7:0] profile_phase,input clk,rst_n,input job_valid,output job_ready,
 input[27:0] job_frame_base,input[11:0] job_x,job_y,input[5:0] job_width,job_height,input[191:0] job_matrix,
 output reg done,output reg tile_too_large,output fault,
 output result_valid,input result_ready,output[15:0] result_rgb,output[11:0] result_x,result_y,
 output[27:0] araddr,output arvalid,input arready,input[255:0] rdata,input rvalid,input rlast,output rready,input[3:0] view_mode);

 localparam IDLE=0,SCAN=1,BOUNDS=2,LOAD=3,SAMPLE=4,FAILED=5,EXTENTS=6;
 reg[2:0] state;reg[27:0] base;reg[11:0] jx,jy,scanx,scany;reg[5:0] jw,jh;
 reg[3:0] tile_view;reg[191:0] matrix;reg[10:0] total,issued,captured,read_index,delivered;
 reg[5:0] scan_col,output_col,output_row;reg[11:0] minx,maxx,miny,maxy;reg has_source;
 reg[15:0] unused;reg job_bank;reg load_sent;

 reg[23:0] coordx[0:1023],coordy[0:1023];reg signed[23:0] cx,cy;reg coord_valid;
// 两级弹性坐标流水线：先BRAM读取，再隔离采样器输入。

 reg signed[23:0] mem_cx,mem_cy;reg mem_valid;

 wire map_valid;wire signed[31:0] sx,sy;
 wire source_ok=sx>=0&&sy>=0&&sx<1920*4096&&sy<1080*4096;
 wire[11:0] ix=sx[23:12],iy=sy[23:12];
 wire[11:0] nx=(ix==1919)?ix:ix+1,ny=(iy==1079)?iy:iy+1;
 reg[12:0] width_needed,height_needed;
 wire[3:0] profile_loader_state;
 // profile_phase 
 assign profile_phase={profile_loader_state,result_valid&&!result_ready,state};
 // job_ready 
 assign job_ready=(state==IDLE)&&!fault;

 wire scan_valid=(state==SCAN)&&(issued<total);
 affine_warp_coordinates mapper(clk,rst_n,scan_valid,scanx,scany,matrix,map_valid,sx,sy,tile_view);

 wire loader_ready,loader_done,loader_fault,lb,bank,lv,p1v,commit;
 wire[11:0] ox,oy;wire[6:0] lw,lh;wire[5:0] lx,ly;wire[15:0] p0,p1;wire[31:0] bursts;
 affine_tile_loader loader(profile_loader_state,clk,rst_n,(state==LOAD)&&!load_sent,loader_ready,job_bank,base,minx,miny,width_needed[6:0],height_needed[6:0],loader_done,loader_fault,
 lb,bank,ox,oy,lw,lh,lv,lx,ly,p0,p1,p1v,commit,araddr,arvalid,arready,rdata,rvalid,rlast,rready,bursts);

 wire coord_ready=!coord_valid||sampler_ready;

 wire mem_ready=!mem_valid||coord_ready;

 wire sampler_ready,sampler_valid,sampler_miss,sampler_fault;wire[1:0] tile_valid;
 affine_tile_sampler sampler(clk,rst_n,lb,bank,ox,oy,lw,lh,lv,lx,ly,p0,p1,p1v,commit,
 (state==SAMPLE)&&coord_valid,sampler_ready,job_bank,{{8{cx[23]}},cx},{{8{cy[23]}},cy},sampler_valid,result_ready,result_rgb,sampler_miss,sampler_fault,tile_valid);
 // fault 
 assign fault=loader_fault||sampler_fault;
 // result_valid 
 assign result_valid=(state==SAMPLE)&&sampler_valid;
 // result_x 
 assign result_x=jx+output_col;assign result_y=jy+output_row;

 always @(posedge clk)begin
  if(!rst_n)begin width_needed<=0;height_needed<=0;state<=IDLE;base<=0;jx<=0;jy<=0;jw<=0;jh<=0;matrix<=0;tile_view<=1;total<=0;issued<=0;captured<=0;read_index<=0;delivered<=0;scan_col<=0;output_col<=0;output_row<=0;minx<=0;maxx<=0;miny<=0;maxy<=0;has_source<=0;job_bank<=0;load_sent<=0;cx<=0;cy<=0;coord_valid<=0;mem_valid<=0;done<=0;tile_too_large<=0;scanx<=0;scany<=0;end
  else begin done<=0;tile_too_large<=0;
   if(fault)state<=FAILED;
   else case(state)
    IDLE:if(job_valid&&job_ready)begin
     if(job_width==0||job_height==0||job_width>32||job_height>32||job_x+job_width>1920||job_y+job_height>1080)begin done<=1;tile_too_large<=1;end
     else begin
      base<=job_frame_base;jx<=job_x;jy<=job_y;jw<=job_width;jh<=job_height;matrix<=job_matrix;tile_view<=view_mode;total<=job_width*job_height;
      scanx<=job_x;scany<=job_y;scan_col<=0;issued<=0;captured<=0;read_index<=0;delivered<=0;output_col<=0;output_row<=0;
      minx<=1919;miny<=1079;maxx<=0;maxy<=0;has_source<=0;coord_valid<=0;mem_valid<=0;load_sent<=0;job_bank<=~job_bank;state<=SCAN;
     end
    end
    SCAN:begin
     if(scan_valid)begin issued<=issued+1;if(scan_col+1>=jw)begin scan_col<=0;scanx<=jx;scany<=scany+1;end else begin scan_col<=scan_col+1;scanx<=scanx+1;end end
     if(map_valid)begin
      coordx[captured[9:0]]<=source_ok?sx[23:0]:-24'sd4096;coordy[captured[9:0]]<=source_ok?sy[23:0]:-24'sd4096;
      if(source_ok)begin has_source<=1;if(ix<minx)minx<=ix;if(iy<miny)miny<=iy;if(nx>maxx)maxx<=nx;if(ny>maxy)maxy<=ny;end
      captured<=captured+1;if(captured+1>=total)state<=EXTENTS;
     end
    end
    EXTENTS:begin width_needed<={1'b0,maxx}-{1'b0,minx}+1;height_needed<={1'b0,maxy}-{1'b0,miny}+1;state<=BOUNDS;end
    BOUNDS:if(!has_source)state<=SAMPLE;else if(width_needed>64||height_needed>64)begin tile_too_large<=1;done<=1;state<=IDLE;end else state<=LOAD;
    LOAD:begin if(!load_sent&&loader_ready)load_sent<=1;if(loader_done)state<=SAMPLE;end
    SAMPLE:begin
     if(coord_ready)begin cx<=mem_cx;cy<=mem_cy;coord_valid<=mem_valid;end
     if(mem_ready)begin
      if(read_index<total)begin mem_cx<=coordx[read_index[9:0]];mem_cy<=coordy[read_index[9:0]];mem_valid<=1;read_index<=read_index+1;end
      else mem_valid<=0;
     end
     if(result_valid&&result_ready)begin
      delivered<=delivered+1;
      if(output_col+1>=jw)begin output_col<=0;output_row<=output_row+1;end else output_col<=output_col+1;
      if(delivered+1>=total)begin state<=IDLE;done<=1;coord_valid<=0;mem_valid<=0;end
     end
    end
    FAILED:begin end
   endcase
  end
 end
endmodule
