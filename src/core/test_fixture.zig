// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! Test Fixture for keyboard simulation
//! Zig equivalent of tests/test_common/test_fixture.cpp
//!
//! keyboard.zig の keyboard_task() パイプライン経由でキー処理を行う。
//! processMatrixScan() による独自処理は廃止し、action/tapping パイプラインを使用。

const std = @import("std");
const keycode = @import("keycode.zig");
const keymap_mod = @import("keymap.zig");
const report_mod = @import("report.zig");
const layer_mod = @import("layer.zig");
const keyboard = @import("keyboard.zig");
const timer = @import("hal").timer;
const tapping = @import("action_tapping.zig");
const FixedTestDriver = @import("test_driver.zig").FixedTestDriver;
const Keycode = keycode.Keycode;
const KC = keycode.KC;
const KeyboardReport = report_mod.KeyboardReport;

pub const MAX_LAYERS = 16;
pub const MATRIX_ROWS = keyboard.MATRIX_ROWS;
pub const MATRIX_COLS = keyboard.MATRIX_COLS;
pub const TAPPING_TERM: u16 = tapping.TAPPING_TERM;

// ============================================================
// TestFixture が要求する最小マトリックスサイズ
// ============================================================
//
// `src/tests/integration_test.zig` 等の共通テストは 「人工キーマップ」 を
// 構築するために特定の (row, col) 位置にキーを登録する。 そのため、 対象
// keyboard のマトリックスサイズが小さすぎるとキー位置が範囲外になり、
// `setKey()` が no-op になってテストが意味を成さなくなる。
//
// 現状の最大要求位置は `integration_test.zig` の thumb cluster 関連定数:
//   MO1_ROW = 3, MO1_COL = 8        → 必要マトリックス: 4 行 9 列以上
// よって以下を共通テストの動作保証ライン (=「最大公約数」) として宣言する。
//
// 検証は test バイナリビルド時に下の comptime ブロックで自動実施される
// (keyboard 側に assert を書く必要はない)。 違反時は `@compileError` により
// 親切なメッセージ付きでビルドが停止する。
//
// 将来 MIN 未満の小型 keyboard (例: 3x8 のマクロパッド) を追加する場合は、
// 以下のいずれかで対応する:
//   1. 共通テストの座標を縮小 (MIN_* も合わせて引き下げる)
//   2. 当該 keyboard を `zig build test` の対象から除外
//   3. test partition を導入 (keyboard ごとに対応する test 群を選択)
//
// 関連 Issue: #393
pub const MIN_ROWS: u8 = 4;
pub const MIN_COLS: u8 = 9;

// 対象 keyboard の MATRIX_ROWS / MATRIX_COLS が共通テスト要件を満たすことを
// test バイナリビルド時に検証する。 違反時は `@compileError` で親切なメッセージを表示。
comptime {
    if (MATRIX_ROWS < MIN_ROWS) {
        @compileError(std.fmt.comptimePrint(
            "Keyboard MATRIX_ROWS={d} is below TestFixture.MIN_ROWS={d}. " ++
                "共通テスト (integration_test.zig 等) は最大要求座標 ({d}, {d}) を使用するため " ++
                "{d} 行 {d} 列以上のマトリックスが必要です。 " ++
                "対処法は src/core/test_fixture.zig 冒頭コメント参照 (1.座標縮小 / 2.test 対象除外 / 3.test partition)。",
            .{ MATRIX_ROWS, MIN_ROWS, MIN_ROWS - 1, MIN_COLS - 1, MIN_ROWS, MIN_COLS },
        ));
    }
    if (MATRIX_COLS < MIN_COLS) {
        @compileError(std.fmt.comptimePrint(
            "Keyboard MATRIX_COLS={d} is below TestFixture.MIN_COLS={d}. " ++
                "共通テスト (integration_test.zig 等) は最大要求座標 ({d}, {d}) を使用するため " ++
                "{d} 行 {d} 列以上のマトリックスが必要です。 " ++
                "対処法は src/core/test_fixture.zig 冒頭コメント参照 (1.座標縮小 / 2.test 対象除外 / 3.test partition)。",
            .{ MATRIX_COLS, MIN_COLS, MIN_ROWS - 1, MIN_COLS - 1, MIN_ROWS, MIN_COLS },
        ));
    }
}

// ============================================================
// Test-only keymap storage and helpers
// ============================================================
// production の keymap (main.zig が `kb.default_keymap` を直接参照する flash 上の
// 静的 const) と共有しないよう、 test 用 keymap は本ファイル内に独立保持する (BSS)。
// keyboard.zig は依存性注入された `keymap_lookup` 経由で参照するのみで、
// production / test それぞれが自分の領域を持つ設計とする (Issue #395)。

