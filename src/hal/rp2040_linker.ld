/* RP2040 Memory Map
 * Flash: 2MB XIP at 0x10000000
 * SRAM:  256KB at 0x20000000
 *
 * Note: Boot2 (second stage bootloader, 256 bytes) will be
 * prepended separately when generating UF2 output.
 */
MEMORY
{
    FLASH  (rx)  : ORIGIN = 0x10000000, LENGTH = 2048K
    RAM    (rwx) : ORIGIN = 0x20000000, LENGTH = 256K
}

ENTRY(_start);

SECTIONS
{
    /* Vector table and code */
    .text : {
        KEEP(*(.vectors))
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
    } > FLASH

    /* Initialized data (loaded from flash, copied to RAM at startup) */
    .data : {
        _sdata = .;
        *(.data*)
        . = ALIGN(4);
        _edata = .;
    } > RAM AT > FLASH

    _sidata = LOADADDR(.data);

    /* Uninitialized data */
    .bss (NOLOAD) : {
        _sbss = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > RAM

    /* Stack (4KB) */
    .stack (NOLOAD) : {
        . = ALIGN(8);
        _stack_bottom = .;
        . += 0x1000;
        _stack_top = .;
    } > RAM

    _heap_start = .;
    _heap_end = ORIGIN(RAM) + LENGTH(RAM);
}
