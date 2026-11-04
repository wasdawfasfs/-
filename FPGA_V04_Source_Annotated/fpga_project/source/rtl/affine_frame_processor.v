// 协调完整帧处理任务、模式配置和统计遥测；F136 为本版签名。
// V13 四个瓦片工作单元：在交错根分块之间实现计算、加载、采样的流水线交叠。
// 共享突发读取器、帧局部缓存与单像素写入器，保持DDR原生访问特性。
// 模块接口：各端口方向与位宽以下方声明为准；与上层实例连接共同决定时钟域。
module affine_frame_processor #(parameter FRAME_WIDTH=1920,FRAME_HEIGHT=1080)(
 input clk,rst_n,init_done,input start,output ready,input[27:0] source_base,result_base,input[191:0] matrix,
 output reg done,output fault,output reg[31:0] split_count,
 output[27:0] native_araddr,output[3:0] native_arid,native_arlen,output native_arvalid,input native_arready,
 input[255:0] native_rdata,input[3:0] native_rid,input native_rvalid,native_rlast,
 output[27:0] native_awaddr,output[3:0] native_awid,native_awlen,output native_awvalid,input native_awready,
 output[255:0] native_wdata,output[31:0] native_wstrb,input native_wready,input[3:0] native_wid,input native_wlast,input[15:0] profile_sequence,output reg[319:0] profile_snapshot,input[3:0] view_mode);
 
 localparam IDLE=0,BEGIN_STRIPE=1,START_WORKERS=2,RUN=3,COMMIT_STRIPE=4,NEXT_STRIPE=5,DRAIN=6,FAILED=7;
 reg[3:0] job_view;reg[2:0] state;reg[27:0] src,dst;reg[191:0] cfg;
 reg[11:0] stripe_x,stripe_y;reg[8:0] stripe_width;reg[5:0] stripe_height;reg bank,internal_fault;
 reg[3:0] finished;reg[15:0] stripes_issued,stripes_done;
 wire[7:0] phase0,phase1,phase2,phase3;
 wire d0,d1,d2,d3,f0,f1,f2,f3,v0,v1,v2,v3,r0,r1,r2,r3;
 wire[31:0] split0,split1,split2,split3;
 wire[15:0] rgb0,rgb1,rgb2,rgb3,rgb;wire[11:0] x0,y0,x1,y1,x2,y2,x3,y3,ox,oy;
 
 wire[27:0] a0,a1,a2,a3,araddr;wire av0,av1,av2,av3,ready0,ready1,ready2,ready3,rv0,rv1,rv2,rv3,rl0,rl1,rl2,rl3,rr0,rr1,rr2,rr3,arvalid,arready,rv,rlast,rr;
 wire[255:0] rd0,rd1,rd2,rd3,rdata;
 affine_tile_worker #(.INDEX(0),.WORKERS(4)) worker0(clk,rst_n,state==START_WORKERS,src,stripe_x,stripe_y,stripe_width,stripe_height,cfg,
 d0,f0,split0,v0,r0,rgb0,x0,y0,phase0,a0,av0,ready0,rd0,rv0,rl0,rr0,job_view);
 affine_tile_worker #(.INDEX(1),.WORKERS(4)) worker1(clk,rst_n,state==START_WORKERS,src,stripe_x,stripe_y,stripe_width,stripe_height,cfg,
 d1,f1,split1,v1,r1,rgb1,x1,y1,phase1,a1,av1,ready1,rd1,rv1,rl1,rr1,job_view);
 affine_tile_worker #(.INDEX(2),.WORKERS(4)) worker2(clk,rst_n,state==START_WORKERS,src,stripe_x,stripe_y,stripe_width,stripe_height,cfg,
 d2,f2,split2,v2,r2,rgb2,x2,y2,phase2,a2,av2,ready2,rd2,rv2,rl2,rr2,job_view);
 affine_tile_worker #(.INDEX(3),.WORKERS(4)) worker3(clk,rst_n,state==START_WORKERS,src,stripe_x,stripe_y,stripe_width,stripe_height,cfg,
 d3,f3,split3,v3,r3,rgb3,x3,y3,phase3,a3,av3,ready3,rd3,rv3,rl3,rr3,job_view);
 wire[27:0] ga0,ga1;wire gav0,gav1,gar0,gar1,grv0,grv1,grl0,grl1,grr0,grr1;wire[255:0] grd0,grd1;
 affine_worker_read_mux read_group0(clk,rst_n,a0,av0,ready0,rd0,rv0,rl0,rr0,a1,av1,ready1,rd1,rv1,rl1,rr1,ga0,gav0,gar0,grd0,grv0,grl0,grr0);
 affine_worker_read_mux read_group1(clk,rst_n,a2,av2,ready2,rd2,rv2,rl2,rr2,a3,av3,ready3,rd3,rv3,rl3,rr3,ga1,gav1,gar1,grd1,grv1,grl1,grr1);
 affine_worker_read_mux read_mux(clk,rst_n,ga0,gav0,gar0,grd0,grv0,grl0,grr0,ga1,gav1,gar1,grd1,grv1,grl1,grr1,araddr,arvalid,arready,rdata,rv,rlast,rr);
 
 wire ov,pr,br,wf,sd,db,cv,cr,bv,bready,blast,wd;wire[27:0] ca;wire[255:0] bd;wire[31:0] bs;
 
 wire gv0,gv1,gpr0,gpr1,mux_valid,mux_ready;wire[15:0] gp0,gp1,mux_rgb;wire[11:0] gx0,gy0,gx1,gy1,mux_x,mux_y;
 affine_worker_pixel_mux pixel_group0(clk,rst_n,v0,r0,rgb0,x0,y0,v1,r1,rgb1,x1,y1,gv0,gpr0,gp0,gx0,gy0);
 affine_worker_pixel_mux pixel_group1(clk,rst_n,v2,r2,rgb2,x2,y2,v3,r3,rgb3,x3,y3,gv1,gpr1,gp1,gx1,gy1);
 affine_worker_pixel_mux pixel_mux(clk,rst_n,gv0,gpr0,gp0,gx0,gy0,gv1,gpr1,gp1,gx1,gy1,mux_valid,mux_ready,mux_rgb,mux_x,mux_y);
