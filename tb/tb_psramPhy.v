`timescale 1ns / 1ps

// Minimal behavioral shells for the Gowin IOB primitives.  The test forces the
// PHY's IDDR outputs directly for reads; write testing only needs clocked ports.
module ODDR (
    input wire CLK, input wire D0, input wire D1, input wire TX,
    output reg Q0, output reg Q1
);
    always @(posedge CLK) begin
        Q0 <= D0;
        Q1 <= TX;
    end
    wire unused = D1;
endmodule

module IDDR (
    input wire CLK, input wire D, output reg Q0, output reg Q1
);
    always @(posedge CLK) begin
        Q0 <= D;
        Q1 <= D;
    end
endmodule

module tb_psramPhy;
    reg clk = 1'b0;
    reg clk_p = 1'b0;
    reg reset_n = 1'b0;
    always #5 clk = ~clk;
    initial begin
        #2.5;
        forever #5 clk_p = ~clk_p;
    end

    reg cmd_valid = 1'b0;
    wire cmd_ready;
    reg cmd_write = 1'b0;
    reg [21:0] cmd_addr = 22'd0;
    reg [6:0] cmd_words = 7'd1;
    reg [15:0] w_data = 16'h1111;
    reg [1:0] w_mask = 2'b00;
    wire w_take;
    wire [15:0] r_data;
    wire r_valid, r_last, busy, done, initDone;
    wire ck, ck_n, cs_n, psreset_n, rwds;
    wire [7:0] dq;

    psramPhy #(.FREQ_HZ(100_000), .LATENCY(3), .DIE_INDEX(0)) dut (
        .clk(clk), .clk_p(clk_p), .reset_n(reset_n),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_write(cmd_write), .cmd_addr(cmd_addr), .cmd_words(cmd_words),
        .w_data(w_data), .w_mask(w_mask), .w_take(w_take),
        .r_data(r_data), .r_valid(r_valid), .r_last(r_last),
        .busy(busy), .done(done), .initDone(initDone),
        .O_psram_ck(ck), .O_psram_ck_n(ck_n),
        .O_psram_cs_n(cs_n), .O_psram_reset_n(psreset_n),
        .IO_psram_rwds(rwds), .IO_psram_dq(dq)
    );

    integer writeBeats = 0;
    integer readBeats = 0;
    integer lastCount = 0;
    time previousTake = 0;
    always @(posedge clk) begin
        if (w_take) begin
            if (writeBeats != 0 && $time - previousTake != 10)
                $fatal(1, "write burst inserted a bubble");
            previousTake = $time;
            case (writeBeats)
                0: if (w_data !== 16'h1111) $fatal(1, "write beat0 mismatch");
                1: if (w_data !== 16'h2222) $fatal(1, "write beat1 mismatch");
                2: if (w_data !== 16'h3333) $fatal(1, "write beat2 mismatch");
                3: if (w_data !== 16'h4444) $fatal(1, "write beat3 mismatch");
                default: $fatal(1, "too many write beats");
            endcase
            writeBeats <= writeBeats + 1;
            w_data <= w_data + 16'h1111;
        end
        if (r_valid) begin
            if (r_data !== 16'ha55a)
                $fatal(1, "read data mismatch: %04x", r_data);
            readBeats <= readBeats + 1;
            if (r_last) lastCount <= lastCount + 1;
        end
    end

    integer timeout;
    initial begin
        repeat (4) @(negedge clk);
        reset_n = 1'b1;
        wait (initDone && cmd_ready);

        @(negedge clk);
        cmd_write = 1'b1;
        cmd_addr = 22'h000120;
        cmd_words = 7'd4;
        cmd_valid = 1'b1;
        @(negedge clk);
        cmd_valid = 1'b0;

        timeout = 0;
        while (!done && timeout < 80) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (!done || writeBeats != 4)
            $fatal(1, "four-beat write did not complete: beats=%0d", writeBeats);

        wait (cmd_ready);
        force dut.rwdsInRis = 1'b1;
        force dut.rwdsInFal = 1'b0;
        force dut.dqInRis = 8'ha5;
        force dut.dqInFal = 8'h5a;

        @(negedge clk);
        cmd_write = 1'b0;
        cmd_addr = 22'h000220;
        cmd_words = 7'd4;
        cmd_valid = 1'b1;
        @(negedge clk);
        cmd_valid = 1'b0;

        timeout = 0;
        while (!done && timeout < 80) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (!done || readBeats != 4 || lastCount != 1)
            $fatal(1, "four-beat read failed: beats=%0d last=%0d",
                   readBeats, lastCount);

        release dut.rwdsInRis;
        release dut.rwdsInFal;
        release dut.dqInRis;
        release dut.dqInFal;

        $display("PASS: psramPhy consecutive 16-bit write/read bursts");
        $finish;
    end
endmodule
