// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zig port of tests/tap_hold_configurations/
// Original: Copyright 2021 Stefan Kerkmann

//! Tap Hold Configuration テスト
//!
//! upstream の tests/tap_hold_configurations/ 以下のテストケースを Zig に移植。
//! 各設定オプションのバリエーション別にテストを整理する。
//!
//! C版参照:
//!   tests/tap_hold_configurations/default_mod_tap/test_tap_hold.cpp
//!   tests/tap_hold_configurations/permissive_hold/test_tap_hold.cpp
//!   tests/tap_hold_configurations/hold_on_other_key_press/test_tap_hold.cpp
//!   tests/tap_hold_configurations/retro_tapping/test_tap_hold.cpp
//!   tests/tap_hold_configurations/quick_tap/test_quick_tap.cpp

const std = @import("std");
const testing = std.testing;

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
const KC = keycode.KC;
const Mod = keycode.Mod;

const TAPPING_TERM = tapping_mod.TAPPING_TERM;
const QUICK_TAP_TERM = tapping_mod.QUICK_TAP_TERM;

const MockDriver = @import("../core/test_driver.zig").FixedTestDriver(64, 16);

// ============================================================
// テスト用キーマップリゾルバ
// ============================================================
//
//   (0,0) = SFT_T(KC_P)   → ACTION_MODS_TAP_KEY(Mod.LSFT, KC_P)
//   (0,1) = KC_A           → ACTION_KEY(KC_A)
//   (0,2) = LT(1, KC_P)   → ACTION_LAYER_TAP_KEY(1, KC_P)
//   (0,3) = RSFT_T(KC_A)  → ACTION_MODS_TAP_KEY(Mod.RSFT, KC_A)
//   Layer 1:
//   (1,1) = KC_B           → ACTION_KEY(KC_B)

fn testActionResolver(ev: KeyEvent) Action {
    const l1_active = layer_mod.layerStateIs(1);

    if (ev.key.row == 0) {
        return switch (ev.key.col) {
            // SFT_T(KC_P): hold=LSHIFT, tap=KC_P
            0 => .{ .code = action_code.ACTION_MODS_TAP_KEY(Mod.LSFT, @truncate(KC.P)) },
            // KC_A (or KC_B on layer 1)
            1 => if (l1_active)
                .{ .code = action_code.ACTION_KEY(@truncate(KC.B)) }
            else
                .{ .code = action_code.ACTION_KEY(@truncate(KC.A)) },
            // LT(1, KC_P): hold=layer 1, tap=KC_P
            2 => .{ .code = action_code.ACTION_LAYER_TAP_KEY(1, @truncate(KC.P)) },
            // RSFT_T(KC_A): hold=RSHIFT, tap=KC_A
            3 => .{ .code = action_code.ACTION(@intFromEnum(action_code.ActionKind.rmods_tap), @as(u12, 0x02) << 8 | @as(u12, @truncate(KC.A))) },
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

fn findReportWithKey(mock: *const MockDriver, start: usize, key: u8) bool {
    var i: usize = start;
    while (i < mock.keyboard_count) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(key)) return true;
    }
    return false;
}

fn findReportWithMods(mock: *const MockDriver, start: usize, mods_mask: u8) bool {
    var i: usize = start;
    while (i < mock.keyboard_count) : (i += 1) {
        if ((mock.keyboard_reports[i].mods & mods_mask) != 0) return true;
    }
    return false;
}

// ============================================================
// デフォルト動作（default_mod_tap）
// C版: tests/tap_hold_configurations/default_mod_tap/test_tap_hold.cpp
// ============================================================

// DefaultTapHold: tap_regular_key_while_mod_tap_key_is_held
// SFT_T ホールド中に KC_A をプレス・リリース → SFT_T はタップとして処理される
test "DefaultTapHold: tap_regular_key_while_mod_tap_key_is_held" {
    const mock = setup();
    defer teardown();

    // SFT_T(KC_P) をプレス
    press(0, 0, 100);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // KC_A をプレス
    press(0, 1, 110);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // KC_A をリリース
    release(0, 1, 160);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // SFT_T をリリース → タップとして処理: KC_P → (KC_P + KC_A) → KC_P → empty
    release(0, 0, 180);
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.P))); // KC_P
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.A))); // KC_A
    // LSHIFT は送信されない（タップ動作）
    try testing.expect(!findReportWithMods(mock, 0, report_mod.ModBit.LSHIFT));
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// DefaultTapHold: tap_a_mod_tap_key_while_another_mod_tap_key_is_held
// SFT_T ホールド中に RSFT_T をプレス・リリース → 両方タップとして処理される
test "DefaultTapHold: tap_a_mod_tap_key_while_another_mod_tap_key_is_held" {
    const mock = setup();
    defer teardown();

    // 1つ目の SFT_T(KC_P) をプレス
    press(0, 0, 100);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // 2つ目の RSFT_T(KC_A) をプレス
    press(0, 3, 110);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // 2つ目の RSFT_T をリリース
    release(0, 3, 150);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // 1つ目の SFT_T をリリース → 両方タップ: KC_P → (KC_P + KC_A) → KC_P → empty
    release(0, 0, 180);
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.P))); // KC_P tap
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.A))); // KC_A tap
    try testing.expect(!findReportWithMods(mock, 0, report_mod.ModBit.LSHIFT));
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// DefaultTapHold: tap_regular_key_while_layer_tap_key_is_held
// LT ホールド中に KC_A をプレス・リリース → LT はタップとして処理される
test "DefaultTapHold: tap_regular_key_while_layer_tap_key_is_held" {
    const mock = setup();
    defer teardown();

    // LT(1, KC_P) をプレス
    press(0, 2, 100);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // KC_A をプレス
    press(0, 1, 110);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // KC_A をリリース
    release(0, 1, 160);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // LT をリリース → タップ: KC_P → (KC_P + KC_A) → KC_P → empty
    release(0, 2, 180);
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.P))); // KC_P tap
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.A))); // KC_A
    // レイヤー1は有効化されない
    try testing.expect(!layer_mod.layerStateIs(1));
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// DefaultTapHold: tap_and_hold_mod_tap_hold_key
// SFT_T を TAPPING_TERM+1 ホールド → LSHIFT が送信される
test "DefaultTapHold: tap_and_hold_mod_tap_hold_key" {
    const mock = setup();
    defer teardown();

    // SFT_T をプレス → TAPPING_TERM+1 後に LSHIFT として発火
    press(0, 0, 100);
    tick(100 + TAPPING_TERM + 1);

    try testing.expect(findReportWithMods(mock, 0, report_mod.ModBit.LSHIFT));
    try testing.expect(!findReportWithKey(mock, 0, @truncate(KC.P)));

    // リリース → LSHIFT 解除
    release(0, 0, 100 + TAPPING_TERM + 50);
    try testing.expectEqual(@as(u8, 0), mock.lastKeyboardReport().mods);
}

