//! QMK Core module - data types and logic
//! Re-exports all core sub-modules.

pub const keycode = @import("keycode.zig");
pub const action_code = @import("action_code.zig");
pub const event = @import("event.zig");
pub const report = @import("report.zig");

// Commonly used types
pub const Keycode = keycode.Keycode;
pub const KC = keycode.KC;
pub const Action = action_code.Action;
pub const KeyEvent = event.KeyEvent;
pub const KeyRecord = event.KeyRecord;
pub const KeyPos = event.KeyPos;
pub const KeyboardReport = report.KeyboardReport;
pub const MouseReport = report.MouseReport;
pub const ExtraReport = report.ExtraReport;

test {
    @import("std").testing.refAllDecls(@This());
}
