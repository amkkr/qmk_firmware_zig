// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zig port of tests/basic/test_tapping.cpp
// Original: Copyright 2017 Fred Sundvik

//! Tapping テスト - Mod-Tap / Layer-Tap キーのタップ/ホールド動作検証
//!
//! upstream参照: tests/basic/test_tapping.cpp
//!
//! C版テスト対応（1-2, 5: C版と同一、3-4: Zig独自追加、6-7: 挙動差異あり）:
//! 1. TapA_SHFT_T_KeyReportsKey      — SFT_T(KC_P) タップ → KC_P              [C版対応]
//! 2. HoldA_SHFT_T_KeyReportsShift   — SFT_T(KC_P) ホールド → LSHIFT          [C版対応]
//! 3. TapA_CTL_T_KeyReportsKey       — CTL_T(KC_P) タップ → KC_P              [Zig独自]
//! 4. HoldA_CTL_T_KeyReportsCtrl     — CTL_T(KC_P) ホールド → LCTRL           [Zig独自]
//! 5. ANewTapWithinTappingTermIsBuggy — 連続タップの既知バグ動作（issue #1478）[C版対応]
//! 6. TapA_CTL_T_KeyWhileReleasingShift — シフト離し中のCTL_Tタップ           [挙動差異]
//! 7. TapA_CTL_T_KeyWhileReleasingLayer — レイヤー離し中のCTL_Tタップ         [挙動差異]
//!
//! 追加テスト（C版にない拡張ケース）:
//! 8.  TAPPING_TERM 境界値: ちょうど TAPPING_TERM でリリース → ホールド
//! 9.  TAPPING_TERM 境界値: TAPPING_TERM-1 でリリース → タップ
//! 10. TAPPING_TERM+1 境界値: TAPPING_TERM+1 の tick → ホールド
//! 11. LT タップ: LT(1, KC_B) を TAPPING_TERM 以内にタップ → KC_B
//! 12. LT ホールド: LT(1, KC_B) を TAPPING_TERM 以上ホールド → レイヤー1有効化
//! 13. Mod-Tap 中の通常キー割り込み: SFT_T ホールド中に KC_A → LSHIFT+A
//! 14. 異なる Mod-Tap の連続タップ: SFT_T タップ → CTL_T タップ

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
//   (0,5) = LT(1, KC_B) → ACTION_LAYER_TAP_KEY(1, KC_B) (LT テスト用)

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
            // LT(1, KC_B): hold=layer 1, tap=KC_B
            5 => .{ .code = action_code.ACTION_LAYER_TAP_KEY(1, @truncate(KC.B)) },
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
    action.reset();
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
    const count_before_press1 = mock.keyboard_count;
    press(0, 0, 100);
    try testing.expectEqual(count_before_press1, mock.keyboard_count);

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

// ============================================================
// 8. TAPPING_TERM 境界値テスト（ちょうど TAPPING_TERM でリリース → ホールド扱い）
//    withinTappingTerm は「< TAPPING_TERM」（厳密に未満）のため、
//    ちょうど TAPPING_TERM 経過時のリリースはホールドとして処理される。
//    TAPPING_TERM-1 でのリリースはタップとして処理される。
// ============================================================

test "TappingTermBoundary_ExactTerm_IsHold" {
    const mock = setup();
    defer teardown();

    // SFT_T(KC_P) をプレス (time=100)
    press(0, 0, 100);

    // ちょうど TAPPING_TERM でリリース (time=100+200=300)
    // withinTappingTerm: (300 - 100) < 200 → false → ホールド判定
    release(0, 0, 100 + TAPPING_TERM);

    // ホールドとして処理されるため LSHIFT が送信される
    var found_shift = false;
    var i: usize = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].mods & report_mod.ModBit.LSHIFT != 0) {
            found_shift = true;
            break;
        }
    }
    try testing.expect(found_shift);

    // 最終レポートは空（リリース済み）
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// ============================================================
// 9. TAPPING_TERM 境界値テスト（TAPPING_TERM-1 でリリース → タップ扱い）
//    withinTappingTerm は「< TAPPING_TERM」（厳密に未満）のため、
//    TAPPING_TERM-1 でのリリースはタップとして処理される。
// ============================================================

test "TappingTermBoundary_TermMinusOne_IsTap" {
    const mock = setup();
    defer teardown();

    // SFT_T(KC_P) をプレス (time=100)
    press(0, 0, 100);

    // TAPPING_TERM - 1 でリリース (time=100+199=299)
    // withinTappingTerm: (299 - 100) < 200 → 199 < 200 → true → タップ判定
    release(0, 0, 100 + TAPPING_TERM - 1);

    // タップとして処理され KC_P (0x13) が送信される
    try testing.expect(mock.keyboard_count >= 2);
    var found_p = false;
    var i: usize = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x13)) { found_p = true; break; }
    }
    try testing.expect(found_p);

    // 最終レポートは空
    try testing.expect(mock.lastKeyboardReport().isEmpty());

    // LSHIFT は送信されていない
    var found_shift = false;
    i = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].mods & report_mod.ModBit.LSHIFT != 0) {
            found_shift = true;
            break;
        }
    }
    try testing.expect(!found_shift);
}

// ============================================================
// 10. TAPPING_TERM+1 境界値テスト（ホールド側）
//    SFT_T(KC_P) を TAPPING_TERM+1 まで保持 → ホールドとして処理される
// ============================================================

