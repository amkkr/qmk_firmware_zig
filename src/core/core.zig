//! QMK Core module - data types and logic
//! Re-exports all core sub-modules.

const builtin = @import("builtin");

pub const keycode = @import("keycode.zig");
pub const action_code = @import("action_code.zig");
pub const event = @import("event.zig");
pub const report = @import("report.zig");
pub const matrix = @import("matrix.zig");
pub const debounce_mod = @import("debounce.zig");

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
pub const Matrix = matrix.Matrix;

// Test-only types (not compiled into firmware)
pub usingnamespace if (builtin.is_test) struct {
    pub const test_driver = @import("test_driver.zig");
    pub const test_fixture = @import("test_fixture.zig");
    pub const TestDriver = @import("test_driver.zig").TestDriver;
    pub const TestFixture = @import("test_fixture.zig").TestFixture;
    pub const KeymapKey = @import("test_fixture.zig").KeymapKey;
} else struct {};

test {
    @import("std").testing.refAllDecls(@This());
}
