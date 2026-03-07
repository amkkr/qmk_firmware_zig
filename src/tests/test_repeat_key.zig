// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zig port of tests/repeat_key/test_repeat_key.cpp
// Original: Copyright 2023 Google LLC

//! Repeat Key 機能の統合テスト
//!
//! C版 tests/repeat_key/test_repeat_key.cpp を Zig に移植。
//! TestFixture を使用して keyboard.zig パイプライン経由での動作を検証する。
//!
//! テスト設定（C版 tests/repeat_key/config.h 相当）:
//!   NO_ALT_REPEAT_KEY: Alt Repeat Key 無効
//!
//! === 移植状況 ===
//! [移植済] Basic                    - 基本の Repeat Key 動作（process_record_user コールバック検証はスキップ）
//! [移植済] AcrossLayers             - レイヤー切替後の Repeat Key 動作
//! [移植済] RollingToRepeat          - キー → Repeat のローリング押し
//! [移植済] RollingFromRepeat        - Repeat → キー のローリング押し
//! [移植済] RecallMods               - 修飾キー付きキーの Repeat
//! [移植済] StackMods                - 追加修飾キーを重ねての Repeat
//! [移植済] IgnoredKeys              - 修飾キーや Layer Lock は記録されない
//! [移植済] ModTap                   - Mod-Tap キーの Repeat
//! [移植済] SetRepeatKeyKeycode      - setLastKeycode/getLastKeycode API 直接呼び出し
//! [スキップ] Macro                  - Zig版に SEND_STRING / process_record_user コールバック未実装
//! [スキップ] MacroCustomRepeat      - Zig版に get_repeat_key_count / process_record_user 未実装
//! [移植済] ShiftedKeycode            - S(KC_x) の Shifted Keycode 記録・再送
//! [移植済] WithOneShotShift         - OSM + Repeat の統合テスト（OSM の oneshot_mods がリピートに反映）
//! [移植済] AutoShift                - Auto Shift + Repeat 統合（長押し Repeat で Auto Shift 適用）
//! [スキップ] FilterRememberedMods   - Zig版に remember_last_key_user コールバック未実装
//! [スキップ] RepeatKeyInvoke        - Zig版に repeat_key_invoke() API 未実装

const std = @import("std");
const testing = std.testing;

const keycode = @import("../core/keycode.zig");
const report_mod = @import("../core/report.zig");
const test_fixture = @import("../core/test_fixture.zig");
const repeat_key = @import("../core/repeat_key.zig");
const auto_shift = @import("../core/auto_shift.zig");
const host = @import("../core/host.zig");
const keymap_mod = @import("../core/keymap.zig");
const layer = @import("../core/layer.zig");
const timer = @import("../hal/timer.zig");

const KC = keycode.KC;
const Mod = keycode.Mod;
const ModBit = report_mod.ModBit;
const TestFixture = test_fixture.TestFixture;
const KeymapKey = test_fixture.KeymapKey;
const TAPPING_TERM = test_fixture.TAPPING_TERM;
const KeyboardReport = report_mod.KeyboardReport;
const AUTO_SHIFT_TIMEOUT = auto_shift.AUTO_SHIFT_TIMEOUT;

// ============================================================
// ヘルパー関数
// ============================================================

/// テスト用のフィクスチャセットアップ
fn setupFixture(fixture: *TestFixture) void {
    fixture.setup();
    timer.mockReset();
    repeat_key.reset();
}

/// キーをタップ（press + scan + release + scan）
fn tapKey(fixture: *TestFixture, row: u8, col: u8) void {
    fixture.pressKey(row, col);
    fixture.runOneScanLoop();
    fixture.releaseKey(row, col);
    fixture.runOneScanLoop();
}

/// キーを指定時間ホールドしてからリリース
fn tapKeyWithDuration(fixture: *TestFixture, row: u8, col: u8, duration_ms: u16) void {
    fixture.pressKey(row, col);
    fixture.idleFor(duration_ms);
    fixture.releaseKey(row, col);
    fixture.runOneScanLoop();
}

