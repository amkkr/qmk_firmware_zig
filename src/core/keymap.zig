// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! QMK Keymap module (Zig port)
//! Based on quantum/keymap_common.c
//!
//! Provides keymap data structures, keycode resolution with layer transparency,
//! and comptime LAYOUT functions for physical key-to-matrix mapping.

const std = @import("std");
const build_options = @import("build_options");
const keycode = @import("keycode.zig");
const layer_mod = @import("layer.zig");
const action_code = @import("action_code.zig");
const report_mod = @import("report.zig");
const eeconfig = @import("eeconfig.zig");
const Keycode = keycode.Keycode;
const KC = keycode.KC;
const LayerState = layer_mod.LayerState;

pub const MATRIX_ROWS: u8 = build_options.MATRIX_ROWS;
pub const MATRIX_COLS: u8 = build_options.MATRIX_COLS;
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

/// キーコードに対して keymap_config のスワップ設定を適用する
/// C版 quantum/keycode_config.c の keycode_config() に相当。
pub fn keycodeConfig(kc: u8) u8 {
    switch (kc) {
        @as(u8, @truncate(KC.CAPS_LOCK)) => {
            if (keymap_config.swap_control_capslock or keymap_config.capslock_to_control) {
                return @truncate(KC.LEFT_CTRL);
            } else if (keymap_config.swap_escape_capslock) {
                return @truncate(KC.ESCAPE);
            }
            return kc;
        },
        @as(u8, @truncate(KC.LEFT_CTRL)) => {
            if (keymap_config.swap_control_capslock) {
                return @truncate(KC.CAPS_LOCK);
            }
            if (keymap_config.swap_lctl_lgui) {
                if (keymap_config.no_gui) return 0;
                return @truncate(KC.LEFT_GUI);
            }
            return kc;
        },
        @as(u8, @truncate(KC.LEFT_ALT)) => {
            if (keymap_config.swap_lalt_lgui) {
                if (keymap_config.no_gui) return 0;
                return @truncate(KC.LEFT_GUI);
            }
            return kc;
        },
        @as(u8, @truncate(KC.LEFT_GUI)) => {
            if (keymap_config.swap_lalt_lgui) {
                return @truncate(KC.LEFT_ALT);
            }
            if (keymap_config.swap_lctl_lgui) {
                return @truncate(KC.LEFT_CTRL);
            }
            if (keymap_config.no_gui) return 0;
            return kc;
        },
        @as(u8, @truncate(KC.RIGHT_CTRL)) => {
            if (keymap_config.swap_rctl_rgui) {
                if (keymap_config.no_gui) return 0;
                return @truncate(KC.RIGHT_GUI);
            }
            return kc;
        },
        @as(u8, @truncate(KC.RIGHT_ALT)) => {
            if (keymap_config.swap_ralt_rgui) {
                if (keymap_config.no_gui) return 0;
                return @truncate(KC.RIGHT_GUI);
            }
            return kc;
        },
        @as(u8, @truncate(KC.RIGHT_GUI)) => {
            if (keymap_config.swap_ralt_rgui) {
                return @truncate(KC.RIGHT_ALT);
            }
            if (keymap_config.swap_rctl_rgui) {
                return @truncate(KC.RIGHT_CTRL);
            }
            if (keymap_config.no_gui) return 0;
            return kc;
        },
        @as(u8, @truncate(KC.GRAVE)) => {
            if (keymap_config.swap_grave_esc) {
                return @truncate(KC.ESCAPE);
            }
            return kc;
        },
        @as(u8, @truncate(KC.ESCAPE)) => {
            if (keymap_config.swap_grave_esc) {
                return @truncate(KC.GRAVE);
            } else if (keymap_config.swap_escape_capslock) {
                return @truncate(KC.CAPS_LOCK);
            }
            return kc;
        },
        @as(u8, @truncate(KC.BACKSLASH)) => {
            if (keymap_config.swap_backslash_backspace) {
                return @truncate(KC.BACKSPACE);
            }
            return kc;
        },
        @as(u8, @truncate(KC.BACKSPACE)) => {
            if (keymap_config.swap_backslash_backspace) {
                return @truncate(KC.BACKSLASH);
            }
            return kc;
        },
        else => return kc,
    }
}

// ============================================================
// EEPROM 永続化
// ============================================================

/// 起動時に EEPROM から KeymapConfig をロードする
/// C版 quantum/keymap.c の eeconfig_read_keymap() 呼び出し相当。
/// EEPROMが未初期化の場合はデフォルト値のまま（全フラグ OFF）。
pub fn keymapInit() void {
    const raw = eeconfig.readKeymap();
    keymap_config = @bitCast(raw);
}

