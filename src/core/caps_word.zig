// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zig port of quantum/caps_word.c
// Original: Copyright 2021-2022 Google LLC (Apache-2.0)

//! Caps Word 機能
//! C版 quantum/caps_word.c に相当
//!
//! Caps Word は CapsLock の改良版で、有効化すると英字キーに自動的に Shift を適用し、
//! スペース・エンター等の非英字キーを押すと自動的に無効化される。
//! CapsLock と異なり、数字や記号には Shift を適用しない。

const host = @import("host.zig");
const report_mod = @import("report.zig");
const keycode = @import("keycode.zig");
const timer = @import("../hal/timer.zig");
const KC = keycode.KC;

/// Caps Word アイドルタイムアウト（ミリ秒）
/// 0 の場合はタイムアウト無効（手動解除のみ）。
/// C版 CAPS_WORD_IDLE_TIMEOUT のデフォルト値: 5000ms
pub var idle_timeout: u16 = 5000;

/// 左右 Shift 同時押しで Caps Word を有効化する
/// C版 BOTH_SHIFTS_TURNS_ON_CAPS_WORD に相当
pub var both_shifts_enable: bool = false;

/// Shift ダブルタップで Caps Word を有効化する
/// C版 DOUBLE_TAP_SHIFT_TURNS_ON_CAPS_WORD に相当
pub var double_tap_shift_enable: bool = false;

/// ダブルタップの判定時間（ミリ秒）
pub var double_tap_shift_term: u16 = 200;

/// Caps Word が有効かどうか
var caps_word_active: bool = false;

/// 最後のキー入力時刻（アイドルタイムアウト用）
var last_key_time: u16 = 0;

/// BothShifts: 現在の Shift 押下状態
var lshift_pressed: bool = false;
var rshift_pressed: bool = false;