// ============================================================
// Basic: "A, Repeat, Repeat, B, Repeat" → "aaabb"
// C版 TEST_F(RepeatKey, Basic) に対応
// ============================================================
test "RepeatKey: Basic - A, Repeat, Repeat, B, Repeat produces aaabb" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    // Keymap: (0,0)=KC_A, (0,1)=KC_B, (0,2)=QK_REP
    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
        KeymapKey.init(0, 0, 1, KC.B),
        KeymapKey.init(0, 0, 2, keycode.QK_REP),
    });

    // KC_A を押す
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.A));
    try testing.expectEqual(KC.A, repeat_key.getLastKeycode());
    try testing.expectEqual(@as(u8, 0), repeat_key.getLastMods());

    // KC_A を離す
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());

    // Repeat Key を1回タップ → KC_A が再送される
    fixture.pressKey(0, 2);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.A));
    fixture.releaseKey(0, 2);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());

    // Repeat Key をもう1回タップ → KC_A が再送される
    fixture.pressKey(0, 2);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.A));
    fixture.releaseKey(0, 2);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());

    // KC_B をタップ
    tapKey(&fixture, 0, 1);
    try testing.expectEqual(KC.B, repeat_key.getLastKeycode());

    // Repeat Key をタップ → KC_B が再送される
    fixture.pressKey(0, 2);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.B));
    fixture.releaseKey(0, 2);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

// ============================================================
// AcrossLayers: レイヤー切替後も Repeat Key が正しく動作する
// C版 TEST_F(RepeatKey, AcrossLayers) に対応
//
// Keymap:
//   Layer 0: QK_REP(0,0), MO(1)(0,1), KC_A(0,2)
//   Layer 1: KC_TRNS(1,0), KC_TRNS(1,1), KC_B(1,2)
//
// 手順: MO(1) ホールド → KC_B タップ → MO(1) リリース → Repeat×2
//       → KC_A タップ → MO(1) ホールド → Repeat×2
// 期待: "bbbaaa"
// ============================================================
test "RepeatKey: AcrossLayers - repeat across layer changes" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        // Layer 0
        KeymapKey.init(0, 0, 0, keycode.QK_REP),
        KeymapKey.init(0, 0, 1, keycode.MO(1)),
        KeymapKey.init(0, 0, 2, KC.A),
        // Layer 1
        KeymapKey.init(1, 0, 0, KC.TRNS),
        KeymapKey.init(1, 0, 1, KC.TRNS),
        KeymapKey.init(1, 0, 2, KC.B),
    });

    // MO(1) をホールド（TAPPING_TERM 待ち）
    fixture.pressKey(0, 1);
    fixture.idleFor(TAPPING_TERM + 1);
    try testing.expect(fixture.isLayerOn(1));

    // Layer 1 で KC_B をタップ
    tapKey(&fixture, 0, 2);
    try testing.expectEqual(KC.B, repeat_key.getLastKeycode());

    // MO(1) をリリース → Layer 0 に戻る
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();
    try testing.expect(!fixture.isLayerOn(1));

    // Repeat Key × 2 → KC_B が再送される
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.B));
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.B));
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // Layer 0 で KC_A をタップ
    tapKey(&fixture, 0, 2);
    try testing.expectEqual(KC.A, repeat_key.getLastKeycode());

    // MO(1) をホールド（TAPPING_TERM 待ち）
    fixture.pressKey(0, 1);
    fixture.idleFor(TAPPING_TERM + 1);

    // Repeat Key × 2 → KC_A が再送される（レイヤー1でも QK_REP は TRNS で layer 0 の QK_REP に解決）
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.A));
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.A));
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
}

