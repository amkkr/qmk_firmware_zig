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

pub const RESETS_BASE: u32 = 0x4000_C000;
pub const RESETS_CLR: u32 = RESETS_BASE + 0x3000; // Atomic clear alias
pub const RESET_DONE: u32 = RESETS_BASE + 0x08;
pub const RESETS_USBCTRL_BIT: u32 = 1 << 24;

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

/// USB interrupt bits (INTE/INTS registers)
pub const IntBit = struct {
    pub const BUFF_STATUS: u32 = 1 << 4;
    pub const BUS_RESET: u32 = 1 << 12;
    pub const SETUP_REQ: u32 = 1 << 16;
};

/// SIE_STATUS register bits
pub const SieStatus = struct {
    pub const SETUP_REC: u32 = 1 << 17;
    pub const BUS_RESET: u32 = 1 << 19;
};

/// DPRAM endpoint buffer control offsets
pub const DPRAM = struct {
    pub const SETUP_PACKET: u32 = 0x00;
    pub const EP_IN_CTRL_BASE: u32 = 0x08;
    pub const EP_OUT_CTRL_BASE: u32 = 0x0C;
    pub const EP_BUF_CTRL_BASE: u32 = 0x80;
    pub const EP0_BUF: u32 = 0x100; // ep0_buf_a: EP0 data stage buffer (IN/OUT shared)
    pub const EP0_OUT_BUF: u32 = 0x140;
    pub const EP_BUF_BASE: u32 = 0x180;
    // EP1: 0x180, EP2: 0x1C0, EP3: 0x200 (existing HID endpoints)
    pub const EP4_BUF: u32 = 0x240; // CDC notification IN
    pub const EP5_IN_BUF: u32 = 0x280; // CDC data IN
    pub const EP5_OUT_BUF: u32 = 0x2C0; // CDC data OUT
};

/// Buffer control bits
pub const BufCtrl = struct {
    pub const FULL: u32 = 1 << 15;
    pub const LAST: u32 = 1 << 14;
    pub const DATA_PID: u32 = 1 << 13;
    pub const AVAILABLE: u32 = 1 << 10;
    pub const LEN_MASK: u32 = 0x3FF;

    /// EP0 OUT buffer control register address (DPRAM offset 0x84)
    pub const EP0_OUT_ADDR: u32 = USBCTRL_DPRAM_BASE + DPRAM.EP_BUF_CTRL_BASE + 4;
};

