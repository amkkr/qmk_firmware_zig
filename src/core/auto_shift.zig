// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zig port of quantum/process_keycode/process_auto_shift.c
// Original: Copyright 2017 Jeremy Cowgar

//! Auto Shift: TAPPING_TERM より長くホールドすると自動で Shift を適用
//! C版 quantum/process_keycode/process_auto_shift.c の移植
//!
//! 対象キー（英字・数字・記号）をプレスした時刻を記録し、
//! リリース時に保持時間を判定:
//!   - AUTO_SHIFT_TIMEOUT 以上: Shift + key として送信
//!   - AUTO_SHIFT_TIMEOUT 未満: 通常 key として送信

const host = @import("host.zig");
const report_mod = @import("report.zig");
const keycode = @import("keycode.zig");
const KC = keycode.KC;

/// Auto Shift のタイムアウト値（ミリ秒）
/// C版 AUTO_SHIFT_TIMEOUT に相当（デフォルト175ms）
pub const AUTO_SHIFT_TIMEOUT: u16 = 175;

/// Auto Shift の有効/無効フラグ（デフォルト: 無効）
var enabled: bool = false;

/// Auto Shift を有効化する
pub fn enable() void {
    enabled = true;
}

/// Auto Shift を無効化する
pub fn disable() void {
    enabled = false;
    state = .{};
}

/// Auto Shift が有効かどうかを返す
pub fn isEnabled() bool {
    return enabled;
}

/// Auto Shift 対象キーの状態
const AutoShiftState = struct {
    /// 対象キーが保留中か
    in_progress: bool = false,
    /// プレス時刻
    press_time: u16 = 0,
    /// 保留中のキーコード（Keycode = u16）
    pending_kc: u16 = 0,
};

var state: AutoShiftState = .{};

/// キーコードが Auto Shift 対象かどうかを判定する
///
/// 対象:
///   - 英字キー (KC_A ~ KC_Z: 0x04 ~ 0x1D)
///   - 数字キー (KC_1 ~ KC_0: 0x1E ~ 0x27)
///   - 記号キー (KC_MINUS ~ KC_SLASH: 0x2D ~ 0x38)
///   - TAB (0x2B)
pub fn isAutoShiftable(kc: u16) bool {
    // 英字 A-Z
    if (kc >= KC.A and kc <= KC.Z) return true;
    // 数字 1-0
    if (kc >= KC.@"1" and kc <= KC.@"0") return true;
    // TAB
    if (kc == KC.TAB) return true;
    // 記号 MINUS ~ SLASH (-, =, [, ], \, #, ;, ', `, ,, ., /)
    if (kc >= KC.MINUS and kc <= KC.SLASH) return true;

    return false;
}

/// Auto Shift のキーイベントを処理する
///
/// プレスイベントの場合: 対象キーなら保留状態にして true を返す
/// リリースイベントの場合: 保留中のキーを時間判定して送信し true を返す
/// 対象外のキーの場合: false を返す（呼び出し元が通常処理を続行）
///
/// 戻り値:
///   true  = Auto Shift が処理を消費した（呼び出し元は何もしない）
///   false = Auto Shift の対象外（呼び出し元が通常処理を行う）
pub fn processAutoShift(kc: u16, pressed: bool, time: u16) bool {
    if (!enabled) return false;

    if (pressed) {
        // 別のキーが押された場合、保留中のキーを確定する
        if (state.in_progress and kc != state.pending_kc) {
            finishAutoShift(time);
        }

        if (isAutoShiftable(kc)) {
            // プレス: 時刻記録して保留
            state.in_progress = true;
            state.press_time = time;
            state.pending_kc = kc;
            return true;
        }

        return false;
    } else {
        // リリース
        if (state.in_progress and kc == state.pending_kc) {
            finishAutoShift(time);
            return true;
        }

        return false;
    }
}

/// 保留中の Auto Shift キーを確定する
fn finishAutoShift(time: u16) void {
    if (!state.in_progress) return;

    const elapsed = time -% state.press_time;
    const shifted = elapsed >= AUTO_SHIFT_TIMEOUT;

    if (shifted) {
        host.addWeakMods(report_mod.ModBit.LSHIFT);
    }

    host.registerCode(@truncate(state.pending_kc));
    host.sendKeyboardReport();

    host.unregisterCode(@truncate(state.pending_kc));
    if (shifted) {
        host.delWeakMods(report_mod.ModBit.LSHIFT);
    }
    host.sendKeyboardReport();

    state = .{};
}

/// Auto Shift の内部状態をリセットする（enabled フラグも無効に戻す）
pub fn reset() void {
    state = .{};
    enabled = false;
}

/// 保留中のキーがあるかどうかを返す（テスト用）
pub fn isInProgress() bool {
    return state.in_progress;
}

// ============================================================
// Tests
// ============================================================

const std = @import("std");
const testing = std.testing;
const FixedTestDriver = @import("test_driver.zig").FixedTestDriver;

test "isAutoShiftable: 英字キー" {
    try testing.expect(isAutoShiftable(KC.A));
    try testing.expect(isAutoShiftable(KC.Z));
    try testing.expect(isAutoShiftable(KC.M));
}

test "isAutoShiftable: 数字キー" {
    try testing.expect(isAutoShiftable(KC.@"1"));
    try testing.expect(isAutoShiftable(KC.@"0"));
    try testing.expect(isAutoShiftable(KC.@"5"));
}

test "isAutoShiftable: 記号キー" {
    try testing.expect(isAutoShiftable(KC.MINUS));
    try testing.expect(isAutoShiftable(KC.EQUAL));
    try testing.expect(isAutoShiftable(KC.LBRC));
    try testing.expect(isAutoShiftable(KC.SLASH));
}

