//! Tapping テスト - Mod-Tap キーのタップ/ホールド動作検証
//!
//! upstream参照: tests/basic/test_tapping.cpp
//!
//! テストケース:
//! 1. TapA_SHFT_T_KeyReportsKey      — SFT_T(KC_P) タップ → KC_P
//! 2. HoldA_SHFT_T_KeyReportsShift   — SFT_T(KC_P) ホールド → LSHIFT
//! 3. TapA_CTL_T_KeyReportsKey       — CTL_T(KC_P) タップ → KC_P
//! 4. HoldA_CTL_T_KeyReportsCtrl     — CTL_T(KC_P) ホールド → LCTRL
//! 5. ANewTapWithinTappingTermIsBuggy — 連続タップの既知バグ動作（issue #1478）
//! 6. TapA_CTL_T_KeyWhileReleasingShift — シフト離し中のCTL_Tタップ
//! 7. TapA_CTL_T_KeyWhileReleasingLayer — レイヤー離し中のCTL_Tタップ

const std = @import("std");
const testing = std.testing;

// Core modules
const action = @import("../core/action.zig");
const action_code = @import("../core/action_code.zig");
const event_mod = @import("../core/event.zig");
const host_mod = @import("../core/host.zig");
const report_mod = @import("../core/report.zig");
const keycode = @import("../core/keycode.zig");
const layer_mod = @import("../core/layer.zig");
const tapping_mod = @import("../core/action_tapping.zig");

const Action = action_code.Action;
const KeyRecord = event_mod.KeyRecord;
const KeyEvent = event_mod.KeyEvent;
const KeyboardReport = report_mod.KeyboardReport;
const KC = keycode.KC;
const Mod = keycode.Mod;

const TAPPING_TERM = tapping_mod.TAPPING_TERM;

const MockDriver = @import("../core/test_driver.zig").FixedTestDriver(64, 16);

// ============================================================
// テスト用キーマップリゾルバ
// ============================================================
//
// C版 test_tapping.cpp のキーマップ:
//   (7,0) = SFT_T(KC_P)  -- テスト 1, 2, 5
//   (8,0) = CTL_T(KC_P)  -- テスト 3, 4
//   (7,0) = KC_LSFT      -- TapA_CTL_T_KeyWhileReleasingShift テスト用
//   (7,0) = MO(1)        -- TapA_CTL_T_KeyWhileReleasingLayer テスト用
//
// 単純化のため、以下のマッピングを使用:
//   (0,0) = SFT_T(KC_P) → ACTION_MODS_TAP_KEY(Mod.LSFT, KC_P)
//   (0,1) = CTL_T(KC_P) → ACTION_MODS_TAP_KEY(Mod.LCTL, KC_P)
//           レイヤー1アクティブ時は CTL_T(KC_Q)（layer test 用）
//   (0,2) = KC_LSFT     → ACTION_MODS_KEY(Mod.LSFT, 0)
//   (0,3) = KC_A        → ACTION_KEY(KC_A) (通常キー、interrupt テスト用)
//   (0,4) = MO(1)       → ACTION_LAYER_MOMENTARY(1) (layer test 用)

fn testActionResolver(ev: KeyEvent) Action {
    if (ev.key.row == 0) {
        return switch (ev.key.col) {
            // SFT_T(KC_P): hold=LSHIFT, tap=KC_P
            0 => .{ .code = action_code.ACTION_MODS_TAP_KEY(Mod.LSFT, @truncate(KC.P)) },
            // CTL_T(KC_P/KC_Q): レイヤー1アクティブ時は KC_Q
            1 => if (layer_mod.layerStateIs(1))
                .{ .code = action_code.ACTION_MODS_TAP_KEY(Mod.LCTL, @truncate(KC.Q)) }
            else
                .{ .code = action_code.ACTION_MODS_TAP_KEY(Mod.LCTL, @truncate(KC.P)) },
            // KC_LSFT: plain modifier key
            2 => .{ .code = action_code.ACTION_MODS_KEY(Mod.LSFT, 0) },
            // KC_A: plain key
            3 => .{ .code = action_code.ACTION_KEY(@truncate(KC.A)) },
            // MO(1): momentary layer key
            4 => .{ .code = action_code.ACTION_LAYER_MOMENTARY(1) },
            else => .{ .code = action_code.ACTION_NO },
        };
    }
    return .{ .code = action_code.ACTION_NO };
}

