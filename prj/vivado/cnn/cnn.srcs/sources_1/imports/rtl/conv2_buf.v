`timescale 1ns / 10ps

// B1 streaming Conv2 window-buffer experiment.
//
// Replaces the complete 13x13 feature-map store with:
//   * two 13x48-bit vertical line-delay memories;
//   * six 48-bit horizontal shift registers;
//   * one 8-entry FIFO of complete 3x3x4 windows.
//
// The external ports and the calc_busy high/low handshake are identical to
// B0/B0.1, so conv2_layer and conv2_calc do not change.
module conv2_buf
    #(
        parameter WIDTH     = 13,
        parameter HEIGHT    = 13,
        parameter CHANNELS  = 4,
        parameter DATA_BITS = 12
    )
    (
        input  wire                                  clk,
        input  wire                                  rst_n,
        input  wire                                  valid_in,
        input  wire [(CHANNELS*DATA_BITS)-1:0]       data_in,
        input  wire                                  calc_busy,

        output reg  [(CHANNELS*DATA_BITS)-1:0]       data_out_0,
        output reg  [(CHANNELS*DATA_BITS)-1:0]       data_out_1,
        output reg  [(CHANNELS*DATA_BITS)-1:0]       data_out_2,
        output reg  [(CHANNELS*DATA_BITS)-1:0]       data_out_3,
        output reg  [(CHANNELS*DATA_BITS)-1:0]       data_out_4,
        output reg  [(CHANNELS*DATA_BITS)-1:0]       data_out_5,
        output reg  [(CHANNELS*DATA_BITS)-1:0]       data_out_6,
        output reg  [(CHANNELS*DATA_BITS)-1:0]       data_out_7,
        output reg  [(CHANNELS*DATA_BITS)-1:0]       data_out_8,
        output reg                                   valid_out_buf
    );

    localparam PIXEL_BITS        = CHANNELS * DATA_BITS;
    localparam WINDOW_BITS       = 9 * PIXEL_BITS;
    localparam WINDOW_FIFO_DEPTH = 8;

    // Before each write at row r/column c:
    //   line_delay_2[c] contains row r-2, column c;
    //   line_delay_1[c] contains row r-1, column c.
    // No reset is required because no window is declared valid until two
    // complete earlier rows and two earlier columns have been overwritten.
    (* ram_style = "distributed" *)
    reg [PIXEL_BITS-1:0] line_delay_2 [0:WIDTH-1];
    (* ram_style = "distributed" *)
    reg [PIXEL_BITS-1:0] line_delay_1 [0:WIDTH-1];

    reg [3:0] input_row;
    reg [3:0] input_col;

    // Two previous columns for each of the three active rows.
    reg [PIXEL_BITS-1:0] top_d2;
    reg [PIXEL_BITS-1:0] top_d1;
    reg [PIXEL_BITS-1:0] middle_d2;
    reg [PIXEL_BITS-1:0] middle_d1;
    reg [PIXEL_BITS-1:0] bottom_d2;
    reg [PIXEL_BITS-1:0] bottom_d1;

    wire [PIXEL_BITS-1:0] top_pixel    = line_delay_2[input_col];
    wire [PIXEL_BITS-1:0] middle_pixel = line_delay_1[input_col];

    // A window is complete when its bottom-right pixel reaches row>=2,col>=2.
    wire window_request = valid_in &&
                          (input_row >= 4'd2) &&
                          (input_col >= 4'd2);

    // Packed as {tap8,...,tap0}; tap0 is the top-left pixel and tap8 is the
    // bottom-right pixel.  Slicing it later reproduces the B0 row-major order.
    wire [WINDOW_BITS-1:0] window_word = {
        data_in,       bottom_d1, bottom_d2,
        middle_pixel, middle_d1, middle_d2,
        top_pixel,    top_d1,    top_d2
    };

    always @(posedge clk) begin
        if (~rst_n) begin
            input_row <= 4'd0;
            input_col <= 4'd0;

            // The line memories and horizontal data registers intentionally
            // have no reset.  Coordinates and valid signals guard their use.
        end
        else if (valid_in) begin
            // Vertical two-line delay, one column at a time.
            line_delay_2[input_col] <= middle_pixel;
            line_delay_1[input_col] <= data_in;

            // Horizontal shift for the three rows of the current window.
            top_d2    <= top_d1;
            top_d1    <= top_pixel;
            middle_d2 <= middle_d1;
            middle_d1 <= middle_pixel;
            bottom_d2 <= bottom_d1;
            bottom_d1 <= data_in;

            if (input_col == WIDTH - 1) begin
                input_col <= 4'd0;
                if (input_row == HEIGHT - 1)
                    input_row <= 4'd0;
                else
                    input_row <= input_row + 1'b1;
            end
            else begin
                input_col <= input_col + 1'b1;
            end
        end
    end

    // Eight entries are sufficient for the present fixed upstream pipeline:
    // Pool1 emits pixels every two cycles inside a row, while output-row starts
    // are 56 cycles apart.  A five-cycle Conv2 service time produces a measured
    // worst-case occupancy of seven entries under the fastest legal input.
    (* ram_style = "distributed" *)
    reg [WINDOW_BITS-1:0] window_fifo [0:WINDOW_FIFO_DEPTH-1];

    reg [2:0] fifo_wr_ptr;
    reg [2:0] fifo_rd_ptr;
    reg [3:0] fifo_count;

    reg [1:0] reader_state;
    localparam R_IDLE    = 2'd0;
    localparam R_WAITHI  = 2'd1;
    localparam R_WAITLO  = 2'd2;

    wire fifo_push = window_request &&
                     (fifo_count < WINDOW_FIFO_DEPTH);
    wire fifo_pop  = (reader_state == R_IDLE) &&
                     (fifo_count != 0);

    // FIFO memory write and occupancy accounting.  One push and one pop may
    // occur in the same cycle and leave the occupancy unchanged.
    always @(posedge clk) begin
        if (~rst_n) begin
            fifo_wr_ptr <= 3'd0;
            fifo_count  <= 4'd0;
        end
        else begin
            if (fifo_push) begin
                window_fifo[fifo_wr_ptr] <= window_word;
                fifo_wr_ptr <= fifo_wr_ptr + 1'b1;
            end

            case ({fifo_push, fifo_pop})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase
        end
    end

    // Present one queued window, then preserve the existing calc_busy
    // high/low handshake before presenting the next one.
    always @(posedge clk) begin
        if (~rst_n) begin
            fifo_rd_ptr  <= 3'd0;
            reader_state <= R_IDLE;
            valid_out_buf <= 1'b0;

            // Window data outputs intentionally have no reset.  They are
            // complete and known whenever valid_out_buf is asserted.
        end
        else begin
            valid_out_buf <= 1'b0;

            case (reader_state)
                R_IDLE: begin
                    if (fifo_count != 0) begin
                        data_out_0 <= window_fifo[fifo_rd_ptr][0*PIXEL_BITS +: PIXEL_BITS];
                        data_out_1 <= window_fifo[fifo_rd_ptr][1*PIXEL_BITS +: PIXEL_BITS];
                        data_out_2 <= window_fifo[fifo_rd_ptr][2*PIXEL_BITS +: PIXEL_BITS];
                        data_out_3 <= window_fifo[fifo_rd_ptr][3*PIXEL_BITS +: PIXEL_BITS];
                        data_out_4 <= window_fifo[fifo_rd_ptr][4*PIXEL_BITS +: PIXEL_BITS];
                        data_out_5 <= window_fifo[fifo_rd_ptr][5*PIXEL_BITS +: PIXEL_BITS];
                        data_out_6 <= window_fifo[fifo_rd_ptr][6*PIXEL_BITS +: PIXEL_BITS];
                        data_out_7 <= window_fifo[fifo_rd_ptr][7*PIXEL_BITS +: PIXEL_BITS];
                        data_out_8 <= window_fifo[fifo_rd_ptr][8*PIXEL_BITS +: PIXEL_BITS];

                        fifo_rd_ptr  <= fifo_rd_ptr + 1'b1;
                        valid_out_buf <= 1'b1;
                        reader_state <= R_WAITHI;
                    end
                end

                R_WAITHI: begin
                    if (calc_busy)
                        reader_state <= R_WAITLO;
                end

                R_WAITLO: begin
                    if (!calc_busy)
                        reader_state <= R_IDLE;
                end

                default: begin
                    reader_state <= R_IDLE;
                end
            endcase
        end
    end

// synthesis translate_off
`ifndef SYNTHESIS
    initial begin
        if ((WIDTH != 13) || (HEIGHT != 13) ||
            (CHANNELS != 4) || (DATA_BITS != 12))
            $display("[conv2_buf B1] NOTE: FIFO depth proof is for 13x13x4, 12-bit Pool1 output.");
    end

    always @(posedge clk) begin
        if (rst_n && window_request &&
            (fifo_count == WINDOW_FIFO_DEPTH))
            $fatal(1, "[conv2_buf B1] Window FIFO overflow; upstream cadence contract was violated");

        if (rst_n && valid_out_buf && calc_busy)
            $fatal(1, "[conv2_buf B1] Window presented while conv2_calc was busy");
    end
`endif
// synthesis translate_on

endmodule
