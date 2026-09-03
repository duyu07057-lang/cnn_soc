`timescale 1ns / 1ps

// Override these paths at compile time when required.
`ifndef INPUT_FILE
`define INPUT_FILE "c1_9_bit_exact.mem"
`endif

`ifndef GOLDEN_FILE
`define GOLDEN_FILE "p1_9_bit_exact.mem"
`endif

module tb_pool1;

    localparam integer CLK_PERIOD_NS = 10;
    localparam integer INPUT_BEATS   = 676; // 26 x 26
    localparam integer OUTPUT_BEATS  = 169; // 13 x 13
    localparam integer MAX_CYCLES    = 3000;

    reg         clk;
    reg         rst_n;
    reg         valid_in;
    reg  [47:0] data_in;
    wire [47:0] data_out;
    wire        valid_out_relu;

    reg [47:0] input_mem  [0:INPUT_BEATS-1];
    reg [47:0] golden_mem [0:OUTPUT_BEATS-1];

    integer input_index;
    integer output_index;
    integer error_count;
    integer cycle_count;
    integer first_input_cycle;
    integer last_input_cycle;
    integer first_output_cycle;
    integer last_output_cycle;
    reg     output_done;

    maxpool_relu #(
        .WIDTH     (26),
        .HEIGHT    (26),
        .CHANNELS  (4),
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
        $display("[TB] Loading Pool1 input  : %s", `INPUT_FILE);
        $display("[TB] Loading Pool1 golden : %s", `GOLDEN_FILE);
        $readmemh(`INPUT_FILE, input_mem);
        $readmemh(`GOLDEN_FILE, golden_mem);
    end

`ifdef DUMP_VCD
    initial begin
        $dumpfile("tb_pool1.vcd");
        $dumpvars(0, tb_pool1);
    end
`endif

    initial begin
        rst_n              = 1'b0;
        valid_in           = 1'b0;
        data_in            = 48'd0;
        input_index        = 0;
        output_index       = 0;
        error_count        = 0;
        cycle_count        = 0;
        first_input_cycle  = -1;
        last_input_cycle   = -1;
        first_output_cycle = -1;
        last_output_cycle  = -1;
        output_done        = 1'b0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // This layer has a valid-only input. Drive each word before posedge.
        for (input_index = 0; input_index < INPUT_BEATS; input_index = input_index + 1) begin
            @(negedge clk);
            valid_in = 1'b1;
            data_in  = input_mem[input_index];
        end

        @(negedge clk);
        valid_in = 1'b0;
        data_in  = 48'd0;

        wait (output_done == 1'b1);
        repeat (20) @(posedge clk);

        if (output_index != OUTPUT_BEATS) begin
            $display(
                "[TB][ERROR] Pool1 output count mismatch: expected=%0d actual=%0d",
                OUTPUT_BEATS,
                output_index
            );
            error_count = error_count + 1;
        end

        $display("[TB] Input cycles  : first=%0d last=%0d", first_input_cycle, last_input_cycle);
        $display("[TB] Output cycles : first=%0d last=%0d", first_output_cycle, last_output_cycle);
        $display("[TB] Output beats  : %0d", output_index);

        if (error_count == 0) begin
            $display("[TB][PASS] Pool1 matched all %0d beats x 4 channels.", OUTPUT_BEATS);
            $finish;
        end
        else begin
            $fatal(1, "[TB][FAIL] Pool1 errors=%0d", error_count);
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
            $fatal(1, "[TB][TIMEOUT] No complete Pool1 output within %0d cycles", MAX_CYCLES);
    end

    // Channel 0 is [11:0], channel 3 is [47:36].
    always @(posedge clk) begin
        if (rst_n && valid_out_relu) begin
            if (first_output_cycle < 0)
                first_output_cycle = cycle_count;
            last_output_cycle = cycle_count;

            if (output_index >= OUTPUT_BEATS) begin
                $display(
                    "[TB][ERROR] Unexpected extra Pool1 beat %0d: rtl=%012h",
                    output_index,
                    data_out
                );
                error_count = error_count + 1;
            end
            else if (^data_out === 1'bx) begin
                $display(
                    "[TB][ERROR] Pool1 X/Z at beat=%0d row=%0d col=%0d rtl=%012h",
                    output_index,
                    output_index / 13,
                    output_index % 13,
                    data_out
                );
                error_count = error_count + 1;
            end
            else if (data_out !== golden_mem[output_index]) begin
                if (error_count < 20) begin
                    $display(
                        "[TB][ERROR] Pool1 beat=%0d row=%0d col=%0d rtl=%012h expected=%012h",
                        output_index,
                        output_index / 13,
                        output_index % 13,
                        data_out,
                        golden_mem[output_index]
                    );
                    $display(
                        "            ch0 rtl=%03h exp=%03h | ch1 rtl=%03h exp=%03h | ch2 rtl=%03h exp=%03h | ch3 rtl=%03h exp=%03h",
                        data_out[11:0],   golden_mem[output_index][11:0],
                        data_out[23:12],  golden_mem[output_index][23:12],
                        data_out[35:24],  golden_mem[output_index][35:24],
                        data_out[47:36],  golden_mem[output_index][47:36]
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
