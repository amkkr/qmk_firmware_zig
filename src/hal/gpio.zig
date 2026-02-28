// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! GPIO driver for RP2040
//! Based on platforms/chibios/gpio.h
//!
//! Provides platform-abstracted GPIO interface.
//! On real hardware: direct RP2040 register access.
//! In tests: mock implementation.

const std = @import("std");
const builtin = @import("builtin");

const is_freestanding = builtin.os.tag == .freestanding;

/// RP2040 GPIO pin (GP0-GP29)
pub const Pin = u5;

/// Pin direction
pub const Direction = enum {
    input,
    output,
};

/// Pull configuration
pub const Pull = enum {
    none,
    up,
    down,
};

// ============================================================
// RP2040 Register definitions (freestanding only)
// ============================================================

const rp2040 = if (is_freestanding) struct {
    const IO_BANK0_BASE: u32 = 0x40014000;
    const PADS_BANK0_BASE: u32 = 0x4001C000;
    const SIO_BASE: u32 = 0xD0000000;

    // SIO registers (single-cycle I/O)
    const GPIO_OUT_SET: *volatile u32 = @ptrFromInt(SIO_BASE + 0x014);
    const GPIO_OUT_CLR: *volatile u32 = @ptrFromInt(SIO_BASE + 0x018);
    const GPIO_OE_SET: *volatile u32 = @ptrFromInt(SIO_BASE + 0x024);
    const GPIO_OE_CLR: *volatile u32 = @ptrFromInt(SIO_BASE + 0x028);
    const GPIO_IN: *volatile u32 = @ptrFromInt(SIO_BASE + 0x004);

    inline fn gpioCtrlAddr(pin: Pin) *volatile u32 {
        return @ptrFromInt(IO_BANK0_BASE + 0x004 + @as(u32, pin) * 8);
    }

    inline fn padCtrlAddr(pin: Pin) *volatile u32 {
        return @ptrFromInt(PADS_BANK0_BASE + 0x004 + @as(u32, pin) * 4);
    }
} else struct {};

// ============================================================
// Mock state (for tests)
// ============================================================

var mock_pin_values: u32 = 0;
var mock_pin_directions: u32 = 0; // 1 = output
var mock_pin_pulls: u32 = 0; // 1 = pull-up enabled

// ============================================================
// Public GPIO API
// ============================================================

/// Set pin as output
pub fn setPinOutput(pin: Pin) void {
    std.debug.assert(pin <= 29); // RP2040 has GP0-GP29 only
    if (is_freestanding) {
        // Set function to SIO (function 5)
        rp2040.gpioCtrlAddr(pin).* = 5;
        // Enable output
        rp2040.GPIO_OE_SET.* = @as(u32, 1) << pin;
    } else {
        mock_pin_directions |= @as(u32, 1) << pin;
    }
}

/// Set pin as input (no pull)
pub fn setPinInput(pin: Pin) void {
    std.debug.assert(pin <= 29); // RP2040 has GP0-GP29 only
    if (is_freestanding) {
        rp2040.gpioCtrlAddr(pin).* = 5;
        rp2040.GPIO_OE_CLR.* = @as(u32, 1) << pin;
        // IE=1, DRIVE=4mA, SCHMITT=1, PUE=0, PDE=0
        rp2040.padCtrlAddr(pin).* = 0x52;
    } else {
        mock_pin_directions &= ~(@as(u32, 1) << pin);
        mock_pin_pulls &= ~(@as(u32, 1) << pin);
    }
}

/// Set pin as input with internal pull-up
pub fn setPinInputHigh(pin: Pin) void {
    std.debug.assert(pin <= 29); // RP2040 has GP0-GP29 only
    if (is_freestanding) {
        rp2040.gpioCtrlAddr(pin).* = 5;
        rp2040.GPIO_OE_CLR.* = @as(u32, 1) << pin;
        // IE=1, PUE=1, PDE=0, SCHMITT=1
        rp2040.padCtrlAddr(pin).* = 0x4A;
    } else {
        mock_pin_directions &= ~(@as(u32, 1) << pin);
        mock_pin_pulls |= @as(u32, 1) << pin;
    }
}

/// Write pin high
pub fn writePinHigh(pin: Pin) void {
    std.debug.assert(pin <= 29); // RP2040 has GP0-GP29 only
    if (is_freestanding) {
        rp2040.GPIO_OUT_SET.* = @as(u32, 1) << pin;
    } else {
        mock_pin_values |= @as(u32, 1) << pin;
    }
}

/// Write pin low
pub fn writePinLow(pin: Pin) void {
    std.debug.assert(pin <= 29); // RP2040 has GP0-GP29 only
    if (is_freestanding) {
        rp2040.GPIO_OUT_CLR.* = @as(u32, 1) << pin;
    } else {
        mock_pin_values &= ~(@as(u32, 1) << pin);
    }
}

/// Read pin value
pub fn readPin(pin: Pin) bool {
    std.debug.assert(pin <= 29); // RP2040 has GP0-GP29 only
    if (is_freestanding) {
        return (rp2040.GPIO_IN.* & (@as(u32, 1) << pin)) != 0;
    } else {
        return (mock_pin_values & (@as(u32, 1) << pin)) != 0;
    }
}

// ============================================================
// Mock helpers (test only)
// ============================================================

/// Set mock pin input value (simulates external signal, test only)
pub fn mockSetPin(pin: Pin, value: bool) void {
    if (value) {
        mock_pin_values |= @as(u32, 1) << pin;
    } else {
        mock_pin_values &= ~(@as(u32, 1) << pin);
    }
}

/// Reset all mock state (test only)
pub fn mockReset() void {
    mock_pin_values = 0;
    mock_pin_directions = 0;
    mock_pin_pulls = 0;
}

/// Check if pin is configured as output (mock, test only)
pub fn mockIsOutput(pin: Pin) bool {
    return (mock_pin_directions & (@as(u32, 1) << pin)) != 0;
}

/// Check if pin has pull-up enabled (mock, test only)
pub fn mockHasPullUp(pin: Pin) bool {
    return (mock_pin_pulls & (@as(u32, 1) << pin)) != 0;
}

// ============================================================
// Tests
// ============================================================

test "GPIO set pin output" {
    mockReset();
    setPinOutput(8);
    try std.testing.expect(mockIsOutput(8));
}

test "GPIO set pin input high" {
    mockReset();
    setPinInputHigh(14);
    try std.testing.expect(!mockIsOutput(14));
    try std.testing.expect(mockHasPullUp(14));
}

test "GPIO write and read" {
    mockReset();
    setPinOutput(8);
    writePinLow(8);
    try std.testing.expect(!readPin(8));
    writePinHigh(8);
    try std.testing.expect(readPin(8));
}

test "GPIO mock external input" {
    mockReset();
    setPinInput(14);
    try std.testing.expect(!readPin(14));
    mockSetPin(14, true);
    try std.testing.expect(readPin(14));
}
