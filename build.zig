// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

const std = @import("std");

const KeyboardConfig = struct { rows: u8, cols: u8 };
const keyboard_configs = std.StaticStringMap(KeyboardConfig).initComptime(.{
    .{ "madbd34", KeyboardConfig{ .rows = 4, .cols = 12 } },
    .{ "madbd5", KeyboardConfig{ .rows = 5, .cols = 16 } },
});

pub fn build(b: *std.Build) void {
    // Build options
    const keyboard = b.option([]const u8, "keyboard", "Target keyboard (e.g. madbd5)") orelse "madbd5";
    const keymap = b.option([]const u8, "keymap", "Target keymap (e.g. default)") orelse "default";
    const bootmagic_row = b.option(u8, "BOOTMAGIC_ROW", "Row index for bootmagic key (default: 0)") orelse 0;
    const bootmagic_col = b.option(u8, "BOOTMAGIC_COLUMN", "Column index for bootmagic key (default: 0)") orelse 0;

    const kb_config = keyboard_configs.get(keyboard) orelse
        std.debug.panic("Unknown keyboard: '{s}'. Known keyboards: madbd34, madbd5", .{keyboard});

    // Build options module (passed to firmware and tests as "build_options")
    const build_opts = b.addOptions();
    build_opts.addOption(u8, "BOOTMAGIC_ROW", bootmagic_row);
    build_opts.addOption(u8, "BOOTMAGIC_COLUMN", bootmagic_col);
    build_opts.addOption(u8, "MATRIX_ROWS", kb_config.rows);
    build_opts.addOption(u8, "MATRIX_COLS", kb_config.cols);
    build_opts.addOption([]const u8, "KEYBOARD", keyboard);

    const optimize = b.standardOptimizeOption(.{});

    // RP2040 target: ARM Cortex-M0+, thumb, freestanding
    const rp2040_target = b.resolveTargetQuery(.{
        .cpu_arch = .thumb,
        .os_tag = .freestanding,
        .abi = .eabi,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m0plus },
    });

    // Native host target (for tools and tests)
    const native_target = b.resolveTargetQuery(.{});

    // Firmware module
    const firmware_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = rp2040_target,
        .optimize = optimize,
    });
    firmware_mod.addImport("build_options", build_opts.createModule());

    // Firmware executable
    const firmware = b.addExecutable(.{
        .name = b.fmt("{s}_{s}", .{ keyboard, keymap }),
        .root_module = firmware_mod,
    });

    firmware.setLinkerScript(b.path("src/hal/rp2040_linker.ld"));
    const install_firmware = b.addInstallArtifact(firmware, .{});

    // ELF ファイルサイズ表示（zig build のデフォルトステップに接続）
    const elf_name = b.fmt("{s}_{s}", .{ keyboard, keymap });
    const elf_size_step = addFileSizeStep(b, b.getInstallPath(.bin, elf_name), elf_name);
    elf_size_step.dependOn(&install_firmware.step);
    b.getInstallStep().dependOn(&install_firmware.step);
    b.getInstallStep().dependOn(elf_size_step);

    // Optional boot2 binary path (required for booting on real hardware)
    // Obtain from pico-sdk: boot_stage2/boot2_w25q080.bin (or appropriate variant)
    const boot2_path = b.option([]const u8, "boot2", "Path to boot2.bin (256-byte second stage bootloader from pico-sdk)");

    // UF2 conversion step
    const uf2_step = b.step("uf2", "Convert firmware to UF2 format");
    const uf2_install = addUf2Step(b, firmware, native_target, keyboard, keymap, boot2_path);
    uf2_step.dependOn(&uf2_install.step);

    // UF2 ファイルサイズ表示
    const uf2_name = b.fmt("{s}_{s}.uf2", .{ keyboard, keymap });
    const uf2_size_step = addFileSizeStep(b, b.getInstallPath(.prefix, uf2_name), uf2_name);
    uf2_size_step.dependOn(&uf2_install.step);
    uf2_step.dependOn(uf2_size_step);

    // Flash step: build UF2 and copy to RP2040 BOOTSEL drive
    const flash_step = b.step("flash", "Flash firmware to RP2040 via BOOTSEL mode");
    const flash_run = addFlashStep(b, uf2_install, native_target, keyboard, keymap);
    flash_step.dependOn(&flash_run.step);
    flash_step.dependOn(uf2_size_step);

    // Test module
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = native_target,
    });
    test_mod.addImport("build_options", build_opts.createModule());

    // Test target (native host)
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    // Flash tool tests
    const flash_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/flash.zig"),
            .target = native_target,
        }),
    });
    const run_flash_tests = b.addRunArtifact(flash_tests);
    test_step.dependOn(&run_flash_tests.step);

    // C ABI compatibility tests (included in main test module via compat/*.zig)
    const test_compat_step = b.step("test-compat", "Run all tests (includes C ABI compatibility tests)");
    test_compat_step.dependOn(&run_tests.step);

    // Verify step: run tests + check firmware ELF compilation succeeds
    // CI向け: `zig build verify` でテストとファームウェアコンパイルの両方を検証
    const verify_step = b.step("verify", "Run tests and verify firmware ELF compilation");
    verify_step.dependOn(&run_tests.step);
    verify_step.dependOn(&run_flash_tests.step);
    verify_step.dependOn(&firmware.step);
}

