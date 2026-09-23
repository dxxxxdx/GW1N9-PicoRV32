`timescale 1ns / 1ps

module tb_busManager;
    reg         mem_valid = 0;
    reg         mem_instr = 0;
    wire        mem_ready;
    reg  [31:0] mem_addr = 0;
    reg  [31:0] mem_wdata = 0;
    reg  [ 3:0] mem_wstrb = 0;
    wire [31:0] mem_rdata;

    wire flash_valid, flash_instr;
    reg  flash_ready = 0;
    wire [31:0] flash_addr, flash_wdata;
    wire [3:0] flash_wstrb;
    reg  [31:0] flash_rdata = 32'hf1a5_0001;

    wire sram_valid, sram_instr;
    reg  sram_ready = 0;
    wire [31:0] sram_addr, sram_wdata;
    wire [3:0] sram_wstrb;
    reg  [31:0] sram_rdata = 32'h5a00_0002;

    wire mmio_valid, mmio_instr;
    reg  mmio_ready = 0;
    wire [31:0] mmio_addr, mmio_wdata;
    wire [3:0] mmio_wstrb;
    reg  [31:0] mmio_rdata = 32'h1100_0003;

    wire reserved_valid, reserved_instr;
    reg  reserved_ready = 0;
    wire [31:0] reserved_addr, reserved_wdata;
    wire [3:0] reserved_wstrb;
    reg  [31:0] reserved_rdata = 32'h4e50_0004;
    wire unmapped_valid;

    busManager dut (
        .mem_valid(mem_valid), .mem_instr(mem_instr),
        .mem_ready(mem_ready), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),

        .flash_valid(flash_valid), .flash_instr(flash_instr),
        .flash_ready(flash_ready), .flash_addr(flash_addr),
        .flash_wdata(flash_wdata), .flash_wstrb(flash_wstrb),
        .flash_rdata(flash_rdata),

        .sram_valid(sram_valid), .sram_instr(sram_instr),
        .sram_ready(sram_ready), .sram_addr(sram_addr),
        .sram_wdata(sram_wdata), .sram_wstrb(sram_wstrb),
        .sram_rdata(sram_rdata),

        .mmio_valid(mmio_valid), .mmio_instr(mmio_instr),
        .mmio_ready(mmio_ready), .mmio_addr(mmio_addr),
        .mmio_wdata(mmio_wdata), .mmio_wstrb(mmio_wstrb),
        .mmio_rdata(mmio_rdata),

        .reserved_valid(reserved_valid),
        .reserved_instr(reserved_instr),
        .reserved_ready(reserved_ready),
        .reserved_addr(reserved_addr),
        .reserved_wdata(reserved_wdata),
        .reserved_wstrb(reserved_wstrb),
        .reserved_rdata(reserved_rdata),
        .unmapped_valid(unmapped_valid)
    );

    task clear_request;
        begin
            mem_valid = 0;
            mem_instr = 0;
            mem_addr = 0;
            mem_wdata = 0;
            mem_wstrb = 0;
            flash_ready = 0;
            sram_ready = 0;
            mmio_ready = 0;
            reserved_ready = 0;
            #1;
        end
    endtask

    task assert_one_hot;
        input expected_flash;
        input expected_sram;
        input expected_mmio;
        input expected_reserved;
        input expected_unmapped;
        begin
            if ({flash_valid, sram_valid, mmio_valid, reserved_valid,
                 unmapped_valid} !==
                {expected_flash, expected_sram, expected_mmio,
                 expected_reserved, expected_unmapped})
                $fatal(1, "Bad route at address %08x", mem_addr);
        end
    endtask

    initial begin
        #1;

        // Flash lower and upper boundaries, including backpressure.
        mem_valid = 1;
        mem_instr = 1;
        mem_addr = 32'h0000_0000;
        #1;
        assert_one_hot(1, 0, 0, 0, 0);
        if (flash_addr !== 0 || mem_ready !== 0 || !flash_instr)
            $fatal(1, "Flash lower boundary/backpressure failed");
        flash_ready = 1;
        #1;
        if (!mem_ready || mem_rdata !== flash_rdata)
            $fatal(1, "Flash response failed");
        mem_addr = 32'h0000_3ffc;
        #1;
        if (flash_addr !== 32'h0000_3ffc)
            $fatal(1, "Flash upper boundary failed");
        clear_request;

        // SRAM boundaries and write-side pass-through.
        mem_valid = 1;
        mem_addr = 32'h0000_4000;
        mem_wdata = 32'ha5a5_5a5a;
        mem_wstrb = 4'b0101;
        #1;
        assert_one_hot(0, 1, 0, 0, 0);
        if (sram_addr !== 0 || sram_wdata !== mem_wdata ||
            sram_wstrb !== mem_wstrb || mem_ready !== 0)
            $fatal(1, "SRAM forwarding failed");
        sram_ready = 1;
        #1;
        if (!mem_ready || mem_rdata !== sram_rdata)
            $fatal(1, "SRAM response failed");
        mem_addr = 32'h0000_7ffc;
        #1;
        if (sram_addr !== 32'h0000_3ffc)
            $fatal(1, "SRAM upper boundary failed");
        clear_request;

        // MMIO window boundaries.
        mem_valid = 1;
        mem_addr = 32'h0100_0000;
        mmio_ready = 1;
        #1;
        assert_one_hot(0, 0, 1, 0, 0);
        if (mmio_addr !== 0 || !mem_ready || mem_rdata !== mmio_rdata)
            $fatal(1, "MMIO lower boundary failed");
        mem_addr = 32'h0100_fffc;
        #1;
        if (mmio_addr !== 32'h0000_fffc)
            $fatal(1, "MMIO upper boundary failed");
        clear_request;

        // Reserved 4 MiB window boundaries.
        mem_valid = 1;
        mem_addr = 32'h0200_0000;
        reserved_ready = 1;
        #1;
        assert_one_hot(0, 0, 0, 1, 0);
        if (reserved_addr !== 0 || !mem_ready ||
            mem_rdata !== reserved_rdata)
            $fatal(1, "Reserved lower boundary failed");
        mem_addr = 32'h023f_fffc;
        #1;
        if (reserved_addr !== 32'h003f_fffc)
            $fatal(1, "Reserved upper boundary failed");
        clear_request;

        // Gaps complete immediately and return zero.
        mem_valid = 1;
        mem_addr = 32'h0000_8000;
        #1;
        assert_one_hot(0, 0, 0, 0, 1);
        if (!mem_ready || mem_rdata !== 0)
            $fatal(1, "Unmapped low gap failed");
        mem_addr = 32'h0101_0000;
        #1;
        assert_one_hot(0, 0, 0, 0, 1);
        if (!mem_ready || mem_rdata !== 0)
            $fatal(1, "Unmapped high gap failed");
        clear_request;

        // No target may be valid while the CPU bus is idle.
        assert_one_hot(0, 0, 0, 0, 0);
        if (mem_ready !== 0)
            $fatal(1, "mem_ready asserted while idle");

        $display("PASS: busManager address routing, offsets, data and backpressure");
        $finish;
    end
endmodule