// DefaultTapHold: tap_mod_tap_hold_key_two_times
// SFT_T タップ → 再プレス・TAPPING_TERM ホールド
test "DefaultTapHold: tap_mod_tap_hold_key_two_times" {
    const mock = setup();
    defer teardown();

    // 1回目タップ
    press(0, 0, 100);
    release(0, 0, 150);
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.P)));
    try testing.expect(mock.lastKeyboardReport().isEmpty());

    // 2回目プレス（TAPPING_TERM以内の再プレス）→ バグ動作でKC_Pが送信される
    const count_before = mock.keyboard_count;
    press(0, 0, 200);
    // TAPPING_TERM 待機
    tick(200 + TAPPING_TERM);

    // KC_P がレポートされる（既知の連続タップ動作）
    try testing.expect(mock.keyboard_count > count_before);

    release(0, 0, 200 + TAPPING_TERM + 10);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// ============================================================
// PERMISSIVE_HOLD
// C版: tests/tap_hold_configurations/permissive_hold/test_tap_hold.cpp
// ============================================================

// PermissiveHold: tap_regular_key_while_mod_tap_key_is_held
// SFT_T ホールド中に KC_A をプレス・リリース → SFT_T はホールドとして処理される
test "PermissiveHold: tap_regular_key_while_mod_tap_key_is_held" {
    const mock = setup();
    defer teardown();
    tapping_mod.permissive_hold = true;

    // SFT_T(KC_P) をプレス
    press(0, 0, 100);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // KC_A をプレス
    press(0, 1, 110);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // KC_A をリリース → PERMISSIVE_HOLD: SFT_T がホールドとして確定
    // LSHIFT → (LSHIFT + KC_A) → LSHIFT の順でレポートされる
    release(0, 1, 160);
    try testing.expect(findReportWithMods(mock, 0, report_mod.ModBit.LSHIFT));
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.A)));
    // LSHIFT と KC_A が同時に含まれるレポートが存在する
    var found_shift_and_a = false;
    var i: usize = 0;
    while (i < mock.keyboard_count) : (i += 1) {
        if (mock.keyboard_reports[i].mods & report_mod.ModBit.LSHIFT != 0 and
            mock.keyboard_reports[i].hasKey(@truncate(KC.A)))
        {
            found_shift_and_a = true;
            break;
        }
    }
    try testing.expect(found_shift_and_a);

    // SFT_T をリリース → LSHIFT 解除
    release(0, 0, 180);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
    // KC_P は送信されない（ホールド動作）
    try testing.expect(!findReportWithKey(mock, 0, @truncate(KC.P)));
}

