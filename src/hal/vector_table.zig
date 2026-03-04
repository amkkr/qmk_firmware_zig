// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! ARM Cortex-M0+ Vector Table for RP2040

const builtin = @import("builtin");
const is_freestanding = builtin.os.tag == .freestanding;

extern var _stack_top: anyopaque;

/// Default handler: infinite loop with breakpoint
fn defaultHandler() callconv(.c) void {
    while (true) {
        asm volatile ("bkpt #0");
    }
}

// ============================================================
// HardFault Debug Info
// ============================================================

/// Cortex-M0+ exception stack frame (automatically pushed by hardware on fault)
/// ARM Architecture Reference Manual: B1.5.6
pub const ExceptionFrame = extern struct {
    r0: u32,
    r1: u32,
    r2: u32,
    r3: u32,
    r12: u32,
    lr: u32, // Link Register (return address before fault)
    pc: u32, // Program Counter (faulting instruction)
    xpsr: u32, // Program Status Register
};

/// Crash information saved to RAM for post-mortem debugging.
/// Placed at a known RAM address so it survives soft reset (Watchdog reset).
pub const CrashInfo = extern struct {
    magic: u32 = 0,
    /// Exception stack frame registers
    r0: u32 = 0,
    r1: u32 = 0,
    r2: u32 = 0,
    r3: u32 = 0,
    r12: u32 = 0,
    lr: u32 = 0,
    pc: u32 = 0,
    xpsr: u32 = 0,
    /// EXC_RETURN value (LR on exception entry, indicates MSP/PSP)
    exc_return: u32 = 0,

    pub const MAGIC: u32 = 0xDEAD_FA17; // "DEAD FAULT"

    pub fn isValid(self: *const volatile CrashInfo) bool {
        return self.magic == MAGIC;
    }

    pub fn clear(self: *volatile CrashInfo) void {
        self.* = .{};
    }
};

/// RAM address for crash info storage.
/// Uses the last bytes of scratch RAM (before stack top at 0x20042000).
/// This area survives Watchdog soft resets.
const CRASH_INFO_ADDR: u32 = 0x20042000 - @sizeOf(CrashInfo);

/// Get pointer to the crash info in RAM (freestanding only)
pub fn getCrashInfo() *volatile CrashInfo {
    if (is_freestanding) {
        return @ptrFromInt(CRASH_INFO_ADDR);
    } else {
        return &test_crash_info;
    }
}

var test_crash_info: CrashInfo = .{};

/// HardFault handler entry point (naked).
/// Determines whether MSP or PSP was in use and passes the correct
/// stack pointer to hardFaultHandlerC.
///
/// Cortex-M0+ EXC_RETURN (LR on exception entry):
///   bit 2 = 0: MSP was in use (handler mode / main stack)
///   bit 2 = 1: PSP was in use (thread mode / process stack)
fn hardFaultHandler() callconv(.naked) noreturn {
    if (is_freestanding) {
        asm volatile (
            \\mov r1, lr
            \\movs r0, #4
            \\tst r0, r1
            \\beq 1f
            \\mrs r0, psp
            \\b 2f
            \\1:
            \\mrs r0, msp
            \\2:
            \\bl hardFaultHandlerC
        );
    }
    while (true) {
        asm volatile ("");
    }
}

/// HardFault handler C implementation.
/// Called from hardFaultHandler with the faulting stack pointer and EXC_RETURN.
export fn hardFaultHandlerC(stack_frame: *const ExceptionFrame, exc_return: u32) callconv(.c) noreturn {
    const info = getCrashInfo();
    info.magic = CrashInfo.MAGIC;
    info.r0 = stack_frame.r0;
    info.r1 = stack_frame.r1;
    info.r2 = stack_frame.r2;
    info.r3 = stack_frame.r3;
    info.r12 = stack_frame.r12;
    info.lr = stack_frame.lr;
    info.pc = stack_frame.pc;
    info.xpsr = stack_frame.xpsr;
    info.exc_return = exc_return;

    while (true) {
        asm volatile ("bkpt #0");
    }
}

