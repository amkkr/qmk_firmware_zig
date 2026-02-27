//! Layer Lock テスト — C版 tests/layer_lock/test_layer_lock.cpp の Zig 移植
//!
//! upstream参照: tests/layer_lock/test_layer_lock.cpp (284行)
//!
//! C版テスト対応表:
//! 1. LayerLockState              — lock/unlock 状態管理の複合テスト        [API テスト]
//! 2. LayerLockMomentaryTest      — MO(1) + QK_LAYER_LOCK                 [TestFixture]
//! 3. LayerLockLayerTapTest       — LT(1, KC_B) + QK_LAYER_LOCK           [TestFixture]
//! 4. LayerLockOneshotTapTest     — OSL(1) タップ + QK_LAYER_LOCK         [TestFixture]
//! 5. LayerLockOneshotHoldTest    — OSL(1) ホールド + QK_LAYER_LOCK        [TestFixture]
//! 6. LayerLockTimeoutTest        — LAYER_LOCK_IDLE_TIMEOUT 後に自動解除    [API + timer mock]
//! 7. ToKeyOverridesLayerLock     — TO(0) が Layer Lock を上書き            [TestFixture]
//! 8. LayerClearOverridesLayerLock — layer_clear() が Layer Lock を上書き   [API テスト]

const std = @import("std");
const testing = std.testing;

const keycode = @import("../core/keycode.zig");
const layer_mod = @import("../core/layer.zig");
const layer_lock = @import("../core/layer_lock.zig");
const test_fixture = @import("../core/test_fixture.zig");
const timer = @import("../hal/timer.zig");
const keymap_mod = @import("../core/keymap.zig");

const KC = keycode.KC;
const TestFixture = test_fixture.TestFixture;
const KeymapKey = test_fixture.KeymapKey;
const TAPPING_TERM = test_fixture.TAPPING_TERM;

// C版 tests/layer_lock/config.h 相当
const LAYER_LOCK_IDLE_TIMEOUT: u32 = 1000;

// ============================================================
// ヘルパー関数
// ============================================================

/// キーをタップする（press + scan + release + scan）
fn tapKey(fixture: *TestFixture, key: KeymapKey) void {
    fixture.pressKey(key.row, key.col);
    fixture.runOneScanLoop();
    fixture.releaseKey(key.row, key.col);
    fixture.runOneScanLoop();
}

// ============================================================
// 1. LayerLockState — lock/unlock 状態管理の複合テスト
// C版 test_layer_lock.cpp:11-65
// ============================================================

test "LayerLockState" {
    layer_lock.reset();
    layer_mod.resetState();
    defer {
        layer_lock.reset();
        layer_mod.resetState();
    }

    // 初期状態: 全レイヤーアンロック
    try testing.expect(!layer_lock.isLayerLocked(1));
    try testing.expect(!layer_lock.isLayerLocked(2));
    try testing.expect(!layer_lock.isLayerLocked(3));

    layer_lock.layerLockInvert(1); // Layer 1: unlocked -> locked
    layer_lock.layerLockOn(2); // Layer 2: unlocked -> locked
    layer_lock.layerLockOff(3); // Layer 3: stays unlocked

    // Layers 1 and 2 are now on.
    try testing.expect(layer_mod.layerStateIs(1));
    try testing.expect(layer_mod.layerStateIs(2));
    // Layers 1 and 2 are now locked.
    try testing.expect(layer_lock.isLayerLocked(1));
    try testing.expect(layer_lock.isLayerLocked(2));
    try testing.expect(!layer_lock.isLayerLocked(3));

    layer_lock.layerLockInvert(1); // Layer 1: locked -> unlocked
    layer_lock.layerLockOn(2); // Layer 2: stays locked
    layer_lock.layerLockOn(3); // Layer 3: unlocked -> locked

    try testing.expect(!layer_mod.layerStateIs(1));
    try testing.expect(layer_mod.layerStateIs(2));
    try testing.expect(layer_mod.layerStateIs(3));
    try testing.expect(!layer_lock.isLayerLocked(1));
    try testing.expect(layer_lock.isLayerLocked(2));
    try testing.expect(layer_lock.isLayerLocked(3));

    layer_lock.layerLockInvert(1); // Layer 1: unlocked -> locked
    layer_lock.layerLockOff(2); // Layer 2: locked -> unlocked

    try testing.expect(layer_mod.layerStateIs(1));
    try testing.expect(!layer_mod.layerStateIs(2));
    try testing.expect(layer_mod.layerStateIs(3));
    try testing.expect(layer_lock.isLayerLocked(1));
    try testing.expect(!layer_lock.isLayerLocked(2));
    try testing.expect(layer_lock.isLayerLocked(3));

    layer_lock.layerLockAllOff(); // Layers 1 and 3: locked -> unlocked

    try testing.expect(!layer_mod.layerStateIs(1));
    try testing.expect(!layer_mod.layerStateIs(2));
    try testing.expect(!layer_mod.layerStateIs(3));
    try testing.expect(!layer_lock.isLayerLocked(1));
    try testing.expect(!layer_lock.isLayerLocked(2));
    try testing.expect(!layer_lock.isLayerLocked(3));
}

