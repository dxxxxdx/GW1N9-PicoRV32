`timescale 1ns / 1ps
`default_nettype none

module tb_rv32top;
    reg clock50MHz = 1'b0;
    always #10 clock50MHz = !clock50MHz;

    reg reset_n = 1'b0;
    reg start = 1'b1;
    reg uartRx = 1'b1;
    wire uartTx;
    wire trap;

    rv32top #(
        .BUTTON_FILTER_CYCLES(22'd8)
    ) dut (
        .clock50MHz(clock50MHz), .reset_n(reset_n), .start(start),
        .uartRx(uartRx), .uartTx(uartTx), .trap(trap)
    );

    // 50 MHz / 115200 取 434 拍/位，与项目里的 UARTTX 一致。
    task send_uart_byte;
        input [7:0] value;
        integer bitNumber;
        begin
            uartRx = 1'b0;
            repeat (434) @(posedge clock50MHz);
            for (bitNumber = 0; bitNumber < 8; bitNumber = bitNumber + 1) begin
                uartRx = value[bitNumber];
                repeat (434) @(posedge clock50MHz);
            end
            uartRx = 1'b1;
            repeat (434) @(posedge clock50MHz);
        end
    endtask

    // 用第二个已验证 UARTRX 监视 CPU 的 MMIO 输出。
    wire [7:0] monitorData;
    wire monitorValid;
    wire monitorError;
    wire monitorBusy;
    UARTRX monitor (
        .clock50MHz(clock50MHz), .reset_n(reset_n), .uartRx(uartTx),
        .byteData(monitorData), .byteValid(monitorValid),
        .framingError(monitorError), .busy(monitorBusy)
    );

    reg [7:0] firmware [0:35];
    reg [7:0] receivedBytes [0:1];
    integer receivedCount = 0;
    integer firmwareIndex;
    integer timeout;

    always @(posedge clock50MHz) begin
        if (monitorValid) begin
            if (receivedCount < 2)
                receivedBytes[receivedCount] <= monitorData;
            receivedCount <= receivedCount + 1;
        end
    end

    initial begin
        $readmemh("GW1N-9_rv32/firmware/hi.hex", firmware);

        repeat (8) @(posedge clock50MHz);
        @(negedge clock50MHz);
        reset_n = 1'b1;
        wait (dut.systemReset_n);
        repeat (4) @(posedge clock50MHz);

        // firmware/hi.hex 中手工编码的 RV32I：
        //   lui  x1, 0x01000       ; x1 = 0x0100_0000
        //   依次发送 'h'、'i'
        //   sb   x2, 0(x1)         ; UART DATA
        //   sb   x3, 1(x1)         ; UART ENABLE，忙时阻塞
        //   jal  x0, 0             ; 原地循环
        for (firmwareIndex = 0; firmwareIndex < 36;
             firmwareIndex = firmwareIndex + 1)
            send_uart_byte(firmware[firmwareIndex]);

        repeat (32) @(posedge clock50MHz);
        if (dut.loadedBytes !== 16'd36 || dut.loadError)
            $fatal(1, "UART loader failed: bytes=%0d error=%b",
                   dut.loadedBytes, dut.loadError);
        if (dut.programLoaded || dut.cpuReset_n)
            $fatal(1, "CPU started before explicit start request");

        // 小于消抖阈值的毛刺不能启动 CPU。
        @(negedge clock50MHz);
        start = 1'b0;
        repeat (3) @(posedge clock50MHz);
        @(negedge clock50MHz);
        start = 1'b1;
        repeat (16) @(posedge clock50MHz);
        if (dut.programLoaded || dut.startRequest)
            $fatal(1, "Short start-button glitch passed debounce");

        @(negedge clock50MHz);
        start = 1'b0;
        repeat (16) @(posedge clock50MHz);
        @(negedge clock50MHz);
        start = 1'b1;

        timeout = 0;
        while (receivedCount < 2 && timeout < 30000) begin
            @(posedge clock50MHz);
            timeout = timeout + 1;
            if (trap)
                $fatal(1, "PicoRV32 trapped before UART output");
            if (monitorError)
                $fatal(1, "UART TX loopback framing error");
        end

        if (!dut.programLoaded || !dut.cpuReset_n)
            $fatal(1, "Start request did not release PicoRV32");
        if (receivedCount < 2)
            $fatal(1, "Timed out waiting for RV32 UART output");
        if (receivedBytes[0] !== 8'h68 || receivedBytes[1] !== 8'h69)
            $fatal(1, "RV32 UART output was %02x %02x, expected 68 69",
                   receivedBytes[0], receivedBytes[1]);

        repeat (100) @(posedge clock50MHz);
        if (dut.cpu.reg_pc !== 32'h0000_0020 || receivedCount != 2)
            $fatal(1, "CPU did not remain in the terminal loop: pc=%08x count=%0d",
                   dut.cpu.reg_pc, receivedCount);

        $display("PASS: UART-loaded PicoRV32 printed hi and entered its loop");
        $finish;
    end
endmodule

`default_nettype wire
