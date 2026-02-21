//! QMK Action Code definitions (Zig port)
//! Based on quantum/action_code.h
//!
//! Action codes are 16-bit values that encode what happens when a key is pressed.
//! Layout (little-endian):
//!   [15:12] kind  - action type ID (4 bits)
//!   [11:0]  param - action parameters (12 bits)

const keycode = @import("keycode.zig");
const Keycode = keycode.Keycode;

/// Action kind IDs (4 bits, bits 12-15)
pub const ActionKind = enum(u4) {
    mods = 0b0000, // ACT_MODS / ACT_LMODS
    rmods = 0b0001, // ACT_RMODS
    mods_tap = 0b0010, // ACT_MODS_TAP / ACT_LMODS_TAP
    rmods_tap = 0b0011, // ACT_RMODS_TAP
    usage = 0b0100, // ACT_USAGE
    mousekey = 0b0101, // ACT_MOUSEKEY
    swap_hands = 0b0110, // ACT_SWAP_HANDS
    layer = 0b1000, // ACT_LAYER
    layer_mods = 0b1001, // ACT_LAYER_MODS
    layer_tap = 0b1010, // ACT_LAYER_TAP (layers 0-15)
    layer_tap_ext = 0b1011, // ACT_LAYER_TAP_EXT (layers 16-31)
    _,
};

/// Action type - 16-bit packed union (binary compatible with C action_t)
pub const Action = packed union {
    code: u16,

    kind: packed struct {
        param: u12,
        id: ActionKind,
    },

    /// Key action: modifier + keycode
    key: packed struct {
        code: u8,
        mods: u4,
        kind: u4,
    },

    /// Layer + mods action
    layer_mods: packed struct {
        mods: u8,
        layer: u4,
        kind: u4,
    },

    /// Layer-tap action (3-bit kind for 5-bit val)
    layer_tap: packed struct {
        code: u8,
        val: u5,
        kind: u3,
    },

    /// Usage action (consumer/system)
    usage: packed struct {
        code: u10,
        page: u2,
        kind: u4,
    },

    comptime {
        if (@sizeOf(Action) != 2) {
            @compileError("Action must be 2 bytes (16 bits)");
        }
    }
};

/// Action code constants
pub const ACTION_NO: u16 = 0x0000;
pub const ACTION_TRANSPARENT: u16 = 0x0001;

/// Usage page for system/consumer actions
pub const UsagePage = enum(u2) {
    system = 1,
    consumer = 2,
    _,
};

// ============================================================
// Action constructor functions (comptime equivalents of C macros)
// ============================================================

/// ACTION(kind, param) = (kind << 12) | param
pub inline fn ACTION(kind: u4, param: u12) u16 {
    return (@as(u16, kind) << 12) | @as(u16, param);
}

/// ACTION_KEY(key) - basic key action
pub inline fn ACTION_KEY(key: u8) u16 {
    return ACTION(@intFromEnum(ActionKind.mods), @as(u12, key));
}

/// ACTION_MODS_KEY(mods, key) - modifier + key
pub inline fn ACTION_MODS_KEY(mods: u5, key: u8) u16 {
    return ACTION(@intFromEnum(ActionKind.mods), @as(u12, mods) << 8 | @as(u12, key));
}

/// ACTION_MODS_TAP_KEY(mods, key) - tap for key, hold for modifier
pub inline fn ACTION_MODS_TAP_KEY(mods: u5, key: u8) u16 {
    return ACTION(@intFromEnum(ActionKind.mods_tap), @as(u12, mods) << 8 | @as(u12, key));
}

/// ACTION_LAYER_MOMENTARY(layer) - momentary layer switch
pub inline fn ACTION_LAYER_MOMENTARY(layer: u5) u16 {
    return ACTION(@intFromEnum(ActionKind.layer_tap), @as(u12, layer) << 8);
}

/// ACTION_LAYER_TAP_KEY(layer, key) - layer tap
pub inline fn ACTION_LAYER_TAP_KEY(layer: u5, key: u8) u16 {
    return ACTION(@intFromEnum(ActionKind.layer_tap), @as(u12, layer) << 8 | @as(u12, key));
}

/// Convert keycode to action
pub fn keycodeToAction(kc: Keycode) Action {
    if (kc == keycode.KC.NO) return .{ .code = ACTION_NO };
    if (kc == keycode.KC.TRANSPARENT) return .{ .code = ACTION_TRANSPARENT };

    if (keycode.isBasic(kc)) {
        return .{ .code = ACTION_KEY(@truncate(kc)) };
    }

    // Modified keycodes: bits[12:8] = mods, bits[7:0] = keycode
    if (keycode.isMods(kc)) {
        return .{ .code = kc }; // Mods keycodes map directly to action codes
    }

    // For other ranges, return the keycode as-is (action code == keycode)
    return .{ .code = kc };
}

// ============================================================
// Tests
// ============================================================

const testing = @import("std").testing;

test "Action size is 2 bytes" {
    try testing.expectEqual(@as(usize, 2), @sizeOf(Action));
}

test "Action kind extraction" {
    const action = Action{ .code = ACTION_KEY(keycode.KC.A) };
    try testing.expectEqual(ActionKind.mods, action.kind.id);
    try testing.expectEqual(@as(u8, keycode.KC.A), action.key.code);
}

test "ACTION macros match upstream values" {
    // ACTION_KEY(KC_A) = (0 << 12) | 0x04 = 0x0004
    try testing.expectEqual(@as(u16, 0x0004), ACTION_KEY(0x04));

    // ACTION_MODS_KEY(MOD_LSFT, KC_A) = (0 << 12) | (0x02 << 8) | 0x04 = 0x0204
    try testing.expectEqual(@as(u16, 0x0204), ACTION_MODS_KEY(0x02, 0x04));
}

test "keycodeToAction basic keys" {
    const action_a = keycodeToAction(keycode.KC.A);
    try testing.expectEqual(@as(u16, 0x0004), action_a.code);

    const action_no = keycodeToAction(keycode.KC.NO);
    try testing.expectEqual(@as(u16, 0x0000), action_no.code);
}