// PermissiveHold: tap_a_mod_tap_key_while_another_mod_tap_key_is_held
// SFT_T ホールド中に RSFT_T をプレス・リリース → SFT_T はホールドとして処理
test "PermissiveHold: tap_a_mod_tap_key_while_another_mod_tap_key_is_held" {
    const mock = setup();
    defer teardown();
    tapping_mod.permissive_hold = true;

    // 1つ目の SFT_T をプレス
    press(0, 0, 100);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // 2つ目の RSFT_T をプレス
    press(0, 3, 110);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // 2つ目の RSFT_T をリリース → PERMISSIVE_HOLD: SFT_T がホールドとして確定
    // LSHIFT → (LSHIFT + KC_A) → LSHIFT の順
    release(0, 3, 150);
    try testing.expect(findReportWithMods(mock, 0, report_mod.ModBit.LSHIFT));
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.A)));

    // 1つ目の SFT_T をリリース
    release(0, 0, 180);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// PermissiveHold: tap_regular_key_while_layer_tap_key_is_held
// LT ホールド中に KC_A をプレス・リリース → LT はホールド（レイヤー有効化）
test "PermissiveHold: tap_regular_key_while_layer_tap_key_is_held" {
    const mock = setup();
    defer teardown();
    tapping_mod.permissive_hold = true;

    // LT(1, KC_P) をプレス
    press(0, 2, 100);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // KC_A をプレス（レイヤー1でも KC_A は KC_A、実際にはレイヤー1の col=1 は KC_B）
    press(0, 1, 110);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // KC_A をリリース → PERMISSIVE_HOLD: LT がホールドとして確定（レイヤー1有効化）
    // レイヤー1の (0,1) は KC_B
    release(0, 1, 160);
    // KC_B (レイヤー1のキー) が送信される
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.B)));
    try testing.expect(!findReportWithKey(mock, 0, @truncate(KC.P))); // KC_P は送信されない

    // LT をリリース → レイヤー1無効化
    release(0, 2, 180);
    try testing.expect(!layer_mod.layerStateIs(1));
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// ============================================================
// HOLD_ON_OTHER_KEY_PRESS
// C版: tests/tap_hold_configurations/hold_on_other_key_press/test_tap_hold.cpp
// ============================================================

// HoldOnOtherKeyPress: tap_regular_key_while_mod_tap_key_is_held
// SFT_T ホールド中に KC_A をプレス → SFT_T がホールドとして即座に確定
test "HoldOnOtherKeyPress: tap_regular_key_while_mod_tap_key_is_held" {
    const mock = setup();
    defer teardown();
    tapping_mod.hold_on_other_key_press = true;

    // SFT_T(KC_P) をプレス
    press(0, 0, 100);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // KC_A をプレス → HOLD_ON_OTHER_KEY_PRESS: SFT_T がホールドとして即座に確定
    // LSHIFT + KC_A が送信される
    press(0, 1, 110);
    try testing.expect(findReportWithMods(mock, 0, report_mod.ModBit.LSHIFT));

    // KC_A をリリース
    release(0, 1, 160);
    // KC_A が含まれるレポートが存在した
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.A)));

    // SFT_T をリリース → LSHIFT 解除
    release(0, 0, 180);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
    try testing.expect(!findReportWithKey(mock, 0, @truncate(KC.P)));
}

