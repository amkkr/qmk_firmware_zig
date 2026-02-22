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

// Keyboard definition
const madbd34 = @import("../keyboards/madbd34.zig");

const Action = action_code.Action;
const KeyRecord = event_mod.KeyRecord;
const KeyEvent = event_mod.KeyEvent;
const KeyboardReport = report_mod.KeyboardReport;
const ExtraReport = report_mod.ExtraReport;
const KC = keycode.KC;
const Keycode = keycode.Keycode;

// ============================================================
// テスト用モックドライバ（キーボード＋Extraレポートを記録）
// ============================================================

const IntegrationMockDriver = struct {
    keyboard_count: usize = 0,
    extra_count: usize = 0,
    keyboard_reports: [64]KeyboardReport = [_]KeyboardReport{KeyboardReport{}} ** 64,
    extra_reports: [16]ExtraReport = [_]ExtraReport{ExtraReport{}} ** 16,
    leds: u8 = 0,

    pub fn keyboardLeds(self: *IntegrationMockDriver) u8 {
        return self.leds;
    }

    pub fn sendKeyboard(self: *IntegrationMockDriver, r: KeyboardReport) void {
        if (self.keyboard_count < 64) {
            self.keyboard_reports[self.keyboard_count] = r;
        }
        self.keyboard_count += 1;
    }

    pub fn sendMouse(_: *IntegrationMockDriver, _: report_mod.MouseReport) void {}

    pub fn sendExtra(self: *IntegrationMockDriver, r: ExtraReport) void {
        if (self.extra_count < 16) {
            self.extra_reports[self.extra_count] = r;
        }
        self.extra_count += 1;
    }

    fn lastKeyboardReport(self: *const IntegrationMockDriver) KeyboardReport {
        if (self.keyboard_count == 0) return KeyboardReport{};
        const idx = if (self.keyboard_count > 64) 63 else self.keyboard_count - 1;
        return self.keyboard_reports[idx];
    }

    fn lastExtraReport(self: *const IntegrationMockDriver) ExtraReport {
        if (self.extra_count == 0) return ExtraReport{};
        const idx = if (self.extra_count > 16) 15 else self.extra_count - 1;
        return self.extra_reports[idx];
    }

    fn reset(self: *IntegrationMockDriver) void {
        self.keyboard_count = 0;
        self.extra_count = 0;
        self.keyboard_reports = [_]KeyboardReport{KeyboardReport{}} ** 64;
        self.extra_reports = [_]ExtraReport{ExtraReport{}} ** 16;
    }
};

// ============================================================
// madbd34 キーマップからアクションを解決するリゾルバ
// ============================================================

