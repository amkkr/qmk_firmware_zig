//! Host driver interface and HID report state management
//! Based on tmk_core/protocol/host.h, host.c
//!
//! Provides:
//! - Type-erased HostDriver interface for sending HID reports
//! - Global keyboard report state with register/unregister operations
//! - Modifier state management (real mods, weak mods)

const std = @import("std");
const report_mod = @import("report.zig");
const KeyboardReport = report_mod.KeyboardReport;
const MouseReport = report_mod.MouseReport;
const ExtraReport = report_mod.ExtraReport;

/// Host driver virtual table (type-erased interface)
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
    pub fn from(ptr: anytype) HostDriver {
        const T = @TypeOf(ptr);
        const Child = @typeInfo(T).pointer.child;

        const gen = struct {
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
                .keyboard_leds = gen.keyboardLedsFn,
                .send_keyboard = gen.sendKeyboardFn,
                .send_mouse = gen.sendMouseFn,
                .send_extra = gen.sendExtraFn,
            },
        };
    }
};

// ============================================================
// Global host state
// ============================================================

var current_driver: ?HostDriver = null;
var keyboard_report: KeyboardReport = .{};
var real_mods: u8 = 0;
var weak_mods: u8 = 0;

pub fn setDriver(driver: HostDriver) void {
    current_driver = driver;
}

pub fn getDriver() ?HostDriver {
    return current_driver;
}

pub fn clearDriver() void {
    current_driver = null;
}

// ============================================================
// Modifier state
// ============================================================

pub fn getMods() u8 {
    return real_mods;
}

pub fn setMods(mods: u8) void {
    real_mods = mods;
}

pub fn addMods(mods: u8) void {
    real_mods |= mods;
}

pub fn delMods(mods: u8) void {
    real_mods &= ~mods;
}

pub fn getWeakMods() u8 {
    return weak_mods;
}

pub fn addWeakMods(mods: u8) void {
    weak_mods |= mods;
}

pub fn delWeakMods(mods: u8) void {
    weak_mods &= ~mods;
}

pub fn clearWeakMods() void {
    weak_mods = 0;
}

// ============================================================
// Keyboard report operations
// ============================================================

pub fn getReport() *KeyboardReport {
    return &keyboard_report;
}

/// Register a keycode into the keyboard report
pub fn registerCode(kc: u8) void {
    if (kc >= 0xE0 and kc <= 0xE7) {
        // Modifier key
        real_mods |= report_mod.keycodeToModBit(kc);
    } else {
        _ = keyboard_report.addKey(kc);
    }
}

/// Unregister a keycode from the keyboard report
pub fn unregisterCode(kc: u8) void {
    if (kc >= 0xE0 and kc <= 0xE7) {
        real_mods &= ~report_mod.keycodeToModBit(kc);
    } else {
        keyboard_report.removeKey(kc);
    }
}

/// Register modifier bits (5-bit mod to 8-bit HID)
pub fn registerMods(mods: u8) void {
    real_mods |= modFiveBitToEightBit(mods);
}

/// Unregister modifier bits
pub fn unregisterMods(mods: u8) void {
    real_mods &= ~modFiveBitToEightBit(mods);
}

/// Send the current keyboard report to the host
pub fn sendKeyboardReport() void {
    keyboard_report.mods = real_mods | weak_mods;
    if (current_driver) |driver| {
        driver.sendKeyboard(&keyboard_report);
    }
}

/// Clear the keyboard state and send an empty report
pub fn clearKeyboard() void {
    keyboard_report.clear();
    real_mods = 0;
    weak_mods = 0;
    sendKeyboardReport();
}

pub fn hostReset() void {
    keyboard_report.clear();
    real_mods = 0;
    weak_mods = 0;
}

