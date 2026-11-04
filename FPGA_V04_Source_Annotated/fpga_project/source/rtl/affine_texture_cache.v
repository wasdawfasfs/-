// 保存当前源图瓦片，按坐标提供像素和有效性。
// 阻塞式四路组相联缓存，用于离线/基于帧的RGB565重采样。
// 使用抽象DDR字节地址；适配器需转换为控制器地址单位。
// Cache缺失时拉取16个256bit拍，合计512字节，对应256个RGB565像素。
// 当物理源缓冲区被覆盖时，必须在任务间隙执行缓存无效化。

module affine_texture_cache #(parameter WIDTH=1920,HEIGHT=1080)(
 input clk,rst_n,input invalidate,input[27:0] frame_base,
 input sample_valid,output sample_ready,input signed[31:0] xs_q12,ys_q12,
 output reg result_valid,input result_ready,output reg[15:0] result_rgb,
 output reg[27:0] araddr,output reg arvalid,input arready,
 input[255:0] rdata,input rvalid,input rlast,output rready,
 output reg fault,output reg[31:0] cache_hits,cache_misses);

 localparam IDLE=0,LOOK=1,READ=2,EXTRACT=3,ISSUE=4,FILL=5,NEXT=6,BLEND=7,OUTPUT=8;
 reg[3:0] state;reg[27:0] address[0:3];reg[15:0] pixel[0:3];reg[1:0] which,victim,replace_way,selected_way;
 reg[3:0] beat;reg[7:0] fx,fy;reg[255:0] q;

 reg[3:0] valids;reg[18:0] tags[0:3];reg[255:0] memory[0:63];
 reg found;reg[1:0] hit_way;integer i;
 wire[18:0] tag=address[which][27:9];
 wire[3:0] word_index=address[which][8:5];
 wire[3:0] subpixel=address[which][4:1];

 wire[31:0] xi=xs_q12>>>12,yi=ys_q12>>>12;
 wire[31:0] xnext=(xi<WIDTH-1)?xi+1:xi;
 wire[31:0] ynext=(yi<HEIGHT-1)?yi+1:yi;
 wire[31:0] p00=yi*WIDTH+xi,p01=yi*WIDTH+xnext,p10=ynext*WIDTH+xi,p11=ynext*WIDTH+xnext;

 wire in_bounds=(xs_q12>=0)&&(ys_q12>=0)&&(xs_q12<WIDTH*4096)&&(ys_q12<HEIGHT*4096);
 // sample_ready 
 assign sample_ready=(state==IDLE)&&!invalidate&&!fault;
 // rready 
 assign rready=(state==FILL);

 always @*begin found=0;hit_way=0;for(integer j=0;j<4;j=j+1)if(valids[j]&&tags[j]==tag)begin found=1;hit_way=j;end end

 function[15:0] blend565;input[15:0] a,b,c,d;input[7:0] x,y;
 reg[31:0] r,g,bl;reg[31:0] wx,wy;
 begin wx=256-x;wy=256-y;
 r=((a[15:11]*wx+b[15:11]*x)*wy+(c[15:11]*wx+d[15:11]*x)*y+32768)>>16;
 g=((a[10:5]*wx+b[10:5]*x)*wy+(c[10:5]*wx+d[10:5]*x)*y+32768)>>16;
 bl=((a[4:0]*wx+b[4:0]*x)*wy+(c[4:0]*wx+d[4:0]*x)*y+32768)>>16;
 blend565={r[4:0],g[5:0],bl[4:0]};end endfunction

 always @(posedge clk)begin
  if(!rst_n)begin state<=IDLE;valids<=0;replace_way<=0;selected_way<=0;victim<=0;beat<=0;which<=0;araddr<=0;arvalid<=0;result_valid<=0;result_rgb<=0;fault<=0;cache_hits<=0;cache_misses<=0;fx<=0;fy<=0;q<=0;for(i=0;i<4;i=i+1)begin tags[i]<=0;address[i]<=0;pixel[i]<=0;end end
  else begin
   if(invalidate)begin if(state==IDLE)valids<=0;else fault<=1;end

   case(state)
    IDLE:if(sample_valid&&sample_ready)begin
     if(!in_bounds)begin result_rgb<=0;result_valid<=1;state<=OUTPUT;end
     else if(frame_base[8:0]!=0)begin fault<=1;result_rgb<=0;result_valid<=1;state<=OUTPUT;end
     else begin
      address[0]<=frame_base+(p00<<1);address[1]<=frame_base+(p01<<1);address[2]<=frame_base+(p10<<1);address[3]<=frame_base+(p11<<1);
      fx<=xs_q12[11:4];fy<=ys_q12[11:4];which<=0;state<=LOOK;
     end
    end
    LOOK:if(found)begin selected_way<=hit_way;cache_hits<=cache_hits+1;state<=READ;end
      else begin victim<=replace_way;valids[replace_way]<=0;araddr<={tag,9'b0};arvalid<=1;cache_misses<=cache_misses+1;state<=ISSUE;end
    READ:begin q<=memory[{selected_way,word_index}];state<=EXTRACT;end
    EXTRACT:begin pixel[which]<=q>>(subpixel*16);state<=NEXT;end
    ISSUE:if(arvalid&&arready)begin arvalid<=0;beat<=0;state<=FILL;end
    FILL:if(rvalid)begin
     memory[{victim,beat}]<=rdata;
     if(rlast!=(beat==15))fault<=1;
     if(rlast)begin
      if(beat==15)begin tags[victim]<=tag;valids[victim]<=1;replace_way<=replace_way+1;state<=LOOK;end
      else begin result_rgb<=0;result_valid<=1;state<=OUTPUT;end
     end else if(beat==15)begin result_rgb<=0;result_valid<=1;state<=OUTPUT;end
     else beat<=beat+1;
    end
    NEXT:if(which==3)state<=BLEND;else begin which<=which+1;state<=LOOK;end
    BLEND:begin result_rgb<=blend565(pixel[0],pixel[1],pixel[2],pixel[3],fx,fy);result_valid<=1;state<=OUTPUT;end
    OUTPUT:if(result_valid&&result_ready)begin result_valid<=0;state<=IDLE;end
    default:begin state<=IDLE;fault<=1;end
   endcase
  end
 end
endmodule
