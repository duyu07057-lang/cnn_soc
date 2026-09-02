`timescale 1ns / 10ps

// Conv2 calculation core with a registered multiplier stage.
//
// Relative to the original implementation, the 13x8 multipliers and the
// nine-term accumulation tree are separated by a register boundary.  The
// balanced tree keeps the arithmetic bit-exact while removing the routed
// calc_state -> DSP -> CARRY4 chain that limited the post-route clock period.
module conv2_calc
    #(
        parameter IN_CHANNELS  = 4,
        parameter OUT_CHANNELS = 8,
        parameter DATA_BITS    = 12,
        parameter WEIGHT_BITS  = 8
    )
    (
        input  wire                               clk,
        input  wire                               rst_n,
        input  wire                               valid_out_buf,

        input  wire [(IN_CHANNELS*DATA_BITS)-1:0] data_out_0, data_out_1, data_out_2,
                                                     data_out_3, data_out_4, data_out_5,
                                                     data_out_6, data_out_7, data_out_8,

        output reg  [(OUT_CHANNELS*DATA_BITS)-1:0] conv_out,
        output reg                                valid_out_calc,
        output reg                                calc_busy
    );

    localparam PRODUCT_BITS = 13 + WEIGHT_BITS;

    // Eight output channels, each with 4 x 3 x 3 weights.
    // Distributed storage is retained because one issued group needs 144
    // simultaneous weight reads.
    (* rom_style = "distributed" *)
    reg signed [WEIGHT_BITS-1:0] weight [0:OUT_CHANNELS*36-1];
    reg signed [15:0] bias [0:OUT_CHANNELS-1];

    initial begin
        $readmemh("conv2_weight_0.mem", weight,   0,  35);
        $readmemh("conv2_weight_1.mem", weight,  36,  71);
        $readmemh("conv2_weight_2.mem", weight,  72, 107);
        $readmemh("conv2_weight_3.mem", weight, 108, 143);
        $readmemh("conv2_weight_4.mem", weight, 144, 179);
        $readmemh("conv2_weight_5.mem", weight, 180, 215);
        $readmemh("conv2_weight_6.mem", weight, 216, 251);
        $readmemh("conv2_weight_7.mem", weight, 252, 287);
        $readmemh("conv2_bias.mem", bias);
    end

    // Pool output is unsigned after ReLU.  The leading zero is essential:
    // it prevents values with bit 11 set from becoming negative operands.
    reg signed [12:0] p_latched [0:IN_CHANNELS-1][0:8];

    reg       calc_state;
    reg       valid_prod;
    reg       valid_d1;
    reg       valid_d2;
    reg       oc_group_prod;
    reg       oc_group_d1;
    reg       oc_group_d2;

    // New timing cut: the DSP products are registered before the adder tree.
    reg signed [PRODUCT_BITS-1:0] product_s1
        [0:3][0:IN_CHANNELS-1][0:8];

    reg signed [23:0] stg1_mult_sum [0:3][0:IN_CHANNELS-1];
    reg signed [27:0] stg2_total_sum [0:3];

    wire signed [15:0] bias_val [0:3];
    wire signed [27:0] biased_sum [0:3];
    wire signed [11:0] final_pixel_wire [0:3];
    wire signed [23:0] balanced_sum [0:3][0:IN_CHANNELS-1];

    integer i;
    integer p;
    integer k;

    always @(posedge clk) begin
        if (~rst_n) begin
            calc_busy     <= 1'b0;
            calc_state    <= 1'b0;
            valid_prod    <= 1'b0;
            valid_d1      <= 1'b0;
            valid_d2      <= 1'b0;
            oc_group_prod <= 1'b0;
            oc_group_d1   <= 1'b0;
            oc_group_d2   <= 1'b0;
            valid_out_calc <= 1'b0;
        end
        else begin
            valid_prod     <= 1'b0;
            valid_out_calc <= 1'b0;

            // Latch one 3x3x4 window.  calc_busy still covers exactly two
            // group issues, so the existing conv2_buf handshake is unchanged.
            if (valid_out_buf) begin
                calc_busy  <= 1'b1;
                calc_state <= 1'b0;

                for (i=0; i<IN_CHANNELS; i=i+1) begin
                    p_latched[i][0] <= {1'b0, data_out_0[i*DATA_BITS +: DATA_BITS]};
                    p_latched[i][1] <= {1'b0, data_out_1[i*DATA_BITS +: DATA_BITS]};
                    p_latched[i][2] <= {1'b0, data_out_2[i*DATA_BITS +: DATA_BITS]};
                    p_latched[i][3] <= {1'b0, data_out_3[i*DATA_BITS +: DATA_BITS]};
                    p_latched[i][4] <= {1'b0, data_out_4[i*DATA_BITS +: DATA_BITS]};
                    p_latched[i][5] <= {1'b0, data_out_5[i*DATA_BITS +: DATA_BITS]};
                    p_latched[i][6] <= {1'b0, data_out_6[i*DATA_BITS +: DATA_BITS]};
                    p_latched[i][7] <= {1'b0, data_out_7[i*DATA_BITS +: DATA_BITS]};
                    p_latched[i][8] <= {1'b0, data_out_8[i*DATA_BITS +: DATA_BITS]};
                end
            end

            // Stage P: issue four output channels and register all 144 DSP
            // products.  Group 0 covers OC0..3; group 1 covers OC4..7.
            if (calc_busy) begin
                valid_prod    <= 1'b1;
                oc_group_prod <= calc_state;

                for (p=0; p<4; p=p+1) begin
                    for (i=0; i<IN_CHANNELS; i=i+1) begin
                        for (k=0; k<9; k=k+1) begin
                            product_s1[p][i][k] <=
                                p_latched[i][k] *
                                weight[(calc_state*4 + p)*36 + i*9 + k];
                        end
                    end
                end

                if (calc_state == 1'b1) begin
                    calc_busy <= 1'b0;
                end
                else begin
                    calc_state <= 1'b1;
                end
            end

            // Stage 1: register the explicitly balanced nine-product trees.
            valid_d1    <= valid_prod;
            oc_group_d1 <= oc_group_prod;
            if (valid_prod) begin
                for (p=0; p<4; p=p+1) begin
                    for (i=0; i<IN_CHANNELS; i=i+1) begin
                        stg1_mult_sum[p][i] <= balanced_sum[p][i];
                    end
                end
            end

            // Stage 2: accumulate the four input-channel partial sums.
            valid_d2    <= valid_d1;
            oc_group_d2 <= oc_group_d1;
            if (valid_d1) begin
                for (p=0; p<4; p=p+1) begin
                    stg2_total_sum[p] <=
                        {{4{stg1_mult_sum[p][0][23]}}, stg1_mult_sum[p][0]} +
                        {{4{stg1_mult_sum[p][1][23]}}, stg1_mult_sum[p][1]} +
                        {{4{stg1_mult_sum[p][2][23]}}, stg1_mult_sum[p][2]} +
                        {{4{stg1_mult_sum[p][3][23]}}, stg1_mult_sum[p][3]};
                end
            end

            // Stage 3: quantize, clip, and assemble four channels per group.
            if (valid_d2) begin
                conv_out[(oc_group_d2*4 + 0)*DATA_BITS +: DATA_BITS] <= final_pixel_wire[0];
                conv_out[(oc_group_d2*4 + 1)*DATA_BITS +: DATA_BITS] <= final_pixel_wire[1];
                conv_out[(oc_group_d2*4 + 2)*DATA_BITS +: DATA_BITS] <= final_pixel_wire[2];
                conv_out[(oc_group_d2*4 + 3)*DATA_BITS +: DATA_BITS] <= final_pixel_wire[3];
            end

            if (valid_d2 && (oc_group_d2 == 1'b1)) begin
                valid_out_calc <= 1'b1;
            end
        end
    end

    // Balanced adder tree.  Every addition has an explicit signed extension,
    // so expression sizing cannot change the original 24-bit MAC result.
    genvar gp;
    genvar gi;
    generate
        for (gp=0; gp<4; gp=gp+1) begin : gen_output_lane
            for (gi=0; gi<IN_CHANNELS; gi=gi+1) begin : gen_input_lane
                wire signed [21:0] pair01;
                wire signed [21:0] pair23;
                wire signed [21:0] pair45;
                wire signed [21:0] pair67;
                wire signed [22:0] sum03;
                wire signed [22:0] sum47;
                wire signed [23:0] sum07;
                wire signed [23:0] product8_ext;

                assign pair01 =
                    {{1{product_s1[gp][gi][0][PRODUCT_BITS-1]}}, product_s1[gp][gi][0]} +
                    {{1{product_s1[gp][gi][1][PRODUCT_BITS-1]}}, product_s1[gp][gi][1]};
                assign pair23 =
                    {{1{product_s1[gp][gi][2][PRODUCT_BITS-1]}}, product_s1[gp][gi][2]} +
                    {{1{product_s1[gp][gi][3][PRODUCT_BITS-1]}}, product_s1[gp][gi][3]};
                assign pair45 =
                    {{1{product_s1[gp][gi][4][PRODUCT_BITS-1]}}, product_s1[gp][gi][4]} +
                    {{1{product_s1[gp][gi][5][PRODUCT_BITS-1]}}, product_s1[gp][gi][5]};
                assign pair67 =
                    {{1{product_s1[gp][gi][6][PRODUCT_BITS-1]}}, product_s1[gp][gi][6]} +
                    {{1{product_s1[gp][gi][7][PRODUCT_BITS-1]}}, product_s1[gp][gi][7]};

                assign sum03 = {pair01[21], pair01} + {pair23[21], pair23};
                assign sum47 = {pair45[21], pair45} + {pair67[21], pair67};
                assign sum07 = {sum03[22], sum03} + {sum47[22], sum47};
                assign product8_ext =
                    {{(24-PRODUCT_BITS){product_s1[gp][gi][8][PRODUCT_BITS-1]}},
                      product_s1[gp][gi][8]};
                assign balanced_sum[gp][gi] = sum07 + product8_ext;
            end
        end
    endgenerate

    genvar g;
    generate
        for (g=0; g<4; g=g+1) begin : post_process
            assign bias_val[g] = bias[oc_group_d2*4 + g];
            assign biased_sum[g] =
                ((stg2_total_sum[g] + 28'sd64) >>> 7) + bias_val[g];
            assign final_pixel_wire[g] =
                (biased_sum[g] > 2047)  ? 12'd2047 :
                (biased_sum[g] < -2048) ? -12'd2048 : biased_sum[g][11:0];
        end
    endgenerate

endmodule
