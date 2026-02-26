//! Space Cadet 機能
//! C版 quantum/process_keycode/process_space_cadet.c に相当
//!
//! Shift/Ctrl/Alt キーをタップすると対応する括弧文字を入力する機能。
//!
//! デフォルトマッピング:
//! - QK_SPACE_CADET_LEFT_SHIFT_PARENTHESIS_OPEN  (SC_LSPO): LSHIFT タップ → ( (KC_9 with LSHIFT)
//! - QK_SPACE_CADET_RIGHT_SHIFT_PARENTHESIS_CLOSE (SC_RSPC): RSHIFT タップ → ) (KC_0 with RSHIFT)
//! - QK_SPACE_CADET_LEFT_CTRL_PARENTHESIS_OPEN   (SC_LCPO): LCTRL タップ → ( (KC_9 with LSHIFT)
//! - QK_SPACE_CADET_RIGHT_CTRL_PARENTHESIS_CLOSE  (SC_RCPC): RCTRL タップ → ) (KC_0 with RSHIFT)
//! - QK_SPACE_CADET_LEFT_ALT_PARENTHESIS_OPEN    (SC_LAPO): LALT タップ → ( (KC_9 with LSHIFT)
//! - QK_SPACE_CADET_RIGHT_ALT_PARENTHESIS_CLOSE   (SC_RAPC): RALT タップ → ) (KC_0 with RSHIFT)
//! - QK_SPACE_CADET_RIGHT_SHIFT_ENTER            (SC_SENT): RSHIFT タップ → Enter

const keycode_mod = @import("keycode.zig");
const host = @import("host.zig");
const report_mod = @import("report.zig");
const timer = @import("../hal/timer.zig");
const Keycode = keycode_mod.Keycode;
const KC = keycode_mod.KC;

// ============================================================
// Space Cadet キーコード定義（keycode.zig から参照）
// ============================================================

pub const QK_SPACE_CADET_LEFT_SHIFT_PARENTHESIS_OPEN: Keycode = keycode_mod.QK_SPACE_CADET_LEFT_SHIFT_PARENTHESIS_OPEN;
pub const QK_SPACE_CADET_RIGHT_SHIFT_PARENTHESIS_CLOSE: Keycode = keycode_mod.QK_SPACE_CADET_RIGHT_SHIFT_PARENTHESIS_CLOSE;
pub const QK_SPACE_CADET_LEFT_CTRL_PARENTHESIS_OPEN: Keycode = keycode_mod.QK_SPACE_CADET_LEFT_CTRL_PARENTHESIS_OPEN;
pub const QK_SPACE_CADET_RIGHT_CTRL_PARENTHESIS_CLOSE: Keycode = keycode_mod.QK_SPACE_CADET_RIGHT_CTRL_PARENTHESIS_CLOSE;
pub const QK_SPACE_CADET_LEFT_ALT_PARENTHESIS_OPEN: Keycode = keycode_mod.QK_SPACE_CADET_LEFT_ALT_PARENTHESIS_OPEN;
pub const QK_SPACE_CADET_RIGHT_ALT_PARENTHESIS_CLOSE: Keycode = keycode_mod.QK_SPACE_CADET_RIGHT_ALT_PARENTHESIS_CLOSE;
pub const QK_SPACE_CADET_RIGHT_SHIFT_ENTER: Keycode = keycode_mod.QK_SPACE_CADET_RIGHT_SHIFT_ENTER;

