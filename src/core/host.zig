// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zig port of tmk_core/protocol/host.c
// Original: Copyright 2011,2012 Jun Wako <wakojun@gmail.com>

//! Host driver interface and HID report state management
//! Based on tmk_core/protocol/host.h, host.c
//!
//! Provides:
//! - Type-erased HostDriver interface for sending HID reports
//! - Global keyboard report state with register/unregister operations
//! - Modifier state management (real mods, weak mods)

const std = @import("std");
const report_mod = @import("report.zig");
const layer_mod = @import("layer.zig");
const timer = @import("../hal/timer.zig");
const keymap_mod = @import("keymap.zig");
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
/// 前回送信したキーボードレポート（差分チェック用）
/// C版 action_util.c の send_6kro_report() 内 static last_report に相当
var last_keyboard_report: KeyboardReport = .{};
var real_mods: u8 = 0;
var weak_mods: u8 = 0;
/// Key Override 用: 置換キーに付与する弱い修飾キー
/// C版 action_util.c の weak_override_mods に相当
var weak_override_mods: u8 = 0;
/// Key Override 用: アクティブなオーバーライドで抑制する修飾キー
/// C版 action_util.c の suppressed_override_mods に相当
var suppressed_override_mods: u8 = 0;
/// One-Shot Mods: 次の1回のキー入力にのみ適用される修飾キー
/// C版 action_util.c の oneshot_mods に相当
var oneshot_mods: u8 = 0;

/// One-Shot Layer 状態データ
/// C版 action_util.c の oneshot_layer_data に相当
/// 上位5ビット: レイヤー番号、下位3ビット: 状態フラグ
var oneshot_layer_data: u8 = 0;

/// One-Shot Locked Mods: ONESHOT_TAP_TOGGLE 回タップで恒久的にロックされた修飾キー
/// C版 action_util.c の oneshot_locked_mods に相当
var oneshot_locked_mods: u8 = 0;

/// ONESHOT_TIMEOUT: ワンショットモッドのタイムアウト値（ミリ秒）
/// 0 の場合はタイムアウト無効
pub var oneshot_timeout: u16 = 0;

/// ワンショットモッド設定時のタイマー
var oneshot_time: u16 = 0;

/// ワンショットレイヤー設定時のタイマー
var oneshot_layer_time: u16 = 0;

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
// Weak Override Mods (Key Override 用)
// C版 action_util.c の weak_override_mods に相当
// ============================================================

pub fn setWeakOverrideMods(mods: u8) void {
    weak_override_mods = mods;
}

pub fn clearWeakOverrideMods() void {
    weak_override_mods = 0;
}

// ============================================================
// Suppressed Override Mods (Key Override 用)
// C版 action_util.c の suppressed_override_mods に相当
// ============================================================

pub fn setSuppressedOverrideMods(mods: u8) void {
    suppressed_override_mods = mods;
}