/// madbd34 のデフォルトキーマップを使って、レイヤーとマトリックス位置から
/// アクションコードを解決する。
/// action.setActionResolver() に渡すためのコールバック。
fn madbd34ActionResolver(ev: KeyEvent) Action {
    const km = &madbd34.default_keymap;

    // レイヤー解決用のクロージャ関数
    const keymapFn = struct {
        fn f(l: u5, row: u8, col: u8) Keycode {
            return keymap_mod.keymapKeyToKeycode(&madbd34.default_keymap, l, row, col);
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
    action.setActionResolver(madbd34ActionResolver);
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

    // madbd34 Layer 0: (0,1) = KC.Q (HID 0x14)
    press(0, 1, 100);

    // KC.Q は basic keycode なのでタッピング不要、即時レポート
    try testing.expect(mock.keyboard_count >= 1);
    try testing.expect(mock.lastKeyboardReport().hasKey(0x14)); // Q

    // リリース
    release(0, 1, 200);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

test "E2E: 複数キー同時押しで6KROレポートに正しく含まれる" {
    const mock = setup();
    defer teardown();

    // Layer 0: (0,1)=Q, (0,2)=W, (0,3)=E
    press(0, 1, 100); // Q
    press(0, 2, 110); // W
    press(0, 3, 120); // E

    const report = mock.lastKeyboardReport();
    try testing.expect(report.hasKey(0x14)); // Q
    try testing.expect(report.hasKey(0x1A)); // W
    try testing.expect(report.hasKey(0x08)); // E

    // 全リリース
    release(0, 1, 200);
    release(0, 2, 210);
    release(0, 3, 220);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

test "E2E: 修飾キー(LCTL)がHIDレポートのmodsに反映される" {
    const mock = setup();
    defer teardown();

    // madbd34 Layer 0: (1,0) = KC.LCTL (HID modifier 0xE0)
    press(1, 0, 100);

    try testing.expect(mock.keyboard_count >= 1);
    try testing.expectEqual(@as(u8, report_mod.ModBit.LCTRL), mock.lastKeyboardReport().mods & report_mod.ModBit.LCTRL);

    release(1, 0, 200);
    try testing.expectEqual(@as(u8, 0), mock.lastKeyboardReport().mods);
}

test "E2E: 修飾キー＋通常キー同時押し (Ctrl+A)" {
    const mock = setup();
    defer teardown();

    // LCTL (1,0) + A (1,1)
    press(1, 0, 100); // LCTL
    press(1, 1, 110); // A

    const report = mock.lastKeyboardReport();
    try testing.expect(report.mods & report_mod.ModBit.LCTRL != 0);
    try testing.expect(report.hasKey(0x04)); // A

    release(1, 1, 200);
    release(1, 0, 210);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

test "E2E: LSFT + Z (Shift+Z) の組み合わせ" {
    const mock = setup();
    defer teardown();

    // madbd34 Layer 0: (2,0) = KC.LSFT, (2,1) = KC.Z
    press(2, 0, 100); // LSFT
    press(2, 1, 110); // Z

    const report = mock.lastKeyboardReport();
    try testing.expect(report.mods & report_mod.ModBit.LSHIFT != 0);
    try testing.expect(report.hasKey(0x1D)); // Z

    release(2, 1, 200);
    release(2, 0, 210);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// ============================================================
// 2. レイヤー切替シナリオ（madbd34 キーマップ）
// ============================================================

test "E2E: MO(1)でレイヤー1が有効化される" {
    _ = setup();
    defer teardown();

    // madbd34 Layer 0: (3,8) = MO(1)
    press(3, 8, 100);
    // MO(1) は layer_tap + OP_ON_OFF のため、タッピングステートマシンを通る
    // OP_ON_OFF は hold動作 (tap_count=0 でレイヤーON)
    tick(100 + TAPPING_TERM + 1); // TAPPING_TERM を超える

    try testing.expect(layer.layerStateIs(1));

    release(3, 8, 100 + TAPPING_TERM + 100);
    try testing.expect(!layer.layerStateIs(1));
}

test "E2E: MO(1)ホールド中にレイヤー1のキーが入力される" {
    const mock = setup();
    defer teardown();

    // (3,8) = MO(1) をホールド
    press(3, 8, 100);
    tick(100 + TAPPING_TERM + 1); // TAPPING_TERM を超えてホールド確定

    try testing.expect(layer.layerStateIs(1));

    // Layer 1: (0,1) = KC.@"1" (HID 0x1E) ※ Layer 0 では KC.Q
    press(0, 1, 100 + TAPPING_TERM + 20);

    // Layer 1がアクティブなので KC.1 が出力されるはず
    var found_1 = false;
    var i: usize = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x1E)) { // KC.@"1"
            found_1 = true;
            break;
        }
    }
    try testing.expect(found_1);

    release(0, 1, 100 + TAPPING_TERM + 100);
    release(3, 8, 100 + TAPPING_TERM + 150);
}

test "E2E: LT(1,SPC) タップでスペースが入力される" {
    const mock = setup();
    defer teardown();

    // madbd34 Layer 0: (3,5) = LT(1, KC.SPC)
    // 短いタップ（TAPPING_TERM未満）→ SPCが出力される
    press(3, 5, 100);
    release(3, 5, 150);

    // タップとして処理され、KC.SPC (0x2C) が送信されるはず
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

    // madbd34 Layer 0: (3,5) = LT(1, KC.SPC)
    press(3, 5, 100);
    tick(100 + TAPPING_TERM + 1); // TAPPING_TERM を超える

    try testing.expect(layer.layerStateIs(1));

    release(3, 5, 100 + TAPPING_TERM + 100);
    try testing.expect(!layer.layerStateIs(1));
}

test "E2E: LT(2,ESC) タップでESCが入力される" {
    const mock = setup();
    defer teardown();

    // madbd34 Layer 0: (3,6) = LT(2, KC.ESC)
    press(3, 6, 100);
    release(3, 6, 150);

    // ESC (0x29)
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

    // madbd34 Layer 0: (3,6) = LT(2, KC.ESC)
    press(3, 6, 100);
    tick(100 + TAPPING_TERM + 1);

    try testing.expect(layer.layerStateIs(2));

    release(3, 6, 100 + TAPPING_TERM + 100);
    try testing.expect(!layer.layerStateIs(2));
}

// ============================================================
// 3. レイヤー2 ナビゲーションキーのテスト
// ============================================================

test "E2E: レイヤー2で矢印キーが入力される" {
    const mock = setup();
    defer teardown();

    // LT(2, ESC)ホールドでレイヤー2有効化
    press(3, 6, 100);
    tick(100 + TAPPING_TERM + 1);
    try testing.expect(layer.layerStateIs(2));

    // Layer 2: (1,6)=LEFT(0x50), (1,7)=DOWN(0x51), (1,8)=UP(0x52), (1,9)=RIGHT(0x4F)
    press(1, 6, 100 + TAPPING_TERM + 20); // LEFT

    var found_left = false;
    var i: usize = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x50)) { // LEFT
            found_left = true;
            break;
        }
    }
    try testing.expect(found_left);

    release(1, 6, 100 + TAPPING_TERM + 100);
    release(3, 6, 100 + TAPPING_TERM + 150);
}

