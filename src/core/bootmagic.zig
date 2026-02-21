//! Bootmagic Lite implementation
//! Based on quantum/bootmagic/bootmagic.c
//!
//! Bootmagic Lite: 起動時に特定キー（デフォルト: row=0, col=0, ESCキー位置）を
//! 押しながら電源を入れると、EEPROMをリセットしてブートローダーモードに入る。
//! フルBootmagicと異なり、この簡易版は単一キーの検出のみを行う。

const std = @import("std");
const builtin = @import("builtin");
const matrix = @import("matrix.zig");
const eeprom = @import("../hal/eeprom.zig");
const bootloader = @import("../hal/bootloader.zig");
const timer = @import("../hal/timer.zig");

const is_test = builtin.is_test;

// ============================================================
// Configuration
// ============================================================

/// Bootmagicで検出するキーの行（デフォルト: 0 = ESCキー位置）
pub const BOOTMAGIC_ROW: u8 = 0;

/// Bootmagicで検出するキーの列（デフォルト: 0 = ESCキー位置）
pub const BOOTMAGIC_COLUMN: u8 = 0;

/// Bootmagicスキャン時のデバウンス待ち時間（ミリ秒）
/// upstreamでは DEBOUNCE * 2 または 30ms
pub const BOOTMAGIC_DEBOUNCE_MS: u16 = 30;

// ============================================================
// EEPROM設定（eeconfig相当）
// ============================================================

/// EEPROM magic number のアドレス（QMK upstream互換）
const EECONFIG_MAGIC_ADDR: u16 = 0;

/// EEPROM magic number（有効な設定が書き込まれていることを示す）
const EECONFIG_MAGIC_NUMBER: u16 = 0xFEED;

/// EEPROMの設定を無効化（magic numberを消去）
/// upstream の eeconfig_disable() に相当
pub fn eeconfigDisable() void {
    eeprom.writeWord(EECONFIG_MAGIC_ADDR, 0xFFFF);
}

/// EEPROMに有効な設定があるか確認
pub fn eeconfigIsEnabled() bool {
    return eeprom.readWord(EECONFIG_MAGIC_ADDR) == EECONFIG_MAGIC_NUMBER;
}

/// EEPROMの設定を有効化（magic numberを書き込み）
pub fn eeconfigEnable() void {
    eeprom.writeWord(EECONFIG_MAGIC_ADDR, EECONFIG_MAGIC_NUMBER);
}

// ============================================================
// Bootmagic Lite
// ============================================================

/// マトリックスの特定キーが押されているか検出する
pub fn shouldReset(m: *const matrix.Matrix) bool {
    return m.isOn(BOOTMAGIC_ROW, BOOTMAGIC_COLUMN);
}

/// Bootmagicスキャンを実行する
/// マトリックスを2回スキャンし（デバウンスのため）、
/// 指定キーが押されていればEEPROMをリセットしてブートローダーにジャンプする。
///
/// テスト時はブートローダージャンプの代わりにフラグをセットする。
pub fn scan(m: *matrix.Matrix) void {
    // デバウンスのため2回スキャン
    _ = m.scan();
    if (!is_test) {
        timer.waitMs(BOOTMAGIC_DEBOUNCE_MS);
    }
    _ = m.scan();

    if (shouldReset(m)) {
        // EEPROMリセット
        eeconfigDisable();

        if (!is_test) {
            // ブートローダーにジャンプ（noreturn）
            bootloader.jump();
        } else {
            // テスト環境ではフラグをセット
            test_state.bootloader_jumped = true;
        }
    }
}

/// Bootmagic初期化（keyboard_init()から呼ばれる）
pub fn init(m: *matrix.Matrix) void {
    scan(m);
}

// ============================================================
// テスト用のモック状態
// ============================================================

pub const test_state = if (is_test) struct {
    pub var bootloader_jumped: bool = false;

    pub fn reset() void {
        bootloader_jumped = false;
    }
} else struct {};

// ============================================================
// Tests
// ============================================================

const gpio = @import("../hal/gpio.zig");

