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
// Global host state
// ============================================================

var current_driver: ?HostDriver = null;
var keyboard_report: KeyboardReport = .{};
var real_mods: u8 = 0;
var weak_mods: u8 = 0;
/// One-Shot Mods: 次の1回のキー入力にのみ適用される修飾キー
/// C版 action_util.c の oneshot_mods に相当
var oneshot_mods: u8 = 0;

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
/// C版 send_keyboard_report() に相当。
/// oneshot_mods は一時的にレポートに含め、キーが送信されていたらクリアする。
pub fn sendKeyboardReport() void {
    keyboard_report.mods = real_mods | weak_mods | oneshot_mods;
    // oneshot_mods が設定されており、かつキーが登録されていればクリアする
    // C版 get_mods_for_report() の has_anykey() チェックに相当
    if (oneshot_mods != 0 and keyboard_report.hasAnyKey()) {
        oneshot_mods = 0;
    }
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
    oneshot_mods = 0;
}

// ============================================================
// One-Shot Mods operations
// C版 action_util.c の oneshot_mods 関連関数に相当
// ============================================================

/// One-Shot Mods を追加する
pub fn addOneshotMods(mods: u8) void {
    oneshot_mods |= mods;
}

/// One-Shot Mods から削除する
pub fn delOneshotMods(mods: u8) void {
    oneshot_mods &= ~mods;
}

/// One-Shot Mods をクリアする
pub fn clearOneshotMods() void {
    oneshot_mods = 0;
}

/// 現在の One-Shot Mods を取得する
pub fn getOneshotMods() u8 {
    return oneshot_mods;
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

const MockDriver = @import("test_driver.zig").FixedTestDriver(32, 4);

test "HostDriver interface dispatch" {
    var mock = MockDriver{};
    const driver = HostDriver.from(&mock);

    var r = KeyboardReport{};
    _ = r.addKey(0x04);
    r.mods = 0x02;
    driver.sendKeyboard(&r);

    try testing.expectEqual(@as(usize, 1), mock.keyboard_count);
    try testing.expect(mock.lastKeyboardReport().hasKey(0x04));
    try testing.expectEqual(@as(u8, 0x02), mock.lastKeyboardReport().mods);
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

test "registerCode / unregisterCode" {
    hostReset();
    var mock = MockDriver{};
    setDriver(HostDriver.from(&mock));
    defer clearDriver();

    registerCode(0x04); // KC_A
    sendKeyboardReport();
    try testing.expect(mock.lastKeyboardReport().hasKey(0x04));

    unregisterCode(0x04);
    sendKeyboardReport();
    try testing.expect(!mock.lastKeyboardReport().hasKey(0x04));
}

test "registerCode modifier" {
    hostReset();
    var mock = MockDriver{};
    setDriver(HostDriver.from(&mock));
    defer clearDriver();

    registerCode(0xE1); // LSHIFT
    sendKeyboardReport();
    try testing.expectEqual(@as(u8, 0x02), mock.lastKeyboardReport().mods);

    unregisterCode(0xE1);
    sendKeyboardReport();
    try testing.expectEqual(@as(u8, 0x00), mock.lastKeyboardReport().mods);
}

test "registerMods 5-bit" {
    hostReset();
    var mock = MockDriver{};
    setDriver(HostDriver.from(&mock));
    defer clearDriver();

    registerMods(0x02); // LSFT (5-bit)
    sendKeyboardReport();
    try testing.expectEqual(@as(u8, 0x02), mock.lastKeyboardReport().mods); // LSHIFT HID bit

    unregisterMods(0x02);
    sendKeyboardReport();
    try testing.expectEqual(@as(u8, 0x00), mock.lastKeyboardReport().mods);
}

test "weak mods" {
    hostReset();
    var mock = MockDriver{};
    setDriver(HostDriver.from(&mock));
    defer clearDriver();

    addWeakMods(0x02); // LSHIFT
    sendKeyboardReport();
    try testing.expectEqual(@as(u8, 0x02), mock.lastKeyboardReport().mods);

    clearWeakMods();
    sendKeyboardReport();
    try testing.expectEqual(@as(u8, 0x00), mock.lastKeyboardReport().mods);
}

test "clearKeyboard" {
    hostReset();
    var mock = MockDriver{};
    setDriver(HostDriver.from(&mock));
    defer clearDriver();

    registerCode(0x04);
    registerCode(0xE1);
    clearKeyboard();
    try testing.expect(mock.lastKeyboardReport().isEmpty());
    try testing.expectEqual(@as(u8, 0), getMods());
}
