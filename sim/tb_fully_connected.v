`timescale 1ns / 1ps

// Pool2 output is the FC input. Channel 0 occupies bits [11:0].
// Override these paths at compile time when required.
`ifndef INPUT_FILE
`define INPUT_FILE "p2_9_bit_exact.mem"
`endif

`ifndef GOLDEN_FILE
`define GOLDEN_FILE "fc_9_bit_exact.mem"
`endif

module tb_fully_connected;

    localparam integer CLK_PERIOD_NS    = 10;
    localparam integer INPUT_BEATS      = 25; // 5 x 5 x 8 channels
    localparam integer LOGIT_COUNT      = 10;
    localparam integer MAX_CYCLES       = 2000;
    localparam [3:0]   EXPECTED_DECISION = 4'd9;

    reg         clk;
    reg         rst_n;
    reg         valid_in;
    reg  [95:0] data_in;
    wire [3:0]  decision;
    wire        valid_out_fc;

    reg [95:0] input_mem  [0:INPUT_BEATS-1];
    reg [11:0] golden_mem [0:LOGIT_COUNT-1];

    integer input_index;
    integer logit_index;
    integer decision_count;
    integer error_count;
    integer cycle_count;
    integer first_input_cycle;
    integer last_input_cycle;
    integer decision_cycle;
    integer first_out_latency;
    integer tail_cycles;
    reg     output_done;

    fully_connected dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .valid_in     (valid_in),
        .data_in      (data_in),
        .decision     (decision),
        .valid_out_fc (valid_out_fc)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD_NS / 2) clk = ~clk;
    end

    initial begin
        $display("[TB] Loading FC input  : %s", `INPUT_FILE);
        $display("[TB] Loading FC golden : %s", `GOLDEN_FILE);
        $readmemh(`INPUT_FILE, input_mem);
        $readmemh(`GOLDEN_FILE, golden_mem);
    end

`ifdef DUMP_VCD
    initial begin
        $dumpfile("tb_fully_connected.vcd");
        $dumpvars(0, tb_fully_connected);
    end
`endif

    initial begin
        rst_n              = 1'b0;
        valid_in           = 1'b0;
        data_in            = 96'd0;
        input_index        = 0;
        logit_index        = 0;
        decision_count     = 0;
        error_count        = 0;
        cycle_count        = 0;
        first_input_cycle  = -1;
        last_input_cycle   = -1;
        decision_cycle     = -1;
        first_out_latency  = -1;
        tail_cycles        = -1;
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
        valid_in = 1'b0;
        data_in  = 96'd0;

        wait (output_done == 1'b1);
        repeat (20) @(posedge clk);

        if (decision_count != 1) begin
            $display(
                "[TB][ERROR] FC decision count mismatch: expected=1 actual=%0d",
                decision_count
            );
            error_count = error_count + 1;
        end

        first_out_latency = decision_cycle - first_input_cycle;
        tail_cycles       = decision_cycle - last_input_cycle;

        $display("[TB] Input cycles       : first=%0d last=%0d", first_input_cycle, last_input_cycle);
        $display("[TB] Decision cycle     : %0d", decision_cycle);
        $display("[TB] First-out latency  : %0d cycles", first_out_latency);
        $display("[TB] Tail after input   : %0d cycles", tail_cycles);
        $display("[TB] Decision           : %0d", decision);

        if (error_count == 0) begin
            $display("[TB][PASS] FC matched all 10 logits and decision=%0d.", EXPECTED_DECISION);
            $finish;
        end
        else begin
            $fatal(1, "[TB][FAIL] FC errors=%0d", error_count);
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
            $fatal(1, "[TB][TIMEOUT] No FC decision within %0d cycles", MAX_CYCLES);
    end

    // Besides the public decision, inspect all ten internal logits in simulation.
    always @(posedge clk) begin
        if (rst_n && valid_out_fc) begin
            if (decision_count == 0)
                decision_cycle = cycle_count;
            else begin
                $display(
                    "[TB][ERROR] Unexpected extra FC decision at cycle=%0d value=%0d",
                    cycle_count,
                    decision
                );
                error_count = error_count + 1;
            end

            if (^decision === 1'bx) begin
                $display("[TB][ERROR] FC decision contains X/Z");
                error_count = error_count + 1;
            end
            else if (decision !== EXPECTED_DECISION) begin
                $display(
                    "[TB][ERROR] FC decision mismatch: rtl=%0d expected=%0d",
                    decision,
                    EXPECTED_DECISION
                );
                error_count = error_count + 1;
            end

            for (logit_index = 0; logit_index < LOGIT_COUNT; logit_index = logit_index + 1) begin
                if (^dut.logits[logit_index] === 1'bx) begin
                    $display("[TB][ERROR] FC logit[%0d] contains X/Z", logit_index);
                    error_count = error_count + 1;
                end
                else if (dut.logits[logit_index] !== golden_mem[logit_index]) begin
                    $display(
                        "[TB][ERROR] FC logit[%0d] rtl=%03h expected=%03h",
                        logit_index,
                        dut.logits[logit_index],
                        golden_mem[logit_index]
                    );
                    error_count = error_count + 1;
                end
                else begin
                    $display(
                        "[TB] logit[%0d] = %03h",
                        logit_index,
                        dut.logits[logit_index]
                    );
                end
            end

            decision_count = decision_count + 1;
            output_done = 1'b1;
        end
    end

endmodule
