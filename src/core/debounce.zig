//! Debounce module (symmetric defer per-key)
//! Based on quantum/debounce/sym_defer_pk.c
//!
//! Each key has its own debounce timer. A key's state only changes
//! after it has been stable for the debounce period.

const std = @import("std");
const MatrixRow = @import("matrix.zig").MatrixRow;

/// Per-key debounce state, parameterized by actual matrix dimensions.
///
/// Using comptime `rows` and `cols` instead of fixed 32x32 reduces memory
/// usage to exactly what the keyboard needs (e.g. 4x12 = 48 bytes vs 2048 bytes).
pub fn DebounceState(comptime rows: u8, comptime cols: u8) type {
    comptime {
        if (cols > @bitSizeOf(MatrixRow)) {
            @compileError("cols exceeds MatrixRow bit width");
        }
    }

    return struct {
        /// Last time each key changed (used for debounce timing)
        timers: [rows][cols]u16,
        /// Whether each key is currently in debounce period
        active: [rows]MatrixRow,
        /// Debounce time in milliseconds
        debounce_ms: u16,

        pub fn init(debounce_ms: u16) @This() {
            return .{
                .timers = .{.{0} ** cols} ** rows,
                .active = .{0} ** rows,
                .debounce_ms = debounce_ms,
            };
        }

        /// Apply debounce filtering.
        /// `raw` is the raw scan result, `cooked` is the debounced output.
        pub fn debounce(self: *@This(), raw: *const [rows]MatrixRow, cooked: *[rows]MatrixRow, time: u16) void {
            for (raw, 0..) |raw_row, row_idx| {
                const changed = raw_row ^ cooked[row_idx];
                if (changed == 0 and self.active[row_idx] == 0) continue;

                for (0..cols) |col| {
                    const mask = @as(MatrixRow, 1) << @as(u5, @intCast(col));

                    if (self.active[row_idx] & mask != 0) {
                        // Key is in debounce period
                        if (changed & mask != 0) {
                            // Raw still differs from cooked - check if debounce complete
                            if (time -% self.timers[row_idx][col] >= self.debounce_ms) {
                                // Debounce period complete - accept the raw state
                                if (raw_row & mask != 0) {
                                    cooked[row_idx] |= mask;
                                } else {
                                    cooked[row_idx] &= ~mask;
                                }
                                self.active[row_idx] &= ~mask;
                            }
                        } else {
                            // Raw matches cooked again - cancel debounce (bounced back)
                            self.active[row_idx] &= ~mask;
                        }
                    } else if (changed & mask != 0) {
                        // New change detected - start debounce timer
                        self.timers[row_idx][col] = time;
                        self.active[row_idx] |= mask;
                    }
                }
            }
        }
    };
}

// ============================================================
// Tests
// ============================================================

test "debounce ignores changes within debounce period" {
    const State = DebounceState(4, 12);
    var state = State.init(5);
    var raw = [_]MatrixRow{0} ** 4;
    var cooked = [_]MatrixRow{0} ** 4;

    // Key pressed at time 0
    raw[0] = 1;
    state.debounce(&raw, &cooked, 0);
    try std.testing.expectEqual(@as(MatrixRow, 0), cooked[0]); // Not accepted yet

    // Still pressed at time 3 (within debounce period)
    state.debounce(&raw, &cooked, 3);
    try std.testing.expectEqual(@as(MatrixRow, 0), cooked[0]); // Still not accepted

    // Still pressed at time 5 (debounce period complete)
    state.debounce(&raw, &cooked, 5);
    try std.testing.expectEqual(@as(MatrixRow, 1), cooked[0]); // Now accepted
}

test "debounce rejects bouncing" {
    const State = DebounceState(4, 12);
    var state = State.init(5);
    var raw = [_]MatrixRow{0} ** 4;
    var cooked = [_]MatrixRow{0} ** 4;

    // Key pressed
    raw[0] = 1;
    state.debounce(&raw, &cooked, 0);

    // Key bounces (released at time 2)
    raw[0] = 0;
    state.debounce(&raw, &cooked, 2);

    // Wait for debounce period after bounce
    state.debounce(&raw, &cooked, 7);
    try std.testing.expectEqual(@as(MatrixRow, 0), cooked[0]); // Should remain released
}

test "debounce multiple keys" {
    const State = DebounceState(4, 12);
    var state = State.init(5);
    var raw = [_]MatrixRow{0} ** 4;
    var cooked = [_]MatrixRow{0} ** 4;

    // Press key at (0, 0) and (0, 1) at different times
    raw[0] = 0b01; // col 0
    state.debounce(&raw, &cooked, 0);

    raw[0] = 0b11; // col 0 + col 1
    state.debounce(&raw, &cooked, 3);

    // At time 5, col 0 debounce completes
    state.debounce(&raw, &cooked, 5);
    try std.testing.expectEqual(@as(MatrixRow, 0b01), cooked[0]); // Only col 0 accepted

    // At time 8, col 1 debounce completes
    state.debounce(&raw, &cooked, 8);
    try std.testing.expectEqual(@as(MatrixRow, 0b11), cooked[0]); // Both accepted
}
