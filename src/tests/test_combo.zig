//! Combo テスト - C版 tests/combo/test_combo.cpp の移植
//!
//! C版テストケースを Zig の combo.zig API で論理的に等価に再現する。
//! keyboard.zig への Combo 統合前のため、combo.processCombo() を直接呼び出す。
//!
//! C版テスト対応:
//! 1. combo_modtest_tapped                    — コンボタップで結果キーが送信される
//! 2. combo_modtest_held_longer_than_tapping_term — ホールドでの動作検証
//! 3. combo_single_key_twice                  — 同一コンボの2回連続タップ

const std = @import("std");
const testing = std.testing;

const action = @import("../core/action.zig");
const action_code = @import("../core/action_code.zig");
const combo = @import("../core/combo.zig");
const event_mod = @import("../core/event.zig");
const host = @import("../core/host.zig");
const keycode_mod = @import("../core/keycode.zig");
const timer = @import("../hal/timer.zig");

const KC = keycode_mod.KC;
const KeyEvent = event_mod.KeyEvent;
const KeyRecord = event_mod.KeyRecord;
const FixedTestDriver = @import("../core/test_driver.zig").FixedTestDriver;
const TestDriver = FixedTestDriver(64, 16);

// ============================================================
// テスト用キーマップ
// ============================================================

// C版テストのキーマップ:
//   (0,0)=KC.Y, (0,1)=KC.U, (0,2)=KC.A
fn testKeycodeResolver(ev: KeyEvent) keycode_mod.Keycode {
    const map = [3]keycode_mod.Keycode{ KC.Y, KC.U, KC.A };
    if (ev.key.col < map.len) return map[ev.key.col];
    return KC.NO;
}

fn testActionResolver(ev: KeyEvent) action_code.Action {
    const kc = testKeycodeResolver(ev);
    return action_code.keycodeToAction(kc);
}

fn setupTest() *TestDriver {
    const S = struct {
        var driver: TestDriver = .{};
    };
    S.driver = .{};
    combo.reset();
    action.reset();
    timer.mockReset();
    host.setDriver(host.HostDriver.from(&S.driver));
    action.setActionResolver(testActionResolver);
    return &S.driver;
}

fn teardownTest() void {
    host.clearDriver();
    combo.reset();
}

// ============================================================
// C版 test_combo.cpp のテストケース移植
// ============================================================

// C版 combo_modtest_tapped の移植
// Y+U コンボタップで結果キー（KC_SPACE）が送信され、
// リリース後に空レポートが送信される。
test "combo_tapped" {
    const driver = setupTest();
    defer teardownTest();

    const combos = [_]combo.ComboDefinition{
        .{ .key1 = KC.Y, .key2 = KC.U, .result = KC.SPACE },
    };
    combo.setComboTable(&combos);
    combo.setKeycodeResolver(testKeycodeResolver);

    // Y を押す
    var press_y = KeyRecord{ .event = KeyEvent.keyPress(0, 0, timer.read()) };
    _ = combo.processCombo(&press_y);

    // U を押す（COMBO_TERM 内）→ コンボ発動
    timer.mockAdvance(10);
    var press_u = KeyRecord{ .event = KeyEvent.keyPress(0, 1, timer.read()) };
    _ = combo.processCombo(&press_u);

    // KC_SPACE が送信されるはず
    try testing.expect(driver.keyboard_count >= 1);
    try testing.expect(driver.lastKeyboardReport().hasKey(KC.SPACE));

    // Y をリリース
    timer.mockAdvance(1);
    var release_y = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, timer.read()) };
    _ = combo.processCombo(&release_y);

    // U をリリース → コンボ解除、空レポート
    timer.mockAdvance(1);
    var release_u = KeyRecord{ .event = KeyEvent.keyRelease(0, 1, timer.read()) };
    _ = combo.processCombo(&release_u);

    try testing.expect(driver.lastKeyboardReport().isEmpty());
}

