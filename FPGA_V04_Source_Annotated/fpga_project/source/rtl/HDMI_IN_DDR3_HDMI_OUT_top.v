// HDMI 收发、DDR 控制及图像处理数据通路的系统集成。
`timescale 1ns / 1ps


module HDMI_IN_DDR3_HDMI_OUT_top#(

	
	parameter MEM_ROW_ADDR_WIDTH   = 15         ,

	
	parameter MEM_COL_ADDR_WIDTH   = 10         ,

	
	parameter MEM_BADDR_WIDTH      = 3          ,

	
	parameter MEM_DQ_WIDTH         =  32        ,

	
	parameter MEM_DQS_WIDTH        =  32/8

)(

    output [319:0] performance_diag,

    output [63:0] video_diag,

    output [31:0] preproc_diag,

    output [95:0] input_diag,

    output dump_uart_tx,dump_uart_active,

    input uart_rxd,

	input                                sys_clk              ,//27Mhz

    input                                clk_p ,

    input                                clk_n ,

    input                                rst_in ,



//DDR

    output                               mem_rst_n                 ,

    output                               mem_ck                    ,

    output                               mem_ck_n                  ,

    output                               mem_cke                   ,

    output                               mem_cs_n                  ,

    output                               mem_ras_n                 ,

    output                               mem_cas_n                 ,

    output                               mem_we_n                  ,

    output                               mem_odt                   ,

    output      [MEM_ROW_ADDR_WIDTH-1:0] mem_a                     ,

    output      [MEM_BADDR_WIDTH-1:0]    mem_ba                    ,

    inout       [MEM_DQ_WIDTH/8-1:0]     mem_dqs                   ,

    inout       [MEM_DQ_WIDTH/8-1:0]     mem_dqs_n                 ,

    inout       [MEM_DQ_WIDTH-1:0]       mem_dq                    ,

    output      [MEM_DQ_WIDTH/8-1:0]     mem_dm                    ,

    output reg                           heart_beat_led            ,

    output                               ddr_init_done             ,

    output                               init_over_rx              ,

//MS72xx       

    output                               rstn_out                  ,

    output                               hd_scl                ,

    inout                                hd_sda                ,

    output                               hdmi_int_led              ,//HDMI_OUT初始化完成



    //HDMI_in

    input             pixclk_in    ,                            

    input             vs_in    /*synthesis PAP_MARK_DEBUG="1"*/, 

    input             hs_in    /*synthesis PAP_MARK_DEBUG="1"*/, 

    input             de_in    /*synthesis PAP_MARK_DEBUG="1"*/,

    input     [7:0]   r_in    /*synthesis PAP_MARK_DEBUG="1"*/, 

    input     [7:0]   g_in    /*synthesis PAP_MARK_DEBUG="1"*/, 

    input     [7:0]   b_in    /*synthesis PAP_MARK_DEBUG="1"*/, 

//HDMI_OUT

    output                               pix_clk   /*synthesis PAP_MARK_DEBUG="1"*/                ,//pixclk                           

    output    reg                           vs_out    /*synthesis PAP_MARK_DEBUG="1"*/                , 

    output    reg                           hs_out    /*synthesis PAP_MARK_DEBUG="1"*/                , 

    output    reg                           de_out    /*synthesis PAP_MARK_DEBUG="1"*/                ,

    output    reg    [7:0]                  r_out     /*synthesis PAP_MARK_DEBUG="1"*/                , 

    output    reg    [7:0]                  g_out     /*synthesis PAP_MARK_DEBUG="1"*/                , 

    output    reg    [7:0]                  b_out     /*synthesis PAP_MARK_DEBUG="1"*/    

);

/////////////////////////////////////////////////////////////////////////////////////

// ENABLE_DDR

    
    parameter CTRL_ADDR_WIDTH = MEM_ROW_ADDR_WIDTH + MEM_BADDR_WIDTH + MEM_COL_ADDR_WIDTH;//28

    
    parameter TH_1S = 27'd33000000;

/////////////////////////////////////////////////////////////////////////////////////

    reg  [15:0]                 rstn_1ms            ;

    wire[15:0]                  o_rgb565            ;



//axi bus   

    wire [CTRL_ADDR_WIDTH-1:0]  axi_awaddr                 ;

    wire                        axi_awuser_ap              ;

    wire [3:0]                  axi_awuser_id              ;

    wire [3:0]                  axi_awlen                  ;

    
    wire                        axi_awready                ;/*synthesis PAP_MARK_DEBUG="1"*/

    
    wire                        axi_awvalid                ;/*synthesis PAP_MARK_DEBUG="1"*/

    wire [MEM_DQ_WIDTH*8-1:0]   axi_wdata                  ;

    wire [MEM_DQ_WIDTH*8/8-1:0] axi_wstrb                  ;

    
    wire                        axi_wready                 ;/*synthesis PAP_MARK_DEBUG="1"*/

    wire [3:0]                  axi_wusero_id              ;

    wire                        axi_wusero_last            ;

    wire [CTRL_ADDR_WIDTH-1:0]  axi_araddr                 ;

    wire                        axi_aruser_ap              ;

    wire [3:0]                  axi_aruser_id              ;

    wire [3:0]                  axi_arlen                  ;

    
    wire                        axi_arready                ;/*synthesis PAP_MARK_DEBUG="1"*/

    
    wire                        axi_arvalid                ;/*synthesis PAP_MARK_DEBUG="1"*/

    wire [MEM_DQ_WIDTH*8-1:0]   axi_rdata                   /* synthesis syn_keep = 1 */;

    
    wire                        axi_rvalid                  /* synthesis syn_keep = 1 */;

    wire [3:0]                  axi_rid                    ;

    wire                        axi_rlast                  ;

    reg  [26:0]                 cnt                        ;

    reg  [15:0]                 cnt_1                      ;

/////////////////////////////////////////////////////////////////////////////////////

//PLL

pll pll_gen_clk (

    .clkin1   (  sys_clk    ),//27MHz

    .clkout0  (  pix_clk    ),//148.5



    .lock (  locked     )

);





cfg_pll cfg_pll_inst (

  .clkout0(cfg_clk),    // output

  .lock(),          // output

  .clkin1(sys_clk)       // input

);









    // Controlled candidate: original vendor HDMI initialization at cfg_clk (10 MHz).

    // Geometry, frame buffers and image processing remain V17.

    wire hdmi_fault = 1'b0; // Vendor driver does not expose an I2C fault indication.

    ms72xx_ctl u_hdmi_cfg (

        .clk(cfg_clk), .rst_n(rstn_out),

        .iic_sda(hd_sda), .iic_scl(hd_scl),

        .init_over_rx(rx_init_done), .init_over(init_over)

    );

    // init_over_rx 
    assign   init_over_rx = rx_init_done;

   // hdmi_int_led 
   assign    hdmi_int_led    =    init_over; 

    

    
    always @(posedge cfg_clk)

    begin

    	if(!locked||!rst_in)

    	    rstn_1ms <= 16'd0;

    	else

    	begin

    		if(rstn_1ms == 16'h2710)

    		    rstn_1ms <= rstn_1ms;

    		else

    		    rstn_1ms <= rstn_1ms + 1'b1;

    	end

    end

    







    reg    rstn_d0;

    reg    rstn_d1;





    // rstn_out 
    assign rstn_out = (rstn_1ms == 16'h2710)&&rst_in;





 reg  rst_reg ;

    
    always @ (posedge sys_clk )

        if (~rst_in)

            rst_reg <= 1'b1 ;

        else

            rst_reg <= 1'b0 ;



wire [15:0] hdmi_data_in;

// Capture the source-synchronous bus once before fanout to arithmetic/probes.

reg raw_de;reg[7:0] raw_r,raw_g,raw_b;


always @(posedge pixclk_in or negedge v10_reset)begin

 if(!v10_reset)begin raw_de<=0;raw_r<=0;raw_g<=0;raw_b<=0;end

 else begin raw_de<=de_in;raw_r<=r_in;raw_g<=g_in;raw_b<=b_in;end

end

wire gamma_mixed;wire gamma_de;wire[7:0] gamma_r,gamma_g,gamma_b,gamma_mean,gamma_frames;


wire[2:0] gamma_curve;wire[1:0] gamma_mode;wire gamma_valid,gamma_ready,gamma_error,gamma_applied,gamma_cfg_valid;

wire[7:0] gamma_command;wire[1:0] gamma_cfg_mode;wire[2:0] gamma_cfg_curve;

gamma_packet_rx gamma_parser(sys_clk,v10_reset,v10_rx_byte,v10_rx_valid,gamma_ready,gamma_valid,gamma_command,gamma_error);

gamma_config_cdc gamma_cdc(sys_clk,v10_reset,gamma_valid,gamma_command,gamma_ready,

 pixclk_in,v10_reset,gamma_cfg_valid,gamma_cfg_mode,gamma_cfg_curve,gamma_applied);

adaptive_gamma gamma_preprocess(pixclk_in,v10_reset,raw_de,raw_r,raw_g,raw_b,

 gamma_cfg_valid,gamma_cfg_mode,gamma_cfg_curve,gamma_applied,gamma_de,gamma_r,gamma_g,gamma_b,

 gamma_mean,gamma_curve,gamma_mode,gamma_frames,gamma_mixed);

// hdmi_data_in 
assign hdmi_data_in={gamma_r[7:3],gamma_g[7:2],gamma_b[7:3]};

input_luma_probe raw_probe(pixclk_in,v10_reset,raw_de,raw_r,raw_g,raw_b,input_diag);

// preproc_diag 
assign preproc_diag={gamma_mean,gamma_mixed,4'd0,gamma_curve,6'd0,gamma_mode,gamma_frames};





wire    vs_reg;

wire    hs_reg;

wire    rd_en ;







//////////////////////////////////////////////////////////////////////////////////////////////////////////

//修改ddr读写模块v1

    wire v10_hs,v10_vs,v10_fault,v10_job_boundary;

    wire[15:0] v10_displayed_seq;

    wire[31:0] v10_drops,v10_underflows,v10_processed,v10_verified;

    
    wire[7:0] v10_rx_byte;wire v10_rx_valid,v10_rx_error,v10_cfg_valid,v10_cfg_error,v10_cfg_busy;

    wire[15:0] v10_sequence;wire[191:0] v10_matrix;

    
    wire[207:0] v10_configuration;wire v10_command_ready,v10_ack,v10_applied;

    wire v10_reset=ddr_init_done&&rst_in;

    affine_uart_rx v10_uart_rx(sys_clk,v10_reset,uart_rxd,v10_rx_byte,v10_rx_valid,v10_rx_error);

    affine_packet_rx v10_packet(sys_clk,v10_reset,v10_rx_byte,v10_rx_valid,v10_command_ready,v10_cfg_valid,v10_sequence,v10_matrix,v10_cfg_error,v10_cfg_busy);

    affine_config_cdc v10_cdc(sys_clk,v10_reset,v10_cfg_valid,{v10_sequence,v10_matrix},v10_command_ready,v10_ack,

        core_clk,v10_reset,v10_job_boundary,v10_configuration,v10_applied);

    reg v10_vs_d;

    
    always @(posedge pix_clk or negedge v10_reset)if(!v10_reset)v10_vs_d<=0;else v10_vs_d<=vs_reg;

    wire[319:0] core_performance;

    performance_snapshot_cdc profile_cdc(core_clk,v10_reset,core_performance,sys_clk,rst_in,performance_diag);

    wire[3:0] view_mode_core;

    view_mode_control view_ctl(sys_clk,v10_reset,v10_rx_byte,v10_rx_valid,core_clk,v10_reset,view_mode_core);

    affine_video_backend v10_backend(.vin_auto(gamma_mode==1),.sys_clk(sys_clk),.control_byte(v10_rx_byte),.control_valid(v10_rx_valid),.dump_tx(dump_uart_tx),.dump_active(dump_uart_active),.view_mode(view_mode_core),.performance_snapshot(core_performance),

        .core_clk(core_clk),.core_rst_n(v10_reset),.configuration(v10_configuration),.job_boundary(v10_job_boundary),.displayed_sequence(v10_displayed_seq),

        .vin_clk(pixclk_in),.vin_de(gamma_de),.vin_pixel(hdmi_data_in),

        .vout_clk(pix_clk),.frame_start(vs_reg&&!v10_vs_d),.hs(hs_reg),.vs(vs_reg),.de(rd_en),

        .out_hs(v10_hs),.out_vs(v10_vs),.out_de(de_o),.out_pixel(o_rgb565),

        .awaddr(axi_awaddr),.awid(axi_awuser_id),.awlen(axi_awlen),.awvalid(axi_awvalid),.awready(axi_awready),

        .wdata(axi_wdata),.wstrb(axi_wstrb),.wready(axi_wready),.wid(axi_wusero_id),.wlast(axi_wusero_last),

        .araddr(axi_araddr),.arid(axi_aruser_id),.arlen(axi_arlen),.arvalid(axi_arvalid),.arready(axi_arready),

        .rdata(axi_rdata),.rid(axi_rid),.rvalid(axi_rvalid),.rlast(axi_rlast),

        .fault(v10_fault),.capture_drops(v10_drops),.display_underflows(v10_underflows),.processed_frames(v10_processed),.verified_bursts(v10_verified));

    // video_diag 
    assign video_diag={v10_processed,v10_displayed_seq,4'd0,v10_fault,3'd0,v10_drops[3:0],v10_underflows[3:0]};



   /*  always@(posedge pix_clk) begin

        r_out<=8'hff;

        g_out<=8'hff;

        b_out<=8'h00; 

        vs_out<=vs_o;

        hs_out<=hs_o;

        de_out<=de_re;

     end*/

//assign pix_clk = pixclk_in;


always  @(posedge pix_clk)begin





        vs_out       <=  v10_vs        ;

        hs_out       <=  v10_hs        ;

        de_out       <=  de_o        ;

        r_out        <=  {o_rgb565[15:11],3'd0}         ;

        g_out        <=  {o_rgb565[10:5],2'd0}         ;

        b_out        <=  {o_rgb565[4:0],3'd0}         ;



end

/////////////////////////////////////////////////////////////////////////////////////

//产生visa时序 

wire                        hs         ;

wire                        vs         ;

wire                        de         ;

//MODE_1080p


parameter V_TOTAL = 12'd1125;  //场扫描周期


parameter V_FP = 12'd4;        //场显示前沿


parameter V_BP = 12'd36;       //场显示后沿


parameter V_SYNC = 12'd5;      //场同步


parameter V_ACT = 12'd1080;    //场有效数据


parameter H_TOTAL = 12'd2200;  //行扫描周期


parameter H_FP = 12'd88;       //行显示前沿


parameter H_BP = 12'd148;      //行显示后沿


parameter H_SYNC = 12'd44;     //行同步


parameter H_ACT = 12'd1920;    //行数据有效


parameter HV_OFFSET = 12'd0;   


parameter   X_WIDTH = 4'd12;


parameter   Y_WIDTH = 4'd12; 

wire [X_WIDTH - 1'b1:0]     act_x      ;

wire [Y_WIDTH - 1'b1:0]     act_y      ;  

sync_vg #(

    .X_BITS               (  X_WIDTH              ), 

    .Y_BITS               (  Y_WIDTH              ),

    .V_TOTAL              (  V_TOTAL              ),//                        

    .V_FP                 (  V_FP                 ),//                        

    .V_BP                 (  V_BP                 ),//                        

    .V_SYNC               (  V_SYNC               ),//                        

    .V_ACT                (  V_ACT                ),//                        

    .H_TOTAL              (  H_TOTAL              ),//                        

    .H_FP                 (  H_FP                 ),//                        

    .H_BP                 (  H_BP                 ),//                        

    .H_SYNC               (  H_SYNC               ),//                        

    .H_ACT                (  H_ACT                ) //                        



) sync_vg                                         

(                                                 

    .clk                  (  pix_clk               ),//input                   clk,                                 

    .rstn                 (  ddr_init_done                 ),//input                   rstn,                            

    .vs_out               (  vs_reg                   ),//output reg              vs_out,                                                                                                                                      

    .hs_out               (  hs_reg                   ),//output reg              hs_out,            

    .de_out               (  rd_en                   ),//output reg              de_out,             

    .x_act                (  act_x                ),//output reg [X_BITS-1:0] x_out,             

    .y_act                (  act_y                ) //output reg [Y_BITS:0]   y_out,             

); 





////////////////////////////////////////////////////////////////////////////////////////////



wire clk_125Mhz ;



GTP_INBUFGDS #(

    .IOSTANDARD("DEFAULT"),

    .TERM_DIFF("ON")

) u_gtp (

    .O(clk_125Mhz), // OUTPUT  

    .I(clk_p), // INPUT  

    .IB(clk_n) // INPUT  

);



//ddr    

        ddr3_test u_ddr3_test_h (

             .ref_clk                   (clk_125Mhz            ),

             .resetn                    (rstn_out           ),// input

             .ddr_init_done             (ddr_init_done      ),// output



             .pll_lock                  (pll_lock           ),// output



             .core_clk                  (core_clk),                                  // output



             .phy_pll_lock              (phy_pll_lock),                          // output

             .gpll_lock                 (gpll_lock),                                // output

             .rst_gpll_lock             (rst_gpll_lock),                        // output

             .ddrphy_cpd_lock           (ddrphy_cpd_lock),                    // output

             //.ddr_init_done             (ddr_init_done),                        // output





             .axi_awaddr                (axi_awaddr         ),// input [27:0]

             .axi_awuser_ap             (1'b0               ),// input

             .axi_awuser_id             (axi_awuser_id      ),// input [3:0]

             .axi_awlen                 (axi_awlen          ),// input [3:0]

             .axi_awready               (axi_awready        ),// output

             .axi_awvalid               (axi_awvalid        ),// input

             .axi_wdata                 (axi_wdata          ),

             .axi_wstrb                 (axi_wstrb          ),// input [31:0]

             .axi_wready                (axi_wready         ),// output

             .axi_wusero_id             (axi_wusero_id      ),// output [3:0]

             .axi_wusero_last           (axi_wusero_last    ),// output

             .axi_araddr                (axi_araddr         ),// input [27:0]

             .axi_aruser_ap             (1'b0               ),// input

             .axi_aruser_id             (axi_aruser_id      ),// input [3:0]

             .axi_arlen                 (axi_arlen          ),// input [3:0]

             .axi_arready               (axi_arready        ),// output

             .axi_arvalid               (axi_arvalid        ),// input

             .axi_rdata                 (axi_rdata          ),// output [255:0]

             .axi_rid                   (axi_rid            ),// output [3:0]

             .axi_rlast                 (axi_rlast          ),// output

             .axi_rvalid                (axi_rvalid         ),// output



             .apb_clk                   (1'b0               ),// input

             .apb_rst_n                 (1'b1               ),// input

             .apb_sel                   (1'b0               ),// input

             .apb_enable                (1'b0               ),// input

             .apb_addr                  (8'b0               ),// input [7:0]

             .apb_write                 (1'b0               ),// input

             .apb_ready                 (                   ), // output

             .apb_wdata                 (16'b0              ),// input [15:0]

             .apb_rdata                 (                   ),// output [15:0]

//             .apb_int                   (                   ),// output



             .mem_rst_n                 (mem_rst_n          ),// output

             .mem_ck                    (mem_ck             ),// output

             .mem_ck_n                  (mem_ck_n           ),// output

             .mem_cke                   (mem_cke            ),// output

             .mem_cs_n                  (mem_cs_n           ),// output

             .mem_ras_n                 (mem_ras_n          ),// output

             .mem_cas_n                 (mem_cas_n          ),// output

             .mem_we_n                  (mem_we_n           ),// output

             .mem_odt                   (mem_odt            ),// output

             .mem_a                     (mem_a              ),// output [14:0]

             .mem_ba                    (mem_ba             ),// output [2:0]

             .mem_dqs                   (mem_dqs            ),// inout [3:0]

             .mem_dqs_n                 (mem_dqs_n          ),// inout [3:0]

             .mem_dq                    (mem_dq             ),// inout [31:0]

             .mem_dm                    (mem_dm             ),// output [3:0]

             //debug



  .dbg_gate_start(1'b0),                      // input

  .dbg_cpd_start(1'b0),                        // input

  .dbg_ddrphy_rst_n(1'b1),                  // input

  .dbg_gpll_scan_rst(1'b0),                // input

  .samp_position_dyn_adj(1'b0),        // input

  .init_samp_position_even(32'd0),    // input [31:0]

  .init_samp_position_odd(32'd0),      // input [31:0]

  .wrcal_position_dyn_adj(1'b0),      // input

  .init_wrcal_position(32'd0),            // input [31:0]

  .force_read_clk_ctrl(1'b0),            // input

  .init_slip_step(16'd0),                      // input [15:0]

  .init_read_clk_ctrl(12'd0),              // input [11:0]

  .debug_calib_ctrl(),                  // output [33:0]

  .dbg_slice_status(),                  // output [67:0]

  .dbg_slice_state(),                    // output [87:0]

  .debug_data(),                              // output [275:0]

  .dbg_dll_upd_state(),                // output [1:0]

  .debug_gpll_dps_phase(),          // output [8:0]

  .dbg_rst_dps_state(),                // output [2:0]

  .dbg_tran_err_rst_cnt(),          // output [5:0]

  .dbg_ddrphy_init_fail(),          // output

  .debug_cpd_offset_adj(1'b0),          // input

  .debug_cpd_offset_dir(1'b0),          // input

  .debug_cpd_offset(10'd0),                  // input [9:0]

  .debug_dps_cnt_dir0(),              // output [9:0]

  .debug_dps_cnt_dir1(),              // output [9:0]

  .ck_dly_en(1'b0),                                // input

  .init_ck_dly_step(8'h0),                  // input [7:0]

  .ck_dly_set_bin(),                      // output [7:0]

  .align_error(),                            // output

  .debug_rst_state(),                    // output [3:0]

  .debug_cpd_state()                     // output [3:0]

       );



//心跳信号

     
     always@(posedge core_clk) begin

        if (!ddr_init_done)

            cnt <= 27'd0;

        else if ( cnt >= TH_1S )

            cnt <= 27'd0;

        else

            cnt <= cnt + 27'd1;

     end



     
     always @(posedge core_clk)

        begin

        if (!ddr_init_done)

            heart_beat_led <= 1'd1;

        else if ( cnt >= TH_1S )

            heart_beat_led <= ~heart_beat_led;

    end

                 

/////////////////////////////////////////////////////////////////////////////////////

endmodule





// Command: A7 7A 01 mode ~mode CRC16-CCITT(body[3]). Invalid frames do nothing.

// Bundled-data toggle handshake: mode is held until acknowledged in core domain.


module view_mode_control(input clk,rst_n,input[7:0] data,input valid,

 input core_clk,core_rst_n,output reg[3:0] mode);

 reg[2:0] state;reg[7:0] candidate;reg[15:0] crc;reg req;reg[3:0] held;

 reg ack;(* ASYNC_REG="TRUE" *)reg ack1,ack2,req1,req2;

 reg[19:0] timeout;

 // 组合函数：实现下列运算；调用方负责位宽、符号及结果时序。
 function[15:0] crcbyte;input[15:0] c;input[7:0] b;integer i;reg[15:0] x;

 begin x=c^{b,8'd0};for(i=0;i<8;i=i+1)x=x[15]?(x<<1)^16'h1021:x<<1;crcbyte=x;end endfunction

 
 always @(posedge clk)begin

  if(!rst_n)begin state<=0;candidate<=0;crc<=0;req<=0;held<=1;ack1<=0;ack2<=0;timeout<=0;end

  else begin

   ack1<=ack;ack2<=ack1;

   if(state!=0)begin timeout<=timeout+1'b1;if(&timeout)state<=0;end

   if(valid)begin timeout<=0;case(state)

    0:if(data==8'ha7)state<=1;

    1:if(data==8'h7a)state<=2;else state<=(data==8'ha7)?1:0;

    2:if(data==1)begin crc<=crcbyte(16'hffff,data);state<=3;end else state<=0;

    3:if(data<=15)begin candidate<=data;crc<=crcbyte(crc,data);state<=4;end else state<=0;

    4:if(data==~candidate)begin crc<=crcbyte(crc,data);state<=5;end else state<=0;

    5:if(data==crc[15:8])state<=6;else state<=0;

    6:begin if(data==crc[7:0]&&req==ack2)begin held<=candidate[3:0];req<=~req;end state<=0;end

    default:state<=0;

   endcase end

  end

 end

 
 always @(posedge core_clk)begin

  if(!core_rst_n)begin req1<=0;req2<=0;ack<=0;mode<=1;end

  else begin req1<=req;req2<=req1;if(req2!=ack)begin mode<=held;ack<=req2;end end

 end

endmodule