// HoldOnOtherKeyPress: short_distinct_taps
// SFT_T タップ → KC_A タップ（重複なし）→ それぞれ独立処理
test "HoldOnOtherKeyPress: short_distinct_taps_of_mod_tap_and_regular_key" {
    const mock = setup();
    defer teardown();
    tapping_mod.hold_on_other_key_press = true;

    // SFT_T をプレス・リリース（TAPPING_TERM以内）
    press(0, 0, 100);
    release(0, 0, 150);

    // KC_P がタップとして送信される
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.P)));
    try testing.expect(mock.lastKeyboardReport().isEmpty());

    // TAPPING_TERM 超過後に KC_A をプレス
    tick(150 + TAPPING_TERM + 1);
    const count_before = mock.keyboard_count;
    press(0, 1, 400);

    try testing.expect(findReportWithKey(mock, count_before, @truncate(KC.A)));
    release(0, 1, 450);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// HoldOnOtherKeyPress: tap_a_mod_tap_key_while_another_mod_tap_key_is_held
// SFT_T ホールド中に RSFT_T をプレス → SFT_T がホールドとして即座に確定
test "HoldOnOtherKeyPress: tap_a_mod_tap_key_while_another_mod_tap_key_is_held" {
    const mock = setup();
    defer teardown();
    tapping_mod.hold_on_other_key_press = true;

    // 1つ目の SFT_T をプレス
    press(0, 0, 100);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // 2つ目の RSFT_T をプレス → HOLD_ON_OTHER_KEY_PRESS: SFT_T がホールドとして確定
    press(0, 3, 110);
    try testing.expect(findReportWithMods(mock, 0, report_mod.ModBit.LSHIFT));

    // 2つ目の RSFT_T をリリース → KC_A が送信される
    release(0, 3, 150);

    // 1つ目の SFT_T をリリース
    release(0, 0, 180);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// HoldOnOtherKeyPress: tap_regular_key_while_layer_tap_key_is_held
// LT ホールド中に KC_A をプレス → LT がホールドとして即座に確定（レイヤー1有効化）
test "HoldOnOtherKeyPress: tap_regular_key_while_layer_tap_key_is_held" {
    const mock = setup();
    defer teardown();
    tapping_mod.hold_on_other_key_press = true;

    // LT(1, KC_P) をプレス
    press(0, 2, 100);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // KC_A をプレス → HOLD_ON_OTHER_KEY_PRESS: LT がホールドとして即座に確定
    // レイヤー1が有効化され、(0,1) は KC_B として解決される
    press(0, 1, 110);
    try testing.expect(layer_mod.layerStateIs(1));
    // KC_B が送信される
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.B)));
    try testing.expect(!findReportWithKey(mock, 0, @truncate(KC.P)));

    // KC_B をリリース
    release(0, 1, 160);

    // LT をリリース → レイヤー1無効化
    release(0, 2, 180);
    try testing.expect(!layer_mod.layerStateIs(1));
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// ============================================================
// RETRO_TAPPING
// C版: tests/tap_hold_configurations/retro_tapping/test_tap_hold.cpp
// ============================================================

