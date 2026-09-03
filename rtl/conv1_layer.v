`timescale 1ns / 10ps

module conv1_layer
    #(
        parameter IMG_WIDTH    = 28,
        parameter IMG_HEIGHT   = 28,
        parameter IN_BITS      = 8,
        parameter OUT_BITS     = 12,
        parameter OUT_CHANNELS = 4    // 【重构核心】：从 16 缩减为 4
    )
    (
        input  wire        clk,
        input  wire        rst_n,
        input  wire        valid_in,
        input  wire [IN_BITS-1:0] data_in,
        
        // 自动计算输出总线宽度: 4 * 12 = 48-bit
        output wire [(OUT_CHANNELS * OUT_BITS)-1:0] conv_out, 
        output wire         valid_out_conv
    );

    // 内部连线
    wire [IN_BITS-1:0] p0, p1, p2, p3, p4, p5, p6, p7, p8;
    wire valid_out_buf;

    conv1_buf #(
        .WIDTH(IMG_WIDTH),
        .HEIGHT(IMG_HEIGHT),
        .DATA_BITS(IN_BITS)
    ) u_conv1_buf (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .data_in(data_in),
        .data_out_0(p0), .data_out_1(p1), .data_out_2(p2),
        .data_out_3(p3), .data_out_4(p4), .data_out_5(p5),
        .data_out_6(p6), .data_out_7(p7), .data_out_8(p8),
        .valid_out_buf(valid_out_buf)
    );

    conv1_calc #(
        .DATA_BITS(IN_BITS),
        .OUT_BITS(OUT_BITS),
        .OUT_CHANNELS(OUT_CHANNELS)
    ) u_conv1_calc (
        .clk(clk),
        .rst_n(rst_n),
        .valid_out_buf(valid_out_buf),
        .data_out_0(p0), .data_out_1(p1), .data_out_2(p2),
        .data_out_3(p3), .data_out_4(p4), .data_out_5(p5),
        .data_out_6(p6), .data_out_7(p7), .data_out_8(p8),
        .conv_out(conv_out),
        .valid_out_calc(valid_out_conv)
    );

endmodule