/// Endpoint control register bits (DPRAM EP_IN_CTRL / EP_OUT_CTRL)
pub const EpCtrl = struct {
    pub const ENABLE: u32 = 1 << 31;
    pub const INTERRUPT_PER_BUFF: u32 = 1 << 29;
    pub const ENDPOINT_TYPE_SHIFT: u5 = 26;
    pub const EP_TYPE_BULK: u32 = 2 << ENDPOINT_TYPE_SHIFT;
    pub const EP_TYPE_INTERRUPT: u32 = 3 << ENDPOINT_TYPE_SHIFT;
    pub const BUFFER_ADDRESS_MASK: u32 = 0xFFFF;
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
    /// Data toggle tracking per endpoint (IN): EP0-EP5
    data_toggle: [6]bool = .{ false, false, false, false, false, false },
    /// EP0 IN multi-packet transfer state
    ep0_in_data: ?[]const u8 = null,
    ep0_in_offset: u16 = 0,
    ep0_in_total_len: u16 = 0,
    /// Pending address to apply after status stage ZLP completion (USB 2.0 spec)
    pending_address: ?u8 = null,
    /// Mock EP0 OUT data (for testing SET_REPORT etc.)
    mock_ep0_out_data: u8 = 0,
    /// Mock INTS register value (for testing task() polling)
    mock_ints: u32 = 0,
    /// Mock setup packet (for testing task() SETUP_REQ dispatch)
    mock_setup_packet: ?SetupPacket = null,
    /// Mock BUFF_STATUS value (for testing handleBuffStatus)
    mock_buff_status: u32 = 0,
    /// CDC Line Coding (default: 115200/8N1)
    cdc_line_coding: usb_descriptors.LineCoding = .{},
    /// CDC DTR/RTS control line state
    cdc_control_line_state: u16 = 0,
    /// CDC TX ring buffer
    cdc_tx_buf: [256]u8 = undefined,
    cdc_tx_head: u8 = 0,
    cdc_tx_tail: u8 = 0,
    /// Small reply buffer for EP0 IN responses (up to 7 bytes for LineCoding)
    ep0_reply_buf: [7]u8 = .{ 0, 0, 0, 0, 0, 0, 0 },

    /// Initialize USB peripheral
    pub fn init(self: *UsbDriver) void {
        self.state = .disconnected;
        self.address = 0;
        self.configuration = 0;
        self.keyboard_protocol = .report;
        self.mouse_protocol = .report;
        self.keyboard_idle = 0;
        self.keyboard_leds = 0;
        self.data_toggle = .{ false, false, false, false, false, false };
        self.ep0_in_data = null;
        self.ep0_in_offset = 0;
        self.ep0_in_total_len = 0;
        self.pending_address = null;
        self.cdc_line_coding = .{};
        self.cdc_control_line_state = 0;
        self.cdc_tx_head = 0;
        self.cdc_tx_tail = 0;
        self.ep0_reply_buf = .{ 0, 0, 0, 0, 0, 0, 0 };
        self.mock_ep0_out_data = 0;
        self.mock_ints = 0;
        self.mock_setup_packet = null;
        self.mock_buff_status = 0;

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

    /// Poll USB peripheral for pending events and dispatch handlers.
    /// Called from the main loop on each iteration.
    pub fn task(self: *UsbDriver) void {
        const ints = if (is_freestanding) blk: {
            const ints_reg = @as(*volatile u32, @ptrFromInt(USBCTRL_REGS_BASE + Reg.INTS));
            break :blk ints_reg.*;
        } else self.mock_ints;

        if ((ints & IntBit.BUS_RESET) != 0) {
            self.handleBusReset();
        }
        if ((ints & IntBit.SETUP_REQ) != 0) {
            self.handleSetupFromHw();
        }
        if ((ints & IntBit.BUFF_STATUS) != 0) {
            self.handleBuffStatus();
        }

        // Flush CDC TX buffer if data is pending and device is configured
        if (self.isConfigured()) {
            self.cdcFlush();
        }
    }

    /// Handle USB bus reset event
    pub fn handleBusReset(self: *UsbDriver) void {
        if (is_freestanding) {
            // Clear BUS_RESET bit in SIE_STATUS (W1C, bit 19)
            const sie_status = @as(*volatile u32, @ptrFromInt(USBCTRL_REGS_BASE + Reg.SIE_STATUS));
            sie_status.* = SieStatus.BUS_RESET;

            // Reset device address to 0
            const addr_endp = @as(*volatile u32, @ptrFromInt(USBCTRL_REGS_BASE + Reg.ADDR_ENDP));
            addr_endp.* = 0;

            // Re-initialize EP0 OUT BUF CTRL to receive next SETUP packet
            self.hwPrepareEp0Out();
        }

        self.address = 0;
        self.configuration = 0;
        self.state = .default_state;
        self.data_toggle = .{ false, false, false, false, false, false };
        self.pending_address = null;
        self.cdc_tx_head = 0;
        self.cdc_tx_tail = 0;
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
                const addr: u8 = @truncate(setup.wValue);
                self.address = addr;
                self.state = .addressed;
                // Defer hardware address application until after status stage ZLP
                // (USB 2.0 spec: address takes effect after status stage completion)
                self.pending_address = addr;
                self.sendStatusStageZlp();
            },
            Request.SET_CONFIGURATION => {
                self.configuration = @truncate(setup.wValue);
                // Reset data toggle for EP1-EP5 to DATA0 (USB 2.0 spec §9.4.7:
                // data toggle bits for all endpoints shall be reset on SET_CONFIGURATION)
                self.data_toggle[1] = false;
                self.data_toggle[2] = false;
                self.data_toggle[3] = false;
                self.data_toggle[4] = false;
                self.data_toggle[5] = false;
                if (self.configuration > 0) {
                    self.state = .configured;
                    if (is_freestanding) {
                        self.hwConfigureEndpoints();
                    }
                } else {
                    self.state = .addressed;
                }
                self.sendStatusStageZlp();
            },
            Request.GET_CONFIGURATION => {
                self.ep0_reply_buf[0] = self.configuration;
                self.ep0_in_data = &self.ep0_reply_buf;
                self.ep0_in_offset = 0;
                self.ep0_in_total_len = @min(1, setup.wLength);
                self.sendEp0InPacket();
            },
            Request.GET_DESCRIPTOR => {
                // Descriptor type is in high byte of wValue
                const desc_type: u8 = @truncate(setup.wValue >> 8);
                const desc_index: u8 = @truncate(setup.wValue);
                self.handleGetDescriptor(desc_type, desc_index, setup.wIndex, setup.wLength);
            },
            else => self.stallEndpoint0(),
        }
    }

    fn handleClassRequest(self: *UsbDriver, setup: *const SetupPacket) void {
        const iface: u8 = @truncate(setup.wIndex);
        // Route CDC class requests to the CDC handler
        if (iface == usb_descriptors.CDC_COMM_INTERFACE or iface == usb_descriptors.CDC_DATA_INTERFACE) {
            self.handleCdcClassRequest(setup);
            return;
        }
        switch (setup.bRequest) {
            HidRequest.SET_IDLE => {
                self.keyboard_idle = @truncate(setup.wValue >> 8);
                self.sendStatusStageZlp();
            },
            HidRequest.SET_PROTOCOL => {
                const protocol: u8 = @truncate(setup.wValue);
                if (iface == usb_descriptors.KEYBOARD_INTERFACE) {
                    self.keyboard_protocol = @enumFromInt(protocol & 1);
                } else if (iface == usb_descriptors.MOUSE_INTERFACE) {
                    self.mouse_protocol = @enumFromInt(protocol & 1);
                }
                self.sendStatusStageZlp();
            },
            HidRequest.SET_REPORT => {
                // LED report from host (1 byte, bits: NumLock, CapsLock, ScrollLock, Compose, Kana)
                // The LED data is sent in the data phase of the control transfer (EP0 OUT buffer),
                // not in wValue. wValue contains (ReportType << 8 | ReportID).
                if (is_freestanding) {
                    // Read LED byte from EP0 OUT data buffer
                    const ep0_buf = @as(*volatile u8, @ptrFromInt(USBCTRL_DPRAM_BASE + DPRAM.EP0_BUF));
                    self.keyboard_leds = ep0_buf.*;
                } else {
                    // Mock: use ep0_out_data if set, otherwise no-op
                    self.keyboard_leds = self.mock_ep0_out_data;
                }
                self.sendStatusStageZlp();
            },
            HidRequest.GET_PROTOCOL => {
                if (iface == usb_descriptors.KEYBOARD_INTERFACE) {
                    self.ep0_reply_buf[0] = @intFromEnum(self.keyboard_protocol);
                } else if (iface == usb_descriptors.MOUSE_INTERFACE) {
                    self.ep0_reply_buf[0] = @intFromEnum(self.mouse_protocol);
                } else {
                    self.stallEndpoint0();
                    return;
                }
                self.ep0_in_data = &self.ep0_reply_buf;
                self.ep0_in_offset = 0;
                self.ep0_in_total_len = @min(1, setup.wLength);
                self.sendEp0InPacket();
            },
            else => self.stallEndpoint0(),
        }
    }

    /// Handle CDC ACM class-specific requests
    fn handleCdcClassRequest(self: *UsbDriver, setup: *const SetupPacket) void {
        switch (setup.bRequest) {
            usb_descriptors.CdcRequest.SET_LINE_CODING => {
                // Host sends 7-byte LineCoding struct in data phase (EP0 OUT)
                if (is_freestanding) {
                    const ep0_buf = @as([*]volatile u8, @ptrFromInt(USBCTRL_DPRAM_BASE + DPRAM.EP0_BUF));
                    var buf: [7]u8 = undefined;
                    for (0..7) |i| {
                        buf[i] = ep0_buf[i];
                    }
                    self.cdc_line_coding = @bitCast(buf);
                } else {
                    // Mock: use ep0_reply_buf as mock data source
                    self.cdc_line_coding = @bitCast(self.ep0_reply_buf);
                }
                self.sendStatusStageZlp();
            },
            usb_descriptors.CdcRequest.GET_LINE_CODING => {
                // Send current LineCoding struct (7 bytes) to host
                self.ep0_reply_buf = @bitCast(self.cdc_line_coding);
                self.ep0_in_data = &self.ep0_reply_buf;
                self.ep0_in_offset = 0;
                self.ep0_in_total_len = @min(7, setup.wLength);
                self.sendEp0InPacket();
            },
            usb_descriptors.CdcRequest.SET_CONTROL_LINE_STATE => {
                // wValue contains DTR (bit 0) and RTS (bit 1)
                self.cdc_control_line_state = setup.wValue;
                self.sendStatusStageZlp();
            },
            else => self.stallEndpoint0(),
        }
    }

    // ============================================================
    // CDC TX Ring Buffer
    // ============================================================

    /// Write data to the CDC TX ring buffer
    pub fn cdcWrite(self: *UsbDriver, data: []const u8) void {
        for (data) |byte| {
            const next_head = self.cdc_tx_head +% 1;
            if (next_head == self.cdc_tx_tail) {
                // Buffer full, drop data
                return;
            }
            self.cdc_tx_buf[self.cdc_tx_head] = byte;
            self.cdc_tx_head = next_head;
        }
    }

    /// Formatted print to CDC TX buffer
    pub fn cdcPrint(self: *UsbDriver, comptime fmt: []const u8, args: anytype) void {
        const CdcWriter = struct {
            drv: *UsbDriver,

            pub fn write(ctx: @This(), data: []const u8) error{}!usize {
                ctx.drv.cdcWrite(data);
                return data.len;
            }
        };
        const writer = std.io.GenericWriter(CdcWriter, error{}, CdcWriter.write){ .context = .{ .drv = self } };
        std.fmt.format(writer, fmt, args) catch {};
    }

    /// Flush CDC TX ring buffer to EP5 IN
    pub fn cdcFlush(self: *UsbDriver) void {
        if (self.cdc_tx_head == self.cdc_tx_tail) return;

        // Calculate how much data is in the ring buffer
        const available: u16 = @as(u16, self.cdc_tx_head -% self.cdc_tx_tail);
        if (available == 0) return;

        const max_packet: u16 = usb_descriptors.CDC_DATA_ENDPOINT_SIZE;
        const send_len: u16 = @min(available, max_packet);

        // Collect data from ring buffer into a contiguous array
        var packet: [64]u8 = undefined;
        for (0..send_len) |i| {
            packet[i] = self.cdc_tx_buf[self.cdc_tx_tail +% @as(u8, @intCast(i))];
        }

        if (is_freestanding) {
            self.hwSendCdcData(packet[0..send_len]);
        } else {
            // Mock: just advance data_toggle
            self.data_toggle[usb_descriptors.CDC_DATA_ENDPOINT] =
                !self.data_toggle[usb_descriptors.CDC_DATA_ENDPOINT];
        }

        self.cdc_tx_tail +%= @intCast(send_len);
    }

    /// Check if DTR is asserted (host has opened the serial port)
    pub fn cdcDtrActive(self: *const UsbDriver) bool {
        return (self.cdc_control_line_state & 0x01) != 0;
    }

    const EP0_MAX_PACKET_SIZE: u16 = 64;

    /// GET_DESCRIPTOR 応答: ディスクリプタを選択し EP0 IN で送信開始。
    /// 64バイト超のディスクリプタはマルチパケットに分割される。
    fn handleGetDescriptor(self: *UsbDriver, desc_type: u8, desc_index: u8, w_index: u16, max_len: u16) void {
        const desc: ?[]const u8 = switch (desc_type) {
            usb_descriptors.DescriptorType.DEVICE => &usb_descriptors.device_descriptor,
            usb_descriptors.DescriptorType.CONFIGURATION => &usb_descriptors.configuration_descriptor,
            usb_descriptors.DescriptorType.STRING => switch (desc_index) {
                0 => &usb_descriptors.string_descriptor_0,
                1 => &usb_descriptors.string_descriptor_manufacturer,
                2 => &usb_descriptors.string_descriptor_product,
                3 => &usb_descriptors.string_descriptor_serial,
                else => null,
            },
            usb_descriptors.DescriptorType.HID_REPORT => blk: {
                const iface: u8 = @truncate(w_index);
                break :blk switch (iface) {
                    usb_descriptors.KEYBOARD_INTERFACE => &usb_descriptors.keyboard_report_descriptor,
                    usb_descriptors.MOUSE_INTERFACE => &usb_descriptors.mouse_report_descriptor,
                    usb_descriptors.EXTRA_INTERFACE => &usb_descriptors.extra_report_descriptor,
                    else => null,
                };
            },
            else => null,
        };

        if (desc) |data| {
            const send_len = @min(@as(u16, @intCast(data.len)), max_len);
            self.ep0_in_data = data;
            self.ep0_in_offset = 0;
            self.ep0_in_total_len = send_len;
            self.sendEp0InPacket();
        } else {
            self.stallEndpoint0();
        }
    }

    /// EP0 IN パケット送信（最大 64 バイト単位）。
    /// マルチパケット転送の場合、BUFF_STATUS で次パケットが要求される。
    fn sendEp0InPacket(self: *UsbDriver) void {
        const data = self.ep0_in_data orelse return;
        const offset = self.ep0_in_offset;
        const total = self.ep0_in_total_len;

        if (offset >= total) {
            self.ep0_in_data = null;
            return;
        }

        const remaining = total - offset;
        const chunk_len = @min(remaining, EP0_MAX_PACKET_SIZE);

        const is_last = (offset + chunk_len) >= total;

        if (is_freestanding) {
            const ep0_buf = @as([*]volatile u8, @ptrFromInt(USBCTRL_DPRAM_BASE + DPRAM.EP0_BUF));
            for (0..chunk_len) |i| {
                ep0_buf[i] = data[offset + i];
            }

            const buf_ctrl = @as(*volatile u32, @ptrFromInt(USBCTRL_DPRAM_BASE + DPRAM.EP_BUF_CTRL_BASE));
            var ctrl: u32 = chunk_len & BufCtrl.LEN_MASK;
            ctrl |= BufCtrl.FULL | BufCtrl.AVAILABLE;
            if (is_last) {
                ctrl |= BufCtrl.LAST;
            }
            if (self.data_toggle[0]) {
                ctrl |= BufCtrl.DATA_PID;
            }
            self.data_toggle[0] = !self.data_toggle[0];
            buf_ctrl.* = ctrl;
        } else {
            self.data_toggle[0] = !self.data_toggle[0];
        }

        self.ep0_in_offset += chunk_len;

        if (is_last) {
            self.ep0_in_data = null;
        }
    }

    /// Send a zero-length packet (ZLP) on EP0 IN for the status stage of a control transfer.
    /// USB 2.0 spec requires a status stage ZLP after processing host-to-device requests
    /// (SET_ADDRESS, SET_CONFIGURATION, SET_IDLE, SET_PROTOCOL, SET_REPORT).
    fn sendStatusStageZlp(self: *UsbDriver) void {
        if (is_freestanding) {
            const buf_ctrl = @as(*volatile u32, @ptrFromInt(USBCTRL_DPRAM_BASE + DPRAM.EP_BUF_CTRL_BASE));
            var ctrl: u32 = BufCtrl.FULL | BufCtrl.LAST | BufCtrl.AVAILABLE;
            if (self.data_toggle[0]) {
                ctrl |= BufCtrl.DATA_PID;
            }
            self.data_toggle[0] = !self.data_toggle[0];
            buf_ctrl.* = ctrl;
        } else {
            self.data_toggle[0] = !self.data_toggle[0];
        }
    }

    fn stallEndpoint0(self: *UsbDriver) void {
        if (is_freestanding) {
            const ep_stall_arm = @as(*volatile u32, @ptrFromInt(USBCTRL_REGS_BASE + Reg.EP_STALL_ARM));
            ep_stall_arm.* = 0x03; // Stall EP0 IN and OUT
        }
        _ = self;
    }

    /// Read setup packet from DPRAM and dispatch to handleSetup.
    /// On freestanding, clears SETUP_REC in SIE_STATUS (W1C).
    fn handleSetupFromHw(self: *UsbDriver) void {
        if (is_freestanding) {
            // Read setup packet from DPRAM first (volatile: USB controller writes asynchronously)
            // Per RP2040 TRM: read the 8-byte setup packet, then clear SETUP_REC
            const setup_ptr = @as(*align(1) volatile const SetupPacket, @ptrFromInt(USBCTRL_DPRAM_BASE + DPRAM.SETUP_PACKET));
            const pkt = setup_ptr.*;

            // Clear SETUP_REC bit in SIE_STATUS (W1C, bit 17) after reading
            const sie_status = @as(*volatile u32, @ptrFromInt(USBCTRL_REGS_BASE + Reg.SIE_STATUS));
            sie_status.* = SieStatus.SETUP_REC;

            self.handleSetup(&pkt);

            // Re-arm EP0 OUT to receive the next SETUP/OUT packet
            self.hwPrepareEp0Out();
        } else {
            if (self.mock_setup_packet) |*pkt| {
                self.handleSetup(pkt);
                self.mock_setup_packet = null;
            }
        }
    }

    /// BUFF_STATUS EP0 IN bit (bit 0)
    const BUFF_STATUS_EP0_IN: u32 = 1 << 0;

    /// Handle buffer status events (endpoint transfer completions).
    /// EP0 IN 完了時にマルチパケット転送の次パケットを送信する。
    /// SET_ADDRESS の場合は ZLP 完了後にアドレスをハードウェアに適用する。
    fn handleBuffStatus(self: *UsbDriver) void {
        const status = if (is_freestanding) blk: {
            // Read and clear BUFF_STATUS (W1C)
            const buff_status = @as(*volatile u32, @ptrFromInt(USBCTRL_REGS_BASE + Reg.BUFF_STATUS));
            const s = buff_status.*;
            buff_status.* = s;
            break :blk s;
        } else blk: {
            const s = self.mock_buff_status;
            self.mock_buff_status = 0;
            break :blk s;
        };

        if ((status & BUFF_STATUS_EP0_IN) != 0) {
            // Continue multi-packet EP0 IN transfer
            if (self.ep0_in_data != null) {
                self.sendEp0InPacket();
            }

            // Apply deferred SET_ADDRESS after status stage ZLP completion
            if (self.pending_address) |addr| {
                if (is_freestanding) {
                    self.hwSetAddress(addr);
                }
                self.pending_address = null;
            }
        }
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
        // Release USB peripheral from reset via RESETS register
        const resets_clr = @as(*volatile u32, @ptrFromInt(RESETS_CLR));
        resets_clr.* = RESETS_USBCTRL_BIT;

        // Wait for reset release to complete
        const reset_done = @as(*volatile u32, @ptrFromInt(RESET_DONE));
        while ((reset_done.* & RESETS_USBCTRL_BIT) == 0) {}

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

        // Initialize EP0 OUT buffer control to receive SETUP/OUT packets from host
        self.hwPrepareEp0Out();

        // Enable pull-up to signal device connection
        const sie_ctrl = @as(*volatile u32, @ptrFromInt(USBCTRL_REGS_BASE + Reg.SIE_CTRL));
        sie_ctrl.* = 1 << 16; // PULLUP_EN
    }

    /// Prepare EP0 OUT buffer control to receive the next OUT/SETUP packet from host.
    /// Sets AVAILABLE with max packet size (64 bytes) at DPRAM offset 0x84.
    fn hwPrepareEp0Out(self: *UsbDriver) void {
        _ = self;
        const ep0_out_buf_ctrl = @as(*volatile u32, @ptrFromInt(BufCtrl.EP0_OUT_ADDR));
        ep0_out_buf_ctrl.* = BufCtrl.AVAILABLE | (EP0_MAX_PACKET_SIZE & BufCtrl.LEN_MASK);
    }

    fn hwSetAddress(self: *UsbDriver, addr: u8) void {
        _ = self;
        const addr_endp = @as(*volatile u32, @ptrFromInt(USBCTRL_REGS_BASE + Reg.ADDR_ENDP));
        addr_endp.* = addr;
    }

    /// Configure EP1-EP5 endpoint control registers in DPRAM.
    /// Called on SET_CONFIGURATION when configuration > 0.
    /// Sets endpoint type, buffer address, and interrupt-per-buffer for each endpoint.
    fn hwConfigureEndpoints(self: *UsbDriver) void {
        _ = self;
        // EP1-EP3: HID Interrupt IN endpoints
        const hid_endpoints = [_]u8{
            usb_descriptors.KEYBOARD_ENDPOINT,
            usb_descriptors.MOUSE_ENDPOINT,
            usb_descriptors.EXTRA_ENDPOINT,
        };

        for (hid_endpoints) |ep| {
            const ctrl_addr = USBCTRL_DPRAM_BASE + DPRAM.EP_IN_CTRL_BASE + (@as(u32, ep) - 1) * 8;
            const ctrl_reg = @as(*volatile u32, @ptrFromInt(ctrl_addr));
            const buf_offset = DPRAM.EP_BUF_BASE + (@as(u32, ep) - 1) * 64;
            ctrl_reg.* = EpCtrl.ENABLE |
                EpCtrl.INTERRUPT_PER_BUFF |
                EpCtrl.EP_TYPE_INTERRUPT |
                (buf_offset & EpCtrl.BUFFER_ADDRESS_MASK);
        }

        // EP4: CDC Notification IN (Interrupt)
        {
            const ep4 = usb_descriptors.CDC_NOTIFICATION_ENDPOINT;
            const ctrl_addr = USBCTRL_DPRAM_BASE + DPRAM.EP_IN_CTRL_BASE + (@as(u32, ep4) - 1) * 8;
            const ctrl_reg = @as(*volatile u32, @ptrFromInt(ctrl_addr));
            ctrl_reg.* = EpCtrl.ENABLE |
                EpCtrl.INTERRUPT_PER_BUFF |
                EpCtrl.EP_TYPE_INTERRUPT |
                (DPRAM.EP4_BUF & EpCtrl.BUFFER_ADDRESS_MASK);
        }

        // EP5 IN: CDC Data IN (Bulk)
        {
            const ep5 = usb_descriptors.CDC_DATA_ENDPOINT;
            const ctrl_addr = USBCTRL_DPRAM_BASE + DPRAM.EP_IN_CTRL_BASE + (@as(u32, ep5) - 1) * 8;
            const ctrl_reg = @as(*volatile u32, @ptrFromInt(ctrl_addr));
            ctrl_reg.* = EpCtrl.ENABLE |
                EpCtrl.INTERRUPT_PER_BUFF |
                EpCtrl.EP_TYPE_BULK |
                (DPRAM.EP5_IN_BUF & EpCtrl.BUFFER_ADDRESS_MASK);
        }

        // EP5 OUT: CDC Data OUT (Bulk)
        {
            const ep5 = usb_descriptors.CDC_DATA_ENDPOINT;
            const ctrl_addr = USBCTRL_DPRAM_BASE + DPRAM.EP_OUT_CTRL_BASE + (@as(u32, ep5) - 1) * 8;
            const ctrl_reg = @as(*volatile u32, @ptrFromInt(ctrl_addr));
            ctrl_reg.* = EpCtrl.ENABLE |
                EpCtrl.INTERRUPT_PER_BUFF |
                EpCtrl.EP_TYPE_BULK |
                (DPRAM.EP5_OUT_BUF & EpCtrl.BUFFER_ADDRESS_MASK);
        }
    }

    fn hwSendEndpoint(self: *UsbDriver, ep: u8, data: []const u8) void {
        const buf_ctrl_addr = USBCTRL_DPRAM_BASE + DPRAM.EP_BUF_CTRL_BASE + @as(u32, ep) * 8;
        const buf_ctrl = @as(*volatile u32, @ptrFromInt(buf_ctrl_addr));

        // Wait for previous packet to be consumed by host before overwriting
        while (buf_ctrl.* & BufCtrl.AVAILABLE != 0) {}

        // Calculate buffer address in DPRAM (must match hwConfigureEndpoints)
        const buf_addr = USBCTRL_DPRAM_BASE + DPRAM.EP_BUF_BASE + (@as(u32, ep) - 1) * 64;
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

    /// Send data on CDC Data IN endpoint (EP5)
    fn hwSendCdcData(self: *UsbDriver, data: []const u8) void {
        const ep: u8 = usb_descriptors.CDC_DATA_ENDPOINT;
        const buf_ctrl_addr = USBCTRL_DPRAM_BASE + DPRAM.EP_BUF_CTRL_BASE + @as(u32, ep) * 8;
        const buf_ctrl = @as(*volatile u32, @ptrFromInt(buf_ctrl_addr));

        // Wait for previous packet to be consumed
        while (buf_ctrl.* & BufCtrl.AVAILABLE != 0) {}

        const buf = @as([*]volatile u8, @ptrFromInt(USBCTRL_DPRAM_BASE + DPRAM.EP5_IN_BUF));
        const len = @min(data.len, 64);

        for (data[0..len], 0..) |byte, i| {
            buf[i] = byte;
        }

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

test "UsbDriver handleBusReset resets state" {
    var drv = UsbDriver{};
    drv.init();

    // Set up an addressed and configured state
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_ADDRESS,
        .wValue = 5,
    });
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_CONFIGURATION,
        .wValue = 1,
    });
    try testing.expectEqual(DeviceState.configured, drv.state);
    try testing.expectEqual(@as(u8, 5), drv.address);
    try testing.expectEqual(@as(u8, 1), drv.configuration);

    // Simulate some data toggle activity
    drv.data_toggle = .{ true, false, true, false, false, false };

    // Bus reset
    drv.handleBusReset();

    try testing.expectEqual(DeviceState.default_state, drv.state);
    try testing.expectEqual(@as(u8, 0), drv.address);
    try testing.expectEqual(@as(u8, 0), drv.configuration);
    try testing.expectEqual([6]bool{ false, false, false, false, false, false }, drv.data_toggle);
}