// ============================================================
// RollingToRepeat: "A(down), Repeat(down), A(up), Repeat(up), Repeat" → "aaa"
// C版 TEST_F(RepeatKey, RollingToRepeat) に対応
// ============================================================
test "RepeatKey: RollingToRepeat - rolling press from key to repeat" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
        KeymapKey.init(0, 0, 1, keycode.QK_REP),
    });

    // A を押す
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.A));

    // Repeat を押す（A はまだ押されている）→ A が繰り返される
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.A));

    // A を離す
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // Repeat を離す
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());

    // もう一度 Repeat をタップ → KC_A が再送される
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.A));
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

// ============================================================
// RollingFromRepeat: "A, Repeat(down), B(down), Repeat(up), B(up), Repeat" → "aabb"
// C版 TEST_F(RepeatKey, RollingFromRepeat) に対応
// ============================================================
test "RepeatKey: RollingFromRepeat - rolling press from repeat to key" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
        KeymapKey.init(0, 0, 1, KC.B),
        KeymapKey.init(0, 0, 2, keycode.QK_REP),
    });

    // A をタップ
    tapKey(&fixture, 0, 0);
    try testing.expectEqual(KC.A, repeat_key.getLastKeycode());

    // Repeat を押す → KC_A が再送される
    fixture.pressKey(0, 2);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.A));

    // B を押す（Repeat はまだ押されている）→ KC_A と KC_B の両方がレポートに含まれる
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.A));
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.B));

    // last_keycode が KC_B に更新されること
    try testing.expectEqual(KC.B, repeat_key.getLastKeycode());

    // Repeat を離す（KC_A が unregister される）
    fixture.releaseKey(0, 2);
    fixture.runOneScanLoop();
    // C版 InSequence: EXPECT_REPORT(driver, (KC_B)) に相当
    // KC_A が unregister され、KC_B のみのレポートになること
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.B));
    try testing.expect(!fixture.driver.lastKeyboardReport().hasKey(KC.A));

    // B を離す
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();
    // tapping パイプラインの遅延を考慮して idle
    fixture.idleFor(TAPPING_TERM + 1);

    // Repeat をタップ → KC_B が再送される
    fixture.pressKey(0, 2);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.B));
    fixture.releaseKey(0, 2);
    fixture.runOneScanLoop();
}

// ============================================================
// RecallMods: "AltGr+C, Repeat, Repeat, C" → AltGr+C が2回再送され、最後はCのみ
// C版 TEST_F(RepeatKey, RecallMods) に対応
// ============================================================
test "RepeatKey: RecallMods - repeat key restores modifier state" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.C),
        KeymapKey.init(0, 0, 1, KC.RIGHT_ALT),
        KeymapKey.init(0, 0, 2, keycode.QK_REP),
    });

    // RALT を押す
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();

    // C をタップ（RALT 押下中）
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    var r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.C));
    try testing.expect(r.mods & ModBit.RALT != 0);

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // RALT を離す
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();

    // last_keycode が KC_C、last_mods に RALT が記録されていること
    try testing.expectEqual(KC.C, repeat_key.getLastKeycode());
    try testing.expect(repeat_key.getLastMods() & ModBit.RALT != 0);

    // Repeat Key 1回目 → RALT + C が再送される
    fixture.pressKey(0, 2);
    fixture.runOneScanLoop();
    r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.C));
    try testing.expect(r.mods & ModBit.RALT != 0);
    fixture.releaseKey(0, 2);
    fixture.runOneScanLoop();

    // Repeat Key 2回目 → RALT + C が再送される
    fixture.pressKey(0, 2);
    fixture.runOneScanLoop();
    r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.C));
    try testing.expect(r.mods & ModBit.RALT != 0);
    fixture.releaseKey(0, 2);
    fixture.runOneScanLoop();

    // 修飾キーなしで C をタップ → C のみ
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.C));
    try testing.expectEqual(@as(u8, 0), r.mods & ModBit.RALT);
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
}

