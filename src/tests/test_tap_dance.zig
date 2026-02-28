// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! Tap Dance テスト - C版 tests/tap_dance/test_examples.cpp の移植
//!
//! C版テストケースを Zig の tap_dance API で論理的に等価に再現する。
//! C版はコールバックベースの高度な Tap Dance 機能（FN, FN_ADVANCED, TAP_HOLD,
//! WITH_RELEASE）を使用しているが、Zig版は TapDanceAction の4キーコード
//! （on_tap, on_double_tap, on_hold, on_tap_hold）で定義する設計のため、
//! C版の ACTION_TAP_DANCE_DOUBLE と QuadFunction に対応するテストを移植する。
//!
//! C版テスト対応:
//! 1. DoubleTap           — シングルタップ→ESC、ダブルタップ→CAPS
//! 2. DoubleTapInterrupted — 割り込みによるダンス確定後、次がシングルタップとして動作
//! 3. QuadFunction        — single tap/hold/double tap/double hold の4パターン

const std = @import("std");
const testing = std.testing;

const tap_dance = @import("../core/tap_dance.zig");
const host = @import("../core/host.zig");
const report_mod = @import("../core/report.zig");
const keycode_mod = @import("../core/keycode.zig");
const timer = @import("../hal/timer.zig");

const KC = keycode_mod.KC;
const Keycode = keycode_mod.Keycode;
const TAPPING_TERM = tap_dance.TAPPING_TERM;
const FixedTestDriver = @import("../core/test_driver.zig").FixedTestDriver;
const TestDriver = FixedTestDriver(64, 16);

fn setupTest() *TestDriver {
    const S = struct {
        var driver: TestDriver = .{};
    };
    S.driver = .{};
    tap_dance.reset();
    host.hostReset();
    timer.mockReset();
    host.setDriver(host.HostDriver.from(&S.driver));
    return &S.driver;
}

fn teardownTest() void {
    host.clearDriver();
    tap_dance.setActions(&.{});
    tap_dance.reset();
}

// ============================================================
// C版 DoubleTap (TD_ESC_CAPS) の移植
// ACTION_TAP_DANCE_DOUBLE(KC_ESC, KC_CAPS) 相当
// ============================================================

// C版 DoubleTap テストの移植（シングルタップ部分）
// タップして TAPPING_TERM 経過 → ESC が確定
test "DoubleTap_single_tap" {
    const driver = setupTest();
    defer teardownTest();

    // TD_ESC_CAPS: on_tap=ESC, on_double_tap=CAPS
    const actions = [_]tap_dance.TapDanceAction{
        .{ .on_tap = KC.ESCAPE, .on_double_tap = KC.CAPS_LOCK },
    };
    tap_dance.setActions(&actions);

    const td_kc = keycode_mod.TD(0);

    // Press TD key
    _ = tap_dance.process(td_kc, true);
    timer.mockAdvance(1);

    // Release TD key
    _ = tap_dance.process(td_kc, false);

    // TAPPING_TERM 経過前はレポートなし
    try testing.expectEqual(@as(usize, 0), driver.keyboard_count);

    // TAPPING_TERM 経過 → ESC 確定
    timer.mockAdvance(TAPPING_TERM);
    tap_dance.task();

    // ESC が送信され、その後空レポート
    try testing.expect(driver.keyboard_count >= 2);
    try testing.expect(driver.keyboard_reports[0].hasKey(KC.ESCAPE));
    try testing.expect(driver.lastKeyboardReport().isEmpty());
}

// C版 DoubleTap テストの移植（ダブルタップ部分）
// 2回タップすると CAPS が確定
test "DoubleTap_double_tap" {
    const driver = setupTest();
    defer teardownTest();

    const actions = [_]tap_dance.TapDanceAction{
        .{ .on_tap = KC.ESCAPE, .on_double_tap = KC.CAPS_LOCK },
    };
    tap_dance.setActions(&actions);

    const td_kc = keycode_mod.TD(0);

    // 1st tap
    _ = tap_dance.process(td_kc, true);
    timer.mockAdvance(1);
    _ = tap_dance.process(td_kc, false);

    // 2nd tap (within TAPPING_TERM)
    timer.mockAdvance(50);
    _ = tap_dance.process(td_kc, true);
    timer.mockAdvance(1);
    _ = tap_dance.process(td_kc, false);

    // TAPPING_TERM 経過前はレポートなし
    try testing.expectEqual(@as(usize, 0), driver.keyboard_count);

    // TAPPING_TERM 経過 → CAPS 確定
    timer.mockAdvance(TAPPING_TERM);
    tap_dance.task();

    // CAPS_LOCK が送信される
    try testing.expect(driver.keyboard_count >= 1);
    var found_caps = false;
    for (0..@min(driver.keyboard_count, 64)) |i| {
        if (driver.keyboard_reports[i].hasKey(KC.CAPS_LOCK)) {
            found_caps = true;
            break;
        }
    }
    try testing.expect(found_caps);
    // 最後は空レポート
    try testing.expect(driver.lastKeyboardReport().isEmpty());
}

