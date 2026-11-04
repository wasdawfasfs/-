// 按映射坐标读取瓦片像素，执行最近邻或双线性采样及边界处理。
// 乒乓64×64 RGB565瓦片。每个周期加载两个相邻像素。
// 四个奇偶存储Bank支持每周期读取四个邻域采样点。
// 五级弹性流水线：阻塞时保持全部像素与元数据。
// 源矩形必须包含双线性插值所需+1邻点；瓦片缺失触发异常。
module affine_tile_sampler #(parameter WIDTH=1920,HEIGHT=1080)(
 input clk,rst_n,
 input load_begin,load_bank,input[11:0] load_origin_x,load_origin_y,
 input[6:0] load_width,load_height,
 input load_valid,input[5:0] load_x,load_y,input[15:0] load_p0,load_p1,input load_p1_valid,input load_commit,
 input sample_valid,output sample_ready,input sample_bank,
 input signed[31:0] xs_q12,ys_q12,
 output reg out_valid,input out_ready,output reg[15:0] out_rgb,output reg out_miss,
 output reg fault,output reg[1:0] tile_valid);
 reg[15:0] m00[0:2047],m01[0:2047],m10[0:2047],m11[0:2047];
 reg[11:0] ox[0:1],oy[0:1];reg[6:0] tw[0:1],th[0:1];reg[1:0] writing;
 reg[15:0] q00,q01,q10,q11,p00,p01,p10,p11;
 reg v0,v1,v2,v3,b0,b1,b2,b3,b4,row0,col0,lastx0,lasty0;
 reg im0,im1,im2,im3,miss0,miss1,miss2,miss3;
 reg[7:0] fx0,fy0,fx1,fy1,fy2;
 reg[14:0] hr0,hr1,hg0,hg1,hb0,hb1;
 reg[23:0] vr0,vr1,vg0,vg1,vb0,vb1;

 wire advance=!out_valid||out_ready;
 // sample_ready 
 assign sample_ready=advance;

 wire[31:0] xi=xs_q12>>>12,yi=ys_q12>>>12;

 wire world_ok=xs_q12>=0&&ys_q12>=0&&xs_q12<WIDTH*4096&&ys_q12<HEIGHT*4096;
 wire[31:0] lx=xi-ox[sample_bank],ly=yi-oy[sample_bank];
 wire[31:0] nx=(xi==WIDTH-1)?lx:lx+1,ny=(yi==HEIGHT-1)?ly:ly+1;

 wire tile_ok=tile_valid[sample_bank]&&xi>=ox[sample_bank]&&yi>=oy[sample_bank]&&lx<tw[sample_bank]&&ly<th[sample_bank]&&nx<tw[sample_bank]&&ny<th[sample_bank];
 wire[5:0] ex=lx[0]?lx[5:0]+1:lx[5:0],odx=lx[0]?lx[5:0]:lx[5:0]+1;
 wire[5:0] ey=ly[0]?ly[5:0]+1:ly[5:0],ody=ly[0]?ly[5:0]:ly[5:0]+1;
 wire[10:0] wa={load_bank,load_y[5:1],load_x[5:1]};

 wire load_busy=(v0&&b0==load_bank)||(v1&&b1==load_bank)||(v2&&b2==load_bank)||(v3&&b3==load_bank)||(out_valid&&b4==load_bank)||(sample_valid&&sample_ready&&sample_bank==load_bank);
 wire[15:0] top0=col0?(row0?q11:q01):(row0?q10:q00);
 wire[15:0] top1=lastx0?top0:col0?(row0?q10:q00):(row0?q11:q01);
 wire[15:0] bot0=lasty0?top0:col0?(row0?q01:q11):(row0?q00:q10);
 wire[15:0] bot1=lasty0?top1:lastx0?bot0:col0?(row0?q00:q10):(row0?q01:q11);
 reg[8:0] wx,wy;
 wire[24:0] rr={1'b0,vr0}+{1'b0,vr1}+25'd32768;
 wire[24:0] gg={1'b0,vg0}+{1'b0,vg1}+25'd32768;
 wire[24:0] bb={1'b0,vb0}+{1'b0,vb1}+25'd32768;
