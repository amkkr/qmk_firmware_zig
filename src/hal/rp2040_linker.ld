/* RP2040 Memory Map
 * Flash:     2MB XIP at 0x10000000
 * SRAM:      256KB at 0x20000000
 * Scratch X: 4KB at 0x20040000
 * Scratch Y: 4KB at 0x20041000
 *
 * Boot2 (256 bytes) is placed at flash origin (0x10000000).
 * The main program starts at 0x10000100 (after Boot2).
 * The last 4KB sector (0x101FF000) is reserved for EEPROM emulation.
 *
 * Stack is placed in scratch RAM (separate from main SRAM) to prevent
 * stack overflow from corrupting .data/.bss sections.
 * ChibiOS (C version) also uses scratch RAM for the initial stack.
 */
MEMORY
{
    FLASH       (rx)  : ORIGIN = 0x10000000, LENGTH = 2048K - 4K
    RAM         (rwx) : ORIGIN = 0x20000000, LENGTH = 256K
    SCRATCH_RAM (rwx) : ORIGIN = 0x20040000, LENGTH = 8K
}

ENTRY(_start);

SECTIONS
{
    /* Boot2 + vector table + code in single FLASH region.
     * Placing .boot2 and .text in the same memory region ensures they share
     * a single LOAD segment with executable flag, which is required for
     * Zig's objcopy to correctly include boot2 data in the raw binary. */
    .text : {
        KEEP(*(.boot2))
        . = ORIGIN(FLASH) + 0x100;
        KEEP(*(.vectors))
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
    } > FLASH

    /* ARM exception handling sections (placed in FLASH, not BOOT2) */
    .ARM.extab : { *(.ARM.extab*) } > FLASH
    .ARM.exidx : { *(.ARM.exidx*) } > FLASH

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

    /* Stack in scratch RAM (8KB, separate from main SRAM)
     * ChibiOS uses scratch_y for the initial stack (SP=0x20040400).
     * We use the full scratch area (scratch_x + scratch_y = 8KB) since
     * there is no RTOS and everything runs on the main stack. */
    .stack (NOLOAD) : {
        . = ALIGN(8);
        _stack_bottom = .;
        . += 0x2000;
        _stack_top = .;
    } > SCRATCH_RAM

    _heap_start = .;
    _heap_end = ORIGIN(RAM) + LENGTH(RAM);
}
