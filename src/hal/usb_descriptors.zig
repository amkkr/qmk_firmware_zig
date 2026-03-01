// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zig port of tmk_core/protocol/usb_descriptor.c
// Original: Copyright 2012 Jun Wako <wakojun@gmail.com>
// Based on LUFA Library, Copyright 2012 Dean Camera

//! USB and HID descriptor definitions
//! Based on tmk_core/protocol/usb_descriptor.c and usb_descriptor.h
//!
//! Defines all USB descriptors needed for a composite HID + CDC ACM device:
//! device, configuration, interface, HID, CDC, endpoint, and report descriptors.

const std = @import("std");
const build_options = @import("build_options");

const kb = if (std.mem.eql(u8, build_options.KEYBOARD, "madbd34"))
    @import("../keyboards/madbd34.zig")
else
    @import("../keyboards/madbd5.zig");

// ============================================================
// USB Descriptor Type Constants
// ============================================================

pub const DescriptorType = struct {
    pub const DEVICE: u8 = 0x01;
    pub const CONFIGURATION: u8 = 0x02;
    pub const STRING: u8 = 0x03;
    pub const INTERFACE: u8 = 0x04;
    pub const ENDPOINT: u8 = 0x05;
    pub const INTERFACE_ASSOCIATION: u8 = 0x0B;
    pub const CS_INTERFACE: u8 = 0x24;
    pub const HID: u8 = 0x21;
    pub const HID_REPORT: u8 = 0x22;
};

pub const DeviceClass = struct {
    pub const PER_INTERFACE: u8 = 0x00;
    pub const MISC: u8 = 0xEF;
};

pub const InterfaceClass = struct {
    pub const HID: u8 = 0x03;
    pub const CDC: u8 = 0x02;
    pub const CDC_DATA: u8 = 0x0A;
};

pub const InterfaceSubClass = struct {
    pub const NONE: u8 = 0x00;
    pub const BOOT: u8 = 0x01;
};

pub const InterfaceProtocol = struct {
    pub const NONE: u8 = 0x00;
    pub const KEYBOARD: u8 = 0x01;
    pub const MOUSE: u8 = 0x02;
};

pub const EndpointDirection = struct {
    pub const IN: u8 = 0x80;
    pub const OUT: u8 = 0x00;
};

pub const EndpointTransfer = struct {
    pub const BULK: u8 = 0x02;
    pub const INTERRUPT: u8 = 0x03;
};

// ============================================================
// USB IDs and Version (from keyboard definition)
// ============================================================

pub const USB_VID: u16 = kb.usb_vid;
pub const USB_PID: u16 = kb.usb_pid;
pub const DEVICE_VERSION: u16 = 0x0001;

// ============================================================
// Interface and Endpoint Numbers
// ============================================================

pub const KEYBOARD_INTERFACE: u8 = 0;
pub const MOUSE_INTERFACE: u8 = 1;
pub const EXTRA_INTERFACE: u8 = 2;
pub const CDC_COMM_INTERFACE: u8 = 3;
pub const CDC_DATA_INTERFACE: u8 = 4;
pub const NUM_INTERFACES: u8 = 5;

pub const KEYBOARD_ENDPOINT: u8 = 1;
pub const MOUSE_ENDPOINT: u8 = 2;
pub const EXTRA_ENDPOINT: u8 = 3;
pub const CDC_NOTIFICATION_ENDPOINT: u8 = 4;
pub const CDC_DATA_ENDPOINT: u8 = 5;

pub const KEYBOARD_ENDPOINT_SIZE: u8 = 8;
pub const MOUSE_ENDPOINT_SIZE: u8 = 8;
pub const EXTRA_ENDPOINT_SIZE: u8 = 8;
pub const CDC_NOTIFICATION_ENDPOINT_SIZE: u8 = 8;
pub const CDC_DATA_ENDPOINT_SIZE: u8 = 64;

pub const KEYBOARD_INTERVAL: u8 = 10; // ms
pub const MOUSE_INTERVAL: u8 = 10;
pub const EXTRA_INTERVAL: u8 = 10;
pub const CDC_NOTIFICATION_INTERVAL: u8 = 16;

// ============================================================
// CDC Definitions
// ============================================================

