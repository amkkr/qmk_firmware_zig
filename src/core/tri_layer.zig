// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zig port of quantum/process_keycode/process_tri_layer.c
// Original: Copyright 2023 QMK

//! Tri Layer の実装
//! C版 quantum/tri_layer.c + quantum/process_keycode/process_tri_layer.c の移植
//!
//! Lower と Upper レイヤーを同時に有効にすると Adjust レイヤーが自動的に有効になる。
//!
//! キーコード:
//!   - QK_TRI_LAYER_LOWER (0x7C77): Lower レイヤーのオン/オフ
//!   - QK_TRI_LAYER_UPPER (0x7C78): Upper レイヤーのオン/オフ

const layer = @import("layer.zig");
const keycode = @import("keycode.zig");

/// デフォルトのレイヤー番号
const DEFAULT_LOWER_LAYER: u5 = 1;
const DEFAULT_UPPER_LAYER: u5 = 2;
const DEFAULT_ADJUST_LAYER: u5 = 3;

/// Tri Layer 設定
var lower_layer: u5 = DEFAULT_LOWER_LAYER;
var upper_layer: u5 = DEFAULT_UPPER_LAYER;
var adjust_layer: u5 = DEFAULT_ADJUST_LAYER;

// ============================================================
// Getter / Setter
// ============================================================

pub fn getLowerLayer() u5 {
    return lower_layer;
}

pub fn getUpperLayer() u5 {
    return upper_layer;
}

pub fn getAdjustLayer() u5 {
    return adjust_layer;
}

pub fn setLowerLayer(l: u5) void {
    lower_layer = l;
}

pub fn setUpperLayer(l: u5) void {
    upper_layer = l;
}

pub fn setAdjustLayer(l: u5) void {
    adjust_layer = l;
}

/// Lower/Upper/Adjust レイヤーを一括設定する
pub fn setTriLayerLayers(lower: u5, upper: u5, adjust: u5) void {
    lower_layer = lower;
    upper_layer = upper;
    adjust_layer = adjust;
}

// ============================================================
// Core logic
// ============================================================

/// Lower/Upper の状態に基づいて Adjust レイヤーを更新する
/// Lower と Upper が両方 ON のとき Adjust を ON、それ以外では OFF にする
pub fn updateTriLayer(lower: u5, upper: u5, adjust: u5) void {
    layer.updateTriLayer(lower, upper, adjust);
}

/// QK_TRI_LAYER_LOWER/UPPER キーイベントを処理する
///
/// `kc`:      キーコード（QK_TRI_LAYER_LOWER または QK_TRI_LAYER_UPPER）
/// `pressed`: true = プレス、false = リリース
///
/// 戻り値: true = 処理済み、false = このキーではない（通常の処理を継続）
pub fn processTriLayer(kc: keycode.Keycode, pressed: bool) bool {
    if (kc == keycode.QK_TRI_LAYER_LOWER) {
        if (pressed) {
            layer.layerOn(lower_layer);
        } else {
            layer.layerOff(lower_layer);
        }
        updateTriLayer(lower_layer, upper_layer, adjust_layer);
        return true;
    }
    if (kc == keycode.QK_TRI_LAYER_UPPER) {
        if (pressed) {
            layer.layerOn(upper_layer);
        } else {
            layer.layerOff(upper_layer);
        }
        updateTriLayer(lower_layer, upper_layer, adjust_layer);
        return true;
    }
    return false;
}

/// 状態をリセットする（テスト用）
pub fn reset() void {
    lower_layer = DEFAULT_LOWER_LAYER;
    upper_layer = DEFAULT_UPPER_LAYER;
    adjust_layer = DEFAULT_ADJUST_LAYER;
}

// ============================================================
// Tests
// ============================================================

const testing = @import("std").testing;

test "processTriLayer: lower press activates lower layer" {
    reset();
    layer.resetState();

    _ = processTriLayer(keycode.QK_TRI_LAYER_LOWER, true);
    try testing.expect(layer.layerStateIs(1)); // lower = 1
    try testing.expect(!layer.layerStateIs(3)); // adjust = 3 (upper が OFF なのでOFFのまま)

    _ = processTriLayer(keycode.QK_TRI_LAYER_LOWER, false);
    try testing.expect(!layer.layerStateIs(1));
}

test "processTriLayer: upper press activates upper layer" {
    reset();
    layer.resetState();

    _ = processTriLayer(keycode.QK_TRI_LAYER_UPPER, true);
    try testing.expect(layer.layerStateIs(2)); // upper = 2
    try testing.expect(!layer.layerStateIs(3)); // adjust = 3 (lower が OFF なのでOFFのまま)

    _ = processTriLayer(keycode.QK_TRI_LAYER_UPPER, false);
    try testing.expect(!layer.layerStateIs(2));
}

test "processTriLayer: lower+upper activates adjust layer" {
    reset();
    layer.resetState();

    // Lower と Upper を両方押すと Adjust が ON
    _ = processTriLayer(keycode.QK_TRI_LAYER_LOWER, true);
    _ = processTriLayer(keycode.QK_TRI_LAYER_UPPER, true);
    try testing.expect(layer.layerStateIs(1));
    try testing.expect(layer.layerStateIs(2));
    try testing.expect(layer.layerStateIs(3)); // adjust = 3

    // Lower を離すと Adjust が OFF
    _ = processTriLayer(keycode.QK_TRI_LAYER_LOWER, false);
    try testing.expect(!layer.layerStateIs(3));
}

test "processTriLayer: returns false for unrelated keycode" {
    reset();
    layer.resetState();

    const result = processTriLayer(0x0004, true); // KC_A
    try testing.expect(!result);
}

test "setTriLayerLayers: カスタムレイヤー設定" {
    reset();
    layer.resetState();

    setTriLayerLayers(4, 5, 6);
    try testing.expectEqual(@as(u5, 4), getLowerLayer());
    try testing.expectEqual(@as(u5, 5), getUpperLayer());
    try testing.expectEqual(@as(u5, 6), getAdjustLayer());

    _ = processTriLayer(keycode.QK_TRI_LAYER_LOWER, true);
    _ = processTriLayer(keycode.QK_TRI_LAYER_UPPER, true);
    try testing.expect(layer.layerStateIs(4));
    try testing.expect(layer.layerStateIs(5));
    try testing.expect(layer.layerStateIs(6));

    reset();
}
