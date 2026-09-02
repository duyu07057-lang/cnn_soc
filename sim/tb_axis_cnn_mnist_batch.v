`timescale 1ns / 1ps

`ifndef IMAGE_BATCH_FILE
`define IMAGE_BATCH_FILE "input_1000.txt"
`endif

`ifndef DECISION_GOLDEN_FILE
`define DECISION_GOLDEN_FILE "decision_1000_bit_exact.mem"
`endif

`ifndef LOGITS_GOLDEN_FILE
`define LOGITS_GOLDEN_FILE "fc_logits_1000_bit_exact.mem"
`endif

`ifndef LABEL_FILE
`define LABEL_FILE "labels_1000_cyclic.mem"
`endif

// Use 10 for a quick smoke test, then change to 1000 for the full regression.
`ifndef RUN_IMAGES
`define RUN_IMAGES 1000
`endif

module tb_axis_cnn_mnist_batch;

    localparam integer CLK_PERIOD_NS   = 10;
    localparam integer TOTAL_IMAGES    = 1000;
    localparam integer PIXELS_PER_IMAGE = 784;
    localparam integer TOTAL_PIXELS    = TOTAL_IMAGES * PIXELS_PER_IMAGE;
    localparam integer RUN_IMAGE_COUNT = `RUN_IMAGES;
    localparam integer MAX_CYCLES      = 2000000;

    reg         clk;
    reg         rst_n;
    reg         s_axis_tvalid;
    reg  [7:0]  s_axis_tdata;
    wire        s_axis_tready;
    reg         m_axis_tready;
    wire [7:0]  m_axis_tdata;
    wire        m_axis_tvalid;
    wire        m_axis_tlast;

    reg [7:0]   image_mem          [0:TOTAL_PIXELS-1];
    reg [3:0]   decision_golden    [0:TOTAL_IMAGES-1];
    reg [119:0] logits_golden      [0:TOTAL_IMAGES-1];
    reg [3:0]   label_mem          [0:TOTAL_IMAGES-1];

    wire [119:0] dut_logits_packed = {
        dut.u_fc.logits[9], dut.u_fc.logits[8],
        dut.u_fc.logits[7], dut.u_fc.logits[6],
        dut.u_fc.logits[5], dut.u_fc.logits[4],
        dut.u_fc.logits[3], dut.u_fc.logits[2],
        dut.u_fc.logits[1], dut.u_fc.logits[0]
    };

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
        $display("[TB] Loading image batch      : %s", `IMAGE_BATCH_FILE);
        $display("[TB] Loading decision golden : %s", `DECISION_GOLDEN_FILE);
        $display("[TB] Loading logits golden   : %s", `LOGITS_GOLDEN_FILE);
        $display("[TB] Loading labels          : %s", `LABEL_FILE);
        $readmemh(`IMAGE_BATCH_FILE, image_mem);
        $readmemh(`DECISION_GOLDEN_FILE, decision_golden);
        $readmemh(`LOGITS_GOLDEN_FILE, logits_golden);
        $readmemh(`LABEL_FILE, label_mem);
    end

`ifdef DUMP_VCD
    initial begin
        $dumpfile("tb_axis_cnn_mnist_batch.vcd");
        $dumpvars(0, tb_axis_cnn_mnist_batch);
    end
`endif

    initial begin
        if (RUN_IMAGE_COUNT < 1 || RUN_IMAGE_COUNT > TOTAL_IMAGES)
            $fatal(1, "[TB] RUN_IMAGES must be between 1 and %0d", TOTAL_IMAGES);

        rst_n                  = 1'b0;
        s_axis_tvalid          = 1'b0;
        s_axis_tdata           = 8'd0;
        m_axis_tready          = 1'b1;
        image_index            = 0;
        pixel_index            = 0;
        cycle_count            = 0;
        input_handshakes       = 0;
        input_stall_cycles     = 0;
        result_count           = 0;
        model_match_count      = 0;
        correct_count          = 0;
        error_count            = 0;
        first_input_cycle      = -1;
        last_input_cycle       = -1;
        first_result_cycle     = -1;
        last_result_cycle      = -1;
        previous_result_cycle  = -1;
        current_interval       = 0;
        min_result_interval    = MAX_CYCLES;
        max_result_interval    = 0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // The safe baseline permits one frame in flight. Send the next frame
        // only after the preceding result has completed its output handshake.
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
                "[TB][ERROR] Input handshakes expected=%0d actual=%0d",
                RUN_IMAGE_COUNT * PIXELS_PER_IMAGE,
                input_handshakes
            );
            error_count = error_count + 1;
        end
        if (result_count != RUN_IMAGE_COUNT) begin
            $display("[TB][ERROR] Results expected=%0d actual=%0d", RUN_IMAGE_COUNT, result_count);
            error_count = error_count + 1;
        end
        if (model_match_count != RUN_IMAGE_COUNT) begin
            $display(
                "[TB][ERROR] Model matches expected=%0d actual=%0d",
                RUN_IMAGE_COUNT,
                model_match_count
            );
            error_count = error_count + 1;
        end

        $display("[TB] Images tested       : %0d", RUN_IMAGE_COUNT);
        $display("[TB] Input handshakes    : %0d", input_handshakes);
        $display("[TB] Input stall cycles  : %0d", input_stall_cycles);
        $display("[TB] RTL/model matches   : %0d/%0d", model_match_count, RUN_IMAGE_COUNT);
        $display("[TB] Classification      : %0d/%0d", correct_count, RUN_IMAGE_COUNT);
        $display("[TB] First input cycle   : %0d", first_input_cycle);
        $display("[TB] Last input cycle    : %0d", last_input_cycle);
        $display("[TB] First result cycle  : %0d", first_result_cycle);
        $display("[TB] Last result cycle   : %0d", last_result_cycle);
        if (RUN_IMAGE_COUNT > 1) begin
            $display("[TB] Min result interval : %0d cycles", min_result_interval);
            $display("[TB] Max result interval : %0d cycles", max_result_interval);
        end

        if (error_count == 0) begin
            $display("[TB][PASS] Batch RTL matched the bit-exact model for all %0d images.", RUN_IMAGE_COUNT);
            $finish;
        end
        else begin
            $fatal(1, "[TB][FAIL] Batch errors=%0d", error_count);
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
                $display("[TB][ERROR] Unexpected extra result at cycle=%0d", cycle_count);
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
                    $display("[TB][ERROR] Decision X/Z at image=%0d", result_count);
                    error_count = error_count + 1;
                end
                else begin
                    if (m_axis_tdata[7:4] !== 4'd0) begin
                        $display("[TB][ERROR] Decision upper bits nonzero at image=%0d", result_count);
                        error_count = error_count + 1;
                    end
                    if (m_axis_tdata[3:0] == label_mem[result_count])
                        correct_count = correct_count + 1;
                end

                if (m_axis_tlast !== 1'b1) begin
                    $display("[TB][ERROR] TLAST missing at image=%0d", result_count);
                    error_count = error_count + 1;
                end

                if (
                    m_axis_tdata[3:0] === decision_golden[result_count] &&
                    dut_logits_packed === logits_golden[result_count]
                ) begin
                    model_match_count = model_match_count + 1;
                end
                else begin
                    if (error_count < 20) begin
                        $display(
                            "[TB][ERROR] Image=%0d decision rtl=%0d exp=%0d",
                            result_count,
                            m_axis_tdata[3:0],
                            decision_golden[result_count]
                        );
                        if (dut_logits_packed !== logits_golden[result_count])
                            $display(
                                "            logits rtl=%030h exp=%030h",
                                dut_logits_packed,
                                logits_golden[result_count]
                            );
                    end
                    error_count = error_count + 1;
                end

                if (result_count < 10 || (result_count + 1) % 100 == 0) begin
                    $display(
                        "[TB] image=%0d decision=%0d label=%0d cycle=%0d",
                        result_count,
                        m_axis_tdata[3:0],
                        label_mem[result_count],
                        cycle_count
                    );
                end
            end

            result_count = result_count + 1;
        end

        if (cycle_count > MAX_CYCLES)
            $fatal(1, "[TB][TIMEOUT] Batch test exceeded %0d cycles", MAX_CYCLES);
    end

endmodule