test "TappingTermBoundary_TermPlusOne_IsHold" {
    const mock = setup();
    defer teardown();

    // SFT_T(KC_P) をプレス (time=100)
    press(0, 0, 100);

    // TAPPING_TERM+1 の tick でホールド判定
    tick(100 + TAPPING_TERM + 1);

    // LSHIFT がレポートされる
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

    // KC_P は送信されていない
    var found_p = false;
    i = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x13)) { found_p = true; break; }
    }
    try testing.expect(!found_p);

    // リリース
    release(0, 0, 100 + TAPPING_TERM + 50);
    try testing.expectEqual(@as(u8, 0), mock.lastKeyboardReport().mods);
}

// ============================================================
// 11. LT タップ: LT(1, KC_B) を TAPPING_TERM 以内にタップ → KC_B
// ============================================================

test "LT_Tap_ReportsKey" {
    const mock = setup();
    defer teardown();

    // LT(1, KC_B) をプレス
    press(0, 5, 100);

    // TAPPING_TERM 以内にリリース → タップとして処理される
    release(0, 5, 150);

    // KC_B (0x05) が送信される
    try testing.expect(mock.keyboard_count >= 2);
    var found_b = false;
    var i: usize = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x05)) { found_b = true; break; }
    }
    try testing.expect(found_b);

    // レイヤー1は有効化されていない
    try testing.expect(!layer_mod.layerStateIs(1));

    // 最終レポートは空
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// ============================================================
// 12. LT ホールド: LT(1, KC_B) を TAPPING_TERM 以上ホールド → レイヤー1有効化
// ============================================================

test "LT_Hold_ActivatesLayer" {
    const mock = setup();
    defer teardown();

    // LT(1, KC_B) をプレス
    press(0, 5, 100);

    // TAPPING_TERM 超過
    tick(100 + TAPPING_TERM + 1);

    // レイヤー1が有効化されている
    try testing.expect(layer_mod.layerStateIs(1));

    // KC_B は送信されていない（ホールド動作のためキーは送信されない）
    var found_b = false;
    var i: usize = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x05)) { found_b = true; break; }
    }
    try testing.expect(!found_b);

    // リリース → レイヤー1が無効化
    release(0, 5, 100 + TAPPING_TERM + 50);
    try testing.expect(!layer_mod.layerStateIs(1));
}

// ============================================================
// 13. Mod-Tap 中の通常キー割り込み（プレス+リリース両方バッファ内）
//    SFT_T(KC_P) 押下中に通常キー KC_A をプレス・リリース → バッファに蓄積。
//    TAPPING_TERM 超過後の次のキーイベントでホールド判定 → LSHIFT として処理、
//    バッファ内の KC_A プレス/リリースも順次処理される。
// ============================================================

test "ModTap_Hold_WithNormalKeyInterrupt" {
    const mock = setup();
    defer teardown();

    // SFT_T(KC_P) をプレス
    press(0, 0, 100);

    // TAPPING_TERM 以内に通常キー KC_A をプレス・リリース
    // → 両方バッファに入り、tapping_key.tap.interrupted = true がセットされる
    press(0, 3, 120);
    release(0, 3, 160);

    // TAPPING_TERM 超過後に SFT_T をリリース
    // → SFT_T がホールドとして処理（LSHIFT 登録）、バッファ内の KC_A 操作も処理される
    release(0, 0, 100 + TAPPING_TERM + 10);

    // LSHIFT がレポートされる（SFT_T のホールド動作）
    var found_shift = false;
    var i: usize = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].mods & report_mod.ModBit.LSHIFT != 0) {
            found_shift = true;
            break;
        }
    }
    try testing.expect(found_shift);

    // KC_A (0x04) がレポートされている
    var found_a = false;
    i = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x04)) { found_a = true; break; }
    }
    try testing.expect(found_a);

    // LSHIFT と KC_A が同一レポートに同時に含まれることを確認
    // （別々のレポートに分かれていないことを保証する）
    var found_shift_and_a = false;
    i = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].mods & report_mod.ModBit.LSHIFT != 0 and
            mock.keyboard_reports[i].hasKey(0x04))
        {
            found_shift_and_a = true;
            break;
        }
    }
    try testing.expect(found_shift_and_a);

    // 最終レポートは空
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// ============================================================
// 14. 異なる Mod-Tap キーの連続タップ
//    SFT_T(KC_P) タップ → CTL_T(KC_P) タップ → それぞれ KC_P が送信される
// ============================================================

test "ConsecutiveDifferentModTaps" {
    const mock = setup();
    defer teardown();

    // 1回目: SFT_T(KC_P) をタップ
    press(0, 0, 100);
    release(0, 0, 150);

    // KC_P が送信される
    var found_p1 = false;
    var i: usize = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x13)) { found_p1 = true; break; }
    }
    try testing.expect(found_p1);
    try testing.expect(mock.lastKeyboardReport().isEmpty());

    // TAPPING_TERM 以上待機して状態をリセット
    tick(150 + TAPPING_TERM + 1);

    const count_before_ctl = mock.keyboard_count;

    // 2回目: CTL_T(KC_P) をタップ
    press(0, 1, 150 + TAPPING_TERM + 10);
    release(0, 1, 150 + TAPPING_TERM + 60);

    // 2回目も KC_P が送信される
    var found_p2 = false;
    i = count_before_ctl;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x13)) { found_p2 = true; break; }
    }
    try testing.expect(found_p2);
    try testing.expect(mock.lastKeyboardReport().isEmpty());

    // LSHIFT, LCTRL ともに最終レポートには含まれない
    try testing.expectEqual(@as(u8, 0), mock.lastKeyboardReport().mods);
}