/// CDC Line Coding structure (7 bytes)
pub const LineCoding = extern struct {
    dwDTERate: u32 align(1) = 115200, // baud rate
    bCharFormat: u8 = 0, // 0: 1 stop bit
    bParityType: u8 = 0, // 0: none
    bDataBits: u8 = 8, // 8 data bits

    comptime {
        if (@sizeOf(LineCoding) != 7) {
            @compileError("LineCoding must be 7 bytes");
        }
    }
};

/// CDC Class-specific request codes
pub const CdcRequest = struct {
    pub const SET_LINE_CODING: u8 = 0x20;
    pub const GET_LINE_CODING: u8 = 0x21;
    pub const SET_CONTROL_LINE_STATE: u8 = 0x22;
};

/// CDC functional descriptor subtypes
pub const CdcDescSubtype = struct {
    pub const HEADER: u8 = 0x00;
    pub const CALL_MANAGEMENT: u8 = 0x01;
    pub const ACM: u8 = 0x02;
    pub const UNION: u8 = 0x06;
};

// ============================================================
// HID Report Descriptors
// ============================================================

/// HID report descriptor items (short items)
fn hidUsagePage(page: u8) [2]u8 {
    return .{ 0x05, page };
}

fn hidUsage(usage: u8) [2]u8 {
    return .{ 0x09, usage };
}

fn hidUsage16(usage: u16) [3]u8 {
    return .{ 0x0A, @truncate(usage), @truncate(usage >> 8) };
}

fn hidCollection(kind: u8) [2]u8 {
    return .{ 0xA1, kind };
}

fn hidEndCollection() [1]u8 {
    return .{0xC0};
}

fn hidReportSize(size: u8) [2]u8 {
    return .{ 0x75, size };
}

fn hidReportCount(count: u8) [2]u8 {
    return .{ 0x95, count };
}

fn hidLogicalMin(val: u8) [2]u8 {
    return .{ 0x15, val };
}

fn hidLogicalMax(val: u8) [2]u8 {
    return .{ 0x25, val };
}

fn hidLogicalMaxU16(val: u16) [3]u8 {
    return .{ 0x26, @truncate(val), @truncate(val >> 8) };
}

fn hidUsageMin(val: u8) [2]u8 {
    return .{ 0x19, val };
}

fn hidUsageMax(val: u8) [2]u8 {
    return .{ 0x29, val };
}

fn hidUsageMaxU16(val: u16) [3]u8 {
    return .{ 0x2A, @truncate(val), @truncate(val >> 8) };
}

fn hidInput(flags: u8) [2]u8 {
    return .{ 0x81, flags };
}

fn hidOutput(flags: u8) [2]u8 {
    return .{ 0x91, flags };
}

fn hidReportId(id: u8) [2]u8 {
    return .{ 0x85, id };
}

/// Input/Output item flags
const DATA_VAR_ABS: u8 = 0x02; // Data, Variable, Absolute
const CONST: u8 = 0x01; // Constant (for padding/reserved bytes)
const DATA_ARR_ABS: u8 = 0x00; // Data, Array, Absolute
const DATA_VAR_REL: u8 = 0x06; // Data, Variable, Relative

/// Keyboard HID report descriptor (Boot Protocol compatible)
pub const keyboard_report_descriptor = blk: {
    break :blk
    // Usage Page (Generic Desktop)
        hidUsagePage(0x01) ++
        // Usage (Keyboard)
        hidUsage(0x06) ++
        // Collection (Application)
        hidCollection(0x01) ++

        // --- Modifier keys (byte 0) ---
        // Usage Page (Key Codes)
        hidUsagePage(0x07) ++
        hidUsageMin(0xE0) ++
        hidUsageMax(0xE7) ++
        hidLogicalMin(0) ++
        hidLogicalMax(1) ++
        hidReportSize(1) ++
        hidReportCount(8) ++
        hidInput(DATA_VAR_ABS) ++

        // --- Reserved byte (byte 1) ---
        hidReportCount(1) ++
        hidReportSize(8) ++
        hidInput(CONST) ++

        // --- LED output report ---
        hidUsagePage(0x08) ++ // LEDs
        hidUsageMin(1) ++
        hidUsageMax(5) ++
        hidReportCount(5) ++
        hidReportSize(1) ++
        hidOutput(DATA_VAR_ABS) ++
        // Padding (3 bits)
        hidReportCount(1) ++
        hidReportSize(3) ++
        hidOutput(CONST) ++

        // --- Key array (bytes 2-7) ---
        hidUsagePage(0x07) ++
        hidUsageMin(0) ++
        hidUsageMax(0xFF) ++
        hidLogicalMin(0) ++
        hidLogicalMaxU16(0xFF) ++
        hidReportCount(6) ++
        hidReportSize(8) ++
        hidInput(DATA_ARR_ABS) ++

        hidEndCollection();
};

