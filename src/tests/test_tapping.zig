//! Tapping テスト - Mod-Tap キーのタップ/ホールド動作検証
//!
//! upstream参照: tests/basic/test_tapping.cpp
//!
//! テストケース:
//! 1. SFT_T(KC_P) タップ → KC_P がレポートされる
//! 2. SFT_T(KC_P) ホールド → LSHIFT がレポートされる
//! 3. CTL_T(KC_P) タップ → KC_P がレポートされる
//! 4. CTL_T(KC_P) ホールド → LCTRL がレポートされる
//! 5. 連続タップ（TAPPING_TERM以内の再タップ）

const std = @import("std");
const testing = std.testing;

// Core modules
const action = @import("../core/action.zig");
const action_code = @import("../core/action_code.zig");
const event_mod = @import("../core/event.zig");
const host_mod = @import("../core/host.zig");
const report_mod = @import("../core/report.zig");
const keycode = @import("../core/keycode.zig");
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
//
// 単純化のため、以下のマッピングを使用:
//   (0,0) = SFT_T(KC_P) → ACTION_MODS_TAP_KEY(Mod.LSFT, KC_P)
//   (0,1) = CTL_T(KC_P) → ACTION_MODS_TAP_KEY(Mod.LCTL, KC_P)
//   (0,2) = KC_LSFT     → ACTION_MODS_KEY(Mod.LSFT, 0)
//   (0,3) = KC_A         → ACTION_KEY(KC_A) (通常キー、interrupt テスト用)

fn testActionResolver(ev: KeyEvent) Action {
    if (ev.key.row == 0) {
        return switch (ev.key.col) {
            // SFT_T(KC_P): hold=LSHIFT, tap=KC_P
            0 => .{ .code = action_code.ACTION_MODS_TAP_KEY(Mod.LSFT, @truncate(KC.P)) },
            // CTL_T(KC_P): hold=LCTRL, tap=KC_P
            1 => .{ .code = action_code.ACTION_MODS_TAP_KEY(Mod.LCTL, @truncate(KC.P)) },
            // KC_LSFT: plain modifier key
            2 => .{ .code = action_code.ACTION_MODS_KEY(Mod.LSFT, 0) },
            // KC_A: plain key
            3 => .{ .code = action_code.ACTION_KEY(@truncate(KC.A)) },
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
// 5. ANewTapWithinTappingTermIsARegisteredTap
//    連続タップ — TAPPING_TERM 以内の再タップでもキーが登録される
// ============================================================

test "ANewTapWithinTappingTermIsARegisteredTap" {
    const mock = setup();
    defer teardown();

    // 1回目のタップ: SFT_T(KC_P)
    press(0, 0, 100);
    release(0, 0, 150);

    // KC_P が送信されたことを確認
    var first_p_count: usize = 0;
    var i: usize = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x13)) {
            first_p_count += 1;
        }
    }
    try testing.expect(first_p_count >= 1);

    // TAPPING_TERM 以内に2回目のタップ
    press(0, 0, 200);
    release(0, 0, 250);

    // 2回目のタップでも KC_P が送信される
    // （C版では「バグ」として記録されている — issue #1478）
    // 2回目のプレス以降で KC_P が出現することを確認
    var second_p_count: usize = 0;
    i = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x13)) {
            second_p_count += 1;
        }
    }
    // 1回目 + 2回目で2回以上 KC_P がレポートされている
    try testing.expect(second_p_count >= 2);

    // 最終的に空レポート
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}
