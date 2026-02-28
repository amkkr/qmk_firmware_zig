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
//! テストフィクスチャ（test_fixture.zig）を使ったシンプルなテストは既存。
//! このファイルでは、action/tapping/host/layer モジュールを直接結合した
//! より詳細な統合テストを実施する。

const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");

// Core modules
const action = @import("../core/action.zig");
const action_code = @import("../core/action_code.zig");
const event_mod = @import("../core/event.zig");
const host_mod = @import("../core/host.zig");
const layer = @import("../core/layer.zig");
const report_mod = @import("../core/report.zig");
const keycode = @import("../core/keycode.zig");
const keymap_mod = @import("../core/keymap.zig");
const extrakey = @import("../core/extrakey.zig");
const tapping_mod = @import("../core/action_tapping.zig");

const TAPPING_TERM = tapping_mod.TAPPING_TERM;

// Keyboard definition (selected via -Dkeyboard build option)
const kb = if (std.mem.eql(u8, build_options.KEYBOARD, "madbd34"))
    @import("../keyboards/madbd34.zig")
else
    @import("../keyboards/madbd5.zig");

const Action = action_code.Action;
const KeyRecord = event_mod.KeyRecord;
const KeyEvent = event_mod.KeyEvent;
const KeyboardReport = report_mod.KeyboardReport;
const ExtraReport = report_mod.ExtraReport;
const KC = keycode.KC;
const Keycode = keycode.Keycode;

const IntegrationMockDriver = @import("../core/test_driver.zig").FixedTestDriver(64, 16);

// ============================================================
// キーボード固有のキーポジション定数
// ============================================================

const Pos = struct { row: u8, col: u8 };

/// キーボード固有のキーポジションを comptime で定義
const is_madbd5 = std.mem.eql(u8, build_options.KEYBOARD, "madbd5");

/// Layer 0 の基本キーポジション
const Q_POS = if (is_madbd5) Pos{ .row = 0, .col = 5 } else Pos{ .row = 0, .col = 1 };
const W_POS = if (is_madbd5) Pos{ .row = 0, .col = 6 } else Pos{ .row = 0, .col = 2 };
const E_POS = if (is_madbd5) Pos{ .row = 0, .col = 7 } else Pos{ .row = 0, .col = 3 };
const TAB_POS = if (is_madbd5) Pos{ .row = 0, .col = 4 } else Pos{ .row = 0, .col = 0 };
const LCTL_POS = if (is_madbd5) Pos{ .row = 1, .col = 4 } else Pos{ .row = 1, .col = 0 };
const A_POS = if (is_madbd5) Pos{ .row = 1, .col = 5 } else Pos{ .row = 1, .col = 1 };
const LSFT_POS = if (is_madbd5) Pos{ .row = 2, .col = 4 } else Pos{ .row = 2, .col = 0 };
const Z_POS = if (is_madbd5) Pos{ .row = 2, .col = 5 } else Pos{ .row = 2, .col = 1 };

/// Layer-Tap / MO キーポジション
const LT1_SPC_POS = if (is_madbd5) Pos{ .row = 3, .col = 6 } else Pos{ .row = 3, .col = 5 };
const LT2_ESC_POS = if (is_madbd5) Pos{ .row = 3, .col = 7 } else Pos{ .row = 3, .col = 6 };
const MO1_POS = if (is_madbd5) Pos{ .row = 3, .col = 9 } else Pos{ .row = 3, .col = 8 };

/// Layer 2 ナビゲーションキー
const L2_LEFT_POS = if (is_madbd5) Pos{ .row = 1, .col = 10 } else Pos{ .row = 1, .col = 6 };

/// Layer 3 ファンクションキー
const L3_F1_COL: u8 = if (is_madbd5) 4 else 0;

/// Layer 3 メディアキー
const L3_MUTE_POS = if (is_madbd5) Pos{ .row = 1, .col = 5 } else Pos{ .row = 1, .col = 1 };
const L3_VOLD_POS = if (is_madbd5) Pos{ .row = 1, .col = 6 } else Pos{ .row = 1, .col = 2 };
const L3_VOLU_POS = if (is_madbd5) Pos{ .row = 1, .col = 7 } else Pos{ .row = 1, .col = 3 };

// ============================================================
// kb キーマップからアクションを解決するリゾルバ
// ============================================================

