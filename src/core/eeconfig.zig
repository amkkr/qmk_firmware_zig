//! EEPROM設定API（eeconfig）
//! Based on quantum/eeconfig.h / quantum/eeconfig.c
//!
//! EEPROMに magic number を書き込み、有効な設定が存在するかを判定する。
//! QMK upstream の eeconfig_enable/disable/is_enabled に相当する。

const std = @import("std");
const eeprom = @import("../hal/eeprom.zig");

/// EEPROM magic number のアドレス（QMK upstream互換）
const EECONFIG_MAGIC_ADDR: u16 = 0;

/// EEPROM magic number（有効な設定が書き込まれていることを示す）
const EECONFIG_MAGIC_NUMBER: u16 = 0xFEED;

/// EEPROM magic number の無効値（設定が消去されていることを示す）
const EECONFIG_MAGIC_INVALID: u16 = 0xFFFF;

/// EEPROMの設定を無効化（magic numberを消去）
/// upstream の eeconfig_disable() に相当
pub fn disable() void {
    eeprom.writeWord(EECONFIG_MAGIC_ADDR, EECONFIG_MAGIC_INVALID);
}

/// EEPROMに有効な設定があるか確認
/// upstream の eeconfig_is_enabled() に相当
pub fn isEnabled() bool {
    return eeprom.readWord(EECONFIG_MAGIC_ADDR) == EECONFIG_MAGIC_NUMBER;
}

/// EEPROMの設定を有効化（magic numberを書き込み）
/// upstream の eeconfig_enable() に相当
pub fn enable() void {
    eeprom.writeWord(EECONFIG_MAGIC_ADDR, EECONFIG_MAGIC_NUMBER);
}

// ============================================================
// Tests
// ============================================================

test "eeconfig: 有効化/無効化" {
    eeprom.mockReset();

    // 初期状態: 未設定（0xFFFF）
    try std.testing.expect(!isEnabled());

    // 有効化
    enable();
    try std.testing.expect(isEnabled());

    // 無効化
    disable();
    try std.testing.expect(!isEnabled());
}
