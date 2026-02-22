//! test_action_layer.zig — Zig port of tests/basic/test_action_layer.cpp
//!
//! レイヤー API テスト（パイプライン不要）と、キーボード統合テスト（TestFixture 使用）の移植。
//! C版テストとの論理的等価性を重視。

const std = @import("std");
const testing = std.testing;
const keycode = @import("../core/keycode.zig");
const layer_mod = @import("../core/layer.zig");
const report_mod = @import("../core/report.zig");
const test_fixture = @import("../core/test_fixture.zig");

const KC = keycode.KC;
const LayerState = layer_mod.LayerState;
const TestFixture = test_fixture.TestFixture;
const KeymapKey = test_fixture.KeymapKey;

// ============================================================
// レイヤー API テスト（パイプライン不要、layer.zig を直接テスト）
// ============================================================

test "LayerStateDBG" {
    layer_mod.resetState();
    defer layer_mod.resetState();

    layer_mod.layerStateSet(0);
    // C版では layer_state_set(0) を呼んでクラッシュしないことだけ確認
    // Zig版でも同様
}

test "LayerStateSet" {
    layer_mod.resetState();
    defer layer_mod.resetState();

    layer_mod.layerStateSet(0);
    try testing.expectEqual(@as(LayerState, 0), layer_mod.getLayerState());

    layer_mod.layerStateSet(0b001100);
    try testing.expectEqual(@as(LayerState, 0b001100), layer_mod.getLayerState());
}

test "LayerStateIs" {
    layer_mod.resetState();
    defer layer_mod.resetState();

    // layer_state = 0: layerStateIs(0) = true (layer_state==0 のとき layer 0 がアクティブ)
    layer_mod.layerStateSet(0);
    try testing.expect(layer_mod.layerStateIs(0));
    try testing.expect(!layer_mod.layerStateIs(1));

    // layer_state = 1 (bit 0 set): layerStateIs(0) = true
    layer_mod.layerStateSet(1);
    try testing.expect(layer_mod.layerStateIs(0));
    try testing.expect(!layer_mod.layerStateIs(1));

    // layer_state = 2 (bit 1 set): layerStateIs(1) = true
    layer_mod.layerStateSet(2);
    try testing.expect(!layer_mod.layerStateIs(0));
    try testing.expect(layer_mod.layerStateIs(1));
    try testing.expect(!layer_mod.layerStateIs(2));
}

test "LayerStateCmp" {
    layer_mod.resetState();
    defer layer_mod.resetState();

    // prev_layer = 0
    try testing.expect(layer_mod.layerStateCmp(0, 0));
    try testing.expect(!layer_mod.layerStateCmp(0, 1));

    // prev_layer = 1 (bit 0 set)
    try testing.expect(layer_mod.layerStateCmp(1, 0));
    try testing.expect(!layer_mod.layerStateCmp(1, 1));

    // prev_layer = 2 (bit 1 set)
    try testing.expect(!layer_mod.layerStateCmp(2, 0));
    try testing.expect(layer_mod.layerStateCmp(2, 1));
    try testing.expect(!layer_mod.layerStateCmp(2, 2));
}

test "LayerClear" {
    layer_mod.resetState();
    defer layer_mod.resetState();

    layer_mod.layerClear();
    try testing.expectEqual(@as(LayerState, 0), layer_mod.getLayerState());
}

test "LayerMove" {
    layer_mod.resetState();
    defer layer_mod.resetState();

    layer_mod.layerMove(0);
    try testing.expectEqual(@as(LayerState, 1), layer_mod.getLayerState());

    layer_mod.layerMove(3);
    try testing.expectEqual(@as(LayerState, 0b1000), layer_mod.getLayerState());
}

test "LayerOn" {
    layer_mod.resetState();
    defer layer_mod.resetState();

    layer_mod.layerClear();
    layer_mod.layerOn(1);
    layer_mod.layerOn(3);
    layer_mod.layerOn(3); // 重複は無視
    try testing.expectEqual(@as(LayerState, 0b1010), layer_mod.getLayerState());
}

test "LayerOff" {
    layer_mod.resetState();
    defer layer_mod.resetState();

    layer_mod.layerClear();
    layer_mod.layerOn(1);
    layer_mod.layerOn(3);
    layer_mod.layerOff(3);
    layer_mod.layerOff(2); // 元々OFFのレイヤーをOFFにしても問題なし
    try testing.expectEqual(@as(LayerState, 0b0010), layer_mod.getLayerState());
}

// ============================================================
// キーボード統合テスト（TestFixture 使用）
// ============================================================