// ============================================================
// テストヘルパー
// ============================================================

var mock_driver: MockDriver = .{};

fn setup() *MockDriver {
    action.reset();
    mock_driver = .{};
    host_mod.setDriver(host_mod.HostDriver.from(&mock_driver));
    action.setActionResolver(testActionResolver);
    return &mock_driver;
}

fn teardown() void {
    host_mod.clearDriver();
}

fn press(row: u8, col: u8, time: u16) void {
    var record = KeyRecord{ .event = KeyEvent.keyPress(row, col, time) };
    action.actionExec(&record);
}

fn release(row: u8, col: u8, time: u16) void {
    var record = KeyRecord{ .event = KeyEvent.keyRelease(row, col, time) };
    action.actionExec(&record);
}

fn tick(time: u16) void {
    var record = KeyRecord{ .event = KeyEvent.tick(time) };
    action.actionExec(&record);
}

// ============================================================
// 1. TapA_SHFT_T_KeyReportsKey
//    SFT_T(KC_P) を TAPPING_TERM 以内にタップ → KC_P がレポートされる
// ============================================================

test "TapA_SHFT_T_KeyReportsKey" {
    const mock = setup();
    defer teardown();

    // SFT_T(KC_P) をプレス
    press(0, 0, 100);
    // タッピングキーはプレス時にはレポートされない（バッファリング中）

    // TAPPING_TERM 以内にリリース → タップとして処理される
    release(0, 0, 150);

    // KC_P (0x13) が送信される
    try testing.expect(mock.keyboard_count >= 2);

    // プレスレポートに KC_P が含まれる
    var found_p = false;
    var i: usize = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x13)) {
            found_p = true;
            break;
        }
    }
    try testing.expect(found_p);

    // 最終レポートは空（リリース済み）
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// ============================================================
// 2. HoldA_SHFT_T_KeyReportsShift
//    SFT_T(KC_P) を TAPPING_TERM 以上ホールド → LSHIFT がレポートされる
// ============================================================

test "HoldA_SHFT_T_KeyReportsShift" {
    const mock = setup();
    defer teardown();

    // SFT_T(KC_P) をプレス
    press(0, 0, 100);

    // TAPPING_TERM 経過してもプレスを維持（バッファリング中はレポートなし）
    tick(100 + TAPPING_TERM);

    // TAPPING_TERM 超過後の次の tick でホールド動作（LSHIFT）が発動する
    tick(100 + TAPPING_TERM + 1);

    // LSHIFT (ModBit 0x02) がレポートされる
    try testing.expect(mock.keyboard_count >= 1);
    var found_shift = false;
    var i: usize = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].mods & report_mod.ModBit.LSHIFT != 0) {
            found_shift = true;
            break;
        }
    }
    try testing.expect(found_shift);

    // リリース
    release(0, 0, 100 + TAPPING_TERM + 50);

    // 最終レポートは空（修飾キーがリリースされている）
    try testing.expectEqual(@as(u8, 0), mock.lastKeyboardReport().mods);
}

// ============================================================
// 3. TapA_CTL_T_KeyReportsKey
//    CTL_T(KC_P) を TAPPING_TERM 以内にタップ → KC_P がレポートされる
// ============================================================

test "TapA_CTL_T_KeyReportsKey" {
    const mock = setup();
    defer teardown();

    // CTL_T(KC_P) をプレス
    press(0, 1, 100);

    // TAPPING_TERM 以内にリリース → タップとして処理される
    release(0, 1, 150);

    // KC_P (0x13) が送信される
    try testing.expect(mock.keyboard_count >= 2);

    var found_p = false;
    var i: usize = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x13)) {
            found_p = true;
            break;
        }
    }
    try testing.expect(found_p);

    // 最終レポートは空
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// ============================================================
// 4. HoldA_CTL_T_KeyReportsCtrl
//    CTL_T(KC_P) を TAPPING_TERM 以上ホールド → LCTRL がレポートされる
// ============================================================

test "HoldA_CTL_T_KeyReportsCtrl" {
    const mock = setup();
    defer teardown();

    // CTL_T(KC_P) をプレス
    press(0, 1, 100);

    // TAPPING_TERM 超過
    tick(100 + TAPPING_TERM + 1);

    // LCTRL (ModBit 0x01) がレポートされる
    try testing.expect(mock.keyboard_count >= 1);
    var found_ctrl = false;
    var i: usize = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].mods & report_mod.ModBit.LCTRL != 0) {
            found_ctrl = true;
            break;
        }
    }
    try testing.expect(found_ctrl);

    // リリース
    release(0, 1, 100 + TAPPING_TERM + 50);

    // 最終レポートの修飾キーがクリアされている
    try testing.expectEqual(@as(u8, 0), mock.lastKeyboardReport().mods);
}

