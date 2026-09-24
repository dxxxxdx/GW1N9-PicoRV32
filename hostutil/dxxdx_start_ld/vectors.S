/*
 * Low-memory layout for the GW1N-9 PicoRV32 system.
 *
 *   0x00000000 - 0x000000ff   IRQ entry   <- PROGADDR_IRQ
 *   0x00000100                _start      <- PROGADDR_RESET
 *
 * PicoRV32 does not vector interrupts: every IRQ jumps to the single fixed
 * address PROGADDR_IRQ.  The hardware only stores the interrupted PC into q0
 * and the pending mask into q1 - it pushes nothing.  So this entry saves the
 * context itself, calls a C dispatcher, and leaves through `retirq`.
 *
 * PicoRV32 has no CSR file and no mret.  retirq/getq/maskirq are custom
 * opcodes that binutils does not know, hence the raw .word encodings below:
 *
 *   getq   a0, q1   0x0000850b   a0 = pending & ~irq_mask
 *   retirq          0x0400000b   jump back to q0, clear irq_active, pulse eoi
 *
 * The handler is 148 bytes, so the IRQ window below _start is 0x100 bytes.
 *
 * Only caller-saved registers are saved: a C function must preserve the
 * callee-saved ones (s0-s11, sp, gp) by the ABI, so the interrupt stays
 * transparent to whatever code was running.  Interrupts cannot nest, because
 * irq_active stays set until `retirq`.
 */

    .section .text.vectors, "ax", @progbits
    .option norvc
    .option nopic
    .balign 4

    .globl _irq_entry
    .type _irq_entry, @function

_irq_entry:                         /* 0x00, must equal PROGADDR_IRQ */
    addi    sp, sp, -64

    sw      ra,  0(sp)
    sw      t0,  4(sp)
    sw      t1,  8(sp)
    sw      t2, 12(sp)
    sw      t3, 16(sp)
    sw      t4, 20(sp)
    sw      t5, 24(sp)
    sw      t6, 28(sp)
    sw      a0, 32(sp)
    sw      a1, 36(sp)
    sw      a2, 40(sp)
    sw      a3, 44(sp)
    sw      a4, 48(sp)
    sw      a5, 52(sp)
    sw      a6, 56(sp)
    sw      a7, 60(sp)

    /* a0 becomes the pending mask handed to irq_dispatch() */
    .word   0x0000850b              /* getq a0, q1 */

    call    irq_dispatch

    lw      ra,  0(sp)
    lw      t0,  4(sp)
    lw      t1,  8(sp)
    lw      t2, 12(sp)
    lw      t3, 16(sp)
    lw      t4, 20(sp)
    lw      t5, 24(sp)
    lw      t6, 28(sp)
    lw      a0, 32(sp)
    lw      a1, 36(sp)
    lw      a2, 40(sp)
    lw      a3, 44(sp)
    lw      a4, 48(sp)
    lw      a5, 52(sp)
    lw      a6, 56(sp)
    lw      a7, 60(sp)

    addi    sp, sp, 64

    .word   0x0400000b              /* retirq */

    .globl _irq_entry_end
_irq_entry_end:
    .size _irq_entry, . - _irq_entry

/*
 * Weak fallback dispatcher so the firmware links before the real one exists.
 * Define a strong `void irq_dispatch(uint32_t pending)` in C and it replaces
 * this stub automatically.  Returning is safe: the hardware already cleared
 * the delivered pending bits and pulsed eoi on entry.
 */
    .section .text.irq, "ax", @progbits
    .balign 4
    .weak irq_dispatch
    .type irq_dispatch, @function
irq_dispatch:
    ret
    .size irq_dispatch, . - irq_dispatch