// ============================================================
// StackMods: "Ctrl+Left, Repeat, Shift+Repeat, Shift+Repeat, Repeat, Left"
// C版 TEST_F(RepeatKey, StackMods) に対応
// 追加修飾キーを重ねて Repeat できることを確認
// ============================================================
test "RepeatKey: StackMods - additional mods stack with repeated mods" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.LEFT),
        KeymapKey.init(0, 0, 1, KC.LEFT_SHIFT),
        KeymapKey.init(0, 0, 2, KC.LEFT_CTRL),
        KeymapKey.init(0, 0, 3, keycode.QK_REP),
    });

    // Ctrl を押す
    fixture.pressKey(0, 2);
    fixture.runOneScanLoop();

    // Left をタップ（Ctrl 押下中）
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    var r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.LEFT));
    try testing.expect(r.mods & ModBit.LCTRL != 0);
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // Ctrl を離す
    fixture.releaseKey(0, 2);
    fixture.runOneScanLoop();

    // last_keycode が LEFT、last_mods に LCTRL が記録
    try testing.expectEqual(KC.LEFT, repeat_key.getLastKeycode());
    try testing.expect(repeat_key.getLastMods() & ModBit.LCTRL != 0);

    // Repeat Key → Ctrl+Left が再送される
    fixture.pressKey(0, 3);
    fixture.runOneScanLoop();
    r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.LEFT));
    try testing.expect(r.mods & ModBit.LCTRL != 0);
    fixture.releaseKey(0, 3);
    fixture.runOneScanLoop();

    // Shift を押す
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();

    // Shift + Repeat → Ctrl+Shift+Left
    fixture.pressKey(0, 3);
    fixture.runOneScanLoop();
    r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.LEFT));
    try testing.expect(r.mods & ModBit.LCTRL != 0);
    try testing.expect(r.mods & ModBit.LSHIFT != 0);
    fixture.releaseKey(0, 3);
    fixture.runOneScanLoop();

    // Shift + Repeat もう一度 → Ctrl+Shift+Left
    fixture.pressKey(0, 3);
    fixture.runOneScanLoop();
    r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.LEFT));
    try testing.expect(r.mods & ModBit.LCTRL != 0);
    try testing.expect(r.mods & ModBit.LSHIFT != 0);
    fixture.releaseKey(0, 3);
    fixture.runOneScanLoop();

    // Shift を離す
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();

    // last_mods は変わらず LCTRL のまま
    try testing.expect(repeat_key.getLastMods() & ModBit.LCTRL != 0);

    // Repeat → Ctrl+Left（Shift なし）
    fixture.pressKey(0, 3);
    fixture.runOneScanLoop();
    r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.LEFT));
    try testing.expect(r.mods & ModBit.LCTRL != 0);
    fixture.releaseKey(0, 3);
    fixture.runOneScanLoop();

    // Left をタップ（修飾キーなし）→ Left のみ
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.LEFT));
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
}

// ============================================================
// IgnoredKeys: 修飾キーと Layer Lock は last_keycode に記録されない
// C版 TEST_F(RepeatKey, IgnoredKeys) に対応
// ============================================================
test "RepeatKey: IgnoredKeys - mods and Layer Lock are not remembered" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
        KeymapKey.init(0, 0, 1, keycode.QK_REP),
        KeymapKey.init(0, 0, 2, KC.LEFT_SHIFT),
        KeymapKey.init(0, 0, 3, KC.LEFT_CTRL),
        KeymapKey.init(0, 0, 4, keycode.QK_LAYER_LOCK),
    });

    // KC_A をタップ
    tapKey(&fixture, 0, 0);
    try testing.expectEqual(KC.A, repeat_key.getLastKeycode());

    // Shift をタップ（修飾キーは記録されない）
    tapKey(&fixture, 0, 2);
    try testing.expectEqual(KC.A, repeat_key.getLastKeycode());

    // Ctrl をタップ（修飾キーは記録されない）
    tapKey(&fixture, 0, 3);
    try testing.expectEqual(KC.A, repeat_key.getLastKeycode());

    // Layer Lock をタップ（記録されない）
    tapKey(&fixture, 0, 4);
    try testing.expectEqual(KC.A, repeat_key.getLastKeycode());

    // Repeat Key をタップ → KC_A が再送される
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.A));
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();

    // もう一度 Repeat Key
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.A));
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();
}