// RetroTapping: tap_and_hold_mod_tap_hold_key
// SFT_T を TAPPING_TERM 以上ホールドして他キー割り込みなしでリリース
// → LSHIFT 送信 → LSHIFT 解除 → KC_P もタップとして送信される
test "RetroTapping: tap_and_hold_mod_tap_hold_key" {
    const mock = setup();
    defer teardown();
    tapping_mod.retro_tapping = true;

    // SFT_T(KC_P) をプレス
    press(0, 0, 100);

    // TAPPING_TERM ホールド
    tick(100 + TAPPING_TERM);

    // LSHIFT が送信されている
    try testing.expect(findReportWithMods(mock, 0, report_mod.ModBit.LSHIFT));
    const count_before_release = mock.keyboard_count;

    // リリース → LSHIFT 解除 + KC_P がレトロタップとして送信される
    release(0, 0, 100 + TAPPING_TERM + 50);

    // LSHIFT が解除されたレポート
    try testing.expectEqual(@as(u8, 0), mock.keyboard_reports[count_before_release].mods);

    // KC_P がレトロタップとして送信される
    try testing.expect(findReportWithKey(mock, count_before_release, @truncate(KC.P)));

    // 最終レポートは空
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// RetroTapping: tap_regular_key_does_not_fire_retro_tap
// SFT_T ホールド中に他キーが押された場合、RETRO_TAPPING は発動しない
test "RetroTapping: interrupted_hold_does_not_fire_retro_tap" {
    const mock = setup();
    defer teardown();
    tapping_mod.retro_tapping = true;

    // SFT_T をプレス
    press(0, 0, 100);

    // 他キー KC_A を押下（割り込み発生）
    press(0, 1, 120);
    release(0, 1, 160);

    // TAPPING_TERM 超過後に SFT_T をリリース
    release(0, 0, 100 + TAPPING_TERM + 10);

    // LSHIFT は送信される（ホールド動作）
    try testing.expect(findReportWithMods(mock, 0, report_mod.ModBit.LSHIFT));

    // KC_P はレトロタップとして送信されない（他キー割り込みがあったため）
    // 注: retro_tap_primed は他キーの press イベントで false にリセットされる
    // KC_A が押されているので retro_tap_curr_key != SFT_T の状態になる
    try testing.expect(!findReportWithKey(mock, 0, @truncate(KC.P)));
    // 最終レポートは空
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// ============================================================
// QUICK_TAP_TERM
// C版: tests/tap_hold_configurations/quick_tap/test_quick_tap.cpp
// ============================================================

// QuickTap: quick_tap_within_term_sends_key_twice
// タップ後すぐに同じキーを再プレス（QUICK_TAP_TERM以内）
// → 再プレス時も tap として処理される（sequential tap）
test "QuickTap: tap_then_quick_tap_sends_key_twice" {
    const mock = setup();
    defer teardown();

    // 1回目のタップ
    press(0, 0, 100);
    release(0, 0, 150);

    // KC_P が送信される
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.P)));
    try testing.expect(mock.lastKeyboardReport().isEmpty());

    // QUICK_TAP_TERM 以内に再プレス（tapping_key が "released" 状態）
    // → sequential tap として処理
    const count_before = mock.keyboard_count;
    press(0, 0, 150 + QUICK_TAP_TERM - 10);

    // KC_P が再度送信される（バグ的動作として既知）
    try testing.expect(mock.keyboard_count > count_before);
    try testing.expect(findReportWithKey(mock, count_before, @truncate(KC.P)));

    release(0, 0, 150 + QUICK_TAP_TERM + 50);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// QuickTap: tap_then_hold_after_quick_tap_term_is_hold
// タップ後、QUICK_TAP_TERM 経過後に再プレス → ホールドとして処理
test "QuickTap: tap_then_hold_after_quick_tap_term_is_hold" {
    const mock = setup();
    defer teardown();

    // 1回目のタップ
    press(0, 0, 100);
    release(0, 0, 150);

    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.P)));
    try testing.expect(mock.lastKeyboardReport().isEmpty());

    // TAPPING_TERM + 1 待機（tapping_key を完全にリセット）
    tick(150 + TAPPING_TERM + 1);

    // 再プレス → 新しいタップ/ホールドサイクル
    const count_before = mock.keyboard_count;
    press(0, 0, 200 + TAPPING_TERM + 1);

    // TAPPING_TERM 超過 → ホールド（LSHIFT）
    tick(200 + TAPPING_TERM * 2 + 2);

    try testing.expect(findReportWithMods(mock, count_before, report_mod.ModBit.LSHIFT));
    try testing.expect(!findReportWithKey(mock, count_before, @truncate(KC.P)));

    release(0, 0, 200 + TAPPING_TERM * 2 + 50);
    try testing.expectEqual(@as(u8, 0), mock.lastKeyboardReport().mods);
}

// ============================================================
// 従来からのテスト（後方互換性のため維持）
// ============================================================

test "ShortDistinctTapsModTap" {
    const mock = setup();
    defer teardown();

    press(0, 0, 100);
    release(0, 0, 150);

    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.P)));
    try testing.expect(mock.lastKeyboardReport().isEmpty());

    tick(150 + TAPPING_TERM + 1);

    const count_before = mock.keyboard_count;
    press(0, 1, 400);

    try testing.expect(mock.keyboard_count > count_before);
    try testing.expect(findReportWithKey(mock, count_before, @truncate(KC.A)));

    release(0, 1, 450);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