/// Mouse HID report descriptor
pub const mouse_report_descriptor = blk: {
    break :blk
    // Usage Page (Generic Desktop)
        hidUsagePage(0x01) ++
        // Usage (Mouse)
        hidUsage(0x02) ++
        // Collection (Application)
        hidCollection(0x01) ++
        // Usage (Pointer)
        hidUsage(0x01) ++
        // Collection (Physical)
        hidCollection(0x00) ++

        // --- Buttons (8 buttons) ---
        hidUsagePage(0x09) ++ // Buttons
        hidUsageMin(1) ++
        hidUsageMax(8) ++
        hidLogicalMin(0) ++
        hidLogicalMax(1) ++
        hidReportCount(8) ++
        hidReportSize(1) ++
        hidInput(DATA_VAR_ABS) ++

        // --- X, Y axes ---
        hidUsagePage(0x01) ++ // Generic Desktop
        hidUsage(0x30) ++ // X
        hidUsage(0x31) ++ // Y
        hidLogicalMin(0x81) ++ // -127 (as u8 = 0x81)
        hidLogicalMax(127) ++
        hidReportSize(8) ++
        hidReportCount(2) ++
        hidInput(DATA_VAR_REL) ++

        // --- Vertical scroll ---
        hidUsage(0x38) ++ // Wheel
        hidLogicalMin(0x81) ++
        hidLogicalMax(127) ++
        hidReportSize(8) ++
        hidReportCount(1) ++
        hidInput(DATA_VAR_REL) ++

        // --- Horizontal scroll ---
        hidUsagePage(0x0C) ++ // Consumer
        hidUsage16(0x0238) ++ // AC Pan
        hidLogicalMin(0x81) ++
        hidLogicalMax(127) ++
        hidReportSize(8) ++
        hidReportCount(1) ++
        hidInput(DATA_VAR_REL) ++

        hidEndCollection() ++ // Physical
        hidEndCollection(); // Application
};

/// Extra (system/consumer) HID report descriptor
pub const extra_report_descriptor = blk: {
    break :blk
    // --- System Control ---
        hidUsagePage(0x01) ++ // Generic Desktop
        hidUsage(0x80) ++ // System Control
        hidCollection(0x01) ++
        hidReportId(3) ++ // System
        hidUsageMin(0x81) ++ // System Power Down
        hidUsageMax(0x83) ++ // System Wake Up
        hidLogicalMin(0) ++
        hidLogicalMax(1) ++
        hidReportCount(3) ++
        hidReportSize(1) ++
        hidInput(DATA_VAR_ABS) ++
        hidReportCount(1) ++
        hidReportSize(5) ++
        hidInput(CONST) ++
        hidEndCollection() ++

        // --- Consumer Control ---
        hidUsagePage(0x0C) ++ // Consumer
        hidUsage(0x01) ++ // Consumer Control
        hidCollection(0x01) ++
        hidReportId(4) ++ // Consumer
        hidUsageMin(0) ++
        hidUsageMaxU16(0x02FF) ++
        hidLogicalMin(0) ++
        hidLogicalMaxU16(0x02FF) ++
        hidReportCount(1) ++
        hidReportSize(16) ++
        hidInput(DATA_VAR_ABS) ++
        hidEndCollection();
};

// ============================================================
// Device Descriptor
// ============================================================