// ============================================================
// ModTap: Mod-Tap キーの Repeat Key 動作
// C版 TEST_F(RepeatKey, ModTap) に対応
//
// LSFT_T(KC_A) をタップ → Repeat × 2 → LSFT_T(KC_A) ホールド → Repeat × 2 → リリース → Repeat
// C版期待値: "aaaAAa"（ホールド中の Repeat は Shift+A）
// ============================================================
test "RepeatKey: ModTap - repeat with mod-tap key" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.LSFT_T(KC.A)),
        KeymapKey.init(0, 0, 1, keycode.QK_REP),
    });

    // LSFT_T(KC_A) をタップ（タップ判定のため素早く press/release）
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    // タップ完了を待つ
    fixture.idleFor(TAPPING_TERM + 1);

    // last_keycode が KC_A に記録されていること
    try testing.expectEqual(KC.A, repeat_key.getLastKeycode());

    // Repeat Key × 1 → KC_A が再送
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.A));
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();

    // Repeat Key × 2 → KC_A が再送
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.A));
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();

    // LSFT_T(KC_A) をホールド（TAPPING_TERM 超え）
    fixture.pressKey(0, 0);
    fixture.idleFor(TAPPING_TERM + 1);
    // ホールド状態: LSHIFT が有効になる
    var r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.mods & ModBit.LSHIFT != 0);

    // Repeat Key → Shift が有効な状態で KC_A が再送（Shift+A）
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();
    r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.A));
    try testing.expect(r.mods & ModBit.LSHIFT != 0);
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();

    // もう一度 Repeat Key → Shift+A
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();
    r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.A));
    try testing.expect(r.mods & ModBit.LSHIFT != 0);
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();

    // LSFT_T をリリース
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // Repeat Key → Shift なしで KC_A
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();
    r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.A));
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();
}

// ============================================================
// SetRepeatKeyKeycode: setLastKeycode/getLastKeycode API の直接テスト
// C版 TEST_F(RepeatKey, SetRepeatKeyKeycode) の簡略版
// ============================================================
test "RepeatKey: SetRepeatKeyKeycode - direct API test" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.QK_REP),
    });

    // setLastKeycode で KC_A を設定
    repeat_key.setLastKeycode(KC.A, 0);
    try testing.expectEqual(KC.A, repeat_key.getLastKeycode());

    // Repeat Key をタップ → KC_A が送信される
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.A));
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // もう一度 Repeat
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.A));
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // setLastKeycode で KC_B + LSHIFT に変更
    repeat_key.setLastKeycode(KC.B, ModBit.LSHIFT);

    // Repeat Key → Shift+B が送信される
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    var r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.B));
    try testing.expect(r.mods & ModBit.LSHIFT != 0);
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // もう一度 Repeat → Shift+B
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.B));
    try testing.expect(r.mods & ModBit.LSHIFT != 0);
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // KC_NO (0) を設定しても、setLastKeycode は KC_NO を無視するため last_keycode は KC_B のまま
    repeat_key.setLastKeycode(0, 0);
    try testing.expectEqual(KC.B, repeat_key.getLastKeycode());

    // setLastKeycode(0, 0) 後に Repeat を押すと、last_keycode が KC_B のままなので KC_B が送信される
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    var r2 = fixture.driver.lastKeyboardReport();
    try testing.expect(r2.hasKey(KC.B));
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
}

