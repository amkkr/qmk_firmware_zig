//! Repeat Key 機能
//! C版 quantum/repeat_key.c に相当
//!
//! Repeat Key は直前に押したキーを再送信するキー。
//! 直前のキーコード（basic keycode）を記録し、Repeat Key 押下時に
//! register/unregister を実行する。

const host = @import("host.zig");
const keycode = @import("keycode.zig");
const KC = keycode.KC;

/// 直前に押されたキーコード（basic keycode, u8）
var last_keycode: u8 = 0;
/// 直前のキー押下時に適用されていた修飾キー（8bit HID format）
var last_mods: u8 = 0;

/// 直前のキーコードを記録する
/// action.zig の processModsAction 等から呼び出される
pub fn setLastKeycode(kc: u8, mods: u8) void {
    // 修飾キー自体は記録しない
    if (kc >= 0xE0 and kc <= 0xE7) return;
    // KC_NO は記録しない
    if (kc == 0) return;
    last_keycode = kc;
    last_mods = mods;
}

/// 記録されている直前のキーコードを取得
pub fn getLastKeycode() u8 {
    return last_keycode;
}

/// 記録されている直前の修飾キーを取得
pub fn getLastMods() u8 {
    return last_mods;
}

/// Repeat Key が押されたときの処理
/// 直前に記録されたキーコードを送信する
pub fn processRepeatKey(pressed: bool) void {
    if (last_keycode == 0) return;

    if (pressed) {
        // 直前のキーの修飾キーを一時的に適用
        if (last_mods != 0) {
            host.addWeakMods(last_mods);
        }
        host.registerCode(last_keycode);
        host.sendKeyboardReport();
    } else {
        host.unregisterCode(last_keycode);
        if (last_mods != 0) {
            host.delWeakMods(last_mods);
        }
        host.sendKeyboardReport();
    }
}

/// 状態のリセット
pub fn reset() void {
    last_keycode = 0;
    last_mods = 0;
}

// ============================================================
// Tests
// ============================================================

const testing = @import("std").testing;
const FixedTestDriver = @import("test_driver.zig").FixedTestDriver(32, 4);

test "repeat key: initial state" {
    reset();
    try testing.expectEqual(@as(u8, 0), getLastKeycode());
    try testing.expectEqual(@as(u8, 0), getLastMods());
}

test "repeat key: setLastKeycode records key" {
    reset();

    setLastKeycode(KC.A, 0);
    try testing.expectEqual(@as(u8, KC.A), getLastKeycode());
    try testing.expectEqual(@as(u8, 0), getLastMods());
}

test "repeat key: setLastKeycode records mods" {
    reset();

    setLastKeycode(KC.A, 0x02); // LSHIFT
    try testing.expectEqual(@as(u8, KC.A), getLastKeycode());
    try testing.expectEqual(@as(u8, 0x02), getLastMods());
}

test "repeat key: modifier keys are not recorded" {
    reset();

    setLastKeycode(KC.A, 0);
    setLastKeycode(0xE1, 0); // LSHIFT keycode
    try testing.expectEqual(@as(u8, KC.A), getLastKeycode()); // 変わらない
}

test "repeat key: KC_NO is not recorded" {
    reset();

    setLastKeycode(KC.A, 0);
    setLastKeycode(0, 0);
    try testing.expectEqual(@as(u8, KC.A), getLastKeycode()); // 変わらない
}

test "repeat key: processRepeatKey sends last key" {
    reset();
    host.hostReset();
    var mock = FixedTestDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    setLastKeycode(KC.A, 0);

    // Repeat Key を押す
    processRepeatKey(true);
    try testing.expect(mock.lastKeyboardReport().hasKey(KC.A));

    // Repeat Key を離す
    processRepeatKey(false);
    try testing.expect(!mock.lastKeyboardReport().hasKey(KC.A));
}

test "repeat key: processRepeatKey with mods" {
    reset();
    host.hostReset();
    var mock = FixedTestDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    setLastKeycode(KC.A, 0x02); // LSHIFT

    processRepeatKey(true);
    try testing.expect(mock.lastKeyboardReport().hasKey(KC.A));
    try testing.expectEqual(@as(u8, 0x02), mock.lastKeyboardReport().mods);

    processRepeatKey(false);
    try testing.expect(!mock.lastKeyboardReport().hasKey(KC.A));
}

test "repeat key: no-op when no key recorded" {
    reset();
    host.hostReset();
    var mock = FixedTestDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // 何も記録されていない状態で Repeat Key を押しても何も起こらない
    processRepeatKey(true);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);
}

test "repeat key: reset clears state" {
    setLastKeycode(KC.B, 0x04);
    try testing.expectEqual(@as(u8, KC.B), getLastKeycode());

    reset();
    try testing.expectEqual(@as(u8, 0), getLastKeycode());
    try testing.expectEqual(@as(u8, 0), getLastMods());
}
