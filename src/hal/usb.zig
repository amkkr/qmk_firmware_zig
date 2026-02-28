// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! RP2040 USB Device Driver
//! Based on tmk_core/protocol/chibios/usb_main.c
//!
//! Direct RP2040 USB peripheral control without ChibiOS/LUFA dependency.
//! On native (test) builds, provides a mock implementation.

const std = @import("std");
const builtin = @import("builtin");
const usb_descriptors = @import("usb_descriptors.zig");
const report = @import("../core/report.zig");
const host = @import("../core/host.zig");
const KeyboardReport = report.KeyboardReport;
const MouseReport = report.MouseReport;
const ExtraReport = report.ExtraReport;

const is_freestanding = builtin.os.tag == .freestanding;

// ============================================================
// RP2040 USB Register Definitions
// ============================================================

pub const USBCTRL_REGS_BASE: u32 = 0x50110000;
pub const USBCTRL_DPRAM_BASE: u32 = 0x50100000;

/// USB register offsets
pub const Reg = struct {
    pub const ADDR_ENDP: u32 = 0x00;
    pub const MAIN_CTRL: u32 = 0x40;
    pub const SIE_CTRL: u32 = 0x4C;
    pub const SIE_STATUS: u32 = 0x50;
    pub const BUFF_STATUS: u32 = 0x58;
    pub const BUFF_CPU_SHOULD_HANDLE: u32 = 0x5C;
    pub const EP_ABORT: u32 = 0x60;
    pub const EP_ABORT_DONE: u32 = 0x64;
    pub const EP_STALL_ARM: u32 = 0x68;
    pub const USB_MUXING: u32 = 0x74;
    pub const USB_PWR: u32 = 0x78;
    pub const INTE: u32 = 0x90;
    pub const INTF: u32 = 0x94;
    pub const INTS: u32 = 0x98;
};

/// USB interrupt bits
pub const IntBit = struct {
    pub const BUFF_STATUS: u32 = 1 << 4;
    pub const BUS_RESET: u32 = 1 << 12;
    pub const SETUP_REQ: u32 = 1 << 16;
};

/// DPRAM endpoint buffer control offsets
pub const DPRAM = struct {
    pub const SETUP_PACKET: u32 = 0x00;
    pub const EP_IN_CTRL_BASE: u32 = 0x08;
    pub const EP_OUT_CTRL_BASE: u32 = 0x0C;
    pub const EP_BUF_CTRL_BASE: u32 = 0x80;
    pub const EP_BUF_BASE: u32 = 0x180;
};

/// Buffer control bits
pub const BufCtrl = struct {
    pub const FULL: u32 = 1 << 15;
    pub const LAST: u32 = 1 << 14;
    pub const DATA_PID: u32 = 1 << 13;
    pub const AVAILABLE: u32 = 1 << 10;
    pub const LEN_MASK: u32 = 0x3FF;
};

// ============================================================
// USB Device State
// ============================================================

pub const DeviceState = enum {
    disconnected,
    attached,
    powered,
    default_state,
    addressed,
    configured,
    suspended,
};

/// USB setup packet (8 bytes)
pub const SetupPacket = extern struct {
    bmRequestType: u8 = 0,
    bRequest: u8 = 0,
    wValue: u16 align(1) = 0,
    wIndex: u16 align(1) = 0,
    wLength: u16 align(1) = 0,

    comptime {
        if (@sizeOf(SetupPacket) != 8) {
            @compileError("SetupPacket must be 8 bytes");
        }
    }
};

/// Standard USB request codes
pub const Request = struct {
    pub const GET_STATUS: u8 = 0;
    pub const CLEAR_FEATURE: u8 = 1;
    pub const SET_FEATURE: u8 = 3;
    pub const SET_ADDRESS: u8 = 5;
    pub const GET_DESCRIPTOR: u8 = 6;
    pub const SET_DESCRIPTOR: u8 = 7;
    pub const GET_CONFIGURATION: u8 = 8;
    pub const SET_CONFIGURATION: u8 = 9;
    pub const GET_INTERFACE: u8 = 10;
    pub const SET_INTERFACE: u8 = 11;
};

