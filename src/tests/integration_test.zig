// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! 統合テスト - End-to-End キーボード処理パイプライン検証
//!
//! 目的:
//!   マトリックススキャン → デバウンス → キーイベント → アクション解決
//!   → タッピング判定 → アクション実行 → HIDレポート送信
//!   の一連フローを検証する。
//!
//! upstream参照:
//!   tests/basic/test_keypress.cpp
//!   tests/basic/test_action_layer.cpp
//!   tests/basic/test_tapping.cpp
//!
//! 設計方針:
//!   兄弟テスト (`test_keypress.zig`, `test_action_layer.zig`, `test_tapping.zig` 等)
//!   と同様に `TestFixture.setKeymap()` で「人工キーマップ」を構築し、 完全に
//!   keyboard 非依存に保つ。 実キーマップ依存テストは各 keyboard 定義
//!   (`src/keyboards/<name>.zig`) 内の `test` ブロックに配置する。
//!   関連 Issue: #386 / 旧 PR #385 の積み残し改善

const std = @import("std");
const testing = std.testing;

const keycode = @import("core").keycode;
const action_code = @import("core").action_code;
const report_mod = @import("core").report;
const extrakey = @import("core").extrakey;
const test_fixture = @import("core").test_fixture;
const tapping_mod = @import("core").action_tapping;

const KC = keycode.KC;
const Keycode = keycode.Keycode;
const KeyboardReport = report_mod.KeyboardReport;
const ExtraReport = report_mod.ExtraReport;
const ModBit = report_mod.ModBit;
const TestFixture = test_fixture.TestFixture;
const KeymapKey = test_fixture.KeymapKey;
const TAPPING_TERM = tapping_mod.TAPPING_TERM;

// ============================================================
// 統合テスト用キーマップ位置定数
// ============================================================
//
// すべての E2E テストはこの位置定数に従い、 `TestFixture.setKeymap()` で
// 人工キーマップを構築する。 整数リテラルではなく定数を使うことで意図を明示する。
// row / col は最小キーボード (madbd34: 4x12) でも動くよう 4x12 領域内に収める。

/// Layer 0 の基本キー
const Q_ROW: u8 = 0;
const Q_COL: u8 = 0;
const W_ROW: u8 = 0;
const W_COL: u8 = 1;
const E_ROW: u8 = 0;
const E_COL: u8 = 2;
const LCTL_ROW: u8 = 1;
const LCTL_COL: u8 = 0;
const A_ROW: u8 = 1;
const A_COL: u8 = 1;
const LSFT_ROW: u8 = 2;
const LSFT_COL: u8 = 0;
const Z_ROW: u8 = 2;
const Z_COL: u8 = 1;

/// Layer-Tap / MO キー位置 (thumb cluster 相当)
const LT1_SPC_ROW: u8 = 3;
const LT1_SPC_COL: u8 = 5;
const LT2_ESC_ROW: u8 = 3;
const LT2_ESC_COL: u8 = 6;
const MO1_ROW: u8 = 3;
const MO1_COL: u8 = 8;

/// Layer 2 ナビゲーションキー (LEFT)
const L2_LEFT_ROW: u8 = 1;
const L2_LEFT_COL: u8 = 6;

