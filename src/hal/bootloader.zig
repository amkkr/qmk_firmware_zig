//! Bootloader interface for RP2040
//! Based on platforms/chibios/bootloader.c
//!
//! Provides bootloader_jump() to enter RP2040 BOOTSEL mode.

const builtin = @import("builtin");

const is_freestanding = builtin.os.tag == .freestanding;

// RP2040 watchdog registers for BOOTSEL reset
const rp2040 = if (is_freestanding) struct {
    const WATCHDOG_BASE: u32 = 0x40058000;
    const WATCHDOG_CTRL: *volatile u32 = @ptrFromInt(WATCHDOG_BASE + 0x00);
    const PSM_BASE: u32 = 0x40010000;
    const PSM_WDSEL: *volatile u32 = @ptrFromInt(PSM_BASE + 0x08);
} else struct {};

/// Jump to bootloader (RP2040 BOOTSEL mode)
/// On real hardware: triggers watchdog reset into USB boot mode.
/// In tests: no-op (or can be tracked via mock).
pub fn jump() noreturn {
    if (is_freestanding) {
        // RP2040 method: write magic to watchdog scratch registers
        // and trigger a reset. The ROM bootloader checks for the magic
        // value and enters BOOTSEL mode.
        const WATCHDOG_SCRATCH0: *volatile u32 = @ptrFromInt(0x4005800C);
        const WATCHDOG_SCRATCH4: *volatile u32 = @ptrFromInt(0x4005801C);

        // Magic values recognized by RP2040 ROM bootloader
        WATCHDOG_SCRATCH4.* = 0xB007C0D3;
        WATCHDOG_SCRATCH0.* = 0; // Disable flash boot

        // Trigger watchdog reset
        rp2040.PSM_WDSEL.* = 0x0001FFFF;
        rp2040.WATCHDOG_CTRL.* = 0x80000000 | 1; // Enable with very short timeout

        while (true) {
            asm volatile ("nop");
        }
    } else {
        // In tests, bootloader jump should not be called
        @panic("bootloader_jump called in test environment");
    }
}