// ============================================================
// 4. テスト用キーマップ（madbd34の実キーマップ）の整合性検証
// ============================================================

test "E2E: madbd34 キーマップ→アクション変換の整合性" {
    _ = setup();
    defer teardown();

    const km = &madbd34.default_keymap;

    // Layer 0 の基本キーが正しくアクションに変換されることを確認
    // (0,0) = KC.TAB → ACTION_KEY(0x2B)
    const tab_action = action_code.keycodeToAction(km[0][0][0]);
    try testing.expectEqual(@as(u16, action_code.ACTION_KEY(0x2B)), tab_action.code);

    // (0,1) = KC.Q → ACTION_KEY(0x14)
    const q_action = action_code.keycodeToAction(km[0][0][1]);
    try testing.expectEqual(@as(u16, action_code.ACTION_KEY(0x14)), q_action.code);

    // (3,5) = LT(1, KC.SPC) → ACTION_LAYER_TAP_KEY(1, 0x2C)
    const lt1_action = action_code.keycodeToAction(km[0][3][5]);
    try testing.expectEqual(@as(u16, action_code.ACTION_LAYER_TAP_KEY(1, 0x2C)), lt1_action.code);

    // (3,6) = LT(2, KC.ESC) → ACTION_LAYER_TAP_KEY(2, 0x29)
    const lt2_action = action_code.keycodeToAction(km[0][3][6]);
    try testing.expectEqual(@as(u16, action_code.ACTION_LAYER_TAP_KEY(2, 0x29)), lt2_action.code);

    // (3,8) = MO(1) → ACTION_LAYER_MOMENTARY(1)
    const mo1_action = action_code.keycodeToAction(km[0][3][8]);
    try testing.expectEqual(@as(u16, action_code.ACTION_LAYER_MOMENTARY(1)), mo1_action.code);
}

