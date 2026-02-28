//! Dynamic Tapping Term
//! C版 quantum/process_keycode/process_dynamic_tapping_term.c に相当
//!
//! ランタイムでタッピングターム（タップ/ホールド判定の閾値）を増減するキーコード処理。
//! DT_UP で +5ms、DT_DOWN で -5ms、DT_PRNT で現在値を出力（現在は no-op）。

const keycode = @import("keycode.zig");
const tapping = @import("action_tapping.zig");

const Keycode = keycode.Keycode;

/// Dynamic Tapping Term の増減幅（ミリ秒）
pub const DYNAMIC_TAPPING_TERM_INCREMENT: u16 = 5;

/// Dynamic Tapping Term キーコードを処理する。
/// 該当キーコードを消費した場合は false を返し、後続パイプラインをスキップさせる。
/// 該当しないキーコードの場合は true を返し、後続パイプラインに処理を委譲する。
pub fn process(kc: Keycode, pressed: bool) bool {
    if (kc == keycode.DT_PRNT) {
        if (pressed) {
            // TODO: HID debug 出力（現在は no-op）
        }
        return false;
    } else if (kc == keycode.DT_UP) {
        if (pressed) {
            tapping.tapping_term +|= DYNAMIC_TAPPING_TERM_INCREMENT;
        }
        return false;
    } else if (kc == keycode.DT_DOWN) {
        if (pressed) {
            tapping.tapping_term -|= DYNAMIC_TAPPING_TERM_INCREMENT;
        }
        return false;
    }
    return true;
}

const std = @import("std");
const testing = std.testing;

test "DT_UP increments tapping_term" {
    tapping.tapping_term = 200;
    _ = process(keycode.DT_UP, true);
    try testing.expectEqual(@as(u16, 205), tapping.tapping_term);
}

test "DT_DOWN decrements tapping_term" {
    tapping.tapping_term = 200;
    _ = process(keycode.DT_DOWN, true);
    try testing.expectEqual(@as(u16, 195), tapping.tapping_term);
}

test "DT_DOWN saturates at 0" {
    tapping.tapping_term = 3;
    _ = process(keycode.DT_DOWN, true);
    try testing.expectEqual(@as(u16, 0), tapping.tapping_term);
}

test "DT_UP saturates at max" {
    tapping.tapping_term = std.math.maxInt(u16);
    _ = process(keycode.DT_UP, true);
    try testing.expectEqual(std.math.maxInt(u16), tapping.tapping_term);
}

test "DT_PRNT consumes keycode" {
    const result = process(keycode.DT_PRNT, true);
    try testing.expectEqual(false, result);
}

test "non-DTT keycode passes through" {
    const result = process(keycode.KC.A, true);
    try testing.expectEqual(true, result);
}

test "release events do not modify tapping_term" {
    tapping.tapping_term = 200;
    _ = process(keycode.DT_UP, false);
    try testing.expectEqual(@as(u16, 200), tapping.tapping_term);
    _ = process(keycode.DT_DOWN, false);
    try testing.expectEqual(@as(u16, 200), tapping.tapping_term);
}
