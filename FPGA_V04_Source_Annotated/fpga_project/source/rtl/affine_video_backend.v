// 连接帧处理结果与视频输出侧缓存/时序。
// 物理视频后端链路：采集 → 受保护DDR → 仿射+镜头校正 → 校验结果DDR → 带纪元标记的显示扫描。
// 全部DDR端口均使用原生地址粒度。

module affine_video_backend(input sys_clk,input[7:0] control_byte,input control_valid,output dump_tx,dump_active,input core_clk,core_rst_n,input[207:0] configuration,
 input[3:0] view_mode,output job_boundary,output[15:0] displayed_sequence,
 input vin_clk,vin_de,input vin_auto,input[15:0] vin_pixel,
 input vout_clk,frame_start,hs,vs,de,
 output out_hs,out_vs,out_de,output[15:0] out_pixel,
 output[27:0] awaddr,output[3:0] awid,awlen,output awvalid,input awready,
 output[255:0] wdata,output[31:0] wstrb,input wready,input[3:0] wid,input wlast,
 output[27:0] araddr,output[3:0] arid,arlen,output arvalid,input arready,
 input[255:0] rdata,input[3:0] rid,input rvalid,rlast,
 output[319:0] performance_snapshot,output fault,output[31:0] capture_drops,display_underflows,processed_frames,verified_bursts);
 reg[1:0] vi_reset,vo_reset;

 always @(posedge vin_clk or negedge core_rst_n)if(!core_rst_n)vi_reset<=0;else vi_reset<={vi_reset[0],1'b1};

 always @(posedge vout_clk or negedge core_rst_n)if(!core_rst_n)vo_reset<=0;else vo_reset<={vo_reset[0],1'b1};
 wire dump_freeze;

 wire cap_mgr_ready,cap_ready,cap_raw_done,cap_raw_abort,cap_fault,process_valid,process_ready,process_raw_done,process_fault;

 wire fence_request,core_boundary,display_valid,manager_fault;wire[1:0] capture_slot,process_source,process_result,display_slot;
 wire[207:0] process_configuration;wire[31:0] srcdrops,resultdrops,shown,splits,verify_retries;
 wire permit_write,verify_drained,verify_fault,verify_done,display_fault,read_fault,write_fault;
 reg cap_pending,abort_pending,process_pending;reg[31:0] processed;
// 自动增强模块在源帧保持不变时仍会迭代调整；不要对其做去重处理。
 reg[1:0] auto_sync;

 always @(posedge core_clk or negedge core_rst_n)if(!core_rst_n)auto_sync<=0;else auto_sync<={auto_sync[0],vin_auto};

 wire captured_tag_valid;wire[15:0] captured_tag;
// UART下发配置后，静态源画面下保持实时预览与Gamma响应特性。
 reg control_epoch;reg[1:0] control_epoch_sync;reg seen_control_epoch;

 always @(posedge sys_clk or negedge core_rst_n)if(!core_rst_n)control_epoch<=0;else if(control_valid)control_epoch<=~control_epoch;

 always @(posedge core_clk or negedge core_rst_n)if(!core_rst_n)begin control_epoch_sync<=0;seen_control_epoch<=0;end
 else begin control_epoch_sync<={control_epoch_sync[0],control_epoch};seen_control_epoch<=control_epoch_sync[1];end
 reg[3:0] last_identity_view;reg[3:0] identity_settle;

 always @(posedge core_clk or negedge core_rst_n)if(!core_rst_n)begin last_identity_view<=0;identity_settle<=15;end
 else begin last_identity_view<=view_mode;if(view_mode!=last_identity_view||control_epoch_sync[1]!=seen_control_epoch)identity_settle<=15;else if(publish_capture&&identity_settle!=0)identity_settle<=identity_settle-1;end
 reg[15:0] result_seq[0:2];

 wire capture_start=cap_mgr_ready&&cap_ready&&!fault;
 wire publish_capture=cap_pending&&verify_drained&&!fault,publish_abort=abort_pending&&verify_drained&&!fault;
 wire publish_process=process_pending&&verify_drained&&!fault;
 affine_frame_manager manager(core_clk,core_rst_n,configuration,capture_start,cap_mgr_ready,capture_slot,publish_capture,
 process_valid,process_ready,process_source,process_result,process_configuration,publish_process,fence_request,
 fence_request&&verify_drained&&!fault,core_boundary&&!dump_freeze,display_valid,display_slot,manager_fault,srcdrops,resultdrops,shown,publish_abort,captured_tag_valid&&(identity_settle==0)&&!auto_sync[1],captured_tag);
 wire[27:0] capture_base={4'b0,capture_slot,22'b0};
 wire[27:0] source_base={4'b0,process_source,22'b0};
 wire[27:0] result_base=(28'd3+process_result)<<22;
 wire[27:0] display_base=(28'd3+display_slot)<<22;

 assign displayed_sequence=display_valid?result_seq[display_slot]:16'd0;

 assign job_boundary=process_valid&&process_ready;

 always @(posedge core_clk or negedge core_rst_n)begin
  if(!core_rst_n)begin cap_pending<=0;abort_pending<=0;process_pending<=0;processed<=0;result_seq[0]<=0;result_seq[1]<=0;result_seq[2]<=0;end
  else begin
   if(cap_raw_done)cap_pending<=1;if(publish_capture)cap_pending<=0;
   if(cap_raw_abort)abort_pending<=1;if(publish_abort)abort_pending<=0;
   if(process_raw_done)begin process_pending<=1;result_seq[process_result]<=process_configuration[207:192];processed<=processed+1;end
   if(publish_process)process_pending<=0;
  end
 end

 assign processed_frames=processed;
 wire[27:0] ca,ta;wire[3:0] ci,cl,ti,tlen;wire cav,car,tav,tar;
 wire[255:0] cd,td;wire[31:0] cs,ts;wire cwr,twr,cwl,twl;
 affine_video_capture capture(core_clk,core_rst_n,capture_start,cap_ready,capture_base,cap_raw_done,cap_raw_abort,cap_fault,capture_drops,
 vin_clk,vi_reset[1],vin_de,vin_pixel,ca,ci,cl,cav,car,cd,cs,cwr,4'h0,cwl,captured_tag_valid,captured_tag);

 wire[27:0] pra;wire[3:0] pri,prlen;wire prav,prar;wire[255:0] prdata;wire prvalid,prlast;

 wire processor_ready;

 assign process_ready=processor_ready&&!fault;
 affine_frame_processor processor(core_clk,core_rst_n,core_rst_n,job_boundary,processor_ready,source_base,result_base,process_configuration[191:0],process_raw_done,process_fault,splits,
 pra,pri,prlen,prav,prar,prdata,4'ha,prvalid,prlast,ta,ti,tlen,tav,tar,td,ts,twr,4'hb,twl,process_configuration[207:192],performance_snapshot,view_mode);

 wire[27:0] dra;wire[3:0] dri,drlen;wire drav,drar;wire[255:0] drdata;wire drvalid,drlast,urgent;
 affine_video_display display(core_clk,core_rst_n,display_valid,display_base,core_boundary,
 dra,dri,drlen,drav,drar,drdata,drvalid,drlast,urgent,display_fault,
 vout_clk,vo_reset[1],frame_start,hs,vs,de,out_hs,out_vs,out_de,out_pixel,display_underflows);
 uart_frame_export exporter(sys_clk,core_clk,core_rst_n,control_byte,control_valid,
 display_valid,core_boundary,display_base,displayed_sequence,
 dra,drav&&drar,drlen,drdata,drvalid,drlast,dump_freeze,dump_tx,dump_active);

 wire[27:0] raw_awaddr;wire[3:0] raw_awid,raw_awlen;wire raw_awvalid,raw_awready;

 assign awaddr=raw_awaddr;assign awid=raw_awid;assign awlen=raw_awlen;

 assign awvalid=raw_awvalid&&permit_write;assign raw_awready=awready&&permit_write;
 affine_ddr_write_arbiter write_arb(core_clk,core_rst_n,ca,cl,cav,car,cd,cs,cwr,cwl,ta,tlen,tav,tar,td,ts,twr,twl,
 raw_awaddr,raw_awid,raw_awlen,raw_awvalid,raw_awready,wdata,wstrb,wready,wid,wlast,write_fault);
 wire[27:0] normal_araddr,verify_araddr;wire[3:0] normal_arid,normal_arlen,verify_arid,verify_arlen;

 wire normal_arvalid,normal_arready,verify_arvalid,verify_arready;
 affine_ddr_read_arbiter read_arb(core_clk,core_rst_n,urgent,dra,drlen,drav,drar,pra,prlen,prav,prar,
 normal_araddr,normal_arid,normal_arlen,normal_arvalid,normal_arready,
 rdata,rid,rvalid&&(rid!=15),rlast,drdata,drvalid,drlast,prdata,prvalid,prlast,read_fault);
 affine_write_verify verify(core_clk,core_rst_n,permit_write,awvalid&&awready,awaddr,awid,wdata,wstrb,wready,wid,wlast,
 verify_araddr,verify_arid,verify_arlen,verify_arvalid,verify_arready,rdata,rvalid&&(rid==15),rlast,verify_done,verify_fault,verified_bursts,verify_retries,verify_drained);
 reg read_locked,read_owner;

 wire choose_verify=read_locked?read_owner:verify_arvalid;

 assign araddr=choose_verify?verify_araddr:normal_araddr;

 assign arid=choose_verify?verify_arid:normal_arid;assign arlen=choose_verify?verify_arlen:normal_arlen;

 assign arvalid=choose_verify?verify_arvalid:normal_arvalid;

 assign verify_arready=choose_verify&&arready;assign normal_arready=!choose_verify&&arready;

 always @(posedge core_clk or negedge core_rst_n)begin
  if(!core_rst_n)begin read_locked<=0;read_owner<=0;end
  else if(arvalid)begin if(arready)read_locked<=0;else begin read_locked<=1;read_owner<=choose_verify;end end
 end

 assign fault=cap_fault||process_fault||manager_fault||display_fault||read_fault||write_fault||verify_fault;
endmodule