pub const device_descriptor = [18]u8{
    18, // bLength
    DescriptorType.DEVICE, // bDescriptorType
    0x00, 0x02, // bcdUSB (USB 2.0)
    DeviceClass.MISC, // bDeviceClass (Miscellaneous, for IAD)
    0x02, // bDeviceSubClass (Common Class)
    0x01, // bDeviceProtocol (Interface Association Descriptor)
    64, // bMaxPacketSize0
    @truncate(USB_VID), @truncate(USB_VID >> 8), // idVendor
    @truncate(USB_PID), @truncate(USB_PID >> 8), // idProduct
    @truncate(DEVICE_VERSION), @truncate(DEVICE_VERSION >> 8), // bcdDevice
    1, // iManufacturer (string index)
    2, // iProduct (string index)
    3, // iSerialNumber (string index)
    1, // bNumConfigurations
};

// ============================================================
// Configuration Descriptor (with all interfaces)
// ============================================================

fn interfaceDescriptor(
    interface_num: u8,
    num_endpoints: u8,
    subclass: u8,
    protocol: u8,
    iface_string: u8,
) [9]u8 {
    return .{
        9, // bLength
        DescriptorType.INTERFACE, // bDescriptorType
        interface_num, // bInterfaceNumber
        0, // bAlternateSetting
        num_endpoints, // bNumEndpoints
        InterfaceClass.HID, // bInterfaceClass
        subclass, // bInterfaceSubClass
        protocol, // bInterfaceProtocol
        iface_string, // iInterface
    };
}

fn genericInterfaceDescriptor(
    interface_num: u8,
    num_endpoints: u8,
    iface_class: u8,
    subclass: u8,
    protocol: u8,
    iface_string: u8,
) [9]u8 {
    return .{
        9, // bLength
        DescriptorType.INTERFACE, // bDescriptorType
        interface_num, // bInterfaceNumber
        0, // bAlternateSetting
        num_endpoints, // bNumEndpoints
        iface_class, // bInterfaceClass
        subclass, // bInterfaceSubClass
        protocol, // bInterfaceProtocol
        iface_string, // iInterface
    };
}

fn hidDescriptor(report_desc_len: u16) [9]u8 {
    return .{
        9, // bLength
        DescriptorType.HID, // bDescriptorType
        0x11, 0x01, // bcdHID (1.11)
        0x00, // bCountryCode
        1, // bNumDescriptors
        DescriptorType.HID_REPORT, // bDescriptorType (Report)
        @truncate(report_desc_len), // wDescriptorLength (low)
        @truncate(report_desc_len >> 8), // wDescriptorLength (high)
    };
}

fn endpointDescriptor(
    endpoint_addr: u8,
    max_packet_size: u8,
    interval: u8,
) [7]u8 {
    return .{
        7, // bLength
        DescriptorType.ENDPOINT, // bDescriptorType
        endpoint_addr | EndpointDirection.IN, // bEndpointAddress (IN)
        EndpointTransfer.INTERRUPT, // bmAttributes
        max_packet_size, 0, // wMaxPacketSize
        interval, // bInterval
    };
}

fn genericEndpointDescriptor(
    endpoint_addr: u8,
    attributes: u8,
    max_packet_size: u8,
    interval: u8,
) [7]u8 {
    return .{
        7, // bLength
        DescriptorType.ENDPOINT, // bDescriptorType
        endpoint_addr, // bEndpointAddress
        attributes, // bmAttributes
        max_packet_size, 0, // wMaxPacketSize
        interval, // bInterval
    };
}

/// Interface Association Descriptor (IAD) for CDC
fn iadDescriptor(
    first_interface: u8,
    interface_count: u8,
    function_class: u8,
    function_subclass: u8,
    function_protocol: u8,
) [8]u8 {
    return .{
        8, // bLength
        DescriptorType.INTERFACE_ASSOCIATION, // bDescriptorType
        first_interface, // bFirstInterface
        interface_count, // bInterfaceCount
        function_class, // bFunctionClass
        function_subclass, // bFunctionSubClass
        function_protocol, // bFunctionProtocol
        0, // iFunction
    };
}

/// CDC Header Functional Descriptor
fn cdcHeaderDescriptor() [5]u8 {
    return .{
        5, // bLength
        DescriptorType.CS_INTERFACE, // bDescriptorType
        CdcDescSubtype.HEADER, // bDescriptorSubtype
        0x10, 0x01, // bcdCDC (1.10)
    };
}