// 加载端口与采样端口相互独立；乒乓Bank由调度器管控。

 always @(posedge clk)begin
  if(!rst_n)begin writing<=0;tile_valid<=0;fault<=0;ox[0]<=0;ox[1]<=0;oy[0]<=0;oy[1]<=0;tw[0]<=0;tw[1]<=0;th[0]<=0;th[1]<=0;end
  else begin
   if(load_begin)begin
    if(load_busy||load_width==0||load_height==0||load_width>64||load_height>64||load_origin_x+load_width>WIDTH||load_origin_y+load_height>HEIGHT)fault<=1;
    else begin writing[load_bank]<=1;tile_valid[load_bank]<=0;ox[load_bank]<=load_origin_x;oy[load_bank]<=load_origin_y;tw[load_bank]<=load_width;th[load_bank]<=load_height;end
   end
   if(load_valid)begin
    if(!writing[load_bank]||load_x[0]||load_x>=tw[load_bank]||load_y>=th[load_bank]||(load_p1_valid&&({1'b0,load_x}+1>=tw[load_bank])))fault<=1;
    else if(load_y[0])begin m10[wa]<=load_p0;if(load_p1_valid)m11[wa]<=load_p1;end
    else begin m00[wa]<=load_p0;if(load_p1_valid)m01[wa]<=load_p1;end
   end
   if(load_commit)begin if(!writing[load_bank])fault<=1;else begin tile_valid[load_bank]<=1;writing[load_bank]<=0;end end
   if(sample_valid&&sample_ready&&world_ok&&!tile_ok)fault<=1;
  end
 end

 always @(posedge clk)begin
  if(!rst_n)begin v0<=0;v1<=0;v2<=0;v3<=0;out_valid<=0;out_rgb<=0;out_miss<=0;b0<=0;b1<=0;b2<=0;b3<=0;b4<=0;im0<=0;im1<=0;im2<=0;im3<=0;miss0<=0;miss1<=0;miss2<=0;miss3<=0;end
  else if(advance)begin
   q00<=m00[{sample_bank,ey[5:1],ex[5:1]}];q01<=m01[{sample_bank,ey[5:1],odx[5:1]}];
   q10<=m10[{sample_bank,ody[5:1],ex[5:1]}];q11<=m11[{sample_bank,ody[5:1],odx[5:1]}];
   row0<=ly[0];col0<=lx[0];lastx0<=xi==WIDTH-1;lasty0<=yi==HEIGHT-1;
   fx0<=xs_q12[11:4];fy0<=ys_q12[11:4];im0<=world_ok&&tile_ok;miss0<=world_ok&&!tile_ok;v0<=sample_valid;b0<=sample_bank;
   p00<=top0;p01<=top1;p10<=bot0;p11<=bot1;fx1<=fx0;wx<=9'd256-{1'b0,fx0};fy1<=fy0;im1<=im0;miss1<=miss0;v1<=v0;b1<=b0;
   hr0<=p00[15:11]*wx+p01[15:11]*fx1;hr1<=p10[15:11]*wx+p11[15:11]*fx1;
   hg0<=p00[10:5]*wx+p01[10:5]*fx1;hg1<=p10[10:5]*wx+p11[10:5]*fx1;
   hb0<=p00[4:0]*wx+p01[4:0]*fx1;hb1<=p10[4:0]*wx+p11[4:0]*fx1;
   fy2<=fy1;wy<=9'd256-{1'b0,fy1};im2<=im1;miss2<=miss1;v2<=v1;b2<=b1;
   vr0<=hr0*wy;vr1<=hr1*fy2;vg0<=hg0*wy;vg1<=hg1*fy2;vb0<=hb0*wy;vb1<=hb1*fy2;
   im3<=im2;miss3<=miss2;v3<=v2;b3<=b2;
   out_rgb<=im3?{rr[20:16],gg[21:16],bb[20:16]}:16'd0;out_miss<=miss3;out_valid<=v3;b4<=b3;
  end
 end
endmodule
