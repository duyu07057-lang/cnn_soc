`timescale 1ns / 10ps

module conv1_calc
    #(
        parameter DATA_BITS = 8,
        parameter OUT_BITS = 12,
        parameter OUT_CHANNELS = 4
    )
    (
        input  wire                 clk,
        input  wire                 rst_n,
        input  wire                 valid_out_buf,

        input  wire [DATA_BITS-1:0] data_out_0, data_out_1, data_out_2,
        data_out_3, data_out_4, data_out_5,
        data_out_6, data_out_7, data_out_8,

         // 4 通道 * 12 bit = 48 bit
        output wire [(OUT_CHANNELS*OUT_BITS)-1:0] conv_out,
        output wire                               valid_out_calc
    );

    localparam FILTER_SIZE = 3;

    // 展平的 ROM 权重：4通道 * 9 = 36
    reg signed [DATA_BITS-1:0] weight [0:OUT_CHANNELS*FILTER_SIZE*FILTER_SIZE-1];
    reg signed [DATA_BITS-1:0] bias [0:OUT_CHANNELS-1];

    // 初始化只需 4 组
    initial begin
        $readmemh("conv1_weight_0.mem", weight, 0, 8);
        $readmemh("conv1_weight_1.mem", weight, 9, 17);
        $readmemh("conv1_weight_2.mem", weight, 18, 26);
        $readmemh("conv1_weight_3.mem", weight, 27, 35);
        $readmemh("conv1_bias.mem", bias);
    end

    // 无符号像素扩展为有符号的 9-bit 数据
    wire signed [DATA_BITS:0] exp_data [0:8];
    assign exp_data[0] = {1'b0, data_out_0};
    assign exp_data[1] = {1'b0, data_out_1};
    assign exp_data[2] = {1'b0, data_out_2};
    assign exp_data[3] = {1'b0, data_out_3};
    assign exp_data[4] = {1'b0, data_out_4};
    assign exp_data[5] = {1'b0, data_out_5};
    assign exp_data[6] = {1'b0, data_out_6};
    assign exp_data[7] = {1'b0, data_out_7};
    assign exp_data[8] = {1'b0, data_out_8};

    // 生成 4 个并发乘加树通道
    genvar c;
    generate
        for (c = 0; c < OUT_CHANNELS; c = c + 1) begin : conv_channels
            reg signed [19:0] stg1_mult [0:8];
            reg signed [19:0] stg2_add  [0:3];
            reg signed [19:0] stg2_mult8;
            reg signed [19:0] stg3_add  [0:1];
            reg signed [19:0] stg4_sum;

            wire signed [11:0] exp_bias = (bias[c][7] == 1) ? {4'b1111, bias[c]} : {4'd0, bias[c]};

            always @(posedge clk) begin
                if (~rst_n) begin
                    stg1_mult[0]<=0;
                    stg1_mult[1]<=0;
                    stg1_mult[2]<=0;
                    stg1_mult[3]<=0;
                    stg1_mult[4]<=0;
                    stg1_mult[5]<=0;
                    stg1_mult[6]<=0;
                    stg1_mult[7]<=0;
                    stg1_mult[8]<=0;
                    stg2_add[0]<=0;
                    stg2_add[1]<=0;
                    stg2_add[2]<=0;
                    stg2_add[3]<=0;
                    stg3_add[0]<=0;
                    stg3_add[1]<=0;
                    stg2_mult8 <= 0;
                    stg4_sum <= 0;
                end
                else begin
                    // Stage 1
                    stg1_mult[0] <= exp_data[0] * weight[c*9 + 0];
                    stg1_mult[1] <= exp_data[1] * weight[c*9 + 1];
                    stg1_mult[2] <= exp_data[2] * weight[c*9 + 2];
                    stg1_mult[3] <= exp_data[3] * weight[c*9 + 3];
                    stg1_mult[4] <= exp_data[4] * weight[c*9 + 4];
                    stg1_mult[5] <= exp_data[5] * weight[c*9 + 5];
                    stg1_mult[6] <= exp_data[6] * weight[c*9 + 6];
                    stg1_mult[7] <= exp_data[7] * weight[c*9 + 7];
                    stg1_mult[8] <= exp_data[8] * weight[c*9 + 8];
                    // Stage 2
                    stg2_add[0] <= stg1_mult[0] + stg1_mult[1];
                    stg2_add[1] <= stg1_mult[2] + stg1_mult[3];
                    stg2_add[2] <= stg1_mult[4] + stg1_mult[5];
                    stg2_add[3] <= stg1_mult[6] + stg1_mult[7];
                    stg2_mult8  <= stg1_mult[8];
                    // Stage 3
                    stg3_add[0] <= stg2_add[0] + stg2_add[1];
                    stg3_add[1] <= stg2_add[2] + stg2_add[3] + stg2_mult8;
                    // Stage 4
                    stg4_sum <= stg3_add[0] + stg3_add[1];
                end
            end

            // 切片挂载到输出总线
            assign conv_out[c*OUT_BITS +: OUT_BITS] = stg4_sum[19:8] + exp_bias;
        end
    endgenerate

    // 乘加树为4级流水线，对齐 Valid 信号
    reg [3:0] valid_shift;
    always @(posedge clk) begin
        if (~rst_n)
            valid_shift <= 4'd0;
        else
            valid_shift <= {valid_shift[2:0], valid_out_buf};
    end
    assign valid_out_calc = valid_shift[3];

endmodule
