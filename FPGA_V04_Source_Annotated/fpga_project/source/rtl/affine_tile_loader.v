// 从 DDR 加载源图瓦片并填入缓存，处理突发请求和回压。
// 将不大于64×64的源矩形加载到仿射瓦片采样器的非激活Bank。
// DDR采用128字节对齐突发（4个256bit拍），字节地址接口。
// 支持任意矩形起始坐标，可跨分块对、跨突发边界。
module affine_tile_loader #(parameter WIDTH=1920,HEIGHT=1080)(
 output[3:0] profile_loader_state,input clk,rst_n,input job_valid,output job_ready,input job_bank,
 input[27:0] job_frame_base,input[11:0] job_x,job_y,input[6:0] job_width,job_height,
 output reg done,output reg fault,
 output reg load_begin,output reg load_bank,output reg[11:0] load_origin_x,load_origin_y,
 output reg[6:0] load_width,load_height,
 output reg load_valid,output reg[5:0] load_x,load_y,output reg[15:0] load_p0,load_p1,output reg load_p1_valid,output reg load_commit,
 output reg[27:0] araddr,output reg arvalid,input arready,input[255:0] rdata,input rvalid,input rlast,output rready,
 output reg[31:0] burst_count);

 localparam IDLE=0,OPEN=1,ROW=2,ISSUE=3,FILL=4,DRAIN=5,COMMIT=6,FINISH=7,FAILED=8;
 reg[3:0] state;reg[27:0] base;reg[5:0] row;reg[6:0] px;
 reg[8:0] offset;reg second,need_second;reg[3:0] beat;reg[255:0] stage[0:7];
 wire[31:0] row_byte=base+((load_origin_y+row)*WIDTH+load_origin_x)*2;
 wire[8:0] source_index=offset+px;
 wire[8:0] source_index1=source_index+1;
 // profile_loader_state 
 assign profile_loader_state=state;
 // job_ready 
 assign job_ready=(state==IDLE)&&!fault;
 // rready 
 assign rready=(state==FILL);

 always @(posedge clk)begin
  if(!rst_n)begin state<=IDLE;done<=0;fault<=0;load_begin<=0;load_bank<=0;load_origin_x<=0;load_origin_y<=0;load_width<=0;load_height<=0;load_valid<=0;load_x<=0;load_y<=0;load_p0<=0;load_p1<=0;load_p1_valid<=0;load_commit<=0;araddr<=0;arvalid<=0;base<=0;row<=0;px<=0;offset<=0;second<=0;need_second<=0;beat<=0;burst_count<=0;end
  else begin
   done<=0;load_begin<=0;load_valid<=0;load_commit<=0;

   case(state)
    IDLE:if(job_valid&&job_ready)begin
     if(job_width==0||job_height==0||job_width>64||job_height>64||job_x+job_width>WIDTH||job_y+job_height>HEIGHT||job_frame_base[8:0]!=0)begin fault<=1;state<=FAILED;end
     else begin base<=job_frame_base;load_bank<=job_bank;load_origin_x<=job_x;load_origin_y<=job_y;load_width<=job_width;load_height<=job_height;row<=0;state<=OPEN;end
    end
    OPEN:begin load_begin<=1;state<=ROW;end
    ROW:begin offset<={3'b0,row_byte[6:1]};need_second<=({3'b0,row_byte[6:1]}+load_width>64);second<=0;araddr<={row_byte[27:7],7'b0};arvalid<=1;state<=ISSUE;end
    ISSUE:if(arvalid&&arready)begin arvalid<=0;beat<=0;burst_count<=burst_count+1;state<=FILL;end
    FILL:if(rvalid)begin
     stage[{second,beat[1:0]}]<=rdata;
     if(rlast!=(beat==3))begin fault<=1;state<=FAILED;end
     else if(rlast)begin
      if(need_second&&!second)begin second<=1;araddr<=araddr+128;arvalid<=1;state<=ISSUE;end
      else begin px<=0;state<=DRAIN;end
     end else beat<=beat+1;
    end
    DRAIN:begin
     load_x<=px[5:0];load_y<=row;load_p0<=stage[source_index[8:4]]>>(source_index[3:0]*16);
     load_p1<=stage[source_index1[8:4]]>>(source_index1[3:0]*16);load_p1_valid<=px+1<load_width;load_valid<=1;
     if(px+2>=load_width)begin if(row+1>=load_height)state<=COMMIT;else begin row<=row+1;state<=ROW;end end
     else px<=px+2;
    end
    COMMIT:begin load_commit<=1;state<=FINISH;end
    FINISH:begin done<=1;state<=IDLE;end
    FAILED:begin arvalid<=0;end
    default:begin fault<=1;state<=FAILED;end
   endcase
  end
 end
endmodule
