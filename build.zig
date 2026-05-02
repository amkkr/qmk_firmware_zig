// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

const std = @import("std");

/// flash バックエンド種別
const Flasher = enum {
    /// 既存 tools/flash.zig (BOOTSEL ドライブコピー、 default)
    bootsel,
    /// picotool (USB PICOBOOT 経由、 BOOTSEL 自動化 + verify)
    picotool,
    /// openocd (SWD 経由、 picoprobe / CMSIS-DAP プローブ必要)
    openocd,
    /// probe-rs (Rust 製、 SWD 経由、 RTT log 等)
    probers,
};

/// keyboard / keymap の引数を許可リスト [A-Za-z0-9_-]+ で検証する。
/// build エラー早期化が目的 (b.addSystemCommand は execve 経由のため
/// shell injection は発生しないが、 ファイルパス組み立てやエラー診断容易性
/// のために制限する)。
fn validateIdentifier(name: []const u8, value: []const u8) void {
    if (value.len == 0) {
        std.debug.panic("Error: --{s} の値が空です", .{name});
    }
    for (value) |c| {
        const ok = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-';
        if (!ok) {
            std.debug.panic("Error: --{s} の値 '{s}' に許可されていない文字が含まれています ([A-Za-z0-9_-]+ のみ許可)", .{ name, value });
        }
    }
}

