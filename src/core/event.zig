// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Based on TMK key event types
// Original: Jun Wako

//! QMK Key Event definitions (Zig port)
//! Based on quantum/keyboard.h

/// Key position in the matrix
pub const KeyPos = packed struct {
    col: u8,
    row: u8,
};

/// Key event type
pub const KeyEventType = enum(u8) {
    tick = 0,
    key = 1,
    encoder_cw = 2,
    encoder_ccw = 3,
    combo = 4,
    dip_switch_on = 5,
    dip_switch_off = 6,
};

/// Key event
pub const KeyEvent = struct {
    key: KeyPos,
    time: u16,
    event_type: KeyEventType = .key,
    pressed: bool,

    pub fn keyPress(row: u8, col: u8, time: u16) KeyEvent {
        return .{
            .key = .{ .row = row, .col = col },
            .time = time,
            .event_type = .key,
            .pressed = true,
        };
    }

    pub fn keyRelease(row: u8, col: u8, time: u16) KeyEvent {
        return .{
            .key = .{ .row = row, .col = col },
            .time = time,
            .event_type = .key,
            .pressed = false,
        };
    }

    pub fn tick(time: u16) KeyEvent {
        return .{
            .key = .{ .row = 0, .col = 0 },
            .time = time,
            .event_type = .tick,
            .pressed = false,
        };
    }

    pub fn isPress(self: KeyEvent) bool {
        return self.pressed and self.event_type == .key;
    }

    pub fn isRelease(self: KeyEvent) bool {
        return !self.pressed and self.event_type == .key;
    }

    pub fn isTick(self: KeyEvent) bool {
        return self.event_type == .tick;
    }
};

/// Tap state (packed into 1 byte, matching C tap_t)
pub const Tap = packed struct {
    interrupted: bool = false,
    speculated: bool = false,
    reserved1: bool = false,
    reserved0: bool = false,
    count: u4 = 0,
};

/// Key record (event + tap state)
pub const KeyRecord = struct {
    event: KeyEvent,
    tap: Tap = .{},
};

// ============================================================
// Tests
// ============================================================

const testing = @import("std").testing;

test "KeyPos size" {
    try testing.expectEqual(@as(usize, 2), @sizeOf(KeyPos));
}

test "Tap size" {
    try testing.expectEqual(@as(usize, 1), @sizeOf(Tap));
}

test "KeyEvent press/release" {
    const press = KeyEvent.keyPress(0, 1, 100);
    try testing.expect(press.isPress());
    try testing.expect(!press.isRelease());
    try testing.expectEqual(@as(u8, 0), press.key.row);
    try testing.expectEqual(@as(u8, 1), press.key.col);
    try testing.expectEqual(@as(u16, 100), press.time);

    const release = KeyEvent.keyRelease(0, 1, 200);
    try testing.expect(!release.isPress());
    try testing.expect(release.isRelease());
}

test "KeyEvent tick" {
    const t = KeyEvent.tick(50);
    try testing.expect(t.isTick());
    try testing.expect(!t.isPress());
    try testing.expect(!t.isRelease());
}

test "Tap count" {
    var tap = Tap{ .count = 3 };
    try testing.expectEqual(@as(u4, 3), tap.count);
    tap.interrupted = true;
    try testing.expect(tap.interrupted);
}
