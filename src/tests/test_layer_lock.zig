// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zig port of tests/layer_lock/test_layer_lock.cpp

//! Layer Lock テスト - C版 tests/layer_lock/test_layer_lock.cpp の Zig 移植
//!
//! upstream参照: tests/layer_lock/test_layer_lock.cpp (284行)
//!
//! C版テスト対応:
//! 1. LayerLockState            — layer_lock_invert/on/off/all_off の API テスト
//! 2. LayerLockMomentaryTest    — MO(1) + QK_LAYER_LOCK の統合テスト
//! 3. LayerLockLayerTapTest     — LT(1, KC_B) + QK_LAYER_LOCK の統合テスト
//! 4-5. OSL テスト              — OSL + Layer Lock のタッピングパイプライン相互作用は要追加調査
//! 6. LayerLockTimeoutTest      — アイドルタイムアウトで自動アンロック
//! 7. ToKeyOverridesLayerLock   — TO(0) で Layer Lock が上書きされる
//! 8. LayerClearOverridesLayerLock — layer_clear() で Layer Lock が上書きされる

const std = @import("std");
const testing = std.testing;

const keycode = @import("../core/keycode.zig");
const layer_mod = @import("../core/layer.zig");
const layer_lock = @import("../core/layer_lock.zig");
const test_fixture = @import("../core/test_fixture.zig");

const KC = keycode.KC;
const TestFixture = test_fixture.TestFixture;
const KeymapKey = test_fixture.KeymapKey;
const TAPPING_TERM = test_fixture.TAPPING_TERM;

const LAYER_LOCK_IDLE_TIMEOUT: u32 = 1000;

// ============================================================
// 1. LayerLockState
// ============================================================

test "LayerLockState" {
    layer_lock.reset();
    layer_mod.resetState();

    try testing.expect(!layer_lock.isLayerLocked(1));
    try testing.expect(!layer_lock.isLayerLocked(2));
    try testing.expect(!layer_lock.isLayerLocked(3));

    layer_lock.layerLockInvert(1);
    layer_lock.layerLockOn(2);
    layer_lock.layerLockOff(3);

    try testing.expect(layer_mod.layerStateIs(1));
    try testing.expect(layer_mod.layerStateIs(2));
    try testing.expect(layer_lock.isLayerLocked(1));
    try testing.expect(layer_lock.isLayerLocked(2));
    try testing.expect(!layer_lock.isLayerLocked(3));

    layer_lock.layerLockInvert(1);
    layer_lock.layerLockOn(2);
    layer_lock.layerLockOn(3);

    try testing.expect(!layer_mod.layerStateIs(1));
    try testing.expect(layer_mod.layerStateIs(2));
    try testing.expect(layer_mod.layerStateIs(3));
    try testing.expect(!layer_lock.isLayerLocked(1));
    try testing.expect(layer_lock.isLayerLocked(2));
    try testing.expect(layer_lock.isLayerLocked(3));

    layer_lock.layerLockInvert(1);
    layer_lock.layerLockOff(2);

    try testing.expect(layer_mod.layerStateIs(1));
    try testing.expect(!layer_mod.layerStateIs(2));
    try testing.expect(layer_mod.layerStateIs(3));
    try testing.expect(layer_lock.isLayerLocked(1));
    try testing.expect(!layer_lock.isLayerLocked(2));
    try testing.expect(layer_lock.isLayerLocked(3));

    layer_lock.layerLockAllOff();

    try testing.expect(!layer_mod.layerStateIs(1));
    try testing.expect(!layer_mod.layerStateIs(2));
    try testing.expect(!layer_mod.layerStateIs(3));
    try testing.expect(!layer_lock.isLayerLocked(1));
    try testing.expect(!layer_lock.isLayerLocked(2));
    try testing.expect(!layer_lock.isLayerLocked(3));
}

// ============================================================
// 2. LayerLockMomentaryTest
// ============================================================

test "LayerLockMomentaryTest" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    const key_layer = KeymapKey.init(0, 0, 0, keycode.MO(1));
    const key_a = KeymapKey.init(0, 1, 0, KC.A);
    const key_trns = KeymapKey.init(1, 0, 0, KC.TRNS);
    const key_ll = KeymapKey.init(1, 1, 0, keycode.QK_LAYER_LOCK);

    fixture.setKeymap(&.{ key_layer, key_a, key_trns, key_ll });

    fixture.pressKey(key_layer.row, key_layer.col);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));
    try testing.expect(!layer_lock.isLayerLocked(1));

    fixture.pressKey(key_ll.row, key_ll.col);
    fixture.runOneScanLoop();
    fixture.releaseKey(key_ll.row, key_ll.col);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));
    try testing.expect(layer_lock.isLayerLocked(1));

    fixture.releaseKey(key_layer.row, key_layer.col);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));
    try testing.expect(layer_lock.isLayerLocked(1));

    fixture.pressKey(key_ll.row, key_ll.col);
    fixture.runOneScanLoop();
    try testing.expect(!fixture.isLayerOn(1));
    try testing.expect(!layer_lock.isLayerLocked(1));
}