pub fn build(b: *std.Build) void {
    // Build options
    const keyboard = b.option([]const u8, "keyboard", "Target keyboard (e.g. madbd5)") orelse "madbd5";
    const keymap = b.option([]const u8, "keymap", "Target keymap (e.g. default)") orelse "default";
    const bootmagic_row = b.option(u8, "BOOTMAGIC_ROW", "Row index for bootmagic key (default: 0)") orelse 0;
    const bootmagic_col = b.option(u8, "BOOTMAGIC_COLUMN", "Column index for bootmagic key (default: 0)") orelse 0;
    const flasher = b.option(Flasher, "flasher", "Flash backend (bootsel|picotool|openocd|probers, default: bootsel)") orelse .bootsel;

    // 入力検証 (build エラー早期化、 ファイルパス組み立て前にチェック)
    validateIdentifier("keyboard", keyboard);
    validateIdentifier("keymap", keymap);

    // -Dkeyboard=<name> から `src/keyboards/<name>.zig` を解決。
    // 不在なら src/keyboards/ ディレクトリをスキャンして有効リストを動的生成し、
    // 日本語エラーで build を停止する (panic ではなく process.exit(1) で UX を改善)。
    const keyboard_path = resolveKeyboardPath(b, keyboard);

    // Build options module (passed to firmware and tests as "build_options")
    // MATRIX_ROWS / MATRIX_COLS は active_keyboard.rows / .cols で参照するため不要。
    const build_opts = b.addOptions();
    build_opts.addOption(u8, "BOOTMAGIC_ROW", bootmagic_row);
    build_opts.addOption(u8, "BOOTMAGIC_COLUMN", bootmagic_col);
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

    // core / hal / active_keyboard を独立 named module として作成し、
    // firmware_mod / 各 module 間で共有する。 同じファイルが複数 module に
    // 属するのを避けるために、 root tree (firmware_mod) からの core / hal /
    // keyboards ファイルへの直接相対 import は廃止し、 named import 経由で
    // のみアクセスする。
    const build_opts_mod = build_opts.createModule();

    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = rp2040_target,
        .optimize = optimize,
    });
    core_mod.addImport("build_options", build_opts_mod);

    const hal_mod = b.createModule(.{
        .root_source_file = b.path("src/hal/hal.zig"),
        .target = rp2040_target,
        .optimize = optimize,
    });
    // src/hal/ 配下のファイルは build_options を参照しないため addImport は不要。
    // 将来 hal が build_options に依存する時点で追加する。

    // active_keyboard モジュール: `-Dkeyboard=<name>` で選ばれた keyboard 定義
    const active_keyboard_mod = b.createModule(.{
        .root_source_file = b.path(keyboard_path),
        .target = rp2040_target,
        .optimize = optimize,
    });
    active_keyboard_mod.addImport("core", core_mod);
    active_keyboard_mod.addImport("hal", hal_mod);

    // core / hal モジュール間および active_keyboard への循環 import を許容。
    // Zig は lazy resolution によりモジュール間の循環 import 自体を許容する。
    // 制約は comptime 型・値評価が循環することのみで、 import 関係の循環は
    // 問題にならない。
    //
    // 現時点で `src/hal/*.zig` から `core/*.zig` を参照しているのは
    // `usb.zig`/`usb_descriptors.zig` のみで、 hal が core に依存する範囲は限定的。
    // 将来 hal の他モジュールが core を参照する場合や、 active_keyboard が
    // hal/core の特定モジュールに依存するような大規模変更を行う場合は、
    // comptime 評価の循環が発生しないかビルドで実証する必要がある。
    core_mod.addImport("active_keyboard", active_keyboard_mod);
    core_mod.addImport("hal", hal_mod);
    hal_mod.addImport("core", core_mod);
    hal_mod.addImport("active_keyboard", active_keyboard_mod);

    // Firmware module
    const firmware_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = rp2040_target,
        .optimize = optimize,
    });
    firmware_mod.addImport("build_options", build_opts_mod);
    firmware_mod.addImport("core", core_mod);
    firmware_mod.addImport("hal", hal_mod);
    firmware_mod.addImport("active_keyboard", active_keyboard_mod);

    // Firmware executable
    const firmware = b.addExecutable(.{
        .name = b.fmt("{s}_{s}", .{ keyboard, keymap }),
        .root_module = firmware_mod,
    });

    firmware.setLinkerScript(b.path("src/hal/rp2040_linker.ld"));
    const install_firmware = b.addInstallArtifact(firmware, .{});

    // ELF メモリ使用状況表示 (.text / .data / .bss と linker region 比較)
    const elf_name = b.fmt("{s}_{s}", .{ keyboard, keymap });
    const elf_size_step = addElfMemoryUsageStep(b, b.getInstallPath(.bin, elf_name), elf_name);
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

    // Flash step: backend を flasher で切替
    const flash_step = b.step("flash", "Flash firmware to RP2040 (backend は -Dflasher で選択)");
    switch (flasher) {
        .bootsel => {
            const flash_run = addFlashStep(b, uf2_install, uf2_size_step, native_target, keyboard, keymap);
            flash_step.dependOn(&flash_run.step);
        },
        .picotool => {
            const run = addPicotoolFlashStep(b, uf2_install, uf2_size_step, keyboard, keymap);
            flash_step.dependOn(&run.step);
        },
        .openocd => {
            const run = addOpenocdFlashStep(b, &install_firmware.step, elf_size_step, keyboard, keymap);
            flash_step.dependOn(&run.step);
        },
        .probers => {
            const run = addProbersFlashStep(b, &install_firmware.step, elf_size_step, keyboard, keymap);
            flash_step.dependOn(&run.step);
        },
    }

    // Test module — native target 用に core / hal / active_keyboard を再構築
    const test_build_opts_mod = build_opts.createModule();

    const test_core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = native_target,
    });
    test_core_mod.addImport("build_options", test_build_opts_mod);

    const test_hal_mod = b.createModule(.{
        .root_source_file = b.path("src/hal/hal.zig"),
        .target = native_target,
    });

    const test_active_kb_mod = b.createModule(.{
        .root_source_file = b.path(keyboard_path),
        .target = native_target,
    });
    test_active_kb_mod.addImport("core", test_core_mod);
    test_active_kb_mod.addImport("hal", test_hal_mod);

    test_core_mod.addImport("active_keyboard", test_active_kb_mod);
    test_core_mod.addImport("hal", test_hal_mod);
    test_hal_mod.addImport("core", test_core_mod);
    test_hal_mod.addImport("active_keyboard", test_active_kb_mod);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = native_target,
    });
    test_mod.addImport("build_options", test_build_opts_mod);
    test_mod.addImport("core", test_core_mod);
    test_mod.addImport("hal", test_hal_mod);
    test_mod.addImport("active_keyboard", test_active_kb_mod);

    // Test target (native host)
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    // core / hal モジュール内 test ブロック実行用の独立 test target。
    // root tree (test_mod = src/main.zig) からは refAllDecls(core) で宣言を
    // 参照しているが、 named module 化により別 module ツリーとなった core /
    // hal 内の `test "..." { ... }` ブロックは root tree の test runner では
    // 拾われない。 各モジュールを root_source_file に持つ test target を追加
    // することでモジュール内テストを実行する。
    const core_tests = b.addTest(.{
        .root_module = test_core_mod,
    });
    const run_core_tests = b.addRunArtifact(core_tests);
    test_step.dependOn(&run_core_tests.step);

    const hal_tests = b.addTest(.{
        .root_module = test_hal_mod,
    });
    const run_hal_tests = b.addRunArtifact(hal_tests);
    test_step.dependOn(&run_hal_tests.step);

    // active_keyboard モジュール内の test ブロック (madbd5 / madbd34 のキーマップ
    // 検証等) も別 module ツリーにあり root tree から拾えないため、 専用 test
    // target を追加する。
    const active_kb_tests = b.addTest(.{
        .root_module = test_active_kb_mod,
    });
    const run_active_kb_tests = b.addRunArtifact(active_kb_tests);
    test_step.dependOn(&run_active_kb_tests.step);

    // Flash tool tests
    const flash_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/flash.zig"),
            .target = native_target,
        }),
    });
    const run_flash_tests = b.addRunArtifact(flash_tests);
    test_step.dependOn(&run_flash_tests.step);

    // UF2 generator tool tests
    const uf2gen_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/uf2gen.zig"),
            .target = native_target,
        }),
    });
    const run_uf2gen_tests = b.addRunArtifact(uf2gen_tests);
    test_step.dependOn(&run_uf2gen_tests.step);

    // C ABI compatibility tests (included in main test module via compat/*.zig)
    const test_compat_step = b.step("test-compat", "Run all tests (includes C ABI compatibility tests)");
    test_compat_step.dependOn(&run_tests.step);
    test_compat_step.dependOn(&run_core_tests.step);
    test_compat_step.dependOn(&run_hal_tests.step);
    test_compat_step.dependOn(&run_active_kb_tests.step);

    // Verify step: run tests + check firmware ELF compilation succeeds
    // CI向け: `zig build verify` でテストとファームウェアコンパイルの両方を検証
    const verify_step = b.step("verify", "Run tests and verify firmware ELF compilation");
    verify_step.dependOn(&run_tests.step);
    verify_step.dependOn(&run_core_tests.step);
    verify_step.dependOn(&run_hal_tests.step);
    verify_step.dependOn(&run_active_kb_tests.step);
    verify_step.dependOn(&run_flash_tests.step);
    verify_step.dependOn(&run_uf2gen_tests.step);
    verify_step.dependOn(&firmware.step);
}

