//! QMK Firmware - Zig Implementation
//! RP2040 (ARM Cortex-M0+) keyboard firmware

const std = @import("std");
const builtin = @import("builtin");

// Module declarations (to be implemented in later issues)
pub const core = struct {};
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
    const vector_table_zig = @import("hal/vector_table.zig");
    const clock = @import("hal/clock.zig");

    extern var _stack_top: anyopaque;

    /// Vector table placed in .vectors section
    export const vector_table linksection(".vectors") = vector_table_zig.vectorTable(&_start);

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
        @setRuntimeSafety(false);
        // Initialize .data section: copy initial values from FLASH to RAM
        {
            extern var _sdata: u8;
            extern var _edata: u8;
            extern const _sidata: u8;
            const data_len = @intFromPtr(&_edata) - @intFromPtr(&_sdata);
            @memcpy(
                @as([*]u8, @ptrCast(&_sdata))[0..data_len],
                @as([*]const u8, @ptrCast(&_sidata))[0..data_len],
            );
        }
        // Zero-initialize .bss section
        {
            extern var _sbss: u8;
            extern var _ebss: u8;
            const bss_len = @intFromPtr(&_ebss) - @intFromPtr(&_sbss);
            @memset(@as([*]u8, @ptrCast(&_sbss))[0..bss_len], 0);
        }
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