// ============================================================
// NoKeyRecorded: 何も押していない状態で Repeat Key は何もしない
// ============================================================
test "RepeatKey: NoKeyRecorded - repeat does nothing when no key recorded" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.QK_REP),
    });

    // 何も記録していない状態で Repeat Key
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    // repeat_key.processRepeatKey は last_keycode == 0 の場合何もしない
    // レポートが送信されないこと（空のレポート）を確認
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
    // last_keycode が 0 のままであることを確認
    try testing.expectEqual(@as(keycode.Keycode, 0), repeat_key.getLastKeycode());
}

// ============================================================
// ResetClearsState: reset() でキーコードとモッドがクリアされる
// ============================================================
test "RepeatKey: ResetClearsState - reset clears keycode and mods" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
        KeymapKey.init(0, 0, 1, keycode.QK_REP),
    });

    // KC_A をタップ
    tapKey(&fixture, 0, 0);
    try testing.expectEqual(KC.A, repeat_key.getLastKeycode());

    // reset() でクリア
    repeat_key.reset();
    try testing.expectEqual(@as(keycode.Keycode, 0), repeat_key.getLastKeycode());
    try testing.expectEqual(@as(u8, 0), repeat_key.getLastMods());
}

// ============================================================
// ShiftedKeycode: S(KC_1) を Repeat Key で再送信
// C版 TEST_F(RepeatKey, ShiftedKeycode) に対応
//
// Keymap: S(KC_1)(0,0), KC_2(1,0), KC_LCTL(2,0), QK_REP(3,0)
// 手順: S(KC_1) タップ → Repeat → Ctrl 押下 → Repeat × 2 → Ctrl リリース → Repeat → KC_2 タップ
// 期待: Shift+1, Shift+1, Ctrl+Shift+1, Ctrl+Shift+1, Shift+1, 2
// ============================================================
test "RepeatKey: ShiftedKeycode - S(KC_1) is remembered and repeated with shift" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    const S_KC_1 = keycode.S(KC.@"1");

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, S_KC_1),
        KeymapKey.init(0, 1, 0, KC.@"2"),
        KeymapKey.init(0, 2, 0, KC.LEFT_CTRL),
        KeymapKey.init(0, 3, 0, keycode.QK_REP),
    });

    // S(KC_1) をタップ → Shift+1 が送信される
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    var r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.@"1"));
    try testing.expect(r.mods & ModBit.LSHIFT != 0);

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // last_keycode が S(KC_1) として記録されていること
    try testing.expectEqual(S_KC_1, repeat_key.getLastKeycode());

    // Repeat Key → Shift+1 が再送される
    fixture.pressKey(3, 0);
    fixture.runOneScanLoop();
    r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.@"1"));
    try testing.expect(r.mods & ModBit.LSHIFT != 0);
    fixture.releaseKey(3, 0);
    fixture.runOneScanLoop();

    // Ctrl を押す
    fixture.pressKey(2, 0);
    fixture.runOneScanLoop();

    // Ctrl + Repeat → Ctrl+Shift+1
    fixture.pressKey(3, 0);
    fixture.runOneScanLoop();
    r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.@"1"));
    try testing.expect(r.mods & ModBit.LSHIFT != 0);
    try testing.expect(r.mods & ModBit.LCTRL != 0);
    fixture.releaseKey(3, 0);
    fixture.runOneScanLoop();

    // Ctrl + Repeat もう一度 → Ctrl+Shift+1
    fixture.pressKey(3, 0);
    fixture.runOneScanLoop();
    r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.@"1"));
    try testing.expect(r.mods & ModBit.LSHIFT != 0);
    try testing.expect(r.mods & ModBit.LCTRL != 0);
    fixture.releaseKey(3, 0);
    fixture.runOneScanLoop();

    // Ctrl を離す
    fixture.releaseKey(2, 0);
    fixture.runOneScanLoop();

    // Repeat → Shift+1（Ctrl なし）
    fixture.pressKey(3, 0);
    fixture.runOneScanLoop();
    r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.@"1"));
    try testing.expect(r.mods & ModBit.LSHIFT != 0);
    try testing.expectEqual(@as(u8, 0), r.mods & ModBit.LCTRL);
    fixture.releaseKey(3, 0);
    fixture.runOneScanLoop();

    // KC_2 をタップ → 2 のみ（Shift なし）
    fixture.pressKey(1, 0);
    fixture.runOneScanLoop();
    r = fixture.driver.lastKeyboardReport();
    try testing.expect(r.hasKey(KC.@"2"));
    try testing.expectEqual(@as(u8, 0), r.mods & ModBit.LSHIFT);
    fixture.releaseKey(1, 0);
    fixture.runOneScanLoop();
}