/// `-Dkeyboard=<name>` から `src/keyboards/<name>.zig` のパスを解決する。
/// 該当ファイルが存在しない場合は `src/keyboards/` 配下の `.zig` を動的にスキャンして
/// 有効な keyboard 一覧を日本語で表示し、 `process.exit(1)` で build を停止する。
///
/// `process.exit(1)` を採用する理由:
///   1. Zig 0.16 の `std.Build` には build error を構造化して報告する API
///      (Cargo の `bail!` や Bazel の `fail()` 相当) が存在しない。
///      `pub fn build(b: *std.Build) void` の戻り値も `void` のため
///      `return error.X` も使えない。
///   2. `std.debug.panic` だと冗長なスタックトレースが CI ログを汚す。
///   3. ユーザは `-Dkeyboard=<name>` 引数の typo を即座に確認したいだけ。
fn resolveKeyboardPath(b: *std.Build, keyboard: []const u8) []const u8 {
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    const path = b.fmt("src/keyboards/{s}.zig", .{keyboard});
    if (cwd.access(io, path, .{})) |_| {
        return path;
    } else |_| {}

    // 有効な keyboard 一覧を src/keyboards/*.zig から動的に収集
    const valid = collectValidKeyboards(b);
    std.debug.print(
        "error: 不明な keyboard 名 \"{s}\"。 有効な keyboard: {s}\n",
        .{ keyboard, valid },
    );
    std.process.exit(1);
}