/// 短縮エイリアス
pub const SC_LSPO: Keycode = QK_SPACE_CADET_LEFT_SHIFT_PARENTHESIS_OPEN;
pub const SC_RSPC: Keycode = QK_SPACE_CADET_RIGHT_SHIFT_PARENTHESIS_CLOSE;
pub const SC_LCPO: Keycode = QK_SPACE_CADET_LEFT_CTRL_PARENTHESIS_OPEN;
pub const SC_RCPC: Keycode = QK_SPACE_CADET_RIGHT_CTRL_PARENTHESIS_CLOSE;
pub const SC_LAPO: Keycode = QK_SPACE_CADET_LEFT_ALT_PARENTHESIS_OPEN;
pub const SC_RAPC: Keycode = QK_SPACE_CADET_RIGHT_ALT_PARENTHESIS_CLOSE;
pub const SC_SENT: Keycode = QK_SPACE_CADET_RIGHT_SHIFT_ENTER;
pub const QK_SPACE_CADET_MIN: Keycode = QK_SPACE_CADET_LEFT_SHIFT_PARENTHESIS_OPEN;
pub const QK_SPACE_CADET_MAX: Keycode = QK_SPACE_CADET_RIGHT_SHIFT_ENTER;

// ============================================================
// タッピング設定
// ============================================================

/// Space Cadet のタッピング判定時間（ミリ秒）
pub const SC_TAPPING_TERM: u16 = 200;

// ============================================================
// Space Cadet キー設定
// ============================================================

/// Space Cadet の1エントリ設定
pub const SpaceCadetKey = struct {
    /// このエントリに対応する Space Cadet キーコード
    sc_keycode: Keycode,
    /// ホールド時に送信する修飾キー（HID modifier bit）
    hold_mod: u8,
    /// タップ時に送信する前の修飾キー（タップ文字が必要な場合）
    tap_mod: u8,
    /// タップ時に送信するキーコード（基本キー、0x00-0xFF）
    tap_key: u8,
};

/// デフォルトの Space Cadet キー設定テーブル
/// C版の perform_space_cadet() 呼び出し引数に対応する
const sc_keys: [7]SpaceCadetKey = .{
    // SC_LSPO: LSHIFT hold, LSHIFT tap-mod, KC_9 tap-key → (
    .{
        .sc_keycode = SC_LSPO,
        .hold_mod = report_mod.ModBit.LSHIFT,
        .tap_mod = report_mod.ModBit.LSHIFT,
        .tap_key = KC.@"9",
    },
    // SC_RSPC: RSHIFT hold, RSHIFT tap-mod, KC_0 tap-key → )
    .{
        .sc_keycode = SC_RSPC,
        .hold_mod = report_mod.ModBit.RSHIFT,
        .tap_mod = report_mod.ModBit.RSHIFT,
        .tap_key = KC.@"0",
    },
    // SC_LCPO: LCTRL hold, LSHIFT tap-mod, KC_9 tap-key → (
    // C版デフォルト: LCPO_KEYS = KC_LEFT_CTRL, KC_LEFT_SHIFT, KC_9
    .{
        .sc_keycode = SC_LCPO,
        .hold_mod = report_mod.ModBit.LCTRL,
        .tap_mod = report_mod.ModBit.LSHIFT,
        .tap_key = KC.@"9",
    },
    // SC_RCPC: RCTRL hold, RSHIFT tap-mod, KC_0 tap-key → )
    // C版デフォルト: RCPC_KEYS = KC_RIGHT_CTRL, KC_RIGHT_SHIFT, KC_0
    .{
        .sc_keycode = SC_RCPC,
        .hold_mod = report_mod.ModBit.RCTRL,
        .tap_mod = report_mod.ModBit.RSHIFT,
        .tap_key = KC.@"0",
    },
    // SC_LAPO: LALT hold, LSHIFT tap-mod, KC_9 tap-key → (
    // C版デフォルト: LAPO_KEYS = KC_LEFT_ALT, KC_LEFT_SHIFT, KC_9
    .{
        .sc_keycode = SC_LAPO,
        .hold_mod = report_mod.ModBit.LALT,
        .tap_mod = report_mod.ModBit.LSHIFT,
        .tap_key = KC.@"9",
    },
    // SC_RAPC: RALT hold, RSHIFT tap-mod, KC_0 tap-key → )
    // C版デフォルト: RAPC_KEYS = KC_RIGHT_ALT, KC_RIGHT_SHIFT, KC_0
    .{
        .sc_keycode = SC_RAPC,
        .hold_mod = report_mod.ModBit.RALT,
        .tap_mod = report_mod.ModBit.RSHIFT,
        .tap_key = KC.@"0",
    },
    // SC_SENT: RSHIFT hold, TRANSPARENT tap-mod, KC_ENT tap-key → Enter
    // C版デフォルト: SFTENT_KEYS = KC_RIGHT_SHIFT, KC_TRANSPARENT, SFTENT_KEY
    .{
        .sc_keycode = SC_SENT,
        .hold_mod = report_mod.ModBit.RSHIFT,
        .tap_mod = 0, // KC_TRANSPARENT → 追加mod不要
        .tap_key = KC.ENTER,
    },
};

