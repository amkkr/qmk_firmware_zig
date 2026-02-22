//! C ABI export stubs for QMK compatibility
//! Provides `export fn` wrappers around Zig core modules,
//! allowing C code to call into the Zig implementation.
//!
//! All exported functions use C-compatible types (u8, u16, u32, pointers).
//! Function names follow QMK C naming conventions (snake_case).

const std = @import("std");
const layer_mod = @import("../core/layer.zig");
const host_mod = @import("../core/host.zig");
const action_mod = @import("../core/action.zig");
const keyboard_mod = @import("../core/keyboard.zig");
const event_mod = @import("../core/event.zig");
const keymap_mod = @import("../core/keymap.zig");
const timer = @import("../hal/timer.zig");

// ============================================================
// Keyboard lifecycle
// ============================================================

/// Initialize keyboard hardware and subsystems
export fn keyboard_init() void {
    keyboard_mod.init();
}

/// Run one iteration of the keyboard processing loop
export fn keyboard_task() void {
    keyboard_mod.task();
}

// ============================================================
// Action execution
// ============================================================

/// Execute action for a key event (C ABI wrapper)
/// C版の action_exec(keyevent_t) に相当するが、シグネチャは意図的に異なる。
/// C版は keyevent_t 構造体を値渡しするが、Zig版は C++ テストとの直接リンクを
/// 目的とせず、FFI 経由の呼び出しやテストアダプタ経由での使用を想定している。
export fn action_exec(row: u8, col: u8, pressed: bool, time: u16) void {
    const ev = if (pressed)
        event_mod.KeyEvent.keyPress(row, col, time)
    else
        event_mod.KeyEvent.keyRelease(row, col, time);
    var record = event_mod.KeyRecord{ .event = ev };
    action_mod.actionExec(&record);
}

// ============================================================
// Record processing
// ============================================================

/// Process a key record through action resolution and execution
/// C版の process_record(keyrecord_t*) に相当するが、シグネチャは意図的に異なる。
/// action_exec と同様、FFI 経由の呼び出しやテストアダプタ経由での使用を想定。
export fn process_record(row: u8, col: u8, pressed: bool, time: u16) void {
    const ev = if (pressed)
        event_mod.KeyEvent.keyPress(row, col, time)
    else
        event_mod.KeyEvent.keyRelease(row, col, time);
    var record = event_mod.KeyRecord{ .event = ev };
    action_mod.processRecord(&record);
}

// ============================================================
// Layer management
// ============================================================

/// Turn on a specific layer
export fn layer_on(layer: u8) void {
    if (layer >= layer_mod.MAX_LAYERS) return;
    layer_mod.layerOn(@intCast(layer));
}

/// Turn off a specific layer
export fn layer_off(layer: u8) void {
    if (layer >= layer_mod.MAX_LAYERS) return;
    layer_mod.layerOff(@intCast(layer));
}

/// Clear all layers
export fn layer_clear() void {
    layer_mod.layerClear();
}

/// Set the layer state directly
export fn layer_state_set(state: u32) void {
    layer_mod.layerStateSet(state);
}

/// Check if a layer is active
export fn layer_state_is(layer: u8) bool {
    if (layer >= layer_mod.MAX_LAYERS) return false;
    return layer_mod.layerStateIs(@intCast(layer));
}

/// Move to a specific layer (exclusive)
export fn layer_move(layer: u8) void {
    if (layer >= layer_mod.MAX_LAYERS) return;
    layer_mod.layerMove(@intCast(layer));
}

// ============================================================
// Key registration
// ============================================================

/// Register a keycode (add to HID report)
/// C版の register_code(uint8_t) に相当
export fn register_code(kc: u8) void {
    host_mod.registerCode(kc);
}

/// Unregister a keycode (remove from HID report)
/// C版の unregister_code(uint8_t) に相当
export fn unregister_code(kc: u8) void {
    host_mod.unregisterCode(kc);
}

// ============================================================
// Host / Report
// ============================================================

/// Clear all keyboard state and send empty report
export fn clear_keyboard() void {
    host_mod.clearKeyboard();
}

/// Send the current keyboard report
export fn send_keyboard_report() void {
    host_mod.sendKeyboardReport();
}

// ============================================================
// Host driver management
// ============================================================

