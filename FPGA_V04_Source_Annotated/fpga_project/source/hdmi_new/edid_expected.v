// 提供 HDMI EDID/输入模式相关配置，影响主机协商的输入格式。


module edid_expected(input [7:0] index, output reg [7:0] value);
    
    always @* begin case(index)
        0: value=8'h5a; 1: value=8'h04; 2: value=8'h11;
        3: value=8'h20; 4: value=8'h11; 5: value=8'h40;
        default: value=0;
    endcase end
endmodule