/// test_fixture 経由のテスト専用 keymap storage (Issue #402)。
var fixture_test_keymap: keymap_mod.Keymap = keymap_mod.emptyKeymap();

/// keyboard.zig に注入する lookup 関数。 純粋関数として `fixture_test_keymap` を引く。
fn fixtureKeymapLookup(l: u5, row: u8, col: u8) Keycode {
    return keymap_mod.keymapKeyToKeycode(&fixture_test_keymap, l, row, col);
}

/// keymap の 1 キーをセットする (範囲外は no-op)。 test 専用。
pub fn setKey(l: u5, row: u8, col: u8, kc: Keycode) void {
    if (row < keymap_mod.MATRIX_ROWS and col < keymap_mod.MATRIX_COLS and l < keymap_mod.MAX_LAYERS) {
        fixture_test_keymap[l][row][col] = kc;
    }
}

/// keymap を空 (KC_NO 全埋め) にリセットする。 test 専用。
pub fn resetKeymap() void {
    fixture_test_keymap = keymap_mod.emptyKeymap();
}

/// test 用 keymap への可変ポインタを返す。 test コード内で keymap 全体を参照したい
/// (例: `keymap_mod.resolveKeycode(km, ...)` で純関数的に検証する) 場合に使用する。
pub fn getTestKeymap() *keymap_mod.Keymap {
    return &fixture_test_keymap;
}

/// Key definition for test keymaps
pub const KeymapKey = struct {
    layer: u4,
    row: u8,
    col: u8,
    code: Keycode,

    pub fn init(layer: u4, row: u8, col: u8, code: Keycode) KeymapKey {
        return .{
            .layer = layer,
            .row = row,
            .col = col,
            .code = code,
        };
    }
};

