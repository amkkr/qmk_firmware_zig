//! C ABI compatibility tests
//! Verifies that Zig struct sizes, field offsets, and bit layouts
//! match the corresponding C struct definitions in QMK.
//!
//! Reference C headers:
//!   - tmk_core/protocol/report.h (KeyboardReport, MouseReport, ExtraReport)
//!   - quantum/keyboard.h (keypos_t, keyevent_t)
//!   - quantum/action_code.h (action_t)
//!   - quantum/action.h (tap_t)

const std = @import("std");
const testing = std.testing;

const report = @import("../core/report.zig");
const event = @import("../core/event.zig");
const action_code = @import("../core/action_code.zig");

// ============================================================
// Struct size tests (C sizeof equivalents)
// ============================================================

test "ABI: KeyboardReport size matches C report_keyboard_t (8 bytes)" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(report.KeyboardReport));
}

test "ABI: MouseReport size matches C report_mouse_t (5 bytes)" {
    try testing.expectEqual(@as(usize, 5), @sizeOf(report.MouseReport));
}

test "ABI: ExtraReport size matches C report_extra_t (3 bytes)" {
    try testing.expectEqual(@as(usize, 3), @sizeOf(report.ExtraReport));
}

test "ABI: Action size matches C action_t (2 bytes)" {
    try testing.expectEqual(@as(usize, 2), @sizeOf(action_code.Action));
}

test "ABI: KeyPos size matches C keypos_t (2 bytes)" {
    try testing.expectEqual(@as(usize, 2), @sizeOf(event.KeyPos));
}

test "ABI: Tap size matches C tap_t (1 byte)" {
    try testing.expectEqual(@as(usize, 1), @sizeOf(event.Tap));
}

// ============================================================
// Field offset tests (C offsetof equivalents)
// ============================================================

test "ABI: KeyboardReport field offsets match C report_keyboard_t" {
    // C: typedef struct { uint8_t mods; uint8_t reserved; uint8_t keys[6]; }
    try testing.expectEqual(@as(usize, 0), @offsetOf(report.KeyboardReport, "mods"));
    try testing.expectEqual(@as(usize, 1), @offsetOf(report.KeyboardReport, "reserved"));
    try testing.expectEqual(@as(usize, 2), @offsetOf(report.KeyboardReport, "keys"));
}

