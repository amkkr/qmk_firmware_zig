/* RP2040 Memory Map
 * Flash: 2MB XIP at 0x10000000
 * SRAM:  256KB at 0x20000000
 *
 * Note: The first 256 bytes of flash (0x10000000-0x100000FF) are reserved
 * for boot2 (second stage bootloader). Boot2 configures XIP flash and
 * jumps to the reset handler at 0x10000104 (vector table offset 4).
 * Boot2 is prepended by uf2gen when building the UF2 firmware image.
 * Use `zig build uf2 -Dboot2=<path/to/boot2.bin>` to include it.
 * Boot2 binaries can be obtained from pico-sdk (boot_stage2/).
 */
MEMORY
{
    FLASH  (rx)  : ORIGIN = 0x10000100, LENGTH = 2048K - 256
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