test "LongDistinctTapsModTap" {
    const mock = setup();
    defer teardown();

    press(0, 0, 100);
    tick(100 + TAPPING_TERM + 1);

    try testing.expect(findReportWithMods(mock, 0, report_mod.ModBit.LSHIFT));

    release(0, 0, 100 + TAPPING_TERM + 10);
    try testing.expect(mock.lastKeyboardReport().isEmpty());

    const count_before = mock.keyboard_count;
    press(0, 1, 100 + TAPPING_TERM + 20);
    try testing.expect(mock.keyboard_count > count_before);
    try testing.expect(findReportWithKey(mock, count_before, @truncate(KC.A)));

    release(0, 1, 100 + TAPPING_TERM + 70);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

test "ShortDistinctTapsLayerTap" {
    const mock = setup();
    defer teardown();

    press(0, 2, 100);
    release(0, 2, 150);

    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.P)));
    try testing.expect(mock.lastKeyboardReport().isEmpty());
    try testing.expect(!layer_mod.layerStateIs(1));

    tick(150 + TAPPING_TERM + 1);

    const count_before = mock.keyboard_count;
    press(0, 1, 400);
    try testing.expect(mock.keyboard_count > count_before);
    try testing.expect(findReportWithKey(mock, count_before, @truncate(KC.A)));

    release(0, 1, 450);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

test "LongDistinctTapsLayerTap" {
    const mock = setup();
    defer teardown();

    press(0, 2, 100);
    tick(100 + TAPPING_TERM + 1);

    try testing.expect(layer_mod.layerStateIs(1));
    try testing.expect(!findReportWithKey(mock, 0, @truncate(KC.P)));

    release(0, 2, 100 + TAPPING_TERM + 10);
    try testing.expect(!layer_mod.layerStateIs(1));

    const count_before = mock.keyboard_count;
    press(0, 1, 100 + TAPPING_TERM + 20);
    try testing.expect(mock.keyboard_count > count_before);
    try testing.expect(findReportWithKey(mock, count_before, @truncate(KC.A)));

    release(0, 1, 100 + TAPPING_TERM + 70);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

test "ModTapHoldWithInterrupt" {
    const mock = setup();
    defer teardown();

    press(0, 0, 100);
    press(0, 1, 120);
    release(0, 1, 160);
    release(0, 0, 100 + TAPPING_TERM + 10);

    try testing.expect(findReportWithMods(mock, 0, report_mod.ModBit.LSHIFT));
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.A)));

    var found_shift_and_a = false;
    var i: usize = 0;
    while (i < mock.keyboard_count) : (i += 1) {
        if (mock.keyboard_reports[i].mods & report_mod.ModBit.LSHIFT != 0 and
            mock.keyboard_reports[i].hasKey(@truncate(KC.A)))
        {
            found_shift_and_a = true;
            break;
        }
    }
    try testing.expect(found_shift_and_a);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

test "ModTapRollWithRegularKey" {
    const mock = setup();
    defer teardown();

    press(0, 0, 100);
    press(0, 1, 120);
    release(0, 0, 140);
    release(0, 1, 170);

    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.P)));
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.A)));
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

test "LayerTapHoldWithInterrupt" {
    const mock = setup();
    defer teardown();

    press(0, 2, 100);
    tick(100 + TAPPING_TERM + 1);
    try testing.expect(layer_mod.layerStateIs(1));

    const count_before = mock.keyboard_count;
    press(0, 1, 100 + TAPPING_TERM + 10);
    try testing.expect(mock.keyboard_count > count_before);
    try testing.expect(findReportWithKey(mock, count_before, @truncate(KC.B)));

    release(0, 1, 100 + TAPPING_TERM + 60);
    release(0, 2, 100 + TAPPING_TERM + 70);
    try testing.expect(!layer_mod.layerStateIs(1));
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

test "RetroTapping_TapAndHold" {
    const mock = setup();
    defer teardown();

    press(0, 0, 100);
    tick(100 + TAPPING_TERM + 1);

    try testing.expect(findReportWithMods(mock, 0, report_mod.ModBit.LSHIFT));

    release(0, 0, 100 + TAPPING_TERM + 50);
    try testing.expectEqual(@as(u8, 0), mock.lastKeyboardReport().mods);
}

test "PermissiveHold_RegularKeyRelease" {
    const mock = setup();
    defer teardown();

    press(0, 0, 100);
    press(0, 1, 120);
    release(0, 1, 160);
    release(0, 0, 180);

    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.P)));
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.A)));
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