// ============================================================
// 内部状態
// ============================================================

/// 最後に押されたホールドmod（タップ判定で使用）
var sc_last: u8 = 0;
/// 最後に押された時刻（タップ判定で使用）
var sc_timer: u16 = 0;

// ============================================================
// パブリック API
// ============================================================

/// Space Cadet キーコードかどうかを確認する
pub fn isSpaceCadetKeycode(kc: Keycode) bool {
    return kc >= QK_SPACE_CADET_MIN and kc <= QK_SPACE_CADET_MAX;
}

/// Space Cadet 処理
///
/// 戻り値:
/// - true:  通常の処理を続ける（上位に処理を渡す）
/// - false: このモジュールで処理済み（Space Cadet キーとして消費）
///
/// 処理ロジック（C版 process_space_cadet() / perform_space_cadet() 互換）:
/// - Space Cadet キー以外が押された場合: sc_last をリセットして通常処理
/// - Space Cadet キー Press:
///   - hold_mod を登録して修飾キーとしての動作開始
///   - sc_last と sc_timer を記録
/// - Space Cadet キー Release:
///   - タッピング判定（sc_last == hold_mod かつ SC_TAPPING_TERM 以内）:
///     - hold_mod を解除
///     - tap_mod を登録（hold_mod と異なる場合）
///     - tap_key を送信（press/release）
///     - tap_mod を解除
///   - ホールド判定（タイムアウト）:
///     - hold_mod を解除
pub fn process(kc: Keycode, pressed: bool) bool {
    // Space Cadet キーを検索する
    const entry = findEntry(kc);

    if (entry == null) {
        // Space Cadet キー以外: sc_last をリセット
        if (pressed) {
            sc_last = 0;
        }
        return true;
    }

    const sc = entry.?;

    if (pressed) {
        // ホールドmod を登録
        sc_last = sc.hold_mod;
        sc_timer = timer.read();
        if (sc.hold_mod != 0) {
            host.addMods(sc.hold_mod);
            host.sendKeyboardReport();
        }
    } else {
        // タッピング判定
        if (sc_last == sc.hold_mod and timer.elapsed(sc_timer) < SC_TAPPING_TERM) {
            // タップ: 括弧文字を送信する
            if (sc.hold_mod != sc.tap_mod) {
                // hold_mod が tap_mod と異なる場合、hold_mod を解除して tap_mod を登録
                if (sc.hold_mod != 0) {
                    host.delMods(sc.hold_mod);
                }
                if (sc.tap_mod != 0) {
                    host.addMods(sc.tap_mod);
                }
            }
            // tap_key を press/release
            if (sc.tap_key != 0) {
                host.registerCode(sc.tap_key);
                host.sendKeyboardReport();
                host.unregisterCode(sc.tap_key);
                host.sendKeyboardReport();
            }
            // tap_mod を解除
            if (sc.tap_mod != 0) {
                host.delMods(sc.tap_mod);
                host.sendKeyboardReport();
            }
        } else {
            // ホールド: hold_mod を解除する
            if (sc.hold_mod != 0) {
                host.delMods(sc.hold_mod);
                host.sendKeyboardReport();
            }
        }
    }

    return false;
}

