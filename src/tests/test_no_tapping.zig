//! No Tapping テスト - C版 tests/no_tapping/ の移植
//!
//! NO_ACTION_TAPPING 設定時の挙動をテストする。
//! タッピング判定が無効な場合、Mod-Tap/Layer-Tap キーは
//! タッピングステートマシンをバイパスして即座にキーを送信する。
//!
//! C版テスト対応:
//!
//! no_action_tapping/test_layer_tap.cpp:
//! 1. TapP_Layer_Tap_KeyReportsKey   — LT(1,KC_P) タップ → 即座に KC_P
//! 2. HoldP_Layer_Tap_KeyReportsKey  — LT(1,KC_P) ホールド → KC_P のまま
//!
//! no_action_tapping/test_mod_tap.cpp:
//! 3. TapA_SHFT_T_KeyReportsKey      — SFT_T(KC_P) タップ → 即座に KC_P
//! 4. HoldA_SHFT_T_KeyReportsShift   — SFT_T(KC_P) ホールド → KC_P のまま
//! 5. ANewTapWithinTappingTermIsBuggy — 連続タップでも KC_P のまま
//!
//! no_action_tapping/test_one_shot_keys.cpp:
//! 6. OSMWithoutAdditionalKeypressDoesNothing — OSM(MOD_LSFT) → 即座に LSFT
//! 7. OSL_No_ReportPress              — OSL(1) タップ＋リリース → レポートなし
//! 8. OSL_ReportPress                 — OSL(1) ホールド中に別キー → レポートなし
//!
//! no_mod_tap_mods/test_tapping.cpp:
//! 9. TapA_SHFT_T_KeyReportsKey      — SFT_T(KC_P) → 即座に LSFT（モッドとして動作）
//! 10. HoldA_SHFT_T_KeyReportsShift   — ホールドでも LSFT のまま
//! 11. ANewTapWithinTappingTermIsBuggy — 連続タップでも LSFT のまま

const std = @import("std");
const testing = std.testing;

const keycode_mod = @import("../core/keycode.zig");
const action_code = @import("../core/action_code.zig");
const report_mod = @import("../core/report.zig");
const tapping = @import("../core/action_tapping.zig");
const TestFixture = @import("../core/test_fixture.zig").TestFixture;
const KeymapKey = @import("../core/test_fixture.zig").KeymapKey;
const KC = keycode_mod.KC;
const TAPPING_TERM = @import("../core/test_fixture.zig").TAPPING_TERM;

fn setupNoTapping() *TestFixture {
    const S = struct {
        var fixture: TestFixture = TestFixture.init();
    };
    S.fixture = TestFixture.init();
    S.fixture.setup();
    // NO_ACTION_TAPPING を有効化
    action_code.no_action_tapping = true;
    action_code.no_action_tapping_modtap_mods = false;
    return &S.fixture;
}

fn setupNoModTapMods() *TestFixture {
    const S = struct {
        var fixture: TestFixture = TestFixture.init();
    };
    S.fixture = TestFixture.init();
    S.fixture.setup();
    // NO_ACTION_TAPPING + NO_ACTION_TAPPING_MODTAP_MODS を有効化
    action_code.no_action_tapping = true;
    action_code.no_action_tapping_modtap_mods = true;
    return &S.fixture;
}

fn teardown(fixture: *TestFixture) void {
    fixture.deinit();
    action_code.no_action_tapping = false;
    action_code.no_action_tapping_modtap_mods = false;
}

// ============================================================
// no_action_tapping/test_layer_tap.cpp の移植
// ============================================================

// LT(1, KC_P) タップ → 即座に KC_P が送信される
test "NoTapping_LayerTap: TapP_Layer_Tap_KeyReportsKey" {
    const fixture = setupNoTapping();
    defer teardown(fixture);

    // LT(1, KC_P)
    const lt_key = keycode_mod.LT(1, KC.P);
    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, lt_key),
    });

    // Press → 即座に KC_P が送信される（タッピング判定なし）
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.keyboard_count >= 1);
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.P));

    // Release → 空レポート
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

// LT(1, KC_P) ホールド → KC_P のまま（レイヤー切替なし）
test "NoTapping_LayerTap: HoldP_Layer_Tap_KeyReportsKey" {
    const fixture = setupNoTapping();
    defer teardown(fixture);

    const lt_key = keycode_mod.LT(1, KC.P);
    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, lt_key),
    });

    // Press → 即座に KC_P
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.keyboard_count >= 1);
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.P));

    // TAPPING_TERM 経過しても KC_P のまま（レイヤーに切り替わらない）
    fixture.idleFor(TAPPING_TERM);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.P));

    // Release → 空レポート
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

// ============================================================
// no_action_tapping/test_mod_tap.cpp の移植
// ============================================================

// SFT_T(KC_P) タップ → 即座に KC_P が送信される
test "NoTapping_ModTap: TapA_SHFT_T_KeyReportsKey" {
    const fixture = setupNoTapping();
    defer teardown(fixture);

    // SFT_T(KC_P) = MT(MOD_LSFT, KC_P)
    const sft_t_key = keycode_mod.MT(keycode_mod.Mod.LSFT, KC.P);
    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, sft_t_key),
    });

    // Press → 即座に KC_P
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.keyboard_count >= 1);
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.P));

    // Release → 空レポート
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

// SFT_T(KC_P) ホールド → KC_P のまま（Shiftにならない）
test "NoTapping_ModTap: HoldA_SHFT_T_KeyReportsShift" {
    const fixture = setupNoTapping();
    defer teardown(fixture);

    const sft_t_key = keycode_mod.MT(keycode_mod.Mod.LSFT, KC.P);
    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, sft_t_key),
    });

    // Press → 即座に KC_P
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.keyboard_count >= 1);
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.P));

    // TAPPING_TERM 経過しても KC_P のまま
    fixture.idleFor(TAPPING_TERM);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.P));

    // Release → 空レポート
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

