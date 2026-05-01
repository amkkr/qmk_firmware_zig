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
    // Git commit hash を埋込 (個体識別 + reproducible のため --short=12 固定)
    // git 不在 / shallow clone 失敗時は空文字、 ビルド継続
    build_opts.addOption([]const u8, "GIT_HASH", gitHash(b));

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

    // ELF ファイルサイズ表示
    const elf_name = b.fmt("{s}_{s}", .{ keyboard, keymap });
    const elf_size_step = addFileSizeStep(b, b.getInstallPath(.bin, elf_name), elf_name);
    elf_size_step.dependOn(&install_firmware.step);

    // ELF のみ生成する step (後方互換: 旧 `zig build` の ELF-only 挙動を保つ)
    const elf_step = b.step("elf", "Build firmware ELF only (no UF2 conversion)");
    elf_step.dependOn(elf_size_step);

    // UF2 conversion step
    const uf2_step = b.step("uf2", "Convert firmware to UF2 format");
    const uf2_install = addUf2Step(b, firmware, native_target, keyboard, keymap);
    uf2_step.dependOn(&uf2_install.step);

    // UF2 ファイルサイズ表示
    const uf2_name = b.fmt("{s}_{s}.uf2", .{ keyboard, keymap });
    const uf2_size_step = addFileSizeStep(b, b.getInstallPath(.prefix, uf2_name), uf2_name);
    uf2_size_step.dependOn(&uf2_install.step);
    uf2_step.dependOn(uf2_size_step);

    // UF2 ファイルの SHA256 を計算して stderr に表示 (個体識別 / reproducible 検証用)
    const uf2_sha256_step = addSha256Step(b, b.getInstallPath(.prefix, uf2_name), uf2_name);
    uf2_sha256_step.dependOn(&uf2_install.step);
    uf2_step.dependOn(uf2_sha256_step);

    // `zig build` のデフォルトステップに ELF サイズ表示 + UF2 install + SHA256 を接続
    // (QMK 慣習として flash 用成果物 .uf2 をデフォルト出力とする)
    b.getInstallStep().dependOn(elf_size_step);
    b.getInstallStep().dependOn(uf2_size_step);
    b.getInstallStep().dependOn(uf2_sha256_step);

    // Flash step: build UF2 and copy to RP2040 BOOTSEL drive
    const flash_step = b.step("flash", "Flash firmware to RP2040 via BOOTSEL mode");
    const flash_run = addFlashStep(b, uf2_install, uf2_size_step, native_target, keyboard, keymap);
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
    uf2_size_step: *std.Build.Step,
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
    // UF2 サイズ表示 → flash 実行 の順序を保証 (出力混在防止)
    flash_run.step.dependOn(uf2_size_step);

    return flash_run;
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

/// `git rev-parse --short=12 HEAD` を実行して GIT_HASH を取得する。
/// git 不在、 shallow clone で取れない、 終了コード非ゼロ等の失敗時は警告を出して空文字を返す。
/// `--short=12` 固定で reproducible を担保 (commit + zig version + OS が同一なら同じ hash)。
fn gitHash(b: *std.Build) []const u8 {
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "git", "rev-parse", "--short=12", "HEAD" },
        .max_output_bytes = 64,
    }) catch |err| {
        std.debug.print("warning: git rev-parse 実行に失敗 ({s})、 GIT_HASH を空文字に設定\n", .{@errorName(err)});
        return "";
    };
    defer b.allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        b.allocator.free(result.stdout);
        std.debug.print("warning: git rev-parse の終了コードが非ゼロ、 GIT_HASH を空文字に設定\n", .{});
        return "";
    }

    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    // trim 後の slice は元の stdout を指すため、 build allocator で複製してから stdout を解放
    const dup = b.allocator.dupe(u8, trimmed) catch @panic("OOM");
    b.allocator.free(result.stdout);
    return dup;
}

/// ファイルサイズを表示するカスタムビルドステップを追加
fn addFileSizeStep(b: *std.Build, file_path: []const u8, display_name: []const u8) *std.Build.Step {
    const print_step = FileSizeStep.create(b, file_path, display_name);
    return &print_step.step;
}

/// ファイルの SHA256 を計算して stderr に表示するカスタムビルドステップを追加
fn addSha256Step(b: *std.Build, file_path: []const u8, display_name: []const u8) *std.Build.Step {
    const step = Sha256Step.create(b, file_path, display_name);
    return &step.step;
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

const Sha256Step = struct {
    step: std.Build.Step,
    file_path: []const u8,
    display_name: []const u8,

    fn create(b: *std.Build, file_path: []const u8, display_name: []const u8) *Sha256Step {
        const self = b.allocator.create(Sha256Step) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("sha256 ({s})", .{display_name}),
                .owner = b,
                .makeFn = make,
            }),
            .file_path = file_path,
            .display_name = display_name,
        };
        return self;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        const self: *Sha256Step = @fieldParentPtr("step", step);
        const file = std.fs.cwd().openFile(self.file_path, .{}) catch |err| {
            std.debug.print("  {s} SHA256: ファイルを開けません ({s})\n", .{ self.display_name, @errorName(err) });
            return;
        };
        defer file.close();

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = file.read(&buf) catch |err| {
                std.debug.print("  {s} SHA256: 読み取りエラー ({s})\n", .{ self.display_name, @errorName(err) });
                return;
            };
            if (n == 0) break;
            hasher.update(buf[0..n]);
        }
        var digest: [32]u8 = undefined;
        hasher.final(&digest);

        std.debug.print("  {s} SHA256: {x}\n", .{ self.display_name, std.fmt.fmtSliceHexLower(&digest) });
    }
};