test "bootmagic: キーが押されていない場合はブートローダーにジャンプしない" {
    gpio.mockReset();
    eeprom.mockReset();
    test_state.reset();

    const col_pins = [_]gpio.Pin{ 8, 9, 10, 11 };
    const row_pins = [_]gpio.Pin{ 14, 15, 16, 17 };

    var m = matrix.Matrix.init(.{
        .rows = 4,
        .cols = 4,
        .col_pins = &col_pins,
        .row_pins = &row_pins,
    });

    // EEPROMを有効化しておく
    eeconfigEnable();

    // Bootmagicスキャン実行（キーは押されていない）
    scan(&m);

    // ブートローダーにジャンプしていないことを確認
    try std.testing.expect(!test_state.bootloader_jumped);

    // EEPROMが有効なまま残っていることを確認
    try std.testing.expect(eeconfigIsEnabled());
}

test "bootmagic: ESCキー（row=0,col=0）が押されている場合はブートローダーにジャンプする" {
    gpio.mockReset();
    eeprom.mockReset();
    test_state.reset();

    const col_pins = [_]gpio.Pin{ 8, 9, 10, 11 };
    const row_pins = [_]gpio.Pin{ 14, 15, 16, 17 };

    var m = matrix.Matrix.init(.{
        .rows = 4,
        .cols = 4,
        .col_pins = &col_pins,
        .row_pins = &row_pins,
    });

    // EEPROMを有効化
    eeconfigEnable();
    try std.testing.expect(eeconfigIsEnabled());

    // BOOTMAGIC_ROW, BOOTMAGIC_COLUMN のキーを押す
    m.mockPress(BOOTMAGIC_ROW, BOOTMAGIC_COLUMN);
    m.mockApply();

    // Bootmagicスキャン実行
    scan(&m);

    // ブートローダーにジャンプしたことを確認
    try std.testing.expect(test_state.bootloader_jumped);

    // EEPROMが無効化されたことを確認
    try std.testing.expect(!eeconfigIsEnabled());
}

test "bootmagic: 別のキーが押されてもブートローダーにジャンプしない" {
    gpio.mockReset();
    eeprom.mockReset();
    test_state.reset();

    const col_pins = [_]gpio.Pin{ 8, 9, 10, 11 };
    const row_pins = [_]gpio.Pin{ 14, 15, 16, 17 };

    var m = matrix.Matrix.init(.{
        .rows = 4,
        .cols = 4,
        .col_pins = &col_pins,
        .row_pins = &row_pins,
    });

    // 別のキー（row=1, col=2）を押す
    m.mockPress(1, 2);
    m.mockApply();

    // Bootmagicスキャン実行
    scan(&m);

    // ブートローダーにジャンプしていないことを確認
    try std.testing.expect(!test_state.bootloader_jumped);
}

test "bootmagic: shouldReset はマトリックスの状態を正しく判定する" {
    gpio.mockReset();

    const col_pins = [_]gpio.Pin{ 8, 9, 10, 11 };
    const row_pins = [_]gpio.Pin{ 14, 15, 16, 17 };

    var m = matrix.Matrix.init(.{
        .rows = 4,
        .cols = 4,
        .col_pins = &col_pins,
        .row_pins = &row_pins,
    });

    // 初期状態: 押されていない
    try std.testing.expect(!shouldReset(&m));

    // ESCキー位置を押す
    m.mockPress(BOOTMAGIC_ROW, BOOTMAGIC_COLUMN);
    m.mockApply();
    try std.testing.expect(shouldReset(&m));

    // キーを離す
    m.mockRelease(BOOTMAGIC_ROW, BOOTMAGIC_COLUMN);
    m.mockApply();
    try std.testing.expect(!shouldReset(&m));
}

test "bootmagic: eeconfig の有効化/無効化" {
    eeprom.mockReset();

    // 初期状態: 未設定（0xFFFF）
    try std.testing.expect(!eeconfigIsEnabled());

    // 有効化
    eeconfigEnable();
    try std.testing.expect(eeconfigIsEnabled());

    // 無効化
    eeconfigDisable();
    try std.testing.expect(!eeconfigIsEnabled());
}