test "UsbDriver task dispatches BUS_RESET" {
    var drv = UsbDriver{};
    drv.init();

    // Configure device first
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_ADDRESS,
        .wValue = 3,
    });
    try testing.expectEqual(DeviceState.addressed, drv.state);

    // Inject BUS_RESET event via mock
    drv.mock_ints = IntBit.BUS_RESET;
    drv.task();

    try testing.expectEqual(DeviceState.default_state, drv.state);
    try testing.expectEqual(@as(u8, 0), drv.address);
}

test "UsbDriver task dispatches SETUP_REQ" {
    var drv = UsbDriver{};
    drv.init();

    // Inject SETUP_REQ event with SET_ADDRESS packet via mock
    drv.mock_ints = IntBit.SETUP_REQ;
    drv.mock_setup_packet = .{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_ADDRESS,
        .wValue = 10,
    };
    drv.task();

    try testing.expectEqual(@as(u8, 10), drv.address);
    try testing.expectEqual(DeviceState.addressed, drv.state);
    // Mock setup packet should be consumed
    try testing.expect(drv.mock_setup_packet == null);
}

test "UsbDriver task handles BUFF_STATUS without crash" {
    var drv = UsbDriver{};
    drv.init();

    // Inject BUFF_STATUS event
    drv.mock_ints = IntBit.BUFF_STATUS;
    drv.task();

    // Should not change state
    try testing.expectEqual(DeviceState.disconnected, drv.state);
}

