// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zig port of quantum/eeconfig.c

//! EEPROM設定API（eeconfig）
//! Based on quantum/eeconfig.h / quantum/eeconfig.c
//!
//! EEPROMに magic number を書き込み、有効な設定が存在するかを判定する。
//! QMK upstream の eeconfig_enable/disable/is_enabled に相当する。

const std = @import("std");
const eeprom = @import("../hal/eeprom.zig");

/// C版 eeprom_core_t 互換のEEPROMアドレスレイアウト（quantum/nvm/eeprom/nvm_eeprom_eeconfig_internal.h 参照）
/// struct PACKED {
///   uint16_t magic;          // offset 0
///   uint8_t  debug;          // offset 2
///   uint8_t  default_layer;  // offset 3
///   uint16_t keymap;         // offset 4
///   ...
/// }

/// EEPROM magic number のアドレス（QMK upstream互換）
const EECONFIG_MAGIC_ADDR: u16 = 0;

/// EEPROM debug フラグのアドレス
const EECONFIG_DEBUG_ADDR: u16 = 2;

/// EEPROM default layer のアドレス
const EECONFIG_DEFAULT_LAYER_ADDR: u16 = 3;

/// EEPROM keymap_config のアドレス（C版 EECONFIG_KEYMAP に相当）
pub const EECONFIG_KEYMAP_ADDR: u16 = 4;

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
// KeymapConfig EEPROM API
// upstream の eeconfig_read_keymap() / eeconfig_update_keymap() に相当
// ============================================================

/// EEPROMから keymap 設定を読み出す（raw u16）
/// upstream の eeconfig_read_keymap() に相当。
/// EEPROMが無効な場合は 0 を返す。
/// 呼び出し側で @bitCast(KeymapConfig) に変換して使用する。
pub fn readKeymap() u16 {
    if (!isEnabled()) {
        return 0;
    }
    return eeprom.readWord(EECONFIG_KEYMAP_ADDR);
}

/// keymap 設定を EEPROM に書き込む（raw u16）
/// upstream の eeconfig_update_keymap() に相当。
pub fn updateKeymap(raw: u16) void {
    eeprom.writeWord(EECONFIG_KEYMAP_ADDR, raw);
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

test "eeconfig: readKeymap/updateKeymap ラウンドトリップ" {
    eeprom.mockReset();
    enable();

    // 書き込み → 読み出しで一致する
    const test_value: u16 = 0x1234;
    updateKeymap(test_value);
    try std.testing.expectEqual(test_value, readKeymap());

    // 別の値で上書き
    const test_value2: u16 = 0xABCD;
    updateKeymap(test_value2);
    try std.testing.expectEqual(test_value2, readKeymap());
}

test "eeconfig: readKeymap は未有効時にデフォルト値を返す" {
    eeprom.mockReset();

    // EEPROM が無効なので 0 が返る
    try std.testing.expect(!isEnabled());
    try std.testing.expectEqual(@as(u16, 0), readKeymap());
}