/// CDC Call Management Functional Descriptor
fn cdcCallManagementDescriptor(data_interface: u8) [5]u8 {
    return .{
        5, // bLength
        DescriptorType.CS_INTERFACE, // bDescriptorType
        CdcDescSubtype.CALL_MANAGEMENT, // bDescriptorSubtype
        0x00, // bmCapabilities (no call management)
        data_interface, // bDataInterface
    };
}

/// CDC ACM Functional Descriptor
fn cdcAcmDescriptor() [4]u8 {
    return .{
        4, // bLength
        DescriptorType.CS_INTERFACE, // bDescriptorType
        CdcDescSubtype.ACM, // bDescriptorSubtype
        0x02, // bmCapabilities (line coding and serial state)
    };
}

/// CDC Union Functional Descriptor
fn cdcUnionDescriptor(master_interface: u8, slave_interface: u8) [5]u8 {
    return .{
        5, // bLength
        DescriptorType.CS_INTERFACE, // bDescriptorType
        CdcDescSubtype.UNION, // bDescriptorSubtype
        master_interface, // bMasterInterface
        slave_interface, // bSlaveInterface
    };
}

/// Full configuration descriptor (config + all interfaces)
pub const configuration_descriptor = blk: {
    const keyboard_iface = interfaceDescriptor(
        KEYBOARD_INTERFACE,
        1,
        InterfaceSubClass.BOOT,
        InterfaceProtocol.KEYBOARD,
        0,
    );
    const keyboard_hid = hidDescriptor(keyboard_report_descriptor.len);
    const keyboard_ep = endpointDescriptor(
        KEYBOARD_ENDPOINT,
        KEYBOARD_ENDPOINT_SIZE,
        KEYBOARD_INTERVAL,
    );

    const mouse_iface = interfaceDescriptor(
        MOUSE_INTERFACE,
        1,
        InterfaceSubClass.BOOT,
        InterfaceProtocol.MOUSE,
        0,
    );
    const mouse_hid = hidDescriptor(mouse_report_descriptor.len);
    const mouse_ep = endpointDescriptor(
        MOUSE_ENDPOINT,
        MOUSE_ENDPOINT_SIZE,
        MOUSE_INTERVAL,
    );

    const extra_iface = interfaceDescriptor(
        EXTRA_INTERFACE,
        1,
        InterfaceSubClass.NONE,
        InterfaceProtocol.NONE,
        0,
    );
    const extra_hid = hidDescriptor(extra_report_descriptor.len);
    const extra_ep = endpointDescriptor(
        EXTRA_ENDPOINT,
        EXTRA_ENDPOINT_SIZE,
        EXTRA_INTERVAL,
    );

    // --- CDC ACM (Interface Association + Comm Interface + Data Interface) ---
    const cdc_iad = iadDescriptor(
        CDC_COMM_INTERFACE,
        2, // 2 interfaces (comm + data)
        InterfaceClass.CDC, // Communication
        0x02, // Abstract Control Model
        0x01, // AT commands (V.25ter)
    );
    const cdc_comm_iface = genericInterfaceDescriptor(
        CDC_COMM_INTERFACE,
        1, // 1 endpoint (notification)
        InterfaceClass.CDC,
        0x02, // ACM
        0x01, // AT commands
        0,
    );
    const cdc_header = cdcHeaderDescriptor();
    const cdc_call_mgmt = cdcCallManagementDescriptor(CDC_DATA_INTERFACE);
    const cdc_acm = cdcAcmDescriptor();
    const cdc_union = cdcUnionDescriptor(CDC_COMM_INTERFACE, CDC_DATA_INTERFACE);
    const cdc_notification_ep = genericEndpointDescriptor(
        CDC_NOTIFICATION_ENDPOINT | EndpointDirection.IN,
        EndpointTransfer.INTERRUPT,
        CDC_NOTIFICATION_ENDPOINT_SIZE,
        CDC_NOTIFICATION_INTERVAL,
    );
    const cdc_data_iface = genericInterfaceDescriptor(
        CDC_DATA_INTERFACE,
        2, // 2 endpoints (IN + OUT)
        InterfaceClass.CDC_DATA,
        0x00,
        0x00,
        0,
    );
    const cdc_data_in_ep = genericEndpointDescriptor(
        CDC_DATA_ENDPOINT | EndpointDirection.IN,
        EndpointTransfer.BULK,
        CDC_DATA_ENDPOINT_SIZE,
        0, // bulk endpoints don't use interval
    );
    const cdc_data_out_ep = genericEndpointDescriptor(
        CDC_DATA_ENDPOINT | EndpointDirection.OUT,
        EndpointTransfer.BULK,
        CDC_DATA_ENDPOINT_SIZE,
        0,
    );

    const total_len: u16 = 9 + // Config header
        keyboard_iface.len + keyboard_hid.len + keyboard_ep.len +
        mouse_iface.len + mouse_hid.len + mouse_ep.len +
        extra_iface.len + extra_hid.len + extra_ep.len +
        cdc_iad.len + cdc_comm_iface.len +
        cdc_header.len + cdc_call_mgmt.len + cdc_acm.len + cdc_union.len +
        cdc_notification_ep.len +
        cdc_data_iface.len + cdc_data_in_ep.len + cdc_data_out_ep.len;

    const config_header = [9]u8{
        9, // bLength
        DescriptorType.CONFIGURATION, // bDescriptorType
        @truncate(total_len), @truncate(total_len >> 8), // wTotalLength
        NUM_INTERFACES, // bNumInterfaces
        1, // bConfigurationValue
        0, // iConfiguration
        0xA0, // bmAttributes (bus-powered, remote wakeup)
        250, // bMaxPower (500mA)
    };

    break :blk config_header ++
        keyboard_iface ++ keyboard_hid ++ keyboard_ep ++
        mouse_iface ++ mouse_hid ++ mouse_ep ++
        extra_iface ++ extra_hid ++ extra_ep ++
        cdc_iad ++ cdc_comm_iface ++
        cdc_header ++ cdc_call_mgmt ++ cdc_acm ++ cdc_union ++
        cdc_notification_ep ++
        cdc_data_iface ++ cdc_data_in_ep ++ cdc_data_out_ep;
};

