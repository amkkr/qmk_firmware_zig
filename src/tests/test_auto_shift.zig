//! Auto Shift テスト - C版 tests/auto_shift/test_auto_shift.cpp の移植
//!
//! C版テストケースを Zig の auto_shift.processAutoShift() で論理的に等価に再現する。
//! keyboard.zig への Auto Shift 統合前のため、processAutoShift() を直接呼び出す。
//! タイマーのモック制御で C版テストの idle_for/run_one_scan_loop に相当する
//! 時間経過を再現する。
//!
//! C版テスト対応:
//! 1. key_release_before_timeout — タイムアウト前リリースで通常キー送信
//! 2. key_release_after_timeout  — タイムアウト後リリースで Shift+キー送信

const std = @import("std");
const testing = std.testing;

const auto_shift = @import("../core/auto_shift.zig");
const host = @import("../core/host.zig");
const report_mod = @import("../core/report.zig");
const keycode_mod = @import("../core/keycode.zig");
const timer = @import("../hal/timer.zig");

const KC = keycode_mod.KC;
const FixedTestDriver = @import("../core/test_driver.zig").FixedTestDriver;
const TestDriver = FixedTestDriver(64, 16);

fn setupTest() *TestDriver {
    const S = struct {
        var driver: TestDriver = .{};
    };
    S.driver = .{};
    auto_shift.reset();
    auto_shift.enable();
    timer.mockReset();
    host.hostReset();
    host.setDriver(host.HostDriver.from(&S.driver));
    return &S.driver;
}

fn teardownTest() void {
    host.clearDriver();
    auto_shift.reset();
}

// ============================================================
// C版 test_auto_shift.cpp のテストケース移植
// ============================================================

// C版 key_release_before_timeout の移植
// キーを AUTO_SHIFT_TIMEOUT より短く保持してリリースすると、
// 通常のキーコードが送信される（Shift なし）。
// C版の動作:
//   press → run_one_scan_loop → EXPECT_NO_REPORT
//   release → run_one_scan_loop → EXPECT_REPORT(KC_A) → EXPECT_EMPTY_REPORT
test "key_release_before_timeout" {
    const driver = setupTest();
    defer teardownTest();

    const press_time: u16 = timer.read();

    // Press KC_A
    const press_result = auto_shift.processAutoShift(KC.A, true, press_time);
    try testing.expect(press_result); // Auto Shift が消費
    try testing.expect(auto_shift.isInProgress());
    // 押しただけではレポートは送信されない (EXPECT_NO_REPORT)
    try testing.expectEqual(@as(usize, 0), driver.keyboard_count);

    // タイムアウト前に時間経過（1ms = run_one_scan_loop 相当）
    timer.mockAdvance(1);
    const release_time: u16 = timer.read();

    // Release KC_A（タイムアウト前）
    const release_result = auto_shift.processAutoShift(KC.A, false, release_time);
    try testing.expect(release_result);
    try testing.expect(!auto_shift.isInProgress());

    // KC_A が送信される（Shift なし）(EXPECT_REPORT(KC_A))
    try testing.expect(driver.keyboard_count >= 2);
    try testing.expect(driver.keyboard_reports[0].hasKey(KC.A));
    try testing.expectEqual(@as(u8, 0), driver.keyboard_reports[0].mods);

    // 空レポートが送信される (EXPECT_EMPTY_REPORT)
    try testing.expect(driver.lastKeyboardReport().isEmpty());
}

// C版 key_release_after_timeout の移植
// キーを AUTO_SHIFT_TIMEOUT 以上保持してリリースすると、
// Shift + キーコードが送信される。
// C版の動作:
//   press → idle_for(AUTO_SHIFT_TIMEOUT) → EXPECT_NO_REPORT
//   release → run_one_scan_loop
//   → EXPECT_REPORT(KC_LSFT, KC_A) → EXPECT_REPORT(KC_LSFT) → EXPECT_EMPTY_REPORT
test "key_release_after_timeout" {
    const driver = setupTest();
    defer teardownTest();

    const press_time: u16 = timer.read();

    // Press KC_A
    const press_result = auto_shift.processAutoShift(KC.A, true, press_time);
    try testing.expect(press_result);
    try testing.expect(auto_shift.isInProgress());

    // idle_for(AUTO_SHIFT_TIMEOUT) — タイムアウトまで待機
    timer.mockAdvance(auto_shift.AUTO_SHIFT_TIMEOUT);

    // まだ押しただけなのでレポートは送信されない (EXPECT_NO_REPORT)
    try testing.expectEqual(@as(usize, 0), driver.keyboard_count);

    // Release KC_A（タイムアウト後）
    const release_time: u16 = timer.read();
    const release_result = auto_shift.processAutoShift(KC.A, false, release_time);
    try testing.expect(release_result);
    try testing.expect(!auto_shift.isInProgress());

    // Shift + KC_A が送信される (EXPECT_REPORT(KC_LSFT, KC_A))
    try testing.expect(driver.keyboard_count >= 2);
    try testing.expect(driver.keyboard_reports[0].hasKey(KC.A));
    try testing.expectEqual(
        report_mod.ModBit.LSHIFT,
        driver.keyboard_reports[0].mods & report_mod.ModBit.LSHIFT,
    );

    // 空レポートが送信される (EXPECT_EMPTY_REPORT)
    try testing.expect(driver.lastKeyboardReport().isEmpty());
}