// C版 combo_modtest_held_longer_than_tapping_term に対応
// NOTE: C版は COMBO(modtest_combo, RSFT_T(KC_SPACE)) による Mod-Tap コンボのホールド動作を
// 検証するが、現行 ComboDefinition では Mod-Tap Combo を表現できないため、
// 単純コンボ (KC.SPACE) のホールド動作のみ検証している。
test "combo_held" {
    const driver = setupTest();
    defer teardownTest();

    const combos = [_]combo.ComboDefinition{
        .{ .key1 = KC.Y, .key2 = KC.U, .result = KC.SPACE },
    };
    combo.setComboTable(&combos);
    combo.setKeycodeResolver(testKeycodeResolver);

    // Y+U でコンボ発動
    var press_y = KeyRecord{ .event = KeyEvent.keyPress(0, 0, timer.read()) };
    _ = combo.processCombo(&press_y);
    timer.mockAdvance(10);
    var press_u = KeyRecord{ .event = KeyEvent.keyPress(0, 1, timer.read()) };
    _ = combo.processCombo(&press_u);

    // コンボが発動している
    try testing.expect(driver.lastKeyboardReport().hasKey(KC.SPACE));

    // TAPPING_TERM を超えてホールド
    timer.mockAdvance(201);

    // まだキーは押されたまま（リリースしていない）
    try testing.expect(driver.lastKeyboardReport().hasKey(KC.SPACE));

    // リリース → 空レポート
    var release_y = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, timer.read()) };
    _ = combo.processCombo(&release_y);
    timer.mockAdvance(1);
    var release_u = KeyRecord{ .event = KeyEvent.keyRelease(0, 1, timer.read()) };
    _ = combo.processCombo(&release_u);

    try testing.expect(driver.lastKeyboardReport().isEmpty());
}

// C版 combo_single_key_twice に対応
// NOTE: C版は single_key_combo (KC_A のみ) による単一キーコンボを使用するが、
// 現行 ComboDefinition では単一キーコンボを表現できないため、2キーコンボで代替。
// 同一コンボを2回連続タップすると、2回とも正しく結果キーが送信される。
test "combo_twice" {
    const driver = setupTest();
    defer teardownTest();

    const combos = [_]combo.ComboDefinition{
        .{ .key1 = KC.Y, .key2 = KC.U, .result = KC.SPACE },
    };
    combo.setComboTable(&combos);
    combo.setKeycodeResolver(testKeycodeResolver);

    // 1回目: Y+U コンボタップ
    var press_y1 = KeyRecord{ .event = KeyEvent.keyPress(0, 0, timer.read()) };
    _ = combo.processCombo(&press_y1);
    timer.mockAdvance(5);
    var press_u1 = KeyRecord{ .event = KeyEvent.keyPress(0, 1, timer.read()) };
    _ = combo.processCombo(&press_u1);
    try testing.expect(driver.lastKeyboardReport().hasKey(KC.SPACE));

    // 1回目リリース
    timer.mockAdvance(1);
    var release_y1 = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, timer.read()) };
    _ = combo.processCombo(&release_y1);
    timer.mockAdvance(1);
    var release_u1 = KeyRecord{ .event = KeyEvent.keyRelease(0, 1, timer.read()) };
    _ = combo.processCombo(&release_u1);
    try testing.expect(driver.lastKeyboardReport().isEmpty());

    // 2回目: 同じ Y+U コンボタップ（disabled フラグがリセットされていること）
    timer.mockAdvance(50);
    var press_y2 = KeyRecord{ .event = KeyEvent.keyPress(0, 0, timer.read()) };
    _ = combo.processCombo(&press_y2);
    timer.mockAdvance(5);
    var press_u2 = KeyRecord{ .event = KeyEvent.keyPress(0, 1, timer.read()) };
    _ = combo.processCombo(&press_u2);
    try testing.expect(driver.lastKeyboardReport().hasKey(KC.SPACE));

    // 2回目リリース
    timer.mockAdvance(1);
    var release_y2 = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, timer.read()) };
    _ = combo.processCombo(&release_y2);
    timer.mockAdvance(1);
    var release_u2 = KeyRecord{ .event = KeyEvent.keyRelease(0, 1, timer.read()) };
    _ = combo.processCombo(&release_u2);
    try testing.expect(driver.lastKeyboardReport().isEmpty());
}