test "MomentaryLayerDoesNothing" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.MO(1)),
    });

    // MO(1) を押してリリース — HIDレポートは送信されない
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expectEqual(@as(usize, 0), fixture.driver.keyboard_count);

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expectEqual(@as(usize, 0), fixture.driver.keyboard_count);
}

test "MomentaryLayerWithKeypress" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.MO(1)),
        KeymapKey.init(0, 1, 0, KC.A),
        // 同じマトリックス位置 (1,0) のレイヤー1にKC_Bを配置
        KeymapKey.init(1, 1, 0, KC.B),
    });

    // MO(1) を押す → レイヤー1が有効化
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));
    try testing.expectEqual(@as(usize, 0), fixture.driver.keyboard_count);

    // レイヤー1のキーを押す → KC_B が報告される
    fixture.pressKey(1, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x05)); // KC_B

    // キーをリリース → 空レポート
    fixture.releaseKey(1, 0);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());

    // MO(1) をリリース → レイヤー0に戻る
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(!fixture.isLayerOn(1));
}

// ============================================================
// action.actionExec を直接呼ぶスタイルのテスト
// (action_tapping_test.zig のアプローチを使用)
// ============================================================

const action = @import("../core/action.zig");
const action_code = @import("../core/action_code.zig");
const event_mod = @import("../core/event.zig");
const host_mod = @import("../core/host.zig");
const tapping_mod = @import("../core/action_tapping.zig");

const Action = action_code.Action;
const KeyRecord = event_mod.KeyRecord;
const KeyEvent = event_mod.KeyEvent;
const ModBit = report_mod.ModBit;

const TAPPING_TERM = tapping_mod.TAPPING_TERM;

const DirectMockDriver = @import("../core/test_driver.zig").FixedTestDriver(64, 16);

// --- LayerTapReleasedBeforeKeypressReleaseWithModifiers 用リゾルバ ---
// キーマップ:
//   Layer 0: (0,0) = LT(1, KC_T), (0,1) = KC_X
//   Layer 1: (0,1) = RALT(KC_9)
//
// ソースレイヤーキャッシュ: プレス時のアクションをキャッシュし、
// リリース時にはキャッシュからアクションを返す（stuck key 防止）。
var lt_action_cache: [4][4]u16 = [_][4]u16{[_]u16{0} ** 4} ** 4;

fn ltModResolveForLayer(row: u8, col: u8) Action {
    if (row == 0 and col == 0) {
        return .{ .code = action_code.ACTION_LAYER_TAP_KEY(1, 0x17) };
    }
    if (row == 0 and col == 1) {
        if (layer_mod.layerStateIs(1)) {
            return .{ .code = 0x1426 }; // RALT(KC_9)
        }
        return .{ .code = action_code.ACTION_KEY(0x1B) }; // KC_X
    }
    return .{ .code = action_code.ACTION_NO };
}

fn ltModResolver(ev: KeyEvent) Action {
    const row = ev.key.row;
    const col = ev.key.col;
    if (ev.pressed) {
        const act = ltModResolveForLayer(row, col);
        lt_action_cache[row][col] = act.code;
        return act;
    } else {
        // リリース時はプレス時にキャッシュしたアクションを返す
        return .{ .code = lt_action_cache[row][col] };
    }
}

// --- LayerModWithKeypress 用リゾルバ ---
// キーマップ:
//   Layer 0: (0,0) = LM(1, MOD_RALT), (0,1) = KC_A
//   Layer 1: (0,1) = KC_B
fn lmResolver(ev: KeyEvent) Action {
    if (ev.key.row == 0 and ev.key.col == 0) {
        // LM(1, MOD_RALT): ACTION_LAYER_MODS(1, 0x40)
        // keycode.Mod.RALT = 0x14 → 8bit HID: 0x40 (RALT)
        return .{ .code = action_code.ACTION_LAYER_MODS(1, ModBit.RALT) };
    }
    if (ev.key.row == 0 and ev.key.col == 1) {
        // レイヤー1がアクティブなら KC_B、そうでなければ KC_A
        if (layer_mod.layerStateIs(1)) {
            return .{ .code = action_code.ACTION_KEY(0x05) }; // KC_B
        }
        return .{ .code = action_code.ACTION_KEY(0x04) }; // KC_A
    }
    return .{ .code = action_code.ACTION_NO };
}

var direct_mock: DirectMockDriver = .{};