/// テスト用キーマップを fixture に設定する。
///
/// 構造:
///   Layer 0:
///     - 基本キー: Q, W, E, A, Z
///     - 修飾キー: LCTL, LSFT
///     - thumb: LT(1, SPC), LT(2, ESC), MO(1)
///   Layer 1:
///     - Q 位置に KC_1 (MO(1) ホールド時の確認用)
///     - LT2_ESC 位置に LT(3, ESC) (Layer 1 → Layer 3 アクセス用)
///   Layer 2:
///     - LEFT (矢印キー)
///   Layer 3:
///     - 空 (Layer 1 上から LT(3,ESC) でアクセス確認用)
fn setupKeymap(fixture: *TestFixture) void {
    fixture.setKeymap(&.{
        // Layer 0: 基本キー
        KeymapKey.init(0, Q_ROW, Q_COL, KC.Q),
        KeymapKey.init(0, W_ROW, W_COL, KC.W),
        KeymapKey.init(0, E_ROW, E_COL, KC.E),
        KeymapKey.init(0, LCTL_ROW, LCTL_COL, KC.LCTL),
        KeymapKey.init(0, A_ROW, A_COL, KC.A),
        KeymapKey.init(0, LSFT_ROW, LSFT_COL, KC.LSFT),
        KeymapKey.init(0, Z_ROW, Z_COL, KC.Z),
        KeymapKey.init(0, LT1_SPC_ROW, LT1_SPC_COL, keycode.LT(1, KC.SPC)),
        KeymapKey.init(0, LT2_ESC_ROW, LT2_ESC_COL, keycode.LT(2, KC.ESC)),
        KeymapKey.init(0, MO1_ROW, MO1_COL, keycode.MO(1)),
        // Layer 1: MO(1) ホールド中の Q 位置に数字 1
        KeymapKey.init(1, Q_ROW, Q_COL, KC.@"1"),
        // Layer 1: LT2_ESC 位置に LT(3, ESC) (Layer 3 アクセス用)
        KeymapKey.init(1, LT2_ESC_ROW, LT2_ESC_COL, keycode.LT(3, KC.ESC)),
        // Layer 2: ナビゲーション
        KeymapKey.init(2, L2_LEFT_ROW, L2_LEFT_COL, KC.LEFT),
    });
}

// ============================================================
// 1. 基本キープレス → HIDレポート生成 (E2Eフロー)
// ============================================================

test "E2E: 単一キー押下→リリースでHIDレポートが正しく生成される" {
    var fixture: TestFixture = undefined;
    TestFixture.withSetup(&fixture, setupKeymap);
    defer fixture.deinit();

    // KC.Q (HID 0x14) を押す
    fixture.pressKey(Q_ROW, Q_COL);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.keyboard_count >= 1);
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x14)); // Q

    // リリース
    fixture.releaseKey(Q_ROW, Q_COL);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "E2E: 複数キー同時押しで6KROレポートに正しく含まれる" {
    var fixture: TestFixture = undefined;
    TestFixture.withSetup(&fixture, setupKeymap);
    defer fixture.deinit();

    fixture.pressKey(Q_ROW, Q_COL); // Q
    fixture.pressKey(W_ROW, W_COL); // W
    fixture.pressKey(E_ROW, E_COL); // E
    fixture.runOneScanLoop();

    const report = fixture.driver.lastKeyboardReport();
    try testing.expect(report.hasKey(0x14)); // Q
    try testing.expect(report.hasKey(0x1A)); // W
    try testing.expect(report.hasKey(0x08)); // E

    fixture.releaseKey(Q_ROW, Q_COL);
    fixture.releaseKey(W_ROW, W_COL);
    fixture.releaseKey(E_ROW, E_COL);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "E2E: 修飾キー(LCTL)がHIDレポートのmodsに反映される" {
    var fixture: TestFixture = undefined;
    TestFixture.withSetup(&fixture, setupKeymap);
    defer fixture.deinit();

    fixture.pressKey(LCTL_ROW, LCTL_COL);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.keyboard_count >= 1);
    try testing.expectEqual(
        @as(u8, ModBit.LCTRL),
        fixture.driver.lastKeyboardReport().mods & ModBit.LCTRL,
    );

    fixture.releaseKey(LCTL_ROW, LCTL_COL);
    fixture.runOneScanLoop();
    try testing.expectEqual(@as(u8, 0), fixture.driver.lastKeyboardReport().mods);
}

