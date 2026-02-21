//! Test Fixture for keyboard simulation
//! Zig equivalent of tests/test_common/test_fixture.cpp
//!
//! Provides a simulated keyboard environment for testing key processing logic.

const std = @import("std");
const keycode = @import("keycode.zig");
const event = @import("event.zig");
const report_mod = @import("report.zig");
const TestDriver = @import("test_driver.zig").TestDriver;
const Keycode = keycode.Keycode;
const KC = keycode.KC;
const KeyPos = event.KeyPos;
const KeyEvent = event.KeyEvent;
const KeyboardReport = report_mod.KeyboardReport;

pub const MAX_LAYERS = 16;
pub const MATRIX_ROWS = 4;
pub const MATRIX_COLS = 12;
pub const TAPPING_TERM: u16 = 200; // Reserved for tap/hold implementation (Issue #8)

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
    /// Current layer state (bitmask)
    layer_state: u32,
    /// Default layer
    default_layer: u4,
    /// Current simulated time (ms)
    timer: u16,
    /// Mock driver for capturing reports
    driver: TestDriver,
    /// Keyboard report state
    keyboard_report: KeyboardReport,

    pub fn init(allocator: std.mem.Allocator) TestFixture {
        var fixture = TestFixture{
            .keymap = undefined,
            .matrix = .{0} ** MATRIX_ROWS,
            .layer_state = 1, // Layer 0 active
            .default_layer = 0,
            .timer = 0,
            .driver = TestDriver.init(allocator),
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

    pub fn deinit(self: *TestFixture) void {
        self.driver.deinit();
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
        // Check layers from highest to lowest
        var layer: i5 = MAX_LAYERS - 1;
        while (layer >= 0) : (layer -= 1) {
            if (self.layer_state & (@as(u32, 1) << @intCast(layer)) != 0) {
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
    // Layer management
    // ============================================================

    pub fn layerOn(self: *TestFixture, layer: u4) void {
        self.layer_state |= @as(u32, 1) << layer;
    }

    pub fn layerOff(self: *TestFixture, layer: u4) void {
        self.layer_state &= ~(@as(u32, 1) << @intCast(layer));
    }

    pub fn layerClear(self: *TestFixture) void {
        self.layer_state = @as(u32, 1) << self.default_layer;
    }

    pub fn isLayerOn(self: *const TestFixture, layer: u4) bool {
        return (self.layer_state & (@as(u32, 1) << layer)) != 0;
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
    /// This is a simplified version - full implementation in Issue #8
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
                        // Convert 5-bit mod to 8-bit mod bits
                        // bit4 is the right-modifier flag: when set, bits 0-3
                        // refer to right modifiers instead of left ones.
                        var mods: u8 = 0;
                        if (mod_bits & 0x10 != 0) {
                            // Right modifier flag
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
                        const layer: u4 = @truncate(kc & 0x1F);
                        self.layerOn(layer);
                    }
                }
            }
        }

        // Check for MO() key releases (layer off)
        for (0..MATRIX_ROWS) |row| {
            for (0..MATRIX_COLS) |col| {
                if (!self.isKeyPressed(@intCast(row), @intCast(col))) {
                    // Check all layers for MO() keys that were active
                    for (0..MAX_LAYERS) |layer| {
                        const kc = self.getKeycode(@intCast(layer), @intCast(row), @intCast(col));
                        if (keycode.isMomentary(kc)) {
                            const target_layer: u4 = @truncate(kc & 0x1F);
                            // Only turn off if no other key is holding this layer
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
                            if (!held) self.layerOff(target_layer);
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
        self.layerClear();
        self.keyboard_report = .{};
        self.driver.clearReports();
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
    var fixture = TestFixture.init(std.testing.allocator);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
    });

    // Press KC_A
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try std.testing.expectEqual(@as(usize, 1), fixture.driver.reportCount());
    try fixture.driver.expectReport(0, 0, &.{0x04});

    // Release KC_A
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    try std.testing.expectEqual(@as(usize, 2), fixture.driver.reportCount());
    try fixture.driver.expectEmptyReport(1);
}

test "TestFixture modifier key" {
    var fixture = TestFixture.init(std.testing.allocator);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.LEFT_SHIFT),
    });

    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try std.testing.expectEqual(@as(usize, 1), fixture.driver.reportCount());
    try fixture.driver.expectReport(0, report_mod.ModBit.LSHIFT, &.{});
}

test "TestFixture two keys" {
    var fixture = TestFixture.init(std.testing.allocator);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
        KeymapKey.init(0, 0, 1, KC.B),
    });

    // Press A
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    try fixture.driver.expectReport(0, 0, &.{0x04});

    // Press B (A still held)
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();
    try fixture.driver.expectReport(1, 0, &.{ 0x04, 0x05 });
}

test "TestFixture MO() layer switch" {
    var fixture = TestFixture.init(std.testing.allocator);
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

    const last = fixture.driver.lastKeyboardReport().?;
    try std.testing.expect(last.hasKey(0x05)); // KC_B

    // Release MO(1)
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try std.testing.expect(!fixture.isLayerOn(1));
}

test "TestFixture resolveKeycode transparency" {
    var fixture = TestFixture.init(std.testing.allocator);
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
