//! QMK Core module - data types and logic
//! Re-exports all core sub-modules.

pub const keycode = @import("keycode.zig");
pub const action_code = @import("action_code.zig");
pub const event = @import("event.zig");
pub const report = @import("report.zig");
pub const matrix = @import("matrix.zig");
pub const debounce_mod = @import("debounce.zig");
pub const test_driver = @import("test_driver.zig");
pub const test_fixture = @import("test_fixture.zig");

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

// Test types
pub const TestDriver = test_driver.TestDriver;
pub const TestFixture = test_fixture.TestFixture;
pub const KeymapKey = test_fixture.KeymapKey;

test {
    @import("std").testing.refAllDecls(@This());
}