test "UsbDriver task handles multiple events" {
    var drv = UsbDriver{};
    drv.init();

    // Configure device
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_ADDRESS,
        .wValue = 5,
    });
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_CONFIGURATION,
        .wValue = 1,
    });
    try testing.expectEqual(DeviceState.configured, drv.state);

    // Inject BUS_RESET + BUFF_STATUS simultaneously
    drv.mock_ints = IntBit.BUS_RESET | IntBit.BUFF_STATUS;
    drv.task();

    try testing.expectEqual(DeviceState.default_state, drv.state);
    try testing.expectEqual(@as(u8, 0), drv.address);
}

test "UsbDriver task no-op when no events" {
    var drv = UsbDriver{};
    drv.init();

    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_ADDRESS,
        .wValue = 7,
    });
    try testing.expectEqual(@as(u8, 7), drv.address);

    // No events
    drv.mock_ints = 0;
    drv.task();

    // State should be unchanged
    try testing.expectEqual(@as(u8, 7), drv.address);
    try testing.expectEqual(DeviceState.addressed, drv.state);
}

test "SetupPacket size" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(SetupPacket));
}

test "EpCtrl bit positions" {
    try testing.expectEqual(@as(u32, 0x80000000), EpCtrl.ENABLE);
    try testing.expectEqual(@as(u32, 0x20000000), EpCtrl.INTERRUPT_PER_BUFF);
    // Interrupt type = 3 << 26 = 0x0C000000
    try testing.expectEqual(@as(u32, 0x0C000000), EpCtrl.EP_TYPE_INTERRUPT);
}

