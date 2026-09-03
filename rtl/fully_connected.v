`timescale 1ns / 10ps

module fully_connected
    (
        input  wire        clk,
        input  wire        rst_n,
        input  wire        valid_in,
        input  wire [95:0] data_in,

        output reg  [3:0]  decision,
        output reg         valid_out_fc
    );

    // Ten classes, 200 signed 8-bit weights per class.
    reg [1599:0] weight_rom [0:9];
    reg signed [7:0] bias_rom [0:9];

    initial begin
        $readmemh("fc_weight_wide.mem", weight_rom);
        $readmemh("fc_bias_wide.mem", bias_rom);
    end

    localparam S_RECV    = 3'd0;
    localparam S_CALC    = 3'd1;
    localparam S_SAVE    = 3'd2;
    localparam S_COMPARE = 3'd3;

    reg [2:0] state;
    reg [4:0] recv_cnt;
    reg [95:0] pool_buf [0:24];

    reg [3:0] neuron_idx;
    reg [4:0] issue_idx;
    reg       issue_done;
    reg [4:0] accum_count;

    reg signed [27:0] mac_accum;
    reg signed [11:0] logits [0:9];

    reg [3:0] comp_idx;
    reg signed [11:0] max_val;

    // ------------------------------------------------------------------
    // Registered balanced MAC pipeline
    //
    // S0: register one 96-bit feature beat and its eight weights
    // S1: eight independent signed multiplications
    // S2: four pair sums
    // S3: two pair sums
    // S4: one beat sum
    // ACC: add one beat sum to the neuron accumulator
    // ------------------------------------------------------------------

    wire [95:0] issue_data = pool_buf[issue_idx];
    wire [63:0] issue_weights =
        weight_rom[neuron_idx][issue_idx * 64 +: 64];

    reg [95:0] data_s0;
    reg [63:0] weights_s0;
    reg        valid_s0;

    wire signed [11:0] data_lane_s0 [0:7];
    wire signed [7:0]  weight_lane_s0 [0:7];

    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : lane_slice
            assign data_lane_s0[g] = $signed(data_s0[g*12 +: 12]);
            assign weight_lane_s0[g] = $signed(weights_s0[g*8 +: 8]);
        end
    endgenerate

    reg signed [19:0] product_s1 [0:7];
    reg               valid_s1;

    reg signed [20:0] sum_s2 [0:3];
    reg               valid_s2;

    reg signed [21:0] sum_s3 [0:1];
    reg               valid_s3;

    reg signed [22:0] beat_sum_s4;
    reg               valid_s4;

    wire signed [27:0] beat_sum_ext =
        {{5{beat_sum_s4[22]}}, beat_sum_s4};

    wire signed [11:0] exp_bias = bias_rom[neuron_idx][7]
        ? {4'b1111, bias_rom[neuron_idx]}
        : {4'b0000, bias_rom[neuron_idx]};

    wire signed [27:0] biased_sum = (mac_accum >>> 7) + exp_bias;
    wire signed [11:0] clipped_val =
        (biased_sum > 28'sd2047)  ? 12'sd2047 :
        (biased_sum < -28'sd2048) ? -12'sd2048 :
                                    biased_sum[11:0];

    integer i;
    always @(posedge clk) begin
        if (~rst_n) begin
            state        <= S_RECV;
            recv_cnt     <= 5'd0;
            neuron_idx   <= 4'd0;
            issue_idx    <= 5'd0;
            issue_done   <= 1'b0;
            accum_count  <= 5'd0;
            mac_accum    <= 28'sd0;
            comp_idx     <= 4'd0;
            max_val      <= -12'sd2048;
            decision     <= 4'd0;
            valid_out_fc <= 1'b0;

            data_s0      <= 96'd0;
            weights_s0   <= 64'd0;
            valid_s0     <= 1'b0;
            valid_s1     <= 1'b0;
            valid_s2     <= 1'b0;
            valid_s3     <= 1'b0;
            valid_s4     <= 1'b0;
            beat_sum_s4  <= 23'sd0;

            for (i = 0; i < 8; i = i + 1)
                product_s1[i] <= 20'sd0;
            for (i = 0; i < 4; i = i + 1)
                sum_s2[i] <= 21'sd0;
            for (i = 0; i < 2; i = i + 1)
                sum_s3[i] <= 22'sd0;
        end
        else begin
            valid_out_fc <= 1'b0;

            case (state)
                S_RECV: begin
                    // Make all pipeline-valid flags quiescent between frames.
                    valid_s0 <= 1'b0;
                    valid_s1 <= 1'b0;
                    valid_s2 <= 1'b0;
                    valid_s3 <= 1'b0;
                    valid_s4 <= 1'b0;

                    if (valid_in) begin
                        pool_buf[recv_cnt] <= data_in;
                        if (recv_cnt == 5'd24) begin
                            recv_cnt    <= 5'd0;
                            neuron_idx  <= 4'd0;
                            issue_idx   <= 5'd0;
                            issue_done  <= 1'b0;
                            accum_count <= 5'd0;
                            mac_accum   <= 28'sd0;
                            state       <= S_CALC;
                        end
                        else begin
                            recv_cnt <= recv_cnt + 1'b1;
                        end
                    end
                end

                S_CALC: begin
                    // S0: issue one feature beat per cycle until all 25 have
                    // entered the pipeline. issue_idx remains at 24 while the
                    // final beats drain, avoiding an out-of-range ROM slice.
                    valid_s0 <= 1'b0;
                    if (!issue_done) begin
                        data_s0    <= issue_data;
                        weights_s0 <= issue_weights;
                        valid_s0   <= 1'b1;

                        if (issue_idx == 5'd24)
                            issue_done <= 1'b1;
                        else
                            issue_idx <= issue_idx + 1'b1;
                    end

                    // S1: registered multipliers. No DSP cascade is required.
                    valid_s1 <= valid_s0;
                    if (valid_s0) begin
                        for (i = 0; i < 8; i = i + 1)
                            product_s1[i] <= data_lane_s0[i] * weight_lane_s0[i];
                    end

                    // S2: 8 products -> 4 explicitly widened sums.
                    valid_s2 <= valid_s1;
                    if (valid_s1) begin
                        sum_s2[0] <= {product_s1[0][19], product_s1[0]} +
                                     {product_s1[1][19], product_s1[1]};
                        sum_s2[1] <= {product_s1[2][19], product_s1[2]} +
                                     {product_s1[3][19], product_s1[3]};
                        sum_s2[2] <= {product_s1[4][19], product_s1[4]} +
                                     {product_s1[5][19], product_s1[5]};
                        sum_s2[3] <= {product_s1[6][19], product_s1[6]} +
                                     {product_s1[7][19], product_s1[7]};
                    end

                    // S3: 4 sums -> 2 explicitly widened sums.
                    valid_s3 <= valid_s2;
                    if (valid_s2) begin
                        sum_s3[0] <= {sum_s2[0][20], sum_s2[0]} +
                                     {sum_s2[1][20], sum_s2[1]};
                        sum_s3[1] <= {sum_s2[2][20], sum_s2[2]} +
                                     {sum_s2[3][20], sum_s2[3]};
                    end

                    // S4: 2 sums -> one registered sum for this feature beat.
                    valid_s4 <= valid_s3;
                    if (valid_s3) begin
                        beat_sum_s4 <= {sum_s3[0][21], sum_s3[0]} +
                                       {sum_s3[1][21], sum_s3[1]};
                    end

                    // ACC: the recurrence now contains only one 28-bit adder.
                    if (valid_s4) begin
                        if (accum_count == 5'd0)
                            mac_accum <= beat_sum_ext;
                        else
                            mac_accum <= mac_accum + beat_sum_ext;

                        if (accum_count == 5'd24) begin
                            accum_count <= 5'd0;
                            state <= S_SAVE;
                        end
                        else begin
                            accum_count <= accum_count + 1'b1;
                        end
                    end
                end

                S_SAVE: begin
                    logits[neuron_idx] <= clipped_val;

                    // Clear the pipeline control before the next neuron.
                    valid_s0    <= 1'b0;
                    valid_s1    <= 1'b0;
                    valid_s2    <= 1'b0;
                    valid_s3    <= 1'b0;
                    valid_s4    <= 1'b0;
                    issue_idx   <= 5'd0;
                    issue_done  <= 1'b0;
                    accum_count <= 5'd0;
                    mac_accum   <= 28'sd0;

                    if (neuron_idx == 4'd9) begin
                        comp_idx <= 4'd0;
                        max_val  <= -12'sd2048;
                        state    <= S_COMPARE;
                    end
                    else begin
                        neuron_idx <= neuron_idx + 1'b1;
                        state <= S_CALC;
                    end
                end

                S_COMPARE: begin
                    if (comp_idx == 4'd10) begin
                        valid_out_fc <= 1'b1;
                        state <= S_RECV;
                    end
                    else begin
                        if (logits[comp_idx] > max_val) begin
                            max_val  <= logits[comp_idx];
                            decision <= comp_idx;
                        end
                        comp_idx <= comp_idx + 1'b1;
                    end
                end

                default: begin
                    state        <= S_RECV;
                    recv_cnt     <= 5'd0;
                    valid_s0     <= 1'b0;
                    valid_s1     <= 1'b0;
                    valid_s2     <= 1'b0;
                    valid_s3     <= 1'b0;
                    valid_s4     <= 1'b0;
                    valid_out_fc <= 1'b0;
                end
            endcase
        end
    end

endmodule
