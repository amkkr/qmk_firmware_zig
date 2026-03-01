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
            \\cpsid i
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
    const usb = @import("hal/usb.zig");
    const timer = @import("hal/timer.zig");
    const cdc_console = @import("hal/cdc_console.zig");
    const eeprom_mod = @import("hal/eeprom.zig");
    const matrix_mod = @import("core/matrix.zig");
    const keyboard = @import("core/keyboard.zig");
    const action_mod = @import("core/action.zig");
    const host_mod = @import("core/host.zig");
    const kb_mod = @import("root").kb;

    const MatrixType = matrix_mod.Matrix(kb_mod.rows, kb_mod.cols);

    var usb_driver: usb.UsbDriver = .{};
    var matrix: MatrixType = undefined;

    // 診断用: GP0 を直接レジスタ操作で出力ピンにする（gpio.init() 前に使用可能）
    // マルチメーターで GP0 の電圧を確認して、どの init で停止しているか判別
    // GP0=HIGH のまま → 次の init でハング
    const DIAG_PIN: u32 = 0; // GP0

    fn diagGpioInit() void {
        // IO_BANK0 と PADS_BANK0 のリセット解除
        const RESETS_CLR: u32 = 0x4000C000 + 0x3000;
        const RESET_DONE: u32 = 0x4000C000 + 0x08;
        const BITS: u32 = (1 << 5) | (1 << 8); // IO_BANK0 | PADS_BANK0
        @as(*volatile u32, @ptrFromInt(RESETS_CLR)).* = BITS;
        while (@as(*volatile u32, @ptrFromInt(RESET_DONE)).* & BITS != BITS) {}
        // GP0 を SIO function (F5) に設定
        @as(*volatile u32, @ptrFromInt(0x40014000 + DIAG_PIN * 8 + 4)).* = 5;
        // GP0 を output enable
        @as(*volatile u32, @ptrFromInt(0xD0000024)).* = @as(u32, 1) << DIAG_PIN;
    }

    /// ペリフェラルのリセットを解除し完了を待つ
    fn unresetPeripherals(mask: u32) void {
        const RESETS_BASE_ADDR: u32 = 0x4000C000;
        const RESETS_CLR_ALIAS: u32 = RESETS_BASE_ADDR + 0x3000;
        const RESET_DONE_ADDR: u32 = RESETS_BASE_ADDR + 0x08;
        // リセットビットをクリア（リセット解除）
        @as(*volatile u32, @ptrFromInt(RESETS_CLR_ALIAS)).* = mask;
        // リセット解除完了を待つ
        while (@as(*volatile u32, @ptrFromInt(RESET_DONE_ADDR)).* & mask != mask) {}
    }

    fn diagPulse() void {
        // 短いパルス（LOW→HIGH）で段階を区切る
        @as(*volatile u32, @ptrFromInt(0xD0000018)).* = @as(u32, 1) << DIAG_PIN;
        var i: u32 = 0;
        while (i < 1000) : (i += 1) {
            asm volatile ("nop");
        }
        @as(*volatile u32, @ptrFromInt(0xD0000014)).* = @as(u32, 1) << DIAG_PIN;
    }

    fn main() !void {
        // [DIAG] Stage 0: GP0 HIGH = zigMain に到達
        diagGpioInit();
        @as(*volatile u32, @ptrFromInt(0xD0000014)).* = @as(u32, 1) << DIAG_PIN;

        // [DIAG] Stage 1: clock.init()
        clock.init();

        // ペリフェラルリセット解除（ChibiOS hal_lld_init() と同等）
        // BUSCTRL(bit1), SYSCFG(bit18), SYSINFO(bit19) を一括でリセット解除
        unresetPeripherals((1 << 1) | (1 << 18) | (1 << 19));

        diagPulse();

        // [DIAG] Stage 2: gpio.init()
        gpio.init();
        // gpio.init() が IO_BANK0 をリセットするため GP0 の FUNCSEL が NULL に戻る。
        // 診断パルスを継続するために GP0 を SIO function に再設定する。
        @as(*volatile u32, @ptrFromInt(0x40014000 + DIAG_PIN * 8 + 4)).* = 5;
        diagPulse();

        // [DIAG] Stage 3: matrix.init()
        matrix = MatrixType.init(kb_mod.matrixConfig());
        diagPulse();

        // [DIAG] Stage 4: usb_driver.init()
        usb_driver.init();
        host_mod.setDriver(usb_driver.hostDriver());
        cdc_console.init(&usb_driver);
        diagPulse();

        // EEPROM初期化（フラッシュからRAMキャッシュに読み込み）
        eeprom_mod.init();

        // キーボード内部状態初期化・キーマップロード・アクションリゾルバ設定
        keyboard.init();
        keyboard.getTestKeymap().* = kb_mod.default_keymap;
        action_mod.setActionResolver(keyboard.keymapActionResolver);

        // 診断用変数
        var loop_count: u32 = 0;
        var last_heartbeat: u32 = timer.read32();
        var prev_matrix: [kb_mod.rows]u32 = .{0} ** kb_mod.rows;

        // メインループ
        while (true) {
            // USBイベントポーリング（SETUP_REQ/BUS_RESET/BUFF_STATUS処理）
            usb_driver.task();

            // マトリックススキャン → 状態を keyboard モジュールに反映
            _ = matrix.scan();
            for (0..kb_mod.rows) |row| {
                keyboard.setMatrixRow(@intCast(row), matrix.getRow(@intCast(row)));
            }

            // キーボードタスク実行（差分検出 → イベント生成 → アクション実行）
            keyboard.task();

            // 診断ログ
            loop_count +%= 1;

            // マトリックス変化検出ログ
            for (0..kb_mod.rows) |row| {
                const current = matrix.getRow(@intCast(row));
                if (current != prev_matrix[row]) {
                    cdc_console.print("matrix[{d}]: 0x{X:0>4} -> 0x{X:0>4}\r\n", .{ row, prev_matrix[row], current });
                    prev_matrix[row] = current;
                }
            }

            // 定期ハートビートログ（5秒ごと）
            const now = timer.read32();
            if (timer.elapsed32(last_heartbeat) >= 5000) {
                const usb_state: []const u8 = if (usb_driver.isConfigured()) "configured" else "not configured";
                cdc_console.print("[heartbeat] loops={d} usb={s}\r\n", .{ loop_count, usb_state });
                last_heartbeat = now;
                loop_count = 0;
            }
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
