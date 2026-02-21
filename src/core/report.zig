//! QMK HID Report definitions (Zig port)
//! Based on tmk_core/protocol/report.h
//!
//! USB HID report structures for keyboard, mouse, and consumer/system devices.

/// HID Report IDs
pub const ReportId = enum(u8) {
    keyboard = 1,
    mouse = 2,
    system = 3,
    consumer = 4,
    programmable_button = 5,
    nkro = 6,
    joystick = 7,
    digitizer = 8,
};

/// Keyboard modifier bits (8-bit, for HID report byte 0)
pub const ModBit = struct {
    pub const LCTRL: u8 = 0x01;
    pub const LSHIFT: u8 = 0x02;
    pub const LALT: u8 = 0x04;
    pub const LGUI: u8 = 0x08;
    pub const RCTRL: u8 = 0x10;
    pub const RSHIFT: u8 = 0x20;
    pub const RALT: u8 = 0x40;
    pub const RGUI: u8 = 0x80;
};

/// Mouse button bits
pub const MouseBtn = struct {
    pub const BTN1: u8 = 0x01;
    pub const BTN2: u8 = 0x02;
    pub const BTN3: u8 = 0x04;
    pub const BTN4: u8 = 0x08;
    pub const BTN5: u8 = 0x10;
    pub const BTN6: u8 = 0x20;
    pub const BTN7: u8 = 0x40;
    pub const BTN8: u8 = 0x80;
};

/// Maximum simultaneous keys in 6KRO mode
pub const KEYBOARD_REPORT_KEYS = 6;

/// 6KRO Keyboard report (8 bytes, USB HID Boot Protocol compatible)
pub const KeyboardReport = extern struct {
    mods: u8 = 0,
    reserved: u8 = 0,
    keys: [KEYBOARD_REPORT_KEYS]u8 = .{0} ** KEYBOARD_REPORT_KEYS,

    pub fn clear(self: *KeyboardReport) void {
        self.mods = 0;
        self.reserved = 0;
        self.keys = .{0} ** KEYBOARD_REPORT_KEYS;
    }

    /// Add a keycode to the report. Returns false if report is full or kc is 0 (KC.NO).
    pub fn addKey(self: *KeyboardReport, kc: u8) bool {
        if (kc == 0) return false;
        // Check if already present
        for (&self.keys) |*k| {
            if (k.* == kc) return true;
        }
        // Find empty slot
        for (&self.keys) |*k| {
            if (k.* == 0) {
                k.* = kc;
                return true;
            }
        }
        return false; // Report full (6KRO limit)
    }

    /// Remove a keycode from the report.
    pub fn removeKey(self: *KeyboardReport, kc: u8) void {
        for (&self.keys) |*k| {
            if (k.* == kc) {
                k.* = 0;
                return;
            }
        }
    }

    /// Check if a keycode is in the report.
    pub fn hasKey(self: *const KeyboardReport, kc: u8) bool {
        for (self.keys) |k| {
            if (k == kc) return true;
        }
        return false;
    }

    /// Check if the report is empty (no keys, no modifiers).
    pub fn isEmpty(self: *const KeyboardReport) bool {
        if (self.mods != 0) return false;
        for (self.keys) |k| {
            if (k != 0) return false;
        }
        return true;
    }

    comptime {
        if (@sizeOf(KeyboardReport) != 8) {
            @compileError("KeyboardReport must be 8 bytes");
        }
    }
};

/// Mouse report
pub const MouseReport = extern struct {
    buttons: u8 = 0,
    x: i8 = 0,
    y: i8 = 0,
    v: i8 = 0, // vertical scroll
    h: i8 = 0, // horizontal scroll

    pub fn clear(self: *MouseReport) void {
        self.* = .{};
    }

    pub fn isEmpty(self: *const MouseReport) bool {
        return self.buttons == 0 and self.x == 0 and self.y == 0 and self.v == 0 and self.h == 0;
    }

    comptime {
        if (@sizeOf(MouseReport) != 5) {
            @compileError("MouseReport must be 5 bytes");
        }
    }
};

