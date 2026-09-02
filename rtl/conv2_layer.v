`timescale 1ns / 10ps

module conv2_layer
    #(
        parameter IMG_WIDTH    = 13,
        parameter IMG_HEIGHT   = 13,
        parameter IN_CHANNELS  = 4,
        parameter OUT_CHANNELS = 8,
        parameter DATA_BITS    = 12
    )
    (
        input  wire        clk,
        input  wire        rst_n,
        input  wire        valid_in,
        input  wire [(IN_CHANNELS*DATA_BITS)-1:0] data_in,
        
        output wire [(OUT_CHANNELS*DATA_BITS)-1:0] conv_out, 
        output wire         valid_out_conv
    );

    wire [(IN_CHANNELS*DATA_BITS)-1:0] d0, d1, d2, d3, d4, d5, d6, d7, d8;
    wire valid_out_buf;
    wire calc_busy;

    conv2_buf #(
        .WIDTH(IMG_WIDTH),
        .HEIGHT(IMG_HEIGHT),
        .CHANNELS(IN_CHANNELS),
        .DATA_BITS(DATA_BITS)
    ) u_buf (
        .clk(clk),
        .rst_n(rst_n),
        .valid_in(valid_in),
        .data_in(data_in),
        .calc_busy(calc_busy),
        .data_out_0(d0), .data_out_1(d1), .data_out_2(d2),
        .data_out_3(d3), .data_out_4(d4), .data_out_5(d5),
        .data_out_6(d6), .data_out_7(d7), .data_out_8(d8),
        .valid_out_buf(valid_out_buf)
    );

    conv2_calc #(
        .IN_CHANNELS(IN_CHANNELS),
        .OUT_CHANNELS(OUT_CHANNELS),
        .DATA_BITS(DATA_BITS)
    ) u_calc (
        .clk(clk),
        .rst_n(rst_n),
        .valid_out_buf(valid_out_buf),
        .data_out_0(d0), .data_out_1(d1), .data_out_2(d2),
        .data_out_3(d3), .data_out_4(d4), .data_out_5(d5),
        .data_out_6(d6), .data_out_7(d7), .data_out_8(d8),
        .conv_out(conv_out),
        .valid_out_calc(valid_out_conv),
        .calc_busy(calc_busy)
    );

endmodule