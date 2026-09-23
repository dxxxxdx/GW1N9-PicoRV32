`timescale 1ns / 1ps
`default_nettype none

// UARTTX 的 PicoRV32 MMIO 包装层。
//
// busManager 已经把 0x0100_0000 减成了本模块看到的地址 0。PicoRV32 的
// mem_addr/mmio_addr 始终按 32 位对齐，字节位置由 mmio_wstrb 表示，因此
// 下面三个“字节寄存器”实际位于同一个 32 位总线字中：
//
//   CPU 地址       字节通道        用途
//   0x0100_0000    [ 7: 0]        TX 数据暂存
//   0x0100_0001    [15: 8]        写非零值，请求发送
//   0x0100_0002    [23:16]        只读，1=空闲，0=忙
//
// 写发送使能时，如果 UARTTX 还忙，mmio_ready 会保持为 0。PicoRV32 会保持
// 整个请求，直到 UARTTX 空闲并在同一个上升沿接受数据。状态读取不阻塞，
// 否则软件永远读不到“忙”的 0。
module UARTTX_MMIO (
    input  wire        clock50MHz,
    input  wire        reset_n,

    input  wire        mmio_valid,
    output reg         mmio_ready,
    input  wire [31:0] mmio_addr,
    input  wire [31:0] mmio_wdata,
    input  wire [ 3:0] mmio_wstrb,
    output reg  [31:0] mmio_rdata,

    output wire        uartTx,
    output wire        uartIdle
);
    reg [7:0] txData;

    // 当前 UART 只占 MMIO 窗口内的第一个 32 位字。其他地址立即返回零，
    // 留给以后扩展新的 MMIO 外设，不让误访问永久挂住 CPU。
    wire uartWordSelected = (mmio_addr[31:2] == 30'd0);

    // 对地址 +1 写入任意非零字节都表示一次发送请求。
    wire sendRequest = uartWordSelected && mmio_wstrb[1] &&
                       (|mmio_wdata[15:8]);

    wire txByteReady;
    wire txBusy;

    // 如果一次 32 位/半字写同时覆盖 DATA 和 ENABLE，就直接发送本次总线
    // 携带的新数据；普通的两个 SB 指令则从 txData 发送。
    wire [7:0] txByteData = mmio_wstrb[0] ? mmio_wdata[7:0] : txData;
    wire txByteValid = reset_n && mmio_valid && sendRequest;

    assign uartIdle = txByteReady;

    UARTTX transmitter (
        .clock50MHz(clock50MHz),
        .reset_n(reset_n),
        .byteData(txByteData),
        .byteValid(txByteValid),
        .byteReady(txByteReady),
        .uartTx(uartTx),
        .busy(txBusy)
    );

    // UARTTX 在 byteValid && byteReady 的沿锁存发送数据；同一个条件也作为
    // PicoRV32 的 MMIO 完成条件，所以请求不会提前完成或重复发送。
    always @* begin
        mmio_ready = 1'b0;
        mmio_rdata = 32'd0;

        if (uartWordSelected) begin
            // 完整 32 位读回布局：DATA、ENABLE(恒 0)、IDLE、保留。
            mmio_rdata[7:0] = txData;
            mmio_rdata[23:16] = {7'd0, txByteReady};
        end

        if (mmio_valid) begin
            if (!uartWordSelected)
                mmio_ready = 1'b1;
            else if (sendRequest)
                mmio_ready = txByteReady;
            else
                mmio_ready = 1'b1;
        end
    end

    // 只有总线事务真正完成时才更新暂存寄存器。发送请求被阻塞期间，数据
    // 保持稳定；若 DATA 和 ENABLE 同拍写入，UARTTX 使用上面的旁路值。
    always @(posedge clock50MHz) begin
        if (!reset_n) begin
            txData <= 8'd0;
        end else if (mmio_valid && mmio_ready && uartWordSelected &&
                     mmio_wstrb[0]) begin
            txData <= mmio_wdata[7:0];
        end
    end

    // txBusy 的含义和 !txByteReady 相同。保留这根内部网线，方便综合后或
    // 仿真时直接观察 UARTTX 的发送状态。
    wire unused_txBusy = txBusy;
endmodule

`default_nettype wire
