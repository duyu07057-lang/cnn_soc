`timescale 1ns / 1ps

`ifndef IMAGE_FILE
`define IMAGE_FILE "9_0.txt"
`endif

module tb_axis_cnn_mnist_backpressure;

    localparam integer CLK_PERIOD_NS = 10;
    localparam integer INPUT_BEATS   = 784;
    localparam integer BLOCKED_INPUT_TEST_CYCLES = 10;
    localparam integer OUTPUT_STALL_CYCLES = 37;
    localparam integer MAX_CYCLES = 5000;
    localparam [7:0]   EXPECTED_DATA = 8'h09;

    reg         clk;
    reg         rst_n;
    reg         s_axis_tvalid;
    reg  [7:0]  s_axis_tdata;
    wire        s_axis_tready;
    reg         m_axis_tready;
    wire [7:0]  m_axis_tdata;
    wire        m_axis_tvalid;
    wire        m_axis_tlast;

    reg [7:0] image_mem [0:INPUT_BEATS-1];

    integer input_index;
    integer test_index;
    integer cycle_count;
    integer input_handshakes;
    integer output_handshakes;
    integer error_count;
    integer first_input_cycle;
    integer last_input_cycle;
    integer valid_assert_cycle;
    integer output_handshake_cycle;
    integer ready_return_cycle;
    reg [7:0] held_data;

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
        $display("[TB] Loading image: %s", `IMAGE_FILE);
        $readmemh(`IMAGE_FILE, image_mem);
    end

