// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zig port of tests/combo/test_combo.cpp
// Original: Copyright 2023 Stefan Kerkmann (@KarlK90), @filterpaper

//! Combo テスト - C版 tests/combo/test_combo.cpp の移植
//!
//! C版テストケースを Zig の combo.zig API で再現する。
//! 一部テストは現行 ComboDefinition の制約により等価ではない（詳細は各テストの NOTE を参照）。
//! keyboard.zig への Combo 統合前のため、combo.processCombo() を直接呼び出す。
//!
//! C版テスト対応:
//! 1. combo_modtest_tapped                    — コンボタップで結果キーが送信される
//! 2. combo_modtest_held_longer_than_tapping_term — ホールドでの動作検証
//! 3. combo_osmshift_tapped                   — OSMコンボタップで次キーにシフト適用
//! 4. combo_single_key_twice                  — 同一コンボの2回連続タップ

const std = @import("std");
const testing = std.testing;

const action = @import("../core/action.zig");
const action_code = @import("../core/action_code.zig");
const combo = @import("../core/combo.zig");
const event_mod = @import("../core/event.zig");
const host = @import("../core/host.zig");
const keycode_mod = @import("../core/keycode.zig");
const keymap_mod = @import("../core/keymap.zig");
const report_mod = @import("../core/report.zig");
const timer = @import("../hal/timer.zig");

const KC = keycode_mod.KC;
const Mod = keycode_mod.Mod;
const KeyEvent = event_mod.KeyEvent;
const KeyRecord = event_mod.KeyRecord;
const FixedTestDriver = @import("../core/test_driver.zig").FixedTestDriver;
const TestDriver = FixedTestDriver(64, 16);

// ============================================================
// テスト用キーマップ
// ============================================================

// C版テストのキーマップ:
//   (0,0)=KC.Y, (0,1)=KC.U, (0,2)=KC.A, (0,3)=KC.Z, (0,4)=KC.X, (0,5)=KC.I
fn testKeycodeResolver(ev: KeyEvent) keycode_mod.Keycode {
    const map = [6]keycode_mod.Keycode{ KC.Y, KC.U, KC.A, KC.Z, KC.X, KC.I };
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

// C版 combo_osmshift_tapped の移植
// Z+X コンボで OSM(LSFT) が発動し、コンボタップ自体ではレポートが送信されず、
// 次のキー（KC_I）を押すと LSHIFT + KC_I が送信される。
test "combo_osmshift_tapped" {
    const driver = setupTest();
    defer teardownTest();

    // oneshot を有効化
    keymap_mod.keymap_config.oneshot_enable = true;

    // Z+X コンボで OSM(MOD_LSFT) を発動
    const combos = [_]combo.ComboDefinition{
        .{ .key1 = KC.Z, .key2 = KC.X, .result = keycode_mod.OSM(Mod.LSFT) },
    };
    combo.setComboTable(&combos);
    combo.setKeycodeResolver(testKeycodeResolver);

    // Z を押す (col=3)
    var press_z = KeyRecord{ .event = KeyEvent.keyPress(0, 3, timer.read()) };
    _ = combo.processCombo(&press_z);

    // X を押す (col=4) → コンボ発動
    timer.mockAdvance(10);
    var press_x = KeyRecord{ .event = KeyEvent.keyPress(0, 4, timer.read()) };
    _ = combo.processCombo(&press_x);

    // Z をリリース
    timer.mockAdvance(1);
    var release_z = KeyRecord{ .event = KeyEvent.keyRelease(0, 3, timer.read()) };
    _ = combo.processCombo(&release_z);

    // X をリリース → コンボ解除
    timer.mockAdvance(1);
    var release_x = KeyRecord{ .event = KeyEvent.keyRelease(0, 4, timer.read()) };
    _ = combo.processCombo(&release_x);

    // press・release 両方でレポートが送信されていないことを確認
    // （OSM タップは次キーまで保留）
    const count_after_combo = driver.keyboard_count;

    // oneshot_mods に LSHIFT が設定されている
    try testing.expect(host.getOneshotMods() & report_mod.ModBit.LSHIFT != 0);

    // 次のキー KC_I を押す → OSM 適用で LSHIFT + KC_I が送信される
    const count_before_i = driver.keyboard_count;
    var press_i = KeyRecord{ .event = KeyEvent.keyPress(0, 5, timer.read()) };
    action.actionExec(&press_i);

    try testing.expect(driver.keyboard_count > count_before_i);

    // KC_I (0x0C) + LSHIFT が含まれるレポートを確認
    var found_shifted_i = false;
    var idx: usize = count_before_i;
    while (idx < driver.keyboard_count) : (idx += 1) {
        const rpt = driver.keyboard_reports[idx];
        if (rpt.hasKey(KC.I) and (rpt.mods & report_mod.ModBit.LSHIFT) != 0) {
            found_shifted_i = true;
            break;
        }
    }
    try testing.expect(found_shifted_i);

    // oneshot_mods がクリアされている
    try testing.expectEqual(@as(u8, 0), host.getOneshotMods());

    // KC_I をリリース
    var release_i = KeyRecord{ .event = KeyEvent.keyRelease(0, 5, timer.read()) };
    action.actionExec(&release_i);
    try testing.expect(driver.lastKeyboardReport().isEmpty());

    // もう一度 KC_I を押す → OSM は1回限りなのでシフトなし
    const count_before_i2 = driver.keyboard_count;
    timer.mockAdvance(10);
    var press_i2 = KeyRecord{ .event = KeyEvent.keyPress(0, 5, timer.read()) };
    action.actionExec(&press_i2);

    try testing.expect(driver.keyboard_count > count_before_i2);

    // LSHIFT なしで KC_I が送信される
    var found_unshifted_i = false;
    var idx2: usize = count_before_i2;
    while (idx2 < driver.keyboard_count) : (idx2 += 1) {
        const rpt = driver.keyboard_reports[idx2];
        if (rpt.hasKey(KC.I) and (rpt.mods & report_mod.ModBit.LSHIFT) == 0) {
            found_unshifted_i = true;
            break;
        }
    }
    try testing.expect(found_unshifted_i);

    var release_i2 = KeyRecord{ .event = KeyEvent.keyRelease(0, 5, timer.read()) };
    action.actionExec(&release_i2);
    try testing.expect(driver.lastKeyboardReport().isEmpty());

    // コンボの press・release でレポートが送信されていないことを確認
    try testing.expectEqual(@as(usize, 0), count_after_combo);
}
