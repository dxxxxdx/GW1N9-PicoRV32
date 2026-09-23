`timescale 1ns / 1ps
`default_nettype none

// 第一版程序存储器：16 KiB，由 UART 裸字节流写入，由 PicoRV32 取指。
//
// 总线把 0x0000_0000~0x0000_3fff 转换为本模块的局部地址。CPU 启动前，
// 顶层一直保持 cpuReset_n=0；按下 START 封存程序后，loader_we 不再产生，
// 因此 UART 写端口与 CPU 读端口不会同时访问存储器。
//
// 这里虽然挂在 busManager 的 flash_* 端口上，当前实现仍是 FPGA 内部
// BSRAM，不是板外 SPI Flash。以后接入 SPI Flash 时可以替换本模块。
module uartProgramMemory #(
    parameter integer WORDS = 4096
) (
    input  wire        clk,
    input  wire        reset_n,

    input  wire        loader_we,
    input  wire [13:0] loader_addr,
    input  wire [ 7:0] loader_wdata,

    input  wire        mem_valid,
    output reg         mem_ready,
    input  wire [31:0] mem_addr,
    output reg  [31:0] mem_rdata
);
    // GowinSynthesis SUG550 的 RAM 映射属性：请求使用器件 BSRAM。
    // 存储数组不能整体复位，否则综合器通常无法把它推导成块 RAM。
    reg [31:0] memory [0:WORDS-1]
        /* synthesis syn_ramstyle = "block_ram" */;

    wire [11:0] loader_word_addr = loader_addr[13:2];
    wire [11:0] cpu_word_addr = mem_addr[13:2];

    always @(posedge clk) begin
        if (!reset_n) begin
            mem_ready <= 1'b0;
            mem_rdata <= 32'd0;
        end else begin
            // 同步读：请求沿读取 BSRAM，下一拍用 ready/rdata 完成事务。
            // ready 只保持一拍，避免同一个 mem_valid 被重复接受。
            if (mem_ready) begin
                mem_ready <= 1'b0;
            end else if (mem_valid) begin
                mem_rdata <= memory[cpu_word_addr];
                mem_ready <= 1'b1;
            end

            // UART 下载按小端字节顺序依次写入程序地址。
            if (loader_we) begin
                case (loader_addr[1:0])
                    2'd0: memory[loader_word_addr][ 7: 0] <= loader_wdata;
                    2'd1: memory[loader_word_addr][15: 8] <= loader_wdata;
                    2'd2: memory[loader_word_addr][23:16] <= loader_wdata;
                    2'd3: memory[loader_word_addr][31:24] <= loader_wdata;
                endcase
            end
        end
    end
endmodule

`default_nettype wire