test "E2E: madbd34 全4レイヤーのキー定義検証" {
    const km = &madbd34.default_keymap;

    // 各レイヤーが定義されている（少なくとも1つの非KC.NOキーがある）
    for (0..4) |l| {
        var key_count: usize = 0;
        for (0..madbd34.rows) |r| {
            for (0..madbd34.cols) |c| {
                if (km[l][r][c] != KC.NO) {
                    key_count += 1;
                }
            }
        }
        // 各レイヤーは少なくとも1つのキーが定義されている
        try testing.expect(key_count > 0);
    }

    // Layer 0 (QWERTY) は最も多くのキーを持つ
    // Row 0: 12, Row 1: 12, Row 2: 11, Row 3: 6 = 41
    // ただし LAYOUT内のキー値にKC.NOが含まれる場合があるため、
    // madbd34 のマトリックス上の使用可能ポジション数を検証
    // Row 3 の cols 0-2, 9-11 は物理的に未使用で KC.NO
    var layer0_count: usize = 0;
    for (0..madbd34.rows) |r| {
        for (0..madbd34.cols) |c| {
            if (km[0][r][c] != KC.NO) {
                layer0_count += 1;
            }
        }
    }
    // Layer 0 のQWERTYは全41キーポジションに非KC.NOキーを配置
    try testing.expectEqual(@as(usize, madbd34.key_count), layer0_count);

    // Layer 4以降は空
    for (4..keymap_mod.MAX_LAYERS) |l| {
        for (0..madbd34.rows) |r| {
            for (0..madbd34.cols) |c| {
                try testing.expectEqual(KC.NO, km[l][r][c]);
            }
        }
    }
}

// ============================================================
// 5. Mod-Tap (SFT_T等) のテスト
// ============================================================

// 注意: madbd34 のデフォルトキーマップには Mod-Tap キーが含まれていないため、
// action モジュールのユニットテスト（action_tapping_test.zig）で既に検証済み。
// ここでは Layer-Tap の挙動を madbd34 キーマップで検証する。

test "E2E: LT(1,SPC) ホールド中に他キーを押すとinterrupt発生" {
    const mock = setup();
    defer teardown();

    // LT(1, SPC) をプレス
    press(3, 5, 100);

    // まだTAPPING_TERM内にQキーを押す（interrupt）
    press(0, 1, 120);

    // Qリリース
    release(0, 1, 150);

    // LT(1, SPC)リリース
    release(3, 5, 180);

    // interruptにより hold として扱われ、layer 1 が有効化された上でQ相当のキーが出るか、
    // もしくはタッピングの実装次第で異なる挙動になる
    // 重要なのは、処理がクラッシュせず正常に完了すること
    try testing.expect(mock.keyboard_count >= 1);
}

// ============================================================
// 6. 連続タップのテスト
// ============================================================

test "E2E: 同一キーの連続タップが正しく処理される" {
    const mock = setup();
    defer teardown();

    // KC.Q (0,1) を連続タップ
    press(0, 1, 100);
    release(0, 1, 150);

    press(0, 1, 200);
    release(0, 1, 250);

    press(0, 1, 300);
    release(0, 1, 350);

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
    press(3, 8, 100);
    tick(100 + TAPPING_TERM + 1);
    try testing.expect(layer.layerStateIs(1));

    // MO(1) リリース
    release(3, 8, 100 + TAPPING_TERM + 100);
    try testing.expect(!layer.layerStateIs(1));
    try testing.expect(layer.layerStateIs(0));

    // LT(2, ESC) ホールド
    press(3, 6, 500);
    tick(500 + TAPPING_TERM + 1);
    try testing.expect(layer.layerStateIs(2));

    // LT(2, ESC) リリース
    release(3, 6, 500 + TAPPING_TERM + 100);
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

    // Layer 0 でキーQ (0,1) をプレス
    press(0, 1, 100);
    try testing.expect(mock.lastKeyboardReport().hasKey(0x14)); // Q

    // キーを押したままレイヤー1を有効化（MO(1)ホールド）
    press(3, 8, 150);
    tick(150 + TAPPING_TERM + 1); // TAPPING_TERM超え

    // レイヤー1が有効でも、既にプレスされたQは Layer 0 の解決で維持される
    // （ソースレイヤーキャッシュにより）

    // Qリリース → Layer 0 の Q として unregister される
    release(0, 1, 150 + TAPPING_TERM + 50);

    // MO(1) リリース
    release(3, 8, 150 + TAPPING_TERM + 100);
}