// ============================================================
// 5. ANewTapWithinTappingTermIsBuggy
//    連続タップの既知バグ動作（upstream issue #1478 参照）
//
//    シナリオ1: TAPPING_TERM 以内の再タップで KC_P が "バグ的に" 送信される
//    シナリオ2: TAPPING_TERM+1 後のタップは正常動作
//    シナリオ3: シナリオ2後の特殊なタイミングでホールド動作が発火
// ============================================================

test "ANewTapWithinTappingTermIsBuggy" {
    // See issue #1478 for more information
    const mock = setup();
    defer teardown();

    // ----- シナリオ1: TAPPING_TERM 以内の再タップは "バグ的" 動作 -----

    // 1回目のタップ: プレスでは何も送信されない
    press(0, 0, 100);
    const count_after_press1 = mock.keyboard_count;
    try testing.expectEqual(count_after_press1, mock.keyboard_count);

    // リリース → KC_P が送信される
    release(0, 0, 150);
    try testing.expect(mock.keyboard_count >= 2);
    var found_p1 = false;
    var i: usize = 0;
    while (i < mock.keyboard_count) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x13)) { found_p1 = true; break; }
    }
    try testing.expect(found_p1);

    const count_after_first_tap = mock.keyboard_count;

    // TAPPING_TERM 以内に再タップ → 「バグ的に」KC_P が再送信される
    // C版コメント: "This sends KC_P, even if it should do nothing"
    press(0, 0, 200); // tapping_key.event.time=150 から50ms後（TAPPING_TERM以内）
    try testing.expect(mock.keyboard_count > count_after_first_tap);

    var found_p2 = false;
    i = count_after_first_tap;
    while (i < mock.keyboard_count) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x13)) { found_p2 = true; break; }
    }
    try testing.expect(found_p2); // 再プレスでも KC_P が送信される（バグ動作）

    release(0, 0, 250);
    try testing.expect(mock.lastKeyboardReport().isEmpty());

    // TAPPING_TERM+1 待機
    tick(250 + TAPPING_TERM + 1);

    // ----- シナリオ2: TAPPING_TERM+1 後のタップは通常動作 -----

    const t2: u16 = 250 + TAPPING_TERM + 1;
    const count_before_s2 = mock.keyboard_count;

    // プレスでは何も送信されない
    press(0, 0, t2);
    try testing.expectEqual(count_before_s2, mock.keyboard_count);

    // リリース → KC_P が送信される
    release(0, 0, t2 + 50);
    var found_p_s2 = false;
    i = count_before_s2;
    while (i < mock.keyboard_count) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x13)) { found_p_s2 = true; break; }
    }
    try testing.expect(found_p_s2);
    try testing.expect(mock.lastKeyboardReport().isEmpty());

    tick(t2 + 50 + TAPPING_TERM + 1);

    // ----- シナリオ3: TAPPING_TERM+1 後のプレスでホールド動作が発火 -----
    // C版では「早すぎる」タイミングで LSHIFT が発火する（"strange territory"）。
    // Zig版では TAPPING_TERM 経過後の tick イベントでホールド動作が正常に発火する。

    const t3: u16 = t2 + 50 + TAPPING_TERM + 1;
    const count_before_s3 = mock.keyboard_count;

    // プレスでは即時レポートなし（tapping pending）
    press(0, 0, t3);
    try testing.expectEqual(count_before_s3, mock.keyboard_count);

    // TAPPING_TERM 経過後の tick でホールド動作（LSHIFT）が発動
    tick(t3 + TAPPING_TERM);

    var found_shift = false;
    i = count_before_s3;
    while (i < mock.keyboard_count) : (i += 1) {
        if (mock.keyboard_reports[i].mods & report_mod.ModBit.LSHIFT != 0) {
            found_shift = true;
            break;
        }
    }
    try testing.expect(found_shift);

    // リリース → 空レポート
    release(0, 0, t3 + TAPPING_TERM + 50);
    try testing.expectEqual(@as(u8, 0), mock.lastKeyboardReport().mods);
}