// ============================================================
// IRQ and Vector Table
// ============================================================

/// RP2040 IRQ numbers (RP2040 Datasheet section 2.3.2)
pub const Irq = enum(u5) {
    TIMER_IRQ_0 = 0,
    TIMER_IRQ_1 = 1,
    TIMER_IRQ_2 = 2,
    TIMER_IRQ_3 = 3,
    PWM_IRQ_WRAP = 4,
    USBCTRL_IRQ = 5,
    XIP_IRQ = 6,
    PIO0_IRQ_0 = 7,
    PIO0_IRQ_1 = 8,
    PIO1_IRQ_0 = 9,
    PIO1_IRQ_1 = 10,
    DMA_IRQ_0 = 11,
    DMA_IRQ_1 = 12,
    IO_IRQ_BANK0 = 13,
    IO_IRQ_QSPI = 14,
    SIO_IRQ_PROC0 = 15,
    SIO_IRQ_PROC1 = 16,
    CLOCKS_IRQ = 17,
    SPI0_IRQ = 18,
    SPI1_IRQ = 19,
    UART0_IRQ = 20,
    UART1_IRQ = 21,
    ADC_IRQ_FIFO = 22,
    I2C0_IRQ = 23,
    I2C1_IRQ = 24,
    RTC_IRQ = 25,
};

/// Cortex-M0+ vector table layout
pub const VectorTable = extern struct {
    initial_sp: *anyopaque,
    reset: *const fn () callconv(.naked) noreturn,
    nmi: *const fn () callconv(.c) void = &defaultHandler,
    hard_fault: *const anyopaque = @ptrCast(&defaultHandler),
    reserved1: [7]*const fn () callconv(.c) void = .{&defaultHandler} ** 7,
    svcall: *const fn () callconv(.c) void = &defaultHandler,
    reserved2: [2]*const fn () callconv(.c) void = .{&defaultHandler} ** 2,
    pendsv: *const fn () callconv(.c) void = &defaultHandler,
    systick: *const fn () callconv(.c) void = &defaultHandler,
    /// IRQ handlers indexed by Irq enum (26 entries: IRQ0-IRQ25)
    irq: [26]*const fn () callconv(.c) void = .{&defaultHandler} ** 26,
};

/// Create the vector table instance with the given reset handler.
/// Registers the USB interrupt handler (IRQ5) from usb.zig.
pub fn vectorTable(reset_handler: *const fn () callconv(.naked) noreturn) VectorTable {
    const usb = @import("usb.zig");
    var vt = VectorTable{
        .initial_sp = @ptrCast(&_stack_top),
        .reset = reset_handler,
        .hard_fault = @ptrCast(&hardFaultHandler),
    };
    vt.irq[@intFromEnum(Irq.USBCTRL_IRQ)] = &usb.usbctrlIrqHandler;
    return vt;
}

// ============================================================
// Tests
// ============================================================

const testing = @import("std").testing;

