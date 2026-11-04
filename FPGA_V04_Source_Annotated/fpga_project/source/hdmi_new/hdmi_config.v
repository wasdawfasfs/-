// 文件职责：hdmi_config 硬件模块，接口与状态机保持原版。
// 维护约束：本次仅添加说明；信号位宽、复位极性、握手和流水级均不修改。
// Shared-bus arbitration for Meyesemi MS7200/MS7210 configuration controllers.
// Vendor-derived controllers run at 27 MHz; I2C engine runs at ~100 kHz.
// 模块接口：各端口方向与位宽以下方声明为准；与上层实例连接共同决定时钟域。
module hdmi_config #(
    // 常量定义：用于以下状态编码、位宽或时序参数，不在本次整理中调整。
    parameter GAP_CYCLES = 27000,
    // 常量定义：用于以下状态编码、位宽或时序参数，不在本次整理中调整。
    parameter BUS_QUARTER_CYCLES = 270
)(
    input clk, input rst_n, inout sda, output scl,
    output rx_ready, output tx_ready, output fault,
    output reg diag_transfer_started, output diag_check_passed, output diag_wait_input,
    output reg diag_write_done, output reg diag_read_done,
    output reg diag_rx_busy_fell, output reg [7:0] diag_first_read,
    output reg edid_done, output reg edid_match,
    output reg [7:0] edid_bad_index, output reg [7:0] edid_bad_value
);
    wire [7:0] dev_rx, dev_tx, wr_rx, wr_tx;
    wire [15:0] addr_rx, addr_tx;
    wire trig_rx, trig_tx, write_rx, write_tx;
    reg busy_rx, busy_tx, byte_rx, byte_tx;
    reg [7:0] read_rx, read_tx;
    ms7200_ctl u_rx(.clk(clk), .rstn(rst_n), .init_over(rx_ready),
        .device_id(dev_rx), .iic_trig(trig_rx), .w_r(write_rx),
        .addr(addr_rx), .data_in(wr_rx), .busy(busy_rx),
        .data_out(read_rx), .byte_over(byte_rx),
        .diag_check_passed(diag_check_passed), .diag_wait_input(diag_wait_input));
    ms7210_ctl u_tx(.clk(clk), .rstn(rst_n), .init_over(tx_ready),
        .device_id(dev_tx), .iic_trig(trig_tx), .w_r(write_tx),
        .addr(addr_tx), .data_in(wr_tx), .busy(busy_tx),
        .data_out(read_tx), .byte_over(byte_tx));
    reg [3:0] pending_rx, pending_tx;
    reg owner, last_owner, start;
    reg [1:0] state;
    reg [15:0] command_addr;
    reg [7:0] command_dev, command_data;
    reg command_write;
    wire engine_busy, engine_done, engine_byte, engine_fault;
    wire [7:0] engine_read;
    reg [15:0] gap;
    reg audit_owner;
    reg [7:0] audit_index;
    // TX readback audit. These are programmed values, not undocumented status meanings.
    // 组合函数：实现下列运算；调用方负责位宽、符号及结果时序。
    function [15:0] audit_address;
        input [7:0] index;
        begin case(index)
            0: audit_address=16'h0003;
            1: audit_address=16'h0016;
            2: audit_address=16'h0006;
            3: audit_address=16'h0900;
            4: audit_address=16'h000b;
            5: audit_address=16'h050e;
            default: audit_address=16'h0502;
        endcase end
    endfunction
    // 组合函数：实现下列运算；调用方负责位宽、符号及结果时序。
    function [7:0] expected_edid;
        input [7:0] index;
        begin case(index)
            0: expected_edid=8'h5a;
            1: expected_edid=8'h04;
            2: expected_edid=8'h11;
            3: expected_edid=8'h20;
            4: expected_edid=8'h11;
            5: expected_edid=8'h40;
            default: expected_edid=0;
        endcase end
    endfunction

    // 连续赋值：fault 由右侧表达式组合驱动。
    assign fault = engine_fault;
    i2c_reg16 #(.QUARTER_CYCLES(BUS_QUARTER_CYCLES)) u_bus(.clk(clk), .rst_n(rst_n), .start(start),
        .device(command_dev), .address(command_addr), .write(command_write),
        .write_data(command_data), .read_data(engine_read), .sda(sda), .scl(scl),
        .busy(engine_busy), .done(engine_done), .byte_done(engine_byte), .fault(engine_fault));
    reg diag_busy_rx_previous;
    // 时序块：仅在声明的时钟/复位边沿更新；非阻塞赋值读取更新前状态。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            diag_write_done <= 0; diag_read_done <= 0;
            diag_rx_busy_fell <= 0; diag_first_read <= 0;
            diag_busy_rx_previous <= 0;
        end else begin
            diag_busy_rx_previous <= busy_rx;
            if (diag_busy_rx_previous && !busy_rx) diag_rx_busy_fell <= 1;
            // Capture only successfully stopped RX register 0003 transfers.
            if (!audit_owner && !owner && state == 1 && engine_done && !engine_fault && command_addr == 16'h0003) begin
                if (command_write && command_data == 8'h5A) diag_write_done <= 1;
                if (!command_write && !diag_read_done) begin
                    diag_read_done <= 1;
                    diag_first_read <= engine_read;
                end
            end
        end
    end
    // Sticky: the I2C engine actually entered busy, not merely a queued request.
    // 时序块：仅在声明的时钟/复位边沿更新；非阻塞赋值读取更新前状态。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) diag_transfer_started <= 1'b0;
        else if (engine_busy) diag_transfer_started <= 1'b1;
    end
    // 时序块：仅在声明的时钟/复位边沿更新；非阻塞赋值读取更新前状态。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_rx <= 0; busy_tx <= 0; byte_rx <= 0; byte_tx <= 0;
            read_rx <= 0; read_tx <= 0; pending_rx <= 0; pending_tx <= 0;
            owner <= 0; last_owner <= 1; start <= 0; state <= 0; gap <= 0;
            audit_owner <= 0; audit_index <= 0;
            edid_done <= 0; edid_match <= 1; edid_bad_index <= 0; edid_bad_value <= 0;
            command_addr <= 0; command_dev <= 0; command_data <= 0; command_write <= 0;
        end else begin
            start <= 0; byte_rx <= 0; byte_tx <= 0;
            if (trig_rx && !busy_rx) begin pending_rx <= 1; busy_rx <= 1; end
            else if (pending_rx != 0 && pending_rx < 8) pending_rx <= pending_rx + 1'b1;
            if (trig_tx && !busy_tx) begin pending_tx <= 1; busy_tx <= 1; end
            else if (pending_tx != 0 && pending_tx < 8) pending_tx <= pending_tx + 1'b1;
            // 分支译码：按当前状态/模式选择数据路径，保留 default 的原行为。
            case (state)
                0: if (!engine_fault && !engine_busy) begin
                    if (tx_ready && !edid_done) begin
                        audit_owner <= 1; owner <= 0;
                        command_dev <= 8'hB2; command_addr <= audit_address(audit_index);
                        command_data <= 0; command_write <= 0;
                        start <= 1; state <= 1;
                    end else if (pending_rx == 8 && (pending_tx != 8 || last_owner)) begin
                        audit_owner <= 0;
                        owner <= 0; command_dev <= dev_rx; command_addr <= addr_rx;
                        command_data <= wr_rx; command_write <= write_rx;
                        pending_rx <= 0; start <= 1; state <= 1;
                    end else if (pending_tx == 8) begin
                        audit_owner <= 0;
                        owner <= 1; command_dev <= dev_tx; command_addr <= addr_tx;
                        command_data <= wr_tx; command_write <= write_tx;
                        pending_tx <= 0; start <= 1; state <= 1;
                    end
                end
                1: begin
                    if (engine_byte && !audit_owner) begin
                        if (owner) begin byte_tx <= 1; read_tx <= engine_read; end
                        else begin byte_rx <= 1; read_rx <= engine_read; end
                    end
                    if (engine_done && !engine_fault) begin
                        if (audit_owner) begin
                            if (audit_index < 6 && engine_read != expected_edid(audit_index)) begin
                                if (edid_match) begin
                                    edid_bad_index <= audit_index; edid_bad_value <= engine_read;
                                end
                                edid_match <= 0;
                            end
                            if (audit_index == 6) begin
                                edid_done <= 1;
                                if (edid_match) begin edid_bad_index <= 6; edid_bad_value <= engine_read; end
                            end
                            else audit_index <= audit_index + 1'b1;
                        end
                        gap <= 0; state <= 2;
                    end
                end
                2: if (gap == GAP_CYCLES) begin // 1 ms between transactions
                    if (!audit_owner) begin
                        if (owner) busy_tx <= 0; else busy_rx <= 0;
                    end
                    last_owner <= owner; state <= 0;
                end else gap <= gap + 1'b1;
            endcase
        end
    end
endmodule