/// C ABI 互換のホストドライバ関数ポインタテーブル
/// C版の host_driver_t に相当（tmk_core/protocol/host_driver.h）
///
/// フィールド順は C版と完全一致:
///   keyboard_leds, send_keyboard, send_nkro, send_mouse, send_extra
///
/// 注意: send_nkro はバイナリ互換性のためフィールドとして存在するが、
/// Zig版は NKRO 非対応のため常に null を設定する。
pub const CHostDriver = extern struct {
    keyboard_leds: ?*const fn () callconv(.c) u8,
    send_keyboard: ?*const fn (*const @import("../core/report.zig").KeyboardReport) callconv(.c) void,
    /// NKRO 非対応につき常に null。C版 host_driver_t とのバイナリ互換性のため維持。
    send_nkro: ?*const fn (*const anyopaque) callconv(.c) void,
    send_mouse: ?*const fn (*const @import("../core/report.zig").MouseReport) callconv(.c) void,
    send_extra: ?*const fn (*const @import("../core/report.zig").ExtraReport) callconv(.c) void,
};

/// C ABI ドライバアダプタ
/// CHostDriver の関数ポインタを HostDriver インターフェースに変換する
const CDriverAdapter = struct {
    c_driver: *const CHostDriver,

    pub fn keyboardLeds(self: *CDriverAdapter) u8 {
        if (self.c_driver.keyboard_leds) |f| return f();
        return 0;
    }

    pub fn sendKeyboard(self: *CDriverAdapter, r: @import("../core/report.zig").KeyboardReport) void {
        if (self.c_driver.send_keyboard) |f| f(&r);
    }

    pub fn sendMouse(self: *CDriverAdapter, r: @import("../core/report.zig").MouseReport) void {
        if (self.c_driver.send_mouse) |f| f(&r);
    }

    pub fn sendExtra(self: *CDriverAdapter, r: @import("../core/report.zig").ExtraReport) void {
        if (self.c_driver.send_extra) |f| f(&r);
    }
};

var c_driver_adapter: CDriverAdapter = .{ .c_driver = &empty_c_driver };
const empty_c_driver = CHostDriver{
    .keyboard_leds = null,
    .send_keyboard = null,
    .send_nkro = null,
    .send_mouse = null,
    .send_extra = null,
};

/// Set host driver (C ABI wrapper)
/// C版の host_set_driver(host_driver_t*) に相当
///
/// 注意: driver ポインタは内部に保持され、ドライバが使用される間（次の
/// host_set_driver(null) 呼び出しまで）有効であり続ける必要がある。
/// C版 host_set_driver と同様のライフタイム制約。
export fn host_set_driver(driver: ?*const CHostDriver) void {
    if (driver) |d| {
        c_driver_adapter = .{ .c_driver = d };
        host_mod.setDriver(host_mod.HostDriver.from(&c_driver_adapter));
    } else {
        c_driver_adapter = .{ .c_driver = &empty_c_driver };
        host_mod.clearDriver();
    }
}

/// Get host driver (C ABI wrapper)
/// 現在ドライバが設定されているかどうかを返す（簡易版）
export fn host_get_driver() ?*const CHostDriver {
    if (host_mod.getDriver() != null) {
        return c_driver_adapter.c_driver;
    }
    return null;
}

// ============================================================
// Timer
// ============================================================

/// Read current time in milliseconds (16-bit)
export fn timer_read() u16 {
    return timer.read();
}

/// Read current time in milliseconds (32-bit)
export fn timer_read32() u32 {
    return timer.read32();
}

/// Clear (reset) the timer
/// Note: テスト環境では `timer.init()` が `mock_timer_ms = 0` にリセットするため
/// 期待通り動作する。freestanding（実機）では `timer.init()` は no-op のため、
/// RP2040 のハードウェアタイマーはリセットされず、QMK C の `timer_clear()` の
/// セマンティクス（タイマーカウンタのリセット）と一致しない。
/// Phase 1 ではテスト専用なので動作上の問題はない。
export fn timer_clear() void {
    timer.init();
}

/// Set mock timer to specific value (test only)
export fn set_time(ms: u32) void {
    timer.mockSet(ms);
}

/// Advance mock timer (test only)
export fn advance_time(ms: u32) void {
    timer.mockAdvance(ms);
}

// ============================================================
// Keymap
// ============================================================