/// DoubleTapShift: 前回の Shift タップ時刻
var last_shift_tap_time: u16 = 0;
/// DoubleTapShift: 前回の Shift タップ回数
var shift_tap_count: u8 = 0;

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
    last_key_time = timer.read();
    host.setMods(0);
    host.clearWeakMods();
    host.clearOneshotMods();
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

    // キー入力時刻を更新（アイドルタイムアウト用）
    if (pressed) {
        last_key_time = timer.read();
    }

    // リリース時: weak mods の LSHIFT をクリアして通常通り処理
    // C版 process_caps_word() の release パスと同様
    if (!pressed) {
        host.delWeakMods(report_mod.ModBit.LSHIFT);
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

    // Minus/Underscore: C版同様 Shift を適用（_ を送信）
    if (kc == KC.MINS) {
        host.addWeakMods(report_mod.ModBit.LSHIFT);
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

/// アイドルタイムアウトチェック
/// keyboard_task() のメインループから毎サイクル呼ばれる。
/// Caps Word が有効かつタイムアウト設定が有効な場合、
/// 最後のキー入力から idle_timeout ミリ秒経過していたら自動解除する。
pub fn checkTimeout() void {
    if (!caps_word_active) return;
    if (idle_timeout == 0) return;
    if (timer.elapsed(last_key_time) >= idle_timeout) {
        deactivate();
    }
}

/// Shift キーイベントを処理して BothShifts / DoubleTapShift を検出する
/// keyboard.zig のキーイベント処理から呼ばれる。
/// 戻り値: true = Caps Word が有効化された
pub fn checkShiftTrigger(kc: keycode.Keycode, pressed: bool) bool {
    if (caps_word_active) return false;

    const is_lshift = (kc == KC.LEFT_SHIFT);
    const is_rshift = (kc == KC.RIGHT_SHIFT);
    if (!is_lshift and !is_rshift) {
        // Shift 以外のキー → ダブルタップカウンタをリセット
        if (pressed) {
            shift_tap_count = 0;
        }
        return false;
    }

    // BothShifts チェック
    if (both_shifts_enable and pressed) {
        if (is_lshift) lshift_pressed = true;
        if (is_rshift) rshift_pressed = true;
        if (lshift_pressed and rshift_pressed) {
            lshift_pressed = false;
            rshift_pressed = false;
            shift_tap_count = 0;
            activate();
            return true;
        }
    }
    if (!pressed) {
        if (is_lshift) lshift_pressed = false;
        if (is_rshift) rshift_pressed = false;
    }

    // DoubleTapShift チェック
    if (double_tap_shift_enable) {
        if (pressed) {
            const now = timer.read();
            if (shift_tap_count > 0 and timer.elapsed(last_shift_tap_time) <= double_tap_shift_term) {
                shift_tap_count = 0;
                activate();
                return true;
            }
            shift_tap_count = 1;
            last_shift_tap_time = now;
        }
    }

    return false;
}

/// 状態のリセット
pub fn reset() void {
    caps_word_active = false;
    last_key_time = 0;
    lshift_pressed = false;
    rshift_pressed = false;
    last_shift_tap_time = 0;
    shift_tap_count = 0;
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

test "caps word: idle timeout deactivates" {
    reset();
    host.hostReset();

    idle_timeout = 5000;
    timer.mockSet(1000);
    activate();
    try testing.expect(isActive());

    // 4999ms 経過 → まだアクティブ
    timer.mockSet(5999);
    checkTimeout();
    try testing.expect(isActive());

    // 5000ms 経過 → 自動解除
    timer.mockSet(6000);
    checkTimeout();
    try testing.expect(!isActive());
}

test "caps word: key press resets idle timer" {
    reset();
    host.hostReset();

    idle_timeout = 5000;
    timer.mockSet(1000);
    activate();

    // 3000ms 後にキー入力
    timer.mockSet(4000);
    _ = process(KC.A, true);
    try testing.expect(isActive());

    // 元の有効化から5000ms経過しても、キー入力からはまだ2000msしか経っていない
    timer.mockSet(6000);
    checkTimeout();
    try testing.expect(isActive());

    // キー入力から5000ms経過 → 自動解除
    timer.mockSet(9000);
    checkTimeout();
    try testing.expect(!isActive());
}

test "caps word: idle timeout 0 disables timeout" {
    reset();
    host.hostReset();

    idle_timeout = 0;
    timer.mockSet(0);
    activate();

    // idle_timeout = 0 のためタイムアウトが無効化されている
    timer.mockSet(60000);
    checkTimeout();
    try testing.expect(isActive());
}

// ============================================================
// BothShifts Tests
// ============================================================

test "caps word: both shifts activates" {
    reset();
    host.hostReset();
    both_shifts_enable = true;
    defer {
        both_shifts_enable = false;
    }

    try testing.expect(!isActive());

    // LSHIFT を押す
    _ = checkShiftTrigger(KC.LEFT_SHIFT, true);
    try testing.expect(!isActive());

    // RSHIFT を押す → BothShifts で有効化
    const activated = checkShiftTrigger(KC.RIGHT_SHIFT, true);
    try testing.expect(activated);
    try testing.expect(isActive());
}

test "caps word: both shifts disabled by default" {
    reset();
    host.hostReset();
    both_shifts_enable = false;

    _ = checkShiftTrigger(KC.LEFT_SHIFT, true);
    _ = checkShiftTrigger(KC.RIGHT_SHIFT, true);
    try testing.expect(!isActive()); // 有効化されない
}

test "caps word: both shifts order reversed" {
    reset();
    host.hostReset();
    both_shifts_enable = true;
    defer {
        both_shifts_enable = false;
    }

    // RSHIFT → LSHIFT でも有効化
    _ = checkShiftTrigger(KC.RIGHT_SHIFT, true);
    const activated = checkShiftTrigger(KC.LEFT_SHIFT, true);
    try testing.expect(activated);
    try testing.expect(isActive());
}

test "caps word: both shifts does not trigger when already active" {
    reset();
    host.hostReset();
    both_shifts_enable = true;
    defer {
        both_shifts_enable = false;
    }

    activate(); // 既に有効

    _ = checkShiftTrigger(KC.LEFT_SHIFT, true);
    const result = checkShiftTrigger(KC.RIGHT_SHIFT, true);
    try testing.expect(!result); // 既に有効なので false
}

// ============================================================
// DoubleTapShift Tests
// ============================================================

test "caps word: double tap shift activates" {
    reset();
    host.hostReset();
    double_tap_shift_enable = true;
    defer {
        double_tap_shift_enable = false;
    }

    timer.mockSet(100);

    // 1回目のタップ
    _ = checkShiftTrigger(KC.LEFT_SHIFT, true);
    try testing.expect(!isActive());

    // 2回目のタップ（200ms 以内）
    timer.mockSet(200);
    const activated = checkShiftTrigger(KC.LEFT_SHIFT, true);
    try testing.expect(activated);
    try testing.expect(isActive());
}

test "caps word: double tap shift timeout" {
    reset();
    host.hostReset();
    double_tap_shift_enable = true;
    defer {
        double_tap_shift_enable = false;
    }

    timer.mockSet(100);
    _ = checkShiftTrigger(KC.LEFT_SHIFT, true);

    // 201ms 後（タイムアウト超過）
    timer.mockSet(301);
    _ = checkShiftTrigger(KC.LEFT_SHIFT, true);
    try testing.expect(!isActive()); // タイムアウトで有効化されない
}

test "caps word: double tap shift reset by other key" {
    reset();
    host.hostReset();
    double_tap_shift_enable = true;
    defer {
        double_tap_shift_enable = false;
    }

    timer.mockSet(100);
    _ = checkShiftTrigger(KC.LEFT_SHIFT, true);

    // 別のキーを押す → ダブルタップカウンタリセット
    _ = checkShiftTrigger(KC.A, true);

    timer.mockSet(200);
    _ = checkShiftTrigger(KC.LEFT_SHIFT, true);
    try testing.expect(!isActive()); // リセットされたので有効化されない
}