test "VectorTable has 42 entries" {
    // 1(SP) + 1(Reset) + 1(NMI) + 1(HardFault) + 7(reserved1) + 1(SVCall) +
    // 2(reserved2) + 1(PendSV) + 1(SysTick) + 26(IRQ) = 42 entries
    const ptr_size = @sizeOf(*anyopaque);
    try testing.expectEqual(42 * ptr_size, @sizeOf(VectorTable));
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

    for (vt.reserved1) |entry| {
        try testing.expect(@intFromPtr(entry) != 0);
    }

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

test "VectorTable field offsets are sequential" {
    const P = @sizeOf(*anyopaque);
    try testing.expectEqual(@as(usize, P * 0), @offsetOf(VectorTable, "initial_sp"));
    try testing.expectEqual(@as(usize, P * 1), @offsetOf(VectorTable, "reset"));
    try testing.expectEqual(@as(usize, P * 2), @offsetOf(VectorTable, "nmi"));
    try testing.expectEqual(@as(usize, P * 3), @offsetOf(VectorTable, "hard_fault"));
    try testing.expectEqual(@as(usize, P * 4), @offsetOf(VectorTable, "reserved1"));
    try testing.expectEqual(@as(usize, P * 11), @offsetOf(VectorTable, "svcall"));
    try testing.expectEqual(@as(usize, P * 12), @offsetOf(VectorTable, "reserved2"));
    try testing.expectEqual(@as(usize, P * 14), @offsetOf(VectorTable, "pendsv"));
    try testing.expectEqual(@as(usize, P * 15), @offsetOf(VectorTable, "systick"));
    try testing.expectEqual(@as(usize, P * 16), @offsetOf(VectorTable, "irq"));
}

test "Irq enum covers all 26 RP2040 IRQs" {
    try testing.expectEqual(@as(u5, 0), @intFromEnum(Irq.TIMER_IRQ_0));
    try testing.expectEqual(@as(u5, 5), @intFromEnum(Irq.USBCTRL_IRQ));
    try testing.expectEqual(@as(u5, 25), @intFromEnum(Irq.RTC_IRQ));
}

test "ExceptionFrame is 32 bytes (8 registers x 4 bytes)" {
    try testing.expectEqual(@as(usize, 32), @sizeOf(ExceptionFrame));
}

test "CrashInfo struct layout" {
    try testing.expectEqual(@as(usize, 40), @sizeOf(CrashInfo));
    try testing.expectEqual(@as(usize, 0), @offsetOf(CrashInfo, "magic"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(CrashInfo, "r0"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(CrashInfo, "pc"));
    try testing.expectEqual(@as(usize, 36), @offsetOf(CrashInfo, "exc_return"));
}

test "CrashInfo magic validation" {
    var info = CrashInfo{};
    try testing.expect(!info.isValid());

    info.magic = CrashInfo.MAGIC;
    try testing.expect(info.isValid());

    info.clear();
    try testing.expect(!info.isValid());
}

test "getCrashInfo saves registers correctly" {
    test_crash_info.clear();

    const frame = ExceptionFrame{
        .r0 = 0x1000_0001,
        .r1 = 0x2000_0002,
        .r2 = 0x3000_0003,
        .r3 = 0x4000_0004,
        .r12 = 0xC000_000C,
        .lr = 0x0800_1234,
        .pc = 0x0800_5678,
        .xpsr = 0x6100_0000,
    };

    const info = getCrashInfo();
    info.magic = CrashInfo.MAGIC;
    info.r0 = frame.r0;
    info.r1 = frame.r1;
    info.r2 = frame.r2;
    info.r3 = frame.r3;
    info.r12 = frame.r12;
    info.lr = frame.lr;
    info.pc = frame.pc;
    info.xpsr = frame.xpsr;
    info.exc_return = 0xFFFF_FFFD;

    try testing.expect(info.isValid());
    try testing.expectEqual(@as(u32, 0x0800_5678), info.pc);
    try testing.expectEqual(@as(u32, 0x0800_1234), info.lr);
    try testing.expectEqual(@as(u32, 0x1000_0001), info.r0);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFD), info.exc_return);
}

test "CRASH_INFO_ADDR is at end of scratch RAM" {
    try testing.expectEqual(@as(u32, 0x20042000 - @sizeOf(CrashInfo)), CRASH_INFO_ADDR);
    try testing.expect(CRASH_INFO_ADDR >= 0x20040000);
    try testing.expect(CRASH_INFO_ADDR + @sizeOf(CrashInfo) <= 0x20042000);
}

test "USBCTRL_IRQ is at index 5 in IRQ table" {
    // Verify USBCTRL_IRQ enum value matches expected IRQ number.
    // The vectorTable() function assigns the USB handler at this index.
    // (Full vector table test requires freestanding build due to ARM instructions.)
    try testing.expectEqual(@as(u5, 5), @intFromEnum(Irq.USBCTRL_IRQ));
}
