//! Grave Escape (QK_GRAVE_ESCAPE) の実装
//! C版 quantum/process_keycode/process_grave_esc.c の移植
//!
//! Shift または GUI が押されているときは KC_GRAVE を送信し、
//! それ以外では KC_ESCAPE を送信する。
//!
//! キーコード: QK_GRAVE_ESCAPE (0x7C16), 略称 QK_GESC

const host = @import("host.zig");
const keycode = @import("keycode.zig");
const KC = keycode.KC;

/// QK_GRAVE_ESCAPE キーコード値
pub const QK_GRAVE_ESCAPE: keycode.Keycode = 0x7C16;
/// 略称
pub const QK_GESC = QK_GRAVE_ESCAPE;

// 8ビット HID mod ビットマスク（modifiers.h 準拠）
const MOD_MASK_SHIFT: u8 = 0x22; // LSHIFT(0x02) | RSHIFT(0x20)
const MOD_MASK_GUI: u8 = 0x88; // LGUI(0x08) | RGUI(0x80)
const MOD_MASK_ALT: u8 = 0x44; // LALT(0x04) | RALT(0x40)
const MOD_MASK_CTRL: u8 = 0x11; // LCTRL(0x01) | RCTRL(0x10)
const MOD_MASK_SG: u8 = MOD_MASK_SHIFT | MOD_MASK_GUI;

/// 最後の QK_GESC プレス時にシフト状態だったか記録する
/// リリース時に正しいキーを解除するために使用する
var grave_esc_was_shifted: bool = false;

/// QK_GRAVE_ESCAPE キーイベントを処理する
///
/// `pressed`: true = プレス、false = リリース
///
/// 戻り値: false（処理済み、通常の処理を継続しない）
pub fn processGraveEsc(pressed: bool) void {
    if (pressed) {
        const mods = host.getMods();
        const shifted: u8 = mods & MOD_MASK_SG;

        grave_esc_was_shifted = (shifted != 0);
        if (shifted != 0) {
            host.registerCode(@intCast(KC.GRAVE));
        } else {
            host.registerCode(@intCast(KC.ESCAPE));
        }
    } else {
        if (grave_esc_was_shifted) {
            host.unregisterCode(@intCast(KC.GRAVE));
        } else {
            host.unregisterCode(@intCast(KC.ESCAPE));
        }
    }
    host.sendKeyboardReport();
}

/// 状態をリセットする（テスト用）
pub fn reset() void {
    grave_esc_was_shifted = false;
}

// ============================================================
// Tests
// ============================================================

const testing = @import("std").testing;
const MockDriver = @import("test_driver.zig").FixedTestDriver(32, 4);

test "QK_GESC without modifiers sends ESC" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // モッドなし → ESC
    processGraveEsc(true);
    try testing.expect(mock.lastKeyboardReport().hasKey(@intCast(KC.ESCAPE)));
    try testing.expect(!mock.lastKeyboardReport().hasKey(@intCast(KC.GRAVE)));

    processGraveEsc(false);
    try testing.expect(!mock.lastKeyboardReport().hasKey(@intCast(KC.ESCAPE)));
}

test "QK_GESC with SHIFT sends GRAVE" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // LSHIFT を押した状態でプレス → GRAVE
    host.addMods(0x02); // LSHIFT
    defer host.delMods(0x02);

    processGraveEsc(true);
    try testing.expect(mock.lastKeyboardReport().hasKey(@intCast(KC.GRAVE)));
    try testing.expect(!mock.lastKeyboardReport().hasKey(@intCast(KC.ESCAPE)));

    processGraveEsc(false);
    try testing.expect(!mock.lastKeyboardReport().hasKey(@intCast(KC.GRAVE)));
}

test "QK_GESC with GUI sends GRAVE" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // LGUI を押した状態でプレス → GRAVE
    host.addMods(0x08); // LGUI
    defer host.delMods(0x08);

    processGraveEsc(true);
    try testing.expect(mock.lastKeyboardReport().hasKey(@intCast(KC.GRAVE)));
    try testing.expect(!mock.lastKeyboardReport().hasKey(@intCast(KC.ESCAPE)));

    processGraveEsc(false);
    try testing.expect(!mock.lastKeyboardReport().hasKey(@intCast(KC.GRAVE)));
}

test "QK_GESC with RSHIFT sends GRAVE" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // RSHIFT を押した状態でプレス → GRAVE
    host.addMods(0x20); // RSHIFT
    defer host.delMods(0x20);

    processGraveEsc(true);
    try testing.expect(mock.lastKeyboardReport().hasKey(@intCast(KC.GRAVE)));

    processGraveEsc(false);
    try testing.expect(!mock.lastKeyboardReport().hasKey(@intCast(KC.GRAVE)));
}

test "QK_GESC release uses press-time state" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // SHIFT が押された状態でプレス → GRAVE
    host.addMods(0x02); // LSHIFT
    processGraveEsc(true);
    try testing.expect(mock.lastKeyboardReport().hasKey(@intCast(KC.GRAVE)));

    // リリース前に SHIFT を離しても GRAVE が解除される
    host.delMods(0x02);
    processGraveEsc(false);
    // grave_esc_was_shifted = true なので GRAVE を解除
    try testing.expect(!mock.lastKeyboardReport().hasKey(@intCast(KC.GRAVE)));
    try testing.expect(!mock.lastKeyboardReport().hasKey(@intCast(KC.ESCAPE)));
}
