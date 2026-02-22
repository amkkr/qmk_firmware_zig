//! Test Fixture for keyboard simulation
//! Zig equivalent of tests/test_common/test_fixture.cpp
//!
//! Provides a simulated keyboard environment for testing key processing logic.
//! Uses layer.zig global state and FixedTestDriver (no allocator needed).

const std = @import("std");
const keycode = @import("keycode.zig");
const event = @import("event.zig");
const report_mod = @import("report.zig");
const layer_mod = @import("layer.zig");
const FixedTestDriver = @import("test_driver.zig").FixedTestDriver;
const Keycode = keycode.Keycode;
const KC = keycode.KC;
const KeyPos = event.KeyPos;
const KeyEvent = event.KeyEvent;
const KeyboardReport = report_mod.KeyboardReport;

pub const MAX_LAYERS = 16;
pub const MATRIX_ROWS = 4;
pub const MATRIX_COLS = 12;
pub const TAPPING_TERM: u16 = 200;

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
pub const TestFixture = struct {
    /// Test keymap: [layer][row][col] = keycode
    keymap: [MAX_LAYERS][MATRIX_ROWS][MATRIX_COLS]Keycode,
    /// Simulated matrix state (which keys are currently pressed)
    matrix: [MATRIX_ROWS]u32,
    /// Current simulated time (ms)
    timer: u16,
    /// Mock driver for capturing reports (fixed-size, no allocator)
    driver: FixedTestDriver(64, 16),
    /// Keyboard report state
    keyboard_report: KeyboardReport,

    pub fn init() TestFixture {
        layer_mod.resetState();

        var fixture = TestFixture{
            .keymap = undefined,
            .matrix = .{0} ** MATRIX_ROWS,
            .timer = 0,
            .driver = .{},
            .keyboard_report = .{},
        };

        // Initialize keymap with KC_NO
        for (&fixture.keymap) |*layer| {
            for (layer) |*row| {
                for (row) |*col| {
                    col.* = KC.NO;
                }
            }
        }

        return fixture;
    }

    pub fn deinit(_: *TestFixture) void {
        layer_mod.resetState();
    }

    // ============================================================
    // Keymap management
    // ============================================================

    /// Set the test keymap from a list of key definitions
    pub fn setKeymap(self: *TestFixture, keys: []const KeymapKey) void {
        // Reset to KC_NO
        for (&self.keymap) |*layer| {
            for (layer) |*row| {
                for (row) |*col| {
                    col.* = KC.NO;
                }
            }
        }

        for (keys) |key| {
            self.addKey(key);
        }
    }

    /// Add a single key to the keymap
    pub fn addKey(self: *TestFixture, key: KeymapKey) void {
        self.keymap[key.layer][key.row][key.col] = key.code;
    }

    /// Get keycode at given layer and position
    pub fn getKeycode(self: *const TestFixture, layer: u4, row: u8, col: u8) Keycode {
        if (row >= MATRIX_ROWS or col >= MATRIX_COLS) return KC.NO;
        return self.keymap[layer][row][col];
    }

    /// Resolve keycode considering layer state and transparency
    pub fn resolveKeycode(self: *const TestFixture, row: u8, col: u8) Keycode {
        const state = layer_mod.getLayerState() | layer_mod.getDefaultLayerState();
        var layer: i6 = MAX_LAYERS - 1;
        while (layer >= 0) : (layer -= 1) {
            if (state & (@as(u32, 1) << @as(u5, @intCast(layer))) != 0) {
                const kc = self.getKeycode(@intCast(layer), row, col);
                if (kc != KC.TRNS) return kc;
            }
        }
        return KC.NO;
    }

    // ============================================================
    // Matrix simulation
    // ============================================================

    /// Press a key at the given matrix position
    pub fn pressKey(self: *TestFixture, row: u8, col: u8) void {
        self.matrix[row] |= @as(u32, 1) << @intCast(col);
    }

    /// Release a key at the given matrix position
    pub fn releaseKey(self: *TestFixture, row: u8, col: u8) void {
        self.matrix[row] &= ~(@as(u32, 1) << @intCast(col));
    }

    /// Check if a key is pressed
    pub fn isKeyPressed(self: *const TestFixture, row: u8, col: u8) bool {
        return (self.matrix[row] & (@as(u32, 1) << @intCast(col))) != 0;
    }

    /// Clear all pressed keys
    pub fn clearAllKeys(self: *TestFixture) void {
        self.matrix = .{0} ** MATRIX_ROWS;
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
        layer_mod.resetState();
    }

    pub fn isLayerOn(_: *const TestFixture, layer: u4) bool {
        return layer_mod.layerStateIs(layer);
    }

    // ============================================================
    // Simulation control
    // ============================================================

    /// Advance time by the given number of milliseconds
    pub fn advanceTime(self: *TestFixture, ms: u16) void {
        self.timer +%= ms;
    }

    /// Run one scan loop (advance 1ms and process)
    pub fn runOneScanLoop(self: *TestFixture) void {
        self.advanceTime(1);
        self.processMatrixScan();
    }

    /// Idle for the given number of milliseconds
    pub fn idleFor(self: *TestFixture, ms: u16) void {
        var i: u16 = 0;
        while (i < ms) : (i += 1) {
            self.runOneScanLoop();
        }
    }

    /// Process the current matrix state (simplified keyboard_task)
    /// TODO: Route through action_tapping pipeline for full tap/hold support
    fn processMatrixScan(self: *TestFixture) void {
        var new_report = KeyboardReport{};

        // Scan matrix and build report from pressed keys
        for (0..MATRIX_ROWS) |row| {
            for (0..MATRIX_COLS) |col| {
                if (self.isKeyPressed(@intCast(row), @intCast(col))) {
                    const kc = self.resolveKeycode(@intCast(row), @intCast(col));
                    if (kc == KC.NO or kc == KC.TRNS) continue;

                    // Handle basic keycodes
                    if (keycode.isBasic(kc)) {
                        const basic_kc: u8 = @truncate(kc);
                        if (keycode.isModifier(kc)) {
                            new_report.mods |= report_mod.keycodeToModBit(basic_kc);
                        } else if (basic_kc >= 0x04) {
                            _ = new_report.addKey(basic_kc);
                        }
                    }
                    // Handle modified keycodes (e.g., LSFT(KC_A))
                    else if (keycode.isMods(kc)) {
                        const basic_kc: u8 = @truncate(kc);
                        const mod_bits: u8 = @truncate(kc >> 8);
                        var mods: u8 = 0;
                        if (mod_bits & 0x10 != 0) {
                            if (mod_bits & 0x01 != 0) mods |= report_mod.ModBit.RCTRL;
                            if (mod_bits & 0x02 != 0) mods |= report_mod.ModBit.RSHIFT;
                            if (mod_bits & 0x04 != 0) mods |= report_mod.ModBit.RALT;
                            if (mod_bits & 0x08 != 0) mods |= report_mod.ModBit.RGUI;
                        } else {
                            if (mod_bits & 0x01 != 0) mods |= report_mod.ModBit.LCTRL;
                            if (mod_bits & 0x02 != 0) mods |= report_mod.ModBit.LSHIFT;
                            if (mod_bits & 0x04 != 0) mods |= report_mod.ModBit.LALT;
                            if (mod_bits & 0x08 != 0) mods |= report_mod.ModBit.LGUI;
                        }
                        new_report.mods |= mods;
                        if (basic_kc >= 0x04) {
                            _ = new_report.addKey(basic_kc);
                        }
                    }
                    // MO() - momentary layer
                    else if (keycode.isMomentary(kc)) {
                        const l: u4 = @truncate(kc & 0x1F);
                        layer_mod.layerOn(l);
                    }
                }
            }
        }

        // Check for MO() key releases (layer off)
        for (0..MATRIX_ROWS) |row| {
            for (0..MATRIX_COLS) |col| {
                if (!self.isKeyPressed(@intCast(row), @intCast(col))) {
                    for (0..MAX_LAYERS) |l| {
                        const kc = self.getKeycode(@intCast(l), @intCast(row), @intCast(col));
                        if (keycode.isMomentary(kc)) {
                            const target_layer: u4 = @truncate(kc & 0x1F);
                            var held = false;
                            for (0..MATRIX_ROWS) |r2| {
                                for (0..MATRIX_COLS) |c2| {
                                    if (self.isKeyPressed(@intCast(r2), @intCast(c2))) {
                                        const kc2 = self.resolveKeycode(@intCast(r2), @intCast(c2));
                                        if (keycode.isMomentary(kc2) and @as(u4, @truncate(kc2 & 0x1F)) == target_layer) {
                                            held = true;
                                        }
                                    }
                                }
                            }
                            if (!held) layer_mod.layerOff(target_layer);
                        }
                    }
                }
            }
        }

        // Send report if changed
        if (!reportEqual(&new_report, &self.keyboard_report)) {
            self.keyboard_report = new_report;
            self.driver.sendKeyboard(new_report);
        }
    }

    /// Reset fixture state for next test
    pub fn reset(self: *TestFixture) void {
        self.clearAllKeys();
        layer_mod.resetState();
        self.keyboard_report = .{};
        self.driver.reset();
        self.timer = 0;
    }

    fn reportEqual(a: *const KeyboardReport, b: *const KeyboardReport) bool {
        return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
    }
};

