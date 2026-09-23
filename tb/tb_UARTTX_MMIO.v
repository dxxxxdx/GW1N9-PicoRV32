`timescale 1ns / 1ps
`default_nettype none

module tb_UARTTX_MMIO;
    reg clock50MHz = 1'b0;
    always #10 clock50MHz = !clock50MHz;

    reg reset_n = 1'b0;
    reg mmio_valid = 1'b0;
    wire mmio_ready;
    reg [31:0] mmio_addr = 32'd0;
    reg [31:0] mmio_wdata = 32'd0;
    reg [3:0] mmio_wstrb = 4'd0;
    wire [31:0] mmio_rdata;
    wire uartTx;
    wire uartIdle;

    UARTTX_MMIO dut (
        .clock50MHz(clock50MHz), .reset_n(reset_n),
        .mmio_valid(mmio_valid), .mmio_ready(mmio_ready),
        .mmio_addr(mmio_addr), .mmio_wdata(mmio_wdata),
        .mmio_wstrb(mmio_wstrb), .mmio_rdata(mmio_rdata),
        .uartTx(uartTx), .uartIdle(uartIdle)
    );

    // 使用同一项目中已经验证过的 RX 做串口回环，确认 MMIO 层送出的字节
    // 不仅完成了握手，也确实从引脚按顺序发送。
    wire [7:0] rxByteData;
    wire rxByteValid;
    wire rxFramingError;
    wire rxBusy;
    UARTRX loopback (
        .clock50MHz(clock50MHz), .reset_n(reset_n), .uartRx(uartTx),
        .byteData(rxByteData), .byteValid(rxByteValid),
        .framingError(rxFramingError), .busy(rxBusy)
    );

    reg [7:0] received [0:1];
    integer receivedCount = 0;
    always @(posedge clock50MHz) begin
        if (rxFramingError)
            $fatal(1, "UART loopback framing error");
        if (rxByteValid) begin
            if (receivedCount < 2)
                received[receivedCount] <= rxByteData;
            receivedCount <= receivedCount + 1;
        end
    end

    task write_byte;
        input [1:0] lane;
        input [7:0] value;
        begin
            @(negedge clock50MHz);
            mmio_valid = 1'b1;
            mmio_addr = 32'd0;
            mmio_wdata = {4{value}};
            mmio_wstrb = 4'b0001 << lane;
            #1;
            while (!mmio_ready)
                @(negedge clock50MHz);
            @(posedge clock50MHz);
            @(negedge clock50MHz);
            mmio_valid = 1'b0;
            mmio_wstrb = 4'd0;
        end
    endtask

    task read_word;
        output [31:0] value;
        begin
            @(negedge clock50MHz);
            mmio_valid = 1'b1;
            mmio_addr = 32'd0;
            mmio_wstrb = 4'd0;
            #1;
            if (!mmio_ready)
                $fatal(1, "MMIO status read unexpectedly stalled");
            value = mmio_rdata;
            @(posedge clock50MHz);
            @(negedge clock50MHz);
            mmio_valid = 1'b0;
        end
    endtask

    reg [31:0] readData;
    integer blockedCycles;

    initial begin
        repeat (4) @(posedge clock50MHz);
        @(negedge clock50MHz);
        reset_n = 1'b1;

        read_word(readData);
        if (readData[23:16] !== 8'd1 || uartIdle !== 1'b1)
            $fatal(1, "UART did not report idle after reset");

        // DATA(+0) 只暂存，ENABLE(+1)=1 才开始发送。
        write_byte(2'd0, 8'h5a);
        if (dut.txData !== 8'h5a || uartIdle !== 1'b1)
            $fatal(1, "TX data register write failed");
        write_byte(2'd1, 8'h01);
        if (uartIdle !== 1'b0)
            $fatal(1, "UART did not become busy after enable write");

        // 忙时仍可读取 IDLE=0，也可以预装下一字节。
        read_word(readData);
        if (readData[23:16] !== 8'd0)
            $fatal(1, "Busy status did not read as zero");
        write_byte(2'd0, 8'ha5);
        if (dut.txData !== 8'ha5)
            $fatal(1, "Busy-time TX data preload failed: %02x", dut.txData);

        // 第二次 ENABLE 写必须保持阻塞，直到第一帧的完整停止位结束。
        @(negedge clock50MHz);
        mmio_valid = 1'b1;
        mmio_addr = 32'd0;
        mmio_wdata = 32'h0101_0101;
        mmio_wstrb = 4'b0010;
        blockedCycles = 0;
        while (!mmio_ready) begin
            @(negedge clock50MHz);
            blockedCycles = blockedCycles + 1;
            if (blockedCycles > 5000)
                $fatal(1, "Blocked enable write never resumed");
        end
        if (blockedCycles < 4000)
            $fatal(1, "Enable write did not remain blocked for the first frame");
        @(posedge clock50MHz);
        @(negedge clock50MHz);
        mmio_valid = 1'b0;
        mmio_wstrb = 4'd0;

        wait (receivedCount == 2);
        if (received[0] !== 8'h5a || received[1] !== 8'ha5)
            $fatal(1, "Loopback bytes wrong: %02x %02x",
                   received[0], received[1]);

        wait (uartIdle);
        read_word(readData);
        if (readData[7:0] !== 8'ha5 || readData[23:16] !== 8'd1)
            $fatal(1, "Final MMIO register values are wrong");

        // MMIO 窗口内尚未分配的字地址不能锁死 CPU。
        @(negedge clock50MHz);
        mmio_valid = 1'b1;
        mmio_addr = 32'h0000_0004;
        mmio_wstrb = 4'd0;
        #1;
        if (!mmio_ready || mmio_rdata !== 32'd0)
            $fatal(1, "Unassigned MMIO address handling failed");

        $display("PASS: UARTTX MMIO byte registers, status, stall and loopback");
        $finish;
    end
endmodule

`default_nettype wire