/// Convert 5-bit modifier encoding to 8-bit HID modifier bits
/// 5-bit format: bit4=right, bit3=GUI, bit2=ALT, bit1=SHIFT, bit0=CTRL
fn modFiveBitToEightBit(mods5: u8) u8 {
    var result: u8 = 0;
    const is_right = (mods5 & 0x10) != 0;
    if (is_right) {
        if (mods5 & 0x01 != 0) result |= report_mod.ModBit.RCTRL;
        if (mods5 & 0x02 != 0) result |= report_mod.ModBit.RSHIFT;
        if (mods5 & 0x04 != 0) result |= report_mod.ModBit.RALT;
        if (mods5 & 0x08 != 0) result |= report_mod.ModBit.RGUI;
    } else {
        if (mods5 & 0x01 != 0) result |= report_mod.ModBit.LCTRL;
        if (mods5 & 0x02 != 0) result |= report_mod.ModBit.LSHIFT;
        if (mods5 & 0x04 != 0) result |= report_mod.ModBit.LALT;
        if (mods5 & 0x08 != 0) result |= report_mod.ModBit.LGUI;
    }
    return result;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

const MockDriver = struct {
    keyboard_count: usize = 0,
    last_keyboard: KeyboardReport = .{},
    leds: u8 = 0,

    pub fn keyboardLeds(self: *MockDriver) u8 {
        return self.leds;
    }

    pub fn sendKeyboard(self: *MockDriver, r: KeyboardReport) void {
        self.keyboard_count += 1;
        self.last_keyboard = r;
    }

    pub fn sendMouse(_: *MockDriver, _: MouseReport) void {}
    pub fn sendExtra(_: *MockDriver, _: ExtraReport) void {}
};

test "registerCode / unregisterCode" {
    hostReset();
    var mock = MockDriver{};
    setDriver(HostDriver.from(&mock));
    defer clearDriver();

    registerCode(0x04); // KC_A
    sendKeyboardReport();
    try testing.expect(mock.last_keyboard.hasKey(0x04));

    unregisterCode(0x04);
    sendKeyboardReport();
    try testing.expect(!mock.last_keyboard.hasKey(0x04));
}

test "registerCode modifier" {
    hostReset();
    var mock = MockDriver{};
    setDriver(HostDriver.from(&mock));
    defer clearDriver();

    registerCode(0xE1); // LSHIFT
    sendKeyboardReport();
    try testing.expectEqual(@as(u8, 0x02), mock.last_keyboard.mods);

    unregisterCode(0xE1);
    sendKeyboardReport();
    try testing.expectEqual(@as(u8, 0x00), mock.last_keyboard.mods);
}

test "registerMods 5-bit" {
    hostReset();
    var mock = MockDriver{};
    setDriver(HostDriver.from(&mock));
    defer clearDriver();

    registerMods(0x02); // LSFT (5-bit)
    sendKeyboardReport();
    try testing.expectEqual(@as(u8, 0x02), mock.last_keyboard.mods); // LSHIFT HID bit

    unregisterMods(0x02);
    sendKeyboardReport();
    try testing.expectEqual(@as(u8, 0x00), mock.last_keyboard.mods);
}

test "weak mods" {
    hostReset();
    var mock = MockDriver{};
    setDriver(HostDriver.from(&mock));
    defer clearDriver();

    addWeakMods(0x02); // LSHIFT
    sendKeyboardReport();
    try testing.expectEqual(@as(u8, 0x02), mock.last_keyboard.mods);

    clearWeakMods();
    sendKeyboardReport();
    try testing.expectEqual(@as(u8, 0x00), mock.last_keyboard.mods);
}

test "clearKeyboard" {
    hostReset();
    var mock = MockDriver{};
    setDriver(HostDriver.from(&mock));
    defer clearDriver();

    registerCode(0x04);
    registerCode(0xE1);
    clearKeyboard();
    try testing.expect(mock.last_keyboard.isEmpty());
    try testing.expectEqual(@as(u8, 0), getMods());
}
