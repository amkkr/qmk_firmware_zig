//! action_tapping のテスト
//! C版 tests/basic/test_tapping.cpp に相当

const std = @import("std");
const testing = std.testing;

const action = @import("action.zig");
const action_code = @import("action_code.zig");
const event_mod = @import("event.zig");
const host_mod = @import("host.zig");
const report_mod = @import("report.zig");
const tapping = @import("action_tapping.zig");

const Action = action_code.Action;
const KeyRecord = event_mod.KeyRecord;
const KeyEvent = event_mod.KeyEvent;
const KeyboardReport = report_mod.KeyboardReport;

const MockDriver = @import("test_driver.zig").FixedTestDriver(32, 4);

// Test keymap resolver: maps (row, col) to action codes
// (0,0) = SFT_T(KC_A) = ACTION_MODS_TAP_KEY(0x02, 0x04)
// (0,1) = LT(1, KC_B)  = ACTION_LAYER_TAP_KEY(1, 0x05)
// (0,2) = KC_C          = ACTION_KEY(0x06)
// (0,3) = KC_D          = ACTION_KEY(0x07)
fn testActionResolver(ev: KeyEvent) Action {
    if (ev.key.row == 0) {
        return switch (ev.key.col) {
            0 => .{ .code = action_code.ACTION_MODS_TAP_KEY(0x02, 0x04) }, // SFT_T(KC_A)
            1 => .{ .code = action_code.ACTION_LAYER_TAP_KEY(1, 0x05) }, // LT(1, KC_B)
            2 => .{ .code = action_code.ACTION_KEY(0x06) }, // KC_C
            3 => .{ .code = action_code.ACTION_KEY(0x07) }, // KC_D
            else => .{ .code = action_code.ACTION_NO },
        };
    }
    return .{ .code = action_code.ACTION_NO };
}

fn setup() *MockDriver {
    const static = struct {
        var mock: MockDriver = .{};
    };
    action.reset();
    static.mock = .{};
    host_mod.setDriver(host_mod.HostDriver.from(&static.mock));
    action.setActionResolver(testActionResolver);
    return &static.mock;
}

fn teardown() void {
    host_mod.clearDriver();
}

fn tick(time: u16) void {
    var record = KeyRecord{ .event = KeyEvent.tick(time) };
    action.actionExec(&record);
}

fn press(row: u8, col: u8, time: u16) void {
    var record = KeyRecord{ .event = KeyEvent.keyPress(row, col, time) };
    action.actionExec(&record);
}

fn release(row: u8, col: u8, time: u16) void {
    var record = KeyRecord{ .event = KeyEvent.keyRelease(row, col, time) };
    action.actionExec(&record);
}

test "SFT_T tap: quick press and release sends KC_A" {
    const mock = setup();
    defer teardown();

    // Press SFT_T(KC_A) at time 100
    press(0, 0, 100);
    // Release within TAPPING_TERM at time 150
    release(0, 0, 150);

    // Should have sent reports: press KC_A, then release KC_A
    try testing.expect(mock.keyboard_count >= 2);

    // First report should have KC_A (0x04)
    try testing.expect(mock.keyboard_reports[0].hasKey(0x04));
    // Last report should be empty (key released)
    try testing.expect(mock.keyboard_reports[mock.keyboard_count - 1].isEmpty());
}

test "SFT_T hold: hold past TAPPING_TERM sends LSHIFT" {
    const mock = setup();
    defer teardown();

    // Press SFT_T(KC_A) at time 100
    press(0, 0, 100);

    // Tick past TAPPING_TERM
    tick(301);

    // Should have registered LSHIFT (held)
    try testing.expect(mock.keyboard_count >= 1);
    var found_shift = false;
    var i: usize = 0;
    while (i < mock.keyboard_count and i < 32) : (i += 1) {
        if (mock.keyboard_reports[i].mods & 0x02 != 0) {
            found_shift = true;
            break;
        }
    }
    try testing.expect(found_shift);

    // Release
    release(0, 0, 400);
    // After release, mods should be cleared
    try testing.expect(mock.keyboard_reports[mock.keyboard_count - 1].mods == 0);
}

test "LT tap: quick press and release sends KC_B" {
    const mock = setup();
    defer teardown();

    // Press LT(1, KC_B) at time 100
    press(0, 1, 100);
    // Release within TAPPING_TERM at time 150
    release(0, 1, 150);

    // Should have sent reports with KC_B (0x05)
    try testing.expect(mock.keyboard_count >= 2);
    try testing.expect(mock.keyboard_reports[0].hasKey(0x05));
    try testing.expect(mock.keyboard_reports[mock.keyboard_count - 1].isEmpty());
}

test "normal key press and release" {
    const mock = setup();
    defer teardown();

    // Press KC_C at time 100
    press(0, 2, 100);

    // Should register immediately (not a tap action)
    try testing.expect(mock.keyboard_count >= 1);
    try testing.expect(mock.keyboard_reports[0].hasKey(0x06));

    // Release KC_C at time 200
    release(0, 2, 200);
    try testing.expect(mock.keyboard_reports[mock.keyboard_count - 1].isEmpty());
}

test "tap then normal key" {
    const mock = setup();
    defer teardown();

    // Press SFT_T(KC_A) at time 100
    press(0, 0, 100);

    // Press KC_C at time 120 (interrupts the tap)
    press(0, 2, 120);

    // Release SFT_T(KC_A) at time 150 (within tapping term, but interrupted)
    release(0, 0, 150);

    // Release KC_C at time 200
    release(0, 2, 200);

    // The tapping key was interrupted by another key press
    // After all events, everything should be released
    try testing.expect(mock.keyboard_count >= 1);
}
