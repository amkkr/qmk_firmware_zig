// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zig port of tests/tri_layer/test_tri_layer.cpp

//! Tri Layer テスト - C版 tests/tri_layer/test_tri_layer.cpp の完全移植
//!
//! TestFixture 経由のフルパイプラインテスト（keyboard_task 経由で tri_layer キー処理を検証）。
//!
//! C版テスト対応:
//! 1. TriLayerLowerTest  — QK_TRI_LAYER_LOWER 押下/解放でレイヤー状態を検証
//! 2. TriLayerUpperTest  — QK_TRI_LAYER_UPPER 押下/解放でレイヤー状態を検証
//! 3. TriLayerAdjustTest — Lower+Upper 同時押下で Adjust レイヤー自動有効化、段階的解放を検証

const std = @import("std");
const testing = std.testing;
const keycode = @import("../core/keycode.zig");
const layer_mod = @import("../core/layer.zig");
const test_fixture = @import("../core/test_fixture.zig");

const KC = keycode.KC;
const TestFixture = test_fixture.TestFixture;
const KeymapKey = test_fixture.KeymapKey;

// ============================================================
// C版 test_tri_layer.cpp のテストケース移植
// ============================================================

// C版 TriLayerLowerTest の移植
// QK_TRI_LAYER_LOWER を押下すると lower レイヤー(1)が有効になり、
// upper(2) と adjust(3) は無効のまま。解放すると全レイヤーが無効になる。
test "TriLayerLowerTest" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.QK_TRI_LAYER_LOWER),
        KeymapKey.init(1, 0, 0, KC.TRNS),
    });

    // Press Lower
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(layer_mod.layerStateIs(1)); // lower layer ON
    try testing.expect(!layer_mod.layerStateIs(2)); // upper layer OFF
    try testing.expect(!layer_mod.layerStateIs(3)); // adjust layer OFF
    // Tri Layer キーはレポートを送信しない
    try testing.expectEqual(@as(usize, 0), fixture.driver.keyboard_count);

    // Release Lower
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(!layer_mod.layerStateIs(1)); // lower layer OFF
    try testing.expect(!layer_mod.layerStateIs(2)); // upper layer OFF
    try testing.expect(!layer_mod.layerStateIs(3)); // adjust layer OFF
}

// C版 TriLayerUpperTest の移植
// QK_TRI_LAYER_UPPER を押下すると upper レイヤー(2)が有効になり、
// lower(1) と adjust(3) は無効のまま。解放すると全レイヤーが無効になる。
test "TriLayerUpperTest" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.QK_TRI_LAYER_UPPER),
        KeymapKey.init(2, 0, 0, KC.TRNS),
    });

    // Press Upper
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(!layer_mod.layerStateIs(1)); // lower layer OFF
    try testing.expect(layer_mod.layerStateIs(2)); // upper layer ON
    try testing.expect(!layer_mod.layerStateIs(3)); // adjust layer OFF
    // Tri Layer キーはレポートを送信しない
    try testing.expectEqual(@as(usize, 0), fixture.driver.keyboard_count);

    // Release Upper
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(!layer_mod.layerStateIs(1)); // lower layer OFF
    try testing.expect(!layer_mod.layerStateIs(2)); // upper layer OFF
    try testing.expect(!layer_mod.layerStateIs(3)); // adjust layer OFF
}

// C版 TriLayerAdjustTest の移植
// Lower と Upper を同時押下すると Adjust レイヤー(3)が自動的に有効になる。
// Lower を先に解放すると Adjust が無効になり Upper だけが残る。
// Upper も解放すると全レイヤーが無効になる。
test "TriLayerAdjustTest" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.QK_TRI_LAYER_LOWER),
        KeymapKey.init(0, 0, 1, keycode.QK_TRI_LAYER_UPPER),
        KeymapKey.init(1, 0, 0, KC.TRNS),
        KeymapKey.init(1, 0, 1, KC.TRNS),
        KeymapKey.init(2, 0, 0, KC.TRNS),
        KeymapKey.init(2, 0, 1, KC.TRNS),
        KeymapKey.init(3, 0, 0, KC.TRNS),
        KeymapKey.init(3, 0, 1, KC.TRNS),
    });

    // Press Lower
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(layer_mod.layerStateIs(1)); // lower ON
    try testing.expect(!layer_mod.layerStateIs(2)); // upper OFF
    try testing.expect(!layer_mod.layerStateIs(3)); // adjust OFF

    // Press Upper (Lower still held) -> Adjust should activate
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();
    try testing.expect(layer_mod.layerStateIs(1)); // lower ON
    try testing.expect(layer_mod.layerStateIs(2)); // upper ON
    try testing.expect(layer_mod.layerStateIs(3)); // adjust ON

    // Release Lower -> Adjust should deactivate, Upper remains
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(!layer_mod.layerStateIs(1)); // lower OFF
    try testing.expect(layer_mod.layerStateIs(2)); // upper ON
    try testing.expect(!layer_mod.layerStateIs(3)); // adjust OFF

    // Release Upper -> All layers off
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();
    try testing.expect(!layer_mod.layerStateIs(1)); // lower OFF
    try testing.expect(!layer_mod.layerStateIs(2)); // upper OFF
    try testing.expect(!layer_mod.layerStateIs(3)); // adjust OFF

    // Tri Layer キーはレポートを送信しない
    try testing.expectEqual(@as(usize, 0), fixture.driver.keyboard_count);
}