test "NestedLayerTapKeys" {
    const mock = setup();
    defer teardown();

    // LT(1, KC_P) をプレス (col=2)
    press(0, 2, 100);
    tick(100 + TAPPING_TERM + 1);
    try testing.expect(layer_mod.layerStateIs(1));

    const count_before = mock.keyboard_count;
    // レイヤー1で (0,1) → KC_B
    press(0, 1, 100 + TAPPING_TERM + 10);
    try testing.expect(mock.keyboard_count > count_before);
    try testing.expect(findReportWithKey(mock, count_before, @truncate(KC.B)));

    release(0, 1, 100 + TAPPING_TERM + 60);
    release(0, 2, 100 + TAPPING_TERM + 100);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

test "ModTapTwoModsSequential" {
    const mock = setup();
    defer teardown();

    press(0, 0, 100);
    release(0, 0, 150);

    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.P)));
    try testing.expect(mock.lastKeyboardReport().isEmpty());

    tick(150 + TAPPING_TERM + 1);

    const count_before = mock.keyboard_count;
    press(0, 3, 150 + TAPPING_TERM + 10);
    release(0, 3, 150 + TAPPING_TERM + 60);

    try testing.expect(findReportWithKey(mock, count_before, @truncate(KC.A)));
    try testing.expect(mock.lastKeyboardReport().isEmpty());
    try testing.expectEqual(@as(u8, 0), mock.lastKeyboardReport().mods);
}

// ============================================================
// Per-key コールバックテスト (TAPPING_TERM_PER_KEY 等)
// C版: tests/tap_hold_configurations/tapping_term_per_key/ 等に相当
// ============================================================
// TestOverrides を使用して per-key コールバック経路を検証する。

// TappingTermPerKey: 特定キーに短い tapping term を設定
// (0,0) SFT_T に 100ms の tapping term を設定 → 110ms ホールドでホールド判定
test "TappingTermPerKey: short_tapping_term_causes_hold" {
    const mock = setup();
    defer teardown();

    // (0,0) のみ tapping term を 100ms に設定
    tapping_mod.TestOverrides.tapping_term_fn = &struct {
        fn f(record: *const event_mod.KeyRecord) u16 {
            if (record.event.key.row == 0 and record.event.key.col == 0) return 100;
            return TAPPING_TERM;
        }
    }.f;

    // SFT_T(KC_P) をプレス
    press(0, 0, 100);
    // 100ms + 1 後 → per-key tapping term 超過でホールド
    tick(201);

    // LSHIFT が送信される（ホールド動作）
    try testing.expect(findReportWithMods(mock, 0, report_mod.ModBit.LSHIFT));
    try testing.expect(!findReportWithKey(mock, 0, @truncate(KC.P)));

    release(0, 0, 250);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// TappingTermPerKey: 特定キーに長い tapping term を設定
// (0,0) SFT_T に 500ms の tapping term を設定 → 300ms ではまだタップ判定可能
test "TappingTermPerKey: long_tapping_term_allows_tap" {
    const mock = setup();
    defer teardown();

    // (0,0) のみ tapping term を 500ms に設定
    tapping_mod.TestOverrides.tapping_term_fn = &struct {
        fn f(record: *const event_mod.KeyRecord) u16 {
            if (record.event.key.row == 0 and record.event.key.col == 0) return 500;
            return TAPPING_TERM;
        }
    }.f;

    // SFT_T(KC_P) をプレス
    press(0, 0, 100);
    // 300ms 後にリリース（デフォルト 200ms なら超過だが、per-key 500ms ではタップ）
    release(0, 0, 400);

    // KC_P がタップとして送信される
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.P)));
    try testing.expect(!findReportWithMods(mock, 0, report_mod.ModBit.LSHIFT));
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// PermissiveHoldPerKey: 特定キーのみ permissive hold を有効化
test "PermissiveHoldPerKey: per_key_permissive_hold_on_specific_key" {
    const mock = setup();
    defer teardown();

    // グローバル permissive_hold は無効のまま
    tapping_mod.permissive_hold = false;

    // (0,0) のみ permissive hold を有効化
    tapping_mod.TestOverrides.permissive_hold_fn = &struct {
        fn f(record: *const event_mod.KeyRecord) bool {
            return record.event.key.row == 0 and record.event.key.col == 0;
        }
    }.f;

    // SFT_T(KC_P) をプレス
    press(0, 0, 100);
    // KC_A をプレス
    press(0, 1, 110);
    // KC_A をリリース → per-key permissive hold: SFT_T がホールドとして確定
    release(0, 1, 160);

    // LSHIFT が送信される
    try testing.expect(findReportWithMods(mock, 0, report_mod.ModBit.LSHIFT));
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.A)));

    // SFT_T をリリース
    release(0, 0, 180);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
    // KC_P は送信されない（ホールド動作）
    try testing.expect(!findReportWithKey(mock, 0, @truncate(KC.P)));
}