/// `src/keyboards/` 配下の `.zig` ファイル名を昇順カンマ区切りで列挙する。
/// 失敗時は空文字を返し、 上位呼出側でエラーを表示するのに任せる。
fn collectValidKeyboards(b: *std.Build) []const u8 {
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, "src/keyboards", .{ .iterate = true }) catch return "";
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(b.allocator);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".zig")) continue;
        const stem = name[0 .. name.len - ".zig".len];
        names.append(b.allocator, b.dupe(stem)) catch return "";
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b_: []const u8) bool {
            return std.mem.lessThan(u8, a, b_);
        }
    }.lessThan);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(b.allocator);
    for (names.items, 0..) |n, i| {
        if (i > 0) buf.appendSlice(b.allocator, ", ") catch return "";
        buf.appendSlice(b.allocator, n) catch return "";
    }
    return buf.toOwnedSlice(b.allocator) catch "";
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

/// picotool バックエンド: `picotool load -f -u -v <abs_uf2_path>` を実行。
/// USB PICOBOOT 経由で BOOTSEL 自動化 + verify + reboot を実施する。
fn addPicotoolFlashStep(
    b: *std.Build,
    uf2_install: *std.Build.Step.InstallFile,
    uf2_size_step: *std.Build.Step,
    keyboard: []const u8,
    keymap: []const u8,
) *std.Build.Step.Run {
    const tool_path = resolveExternalTool(b, "picotool", &.{
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    });

    const run = b.addSystemCommand(&.{
        tool_path,
        "load",
        "-f",
        "-u",
        "-v",
    });
    run.addArg(b.getInstallPath(.prefix, b.fmt("{s}_{s}.uf2", .{ keyboard, keymap })));

    run.step.dependOn(&uf2_install.step);
    run.step.dependOn(uf2_size_step);
    return run;
}

/// openocd バックエンド: SWD 経由で ELF を直接書込 + verify + reset。
/// `interface/cmsis-dap.cfg` 等の探索ディレクトリは絶対パス指定 (`-s`) で
/// 設定ファイルインジェクション対策を行う (CWD 経由の cfg 読込を防ぐ)。
fn addOpenocdFlashStep(
    b: *std.Build,
    install_step: *std.Build.Step,
    elf_size_step: *std.Build.Step,
    keyboard: []const u8,
    keymap: []const u8,
) *std.Build.Step.Run {
    const tool_path = resolveExternalTool(b, "openocd", &.{
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    });
    // openocd の scripts ディレクトリ候補 (Homebrew / Linux 標準)
    const scripts_dir = resolveOpenocdScriptsDir(b);

    const elf_path = b.getInstallPath(.bin, b.fmt("{s}_{s}", .{ keyboard, keymap }));
    // openocd の -c は TCL インタープリタに渡されるため、 path は double quote で囲む
    // (パスにスペースが含まれる場合の誤動作防止)
    const program_cmd = b.fmt("program \"{s}\" verify reset exit", .{elf_path});

    const run = b.addSystemCommand(&.{
        tool_path,
        "-s", scripts_dir,
        "-f", "interface/cmsis-dap.cfg",
        "-f", "target/rp2040.cfg",
        "-c", program_cmd,
    });

    run.step.dependOn(install_step);
    run.step.dependOn(elf_size_step);
    return run;
}

