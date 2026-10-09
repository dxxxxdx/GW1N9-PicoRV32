    .section .text.start, "ax", @progbits
    .globl _start
    .type _start, @function
    .extern main
    .option norvc
    .option nopic
    .balign 4

/* UART TX byte registers. */
    .equ UART_TX_DATA,   0x01000000
    .equ UART_TX_ENABLE, 0x01000001
    .equ UART_TX_IDLE,   0x01000002

/* PSRAM status register: bit0 = initDone. */
    .equ PSRAM_STATUS,   0x03000004

_start:
    /*
     * Touch the UART before using DATA_RAM.  Loading the string address is
     * PC-relative and therefore does not require gp or initialized memory.
     */
    li      t0, UART_TX_DATA
    .option push
    .option norelax
    la      t1, .Lwelcome_message
    .option pop

.Luart_next:
    /* Wait until the transmitter has completed the previous byte. */
    lbu     t3, UART_TX_IDLE - UART_TX_DATA(t0)
    beqz    t3, .Luart_next

    lbu     t2, 0(t1)
    beqz    t2, .Luart_done

    sb      t2, UART_TX_DATA - UART_TX_DATA(t0)
    li      t3, 1
    sb      t3, UART_TX_ENABLE - UART_TX_DATA(t0)
    addi    t1, t1, 1
    j       .Luart_next

.Luart_done:
    /* Establish the RISC-V ABI registers before entering C code. */
    .option push
    .option norelax
    la      gp, __global_pointer$
    la      sp, __stack_top
    .option pop

    /* Copy initialized data from its program-image address to DATA_RAM. */
    la      t0, __data_load_start
    la      t1, __data_start
    la      t2, __data_end

.Lcopy_data:
    beq     t1, t2, .Lclear_bss_begin
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    j       .Lcopy_data

    /* Zero all statically allocated, uninitialized objects. */
.Lclear_bss_begin:
    la      t0, __bss_start
    la      t1, __bss_end

.Lclear_bss:
    beq     t0, t1, .Lwait_psram
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       .Lclear_bss

    /*
     * 等两路 PSRAM PHY 上电完成：cpuReset_n 放开后先等待 160us(tRPU 150us)
     * 再写一次 CR0 才算初始化好。这期间读状态寄存器是安全的，碰数据窗口
     * 只会把总线卡住——虽然结果一样，但在这里等掉，main 里的第一次访问
     * 就不会看起来像死机。
     *
     * 实际上上面的欢迎串要发 19 个字节约 1.6ms，早就初始化完了，
     * 这个循环正常是直接穿过去的，留着是防以后改短欢迎串。
     */
.Lwait_psram:
    /* PSRAM CK 相位已在 PLL 中固定为实测窗口中心档位 5。 */
    li      t0, PSRAM_STATUS
.Lpsram_poll:
    lw      t1, 0(t0)
    andi    t1, t1, 1
    beqz    t1, .Lpsram_poll

.Lenter_main:
    li      a0, 0
    li      a1, 0
    jal     ra, main

    /* main is not expected to return. */
.Lhang:
    j       .Lhang

    .size _start, . - _start

    .section .rodata
    .balign 4
.Lwelcome_message:
    .asciz "Welcome to GW1NR9 RISC-V\r\n"