test "EP buffer offsets are consistent between hwConfigureEndpoints and hwSendEndpoint" {
    // hwConfigureEndpoints uses: EP_BUF_BASE + (ep - 1) * 64
    // hwSendEndpoint uses:       EP_BUF_BASE + (ep - 1) * 64
    // Both must produce the same buffer offset for each endpoint.
    const ep1_offset = DPRAM.EP_BUF_BASE + (@as(u32, usb_descriptors.KEYBOARD_ENDPOINT) - 1) * 64;
    const ep2_offset = DPRAM.EP_BUF_BASE + (@as(u32, usb_descriptors.MOUSE_ENDPOINT) - 1) * 64;
    const ep3_offset = DPRAM.EP_BUF_BASE + (@as(u32, usb_descriptors.EXTRA_ENDPOINT) - 1) * 64;

    // EP1 (Keyboard) buffer at 0x180
    try testing.expectEqual(@as(u32, 0x180), ep1_offset);
    // EP2 (Mouse) buffer at 0x1C0
    try testing.expectEqual(@as(u32, 0x1C0), ep2_offset);
    // EP3 (Extra) buffer at 0x200
    try testing.expectEqual(@as(u32, 0x200), ep3_offset);

    // Buffers must not overlap (each is 64 bytes)
    try testing.expect(ep2_offset >= ep1_offset + 64);
    try testing.expect(ep3_offset >= ep2_offset + 64);
}

test "EP0 data buffer address is correct" {
    // EP0 data buffer (ep0_buf_a) is at DPRAM offset 0x100
    // This is used for both GET_DESCRIPTOR (IN) and SET_REPORT (OUT) data stages.
    try testing.expectEqual(@as(u32, 0x100), DPRAM.EP0_BUF);
    // EP0_BUF must not overlap with EP1+ buffers
    try testing.expect(DPRAM.EP0_BUF + 64 <= DPRAM.EP0_OUT_BUF);
    try testing.expect(DPRAM.EP0_OUT_BUF + 64 <= DPRAM.EP_BUF_BASE);
}

test "EP control register DPRAM offsets" {
    // EP1 IN control: EP_IN_CTRL_BASE + (1 - 1) * 8 = 0x08
    try testing.expectEqual(@as(u32, 0x08), DPRAM.EP_IN_CTRL_BASE + (@as(u32, 1) - 1) * 8);
    // EP2 IN control: EP_IN_CTRL_BASE + (2 - 1) * 8 = 0x10
    try testing.expectEqual(@as(u32, 0x10), DPRAM.EP_IN_CTRL_BASE + (@as(u32, 2) - 1) * 8);
    // EP3 IN control: EP_IN_CTRL_BASE + (3 - 1) * 8 = 0x18
    try testing.expectEqual(@as(u32, 0x18), DPRAM.EP_IN_CTRL_BASE + (@as(u32, 3) - 1) * 8);
}

test "GET_DESCRIPTOR DEVICE returns device descriptor" {
    var drv = UsbDriver{};
    drv.init();

    drv.handleSetup(&.{
        .bmRequestType = 0x80, // Device-to-Host, Standard, Device
        .bRequest = Request.GET_DESCRIPTOR,
        .wValue = @as(u16, usb_descriptors.DescriptorType.DEVICE) << 8,
        .wIndex = 0,
        .wLength = 18,
    });

    // Device descriptor fits in one packet (18 bytes < 64), transfer should be complete
    try testing.expect(drv.ep0_in_data == null);
    try testing.expectEqual(@as(u16, 18), drv.ep0_in_total_len);
    // Data toggle should have been flipped once
    try testing.expect(drv.data_toggle[0] == true);
}

test "GET_DESCRIPTOR CONFIGURATION returns configuration descriptor" {
    var drv = UsbDriver{};
    drv.init();

    const config_len: u16 = @intCast(usb_descriptors.configuration_descriptor.len);

    drv.handleSetup(&.{
        .bmRequestType = 0x80,
        .bRequest = Request.GET_DESCRIPTOR,
        .wValue = @as(u16, usb_descriptors.DescriptorType.CONFIGURATION) << 8,
        .wIndex = 0,
        .wLength = 0xFFFF, // Host often requests max first
    });

    // Configuration descriptor > 64 bytes, multi-packet transfer
    try testing.expectEqual(config_len, drv.ep0_in_total_len);

    if (config_len > UsbDriver.EP0_MAX_PACKET_SIZE) {
        // First packet sent, more data pending
        try testing.expectEqual(UsbDriver.EP0_MAX_PACKET_SIZE, drv.ep0_in_offset);
        try testing.expect(drv.ep0_in_data != null);

        // Send remaining packets
        while (drv.ep0_in_data != null) {
            drv.sendEp0InPacket();
        }
    }
    // After all packets sent, transfer is complete
    try testing.expect(drv.ep0_in_data == null);
}

test "GET_DESCRIPTOR STRING returns correct string descriptors" {
    var drv = UsbDriver{};
    drv.init();

    // String descriptor 0 (language)
    drv.handleSetup(&.{
        .bmRequestType = 0x80,
        .bRequest = Request.GET_DESCRIPTOR,
        .wValue = @as(u16, usb_descriptors.DescriptorType.STRING) << 8 | 0,
        .wIndex = 0,
        .wLength = 255,
    });
    try testing.expectEqual(@as(u16, @intCast(usb_descriptors.string_descriptor_0.len)), drv.ep0_in_total_len);
    try testing.expect(drv.ep0_in_data == null); // Small, fits in one packet

    // String descriptor 1 (manufacturer)
    drv.data_toggle[0] = false;
    drv.handleSetup(&.{
        .bmRequestType = 0x80,
        .bRequest = Request.GET_DESCRIPTOR,
        .wValue = @as(u16, usb_descriptors.DescriptorType.STRING) << 8 | 1,
        .wIndex = 0,
        .wLength = 255,
    });
    try testing.expectEqual(@as(u16, @intCast(usb_descriptors.string_descriptor_manufacturer.len)), drv.ep0_in_total_len);

    // String descriptor 2 (product)
    drv.data_toggle[0] = false;
    drv.handleSetup(&.{
        .bmRequestType = 0x80,
        .bRequest = Request.GET_DESCRIPTOR,
        .wValue = @as(u16, usb_descriptors.DescriptorType.STRING) << 8 | 2,
        .wIndex = 0,
        .wLength = 255,
    });
    try testing.expectEqual(@as(u16, @intCast(usb_descriptors.string_descriptor_product.len)), drv.ep0_in_total_len);

    // String descriptor 3 (serial)
    drv.data_toggle[0] = false;
    drv.handleSetup(&.{
        .bmRequestType = 0x80,
        .bRequest = Request.GET_DESCRIPTOR,
        .wValue = @as(u16, usb_descriptors.DescriptorType.STRING) << 8 | 3,
        .wIndex = 0,
        .wLength = 255,
    });
    try testing.expectEqual(@as(u16, @intCast(usb_descriptors.string_descriptor_serial.len)), drv.ep0_in_total_len);
}

