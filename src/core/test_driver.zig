//! Mock Host Driver for testing
//! Zig equivalent of tests/test_common/test_driver.cpp
//!
//! Captures HID reports sent by the keyboard firmware for verification in tests.

const std = @import("std");
const report = @import("report.zig");
const KeyboardReport = report.KeyboardReport;
const MouseReport = report.MouseReport;
const ExtraReport = report.ExtraReport;

/// Fixed-size buffer mock driver for testing.
/// Replaces per-file MockDriver definitions with a single reusable type.
pub fn FixedTestDriver(comptime keyboard_capacity: usize, comptime extra_capacity: usize) type {
    return struct {
        keyboard_count: usize = 0,
        mouse_count: usize = 0,
        extra_count: usize = 0,
        keyboard_reports: [keyboard_capacity]KeyboardReport = [_]KeyboardReport{KeyboardReport{}} ** keyboard_capacity,
        extra_reports: [extra_capacity]ExtraReport = [_]ExtraReport{ExtraReport{}} ** extra_capacity,
        leds: u8 = 0,

        const Self = @This();

        pub fn keyboardLeds(self: *Self) u8 {
            return self.leds;
        }

        pub fn sendKeyboard(self: *Self, r: KeyboardReport) void {
            if (self.keyboard_count < keyboard_capacity) {
                self.keyboard_reports[self.keyboard_count] = r;
            }
            self.keyboard_count += 1;
        }

        pub fn sendMouse(self: *Self, _: MouseReport) void {
            self.mouse_count += 1;
        }

        pub fn sendExtra(self: *Self, r: ExtraReport) void {
            if (self.extra_count < extra_capacity) {
                self.extra_reports[self.extra_count] = r;
            }
            self.extra_count += 1;
        }

        pub fn lastKeyboardReport(self: *const Self) KeyboardReport {
            if (self.keyboard_count == 0) return KeyboardReport{};
            const idx = if (self.keyboard_count > keyboard_capacity) keyboard_capacity - 1 else self.keyboard_count - 1;
            return self.keyboard_reports[idx];
        }

        pub fn lastExtraReport(self: *const Self) ExtraReport {
            if (self.extra_count == 0) return ExtraReport{};
            const idx = if (self.extra_count > extra_capacity) extra_capacity - 1 else self.extra_count - 1;
            return self.extra_reports[idx];
        }

        pub fn reset(self: *Self) void {
            self.keyboard_count = 0;
            self.mouse_count = 0;
            self.extra_count = 0;
            self.keyboard_reports = [_]KeyboardReport{KeyboardReport{}} ** keyboard_capacity;
            self.extra_reports = [_]ExtraReport{ExtraReport{}} ** extra_capacity;
            self.leds = 0;
        }
    };
}

// ============================================================
// Tests
// ============================================================

test "FixedTestDriver captures keyboard reports" {
    var driver: FixedTestDriver(8, 4) = .{};

    var r = KeyboardReport{};
    _ = r.addKey(0x04);
    driver.sendKeyboard(r);

    try std.testing.expectEqual(@as(usize, 1), driver.keyboard_count);
    try std.testing.expect(driver.lastKeyboardReport().hasKey(0x04));
}

test "FixedTestDriver captures extra reports" {
    var driver: FixedTestDriver(8, 4) = .{};

    driver.sendExtra(ExtraReport{});
    try std.testing.expectEqual(@as(usize, 1), driver.extra_count);
}

test "FixedTestDriver reset clears all state" {
    var driver: FixedTestDriver(8, 4) = .{};

    driver.sendKeyboard(KeyboardReport{});
    driver.sendMouse(MouseReport{});
    driver.sendExtra(ExtraReport{});
    driver.leds = 0xFF;
    driver.reset();

    try std.testing.expectEqual(@as(usize, 0), driver.keyboard_count);
    try std.testing.expectEqual(@as(usize, 0), driver.mouse_count);
    try std.testing.expectEqual(@as(usize, 0), driver.extra_count);
    try std.testing.expectEqual(@as(u8, 0), driver.leds);
}

test "FixedTestDriver overflow does not crash" {
    var driver: FixedTestDriver(2, 1) = .{};

    // Send more than capacity
    driver.sendKeyboard(KeyboardReport{});
    driver.sendKeyboard(KeyboardReport{});
    driver.sendKeyboard(KeyboardReport{}); // overflow

    try std.testing.expectEqual(@as(usize, 3), driver.keyboard_count);
    // lastKeyboardReport returns the last stored entry
    _ = driver.lastKeyboardReport();
}
