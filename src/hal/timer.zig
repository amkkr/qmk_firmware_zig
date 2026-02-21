//! Timer driver for RP2040
//! Based on platforms/chibios/timer.c and platforms/test/timer.c
//!
//! Provides millisecond-resolution timing.
//! On real hardware: uses RP2040 timer peripheral.
//! In tests: software-based mock timer.

const std = @import("std");
const builtin = @import("builtin");

const is_freestanding = builtin.os.tag == .freestanding;

// ============================================================
// RP2040 Timer registers
// ============================================================

const rp2040_timer = if (is_freestanding) struct {
    const TIMER_BASE: u32 = 0x40054000;
    const TIMERAWL: *volatile u32 = @ptrFromInt(TIMER_BASE + 0x28);
    const TIMERAWH: *volatile u32 = @ptrFromInt(TIMER_BASE + 0x2C);
} else struct {};

// ============================================================
// Mock timer state
// ============================================================

var mock_timer_ms: u32 = 0;

// ============================================================
// Public Timer API
// ============================================================

/// Initialize the timer (no-op on RP2040, hardware auto-starts)
pub fn init() void {
    if (!is_freestanding) {
        mock_timer_ms = 0;
    }
}

/// Read current time in milliseconds (16-bit, wraps at ~65s)
pub fn read() u16 {
    return @truncate(read32());
}

/// Read current time in milliseconds (32-bit, wraps at ~49 days)
pub fn read32() u32 {
    if (is_freestanding) {
        // RP2040 timer counts in microseconds
        return rp2040_timer.TIMERAWL.* / 1000;
    } else {
        return mock_timer_ms;
    }
}

/// Calculate elapsed time since `start` (16-bit, handles wrap)
pub fn elapsed(start: u16) u16 {
    return read() -% start;
}

/// Calculate elapsed time since `start` (32-bit, handles wrap)
pub fn elapsed32(start: u32) u32 {
    return read32() -% start;
}

/// Busy-wait for the given number of milliseconds
pub fn waitMs(ms: u32) void {
    if (is_freestanding) {
        const start = read32();
        while (elapsed32(start) < ms) {
            asm volatile ("nop");
        }
    } else {
        mock_timer_ms += ms;
    }
}

/// Busy-wait for the given number of microseconds
pub fn waitUs(us: u32) void {
    if (is_freestanding) {
        const start = rp2040_timer.TIMERAWL.*;
        while (rp2040_timer.TIMERAWL.* -% start < us) {
            asm volatile ("nop");
        }
    } else {
        // In mock, round up to ms
        mock_timer_ms += (us + 999) / 1000;
    }
}

// ============================================================
// Mock helpers (test only)
// ============================================================

/// Advance mock timer by the given milliseconds
pub fn mockAdvance(ms: u32) void {
    mock_timer_ms += ms;
}

/// Set mock timer to specific value
pub fn mockSet(ms: u32) void {
    mock_timer_ms = ms;
}

/// Reset mock timer
pub fn mockReset() void {
    mock_timer_ms = 0;
}

// ============================================================
// Tests
// ============================================================

test "timer init and read" {
    init();
    try std.testing.expectEqual(@as(u32, 0), read32());
    try std.testing.expectEqual(@as(u16, 0), read());
}

test "timer elapsed" {
    init();
    const start = read();
    mockAdvance(100);
    try std.testing.expectEqual(@as(u16, 100), elapsed(start));
}

test "timer elapsed32" {
    init();
    const start = read32();
    mockAdvance(50000);
    try std.testing.expectEqual(@as(u32, 50000), elapsed32(start));
}

test "timer waitMs mock" {
    init();
    waitMs(50);
    try std.testing.expectEqual(@as(u32, 50), read32());
}

test "timer 16-bit wrap" {
    init();
    mockSet(0xFFF0);
    const start = read();
    mockAdvance(0x20);
    try std.testing.expectEqual(@as(u16, 0x20), elapsed(start));
}