test "GET_DESCRIPTOR HID_REPORT selects by interface via wIndex" {
    var drv = UsbDriver{};
    drv.init();

    // Keyboard report descriptor (interface 0)
    drv.handleSetup(&.{
        .bmRequestType = 0x81, // Device-to-Host, Standard, Interface
        .bRequest = Request.GET_DESCRIPTOR,
        .wValue = @as(u16, usb_descriptors.DescriptorType.HID_REPORT) << 8,
        .wIndex = usb_descriptors.KEYBOARD_INTERFACE,
        .wLength = 0xFFFF,
    });
    try testing.expectEqual(@as(u16, @intCast(usb_descriptors.keyboard_report_descriptor.len)), drv.ep0_in_total_len);

    // Mouse report descriptor (interface 1)
    drv.data_toggle[0] = false;
    drv.ep0_in_data = null;
    drv.handleSetup(&.{
        .bmRequestType = 0x81,
        .bRequest = Request.GET_DESCRIPTOR,
        .wValue = @as(u16, usb_descriptors.DescriptorType.HID_REPORT) << 8,
        .wIndex = usb_descriptors.MOUSE_INTERFACE,
        .wLength = 0xFFFF,
    });
    try testing.expectEqual(@as(u16, @intCast(usb_descriptors.mouse_report_descriptor.len)), drv.ep0_in_total_len);

    // Extra report descriptor (interface 2)
    drv.data_toggle[0] = false;
    drv.ep0_in_data = null;
    drv.handleSetup(&.{
        .bmRequestType = 0x81,
        .bRequest = Request.GET_DESCRIPTOR,
        .wValue = @as(u16, usb_descriptors.DescriptorType.HID_REPORT) << 8,
        .wIndex = usb_descriptors.EXTRA_INTERFACE,
        .wLength = 0xFFFF,
    });
    try testing.expectEqual(@as(u16, @intCast(usb_descriptors.extra_report_descriptor.len)), drv.ep0_in_total_len);
}

test "GET_DESCRIPTOR unknown type does not set ep0_in_data" {
    var drv = UsbDriver{};
    drv.init();

    drv.handleSetup(&.{
        .bmRequestType = 0x80,
        .bRequest = Request.GET_DESCRIPTOR,
        .wValue = @as(u16, 0xFF) << 8, // Unknown descriptor type
        .wIndex = 0,
        .wLength = 64,
    });

    // Should not start any transfer (stallEndpoint0 called instead)
    try testing.expect(drv.ep0_in_data == null);
    try testing.expectEqual(@as(u16, 0), drv.ep0_in_total_len);
}

test "GET_DESCRIPTOR clamps to wLength" {
    var drv = UsbDriver{};
    drv.init();

    // Request device descriptor with wLength < descriptor size
    drv.handleSetup(&.{
        .bmRequestType = 0x80,
        .bRequest = Request.GET_DESCRIPTOR,
        .wValue = @as(u16, usb_descriptors.DescriptorType.DEVICE) << 8,
        .wIndex = 0,
        .wLength = 8, // Only request first 8 bytes
    });

    try testing.expectEqual(@as(u16, 8), drv.ep0_in_total_len);
    try testing.expect(drv.ep0_in_data == null); // 8 bytes < 64, single packet
}

test "GET_DESCRIPTOR unknown string index does not set ep0_in_data" {
    var drv = UsbDriver{};
    drv.init();

    drv.handleSetup(&.{
        .bmRequestType = 0x80,
        .bRequest = Request.GET_DESCRIPTOR,
        .wValue = @as(u16, usb_descriptors.DescriptorType.STRING) << 8 | 99,
        .wIndex = 0,
        .wLength = 255,
    });

    try testing.expect(drv.ep0_in_data == null);
    try testing.expectEqual(@as(u16, 0), drv.ep0_in_total_len);
}

test "GET_DESCRIPTOR HID_REPORT unknown interface does not set ep0_in_data" {
    var drv = UsbDriver{};
    drv.init();

    drv.handleSetup(&.{
        .bmRequestType = 0x81,
        .bRequest = Request.GET_DESCRIPTOR,
        .wValue = @as(u16, usb_descriptors.DescriptorType.HID_REPORT) << 8,
        .wIndex = 99, // Unknown interface
        .wLength = 0xFFFF,
    });

    try testing.expect(drv.ep0_in_data == null);
    try testing.expectEqual(@as(u16, 0), drv.ep0_in_total_len);
}

test "sendEp0InPacket multi-packet transfer" {
    var drv = UsbDriver{};
    drv.init();

    // Simulate a transfer of configuration descriptor (> 64 bytes)
    const config = &usb_descriptors.configuration_descriptor;
    const config_len: u16 = @intCast(config.len);
    drv.ep0_in_data = config;
    drv.ep0_in_offset = 0;
    drv.ep0_in_total_len = config_len;

    // Count packets needed
    var packets: u16 = 0;
    while (drv.ep0_in_data != null) {
        drv.sendEp0InPacket();
        packets += 1;
    }

    // Expected number of packets
    const expected_packets = (config_len + UsbDriver.EP0_MAX_PACKET_SIZE - 1) / UsbDriver.EP0_MAX_PACKET_SIZE;
    try testing.expectEqual(expected_packets, packets);

    // Data toggle should have been flipped for each packet
    // Starting from false, after odd number of flips = true, after even = false
    try testing.expectEqual(packets % 2 == 1, drv.data_toggle[0]);
}

test "handleBuffStatus continues multi-packet EP0 IN transfer" {
    var drv = UsbDriver{};
    drv.init();

    // Request configuration descriptor (> 64 bytes) via GET_DESCRIPTOR
    drv.handleSetup(&.{
        .bmRequestType = 0x80,
        .bRequest = Request.GET_DESCRIPTOR,
        .wValue = @as(u16, usb_descriptors.DescriptorType.CONFIGURATION) << 8,
        .wIndex = 0,
        .wLength = 0xFFFF,
    });

    const config_len: u16 = @intCast(usb_descriptors.configuration_descriptor.len);

    // First packet already sent by handleGetDescriptor
    if (config_len > UsbDriver.EP0_MAX_PACKET_SIZE) {
        try testing.expect(drv.ep0_in_data != null);
        try testing.expectEqual(UsbDriver.EP0_MAX_PACKET_SIZE, drv.ep0_in_offset);

        // Simulate BUFF_STATUS EP0 IN completion to trigger next packet
        drv.mock_buff_status = UsbDriver.BUFF_STATUS_EP0_IN;
        drv.handleBuffStatus();

        // Should have advanced the offset
        try testing.expect(drv.ep0_in_offset > UsbDriver.EP0_MAX_PACKET_SIZE);

        // Continue until transfer completes (re-set mock_buff_status each iteration)
        while (drv.ep0_in_data != null) {
            drv.mock_buff_status = UsbDriver.BUFF_STATUS_EP0_IN;
            drv.handleBuffStatus();
        }
    }

    try testing.expect(drv.ep0_in_data == null);
}

test "handleBuffStatus no-op when no EP0 IN data pending" {
    var drv = UsbDriver{};
    drv.init();

    // No pending transfer
    drv.mock_buff_status = UsbDriver.BUFF_STATUS_EP0_IN;
    drv.handleBuffStatus();

    // Should not crash, state unchanged
    try testing.expect(drv.ep0_in_data == null);
    try testing.expectEqual(@as(u16, 0), drv.ep0_in_offset);
}

test "SET_ADDRESS sends status stage ZLP and defers address" {
    var drv = UsbDriver{};
    drv.init();

    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_ADDRESS,
        .wValue = 7,
    });

    // Address should be set in software immediately
    try testing.expectEqual(@as(u8, 7), drv.address);
    try testing.expectEqual(DeviceState.addressed, drv.state);

    // pending_address should be set (waiting for ZLP completion)
    try testing.expectEqual(@as(?u8, 7), drv.pending_address);

    // Data toggle should have been flipped by ZLP
    try testing.expect(drv.data_toggle[0] == true);

    // Simulate ZLP completion via BUFF_STATUS
    drv.mock_buff_status = UsbDriver.BUFF_STATUS_EP0_IN;
    drv.handleBuffStatus();

    // pending_address should be cleared after ZLP completion
    try testing.expect(drv.pending_address == null);
}