// ============================================================
// String Descriptors
// ============================================================

/// Convert ASCII string to USB string descriptor (UTF-16LE) at comptime
fn stringDescriptor(comptime str: []const u8) [2 + str.len * 2]u8 {
    const len = 2 + str.len * 2;
    var desc: [len]u8 = undefined;
    desc[0] = @intCast(len);
    desc[1] = DescriptorType.STRING;
    for (str, 0..) |c, i| {
        desc[2 + i * 2] = c;
        desc[2 + i * 2 + 1] = 0;
    }
    return desc;
}

/// Language descriptor (English US)
pub const string_descriptor_0 = [4]u8{
    4, // bLength
    DescriptorType.STRING, // bDescriptorType
    0x09, 0x04, // wLANGID (English US)
};

pub const string_descriptor_manufacturer = stringDescriptor(kb.manufacturer);
pub const string_descriptor_product = stringDescriptor(kb.name);
pub const string_descriptor_serial = stringDescriptor("000000000000");

// ============================================================
// Individual HID Descriptors (for GET_DESCRIPTOR HID type 0x21)
// ============================================================

pub const keyboard_hid_descriptor = hidDescriptor(keyboard_report_descriptor.len);
pub const mouse_hid_descriptor = hidDescriptor(mouse_report_descriptor.len);
pub const extra_hid_descriptor = hidDescriptor(extra_report_descriptor.len);

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "device descriptor length" {
    try testing.expectEqual(@as(usize, 18), device_descriptor.len);
    try testing.expectEqual(@as(u8, 18), device_descriptor[0]); // bLength field matches
}

test "device descriptor type" {
    try testing.expectEqual(DescriptorType.DEVICE, device_descriptor[1]);
}

test "device descriptor VID/PID" {
    const vid = @as(u16, device_descriptor[9]) << 8 | device_descriptor[8];
    const pid = @as(u16, device_descriptor[11]) << 8 | device_descriptor[10];
    try testing.expectEqual(USB_VID, vid);
    try testing.expectEqual(USB_PID, pid);
}