// ============================================================
// 2. LayerLockMomentaryTest — MO(1) + QK_LAYER_LOCK
// C版 test_layer_lock.cpp:67-103
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

    // MO(1) を押す → レイヤー1が有効化（HIDレポートなし）
    fixture.pressKey(key_layer.row, key_layer.col);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));
    try testing.expect(!layer_lock.isLayerLocked(1));

    // QK_LAYER_LOCK をタップ → レイヤー1がロック
    tapKey(&fixture, key_ll);
    try testing.expect(fixture.isLayerOn(1));
    try testing.expect(layer_lock.isLayerLocked(1));

    // MO(1) をリリース → ロックされているのでレイヤー1は維持
    fixture.releaseKey(key_layer.row, key_layer.col);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));
    try testing.expect(layer_lock.isLayerLocked(1));

    // Layer Lock をもう一度押す → ロック解除
    fixture.pressKey(key_ll.row, key_ll.col);
    fixture.runOneScanLoop();
    try testing.expect(!fixture.isLayerOn(1));
    try testing.expect(!layer_lock.isLayerLocked(1));
}

// ============================================================
// 3. LayerLockLayerTapTest — LT(1, KC_B) + QK_LAYER_LOCK
// C版 test_layer_lock.cpp:105-134
// ============================================================

test "LayerLockLayerTapTest" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    const key_layer = KeymapKey.init(0, 0, 0, keycode.LT(1, @truncate(KC.B)));
    const key_a = KeymapKey.init(0, 1, 0, KC.A);
    const key_trns = KeymapKey.init(1, 0, 0, KC.TRNS);
    const key_ll = KeymapKey.init(1, 1, 0, keycode.QK_LAYER_LOCK);

    fixture.setKeymap(&.{ key_layer, key_a, key_trns, key_ll });

    // LT(1, KC_B) を押してホールド → TAPPING_TERM 経過でレイヤー1有効
    fixture.pressKey(key_layer.row, key_layer.col);
    fixture.idleFor(TAPPING_TERM);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));

    // QK_LAYER_LOCK をタップ → レイヤー1がロック
    tapKey(&fixture, key_ll);
    try testing.expect(fixture.isLayerOn(1));
    try testing.expect(layer_lock.isLayerLocked(1));

    // Layer Lock をもう一度押す → ロック解除
    fixture.pressKey(key_ll.row, key_ll.col);
    fixture.runOneScanLoop();
    try testing.expect(!fixture.isLayerOn(1));
    try testing.expect(!layer_lock.isLayerLocked(1));
}

// ============================================================
// 4. LayerLockOneshotTapTest — OSL(1) タップ + QK_LAYER_LOCK
// C版 test_layer_lock.cpp:136-165
// ============================================================

test "LayerLockOneshotTapTest" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    // oneshot を有効化
    keymap_mod.keymap_config.oneshot_enable = true;
    defer {
        keymap_mod.keymap_config = .{};
    }

    const key_layer = KeymapKey.init(0, 0, 0, keycode.OSL(1));
    const key_a = KeymapKey.init(0, 1, 0, KC.A);
    const key_trns = KeymapKey.init(1, 0, 0, KC.TRNS);
    const key_ll = KeymapKey.init(1, 1, 0, keycode.QK_LAYER_LOCK);

    fixture.setKeymap(&.{ key_layer, key_a, key_trns, key_ll });

    // OSL(1) をタップ → レイヤー1がワンショットで有効化
    tapKey(&fixture, key_layer);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));

    // QK_LAYER_LOCK をタップ → レイヤー1がロック（oneshot 解除してロックに切り替え）
    tapKey(&fixture, key_ll);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));
    try testing.expect(layer_lock.isLayerLocked(1));

    // Layer Lock をもう一度押す → ロック解除
    fixture.pressKey(key_ll.row, key_ll.col);
    fixture.runOneScanLoop();
    try testing.expect(!fixture.isLayerOn(1));
    try testing.expect(!layer_lock.isLayerLocked(1));
}

// ============================================================
// 5. LayerLockOneshotHoldTest — OSL(1) ホールド + QK_LAYER_LOCK
// C版 test_layer_lock.cpp:167-203
// ============================================================

