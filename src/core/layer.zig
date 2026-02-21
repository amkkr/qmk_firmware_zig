//! QMK Layer management module (Zig port)
//! Based on quantum/action_layer.c
//!
//! Manages global layer state (bitmask) and source layer cache.
//! Layers are stacked with higher-numbered layers taking priority.

const std = @import("std");
const keycode = @import("keycode.zig");
const action_code = @import("action_code.zig");
const Keycode = keycode.Keycode;

pub const MAX_LAYERS: u5 = 16;
pub const LayerState = u32;

// ============================================================
// Global layer state
// ============================================================

var layer_state: LayerState = 0;
var default_layer_state: LayerState = 1; // Layer 0

// ============================================================
// Layer state query
// ============================================================

/// Get the current layer state bitmask
pub fn getLayerState() LayerState {
    return layer_state;
}

/// Get the current default layer state bitmask
pub fn getDefaultLayerState() LayerState {
    return default_layer_state;
}

/// Check if a layer is active (may be shadowed by higher layers)
/// When layer_state is 0, layer 0 is considered active (matching C layer_state_cmp)
pub fn layerStateIs(layer: u5) bool {
    return layerStateCmp(layer_state, layer);
}

/// Compare a layer state against a specific layer
/// When state is 0, returns true only for layer 0
pub fn layerStateCmp(state: LayerState, layer: u5) bool {
    if (state == 0) {
        return layer == 0;
    }
    return (state & (@as(LayerState, 1) << layer)) != 0;
}

// ============================================================
// Layer state manipulation
// ============================================================

/// Set the layer state directly
pub fn layerStateSet(state: LayerState) void {
    layer_state = state;
}

/// Turn on a specific layer
pub fn layerOn(layer: u5) void {
    layerStateSet(layer_state | (@as(LayerState, 1) << layer));
}

/// Turn off a specific layer
pub fn layerOff(layer: u5) void {
    layerStateSet(layer_state & ~(@as(LayerState, 1) << layer));
}

/// Move to a specific layer (turn on only that layer, turn off all others)
pub fn layerMove(layer: u5) void {
    layerStateSet(@as(LayerState, 1) << layer);
}

/// Toggle a specific layer
pub fn layerInvert(layer: u5) void {
    layerStateSet(layer_state ^ (@as(LayerState, 1) << layer));
}

/// Turn off all layers
pub fn layerClear() void {
    layerStateSet(0);
}

/// Bitwise OR with layer state
pub fn layerOr(state: LayerState) void {
    layerStateSet(layer_state | state);
}

/// Bitwise AND with layer state
pub fn layerAnd(state: LayerState) void {
    layerStateSet(layer_state & state);
}

/// Bitwise XOR with layer state
pub fn layerXor(state: LayerState) void {
    layerStateSet(layer_state ^ state);
}

// ============================================================
// Default layer operations
// ============================================================

/// Set the default layer state
pub fn defaultLayerSet(state: LayerState) void {
    default_layer_state = state;
}

/// OR bits into default layer state
pub fn defaultLayerOr(state: LayerState) void {
    default_layer_state |= state;
}

// ============================================================
// Helper functions
// ============================================================

/// Get the highest active layer from a state bitmask
/// Returns 0 if no layer is active
pub fn getHighestLayer(state: LayerState) u5 {
    if (state == 0) return 0;
    // Find the position of the highest set bit
    var i: u5 = MAX_LAYERS - 1;
    while (true) {
        if (state & (@as(LayerState, 1) << i) != 0) {
            return i;
        }
        if (i == 0) break;
        i -= 1;
    }
    return 0;
}

// ============================================================
// Source layers cache
// ============================================================
// Records which layer a key was resolved from when pressed,
// so that on release the same layer is used (prevents stuck keys
// when layers change while a key is held).

const MATRIX_ROWS = 4;
const MATRIX_COLS = 12;
const CACHE_ENTRIES = MATRIX_ROWS * MATRIX_COLS;
const MAX_LAYER_BITS = 4; // log2(MAX_LAYERS) = log2(16) = 4

var source_layers_cache: [cacheStorageSize(CACHE_ENTRIES)][MAX_LAYER_BITS]u8 = .{.{0} ** MAX_LAYER_BITS} ** cacheStorageSize(CACHE_ENTRIES);

fn cacheStorageSize(entries: usize) usize {
    return (entries + 7) / 8;
}

/// Update the source layer cache for a key position
pub fn updateSourceLayersCache(row: u8, col: u8, layer: u5) void {
    if (row >= MATRIX_ROWS or col >= MATRIX_COLS) return;
    const entry: u16 = @as(u16, row) * MATRIX_COLS + @as(u16, col);
    updateSourceLayersCacheImpl(layer, entry, &source_layers_cache);
}

/// Read the source layer cache for a key position
pub fn readSourceLayersCache(row: u8, col: u8) u5 {
    if (row >= MATRIX_ROWS or col >= MATRIX_COLS) return 0;
    const entry: u16 = @as(u16, row) * MATRIX_COLS + @as(u16, col);
    return readSourceLayersCacheImpl(entry, &source_layers_cache);
}

