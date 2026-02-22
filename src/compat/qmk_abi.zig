//! C ABI export stubs for QMK compatibility
//! Provides `export fn` wrappers around Zig core modules,
//! allowing C code to call into the Zig implementation.
//!
//! All exported functions use C-compatible types (u8, u16, u32, pointers).
//! Function names follow QMK C naming conventions (snake_case).

const std = @import("std");
const layer_mod = @import("../core/layer.zig");
const host_mod = @import("../core/host.zig");
const timer = @import("../hal/timer.zig");

// ============================================================
// Keyboard lifecycle (TODO: wire to keyboard.zig when ready)
// ============================================================

/// Initialize keyboard hardware and subsystems
export fn keyboard_init() void {
    // TODO: Wire to keyboard.init() when keyboard.zig is integrated
}

/// Run one iteration of the keyboard processing loop
export fn keyboard_task() void {
    // TODO: Wire to keyboard.task() when keyboard.zig is integrated
}

// ============================================================
// Layer management
// ============================================================

/// Turn on a specific layer
export fn layer_on(layer: u8) void {
    if (layer >= layer_mod.MAX_LAYERS) return;
    layer_mod.layerOn(@intCast(layer));
}

/// Turn off a specific layer
export fn layer_off(layer: u8) void {
    if (layer >= layer_mod.MAX_LAYERS) return;
    layer_mod.layerOff(@intCast(layer));
}

/// Clear all layers
export fn layer_clear() void {
    layer_mod.layerClear();
}

/// Set the layer state directly
export fn layer_state_set(state: u32) void {
    layer_mod.layerStateSet(state);
}

/// Check if a layer is active
export fn layer_state_is(layer: u8) bool {
    if (layer >= layer_mod.MAX_LAYERS) return false;
    return layer_mod.layerStateIs(@intCast(layer));
}

/// Move to a specific layer (exclusive)
export fn layer_move(layer: u8) void {
    if (layer >= layer_mod.MAX_LAYERS) return;
    layer_mod.layerMove(@intCast(layer));
}

// ============================================================
// Host / Report
// ============================================================

/// Clear all keyboard state and send empty report
export fn clear_keyboard() void {
    host_mod.clearKeyboard();
}

// ============================================================
// Timer
// ============================================================

/// Read current time in milliseconds (16-bit)
export fn timer_read() u16 {
    return timer.read();
}

/// Read current time in milliseconds (32-bit)
export fn timer_read32() u32 {
    return timer.read32();
}

/// Clear (reset) the timer
/// Note: テスト環境では `timer.init()` が `mock_timer_ms = 0` にリセットするため
/// 期待通り動作する。freestanding（実機）では `timer.init()` は no-op のため、
/// RP2040 のハードウェアタイマーはリセットされず、QMK C の `timer_clear()` の
/// セマンティクス（タイマーカウンタのリセット）と一致しない。
/// Phase 1 ではテスト専用なので動作上の問題はない。
export fn timer_clear() void {
    timer.init();
}

/// Set mock timer to specific value (test only)
export fn set_time(ms: u32) void {
    timer.mockSet(ms);
}

/// Advance mock timer (test only)
export fn advance_time(ms: u32) void {
    timer.mockAdvance(ms);
}

// ============================================================
// Keymap (TODO: wire to keymap.zig when ready)
// ============================================================

/// Get keycode at given layer and position
export fn keymap_key_to_keycode(layer: u8, row: u8, col: u8) u16 {
    _ = layer;
    _ = row;
    _ = col;
    // TODO: Wire to keymap module when keymap_key_to_keycode is available
    return 0;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "qmk_abi: layer_on/off/state_is" {
    layer_mod.resetState();
    layer_on(1);
    try testing.expect(layer_state_is(1));
    layer_off(1);
    try testing.expect(!layer_state_is(1));
}

test "qmk_abi: layer_clear" {
    layer_mod.resetState();
    layer_on(1);
    layer_on(3);
    layer_clear();
    try testing.expect(!layer_state_is(1));
    try testing.expect(!layer_state_is(3));
}

test "qmk_abi: layer_state_set" {
    layer_mod.resetState();
    layer_state_set(0b1010);
    try testing.expect(layer_state_is(1));
    try testing.expect(layer_state_is(3));
    try testing.expect(!layer_state_is(2));
}

test "qmk_abi: layer_move" {
    layer_mod.resetState();
    layer_on(1);
    layer_on(2);
    layer_move(3);
    try testing.expect(!layer_state_is(1));
    try testing.expect(!layer_state_is(2));
    try testing.expect(layer_state_is(3));
}

test "qmk_abi: layer boundary check" {
    layer_mod.resetState();
    // Should not crash with out-of-range layer
    layer_on(255);
    try testing.expect(!layer_state_is(255));
    layer_off(255);
    layer_move(255);
}

test "qmk_abi: timer_read/read32" {
    timer.mockReset();
    try testing.expectEqual(@as(u16, 0), timer_read());
    try testing.expectEqual(@as(u32, 0), timer_read32());
}

test "qmk_abi: set_time/advance_time" {
    timer.mockReset();
    set_time(100);
    try testing.expectEqual(@as(u32, 100), timer_read32());
    advance_time(50);
    try testing.expectEqual(@as(u32, 150), timer_read32());
}

test "qmk_abi: timer_clear resets timer" {
    timer.mockReset();
    set_time(500);
    timer_clear();
    try testing.expectEqual(@as(u32, 0), timer_read32());
}

test "qmk_abi: keyboard_init/task do not crash" {
    keyboard_init();
    keyboard_task();
}

test "qmk_abi: keymap_key_to_keycode stub returns 0" {
    try testing.expectEqual(@as(u16, 0), keymap_key_to_keycode(0, 0, 0));
    try testing.expectEqual(@as(u16, 0), keymap_key_to_keycode(1, 2, 3));
}
