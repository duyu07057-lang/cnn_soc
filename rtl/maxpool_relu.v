`timescale 1ns / 10ps

module maxpool_relu
    #(
        parameter WIDTH = 26,     // 输入特征图宽度
        parameter HEIGHT = 26,    // 输入特征图高度
        parameter CHANNELS = 4,   // 通道数 (默认值已更新为轻量化结构的 4)
        parameter DATA_BITS = 12  // 数据位宽
    )
    (
        input  wire                               clk,
        input  wire                               rst_n,
        input  wire                               valid_in,
        
        // 自动计算宽度的超级总线
        input  wire [(CHANNELS*DATA_BITS)-1:0]    data_in,
        output reg  [(CHANNELS*DATA_BITS)-1:0]    data_out,
        output reg                                valid_out_relu
    );

    // 计算内部所需参数
    localparam HALF_WIDTH = WIDTH / 2;
    localparam TOTAL_BITS = CHANNELS * DATA_BITS;

    // --- 极简行缓存 ---
    reg [TOTAL_BITS-1:0] line_buf [0:HALF_WIDTH-1];

    // --- 坐标计数器 ---
    // 位宽统一加宽到 8-bit，彻底消除溢出隐患，最高可无缝支持 256x256 的图像分辨率
    reg [7:0] w_idx;
    reg [7:0] h_idx;

    // --- 像素暂存器 ---
    reg [TOTAL_BITS-1:0] temp_max;

    // ==========================================
    // 1. 纯组合逻辑：全通道并行 ReLU 激活
    // ==========================================
    wire [TOTAL_BITS-1:0] relu_data;
    genvar c;
    generate
        for (c = 0; c < CHANNELS; c = c + 1) begin : relu_gen
            wire signed [DATA_BITS-1:0] ch_data = data_in[c*DATA_BITS +: DATA_BITS];
            
            // 逢负必零：利用位复制语法自动适配任意的 DATA_BITS 宽度，告别硬编码的 12'd0
            assign relu_data[c*DATA_BITS +: DATA_BITS] = (ch_data[DATA_BITS-1]) ? {DATA_BITS{1'b0}} : ch_data;
        end
    endgenerate

    // ==========================================
    // 2. 纯组合逻辑：全通道并行 Max 比较树
    // ==========================================
    wire [TOTAL_BITS-1:0] max_of_row;
    wire [TOTAL_BITS-1:0] final_max;
    
    // 使用右移语法实现通用的除以 2 索引映射，取代原有的 w_idx[4:1] 硬切片
    wire [7:0] buf_idx = w_idx >> 1;

    generate
        for (c = 0; c < CHANNELS; c = c + 1) begin : max_gen
            wire signed [DATA_BITS-1:0] val_a   = temp_max[c*DATA_BITS +: DATA_BITS];
            wire signed [DATA_BITS-1:0] val_b   = relu_data[c*DATA_BITS +: DATA_BITS];
            wire signed [DATA_BITS-1:0] val_buf = line_buf[buf_idx][c*DATA_BITS +: DATA_BITS];

            // 第一级比较：当前进来的像素 vs 暂存的同一行上一个像素
            assign max_of_row[c*DATA_BITS +: DATA_BITS] = (val_a > val_b) ? val_a : val_b;
            
            // 第二级比较：当前行最大值 vs 上一行存在 Buffer 里的最大值
            assign final_max[c*DATA_BITS +: DATA_BITS]  = (max_of_row[c*DATA_BITS +: DATA_BITS] > val_buf) ? max_of_row[c*DATA_BITS +: DATA_BITS] : val_buf;
        end
    endgenerate

    // ==========================================
    // 3. 时序逻辑：数据流与坐标路由控制
    // ==========================================
    integer i;
    always @(posedge clk) begin
        if (~rst_n) begin
            w_idx <= 0;
            h_idx <= 0;
            valid_out_relu <= 0;
            data_out <= 0;
            temp_max <= 0;
            for (i=0; i<HALF_WIDTH; i=i+1) begin
                line_buf[i] <= 0;
            end
        end else begin
            valid_out_relu <= 1'b0; // 默认拉低 valid 信号

            if (valid_in) begin
                // --- 坐标扫描更新 ---
                if (w_idx == WIDTH - 1) begin
                    w_idx <= 0;
                    if (h_idx == HEIGHT - 1) begin
                        h_idx <= 0;
                    end else begin
                        h_idx <= h_idx + 1'b1;
                    end
                end else begin
                    w_idx <= w_idx + 1'b1;
                end

                // --- 奇偶行列路由逻辑 (2x2 池化的核心) ---
                if (w_idx[0] == 1'b0) begin
                    // 【偶数列】(0, 2, 4...)：来的是左半边像素，将其存入组合逻辑前级
                    temp_max <= relu_data;
                end else begin
                    // 【奇数列】(1, 3, 5...)：凑齐了左右两个，组合逻辑已算出本行的最大值
                    if (h_idx[0] == 1'b0) begin
                        // 【偶数行】(0, 2, 4...)：把上半部分选出的最大值存入行缓存
                        line_buf[buf_idx] <= max_of_row;
                    end else begin
                        // 【奇数行】(1, 3, 5...)：凑齐了上下左右四个像素，输出最终终极最大值
                        data_out <= final_max;
                        valid_out_relu <= 1'b1; // 打出一拍有效脉冲
                    end
                end
            end
        end
    end
endmodule