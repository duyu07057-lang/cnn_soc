`timescale 1ns / 1ps

// Conv2 output is the Pool2 input. Channel 0 occupies bits [11:0].
// Override these paths at compile time when required.
`ifndef INPUT_FILE
`define INPUT_FILE "c2_9_bit_exact.mem"
`endif

`ifndef GOLDEN_FILE
`define GOLDEN_FILE "p2_9_bit_exact.mem"
`endif

module tb_pool2;

    localparam integer CLK_PERIOD_NS = 10;
    localparam integer INPUT_BEATS   = 121; // 11 x 11 x 8 channels
    localparam integer OUTPUT_BEATS  = 25;  // 5 x 5 x 8 channels
    localparam integer MAX_CYCLES    = 1000;

    reg         clk;
    reg         rst_n;
    reg         valid_in;
    reg  [95:0] data_in;
    wire [95:0] data_out;
    wire        valid_out_relu;

    reg [95:0] input_mem  [0:INPUT_BEATS-1];
    reg [95:0] golden_mem [0:OUTPUT_BEATS-1];

    integer input_index;
    integer output_index;
    integer error_count;
    integer cycle_count;
    integer first_input_cycle;
    integer last_input_cycle;
    integer first_output_cycle;
    integer last_output_cycle;
    integer first_out_latency;
    integer frame_latency;
    integer output_lead;
    reg     output_done;

    maxpool_relu #(
        .WIDTH     (11),
        .HEIGHT    (11),
        .CHANNELS  (8),
        .DATA_BITS (12)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .valid_in       (valid_in),
        .data_in        (data_in),
        .data_out       (data_out),
        .valid_out_relu (valid_out_relu)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD_NS / 2) clk = ~clk;
    end

    initial begin
        $display("[TB] Loading Pool2 input  : %s", `INPUT_FILE);
        $display("[TB] Loading Pool2 golden : %s", `GOLDEN_FILE);
        $readmemh(`INPUT_FILE, input_mem);
        $readmemh(`GOLDEN_FILE, golden_mem);
    end

`ifdef DUMP_VCD
    initial begin
        $dumpfile("tb_pool2.vcd");
        $dumpvars(0, tb_pool2);
    end
`endif

    initial begin
        rst_n              = 1'b0;
        valid_in           = 1'b0;
        data_in            = 96'd0;
        input_index        = 0;
        output_index       = 0;
        error_count        = 0;
        cycle_count        = 0;
        first_input_cycle  = -1;
        last_input_cycle   = -1;
        first_output_cycle = -1;
        last_output_cycle  = -1;
        first_out_latency  = -1;
        frame_latency      = -1;
        output_lead        = -1;
        output_done        = 1'b0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        for (input_index = 0; input_index < INPUT_BEATS; input_index = input_index + 1) begin
            @(negedge clk);
            valid_in = 1'b1;
            data_in  = input_mem[input_index];
        end

        @(negedge clk);
        valid_in  = 1'b0;
        data_in   = 96'd0;

        wait (output_done == 1'b1);
        repeat (20) @(posedge clk);

        if (output_index != OUTPUT_BEATS) begin
            $display(
                "[TB][ERROR] Pool2 output count mismatch: expected=%0d actual=%0d",
                OUTPUT_BEATS,
                output_index
            );
            error_count = error_count + 1;
        end

        first_out_latency = first_output_cycle - first_input_cycle;
        frame_latency     = last_output_cycle - first_input_cycle;
        output_lead       = last_input_cycle - last_output_cycle;

        $display("[TB] Input cycles       : first=%0d last=%0d", first_input_cycle, last_input_cycle);
        $display("[TB] Output cycles      : first=%0d last=%0d", first_output_cycle, last_output_cycle);
        $display("[TB] Output beats       : %0d", output_index);
        $display("[TB] First-out latency  : %0d cycles", first_out_latency);
        $display("[TB] Frame latency      : %0d cycles", frame_latency);
        $display("[TB] Output-before-input-end: %0d cycles", output_lead);

        if (error_count == 0) begin
            $display("[TB][PASS] Pool2 matched all %0d beats x 8 channels.", OUTPUT_BEATS);
            $finish;
        end
        else begin
            $fatal(1, "[TB][FAIL] Pool2 errors=%0d", error_count);
        end
    end

    always @(posedge clk) begin
        cycle_count = cycle_count + 1;

        if (rst_n && valid_in) begin
            if (first_input_cycle < 0)
                first_input_cycle = cycle_count;
            last_input_cycle = cycle_count;
        end

        if (cycle_count > MAX_CYCLES && !output_done)
            $fatal(1, "[TB][TIMEOUT] No complete Pool2 output within %0d cycles", MAX_CYCLES);
    end

    always @(posedge clk) begin
        if (rst_n && valid_out_relu) begin
            if (first_output_cycle < 0)
                first_output_cycle = cycle_count;
            last_output_cycle = cycle_count;

            if (output_index >= OUTPUT_BEATS) begin
                $display(
                    "[TB][ERROR] Unexpected extra Pool2 beat %0d: rtl=%024h",
                    output_index,
                    data_out
                );
                error_count = error_count + 1;
            end
            else if (^data_out === 1'bx) begin
                $display(
                    "[TB][ERROR] Pool2 X/Z at beat=%0d row=%0d col=%0d rtl=%024h",
                    output_index,
                    output_index / 5,
                    output_index % 5,
                    data_out
                );
                error_count = error_count + 1;
            end
            else if (data_out !== golden_mem[output_index]) begin
                if (error_count < 20) begin
                    $display(
                        "[TB][ERROR] Pool2 beat=%0d row=%0d col=%0d rtl=%024h expected=%024h",
                        output_index,
                        output_index / 5,
                        output_index % 5,
                        data_out,
                        golden_mem[output_index]
                    );
                    $display(
                        "            ch0 rtl=%03h exp=%03h | ch1 rtl=%03h exp=%03h | ch2 rtl=%03h exp=%03h | ch3 rtl=%03h exp=%03h",
                        data_out[11:0],  golden_mem[output_index][11:0],
                        data_out[23:12], golden_mem[output_index][23:12],
                        data_out[35:24], golden_mem[output_index][35:24],
                        data_out[47:36], golden_mem[output_index][47:36]
                    );
                    $display(
                        "            ch4 rtl=%03h exp=%03h | ch5 rtl=%03h exp=%03h | ch6 rtl=%03h exp=%03h | ch7 rtl=%03h exp=%03h",
                        data_out[59:48], golden_mem[output_index][59:48],
                        data_out[71:60], golden_mem[output_index][71:60],
                        data_out[83:72], golden_mem[output_index][83:72],
                        data_out[95:84], golden_mem[output_index][95:84]
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