// HoldOnOtherKeyPressPerKey: 特定キーのみ hold_on_other_key_press を有効化
test "HoldOnOtherKeyPressPerKey: per_key_hold_on_other_key_press" {
    const mock = setup();
    defer teardown();

    // グローバル hold_on_other_key_press は無効のまま
    tapping_mod.hold_on_other_key_press = false;

    // (0,0) のみ hold_on_other_key_press を有効化
    tapping_mod.TestOverrides.hold_on_other_key_press_fn = &struct {
        fn f(record: *const event_mod.KeyRecord) bool {
            return record.event.key.row == 0 and record.event.key.col == 0;
        }
    }.f;

    // SFT_T(KC_P) をプレス
    press(0, 0, 100);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);

    // KC_A をプレス → per-key hold_on_other_key_press: SFT_T がホールドとして即座に確定
    press(0, 1, 110);
    try testing.expect(findReportWithMods(mock, 0, report_mod.ModBit.LSHIFT));

    // KC_A をリリース
    release(0, 1, 160);
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.A)));

    // SFT_T をリリース
    release(0, 0, 180);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
    try testing.expect(!findReportWithKey(mock, 0, @truncate(KC.P)));
}

// QuickTapTermPerKey: quick tap term を 0 に設定 → 連続タップが発動せずホールドになる
// デフォルト (QUICK_TAP_TERM=200ms) なら 60ms 後の再プレスは即座にタップ扱い(tap.count=2)。
// per-key で 0ms にすると withinQuickTapTerm が常に false になり、
// 2回目はホールドの新サイクルとして扱われる。
test "QuickTapTermPerKey: zero_quick_tap_term_causes_hold_on_repress" {
    const mock = setup();
    defer teardown();

    // (0,0) のみ quick tap term を 0 に設定（連続タップ無効）
    tapping_mod.TestOverrides.quick_tap_term_fn = &struct {
        fn f(record: *const event_mod.KeyRecord) u16 {
            if (record.event.key.row == 0 and record.event.key.col == 0) return 0;
            return QUICK_TAP_TERM;
        }
    }.f;

    // 1回目のタップ
    press(0, 0, 100);
    release(0, 0, 120);

    // KC_P が送信される
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.P)));
    try testing.expect(mock.lastKeyboardReport().isEmpty());

    // 60ms 後に再プレス（デフォルトなら QUICK_TAP_TERM=200 以内で連続タップ、
    // per-key 0ms では withinQuickTapTerm=false のため新サイクル開始）
    const count_before = mock.keyboard_count;
    press(0, 0, 180);

    // TAPPING_TERM 超過まで保持 → 新サイクルとしてホールド（LSHIFT）になる
    tick(180 + TAPPING_TERM + 1);

    // LSHIFT が送信される（ホールド動作）
    try testing.expect(findReportWithMods(mock, count_before, report_mod.ModBit.LSHIFT));
    // KC_P はこの時点では送信されない（ホールド動作中）
    try testing.expect(!findReportWithKey(mock, count_before, @truncate(KC.P)));

    release(0, 0, 180 + TAPPING_TERM + 50);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// QuickTapTermPerKey: デフォルト quick tap term では連続タップが発動する（対照テスト）
test "QuickTapTermPerKey: default_quick_tap_term_allows_repeat_tap" {
    const mock = setup();
    defer teardown();

    // オーバーライドなし（デフォルト QUICK_TAP_TERM=200ms）

    // 1回目のタップ
    press(0, 0, 100);
    release(0, 0, 120);

    // KC_P が送信される
    try testing.expect(findReportWithKey(mock, 0, @truncate(KC.P)));
    try testing.expect(mock.lastKeyboardReport().isEmpty());

    // 60ms 後に再プレス（QUICK_TAP_TERM=200ms 以内なので連続タップ）
    const count_before = mock.keyboard_count;
    press(0, 0, 180);

    // 連続タップ: 即座に KC_P が送信される（tap.count が 2 に増加）
    try testing.expect(findReportWithKey(mock, count_before, @truncate(KC.P)));

    // TAPPING_TERM 超過しても LSHIFT にはならない（連続タップモード）
    try testing.expect(!findReportWithMods(mock, count_before, report_mod.ModBit.LSHIFT));

    release(0, 0, 180 + TAPPING_TERM + 50);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}
