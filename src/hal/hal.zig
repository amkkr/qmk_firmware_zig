// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! Hardware Abstraction Layer
//! Re-exports all HAL sub-modules.

const builtin = @import("builtin");

pub const gpio = @import("gpio.zig");
pub const timer = @import("timer.zig");
pub const eeprom = @import("eeprom.zig");
pub const bootloader = @import("bootloader.zig");
pub const clock = @import("clock.zig");
pub const cdc_console = @import("cdc_console.zig");
pub const usb = @import("usb.zig");
pub const usb_descriptors = @import("usb_descriptors.zig");
pub const boot2 = @import("boot2.zig");
/// vector_table は ARM Cortex-M0+ 固有の inline asm (`bkpt #0`) を持つため
/// native test target ではコンパイル不可。 host ネイティブでは空 struct に置換する。
pub const vector_table = if (builtin.os.tag == .freestanding) @import("vector_table.zig") else struct {};

/// Pin type alias
pub const Pin = gpio.Pin;

test {
    @import("std").testing.refAllDecls(@This());
}
