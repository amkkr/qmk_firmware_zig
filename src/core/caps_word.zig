//! Caps Word 機能
//! C版 quantum/caps_word.c に相当
//!
//! Caps Word は CapsLock の改良版で、有効化すると英字キーに自動的に Shift を適用し、
//! スペース・エンター等の非英字キーを押すと自動的に無効化される。
//! CapsLock と異なり、数字や記号には Shift を適用しない。

const host = @import("host.zig");
const report_mod = @import("report.zig");
const keycode = @import("keycode.zig");
const KC = keycode.KC;

/// Caps Word が有効かどうか
var caps_word_active: bool = false;

/// Caps Word の有効/無効を取得
pub fn isActive() bool {
    return caps_word_active;
}

/// Caps Word をトグルする
pub fn toggle() void {
    if (caps_word_active) {
        deactivate();
    } else {
        activate();
    }
}

/// Caps Word を有効化する
/// C版 caps_word_on() と同様に、有効化時にモッドをクリアする
pub fn activate() void {
    caps_word_active = true;
    host.setMods(0);
    host.clearWeakMods();
}

/// Caps Word を無効化する
pub fn deactivate() void {
    caps_word_active = false;
    // weak mods のクリア（Shift が残らないように）
    host.delWeakMods(report_mod.ModBit.LSHIFT);
}

/// キー押下時に Caps Word の処理を行う
/// Caps Word が有効な場合、キーコードに基づいて Shift を適用するか、
/// Caps Word を解除するかを判定する。
///
/// 戻り値: true = キーは通常通り処理される、false = キーを飲み込む（送信しない）
pub fn process(kc: u8, pressed: bool) bool {
    if (!caps_word_active) return true;

    // リリース時は何もしない（通常通り処理）
    if (!pressed) {
        return true;
    }

    // 英字キー (A-Z): Shift を適用して継続
    if (kc >= KC.A and kc <= KC.Z) {
        host.addWeakMods(report_mod.ModBit.LSHIFT);
        return true;
    }

    // 数字キー (1-0): Shift なしで継続
    if (kc >= KC.@"1" and kc <= KC.@"0") {
        return true;
    }

    // Backspace: Shift なしで継続
    if (kc == KC.BSPC) {
        return true;
    }

    // Delete: Shift なしで継続
    if (kc == KC.DEL) {
        return true;
    }

    // Minus/Underscore: Shift なしで継続
    if (kc == KC.MINS) {
        return true;
    }

    // 修飾キーは無視して継続
    if (kc >= 0xE0 and kc <= 0xE7) {
        return true;
    }

    // それ以外のキー: Caps Word を解除
    deactivate();
    return true;
}

/// 状態のリセット
pub fn reset() void {
    caps_word_active = false;
}

// ============================================================
// Tests
// ============================================================

const testing = @import("std").testing;
const FixedTestDriver = @import("test_driver.zig").FixedTestDriver(32, 4);

test "caps word: initial state is inactive" {
    reset();
    try testing.expect(!isActive());
}

test "caps word: toggle activates and deactivates" {
    reset();
    host.hostReset();

    toggle();
    try testing.expect(isActive());

    toggle();
    try testing.expect(!isActive());
}

test "caps word: activate and deactivate" {
    reset();
    host.hostReset();

    activate();
    try testing.expect(isActive());

    deactivate();
    try testing.expect(!isActive());
}

test "caps word: letter keys add LSHIFT" {
    reset();
    host.hostReset();
    var mock = FixedTestDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    activate();

    // 英字キーを押すと LSHIFT が weak mods に追加される
    _ = process(KC.A, true);
    try testing.expectEqual(@as(u8, report_mod.ModBit.LSHIFT), host.getWeakMods());
    try testing.expect(isActive()); // 継続中

    host.clearWeakMods();
}

test "caps word: number keys do not add shift" {
    reset();
    host.hostReset();
    var mock = FixedTestDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    activate();

    _ = process(KC.@"1", true);
    try testing.expectEqual(@as(u8, 0), host.getWeakMods());
    try testing.expect(isActive()); // 継続中
}

test "caps word: space deactivates" {
    reset();
    host.hostReset();

    activate();

    _ = process(KC.SPC, true);
    try testing.expect(!isActive()); // 解除された
}

test "caps word: backspace continues" {
    reset();
    host.hostReset();

    activate();

    _ = process(KC.BSPC, true);
    try testing.expect(isActive()); // 継続中
}

test "caps word: minus continues" {
    reset();
    host.hostReset();

    activate();

    _ = process(KC.MINS, true);
    try testing.expect(isActive()); // 継続中
}

test "caps word: release does not deactivate" {
    reset();
    host.hostReset();

    activate();

    _ = process(KC.SPC, false); // リリースは無視
    try testing.expect(isActive()); // 継続中
}

test "caps word: inactive mode passes through" {
    reset();
    host.hostReset();

    // 非アクティブ時はそのまま通過
    const result = process(KC.A, true);
    try testing.expect(result);
    try testing.expectEqual(@as(u8, 0), host.getWeakMods());
}

test "caps word: modifier keys continue" {
    reset();
    host.hostReset();

    activate();

    _ = process(0xE0, true); // LCTRL
    try testing.expect(isActive()); // 継続中

    _ = process(0xE1, true); // LSHIFT
    try testing.expect(isActive()); // 継続中
}

test "caps word: reset clears state" {
    activate();
    try testing.expect(isActive());

    reset();
    try testing.expect(!isActive());
}
