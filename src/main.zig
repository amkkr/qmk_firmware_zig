// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! QMK Firmware - Zig Implementation
//! RP2040 (ARM Cortex-M0+) keyboard firmware

const std = @import("std");
const builtin = @import("builtin");

// Module declarations
pub const core = @import("core/core.zig");
pub const hal = @import("hal/hal.zig");
pub const drivers = struct {};
const build_options = @import("build_options");
pub const kb = if (std.mem.eql(u8, build_options.KEYBOARD, "madbd34"))
    @import("keyboards/madbd34.zig")
else
    @import("keyboards/madbd5.zig");

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

    const gpio = @import("hal/gpio.zig");
    const uart = @import("hal/uart.zig");
    const usb = @import("hal/usb.zig");
    const eeprom_mod = @import("hal/eeprom.zig");
    const matrix_mod = @import("core/matrix.zig");
    const keyboard = @import("core/keyboard.zig");
    const action_mod = @import("core/action.zig");
    const host_mod = @import("core/host.zig");
    const kb_mod = @import("root").kb;

    const MatrixType = matrix_mod.Matrix(kb_mod.rows, kb_mod.cols);

    var usb_driver: usb.UsbDriver = .{};
    var matrix: MatrixType = undefined;

    fn main() !void {
        // クロックツリー初期化（XOSC, PLL, システムクロック設定）
        clock.init();
        // GPIO ペリフェラルのリセット解除（IO_BANK0, PADS_BANK0）
        gpio.init();
        // UART0 デバッグ出力初期化（GP0 = TX, 115200bps, 8N1）
        uart.init();

        uart.print("[BOOT] clock.init() done\n", .{});
        uart.print("[BOOT] gpio.init() done\n", .{});
        uart.print("[BOOT] uart.init() done\n", .{});

        // キーボードマトリックス初期化
        matrix = MatrixType.init(kb_mod.matrixConfig());
        uart.print("[BOOT] matrix.init() done\n", .{});

        // USB HID 初期化
        usb_driver.init();
        host_mod.setDriver(usb_driver.hostDriver());
        uart.print("[BOOT] usb.init() done\n", .{});

        // EEPROM初期化（フラッシュからRAMキャッシュに読み込み）
        eeprom_mod.init();
        uart.print("[BOOT] eeprom.init() done\n", .{});

        // キーボード内部状態初期化・キーマップロード・アクションリゾルバ設定
        keyboard.init();
        keyboard.getTestKeymap().* = kb_mod.default_keymap;
        action_mod.setActionResolver(keyboard.keymapActionResolver);
        uart.print("[BOOT] keyboard.init() done\n", .{});

        uart.print("[BOOT] {s} firmware ready, entering main loop\n", .{build_options.KEYBOARD});

        // メインループ
        while (true) {
            // USBイベントポーリング（SETUP_REQ/BUS_RESET/BUFF_STATUS処理）
            usb_driver.task();

            // マトリックススキャン → 状態を keyboard モジュールに反映
            const matrix_changed = matrix.scan();
            for (0..kb_mod.rows) |row| {
                keyboard.setMatrixRow(@intCast(row), matrix.getRow(@intCast(row)));
            }

            if (matrix_changed) {
                uart.print("matrix changed\n", .{});
            }

            // キーボードタスク実行（差分検出 → イベント生成 → アクション実行）
            keyboard.task();
        }
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
    _ = kb;
}

test {
    // Run all sub-module tests
    @import("std").testing.refAllDecls(core);
    @import("std").testing.refAllDecls(hal);
    @import("std").testing.refAllDecls(kb);
    // Boot2モジュールのテストを実行
    _ = @import("hal/boot2.zig");
    // 統合テストを実行
    _ = @import("tests/integration_test.zig");
    // C版テスト移植
    _ = @import("tests/test_keypress.zig");
    _ = @import("tests/test_action_layer.zig");
    _ = @import("tests/test_tapping.zig");
    _ = @import("tests/test_oneshot.zig");
    _ = @import("tests/test_mousekey.zig");
    _ = @import("tests/test_tap_hold_config.zig");
    _ = @import("tests/test_secure.zig");
    _ = @import("tests/test_caps_word.zig");
    _ = @import("tests/test_tri_layer.zig");
    _ = @import("tests/test_auto_shift.zig");
    _ = @import("tests/test_layer_lock.zig");
    _ = @import("tests/test_leader.zig");
    _ = @import("tests/test_combo.zig");
    _ = @import("tests/test_repeat_key.zig");
    _ = @import("tests/test_tap_dance.zig");
    _ = @import("tests/test_autocorrect.zig");
    _ = @import("tests/test_no_tapping.zig");
    _ = @import("tests/test_dynamic_tapping_term.zig");
    _ = @import("tests/test_unicode.zig");
    // C ABI互換性テストを実行
    _ = @import("compat/abi_test.zig");
    _ = @import("compat/qmk_abi.zig");
}