/// probe-rs バックエンド: SWD 経由で ELF 書込。 RTT ログ表示も可能。
fn addProbersFlashStep(
    b: *std.Build,
    install_step: *std.Build.Step,
    elf_size_step: *std.Build.Step,
    keyboard: []const u8,
    keymap: []const u8,
) *std.Build.Step.Run {
    const tool_path = resolveExternalTool(b, "probe-rs", &.{
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    });

    const elf_path = b.getInstallPath(.bin, b.fmt("{s}_{s}", .{ keyboard, keymap }));

    const run = b.addSystemCommand(&.{
        tool_path,
        "run",
        "--chip", "RP2040",
        elf_path,
    });

    run.step.dependOn(install_step);
    run.step.dependOn(elf_size_step);
    return run;
}

/// 外部ツールバイナリの絶対パスを解決する (PATH 攻撃対策)。
/// 候補ディレクトリで実体を探し、 見つからなければ warning を出してツール名を返す。
/// build graph 構築フェーズで panic しないため、 flash 以外のステップ (`zig build test` 等)
/// は flasher オプション指定中でも問題なく実行できる。
/// 候補に見つからなかった場合のフォールバックとして PATH 経由の解決に委ねる
/// (PATH 攻撃対策は限定的になるが、 実用性を優先)。
fn resolveExternalTool(b: *std.Build, name: []const u8, paths: []const []const u8) []const u8 {
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    for (paths) |dir| {
        const candidate = b.fmt("{s}/{s}", .{ dir, name });
        if (cwd.access(io, candidate, .{})) |_| {
            return candidate;
        } else |_| {}
    }
    std.debug.print(
        "Warning: 外部ツール '{s}' が候補パスに見つかりません。 PATH 経由の解決に委ねます。 見つからない場合は flash 実行時に execvp が失敗します (macOS では `brew install {s}` でインストール可)。\n",
        .{ name, name },
    );
    return b.dupe(name);
}