pub fn clearSuppressedOverrideMods() void {
    suppressed_override_mods = 0;
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
/// C版 send_keyboard_report() / send_6kro_report() に相当。
/// oneshot_mods は一時的にレポートに含め、キーが送信されていたらクリアする。
/// 前回送信したレポートと比較し、変更がある場合のみ送信する。
pub fn sendKeyboardReport() void {
    // ONESHOT_TIMEOUT: タイムアウトチェック
    if (oneshot_timeout > 0 and hasOneshotModsTimedOut()) {
        clearOneshotMods();
    }

    keyboard_report.mods = (real_mods | weak_mods | weak_override_mods | oneshot_mods | oneshot_locked_mods) & ~suppressed_override_mods;
    // oneshot_mods が設定されており、かつキーが登録されていればクリアする
    // C版 get_mods_for_report() の has_anykey() チェックに相当
    if (oneshot_mods != 0 and keyboard_report.hasAnyKey()) {
        oneshot_mods = 0;
    }
    if (current_driver) |driver| {
        // 前回のレポートと比較し、変更がある場合のみ送信する
        // C版 action_util.c の send_6kro_report() 内 memcmp に相当
        const current: [8]u8 = @bitCast(keyboard_report);
        const last: [8]u8 = @bitCast(last_keyboard_report);
        if (!std.mem.eql(u8, &current, &last)) {
            last_keyboard_report = keyboard_report;
            driver.sendKeyboard(&keyboard_report);
        }
    }
}

/// Clear the keyboard state and send an empty report
/// ホスト側のクリーン状態を保証するため差分チェックをバイパスして強制送信する。
/// C版 clear_keyboard() は host_keyboard_send() → send_6kro_report() を経由するため
/// memcmp による差分チェックが適用されスキップされる場合がある。
pub fn clearKeyboard() void {
    keyboard_report.clear();
    real_mods = 0;
    weak_mods = 0;
    weak_override_mods = 0;
    suppressed_override_mods = 0;
    last_keyboard_report = keyboard_report;
    if (current_driver) |driver| {
        driver.sendKeyboard(&keyboard_report);
    }
}

pub fn hostReset() void {
    keyboard_report.clear();
    last_keyboard_report = .{};
    real_mods = 0;
    weak_mods = 0;
    weak_override_mods = 0;
    suppressed_override_mods = 0;
    oneshot_mods = 0;
    oneshot_layer_data = 0;
    oneshot_locked_mods = 0;
    oneshot_time = 0;
    oneshot_layer_time = 0;
    oneshot_timeout = 0;
}

// ============================================================
// One-Shot Mods operations
// C版 action_util.c の oneshot_mods 関連関数に相当
// ============================================================

/// One-Shot Mods を追加する
pub fn addOneshotMods(mods: u8) void {
    if ((oneshot_mods & mods) != mods) {
        oneshot_time = timer.read();
    }
    oneshot_mods |= mods;
}

/// One-Shot Mods から削除する
pub fn delOneshotMods(mods: u8) void {
    oneshot_mods &= ~mods;
    if (oneshot_mods == 0) {
        oneshot_time = 0;
    }
}

/// One-Shot Mods をクリアする
pub fn clearOneshotMods() void {
    oneshot_mods = 0;
    oneshot_time = 0;
}

/// 現在の One-Shot Mods を取得する
pub fn getOneshotMods() u8 {
    return oneshot_mods;
}

/// ワンショットモッドがタイムアウトしたかチェックする
pub fn hasOneshotModsTimedOut() bool {
    if (oneshot_timeout == 0) return false;
    if (oneshot_mods == 0) return false;
    return timer.elapsed(oneshot_time) >= oneshot_timeout;
}

// ============================================================
// One-Shot Locked Mods operations
// ============================================================

pub fn getOneshotLockedMods() u8 {
    return oneshot_locked_mods;
}

pub fn setOneshotLockedMods(mods: u8) void {
    oneshot_locked_mods = mods;
}

pub fn addOneshotLockedMods(mods: u8) void {
    oneshot_locked_mods |= mods;
}

pub fn delOneshotLockedMods(mods: u8) void {
    oneshot_locked_mods &= ~mods;
}

pub fn clearOneshotLockedMods() void {
    oneshot_locked_mods = 0;
}

// ============================================================
// One-Shot Layer operations
// C版 action_util.c の oneshot_layer 関連関数に相当
// ============================================================

/// One-Shot Layer 状態フラグ
/// C版 oneshot_fullfillment_t に相当
pub const OneshotState = struct {
    pub const PRESSED: u3 = 0b001;
    pub const OTHER_KEY_PRESSED: u3 = 0b010;
    pub const START: u3 = 0b011; // PRESSED | OTHER_KEY_PRESSED
    pub const TOGGLED: u3 = 0b100;
};

/// One-Shot Layer を設定し、レイヤーを有効化する
/// C版 set_oneshot_layer() に相当
pub fn setOneshotLayer(l: u5, state: u3) void {
    if (!keymap_mod.keymap_config.oneshot_enable) return;
    oneshot_layer_data = (@as(u8, l) << 3) | @as(u8, state);
    layer_mod.layerOn(l);
    oneshot_layer_time = timer.read();
}

/// One-Shot Layer データをリセットする（レイヤー操作なし）
/// C版 reset_oneshot_layer() に相当
pub fn resetOneshotLayer() void {
    oneshot_layer_data = 0;
    oneshot_layer_time = 0;
}

/// One-Shot Layer の状態フラグをクリアする
/// 全フラグがクリアされた場合、レイヤーをオフにしてリセットする
/// C版 clear_oneshot_layer_state() に相当
pub fn clearOneshotLayerState(state: u3) void {
    const start_state = oneshot_layer_data;
    oneshot_layer_data &= ~@as(u8, state);
    if (getOneshotLayerState() == 0 and start_state != oneshot_layer_data) {
        layer_mod.layerOff(getOneshotLayerFromData(start_state));
        resetOneshotLayer();
    }
}

/// One-Shot Layer のレイヤー番号を取得する
/// C版 get_oneshot_layer() に相当
pub fn getOneshotLayer() u5 {
    return @truncate(oneshot_layer_data >> 3);
}

/// 指定データからレイヤー番号を取得する（内部用）
fn getOneshotLayerFromData(data: u8) u5 {
    return @truncate(data >> 3);
}

/// One-Shot Layer の状態フラグを取得する
/// C版 get_oneshot_layer_state() に相当
pub fn getOneshotLayerState() u3 {
    return @truncate(oneshot_layer_data & 0b111);
}

/// One-Shot Layer がアクティブかどうかを確認する
pub fn isOneshotLayerActive() bool {
    return getOneshotLayerState() != 0;
}

/// ワンショットレイヤーがタイムアウトしたかチェックする
/// TOGGLED 状態の場合はタイムアウトしない
pub fn hasOneshotLayerTimedOut() bool {
    if (oneshot_timeout == 0) return false;
    if (getOneshotLayerState() == 0) return false;
    if (getOneshotLayerState() == OneshotState.TOGGLED) return false;
    return timer.elapsed(oneshot_layer_time) >= oneshot_timeout;
}

/// Convert 5-bit modifier encoding to 8-bit HID modifier bits
/// 5-bit format: bit4=right, bit3=GUI, bit2=ALT, bit1=SHIFT, bit0=CTRL
pub fn modFiveBitToEightBit(mods5: u8) u8 {
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

test "sendKeyboardReport skips duplicate reports" {
    hostReset();
    var mock = MockDriver{};
    setDriver(HostDriver.from(&mock));
    defer clearDriver();

    // 最初の送信: キーAを押す -> 送信される
    registerCode(0x04); // KC_A
    sendKeyboardReport();
    try testing.expectEqual(@as(usize, 1), mock.keyboard_count);

    // 同じレポートを再送信 -> スキップされる
    sendKeyboardReport();
    try testing.expectEqual(@as(usize, 1), mock.keyboard_count);

    // キーBを追加 -> 変更があるので送信される
    registerCode(0x05); // KC_B
    sendKeyboardReport();
    try testing.expectEqual(@as(usize, 2), mock.keyboard_count);

    // キーBを解除 -> 変更があるので送信される
    unregisterCode(0x05);
    sendKeyboardReport();
    try testing.expectEqual(@as(usize, 3), mock.keyboard_count);

    // 再度同じレポート -> スキップされる
    sendKeyboardReport();
    try testing.expectEqual(@as(usize, 3), mock.keyboard_count);
}

test "clearKeyboard always sends report" {
    hostReset();
    var mock = MockDriver{};
    setDriver(HostDriver.from(&mock));
    defer clearDriver();

    // 初期状態で空レポートを送信（clearKeyboardは常に送信）
    clearKeyboard();
    try testing.expectEqual(@as(usize, 1), mock.keyboard_count);

    // もう一度clearKeyboard -> 差分チェックバイパスなので送信される
    clearKeyboard();
    try testing.expectEqual(@as(usize, 2), mock.keyboard_count);
}

test "oneshot locked mods included in report" {
    hostReset();
    var mock = MockDriver{};
    setDriver(HostDriver.from(&mock));
    defer clearDriver();

    addOneshotLockedMods(0x02); // LSHIFT
    sendKeyboardReport();
    try testing.expectEqual(@as(u8, 0x02), mock.lastKeyboardReport().mods);

    clearOneshotLockedMods();
    sendKeyboardReport();
    try testing.expectEqual(@as(u8, 0x00), mock.lastKeyboardReport().mods);
}

test "oneshot mods timeout clears mods" {
    hostReset();
    timer.mockReset();
    var mock = MockDriver{};
    setDriver(HostDriver.from(&mock));
    defer clearDriver();

    oneshot_timeout = 500;
    addOneshotMods(0x02); // LSHIFT

    timer.mockAdvance(100);
    sendKeyboardReport();
    try testing.expectEqual(@as(u8, 0x02), mock.lastKeyboardReport().mods);

    timer.mockAdvance(500);
    sendKeyboardReport();
    try testing.expectEqual(@as(u8, 0x00), mock.lastKeyboardReport().mods);
    try testing.expectEqual(@as(u8, 0), getOneshotMods());
}

test "hasOneshotModsTimedOut" {
    hostReset();
    timer.mockReset();
    oneshot_timeout = 200;
    addOneshotMods(0x01);

    try testing.expect(!hasOneshotModsTimedOut());
    timer.mockAdvance(199);
    try testing.expect(!hasOneshotModsTimedOut());
    timer.mockAdvance(1);
    try testing.expect(hasOneshotModsTimedOut());
}

test "hasOneshotLayerTimedOut" {
    hostReset();
    timer.mockReset();
    oneshot_timeout = 300;
    keymap_mod.keymap_config.oneshot_enable = true;
    defer { keymap_mod.keymap_config.oneshot_enable = false; }

    setOneshotLayer(1, OneshotState.START);
    try testing.expect(!hasOneshotLayerTimedOut());
    timer.mockAdvance(300);
    try testing.expect(hasOneshotLayerTimedOut());
}

test "hasOneshotLayerTimedOut TOGGLED state does not timeout" {
    hostReset();
    timer.mockReset();
    oneshot_timeout = 100;
    keymap_mod.keymap_config.oneshot_enable = true;
    defer { keymap_mod.keymap_config.oneshot_enable = false; }

    setOneshotLayer(1, OneshotState.TOGGLED);
    timer.mockAdvance(200);
    try testing.expect(!hasOneshotLayerTimedOut());
}

test "hasOneshotLayerTimedOut returns false when no layer is active" {
    hostReset();
    timer.mockReset();
    oneshot_timeout = 100;

    // レイヤー未設定の状態でタイムアウト時間を超過しても false を返すことを確認
    timer.mockAdvance(200);
    try testing.expect(!hasOneshotLayerTimedOut());
}