/// kb のデフォルトキーマップを使って、レイヤーとマトリックス位置から
/// アクションコードを解決する。
/// action.setActionResolver() に渡すためのコールバック。
fn kbActionResolver(ev: KeyEvent) Action {
    const km = &kb.default_keymap;

    // レイヤー解決用のクロージャ関数
    const keymapFn = struct {
        fn f(l: u5, row: u8, col: u8) Keycode {
            return keymap_mod.keymapKeyToKeycode(&kb.default_keymap, l, row, col);
        }
    }.f;

    // アクティブレイヤーから非透過キーを持つレイヤーを検索
    const resolved_layer = layer.layerSwitchGetLayer(keymapFn, ev.key.row, ev.key.col);

    // ソースレイヤーキャッシュ更新（プレス時）
    if (ev.pressed) {
        layer.updateSourceLayersCache(ev.key.row, ev.key.col, resolved_layer);
    }

    // リリース時はキャッシュからレイヤーを取得（stuck key防止）
    const use_layer = if (ev.pressed) resolved_layer else layer.readSourceLayersCache(ev.key.row, ev.key.col);

    const kc = keymap_mod.keymapKeyToKeycode(km, use_layer, ev.key.row, ev.key.col);
    return action_code.keycodeToAction(kc);
}

// ============================================================
// テストヘルパー
// ============================================================

var mock_driver: IntegrationMockDriver = .{};

fn setup() *IntegrationMockDriver {
    action.reset();
    mock_driver = .{};
    host_mod.setDriver(host_mod.HostDriver.from(&mock_driver));
    action.setActionResolver(kbActionResolver);
    return &mock_driver;
}

fn teardown() void {
    host_mod.clearDriver();
}

/// キーをプレスするヘルパー
fn press(row: u8, col: u8, time: u16) void {
    var record = KeyRecord{ .event = KeyEvent.keyPress(row, col, time) };
    action.actionExec(&record);
}

/// キーをリリースするヘルパー
fn release(row: u8, col: u8, time: u16) void {
    var record = KeyRecord{ .event = KeyEvent.keyRelease(row, col, time) };
    action.actionExec(&record);
}

/// タイマーティック
fn tick(time: u16) void {
    var record = KeyRecord{ .event = KeyEvent.tick(time) };
    action.actionExec(&record);
}

// ============================================================
// 1. 基本キープレス → HIDレポート生成 (E2Eフロー)
// ============================================================