/// KeymapConfig を更新し、EEPROM に永続化する
/// C版 eeconfig_update_keymap() 呼び出しを行う箇所に相当。
pub fn updateKeymapConfig(config: KeymapConfig) void {
    keymap_config = config;
    eeconfig.updateKeymap(@bitCast(config));
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

test "KeymapConfig size is 2 bytes" {
    try testing.expectEqual(@as(usize, 2), @sizeOf(KeymapConfig));
}

test "keycodeConfig: no swap returns unchanged" {
    keymap_config = .{};
    try testing.expectEqual(@as(u8, 0x04), keycodeConfig(0x04)); // KC_A
    try testing.expectEqual(@as(u8, 0x29), keycodeConfig(0x29)); // KC_ESCAPE
    try testing.expectEqual(@as(u8, 0x35), keycodeConfig(0x35)); // KC_GRAVE
}

test "keycodeConfig: swap_grave_esc" {
    keymap_config = .{};
    keymap_config.swap_grave_esc = true;
    try testing.expectEqual(@as(u8, 0x29), keycodeConfig(0x35)); // GRAVE → ESCAPE
    try testing.expectEqual(@as(u8, 0x35), keycodeConfig(0x29)); // ESCAPE → GRAVE
    try testing.expectEqual(@as(u8, 0x04), keycodeConfig(0x04)); // unaffected
}

test "keycodeConfig: swap_backslash_backspace" {
    keymap_config = .{};
    keymap_config.swap_backslash_backspace = true;
    try testing.expectEqual(@as(u8, 0x2A), keycodeConfig(0x31)); // BACKSLASH → BACKSPACE
    try testing.expectEqual(@as(u8, 0x31), keycodeConfig(0x2A)); // BACKSPACE → BACKSLASH
}

test "keycodeConfig: swap_control_capslock" {
    keymap_config = .{};
    keymap_config.swap_control_capslock = true;
    try testing.expectEqual(@as(u8, @truncate(KC.LEFT_CTRL)), keycodeConfig(@truncate(KC.CAPS_LOCK)));
    try testing.expectEqual(@as(u8, @truncate(KC.CAPS_LOCK)), keycodeConfig(@truncate(KC.LEFT_CTRL)));
}

test "keycodeConfig: capslock_to_control" {
    keymap_config = .{};
    keymap_config.capslock_to_control = true;
    try testing.expectEqual(@as(u8, @truncate(KC.LEFT_CTRL)), keycodeConfig(@truncate(KC.CAPS_LOCK)));
    // LEFT_CTRL は変わらない（swap_control_capslock がfalseのため）
    try testing.expectEqual(@as(u8, @truncate(KC.LEFT_CTRL)), keycodeConfig(@truncate(KC.LEFT_CTRL)));
}

test "keycodeConfig: swap_escape_capslock" {
    keymap_config = .{};
    keymap_config.swap_escape_capslock = true;
    try testing.expectEqual(@as(u8, @truncate(KC.ESCAPE)), keycodeConfig(@truncate(KC.CAPS_LOCK)));
    try testing.expectEqual(@as(u8, @truncate(KC.CAPS_LOCK)), keycodeConfig(@truncate(KC.ESCAPE)));
}

test "modConfig: no swap returns unchanged" {
    keymap_config = .{};
    try testing.expectEqual(@as(u8, 0x04), modConfig(0x04)); // LALT
    try testing.expectEqual(@as(u8, 0x01), modConfig(0x01)); // LCTRL
}

test "modConfig: swap_lalt_lgui" {
    keymap_config = .{};
    keymap_config.swap_lalt_lgui = true;
    try testing.expectEqual(@as(u8, report_mod.ModBit.LGUI), modConfig(report_mod.ModBit.LALT));
    try testing.expectEqual(@as(u8, report_mod.ModBit.LALT), modConfig(report_mod.ModBit.LGUI));
    // 両方セットされている場合はスワップしない
    try testing.expectEqual(@as(u8, report_mod.ModBit.LALT | report_mod.ModBit.LGUI), modConfig(report_mod.ModBit.LALT | report_mod.ModBit.LGUI));
}

test "modConfig: no_gui" {
    keymap_config = .{};
    keymap_config.no_gui = true;
    try testing.expectEqual(@as(u8, 0), modConfig(report_mod.ModBit.LGUI));
    try testing.expectEqual(@as(u8, 0), modConfig(report_mod.ModBit.RGUI));
    try testing.expectEqual(@as(u8, report_mod.ModBit.LCTRL), modConfig(report_mod.ModBit.LCTRL | report_mod.ModBit.LGUI));
}
