`timescale 1ns / 1ps
`default_nettype none

// UART 接收物理层：50 MHz 时钟，115200 baud，8N1，低位先发。
// 8N1 = 1 位低电平起始位 + 8 位数据 + 无校验位 + 1 位高电平停止位。
//
// byteValid 是一个 50 MHz 周期（20 ns）的脉冲，不是新时钟。
// 沿 A：停止位校验通过，更新 byteData，并把 byteValid 置 1。
// 沿 B：下游在 posedge clock50MHz 看到 byteValid=1，取走 byteData；
//       本模块同时把 byteValid 清零。因此下游可在紧接着的一拍写 RAM。
// 这里没有 ready/FIFO，下游必须能在这一拍接收；BSRAM 写端口可以做到。
module UARTRX (
    input  wire       clock50MHz,
    input  wire       reset_n,       // 低有效同步复位，中止未收完的帧。
    input  wire       uartRx,        // 外部串行输入，空闲时为高电平。
    output reg  [7:0] byteData,      // 最近一次接收成功的数据，直到下次成功才改变。
    output reg        byteValid,     // 接收成功脉冲，只持续一个 50 MHz 周期。
    output reg        framingError,  // 停止位错误脉冲；错误帧不产生 byteValid。
    output wire       busy           // 正在检测/接收帧，或等待错误后的线路恢复。
);
    // 16 倍过采样：每个串口位取 16 个采样时刻。
    // 50,000,000 / (115,200 * 16) = 27.1267，取整为每 27 拍采样一次。
    // 实际接收时基对应 115740.7 baud，误差约 +0.47%。
    // 只生成“采样使能”，整个模块始终使用 clock50MHz，不产生分频时钟。
    localparam [4:0] SAMPLE_DIV_LAST = 5'd26;
    localparam [2:0] RX_IDLE      = 3'd0,
                     RX_START     = 3'd1,
                     RX_DATA      = 3'd2,
                     RX_STOP      = 3'd3,
                     RX_WAIT_HIGH = 3'd4;

    // RX 与本地时钟异步。先经过两级触发器同步，降低亚稳态传播风险。
    // 后续电路只使用 rxSync，不直接采样引脚 uartRx。
    reg rxMeta;
    reg rxSync;
    reg rxPrevious;
    wire startEdge = rxPrevious && !rxSync;

    always @(posedge clock50MHz) begin
        if (!reset_n) begin
            rxMeta <= 1'b1;
            rxSync <= 1'b1;
            rxPrevious <= 1'b1;
        end else begin
            rxMeta <= uartRx;
            rxSync <= rxMeta;
            rxPrevious <= rxSync;
        end
    end

    reg [2:0] rxState;
    reg [4:0] sampleDivider;  // 0~26：27 个系统时钟产生一次采样使能。
    reg [3:0] sampleIndex;    // 0~15：记录当前串口位的采样相位。
    reg [2:0] bitIndex;       // 0~7：当前正在接收哪一位数据。
    reg [7:0] shiftData;      // 尚未完成停止位校验的数据，不直接交给下游。
    reg [1:0] middleSamples;  // 中间三次采样中的前两次。

    // 三取二：三次采样中至少有两个 1，才把这一位判为 1。
    // 第三次采样直接使用此时的 rxSync，前两次已经保存在寄存器中。
    wire majorityBit = (middleSamples[0] && middleSamples[1]) ||
                       (middleSamples[0] && rxSync) ||
                       (middleSamples[1] && rxSync);
    assign busy = reset_n && (rxState != RX_IDLE);

    always @(posedge clock50MHz) begin
        if (!reset_n) begin
            rxState <= RX_IDLE;
            sampleDivider <= 5'd0;
            sampleIndex <= 4'd0;
            bitIndex <= 3'd0;
            shiftData <= 8'd0;
            middleSamples <= 2'b11;
            byteData <= 8'd0;
            byteValid <= 1'b0;
            framingError <= 1'b0;
        end else begin
            // 默认每拍撤销通知，只有事件发生的分支把它重新置 1。
            byteValid <= 1'b0;
            framingError <= 1'b0;

            case (rxState)
                RX_IDLE: begin
                    sampleDivider <= 5'd0;
                    sampleIndex <= 4'd0;
                    bitIndex <= 3'd0;
                    if (startEdge)
                        rxState <= RX_START;
                end
                RX_START, RX_DATA, RX_STOP: begin
                    if (sampleDivider == SAMPLE_DIV_LAST) begin
                        sampleDivider <= 5'd0;
                        sampleIndex <= sampleIndex + 4'd1;

                        // Index 从 0 起算，所以 6/7/8 对应第 7/8/9 次采样。
                        // 在位中心附近连续取三次样本，可容忍一次采样被毛刺干扰。
                        if (sampleIndex == 4'd6)
                            middleSamples[0] <= rxSync;
                        if (sampleIndex == 4'd7)
                            middleSamples[1] <= rxSync;

                        if (sampleIndex == 4'd8) begin
                            case (rxState)
                                RX_START: begin
                                    // 真起始位在中间仍应为低；短低脉冲会在这里被丢弃。
                                    if (!majorityBit)
                                        rxState <= RX_DATA;
                                    else
                                        rxState <= RX_IDLE;
                                end
                                RX_DATA: begin
                                    // UART 从 bit 0 开始发，不需要倒转字节。
                                    shiftData[bitIndex] <= majorityBit;
                                    if (bitIndex == 3'd7)
                                        rxState <= RX_STOP;
                                    else
                                        bitIndex <= bitIndex + 3'd1;
                                end
                                RX_STOP: begin
                                    if (majorityBit) begin
                                        byteData <= shiftData;
                                        byteValid <= 1'b1;
                                        rxState <= RX_IDLE;
                                    end else begin
                                        framingError <= 1'b1;
                                        rxState <= RX_WAIT_HIGH;
                                    end
                                end
                                default: rxState <= RX_IDLE;
                            endcase
                        end
                        // START -> DATA -> STOP 时不重置 sampleIndex。
                        // 四位计数器自然回绕，所以相邻位中心相隔完整的 16 次采样。
                    end else begin
                        sampleDivider <= sampleDivider + 5'd1;
                    end
                end
                RX_WAIT_HIGH: begin
                    // 错误停止位或线路长时间拉低（break）时，不反复上报假字节。
                    // 等待线路回到高电平，再准备检测下一次起始下降沿。
                    sampleDivider <= 5'd0;
                    sampleIndex <= 4'd0;
                    if (rxSync)
                        rxState <= RX_IDLE;
                end
                default: rxState <= RX_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
