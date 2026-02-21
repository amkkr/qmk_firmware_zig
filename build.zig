const std = @import("std");

pub fn build(b: *std.Build) void {
    // Build options
    const keyboard = b.option([]const u8, "keyboard", "Target keyboard (e.g. madbd34)") orelse "madbd34";
    const keymap = b.option([]const u8, "keymap", "Target keymap (e.g. default)") orelse "default";
    const bootmagic_row = b.option(u8, "BOOTMAGIC_ROW", "Row index for bootmagic key (default: 0)") orelse 0;
    const bootmagic_col = b.option(u8, "BOOTMAGIC_COLUMN", "Column index for bootmagic key (default: 0)") orelse 0;

    // Build options module (passed to firmware and tests as "build_options")
    const build_opts = b.addOptions();
    build_opts.addOption(u8, "BOOTMAGIC_ROW", bootmagic_row);
    build_opts.addOption(u8, "BOOTMAGIC_COLUMN", bootmagic_col);

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
    b.installArtifact(firmware);

    // Optional boot2 binary path (required for booting on real hardware)
    // Obtain from pico-sdk: boot_stage2/boot2_w25q080.bin (or appropriate variant)
    const boot2_path = b.option([]const u8, "boot2", "Path to boot2.bin (256-byte second stage bootloader from pico-sdk)");

    // UF2 conversion step
    const uf2_step = b.step("uf2", "Convert firmware to UF2 format");
    const uf2_install = addUf2Step(b, firmware, native_target, keyboard, keymap, boot2_path);
    uf2_step.dependOn(&uf2_install.step);

    // Flash step: build UF2 and copy to RP2040 BOOTSEL drive
    const flash_step = b.step("flash", "Flash firmware to RP2040 via BOOTSEL mode");
    const flash_run = addFlashStep(b, uf2_install, native_target, keyboard, keymap);
    flash_step.dependOn(&flash_run.step);

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
