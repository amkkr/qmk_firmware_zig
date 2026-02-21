//! Hardware Abstraction Layer
//! Re-exports all HAL sub-modules.

pub const gpio = @import("gpio.zig");
pub const timer = @import("timer.zig");
pub const eeprom = @import("eeprom.zig");
pub const bootloader = @import("bootloader.zig");
pub const usb = @import("usb.zig");
pub const usb_descriptors = @import("usb_descriptors.zig");

/// Pin type alias
pub const Pin = gpio.Pin;

test {
    @import("std").testing.refAllDecls(@This());
}