test "device descriptor uses IAD class for composite device" {
    try testing.expectEqual(DeviceClass.MISC, device_descriptor[4]); // bDeviceClass
    try testing.expectEqual(@as(u8, 0x02), device_descriptor[5]); // bDeviceSubClass
    try testing.expectEqual(@as(u8, 0x01), device_descriptor[6]); // bDeviceProtocol
}

test "configuration descriptor total length" {
    const total_len = @as(u16, configuration_descriptor[3]) << 8 | configuration_descriptor[2];
    try testing.expectEqual(@as(u16, @intCast(configuration_descriptor.len)), total_len);
}

test "configuration descriptor type" {
    try testing.expectEqual(DescriptorType.CONFIGURATION, configuration_descriptor[1]);
}

test "configuration descriptor num interfaces" {
    try testing.expectEqual(NUM_INTERFACES, configuration_descriptor[4]);
}

test "keyboard report descriptor size" {
    // Boot protocol keyboard descriptor should be reasonable size
    try testing.expect(keyboard_report_descriptor.len > 0);
    try testing.expect(keyboard_report_descriptor.len < 256);
}

test "mouse report descriptor size" {
    try testing.expect(mouse_report_descriptor.len > 0);
    try testing.expect(mouse_report_descriptor.len < 256);
}

test "extra report descriptor size" {
    try testing.expect(extra_report_descriptor.len > 0);
    try testing.expect(extra_report_descriptor.len < 256);
}

test "string descriptor format" {
    // Language descriptor
    try testing.expectEqual(@as(u8, 4), string_descriptor_0[0]); // bLength
    try testing.expectEqual(DescriptorType.STRING, string_descriptor_0[1]);

    // Manufacturer string
    try testing.expectEqual(DescriptorType.STRING, string_descriptor_manufacturer[1]);
    try testing.expectEqual(@as(u8, string_descriptor_manufacturer.len), string_descriptor_manufacturer[0]);

    // First char should be manufacturer name's first char in UTF-16LE
    try testing.expectEqual(kb.manufacturer[0], string_descriptor_manufacturer[2]);
    try testing.expectEqual(@as(u8, 0), string_descriptor_manufacturer[3]);
}

test "string descriptors match keyboard definition" {
    // Manufacturer string length: 2 (header) + manufacturer.len * 2 (UTF-16LE)
    try testing.expectEqual(@as(usize, 2 + kb.manufacturer.len * 2), string_descriptor_manufacturer.len);

    // Product string length: 2 (header) + name.len * 2 (UTF-16LE)
    try testing.expectEqual(@as(usize, 2 + kb.name.len * 2), string_descriptor_product.len);
}

test "configuration descriptor contains IAD for CDC" {
    var found_iad = false;
    var i: usize = 0;
    while (i < configuration_descriptor.len) {
        const len = configuration_descriptor[i];
        if (len == 0) break;
        if (i + 1 < configuration_descriptor.len and
            configuration_descriptor[i + 1] == DescriptorType.INTERFACE_ASSOCIATION)
        {
            found_iad = true;
            try testing.expectEqual(@as(u8, 8), len);
            try testing.expectEqual(CDC_COMM_INTERFACE, configuration_descriptor[i + 2]);
            try testing.expectEqual(@as(u8, 2), configuration_descriptor[i + 3]);
            try testing.expectEqual(InterfaceClass.CDC, configuration_descriptor[i + 4]);
            break;
        }
        i += len;
    }
    try testing.expect(found_iad);
}

test "configuration descriptor contains CDC functional descriptors" {
    var cs_count: u8 = 0;
    var i: usize = 0;
    while (i < configuration_descriptor.len) {
        const len = configuration_descriptor[i];
        if (len == 0) break;
        if (i + 1 < configuration_descriptor.len and
            configuration_descriptor[i + 1] == DescriptorType.CS_INTERFACE)
        {
            cs_count += 1;
        }
        i += len;
    }
    // Header, Call Management, ACM, Union = 4
    try testing.expectEqual(@as(u8, 4), cs_count);
}

