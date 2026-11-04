// 仲裁捕获、瓦片读取和输出写回请求，维持各接口握手。

module affine_ddr_read_arbiter(input clk,rst_n,input display_urgent,
 input[27:0] d_addr,input[3:0] d_len,input d_valid,output d_ready,
 input[27:0] t_addr,input[3:0] t_len,input t_valid,output t_ready,
 output[27:0] araddr,output[3:0] arid,arlen,output arvalid,input arready,
 input[255:0] rdata,input[3:0] rid,input rvalid,rlast,
 output[255:0] d_data,output d_rvalid,d_last,output[255:0] t_data,output t_rvalid,t_last,output reg fault);

 reg locked,owner,turn;wire pick=locked?owner:(d_valid&&display_urgent)?0:(d_valid&&t_valid)?turn:t_valid;
 // araddr 
 assign araddr=pick?t_addr:d_addr;assign arlen=pick?t_len:d_len;assign arid=pick?4'ha:4'h0;
 // arvalid 
 assign arvalid=pick?t_valid:d_valid;assign d_ready=!pick&&arready;assign t_ready=pick&&arready;
 // d_data 
 assign d_data=rdata;assign t_data=rdata;assign d_rvalid=rvalid&&rid==0;assign t_rvalid=rvalid&&rid==10;assign d_last=rlast;assign t_last=rlast;
 
 always @(posedge clk)begin
  if(!rst_n)begin locked<=0;owner<=0;turn<=0;fault<=0;end
  else begin
   if(arvalid)begin if(arready)begin locked<=0;turn<=~pick;end else begin locked<=1;owner<=pick;end end
   if(rvalid&&rid!=0&&rid!=10)fault<=1;
  end
 end
endmodule


module affine_ddr_write_arbiter(input clk,rst_n,
 input[27:0] c_addr,input[3:0] c_len,input c_valid,output c_ready,input[255:0] c_data,input[31:0] c_strb,output c_wready,c_last,
 input[27:0] t_addr,input[3:0] t_len,input t_valid,output t_ready,input[255:0] t_data,input[31:0] t_strb,output t_wready,t_last,
 output[27:0] awaddr,output[3:0] awid,awlen,output awvalid,input awready,
 output[255:0] wdata,output[31:0] wstrb,input wready,input[3:0] wid,input wlast,output reg fault);
 reg active,owner,locked,aw_owner,turn;

 wire pick=locked?aw_owner:(c_valid&&t_valid)?turn:t_valid;
 // awaddr 
 assign awaddr=pick?t_addr:c_addr;assign awlen=pick?t_len:c_len;assign awid=pick?4'hb:4'h0;
 // awvalid 
 assign awvalid=!active&&(pick?t_valid:c_valid);
 // c_ready 
 assign c_ready=!active&&!pick&&awready;assign t_ready=!active&&pick&&awready;

 wire aw_accept=awvalid&&awready;
 wire data_owner=active?owner:pick;
 wire data_phase=active||aw_accept;
 wire correct_id=wid==(data_owner?4'hb:4'h0);
 // wdata 
 assign wdata=data_owner?t_data:c_data;assign wstrb=data_owner?t_strb:c_strb;
 // c_wready 
 assign c_wready=data_phase&&!data_owner&&correct_id&&wready;assign t_wready=data_phase&&data_owner&&correct_id&&wready;
 // c_last 
 assign c_last=wlast;assign t_last=wlast;
 
 always @(posedge clk)begin
  if(!rst_n)begin active<=0;owner<=0;locked<=0;aw_owner<=0;turn<=0;fault<=0;end
  else begin
   if(!active&&awvalid&&!awready)begin locked<=1;aw_owner<=pick;end
   if(aw_accept)begin active<=1;owner<=pick;locked<=0;end
   if(data_phase&&wready)begin
    if(!correct_id)fault<=1;
    else if(wlast)begin active<=0;turn<=~data_owner;end
   end
  end
 end
endmodule
