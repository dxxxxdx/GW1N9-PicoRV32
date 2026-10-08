`timescale 1ns / 1ps
`default_nettype none

// UART 发送物理层：115200 baud，8N1，低位先发，没有 FIFO。
//
// 直接接 bfcore：
//   bfcore.output_data  -> byteData
//   bfcore.output_valid -> byteValid
//   bfcore.output_ready <- byteReady
// 两个模块必须使用同一个时钟和 reset_n。
//
// 在上升沿 byteValid && byteReady 时接收一次字节，并立刻开始发送起始位。
// 随后 byteReady 拉低，直到整个停止位发完，才允许接收下一个字节。
// 上游在等待期间必须保持 byteValid 和 byteData；不能只给一个脉冲就撤回。
module UARTTX #(
    // 系统时钟频率，只用来算位周期。改系统时钟只要改这里。
    parameter integer CLK_HZ = 50_000_000,
    parameter integer BAUD   = 115200
) (
    input  wire       clk,
    input  wire       reset_n,   // 低有效同步复位，中止当前帧。
    input  wire [7:0] byteData,  // 要发送的字节，只在握手沿采样。
    input  wire       byteValid, // 上游有有效字节，接 bfcore.output_valid。
    output wire       byteReady, // 可以接收新字节，接 bfcore.output_ready。
    output wire       uartTx,    // 串行输出，空闲和停止位均为高电平。
    output wire       busy       // 当前帧尚未发完；判断串口排空时使用。
);
    // 50MHz: 50,000,000 / 115200 = 434.03 -> 每位 434 拍，115207 baud，误差 +0.006%
    // 80MHz: 80,000,000 / 115200 = 694.44 -> 每位 694 拍，115274 baud，误差 +0.064%
    // 四舍五入，40/50/80MHz 下误差都比截断小
    localparam integer BIT_CYCLES = (CLK_HZ + BAUD / 2) / BAUD;
    localparam [15:0] BIT_CYCLES_LAST = BIT_CYCLES[15:0] - 16'd1;

    // transmitting 表示两个状态：0=空闲，1=正在发送。
    // uartFrame 只保存正在发送的这一帧，不额外排队保存下一个字节。
    reg       transmitting;
    reg [9:0] uartFrame;
    reg [15:0] baudCounter;
    reg [3:0] bitIndex;      // 0=起始位，1~8=数据位，9=停止位。

    assign byteReady = reset_n && !transmitting;
    assign busy = reset_n && transmitting;
    assign uartTx = (reset_n && transmitting) ? uartFrame[0] : 1'b1;

    always @(posedge clk) begin
        if (!reset_n) begin
            transmitting <= 1'b0;
            uartFrame <= 10'h3ff;
            baudCounter <= 16'd0;
            bitIndex <= 4'd0;
        end else if (!transmitting) begin
            // 此分支里 byteReady 已经为 1，byteValid=1 就完成握手。
            // 用电平握手，不检测 byteValid 上升沿；连续有效也能逐字节接收。
            if (byteValid) begin
                // 拼接顺序从高位到低位：停止位、8 位数据、起始位。
                // 输出端接最低位，所以先输出起始 0，再依次输出 D0~D7，最后 1。
                uartFrame <= {1'b1, byteData, 1'b0};
                baudCounter <= 16'd0;
                bitIndex <= 4'd0;
                transmitting <= 1'b1;
            end
        end else if (baudCounter == BIT_CYCLES_LAST) begin
            baudCounter <= 16'd0;
            if (bitIndex == 4'd9) begin
                // 必须等停止位也保持满 694 拍，才释放发送器。
                // 本沿之后 ready 才为 1，最早下一上升沿接收新的字节。
                transmitting <= 1'b0;
                bitIndex <= 4'd0;
            end else begin
                // 每到位边界右移一次；两个位边界之间输出保持不变。
                uartFrame <= {1'b1, uartFrame[9:1]};
                bitIndex <= bitIndex + 4'd1;
            end
        end else begin
            baudCounter <= baudCounter + 16'd1;
        end
    end

    // 注意：握手表示“这个字节已被 TX 接收”，并不表示“已经从引脚发完”。
    // bfcore 可在第一次握手后执行其他指令，但下一次 '.' 会因 ready=0 阻塞。
    // 因此 bfcore.done 可能先于最后一帧结束；需要全部发完时还要检查 !busy。
endmodule

`default_nettype wire
