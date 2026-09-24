OUTPUT_ARCH("riscv")
ENTRY(_start)

/*
 * GW1N-9 PicoRV32 memory map
 *
 * 0x0000_0000 - 0x0000_3fff: UART-loaded program BSRAM
 * 0x0000_0000 - 0x0000_00ff: IRQ entry, padded (PROGADDR_IRQ, see vectors.S)
 * 0x0000_0100 - 0x0000_3fff: _start, .text / .rodata and the .data load image
 * 0x0000_4000 - 0x0000_7fff: data BSRAM
 *
 * There is no external SPI flash in the current system. Initialized data is
 * stored in the program image and must be copied to DATA_RAM by _start.
 */

__stack_size = 2K;
PROVIDE(_stack_size = __stack_size);

MEMORY
{
    PROGRAM_RAM (rx)  : ORIGIN = 0x00000000, LENGTH = 16K
    DATA_RAM    (rw)  : ORIGIN = 0x00004000, LENGTH = 16K
}

SECTIONS
{
    /*
     * Low-memory region, pinned to the base of PROGRAM_RAM.  It holds the IRQ
     * entry (PROGADDR_IRQ) and is padded up to _start, so that _start lands on
     * 0x00000100 = PROGADDR_RESET.  If the entry ever outgrows the window the
     * assignment below moves the location counter backwards and the link
     * fails, which is exactly the guard we want.
     */
    .vectors ORIGIN(PROGRAM_RAM) :
    {
        . = ALIGN(4);
        __vector_base = .;
        KEEP(*(.text.vectors .text.vectors.*))
        . = ORIGIN(PROGRAM_RAM) + 0x100;
        __vector_end = .;
    } > PROGRAM_RAM

    /*
     * start.S must place _start in .text.start.  It follows the IRQ window and
     * therefore sits at ORIGIN(PROGRAM_RAM) + 0x100.
     */
    .start :
    {
        . = ALIGN(4);
        __text_start = .;
        KEEP(*(.text.start .text.start.*))
    } > PROGRAM_RAM

    .text :
    {
        . = ALIGN(4);
        *(.text .text.*)
        *(.gnu.linkonce.t.*)

        . = ALIGN(4);
        __text_end = .;
    } > PROGRAM_RAM

    .rodata :
    {
        . = ALIGN(4);
        __rodata_start = .;

        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        *(.gnu.linkonce.r.*)
        *(.eh_frame .eh_frame.*)

        . = ALIGN(4);
        __rodata_end = .;
    } > PROGRAM_RAM

    /*
     * .data executes from DATA_RAM. Its initial bytes follow the read-only
     * program image in PROGRAM_RAM and are copied by the reset code.
     */
    .data :
    {
        . = ALIGN(4);
        __data_start = .;
        _data_vma = .;

        *(.data .data.*)
        *(.gnu.linkonce.d.*)

        . = ALIGN(8);
        PROVIDE(__global_pointer$ = . + 0x800);
        *(.sdata .sdata.*)
        *(.gnu.linkonce.s.*)

        . = ALIGN(4);
        __data_end = .;
        _edata = .;
    } > DATA_RAM AT > PROGRAM_RAM

    __data_load_start = LOADADDR(.data);
    __data_load_end = LOADADDR(.data) + SIZEOF(.data);
    _data_lma = __data_load_start;
    PROVIDE(_sidata = __data_load_start);
    PROVIDE(_sdata = __data_start);

    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        __bss_start = .;
        _sbss = .;

        *(.sbss .sbss.*)
        *(.gnu.linkonce.sb.*)
        *(.bss .bss.*)
        *(.gnu.linkonce.b.*)
        *(COMMON)

        . = ALIGN(4);
        __bss_end = .;
        _ebss = .;
    } > DATA_RAM

    . = ALIGN(8);
    __static_end = .;

    .stack ORIGIN(DATA_RAM) + LENGTH(DATA_RAM) - __stack_size (NOLOAD) :
    {
        . = ALIGN(16);
        __stack_bottom = .;

        . += __stack_size;

        __stack_top = .;
    } > DATA_RAM

    /DISCARD/ :
    {
        *(.comment)
        *(.note .note.*)
    }

    ASSERT(DEFINED(_start), "entry symbol _start is not defined")
    ASSERT(DEFINED(_irq_entry) && DEFINED(_irq_entry_end),
           "the IRQ entry is missing (is vectors.S linked?)")
    ASSERT(_irq_entry == ORIGIN(PROGRAM_RAM),
           "the IRQ entry must be located at 0x00000000 (PROGADDR_IRQ)")
    ASSERT(_irq_entry_end <= ORIGIN(PROGRAM_RAM) + 0x100,
           "the IRQ entry does not fit in the 0x100 bytes below _start")
    ASSERT(SIZEOF(.vectors) == 0x100,
           "the low-memory region must be 0x100 bytes long")
    ASSERT(_start == ORIGIN(PROGRAM_RAM) + 0x100,
           "_start must be located at 0x00000100 (PROGADDR_RESET)")
    ASSERT(__static_end <= __stack_bottom,
           "DATA_RAM overflow: static data overlaps the stack")
    ASSERT(__stack_top == ORIGIN(DATA_RAM) + LENGTH(DATA_RAM),
           "stack does not end at the top of DATA_RAM")
}
