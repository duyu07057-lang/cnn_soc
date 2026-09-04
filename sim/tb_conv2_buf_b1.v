`timescale 1ns / 1ps

// Self-checking B1 line/window-buffer test.
// Drives two 13x13 frames with the fastest cadence produced by the existing
// Conv1+Pool1 pipeline: two cycles between pixels and 56 cycles between row
// starts.  The calc_busy model matches the current two-group Conv2 scheduler.
module tb_conv2_buf_b1;

    localparam CLK_PERIOD_NS     = 10;
    localparam WIDTH             = 13;
    localparam HEIGHT            = 13;
    localparam CHANNELS          = 4;
    localparam DATA_BITS         = 12;
    localparam INPUT_BEATS       = WIDTH * HEIGHT;
    localparam OUTPUT_WIDTH      = WIDTH - 2;
    localparam OUTPUT_HEIGHT     = HEIGHT - 2;
    localparam WINDOWS_PER_FRAME = OUTPUT_WIDTH * OUTPUT_HEIGHT;
    localparam TEST_FRAMES       = 2;
    localparam MAX_CYCLES        = 5000;

    reg         clk;
    reg         rst_n;
    reg         valid_in;
    reg  [47:0] data_in;
    reg         calc_busy;

    wire [47:0] data_out_0;
    wire [47:0] data_out_1;
    wire [47:0] data_out_2;
    wire [47:0] data_out_3;
    wire [47:0] data_out_4;
    wire [47:0] data_out_5;
    wire [47:0] data_out_6;
    wire [47:0] data_out_7;
    wire [47:0] data_out_8;
    wire        valid_out_buf;

    integer cycle_count;
    integer busy_cycles_left;
    integer total_windows;
    integer error_count;
    integer expected_frame;
    integer expected_window;
    integer expected_row;
    integer expected_col;
    integer expected_base;
    integer max_fifo_count;
    reg     previous_valid;

    conv2_buf #(
        .WIDTH     (WIDTH),
        .HEIGHT    (HEIGHT),
        .CHANNELS  (CHANNELS),
        .DATA_BITS (DATA_BITS)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .valid_in      (valid_in),
        .data_in       (data_in),
        .calc_busy     (calc_busy),
        .data_out_0    (data_out_0),
        .data_out_1    (data_out_1),
        .data_out_2    (data_out_2),
        .data_out_3    (data_out_3),
        .data_out_4    (data_out_4),
        .data_out_5    (data_out_5),
        .data_out_6    (data_out_6),
        .data_out_7    (data_out_7),
        .data_out_8    (data_out_8),
        .valid_out_buf (valid_out_buf)
    );

    function [47:0] make_word;
        input integer frame_id;
        input integer pixel_id;
        reg [11:0] ch0;
        reg [11:0] ch1;
        reg [11:0] ch2;
        reg [11:0] ch3;
        begin
            ch0 = frame_id * 12'd512 + pixel_id;
            ch1 = frame_id * 12'd512 + pixel_id + 12'd256;
            ch2 = frame_id * 12'd512 + pixel_id + 12'd512;
            ch3 = frame_id * 12'd512 + pixel_id + 12'd768;
            make_word = {ch3, ch2, ch1, ch0};
        end
    endfunction

    task send_frame_at_pool1_cadence;
        input integer frame_id;
        integer row;
        integer col;
        integer pixel;
        begin
            // The current top level starts a new image only after the preceding
            // classification result has completed.  Reproduce that safe point.
            wait ((dut.fifo_count == 0) &&
                  (dut.reader_state == 2'd0) &&
                  (calc_busy == 1'b0) &&
                  (valid_out_buf == 1'b0));

            pixel = 0;
            for (row = 0; row < HEIGHT; row = row + 1) begin
                for (col = 0; col < WIDTH; col = col + 1) begin
                    @(negedge clk);
                    valid_in = 1'b1;
                    data_in  = make_word(frame_id, pixel);
                    pixel    = pixel + 1;

                    // Pool1 outputs are two cycles apart inside a row.
                    @(negedge clk);
                    valid_in = 1'b0;
                    data_in  = 48'd0;
                end

                // Last valid of one row to first valid of the next is 32
                // cycles, yielding a 56-cycle row-start interval.
                if (row != HEIGHT - 1)
                    repeat (30) @(negedge clk);
            end

            if (pixel != INPUT_BEATS) begin
                $display("[TB][ERROR] Input count expected=%0d actual=%0d", INPUT_BEATS, pixel);
                error_count = error_count + 1;
            end
        end
    endtask

    task check_one;
        input [47:0] actual;
        input [47:0] expected;
        input integer tap;
        begin
            if (^actual === 1'bx) begin
                $display(
                    "[TB][ERROR] X/Z frame=%0d window=%0d tap=%0d actual=%012h",
                    expected_frame, expected_window, tap, actual
                );
                error_count = error_count + 1;
            end
            else if (actual !== expected) begin
                $display(
                    "[TB][ERROR] Mismatch frame=%0d window=%0d row=%0d col=%0d tap=%0d actual=%012h expected=%012h",
                    expected_frame, expected_window, expected_row, expected_col,
                    tap, actual, expected
                );
                error_count = error_count + 1;
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD_NS / 2) clk = ~clk;
    end

    initial begin
        rst_n            = 1'b0;
        valid_in         = 1'b0;
        data_in          = 48'd0;
        calc_busy        = 1'b0;
        cycle_count      = 0;
        busy_cycles_left = 0;
        total_windows    = 0;
        error_count      = 0;
        max_fifo_count   = 0;
        previous_valid   = 1'b0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        send_frame_at_pool1_cadence(0);
        wait (total_windows == WINDOWS_PER_FRAME);
        wait ((dut.fifo_count == 0) &&
              (dut.reader_state == 2'd0) &&
              (calc_busy == 1'b0));
        repeat (5) @(posedge clk);

        send_frame_at_pool1_cadence(1);
        wait (total_windows == TEST_FRAMES * WINDOWS_PER_FRAME);
        wait ((dut.fifo_count == 0) &&
              (dut.reader_state == 2'd0) &&
              (calc_busy == 1'b0));
        repeat (10) @(posedge clk);

        if (total_windows != TEST_FRAMES * WINDOWS_PER_FRAME) begin
            $display(
                "[TB][ERROR] Window count expected=%0d actual=%0d",
                TEST_FRAMES * WINDOWS_PER_FRAME, total_windows
            );
            error_count = error_count + 1;
        end

        if (max_fifo_count > 8) begin
            $display("[TB][ERROR] FIFO occupancy exceeded depth: %0d", max_fifo_count);
            error_count = error_count + 1;
        end

        if (error_count == 0) begin
            $display(
                "[TB][PASS] B1 line/window buffer produced %0d correct windows; max FIFO occupancy=%0d/8.",
                total_windows, max_fifo_count
            );
            $finish;
        end
        else begin
            $fatal(1, "[TB][FAIL] B1 errors=%0d", error_count);
        end
    end

    // Current conv2_calc keeps calc_busy high for two processing cycles after
    // accepting a window: group 0, then group 1.
    always @(posedge clk) begin
        if (!rst_n) begin
            calc_busy        <= 1'b0;
            busy_cycles_left <= 0;
        end
        else if (valid_out_buf) begin
            calc_busy        <= 1'b1;
            busy_cycles_left <= 1;
        end
        else if (calc_busy) begin
            if (busy_cycles_left == 0)
                calc_busy <= 1'b0;
            else
                busy_cycles_left <= busy_cycles_left - 1;
        end
    end

    always @(posedge clk) begin
        cycle_count = cycle_count + 1;

        if (cycle_count > MAX_CYCLES)
            $fatal(1, "[TB][TIMEOUT] B1 test exceeded %0d cycles", MAX_CYCLES);

        if (!rst_n) begin
            previous_valid = 1'b0;
        end
        else begin
            if (dut.fifo_count > max_fifo_count)
                max_fifo_count = dut.fifo_count;

            if (valid_out_buf && previous_valid) begin
                $display("[TB][ERROR] valid_out_buf stayed high for more than one cycle");
                error_count = error_count + 1;
            end
            previous_valid = valid_out_buf;

            if (valid_out_buf) begin
                if (calc_busy) begin
                    $display("[TB][ERROR] Window emitted while calc_busy was high");
                    error_count = error_count + 1;
                end

                if (total_windows >= TEST_FRAMES * WINDOWS_PER_FRAME) begin
                    $display("[TB][ERROR] Unexpected extra window %0d", total_windows);
                    error_count = error_count + 1;
                end
                else begin
                    expected_frame  = total_windows / WINDOWS_PER_FRAME;
                    expected_window = total_windows % WINDOWS_PER_FRAME;
                    expected_row    = expected_window / OUTPUT_WIDTH;
                    expected_col    = expected_window % OUTPUT_WIDTH;
                    expected_base   = expected_row * WIDTH + expected_col;

                    check_one(data_out_0, make_word(expected_frame, expected_base),                 0);
                    check_one(data_out_1, make_word(expected_frame, expected_base + 1),             1);
                    check_one(data_out_2, make_word(expected_frame, expected_base + 2),             2);
                    check_one(data_out_3, make_word(expected_frame, expected_base + WIDTH),         3);
                    check_one(data_out_4, make_word(expected_frame, expected_base + WIDTH + 1),     4);
                    check_one(data_out_5, make_word(expected_frame, expected_base + WIDTH + 2),     5);
                    check_one(data_out_6, make_word(expected_frame, expected_base + WIDTH * 2),     6);
                    check_one(data_out_7, make_word(expected_frame, expected_base + WIDTH * 2 + 1), 7);
                    check_one(data_out_8, make_word(expected_frame, expected_base + WIDTH * 2 + 2), 8);
                end

                total_windows = total_windows + 1;
            end
        end
    end

endmodule
