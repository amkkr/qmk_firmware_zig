//! QMK Core module - data types and logic
//! Re-exports all core sub-modules.

const builtin = @import("builtin");

pub const keycode = @import("keycode.zig");
pub const action_code = @import("action_code.zig");
pub const event = @import("event.zig");
pub const report = @import("report.zig");
pub const matrix = @import("matrix.zig");
pub const debounce_mod = @import("debounce.zig");
pub const host_mod = @import("host.zig");
pub const layer = @import("layer.zig");
pub const action_mod = @import("action.zig");
pub const action_tapping = @import("action_tapping.zig");
pub const keymap = @import("keymap.zig");
pub const extrakey = @import("extrakey.zig");
pub const eeconfig = @import("eeconfig.zig");
pub const bootmagic = @import("bootmagic.zig");
pub const mousekey = @import("mousekey.zig");
pub const combo = @import("combo.zig");
pub const tap_dance = @import("tap_dance.zig");
pub const leader = @import("leader.zig");
pub const keyboard = @import("keyboard.zig");
pub const auto_shift = @import("auto_shift.zig");
pub const grave_esc = @import("grave_esc.zig");

// Test infrastructure - only included in test builds to avoid bloating firmware
pub const test_driver = if (builtin.is_test) @import("test_driver.zig") else struct {};
pub const test_fixture = if (builtin.is_test) @import("test_fixture.zig") else struct {};

// Commonly used types
pub const Keycode = keycode.Keycode;
pub const KC = keycode.KC;
pub const Action = action_code.Action;
pub const LayerState = layer.LayerState;
pub const KeyEvent = event.KeyEvent;
pub const KeyRecord = event.KeyRecord;
pub const KeyPos = event.KeyPos;
pub const KeyboardReport = report.KeyboardReport;
pub const MouseReport = report.MouseReport;
pub const ExtraReport = report.ExtraReport;
pub const Matrix = matrix.Matrix;
pub const HostDriver = host_mod.HostDriver;

// Test types (only available in test builds)
pub const TestFixture = if (builtin.is_test) test_fixture.TestFixture else void;
pub const KeymapKey = if (builtin.is_test) test_fixture.KeymapKey else void;

test {
    @import("std").testing.refAllDecls(@This());
}
