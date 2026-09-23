`timescale 1ns / 1ps
`default_nettype none

// PicoRV32 数据存储器：16 KiB，同步读写，支持逐字节写使能。
// busManager 已将 CPU 的 0x0000_4000~0x0000_7fff 转换为本模块看到的
// 0x0000~0x3fff 局部地址。
module rv32RegisterRam #(
    parameter integer WORDS = 4096
) (
    input  wire        clk,
    input  wire        reset_n,
    input  wire        mem_valid,
    output reg         mem_ready,
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [ 3:0] mem_wstrb,
    output reg  [31:0] mem_rdata
);
    // 请求 GowinSynthesis 使用 BSRAM。不要给整个数组添加复位或初始化
    // 循环，否则可能退化成大量逻辑寄存器；软件不能假设上电内容为零。
    reg [31:0] memory [0:WORDS-1]
        /* synthesis syn_ramstyle = "block_ram" */;

    wire [11:0] word_addr = mem_addr[13:2];

    always @(posedge clk) begin
        if (!reset_n) begin
            mem_ready <= 1'b0;
            mem_rdata <= 32'd0;
        end else begin
            if (mem_ready) begin
                mem_ready <= 1'b0;
            end else if (mem_valid) begin
                mem_rdata <= memory[word_addr];

                // PicoRV32 用 wstrb 指明 SB/SH/SW 实际写入的字节通道。
                if (mem_wstrb[0]) memory[word_addr][ 7: 0] <= mem_wdata[ 7: 0];
                if (mem_wstrb[1]) memory[word_addr][15: 8] <= mem_wdata[15: 8];
                if (mem_wstrb[2]) memory[word_addr][23:16] <= mem_wdata[23:16];
                if (mem_wstrb[3]) memory[word_addr][31:24] <= mem_wdata[31:24];
                mem_ready <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