/// 状態をリセットする
pub fn reset() void {
    sc_last = 0;
    sc_timer = 0;
}

// ============================================================
// 内部ヘルパー
// ============================================================

/// キーコードに対応する SpaceCadetKey エントリを検索する
fn findEntry(kc: Keycode) ?*const SpaceCadetKey {
    for (&sc_keys) |*entry| {
        if (entry.sc_keycode == kc) {
            return entry;
        }
    }
    return null;
}

// ============================================================
// Tests
// ============================================================

const std = @import("std");
const testing = std.testing;
const FixedTestDriver = @import("test_driver.zig").FixedTestDriver;
const MockDriver = FixedTestDriver(32, 4);

test "SC_LSPO: 短時間タップで '(' が送信される" {
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    host.hostReset();
    reset();
    timer.mockReset();
    defer host.clearDriver();

    // SC_LSPO を押す（LSHIFT が登録される）
    const result_press = process(SC_LSPO, true);
    try testing.expect(!result_press); // Space Cadet が消費
    // addMods は直接 real_mods に加算する（sendKeyboardReport 済み）
    // process() の中で既に sendKeyboardReport が呼ばれている
    try testing.expectEqual(report_mod.ModBit.LSHIFT, mock.lastKeyboardReport().mods & report_mod.ModBit.LSHIFT);

    // タッピング時間内にリリース → '(' を送信
    timer.mockAdvance(SC_TAPPING_TERM - 10);
    const result_release = process(SC_LSPO, false);
    try testing.expect(!result_release); // Space Cadet が消費

    // タップ中に KC_9 + LSHIFT が含まれるレポートが送信された
    var found_tap = false;
    for (0..mock.keyboard_count) |j| {
        if (mock.keyboard_reports[j].hasKey(KC.@"9") and
            mock.keyboard_reports[j].mods & report_mod.ModBit.LSHIFT != 0)
        {
            found_tap = true;
            break;
        }
    }
    try testing.expect(found_tap);

    // タップ後はモッドがクリアされている
    const last = mock.lastKeyboardReport();
    try testing.expectEqual(@as(u8, 0), last.mods); // tap_mod がクリアされた
}

test "SC_RSPC: 短時間タップで ')' が送信される" {
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    host.hostReset();
    reset();
    timer.mockReset();
    defer host.clearDriver();

    const result_press = process(SC_RSPC, true);
    try testing.expect(!result_press);

    timer.mockAdvance(50);
    const result_release = process(SC_RSPC, false);
    try testing.expect(!result_release);

    // ')'（KC_0 + RSHIFT）が送信された
    var found_tap = false;
    for (0..mock.keyboard_count) |j| {
        if (mock.keyboard_reports[j].hasKey(KC.@"0") and
            mock.keyboard_reports[j].mods & report_mod.ModBit.RSHIFT != 0)
        {
            found_tap = true;
            break;
        }
    }
    try testing.expect(found_tap);

    // 最終レポートはモッドがクリアされている
    const last = mock.lastKeyboardReport();
    try testing.expectEqual(@as(u8, 0), last.mods);
}

test "SC_LSPO: ホールド（タイムアウト）では LSHIFT として動作" {
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    host.hostReset();
    reset();
    timer.mockReset();
    defer host.clearDriver();

    // SC_LSPO を押す（sendKeyboardReport が内部で呼ばれる）
    _ = process(SC_LSPO, true);
    // LSHIFT が登録されている
    try testing.expectEqual(report_mod.ModBit.LSHIFT, mock.lastKeyboardReport().mods & report_mod.ModBit.LSHIFT);

    // タッピングタームを超えてリリース → ホールドとして処理
    timer.mockAdvance(SC_TAPPING_TERM + 50);
    _ = process(SC_LSPO, false);

    // リリース後はモッドがクリアされている
    try testing.expectEqual(@as(u8, 0), mock.lastKeyboardReport().mods);
}

