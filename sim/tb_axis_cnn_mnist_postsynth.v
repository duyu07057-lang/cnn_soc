`timescale 1ns / 1ps

`ifndef POSTSYNTH_IMAGE_BATCH_FILE
`define POSTSYNTH_IMAGE_BATCH_FILE "input_1000.txt"
`endif

`ifndef POSTSYNTH_DECISION_FILE
`define POSTSYNTH_DECISION_FILE "decision_1000_bit_exact.mem"
`endif

`ifndef POSTSYNTH_LABEL_FILE
`define POSTSYNTH_LABEL_FILE "labels_1000_cyclic.mem"
`endif

// Ten images are enough to detect missing/trimmed parameters in the netlist.
// Increase this only after the short post-synthesis regression passes.
`ifndef POSTSYNTH_RUN_IMAGES
`define POSTSYNTH_RUN_IMAGES 10
`endif

module tb_axis_cnn_mnist_postsynth;

    localparam integer CLK_PERIOD_NS    = 10;
    localparam integer TOTAL_IMAGES     = 1000;
    localparam integer PIXELS_PER_IMAGE = 784;
    localparam integer TOTAL_PIXELS     = TOTAL_IMAGES * PIXELS_PER_IMAGE;
    localparam integer RUN_IMAGE_COUNT  = `POSTSYNTH_RUN_IMAGES;
    localparam integer MAX_CYCLES       = 2000000;

    reg         clk;
    reg         rst_n;
    reg         s_axis_tvalid;
    reg  [7:0]  s_axis_tdata;
    wire        s_axis_tready;
    reg         m_axis_tready;
    wire [7:0]  m_axis_tdata;
    wire        m_axis_tvalid;
    wire        m_axis_tlast;

    reg [7:0] image_mem       [0:TOTAL_PIXELS-1];
    reg [3:0] decision_golden [0:TOTAL_IMAGES-1];
    reg [3:0] label_mem       [0:TOTAL_IMAGES-1];

    integer image_index;
    integer pixel_index;
    integer cycle_count;
    integer input_handshakes;
    integer input_stall_cycles;
    integer result_count;
    integer model_match_count;
    integer correct_count;
    integer error_count;
    integer first_input_cycle;
    integer last_input_cycle;
    integer first_result_cycle;
    integer last_result_cycle;
    integer previous_result_cycle;
    integer current_interval;
    integer min_result_interval;
    integer max_result_interval;

    // Port-only instantiation: this testbench remains compatible with the
    // synthesized structural netlist and does not inspect RTL hierarchy.
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
        $display("[TB-POST] Loading image batch     : %s", `POSTSYNTH_IMAGE_BATCH_FILE);
        $display("[TB-POST] Loading decision golden: %s", `POSTSYNTH_DECISION_FILE);
        $display("[TB-POST] Loading labels         : %s", `POSTSYNTH_LABEL_FILE);
        $readmemh(`POSTSYNTH_IMAGE_BATCH_FILE, image_mem);
        $readmemh(`POSTSYNTH_DECISION_FILE, decision_golden);
        $readmemh(`POSTSYNTH_LABEL_FILE, label_mem);
    end

    initial begin
        if (RUN_IMAGE_COUNT < 1 || RUN_IMAGE_COUNT > TOTAL_IMAGES)
            $fatal(1, "[TB-POST] POSTSYNTH_RUN_IMAGES must be between 1 and %0d", TOTAL_IMAGES);

        rst_n                 = 1'b0;
        s_axis_tvalid         = 1'b0;
        s_axis_tdata          = 8'd0;
        m_axis_tready         = 1'b1;
        image_index           = 0;
        pixel_index           = 0;
        cycle_count           = 0;
        input_handshakes      = 0;
        input_stall_cycles    = 0;
        result_count          = 0;
        model_match_count     = 0;
        correct_count         = 0;
        error_count           = 0;
        first_input_cycle     = -1;
        last_input_cycle      = -1;
        first_result_cycle    = -1;
        last_result_cycle     = -1;
        previous_result_cycle = -1;
        current_interval      = 0;
        min_result_interval   = MAX_CYCLES;
        max_result_interval   = 0;

        // Vivado netlist simulation normally keeps glbl.GSR asserted for about
        // 100 ns. Hold the explicit reset beyond that interval so no input
        // handshake occurs while the synthesized registers are still in GSR.
        repeat (20) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // The current safe top level permits one complete frame in flight.
        for (image_index = 0; image_index < RUN_IMAGE_COUNT; image_index = image_index + 1) begin
            for (pixel_index = 0; pixel_index < PIXELS_PER_IMAGE; pixel_index = pixel_index + 1) begin
                @(negedge clk);
                s_axis_tvalid = 1'b1;
                s_axis_tdata = image_mem[image_index * PIXELS_PER_IMAGE + pixel_index];
                while (s_axis_tready !== 1'b1)
                    @(negedge clk);
            end

            @(negedge clk);
            s_axis_tvalid = 1'b0;
            s_axis_tdata = 8'd0;

            wait (result_count >= image_index + 1);
            wait (s_axis_tready === 1'b1);
        end

        repeat (20) @(posedge clk);

        if (input_handshakes != RUN_IMAGE_COUNT * PIXELS_PER_IMAGE) begin
            $display(
                "[TB-POST][ERROR] Input handshakes expected=%0d actual=%0d",
                RUN_IMAGE_COUNT * PIXELS_PER_IMAGE,
                input_handshakes
            );
            error_count = error_count + 1;
        end
        if (result_count != RUN_IMAGE_COUNT) begin
            $display("[TB-POST][ERROR] Results expected=%0d actual=%0d", RUN_IMAGE_COUNT, result_count);
            error_count = error_count + 1;
        end
        if (model_match_count != RUN_IMAGE_COUNT) begin
            $display(
                "[TB-POST][ERROR] Model matches expected=%0d actual=%0d",
                RUN_IMAGE_COUNT,
                model_match_count
            );
            error_count = error_count + 1;
        end

        $display("[TB-POST] Images tested       : %0d", RUN_IMAGE_COUNT);
        $display("[TB-POST] Input handshakes    : %0d", input_handshakes);
        $display("[TB-POST] Input stall cycles  : %0d", input_stall_cycles);
        $display("[TB-POST] RTL/model matches   : %0d/%0d", model_match_count, RUN_IMAGE_COUNT);
        $display("[TB-POST] Classification      : %0d/%0d", correct_count, RUN_IMAGE_COUNT);
        $display("[TB-POST] First input cycle   : %0d", first_input_cycle);
        $display("[TB-POST] Last input cycle    : %0d", last_input_cycle);
        $display("[TB-POST] First result cycle  : %0d", first_result_cycle);
        $display("[TB-POST] Last result cycle   : %0d", last_result_cycle);
        if (RUN_IMAGE_COUNT > 1) begin
            $display("[TB-POST] Min result interval : %0d cycles", min_result_interval);
            $display("[TB-POST] Max result interval : %0d cycles", max_result_interval);
        end

        if (error_count == 0) begin
            $display(
                "[TB-POST][PASS] Synthesized netlist matched all %0d expected decisions.",
                RUN_IMAGE_COUNT
            );
            $finish;
        end
        else begin
            $fatal(1, "[TB-POST][FAIL] Post-synthesis errors=%0d", error_count);
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
        else if (rst_n && s_axis_tvalid && !s_axis_tready) begin
            input_stall_cycles = input_stall_cycles + 1;
        end

        if (rst_n && m_axis_tvalid && m_axis_tready) begin
            if (result_count >= RUN_IMAGE_COUNT) begin
                $display("[TB-POST][ERROR] Unexpected extra result at cycle=%0d", cycle_count);
                error_count = error_count + 1;
            end
            else begin
                if (first_result_cycle < 0)
                    first_result_cycle = cycle_count;
                last_result_cycle = cycle_count;

                if (previous_result_cycle >= 0) begin
                    current_interval = cycle_count - previous_result_cycle;
                    if (current_interval < min_result_interval)
                        min_result_interval = current_interval;
                    if (current_interval > max_result_interval)
                        max_result_interval = current_interval;
                end
                previous_result_cycle = cycle_count;

                if (^m_axis_tdata === 1'bx) begin
                    $display("[TB-POST][ERROR] Decision X/Z at image=%0d", result_count);
                    error_count = error_count + 1;
                end
                else begin
                    if (m_axis_tdata[7:4] !== 4'd0) begin
                        $display("[TB-POST][ERROR] Decision upper bits nonzero at image=%0d", result_count);
                        error_count = error_count + 1;
                    end

                    if (m_axis_tdata[3:0] === decision_golden[result_count])
                        model_match_count = model_match_count + 1;
                    else begin
                        $display(
                            "[TB-POST][ERROR] Image=%0d decision netlist=%0d expected=%0d",
                            result_count,
                            m_axis_tdata[3:0],
                            decision_golden[result_count]
                        );
                        error_count = error_count + 1;
                    end

                    if (m_axis_tdata[3:0] == label_mem[result_count])
                        correct_count = correct_count + 1;
                end

                if (m_axis_tlast !== 1'b1) begin
                    $display("[TB-POST][ERROR] TLAST missing at image=%0d", result_count);
                    error_count = error_count + 1;
                end

                $display(
                    "[TB-POST] image=%0d decision=%0d expected=%0d label=%0d cycle=%0d",
                    result_count,
                    m_axis_tdata[3:0],
                    decision_golden[result_count],
                    label_mem[result_count],
                    cycle_count
                );
            end

            result_count = result_count + 1;
        end

        if (cycle_count > MAX_CYCLES)
            $fatal(1, "[TB-POST][TIMEOUT] Test exceeded %0d cycles", MAX_CYCLES);
    end

endmodule