/// Test fixture for keyboard simulation
/// keyboard.zig の task() パイプラインに委譲する。
pub const TestFixture = struct {
    /// Mock driver for capturing reports (fixed-size, no allocator)
    driver: FixedTestDriver(64, 16),

    /// 構造体を初期化する（ドライバ登録はまだ行わない）
    pub fn init() TestFixture {
        return TestFixture{
            .driver = .{},
        };
    }

    /// ドライバ登録を含むフルセットアップ（init() 後、self のアドレスが確定してから呼ぶ）
    ///
    /// 呼び出し順序契約 (Issue #401):
    /// `keyboard.init()` (initTest 内で呼ばれる) は keymap_lookup を defaultKeymapLookup
    /// に戻すため、 必ず `initTest` の **後に** `setKeymapLookup` を呼ぶこと。
    pub fn setup(self: *TestFixture) void {
        resetKeymap();
        keyboard.initTest(keyboard.host.HostDriver.from(&self.driver));
        keyboard.setKeymapLookup(fixtureKeymapLookup);
    }

    /// ボイラープレート削減用コンビニエンス API: out ポインタに対して init + setup を行う。
    ///
    /// out ポインタ版を採用する理由:
    /// (1) `var fixture = TestFixture.initAndSetup();` のような戻り値式中使用を構文的に防ぐ
    ///     (戻り値が void のため、 値を受ける書き方ができない)。
    /// (2) アドレス安定性が API レベルの契約として明示される
    ///     (呼び出し側が `var fixture: TestFixture = undefined;` で記憶域を確保することを強制する)。
    /// (3) host driver が保持する self pointer (`&self.driver`) のライフタイムが
    ///     呼び出し側のスコープに紐付くという意図がシグネチャから明確になる。
    ///
    /// 標準の使い方:
    /// ```zig
    /// var fixture: TestFixture = undefined;
    /// TestFixture.initAndSetup(&fixture);
    /// defer fixture.deinit();
    /// ```
    pub fn initAndSetup(out: *TestFixture) void {
        out.* = TestFixture.init();
        out.setup();
    }

    /// ボイラープレート削減用コンビニエンス API: initAndSetup 後に追加の setup_fn を実行する。
    /// 共通のキーマップセットアップ等を関数化して各テストから注入できる。
    ///
    /// out ポインタ版を採用する理由は `initAndSetup` と同じ:
    /// (1) 戻り値式中使用を構文的に防ぐ
    /// (2) アドレス安定性が API レベルの契約として明示される
    /// (3) setup_fn が `&out.driver` 等を保持する可能性に備えたライフタイム意図の明確化
    ///
    /// 標準の使い方:
    /// ```zig
    /// var fixture: TestFixture = undefined;
    /// TestFixture.withSetup(&fixture, setupKeymap);
    /// defer fixture.deinit();
    /// ```
    pub fn withSetup(out: *TestFixture, comptime setup_fn: fn (*TestFixture) void) void {
        TestFixture.initAndSetup(out);
        setup_fn(out);
    }

    /// ボイラープレート削減用コンビニエンス API: init + setup + setKeymap を一括で実行する。
    /// 単純なキーマップだけを設定するテストで使用する。
    ///
    /// out ポインタ版を採用する理由は `initAndSetup` と同じ:
    /// (1) 戻り値式中使用を構文的に防ぐ
    /// (2) アドレス安定性が API レベルの契約として明示される
    /// (3) host driver が保持する `&out.driver` のライフタイム意図の明確化
    ///
    /// 標準の使い方:
    /// ```zig
    /// var fixture: TestFixture = undefined;
    /// TestFixture.initWithKeymap(&fixture, &.{
    ///     KeymapKey.init(0, 0, 0, KC.A),
    /// });
    /// defer fixture.deinit();
    /// ```
    pub fn initWithKeymap(out: *TestFixture, keys: []const KeymapKey) void {
        TestFixture.initAndSetup(out);
        out.setKeymap(keys);
    }

    pub fn deinit(_: *TestFixture) void {
        keyboard.host.clearDriver();
        keyboard.clearKeymapLookup();
    }

    // ============================================================
    // Keymap management
    // ============================================================

    /// Set the test keymap from a list of key definitions
    pub fn setKeymap(_: *TestFixture, keys: []const KeymapKey) void {
        resetKeymap();
        for (keys) |key| {
            setKey(key.layer, key.row, key.col, key.code);
        }
    }

    /// Add a single key to the keymap
    pub fn addKey(_: *TestFixture, key: KeymapKey) void {
        setKey(key.layer, key.row, key.col, key.code);
    }

    // ============================================================
    // Matrix simulation (delegates to keyboard.zig)
    // ============================================================

    /// Press a key at the given matrix position
    pub fn pressKey(_: *TestFixture, row: u8, col: u8) void {
        keyboard.pressKey(row, col);
    }

    /// Release a key at the given matrix position
    pub fn releaseKey(_: *TestFixture, row: u8, col: u8) void {
        keyboard.releaseKey(row, col);
    }

    /// Clear all pressed keys
    pub fn clearAllKeys(_: *TestFixture) void {
        keyboard.clearAllKeys();
    }

    // ============================================================
    // Layer management (delegates to layer.zig global state)
    // ============================================================

    pub fn layerOn(_: *TestFixture, layer: u4) void {
        layer_mod.layerOn(layer);
    }

    pub fn layerOff(_: *TestFixture, layer: u4) void {
        layer_mod.layerOff(layer);
    }

    pub fn layerClear(_: *TestFixture) void {
        layer_mod.layerClear();
    }

    pub fn isLayerOn(_: *const TestFixture, layer: u4) bool {
        return layer_mod.layerStateIs(layer);
    }

    // ============================================================
    // Simulation control
    // ============================================================

    /// Run one scan loop (advance 1ms and process via keyboard.task)
    pub fn runOneScanLoop(_: *TestFixture) void {
        timer.mockAdvance(1);
        keyboard.task();
    }

    /// Idle for the given number of milliseconds
    pub fn idleFor(self: *TestFixture, ms: u16) void {
        var i: u16 = 0;
        while (i < ms) : (i += 1) {
            self.runOneScanLoop();
        }
    }

    /// Reset fixture state for next test
    ///
    /// 呼び出し順序契約 (Issue #401):
    /// `init()` は keymap_lookup と action_resolver をクリアするため、
    /// `setKeymapLookup` / `setActionResolver` は init() の **後に** 呼ぶこと。
    pub fn reset(self: *TestFixture) void {
        self.driver.reset();
        resetKeymap();
        keyboard.init();
        keyboard.setKeymapLookup(fixtureKeymapLookup);
        keyboard.host.setDriver(keyboard.host.HostDriver.from(&self.driver));
        @import("action.zig").setActionResolver(keyboard.keymapActionResolver);
    }
};

// ============================================================
// Tests
// ============================================================

test "TestFixture basic key press" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
    });

    // Press KC_A
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try std.testing.expect(fixture.driver.keyboard_count >= 1);
    try std.testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x04));
    try std.testing.expectEqual(@as(u8, 0), fixture.driver.lastKeyboardReport().mods);

    // Release KC_A
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    try std.testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "TestFixture modifier key" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.LEFT_SHIFT),
    });

    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try std.testing.expect(fixture.driver.keyboard_count >= 1);
    try std.testing.expectEqual(
        report_mod.ModBit.LSHIFT,
        fixture.driver.lastKeyboardReport().mods & report_mod.ModBit.LSHIFT,
    );
}

test "TestFixture two keys" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
        KeymapKey.init(0, 0, 1, KC.B),
    });

    // Press A
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try std.testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x04));

    // Press B (A still held)
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();
    try std.testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x04));
    try std.testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x05));
}

