`timescale 1ns / 10ps

module conv1_buf
    #(
        parameter WIDTH = 28,
        parameter HEIGHT = 28,
        parameter DATA_BITS = 8
    )
    (
        input  wire                 clk,
        input  wire                 rst_n,
        input  wire                 valid_in,
        input  wire [DATA_BITS-1:0] data_in,

        output reg  [DATA_BITS-1:0] data_out_0, data_out_1, data_out_2,
                                data_out_3, data_out_4, data_out_5,
                                data_out_6, data_out_7, data_out_8,
        output reg                  valid_out_buf
    );

    localparam FILTER_SIZE = 3;
    localparam BUF_LINES   = 4; // N+1 架构
    localparam BUF_SIZE    = WIDTH * BUF_LINES;

    reg [DATA_BITS-1:0] buffer [0:BUF_SIZE-1];
    
    // 计数器与指针
    reg [11:0] total_cnt;    // 总像素计数
    reg [10:0] w_ptr;        // 环形写指针 (0 to 111)
    reg [1:0]  line_sel;     // 当前写到了第几行 (0,1,2,3)
    reg [4:0]  x_ptr;        // 当前行的横坐标 (0 to 27)

    // 1. 写逻辑：数据进来就直接存，指针不停旋转
    always @(posedge clk) begin
        if (~rst_n) begin
            w_ptr <= 0;
            total_cnt <= 0;
            line_sel <= 0;
            x_ptr <= 0;
        end else if (valid_in) begin
            buffer[w_ptr] <= data_in;
            total_cnt <= (total_cnt == 783) ? 0 : total_cnt + 1;
            
            // 环形指针逻辑
            if (w_ptr == BUF_SIZE - 1) w_ptr <= 0;
            else w_ptr <= w_ptr + 1;

            if (x_ptr == WIDTH - 1) begin
                x_ptr <= 0;
                line_sel <= line_sel + 1; // 自动 0,1,2,3 循环
            end else begin
                x_ptr <= x_ptr + 1;
            end
        end
    end

    // 2. 读逻辑：根据当前写在哪一行，动态映射 Top/Mid/Bot
    // 核心公式：读窗在写指针的“后方”
    wire [10:0] col_idx = x_ptr; 
    
    always @(posedge clk) begin
        valid_out_buf <= 1'b0;
        
        // 只有当存够了 2 行 + 3 个像素后，才开始输出
        if (valid_in && total_cnt >= (WIDTH*2 + 2)) begin
            // 避开图像右侧边缘（3x3 窗不能越界）
            if (x_ptr >= 2 && x_ptr <= WIDTH - 1) begin
                valid_out_buf <= 1'b1;
                case(line_sel)
                    2'd2: begin // 正在写 Line 2，读 0,1,2
                        data_out_0 <= buffer[col_idx-2];         data_out_1 <= buffer[col_idx-1];         data_out_2 <= buffer[col_idx];
                        data_out_3 <= buffer[col_idx-2 + WIDTH]; data_out_4 <= buffer[col_idx-1 + WIDTH]; data_out_5 <= buffer[col_idx + WIDTH];
                        data_out_6 <= buffer[col_idx-2 + WIDTH*2];data_out_7 <= buffer[col_idx-1 + WIDTH*2];data_out_8 <= data_in;
                    end
                    2'd3: begin // 正在写 Line 3，读 1,2,3
                        data_out_0 <= buffer[col_idx-2 + WIDTH]; data_out_1 <= buffer[col_idx-1 + WIDTH]; data_out_2 <= buffer[col_idx + WIDTH];
                        data_out_3 <= buffer[col_idx-2 + WIDTH*2];data_out_4 <= buffer[col_idx-1 + WIDTH*2];data_out_5 <= buffer[col_idx + WIDTH*2];
                        data_out_6 <= buffer[col_idx-2 + WIDTH*3];data_out_7 <= buffer[col_idx-1 + WIDTH*3];data_out_8 <= data_in;
                    end
                    2'd0: begin // 正在写 Line 0，读 2,3,0
                        data_out_0 <= buffer[col_idx-2 + WIDTH*2];data_out_1 <= buffer[col_idx-1 + WIDTH*2];data_out_2 <= buffer[col_idx + WIDTH*2];
                        data_out_3 <= buffer[col_idx-2 + WIDTH*3];data_out_4 <= buffer[col_idx-1 + WIDTH*3];data_out_5 <= buffer[col_idx + WIDTH*3];
                        data_out_6 <= buffer[col_idx-2];         data_out_7 <= buffer[col_idx-1];         data_out_8 <= data_in;
                    end
                    2'd1: begin // 正在写 Line 1，读 3,0,1
                        data_out_0 <= buffer[col_idx-2 + WIDTH*3];data_out_1 <= buffer[col_idx-1 + WIDTH*3];data_out_2 <= buffer[col_idx + WIDTH*3];
                        data_out_3 <= buffer[col_idx-2];         data_out_4 <= buffer[col_idx-1];         data_out_5 <= buffer[col_idx];
                        data_out_6 <= buffer[col_idx-2 + WIDTH]; data_out_7 <= buffer[col_idx-1 + WIDTH]; data_out_8 <= data_in;
                    end
                endcase
            end
        end
    end
endmodule