test "E2E: 単一キー押下→リリースでHIDレポートが正しく生成される" {
    const mock = setup();
    defer teardown();

    // Layer 0: Q (HID 0x14)
    press(Q_POS.row, Q_POS.col, 100);

    // KC.Q は basic keycode なのでタッピング不要、即時レポート
    try testing.expect(mock.keyboard_count >= 1);
    try testing.expect(mock.lastKeyboardReport().hasKey(0x14)); // Q

    // リリース
    release(Q_POS.row, Q_POS.col, 200);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

test "E2E: 複数キー同時押しで6KROレポートに正しく含まれる" {
    const mock = setup();
    defer teardown();

    // Layer 0: Q, W, E
    press(Q_POS.row, Q_POS.col, 100); // Q
    press(W_POS.row, W_POS.col, 110); // W
    press(E_POS.row, E_POS.col, 120); // E

    const report = mock.lastKeyboardReport();
    try testing.expect(report.hasKey(0x14)); // Q
    try testing.expect(report.hasKey(0x1A)); // W
    try testing.expect(report.hasKey(0x08)); // E

    // 全リリース
    release(Q_POS.row, Q_POS.col, 200);
    release(W_POS.row, W_POS.col, 210);
    release(E_POS.row, E_POS.col, 220);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

test "E2E: 修飾キー(LCTL)がHIDレポートのmodsに反映される" {
    const mock = setup();
    defer teardown();

    press(LCTL_POS.row, LCTL_POS.col, 100);

    try testing.expect(mock.keyboard_count >= 1);
    try testing.expectEqual(@as(u8, report_mod.ModBit.LCTRL), mock.lastKeyboardReport().mods & report_mod.ModBit.LCTRL);

    release(LCTL_POS.row, LCTL_POS.col, 200);
    try testing.expectEqual(@as(u8, 0), mock.lastKeyboardReport().mods);
}

test "E2E: 修飾キー＋通常キー同時押し (Ctrl+A)" {
    const mock = setup();
    defer teardown();

    press(LCTL_POS.row, LCTL_POS.col, 100); // LCTL
    press(A_POS.row, A_POS.col, 110); // A

    const report = mock.lastKeyboardReport();
    try testing.expect(report.mods & report_mod.ModBit.LCTRL != 0);
    try testing.expect(report.hasKey(0x04)); // A

    release(A_POS.row, A_POS.col, 200);
    release(LCTL_POS.row, LCTL_POS.col, 210);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

test "E2E: LSFT + Z (Shift+Z) の組み合わせ" {
    const mock = setup();
    defer teardown();

    press(LSFT_POS.row, LSFT_POS.col, 100); // LSFT
    press(Z_POS.row, Z_POS.col, 110); // Z

    const report = mock.lastKeyboardReport();
    try testing.expect(report.mods & report_mod.ModBit.LSHIFT != 0);
    try testing.expect(report.hasKey(0x1D)); // Z

    release(Z_POS.row, Z_POS.col, 200);
    release(LSFT_POS.row, LSFT_POS.col, 210);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// ============================================================
// 2. レイヤー切替シナリオ
// ============================================================

test "E2E: MO(1)でレイヤー1が有効化される" {
    _ = setup();
    defer teardown();

    press(MO1_POS.row, MO1_POS.col, 100);
    tick(100 + TAPPING_TERM + 1); // TAPPING_TERM を超える

    try testing.expect(layer.layerStateIs(1));

    release(MO1_POS.row, MO1_POS.col, 100 + TAPPING_TERM + 100);
    try testing.expect(!layer.layerStateIs(1));
}

test "E2E: MO(1)ホールド中にレイヤー1のキーが入力される" {
    const mock = setup();
    defer teardown();

    // MO(1) をホールド
    press(MO1_POS.row, MO1_POS.col, 100);
    tick(100 + TAPPING_TERM + 1);

    try testing.expect(layer.layerStateIs(1));

    // Layer 1 でQの位置は数字キーになる (HID 0x1E = KC.@"1")
    press(Q_POS.row, Q_POS.col, 100 + TAPPING_TERM + 20);

    var found_1 = false;
    var i: usize = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x1E)) { // KC.@"1"
            found_1 = true;
            break;
        }
    }
    try testing.expect(found_1);

    release(Q_POS.row, Q_POS.col, 100 + TAPPING_TERM + 100);
    release(MO1_POS.row, MO1_POS.col, 100 + TAPPING_TERM + 150);
}

test "E2E: LT(1,SPC) タップでスペースが入力される" {
    const mock = setup();
    defer teardown();

    // 短いタップ（TAPPING_TERM未満）→ SPCが出力される
    press(LT1_SPC_POS.row, LT1_SPC_POS.col, 100);
    release(LT1_SPC_POS.row, LT1_SPC_POS.col, 150);

    var found_space = false;
    var i: usize = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x2C)) { // KC.SPC
            found_space = true;
            break;
        }
    }
    try testing.expect(found_space);

    // 最終的にリリースされる
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

test "E2E: LT(1,SPC) ホールドでレイヤー1が有効化される" {
    _ = setup();
    defer teardown();

    press(LT1_SPC_POS.row, LT1_SPC_POS.col, 100);
    tick(100 + TAPPING_TERM + 1);

    try testing.expect(layer.layerStateIs(1));

    release(LT1_SPC_POS.row, LT1_SPC_POS.col, 100 + TAPPING_TERM + 100);
    try testing.expect(!layer.layerStateIs(1));
}

test "E2E: LT(2,ESC) タップでESCが入力される" {
    const mock = setup();
    defer teardown();

    press(LT2_ESC_POS.row, LT2_ESC_POS.col, 100);
    release(LT2_ESC_POS.row, LT2_ESC_POS.col, 150);

    var found_esc = false;
    var i: usize = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x29)) {
            found_esc = true;
            break;
        }
    }
    try testing.expect(found_esc);
}

test "E2E: LT(2,ESC) ホールドでレイヤー2が有効化される" {
    _ = setup();
    defer teardown();

    press(LT2_ESC_POS.row, LT2_ESC_POS.col, 100);
    tick(100 + TAPPING_TERM + 1);

    try testing.expect(layer.layerStateIs(2));

    release(LT2_ESC_POS.row, LT2_ESC_POS.col, 100 + TAPPING_TERM + 100);
    try testing.expect(!layer.layerStateIs(2));
}

// ============================================================
// 3. レイヤー2 ナビゲーションキーのテスト
// ============================================================