fn addFlashStep(
    b: *std.Build,
    uf2_install: *std.Build.Step.InstallFile,
    native_target: std.Build.ResolvedTarget,
    keyboard: []const u8,
    keymap: []const u8,
) *std.Build.Step.Run {
    const flash_tool = b.addExecutable(.{
        .name = "flash",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/flash.zig"),
            .target = native_target,
        }),
    });

    const flash_run = b.addRunArtifact(flash_tool);
    flash_run.addArg(b.getInstallPath(.prefix, b.fmt("{s}_{s}.uf2", .{ keyboard, keymap })));
    flash_run.step.dependOn(&uf2_install.step);

    return flash_run;
}

fn addUf2Step(
    b: *std.Build,
    firmware: *std.Build.Step.Compile,
    native_target: std.Build.ResolvedTarget,
    keyboard: []const u8,
    keymap: []const u8,
    boot2_path: ?[]const u8,
) *std.Build.Step.InstallFile {
    const raw_bin = firmware.addObjCopy(.{
        .format = .bin,
    });

    const uf2_gen = b.addExecutable(.{
        .name = "uf2gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/uf2gen.zig"),
            .target = native_target,
        }),
    });

    const uf2_run = b.addRunArtifact(uf2_gen);
    uf2_run.addFileArg(raw_bin.getOutput());
    const uf2_output = uf2_run.addOutputFileArg(b.fmt("{s}_{s}.uf2", .{ keyboard, keymap }));
    if (boot2_path) |path| {
        uf2_run.addArg(path);
    }

    return b.addInstallFile(uf2_output, b.fmt("{s}_{s}.uf2", .{ keyboard, keymap }));
}

/// ファイルサイズを表示するカスタムビルドステップを追加
fn addFileSizeStep(b: *std.Build, file_path: []const u8, display_name: []const u8) *std.Build.Step {
    const print_step = FileSizeStep.create(b, file_path, display_name);
    return &print_step.step;
}

const FileSizeStep = struct {
    step: std.Build.Step,
    file_path: []const u8,
    display_name: []const u8,

    fn create(b: *std.Build, file_path: []const u8, display_name: []const u8) *FileSizeStep {
        const self = b.allocator.create(FileSizeStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("file-size ({s})", .{display_name}),
                .owner = b,
                .makeFn = make,
            }),
            .file_path = file_path,
            .display_name = display_name,
        };
        return self;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        const self: *FileSizeStep = @fieldParentPtr("step", step);
        const stat = std.fs.cwd().statFile(self.file_path) catch |err| {
            std.debug.print("  {s}: could not stat file ({s})\n", .{ self.display_name, @errorName(err) });
            return;
        };
        const size = stat.size;
        if (size >= 1024) {
            std.debug.print("  {s}: {d:.1} KB ({d} bytes)\n", .{
                self.display_name,
                @as(f64, @floatFromInt(size)) / 1024.0,
                size,
            });
        } else {
            std.debug.print("  {s}: {d} bytes\n", .{ self.display_name, size });
        }
    }
};
