`timescale 1ns / 1ps
`default_nettype none

// PicoRV32 native-memory bus address router.
//
// CPU address map (byte addresses):
//   0x0000_0000 - 0x0000_3fff : 16 KiB program memory window
//   0x0000_4000 - 0x0000_7fff : 16 KiB SRAM window
//   0x0100_0000 - 0x0100_ffff : 64 KiB MMIO window
//   0x0200_0000 - 0x023f_ffff : 4 MiB reserved window
//
// Downstream addresses are local byte offsets within the selected window.
// Every downstream port uses the same valid/ready transaction rule as the
// PicoRV32 native memory interface. A transaction completes on a rising edge
// where valid and ready are both high.
module busManager #(
    parameter [31:0] FLASH_BASE    = 32'h0000_0000,
    parameter [31:0] FLASH_MASK    = 32'hffff_c000,
    parameter [31:0] SRAM_BASE     = 32'h0000_4000,
    parameter [31:0] SRAM_MASK     = 32'hffff_c000,
    parameter [31:0] MMIO_BASE     = 32'h0100_0000,
    parameter [31:0] MMIO_MASK     = 32'hffff_0000,
    parameter [31:0] RESERVED_BASE = 32'h0200_0000,
    parameter [31:0] RESERVED_MASK = 32'hffc0_0000,

    // Unmapped reads return this value. With the default value, an unmapped
    // instruction fetch decodes as an illegal instruction and reaches trap
    // when CATCH_ILLINSN is enabled in PicoRV32.
    parameter [31:0] UNMAPPED_RDATA = 32'h0000_0000
) (
    // PicoRV32 master side
    input  wire        mem_valid,
    input  wire        mem_instr,
    output reg         mem_ready,
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [ 3:0] mem_wstrb,
    output reg  [31:0] mem_rdata,

    // Program-memory target. flash_addr is 0x0000 through 0x3fff.
    output wire        flash_valid,
    output wire        flash_instr,
    input  wire        flash_ready,
    output wire [31:0] flash_addr,
    output wire [31:0] flash_wdata,
    output wire [ 3:0] flash_wstrb,
    input  wire [31:0] flash_rdata,

    // SRAM target. sram_addr is 0x0000 through 0x3fff.
    output wire        sram_valid,
    output wire        sram_instr,
    input  wire        sram_ready,
    output wire [31:0] sram_addr,
    output wire [31:0] sram_wdata,
    output wire [ 3:0] sram_wstrb,
    input  wire [31:0] sram_rdata,

    // MMIO target. mmio_addr is 0x0000 through 0xffff.
    output wire        mmio_valid,
    output wire        mmio_instr,
    input  wire        mmio_ready,
    output wire [31:0] mmio_addr,
    output wire [31:0] mmio_wdata,
    output wire [ 3:0] mmio_wstrb,
    input  wire [31:0] mmio_rdata,

    // Reserved target. reserved_addr is 0x0000_0000 through 0x003f_ffff.
    // Until a device is attached, tie reserved_ready high and reserved_rdata
    // to zero so accidental accesses do not stall the CPU forever.
    output wire        reserved_valid,
    output wire        reserved_instr,
    input  wire        reserved_ready,
    output wire [31:0] reserved_addr,
    output wire [31:0] reserved_wdata,
    output wire [ 3:0] reserved_wstrb,
    input  wire [31:0] reserved_rdata,

    // High only while the CPU is requesting an address outside every window.
    // Such accesses are completed immediately using UNMAPPED_RDATA.
    output wire        unmapped_valid
);
    wire flash_select;
    wire sram_select;
    wire mmio_select;
    wire reserved_select;

    assign flash_select = (mem_addr & FLASH_MASK) ==
                          (FLASH_BASE & FLASH_MASK);
    assign sram_select = (mem_addr & SRAM_MASK) ==
                         (SRAM_BASE & SRAM_MASK);
    assign mmio_select = (mem_addr & MMIO_MASK) ==
                         (MMIO_BASE & MMIO_MASK);
    assign reserved_select = (mem_addr & RESERVED_MASK) ==
                             (RESERVED_BASE & RESERVED_MASK);

    // Only the selected target sees mem_valid. Address, data and strobes are
    // combinational pass-through signals and remain stable because PicoRV32
    // holds its request stable until mem_ready is returned.
    assign flash_valid = mem_valid && flash_select;
    assign sram_valid = mem_valid && sram_select;
    assign mmio_valid = mem_valid && mmio_select;
    assign reserved_valid = mem_valid && reserved_select;

    assign flash_instr = mem_instr;
    assign sram_instr = mem_instr;
    assign mmio_instr = mem_instr;
    assign reserved_instr = mem_instr;

    assign flash_addr = mem_addr - FLASH_BASE;
    assign sram_addr = mem_addr - SRAM_BASE;
    assign mmio_addr = mem_addr - MMIO_BASE;
    assign reserved_addr = mem_addr - RESERVED_BASE;

    assign flash_wdata = mem_wdata;
    assign sram_wdata = mem_wdata;
    assign mmio_wdata = mem_wdata;
    assign reserved_wdata = mem_wdata;

    assign flash_wstrb = mem_wstrb;
    assign sram_wstrb = mem_wstrb;
    assign mmio_wstrb = mem_wstrb;
    assign reserved_wstrb = mem_wstrb;

    assign unmapped_valid = mem_valid && !flash_select && !sram_select &&
                            !mmio_select && !reserved_select;

    // Return only the selected target's response to the CPU. The ready input
    // is additionally gated with mem_valid, so an idle target cannot create a
    // spurious completion on the CPU side.
    always @* begin
        mem_ready = 1'b0;
        mem_rdata = UNMAPPED_RDATA;

        if (flash_select) begin
            mem_ready = mem_valid && flash_ready;
            mem_rdata = flash_rdata;
        end else if (sram_select) begin
            mem_ready = mem_valid && sram_ready;
            mem_rdata = sram_rdata;
        end else if (mmio_select) begin
            mem_ready = mem_valid && mmio_ready;
            mem_rdata = mmio_rdata;
        end else if (reserved_select) begin
            mem_ready = mem_valid && reserved_ready;
            mem_rdata = reserved_rdata;
        end else begin
            // Finish unmapped reads and writes immediately. Writes are
            // discarded; reads return UNMAPPED_RDATA.
            mem_ready = mem_valid;
            mem_rdata = UNMAPPED_RDATA;
        end
    end
endmodule

`default_nettype wire
