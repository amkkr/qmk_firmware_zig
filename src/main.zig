//! QMK Firmware - Zig Implementation
//! RP2040 (ARM Cortex-M0+) keyboard firmware

const std = @import("std");
const builtin = @import("builtin");

// Module declarations
pub const core = @import("core/core.zig");
pub const hal = struct {
    pub const clock = @import("hal/clock.zig");
};
pub const drivers = struct {};
pub const keyboards = struct {};

const is_freestanding = builtin.os.tag == .freestanding;

// ============================================================
// RP2040 Startup (freestanding only)
// ============================================================

pub const startup = if (is_freestanding) struct {
    const vector_table_mod = @import("hal/vector_table.zig");
    const clock = @import("hal/clock.zig");

    extern var _stack_top: anyopaque;

    // Linker-provided section symbols
    extern var _sdata: u8;
    extern var _edata: u8;
    extern const _sidata: u8;
    extern var _sbss: u8;
    extern var _ebss: u8;

    /// Vector table placed in .vectors section
    export const vector_table linksection(".vectors") = vector_table_mod.vectorTable(&_start);

    /// Entry point for RP2040 firmware
    pub export fn _start() callconv(.naked) noreturn {
        @setRuntimeSafety(false);
        asm volatile (
            \\ldr r0, =_stack_top
            \\mov sp, r0
            \\bl %[main]
            :
            : [main] "X" (&zigMain),
        );
    }

    fn zigMain() callconv(.c) noreturn {
        // Initialize .data section (copy from flash to RAM)
        const data_start: [*]u8 = @ptrCast(&_sdata);
        const data_end: [*]u8 = @ptrCast(&_edata);
        const data_src: [*]const u8 = @ptrCast(&_sidata);
        const data_size = @intFromPtr(data_end) - @intFromPtr(data_start);
        @memcpy(data_start[0..data_size], data_src[0..data_size]);

        // Initialize .bss section (zero fill)
        const bss_start: [*]u8 = @ptrCast(&_sbss);
        const bss_end: [*]u8 = @ptrCast(&_ebss);
        const bss_size = @intFromPtr(bss_end) - @intFromPtr(bss_start);
        @memset(bss_start[0..bss_size], 0);

        main() catch {};
        while (true) {
            asm volatile ("wfi");
        }
    }

    fn main() !void {
        // クロックツリー初期化（XOSC, PLL, システムクロック設定）
        clock.init();
        // TODO: Initialize keyboard matrix (Issue #5)
        // TODO: Initialize USB HID (Issue #6)
        // TODO: Main loop - keyboard_task() (Issue #8)
    }
} else struct {};

comptime {
    _ = startup; // Ensure startup code is analyzed for freestanding
}

// ============================================================
// Tests
// ============================================================

test "build smoke test" {
    try std.testing.expect(true);
}

test "module structure exists" {
    _ = core;
    _ = hal;
    _ = drivers;
    _ = keyboards;
}

test {
    // Run all sub-module tests
    @import("std").testing.refAllDecls(core);
}