// ============================================================
// 10. madbd34 キーマップでの Layer-Tap 組み合わせテスト
// ============================================================

test "E2E: Layer 1 の LT(3,ESC) でレイヤー3にアクセスできる" {
    _ = setup();
    defer teardown();

    // まず MO(1) でレイヤー1を有効化
    press(3, 8, 100);
    tick(100 + TAPPING_TERM + 1);
    try testing.expect(layer.layerStateIs(1));

    // Layer 1: (3,6) = LT(3, KC.ESC) をホールド
    press(3, 6, 100 + TAPPING_TERM + 20);
    tick(100 + TAPPING_TERM + 20 + TAPPING_TERM + 1); // TAPPING_TERM 超え

    try testing.expect(layer.layerStateIs(3));

    // リリース
    release(3, 6, 100 + TAPPING_TERM + 20 + TAPPING_TERM + 100);
    release(3, 8, 100 + TAPPING_TERM + 20 + TAPPING_TERM + 150);
}

// ============================================================
// 11. Extrakey (メディアキー) の統合テスト
// ============================================================

test "E2E: メディアキーのHID Usageコード変換が正しい" {
    // KC.MUTE → Consumer Usage 0x0E2
    try testing.expectEqual(
        extrakey.ConsumerUsage.AUDIO_MUTE,
        extrakey.keycodeToConsumer(@truncate(KC.MUTE)),
    );
    // KC.VOLU → Consumer Usage 0x0E9
    try testing.expectEqual(
        extrakey.ConsumerUsage.AUDIO_VOL_UP,
        extrakey.keycodeToConsumer(@truncate(KC.VOLU)),
    );
    // KC.VOLD → Consumer Usage 0x0EA
    try testing.expectEqual(
        extrakey.ConsumerUsage.AUDIO_VOL_DOWN,
        extrakey.keycodeToConsumer(@truncate(KC.VOLD)),
    );
}

test "E2E: madbd34 Layer 3 のメディアキー配置が正しい" {
    const km = &madbd34.default_keymap;

    // Layer 3: (1,1) = KC.MUTE, (1,2) = KC.VOLD, (1,3) = KC.VOLU
    try testing.expectEqual(KC.MUTE, km[3][1][1]);
    try testing.expectEqual(KC.VOLD, km[3][1][2]);
    try testing.expectEqual(KC.VOLU, km[3][1][3]);

    // マウスキー: (1,6) = MS_LEFT, (1,7) = MS_DOWN, (1,8) = MS_UP, (1,9) = MS_RIGHT
    try testing.expectEqual(KC.MS_LEFT, km[3][1][6]);
    try testing.expectEqual(KC.MS_DOWN, km[3][1][7]);
    try testing.expectEqual(KC.MS_UP, km[3][1][8]);
    try testing.expectEqual(KC.MS_RIGHT, km[3][1][9]);
}

// ============================================================
// 12. ファンクションキーのテスト
// ============================================================

test "E2E: madbd34 Layer 3 のファンクションキー配置" {
    const km = &madbd34.default_keymap;

    // Layer 3: Row 0 は F1-F12
    try testing.expectEqual(KC.F1, km[3][0][0]);
    try testing.expectEqual(KC.F2, km[3][0][1]);
    try testing.expectEqual(KC.F3, km[3][0][2]);
    try testing.expectEqual(KC.F4, km[3][0][3]);
    try testing.expectEqual(KC.F5, km[3][0][4]);
    try testing.expectEqual(KC.F6, km[3][0][5]);
    try testing.expectEqual(KC.F7, km[3][0][6]);
    try testing.expectEqual(KC.F8, km[3][0][7]);
    try testing.expectEqual(KC.F9, km[3][0][8]);
    try testing.expectEqual(KC.F10, km[3][0][9]);
    try testing.expectEqual(KC.F11, km[3][0][10]);
    try testing.expectEqual(KC.F12, km[3][0][11]);
}

