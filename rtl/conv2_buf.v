`timescale 1ns / 10ps

module conv2_buf
    #(
        parameter WIDTH = 13,
        parameter HEIGHT = 13,
        parameter CHANNELS = 4,
        parameter DATA_BITS = 12
    )
    (
        input  wire                               clk,
        input  wire                               rst_n,
        input  wire                               valid_in,
        input  wire [(CHANNELS*DATA_BITS)-1:0]    data_in,
        input  wire                               calc_busy,

        output reg  [(CHANNELS*DATA_BITS)-1:0]    data_out_0, data_out_1, data_out_2,
            data_out_3, data_out_4, data_out_5,
            data_out_6, data_out_7, data_out_8,
        output reg                                valid_out_buf
    );

    localparam TOTAL_PIXELS = WIDTH * HEIGHT; // 13x13 = 169
    localparam OUT_WIDTH    = WIDTH - 3 + 1;  // 11
    localparam OUT_HEIGHT   = HEIGHT - 3 + 1; // 11

    // -------------------------------------------------------------
    // 物理存储区：两个独立的 BRAM Bank (乒乓架构)
    // -------------------------------------------------------------
    reg [(CHANNELS*DATA_BITS)-1:0] bank_A [0:TOTAL_PIXELS-1];
    reg [(CHANNELS*DATA_BITS)-1:0] bank_B [0:TOTAL_PIXELS-1];

    // -------------------------------------------------------------
    // 写入逻辑 (高速吸收上游数据)
    // -------------------------------------------------------------
    reg [7:0] wr_ptr;
    reg       wr_bank;
    reg       frame_ready_A;
    reg       frame_ready_B;

    reg       frame_done;

    reg       rd_bank;
    reg [3:0] win_row;
    reg [3:0] win_col;
    reg [2:0] state;   // 【更新】：扩展为 3-bit 状态机

    localparam S_IDLE   = 3'd0;
    localparam S_EMIT   = 3'd1;
    localparam S_WAITHI = 3'd2;
    localparam S_WAITLO = 3'd3;
    localparam S_CLEAR  = 3'd4; // 【核心更新】：增加专门的清空缓冲状态

    wire [7:0] base_idx = win_row * WIDTH + win_col;

    always @(posedge clk) begin
        if (~rst_n) begin
            wr_ptr <= 0;
            wr_bank <= 0;
            frame_ready_A <= 0;
            frame_ready_B <= 0;
        end
        else begin
            // 接收上游数据
            if (valid_in) begin
                if (wr_bank == 1'b0)
                    bank_A[wr_ptr] <= data_in;
                else
                    bank_B[wr_ptr] <= data_in;

                if (wr_ptr == TOTAL_PIXELS - 1) begin
                    wr_ptr <= 0;
                    if (wr_bank == 1'b0)
                        frame_ready_A <= 1'b1;
                    else
                        frame_ready_B <= 1'b1;
                    wr_bank <= ~wr_bank;
                end
                else begin
                    wr_ptr <= wr_ptr + 1;
                end
            end

            // 当下游算完一张图时，释放刚刚算完的那个 Bank
            if (frame_done) begin
                if (rd_bank == 1'b0)
                    frame_ready_A <= 1'b0;
                else
                    frame_ready_B <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------
    // 读取逻辑 (慢速提供给下游计算，握手 calc_busy)
    // -------------------------------------------------------------

    always @(posedge clk) begin
        if (~rst_n) begin
            win_row <= 0;
            win_col <= 0;
            rd_bank <= 0;
            valid_out_buf <= 0;
            frame_done <= 0;
            state <= S_IDLE;
        end
        else begin
            // 默认脉冲拉低
            valid_out_buf <= 1'b0;
            frame_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    win_row <= 0;
                    win_col <= 0;
                    if (frame_ready_A && rd_bank == 1'b0) begin
                        state <= S_EMIT;
                    end
                    else if (frame_ready_B && rd_bank == 1'b1) begin
                        state <= S_EMIT;
                    end
                    else if (frame_ready_A) begin
                        rd_bank <= 1'b0;
                        state <= S_EMIT;
                    end
                    else if (frame_ready_B) begin
                        rd_bank <= 1'b1;
                        state <= S_EMIT;
                    end
                end

                S_EMIT: begin
                    if (rd_bank == 1'b0) begin
                        data_out_0 <= bank_A[base_idx];
                        data_out_1 <= bank_A[base_idx+1];
                        data_out_2 <= bank_A[base_idx+2];
                        data_out_3 <= bank_A[base_idx+WIDTH];
                        data_out_4 <= bank_A[base_idx+WIDTH+1];
                        data_out_5 <= bank_A[base_idx+WIDTH+2];
                        data_out_6 <= bank_A[base_idx+WIDTH*2];
                        data_out_7 <= bank_A[base_idx+WIDTH*2+1];
                        data_out_8 <= bank_A[base_idx+WIDTH*2+2];
                    end
                    else begin
                        data_out_0 <= bank_B[base_idx];
                        data_out_1 <= bank_B[base_idx+1];
                        data_out_2 <= bank_B[base_idx+2];
                        data_out_3 <= bank_B[base_idx+WIDTH];
                        data_out_4 <= bank_B[base_idx+WIDTH+1];
                        data_out_5 <= bank_B[base_idx+WIDTH+2];
                        data_out_6 <= bank_B[base_idx+WIDTH*2];
                        data_out_7 <= bank_B[base_idx+WIDTH*2+1];
                        data_out_8 <= bank_B[base_idx+WIDTH*2+2];
                    end

                    valid_out_buf <= 1'b1;
                    state <= S_WAITHI;
                end

                S_WAITHI: begin
                    if (calc_busy)
                        state <= S_WAITLO;
                end

                S_WAITLO: begin
                    if (!calc_busy) begin
                        if (win_col == OUT_WIDTH - 1) begin
                            win_col <= 0;
                            if (win_row == OUT_HEIGHT - 1) begin
                                // 整张图算完，发出清空脉冲，进入缓冲状态
                                frame_done <= 1'b1;
                                state <= S_CLEAR;
                            end
                            else begin
                                win_row <= win_row + 1;
                                state <= S_EMIT;
                            end
                        end
                        else begin
                            win_col <= win_col + 1;
                            state <= S_EMIT;
                        end
                    end
                end

                S_CLEAR: begin
                    // 【核心更新】：停留一拍！
                    // 在这一拍里，Writer 模块正在安心地把标志位清零
                    // 我们在这个安全的时空里，切换读取的 Bank，然后回到 IDLE
                    rd_bank <= ~rd_bank;
                    state <= S_IDLE;
                end
            endcase
        end
    end
endmodule
