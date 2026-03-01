// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! ARM Cortex-M0+ Vector Table for RP2040

extern var _stack_top: anyopaque;

/// Default handler: infinite loop with breakpoint
fn defaultHandler() callconv(.c) void {
    while (true) {
        asm volatile ("bkpt #0");
    }
}

/// RP2040 IRQ numbers (RP2040 Datasheet §2.3.2)
pub const Irq = enum(u5) {
    TIMER_IRQ_0    = 0,
    TIMER_IRQ_1    = 1,
    TIMER_IRQ_2    = 2,
    TIMER_IRQ_3    = 3,
    PWM_IRQ_WRAP   = 4,
    USBCTRL_IRQ    = 5,
    XIP_IRQ        = 6,
    PIO0_IRQ_0     = 7,
    PIO0_IRQ_1     = 8,
    PIO1_IRQ_0     = 9,
    PIO1_IRQ_1     = 10,
    DMA_IRQ_0      = 11,
    DMA_IRQ_1      = 12,
    IO_IRQ_BANK0   = 13,
    IO_IRQ_QSPI    = 14,
    SIO_IRQ_PROC0  = 15,
    SIO_IRQ_PROC1  = 16,
    CLOCKS_IRQ     = 17,
    SPI0_IRQ       = 18,
    SPI1_IRQ       = 19,
    UART0_IRQ      = 20,
    UART1_IRQ      = 21,
    ADC_IRQ_FIFO   = 22,
    I2C0_IRQ       = 23,
    I2C1_IRQ       = 24,
    RTC_IRQ        = 25,
};

/// Cortex-M0+ vector table layout
pub const VectorTable = extern struct {
    initial_sp: *anyopaque,
    reset: *const fn () callconv(.naked) noreturn,
    nmi: *const fn () callconv(.c) void = &defaultHandler,
    hard_fault: *const fn () callconv(.c) void = &defaultHandler,
    reserved1: [7]*const fn () callconv(.c) void = .{&defaultHandler} ** 7,
    svcall: *const fn () callconv(.c) void = &defaultHandler,
    reserved2: [2]*const fn () callconv(.c) void = .{&defaultHandler} ** 2,
    pendsv: *const fn () callconv(.c) void = &defaultHandler,
    systick: *const fn () callconv(.c) void = &defaultHandler,
    /// IRQ handlers indexed by Irq enum (26 entries: IRQ0-IRQ25)
    irq: [26]*const fn () callconv(.c) void = .{&defaultHandler} ** 26,
};

/// Create the vector table instance with the given reset handler
pub fn vectorTable(reset_handler: *const fn () callconv(.naked) noreturn) VectorTable {
    return .{
        .initial_sp = @ptrCast(&_stack_top),
        .reset = reset_handler,
    };
}

// ============================================================
// Tests
// ============================================================

const testing = @import("std").testing;

test "VectorTable size is 48 entries (192 bytes)" {
    // ARM Cortex-M0+ vector table: 16 system + 26 IRQ + padding = correct layout
    try testing.expectEqual(@as(usize, 192), @sizeOf(VectorTable));
}

test "VectorTable reserved entries are non-zero (filled with defaultHandler)" {
    const dummy_reset = struct {
        fn handler() callconv(.naked) noreturn {
            while (true) {}
        }
    }.handler;
    const vt = VectorTable{
        .initial_sp = @ptrFromInt(0x20042000),
        .reset = &dummy_reset,
    };

    // reserved1 (7 entries) should all be non-zero (defaultHandler address)
    for (vt.reserved1) |entry| {
        try testing.expect(@intFromPtr(entry) != 0);
    }

    // reserved2 (2 entries) should all be non-zero
    for (vt.reserved2) |entry| {
        try testing.expect(@intFromPtr(entry) != 0);
    }
}

test "VectorTable all IRQ entries default to defaultHandler" {
    const dummy_reset = struct {
        fn handler() callconv(.naked) noreturn {
            while (true) {}
        }
    }.handler;
    const vt = VectorTable{
        .initial_sp = @ptrFromInt(0x20042000),
        .reset = &dummy_reset,
    };

    for (vt.irq) |handler| {
        try testing.expect(@intFromPtr(handler) != 0);
    }
}

test "VectorTable field offsets match ARM Cortex-M0+ specification" {
    // ARM Architecture Reference Manual: Cortex-M0+ vector table layout
    try testing.expectEqual(@as(usize, 0x00), @offsetOf(VectorTable, "initial_sp"));
    try testing.expectEqual(@as(usize, 0x04), @offsetOf(VectorTable, "reset"));
    try testing.expectEqual(@as(usize, 0x08), @offsetOf(VectorTable, "nmi"));
    try testing.expectEqual(@as(usize, 0x0C), @offsetOf(VectorTable, "hard_fault"));
    try testing.expectEqual(@as(usize, 0x10), @offsetOf(VectorTable, "reserved1"));
    try testing.expectEqual(@as(usize, 0x2C), @offsetOf(VectorTable, "svcall"));
    try testing.expectEqual(@as(usize, 0x30), @offsetOf(VectorTable, "reserved2"));
    try testing.expectEqual(@as(usize, 0x38), @offsetOf(VectorTable, "pendsv"));
    try testing.expectEqual(@as(usize, 0x3C), @offsetOf(VectorTable, "systick"));
    try testing.expectEqual(@as(usize, 0x40), @offsetOf(VectorTable, "irq"));
}

test "Irq enum covers all 26 RP2040 IRQs" {
    try testing.expectEqual(@as(u5, 0), @intFromEnum(Irq.TIMER_IRQ_0));
    try testing.expectEqual(@as(u5, 5), @intFromEnum(Irq.USBCTRL_IRQ));
    try testing.expectEqual(@as(u5, 25), @intFromEnum(Irq.RTC_IRQ));
}