// ============================================================
// WithOneShotShift: OSM(LSFT) + Repeat Key で Shift 付きリピート
// C版 TEST_F(RepeatKey, WithOneShotShift) に対応
//
// 手順: A, OSM(LSFT), Repeat, Repeat → "aAa"
// OSM タップ後の Repeat Key は oneshot_mods の LSHIFT 付きで
// リピートされ "A" を送信する。
// 2回目の Repeat は oneshot_mods が消費済みなので "a" になる。
// ============================================================
test "RepeatKey: WithOneShotShift - OSM shift applies to repeat" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    // oneshot_enable を有効にする
    keymap_mod.keymap_config.oneshot_enable = true;
    defer {
        keymap_mod.keymap_config.oneshot_enable = false;
    }

    // Keymap: (0,0)=KC_A, (0,1)=OSM(LSFT), (0,2)=QK_REP
    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
        KeymapKey.init(0, 0, 1, keycode.OSM(Mod.LSFT)),
        KeymapKey.init(0, 0, 2, keycode.QK_REP),
    });

    // --- Step 1: KC_A をタップ → "a" ---
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    {
        const r = fixture.driver.lastKeyboardReport();
        try testing.expect(r.hasKey(KC.A));
        try testing.expectEqual(@as(u8, 0), r.mods & ModBit.LSHIFT);
    }
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expectEqual(KC.A, repeat_key.getLastKeycode());
    try testing.expectEqual(@as(u8, 0), repeat_key.getLastMods());

    // --- Step 2: OSM(LSFT) をタップ ---
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();
    // タッピング完了を待つ
    fixture.idleFor(TAPPING_TERM + 1);

    // oneshot_mods に LSHIFT が設定されていることを確認
    try testing.expect(host.getOneshotMods() & ModBit.LSHIFT != 0);

    // --- Step 3: Repeat Key をタップ → "A" (OSM の LSHIFT 適用) ---
    fixture.pressKey(0, 2);
    fixture.runOneScanLoop();
    {
        const r = fixture.driver.lastKeyboardReport();
        try testing.expect(r.hasKey(KC.A));
        // OSM の LSHIFT がレポートに含まれる
        try testing.expect(r.mods & ModBit.LSHIFT != 0);
    }
    fixture.releaseKey(0, 2);
    fixture.runOneScanLoop();

    // OSM は1回で消費されている
    try testing.expectEqual(@as(u8, 0), host.getOneshotMods());

    // --- Step 4: Repeat Key をもう一度タップ → "a" (OSM 消費済み) ---
    fixture.pressKey(0, 2);
    fixture.runOneScanLoop();
    {
        const r = fixture.driver.lastKeyboardReport();
        try testing.expect(r.hasKey(KC.A));
        // OSM は消費済みなので LSHIFT なし
        try testing.expectEqual(@as(u8, 0), r.mods & ModBit.LSHIFT);
    }
    fixture.releaseKey(0, 2);
    fixture.runOneScanLoop();
}