test "SET_CONFIGURATION sends status stage ZLP" {
    var drv = UsbDriver{};
    drv.init();

    // Set address first
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_ADDRESS,
        .wValue = 1,
    });
    const toggle_after_addr = drv.data_toggle[0];

    // Set configuration
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_CONFIGURATION,
        .wValue = 1,
    });

    try testing.expectEqual(DeviceState.configured, drv.state);
    // Data toggle should have flipped again (ZLP for SET_CONFIGURATION)
    try testing.expectEqual(!toggle_after_addr, drv.data_toggle[0]);
}

test "SET_IDLE sends status stage ZLP" {
    var drv = UsbDriver{};
    drv.init();

    drv.handleSetup(&.{
        .bmRequestType = 0x21,
        .bRequest = HidRequest.SET_IDLE,
        .wValue = 0x0400,
    });

    try testing.expectEqual(@as(u8, 4), drv.keyboard_idle);
    // Data toggle flipped by ZLP
    try testing.expect(drv.data_toggle[0] == true);
}

test "SET_PROTOCOL sends status stage ZLP" {
    var drv = UsbDriver{};
    drv.init();

    drv.handleSetup(&.{
        .bmRequestType = 0x21,
        .bRequest = HidRequest.SET_PROTOCOL,
        .wValue = 0,
        .wIndex = usb_descriptors.KEYBOARD_INTERFACE,
    });

    try testing.expectEqual(HidProtocol.boot, drv.keyboard_protocol);
    // Data toggle flipped by ZLP
    try testing.expect(drv.data_toggle[0] == true);
}

test "SET_REPORT sends status stage ZLP" {
    var drv = UsbDriver{};
    drv.init();

    drv.mock_ep0_out_data = 0x03; // NumLock + CapsLock
    drv.handleSetup(&.{
        .bmRequestType = 0x21,
        .bRequest = HidRequest.SET_REPORT,
        .wValue = 0x0200, // Output report, ID 0
        .wIndex = usb_descriptors.KEYBOARD_INTERFACE,
        .wLength = 1,
    });

    try testing.expectEqual(@as(u8, 0x03), drv.keyboard_leds);
    // Data toggle flipped by ZLP
    try testing.expect(drv.data_toggle[0] == true);
}

test "handleBusReset clears pending_address" {
    var drv = UsbDriver{};
    drv.init();

    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_ADDRESS,
        .wValue = 5,
    });
    try testing.expectEqual(@as(?u8, 5), drv.pending_address);

    drv.handleBusReset();
    try testing.expect(drv.pending_address == null);
    try testing.expectEqual(@as(u8, 0), drv.address);
}

test "handleBuffStatus applies pending_address after ZLP" {
    var drv = UsbDriver{};
    drv.init();

    // Manually set pending_address (simulating SET_ADDRESS processing)
    drv.pending_address = 12;

    // Simulate ZLP completion
    drv.mock_buff_status = UsbDriver.BUFF_STATUS_EP0_IN;
    drv.handleBuffStatus();

    // pending_address should be consumed
    try testing.expect(drv.pending_address == null);
}

test "SET_CONFIGURATION resets EP1-EP3 data toggle to DATA0" {
    var drv = UsbDriver{};
    drv.init();

    // Simulate some data toggle activity on EP1-EP3
    drv.data_toggle[1] = true;
    drv.data_toggle[2] = true;
    drv.data_toggle[3] = true;

    // Set configuration
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_CONFIGURATION,
        .wValue = 1,
    });

    try testing.expectEqual(DeviceState.configured, drv.state);
    // EP1-EP3 data toggles should be reset to DATA0 (false)
    try testing.expectEqual(false, drv.data_toggle[1]);
    try testing.expectEqual(false, drv.data_toggle[2]);
    try testing.expectEqual(false, drv.data_toggle[3]);
}

test "SET_CONFIGURATION re-configuration resets EP1-EP3 data toggle" {
    var drv = UsbDriver{};
    drv.init();

    // First configuration
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_CONFIGURATION,
        .wValue = 1,
    });
    try testing.expectEqual(DeviceState.configured, drv.state);

    // Simulate data toggle activity after first configuration
    drv.data_toggle[1] = true;
    drv.data_toggle[2] = true;
    drv.data_toggle[3] = true;

    // Re-configuration (SET_CONFIGURATION again)
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_CONFIGURATION,
        .wValue = 1,
    });

    try testing.expectEqual(DeviceState.configured, drv.state);
    // EP1-EP3 data toggles should be reset again
    try testing.expectEqual(false, drv.data_toggle[1]);
    try testing.expectEqual(false, drv.data_toggle[2]);
    try testing.expectEqual(false, drv.data_toggle[3]);
}

test "SET_CONFIGURATION with value 0 also resets EP1-EP3 data toggle" {
    var drv = UsbDriver{};
    drv.init();

    // First configure
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_CONFIGURATION,
        .wValue = 1,
    });
    try testing.expectEqual(DeviceState.configured, drv.state);

    // Simulate data toggle activity
    drv.data_toggle[1] = true;
    drv.data_toggle[2] = true;
    drv.data_toggle[3] = true;

    // De-configure (SET_CONFIGURATION with value 0)
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_CONFIGURATION,
        .wValue = 0,
    });

    try testing.expectEqual(DeviceState.addressed, drv.state);
    // EP1-EP3 data toggles should be reset even with configuration 0
    try testing.expectEqual(false, drv.data_toggle[1]);
    try testing.expectEqual(false, drv.data_toggle[2]);
    try testing.expectEqual(false, drv.data_toggle[3]);
}

// ============================================================
// CDC Tests
// ============================================================

test "CDC SET_LINE_CODING stores line coding" {
    var drv = UsbDriver{};
    drv.init();

    // Mock: set LineCoding data in ep0_reply_buf (used as mock source)
    const lc = usb_descriptors.LineCoding{
        .dwDTERate = 9600,
        .bCharFormat = 1,
        .bParityType = 2,
        .bDataBits = 7,
    };
    drv.ep0_reply_buf = @bitCast(lc);

    drv.handleSetup(&.{
        .bmRequestType = 0x21, // Host-to-Device, Class, Interface
        .bRequest = usb_descriptors.CdcRequest.SET_LINE_CODING,
        .wValue = 0,
        .wIndex = usb_descriptors.CDC_COMM_INTERFACE,
        .wLength = 7,
    });

    try testing.expectEqual(@as(u32, 9600), drv.cdc_line_coding.dwDTERate);
    try testing.expectEqual(@as(u8, 1), drv.cdc_line_coding.bCharFormat);
    try testing.expectEqual(@as(u8, 2), drv.cdc_line_coding.bParityType);
    try testing.expectEqual(@as(u8, 7), drv.cdc_line_coding.bDataBits);
    // ZLP sent
    try testing.expect(drv.data_toggle[0] == true);
}

test "CDC GET_LINE_CODING returns current line coding" {
    var drv = UsbDriver{};
    drv.init();

    // Default line coding should be 115200/8N1
    drv.handleSetup(&.{
        .bmRequestType = 0xA1, // Device-to-Host, Class, Interface
        .bRequest = usb_descriptors.CdcRequest.GET_LINE_CODING,
        .wValue = 0,
        .wIndex = usb_descriptors.CDC_COMM_INTERFACE,
        .wLength = 7,
    });

    try testing.expectEqual(@as(u16, 7), drv.ep0_in_total_len);
    // ep0_reply_buf should contain the default line coding
    const reply_lc: usb_descriptors.LineCoding = @bitCast(drv.ep0_reply_buf);
    try testing.expectEqual(@as(u32, 115200), reply_lc.dwDTERate);
    try testing.expectEqual(@as(u8, 0), reply_lc.bCharFormat);
    try testing.expectEqual(@as(u8, 0), reply_lc.bParityType);
    try testing.expectEqual(@as(u8, 8), reply_lc.bDataBits);
}