/// Extra report (system control / consumer control)
pub const ExtraReport = extern struct {
    report_id: u8 = 0,
    usage: u16 align(1) = 0,

    pub fn system(usage_code: u16) ExtraReport {
        return .{
            .report_id = @intFromEnum(ReportId.system),
            .usage = usage_code,
        };
    }

    pub fn consumer(usage_code: u16) ExtraReport {
        return .{
            .report_id = @intFromEnum(ReportId.consumer),
            .usage = usage_code,
        };
    }

    pub fn clear(self: *ExtraReport) void {
        self.usage = 0;
    }

    pub fn isEmpty(self: *const ExtraReport) bool {
        return self.usage == 0;
    }

    comptime {
        if (@sizeOf(ExtraReport) != 3) {
            @compileError("ExtraReport must be 3 bytes");
        }
    }
};

/// Matrix row type (one bit per column)
pub const MatrixRow = u32;

/// Convert a modifier keycode (0xE0-0xE7) to its corresponding modifier bit
pub inline fn keycodeToModBit(kc: u8) u8 {
    if (kc >= 0xE0 and kc <= 0xE7) {
        return @as(u8, 1) << @truncate(kc - 0xE0);
    }
    return 0;
}

// ============================================================
// Tests
// ============================================================

const testing = @import("std").testing;

test "KeyboardReport size is 8 bytes" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(KeyboardReport));
}

test "MouseReport size is 5 bytes" {
    try testing.expectEqual(@as(usize, 5), @sizeOf(MouseReport));
}

test "ExtraReport size is 3 bytes" {
    try testing.expectEqual(@as(usize, 3), @sizeOf(ExtraReport));
}

test "KeyboardReport add/remove keys" {
    var report = KeyboardReport{};
    try testing.expect(report.isEmpty());

    try testing.expect(report.addKey(0x04)); // KC_A
    try testing.expect(report.hasKey(0x04));
    try testing.expect(!report.isEmpty());

    try testing.expect(report.addKey(0x05)); // KC_B
    try testing.expect(report.hasKey(0x05));

    report.removeKey(0x04);
    try testing.expect(!report.hasKey(0x04));
    try testing.expect(report.hasKey(0x05));

    report.clear();
    try testing.expect(report.isEmpty());
}

test "KeyboardReport 6KRO limit" {
    var report = KeyboardReport{};
    // Fill all 6 slots
    var i: u8 = 0;
    while (i < 6) : (i += 1) {
        try testing.expect(report.addKey(0x04 + i));
    }
    // 7th key should fail
    try testing.expect(!report.addKey(0x0A));
}

test "KeyboardReport modifier bits" {
    var report = KeyboardReport{};
    report.mods = ModBit.LSHIFT | ModBit.LCTRL;
    try testing.expectEqual(@as(u8, 0x03), report.mods);
    try testing.expect(!report.isEmpty());
}

test "MouseReport" {
    var report = MouseReport{};
    try testing.expect(report.isEmpty());

    report.buttons = MouseBtn.BTN1;
    report.x = 10;
    report.y = -5;
    try testing.expect(!report.isEmpty());

    report.clear();
    try testing.expect(report.isEmpty());
}

test "ExtraReport" {
    const consumer = ExtraReport.consumer(0x00E2); // Audio Mute
    try testing.expectEqual(@as(u8, 4), consumer.report_id);
    try testing.expectEqual(@as(u16, 0x00E2), consumer.usage);

    const sys = ExtraReport.system(0x0081); // System Power Down
    try testing.expectEqual(@as(u8, 3), sys.report_id);
    try testing.expectEqual(@as(u16, 0x0081), sys.usage);
}

test "keycodeToModBit" {
    try testing.expectEqual(@as(u8, 0x01), keycodeToModBit(0xE0)); // LCTRL
    try testing.expectEqual(@as(u8, 0x02), keycodeToModBit(0xE1)); // LSHIFT
    try testing.expectEqual(@as(u8, 0x04), keycodeToModBit(0xE2)); // LALT
    try testing.expectEqual(@as(u8, 0x08), keycodeToModBit(0xE3)); // LGUI
    try testing.expectEqual(@as(u8, 0x10), keycodeToModBit(0xE4)); // RCTRL
    try testing.expectEqual(@as(u8, 0x80), keycodeToModBit(0xE7)); // RGUI
    try testing.expectEqual(@as(u8, 0x00), keycodeToModBit(0x04)); // KC_A (not a mod)
}
