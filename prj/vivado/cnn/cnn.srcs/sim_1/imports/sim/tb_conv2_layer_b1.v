`timescale 1ns / 1ps

// Pool1 output is the Conv2 input. Channel 0 occupies bits [11:0].
// Override these paths at compile time when required.
`ifndef INPUT_FILE
`define INPUT_FILE "p1_9_bit_exact.mem"
`endif

`ifndef GOLDEN_FILE
`define GOLDEN_FILE "c2_9_bit_exact.mem"
`endif

// B1-specific Conv2 layer regression.  Unlike the historical standalone test,
// this version drives the 169 Pool1 pixels at the fastest cadence the actual
// Conv1+Pool1 chain can produce, which is the B1 input contract.
module tb_conv2_layer_b1;

    localparam integer CLK_PERIOD_NS = 10;
    localparam integer INPUT_BEATS   = 169; // 13 x 13 x 4 channels
    localparam integer OUTPUT_BEATS  = 121; // 11 x 11 x 8 channels
    localparam integer MAX_CYCLES    = 5000;

    reg         clk;
    reg         rst_n;
    reg         valid_in;
    reg  [47:0] data_in;
    wire [95:0] conv_out;
    wire        valid_out_conv;

    reg [47:0] input_mem  [0:INPUT_BEATS-1];
    reg [95:0] golden_mem [0:OUTPUT_BEATS-1];

    integer input_index;
    integer input_row;
    integer input_col;
    integer output_index;
    integer error_count;
    integer cycle_count;
    integer first_input_cycle;
    integer last_input_cycle;
    integer first_output_cycle;
    integer last_output_cycle;
    integer latency_first;
    integer latency_frame;
    integer tail_cycles;
    integer max_fifo_count;
    reg     output_done;

    conv2_layer #(
        .IMG_WIDTH    (13),
        .IMG_HEIGHT   (13),
        .IN_CHANNELS  (4),
        .OUT_CHANNELS (8),
        .DATA_BITS    (12)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .valid_in       (valid_in),
        .data_in        (data_in),
        .conv_out       (conv_out),
        .valid_out_conv (valid_out_conv)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD_NS / 2) clk = ~clk;
    end

    initial begin
        $display("[TB] Loading Conv2 input  : %s", `INPUT_FILE);
        $display("[TB] Loading Conv2 golden : %s", `GOLDEN_FILE);
        $readmemh(`INPUT_FILE, input_mem);
        $readmemh(`GOLDEN_FILE, golden_mem);
    end

`ifdef DUMP_VCD
    initial begin
        $dumpfile("tb_conv2_layer_b1.vcd");
        $dumpvars(0, tb_conv2_layer_b1);
    end
`endif

    initial begin
        rst_n              = 1'b0;
        valid_in           = 1'b0;
        data_in            = 48'd0;
        input_index        = 0;
        input_row          = 0;
        input_col          = 0;
        output_index       = 0;
        error_count        = 0;
        cycle_count        = 0;
        first_input_cycle  = -1;
        last_input_cycle   = -1;
        first_output_cycle = -1;
        last_output_cycle  = -1;
        latency_first      = -1;
        latency_frame      = -1;
        tail_cycles        = -1;
        max_fifo_count     = 0;
        output_done        = 1'b0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Fastest legal Pool1 cadence:
        //   * valid pixels are two cycles apart inside a row;
        //   * adjacent row starts are 56 cycles apart.
        for (input_row = 0; input_row < 13; input_row = input_row + 1) begin
            for (input_col = 0; input_col < 13; input_col = input_col + 1) begin
                @(negedge clk);
                valid_in = 1'b1;
                data_in  = input_mem[input_index];
                input_index = input_index + 1;

                @(negedge clk);
                valid_in = 1'b0;
                data_in  = 48'd0;
            end

            if (input_row != 12)
                repeat (30) @(negedge clk);
        end

        if (input_index != INPUT_BEATS) begin
            $display("[TB][ERROR] Conv2 input count expected=%0d actual=%0d", INPUT_BEATS, input_index);
            error_count = error_count + 1;
        end

        wait (output_done == 1'b1);
        repeat (20) @(posedge clk);

        if (output_index != OUTPUT_BEATS) begin
            $display(
                "[TB][ERROR] Conv2 output count mismatch: expected=%0d actual=%0d",
                OUTPUT_BEATS,
                output_index
            );
            error_count = error_count + 1;
        end

        latency_first = first_output_cycle - first_input_cycle;
        latency_frame = last_output_cycle - first_input_cycle;
        tail_cycles   = last_output_cycle - last_input_cycle;

        $display("[TB] Input cycles       : first=%0d last=%0d", first_input_cycle, last_input_cycle);
        $display("[TB] Output cycles      : first=%0d last=%0d", first_output_cycle, last_output_cycle);
        $display("[TB] Output beats       : %0d", output_index);
        $display("[TB] First-out latency  : %0d cycles", latency_first);
        $display("[TB] Frame latency      : %0d cycles", latency_frame);
        $display("[TB] Tail after input   : %0d cycles", tail_cycles);
        $display("[TB] Max B1 FIFO count  : %0d/8", max_fifo_count);

        if (error_count == 0) begin
            $display("[TB][PASS] B1 Conv2 matched all %0d beats x 8 channels.", OUTPUT_BEATS);
            $finish;
        end
        else begin
            $fatal(1, "[TB][FAIL] Conv2 errors=%0d", error_count);
        end
    end

    always @(posedge clk) begin
        cycle_count = cycle_count + 1;

        if (rst_n && valid_in) begin
            if (first_input_cycle < 0)
                first_input_cycle = cycle_count;
            last_input_cycle = cycle_count;
        end

        if (rst_n && dut.u_buf.fifo_count > max_fifo_count)
            max_fifo_count = dut.u_buf.fifo_count;

        if (cycle_count > MAX_CYCLES && !output_done)
            $fatal(1, "[TB][TIMEOUT] No complete Conv2 output within %0d cycles", MAX_CYCLES);
    end

    // Each valid beat contains all eight output channels.
    always @(posedge clk) begin
        if (rst_n && valid_out_conv) begin
            if (first_output_cycle < 0)
                first_output_cycle = cycle_count;
            last_output_cycle = cycle_count;

            if (output_index >= OUTPUT_BEATS) begin
                $display(
                    "[TB][ERROR] Unexpected extra Conv2 beat %0d: rtl=%024h",
                    output_index,
                    conv_out
                );
                error_count = error_count + 1;
            end
            else if (^conv_out === 1'bx) begin
                $display(
                    "[TB][ERROR] Conv2 X/Z at beat=%0d row=%0d col=%0d rtl=%024h",
                    output_index,
                    output_index / 11,
                    output_index % 11,
                    conv_out
                );
                error_count = error_count + 1;
            end
            else if (conv_out !== golden_mem[output_index]) begin
                if (error_count < 20) begin
                    $display(
                        "[TB][ERROR] Conv2 beat=%0d row=%0d col=%0d rtl=%024h expected=%024h",
                        output_index,
                        output_index / 11,
                        output_index % 11,
                        conv_out,
                        golden_mem[output_index]
                    );
                    $display(
                        "            ch0 rtl=%03h exp=%03h | ch1 rtl=%03h exp=%03h | ch2 rtl=%03h exp=%03h | ch3 rtl=%03h exp=%03h",
                        conv_out[11:0],  golden_mem[output_index][11:0],
                        conv_out[23:12], golden_mem[output_index][23:12],
                        conv_out[35:24], golden_mem[output_index][35:24],
                        conv_out[47:36], golden_mem[output_index][47:36]
                    );
                    $display(
                        "            ch4 rtl=%03h exp=%03h | ch5 rtl=%03h exp=%03h | ch6 rtl=%03h exp=%03h | ch7 rtl=%03h exp=%03h",
                        conv_out[59:48], golden_mem[output_index][59:48],
                        conv_out[71:60], golden_mem[output_index][71:60],
                        conv_out[83:72], golden_mem[output_index][83:72],
                        conv_out[95:84], golden_mem[output_index][95:84]
                    );
                end
                error_count = error_count + 1;
            end

            output_index = output_index + 1;
            if (output_index == OUTPUT_BEATS)
                output_done = 1'b1;
        end
    end

endmodule