// ============================================================
// AutoShift: Auto Shift + Repeat Key の統合
// C版 TEST_F(RepeatKey, AutoShift) に対応
//
// 手順:
//   tap_key(A) → "a" (短タップ、Auto Shift なし)
//   tap_key(Repeat) → "a" (短タップ Repeat)
//   tap_key(Repeat, AUTO_SHIFT_TIMEOUT+1) → "A" (長押し Repeat → Auto Shift)
//   tap_key(B, AUTO_SHIFT_TIMEOUT+1) → "B" (B の長押し → Auto Shift)
//   tap_key(Repeat) → "b" (短タップ Repeat、last_mods=0)
//   tap_key(Repeat, AUTO_SHIFT_TIMEOUT+1) → "B" (長押し Repeat → Auto Shift)
//
// 期待出力: "aaABbB"
// ============================================================
test "RepeatKey: AutoShift - auto shift applies to long-press repeat" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    // Auto Shift を有効化
    auto_shift.enable();
    defer auto_shift.reset();

    // Keymap: (0,0)=KC_A, (0,1)=KC_B, (0,2)=QK_REP
    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
        KeymapKey.init(0, 0, 1, KC.B),
        KeymapKey.init(0, 0, 2, keycode.QK_REP),
    });

    // --- Step 1: KC_A を短タップ → "a" ---
    // Auto Shift 対象だが短タップなのでシフトなし
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    // Auto Shift: press で保留される（レポートはまだ送信されない）
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    // Auto Shift: release で確定（短タップ → シフトなし）

    try testing.expectEqual(KC.A, repeat_key.getLastKeycode());
    try testing.expectEqual(@as(u8, 0), repeat_key.getLastMods());

    // --- Step 2: Repeat Key を短タップ → "a" ---
    tapKey(&fixture, 0, 2);

    // --- Step 3: Repeat Key を長押し → "A" (Auto Shift 適用) ---
    tapKeyWithDuration(&fixture, 0, 2, AUTO_SHIFT_TIMEOUT + 1);

    // キーボードレポートの中に Shift + A のレポートがあることを確認
    {
        var found_shifted_a = false;
        var i: usize = 0;
        while (i < fixture.driver.keyboard_count) : (i += 1) {
            const r = fixture.driver.keyboard_reports[i];
            if (r.hasKey(KC.A) and (r.mods & ModBit.LSHIFT != 0)) {
                found_shifted_a = true;
                break;
            }
        }
        try testing.expect(found_shifted_a);
    }

    // --- Step 4: KC_B を長押し → "B" (Auto Shift 適用) ---
    fixture.pressKey(0, 1);
    fixture.idleFor(AUTO_SHIFT_TIMEOUT + 1);
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();

    try testing.expectEqual(KC.B, repeat_key.getLastKeycode());
    // Auto Shift で適用された Shift は last_mods に含まれない（C版互換）
    try testing.expectEqual(@as(u8, 0), repeat_key.getLastMods());

    // --- Step 5: Repeat Key を短タップ → "b" (Auto Shift なし) ---
    const count_before_step5 = fixture.driver.keyboard_count;
    tapKey(&fixture, 0, 2);
    // 短タップなので Shift なしの B が送信される
    {
        var found_unshifted_b = false;
        var i: usize = count_before_step5;
        while (i < fixture.driver.keyboard_count) : (i += 1) {
            const r = fixture.driver.keyboard_reports[i];
            if (r.hasKey(KC.B) and (r.mods & ModBit.LSHIFT == 0)) {
                found_unshifted_b = true;
                break;
            }
        }
        try testing.expect(found_unshifted_b);
    }

    // --- Step 6: Repeat Key を長押し → "B" (Auto Shift 適用) ---
    const count_before_step6 = fixture.driver.keyboard_count;
    tapKeyWithDuration(&fixture, 0, 2, AUTO_SHIFT_TIMEOUT + 1);
    {
        var found_shifted_b = false;
        var i: usize = count_before_step6;
        while (i < fixture.driver.keyboard_count) : (i += 1) {
            const r = fixture.driver.keyboard_reports[i];
            if (r.hasKey(KC.B) and (r.mods & ModBit.LSHIFT != 0)) {
                found_shifted_b = true;
                break;
            }
        }
        try testing.expect(found_shifted_b);
    }
}