fn updateSourceLayersCacheImpl(layer: u5, entry_number: u16, cache: *[cacheStorageSize(CACHE_ENTRIES)][MAX_LAYER_BITS]u8) void {
    const storage_idx = entry_number / 8;
    const storage_bit: u3 = @truncate(entry_number);
    for (0..MAX_LAYER_BITS) |bit_number| {
        const layer_bit: u1 = if (layer & (@as(u5, 1) << @as(u3, @truncate(bit_number))) != 0) 1 else 0;
        // Set or clear the bit at storage_bit position
        cache[storage_idx][bit_number] = (cache[storage_idx][bit_number] & ~(@as(u8, 1) << storage_bit)) | (@as(u8, layer_bit) << storage_bit);
    }
}

fn readSourceLayersCacheImpl(entry_number: u16, cache: *const [cacheStorageSize(CACHE_ENTRIES)][MAX_LAYER_BITS]u8) u5 {
    const storage_idx = entry_number / 8;
    const storage_bit: u3 = @truncate(entry_number);
    var layer: u5 = 0;
    for (0..MAX_LAYER_BITS) |bit_number| {
        if (cache[storage_idx][bit_number] & (@as(u8, 1) << storage_bit) != 0) {
            layer |= @as(u5, 1) << @as(u3, @truncate(bit_number));
        }
    }
    return layer;
}

// ============================================================
// Layer resolution
// ============================================================

/// Find the active layer that has a non-transparent key at the given position.
/// Checks layers from highest to lowest, combining layer_state and default_layer_state.
/// keymapFn: fn(layer: u5, row: u8, col: u8) Keycode
pub fn layerSwitchGetLayer(keymapFn: anytype, row: u8, col: u8) u5 {
    const layers = layer_state | default_layer_state;
    // Check from highest layer down
    var i: i6 = MAX_LAYERS - 1;
    while (i >= 0) : (i -= 1) {
        const l: u5 = @intCast(i);
        if (layers & (@as(LayerState, 1) << l) != 0) {
            const kc = keymapFn(l, row, col);
            const action = action_code.keycodeToAction(kc);
            if (action.code != action_code.ACTION_TRANSPARENT) {
                return l;
            }
        }
    }
    // Fall back to layer 0
    return 0;
}

// ============================================================
// Tri-layer support
// ============================================================

/// Update tri-layer state: when both layer1 and layer2 are active, activate layer3
pub fn updateTriLayerState(state: LayerState, layer1: u5, layer2: u5, layer3: u5) LayerState {
    const mask12 = (@as(LayerState, 1) << layer1) | (@as(LayerState, 1) << layer2);
    const mask3 = @as(LayerState, 1) << layer3;
    return if (state & mask12 == mask12) state | mask3 else state & ~mask3;
}

/// Update tri-layer: applies updateTriLayerState to the current layer_state
pub fn updateTriLayer(layer1: u5, layer2: u5, layer3: u5) void {
    layerStateSet(updateTriLayerState(layer_state, layer1, layer2, layer3));
}

// ============================================================
// State reset (for testing)
// ============================================================