/// Get keycode at given layer and position
/// keyboard_mod の test_keymap を参照する
export fn keymap_key_to_keycode(layer: u8, row: u8, col: u8) u16 {
    const km = keyboard_mod.getTestKeymap();
    if (layer >= keymap_mod.MAX_LAYERS) return 0;
    return keymap_mod.keymapKeyToKeycode(km, @intCast(layer), row, col);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "qmk_abi: layer_on/off/state_is" {
    layer_mod.resetState();
    layer_on(1);
    try testing.expect(layer_state_is(1));
    layer_off(1);
    try testing.expect(!layer_state_is(1));
}

test "qmk_abi: layer_clear" {
    layer_mod.resetState();
    layer_on(1);
    layer_on(3);
    layer_clear();
    try testing.expect(!layer_state_is(1));
    try testing.expect(!layer_state_is(3));
}

test "qmk_abi: layer_state_set" {
    layer_mod.resetState();
    layer_state_set(0b1010);
    try testing.expect(layer_state_is(1));
    try testing.expect(layer_state_is(3));
    try testing.expect(!layer_state_is(2));
}

test "qmk_abi: layer_move" {
    layer_mod.resetState();
    layer_on(1);
    layer_on(2);
    layer_move(3);
    try testing.expect(!layer_state_is(1));
    try testing.expect(!layer_state_is(2));
    try testing.expect(layer_state_is(3));
}

test "qmk_abi: layer boundary check" {
    layer_mod.resetState();
    // Should not crash with out-of-range layer
    layer_on(255);
    try testing.expect(!layer_state_is(255));
    layer_off(255);
    layer_move(255);
}

test "qmk_abi: timer_read/read32" {
    timer.mockReset();
    try testing.expectEqual(@as(u16, 0), timer_read());
    try testing.expectEqual(@as(u32, 0), timer_read32());
}

test "qmk_abi: set_time/advance_time" {
    timer.mockReset();
    set_time(100);
    try testing.expectEqual(@as(u32, 100), timer_read32());
    advance_time(50);
    try testing.expectEqual(@as(u32, 150), timer_read32());
}

test "qmk_abi: timer_clear resets timer" {
    timer.mockReset();
    set_time(500);
    timer_clear();
    try testing.expectEqual(@as(u32, 0), timer_read32());
}

test "qmk_abi: keyboard_init/task lifecycle" {
    keyboard_init();
    keyboard_task();
}

test "qmk_abi: register_code/unregister_code with mock driver" {
    const FixedTestDriver = @import("../core/test_driver.zig").FixedTestDriver;
    const MockDriver = FixedTestDriver(32, 4);

    keyboard_init();
    var mock = MockDriver{};
    host_mod.setDriver(host_mod.HostDriver.from(&mock));
    defer host_mod.clearDriver();

    register_code(0x04); // KC_A
    send_keyboard_report();
    try testing.expect(mock.lastKeyboardReport().hasKey(0x04));

    unregister_code(0x04);
    send_keyboard_report();
    try testing.expect(!mock.lastKeyboardReport().hasKey(0x04));
}

test "qmk_abi: register_code modifier key" {
    const FixedTestDriver = @import("../core/test_driver.zig").FixedTestDriver;
    const MockDriver = FixedTestDriver(32, 4);

    keyboard_init();
    var mock = MockDriver{};
    host_mod.setDriver(host_mod.HostDriver.from(&mock));
    defer host_mod.clearDriver();

    register_code(0xE1); // LSHIFT
    send_keyboard_report();
    try testing.expectEqual(@as(u8, 0x02), mock.lastKeyboardReport().mods);

    unregister_code(0xE1);
    send_keyboard_report();
    try testing.expectEqual(@as(u8, 0x00), mock.lastKeyboardReport().mods);
}

test "qmk_abi: clear_keyboard clears all state" {
    const FixedTestDriver = @import("../core/test_driver.zig").FixedTestDriver;
    const MockDriver = FixedTestDriver(32, 4);

    keyboard_init();
    var mock = MockDriver{};
    host_mod.setDriver(host_mod.HostDriver.from(&mock));
    defer host_mod.clearDriver();

    register_code(0x04);
    register_code(0xE1);
    clear_keyboard();
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

test "qmk_abi: host_set_driver/host_get_driver null" {
    keyboard_init();
    host_set_driver(null);
    try testing.expectEqual(@as(?*const CHostDriver, null), host_get_driver());
}

test "qmk_abi: action_exec does not crash" {
    keyboard_init();
    action_exec(0, 0, true, 100);
    action_exec(0, 0, false, 200);
}

test "qmk_abi: process_record does not crash" {
    keyboard_init();
    process_record(0, 0, true, 100);
    process_record(0, 0, false, 200);
}

test "qmk_abi: keymap_key_to_keycode returns keycode from test keymap" {
    const keycode_mod = @import("../core/keycode.zig");
    keyboard_init();
    // 初期状態ではすべて KC_NO (0)
    try testing.expectEqual(@as(u16, 0), keymap_key_to_keycode(0, 0, 0));

    // テストキーマップにキーを設定
    keyboard_mod.setTestKey(0, 0, 0, keycode_mod.KC.A);
    try testing.expectEqual(keycode_mod.KC.A, keymap_key_to_keycode(0, 0, 0));

    // 範囲外のレイヤーは 0 を返す
    try testing.expectEqual(@as(u16, 0), keymap_key_to_keycode(255, 0, 0));

    // クリーンアップ
    keyboard_init();
}
