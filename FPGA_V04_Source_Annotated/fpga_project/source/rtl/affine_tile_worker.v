// 单瓦片工作单元，衔接坐标生成、加载、采样和结果提交。
// 两个交错根分块工作单元之一。各自持有一套深度优先细分栈。
// 源数据与变换参数保持锁存，直至整条条带处理完成。

module affine_tile_worker #(parameter INDEX=0,WORKERS=4)(input clk,rst_n,start,
 input[27:0] source_base,input[11:0] stripe_x,stripe_y,input[8:0] stripe_width,input[5:0] stripe_height,
 input[191:0] configuration,output reg done,output fault,output reg[31:0] splits,
 output result_valid,input result_ready,output[15:0] result_rgb,output[11:0] result_x,result_y,
 output[7:0] profile_phase,output[27:0] araddr,output arvalid,input arready,input[255:0] rdata,input rvalid,rlast,output rready,input[3:0] view_mode);
 
 localparam IDLE=0,ISSUE=1,WAIT_JOB=2,FAILED=3;
 reg[3:0] tile_view;reg[1:0] state;reg[27:0] src;reg[191:0] cfg;reg[11:0] sx,sy,tx,ty;
 reg[8:0] sw,root_offset;reg[5:0] sh,tw,th;reg[3:0] sp;reg[35:0] stack[0:9];reg internal_fault;
 
 wire ready,ed,oversize,ef;
 affine_tile_engine engine(profile_phase,clk,rst_n,state==ISSUE,ready,src,tx,ty,tw,th,cfg,ed,oversize,ef,
 result_valid,result_ready,result_rgb,result_x,result_y,araddr,arvalid,arready,rdata,rvalid,rlast,rready,tile_view);
 // fault 
 assign fault=internal_fault||ef;
 
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;tile_view<=1;src<=0;cfg<=0;sx<=0;sy<=0;sw<=0;sh<=0;tx<=0;ty<=0;tw<=0;th<=0;sp<=0;root_offset<=0;done<=0;splits<=0;internal_fault<=0;end
 else begin done<=0;
 if(fault)state<=FAILED;
 else case(state)
 IDLE:if(start)begin
  src<=source_base;cfg<=configuration;tile_view<=view_mode;sx<=stripe_x;sy<=stripe_y;sw<=stripe_width;sh<=stripe_height;
  root_offset<=INDEX*32;sp<=0;splits<=0;
  if(INDEX*32>=stripe_width)done<=1;
  else begin tx<=stripe_x+INDEX*32;ty<=stripe_y;tw<=stripe_width-INDEX*32<32?stripe_width-INDEX*32:32;th<=stripe_height;state<=ISSUE;end
 end
 ISSUE:if(ready)state<=WAIT_JOB;
 WAIT_JOB:if(ed)begin
  if(oversize)begin
   if(sp>=10||(tw==1&&th==1))begin internal_fault<=1;state<=FAILED;end
   else begin
    splits<=splits+1;
    if(tw>=th&&tw>1)begin stack[sp]<={tx+(tw>>1),ty,tw-(tw>>1),th};tw<=tw>>1;end
    else begin stack[sp]<={tx,ty+(th>>1),tw,th-(th>>1)};th<=th>>1;end
    sp<=sp+1;state<=ISSUE;
   end
  end else if(sp!=0)begin {tx,ty,tw,th}<=stack[sp-1];sp<=sp-1;state<=ISSUE;end
  else if(root_offset+32*WORKERS<sw)begin
   root_offset<=root_offset+32*WORKERS;tx<=sx+root_offset+32*WORKERS;ty<=sy;
   tw<=sw-root_offset-32*WORKERS<32?sw-root_offset-32*WORKERS:32;th<=sh;state<=ISSUE;
  end else begin done<=1;state<=IDLE;end
 end
 FAILED:begin end
 endcase end end
endmodule

// 抽象字节地址突发仲裁。当发生阻塞时锁定命令，并持续持有应答所有权直到最后一拍传输完成；各个工作单元可并行扫描与采样。