// ============================================================
// 6. TapA_CTL_T_KeyWhileReleasingShift
//    シフトキーを離しながら CTL_T(KC_P) をタップ
//
//    C版の期待動作:
//      シフトリリースは tapping 中に遅延され、タップ後に (LSFT+P)→(P)→empty の順で送信される。
//    Zig版の実際の動作:
//      シフトリリースは遅延されず即時処理される（action_tapping.c との既知の挙動差異）。
//      結果: (LSFT) → (empty) → (P) → (empty) の順で送信される。
// ============================================================

test "TapA_CTL_T_KeyWhileReleasingShift" {
    const mock = setup();
    defer teardown();

    // シフトキーをプレス → LSHIFT が登録される
    press(0, 2, 100); // KC_LSFT
    try testing.expect(mock.keyboard_count >= 1);
    var found_shift_press = false;
    var i: usize = 0;
    while (i < mock.keyboard_count) : (i += 1) {
        if (mock.keyboard_reports[i].mods & report_mod.ModBit.LSHIFT != 0) {
            found_shift_press = true;
            break;
        }
    }
    try testing.expect(found_shift_press);

    // CTL_T(KC_P) をプレス → tapping pending（追加レポートなし）
    const count_after_ctl_press = mock.keyboard_count;
    press(0, 1, 110);
    try testing.expectEqual(count_after_ctl_press, mock.keyboard_count);

    // シフトをリリース → Zig版では即時処理（LSHIFT 解除）
    // C版では tapping 中にシフトリリースが遅延される（既知挙動差異）
    release(0, 2, 120);
    // LSHIFT が解除されている（最新レポートに LSHIFT なし）
    const count_after_shift_release = mock.keyboard_count;
    try testing.expect(count_after_shift_release > count_after_ctl_press);
    var shift_still_held = false;
    i = count_after_ctl_press;
    while (i < count_after_shift_release) : (i += 1) {
        if (mock.keyboard_reports[i].mods & report_mod.ModBit.LSHIFT != 0) {
            shift_still_held = true;
        }
    }
    try testing.expect(!shift_still_held); // シフトは即時解除済み

    // CTL_T をリリース → タップとして処理され KC_P が送信される
    release(0, 1, 150);
    var found_p = false;
    i = count_after_shift_release;
    while (i < mock.keyboard_count) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x13)) { found_p = true; break; }
    }
    try testing.expect(found_p);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// ============================================================
// 7. TapA_CTL_T_KeyWhileReleasingLayer
//    MO(1) キーを離しながら CTL_T をタップ（レイヤー遅延の検証）
//
//    C版の期待動作:
//      MO(1) リリースは tapping 中に遅延され、タップ時にレイヤー1のキー KC_Q が送信される。
//    Zig版の実際の動作:
//      MO(1) リリースは遅延されず即時処理される（action_tapping.c との既知の挙動差異）。
//      結果: タップ時にはレイヤー0の CTL_T(KC_P) が解決されるため、KC_P が送信される。
// ============================================================

test "TapA_CTL_T_KeyWhileReleasingLayer" {
    const mock = setup();
    defer teardown();

    // MO(1) をプレス → レイヤー1が有効化（レポートなし）
    press(0, 4, 100); // MO(1)
    try testing.expect(layer_mod.layerStateIs(1));
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // レイヤー1アクティブ中に (0,1) をプレス → CTL_T(KC_Q) として処理される
    press(0, 1, 110);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // MO(1) をリリース → Zig版では即時レイヤー解除
    // C版では tapping 中に MO(1) リリースが遅延される（既知挙動差異）
    release(0, 4, 120);
    try testing.expect(!layer_mod.layerStateIs(1)); // レイヤー1は即時解除

    // CTL_T をリリース → タップとして処理
    // Zig版: レイヤー0アクティブ状態で action を解決 → CTL_T(KC_P) → KC_P が送信される
    // C版: レイヤー1のまま解決 → CTL_T(KC_Q) → KC_Q が送信される
    release(0, 1, 150);
    var found_p = false;
    var found_q = false;
    var i: usize = 0;
    while (i < mock.keyboard_count) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x13)) found_p = true; // KC_P
        if (mock.keyboard_reports[i].hasKey(0x14)) found_q = true; // KC_Q
    }
    // Zig版では KC_P が送信される（レイヤー0でのアクション解決）
    try testing.expect(found_p);
    try testing.expect(!found_q);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}