/// HID class request codes
pub const HidRequest = struct {
    pub const GET_REPORT: u8 = 0x01;
    pub const GET_IDLE: u8 = 0x02;
    pub const GET_PROTOCOL: u8 = 0x03;
    pub const SET_REPORT: u8 = 0x09;
    pub const SET_IDLE: u8 = 0x0A;
    pub const SET_PROTOCOL: u8 = 0x0B;
};

/// HID protocol modes
pub const HidProtocol = enum(u8) {
    boot = 0,
    report = 1,
};

// ============================================================
// USB Driver
// ============================================================

pub const UsbDriver = struct {
    state: DeviceState = .disconnected,
    address: u8 = 0,
    configuration: u8 = 0,
    keyboard_protocol: HidProtocol = .report,
    mouse_protocol: HidProtocol = .report,
    keyboard_idle: u8 = 0,
    keyboard_leds: u8 = 0,
    /// Data toggle tracking per endpoint (IN)
    data_toggle: [4]bool = .{ false, false, false, false },
    /// Mock EP0 OUT data (for testing SET_REPORT etc.)
    mock_ep0_out_data: u8 = 0,

    /// Initialize USB peripheral
    pub fn init(self: *UsbDriver) void {
        self.state = .disconnected;
        self.address = 0;
        self.configuration = 0;
        self.keyboard_protocol = .report;
        self.mouse_protocol = .report;
        self.keyboard_idle = 0;
        self.keyboard_leds = 0;
        self.data_toggle = .{ false, false, false, false };
        self.mock_ep0_out_data = 0;

        if (is_freestanding) {
            self.hwInit();
        }
    }

    /// Check if device is configured and ready to send reports
    pub fn isConfigured(self: *const UsbDriver) bool {
        return self.state == .configured;
    }

    /// Get keyboard LED state (set by host via SET_REPORT)
    pub fn getLeds(self: *const UsbDriver) u8 {
        return self.keyboard_leds;
    }

    /// Get keyboard LED state (HostDriver.from() compatible name)
    pub fn keyboardLeds(self: *const UsbDriver) u8 {
        return self.keyboard_leds;
    }

    /// Send a keyboard report
    pub fn sendKeyboard(self: *UsbDriver, r: KeyboardReport) void {
        if (!self.isConfigured()) return;
        self.sendEndpoint(
            usb_descriptors.KEYBOARD_ENDPOINT,
            std.mem.asBytes(&r),
        );
    }

    /// Send a mouse report
    pub fn sendMouse(self: *UsbDriver, r: MouseReport) void {
        if (!self.isConfigured()) return;
        self.sendEndpoint(
            usb_descriptors.MOUSE_ENDPOINT,
            std.mem.asBytes(&r),
        );
    }

    /// Send an extra report
    pub fn sendExtra(self: *UsbDriver, r: ExtraReport) void {
        if (!self.isConfigured()) return;
        self.sendEndpoint(
            usb_descriptors.EXTRA_ENDPOINT,
            std.mem.asBytes(&r),
        );
    }

    /// Process a setup packet (called from interrupt handler or poll)
    pub fn handleSetup(self: *UsbDriver, setup: *const SetupPacket) void {
        const req_type = setup.bmRequestType & 0x60; // Type field
        switch (req_type) {
            0x00 => self.handleStandardRequest(setup),
            0x20 => self.handleClassRequest(setup),
            else => self.stallEndpoint0(),
        }
    }

    fn handleStandardRequest(self: *UsbDriver, setup: *const SetupPacket) void {
        switch (setup.bRequest) {
            Request.SET_ADDRESS => {
                self.address = @truncate(setup.wValue);
                self.state = .addressed;
                if (is_freestanding) {
                    self.hwSetAddress(self.address);
                }
            },
            Request.SET_CONFIGURATION => {
                self.configuration = @truncate(setup.wValue);
                if (self.configuration > 0) {
                    self.state = .configured;
                } else {
                    self.state = .addressed;
                }
            },
            Request.GET_CONFIGURATION => {
                // Would send self.configuration back
            },
            Request.GET_DESCRIPTOR => {
                // Descriptor type is in high byte of wValue
                const desc_type: u8 = @truncate(setup.wValue >> 8);
                const desc_index: u8 = @truncate(setup.wValue);
                self.handleGetDescriptor(desc_type, desc_index, setup.wLength);
            },
            else => self.stallEndpoint0(),
        }
    }

    fn handleClassRequest(self: *UsbDriver, setup: *const SetupPacket) void {
        switch (setup.bRequest) {
            HidRequest.SET_IDLE => {
                self.keyboard_idle = @truncate(setup.wValue >> 8);
            },
            HidRequest.SET_PROTOCOL => {
                const iface: u8 = @truncate(setup.wIndex);
                const protocol: u8 = @truncate(setup.wValue);
                if (iface == usb_descriptors.KEYBOARD_INTERFACE) {
                    self.keyboard_protocol = @enumFromInt(protocol & 1);
                } else if (iface == usb_descriptors.MOUSE_INTERFACE) {
                    self.mouse_protocol = @enumFromInt(protocol & 1);
                }
            },
            HidRequest.SET_REPORT => {
                // LED report from host (1 byte, bits: NumLock, CapsLock, ScrollLock, Compose, Kana)
                // The LED data is sent in the data phase of the control transfer (EP0 OUT buffer),
                // not in wValue. wValue contains (ReportType << 8 | ReportID).
                if (is_freestanding) {
                    // Read LED byte from EP0 OUT data buffer
                    const ep0_buf = @as(*volatile u8, @ptrFromInt(USBCTRL_DPRAM_BASE + DPRAM.EP_BUF_BASE));
                    self.keyboard_leds = ep0_buf.*;
                } else {
                    // Mock: use ep0_out_data if set, otherwise no-op
                    self.keyboard_leds = self.mock_ep0_out_data;
                }
            },
            HidRequest.GET_PROTOCOL => {
                // Would send protocol value back
            },
            else => self.stallEndpoint0(),
        }
    }

    fn handleGetDescriptor(self: *UsbDriver, desc_type: u8, desc_index: u8, max_len: u16) void {
        _ = max_len;
        _ = self;
        _ = desc_type;
        _ = desc_index;
        // In real implementation, this would copy the descriptor to EP0 IN buffer
        // and start the transfer. The actual descriptor data is in usb_descriptors.zig.
        // For the mock/test version, this is a no-op.
    }

    fn stallEndpoint0(self: *UsbDriver) void {
        if (is_freestanding) {
            const ep_stall_arm = @as(*volatile u32, @ptrFromInt(USBCTRL_REGS_BASE + Reg.EP_STALL_ARM));
            ep_stall_arm.* = 0x03; // Stall EP0 IN and OUT
        }
        _ = self;
    }

    fn sendEndpoint(self: *UsbDriver, ep: u8, data: []const u8) void {
        if (is_freestanding) {
            self.hwSendEndpoint(ep, data);
        } else {
            // Mock: track data toggle
            self.data_toggle[ep] = !self.data_toggle[ep];
        }
    }

    // ============================================================
    // Hardware-specific (RP2040) - only compiled for freestanding
    // ============================================================

    fn hwInit(self: *UsbDriver) void {
        _ = self;
        // Release USB peripheral from reset via RESETS register
        const RESETS_USBCTRL_BIT: u32 = 1 << 24;
        const resets_clr = @as(*volatile u32, @ptrFromInt(0x4000_F000)); // RESETS atomic clear alias
        resets_clr.* = RESETS_USBCTRL_BIT;

        // Wait for reset release to complete
        const reset_done = @as(*volatile u32, @ptrFromInt(0x4000_C008)); // RESET_DONE
        while (reset_done.* & RESETS_USBCTRL_BIT == 0) {}

        // Clear DPRAM
        const dpram = @as([*]volatile u32, @ptrFromInt(USBCTRL_DPRAM_BASE));
        for (0..1024) |i| {
            dpram[i] = 0;
        }

        // Enable USB controller
        const main_ctrl = @as(*volatile u32, @ptrFromInt(USBCTRL_REGS_BASE + Reg.MAIN_CTRL));
        main_ctrl.* = 1; // CONTROLLER_EN

        // Configure muxing
        const usb_muxing = @as(*volatile u32, @ptrFromInt(USBCTRL_REGS_BASE + Reg.USB_MUXING));
        usb_muxing.* = (1 << 3) | (1 << 0); // SOFTCON | TO_PHY

        // Configure power
        const usb_pwr = @as(*volatile u32, @ptrFromInt(USBCTRL_REGS_BASE + Reg.USB_PWR));
        usb_pwr.* = (1 << 3) | (1 << 2); // VBUS_DETECT_OVERRIDE | VBUS_DETECT

        // Enable interrupts
        const inte = @as(*volatile u32, @ptrFromInt(USBCTRL_REGS_BASE + Reg.INTE));
        inte.* = IntBit.BUFF_STATUS | IntBit.BUS_RESET | IntBit.SETUP_REQ;

        // Enable pull-up to signal device connection
        const sie_ctrl = @as(*volatile u32, @ptrFromInt(USBCTRL_REGS_BASE + Reg.SIE_CTRL));
        sie_ctrl.* = 1 << 16; // PULLUP_EN
    }

    fn hwSetAddress(self: *UsbDriver, addr: u8) void {
        _ = self;
        const addr_endp = @as(*volatile u32, @ptrFromInt(USBCTRL_REGS_BASE + Reg.ADDR_ENDP));
        addr_endp.* = addr;
    }

    fn hwSendEndpoint(self: *UsbDriver, ep: u8, data: []const u8) void {
        const buf_ctrl_addr = USBCTRL_DPRAM_BASE + DPRAM.EP_BUF_CTRL_BASE + @as(u32, ep) * 8;
        const buf_ctrl = @as(*volatile u32, @ptrFromInt(buf_ctrl_addr));

        // Wait for previous packet to be consumed by host before overwriting
        while (buf_ctrl.* & BufCtrl.AVAILABLE != 0) {}

        // Calculate buffer address in DPRAM
        const buf_addr = USBCTRL_DPRAM_BASE + DPRAM.EP_BUF_BASE + @as(u32, ep) * 64;
        const buf = @as([*]volatile u8, @ptrFromInt(buf_addr));

        // Clamp data length to endpoint buffer size (64 bytes max)
        const len = @min(data.len, 64);

        // Copy data to buffer
        for (data[0..len], 0..) |byte, i| {
            buf[i] = byte;
        }

        // Set buffer control
        var ctrl: u32 = @as(u32, @intCast(len)) & BufCtrl.LEN_MASK;
        ctrl |= BufCtrl.FULL | BufCtrl.LAST | BufCtrl.AVAILABLE;
        if (self.data_toggle[ep]) {
            ctrl |= BufCtrl.DATA_PID;
        }
        self.data_toggle[ep] = !self.data_toggle[ep];

        buf_ctrl.* = ctrl;
    }

    /// Create a HostDriver interface from this USB driver
    pub fn hostDriver(self: *UsbDriver) host.HostDriver {
        return host.HostDriver.from(self);
    }
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "UsbDriver init state" {
    var drv = UsbDriver{};
    drv.init();

    try testing.expectEqual(DeviceState.disconnected, drv.state);
    try testing.expectEqual(@as(u8, 0), drv.address);
    try testing.expectEqual(@as(u8, 0), drv.configuration);
    try testing.expect(!drv.isConfigured());
}

test "UsbDriver SET_ADDRESS" {
    var drv = UsbDriver{};
    drv.init();

    const setup = SetupPacket{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_ADDRESS,
        .wValue = 7,
        .wIndex = 0,
        .wLength = 0,
    };
    drv.handleSetup(&setup);

    try testing.expectEqual(@as(u8, 7), drv.address);
    try testing.expectEqual(DeviceState.addressed, drv.state);
}

test "UsbDriver SET_CONFIGURATION" {
    var drv = UsbDriver{};
    drv.init();

    // Set address first
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_ADDRESS,
        .wValue = 1,
    });

    // Set configuration
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_CONFIGURATION,
        .wValue = 1,
    });

    try testing.expectEqual(DeviceState.configured, drv.state);
    try testing.expect(drv.isConfigured());

    // Deconfigure
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_CONFIGURATION,
        .wValue = 0,
    });

    try testing.expectEqual(DeviceState.addressed, drv.state);
    try testing.expect(!drv.isConfigured());
}