module affine_worker_read_mux(input clk,rst_n,
 input[27:0] a0,input v0,output ready0,output[255:0] d0,output rv0,rl0,input rr0,
 input[27:0] a1,input v1,output ready1,output[255:0] d1,output rv1,rl1,input rr1,
 output[27:0] address,output valid,input ready,input[255:0] data,input rv,rl,output rr);
 reg busy,owner,turn,locked,lock_owner;
 wire selected=locked?lock_owner:(v0&&v1?turn:!v0);
 // address 
 assign address=selected?a1:a0;assign valid=!busy&&(selected?v1:v0);
 // ready0 
 assign ready0=!busy&&!selected&&ready;assign ready1=!busy&&selected&&ready;
 // d0 
 assign d0=data;assign d1=data;assign rv0=busy&&!owner&&rv;assign rv1=busy&&owner&&rv;
 // rl0 
 assign rl0=rl;assign rl1=rl;assign rr=busy&&(owner?rr1:rr0);
 
 always @(posedge clk)begin
 if(!rst_n)begin busy<=0;owner<=0;turn<=0;locked<=0;lock_owner<=0;end
 else begin
  if(valid)begin if(ready)begin busy<=1;owner<=selected;locked<=0;end else begin locked<=1;lock_owner<=selected;end end
  if(busy&&rv&&rr&&rl)begin busy<=0;turn<=~owner;end
 end end
endmodule

// 双条目寄存器型输出队列：输入就绪信号仅由自身占用情况决定。
// 切断跨工作单元仲裁通往采样器/坐标BRAM使能信号的链路。

module affine_worker_pixel_mux_arb(input clk,rst_n,
 input v0,output r0,input[15:0] p0,input[11:0] x0,y0,
 input v1,output r1,input[15:0] p1,input[11:0] x1,y1,
 output valid,input ready,output[15:0] pixel,output[11:0] x,y);
 reg turn,locked,owner;reg[1:0] count;reg[39:0] q0,q1;
 wire selected=locked?owner:(v0&&v1?turn:!v0);
 wire have=selected?v1:v0;wire space=(count<2);
 
 wire push=have&&space;wire pop=valid&&ready;
 wire[39:0] incoming=selected?{p1,x1,y1}:{p0,x0,y0};
 // valid 
 assign valid=(count!=0);assign {pixel,x,y}=q0;
 // r0 
 assign r0=!selected&&space;assign r1=selected&&space;
 
 always @(posedge clk)begin
  if(!rst_n)begin turn<=0;locked<=0;owner<=0;count<=0;end
  else begin
   if(have)begin
    if(space)begin turn<=~selected;locked<=0;end
    else begin locked<=1;owner<=selected;end
   end
   
   case({push,pop})
    2'b10:begin if(count==0)q0<=incoming;else q1<=incoming;count<=count+1;end
    2'b01:begin q0<=q1;count<=count-1;end
    2'b11:begin if(count==1)q0<=incoming;else begin q0<=q1;q1<=incoming;end end
    default:begin end
   endcase
  end
 end
endmodule

// 独立输入队列，切断跨工作单元 valid → selected → ready 信号链路。

module affine_worker_pixel_input_queue(input clk,rst_n,input in_valid,output in_ready,input[39:0] in_data,output out_valid,input out_ready,output[39:0] out_data);
 reg[1:0] count;reg[39:0] q0,q1;
 // in_ready 
 assign in_ready=count<2;assign out_valid=count!=0;assign out_data=q0;
 
 wire push=in_valid&&in_ready,pop=out_valid&&out_ready;
 
 always @(posedge clk)begin
  if(!rst_n)count<=0;
  else case({push,pop})
   2'b10:begin if(count==0)q0<=in_data;else q1<=in_data;count<=count+1;end
   2'b01:begin q0<=q1;count<=count-1;end
   2'b11:begin if(count==1)q0<=in_data;else begin q0<=q1;q1<=in_data;end end
   default:begin end
  endcase
 end
endmodule

module affine_worker_pixel_mux(input clk,rst_n,
 input v0,output r0,input[15:0] p0,input[11:0] x0,y0,
 input v1,output r1,input[15:0] p1,input[11:0] x1,y1,
 output valid,input ready,output[15:0] pixel,output[11:0] x,y);
 wire av,bv,ar,br;wire[39:0] ad,bd;
 affine_worker_pixel_input_queue qa(clk,rst_n,v0,r0,{p0,x0,y0},av,ar,ad);
 affine_worker_pixel_input_queue qb(clk,rst_n,v1,r1,{p1,x1,y1},bv,br,bd);
 affine_worker_pixel_mux_arb arb(clk,rst_n,av,ar,ad[39:24],ad[23:12],ad[11:0],bv,br,bd[39:24],bd[23:12],bd[11:0],valid,ready,pixel,x,y);
endmodule