/// openocd の scripts ディレクトリ (interface/, target/ を含む) の絶対パスを解決する。
/// 見つからない場合も build graph では panic せず、 デフォルト候補を返してエラーを実行時に遅延させる。
fn resolveOpenocdScriptsDir(b: *std.Build) []const u8 {
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    const candidates = [_][]const u8{
        "/opt/homebrew/share/openocd/scripts",
        "/usr/local/share/openocd/scripts",
        "/usr/share/openocd/scripts",
    };
    for (candidates) |dir| {
        if (cwd.access(io, dir, .{})) |_| {
            return b.dupe(dir);
        } else |_| {}
    }
    std.debug.print(
        "Warning: openocd の scripts ディレクトリが候補パスに見つかりません。 デフォルト候補 '{s}' を使用します。 必要に応じて手動で調整してください。\n",
        .{candidates[0]},
    );
    return b.dupe(candidates[0]);
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
    const io = b.graph.io;
    var child = std.process.spawn(io, .{
        .argv = &.{ "git", "rev-parse", "--short=12", "HEAD" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| {
        std.debug.print("warning: git rev-parse 実行に失敗 ({s})、 GIT_HASH を空文字に設定\n", .{@errorName(err)});
        return "";
    };

    var stdout_reader = child.stdout.?.readerStreaming(io, &.{});
    const stdout = stdout_reader.interface.allocRemaining(b.allocator, .limited(64)) catch {
        _ = child.wait(io) catch {};
        std.debug.print("warning: git rev-parse の出力読み取りに失敗、 GIT_HASH を空文字に設定\n", .{});
        return "";
    };

    const term = child.wait(io) catch |err| {
        std.debug.print("warning: git rev-parse の wait に失敗 ({s})、 GIT_HASH を空文字に設定\n", .{@errorName(err)});
        b.allocator.free(stdout);
        return "";
    };

    if (term != .exited or term.exited != 0) {
        b.allocator.free(stdout);
        std.debug.print("warning: git rev-parse の終了コードが非ゼロ、 GIT_HASH を空文字に設定\n", .{});
        return "";
    }

    const trimmed = std.mem.trim(u8, stdout, &std.ascii.whitespace);
    // trim 後の slice は元の stdout を指すため、 build allocator で複製してから stdout を解放
    const dup = b.allocator.dupe(u8, trimmed) catch @panic("OOM");
    b.allocator.free(stdout);
    return dup;
}

/// ファイルサイズを表示するカスタムビルドステップを追加 (UF2 等の汎用バイナリ向け)
fn addFileSizeStep(b: *std.Build, file_path: []const u8, display_name: []const u8) *std.Build.Step {
    const print_step = FileSizeStep.create(b, file_path, display_name);
    return &print_step.step;
}

/// ELF のセクションサイズ (.text/.data/.bss) を linker region 容量と比較表示する
/// カスタムビルドステップを追加。 解析失敗時は FileSizeStep 同等の表示にフォールバック。
fn addElfMemoryUsageStep(b: *std.Build, elf_path: []const u8, display_name: []const u8) *std.Build.Step {
    const step = ElfMemoryUsageStep.create(b, elf_path, display_name);
    return &step.step;
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
        const io = step.owner.graph.io;
        const stat = std.Io.Dir.cwd().statFile(io, self.file_path, .{}) catch |err| {
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

/// ELF メモリ使用状況を解析・表示するカスタム step。
/// rp2040_linker.ld の MEMORY 定義に追従:
///   FLASH       2048K - 4K   (EEPROM 予約)
///   RAM          256K
///   SCRATCH_RAM    8K
const ElfMemoryUsageStep = struct {
    step: std.Build.Step,
    elf_path: []const u8,
    display_name: []const u8,

    /// FLASH 容量 (boot2 含む、 EEPROM 4KB 予約後)
    const flash_capacity_bytes: u64 = (2048 - 4) * 1024;
    /// メイン SRAM 容量
    const ram_capacity_bytes: u64 = 256 * 1024;

    /// FLASH 使用率がこの閾値を超えたら warning
    const flash_warn_pct: u64 = 90;
    /// RAM 使用率がこの閾値を超えたら warning
    const ram_warn_pct: u64 = 80;

    fn create(b: *std.Build, elf_path: []const u8, display_name: []const u8) *ElfMemoryUsageStep {
        const self = b.allocator.create(ElfMemoryUsageStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("elf-memory-usage ({s})", .{display_name}),
                .owner = b,
                .makeFn = make,
            }),
            .elf_path = elf_path,
            .display_name = display_name,
        };
        return self;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        const self: *ElfMemoryUsageStep = @fieldParentPtr("step", step);
        const allocator = step.owner.allocator;
        const io = step.owner.graph.io;

        const file = std.Io.Dir.cwd().openFile(io, self.elf_path, .{}) catch |err| {
            std.debug.print("  {s}: ELF を開けません ({s})\n", .{ self.display_name, @errorName(err) });
            return;
        };
        defer file.close(io);

        const sizes = readElfSectionSizes(io, allocator, file) catch |err| {
            // ELF 解析失敗時は単純なサイズ表示にフォールバック
            std.debug.print("  {s}: ELF section 解析に失敗 ({s})、 ファイルサイズのみ表示\n", .{ self.display_name, @errorName(err) });
            const stat = file.stat(io) catch return;
            std.debug.print("    size: {d} bytes\n", .{stat.size});
            return;
        };

        std.debug.print("  {s}:\n", .{self.display_name});
        printRegion(".text+.rodata", sizes.text, flash_capacity_bytes, flash_warn_pct, "FLASH");
        printRegion(".data        ", sizes.data, ram_capacity_bytes, ram_warn_pct, "RAM");
        printRegion(".bss         ", sizes.bss, ram_capacity_bytes, ram_warn_pct, "RAM");
        // .data + .bss の合算 RAM チェック (個別では下回っても合算で超過する場合に検出)
        printRegion("(.data+.bss) ", sizes.data + sizes.bss, ram_capacity_bytes, ram_warn_pct, "RAM");
    }

    fn printRegion(label: []const u8, used: u64, capacity: u64, warn_pct: u64, region_name: []const u8) void {
        const pct = if (capacity > 0) (used * 100) / capacity else 0;
        std.debug.print("    {s}: {d:.1} KB / {d:.1} KB ({d}%) [{s}]\n", .{
            label,
            @as(f64, @floatFromInt(used)) / 1024.0,
            @as(f64, @floatFromInt(capacity)) / 1024.0,
            pct,
            region_name,
        });
        if (pct >= warn_pct) {
            std.debug.print("    Warning: {s} 使用率が {d}% を超えています ({d}%)\n", .{ region_name, warn_pct, pct });
        }
    }
};

const ElfSectionSizes = struct {
    text: u64,
    data: u64,
    bss: u64,
};

/// ELF を解析して .text+.rodata / .data / .bss のセクションサイズを集計する。
/// std.elf.Header.read は *std.Io.Reader を要求するため、
/// 互換性のため ELF spec に従って手動でヘッダを parse する (readInt のみ使用)。
/// 解析失敗時は error を返し、 呼出側でフォールバックさせる。
fn readElfSectionSizes(io: std.Io, allocator: std.mem.Allocator, file: std.Io.File) !ElfSectionSizes {
    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const elf_bytes = try file_reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(elf_bytes);

    // ELF header 最低サイズ (32bit:52, 64bit:64) を確認
    if (elf_bytes.len < 64) return error.InvalidElf;

    // Magic: \x7fELF
    if (!std.mem.eql(u8, elf_bytes[0..4], "\x7fELF")) return error.InvalidElf;

    // e_class: 1=32bit, 2=64bit (offset 4)
    const e_class = elf_bytes[4];
    const is_64 = e_class == 2;
    if (e_class != 1 and e_class != 2) return error.InvalidElf;

    // ELF header 内の各フィールドオフセット (32bit / 64bit)
    const e_shoff_off: usize = if (is_64) 40 else 32;
    const e_shentsize_off: usize = if (is_64) 58 else 46;
    const e_shnum_off: usize = if (is_64) 60 else 48;
    const e_shstrndx_off: usize = if (is_64) 62 else 50;

    if (elf_bytes.len < e_shstrndx_off + 2) return error.InvalidElf;

    const e_shoff: u64 = if (is_64)
        std.mem.readInt(u64, elf_bytes[e_shoff_off..][0..8], .little)
    else
        std.mem.readInt(u32, elf_bytes[e_shoff_off..][0..4], .little);
    const e_shentsize = std.mem.readInt(u16, elf_bytes[e_shentsize_off..][0..2], .little);
    const e_shnum = std.mem.readInt(u16, elf_bytes[e_shnum_off..][0..2], .little);
    const e_shstrndx = std.mem.readInt(u16, elf_bytes[e_shstrndx_off..][0..2], .little);

    if (e_shstrndx >= e_shnum or e_shnum == 0) return error.InvalidElf;

    // section header 内のフィールドオフセット
    const sh_name_off: usize = 0;
    const sh_offset_off: usize = if (is_64) 24 else 16;
    const sh_size_off: usize = if (is_64) 32 else 20;

    // shstrtab section header から shstrtab 自体のオフセット/サイズを取得
    const shstrtab_sh_pos = e_shoff + @as(u64, e_shstrndx) * @as(u64, e_shentsize);
    if (shstrtab_sh_pos + e_shentsize > elf_bytes.len) return error.InvalidElf;
    const shstrtab_sh_pos_us: usize = @intCast(shstrtab_sh_pos);

    const shstrtab_offset: u64 = if (is_64)
        std.mem.readInt(u64, elf_bytes[shstrtab_sh_pos_us + sh_offset_off ..][0..8], .little)
    else
        std.mem.readInt(u32, elf_bytes[shstrtab_sh_pos_us + sh_offset_off ..][0..4], .little);
    const shstrtab_size: u64 = if (is_64)
        std.mem.readInt(u64, elf_bytes[shstrtab_sh_pos_us + sh_size_off ..][0..8], .little)
    else
        std.mem.readInt(u32, elf_bytes[shstrtab_sh_pos_us + sh_size_off ..][0..4], .little);

    if (shstrtab_offset + shstrtab_size > elf_bytes.len) return error.InvalidElf;
    const shstrtab_off_us: usize = @intCast(shstrtab_offset);
    const shstrtab_size_us: usize = @intCast(shstrtab_size);
    const shstrtab = elf_bytes[shstrtab_off_us .. shstrtab_off_us + shstrtab_size_us];

    var sizes = ElfSectionSizes{ .text = 0, .data = 0, .bss = 0 };

    var i: u16 = 0;
    while (i < e_shnum) : (i += 1) {
        const sh_pos = e_shoff + @as(u64, i) * @as(u64, e_shentsize);
        if (sh_pos + e_shentsize > elf_bytes.len) return error.InvalidElf;
        const sh_pos_us: usize = @intCast(sh_pos);

        const sh_name = std.mem.readInt(u32, elf_bytes[sh_pos_us + sh_name_off ..][0..4], .little);
        const sh_size: u64 = if (is_64)
            std.mem.readInt(u64, elf_bytes[sh_pos_us + sh_size_off ..][0..8], .little)
        else
            std.mem.readInt(u32, elf_bytes[sh_pos_us + sh_size_off ..][0..4], .little);

        if (sh_name >= shstrtab.len) continue;
        const name_end = std.mem.indexOfScalarPos(u8, shstrtab, sh_name, 0) orelse shstrtab.len;
        const name = shstrtab[sh_name..name_end];

        if (std.mem.eql(u8, name, ".text") or std.mem.eql(u8, name, ".rodata")) {
            sizes.text += sh_size;
        } else if (std.mem.eql(u8, name, ".data")) {
            sizes.data += sh_size;
        } else if (std.mem.eql(u8, name, ".bss")) {
            sizes.bss += sh_size;
        }
    }

    return sizes;
}

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
        const io = step.owner.graph.io;
        const file = std.Io.Dir.cwd().openFile(io, self.file_path, .{}) catch |err| {
            std.debug.print("  {s} SHA256: ファイルを開けません ({s})\n", .{ self.display_name, @errorName(err) });
            return;
        };
        defer file.close(io);

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var buf: [4096]u8 = undefined;
        var reader = file.reader(io, &.{});
        while (true) {
            const n = reader.interface.readSliceShort(&buf) catch |err| {
                std.debug.print("  {s} SHA256: 読み取りエラー ({s})\n", .{ self.display_name, @errorName(err) });
                return;
            };
            if (n == 0) break;
            hasher.update(buf[0..n]);
        }
        var digest: [32]u8 = undefined;
        hasher.final(&digest);

        const hex_chars = "0123456789abcdef";
        var hex: [64]u8 = undefined;
        for (digest, 0..) |byte, i| {
            hex[i * 2] = hex_chars[byte >> 4];
            hex[i * 2 + 1] = hex_chars[byte & 0x0f];
        }
        std.debug.print("  {s} SHA256: {s}\n", .{ self.display_name, &hex });
    }
};
