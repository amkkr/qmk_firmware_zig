//! QMK Keymap module (Zig port)
//! Based on quantum/keymap_common.c
//!
//! Provides keymap data structures, keycode resolution with layer transparency,
//! and comptime LAYOUT functions for physical key-to-matrix mapping.

const std = @import("std");
const keycode = @import("keycode.zig");
const layer_mod = @import("layer.zig");
const action_code = @import("action_code.zig");
const report_mod = @import("report.zig");
const Keycode = keycode.Keycode;
const KC = keycode.KC;
const LayerState = layer_mod.LayerState;

pub const MATRIX_ROWS = 4;
pub const MATRIX_COLS = 12;
pub const MAX_LAYERS = layer_mod.MAX_LAYERS;

// ============================================================
// KeymapConfig (C版 keymap_config_t 相当)
// quantum/keycode_config.h の keymap_config_t を移植
// ============================================================

/// キーマップ設定フラグ（EEPROM 永続化対象）
/// C版 keymap_config_t に相当する packed struct。
/// フィールド順は C 版ビットフィールドの順序と一致させる。
pub const KeymapConfig = packed struct(u16) {
    /// CapsLock と Left Ctrl を入れ替える
    swap_control_capslock: bool = false,
    /// CapsLock を Left Ctrl として扱う
    capslock_to_control: bool = false,
    /// Left Alt と Left GUI を入れ替える
    swap_lalt_lgui: bool = false,
    /// Right Alt と Right GUI を入れ替える
    swap_ralt_rgui: bool = false,
    /// GUI キーを無効化する
    no_gui: bool = false,
    /// Grave と Escape を入れ替える
    swap_grave_esc: bool = false,
    /// Backslash と Backspace を入れ替える
    swap_backslash_backspace: bool = false,
    /// N-Key Rollover を有効化する
    nkro: bool = false,
    /// Left Ctrl と Left GUI を入れ替える
    swap_lctl_lgui: bool = false,
    /// Right Ctrl と Right GUI を入れ替える
    swap_rctl_rgui: bool = false,
    /// One-shot modifier を有効化する
    oneshot_enable: bool = false,
    /// Escape と CapsLock を入れ替える
    swap_escape_capslock: bool = false,
    /// 自動補正を有効化する
    autocorrect_enable: bool = false,
    /// 予約（将来の使用のため）
    _reserved: u3 = 0,
};

comptime {
    if (@sizeOf(KeymapConfig) != 2) {
        @compileError("KeymapConfig must be 2 bytes (same as uint16_t in C version)");
    }
}

/// グローバル keymap_config インスタンス
/// C版 `extern keymap_config_t keymap_config;` に相当。
pub var keymap_config: KeymapConfig = .{};

/// 8ビット HID モッドに対して keymap_config のスワップ設定を適用する
/// C版 quantum/keycode_config.c の mod_config() に相当（8ビットHID版）
///
/// C版は5ビットパックモッドを扱うが、本実装は8ビットHIDモッドを直接扱う。
/// 変換ロジックは等価。
pub fn modConfig(mod: u8) u8 {
    var m = mod;

    if (keymap_config.swap_lalt_lgui) {
        const has_lalt = (m & report_mod.ModBit.LALT) != 0;
        const has_lgui = (m & report_mod.ModBit.LGUI) != 0;
        if (has_lalt != has_lgui) {
            m ^= (report_mod.ModBit.LALT | report_mod.ModBit.LGUI);
        }
    }
    if (keymap_config.swap_ralt_rgui) {
        const has_ralt = (m & report_mod.ModBit.RALT) != 0;
        const has_rgui = (m & report_mod.ModBit.RGUI) != 0;
        if (has_ralt != has_rgui) {
            m ^= (report_mod.ModBit.RALT | report_mod.ModBit.RGUI);
        }
    }
    if (keymap_config.swap_lctl_lgui) {
        const has_lctl = (m & report_mod.ModBit.LCTRL) != 0;
        const has_lgui = (m & report_mod.ModBit.LGUI) != 0;
        if (has_lctl != has_lgui) {
            m ^= (report_mod.ModBit.LCTRL | report_mod.ModBit.LGUI);
        }
    }
    if (keymap_config.swap_rctl_rgui) {
        const has_rctl = (m & report_mod.ModBit.RCTRL) != 0;
        const has_rgui = (m & report_mod.ModBit.RGUI) != 0;
        if (has_rctl != has_rgui) {
            m ^= (report_mod.ModBit.RCTRL | report_mod.ModBit.RGUI);
        }
    }
    if (keymap_config.no_gui) {
        m &= ~@as(u8, report_mod.ModBit.LGUI | report_mod.ModBit.RGUI);
    }

    return m;
}