test "isAutoShiftable: TAB" {
    try testing.expect(isAutoShiftable(KC.TAB));
}

test "isAutoShiftable: 対象外キー" {
    try testing.expect(!isAutoShiftable(KC.ENTER));
    try testing.expect(!isAutoShiftable(KC.ESCAPE));
    try testing.expect(!isAutoShiftable(KC.BACKSPACE));
    try testing.expect(!isAutoShiftable(KC.SPACE));
    try testing.expect(!isAutoShiftable(KC.LEFT_CTRL));
    try testing.expect(!isAutoShiftable(KC.F1));
    try testing.expect(!isAutoShiftable(0)); // KC_NO
}

test "processAutoShift: 無効時は常に false" {
    reset();
    // enabled = false（デフォルト）
    try testing.expect(!processAutoShift(KC.A, true, 100));
    try testing.expect(!isInProgress());
}

test "processAutoShift: 短いタップでシフトなし" {
    reset();
    enable();
    host.hostReset();
    var mock = FixedTestDriver(32, 4){};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // KC_A を押す（time=100）
    try testing.expect(processAutoShift(KC.A, true, 100));
    try testing.expect(isInProgress());
    // 押しただけではレポートは送信されない
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // KC_A を離す（time=150, elapsed=50 < AUTO_SHIFT_TIMEOUT）
    try testing.expect(processAutoShift(KC.A, false, 150));
    try testing.expect(!isInProgress());

    // レポートが送信される（シフトなし）
    try testing.expect(mock.keyboard_count >= 1);
    // 最後のレポートは空（キーリリース後）
    try testing.expect(mock.lastKeyboardReport().isEmpty());
    // 1つ前のレポートにキーが含まれている（シフトなし）
    try testing.expect(mock.keyboard_reports[0].hasKey(KC.A));
    try testing.expectEqual(@as(u8, 0), mock.keyboard_reports[0].mods);
}

test "processAutoShift: 長いホールドでシフトあり" {
    reset();
    enable();
    host.hostReset();
    var mock = FixedTestDriver(32, 4){};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // KC_A を押す（time=100）
    try testing.expect(processAutoShift(KC.A, true, 100));

    // KC_A を離す（time=300, elapsed=200 >= AUTO_SHIFT_TIMEOUT=175）
    try testing.expect(processAutoShift(KC.A, false, 300));

    // レポートが送信される（シフトあり）
    try testing.expect(mock.keyboard_count >= 2);
    // 1つ目のレポート: Shift + A
    try testing.expect(mock.keyboard_reports[0].hasKey(KC.A));
    try testing.expectEqual(report_mod.ModBit.LSHIFT, mock.keyboard_reports[0].mods & report_mod.ModBit.LSHIFT);
    // 2つ目のレポート: 空（リリース）
    try testing.expect(mock.keyboard_reports[1].isEmpty());
}

test "processAutoShift: 対象外キーは false を返す" {
    reset();
    enable();

    try testing.expect(!processAutoShift(KC.ENTER, true, 100));
    try testing.expect(!processAutoShift(KC.SPACE, true, 100));
    try testing.expect(!processAutoShift(KC.LEFT_CTRL, true, 100));
    try testing.expect(!isInProgress());
}

test "processAutoShift: 別キー押下で保留を確定" {
    reset();
    enable();
    host.hostReset();
    var mock = FixedTestDriver(32, 4){};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // KC_A を押す（time=100）
    try testing.expect(processAutoShift(KC.A, true, 100));
    try testing.expect(isInProgress());

    // KC_B を押す（time=150, elapsed=50 < TIMEOUT → シフトなし確定）
    try testing.expect(processAutoShift(KC.B, true, 150));
    // KC_A は確定済み、KC_B が保留中
    try testing.expect(isInProgress());
    // KC_A のレポートが送信されている
    try testing.expect(mock.keyboard_reports[0].hasKey(KC.A));
    try testing.expectEqual(@as(u8, 0), mock.keyboard_reports[0].mods);
}

test "processAutoShift: リセットでクリア" {
    reset();
    enable();

    _ = processAutoShift(KC.A, true, 100);
    try testing.expect(isInProgress());

    reset();
    try testing.expect(!isInProgress());
}

test "processAutoShift: 正確な境界値テスト" {
    reset();
    enable();
    host.hostReset();
    var mock = FixedTestDriver(32, 4){};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // elapsed == AUTO_SHIFT_TIMEOUT（ちょうど境界）→ シフトあり
    _ = processAutoShift(KC.A, true, 0);
    _ = processAutoShift(KC.A, false, AUTO_SHIFT_TIMEOUT);
    try testing.expect(mock.keyboard_reports[0].hasKey(KC.A));
    try testing.expectEqual(report_mod.ModBit.LSHIFT, mock.keyboard_reports[0].mods & report_mod.ModBit.LSHIFT);
}

test "processAutoShift: タイマーラップアラウンド" {
    reset();
    enable();
    host.hostReset();
    var mock = FixedTestDriver(32, 4){};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // press at 65535 (near u16 max), release at 100 (wrapped around)
    // elapsed = 100 -% 65535 = 101 < AUTO_SHIFT_TIMEOUT → シフトなし
    _ = processAutoShift(KC.A, true, 65535);
    _ = processAutoShift(KC.A, false, 100);
    try testing.expect(mock.keyboard_reports[0].hasKey(KC.A));
    try testing.expectEqual(@as(u8, 0), mock.keyboard_reports[0].mods);
}
