`timescale 1ns / 1ps

`ifndef IMAGE_FILE
`define IMAGE_FILE "9_0.txt"
`endif

`ifndef C1_GOLDEN_FILE
`define C1_GOLDEN_FILE "c1_9_bit_exact.mem"
`endif

`ifndef P1_GOLDEN_FILE
`define P1_GOLDEN_FILE "p1_9_bit_exact.mem"
`endif

`ifndef C2_GOLDEN_FILE
`define C2_GOLDEN_FILE "c2_9_bit_exact.mem"
`endif

`ifndef P2_GOLDEN_FILE
`define P2_GOLDEN_FILE "p2_9_bit_exact.mem"
`endif

`ifndef FC_GOLDEN_FILE
`define FC_GOLDEN_FILE "fc_9_bit_exact.mem"
`endif

module tb_axis_cnn_mnist_e2e;

    localparam integer CLK_PERIOD_NS = 10;
    localparam integer INPUT_BEATS   = 784;
    localparam integer C1_BEATS      = 676;
    localparam integer P1_BEATS      = 169;
    localparam integer C2_BEATS      = 121;
    localparam integer P2_BEATS      = 25;
    localparam integer LOGIT_COUNT   = 10;
    localparam integer MAX_CYCLES    = 5000;
    localparam [3:0]   EXPECTED_DECISION = 4'd9;

    reg         clk;
    reg         rst_n;
    reg         s_axis_tvalid;
    reg  [7:0]  s_axis_tdata;
    wire        s_axis_tready;
    reg         m_axis_tready;
    wire [7:0]  m_axis_tdata;
    wire        m_axis_tvalid;
    wire        m_axis_tlast;

    reg [7:0]  image_mem [0:INPUT_BEATS-1];
    reg [47:0] c1_golden [0:C1_BEATS-1];
    reg [47:0] p1_golden [0:P1_BEATS-1];
    reg [95:0] c2_golden [0:C2_BEATS-1];
    reg [95:0] p2_golden [0:P2_BEATS-1];
    reg [11:0] fc_golden [0:LOGIT_COUNT-1];

    integer input_index;
    integer logit_index;
    integer cycle_count;
    integer input_first_cycle;
    integer input_last_cycle;
    integer c1_first_cycle;
    integer c1_last_cycle;
    integer p1_first_cycle;
    integer p1_last_cycle;
    integer c2_first_cycle;
    integer c2_last_cycle;
    integer p2_first_cycle;
    integer p2_last_cycle;
    integer decision_cycle;
    integer input_count;
    integer c1_count;
    integer p1_count;
    integer c2_count;
    integer p2_count;
    integer decision_count;
    integer c1_errors;
    integer p1_errors;
    integer c2_errors;
    integer p2_errors;
    integer fc_errors;
    integer protocol_errors;
    integer total_errors;
    integer e2e_latency;
    integer tail_cycles;
    reg     output_done;

    axis_cnn_mnist dut (
        .aclk          (clk),
        .aresetn       (rst_n),
        .s_axis_tready (s_axis_tready),
        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tvalid (s_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tlast  (m_axis_tlast)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD_NS / 2) clk = ~clk;
    end

    initial begin
        $display("[TB] Loading image      : %s", `IMAGE_FILE);
        $display("[TB] Loading Conv1 gold : %s", `C1_GOLDEN_FILE);
        $display("[TB] Loading Pool1 gold : %s", `P1_GOLDEN_FILE);
        $display("[TB] Loading Conv2 gold : %s", `C2_GOLDEN_FILE);
        $display("[TB] Loading Pool2 gold : %s", `P2_GOLDEN_FILE);
        $display("[TB] Loading FC gold    : %s", `FC_GOLDEN_FILE);
        $readmemh(`IMAGE_FILE, image_mem);
        $readmemh(`C1_GOLDEN_FILE, c1_golden);
        $readmemh(`P1_GOLDEN_FILE, p1_golden);
        $readmemh(`C2_GOLDEN_FILE, c2_golden);
        $readmemh(`P2_GOLDEN_FILE, p2_golden);
        $readmemh(`FC_GOLDEN_FILE, fc_golden);
    end

`ifdef DUMP_VCD
    initial begin
        $dumpfile("tb_axis_cnn_mnist_e2e.vcd");
        $dumpvars(0, tb_axis_cnn_mnist_e2e);
    end
`endif

    initial begin
        rst_n              = 1'b0;
        s_axis_tvalid      = 1'b0;
        s_axis_tdata       = 8'd0;
        m_axis_tready      = 1'b1;
        input_index        = 0;
        logit_index        = 0;
        cycle_count        = 0;
        input_first_cycle  = -1;
        input_last_cycle   = -1;
        c1_first_cycle     = -1;
        c1_last_cycle      = -1;
        p1_first_cycle     = -1;
        p1_last_cycle      = -1;
        c2_first_cycle     = -1;
        c2_last_cycle      = -1;
        p2_first_cycle     = -1;
        p2_last_cycle      = -1;
        decision_cycle     = -1;
        input_count        = 0;
        c1_count           = 0;
        p1_count           = 0;
        c2_count           = 0;
        p2_count           = 0;
        decision_count     = 0;
        c1_errors          = 0;
        p1_errors          = 0;
        c2_errors          = 0;
        p2_errors          = 0;
        fc_errors          = 0;
        protocol_errors    = 0;
        total_errors       = 0;
        e2e_latency        = -1;
        tail_cycles        = -1;
        output_done        = 1'b0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // AXI-Stream source: hold each pixel until a rising-edge handshake.
        for (input_index = 0; input_index < INPUT_BEATS; input_index = input_index + 1) begin
            @(negedge clk);
            s_axis_tvalid = 1'b1;
            s_axis_tdata  = image_mem[input_index];
            while (s_axis_tready !== 1'b1)
                @(negedge clk);
        end

        @(negedge clk);
        s_axis_tvalid = 1'b0;
        s_axis_tdata  = 8'd0;

        wait (output_done == 1'b1);
        repeat (20) @(posedge clk);

        if (input_count != INPUT_BEATS) begin
            $display("[TB][ERROR] Input count: expected=%0d actual=%0d", INPUT_BEATS, input_count);
            protocol_errors = protocol_errors + 1;
        end
        if (c1_count != C1_BEATS) begin
            $display("[TB][ERROR] Conv1 count: expected=%0d actual=%0d", C1_BEATS, c1_count);
            c1_errors = c1_errors + 1;
        end
        if (p1_count != P1_BEATS) begin
            $display("[TB][ERROR] Pool1 count: expected=%0d actual=%0d", P1_BEATS, p1_count);
            p1_errors = p1_errors + 1;
        end
        if (c2_count != C2_BEATS) begin
            $display("[TB][ERROR] Conv2 count: expected=%0d actual=%0d", C2_BEATS, c2_count);
            c2_errors = c2_errors + 1;
        end
        if (p2_count != P2_BEATS) begin
            $display("[TB][ERROR] Pool2 count: expected=%0d actual=%0d", P2_BEATS, p2_count);
            p2_errors = p2_errors + 1;
        end
        if (decision_count != 1) begin
            $display("[TB][ERROR] Decision count: expected=1 actual=%0d", decision_count);
            fc_errors = fc_errors + 1;
        end

        total_errors = c1_errors + p1_errors + c2_errors + p2_errors + fc_errors + protocol_errors;
        e2e_latency  = decision_cycle - input_first_cycle;
        tail_cycles  = decision_cycle - input_last_cycle;

        $display("[TB] Input    : beats=%0d first=%0d last=%0d", input_count, input_first_cycle, input_last_cycle);
        $display("[TB] Conv1    : beats=%0d first=%0d last=%0d errors=%0d", c1_count, c1_first_cycle, c1_last_cycle, c1_errors);
        $display("[TB] Pool1    : beats=%0d first=%0d last=%0d errors=%0d", p1_count, p1_first_cycle, p1_last_cycle, p1_errors);
        $display("[TB] Conv2    : beats=%0d first=%0d last=%0d errors=%0d", c2_count, c2_first_cycle, c2_last_cycle, c2_errors);
        $display("[TB] Pool2    : beats=%0d first=%0d last=%0d errors=%0d", p2_count, p2_first_cycle, p2_last_cycle, p2_errors);
        $display("[TB] Decision : value=%0d cycle=%0d", m_axis_tdata[3:0], decision_cycle);
        $display("[TB] End-to-end latency : %0d cycles", e2e_latency);
        $display("[TB] Tail after input   : %0d cycles", tail_cycles);

        if (total_errors == 0) begin
            $display("[TB][PASS] End-to-end CNN matched every stage and decision=%0d.", EXPECTED_DECISION);
            $finish;
        end
        else begin
            $fatal(1, "[TB][FAIL] End-to-end errors=%0d", total_errors);
        end
    end

    always @(posedge clk) begin
        cycle_count = cycle_count + 1;

        if (rst_n && s_axis_tvalid && s_axis_tready) begin
            if (input_first_cycle < 0)
                input_first_cycle = cycle_count;
            input_last_cycle = cycle_count;
            input_count = input_count + 1;
        end

        if (cycle_count > MAX_CYCLES && !output_done)
            $fatal(1, "[TB][TIMEOUT] No end-to-end decision within %0d cycles", MAX_CYCLES);
    end

    always @(posedge clk) begin
        if (rst_n && dut.valid_out_conv1) begin
            if (c1_first_cycle < 0)
                c1_first_cycle = cycle_count;
            c1_last_cycle = cycle_count;
            if (c1_count >= C1_BEATS) begin
                $display("[TB][ERROR] Extra Conv1 beat=%0d", c1_count);
                c1_errors = c1_errors + 1;
            end
            else if (^dut.conv1_out === 1'bx) begin
                $display("[TB][ERROR] Conv1 X/Z at beat=%0d", c1_count);
                c1_errors = c1_errors + 1;
            end
            else if (dut.conv1_out !== c1_golden[c1_count]) begin
                if (c1_errors < 10)
                    $display("[TB][ERROR] Conv1 beat=%0d rtl=%012h exp=%012h", c1_count, dut.conv1_out, c1_golden[c1_count]);
                c1_errors = c1_errors + 1;
            end
            c1_count = c1_count + 1;
        end
    end

    always @(posedge clk) begin
        if (rst_n && dut.valid_out_pool1) begin
            if (p1_first_cycle < 0)
                p1_first_cycle = cycle_count;
            p1_last_cycle = cycle_count;
            if (p1_count >= P1_BEATS) begin
                $display("[TB][ERROR] Extra Pool1 beat=%0d", p1_count);
                p1_errors = p1_errors + 1;
            end
            else if (^dut.pool1_out === 1'bx) begin
                $display("[TB][ERROR] Pool1 X/Z at beat=%0d", p1_count);
                p1_errors = p1_errors + 1;
            end
            else if (dut.pool1_out !== p1_golden[p1_count]) begin
                if (p1_errors < 10)
                    $display("[TB][ERROR] Pool1 beat=%0d rtl=%012h exp=%012h", p1_count, dut.pool1_out, p1_golden[p1_count]);
                p1_errors = p1_errors + 1;
            end
            p1_count = p1_count + 1;
        end
    end

    always @(posedge clk) begin
        if (rst_n && dut.valid_out_conv2) begin
            if (c2_first_cycle < 0)
                c2_first_cycle = cycle_count;
            c2_last_cycle = cycle_count;
            if (c2_count >= C2_BEATS) begin
                $display("[TB][ERROR] Extra Conv2 beat=%0d", c2_count);
                c2_errors = c2_errors + 1;
            end
            else if (^dut.conv2_out === 1'bx) begin
                $display("[TB][ERROR] Conv2 X/Z at beat=%0d", c2_count);
                c2_errors = c2_errors + 1;
            end
            else if (dut.conv2_out !== c2_golden[c2_count]) begin
                if (c2_errors < 10)
                    $display("[TB][ERROR] Conv2 beat=%0d rtl=%024h exp=%024h", c2_count, dut.conv2_out, c2_golden[c2_count]);
                c2_errors = c2_errors + 1;
            end
            c2_count = c2_count + 1;
        end
    end

    always @(posedge clk) begin
        if (rst_n && dut.valid_out_pool2) begin
            if (p2_first_cycle < 0)
                p2_first_cycle = cycle_count;
            p2_last_cycle = cycle_count;
            if (p2_count >= P2_BEATS) begin
                $display("[TB][ERROR] Extra Pool2 beat=%0d", p2_count);
                p2_errors = p2_errors + 1;
            end
            else if (^dut.pool2_out === 1'bx) begin
                $display("[TB][ERROR] Pool2 X/Z at beat=%0d", p2_count);
                p2_errors = p2_errors + 1;
            end
            else if (dut.pool2_out !== p2_golden[p2_count]) begin
                if (p2_errors < 10)
                    $display("[TB][ERROR] Pool2 beat=%0d rtl=%024h exp=%024h", p2_count, dut.pool2_out, p2_golden[p2_count]);
                p2_errors = p2_errors + 1;
            end
            p2_count = p2_count + 1;
        end
    end

    always @(posedge clk) begin
        if (rst_n && m_axis_tvalid) begin
            if (decision_count == 0)
                decision_cycle = cycle_count;
            else begin
                $display("[TB][ERROR] Extra decision at cycle=%0d", cycle_count);
                fc_errors = fc_errors + 1;
            end

            if (m_axis_tready !== 1'b1) begin
                $display("[TB][ERROR] Output valid without a ready handshake");
                protocol_errors = protocol_errors + 1;
            end
            if (m_axis_tlast !== 1'b1) begin
                $display("[TB][ERROR] m_axis_tlast was not asserted with decision");
                protocol_errors = protocol_errors + 1;
            end
            if (^m_axis_tdata === 1'bx) begin
                $display("[TB][ERROR] Decision contains X/Z");
                fc_errors = fc_errors + 1;
            end
            else if (m_axis_tdata !== {4'd0, EXPECTED_DECISION}) begin
                $display("[TB][ERROR] Decision rtl=%02h expected=%02h", m_axis_tdata, {4'd0, EXPECTED_DECISION});
                fc_errors = fc_errors + 1;
            end

            for (logit_index = 0; logit_index < LOGIT_COUNT; logit_index = logit_index + 1) begin
                if (^dut.u_fc.logits[logit_index] === 1'bx) begin
                    $display("[TB][ERROR] FC logit[%0d] contains X/Z", logit_index);
                    fc_errors = fc_errors + 1;
                end
                else if (dut.u_fc.logits[logit_index] !== fc_golden[logit_index]) begin
                    $display(
                        "[TB][ERROR] FC logit[%0d] rtl=%03h exp=%03h",
                        logit_index,
                        dut.u_fc.logits[logit_index],
                        fc_golden[logit_index]
                    );
                    fc_errors = fc_errors + 1;
                end
            end

            decision_count = decision_count + 1;
            output_done = 1'b1;
        end
    end

endmodule
