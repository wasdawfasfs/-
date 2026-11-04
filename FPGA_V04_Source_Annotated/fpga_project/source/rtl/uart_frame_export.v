// 冻结输出并串口导出 RGB565 整帧；包含帧头、有效载荷与校验。
// 冻结显示时隙并导出其DDR内RGB565图像，不新增DDR主控制器。
// 监听原有显示读通路；每次接收突发传输前预留512字节缓冲。
// 指令帧格式：A8 8A | 版本01，指令01(冻结/导出)或02(恢复)，小端16位序号 | 大端CRC16。
// 应答帧：FPGA24\r\n，版本号，格式标识，请求序号(LE16)，显示帧序号(LE16)，宽度(LE16)，高度(LE16)，数据长度(LE32)，
// RGB565小端像素数据，包头+载荷的小端CRC32（兼容zlib）。
// 模块接口：各端口方向与位宽以下方声明为准；与上层实例连接共同决定时钟域。
module uart_frame_export #(parameter WIDTH=1920,HEIGHT=1080,CLK_HZ=27000000,BAUD=115200)(
 input sys_clk,core_clk,rst_n,input[7:0] byte_data,input byte_valid,
 input display_valid,core_boundary,input[27:0] display_base,input[15:0] display_sequence,
 input[27:0] read_addr,input read_command,input[3:0] read_len,
 input[255:0] read_data,input read_valid,read_last,
 output freeze_display,output reg tx=1,output reg tx_active=0);
 
 localparam BYTES=WIDTH*HEIGHT*2,BURSTS=BYTES/512,DIV=(CLK_HZ+BAUD/2)/BAUD;
 
 function[15:0] crc16;input[15:0] c0;input[7:0] b;integer i;reg[15:0] c;
 begin c=c0^{b,8'b0};for(i=0;i<8;i=i+1)c=c[15]?(c<<1)^16'h1021:c<<1;crc16=c;end endfunction
 
 function[31:0] crc32;input[31:0] c0;input[7:0] b;integer i;reg[31:0] c;
 begin c=c0^{24'd0,b};for(i=0;i<8;i=i+1)c=c[0]?(c>>1)^32'hedb88320:c>>1;crc32=c;end endfunction
 reg[1:0] parse_state;reg[2:0] pos;reg[7:0] version,command,crc_hi;reg[15:0] seq_work,check;
 reg[21:0] parse_timer;reg freeze_sys;reg[15:0] request_seq;
 reg[15:0] baud_count;reg[3:0] bit_count;reg[9:0] tx_shift;reg tx_busy,last_byte;
 (* ASYNC_REG="TRUE" *)reg freeze1,freeze2;reg[15:0] seq1,seq2;
 
 always @(posedge core_clk or negedge rst_n)begin
  if(!rst_n)begin freeze1<=0;freeze2<=0;seq1<=0;seq2<=0;end
  else begin freeze1<=freeze_sys;freeze2<=freeze1;seq1<=request_seq;seq2<=seq1;end
 end
 // freeze_display 
 assign freeze_display=freeze2;
// 协同置位；冻结指令被接收后，本地同步释放。
 wire fifo_reset=rst_n&&freeze_sys;
 reg[1:0] cw_reset,sr_reset;
 
 always @(posedge core_clk or negedge fifo_reset)if(!fifo_reset)cw_reset<=0;else cw_reset<={cw_reset[0],1'b1};
 
 always @(posedge sys_clk or negedge fifo_reset)if(!fifo_reset)sr_reset<=0;else sr_reset<={sr_reset[0],1'b1};
 
 wire fifo_wr_ready,fifo_valid,fifo_ready;wire[8:0] fifo_data;wire[10:0] level;
 
 wire fifo_wr_valid;wire[8:0] fifo_wr_data;
 affine_async_fifo #(.WIDTH(9),.AW(10)) stream(core_clk,cw_reset[1],fifo_wr_valid,fifo_wr_ready,fifo_wr_data,
 sys_clk,sr_reset[1],fifo_valid,fifo_ready,fifo_data,level);
 // fifo_ready 
 assign fifo_ready=tx_active&&!tx_busy;
 wire finish_tx=tx_busy&&(baud_count==0)&&(bit_count==9)&&last_byte;
 
 wire cmd_valid=byte_valid&&parse_state==2&&pos==5&&version==1&&{crc_hi,byte_data}==check;
 
 always @(posedge sys_clk or negedge rst_n)begin
  if(!rst_n)begin parse_state<=0;pos<=0;version<=0;command<=0;crc_hi<=0;seq_work<=0;check<=16'hffff;
   parse_timer<=0;freeze_sys<=0;request_seq<=0;tx<=1;tx_active<=0;tx_busy<=0;baud_count<=0;bit_count<=0;tx_shift<=10'h3ff;last_byte<=0;end
  else begin
   if(parse_state!=0)begin if(parse_timer==2700000)begin parse_state<=0;parse_timer<=0;end else parse_timer<=parse_timer+1;end
   if(byte_valid)begin parse_timer<=0;
    
    case(parse_state)
     0:if(byte_data==8'ha8)parse_state<=1;
     1:if(byte_data==8'h8a)begin parse_state<=2;pos<=0;check<=16'hffff;end else if(byte_data!=8'ha8)parse_state<=0;
     2:begin
      if(pos<4)check<=crc16(check,byte_data);
      
      case(pos)0:version<=byte_data;1:command<=byte_data;2:seq_work[7:0]<=byte_data;3:seq_work[15:8]<=byte_data;4:crc_hi<=byte_data;endcase
      if(pos==5)parse_state<=0;else pos<=pos+1;
     end
    endcase
   end
   if(!tx_busy&&tx_active&&fifo_valid)begin tx_shift<={1'b1,fifo_data[7:0],1'b0};tx<=0;baud_count<=DIV-1;bit_count<=0;tx_busy<=1;last_byte<=fifo_data[8];end
   else if(tx_busy)begin
    if(baud_count!=0)baud_count<=baud_count-1;
    else begin baud_count<=DIV-1;if(bit_count==9)begin tx_busy<=0;tx<=1;end
     else begin bit_count<=bit_count+1;tx_shift<={1'b1,tx_shift[9:1]};tx<=tx_shift[1];end end
   end
   if(finish_tx)tx_active<=0;
   if(cmd_valid&&command==1&&!freeze_sys)begin freeze_sys<=1;request_seq<=seq_work;tx_active<=1;end
   if(cmd_valid&&command==2)begin freeze_sys<=0;tx_active<=0;tx_busy<=0;tx<=1;end
  end
 end
 
 localparam IDLE=0,HEADER=1,WAIT_COMMAND=2,RECEIVE=3,LOAD_WORD=4,SEND_WORD=5,TRAILER=6,HELD=7;
 reg[2:0] state;reg[27:0] base;reg[15:0] frame_seq,export_seq;
 reg[4:0] header_index;reg[15:0] burst;reg[3:0] beat,word_index;reg[4:0] byte_index;reg[1:0] trailer_index;
 reg[255:0] buffer[0:15],word_shift;reg[31:0] crc;
 wire[31:0] final_crc=crc^32'hffffffff;
 
 function[7:0] header_byte;input[4:0] index;
 begin case(index)
  0:header_byte="F";1:header_byte="P";2:header_byte="G";3:header_byte="A";
  4:header_byte="2";5:header_byte="4";6:header_byte=13;7:header_byte=10;
  8:header_byte=1;9:header_byte=1;
  10:header_byte=export_seq[7:0];11:header_byte=export_seq[15:8];
  12:header_byte=frame_seq[7:0];13:header_byte=frame_seq[15:8];
  14:header_byte=WIDTH&255;15:header_byte=(WIDTH>>8)&255;
  16:header_byte=HEIGHT&255;17:header_byte=(HEIGHT>>8)&255;
  18:header_byte=BYTES&255;19:header_byte=(BYTES>>8)&255;
  20:header_byte=(BYTES>>16)&255;21:header_byte=(BYTES>>24)&255;
  default:header_byte=0;
 endcase end endfunction
 wire[27:0] expected_address=(base+{3'b0,burst,9'b0})>>2;
 // fifo_wr_valid 
 assign fifo_wr_valid=cw_reset[1]&&(state==HEADER||state==SEND_WORD||state==TRAILER);
 wire[7:0] send_byte=state==HEADER?header_byte(header_index):state==SEND_WORD?word_shift[7:0]:(final_crc>>(trailer_index*8));
 // fifo_wr_data 
 assign fifo_wr_data={(state==TRAILER&&trailer_index==3),send_byte};
 
 wire sent=fifo_wr_valid&&fifo_wr_ready;
 
 always @(posedge core_clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;base<=0;frame_seq<=0;export_seq<=0;header_index<=0;burst<=0;beat<=0;word_index<=0;byte_index<=0;trailer_index<=0;word_shift<=0;crc<=32'hffffffff;end
  else begin
   
   case(state)
    IDLE:if(freeze2&&cw_reset[1]&&core_boundary&&display_valid)begin base<=display_base;frame_seq<=display_sequence;export_seq<=seq2;header_index<=0;crc<=32'hffffffff;burst<=0;state<=HEADER;end
    HEADER:if(sent)begin crc<=crc32(crc,send_byte);if(header_index==21)state<=WAIT_COMMAND;else header_index<=header_index+1;end
    WAIT_COMMAND:if(read_command&&read_addr==expected_address&&read_len==15)begin beat<=0;state<=RECEIVE;end
    RECEIVE:if(read_valid)begin buffer[beat]<=read_data;
     if(read_last!=(beat==15))state<=HELD;
     else if(read_last)begin word_index<=0;state<=LOAD_WORD;end else beat<=beat+1;
    end
    LOAD_WORD:begin word_shift<=buffer[word_index];byte_index<=0;state<=SEND_WORD;end
    SEND_WORD:if(sent)begin crc<=crc32(crc,send_byte);word_shift<={8'd0,word_shift[255:8]};
     if(byte_index==31)begin
      if(word_index==15)begin if(burst==BURSTS-1)begin trailer_index<=0;state<=TRAILER;end else begin burst<=burst+1;state<=WAIT_COMMAND;end end
      else begin word_index<=word_index+1;state<=LOAD_WORD;end
     end else byte_index<=byte_index+1;
    end
    TRAILER:if(sent)begin if(trailer_index==3)state<=HELD;else trailer_index<=trailer_index+1;end
    HELD:begin end
   endcase
   if(!freeze2)state<=IDLE;
  end
 end
endmodule
