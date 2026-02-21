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
        self.reports.append(self.allocator, .{ .keyboard = r }) catch @panic("TestDriver: OOM");
    }

    pub fn sendMouse(self: *TestDriver, r: MouseReport) void {
        self.reports.append(self.allocator, .{ .mouse = r }) catch @panic("TestDriver: OOM");
    }

    pub fn sendExtra(self: *TestDriver, r: ExtraReport) void {
        self.reports.append(self.allocator, .{ .extra = r }) catch @panic("TestDriver: OOM");
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
// Fixed-size buffer mock driver (no allocator needed)
// ============================================================

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
        }
    };
}

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
    driver.reset();

    try std.testing.expectEqual(@as(usize, 0), driver.keyboard_count);
    try std.testing.expectEqual(@as(usize, 0), driver.mouse_count);
    try std.testing.expectEqual(@as(usize, 0), driver.extra_count);
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