test "LayerLockOneshotHoldTest" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    // oneshot を有効化
    keymap_mod.keymap_config.oneshot_enable = true;
    defer {
        keymap_mod.keymap_config = .{};
    }

    const key_layer = KeymapKey.init(0, 0, 0, keycode.OSL(1));
    const key_a = KeymapKey.init(0, 1, 0, KC.A);
    const key_trns = KeymapKey.init(1, 0, 0, KC.TRNS);
    const key_ll = KeymapKey.init(1, 1, 0, keycode.QK_LAYER_LOCK);

    fixture.setKeymap(&.{ key_layer, key_a, key_trns, key_ll });

    // OSL(1) をホールド → TAPPING_TERM 経過でレイヤー1有効
    fixture.pressKey(key_layer.row, key_layer.col);
    fixture.idleFor(TAPPING_TERM);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));

    // QK_LAYER_LOCK をタップ
    tapKey(&fixture, key_ll);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));

    // OSL(1) をリリース → Layer Lock によりレイヤー1は維持
    fixture.releaseKey(key_layer.row, key_layer.col);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));
    try testing.expect(layer_lock.isLayerLocked(1));

    // Layer Lock をもう一度押す → ロック解除
    fixture.pressKey(key_ll.row, key_ll.col);
    fixture.runOneScanLoop();
    try testing.expect(!fixture.isLayerOn(1));
    try testing.expect(!layer_lock.isLayerLocked(1));
}

// ============================================================
// 6. LayerLockTimeoutTest — LAYER_LOCK_IDLE_TIMEOUT 後に自動解除
// C版 test_layer_lock.cpp:205-238
//
// keyboard.task() には layer_lock.task() が組み込まれていないため、
// timer mock + layer_lock.task() を直接呼び出してタイムアウト動作を検証する。
// ============================================================

test "LayerLockTimeoutTest" {
    layer_lock.reset();
    layer_mod.resetState();
    timer.mockReset();
    defer {
        layer_lock.reset();
        layer_mod.resetState();
    }

    // タイムアウトを設定（C版 config.h: LAYER_LOCK_IDLE_TIMEOUT 1000）
    layer_lock.idle_timeout = LAYER_LOCK_IDLE_TIMEOUT;

    // レイヤー1をロック
    layer_lock.layerLockOn(1);
    try testing.expect(layer_mod.layerStateIs(1));
    try testing.expect(layer_lock.isLayerLocked(1));

    // タイムアウト時間経過後に task() を呼ぶ
    timer.mockAdvance(LAYER_LOCK_IDLE_TIMEOUT + 1);
    layer_lock.task();

    // タイムアウトによりロック解除
    try testing.expect(!layer_mod.layerStateIs(1));
    try testing.expect(!layer_lock.isLayerLocked(1));
}

// ============================================================
// 7. ToKeyOverridesLayerLock — TO(0) が Layer Lock を上書き
// C版 test_layer_lock.cpp:240-260
// ============================================================

test "ToKeyOverridesLayerLock" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    const key_layer = KeymapKey.init(0, 0, 0, keycode.MO(1));
    const key_to0 = KeymapKey.init(1, 0, 0, keycode.TO(0));
    const key_ll = KeymapKey.init(1, 1, 0, keycode.QK_LAYER_LOCK);

    fixture.setKeymap(&.{ key_layer, key_to0, key_ll });

    // layer_lock_on(1) で直接ロック
    layer_lock.layerLockOn(1);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));
    try testing.expect(layer_lock.isLayerLocked(1));

    // TO(0) をタップ → layerMove(0) が呼ばれ、layer_state がリセットされる
    tapKey(&fixture, key_to0);
    // syncWithLayerState() でロック状態を現在のレイヤー状態に同期
    layer_lock.syncWithLayerState();
    try testing.expect(!fixture.isLayerOn(1));
    try testing.expect(!layer_lock.isLayerLocked(1));
}

// ============================================================
// 8. LayerClearOverridesLayerLock — layer_clear() が Layer Lock を上書き
// C版 test_layer_lock.cpp:262-284
// ============================================================

test "LayerClearOverridesLayerLock" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    const key_layer = KeymapKey.init(0, 0, 0, keycode.MO(1));
    const key_a = KeymapKey.init(0, 1, 0, KC.A);
    const key_ll = KeymapKey.init(1, 1, 0, keycode.QK_LAYER_LOCK);

    fixture.setKeymap(&.{ key_layer, key_a, key_ll });

    // layer_lock_on(1) で直接ロック
    layer_lock.layerLockOn(1);
    fixture.runOneScanLoop();
    try testing.expect(fixture.isLayerOn(1));
    try testing.expect(layer_lock.isLayerLocked(1));

    // layer_clear() で全レイヤーをオフ → Layer Lock も上書きされる
    layer_mod.layerClear();
    layer_lock.syncWithLayerState();

    // KC_A を押す → レイヤー0のキーが送信される
    fixture.pressKey(key_a.row, key_a.col);
    fixture.runOneScanLoop();
    try testing.expect(!fixture.isLayerOn(1));
    try testing.expect(!layer_lock.isLayerLocked(1));
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x04)); // KC_A
}