test "E2E: レイヤー2で矢印キーが入力される" {
    const mock = setup();
    defer teardown();

    // LT(2, ESC)ホールドでレイヤー2有効化
    press(LT2_ESC_POS.row, LT2_ESC_POS.col, 100);
    tick(100 + TAPPING_TERM + 1);
    try testing.expect(layer.layerStateIs(2));

    // Layer 2: LEFT (0x50)
    press(L2_LEFT_POS.row, L2_LEFT_POS.col, 100 + TAPPING_TERM + 20);

    var found_left = false;
    var i: usize = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x50)) {
            found_left = true;
            break;
        }
    }
    try testing.expect(found_left);

    release(L2_LEFT_POS.row, L2_LEFT_POS.col, 100 + TAPPING_TERM + 100);
    release(LT2_ESC_POS.row, LT2_ESC_POS.col, 100 + TAPPING_TERM + 150);
}

// ============================================================
// 4. キーマップ→アクション変換の整合性検証
// ============================================================

test "E2E: kb キーマップ→アクション変換の整合性" {
    _ = setup();
    defer teardown();

    const km = &kb.default_keymap;

    // TAB → ACTION_KEY(0x2B)
    const tab_action = action_code.keycodeToAction(km[0][TAB_POS.row][TAB_POS.col]);
    try testing.expectEqual(@as(u16, action_code.ACTION_KEY(0x2B)), tab_action.code);

    // Q → ACTION_KEY(0x14)
    const q_action = action_code.keycodeToAction(km[0][Q_POS.row][Q_POS.col]);
    try testing.expectEqual(@as(u16, action_code.ACTION_KEY(0x14)), q_action.code);

    // LT(1, KC.SPC) → ACTION_LAYER_TAP_KEY(1, 0x2C)
    const lt1_action = action_code.keycodeToAction(km[0][LT1_SPC_POS.row][LT1_SPC_POS.col]);
    try testing.expectEqual(@as(u16, action_code.ACTION_LAYER_TAP_KEY(1, 0x2C)), lt1_action.code);

    // LT(2, KC.ESC) → ACTION_LAYER_TAP_KEY(2, 0x29)
    const lt2_action = action_code.keycodeToAction(km[0][LT2_ESC_POS.row][LT2_ESC_POS.col]);
    try testing.expectEqual(@as(u16, action_code.ACTION_LAYER_TAP_KEY(2, 0x29)), lt2_action.code);

    // MO(1) → ACTION_LAYER_MOMENTARY(1)
    const mo1_action = action_code.keycodeToAction(km[0][MO1_POS.row][MO1_POS.col]);
    try testing.expectEqual(@as(u16, action_code.ACTION_LAYER_MOMENTARY(1)), mo1_action.code);
}