fn directSetup(resolver: action.ActionResolver) *DirectMockDriver {
    action.reset();
    direct_mock = .{};
    lt_action_cache = [_][4]u16{[_]u16{0} ** 4} ** 4;
    host_mod.setDriver(host_mod.HostDriver.from(&direct_mock));
    action.setActionResolver(resolver);
    return &direct_mock;
}

fn directTeardown() void {
    host_mod.clearDriver();
}

fn directPress(row: u8, col: u8, time: u16) void {
    var record = KeyRecord{ .event = KeyEvent.keyPress(row, col, time) };
    action.actionExec(&record);
}

fn directRelease(row: u8, col: u8, time: u16) void {
    var record = KeyRecord{ .event = KeyEvent.keyRelease(row, col, time) };
    action.actionExec(&record);
}

fn directTick(time: u16) void {
    var record = KeyRecord{ .event = KeyEvent.tick(time) };
    action.actionExec(&record);
}

// ============================================================
// LayerTapReleasedBeforeKeypressReleaseWithModifiers
// (C版 test_action_layer.cpp:363-403)
//
// LT(1, KC_T) をホールドしてレイヤー1を有効化し、
// レイヤー1のキー RALT(KC_9) を押した後、LT キーを先にリリースするシナリオ。
// ============================================================

test "LayerTapReleasedBeforeKeypressReleaseWithModifiers" {
    const mock = directSetup(ltModResolver);
    defer directTeardown();

    // 1. LT(1, KC_T) をプレスし、TAPPING_TERM を待ってホールド確定
    directPress(0, 0, 100);
    directTick(100 + TAPPING_TERM + 1);

    // レイヤー1が有効化されている
    try testing.expect(layer_mod.layerStateIs(1));

    // 2. レイヤー1のキー RALT(KC_9) をプレス
    //    → RALT修飾 + KC_9 がレポートに含まれる
    directPress(0, 1, 100 + TAPPING_TERM + 10);

    // RALT(KC_9) がレポートされる
    var found_ralt_9 = false;
    var i: usize = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].mods & ModBit.RALT != 0 and
            mock.keyboard_reports[i].hasKey(0x26))
        {
            found_ralt_9 = true;
            break;
        }
    }
    try testing.expect(found_ralt_9);

    // 3. LT(1, KC_T) をリリース → レイヤー0に戻る
    directRelease(0, 0, 100 + TAPPING_TERM + 50);
    try testing.expect(!layer_mod.layerStateIs(1));

    // 4. RALT(KC_9) をリリース → 修飾キーとキーが解除される
    directRelease(0, 1, 100 + TAPPING_TERM + 80);

    // 最終レポートは空
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// ============================================================
// LayerModWithKeypress
// (C版 test_action_layer.cpp:405-433)
//
// LM(1, MOD_RALT) をプレスしてレイヤー1 + RALT を有効化し、
// レイヤー1のキー KC_B をタップするシナリオ。
// ============================================================

test "LayerModWithKeypress" {
    const mock = directSetup(lmResolver);
    defer directTeardown();

    // 1. LM(1, MOD_RALT) をプレス → レイヤー1有効 + RALT登録
    directPress(0, 0, 100);

    // レイヤー1が有効化されている
    try testing.expect(layer_mod.layerStateIs(1));

    // RALT がレポートに含まれている
    try testing.expect(mock.keyboard_count >= 1);
    try testing.expect(mock.lastKeyboardReport().mods & ModBit.RALT != 0);

    // 2. レイヤー1のキー KC_B をプレス → RALT + KC_B
    directPress(0, 1, 120);
    var found_ralt_b = false;
    var i: usize = 0;
    while (i < mock.keyboard_count and i < 64) : (i += 1) {
        if (mock.keyboard_reports[i].mods & ModBit.RALT != 0 and
            mock.keyboard_reports[i].hasKey(0x05))
        {
            found_ralt_b = true;
            break;
        }
    }
    try testing.expect(found_ralt_b);

    // 3. KC_B をリリース
    directRelease(0, 1, 150);

    // 4. LM(1, MOD_RALT) をリリース → レイヤー0に戻る + RALT解除
    directRelease(0, 0, 200);

    try testing.expect(!layer_mod.layerStateIs(1));
    try testing.expectEqual(@as(u8, 0), mock.lastKeyboardReport().mods);
}

// LayerModHonorsModConfig
// (C版 line 435-467, keymap_config.swap_ralt_rgui 機能への依存)
//
// 未移植の理由:
//   keymap_config.swap_ralt_rgui 機能（RALT/RGUI スワップ）が未実装のためスキップ。
//
// test "LayerModHonorsModConfig" { ... }
