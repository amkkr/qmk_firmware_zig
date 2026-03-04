// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! Bootloader interface for RP2040
//! Based on platforms/chibios/bootloader.c
//!
//! Provides bootloader_jump() to enter RP2040 BOOTSEL mode.
//! Uses the ROM function `reset_usb_boot` ("UB") for pico-sdk compatible
//! BOOTSEL mode transition (RP2040 datasheet S2.8.3).

const std = @import("std");
const builtin = @import("builtin");

const is_freestanding = builtin.os.tag == .freestanding;

// RP2040 ROM function table (freestanding only)
const rom = if (is_freestanding) struct {
    const ROM_TABLE_LOOKUP_ADDR: u32 = 0x00000018;
    const ROM_FUNC_TABLE_ADDR: u32 = 0x00000014;

    /// Look up a ROM function by its two-character code.
    /// Same pattern as eeprom.zig romFuncLookup.
    inline fn romFuncLookup(code: [2]u8) usize {
        const rom_table_lookup: *const fn (table: u16, code: u32) callconv(.c) usize =
            @ptrFromInt(@as(u32, @as(*const u16, @ptrFromInt(ROM_TABLE_LOOKUP_ADDR)).*));
        const func_table: u16 = @as(*const u16, @ptrFromInt(ROM_FUNC_TABLE_ADDR)).*;
        return rom_table_lookup(func_table, @as(u32, code[0]) | (@as(u32, code[1]) << 8));
    }

    /// reset_usb_boot(gpio_activity_pin_mask: u32, disable_interface_mask: u32)
    /// ROM function "UB": reboots into BOOTSEL (USB mass storage) mode.
    inline fn resetUsbBoot(gpio_activity_pin_mask: u32, disable_interface_mask: u32) noreturn {
        const func: *const fn (u32, u32) callconv(.c) noreturn =
            @ptrFromInt(romFuncLookup("UB".*));
        func(gpio_activity_pin_mask, disable_interface_mask);
    }
} else struct {};

/// Jump to bootloader (RP2040 BOOTSEL mode)
/// On real hardware: calls ROM function reset_usb_boot ("UB") to enter
/// USB mass storage mode. This is the pico-sdk compatible method.
/// In tests: panics (bootloader jump should not be called in tests).
pub fn jump() noreturn {
    if (is_freestanding) {
        // Use ROM function "UB" (reset_usb_boot) for BOOTSEL mode.
        // gpio_activity_pin_mask=0: no GPIO activity LED
        // disable_interface_mask=0: enable both USB MSD and PICOBOOT interfaces
        rom.resetUsbBoot(0, 0);
    } else {
        // In tests, bootloader jump should not be called
        @panic("bootloader_jump called in test environment");
    }
}

const testing = std.testing;

test "is_freestanding is false in test builds" {
    try testing.expect(!is_freestanding);
}