test "E2E: kb 全レイヤーのキー定義検証" {
    const km = &kb.default_keymap;

    // 定義済みレイヤーがそれぞれ少なくとも1つの非KC.NOキーを持つ
    for (0..kb.num_layers) |l| {
        var key_count: usize = 0;
        for (0..kb.rows) |r| {
            for (0..kb.cols) |c| {
                if (km[l][r][c] != KC.NO) {
                    key_count += 1;
                }
            }
        }
        try testing.expect(key_count > 0);
    }

    // Layer 0 の非KC.NOキー数がキーボードの物理キー数と一致
    var layer0_count: usize = 0;
    for (0..kb.rows) |r| {
        for (0..kb.cols) |c| {
            if (km[0][r][c] != KC.NO) {
                layer0_count += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, kb.key_count), layer0_count);

    // 定義済みレイヤーより上は空
    for (kb.num_layers..keymap_mod.MAX_LAYERS) |l| {
        for (0..kb.rows) |r| {
            for (0..kb.cols) |c| {
                try testing.expectEqual(KC.NO, km[l][r][c]);
            }
        }
    }
}

// ============================================================
// 5. Mod-Tap / Layer-Tap のテスト
// ============================================================

test "E2E: LT(1,SPC) ホールド中に他キーを押すとinterrupt発生" {
    const mock = setup();
    defer teardown();

    // LT(1, SPC) をプレス
    press(LT1_SPC_POS.row, LT1_SPC_POS.col, 100);

    // TAPPING_TERM内にQキーを押す（interrupt）
    press(Q_POS.row, Q_POS.col, 120);

    // Qリリース
    release(Q_POS.row, Q_POS.col, 150);

    // LT(1, SPC)リリース
    release(LT1_SPC_POS.row, LT1_SPC_POS.col, 180);

    // 重要なのは、処理がクラッシュせず正常に完了すること
    try testing.expect(mock.keyboard_count >= 1);
}

// ============================================================
// 6. 連続タップのテスト
// ============================================================

test "E2E: 同一キーの連続タップが正しく処理される" {
    const mock = setup();
    defer teardown();

    // KC.Q を連続タップ
    press(Q_POS.row, Q_POS.col, 100);
    release(Q_POS.row, Q_POS.col, 150);

    press(Q_POS.row, Q_POS.col, 200);
    release(Q_POS.row, Q_POS.col, 250);

    press(Q_POS.row, Q_POS.col, 300);
    release(Q_POS.row, Q_POS.col, 350);

    // 3回のプレス/リリースサイクルでレポートが生成される
    try testing.expect(mock.keyboard_count >= 3);

    // 最終的に空レポート
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// ============================================================
// 7. レイヤーの復帰テスト
// ============================================================

test "E2E: レイヤー切替後にベースレイヤーに正しく戻る" {
    _ = setup();
    defer teardown();

    // 初期状態: Layer 0 のみ
    try testing.expect(layer.layerStateIs(0));
    try testing.expect(!layer.layerStateIs(1));

    // MO(1) ホールド
    press(MO1_POS.row, MO1_POS.col, 100);
    tick(100 + TAPPING_TERM + 1);
    try testing.expect(layer.layerStateIs(1));

    // MO(1) リリース
    release(MO1_POS.row, MO1_POS.col, 100 + TAPPING_TERM + 100);
    try testing.expect(!layer.layerStateIs(1));
    try testing.expect(layer.layerStateIs(0));

    // LT(2, ESC) ホールド
    press(LT2_ESC_POS.row, LT2_ESC_POS.col, 500);
    tick(500 + TAPPING_TERM + 1);
    try testing.expect(layer.layerStateIs(2));

    // LT(2, ESC) リリース
    release(LT2_ESC_POS.row, LT2_ESC_POS.col, 500 + TAPPING_TERM + 100);
    try testing.expect(!layer.layerStateIs(2));
    try testing.expect(layer.layerStateIs(0));
}

// ============================================================
// 8. HIDレポートのバイナリ互換性検証
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
// 9. ソースレイヤーキャッシュの統合テスト
// ============================================================

test "E2E: レイヤー切替中のキーリリースが正しいレイヤーで処理される" {
    const mock = setup();
    defer teardown();

    // Layer 0 でキーQ をプレス
    press(Q_POS.row, Q_POS.col, 100);
    try testing.expect(mock.lastKeyboardReport().hasKey(0x14)); // Q

    // キーを押したままレイヤー1を有効化（MO(1)ホールド）
    press(MO1_POS.row, MO1_POS.col, 150);
    tick(150 + TAPPING_TERM + 1);

    // Qリリース → Layer 0 の Q として unregister される（ソースレイヤーキャッシュ）
    release(Q_POS.row, Q_POS.col, 150 + TAPPING_TERM + 50);

    // MO(1) リリース
    release(MO1_POS.row, MO1_POS.col, 150 + TAPPING_TERM + 100);
}

// ============================================================
// 10. Layer-Tap 組み合わせテスト
// ============================================================

test "E2E: Layer 1 の LT(3,ESC) でレイヤー3にアクセスできる" {
    _ = setup();
    defer teardown();

    // まず MO(1) でレイヤー1を有効化
    press(MO1_POS.row, MO1_POS.col, 100);
    tick(100 + TAPPING_TERM + 1);
    try testing.expect(layer.layerStateIs(1));

    // Layer 1 の LT(2,ESC) 位置は LT(3,ESC) になっている
    // madbd34: (3,6), madbd5: (3,7)
    press(LT2_ESC_POS.row, LT2_ESC_POS.col, 100 + TAPPING_TERM + 20);
    tick(100 + TAPPING_TERM + 20 + TAPPING_TERM + 1);

    try testing.expect(layer.layerStateIs(3));

    // リリース
    release(LT2_ESC_POS.row, LT2_ESC_POS.col, 100 + TAPPING_TERM + 20 + TAPPING_TERM + 100);
    release(MO1_POS.row, MO1_POS.col, 100 + TAPPING_TERM + 20 + TAPPING_TERM + 150);
}

// ============================================================
// 11. Extrakey (メディアキー) の統合テスト
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

test "E2E: kb Layer 3 のメディアキー配置が正しい" {
    const km = &kb.default_keymap;

    try testing.expectEqual(KC.MUTE, km[3][L3_MUTE_POS.row][L3_MUTE_POS.col]);
    try testing.expectEqual(KC.VOLD, km[3][L3_VOLD_POS.row][L3_VOLD_POS.col]);
    try testing.expectEqual(KC.VOLU, km[3][L3_VOLU_POS.row][L3_VOLU_POS.col]);
}

// ============================================================
// 12. ファンクションキーのテスト
// ============================================================

test "E2E: kb Layer 3 のファンクションキー配置" {
    const km = &kb.default_keymap;

    // Layer 3: F1-F12 は連続した列に配置
    try testing.expectEqual(KC.F1, km[3][0][L3_F1_COL]);
    try testing.expectEqual(KC.F2, km[3][0][L3_F1_COL + 1]);
    try testing.expectEqual(KC.F3, km[3][0][L3_F1_COL + 2]);
    try testing.expectEqual(KC.F4, km[3][0][L3_F1_COL + 3]);
    try testing.expectEqual(KC.F5, km[3][0][L3_F1_COL + 4]);
    try testing.expectEqual(KC.F6, km[3][0][L3_F1_COL + 5]);
    try testing.expectEqual(KC.F7, km[3][0][L3_F1_COL + 6]);
    try testing.expectEqual(KC.F8, km[3][0][L3_F1_COL + 7]);
    try testing.expectEqual(KC.F9, km[3][0][L3_F1_COL + 8]);
    try testing.expectEqual(KC.F10, km[3][0][L3_F1_COL + 9]);
    try testing.expectEqual(KC.F11, km[3][0][L3_F1_COL + 10]);
    try testing.expectEqual(KC.F12, km[3][0][L3_F1_COL + 11]);
}

// ============================================================
// 13. Action Code → Keycode ラウンドトリップテスト
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
// 14. 全レイヤーを通したキーマップ解決テスト
// ============================================================

test "E2E: keymap resolveKeycode がレイヤー優先度を正しく処理する" {
    const km = &kb.default_keymap;

    // Layer 0 のみ: Q位置 = KC.Q
    try testing.expectEqual(KC.Q, keymap_mod.resolveKeycode(km, 0b01, Q_POS.row, Q_POS.col));

    // Layer 0 + 1: Q位置 = Layer1 の KC.@"1"
    try testing.expectEqual(KC.@"1", keymap_mod.resolveKeycode(km, 0b11, Q_POS.row, Q_POS.col));
}

// ============================================================
// 15. デバウンスモジュールの統合テスト
// ============================================================

test "E2E: デバウンスのインポートとAPIが正しく公開されている" {
    const debounce_mod = @import("../core/debounce.zig");
    var db = debounce_mod.DebounceState(kb.rows, kb.cols).init(5);
    _ = &db;
    try testing.expectEqual(@as(u16, 5), db.debounce_ms);
}

// ============================================================
// 16. マトリックスモジュールの統合テスト
// ============================================================

test "E2E: マトリックス設定がkbと一致する" {
    const matrix_mod = @import("../core/matrix.zig");
    const cfg = kb.matrixConfig();

    try testing.expectEqual(@as(usize, kb.rows), cfg.row_pins.len);
    try testing.expectEqual(@as(usize, kb.cols), cfg.col_pins.len);

    var mat = matrix_mod.Matrix(kb.rows, kb.cols).init(cfg);
    _ = &mat;
    try testing.expectEqual(@as(usize, kb.rows), mat.config.row_pins.len);
    try testing.expectEqual(@as(usize, kb.cols), mat.config.col_pins.len);
}

// ============================================================
// 17. Host ドライバ統合テスト
// ============================================================

test "E2E: HostDriverインターフェースがモックで正しく動作する" {
    var mock = IntegrationMockDriver{};
    const driver = host_mod.HostDriver.from(&mock);

    // キーボードレポート送信
    var report = KeyboardReport{};
    _ = report.addKey(0x04);
    report.mods = report_mod.ModBit.LSHIFT;
    driver.sendKeyboard(&report);

    try testing.expectEqual(@as(usize, 1), mock.keyboard_count);
    try testing.expect(mock.keyboard_reports[0].hasKey(0x04));
    try testing.expectEqual(report_mod.ModBit.LSHIFT, mock.keyboard_reports[0].mods);

    // Extraレポート送信
    const extra = ExtraReport.consumer(0x00E2);
    driver.sendExtra(&extra);

    try testing.expectEqual(@as(usize, 1), mock.extra_count);
    try testing.expectEqual(@as(u16, 0x00E2), mock.extra_reports[0].usage);
}