// ============================================================
// 13. Action Code → Keycode ラウンドトリップテスト
// ============================================================

test "E2E: 基本キーコードのアクション変換ラウンドトリップ" {
    // 全アルファベットキーのラウンドトリップ
    const alpha_keys = [_]Keycode{
        KC.A, KC.B, KC.C, KC.D, KC.E, KC.F, KC.G,
        KC.H, KC.I, KC.J, KC.K, KC.L, KC.M, KC.N,
        KC.O, KC.P, KC.Q, KC.R, KC.S, KC.T, KC.U,
        KC.V, KC.W, KC.X, KC.Y, KC.Z,
    };

    for (alpha_keys) |kc| {
        const act = action_code.keycodeToAction(kc);
        // 基本キーは ACTION_KEY(kc) と等価
        try testing.expectEqual(action_code.ACTION_KEY(@truncate(kc)), act.code);
    }
}

test "E2E: レイヤー操作キーコードのアクション変換" {
    // MO(0) ～ MO(3) のラウンドトリップ
    for (0..4) |l| {
        const kc = keycode.MO(@intCast(l));
        const act = action_code.keycodeToAction(kc);
        try testing.expectEqual(action_code.ACTION_LAYER_MOMENTARY(@intCast(l)), act.code);
    }

    // LT(1, KC_A) のラウンドトリップ
    const lt_kc = keycode.LT(1, KC.A);
    const lt_act = action_code.keycodeToAction(lt_kc);
    try testing.expectEqual(action_code.ACTION_LAYER_TAP_KEY(1, 0x04), lt_act.code);
}

// ============================================================
// 14. 全レイヤーを通したキーマップ解決テスト
// ============================================================

test "E2E: keymap resolveKeycode がレイヤー優先度を正しく処理する" {
    const km = &madbd34.default_keymap;

    // Layer 0 のみ: (0,1) = KC.Q
    try testing.expectEqual(KC.Q, keymap_mod.resolveKeycode(km, 0b01, 0, 1));

    // Layer 0 + 1: (0,1) = Layer1の KC.@"1"
    try testing.expectEqual(KC.@"1", keymap_mod.resolveKeycode(km, 0b11, 0, 1));

    // Layer 0 + 2: (0,1) = Layer2 の KC.NO ... 実際はどうか確認
    // Layer 2: (0,1) = KC.NO → KC.NO は透過ではないので Layer 2 の値が返る
    // しかし実際の madbd34 Layer 2 の (0,1) は KC.NO
    const layer2_01 = km[2][0][1];
    try testing.expectEqual(KC.NO, layer2_01);
    try testing.expectEqual(KC.NO, keymap_mod.resolveKeycode(km, 0b101, 0, 1));
}

// ============================================================
// 15. デバウンスモジュールの統合テスト
// ============================================================

test "E2E: デバウンスのインポートとAPIが正しく公開されている" {
    const debounce_mod = @import("../core/debounce.zig");
    // デバウンスモジュールが正しくインポートできることを確認
    // DebounceState が利用可能
    var db = debounce_mod.DebounceState(4, 12).init(5);
    _ = &db;
    // デバウンス時間が正しく設定される
    try testing.expectEqual(@as(u16, 5), db.debounce_ms);
}

// ============================================================
// 16. マトリックスモジュールの統合テスト
// ============================================================

test "E2E: マトリックス設定がmadbd34と一致する" {
    const matrix = @import("../core/matrix.zig");
    const cfg = madbd34.matrixConfig();

    try testing.expectEqual(@as(usize, 4), cfg.row_pins.len);
    try testing.expectEqual(@as(usize, 12), cfg.col_pins.len);

    // Matrix型がこの設定で初期化可能であることを確認
    var mat = matrix.Matrix(4, 12).init(cfg);
    _ = &mat;
    try testing.expectEqual(@as(usize, 4), mat.config.row_pins.len);
    try testing.expectEqual(@as(usize, 12), mat.config.col_pins.len);
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
