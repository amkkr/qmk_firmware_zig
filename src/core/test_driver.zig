//! Mock Host Driver for testing
//! Zig equivalent of tests/test_common/test_driver.cpp
//!
//! Captures HID reports sent by the keyboard firmware for verification in tests.

const std = @import("std");
const report = @import("report.zig");
const KeyboardReport = report.KeyboardReport;
const MouseReport = report.MouseReport;
const ExtraReport = report.ExtraReport;

/// Captured report entry
pub const CapturedReport = union(enum) {
    keyboard: KeyboardReport,
    mouse: MouseReport,
    extra: ExtraReport,
};

/// Mock host driver that captures all sent reports
pub const TestDriver = struct {
    /// All captured reports in order
    reports: std.ArrayListUnmanaged(CapturedReport) = .empty,
    /// Allocator for report storage
    allocator: std.mem.Allocator,
    /// LED state (set by host)
    leds: u8 = 0,

    pub fn init(allocator: std.mem.Allocator) TestDriver {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TestDriver) void {
        self.reports.deinit(self.allocator);
    }

    // ============================================================
    // Host driver interface (called by keyboard firmware)
    // ============================================================

    pub fn sendKeyboard(self: *TestDriver, r: KeyboardReport) void {
        self.reports.append(self.allocator, .{ .keyboard = r }) catch @panic("TestDriver: allocation failed");
    }

    pub fn sendMouse(self: *TestDriver, r: MouseReport) void {
        self.reports.append(self.allocator, .{ .mouse = r }) catch @panic("TestDriver: allocation failed");
    }

    pub fn sendExtra(self: *TestDriver, r: ExtraReport) void {
        self.reports.append(self.allocator, .{ .extra = r }) catch @panic("TestDriver: allocation failed");
    }

    pub fn keyboardLeds(self: *const TestDriver) u8 {
        return self.leds;
    }

    // ============================================================
    // Report verification helpers
    // ============================================================

    /// Get total number of captured reports
    pub fn reportCount(self: *const TestDriver) usize {
        return self.reports.items.len;
    }

    /// Get the last keyboard report, or null if none
    pub fn lastKeyboardReport(self: *const TestDriver) ?KeyboardReport {
        var i = self.reports.items.len;
        while (i > 0) {
            i -= 1;
            switch (self.reports.items[i]) {
                .keyboard => |r| return r,
                else => {},
            }
        }
        return null;
    }

    /// Check if a specific keyboard report was sent (in order)
    pub fn expectReport(self: *const TestDriver, index: usize, expected_mods: u8, expected_keys: []const u8) !void {
        var keyboard_index: usize = 0;
        for (self.reports.items) |entry| {
            switch (entry) {
                .keyboard => |r| {
                    if (keyboard_index == index) {
                        try std.testing.expectEqual(expected_mods, r.mods);
                        for (expected_keys) |ek| {
                            if (!r.hasKey(ek)) {
                                std.debug.print("Expected key 0x{X:0>2} not found in report\n", .{ek});
                                return error.TestExpectedEqual;
                            }
                        }
                        return;
                    }
                    keyboard_index += 1;
                },
                else => {},
            }
        }
        std.debug.print("Keyboard report index {d} not found (only {d} reports)\n", .{ index, keyboard_index });
        return error.TestExpectedEqual;
    }

    /// Verify that an empty keyboard report was sent at the given index
    pub fn expectEmptyReport(self: *const TestDriver, index: usize) !void {
        var keyboard_index: usize = 0;
        for (self.reports.items) |entry| {
            switch (entry) {
                .keyboard => |r| {
                    if (keyboard_index == index) {
                        try std.testing.expect(r.isEmpty());
                        return;
                    }
                    keyboard_index += 1;
                },
                else => {},
            }
        }
        std.debug.print("Keyboard report index {d} not found\n", .{index});
        return error.TestExpectedEqual;
    }

    /// Clear all captured reports
    pub fn clearReports(self: *TestDriver) void {
        self.reports.clearRetainingCapacity();
    }
};

// ============================================================
// Tests
// ============================================================

test "TestDriver captures keyboard reports" {
    var driver = TestDriver.init(std.testing.allocator);
    defer driver.deinit();

    var r = KeyboardReport{};
    _ = r.addKey(0x04); // KC_A
    driver.sendKeyboard(r);

    try std.testing.expectEqual(@as(usize, 1), driver.reportCount());
    const last = driver.lastKeyboardReport().?;
    try std.testing.expect(last.hasKey(0x04));
}

test "TestDriver expectReport" {
    var driver = TestDriver.init(std.testing.allocator);
    defer driver.deinit();

    var r1 = KeyboardReport{};
    r1.mods = 0x02; // LSHIFT
    _ = r1.addKey(0x04); // KC_A
    driver.sendKeyboard(r1);

    const r2 = KeyboardReport{};
    driver.sendKeyboard(r2);

    try driver.expectReport(0, 0x02, &.{0x04});
    try driver.expectEmptyReport(1);
}

test "TestDriver clearReports" {
    var driver = TestDriver.init(std.testing.allocator);
    defer driver.deinit();

    driver.sendKeyboard(KeyboardReport{});
    try std.testing.expectEqual(@as(usize, 1), driver.reportCount());

    driver.clearReports();
    try std.testing.expectEqual(@as(usize, 0), driver.reportCount());
}