test "ABI: MouseReport field offsets match C report_mouse_t" {
    // C: typedef struct { uint8_t buttons; int8_t x; int8_t y; int8_t v; int8_t h; }
    try testing.expectEqual(@as(usize, 0), @offsetOf(report.MouseReport, "buttons"));
    try testing.expectEqual(@as(usize, 1), @offsetOf(report.MouseReport, "x"));
    try testing.expectEqual(@as(usize, 2), @offsetOf(report.MouseReport, "y"));
    try testing.expectEqual(@as(usize, 3), @offsetOf(report.MouseReport, "v"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(report.MouseReport, "h"));
}

test "ABI: ExtraReport field offsets match C report_extra_t" {
    // C: typedef struct { uint8_t report_id; uint16_t usage; } __attribute__((packed))
    try testing.expectEqual(@as(usize, 0), @offsetOf(report.ExtraReport, "report_id"));
    try testing.expectEqual(@as(usize, 1), @offsetOf(report.ExtraReport, "usage"));
}

// ============================================================
// Bit layout tests (C bitfield / union equivalents)
// ============================================================

test "ABI: Action kind field at bits [15:12]" {
    // ACTION_KEY(KC_A) = 0x0004 → kind = 0 (ACT_MODS)
    const action = action_code.Action{ .code = 0x0004 };
    try testing.expectEqual(action_code.ActionKind.mods, action.kind.id);
    try testing.expectEqual(@as(u12, 0x004), action.kind.param);
}

test "ABI: Action key view matches C action_t.key" {
    // ACTION_MODS_KEY(MOD_LSFT=0x02, KC_A=0x04) = 0x0204
    const action = action_code.Action{ .code = 0x0204 };
    try testing.expectEqual(@as(u8, 0x04), action.key.code);
    try testing.expectEqual(@as(u4, 0x2), action.key.mods);
    try testing.expectEqual(@as(u4, 0x0), action.key.kind);
}

test "ABI: Action layer_tap view matches C action_t.layer_tap" {
    // ACTION_LAYER_TAP_KEY(1, KC_A=0x04) = 0xA104
    const action = action_code.Action{ .code = 0xA104 };
    try testing.expectEqual(@as(u8, 0x04), action.layer_tap.code);
    try testing.expectEqual(@as(u5, 1), action.layer_tap.val);
    // kind is top 3 bits of u16: 0xA = 0b1010, top 3 bits = 0b101 = 5
    try testing.expectEqual(@as(u3, 5), action.layer_tap.kind);
}

test "ABI: Action layer_mods view matches C action_t.layer_mods" {
    // ACTION_LAYER_MODS(1, 0x02) = 0x9102
    const action = action_code.Action{ .code = 0x9102 };
    try testing.expectEqual(@as(u8, 0x02), action.layer_mods.mods);
    try testing.expectEqual(@as(u4, 1), action.layer_mods.layer);
    try testing.expectEqual(@as(u4, 0x9), action.layer_mods.kind);
}

test "ABI: Action usage view matches C action_t.usage" {
    // ACTION(ACT_USAGE=4, page=2<<10 | code=0x0E2) = 0x48E2
    const action = action_code.Action{ .code = 0x48E2 };
    try testing.expectEqual(@as(u4, 4), action.usage.kind);
    try testing.expectEqual(@as(u2, 2), action.usage.page);
    // code is bottom 10 bits of 0x8E2 = 0x0E2
    try testing.expectEqual(@as(u10, 0x0E2), action.usage.code);
}

test "ABI: KeyPos bit layout matches C keypos_t" {
    // C: typedef struct { uint8_t col; uint8_t row; }
    const pos = event.KeyPos{ .col = 5, .row = 3 };
    const raw = @as(u16, @bitCast(pos));
    // Little-endian: col in low byte, row in high byte
    try testing.expectEqual(@as(u16, 0x0305), raw);
}

test "ABI: Tap bit layout matches C tap_t" {
    // C: typedef struct { uint8_t interrupted:1, speculated:1, reserved1:1, reserved0:1, count:4 }
    var tap = event.Tap{};
    tap.count = 3;
    tap.interrupted = true;
    const raw = @as(u8, @bitCast(tap));
    // bit 0 = interrupted(1), bits 4-7 = count(3) = 0x31
    try testing.expectEqual(@as(u8, 0x31), raw);
}

// ============================================================
// Cross-validation: constructor functions produce correct bit patterns
// ============================================================

test "ABI: ACTION_KEY produces kind=mods, param=keycode" {
    const code = action_code.ACTION_KEY(0x04);
    const action = action_code.Action{ .code = code };
    try testing.expectEqual(@as(u16, 0x0004), code);
    try testing.expectEqual(action_code.ActionKind.mods, action.kind.id);
    try testing.expectEqual(@as(u8, 0x04), action.key.code);
    try testing.expectEqual(@as(u4, 0), action.key.mods);
}

test "ABI: ACTION_MODS_KEY produces correct mod+key encoding" {
    const code = action_code.ACTION_MODS_KEY(0x02, 0x04);
    try testing.expectEqual(@as(u16, 0x0204), code);
    const action = action_code.Action{ .code = code };
    try testing.expectEqual(@as(u8, 0x04), action.key.code);
    try testing.expectEqual(@as(u4, 0x2), action.key.mods);
}

test "ABI: ACTION_LAYER_MOMENTARY produces correct layer_tap encoding" {
    // MO(1) = 0xA1F1
    const code = action_code.ACTION_LAYER_MOMENTARY(1);
    try testing.expectEqual(@as(u16, 0xA1F1), code);
    const action = action_code.Action{ .code = code };
    try testing.expectEqual(@as(u8, 0xF1), action.layer_tap.code);
    try testing.expectEqual(@as(u5, 1), action.layer_tap.val);
}

test "ABI: ACTION_LAYER_TAP_KEY produces correct layer_tap encoding" {
    // LT(2, KC_SPC=0x2C) = 0xA22C
    const code = action_code.ACTION_LAYER_TAP_KEY(2, 0x2C);
    try testing.expectEqual(@as(u16, 0xA22C), code);
    const action = action_code.Action{ .code = code };
    try testing.expectEqual(@as(u8, 0x2C), action.layer_tap.code);
    try testing.expectEqual(@as(u5, 2), action.layer_tap.val);
}

test "ABI: ACTION_LAYER_MODS produces correct layer_mods encoding" {
    // LAYER_MODS(1, LSFT=0x02) = 0x9102
    const code = action_code.ACTION_LAYER_MODS(1, 0x02);
    try testing.expectEqual(@as(u16, 0x9102), code);
    const action = action_code.Action{ .code = code };
    try testing.expectEqual(@as(u8, 0x02), action.layer_mods.mods);
    try testing.expectEqual(@as(u4, 1), action.layer_mods.layer);
}

test "ABI: ACTION_LAYER_GOTO produces correct layer bitop encoding" {
    const code = action_code.ACTION_LAYER_GOTO(1);
    try testing.expectEqual(@as(u16, 0x8D02), code);
}

test "ABI: ACTION_LAYER_TOGGLE produces correct layer bitop encoding" {
    const code = action_code.ACTION_LAYER_TOGGLE(1);
    try testing.expectEqual(@as(u16, 0x8A02), code);
}

test "ABI: ACTION_DEFAULT_LAYER_SET produces correct encoding" {
    const code = action_code.ACTION_DEFAULT_LAYER_SET(0);
    try testing.expectEqual(@as(u16, 0x8C01), code);
}