// 弹性寄存器切断坐标加法/多路选择器通往写入器边界、写使能的信号链路。
 
 reg queued_valid;reg[15:0] queued_rgb;reg[11:0] queued_x,queued_y;
 // mux_ready 
 assign mux_ready=!queued_valid||pr;assign ov=queued_valid;assign rgb=queued_rgb;assign ox=queued_x;assign oy=queued_y;
 
 always @(posedge clk)begin if(!rst_n)begin queued_valid<=0;queued_rgb<=0;queued_x<=0;queued_y<=0;end
 else if(mux_ready)begin queued_valid<=mux_valid;if(mux_valid)begin queued_rgb<=mux_rgb;queued_x<=mux_x;queued_y<=mux_y;end end end
 affine_stripe_writer writer(clk,rst_n,state==BEGIN_STRIPE,br,bank,dst,stripe_x,stripe_y,stripe_width,stripe_height,
 ov,pr,ox,oy,rgb,state==COMMIT_STRIPE,wf,sd,db,cv,cr,ca,bv,bready,bd,bs,blast,wd);
 wire rf,awf;
 affine_cached_read_adapter ra(clk,rst_n,init_done,araddr,arvalid,arready,rdata,rv,rlast,rr,rf,
 native_araddr,native_arid,native_arlen,native_arvalid,native_arready,native_rdata,native_rid,native_rvalid,native_rlast,start&&ready);
 affine_pango_write_adapter wa(clk,rst_n,init_done,cv,cr,ca,bv,bready,bd,bs,blast,wd,awf,
 native_awaddr,native_awid,native_awlen,native_awvalid,native_awready,native_wdata,native_wstrb,native_wready,native_wid,native_wlast);
 // fault 
 assign fault=internal_fault||f0||f1||f2||f3||wf||rf||awf;
 // ready 
 assign ready=state==IDLE&&!fault&&init_done;
 reg[13:0] stripe_remaining;
 
 always @(posedge clk)begin
  if(!rst_n)stripe_remaining<=0;
  else if(state==BEGIN_STRIPE&&br)stripe_remaining<=stripe_width*stripe_height;
  else if(ov&&pr)stripe_remaining<=stripe_remaining-1'b1;
 end
 wire[11:0] after_stripe=stripe_x+256,after_row=stripe_y+32;
 
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;job_view<=1;src<=0;dst<=0;cfg<=0;stripe_x<=0;stripe_y<=0;stripe_width<=0;stripe_height<=0;bank<=0;internal_fault<=0;finished<=0;stripes_issued<=0;stripes_done<=0;done<=0;split_count<=0;end
 else begin
 done<=0;if(sd)stripes_done<=stripes_done+1;
 if(d0||d1||d2||d3)split_count<=split_count+(d0?split0:0)+(d1?split1:0)+(d2?split2:0)+(d3?split3:0);
 if(fault)state<=FAILED;
 else case(state)
 IDLE:if(start&&ready)begin
  if(source_base==result_base||source_base[8:0]!=0||result_base[8:0]!=0)begin internal_fault<=1;state<=FAILED;end
  else begin src<=source_base;dst<=result_base;cfg<=matrix;job_view<=view_mode;stripe_x<=0;stripe_y<=0;
   stripe_width<=FRAME_WIDTH<256?FRAME_WIDTH:256;stripe_height<=FRAME_HEIGHT<32?FRAME_HEIGHT:32;
   bank<=0;finished<=0;stripes_issued<=0;stripes_done<=0;split_count<=0;state<=BEGIN_STRIPE;
  end end
 BEGIN_STRIPE:if(br)state<=START_WORKERS;
 START_WORKERS:begin finished<=0;state<=RUN;end
 RUN:begin
  if(d0)finished[0]<=1;if(d1)finished[1]<=1;if(d2)finished[2]<=1;if(d3)finished[3]<=1;
  if((finished[0]||d0)&&(finished[1]||d1)&&(finished[2]||d2)&&(finished[3]||d3)&&stripe_remaining==0&&!ov&&!mux_valid&&!gv0&&!gv1)state<=COMMIT_STRIPE;
 end
 COMMIT_STRIPE:begin stripes_issued<=stripes_issued+1;state<=NEXT_STRIPE;end
 NEXT_STRIPE:begin
  if(after_stripe<FRAME_WIDTH)begin
   stripe_x<=after_stripe;stripe_width<=FRAME_WIDTH-after_stripe<256?FRAME_WIDTH-after_stripe:256;bank<=~bank;state<=BEGIN_STRIPE;
  end else if(after_row<FRAME_HEIGHT)begin
   stripe_x<=0;stripe_y<=after_row;stripe_width<=FRAME_WIDTH<256?FRAME_WIDTH:256;
   stripe_height<=FRAME_HEIGHT-after_row<32?FRAME_HEIGHT-after_row:32;bank<=~bank;state<=BEGIN_STRIPE;
  end else state<=DRAIN;
 end
 DRAIN:if(stripes_done==stripes_issued)begin done<=1;state<=IDLE;end
 FAILED:begin end
 endcase end end

