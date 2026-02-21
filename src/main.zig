//! QMK Firmware - Zig Implementation
//! RP2040 (ARM Cortex-M0+) keyboard firmware

const std = @import("std");
const builtin = @import("builtin");

// Module declarations
pub const core = @import("core/core.zig");
pub const hal = struct {};
pub const drivers = struct {};
pub const keyboards = struct {};

const is_freestanding = builtin.os.tag == .freestanding;

// ============================================================
// RP2040 Startup (freestanding only)
// ============================================================

pub const startup = if (is_freestanding) struct {
    const vector_table_zig = @import("hal/vector_table.zig");

    extern var _stack_top: anyopaque;

    /// Vector table placed in .vectors section
    export const vector_table linksection(".vectors") = vector_table_zig.vectorTable();

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
        main() catch {};
        while (true) {
            asm volatile ("wfi");
        }
    }

    fn main() !void {
        // TODO: Initialize hardware (Issue #4)
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