// ============================================================
// C版 DoubleTapInterrupted の移植
// ============================================================

// 割り込みによりダンスが即座に確定され、次のタップはシングルタップとして動作
test "DoubleTapInterrupted" {
    const driver = setupTest();
    defer teardownTest();

    const actions = [_]tap_dance.TapDanceAction{
        .{ .on_tap = KC.ESCAPE, .on_double_tap = KC.CAPS_LOCK },
    };
    tap_dance.setActions(&actions);

    const td_kc = keycode_mod.TD(0);

    // 1st tap
    _ = tap_dance.process(td_kc, true);
    timer.mockAdvance(1);
    _ = tap_dance.process(td_kc, false);

    // 割り込み: 別キー押下で TD が即座にシングルタップとして確定
    timer.mockAdvance(5);
    _ = tap_dance.preprocess(KC.A, true);

    // ESC が即座に確定されている
    try testing.expect(driver.keyboard_count >= 1);
    var found_esc = false;
    for (0..@min(driver.keyboard_count, 64)) |i| {
        if (driver.keyboard_reports[i].hasKey(KC.ESCAPE)) {
            found_esc = true;
            break;
        }
    }
    try testing.expect(found_esc);

    // ドライバをリセットして次のテストの前にクリーン状態に
    driver.reset();

    // 割り込み後の2回目のタップはシングルタップとして動作
    timer.mockAdvance(50);
    _ = tap_dance.process(td_kc, true);
    timer.mockAdvance(1);
    _ = tap_dance.process(td_kc, false);

    // TAPPING_TERM 経過 → ESC 確定（ダブルタップではない）
    timer.mockAdvance(TAPPING_TERM);
    tap_dance.task();

    try testing.expect(driver.keyboard_count >= 1);
    var found_esc2 = false;
    var found_caps_lock = false;
    for (0..@min(driver.keyboard_count, 64)) |i| {
        if (driver.keyboard_reports[i].hasKey(KC.ESCAPE)) {
            found_esc2 = true;
        }
        if (driver.keyboard_reports[i].hasKey(KC.CAPS_LOCK)) {
            found_caps_lock = true;
        }
    }
    // 割り込み後のタップはシングルタップ → ESC が送信される
    try testing.expect(found_esc2);
    // ダブルタップとして確定されていない → CAPS_LOCK は送信されない
    try testing.expect(!found_caps_lock);
}

// ============================================================
// C版 QuadFunction (X_CTL) の移植
// single tap=X, single hold=LCTL, double tap=ESC, double hold=LALT
// ============================================================

// Single tap → KC_X
test "QuadFunction_single_tap" {
    const driver = setupTest();
    defer teardownTest();

    const actions = [_]tap_dance.TapDanceAction{
        .{ .on_tap = KC.X, .on_hold = KC.LEFT_CTRL, .on_double_tap = KC.ESCAPE, .on_tap_hold = KC.LEFT_ALT },
    };
    tap_dance.setActions(&actions);

    const td_kc = keycode_mod.TD(0);

    // Single tap
    _ = tap_dance.process(td_kc, true);
    timer.mockAdvance(1);
    _ = tap_dance.process(td_kc, false);

    // TAPPING_TERM 経過
    timer.mockAdvance(TAPPING_TERM);
    tap_dance.task();

    // KC_X が送信される
    try testing.expect(driver.keyboard_count >= 1);
    var found_x = false;
    for (0..@min(driver.keyboard_count, 64)) |i| {
        if (driver.keyboard_reports[i].hasKey(KC.X)) {
            found_x = true;
            break;
        }
    }
    try testing.expect(found_x);
    try testing.expect(driver.lastKeyboardReport().isEmpty());
}

// Single hold → KC_LCTL
test "QuadFunction_single_hold" {
    const driver = setupTest();
    defer teardownTest();

    const actions = [_]tap_dance.TapDanceAction{
        .{ .on_tap = KC.X, .on_hold = KC.LEFT_CTRL, .on_double_tap = KC.ESCAPE, .on_tap_hold = KC.LEFT_ALT },
    };
    tap_dance.setActions(&actions);

    const td_kc = keycode_mod.TD(0);

    // Press and hold
    _ = tap_dance.process(td_kc, true);

    // TAPPING_TERM 経過 → ホールドとして確定
    timer.mockAdvance(TAPPING_TERM + 1);
    tap_dance.task();

    // LCTL が登録される
    try testing.expect(driver.keyboard_count >= 1);
    var found_ctrl = false;
    for (0..@min(driver.keyboard_count, 64)) |i| {
        if (driver.keyboard_reports[i].mods & report_mod.ModBit.LCTRL != 0) {
            found_ctrl = true;
            break;
        }
    }
    try testing.expect(found_ctrl);

    // Release → LCTL 解除
    _ = tap_dance.process(td_kc, false);
    try testing.expect(driver.lastKeyboardReport().isEmpty());
}