// ============================================================
// Tests
// ============================================================

test "TestFixture basic key press" {
    var fixture = TestFixture.init();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
    });

    // Press KC_A
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try std.testing.expectEqual(@as(usize, 1), fixture.driver.keyboard_count);
    try std.testing.expect(fixture.driver.keyboard_reports[0].hasKey(0x04));

    // Release KC_A
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    try std.testing.expectEqual(@as(usize, 2), fixture.driver.keyboard_count);
    try std.testing.expect(fixture.driver.keyboard_reports[1].isEmpty());
}

test "TestFixture modifier key" {
    var fixture = TestFixture.init();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.LEFT_SHIFT),
    });

    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try std.testing.expectEqual(@as(usize, 1), fixture.driver.keyboard_count);
    try std.testing.expectEqual(report_mod.ModBit.LSHIFT, fixture.driver.keyboard_reports[0].mods);
}

test "TestFixture two keys" {
    var fixture = TestFixture.init();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
        KeymapKey.init(0, 0, 1, KC.B),
    });

    // Press A
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try std.testing.expect(fixture.driver.keyboard_reports[0].hasKey(0x04));

    // Press B (A still held)
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();
    try std.testing.expect(fixture.driver.keyboard_reports[1].hasKey(0x04));
    try std.testing.expect(fixture.driver.keyboard_reports[1].hasKey(0x05));
}

test "TestFixture MO() layer switch" {
    var fixture = TestFixture.init();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.MO(1)),
        KeymapKey.init(0, 0, 1, KC.A),
        KeymapKey.init(1, 0, 1, KC.B),
    });

    // Press MO(1)
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
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
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
        KeymapKey.init(1, 0, 0, KC.TRNS), // Transparent on layer 1
    });

    // Layer 0 only: should return KC_A
    try std.testing.expectEqual(KC.A, fixture.resolveKeycode(0, 0));

    // Activate layer 1: TRNS should fall through to layer 0 -> KC_A
    fixture.layerOn(1);
    try std.testing.expectEqual(KC.A, fixture.resolveKeycode(0, 0));
}
