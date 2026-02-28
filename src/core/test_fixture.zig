// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! Test Fixture for keyboard simulation
//! Zig equivalent of tests/test_common/test_fixture.cpp
//!
//! keyboard.zig の keyboard_task() パイプライン経由でキー処理を行う。
//! processMatrixScan() による独自処理は廃止し、action/tapping パイプラインを使用。

const std = @import("std");
const keycode = @import("keycode.zig");
const report_mod = @import("report.zig");
const layer_mod = @import("layer.zig");
const keyboard = @import("keyboard.zig");
const timer = @import("../hal/timer.zig");
const tapping = @import("action_tapping.zig");
const FixedTestDriver = @import("test_driver.zig").FixedTestDriver;
const Keycode = keycode.Keycode;
const KC = keycode.KC;
const KeyboardReport = report_mod.KeyboardReport;

pub const MAX_LAYERS = 16;
pub const MATRIX_ROWS = keyboard.MATRIX_ROWS;
pub const MATRIX_COLS = keyboard.MATRIX_COLS;
pub const TAPPING_TERM: u16 = tapping.TAPPING_TERM;

/// Key definition for test keymaps
pub const KeymapKey = struct {
    layer: u4,
    row: u8,
    col: u8,
    code: Keycode,

    pub fn init(layer: u4, row: u8, col: u8, code: Keycode) KeymapKey {
        return .{
            .layer = layer,
            .row = row,
            .col = col,
            .code = code,
        };
    }
};

/// Test fixture for keyboard simulation
/// keyboard.zig の task() パイプラインに委譲する。
pub const TestFixture = struct {
    /// Mock driver for capturing reports (fixed-size, no allocator)
    driver: FixedTestDriver(64, 16),

    /// 構造体を初期化する（ドライバ登録はまだ行わない）
    pub fn init() TestFixture {
        return TestFixture{
            .driver = .{},
        };
    }

    /// ドライバ登録を含むフルセットアップ（init() 後、self のアドレスが確定してから呼ぶ）
    pub fn setup(self: *TestFixture) void {
        keyboard.initTest(keyboard.host.HostDriver.from(&self.driver));
    }

    pub fn deinit(_: *TestFixture) void {
        keyboard.host.clearDriver();
    }

    // ============================================================
    // Keymap management
    // ============================================================

    /// Set the test keymap from a list of key definitions
    pub fn setKeymap(_: *TestFixture, keys: []const KeymapKey) void {
        const km = keyboard.getTestKeymap();
        km.* = @import("keymap.zig").emptyKeymap();
        for (keys) |key| {
            km[key.layer][key.row][key.col] = key.code;
        }
    }

    /// Add a single key to the keymap
    pub fn addKey(_: *TestFixture, key: KeymapKey) void {
        keyboard.setTestKey(key.layer, key.row, key.col, key.code);
    }

    // ============================================================
    // Matrix simulation (delegates to keyboard.zig)
    // ============================================================

    /// Press a key at the given matrix position
    pub fn pressKey(_: *TestFixture, row: u8, col: u8) void {
        keyboard.pressKey(row, col);
    }

    /// Release a key at the given matrix position
    pub fn releaseKey(_: *TestFixture, row: u8, col: u8) void {
        keyboard.releaseKey(row, col);
    }

    /// Clear all pressed keys
    pub fn clearAllKeys(_: *TestFixture) void {
        keyboard.clearAllKeys();
    }

    // ============================================================
    // Layer management (delegates to layer.zig global state)
    // ============================================================

    pub fn layerOn(_: *TestFixture, layer: u4) void {
        layer_mod.layerOn(layer);
    }

    pub fn layerOff(_: *TestFixture, layer: u4) void {
        layer_mod.layerOff(layer);
    }

    pub fn layerClear(_: *TestFixture) void {
        layer_mod.layerClear();
    }

    pub fn isLayerOn(_: *const TestFixture, layer: u4) bool {
        return layer_mod.layerStateIs(layer);
    }

    // ============================================================
    // Simulation control
    // ============================================================

    /// Run one scan loop (advance 1ms and process via keyboard.task)
    pub fn runOneScanLoop(_: *TestFixture) void {
        timer.mockAdvance(1);
        keyboard.task();
    }

    /// Idle for the given number of milliseconds
    pub fn idleFor(self: *TestFixture, ms: u16) void {
        var i: u16 = 0;
        while (i < ms) : (i += 1) {
            self.runOneScanLoop();
        }
    }

    /// Reset fixture state for next test
    pub fn reset(self: *TestFixture) void {
        self.driver.reset();
        keyboard.init();
        keyboard.host.setDriver(keyboard.host.HostDriver.from(&self.driver));
        @import("action.zig").setActionResolver(keyboard.keymapActionResolver);
    }
};

// ============================================================
// Tests
// ============================================================

test "TestFixture basic key press" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
    });

    // Press KC_A
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try std.testing.expect(fixture.driver.keyboard_count >= 1);
    try std.testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x04));
    try std.testing.expectEqual(@as(u8, 0), fixture.driver.lastKeyboardReport().mods);

    // Release KC_A
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    try std.testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "TestFixture modifier key" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.LEFT_SHIFT),
    });

    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try std.testing.expect(fixture.driver.keyboard_count >= 1);
    try std.testing.expectEqual(
        report_mod.ModBit.LSHIFT,
        fixture.driver.lastKeyboardReport().mods & report_mod.ModBit.LSHIFT,
    );
}

test "TestFixture two keys" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
        KeymapKey.init(0, 0, 1, KC.B),
    });

    // Press A
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try std.testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x04));

    // Press B (A still held)
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();
    try std.testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x04));
    try std.testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x05));
}

test "TestFixture MO() layer switch" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.MO(1)),
        KeymapKey.init(0, 0, 1, KC.A),
        KeymapKey.init(1, 0, 1, KC.B),
    });

    // Press MO(1) — tapping パイプラインのため TAPPING_TERM 待ちが必要
    fixture.pressKey(0, 0);
    fixture.idleFor(TAPPING_TERM + 1);
    try std.testing.expect(fixture.isLayerOn(1));

    // Press key on layer 1 -> should be KC_B
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();

    const last = fixture.driver.lastKeyboardReport();
    try std.testing.expect(last.hasKey(0x05)); // KC_B

    // Release MO(1)
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try std.testing.expect(!fixture.isLayerOn(1));
}

test "TestFixture resolveKeycode transparency" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
        KeymapKey.init(1, 0, 0, KC.TRNS),
    });

    // Layer 0 only: press key -> should get KC_A
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try std.testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x04));

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // Activate layer 1 and press key -> TRNS falls through to layer 0 -> KC_A
    fixture.layerOn(1);
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try std.testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x04));
}
