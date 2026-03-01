// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! Hardware Abstraction Layer
//! Re-exports all HAL sub-modules.

pub const gpio = @import("gpio.zig");
pub const timer = @import("timer.zig");
pub const eeprom = @import("eeprom.zig");
pub const bootloader = @import("bootloader.zig");
pub const clock = @import("clock.zig");
pub const uart = @import("uart.zig");
pub const cdc_console = @import("cdc_console.zig");

/// Pin type alias
pub const Pin = gpio.Pin;

test {
    @import("std").testing.refAllDecls(@This());
}
