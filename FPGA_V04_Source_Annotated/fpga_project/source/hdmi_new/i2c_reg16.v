// 文件职责：i2c_reg16 硬件模块，接口与状态机保持原版。
// 维护约束：本次仅添加说明；信号位宽、复位极性、握手和流水级均不修改。
// Single-master I2C, 16-bit register address (LOW BYTE FIRST for MS7200/MS7210), one data byte.
// SDA is open drain. SCL is driven: no clock stretching/multi-master support.
// NACK is a latched failure: stop bus, never claim successful initialization.
// 模块接口：各端口方向与位宽以下方声明为准；与上层实例连接共同决定时钟域。
module i2c_reg16 #(
    // 常量定义：用于以下状态编码、位宽或时序参数，不在本次整理中调整。
    parameter QUARTER_CYCLES = 68
)(
    input clk, input rst_n, input start,
    input [7:0] device, input [15:0] address, input write,
    input [7:0] write_data,
    output reg [7:0] read_data,
    inout sda, output reg scl,
    output reg busy, output reg done, output reg byte_done, output reg fault
);
    // 常量定义：用于以下状态编码、位宽或时序参数，不在本次整理中调整。
    localparam IDLE=0, START=1, SEND=2, ACK=3, RESTART=4,
        RECEIVE=5, NACK=6, STOP=7, FINISH=8;
    reg [3:0] state;
    reg [1:0] phase;
    reg [15:0] divider;
    reg sda_low;
    reg [2:0] bit_index, byte_index;
    reg [7:0] tx_byte, dev_latched, data_latched, rx_byte;
    reg [15:0] addr_latched;
    reg write_latched;
    // Synchronize the asynchronous SDA input; sampling occurs well inside SCL high.
    reg [1:0] sda_sync;
    // 连续赋值：sda 由右侧表达式组合驱动。
    assign sda = sda_low ? 1'b0 : 1'bz;
    // 时序块：仅在声明的时钟/复位边沿更新；非阻塞赋值读取更新前状态。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; phase <= 0; divider <= 0; sda_low <= 0;
            scl <= 1; busy <= 0; done <= 0; byte_done <= 0; fault <= 0;
            bit_index <= 7; byte_index <= 0; tx_byte <= 0; dev_latched <= 0;
            data_latched <= 0; addr_latched <= 0; write_latched <= 0;
            read_data <= 0; rx_byte <= 0; sda_sync <= 2'b11;
        end else begin
            sda_sync <= {sda_sync[0], sda};
            done <= 0; byte_done <= 0;
            if (state == IDLE) begin
                divider <= 0; phase <= 0; scl <= 1; sda_low <= 0;
                if (start && !fault) begin
                    busy <= 1; state <= START;
                    dev_latched <= {device[7:1],1'b0}; addr_latched <= address;
                    data_latched <= write_data; write_latched <= write;
                    tx_byte <= {device[7:1],1'b0}; byte_index <= 0; bit_index <= 7;
                end
            end else if (divider < QUARTER_CYCLES-1) divider <= divider + 1'b1;
            else begin
                divider <= 0; phase <= phase + 1'b1;
                // 分支译码：按当前状态/模式选择数据路径，保留 default 的原行为。
                case (state)
                    START: case (phase)
                        0: begin scl <= 1; sda_low <= 0; end
                        1: sda_low <= 1;
                        2: scl <= 0;
                        3: state <= SEND;
                    endcase
                    SEND: case (phase)
                        0: begin scl <= 0; sda_low <= !tx_byte[bit_index]; end
                        1: scl <= 1;
                        3: begin scl <= 0;
                            if (bit_index == 0) state <= ACK;
                            else bit_index <= bit_index - 1'b1;
                        end
                    endcase
                    ACK: case (phase)
                        0: begin scl <= 0; sda_low <= 0; end
                        1: scl <= 1;
                        2: if (sda_sync[1]) fault <= 1;
                        3: begin
                            scl <= 0; bit_index <= 7;
                            if (fault) state <= STOP;
                            else case (byte_index)
                                0: begin tx_byte <= addr_latched[7:0]; byte_index <= 1; state <= SEND; end
                                1: begin tx_byte <= addr_latched[15:8]; byte_index <= 2; state <= SEND; end
                                2: if (write_latched) begin tx_byte <= data_latched; byte_index <= 3; state <= SEND; end
                                   else state <= RESTART;
                                3: begin byte_done <= 1; state <= STOP; end
                                4: begin rx_byte <= 0; state <= RECEIVE; end
                                default: begin fault <= 1; state <= STOP; end
                            endcase
                        end
                    endcase
                    RESTART: case (phase)
                        0: begin scl <= 0; sda_low <= 0; end
                        1: scl <= 1;
                        2: sda_low <= 1;
                        3: begin scl <= 0; tx_byte <= dev_latched | 8'h01;
                            byte_index <= 4; bit_index <= 7; state <= SEND; end
                    endcase
                    RECEIVE: case (phase)
                        0: begin scl <= 0; sda_low <= 0; end
                        1: scl <= 1;
                        2: rx_byte[bit_index] <= sda_sync[1];
                        3: begin scl <= 0;
                            if (bit_index == 0) begin read_data <= rx_byte; byte_done <= 1; state <= NACK; end
                            else bit_index <= bit_index - 1'b1;
                        end
                    endcase
                    NACK: case (phase)
                        0: begin scl <= 0; sda_low <= 0; end
                        1: scl <= 1;
                        3: begin scl <= 0; state <= STOP; end
                    endcase
                    STOP: case (phase)
                        0: begin scl <= 0; sda_low <= 1; end
                        1: scl <= 1;
                        2: sda_low <= 0;
                        3: state <= FINISH;
                    endcase
                    FINISH: begin busy <= 0; done <= 1; state <= IDLE; end
                    default: begin fault <= 1; state <= STOP; end
                endcase
            end
        end
    end
endmodule