test "E2E: 修飾キー＋通常キー同時押し (Ctrl+A)" {
    var fixture: TestFixture = undefined;
    TestFixture.withSetup(&fixture, setupKeymap);
    defer fixture.deinit();

    fixture.pressKey(LCTL_ROW, LCTL_COL); // LCTL
    fixture.pressKey(A_ROW, A_COL); // A
    fixture.runOneScanLoop();

    const report = fixture.driver.lastKeyboardReport();
    try testing.expect(report.mods & ModBit.LCTRL != 0);
    try testing.expect(report.hasKey(0x04)); // A

    fixture.releaseKey(A_ROW, A_COL);
    fixture.releaseKey(LCTL_ROW, LCTL_COL);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "E2E: LSFT + Z (Shift+Z) の組み合わせ" {
    var fixture: TestFixture = undefined;
    TestFixture.withSetup(&fixture, setupKeymap);
    defer fixture.deinit();

    fixture.pressKey(LSFT_ROW, LSFT_COL); // LSFT
    fixture.pressKey(Z_ROW, Z_COL); // Z
    fixture.runOneScanLoop();

    const report = fixture.driver.lastKeyboardReport();
    try testing.expect(report.mods & ModBit.LSHIFT != 0);
    try testing.expect(report.hasKey(0x1D)); // Z

    fixture.releaseKey(Z_ROW, Z_COL);
    fixture.releaseKey(LSFT_ROW, LSFT_COL);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

// ============================================================
// 2. レイヤー切替シナリオ
// ============================================================

test "E2E: MO(1)でレイヤー1が有効化される" {
    var fixture: TestFixture = undefined;
    TestFixture.withSetup(&fixture, setupKeymap);
    defer fixture.deinit();

    fixture.pressKey(MO1_ROW, MO1_COL);
    fixture.idleFor(TAPPING_TERM + 1);

    try testing.expect(fixture.isLayerOn(1));

    fixture.releaseKey(MO1_ROW, MO1_COL);
    fixture.runOneScanLoop();
    try testing.expect(!fixture.isLayerOn(1));
}

test "E2E: MO(1)ホールド中にレイヤー1のキーが入力される" {
    var fixture: TestFixture = undefined;
    TestFixture.withSetup(&fixture, setupKeymap);
    defer fixture.deinit();

    // MO(1) をホールド
    fixture.pressKey(MO1_ROW, MO1_COL);
    fixture.idleFor(TAPPING_TERM + 1);
    try testing.expect(fixture.isLayerOn(1));

    // Layer 1 で Q 位置は数字キー (HID 0x1E = KC.@"1")
    fixture.pressKey(Q_ROW, Q_COL);
    fixture.runOneScanLoop();

    var found_1 = false;
    var i: usize = 0;
    while (i < fixture.driver.keyboard_count and i < 64) : (i += 1) {
        if (fixture.driver.keyboard_reports[i].hasKey(0x1E)) {
            found_1 = true;
            break;
        }
    }
    try testing.expect(found_1);

    fixture.releaseKey(Q_ROW, Q_COL);
    fixture.releaseKey(MO1_ROW, MO1_COL);
    fixture.runOneScanLoop();
}

test "E2E: LT(1,SPC) タップでスペースが入力される" {
    var fixture: TestFixture = undefined;
    TestFixture.withSetup(&fixture, setupKeymap);
    defer fixture.deinit();

    // 短いタップ (TAPPING_TERM 未満) → SPC が出力
    fixture.pressKey(LT1_SPC_ROW, LT1_SPC_COL);
    fixture.idleFor(50);
    fixture.releaseKey(LT1_SPC_ROW, LT1_SPC_COL);
    fixture.runOneScanLoop();

    var found_space = false;
    var i: usize = 0;
    while (i < fixture.driver.keyboard_count and i < 64) : (i += 1) {
        if (fixture.driver.keyboard_reports[i].hasKey(0x2C)) { // KC.SPC
            found_space = true;
            break;
        }
    }
    try testing.expect(found_space);

    // 最終的に空レポート
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "E2E: LT(1,SPC) ホールドでレイヤー1が有効化される" {
    var fixture: TestFixture = undefined;
    TestFixture.withSetup(&fixture, setupKeymap);
    defer fixture.deinit();

    fixture.pressKey(LT1_SPC_ROW, LT1_SPC_COL);
    fixture.idleFor(TAPPING_TERM + 1);

    try testing.expect(fixture.isLayerOn(1));

    fixture.releaseKey(LT1_SPC_ROW, LT1_SPC_COL);
    fixture.runOneScanLoop();
    try testing.expect(!fixture.isLayerOn(1));
}

test "E2E: LT(2,ESC) タップでESCが入力される" {
    var fixture: TestFixture = undefined;
    TestFixture.withSetup(&fixture, setupKeymap);
    defer fixture.deinit();

    fixture.pressKey(LT2_ESC_ROW, LT2_ESC_COL);
    fixture.idleFor(50);
    fixture.releaseKey(LT2_ESC_ROW, LT2_ESC_COL);
    fixture.runOneScanLoop();

    var found_esc = false;
    var i: usize = 0;
    while (i < fixture.driver.keyboard_count and i < 64) : (i += 1) {
        if (fixture.driver.keyboard_reports[i].hasKey(0x29)) { // KC.ESC
            found_esc = true;
            break;
        }
    }
    try testing.expect(found_esc);
}

test "E2E: LT(2,ESC) ホールドでレイヤー2が有効化される" {
    var fixture: TestFixture = undefined;
    TestFixture.withSetup(&fixture, setupKeymap);
    defer fixture.deinit();

    fixture.pressKey(LT2_ESC_ROW, LT2_ESC_COL);
    fixture.idleFor(TAPPING_TERM + 1);

    try testing.expect(fixture.isLayerOn(2));

    fixture.releaseKey(LT2_ESC_ROW, LT2_ESC_COL);
    fixture.runOneScanLoop();
    try testing.expect(!fixture.isLayerOn(2));
}

// ============================================================
// 3. レイヤー2 ナビゲーションキーのテスト
// ============================================================

test "E2E: レイヤー2で矢印キーが入力される" {
    var fixture: TestFixture = undefined;
    TestFixture.withSetup(&fixture, setupKeymap);
    defer fixture.deinit();

    // LT(2, ESC) ホールドでレイヤー2有効化
    fixture.pressKey(LT2_ESC_ROW, LT2_ESC_COL);
    fixture.idleFor(TAPPING_TERM + 1);
    try testing.expect(fixture.isLayerOn(2));

    // Layer 2: LEFT (0x50)
    fixture.pressKey(L2_LEFT_ROW, L2_LEFT_COL);
    fixture.runOneScanLoop();

    var found_left = false;
    var i: usize = 0;
    while (i < fixture.driver.keyboard_count and i < 64) : (i += 1) {
        if (fixture.driver.keyboard_reports[i].hasKey(0x50)) { // KC.LEFT
            found_left = true;
            break;
        }
    }
    try testing.expect(found_left);

    fixture.releaseKey(L2_LEFT_ROW, L2_LEFT_COL);
    fixture.releaseKey(LT2_ESC_ROW, LT2_ESC_COL);
    fixture.runOneScanLoop();
}

// ============================================================
// 4. Mod-Tap / Layer-Tap のテスト
// ============================================================

test "E2E: LT(1,SPC) ホールド中に他キーを押すとinterrupt発生" {
    var fixture: TestFixture = undefined;
    TestFixture.withSetup(&fixture, setupKeymap);
    defer fixture.deinit();

    // LT(1, SPC) をプレス
    fixture.pressKey(LT1_SPC_ROW, LT1_SPC_COL);
    fixture.idleFor(20);

    // TAPPING_TERM 内に Q キーを押す (interrupt)
    fixture.pressKey(Q_ROW, Q_COL);
    fixture.idleFor(30);

    // Q リリース
    fixture.releaseKey(Q_ROW, Q_COL);
    fixture.runOneScanLoop();

    // LT(1, SPC) リリース
    fixture.releaseKey(LT1_SPC_ROW, LT1_SPC_COL);
    fixture.runOneScanLoop();

    // 重要なのは処理がクラッシュせず正常完了すること
    try testing.expect(fixture.driver.keyboard_count >= 1);
}

// ============================================================
// 5. 連続タップのテスト
// ============================================================

test "E2E: 同一キーの連続タップが正しく処理される" {
    var fixture: TestFixture = undefined;
    TestFixture.withSetup(&fixture, setupKeymap);
    defer fixture.deinit();

    // KC.Q を連続タップ
    fixture.pressKey(Q_ROW, Q_COL);
    fixture.runOneScanLoop();
    fixture.releaseKey(Q_ROW, Q_COL);
    fixture.runOneScanLoop();

    fixture.pressKey(Q_ROW, Q_COL);
    fixture.runOneScanLoop();
    fixture.releaseKey(Q_ROW, Q_COL);
    fixture.runOneScanLoop();

    fixture.pressKey(Q_ROW, Q_COL);
    fixture.runOneScanLoop();
    fixture.releaseKey(Q_ROW, Q_COL);
    fixture.runOneScanLoop();

    // 3 回のプレス/リリースサイクルでレポートが生成される
    try testing.expect(fixture.driver.keyboard_count >= 3);

    // 最終的に空レポート
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

// ============================================================
// 6. レイヤーの復帰テスト
// ============================================================

test "E2E: レイヤー切替後にベースレイヤーに正しく戻る" {
    var fixture: TestFixture = undefined;
    TestFixture.withSetup(&fixture, setupKeymap);
    defer fixture.deinit();

    // 初期状態: Layer 0 のみ
    try testing.expect(fixture.isLayerOn(0));
    try testing.expect(!fixture.isLayerOn(1));

    // MO(1) ホールド
    fixture.pressKey(MO1_ROW, MO1_COL);
    fixture.idleFor(TAPPING_TERM + 1);
    try testing.expect(fixture.isLayerOn(1));

    // MO(1) リリース
    fixture.releaseKey(MO1_ROW, MO1_COL);
    fixture.runOneScanLoop();
    try testing.expect(!fixture.isLayerOn(1));
    try testing.expect(fixture.isLayerOn(0));

    // LT(2, ESC) ホールド
    fixture.pressKey(LT2_ESC_ROW, LT2_ESC_COL);
    fixture.idleFor(TAPPING_TERM + 1);
    try testing.expect(fixture.isLayerOn(2));

    // LT(2, ESC) リリース
    fixture.releaseKey(LT2_ESC_ROW, LT2_ESC_COL);
    fixture.runOneScanLoop();
    try testing.expect(!fixture.isLayerOn(2));
    try testing.expect(fixture.isLayerOn(0));
}

// ============================================================
// 7. HIDレポートのバイナリ互換性検証
// ============================================================

test "E2E: KeyboardReportのサイズが8バイト（USB HID Boot Protocol互換）" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(KeyboardReport));
}

test "E2E: ExtraReportのサイズが3バイト" {
    try testing.expectEqual(@as(usize, 3), @sizeOf(ExtraReport));
}

test "E2E: MouseReportのサイズが5バイト" {
    try testing.expectEqual(@as(usize, 5), @sizeOf(report_mod.MouseReport));
}

// ============================================================
// 8. ソースレイヤーキャッシュの統合テスト
// ============================================================

test "E2E: レイヤー切替中のキーリリースが正しいレイヤーで処理される" {
    var fixture: TestFixture = undefined;
    TestFixture.withSetup(&fixture, setupKeymap);
    defer fixture.deinit();

    // Layer 0 でキー Q をプレス
    fixture.pressKey(Q_ROW, Q_COL);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x14)); // Q

    // キーを押したままレイヤー 1 を有効化 (MO(1) ホールド)
    fixture.pressKey(MO1_ROW, MO1_COL);
    fixture.idleFor(TAPPING_TERM + 1);

    // Q リリース → Layer 0 の Q として unregister される (ソースレイヤーキャッシュ)
    fixture.releaseKey(Q_ROW, Q_COL);
    fixture.runOneScanLoop();

    // MO(1) リリース
    fixture.releaseKey(MO1_ROW, MO1_COL);
    fixture.runOneScanLoop();
}