test "SC_LCPO: 短時間タップで LSHIFT+KC_9 が送信される" {
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    host.hostReset();
    reset();
    timer.mockReset();
    defer host.clearDriver();

    // SC_LCPO を押す（LCTRL が登録される）
    _ = process(SC_LCPO, true);
    try testing.expectEqual(report_mod.ModBit.LCTRL, mock.lastKeyboardReport().mods & report_mod.ModBit.LCTRL);

    // タッピング時間内にリリース → LSHIFT+KC_9
    timer.mockAdvance(50);
    _ = process(SC_LCPO, false);

    // KC_9 + LSHIFT が含まれるレポートが送信された
    var found_tap = false;
    for (0..mock.keyboard_count) |j| {
        if (mock.keyboard_reports[j].hasKey(KC.@"9") and
            mock.keyboard_reports[j].mods & report_mod.ModBit.LSHIFT != 0)
        {
            found_tap = true;
            break;
        }
    }
    try testing.expect(found_tap);

    // 最終状態: モッドがクリア
    try testing.expectEqual(@as(u8, 0), mock.lastKeyboardReport().mods);
}

test "SC_SENT: 短時間タップで Enter が送信される" {
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    host.hostReset();
    reset();
    timer.mockReset();
    defer host.clearDriver();

    // SC_SENT を押す（RSHIFT が登録される）
    _ = process(SC_SENT, true);
    try testing.expectEqual(report_mod.ModBit.RSHIFT, mock.lastKeyboardReport().mods & report_mod.ModBit.RSHIFT);

    // タッピング時間内にリリース → KC_ENTER（tap_mod=0なのでShiftなし）
    timer.mockAdvance(50);
    _ = process(SC_SENT, false);

    // KC_ENTER がレポートに含まれること（tap_mod=0 なのでモッドなし）
    var found_enter = false;
    for (0..mock.keyboard_count) |j| {
        if (mock.keyboard_reports[j].hasKey(KC.ENTER)) {
            found_enter = true;
            break;
        }
    }
    try testing.expect(found_enter);

    // Enter が送信された後、モッドがクリアされている
    const last = mock.lastKeyboardReport();
    try testing.expectEqual(@as(u8, 0), last.mods);
}

test "isSpaceCadetKeycode: 範囲チェック" {
    try testing.expect(isSpaceCadetKeycode(SC_LSPO));
    try testing.expect(isSpaceCadetKeycode(SC_RSPC));
    try testing.expect(isSpaceCadetKeycode(SC_LCPO));
    try testing.expect(isSpaceCadetKeycode(SC_RCPC));
    try testing.expect(isSpaceCadetKeycode(SC_LAPO));
    try testing.expect(isSpaceCadetKeycode(SC_RAPC));
    try testing.expect(isSpaceCadetKeycode(SC_SENT));
    try testing.expect(!isSpaceCadetKeycode(KC.A));
    try testing.expect(!isSpaceCadetKeycode(KC.LEFT_SHIFT));
    try testing.expect(!isSpaceCadetKeycode(0x0000));
}

test "非 Space Cadet キーが押された場合、sc_last がリセットされる" {
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    host.hostReset();
    reset();
    timer.mockReset();
    defer host.clearDriver();

    // SC_LSPO を押して sc_last を設定
    _ = process(SC_LSPO, true);
    try testing.expect(sc_last == report_mod.ModBit.LSHIFT);

    // 通常キーが押される → sc_last がリセット
    const result = process(KC.A, true);
    try testing.expect(result); // 通常処理に渡される
    try testing.expect(sc_last == 0);
}

test "process: 通常キーは true を返す" {
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    host.hostReset();
    reset();
    timer.mockReset();
    defer host.clearDriver();

    try testing.expect(process(KC.A, true));
    try testing.expect(process(KC.A, false));
    try testing.expect(process(KC.LEFT_SHIFT, true));
}