// SFT_T(KC_P) の連続タップ
test "NoTapping_ModTap: ANewTapWithinTappingTermIsBuggy" {
    const fixture = setupNoTapping();
    defer teardown(fixture);

    const sft_t_key = keycode_mod.MT(keycode_mod.Mod.LSFT, KC.P);
    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, sft_t_key),
    });

    // 1st tap
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.P));

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());

    // 2nd tap (within TAPPING_TERM)
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.P));

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());

    fixture.idleFor(TAPPING_TERM + 1);

    // 3rd tap
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.P));

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());

    fixture.idleFor(TAPPING_TERM + 1);

    // 4th tap + hold
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.P));

    fixture.idleFor(TAPPING_TERM);
    // Still KC_P
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.P));

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

// ============================================================
// no_action_tapping/test_one_shot_keys.cpp の移植
// ============================================================

// OSM(MOD_LSFT) → NO_ACTION_TAPPING 時は即座に LSFT が送信される
test "NoTapping_OneShot: OSMWithoutAdditionalKeypressDoesNothing" {
    const fixture = setupNoTapping();
    defer teardown(fixture);

    // OSM(MOD_LSFT)
    const osm_key = keycode_mod.OSM(keycode_mod.Mod.LSFT);
    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, osm_key),
    });

    // Press → 即座に LSFT が送信される（通常モッドとして動作）
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.keyboard_count >= 1);
    try testing.expect(fixture.driver.lastKeyboardReport().mods & report_mod.ModBit.LSHIFT != 0);

    // Release → 空レポート
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

// OSL(1) タップ＋リリース → レイヤー操作のみでレポートなし
// NO_ACTION_TAPPING 時の OSL は MO（layer_on/layer_off）として動作する
// C版: #if !defined(NO_ACTION_ONESHOT) && !defined(NO_ACTION_TAPPING) の else ブランチ
test "NoTapping_OneShot: OSL_No_ReportPress" {
    const fixture = setupNoTapping();
    defer teardown(fixture);

    // OSL(1) at (0,0,0)
    const osl_key = keycode_mod.OSL(1);
    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, osl_key),
    });

    const count_before = fixture.driver.keyboard_count;

    // Press OSL key → NO_ACTION_TAPPING 時は layer_on(1) のみ、レポートなし
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expectEqual(count_before, fixture.driver.keyboard_count);

    // Release OSL key → layer_off(1)、レポートなし
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expectEqual(count_before, fixture.driver.keyboard_count);
}

// OSL(1) ホールド中 → レイヤー操作のみでレポートなし
test "NoTapping_OneShot: OSL_ReportPress" {
    const fixture = setupNoTapping();
    defer teardown(fixture);

    const osl_key = keycode_mod.OSL(1);
    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, osl_key),
    });

    const count_before = fixture.driver.keyboard_count;

    // Press OSL key (hold) → layer_on(1) のみ、レポートなし
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expectEqual(count_before, fixture.driver.keyboard_count);

    // Release OSL key → layer_off(1)、レポートなし
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expectEqual(count_before, fixture.driver.keyboard_count);
}

// ============================================================
// no_mod_tap_mods/test_tapping.cpp の移植
// NO_ACTION_TAPPING + NO_ACTION_TAPPING_MODTAP_MODS
// ============================================================

// SFT_T(KC_P) → 即座に LSFT（モディファイヤとして動作）
test "NoModTapMods: TapA_SHFT_T_KeyReportsKey" {
    const fixture = setupNoModTapMods();
    defer teardown(fixture);

    const sft_t_key = keycode_mod.MT(keycode_mod.Mod.LSFT, KC.P);
    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, sft_t_key),
    });

    // Press → 即座に LSFT
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.keyboard_count >= 1);
    try testing.expect(fixture.driver.lastKeyboardReport().mods & report_mod.ModBit.LSHIFT != 0);

    // Release → 空レポート
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

// SFT_T(KC_P) ホールド → LSFT のまま
test "NoModTapMods: HoldA_SHFT_T_KeyReportsShift" {
    const fixture = setupNoModTapMods();
    defer teardown(fixture);

    const sft_t_key = keycode_mod.MT(keycode_mod.Mod.LSFT, KC.P);
    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, sft_t_key),
    });

    // Press → 即座に LSFT
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.keyboard_count >= 1);
    try testing.expect(fixture.driver.lastKeyboardReport().mods & report_mod.ModBit.LSHIFT != 0);

    // TAPPING_TERM 経過しても LSFT のまま
    fixture.idleFor(TAPPING_TERM);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().mods & report_mod.ModBit.LSHIFT != 0);

    // Release → 空レポート
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

// 連続タップでも LSFT のまま
test "NoModTapMods: ANewTapWithinTappingTermIsBuggy" {
    const fixture = setupNoModTapMods();
    defer teardown(fixture);

    const sft_t_key = keycode_mod.MT(keycode_mod.Mod.LSFT, KC.P);
    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, sft_t_key),
    });

    // 1st tap
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().mods & report_mod.ModBit.LSHIFT != 0);

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());

    // 2nd tap
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().mods & report_mod.ModBit.LSHIFT != 0);

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());

    fixture.idleFor(TAPPING_TERM + 1);

    // 3rd tap
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().mods & report_mod.ModBit.LSHIFT != 0);

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());

    fixture.idleFor(TAPPING_TERM + 1);

    // 4th tap + hold
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().mods & report_mod.ModBit.LSHIFT != 0);

    fixture.idleFor(TAPPING_TERM);

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}