/// Keymap type: [layer][row][col] = Keycode
pub const Keymap = [MAX_LAYERS][MATRIX_ROWS][MATRIX_COLS]Keycode;

// ============================================================
// Keycode access
// ============================================================

/// Get keycode at a specific layer and matrix position
pub fn keymapKeyToKeycode(km: *const Keymap, l: u5, row: u8, col: u8) Keycode {
    if (row >= MATRIX_ROWS or col >= MATRIX_COLS or l >= MAX_LAYERS) return KC.NO;
    return km[l][row][col];
}

// ============================================================
// Layer-aware keycode resolution
// ============================================================

/// Resolve the effective keycode at a matrix position, considering active layers.
/// Checks layers from highest to lowest (in the combined layer_state | default_layer_state).
/// Transparent keys (KC_TRNS) fall through to lower layers.
pub fn resolveKeycode(km: *const Keymap, state: LayerState, row: u8, col: u8) Keycode {
    // Check from highest layer down
    var i: i6 = MAX_LAYERS - 1;
    while (i >= 0) : (i -= 1) {
        const l: u5 = @intCast(i);
        if (state & (@as(LayerState, 1) << l) != 0) {
            const kc = keymapKeyToKeycode(km, l, row, col);
            if (kc != KC.TRNS) return kc;
        }
    }
    return KC.NO;
}

// ============================================================
// madbd34 LAYOUT function
// ============================================================

/// Number of physical keys on madbd34 (4x12 split, 41 used positions)
pub const MADBD34_KEY_COUNT = 41;

/// Convert flat 41-key array to 4x12 matrix for madbd34.
/// Maps physical key indices to matrix [row][col] positions.
/// Unused positions are filled with KC_NO.
///
/// Physical layout:
///   Row 0: 12 keys (cols 0-11)
///   Row 1: 12 keys (cols 0-11)
///   Row 2: 11 keys (cols 0-10, col 11 unused)
///   Row 3: 6 keys  (cols 3-8, cols 0-2 and 9-11 unused)
pub fn layoutMadbd34(comptime keys: [MADBD34_KEY_COUNT]Keycode) [MATRIX_ROWS][MATRIX_COLS]Keycode {
    @setEvalBranchQuota(2000);
    var result: [MATRIX_ROWS][MATRIX_COLS]Keycode = .{.{KC.NO} ** MATRIX_COLS} ** MATRIX_ROWS;
    var idx: usize = 0;

    // Row 0: cols 0-11 (12 keys)
    for (0..12) |col| {
        result[0][col] = keys[idx];
        idx += 1;
    }

    // Row 1: cols 0-11 (12 keys)
    for (0..12) |col| {
        result[1][col] = keys[idx];
        idx += 1;
    }

    // Row 2: cols 0-10 (11 keys)
    for (0..11) |col| {
        result[2][col] = keys[idx];
        idx += 1;
    }

    // Row 3: cols 3-8 (6 keys)
    for (3..9) |col| {
        result[3][col] = keys[idx];
        idx += 1;
    }

    return result;
}

