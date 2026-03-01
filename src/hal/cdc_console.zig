// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! USB CDC ACM デバッグコンソール
//!
//! USB CDC 仮想シリアルポート経由でデバッグログを出力する。
//! macOS では /dev/tty.usbmodemXXXX として認識される。

const std = @import("std");
const builtin = @import("builtin");
const usb_mod = @import("usb.zig");

const is_freestanding = builtin.os.tag == .freestanding;

/// Global USB driver reference (set by init())
var usb_driver: ?*usb_mod.UsbDriver = null;

/// Initialize CDC console with USB driver reference
pub fn init(drv: *usb_mod.UsbDriver) void {
    usb_driver = drv;
}

/// Write raw data to CDC
pub fn write(data: []const u8) void {
    if (usb_driver) |drv| {
        if (drv.isConfigured()) {
            drv.cdcWrite(data);
        }
    }
}

/// Formatted print to CDC
pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (usb_driver) |drv| {
        if (drv.isConfigured()) {
            drv.cdcPrint(fmt, args);
        }
    }
}

// ============================================================
// Tests
// ============================================================

test "init sets driver reference" {
    var drv = usb_mod.UsbDriver{};
    drv.init();

    init(&drv);
    try std.testing.expect(usb_driver != null);

    // Cleanup
    usb_driver = null;
}

test "write does not crash without driver" {
    usb_driver = null;
    write("hello");
}

test "write does not crash with unconfigured driver" {
    var drv = usb_mod.UsbDriver{};
    drv.init();
    init(&drv);

    write("hello");

    usb_driver = null;
}

test "print does not crash without driver" {
    usb_driver = null;
    print("test {d}\n", .{42});
}