test "UsbDriver SET_IDLE" {
    var drv = UsbDriver{};
    drv.init();

    drv.handleSetup(&.{
        .bmRequestType = 0x21, // Class request, Interface
        .bRequest = HidRequest.SET_IDLE,
        .wValue = 0x0400, // idle rate 4, report ID 0
    });

    try testing.expectEqual(@as(u8, 4), drv.keyboard_idle);
}

test "UsbDriver SET_PROTOCOL" {
    var drv = UsbDriver{};
    drv.init();

    // Set keyboard to boot protocol
    drv.handleSetup(&.{
        .bmRequestType = 0x21,
        .bRequest = HidRequest.SET_PROTOCOL,
        .wValue = 0, // Boot protocol
        .wIndex = usb_descriptors.KEYBOARD_INTERFACE,
    });

    try testing.expectEqual(HidProtocol.boot, drv.keyboard_protocol);

    // Set back to report protocol
    drv.handleSetup(&.{
        .bmRequestType = 0x21,
        .bRequest = HidRequest.SET_PROTOCOL,
        .wValue = 1, // Report protocol
        .wIndex = usb_descriptors.KEYBOARD_INTERFACE,
    });

    try testing.expectEqual(HidProtocol.report, drv.keyboard_protocol);
}

test "UsbDriver SET_REPORT (LEDs)" {
    var drv = UsbDriver{};
    drv.init();

    // Simulate LED data in EP0 OUT data buffer (mock)
    drv.mock_ep0_out_data = 0x02; // CapsLock
    drv.handleSetup(&.{
        .bmRequestType = 0x21,
        .bRequest = HidRequest.SET_REPORT,
        .wValue = 0x0200, // ReportType=Output(0x02), ReportID=0
        .wIndex = usb_descriptors.KEYBOARD_INTERFACE,
    });

    try testing.expectEqual(@as(u8, 0x02), drv.keyboard_leds);
    try testing.expectEqual(@as(u8, 0x02), drv.getLeds());
}

test "UsbDriver send does nothing when not configured" {
    var drv = UsbDriver{};
    drv.init();

    // Should not crash when sending without configuration
    const r = KeyboardReport{};
    drv.sendKeyboard(r);
    drv.sendMouse(MouseReport{});
    drv.sendExtra(ExtraReport{});
}

test "UsbDriver hostDriver interface" {
    var drv = UsbDriver{};
    drv.init();
    drv.keyboard_leds = 0x05;

    const hd = drv.hostDriver();
    try testing.expectEqual(@as(u8, 0x05), hd.keyboardLeds());
}

test "SetupPacket size" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(SetupPacket));
}