`ifdef DUMP_VCD
    initial begin
        $dumpfile("tb_axis_cnn_mnist_backpressure.vcd");
        $dumpvars(0, tb_axis_cnn_mnist_backpressure);
    end
`endif

    initial begin
        rst_n                 = 1'b0;
        s_axis_tvalid         = 1'b0;
        s_axis_tdata          = 8'd0;
        m_axis_tready         = 1'b0;
        input_index           = 0;
        test_index            = 0;
        cycle_count           = 0;
        input_handshakes      = 0;
        output_handshakes     = 0;
        error_count           = 0;
        first_input_cycle     = -1;
        last_input_cycle      = -1;
        valid_assert_cycle    = -1;
        output_handshake_cycle = -1;
        ready_return_cycle    = -1;
        held_data             = 8'd0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Send one complete image with normal AXI input handshakes.
        for (input_index = 0; input_index < INPUT_BEATS; input_index = input_index + 1) begin
            @(negedge clk);
            s_axis_tvalid = 1'b1;
            s_axis_tdata  = image_mem[input_index];
            while (s_axis_tready !== 1'b1)
                @(negedge clk);
        end

        // Try to inject dummy pixels while the completed frame is busy.
        // They must not be acknowledged or forwarded to Conv1.
        for (test_index = 0; test_index < BLOCKED_INPUT_TEST_CYCLES; test_index = test_index + 1) begin
            @(negedge clk);
            s_axis_tvalid = 1'b1;
            s_axis_tdata  = 8'hA5;
            if (s_axis_tready !== 1'b0) begin
                $display("[TB][ERROR] s_axis_tready should be low while frame is busy");
                error_count = error_count + 1;
            end
            @(posedge clk);
            #1;
            if (dut.s_axis_tvalid_reg !== 1'b0) begin
                $display("[TB][ERROR] Blocked input was forwarded to Conv1 at cycle=%0d", cycle_count);
                error_count = error_count + 1;
            end
        end

        s_axis_tvalid = 1'b0;
        s_axis_tdata  = 8'd0;

        // Keep the output blocked until the result appears.
        wait (m_axis_tvalid === 1'b1);
        #1;
        valid_assert_cycle = cycle_count;
        held_data = m_axis_tdata;

        if (held_data !== EXPECTED_DATA) begin
            $display("[TB][ERROR] Decision rtl=%02h expected=%02h", held_data, EXPECTED_DATA);
            error_count = error_count + 1;
        end
        if (m_axis_tlast !== 1'b1) begin
            $display("[TB][ERROR] TLAST missing when TVALID asserted");
            error_count = error_count + 1;
        end

        // TVALID, TDATA and TLAST must stay asserted/stable throughout the stall.
        for (test_index = 0; test_index < OUTPUT_STALL_CYCLES; test_index = test_index + 1) begin
            @(posedge clk);
            #1;
            if (m_axis_tvalid !== 1'b1) begin
                $display("[TB][ERROR] TVALID dropped during stall index=%0d", test_index);
                error_count = error_count + 1;
            end
            if (m_axis_tdata !== held_data) begin
                $display("[TB][ERROR] TDATA changed during stall: old=%02h new=%02h", held_data, m_axis_tdata);
                error_count = error_count + 1;
            end
            if (m_axis_tlast !== 1'b1) begin
                $display("[TB][ERROR] TLAST dropped during stall index=%0d", test_index);
                error_count = error_count + 1;
            end
            if (s_axis_tready !== 1'b0) begin
                $display("[TB][ERROR] Input became ready before output handshake");
                error_count = error_count + 1;
            end
        end

        // Release the sink and complete exactly one output handshake.
        @(negedge clk);
        m_axis_tready = 1'b1;
        @(posedge clk);
        #1;

        if (m_axis_tvalid !== 1'b0) begin
            $display("[TB][ERROR] TVALID did not clear after output handshake");
            error_count = error_count + 1;
        end
        if (s_axis_tready !== 1'b1) begin
            $display("[TB][ERROR] Input did not become ready after output handshake");
            error_count = error_count + 1;
        end
        else begin
            ready_return_cycle = cycle_count;
        end

        repeat (10) @(posedge clk);

        if (input_handshakes != INPUT_BEATS) begin
            $display("[TB][ERROR] Input handshakes expected=%0d actual=%0d", INPUT_BEATS, input_handshakes);
            error_count = error_count + 1;
        end
        if (output_handshakes != 1) begin
            $display("[TB][ERROR] Output handshakes expected=1 actual=%0d", output_handshakes);
            error_count = error_count + 1;
        end

        $display("[TB] Input handshakes   : %0d, first=%0d last=%0d", input_handshakes, first_input_cycle, last_input_cycle);
        $display("[TB] Output valid cycle : %0d", valid_assert_cycle);
        $display("[TB] Output handshake   : %0d", output_handshake_cycle);
        $display("[TB] Input ready again  : %0d", ready_return_cycle);
        $display("[TB] Held decision      : %0d", held_data[3:0]);

        if (error_count == 0) begin
            $display("[TB][PASS] AXI output survived %0d stalled cycles with stable data.", OUTPUT_STALL_CYCLES);
            $finish;
        end
        else begin
            $fatal(1, "[TB][FAIL] AXI backpressure errors=%0d", error_count);
        end
    end

    always @(posedge clk) begin
        cycle_count = cycle_count + 1;

        if (rst_n && s_axis_tvalid && s_axis_tready) begin
            input_handshakes = input_handshakes + 1;
            if (first_input_cycle < 0)
                first_input_cycle = cycle_count;
            last_input_cycle = cycle_count;
        end

        if (rst_n && m_axis_tvalid && m_axis_tready) begin
            output_handshakes = output_handshakes + 1;
            output_handshake_cycle = cycle_count;
            if (m_axis_tdata !== EXPECTED_DATA) begin
                $display("[TB][ERROR] Handshake decision rtl=%02h expected=%02h", m_axis_tdata, EXPECTED_DATA);
                error_count = error_count + 1;
            end
            if (m_axis_tlast !== 1'b1) begin
                $display("[TB][ERROR] Handshake occurred without TLAST");
                error_count = error_count + 1;
            end
        end

        if (cycle_count > MAX_CYCLES)
            $fatal(1, "[TB][TIMEOUT] AXI backpressure test exceeded %0d cycles", MAX_CYCLES);
    end

endmodule
