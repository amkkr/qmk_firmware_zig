//! Matrix scan module
//! Based on quantum/matrix.c and quantum/matrix_common.c
//!
//! COL2ROW scanning: columns are outputs (active low), rows are inputs (pull-up).
//! When a key is pressed, it connects a column to a row.

const std = @import("std");
const builtin = @import("builtin");
const gpio = @import("../hal/gpio.zig");
const timer = @import("../hal/timer.zig");
const debounce = @import("debounce.zig");

pub const MatrixRow = u32;

/// Matrix configuration (set by keyboard definition).
/// `rows` and `cols` are provided as comptime parameters to `Matrix(rows, cols)`.
pub const Config = struct {
    col_pins: []const gpio.Pin,
    row_pins: []const gpio.Pin,
    debounce_ms: u16 = 5,
};

/// Matrix state, parameterized by actual matrix dimensions.
///
/// Using comptime `rows` and `cols` avoids the previous 32x32 over-allocation
/// and sizes all arrays exactly to the keyboard's matrix.
pub fn Matrix(comptime rows: u8, comptime cols: u8) type {
    comptime {
        if (cols > @bitSizeOf(MatrixRow)) {
            @compileError("cols exceeds MatrixRow bit width");
        }
    }

    return struct {
        config: Config,
        /// Current debounced matrix state
        current: [rows]MatrixRow,
        /// Previous matrix state (for change detection)
        previous: [rows]MatrixRow,
        /// Raw (undebounced) matrix state
        raw: [rows]MatrixRow,
        /// Debounce state
        debounce_state: debounce.DebounceState(rows, cols),

        pub fn init(config: Config) @This() {
            std.debug.assert(config.row_pins.len == rows);
            std.debug.assert(config.col_pins.len == cols);

            var m = @This(){
                .config = config,
                .current = .{0} ** rows,
                .previous = .{0} ** rows,
                .raw = .{0} ** rows,
                .debounce_state = debounce.DebounceState(rows, cols).init(config.debounce_ms),
            };

            // Configure pins
            m.initPins();
            return m;
        }

        fn initPins(self: *@This()) void {
            // Rows as input with pull-up (COL2ROW: rows are read)
            for (self.config.row_pins) |pin| {
                gpio.setPinInputHigh(pin);
            }

            // Columns as output, initially high (inactive)
            for (self.config.col_pins) |pin| {
                gpio.setPinOutput(pin);
                gpio.writePinHigh(pin);
            }
        }

        /// Perform a full matrix scan. Returns true if any key changed.
        pub fn scan(self: *@This()) bool {
            self.previous = self.current;

            // Scan each column
            for (0..cols) |col| {
                self.scanColumn(@intCast(col));
            }

            // Apply debounce
            const time = timer.read();
            self.debounce_state.debounce(&self.raw, &self.current, time);

            return self.hasChanged();
        }

        fn scanColumn(self: *@This(), col: u8) void {
            const col_pin = self.config.col_pins[col];

            // Activate column (drive low)
            gpio.writePinLow(col_pin);

            // Small delay for signal to settle
            // On real hardware: a few NOPs. In mock: instant.
            matrixOutputSelectDelay();

            // Read all rows
            for (0..rows) |row| {
                const row_pin = self.config.row_pins[row];
                // With pull-up, unpressed = high (1), pressed = low (0)
                const pressed = !gpio.readPin(row_pin);
                if (pressed) {
                    self.raw[row] |= @as(MatrixRow, 1) << @intCast(col);
                } else {
                    self.raw[row] &= ~(@as(MatrixRow, 1) << @intCast(col));
                }
            }

            // Deactivate column (drive high)
            gpio.writePinHigh(col_pin);
        }

        fn matrixOutputSelectDelay() void {
            // On RP2040: ~30ns per NOP at 125MHz, need ~1µs settling time
            // In tests: no delay needed
            if (@import("builtin").os.tag == .freestanding) {
                var i: u32 = 0;
                while (i < 30) : (i += 1) {
                    asm volatile ("nop");
                }
            }
        }

        /// Check if key at (row, col) is currently pressed
        pub fn isOn(self: *const @This(), row: u8, col: u8) bool {
            return (self.current[row] & (@as(MatrixRow, 1) << @intCast(col))) != 0;
        }

        /// Get the state of a row
        pub fn getRow(self: *const @This(), row: u8) MatrixRow {
            return self.current[row];
        }

        /// Check if any key changed since last scan
        pub fn hasChanged(self: *const @This()) bool {
            for (0..rows) |row| {
                if (self.current[row] != self.previous[row]) return true;
            }
            return false;
        }

        /// Check if a specific key changed since last scan
        pub fn keyChanged(self: *const @This(), row: u8, col: u8) bool {
            const mask = @as(MatrixRow, 1) << @intCast(col);
            return (self.current[row] & mask) != (self.previous[row] & mask);
        }

        // ============================================================
        // Mock helpers (test only)
        // ============================================================

        /// Directly set a key's raw state (bypasses GPIO, for testing)
        pub fn mockPress(self: *@This(), row: u8, col: u8) void {
            self.raw[row] |= @as(MatrixRow, 1) << @intCast(col);
        }

        /// Directly clear a key's raw state (bypasses GPIO, for testing)
        pub fn mockRelease(self: *@This(), row: u8, col: u8) void {
            self.raw[row] &= ~(@as(MatrixRow, 1) << @intCast(col));
        }

        /// Apply raw state directly to current (bypasses debounce, for testing)
        pub fn mockApply(self: *@This()) void {
            self.previous = self.current;
            self.current = self.raw;
        }
    };
}