test "TestFixture MO() layer switch" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.MO(1)),
        KeymapKey.init(0, 0, 1, KC.A),
        KeymapKey.init(1, 0, 1, KC.B),
    });

    // Press MO(1) — tapping パイプラインのため TAPPING_TERM 待ちが必要
    fixture.pressKey(0, 0);
    fixture.idleFor(TAPPING_TERM + 1);
    try std.testing.expect(fixture.isLayerOn(1));

    // Press key on layer 1 -> should be KC_B
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();

    const last = fixture.driver.lastKeyboardReport();
    try std.testing.expect(last.hasKey(0x05)); // KC_B

    // Release MO(1)
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try std.testing.expect(!fixture.isLayerOn(1));
}

test "TestFixture resolveKeycode transparency" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
        KeymapKey.init(1, 0, 0, KC.TRNS),
    });

    // Layer 0 only: press key -> should get KC_A
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try std.testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x04));

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // Activate layer 1 and press key -> TRNS falls through to layer 0 -> KC_A
    fixture.layerOn(1);
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try std.testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x04));
}

// ============================================================
// コンビニエンス API のテスト
// ============================================================

test "TestFixture initAndSetup convenience API" {
    var fixture: TestFixture = undefined;
    TestFixture.initAndSetup(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
    });

    // 通常の init() + setup() と同じ挙動になることを確認
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try std.testing.expect(fixture.driver.keyboard_count >= 1);
    try std.testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x04));

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try std.testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "TestFixture withSetup convenience API" {
    const setup_fn = struct {
        fn setupKeymap(f: *TestFixture) void {
            f.setKeymap(&.{
                KeymapKey.init(0, 0, 0, KC.B),
                KeymapKey.init(0, 0, 1, KC.C),
            });
        }
    }.setupKeymap;

    var fixture: TestFixture = undefined;
    TestFixture.withSetup(&fixture, setup_fn);
    defer fixture.deinit();

    // setup_fn で登録された keymap が反映されていることを確認
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try std.testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x05)); // KC_B

    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();
    try std.testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x06)); // KC_C
}

test "TestFixture initWithKeymap convenience API" {
    var fixture: TestFixture = undefined;
    TestFixture.initWithKeymap(&fixture, &.{
        KeymapKey.init(0, 0, 0, KC.D),
    });
    defer fixture.deinit();

    // initWithKeymap で keymap が登録されていることを確認
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try std.testing.expect(fixture.driver.keyboard_count >= 1);
    try std.testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x07)); // KC_D
}

// ============================================================
// コンビニエンス API のエッジケーステスト (Issue #411)
// ============================================================

test "TestFixture initWithKeymap: 空 keymap でも初期化が完了する" {
    // 空配列を渡してもクラッシュせず、 全キーが KC_NO 状態になる。
    // setup の冪等性 (resetKeymap → 全 KC_NO) と、 deinit が正常に呼べることを保証する。
    var fixture: TestFixture = undefined;
    TestFixture.initWithKeymap(&fixture, &.{});
    defer fixture.deinit();

    // 何のキーも登録されていないので、 (0,0) を押下しても
    // KC_NO として処理され、 keyboard report にキーが乗らない。
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try std.testing.expect(fixture.driver.lastKeyboardReport().isEmpty());

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try std.testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "TestFixture initWithKeymap: out-of-range な row/col を含む keys は無視される (no-op)" {
    // setKey は row >= MATRIX_ROWS / col >= MATRIX_COLS / layer >= MAX_LAYERS の
    // いずれかが満たされた場合に no-op になる契約 (test_fixture.zig: setKey)。
    // ここではユーザーが誤って out-of-range な KeymapKey を渡しても
    // クラッシュせず、 範囲内の有効なキーだけが登録されることを検証する。

    // 範囲外座標を comptime で計算 (MATRIX_ROWS=4, MATRIX_COLS=9 を超える値)
    const oor_row: u8 = keymap_mod.MATRIX_ROWS;
    const oor_col: u8 = keymap_mod.MATRIX_COLS;

    var fixture: TestFixture = undefined;
    TestFixture.initWithKeymap(&fixture, &.{
        // 有効なキー
        KeymapKey.init(0, 0, 0, KC.A),
        // row 範囲外 → 無視されるべき
        KeymapKey.init(0, oor_row, 0, KC.B),
        // col 範囲外 → 無視されるべき
        KeymapKey.init(0, 0, oor_col, KC.C),
        // row, col 共に範囲外 → 無視されるべき
        KeymapKey.init(0, oor_row, oor_col, KC.D),
    });
    defer fixture.deinit();

    // 有効なキーは押せる
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try std.testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x04)); // KC_A

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try std.testing.expect(fixture.driver.lastKeyboardReport().isEmpty());

    // 範囲外キーは登録されていないので、 マトリックス内の他の位置 (0, 1) は KC_NO のまま
    // (= report にキーが乗らない)
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();
    try std.testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}