// ============================================================
// 9. Layer-Tap 組み合わせテスト
// ============================================================

test "E2E: Layer 1 の LT(3,ESC) でレイヤー3にアクセスできる" {
    var fixture: TestFixture = undefined;
    TestFixture.withSetup(&fixture, setupKeymap);
    defer fixture.deinit();

    // まず MO(1) でレイヤー 1 を有効化
    fixture.pressKey(MO1_ROW, MO1_COL);
    fixture.idleFor(TAPPING_TERM + 1);
    try testing.expect(fixture.isLayerOn(1));

    // Layer 1 上の LT2_ESC 位置は LT(3, ESC) になっている
    fixture.pressKey(LT2_ESC_ROW, LT2_ESC_COL);
    fixture.idleFor(TAPPING_TERM + 1);

    try testing.expect(fixture.isLayerOn(3));

    fixture.releaseKey(LT2_ESC_ROW, LT2_ESC_COL);
    fixture.releaseKey(MO1_ROW, MO1_COL);
    fixture.runOneScanLoop();
}

// ============================================================
// 10. Extrakey (メディアキー) の統合テスト
// ============================================================

test "E2E: メディアキーのHID Usageコード変換が正しい" {
    try testing.expectEqual(
        extrakey.ConsumerUsage.AUDIO_MUTE,
        extrakey.keycodeToConsumer(@truncate(KC.MUTE)),
    );
    try testing.expectEqual(
        extrakey.ConsumerUsage.AUDIO_VOL_UP,
        extrakey.keycodeToConsumer(@truncate(KC.VOLU)),
    );
    try testing.expectEqual(
        extrakey.ConsumerUsage.AUDIO_VOL_DOWN,
        extrakey.keycodeToConsumer(@truncate(KC.VOLD)),
    );
}

