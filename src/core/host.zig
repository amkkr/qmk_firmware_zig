//! Host driver interface
//! Based on tmk_core/protocol/host.h and host.c
//!
//! Provides a type-erased interface for sending HID reports to the host.
//! Both the real USB driver and the test mock implement this interface.

const std = @import("std");
const report = @import("report.zig");
const KeyboardReport = report.KeyboardReport;
const MouseReport = report.MouseReport;
const ExtraReport = report.ExtraReport;

/// Host driver virtual table (type-erased interface)
/// Zig equivalent of C's host_driver_t function pointer struct.
pub const HostDriver = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        keyboard_leds: *const fn (ctx: *anyopaque) u8,
        send_keyboard: *const fn (ctx: *anyopaque, r: *const KeyboardReport) void,
        send_mouse: *const fn (ctx: *anyopaque, r: *const MouseReport) void,
        send_extra: *const fn (ctx: *anyopaque, r: *const ExtraReport) void,
    };

    pub fn keyboardLeds(self: HostDriver) u8 {
        return self.vtable.keyboard_leds(self.context);
    }

    pub fn sendKeyboard(self: HostDriver, r: *const KeyboardReport) void {
        self.vtable.send_keyboard(self.context, r);
    }

    pub fn sendMouse(self: HostDriver, r: *const MouseReport) void {
        self.vtable.send_mouse(self.context, r);
    }

    pub fn sendExtra(self: HostDriver, r: *const ExtraReport) void {
        self.vtable.send_extra(self.context, r);
    }

    /// Create a HostDriver from a typed pointer.
    /// The type T must have methods: keyboardLeds, sendKeyboard, sendMouse, sendExtra.
    pub fn from(ptr: anytype) HostDriver {
        const T = @TypeOf(ptr);
        const Child = @typeInfo(T).pointer.child;

        const vtable = struct {
            fn keyboardLedsFn(ctx: *anyopaque) u8 {
                const self: *Child = @ptrCast(@alignCast(ctx));
                return self.keyboardLeds();
            }
            fn sendKeyboardFn(ctx: *anyopaque, r: *const KeyboardReport) void {
                const self: *Child = @ptrCast(@alignCast(ctx));
                self.sendKeyboard(r.*);
            }
            fn sendMouseFn(ctx: *anyopaque, r: *const MouseReport) void {
                const self: *Child = @ptrCast(@alignCast(ctx));
                self.sendMouse(r.*);
            }
            fn sendExtraFn(ctx: *anyopaque, r: *const ExtraReport) void {
                const self: *Child = @ptrCast(@alignCast(ctx));
                self.sendExtra(r.*);
            }
        };

        return .{
            .context = @ptrCast(ptr),
            .vtable = &.{
                .keyboard_leds = vtable.keyboardLedsFn,
                .send_keyboard = vtable.sendKeyboardFn,
                .send_mouse = vtable.sendMouseFn,
                .send_extra = vtable.sendExtraFn,
            },
        };
    }
};

// ============================================================
// Global host driver state
// ============================================================

var current_driver: ?HostDriver = null;

pub fn setDriver(driver: HostDriver) void {
    current_driver = driver;
}

pub fn getDriver() ?HostDriver {
    return current_driver;
}

pub fn clearDriver() void {
    current_driver = null;
}

/// Send a keyboard report via the current host driver
pub fn sendKeyboard(r: *const KeyboardReport) void {
    if (current_driver) |driver| {
        driver.sendKeyboard(r);
    }
}

/// Send a mouse report via the current host driver
pub fn sendMouse(r: *const MouseReport) void {
    if (current_driver) |driver| {
        driver.sendMouse(r);
    }
}

/// Send an extra report via the current host driver
pub fn sendExtra(r: *const ExtraReport) void {
    if (current_driver) |driver| {
        driver.sendExtra(r);
    }
}

/// Get keyboard LEDs state from the host
pub fn keyboardLeds() u8 {
    if (current_driver) |driver| {
        return driver.keyboardLeds();
    }
    return 0;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

/// Simple mock driver for testing the HostDriver interface
const MockDriver = struct {
    keyboard_count: usize = 0,
    mouse_count: usize = 0,
    extra_count: usize = 0,
    last_keyboard: KeyboardReport = .{},
    leds: u8 = 0,

    pub fn keyboardLeds(self: *MockDriver) u8 {
        return self.leds;
    }

    pub fn sendKeyboard(self: *MockDriver, r: KeyboardReport) void {
        self.keyboard_count += 1;
        self.last_keyboard = r;
    }

    pub fn sendMouse(self: *MockDriver, _: MouseReport) void {
        self.mouse_count += 1;
    }

    pub fn sendExtra(self: *MockDriver, _: ExtraReport) void {
        self.extra_count += 1;
    }
};

test "HostDriver interface dispatch" {
    var mock = MockDriver{};
    const driver = HostDriver.from(&mock);

    var r = KeyboardReport{};
    _ = r.addKey(0x04);
    r.mods = 0x02;
    driver.sendKeyboard(&r);

    try testing.expectEqual(@as(usize, 1), mock.keyboard_count);
    try testing.expect(mock.last_keyboard.hasKey(0x04));
    try testing.expectEqual(@as(u8, 0x02), mock.last_keyboard.mods);
}

test "HostDriver mouse and extra" {
    var mock = MockDriver{};
    const driver = HostDriver.from(&mock);

    driver.sendMouse(&MouseReport{});
    driver.sendExtra(&ExtraReport{});

    try testing.expectEqual(@as(usize, 1), mock.mouse_count);
    try testing.expectEqual(@as(usize, 1), mock.extra_count);
}

test "HostDriver keyboard LEDs" {
    var mock = MockDriver{ .leds = 0x02 };
    const driver = HostDriver.from(&mock);

    try testing.expectEqual(@as(u8, 0x02), driver.keyboardLeds());
}

test "global host driver" {
    var mock = MockDriver{};
    const driver = HostDriver.from(&mock);

    // Initially no driver
    clearDriver();
    try testing.expectEqual(@as(u8, 0), keyboardLeds());

    // Set driver
    setDriver(driver);
    defer clearDriver();

    mock.leds = 0x04;
    try testing.expectEqual(@as(u8, 0x04), keyboardLeds());

    var r = KeyboardReport{};
    sendKeyboard(&r);
    try testing.expectEqual(@as(usize, 1), mock.keyboard_count);
}