/// Create an empty keymap (all KC_NO)
pub fn emptyKeymap() Keymap {
    return .{.{.{KC.NO} ** MATRIX_COLS} ** MATRIX_ROWS} ** MAX_LAYERS;
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "keymapKeyToKeycode: basic access" {
    var km = emptyKeymap();
    km[0][0][0] = KC.A;
    km[0][1][3] = KC.B;
    km[1][0][0] = KC.C;

    try testing.expectEqual(KC.A, keymapKeyToKeycode(&km, 0, 0, 0));
    try testing.expectEqual(KC.B, keymapKeyToKeycode(&km, 0, 1, 3));
    try testing.expectEqual(KC.C, keymapKeyToKeycode(&km, 1, 0, 0));
    try testing.expectEqual(KC.NO, keymapKeyToKeycode(&km, 0, 0, 1));
}

test "keymapKeyToKeycode: out of bounds" {
    const km = emptyKeymap();
    try testing.expectEqual(KC.NO, keymapKeyToKeycode(&km, 0, 10, 0));
    try testing.expectEqual(KC.NO, keymapKeyToKeycode(&km, 0, 0, 20));
    try testing.expectEqual(KC.NO, keymapKeyToKeycode(&km, 20, 0, 0));
}

test "resolveKeycode: basic layer resolution" {
    var km = emptyKeymap();
    km[0][0][0] = KC.A;
    km[1][0][0] = KC.B;

    // Only layer 0 active
    try testing.expectEqual(KC.A, resolveKeycode(&km, 0b01, 0, 0));

    // Layer 1 active (higher priority)
    try testing.expectEqual(KC.B, resolveKeycode(&km, 0b11, 0, 0));

    // Only layer 1 active
    try testing.expectEqual(KC.B, resolveKeycode(&km, 0b10, 0, 0));
}

test "resolveKeycode: transparency falls through" {
    var km = emptyKeymap();
    km[0][0][0] = KC.A;
    km[1][0][0] = KC.TRNS; // Transparent on layer 1

    // Layer 1 transparent → falls through to layer 0
    try testing.expectEqual(KC.A, resolveKeycode(&km, 0b11, 0, 0));
}

test "resolveKeycode: multiple transparent layers" {
    var km = emptyKeymap();
    km[0][0][0] = KC.A;
    km[1][0][0] = KC.TRNS;
    km[2][0][0] = KC.TRNS;

    // Layers 2 and 1 transparent → falls through to layer 0
    try testing.expectEqual(KC.A, resolveKeycode(&km, 0b111, 0, 0));
}

test "resolveKeycode: highest layer wins" {
    var km = emptyKeymap();
    km[0][0][0] = KC.A;
    km[1][0][0] = KC.B;
    km[2][0][0] = KC.C;

    // All layers active → layer 2 wins
    try testing.expectEqual(KC.C, resolveKeycode(&km, 0b111, 0, 0));
}

test "resolveKeycode: no active layers returns KC_NO" {
    const km = emptyKeymap();
    try testing.expectEqual(KC.NO, resolveKeycode(&km, 0, 0, 0));
}

test "layoutMadbd34: key count and mapping" {
    const keys = comptime blk: {
        var k: [MADBD34_KEY_COUNT]Keycode = undefined;
        for (0..MADBD34_KEY_COUNT) |i| {
            k[i] = @intCast(i + 1); // Use 1-based index as keycode value
        }
        break :blk k;
    };

    const m = layoutMadbd34(keys);

    // Row 0: indices 0-11 → cols 0-11
    try testing.expectEqual(@as(Keycode, 1), m[0][0]); // index 0
    try testing.expectEqual(@as(Keycode, 12), m[0][11]); // index 11

    // Row 1: indices 12-23 → cols 0-11
    try testing.expectEqual(@as(Keycode, 13), m[1][0]); // index 12
    try testing.expectEqual(@as(Keycode, 24), m[1][11]); // index 23

    // Row 2: indices 24-34 → cols 0-10
    try testing.expectEqual(@as(Keycode, 25), m[2][0]); // index 24
    try testing.expectEqual(@as(Keycode, 35), m[2][10]); // index 34
    try testing.expectEqual(KC.NO, m[2][11]); // unused

    // Row 3: indices 35-40 → cols 3-8
    try testing.expectEqual(KC.NO, m[3][0]); // unused
    try testing.expectEqual(KC.NO, m[3][1]); // unused
    try testing.expectEqual(KC.NO, m[3][2]); // unused
    try testing.expectEqual(@as(Keycode, 36), m[3][3]); // index 35
    try testing.expectEqual(@as(Keycode, 41), m[3][8]); // index 40
    try testing.expectEqual(KC.NO, m[3][9]); // unused
    try testing.expectEqual(KC.NO, m[3][10]); // unused
    try testing.expectEqual(KC.NO, m[3][11]); // unused
}

test "layoutMadbd34: realistic keymap layer 0" {
    const m = layoutMadbd34(.{
        // Row 0
        KC.TAB, KC.Q, KC.W, KC.E, KC.R, KC.T, KC.Y, KC.U, KC.I, KC.O, KC.P, KC.BSPC,
        // Row 1
        KC.LCTL, KC.A, KC.S, KC.D, KC.F, KC.G, KC.H, KC.J, KC.K, KC.L, KC.SCLN, KC.ENT,
        // Row 2
        KC.LSFT, KC.Z, KC.X, KC.C, KC.V, KC.B, KC.N, KC.M, KC.COMM, KC.DOT, KC.SLSH,
        // Row 3 (thumb cluster)
        KC.LCTL, KC.LGUI, KC.SPC, KC.ESC, KC.RALT, keycode.MO(1),
    });

    try testing.expectEqual(KC.TAB, m[0][0]);
    try testing.expectEqual(KC.BSPC, m[0][11]);
    try testing.expectEqual(KC.LCTL, m[1][0]);
    try testing.expectEqual(KC.ENT, m[1][11]);
    try testing.expectEqual(KC.LSFT, m[2][0]);
    try testing.expectEqual(KC.SLSH, m[2][10]);
    try testing.expectEqual(KC.NO, m[2][11]); // unused
    try testing.expectEqual(KC.LCTL, m[3][3]);
    try testing.expectEqual(keycode.MO(1), m[3][8]);
    try testing.expectEqual(KC.NO, m[3][0]); // unused
}
