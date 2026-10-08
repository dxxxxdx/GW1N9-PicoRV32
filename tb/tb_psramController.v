`timescale 1ns / 1ps

// Transaction-level stub for one x8 die.  The real IOB PHY is intentionally
// excluded so this test can focus on bank selection, CDC, masks and handshake.
module psramPhy #(
    parameter integer FREQ_HZ = 80_000_000,
    parameter integer LATENCY = 3,
    parameter integer DIE_INDEX = 0
) (
    input wire clk, input wire clk_p, input wire reset_n,
    input wire start, input wire wr, input wire [21:0] byteAddr,
    input wire [1:0] wmask, input wire [15:0] dIn,
    output reg [15:0] dOut, output reg busy, output reg done,
    output reg initDone,
    output wire O_psram_ck, output wire O_psram_ck_n,
    output wire O_psram_cs_n, output wire O_psram_reset_n,
    inout wire IO_psram_rwds, inout wire [7:0] IO_psram_dq
);
    integer requestCount;
    reg [21:0] logAddr [0:31];
    reg        logWr   [0:31];
    reg [1:0]  logMask [0:31];
    reg [15:0] logData [0:31];

    assign O_psram_ck = 1'b0;
    assign O_psram_ck_n = 1'b0;
    assign O_psram_cs_n = 1'b1;
    assign O_psram_reset_n = reset_n;
    assign IO_psram_rwds = 1'bz;
    assign IO_psram_dq = 8'hzz;

    wire unused = &{1'b0, clk_p, FREQ_HZ[0], LATENCY[0]};

    always @(posedge clk) begin
        done <= 1'b0;
        if (!reset_n) begin
            dOut <= 16'd0;
            busy <= 1'b1;
            done <= 1'b0;
            initDone <= 1'b0;
            requestCount <= 0;
        end else begin
            initDone <= 1'b1;
            if (!initDone)
                busy <= 1'b0;
            if (start && !busy) begin
                logAddr[requestCount] <= byteAddr;
                logWr[requestCount] <= wr;
                logMask[requestCount] <= wmask;
                logData[requestCount] <= dIn;
                requestCount <= requestCount + 1;
                busy <= 1'b1;
            end else if (busy && initDone) begin
                dOut <= (DIE_INDEX ? 16'h8000 : 16'h0000) |
                        {logAddr[requestCount-1][7:1], 9'h155};
                done <= 1'b1;
                busy <= 1'b0;
            end
        end
    end
endmodule

module tb_psramController;
    reg clk = 1'b0;       // CPU clock
    reg phy_clk = 1'b0;   // 2x PHY clock
    reg clk_p = 1'b0;
    reg reset_n = 1'b0;
    always #10 clk = ~clk;
    always #5 phy_clk = ~phy_clk;
    initial begin
        #2.5;
        forever #5 clk_p = ~clk_p;
    end

    reg mem_valid = 1'b0;
    wire mem_ready;
    reg [31:0] mem_addr = 32'd0;
    reg [31:0] mem_wdata = 32'd0;
    reg [3:0] mem_wstrb = 4'd0;
    wire [31:0] mem_rdata;

    reg cfg_valid = 1'b0;
    wire cfg_ready;
    reg [11:0] cfg_addr = 12'd0;
    reg [31:0] cfg_wdata = 32'd0;
    reg [3:0] cfg_wstrb = 4'd0;
    wire [31:0] cfg_rdata;

    reg gpu_valid = 1'b0;
    wire gpu_ready;
    reg gpu_wr = 1'b0;
    reg [21:0] gpu_addr = 22'd0;
    reg [1:0] gpu_mask = 2'b11;
    reg [15:0] gpu_wdata = 16'd0;
    wire [15:0] gpu_rdata;
    wire gpu_done;

    reg hdmi_valid = 1'b0;
    wire hdmi_ready;
    reg [21:0] hdmi_addr = 22'd0;
    wire [15:0] hdmi_rdata;
    wire hdmi_done;
    reg hdmi_frame_done = 1'b0;
    wire frame_swap_request;

    wire [3:0] phase;
    wire [1:0] ck, ck_n, cs_n, psreset_n;
    wire [1:0] rwds;
    wire [15:0] dq;

    psramController dut (
        .clk(clk), .phy_clk(phy_clk), .clk_p(clk_p), .reset_n(reset_n),
        .mem_valid(mem_valid), .mem_ready(mem_ready), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb), .mem_rdata(mem_rdata),
        .cfg_valid(cfg_valid), .cfg_ready(cfg_ready), .cfg_addr(cfg_addr),
        .cfg_wdata(cfg_wdata), .cfg_wstrb(cfg_wstrb), .cfg_rdata(cfg_rdata),
        .gpu_valid(gpu_valid), .gpu_ready(gpu_ready), .gpu_wr(gpu_wr),
        .gpu_addr(gpu_addr), .gpu_mask(gpu_mask), .gpu_wdata(gpu_wdata),
        .gpu_rdata(gpu_rdata), .gpu_done(gpu_done),
        .hdmi_valid(hdmi_valid), .hdmi_ready(hdmi_ready),
        .hdmi_addr(hdmi_addr), .hdmi_rdata(hdmi_rdata),
        .hdmi_done(hdmi_done), .hdmi_frame_done(hdmi_frame_done),
        .frame_swap_request(frame_swap_request),
        .ckPhase(phase), .O_psram_ck(ck), .O_psram_ck_n(ck_n),
        .O_psram_cs_n(cs_n), .O_psram_reset_n(psreset_n),
        .IO_psram_rwds(rwds), .IO_psram_dq(dq)
    );

    task transact;
        input [31:0] addr;
        input [31:0] data;
        input [3:0] strb;
        begin
            @(negedge clk);
            mem_addr = addr;
            mem_wdata = data;
            mem_wstrb = strb;
            mem_valid = 1'b1;
            while (!mem_ready)
                @(negedge clk);
            // Keep valid asserted for another cycle; it must not be replayed.
            @(negedge clk);
            mem_valid = 1'b0;
            mem_wstrb = 4'd0;
            @(negedge clk);
        end
    endtask

    task cfg_write;
        input [11:0] addr;
        input [31:0] data;
        begin
            @(negedge clk);
            cfg_addr = addr;
            cfg_wdata = data;
            cfg_wstrb = 4'b1111;
            cfg_valid = 1'b1;
            while (!cfg_ready)
                @(negedge clk);
            cfg_valid = 1'b0;
            cfg_wstrb = 4'd0;
            @(negedge clk);
        end
    endtask

    task cfg_read;
        input [11:0] addr;
        input [31:0] expected;
        begin
            @(negedge clk);
            cfg_addr = addr;
            cfg_valid = 1'b1;
            while (!cfg_ready)
                @(negedge clk);
            if (cfg_rdata !== expected)
                $fatal(1, "cfg %03x got %08x expected %08x",
                       addr, cfg_rdata, expected);
            cfg_valid = 1'b0;
            @(negedge clk);
        end
    endtask

    integer base0;
    integer base1;
    reg [31:0] expectedRead;
    initial begin
        repeat (4) @(negedge clk);
        reset_n = 1'b1;
        wait (dut.initDoneCpu);
        repeat (3) @(negedge clk);

        if (phase !== 4'd5)
            $fatal(1, "phase did not reset to trained tap 5");

        // The only CPU-visible window initially maps to back die 0.
        base0 = dut.phy0.requestCount;
        base1 = dut.phy1.requestCount;
        transact(32'h003f_fffc, 32'h1122_3344, 4'b1111);
        if (dut.phy0.requestCount != base0 + 2 ||
            dut.phy1.requestCount != base1 ||
            dut.phy0.logAddr[base0] !== 22'h3f_fffc ||
            dut.phy0.logAddr[base0+1] !== 22'h3f_fffe ||
            dut.phy0.logData[base0] !== 16'h3344 ||
            dut.phy0.logData[base0+1] !== 16'h1122 ||
            dut.phy0.logMask[base0] !== 2'b00 ||
            dut.phy0.logMask[base0+1] !== 2'b00)
            $fatal(1, "logical back window did not route to die 0");

        // MMIO request + software frame boundary flips only the ownership map.
        cfg_write(12'h018, 32'h0000_0003);
        wait (dut.swapCountCpu == 16'd1);
        repeat (3) @(negedge clk);
        cfg_read(12'h018, 32'h0001_0004); // front=0, back=1, no pending

        // The same logical CPU address now reaches physical die 1.
        base0 = dut.phy0.requestCount;
        base1 = dut.phy1.requestCount;
        transact(32'h0000_0000, 32'ha1b2_c3d4, 4'b1111);
        if (dut.phy0.requestCount != base0 ||
            dut.phy1.requestCount != base1 + 2 ||
            dut.phy1.logAddr[base1] !== 22'h000000 ||
            dut.phy1.logAddr[base1+1] !== 22'h000002)
            $fatal(1, "swapped logical window did not route to die 1");

        // Byte lane 2: skip the low half and preserve the other byte.
        base1 = dut.phy1.requestCount;
        transact(32'h0000_0100, 32'ha1b2_c3d4, 4'b0100);
        if (dut.phy1.requestCount != base1 + 1 ||
            dut.phy1.logAddr[base1] !== 22'h000102 ||
            dut.phy1.logData[base1] !== 16'ha1b2 ||
            dut.phy1.logMask[base1] !== 2'b10)
            $fatal(1, "bank 1 upper byte-lane write failed");

        // Reads concatenate both halfwords from the currently selected back die.
        base1 = dut.phy1.requestCount;
        transact(32'h0000_0300, 32'd0, 4'b0000);
        expectedRead = 32'h8355_8155;
        if (dut.phy1.requestCount != base1 + 2 ||
            dut.phy1.logWr[base1] !== 1'b0 ||
            dut.phy1.logWr[base1+1] !== 1'b0 ||
            mem_rdata !== expectedRead)
            $fatal(1, "swapped die read/CDC failed: %08x", mem_rdata);

        // Request alone is sticky and must not swap before a frame boundary.
        cfg_write(12'h018, 32'h0000_0001);
        repeat (12) @(negedge clk);
        if (!frame_swap_request || dut.swapCountCpu != 16'd1)
            $fatal(1, "swap request did not wait for frame boundary");
        cfg_write(12'h018, 32'h0000_0002);
        wait (dut.swapCountCpu == 16'd2);
        repeat (3) @(negedge clk);
        cfg_read(12'h018, 32'h0002_0002); // front=1, back=0, no pending

        cfg_read(12'h000, 32'd80_000_000);
        cfg_read(12'h008, 32'd5);
        cfg_write(12'h008, 32'd11);
        cfg_read(12'h008, 32'd11);
        if (phase !== 4'd11)
            $fatal(1, "dynamic phase write failed");
        cfg_read(12'h00c, 32'h5053_5253);
        cfg_read(12'h014, 32'h0040_0000);
        cfg_read(12'h01c, 32'h0080_0000);

        $display("PASS: logical back window, frame swap, CDC, masks and handshake");
        $finish;
    end
endmodule