test "CDC endpoint descriptors are present" {
    var ep_count: u8 = 0;
    var found_bulk_in = false;
    var found_bulk_out = false;
    var found_interrupt_in = false;
    var i: usize = 0;
    while (i < configuration_descriptor.len) {
        const len = configuration_descriptor[i];
        if (len == 0) break;
        if (i + 1 < configuration_descriptor.len and
            configuration_descriptor[i + 1] == DescriptorType.ENDPOINT)
        {
            ep_count += 1;
            const addr = configuration_descriptor[i + 2];
            const attr = configuration_descriptor[i + 3];
            if (addr == (CDC_NOTIFICATION_ENDPOINT | EndpointDirection.IN) and
                attr == EndpointTransfer.INTERRUPT)
            {
                found_interrupt_in = true;
            }
            if (addr == (CDC_DATA_ENDPOINT | EndpointDirection.IN) and
                attr == EndpointTransfer.BULK)
            {
                found_bulk_in = true;
            }
            if (addr == (CDC_DATA_ENDPOINT | EndpointDirection.OUT) and
                attr == EndpointTransfer.BULK)
            {
                found_bulk_out = true;
            }
        }
        i += len;
    }
    // 3 HID + 3 CDC = 6
    try testing.expectEqual(@as(u8, 6), ep_count);
    try testing.expect(found_interrupt_in);
    try testing.expect(found_bulk_in);
    try testing.expect(found_bulk_out);
}

test "LineCoding size" {
    try testing.expectEqual(@as(usize, 7), @sizeOf(LineCoding));
}

test "configuration descriptor enables remote wakeup" {
    // bmAttributes byte at offset 7 of configuration descriptor
    // Bit 5 = Remote Wakeup
    const bmAttributes = configuration_descriptor[7];
    try testing.expectEqual(@as(u8, 0xA0), bmAttributes);
    try testing.expect(bmAttributes & 0x20 != 0); // Remote Wakeup bit set
}

test "individual HID descriptors exist and have correct type" {
    // HID descriptor type = 0x21
    try testing.expectEqual(@as(u8, DescriptorType.HID), keyboard_hid_descriptor[1]);
    try testing.expectEqual(@as(u8, DescriptorType.HID), mouse_hid_descriptor[1]);
    try testing.expectEqual(@as(u8, DescriptorType.HID), extra_hid_descriptor[1]);
}

test "individual HID descriptor report lengths match report descriptors" {
    // HID descriptor: byte 7-8 = wDescriptorLength (report descriptor size, little-endian)
    const kb_len = @as(u16, keyboard_hid_descriptor[8]) << 8 | keyboard_hid_descriptor[7];
    try testing.expectEqual(@as(u16, keyboard_report_descriptor.len), kb_len);

    const mouse_len = @as(u16, mouse_hid_descriptor[8]) << 8 | mouse_hid_descriptor[7];
    try testing.expectEqual(@as(u16, mouse_report_descriptor.len), mouse_len);

    const extra_len = @as(u16, extra_hid_descriptor[8]) << 8 | extra_hid_descriptor[7];
    try testing.expectEqual(@as(u16, extra_report_descriptor.len), extra_len);
}

test "mouse report descriptor has 8 buttons" {
    // Search for Usage Maximum in mouse report descriptor
    // Usage Maximum (8) = 0x29, 0x08
    var found_8_buttons = false;
    var i: usize = 0;
    while (i < mouse_report_descriptor.len - 1) : (i += 1) {
        if (mouse_report_descriptor[i] == 0x29) { // Usage Maximum tag
            if (mouse_report_descriptor[i + 1] == 8) {
                found_8_buttons = true;
                break;
            }
        }
    }
    try testing.expect(found_8_buttons);
}

test "keyboard report descriptor padding uses CONST not CONST_VAR_ABS" {
    // Input(Const) = 0x81, 0x01
    // Input(Const,Var,Abs) = 0x81, 0x03
    // Search for reserved byte padding in keyboard report descriptor
    var found_const = false;
    var i: usize = 0;
    while (i < keyboard_report_descriptor.len - 1) : (i += 1) {
        if (keyboard_report_descriptor[i] == 0x81) { // Input tag
            if (keyboard_report_descriptor[i + 1] == 0x01) { // CONST
                found_const = true;
                break;
            }
        }
    }
    try testing.expect(found_const);
}
