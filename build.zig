const std = @import("std");

pub fn build(b: *std.Build) void {
    // Build options
    const keyboard = b.option([]const u8, "keyboard", "Target keyboard (e.g. madbd34)") orelse "madbd34";
    const keymap = b.option([]const u8, "keymap", "Target keymap (e.g. default)") orelse "default";

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

    // Firmware executable
    const firmware = b.addExecutable(.{
        .name = b.fmt("{s}_{s}", .{ keyboard, keymap }),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = rp2040_target,
            .optimize = optimize,
        }),
    });

    firmware.setLinkerScript(b.path("src/hal/rp2040_linker.ld"));
    b.installArtifact(firmware);

    // UF2 conversion step
    const uf2_step = b.step("uf2", "Convert firmware to UF2 format");
    const uf2_install = addUf2Step(b, firmware, native_target, keyboard, keymap);
    uf2_step.dependOn(&uf2_install.step);

    // Test target (native host)
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = native_target,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}

fn addUf2Step(
    b: *std.Build,
    firmware: *std.Build.Step.Compile,
    native_target: std.Build.ResolvedTarget,
    keyboard: []const u8,
    keymap: []const u8,
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

    return b.addInstallFile(uf2_output, b.fmt("{s}_{s}.uf2", .{ keyboard, keymap }));
}