// 仅用于性能剖析：阶段占用统计汇总四个工作单元；计数器设计上允许交叠。
reg[31:0] prof_pt,prof_ps,prof_pl,prof_pp,prof_pb,prof_pr,prof_pw,prof_pm,profile_jobs;
reg[15:0] profile_seq;
wire[2:0] nscan={2'b0,phase0[7:4]==4'd3}+{2'b0,phase1[7:4]==4'd3}+{2'b0,phase2[7:4]==4'd3}+{2'b0,phase3[7:4]==4'd3};
wire[2:0] nload={2'b0,phase0[7:4]==4'd4}+{2'b0,phase1[7:4]==4'd4}+{2'b0,phase2[7:4]==4'd4}+{2'b0,phase3[7:4]==4'd4};
wire[2:0] nsample={2'b0,phase0[7:4]==4'd5}+{2'b0,phase1[7:4]==4'd5}+{2'b0,phase2[7:4]==4'd5}+{2'b0,phase3[7:4]==4'd5};

wire[2:0] nblocked={2'b0,av0&&!ready0}+{2'b0,av1&&!ready1}+{2'b0,av2&&!ready2}+{2'b0,av3&&!ready3};

always @(posedge clk)begin
 if(!rst_n)begin prof_pt<=0;prof_ps<=0;prof_pl<=0;prof_pp<=0;prof_pb<=0;prof_pr<=0;prof_pw<=0;prof_pm<=0;profile_jobs<=0;profile_seq<=0;profile_snapshot<=0;end
 else if(start&&ready)begin prof_pt<=0;prof_ps<=0;prof_pl<=0;prof_pp<=0;prof_pb<=0;prof_pr<=0;prof_pw<=0;prof_pm<=0;profile_seq<=profile_sequence;end
 else if(state!=IDLE&&state!=FAILED)begin
 prof_pt<=prof_pt+1;prof_ps<=prof_ps+nscan;prof_pl<=prof_pl+nload;prof_pp<=prof_pp+nsample;prof_pb<=prof_pb+nblocked;
 prof_pr<=prof_pr+(native_arvalid&&!native_arready);prof_pw<=prof_pw+(native_awvalid&&!native_awready);prof_pm<=prof_pm+(mux_valid&&!mux_ready);
 if(state==DRAIN&&stripes_done==stripes_issued)begin
 profile_jobs<=profile_jobs+1;
 profile_snapshot<={16'hF136,profile_jobs+32'd1,profile_seq,prof_pt+32'd1,prof_ps+nscan,prof_pl+nload,prof_pp+nsample,prof_pb+nblocked,prof_pr+{31'b0,native_arvalid&&!native_arready},prof_pw+{31'b0,native_awvalid&&!native_awready},{job_view,prof_pm[27:0]}};
 end
 end
end
endmodule

