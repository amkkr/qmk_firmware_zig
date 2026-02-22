//! QMK Firmware - Zig Implementation
//! RP2040 (ARM Cortex-M0+) keyboard firmware

const std = @import("std");
const builtin = @import("builtin");

// Module declarations
pub const core = @import("core/core.zig");
pub const hal = @import("hal/hal.zig");
pub const drivers = struct {};
pub const keyboards = struct {
    pub const madbd34 = @import("keyboards/madbd34.zig");
};

const is_freestanding = builtin.os.tag == .freestanding;

// ============================================================
// RP2040 Startup (freestanding only)
// ============================================================

pub const startup = if (is_freestanding) struct {
    const vector_table_mod = @import("hal/vector_table.zig");
    const boot2_mod = @import("hal/boot2.zig");
    const clock = @import("hal/clock.zig");

    extern var _stack_top: anyopaque;

    // Linker-provided section symbols
    extern var _sdata: u8;
    extern var _edata: u8;
    extern const _sidata: u8;
    extern var _sbss: u8;
    extern var _ebss: u8;

    /// Boot2 second stage bootloader (256 bytes at 0x10000000)
    export const boot2_entry linksection(".boot2") = boot2_mod.boot2;

    /// Vector table placed in .vectors section
    export const vector_table linksection(".vectors") = vector_table_mod.vectorTable(&_start);

    /// Entry point for RP2040 firmware
    /// Note: Cortex-M0+ は ldr r0, =symbol のリテラルプール距離に制限があるため、
    /// PC相対ロードで明示的にリテラルプールを関数内に配置する。
    pub export fn _start() callconv(.naked) noreturn {
        @setRuntimeSafety(false);
        asm volatile (
            \\ldr r0, .Lstack_top_addr
            \\mov sp, r0
            \\ldr r0, .Lmain_addr
            \\bx r0
            \\.align 2
            \\.Lstack_top_addr: .word _stack_top
            \\.Lmain_addr: .word %[main]
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
    // On freestanding: forces Zig to analyze the startup struct so that
    // `vector_table` (export) and `_start` (export) are emitted in the binary.
    // On native test builds: `startup` is an empty struct, so this is a no-op.
    _ = startup;
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
    @import("std").testing.refAllDecls(hal);
    @import("std").testing.refAllDecls(keyboards);
    // Boot2モジュールのテストを実行
    _ = @import("hal/boot2.zig");
    // 統合テストを実行
    _ = @import("tests/integration_test.zig");
    // C ABI互換性テストを実行
    _ = @import("compat/abi_test.zig");
    _ = @import("compat/qmk_abi.zig");
}