test "CDC SET_CONTROL_LINE_STATE stores DTR/RTS" {
    var drv = UsbDriver{};
    drv.init();

    drv.handleSetup(&.{
        .bmRequestType = 0x21,
        .bRequest = usb_descriptors.CdcRequest.SET_CONTROL_LINE_STATE,
        .wValue = 0x03, // DTR + RTS
        .wIndex = usb_descriptors.CDC_COMM_INTERFACE,
        .wLength = 0,
    });

    try testing.expectEqual(@as(u16, 0x03), drv.cdc_control_line_state);
    try testing.expect(drv.cdcDtrActive());
    // ZLP sent
    try testing.expect(drv.data_toggle[0] == true);
}

test "CDC DTR inactive by default" {
    var drv = UsbDriver{};
    drv.init();
    try testing.expect(!drv.cdcDtrActive());
}

test "CDC TX ring buffer write and flush" {
    var drv = UsbDriver{};
    drv.init();

    // Configure device so flush works
    drv.state = .configured;

    drv.cdcWrite("Hello");
    try testing.expectEqual(@as(u8, 5), drv.cdc_tx_head);
    try testing.expectEqual(@as(u8, 0), drv.cdc_tx_tail);

    drv.cdcFlush();

    // After flush, tail should catch up to head
    try testing.expectEqual(@as(u8, 5), drv.cdc_tx_tail);
    // EP5 data toggle should have been flipped
    try testing.expect(drv.data_toggle[usb_descriptors.CDC_DATA_ENDPOINT]);
}

test "CDC TX ring buffer handles empty flush" {
    var drv = UsbDriver{};
    drv.init();
    drv.state = .configured;

    // Flush with no data should not crash or change toggle
    drv.cdcFlush();
    try testing.expect(!drv.data_toggle[usb_descriptors.CDC_DATA_ENDPOINT]);
}

test "CDC print formatted output" {
    var drv = UsbDriver{};
    drv.init();

    drv.cdcPrint("test {d}\n", .{42});

    // Check that data was written to buffer
    const expected = "test 42\n";
    try testing.expectEqual(@as(u8, @intCast(expected.len)), drv.cdc_tx_head);
    for (expected, 0..) |c, i| {
        try testing.expectEqual(c, drv.cdc_tx_buf[i]);
    }
}

test "handleBusReset clears CDC TX buffer" {
    var drv = UsbDriver{};
    drv.init();

    drv.cdcWrite("hello");
    try testing.expect(drv.cdc_tx_head != drv.cdc_tx_tail);

    drv.handleBusReset();

    try testing.expectEqual(@as(u8, 0), drv.cdc_tx_head);
    try testing.expectEqual(@as(u8, 0), drv.cdc_tx_tail);
}

test "EP4/EP5 DPRAM buffer offsets" {
    try testing.expectEqual(@as(u32, 0x240), DPRAM.EP4_BUF);
    try testing.expectEqual(@as(u32, 0x280), DPRAM.EP5_IN_BUF);
    try testing.expectEqual(@as(u32, 0x2C0), DPRAM.EP5_OUT_BUF);
    // No overlap with EP3 buffer (EP3 at 0x200, 64 bytes -> 0x240)
    try testing.expect(DPRAM.EP4_BUF >= DPRAM.EP_BUF_BASE + 3 * 64);
    try testing.expect(DPRAM.EP5_IN_BUF >= DPRAM.EP4_BUF + 64);
    try testing.expect(DPRAM.EP5_OUT_BUF >= DPRAM.EP5_IN_BUF + 64);
}

test "EpCtrl bulk type value" {
    // Bulk type = 2 << 26 = 0x08000000
    try testing.expectEqual(@as(u32, 0x08000000), EpCtrl.EP_TYPE_BULK);
}

test "GET_CONFIGURATION returns 0 when not configured" {
    var drv = UsbDriver{};
    drv.init();

    drv.handleSetup(&.{
        .bmRequestType = 0x80,
        .bRequest = Request.GET_CONFIGURATION,
        .wValue = 0,
        .wIndex = 0,
        .wLength = 1,
    });

    // 1-byte response should have been sent
    try testing.expectEqual(@as(u16, 1), drv.ep0_in_total_len);
    // Value should be 0 (not configured)
    try testing.expectEqual(@as(u8, 0), drv.ep0_reply_buf[0]);
    // Single byte fits in one packet, transfer should be complete
    try testing.expect(drv.ep0_in_data == null);
    // Data toggle should have been flipped
    try testing.expect(drv.data_toggle[0] == true);
}

test "GET_CONFIGURATION returns 1 after SET_CONFIGURATION" {
    var drv = UsbDriver{};
    drv.init();

    // Set configuration first
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_CONFIGURATION,
        .wValue = 1,
    });
    drv.data_toggle[0] = false; // Reset for clarity

    drv.handleSetup(&.{
        .bmRequestType = 0x80,
        .bRequest = Request.GET_CONFIGURATION,
        .wValue = 0,
        .wIndex = 0,
        .wLength = 1,
    });

    try testing.expectEqual(@as(u16, 1), drv.ep0_in_total_len);
    try testing.expectEqual(@as(u8, 1), drv.ep0_reply_buf[0]);
    try testing.expect(drv.ep0_in_data == null);
}

test "GET_PROTOCOL returns report protocol by default for keyboard" {
    var drv = UsbDriver{};
    drv.init();

    drv.handleSetup(&.{
        .bmRequestType = 0xA1,
        .bRequest = HidRequest.GET_PROTOCOL,
        .wValue = 0,
        .wIndex = usb_descriptors.KEYBOARD_INTERFACE,
        .wLength = 1,
    });

    try testing.expectEqual(@as(u16, 1), drv.ep0_in_total_len);
    // Default is report protocol (1)
    try testing.expectEqual(@as(u8, 1), drv.ep0_reply_buf[0]);
    try testing.expect(drv.ep0_in_data == null);
    try testing.expect(drv.data_toggle[0] == true);
}

test "GET_PROTOCOL returns boot protocol after SET_PROTOCOL" {
    var drv = UsbDriver{};
    drv.init();

    // Set keyboard to boot protocol
    drv.handleSetup(&.{
        .bmRequestType = 0x21,
        .bRequest = HidRequest.SET_PROTOCOL,
        .wValue = 0, // boot protocol
        .wIndex = usb_descriptors.KEYBOARD_INTERFACE,
    });
    drv.data_toggle[0] = false;

    drv.handleSetup(&.{
        .bmRequestType = 0xA1,
        .bRequest = HidRequest.GET_PROTOCOL,
        .wValue = 0,
        .wIndex = usb_descriptors.KEYBOARD_INTERFACE,
        .wLength = 1,
    });

    try testing.expectEqual(@as(u16, 1), drv.ep0_in_total_len);
    try testing.expectEqual(@as(u8, 0), drv.ep0_reply_buf[0]); // boot = 0
    try testing.expect(drv.ep0_in_data == null);
}

test "GET_PROTOCOL returns mouse protocol" {
    var drv = UsbDriver{};
    drv.init();

    // Set mouse to boot protocol
    drv.handleSetup(&.{
        .bmRequestType = 0x21,
        .bRequest = HidRequest.SET_PROTOCOL,
        .wValue = 0,
        .wIndex = usb_descriptors.MOUSE_INTERFACE,
    });
    drv.data_toggle[0] = false;

    drv.handleSetup(&.{
        .bmRequestType = 0xA1,
        .bRequest = HidRequest.GET_PROTOCOL,
        .wValue = 0,
        .wIndex = usb_descriptors.MOUSE_INTERFACE,
        .wLength = 1,
    });

    try testing.expectEqual(@as(u16, 1), drv.ep0_in_total_len);
    try testing.expectEqual(@as(u8, 0), drv.ep0_reply_buf[0]); // boot = 0
    try testing.expect(drv.ep0_in_data == null);
}

test "GET_PROTOCOL stalls on unknown interface" {
    var drv = UsbDriver{};
    drv.init();

    drv.handleSetup(&.{
        .bmRequestType = 0xA1,
        .bRequest = HidRequest.GET_PROTOCOL,
        .wValue = 0,
        .wIndex = 99, // Unknown interface
        .wLength = 1,
    });

    // Should not start any transfer (stallEndpoint0 called)
    try testing.expect(drv.ep0_in_data == null);
    try testing.expectEqual(@as(u16, 0), drv.ep0_in_total_len);
}