// ============================================================
// Tests
// ============================================================

test "Matrix init" {
    const col_pins = [_]gpio.Pin{ 8, 9, 10, 11 };
    const row_pins = [_]gpio.Pin{ 14, 15, 16, 17 };

    gpio.mockReset();
    var m = Matrix(4, 4).init(.{
        .col_pins = &col_pins,
        .row_pins = &row_pins,
    });

    // All keys should be unpressed
    for (0..4) |row| {
        try std.testing.expectEqual(@as(MatrixRow, 0), m.getRow(@intCast(row)));
    }
}

test "Matrix mock press/release" {
    const col_pins = [_]gpio.Pin{ 8, 9, 10, 11 };
    const row_pins = [_]gpio.Pin{ 14, 15, 16, 17 };

    gpio.mockReset();
    var m = Matrix(4, 4).init(.{
        .col_pins = &col_pins,
        .row_pins = &row_pins,
    });

    // Press key at (0, 0)
    m.mockPress(0, 0);
    m.mockApply();
    try std.testing.expect(m.isOn(0, 0));
    try std.testing.expect(m.hasChanged());

    // Release key
    m.mockRelease(0, 0);
    m.mockApply();
    try std.testing.expect(!m.isOn(0, 0));
    try std.testing.expect(m.hasChanged());
}

test "Matrix multiple keys" {
    const col_pins = [_]gpio.Pin{ 8, 9, 10, 11 };
    const row_pins = [_]gpio.Pin{ 14, 15, 16, 17 };

    gpio.mockReset();
    var m = Matrix(4, 4).init(.{
        .col_pins = &col_pins,
        .row_pins = &row_pins,
    });

    m.mockPress(0, 0);
    m.mockPress(1, 2);
    m.mockPress(3, 3);
    m.mockApply();

    try std.testing.expect(m.isOn(0, 0));
    try std.testing.expect(!m.isOn(0, 1));
    try std.testing.expect(m.isOn(1, 2));
    try std.testing.expect(m.isOn(3, 3));
}

test "Matrix keyChanged" {
    const col_pins = [_]gpio.Pin{ 8, 9, 10, 11 };
    const row_pins = [_]gpio.Pin{ 14, 15, 16, 17 };

    gpio.mockReset();
    var m = Matrix(4, 4).init(.{
        .col_pins = &col_pins,
        .row_pins = &row_pins,
    });

    m.mockPress(0, 0);
    m.mockApply();
    try std.testing.expect(m.keyChanged(0, 0));
    try std.testing.expect(!m.keyChanged(0, 1));

    // No change on next apply
    m.mockApply();
    try std.testing.expect(!m.keyChanged(0, 0));
}