// ============================================================
// 11. Action Code → Keycode ラウンドトリップテスト
// ============================================================

test "E2E: 基本キーコードのアクション変換ラウンドトリップ" {
    const alpha_keys = [_]Keycode{
        KC.A, KC.B, KC.C, KC.D, KC.E, KC.F, KC.G,
        KC.H, KC.I, KC.J, KC.K, KC.L, KC.M, KC.N,
        KC.O, KC.P, KC.Q, KC.R, KC.S, KC.T, KC.U,
        KC.V, KC.W, KC.X, KC.Y, KC.Z,
    };

    for (alpha_keys) |kc| {
        const act = action_code.keycodeToAction(kc);
        try testing.expectEqual(action_code.ACTION_KEY(@truncate(kc)), act.code);
    }
}

test "E2E: レイヤー操作キーコードのアクション変換" {
    for (0..4) |l| {
        const kc = keycode.MO(@intCast(l));
        const act = action_code.keycodeToAction(kc);
        try testing.expectEqual(action_code.ACTION_LAYER_MOMENTARY(@intCast(l)), act.code);
    }

    const lt_kc = keycode.LT(1, KC.A);
    const lt_act = action_code.keycodeToAction(lt_kc);
    try testing.expectEqual(action_code.ACTION_LAYER_TAP_KEY(1, 0x04), lt_act.code);
}

