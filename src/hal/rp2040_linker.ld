/* RP2040 Memory Map
 * Flash: 2MB XIP at 0x10000000
 * SRAM:  256KB at 0x20000000
 *
 * Boot2 (256 bytes) is placed at flash origin (0x10000000).
 * The main program starts at 0x10000100 (after Boot2).
 */
MEMORY
{
    BOOT2  (rx)  : ORIGIN = 0x10000000, LENGTH = 256
    FLASH  (rx)  : ORIGIN = 0x10000100, LENGTH = 2048K - 256
    RAM    (rwx) : ORIGIN = 0x20000000, LENGTH = 256K
}

ENTRY(_start);

SECTIONS
{
    /* Boot2 second stage bootloader (256 bytes at flash origin) */
    .boot2 : {
        KEEP(*(.boot2))
        . = ORIGIN(BOOT2) + 0x100;
    } > BOOT2

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