// Double tap → KC_ESC
test "QuadFunction_double_tap" {
    const driver = setupTest();
    defer teardownTest();

    const actions = [_]tap_dance.TapDanceAction{
        .{ .on_tap = KC.X, .on_hold = KC.LEFT_CTRL, .on_double_tap = KC.ESCAPE, .on_tap_hold = KC.LEFT_ALT },
    };
    tap_dance.setActions(&actions);

    const td_kc = keycode_mod.TD(0);

    // 1st tap
    _ = tap_dance.process(td_kc, true);
    timer.mockAdvance(1);
    _ = tap_dance.process(td_kc, false);

    // 2nd tap
    timer.mockAdvance(50);
    _ = tap_dance.process(td_kc, true);
    timer.mockAdvance(1);
    _ = tap_dance.process(td_kc, false);

    // TAPPING_TERM 経過
    timer.mockAdvance(TAPPING_TERM);
    tap_dance.task();

    // ESC が送信される
    try testing.expect(driver.keyboard_count >= 1);
    var found_esc = false;
    for (0..@min(driver.keyboard_count, 64)) |i| {
        if (driver.keyboard_reports[i].hasKey(KC.ESCAPE)) {
            found_esc = true;
            break;
        }
    }
    try testing.expect(found_esc);
    try testing.expect(driver.lastKeyboardReport().isEmpty());
}

// Double tap and hold → KC_LALT
test "QuadFunction_double_hold" {
    const driver = setupTest();
    defer teardownTest();

    const actions = [_]tap_dance.TapDanceAction{
        .{ .on_tap = KC.X, .on_hold = KC.LEFT_CTRL, .on_double_tap = KC.ESCAPE, .on_tap_hold = KC.LEFT_ALT },
    };
    tap_dance.setActions(&actions);

    const td_kc = keycode_mod.TD(0);

    // 1st tap
    _ = tap_dance.process(td_kc, true);
    timer.mockAdvance(1);
    _ = tap_dance.process(td_kc, false);

    // 2nd press (hold)
    timer.mockAdvance(50);
    _ = tap_dance.process(td_kc, true);

    // TAPPING_TERM 経過 → ダブルホールドとして確定
    timer.mockAdvance(TAPPING_TERM + 1);
    tap_dance.task();

    // LALT が登録される
    try testing.expect(driver.keyboard_count >= 1);
    var found_alt = false;
    for (0..@min(driver.keyboard_count, 64)) |i| {
        if (driver.keyboard_reports[i].mods & report_mod.ModBit.LALT != 0) {
            found_alt = true;
            break;
        }
    }
    try testing.expect(found_alt);

    // Release → LALT 解除
    _ = tap_dance.process(td_kc, false);
    try testing.expect(driver.lastKeyboardReport().isEmpty());
}

// ============================================================
// C版 QuadFunction "Double single tap" の移植
// tap_key(key_quad); tap_key(key_quad); regular_key.press() で
// 2回の独立シングルタップ（各々 KC_X）が送信される
// ============================================================

test "QuadFunction_double_single_tap" {
    const driver = setupTest();
    defer teardownTest();

    const actions = [_]tap_dance.TapDanceAction{
        .{ .on_tap = KC.X, .on_hold = KC.LEFT_CTRL, .on_double_tap = KC.ESCAPE, .on_tap_hold = KC.LEFT_ALT },
    };
    tap_dance.setActions(&actions);

    const td_kc = keycode_mod.TD(0);

    // 1st tap
    _ = tap_dance.process(td_kc, true);
    timer.mockAdvance(1);
    _ = tap_dance.process(td_kc, false);

    // 2nd tap
    timer.mockAdvance(50);
    _ = tap_dance.process(td_kc, true);
    timer.mockAdvance(1);
    _ = tap_dance.process(td_kc, false);

    // 別キーで割り込み → ダブルシングルタップとして確定
    timer.mockAdvance(5);
    _ = tap_dance.preprocess(KC.A, true);

    // C版期待値:
    //   EXPECT_REPORT(driver, (KC_X));      -- 1回目シングルタップ
    //   EXPECT_EMPTY_REPORT(driver);
    //   EXPECT_REPORT(driver, (KC_X));      -- 2回目シングルタップ
    //   EXPECT_EMPTY_REPORT(driver);

    // レポートが4件以上あること（X押下、空、X押下、空）
    try testing.expect(driver.keyboard_count >= 4);

    // 1つ目: KC_X あり
    try testing.expect(driver.keyboard_reports[0].hasKey(KC.X));
    // 2つ目: 空レポート
    try testing.expect(driver.keyboard_reports[1].isEmpty());
    // 3つ目: KC_X あり
    try testing.expect(driver.keyboard_reports[2].hasKey(KC.X));
    // 4つ目: 空レポート（unregisterAndReset で送信される）
    try testing.expect(driver.keyboard_reports[3].isEmpty());

    // ESC（on_double_tap）は送信されていないこと
    var found_esc = false;
    for (0..@min(driver.keyboard_count, 64)) |i| {
        if (driver.keyboard_reports[i].hasKey(KC.ESCAPE)) {
            found_esc = true;
            break;
        }
    }
    try testing.expect(!found_esc);
}
