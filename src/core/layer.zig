//! レイヤー状態管理
//! C版 quantum/action_layer.c に相当
//!
//! 16レイヤーのビットマスクベースのレイヤー管理。

pub const LayerState = u16;
pub const MAX_LAYERS: u4 = 16;

var layer_state: LayerState = 1; // Layer 0 active by default
var default_layer_state: LayerState = 1;

pub fn getLayerState() LayerState {
    return layer_state;
}

pub fn getDefaultLayerState() LayerState {
    return default_layer_state;
}

pub fn isLayerOn(l: u4) bool {
    return (layer_state & (@as(LayerState, 1) << l)) != 0;
}

pub fn layerOn(l: u4) void {
    layer_state |= @as(LayerState, 1) << l;
}

pub fn layerOff(l: u4) void {
    layer_state &= ~(@as(LayerState, 1) << l);
}

pub fn layerInvert(l: u4) void {
    layer_state ^= @as(LayerState, 1) << l;
}

pub fn layerMove(l: u4) void {
    layer_state = @as(LayerState, 1) << l;
}

pub fn layerClear() void {
    layer_state = 0;
}

pub fn layerStateSet(s: LayerState) void {
    layer_state = s;
}

// Default layer operations

pub fn defaultLayerSet(l: u4) void {
    default_layer_state = @as(LayerState, 1) << l;
    layer_state = default_layer_state;
}

pub fn defaultLayerOr(bits: LayerState) void {
    default_layer_state |= bits;
}

pub fn defaultLayerAnd(bits: LayerState) void {
    default_layer_state &= bits;
}

pub fn defaultLayerXor(bits: LayerState) void {
    default_layer_state ^= bits;
}

/// Get the highest active layer
pub fn getHighestLayer(state: LayerState) u4 {
    if (state == 0) return 0;
    var i: u4 = 15;
    while (true) {
        if (state & (@as(LayerState, 1) << i) != 0) return i;
        if (i == 0) break;
        i -= 1;
    }
    return 0;
}

pub fn reset() void {
    layer_state = 1;
    default_layer_state = 1;
}

// ============================================================
// Tests
// ============================================================

const testing = @import("std").testing;

test "layer on/off" {
    reset();
    try testing.expect(isLayerOn(0));
    try testing.expect(!isLayerOn(1));

    layerOn(1);
    try testing.expect(isLayerOn(1));

    layerOff(1);
    try testing.expect(!isLayerOn(1));
}

test "layer move" {
    reset();
    layerMove(2);
    try testing.expect(!isLayerOn(0));
    try testing.expect(!isLayerOn(1));
    try testing.expect(isLayerOn(2));
    reset();
}

test "layer invert" {
    reset();
    layerInvert(1);
    try testing.expect(isLayerOn(1));
    layerInvert(1);
    try testing.expect(!isLayerOn(1));
    reset();
}

test "getHighestLayer" {
    try testing.expectEqual(@as(u4, 0), getHighestLayer(0b0001));
    try testing.expectEqual(@as(u4, 1), getHighestLayer(0b0011));
    try testing.expectEqual(@as(u4, 3), getHighestLayer(0b1001));
    try testing.expectEqual(@as(u4, 0), getHighestLayer(0));
}

test "default layer" {
    reset();
    defaultLayerSet(2);
    try testing.expect(isLayerOn(2));
    try testing.expect(!isLayerOn(0));
    reset();
}
