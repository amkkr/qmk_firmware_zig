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