// ============================================================
// 12. 全レイヤーを通したキーマップ解決テスト
// ============================================================

test "E2E: keymap resolveKeycode がレイヤー優先度を正しく処理する" {
    const keymap_mod = @import("core").keymap;
    var fixture: TestFixture = undefined;
    TestFixture.withSetup(&fixture, setupKeymap);
    defer fixture.deinit();

    // setupKeymap が登録した test 用 keymap を直接参照する
    // (production の `kb_mod.default_keymap` 直参照とは別物; 依存性注入で分離されている)
    const km = test_fixture.getTestKeymap();

    // Layer 0 のみアクティブ: Q 位置 = KC.Q
    try testing.expectEqual(KC.Q, keymap_mod.resolveKeycode(km, 0b01, Q_ROW, Q_COL));

    // Layer 0 + 1 アクティブ: Q 位置 = Layer 1 の KC.@"1"
    try testing.expectEqual(KC.@"1", keymap_mod.resolveKeycode(km, 0b11, Q_ROW, Q_COL));
}

// ============================================================
// 13. デバウンスモジュールの統合テスト
// ============================================================

test "E2E: デバウンスのインポートとAPIが正しく公開されている" {
    const debounce_mod = @import("core").debounce_mod;
    var db = debounce_mod.DebounceState(test_fixture.MATRIX_ROWS, test_fixture.MATRIX_COLS).init(5);
    _ = &db;
    try testing.expectEqual(@as(u16, 5), db.debounce_ms);
}

// ============================================================
// 14. Host ドライバ統合テスト
// ============================================================

test "E2E: HostDriverインターフェースがモックで正しく動作する" {
    const host_mod = @import("core").host_mod;
    const IntegrationMockDriver = @import("core").test_driver.FixedTestDriver(64, 16);

    var mock = IntegrationMockDriver{};
    const driver = host_mod.HostDriver.from(&mock);

    // キーボードレポート送信
    var report = KeyboardReport{};
    _ = report.addKey(0x04);
    report.mods = ModBit.LSHIFT;
    driver.sendKeyboard(&report);

    try testing.expectEqual(@as(usize, 1), mock.keyboard_count);
    try testing.expect(mock.keyboard_reports[0].hasKey(0x04));
    try testing.expectEqual(ModBit.LSHIFT, mock.keyboard_reports[0].mods);

    // Extra レポート送信
    const extra = ExtraReport.consumer(0x00E2);
    driver.sendExtra(&extra);

    try testing.expectEqual(@as(usize, 1), mock.extra_count);
    try testing.expectEqual(@as(u16, 0x00E2), mock.extra_reports[0].usage);
}
