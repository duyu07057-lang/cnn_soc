`timescale 1ns / 10ps

module axis_cnn_mnist
    (
        input  wire       aclk,
        input  wire       aresetn,

        output wire       s_axis_tready,
        input  wire [7:0] s_axis_tdata,
        input  wire       s_axis_tvalid,

        input  wire       m_axis_tready,
        output wire [7:0] m_axis_tdata,
        output wire       m_axis_tvalid,
        output wire       m_axis_tlast
    );

    localparam integer INPUT_PIXELS = 784;

    // Conv1 output: 26 x 26 x 4 x 12-bit.
    wire [47:0] conv1_out;
    wire        valid_out_conv1;

    // Pool1 output: 13 x 13 x 4 x 12-bit.
    wire [47:0] pool1_out;
    wire        valid_out_pool1;

    // Conv2 output: 11 x 11 x 8 x 12-bit.
    wire [95:0] conv2_out;
    wire        valid_out_conv2;

    // Pool2 output: 5 x 5 x 8 x 12-bit.
    wire [95:0] pool2_out;
    wire        valid_out_pool2;

    wire [3:0] decision;
    wire       valid_out_fc;

    // Registered input presented to Conv1 only after a real AXI handshake.
    reg [7:0] s_axis_tdata_reg;
    reg       s_axis_tvalid_reg;

    // Baseline control policy: allow exactly one complete frame in flight.
    // This guarantees that a blocked output cannot be overwritten by a later frame.
    reg [9:0] input_pixel_count;
    reg       frame_busy;

    // One-entry output holding register. Data and TLAST remain stable while stalled.
    reg [7:0] m_axis_tdata_reg;
    reg       m_axis_tvalid_reg;

    wire input_fire  = s_axis_tvalid && s_axis_tready;
    wire output_fire = m_axis_tvalid_reg && m_axis_tready;

    assign s_axis_tready = ~frame_busy;
    assign m_axis_tdata  = m_axis_tdata_reg;
    assign m_axis_tvalid = m_axis_tvalid_reg;
    assign m_axis_tlast  = m_axis_tvalid_reg;

    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axis_tdata_reg  <= 8'd0;
            s_axis_tvalid_reg <= 1'b0;
            input_pixel_count <= 10'd0;
            frame_busy        <= 1'b0;
            m_axis_tdata_reg  <= 8'd0;
            m_axis_tvalid_reg <= 1'b0;
        end
        else begin
            // Default: do not send anything to Conv1 without an input handshake.
            s_axis_tvalid_reg <= 1'b0;

            if (input_fire) begin
                s_axis_tdata_reg  <= s_axis_tdata;
                s_axis_tvalid_reg <= 1'b1;

                if (input_pixel_count == INPUT_PIXELS - 1) begin
                    input_pixel_count <= 10'd0;
                    frame_busy        <= 1'b1;
                end
                else begin
                    input_pixel_count <= input_pixel_count + 1'b1;
                end
            end

            // Release the accelerator only after the result handshake completes.
            if (output_fire) begin
                m_axis_tvalid_reg <= 1'b0;
                frame_busy        <= 1'b0;
            end

            // Capture the one-cycle FC result pulse and hold it for AXI-Stream.
            // This assignment intentionally has priority over output_fire.
            if (valid_out_fc) begin
                m_axis_tdata_reg  <= {4'b0000, decision};
                m_axis_tvalid_reg <= 1'b1;
                frame_busy        <= 1'b1;
            end
        end
    end

    conv1_layer u_conv1 (
        .clk            (aclk),
        .rst_n          (aresetn),
        .valid_in       (s_axis_tvalid_reg),
        .data_in        (s_axis_tdata_reg),
        .conv_out       (conv1_out),
        .valid_out_conv (valid_out_conv1)
    );

    maxpool_relu #(
        .WIDTH(26), .HEIGHT(26), .CHANNELS(4), .DATA_BITS(12)
    ) u_pool1 (
        .clk            (aclk),
        .rst_n          (aresetn),
        .valid_in       (valid_out_conv1),
        .data_in        (conv1_out),
        .data_out       (pool1_out),
        .valid_out_relu (valid_out_pool1)
    );

    conv2_layer u_conv2 (
        .clk            (aclk),
        .rst_n          (aresetn),
        .valid_in       (valid_out_pool1),
        .data_in        (pool1_out),
        .conv_out       (conv2_out),
        .valid_out_conv (valid_out_conv2)
    );

    maxpool_relu #(
        .WIDTH(11), .HEIGHT(11), .CHANNELS(8), .DATA_BITS(12)
    ) u_pool2 (
        .clk            (aclk),
        .rst_n          (aresetn),
        .valid_in       (valid_out_conv2),
        .data_in        (conv2_out),
        .data_out       (pool2_out),
        .valid_out_relu (valid_out_pool2)
    );

    fully_connected u_fc (
        .clk          (aclk),
        .rst_n        (aresetn),
        .valid_in     (valid_out_pool2),
        .data_in      (pool2_out),
        .decision     (decision),
        .valid_out_fc (valid_out_fc)
    );

endmodule
