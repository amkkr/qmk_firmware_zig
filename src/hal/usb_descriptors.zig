//! USB and HID descriptor definitions
//! Based on tmk_core/protocol/usb_descriptor.c and usb_descriptor.h
//!
//! Defines all USB descriptors needed for a HID keyboard device:
//! device, configuration, interface, HID, endpoint, and report descriptors.

const std = @import("std");

// ============================================================
// USB Descriptor Type Constants
// ============================================================

pub const DescriptorType = struct {
    pub const DEVICE: u8 = 0x01;
    pub const CONFIGURATION: u8 = 0x02;
    pub const STRING: u8 = 0x03;
    pub const INTERFACE: u8 = 0x04;
    pub const ENDPOINT: u8 = 0x05;
    pub const HID: u8 = 0x21;
    pub const HID_REPORT: u8 = 0x22;
};

pub const DeviceClass = struct {
    pub const PER_INTERFACE: u8 = 0x00;
};

pub const InterfaceClass = struct {
    pub const HID: u8 = 0x03;
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
};

pub const EndpointTransfer = struct {
    pub const INTERRUPT: u8 = 0x03;
};

// ============================================================
// USB IDs and Version
// ============================================================

pub const USB_VID: u16 = 0xFEED;
pub const USB_PID: u16 = 0x6060;
pub const DEVICE_VERSION: u16 = 0x0001;

// ============================================================
// Interface and Endpoint Numbers
// ============================================================

pub const KEYBOARD_INTERFACE: u8 = 0;
pub const MOUSE_INTERFACE: u8 = 1;
pub const EXTRA_INTERFACE: u8 = 2;
pub const NUM_INTERFACES: u8 = 3;

pub const KEYBOARD_ENDPOINT: u8 = 1;
pub const MOUSE_ENDPOINT: u8 = 2;
pub const EXTRA_ENDPOINT: u8 = 3;

pub const KEYBOARD_ENDPOINT_SIZE: u8 = 8;
pub const MOUSE_ENDPOINT_SIZE: u8 = 8;
pub const EXTRA_ENDPOINT_SIZE: u8 = 8;

pub const KEYBOARD_INTERVAL: u8 = 10; // ms
pub const MOUSE_INTERVAL: u8 = 10;
pub const EXTRA_INTERVAL: u8 = 10;

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
const CONST_VAR_ABS: u8 = 0x03; // Constant, Variable, Absolute
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
        hidInput(CONST_VAR_ABS) ++

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
        hidOutput(CONST_VAR_ABS) ++

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

        // --- Buttons (5 buttons) ---
        hidUsagePage(0x09) ++ // Buttons
        hidUsageMin(1) ++
        hidUsageMax(5) ++
        hidLogicalMin(0) ++
        hidLogicalMax(1) ++
        hidReportCount(5) ++
        hidReportSize(1) ++
        hidInput(DATA_VAR_ABS) ++
        // Padding (3 bits)
        hidReportCount(1) ++
        hidReportSize(3) ++
        hidInput(CONST_VAR_ABS) ++

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
        hidUsage(0x38) ++ // AC Pan (mapped to 0x238 in some implementations)
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
        hidInput(CONST_VAR_ABS) ++
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
    DeviceClass.PER_INTERFACE, // bDeviceClass
    0x00, // bDeviceSubClass
    0x00, // bDeviceProtocol
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

    const total_len: u16 = 9 + // Config header
        keyboard_iface.len + keyboard_hid.len + keyboard_ep.len +
        mouse_iface.len + mouse_hid.len + mouse_ep.len +
        extra_iface.len + extra_hid.len + extra_ep.len;

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
        extra_iface ++ extra_hid ++ extra_ep;
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

pub const string_descriptor_manufacturer = stringDescriptor("QMK");
pub const string_descriptor_product = stringDescriptor("QMK Keyboard");
pub const string_descriptor_serial = stringDescriptor("000000000000");

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

    // First char should be 'Q' in UTF-16LE
    try testing.expectEqual(@as(u8, 'Q'), string_descriptor_manufacturer[2]);
    try testing.expectEqual(@as(u8, 0), string_descriptor_manufacturer[3]);
}
