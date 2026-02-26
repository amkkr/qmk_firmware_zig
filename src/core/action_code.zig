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

    /// Layer bitwise operation (ACT_LAYER)
    layer_bitop: packed struct {
        bits: u4,
        xbit: u1,
        part: u3,
        on: u2,
        op: u2,
        kind: u4,
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
// Layer operation constants (matching C action_code.h)
// ============================================================

/// Layer bitwise operation types
pub const OP_BIT_AND: u2 = 0;
pub const OP_BIT_OR: u2 = 1;
pub const OP_BIT_XOR: u2 = 2;
pub const OP_BIT_SET: u2 = 3;

/// Layer action triggers (on=0 means default layer operation)
pub const ON_PRESS: u2 = 1;
pub const ON_RELEASE: u2 = 2;
pub const ON_BOTH: u2 = 3;

/// Layer-tap special operation codes
pub const OP_TAP_TOGGLE: u8 = 0xF0;
pub const OP_ON_OFF: u8 = 0xF1;
pub const OP_OFF_ON: u8 = 0xF2;
pub const OP_SET_CLEAR: u8 = 0xF3;
pub const OP_ONESHOT: u8 = 0xF4;

/// Mods-tap special codes
pub const MODS_ONESHOT: u8 = 0x00;
pub const MODS_TAP_TOGGLE: u8 = 0x01;

/// Internal action codes for special keycodes (Caps Word, Repeat Key, Layer Lock)
/// These use a reserved kind value (0b1111) to avoid collision with real action types.
/// param encodes which feature:
///   0x01 = Caps Word Toggle
///   0x02 = Repeat Key
///   0x03 = Alt Repeat Key
///   0x04 = Layer Lock
///   0x05 = Grave Escape
pub const ACTION_CAPS_WORD_TOGGLE: u16 = 0xF001;
pub const ACTION_REPEAT_KEY: u16 = 0xF002;
pub const ACTION_ALT_REPEAT_KEY: u16 = 0xF003;
pub const ACTION_LAYER_LOCK: u16 = 0xF004;
pub const ACTION_GRAVE_ESCAPE: u16 = 0xF005;

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

/// ACTION_LAYER_MOMENTARY(layer) - momentary layer switch (ON_OFF)
/// C版互換: ACTION_LAYER_MOMENTARY(layer)
///   → ACTION_LAYER_ON_OFF(layer)
///   → ACTION_LAYER_TAP(layer, OP_ON_OFF)
///   → ACTION(ACT_LAYER_TAP, layer<<8 | OP_ON_OFF)
///   = ACT_LAYER_TAP(0b1010)<<12 | layer<<8 | 0xF1
pub inline fn ACTION_LAYER_MOMENTARY(layer: u5) u16 {
    return actionLayerTap(layer, OP_ON_OFF);
}

// C版とのバイナリ互換性を comptime で検証 (Issue #55)
comptime {
    // C版: ACT_LAYER_TAP=0b1010, OP_ON_OFF=0xF1
    // ACTION_LAYER_MOMENTARY(0) = 0b1010<<12 | 0<<8 | 0xF1 = 0xA0F1
    // ACTION_LAYER_MOMENTARY(1) = 0b1010<<12 | 1<<8 | 0xF1 = 0xA1F1
    // ACTION_LAYER_MOMENTARY(15) = 0b1010<<12 | 15<<8 | 0xF1 = 0xAFF1
    if (ACTION_LAYER_MOMENTARY(0) != 0xA0F1) @compileError("ACTION_LAYER_MOMENTARY(0) must be 0xA0F1 for C compat");
    if (ACTION_LAYER_MOMENTARY(1) != 0xA1F1) @compileError("ACTION_LAYER_MOMENTARY(1) must be 0xA1F1 for C compat");
    if (ACTION_LAYER_MOMENTARY(15) != 0xAFF1) @compileError("ACTION_LAYER_MOMENTARY(15) must be 0xAFF1 for C compat");
}

/// ACTION_LAYER_TAP_KEY(layer, key) - layer tap
pub inline fn ACTION_LAYER_TAP_KEY(layer: u5, key: u8) u16 {
    return actionLayerTap(layer, key);
}

/// ACTION_LAYER_BITOP(op, part, bits, on) - layer bitwise operation
pub inline fn ACTION_LAYER_BITOP(op: u2, part: u3, bits: u5, on: u2) u16 {
    return ACTION(@intFromEnum(ActionKind.layer), @as(u12, op) << 10 | @as(u12, on) << 8 | @as(u12, part) << 5 | @as(u12, bits));
}

/// ACTION_LAYER_GOTO(layer) - switch to layer exclusively (SET on press)
pub inline fn ACTION_LAYER_GOTO(layer: u5) u16 {
    const part: u3 = @truncate(layer >> 2);
    const bit: u2 = @truncate(layer);
    const bits: u5 = @as(u5, 1) << bit;
    return ACTION_LAYER_BITOP(OP_BIT_SET, part, bits, ON_PRESS);
}

/// ACTION_LAYER_TOGGLE(layer) - toggle layer (XOR on release)
pub inline fn ACTION_LAYER_TOGGLE(layer: u5) u16 {
    const part: u3 = @truncate(layer >> 2);
    const bit: u2 = @truncate(layer);
    const bits: u5 = @as(u5, 1) << bit;
    return ACTION_LAYER_BITOP(OP_BIT_XOR, part, bits, ON_RELEASE);
}

/// ACTION_DEFAULT_LAYER_SET(layer) - set default layer (SET, on=0)
pub inline fn ACTION_DEFAULT_LAYER_SET(layer: u5) u16 {
    const part: u3 = @truncate(layer >> 2);
    const bit: u2 = @truncate(layer);
    const bits: u5 = @as(u5, 1) << bit;
    return ACTION_LAYER_BITOP(OP_BIT_SET, part, bits, 0);
}

/// ACTION_LAYER_MODS(layer, mods) - activate layer with mods
pub inline fn ACTION_LAYER_MODS(layer: u4, mods: u8) u16 {
    return ACTION(@intFromEnum(ActionKind.layer_mods), @as(u12, layer) << 8 | @as(u12, mods));
}

/// ACTION_LAYER_ONESHOT(layer) - one-shot layer
pub inline fn ACTION_LAYER_ONESHOT(layer: u5) u16 {
    return actionLayerTap(layer, OP_ONESHOT);
}

/// ACTION_LAYER_TAP_TOGGLE(layer) - tap toggle layer
pub inline fn ACTION_LAYER_TAP_TOGGLE(layer: u5) u16 {
    return actionLayerTap(layer, OP_TAP_TOGGLE);
}

/// ACTION_MODS_ONESHOT(mods) - one-shot modifier
pub inline fn ACTION_MODS_ONESHOT(mods: u5) u16 {
    return ACTION(@intFromEnum(ActionKind.mods_tap), @as(u12, mods) << 8 | @as(u12, MODS_ONESHOT));
}

/// ACTION_MODS_TAP_TOGGLE(mods) - tap toggle modifier
/// タップ TAPPING_TOGGLE 回でモッド固定
pub inline fn ACTION_MODS_TAP_TOGGLE(mods: u5) u16 {
    return ACTION(@intFromEnum(ActionKind.mods_tap), @as(u12, mods) << 8 | @as(u12, MODS_TAP_TOGGLE));
}

/// ACTION_MOUSEKEY(key) - mouse key action
pub inline fn ACTION_MOUSEKEY(key: u8) u16 {
    return ACTION(@intFromEnum(ActionKind.mousekey), @as(u12, key));
}

// ============================================================
// Swap Hands action constructors
// C版 quantum/action_code.h の ACTION_SWAP_HANDS_* に相当
// ACT_SWAP_HANDS = 0b0110, param = u8 操作コード
// ============================================================

/// ACTION_SWAP_HANDS_TOGGLE() - Swap Hands をトグル (SH_TOGG)
pub inline fn ACTION_SWAP_HANDS_TOGGLE() u16 {
    // OP_SH_TOGGLE = 0xF0
    return ACTION(@intFromEnum(ActionKind.swap_hands), 0xF0);
}

/// ACTION_SWAP_HANDS_TAP_TOGGLE() - Swap Hands タップトグル (SH_TT)
pub inline fn ACTION_SWAP_HANDS_TAP_TOGGLE() u16 {
    // OP_SH_TAP_TOGGLE = 0xF1
    return ACTION(@intFromEnum(ActionKind.swap_hands), 0xF1);
}

/// ACTION_SWAP_HANDS_ON_OFF() - モメンタリー Swap Hands (SH_MON)
pub inline fn ACTION_SWAP_HANDS_ON_OFF() u16 {
    // OP_SH_ON_OFF = 0xF2
    return ACTION(@intFromEnum(ActionKind.swap_hands), 0xF2);
}

/// ACTION_SWAP_HANDS_OFF_ON() - モメンタリー Swap Hands 無効 (SH_MOFF)
pub inline fn ACTION_SWAP_HANDS_OFF_ON() u16 {
    // OP_SH_OFF_ON = 0xF3
    return ACTION(@intFromEnum(ActionKind.swap_hands), 0xF3);
}

/// ACTION_SWAP_HANDS_OFF() - Swap Hands を無効化 (SH_OFF)
pub inline fn ACTION_SWAP_HANDS_OFF() u16 {
    // OP_SH_OFF = 0xF4
    return ACTION(@intFromEnum(ActionKind.swap_hands), 0xF4);
}

/// ACTION_SWAP_HANDS_ON() - Swap Hands を有効化 (SH_ON)
pub inline fn ACTION_SWAP_HANDS_ON() u16 {
    // OP_SH_ON = 0xF5
    return ACTION(@intFromEnum(ActionKind.swap_hands), 0xF5);
}

/// ACTION_SWAP_HANDS_ONESHOT() - One-shot Swap Hands (SH_OS)
pub inline fn ACTION_SWAP_HANDS_ONESHOT() u16 {
    // OP_SH_ONESHOT = 0xF6
    return ACTION(@intFromEnum(ActionKind.swap_hands), 0xF6);
}

/// ACTION_SWAP_HANDS_TAP_KEY(key) - タップでキー、ホールドで Swap Hands (SH_T(kc))
pub inline fn ACTION_SWAP_HANDS_TAP_KEY(key: u8) u16 {
    return ACTION(@intFromEnum(ActionKind.swap_hands), @as(u12, key));
}

/// Internal helper: construct layer_tap action using u16 arithmetic
/// Supports layers 0-31 (overflow into kind bits for layers 16-31)
inline fn actionLayerTap(layer: u5, code: u8) u16 {
    return (@as(u16, @intFromEnum(ActionKind.layer_tap)) << 12) | (@as(u16, layer) << 8) | @as(u16, code);
}

/// Convert keycode to action
/// Zig equivalent of action_for_keycode() in quantum/keymap_common.c
pub fn keycodeToAction(kc: Keycode) Action {
    if (kc == keycode.KC.NO) return .{ .code = ACTION_NO };
    if (kc == keycode.KC.TRANSPARENT) return .{ .code = ACTION_TRANSPARENT };

    // System keycodes (KC_SYSTEM_POWER - KC_SYSTEM_WAKE)
    if (keycode.isSystemKeycode(kc)) {
        const ek = @import("extrakey.zig");
        const usage = ek.keycodeToSystem(@truncate(kc));
        return .{ .code = ek.actionUsageSystem(@truncate(usage)) };
    }

    // Consumer keycodes (KC_AUDIO_MUTE - KC_LAUNCHPAD)
    if (keycode.isConsumerKeycode(kc)) {
        const ek = @import("extrakey.zig");
        const usage = ek.keycodeToConsumer(@truncate(kc));
        return .{ .code = ek.actionUsageConsumer(@truncate(usage)) };
    }

    // Mouse keycodes (within basic range but handled with ACT_MOUSEKEY)
    if (keycode.isMouseKey(kc)) {
        return .{ .code = ACTION_MOUSEKEY(@truncate(kc)) };
    }

    // Basic keycodes (0x0000-0x00FF)
    if (keycode.isBasic(kc)) {
        return .{ .code = ACTION_KEY(@truncate(kc)) };
    }

    // Modified keycodes (0x0100-0x1FFF) - keycode maps directly to action code
    if (keycode.isMods(kc)) {
        return .{ .code = kc };
    }

    // Mod-Tap (0x2000-0x3FFF) - keycode maps directly to action code
    if (keycode.isModTap(kc)) {
        return .{ .code = kc };
    }

    // Layer-Tap (0x4000-0x4FFF)
    if (keycode.isLayerTap(kc)) {
        const lt_layer: u5 = @truncate(kc >> 8);
        const tap_kc: u8 = @truncate(kc);
        return .{ .code = ACTION_LAYER_TAP_KEY(lt_layer, tap_kc) };
    }

    // Layer-Mod (0x5000-0x51FF)
    if (kc >= keycode.QK_LAYER_MOD and kc <= keycode.QK_LAYER_MOD_MAX) {
        const lm_layer: u4 = @truncate(kc >> 5);
        const mod: u5 = @truncate(kc);
        // Convert 5-bit mod encoding to 8-bit (right mod flag in bit 4)
        const mods: u8 = if (mod & 0x10 != 0) @as(u8, mod & 0xF) << 4 else @as(u8, mod);
        return .{ .code = ACTION_LAYER_MODS(lm_layer, mods) };
    }

    // TO (0x5200-0x521F)
    if (kc >= keycode.QK_TO and kc <= keycode.QK_TO_MAX) {
        const layer: u5 = @truncate(kc);
        return .{ .code = ACTION_LAYER_GOTO(layer) };
    }

    // Momentary (0x5220-0x523F)
    if (keycode.isMomentary(kc)) {
        const layer: u5 = @truncate(kc);
        return .{ .code = ACTION_LAYER_MOMENTARY(layer) };
    }

    // Default Layer (0x5240-0x525F)
    if (kc >= keycode.QK_DEF_LAYER and kc <= keycode.QK_DEF_LAYER_MAX) {
        const layer: u5 = @truncate(kc);
        return .{ .code = ACTION_DEFAULT_LAYER_SET(layer) };
    }

    // Toggle Layer (0x5260-0x527F)
    if (kc >= keycode.QK_TOGGLE_LAYER and kc <= keycode.QK_TOGGLE_LAYER_MAX) {
        const layer: u5 = @truncate(kc);
        return .{ .code = ACTION_LAYER_TOGGLE(layer) };
    }

    // One Shot Layer (0x5280-0x529F)
    if (kc >= keycode.QK_ONE_SHOT_LAYER and kc <= keycode.QK_ONE_SHOT_LAYER_MAX) {
        const layer: u5 = @truncate(kc);
        return .{ .code = ACTION_LAYER_ONESHOT(layer) };
    }

    // One Shot Mod (0x52A0-0x52BF)
    if (kc >= keycode.QK_ONE_SHOT_MOD and kc <= keycode.QK_ONE_SHOT_MOD_MAX) {
        const mods: u5 = @truncate(kc);
        return .{ .code = ACTION_MODS_ONESHOT(mods) };
    }

    // Layer Tap Toggle (0x52C0-0x52DF)
    if (kc >= keycode.QK_LAYER_TAP_TOGGLE and kc <= keycode.QK_LAYER_TAP_TOGGLE_MAX) {
        const layer: u5 = @truncate(kc);
        return .{ .code = ACTION_LAYER_TAP_TOGGLE(layer) };
    }

    // Caps Word Toggle
    if (kc == keycode.QK_CAPS_WORD_TOGGLE) {
        return .{ .code = ACTION_CAPS_WORD_TOGGLE };
    }

    // Repeat Key
    if (kc == keycode.QK_REP) {
        return .{ .code = ACTION_REPEAT_KEY };
    }

    // Alt Repeat Key
    if (kc == keycode.QK_AREP) {
        return .{ .code = ACTION_ALT_REPEAT_KEY };
    }

    // Layer Lock
    if (kc == keycode.QK_LAYER_LOCK) {
        return .{ .code = ACTION_LAYER_LOCK };
    }

    // Grave Escape
    if (kc == keycode.QK_GRAVE_ESCAPE) {
        return .{ .code = ACTION_GRAVE_ESCAPE };
    }

    // Key Override (KO_TOGG/KO_ON/KO_OFF) はアクションコード不要。
    // keyboard.zig のプリプロセスで processKeyOverride() が直接消費する。

    // Swap Hands (0x5600-0x56FF)
    if (kc >= keycode.QK_SWAP_HANDS and kc <= keycode.QK_SWAP_HANDS_MAX) {
        const sh_code: u8 = @truncate(kc);
        return .{ .code = ACTION_SWAP_HANDS_TAP_KEY(sh_code) };
    }

    // Unknown keycode
    return .{ .code = ACTION_NO };
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

test "ACTION_LAYER_GOTO matches upstream" {
    // Layer 0: ACTION_LAYER_BITOP(SET, 0, 1, ON_PRESS) = ACTION(8, 0xD01) = 0x8D01
    try testing.expectEqual(@as(u16, 0x8D01), ACTION_LAYER_GOTO(0));
    // Layer 1: ACTION_LAYER_BITOP(SET, 0, 2, ON_PRESS) = ACTION(8, 0xD02) = 0x8D02
    try testing.expectEqual(@as(u16, 0x8D02), ACTION_LAYER_GOTO(1));
}

test "ACTION_LAYER_TOGGLE matches upstream" {
    // Layer 0: ACTION_LAYER_BITOP(XOR, 0, 1, ON_RELEASE) = ACTION(8, 0xA01) = 0x8A01
    try testing.expectEqual(@as(u16, 0x8A01), ACTION_LAYER_TOGGLE(0));
    // Layer 1: ACTION_LAYER_BITOP(XOR, 0, 2, ON_RELEASE) = ACTION(8, 0xA02) = 0x8A02
    try testing.expectEqual(@as(u16, 0x8A02), ACTION_LAYER_TOGGLE(1));
}

test "ACTION_DEFAULT_LAYER_SET matches upstream" {
    // Layer 0: ACTION_LAYER_BITOP(SET, 0, 1, 0) = ACTION(8, 0xC01) = 0x8C01
    try testing.expectEqual(@as(u16, 0x8C01), ACTION_DEFAULT_LAYER_SET(0));
    // Layer 1: ACTION_LAYER_BITOP(SET, 0, 2, 0) = ACTION(8, 0xC02) = 0x8C02
    try testing.expectEqual(@as(u16, 0x8C02), ACTION_DEFAULT_LAYER_SET(1));
}

test "ACTION_LAYER_MODS matches upstream" {
    // Layer 1, LSFT(0x02): ACTION(9, 1<<8 | 0x02) = 0x9102
    try testing.expectEqual(@as(u16, 0x9102), ACTION_LAYER_MODS(1, 0x02));
}

test "ACTION_LAYER_ONESHOT matches upstream" {
    // Layer 1: actionLayerTap(1, 0xF4) = 0xA1F4
    try testing.expectEqual(@as(u16, 0xA1F4), ACTION_LAYER_ONESHOT(1));
}

test "ACTION_MODS_ONESHOT matches upstream" {
    // LCTL(0x01): ACTION(2, 0x01<<8 | 0x00) = 0x2100
    try testing.expectEqual(@as(u16, 0x2100), ACTION_MODS_ONESHOT(0x01));
}

test "ACTION_LAYER_TAP_TOGGLE matches upstream" {
    // Layer 1: actionLayerTap(1, 0xF0) = 0xA1F0
    try testing.expectEqual(@as(u16, 0xA1F0), ACTION_LAYER_TAP_TOGGLE(1));
}

test "ACTION_MOUSEKEY matches upstream" {
    // MS_UP(0xCD): ACTION(5, 0xCD) = 0x50CD
    try testing.expectEqual(@as(u16, 0x50CD), ACTION_MOUSEKEY(0xCD));
}

test "ACTION_LAYER_MOMENTARY uses OP_ON_OFF" {
    // C版展開: ACTION_LAYER_MOMENTARY(layer)
    //   → ACTION_LAYER_ON_OFF(layer)
    //   → ACTION_LAYER_TAP(layer, OP_ON_OFF)
    //   → ACTION(ACT_LAYER_TAP, layer<<8 | OP_ON_OFF)
    //   = 0b1010<<12 | layer<<8 | 0xF1
    try testing.expectEqual(@as(u16, 0xA0F1), ACTION_LAYER_MOMENTARY(0));
    try testing.expectEqual(@as(u16, 0xA1F1), ACTION_LAYER_MOMENTARY(1));
    try testing.expectEqual(@as(u16, 0xA2F1), ACTION_LAYER_MOMENTARY(2));
    try testing.expectEqual(@as(u16, 0xAFF1), ACTION_LAYER_MOMENTARY(15));
}

test "keycodeToAction basic keys" {
    const action_a = keycodeToAction(keycode.KC.A);
    try testing.expectEqual(@as(u16, 0x0004), action_a.code);

    const action_no = keycodeToAction(keycode.KC.NO);
    try testing.expectEqual(@as(u16, 0x0000), action_no.code);
}

test "keycodeToAction MO() keycodes" {
    const action = keycodeToAction(keycode.MO(1));
    try testing.expectEqual(@as(u16, 0xA1F1), action.code);
}

test "keycodeToAction TO() keycodes" {
    const action = keycodeToAction(keycode.TO(1));
    try testing.expectEqual(@as(u16, 0x8D02), action.code);
}

test "keycodeToAction TG() keycodes" {
    const action = keycodeToAction(keycode.TG(1));
    try testing.expectEqual(@as(u16, 0x8A02), action.code);
}

test "keycodeToAction LT() keycodes" {
    // LT(1, KC_A) = 0x4104 → ACTION_LAYER_TAP_KEY(1, 0x04) = 0xA104
    const action = keycodeToAction(keycode.LT(1, keycode.KC.A));
    try testing.expectEqual(@as(u16, 0xA104), action.code);
}

test "keycodeToAction MT() keycodes" {
    // MT(MOD_LCTL, KC_A) = 0x2104 → direct mapping = 0x2104
    const action = keycodeToAction(keycode.MT(keycode.Mod.LCTL, keycode.KC.A));
    try testing.expectEqual(@as(u16, 0x2104), action.code);
}

test "keycodeToAction DF() keycodes" {
    const action = keycodeToAction(keycode.DF(1));
    try testing.expectEqual(@as(u16, 0x8C02), action.code);
}

test "keycodeToAction OSL() keycodes" {
    const action = keycodeToAction(keycode.OSL(1));
    try testing.expectEqual(@as(u16, 0xA1F4), action.code);
}

test "keycodeToAction OSM() keycodes" {
    const action = keycodeToAction(keycode.OSM(keycode.Mod.LCTL));
    try testing.expectEqual(@as(u16, 0x2100), action.code);
}

test "keycodeToAction TT() keycodes" {
    const action = keycodeToAction(keycode.TT(1));
    try testing.expectEqual(@as(u16, 0xA1F0), action.code);
}

test "keycodeToAction LM() keycodes" {
    // LM(1, MOD_LSFT) = QK_LAYER_MOD | (1<<5) | 0x02 = 0x5022
    // layer=1, mod=0x02 → ACTION_LAYER_MODS(1, 0x02) = 0x9102
    const action = keycodeToAction(keycode.LM(1, keycode.Mod.LSFT));
    try testing.expectEqual(@as(u16, 0x9102), action.code);
}

test "keycodeToAction swap hands keycodes" {
    // SH_TG = 0x56F0 → ACTION_SWAP_HANDS_TAP_KEY(0xF0) = 0x60F0
    const sh_tg = keycodeToAction(keycode.KC.SH_TG);
    try testing.expectEqual(@as(u16, 0x60F0), sh_tg.code);
    // SH_T(KC_A=0x04) = 0x5604 → ACTION_SWAP_HANDS_TAP_KEY(0x04) = 0x6004
    const sh_t_a = keycodeToAction(keycode.SH_T(0x04));
    try testing.expectEqual(@as(u16, 0x6004), sh_t_a.code);
}

test "keycodeToAction mouse keys" {
    const action = keycodeToAction(keycode.KC.MS_UP);
    try testing.expectEqual(@as(u16, 0x50CD), action.code);
}

test "layer_bitop field decoding" {
    // ACTION_LAYER_BITOP(OP_BIT_OR=1, part=0, bits=0b00010, ON_PRESS=1) = 0x8502
    const act = Action{ .code = ACTION_LAYER_BITOP(OP_BIT_OR, 0, 0b00010, ON_PRESS) };
    try testing.expectEqual(@as(u4, 0b0010), act.layer_bitop.bits);
    try testing.expectEqual(@as(u1, 0), act.layer_bitop.xbit);
    try testing.expectEqual(@as(u3, 0), act.layer_bitop.part);
    try testing.expectEqual(@as(u2, 1), act.layer_bitop.on);
    try testing.expectEqual(@as(u2, 1), act.layer_bitop.op);
}