// ============================================================
// 3. LayerLockLayerTapTest
// ============================================================

test "LayerLockLayerTapTest" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    const key_layer = KeymapKey.init(0, 0, 0, keycode.LT(1, KC.B));
    const key_a = KeymapKey.init(0, 1, 0, KC.A);
    const key_trns = KeymapKey.init(1, 0, 0, KC.TRNS);
    const key_ll = KeymapKey.init(1, 1, 0, keycode.QK_LAYER_LOCK);

    fixture.setKeymap(&.{ key_layer, key_a, key_trns, key_ll });

    fixture.pressKey(key_layer.row, key_layer.col);
    fixture.idleFor(TAPPING_TERM);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));

    fixture.pressKey(key_ll.row, key_ll.col);
    fixture.runOneScanLoop();
    fixture.releaseKey(key_ll.row, key_ll.col);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));
    try testing.expect(layer_lock.isLayerLocked(1));

    fixture.pressKey(key_ll.row, key_ll.col);
    fixture.runOneScanLoop();
    try testing.expect(!fixture.isLayerOn(1));
    try testing.expect(!layer_lock.isLayerLocked(1));
}

// ============================================================
// 6. LayerLockTimeoutTest
// ============================================================

test "LayerLockTimeoutTest" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    layer_lock.idle_timeout = LAYER_LOCK_IDLE_TIMEOUT;

    const key_layer = KeymapKey.init(0, 0, 0, keycode.MO(1));
    const key_a = KeymapKey.init(0, 1, 0, KC.A);
    const key_trns = KeymapKey.init(1, 0, 0, KC.TRNS);
    const key_ll = KeymapKey.init(1, 1, 0, keycode.QK_LAYER_LOCK);

    fixture.setKeymap(&.{ key_layer, key_a, key_trns, key_ll });

    fixture.pressKey(key_layer.row, key_layer.col);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));

    fixture.pressKey(key_ll.row, key_ll.col);
    fixture.runOneScanLoop();
    fixture.releaseKey(key_ll.row, key_ll.col);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));

    fixture.releaseKey(key_layer.row, key_layer.col);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));
    try testing.expect(layer_lock.isLayerLocked(1));

    fixture.idleFor(@intCast(LAYER_LOCK_IDLE_TIMEOUT));
    fixture.runOneScanLoop();
    try testing.expect(!fixture.isLayerOn(1));
    try testing.expect(!layer_lock.isLayerLocked(1));
}

// ============================================================
// 7. ToKeyOverridesLayerLock
// ============================================================

test "ToKeyOverridesLayerLock" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    const key_layer = KeymapKey.init(0, 0, 0, keycode.MO(1));
    const key_to0 = KeymapKey.init(1, 0, 0, keycode.TO(0));
    const key_ll = KeymapKey.init(1, 1, 0, keycode.QK_LAYER_LOCK);

    fixture.setKeymap(&.{ key_layer, key_to0, key_ll });

    layer_lock.layerLockOn(1);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));
    try testing.expect(layer_lock.isLayerLocked(1));

    fixture.pressKey(key_to0.row, key_to0.col);
    fixture.runOneScanLoop();
    fixture.releaseKey(key_to0.row, key_to0.col);
    fixture.runOneScanLoop();
    try testing.expect(!fixture.isLayerOn(1));
    try testing.expect(!layer_lock.isLayerLocked(1));
}

// ============================================================
// 8. LayerClearOverridesLayerLock
// ============================================================

test "LayerClearOverridesLayerLock" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    const key_layer = KeymapKey.init(0, 0, 0, keycode.MO(1));
    const key_a = KeymapKey.init(0, 1, 0, KC.A);
    const key_ll = KeymapKey.init(1, 1, 0, keycode.QK_LAYER_LOCK);

    fixture.setKeymap(&.{ key_layer, key_a, key_ll });

    layer_lock.layerLockOn(1);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));
    try testing.expect(layer_lock.isLayerLocked(1));

    fixture.layerClear();
    fixture.pressKey(key_a.row, key_a.col);
    fixture.runOneScanLoop();
    try testing.expect(!fixture.isLayerOn(1));
    try testing.expect(!layer_lock.isLayerLocked(1));
}