/// Reset all layer state to defaults (for testing)
pub fn resetState() void {
    layer_state = 0;
    default_layer_state = 1;
    source_layers_cache = .{.{0} ** MAX_LAYER_BITS} ** cacheStorageSize(CACHE_ENTRIES);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "layerStateIs: layer 0 default active" {
    resetState();
    // layer_state is 0, so layerStateCmp returns true only for layer 0
    try testing.expect(layerStateIs(0));
    try testing.expect(!layerStateIs(1));
}

test "layerOn/Off: bit operations" {
    resetState();
    layerOn(1);
    try testing.expectEqual(@as(LayerState, 0b10), layer_state);
    try testing.expect(layerStateIs(1));

    layerOn(3);
    try testing.expectEqual(@as(LayerState, 0b1010), layer_state);

    layerOff(1);
    try testing.expectEqual(@as(LayerState, 0b1000), layer_state);
    try testing.expect(!layerStateIs(1));
    try testing.expect(layerStateIs(3));
}

test "layerMove: only one layer active" {
    resetState();
    layerOn(1);
    layerOn(2);
    layerMove(3);
    try testing.expectEqual(@as(LayerState, 0b1000), layer_state);
    try testing.expect(layerStateIs(3));
    try testing.expect(!layerStateIs(1));
    try testing.expect(!layerStateIs(2));
}

test "layerInvert: toggle behavior" {
    resetState();
    layerInvert(2);
    try testing.expect(layerStateIs(2));
    layerInvert(2);
    try testing.expect(!layerStateIs(2));
}

test "layerClear: clears all layers" {
    resetState();
    layerOn(1);
    layerOn(3);
    layerOn(5);
    layerClear();
    try testing.expectEqual(@as(LayerState, 0), layer_state);
    // With layer_state=0, layerStateIs(0) returns true
    try testing.expect(layerStateIs(0));
}

test "getHighestLayer: returns highest active layer" {
    try testing.expectEqual(@as(u5, 0), getHighestLayer(0));
    try testing.expectEqual(@as(u5, 0), getHighestLayer(0b1));
    try testing.expectEqual(@as(u5, 1), getHighestLayer(0b10));
    try testing.expectEqual(@as(u5, 3), getHighestLayer(0b1010));
    try testing.expectEqual(@as(u5, 15), getHighestLayer(0b1000_0000_0000_0000));
}

test "sourceLayersCache: store and retrieve" {
    resetState();
    updateSourceLayersCache(0, 0, 3);
    try testing.expectEqual(@as(u5, 3), readSourceLayersCache(0, 0));

    updateSourceLayersCache(1, 5, 7);
    try testing.expectEqual(@as(u5, 7), readSourceLayersCache(1, 5));

    // Original cache entry unchanged
    try testing.expectEqual(@as(u5, 3), readSourceLayersCache(0, 0));

    // Unset entries return 0
    try testing.expectEqual(@as(u5, 0), readSourceLayersCache(2, 2));
}

test "sourceLayersCache: overwrite existing entry" {
    resetState();
    updateSourceLayersCache(0, 0, 5);
    try testing.expectEqual(@as(u5, 5), readSourceLayersCache(0, 0));

    updateSourceLayersCache(0, 0, 2);
    try testing.expectEqual(@as(u5, 2), readSourceLayersCache(0, 0));
}

test "sourceLayersCache: boundary values" {
    resetState();
    // Max layer value
    updateSourceLayersCache(0, 0, 15);
    try testing.expectEqual(@as(u5, 15), readSourceLayersCache(0, 0));

    // Layer 0
    updateSourceLayersCache(0, 1, 0);
    try testing.expectEqual(@as(u5, 0), readSourceLayersCache(0, 1));

    // Out of bounds returns 0
    try testing.expectEqual(@as(u5, 0), readSourceLayersCache(10, 10));
}

test "updateTriLayerState: both layers active enables third" {
    const state: LayerState = (@as(LayerState, 1) << 1) | (@as(LayerState, 1) << 2);
    const result = updateTriLayerState(state, 1, 2, 3);
    try testing.expect(result & (@as(LayerState, 1) << 3) != 0);
}

test "updateTriLayerState: one layer missing disables third" {
    const state: LayerState = @as(LayerState, 1) << 1; // Only layer 1
    const result = updateTriLayerState(state, 1, 2, 3);
    try testing.expect(result & (@as(LayerState, 1) << 3) == 0);
}

test "updateTriLayerState: removes layer 3 when condition no longer met" {
    // Start with all three layers active
    var state: LayerState = (@as(LayerState, 1) << 1) | (@as(LayerState, 1) << 2) | (@as(LayerState, 1) << 3);
    // Remove layer 2
    state &= ~(@as(LayerState, 1) << 2);
    const result = updateTriLayerState(state, 1, 2, 3);
    try testing.expect(result & (@as(LayerState, 1) << 3) == 0);
}

test "updateTriLayer: modifies global state" {
    resetState();
    layerOn(1);
    layerOn(2);
    updateTriLayer(1, 2, 3);
    try testing.expect(layerStateIs(3));
}

test "defaultLayerSet and defaultLayerOr" {
    resetState();
    defaultLayerSet(@as(LayerState, 1) << 2);
    try testing.expectEqual(@as(LayerState, 1) << 2, default_layer_state);

    defaultLayerOr(@as(LayerState, 1) << 3);
    try testing.expectEqual((@as(LayerState, 1) << 2) | (@as(LayerState, 1) << 3), default_layer_state);
}

test "layerSwitchGetLayer: finds active layer with non-transparent key" {
    resetState();
    default_layer_state = 1; // Layer 0

    // Mock keymap: layer 0 has KC_A, layer 1 has KC_TRNS (transparent)
    const keymapFn = struct {
        fn f(l: u5, _: u8, _: u8) Keycode {
            return switch (l) {
                0 => keycode.KC.A,
                1 => keycode.KC.TRNS,
                2 => keycode.KC.B,
                else => keycode.KC.NO,
            };
        }
    }.f;

    // Only default layer: should resolve to layer 0
    try testing.expectEqual(@as(u5, 0), layerSwitchGetLayer(keymapFn, 0, 0));

    // Layer 1 on but transparent → falls through to layer 0
    layerOn(1);
    try testing.expectEqual(@as(u5, 0), layerSwitchGetLayer(keymapFn, 0, 0));

    // Layer 2 on with KC_B → resolves to layer 2
    layerOn(2);
    try testing.expectEqual(@as(u5, 2), layerSwitchGetLayer(keymapFn, 0, 0));
}

test "layerOr/And/Xor operations" {
    resetState();
    layerOr(0b1010);
    try testing.expectEqual(@as(LayerState, 0b1010), layer_state);

    layerAnd(0b1110);
    try testing.expectEqual(@as(LayerState, 0b1010), layer_state);

    layerXor(0b1100);
    try testing.expectEqual(@as(LayerState, 0b0110), layer_state);
}
