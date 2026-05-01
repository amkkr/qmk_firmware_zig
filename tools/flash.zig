// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! RP2040 BOOTSEL flash tool
//! BOOTSEL モードの RP2040 を検出し、 UF2 ファームウェアをコピーする。
//!
//! 使い方:
//!   flash <firmware.uf2> [オプション]
//!
//! オプション:
//!   --timeout=<秒>          検出待ちの最大秒数 (default: 60、 env QMK_FLASH_TIMEOUT_SEC)
//!   --device-path=<パス>    検出をスキップして直接指定するパス
//!   --device-index=<n>      複数検出時、 0-indexed で n 番目を選ぶ (default: 0)
//!   --verbose               詳細ログ
//!
//! BOOTSEL ドライブの検出パス:
//!   - macOS:   /Volumes/RPI-RP2 (および同名の追加ボリューム)
//!   - Linux:   /run/media/<user>/RPI-RP2, /media/<user>/RPI-RP2, /mnt/RPI-RP2
//!   - Windows: D:\ 〜 Z:\ (INFO_UF2.TXT を確認)
//!
//! 検出されたパスは INFO_UF2.TXT の内容と realpath での正規化結果で検証する。
//! USER 環境変数は許可リスト [A-Za-z0-9._-]{1,32} で内容を検証し、 違反時は次経路へ fallback する。

const std = @import("std");
const builtin = @import("builtin");

const BOOTSEL_VOLUME_NAME = "RPI-RP2";

/// USER 環境変数として許可される最大長 (path injection 緩和)
const MAX_USER_LEN: usize = 32;

const default_timeout_seconds: u64 = 60;
const poll_interval_ms: u64 = 500;
const reboot_confirm_seconds: u64 = 5;
const reboot_poll_interval_ms: u64 = 500;
const copy_chunk_bytes: usize = 4 * 1024;

const Args = struct {
    uf2_path: []const u8,
    timeout_seconds: u64,
    device_path: ?[]const u8,
    device_index: usize,
    verbose: bool,
    auto_reset: bool,
};

const ArgsError = error{
    InvalidArgs,
    HelpRequested,
    InvalidNumber,
};

fn printUsage() void {
    std.debug.print(
        \\使い方: flash <firmware.uf2> [オプション]
        \\
        \\オプション:
        \\  --timeout=<秒>          検出待ちの最大秒数 (default: {d}、 env QMK_FLASH_TIMEOUT_SEC で上書き可)
        \\  --device-path=<パス>    検出をスキップして直接指定するパス
        \\  --device-index=<n>      複数検出時、 0-indexed で n 番目を選ぶ (default: 0)
        \\  --verbose               詳細ログ
        \\  --no-auto-reset         CDC 1200bps タッチによる BOOTSEL 自動リセットを無効化
        \\  --help, -h              このヘルプを表示
        \\
    , .{default_timeout_seconds});
}

fn parseArgs(raw_args: [][:0]u8) ArgsError!Args {
    var positional: ?[]const u8 = null;
    var timeout_seconds: u64 = default_timeout_seconds;
    var device_path: ?[]const u8 = null;
    var device_index: usize = 0;
    var verbose = false;
    var auto_reset = true;

    // 環境変数 QMK_FLASH_TIMEOUT_SEC で default 上書き
    if (std.posix.getenv("QMK_FLASH_TIMEOUT_SEC")) |env_val| {
        if (std.fmt.parseUnsigned(u64, env_val, 10)) |n| {
            timeout_seconds = n;
        } else |_| {
            std.debug.print("Warning: 環境変数 QMK_FLASH_TIMEOUT_SEC の値 ({s}) が不正、 default 値を使用\n", .{env_val});
        }
    }

    var i: usize = 1; // skip argv[0]
    while (i < raw_args.len) : (i += 1) {
        const arg = raw_args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return ArgsError.HelpRequested;
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            const v = arg["--timeout=".len..];
            timeout_seconds = std.fmt.parseUnsigned(u64, v, 10) catch {
                std.debug.print("Error: --timeout の値が不正です (符号なし整数を指定): {s}\n", .{v});
                return ArgsError.InvalidNumber;
            };
        } else if (std.mem.startsWith(u8, arg, "--device-path=")) {
            device_path = arg["--device-path=".len..];
        } else if (std.mem.startsWith(u8, arg, "--device-index=")) {
            const v = arg["--device-index=".len..];
            device_index = std.fmt.parseUnsigned(usize, v, 10) catch {
                std.debug.print("Error: --device-index の値が不正です (符号なし整数を指定): {s}\n", .{v});
                return ArgsError.InvalidNumber;
            };
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--no-auto-reset")) {
            auto_reset = false;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("Error: 未知のオプション: {s}\n", .{arg});
            return ArgsError.InvalidArgs;
        } else {
            if (positional != null) {
                std.debug.print("Error: 引数が多すぎます: {s}\n", .{arg});
                return ArgsError.InvalidArgs;
            }
            positional = arg;
        }
    }

    const uf2_path = positional orelse {
        std.debug.print("Error: UF2 ファイルパスを指定してください\n", .{});
        return ArgsError.InvalidArgs;
    };

    return Args{
        .uf2_path = uf2_path,
        .timeout_seconds = timeout_seconds,
        .device_path = device_path,
        .device_index = device_index,
        .verbose = verbose,
        .auto_reset = auto_reset,
    };
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    const args = parseArgs(raw_args) catch |err| switch (err) {
        ArgsError.HelpRequested => {
            printUsage();
            return;
        },
        ArgsError.InvalidArgs, ArgsError.InvalidNumber => {
            printUsage();
            return error.InvalidArgs;
        },
    };

    // UF2 ファイルの存在確認
    std.fs.cwd().access(args.uf2_path, .{}) catch {
        std.debug.print("Error: UF2 ファイルが見つかりません: {s}\n", .{args.uf2_path});
        return error.Uf2NotFound;
    };

    // BOOTSEL ドライブを取得 (--device-path 指定 / 検出 / 待機)
    const bootsel_path = try resolveBootselPath(allocator, args);
    defer allocator.free(bootsel_path);

    std.debug.print("RP2040 BOOTSEL ドライブを検出: {s}\n", .{bootsel_path});

    // 書込先パス (basename のみ使うため path traversal は無し)
    const dest_path = try std.fs.path.join(allocator, &.{ bootsel_path, std.fs.path.basename(args.uf2_path) });
    defer allocator.free(dest_path);

    if (args.verbose) {
        std.debug.print("詳細: 書込先 = {s}\n", .{dest_path});
    }

    std.debug.print("フラッシュ中: {s} -> {s}\n", .{ args.uf2_path, dest_path });

    // TOCTOU 緩和: 書込直前にもう一度ドライブ妥当性を検証
    if (!verifyBootselDrive(allocator, bootsel_path)) {
        std.debug.print("Error: 書込直前の検証で BOOTSEL ドライブが妥当でないと判定されました: {s}\n", .{bootsel_path});
        return error.BootselNotFound;
    }

    copyFileWithProgress(args.uf2_path, dest_path, args.verbose) catch |err| {
        std.debug.print("Error: UF2 ファイルのコピーに失敗しました: {}\n", .{err});
        return error.CopyFailed;
    };

    std.debug.print("フラッシュ完了。RP2040 の再起動を確認しています...\n", .{});

    // 書込後、 BOOTSEL ドライブが消失するのを 5 秒間ポーリング (RP2040 の再起動確認)。
    // RP2040 のリブート + OS の unmount 反映には実測 2-3 秒かかるため、 5 秒の余裕を取る。
    if (waitForBootselDisappear(bootsel_path)) {
        std.debug.print("RP2040 の再起動を確認しました。\n", .{});
    } else {
        std.debug.print("Warning: 書込は完了しましたが RP2040 の再起動が {d} 秒以内に確認できませんでした。\n", .{reboot_confirm_seconds});
        std.debug.print("        手動で USB 接続を確認してください。\n", .{});
    }
}

/// args に基づいて BOOTSEL パスを取得する。
/// - --device-path 指定時はそのパスを検証して返す
/// - それ以外は detect → 1 件なら採用、 複数なら --device-index で選択
/// - 見つからなければ auto-reset を試行 (CDC 1200bps タッチで BOOTSEL モードへ遷移)
/// - それでも見つからなければ args.timeout_seconds 待機して再検出
fn resolveBootselPath(allocator: std.mem.Allocator, args: Args) ![]const u8 {
    if (args.device_path) |path| {
        if (!verifyBootselDrive(allocator, path)) {
            std.debug.print("Error: 指定された --device-path が BOOTSEL ドライブではありません: {s}\n", .{path});
            return error.BootselNotFound;
        }
        return try allocator.dupe(u8, path);
    }

    // 検出 (1 回目)
    if (try selectBootselFromDetected(allocator, args)) |path| return path;

    // BOOTSEL 自動リセットを試行 (CDC 1200bps タッチ、 ファーム側 D1 と協調)
    if (args.auto_reset) {
        attempt1200bpsTouch(allocator, args.verbose);
        // タッチ後の BOOTSEL ドライブ出現を待つ (短時間)
        const auto_reset_max_iter = 10 * std.time.ms_per_s / poll_interval_ms;
        for (0..auto_reset_max_iter) |_| {
            std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms);
            if (try selectBootselFromDetected(allocator, args)) |path| return path;
        }
    }

    // 待機ループ
    std.debug.print(
        \\RP2040 を BOOTSEL モードで接続してください...
        \\  (BOOT ボタンを押しながら USB ケーブルを接続、 または --no-auto-reset を指定)
        \\  {d}秒以内に検出されない場合はタイムアウトします。
        \\
    , .{args.timeout_seconds});

    const max_iterations = args.timeout_seconds * std.time.ms_per_s / poll_interval_ms;
    for (0..max_iterations) |_| {
        std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms);
        if (try selectBootselFromDetected(allocator, args)) |path| return path;
    }

    std.debug.print("Error: タイムアウト。RP2040 が検出されませんでした。\n", .{});
    return error.BootselNotFound;
}

/// 全候補を列挙し、 args.device_index で選択する。 検出なし → null、 index 範囲外なら error。
fn selectBootselFromDetected(allocator: std.mem.Allocator, args: Args) !?[]const u8 {
    var candidates = std.ArrayList([]const u8){};
    defer {
        for (candidates.items) |c| allocator.free(c);
        candidates.deinit(allocator);
    }

    try detectAllBootsel(allocator, &candidates);

    if (candidates.items.len == 0) return null;

    if (args.verbose or candidates.items.len > 1) {
        std.debug.print("検出された BOOTSEL ドライブ ({d} 件):\n", .{candidates.items.len});
        for (candidates.items, 0..) |c, i| {
            std.debug.print("  [{d}] {s}\n", .{ i, c });
        }
    }

    if (args.device_index >= candidates.items.len) {
        std.debug.print("Error: --device-index={d} は範囲外です (検出 {d} 件)\n", .{ args.device_index, candidates.items.len });
        return error.InvalidArgs;
    }

    // 選択された候補だけ複製、 残りは defer で解放
    return try allocator.dupe(u8, candidates.items[args.device_index]);
}

/// CDC ACM の line_coding を 1200bps に設定して BOOTSEL モードへの遷移をトリガする
/// (Arduino / picotool 互換)。 ファーム側の set_line_coding ハンドラが dwDTERate == 1200
/// を検出して bootloader.jump() を呼ぶことで RP2040 が BOOTSEL モードへ再起動する。
/// 失敗しても warning を出すだけでフォールバック (BOOTSEL ドライブ検出待ち) を継続する。
fn attempt1200bpsTouch(allocator: std.mem.Allocator, verbose: bool) void {
    const ports = findCdcPorts(allocator) catch |err| {
        if (verbose) std.debug.print("詳細: CDC ポート検索失敗 ({s})、 1200bps タッチをスキップ\n", .{@errorName(err)});
        return;
    };
    defer {
        for (ports) |p| allocator.free(p);
        allocator.free(ports);
    }

    if (ports.len == 0) {
        if (verbose) std.debug.print("詳細: CDC ポートが見つからず、 1200bps タッチをスキップ\n", .{});
        return;
    }

    for (ports) |port| {
        std.debug.print("RP2040 を BOOTSEL に遷移中 ({s} を 1200bps でタッチ)...\n", .{port});
        runStty1200bps(allocator, port, verbose) catch |err| {
            std.debug.print("Warning: {s} の 1200bps タッチ失敗 ({s})、 次のポートを試行\n", .{ port, @errorName(err) });
            continue;
        };
    }
}

/// CDC ACM 用のシリアルポートを列挙する。 OS 別:
/// - macOS: /dev/cu.usbmodem* を glob
/// - Linux: /dev/ttyACM* を glob
/// - その他: 空配列を返す (未対応)
fn findCdcPorts(allocator: std.mem.Allocator) ![][]const u8 {
    var ports = std.ArrayList([]const u8){};
    errdefer {
        for (ports.items) |p| allocator.free(p);
        ports.deinit(allocator);
    }

    const dir_path: []const u8 = switch (builtin.os.tag) {
        .macos => "/dev",
        .linux => "/dev",
        else => return ports.toOwnedSlice(allocator),
    };

    const prefix: []const u8 = switch (builtin.os.tag) {
        .macos => "cu.usbmodem",
        .linux => "ttyACM",
        else => return ports.toOwnedSlice(allocator),
    };

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return ports.toOwnedSlice(allocator);
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        const port = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        try ports.append(allocator, port);
    }
    return ports.toOwnedSlice(allocator);
}

/// stty コマンドで指定 tty を 1200bps に設定して短時間 open する (1200bps タッチ)。
/// macOS は `-f`、 Linux は `-F` でデバイスを指定する。
fn runStty1200bps(allocator: std.mem.Allocator, port: []const u8, verbose: bool) !void {
    const flag = switch (builtin.os.tag) {
        .macos => "-f",
        .linux => "-F",
        else => return error.UnsupportedOs,
    };

    var child = std.process.Child.init(&.{ "stty", flag, port, "1200" }, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = if (verbose) .Inherit else .Ignore;

    const term = try child.spawnAndWait();
    if (term != .Exited or term.Exited != 0) {
        return error.SttyFailed;
    }
}

/// プラットフォーム依存の全候補列挙。 候補は BOOTSEL_VOLUME_NAME 名のディレクトリで、
/// verifyBootselDrive を満たすもののみ返す。
fn detectAllBootsel(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    switch (builtin.os.tag) {
        .macos => try detectAllBootselMacos(allocator, out),
        .linux => try detectAllBootselLinux(allocator, out),
        .windows => try detectAllBootselWindows(allocator, out),
        else => {
            std.debug.print("Warning: 未対応の OS です。--device-path で手動指定してください。\n", .{});
        },
    }
}

fn detectAllBootselMacos(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    // /Volumes/RPI-RP2 に加え、 macOS は同名追加マウント時に "RPI-RP2 1", "RPI-RP2 2", ... を作る
    var dir = std.fs.cwd().openDir("/Volumes", .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        if (!std.mem.startsWith(u8, entry.name, BOOTSEL_VOLUME_NAME)) continue;
        const candidate = try std.fmt.allocPrint(allocator, "/Volumes/{s}", .{entry.name});
        if (verifyBootselDrive(allocator, candidate)) {
            try out.append(allocator, candidate);
        } else {
            allocator.free(candidate);
        }
    }
}

fn detectAllBootselLinux(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    // USER 環境変数を許可リストで検証 (違反時は USER 経由パスをスキップ)
    if (std.posix.getenv("USER")) |user| {
        if (isValidUser(user)) {
            // /run/media/$USER/RPI-RP2 (近年のディストリの既定)
            const run_media_path = try std.fmt.allocPrint(allocator, "/run/media/{s}/" ++ BOOTSEL_VOLUME_NAME, .{user});
            if (verifyBootselDrive(allocator, run_media_path)) {
                try out.append(allocator, run_media_path);
            } else {
                allocator.free(run_media_path);
            }

            // /media/$USER/RPI-RP2 (旧 udisks)
            const media_path = try std.fmt.allocPrint(allocator, "/media/{s}/" ++ BOOTSEL_VOLUME_NAME, .{user});
            if (verifyBootselDrive(allocator, media_path)) {
                try out.append(allocator, media_path);
            } else {
                allocator.free(media_path);
            }
        }
    }

    // /mnt/RPI-RP2 (手動 mount のフォールバック)
    const mnt_path = "/mnt/" ++ BOOTSEL_VOLUME_NAME;
    if (verifyBootselDrive(allocator, mnt_path)) {
        try out.append(allocator, try allocator.dupe(u8, mnt_path));
    }
}

fn detectAllBootselWindows(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    // ドライブレター D: 〜 Z: をスキャン
    const drive_letters = "DEFGHIJKLMNOPQRSTUVWXYZ";
    for (drive_letters) |letter| {
        const drive_path = try std.fmt.allocPrint(allocator, "{c}:\\", .{letter});
        if (verifyBootselDrive(allocator, drive_path)) {
            try out.append(allocator, drive_path);
        } else {
            allocator.free(drive_path);
        }
    }
}

/// 4KB チャンクずつコピーし、 進捗を `\r{percent}% ({bytes}/{total})` で stderr 表示する。
fn copyFileWithProgress(src_path: []const u8, dest_path: []const u8, verbose: bool) !void {
    var src = try std.fs.cwd().openFile(src_path, .{});
    defer src.close();

    const total_bytes = (try src.stat()).size;

    var dest = try std.fs.cwd().createFile(dest_path, .{ .truncate = true });
    defer dest.close();

    var buf: [copy_chunk_bytes]u8 = undefined;
    var copied: u64 = 0;
    // エラー早期リターン時、 進捗行 (\r) がカーソルに残ると main のエラー出力と混ざるため
    // copied > 0 のときのみ改行を入れて行頭に戻す
    errdefer if (copied > 0) std.debug.print("\n", .{});

    while (true) {
        const n = try src.read(&buf);
        if (n == 0) break;
        try dest.writeAll(buf[0..n]);
        copied += n;

        if (total_bytes > 0) {
            const percent = (copied * 100) / total_bytes;
            std.debug.print("\r進捗: {d}% ({d}/{d} bytes)", .{ percent, copied, total_bytes });
        }
    }
    // 進捗行が出力されていた場合のみ改行で終わらせる (空ファイル時は不要)
    if (total_bytes > 0) {
        std.debug.print("\n", .{});
    }
    if (verbose) {
        std.debug.print("詳細: 書込バイト数 = {d}\n", .{copied});
    }
}

/// BOOTSEL ドライブが消失する (RP2040 が再起動して unmount される) のを reboot_confirm_seconds 秒待機する。
/// 消失を確認できれば true、 タイムアウトで残存していれば false を返す。
fn waitForBootselDisappear(bootsel_path: []const u8) bool {
    const max_iterations = reboot_confirm_seconds * std.time.ms_per_s / reboot_poll_interval_ms;
    for (0..max_iterations) |_| {
        std.Thread.sleep(reboot_poll_interval_ms * std.time.ns_per_ms);
        // realpath が失敗 = ディレクトリ消失と判定
        var realbuf: [std.fs.max_path_bytes]u8 = undefined;
        _ = std.fs.realpath(bootsel_path, &realbuf) catch {
            return true;
        };
    }
    return false;
}

/// USER 環境変数の内容を許可リスト [A-Za-z0-9._-]{1,MAX_USER_LEN} で検証する。
/// path injection (`USER=../../tmp/x` 等) や log injection (制御文字) を防ぐ。
fn isValidUser(user: []const u8) bool {
    if (user.len == 0 or user.len > MAX_USER_LEN) return false;
    for (user) |c| {
        const ok = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '.' or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// realpath で正規化されたパスが各 OS の許可された prefix で始まるかを検証する。
/// symlink で意図しないディレクトリを指している場合に拒否する。
fn isAllowedRealPath(real_path: []const u8) bool {
    return switch (builtin.os.tag) {
        .macos => std.mem.startsWith(u8, real_path, "/Volumes/"),
        .linux => std.mem.startsWith(u8, real_path, "/run/media/") or
            std.mem.startsWith(u8, real_path, "/media/") or
            std.mem.startsWith(u8, real_path, "/mnt/"),
        // Windows はドライブレター直下なので prefix チェックを行わない
        else => true,
    };
}

/// 与えられたパスが RP2040 BOOTSEL ドライブとして妥当かを検証する。
/// 1. realpath で正規化、 OS 別の許可 prefix を満たすか (symlink 拒否)
/// 2. INFO_UF2.TXT が存在し、 "UF2 Bootloader" または "RPI-RP2" を含むか
///
/// 注: 本検証は **誤書込防止** が目的であり、 敵対的な攻撃 (偽 INFO_UF2.TXT 配置) は防げない。
/// 強い真贋検証が必要な場合は picotool バックエンドの USB VID/PID 検証を使うこと。
fn verifyBootselDrive(allocator: std.mem.Allocator, path: []const u8) bool {
    // 1. realpath で正規化
    var realbuf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = std.fs.realpath(path, &realbuf) catch return false;
    if (!isAllowedRealPath(real_path)) return false;

    // 2. INFO_UF2.TXT 読み込み + 内容検証
    const info_path = std.fs.path.join(allocator, &.{ path, "INFO_UF2.TXT" }) catch return false;
    defer allocator.free(info_path);

    var file = std.fs.cwd().openFile(info_path, .{}) catch return false;
    defer file.close();

    var buf: [1024]u8 = undefined;
    const n = file.readAll(&buf) catch return false;
    const content = buf[0..n];

    // "UF2 Bootloader" (BOOTSEL の標準ヘッダ) か "RPI-RP2" (Board-ID) のどちらかを含む
    return std.mem.indexOf(u8, content, "UF2 Bootloader") != null or
        std.mem.indexOf(u8, content, "RPI-RP2") != null;
}

test "isValidUser accepts allowed characters" {
    const testing = std.testing;
    try testing.expect(isValidUser("alice"));
    try testing.expect(isValidUser("bob123"));
    try testing.expect(isValidUser("user.name"));
    try testing.expect(isValidUser("user_name"));
    try testing.expect(isValidUser("user-name"));
    try testing.expect(isValidUser("a"));
    try testing.expect(isValidUser("A_B.C-1"));
}

test "isValidUser rejects invalid characters and lengths" {
    const testing = std.testing;
    try testing.expect(!isValidUser(""));
    try testing.expect(!isValidUser("user/name"));
    try testing.expect(!isValidUser("../etc"));
    try testing.expect(!isValidUser("user name"));
    try testing.expect(!isValidUser("user;name"));
    try testing.expect(!isValidUser("user\nname"));
    try testing.expect(!isValidUser("user\x00null"));
    // 33 文字 (上限 32 を超える)
    try testing.expect(!isValidUser("a" ** 33));
}

test "isAllowedRealPath enforces OS prefix" {
    const testing = std.testing;
    switch (builtin.os.tag) {
        .macos => {
            try testing.expect(isAllowedRealPath("/Volumes/RPI-RP2"));
            try testing.expect(!isAllowedRealPath("/tmp/RPI-RP2"));
            try testing.expect(!isAllowedRealPath("/Users/x/RPI-RP2"));
        },
        .linux => {
            try testing.expect(isAllowedRealPath("/run/media/alice/RPI-RP2"));
            try testing.expect(isAllowedRealPath("/media/alice/RPI-RP2"));
            try testing.expect(isAllowedRealPath("/mnt/RPI-RP2"));
            try testing.expect(!isAllowedRealPath("/tmp/RPI-RP2"));
            try testing.expect(!isAllowedRealPath("/home/alice/RPI-RP2"));
        },
        .windows => {
            // Windows はドライブレター直下なので true 固定
            try testing.expect(isAllowedRealPath("D:\\"));
        },
        else => {},
    }
}

test "verifyBootselDrive rejects directory with disallowed prefix" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &buf);

    // testing.tmpDir() は通常 /tmp/... 配下に作られるため、 isAllowedRealPath が false を返す。
    // verifyBootselDrive は INFO_UF2.TXT 内容検証に到達する前に拒否する。
    // INFO_UF2.TXT 不存在の検証経路は許可 prefix 内ディレクトリが必要なため CI 環境では別途扱う。
    try testing.expect(!verifyBootselDrive(testing.allocator, tmp_path));
}

test "verifyBootselDrive rejects non-existent path matching allowed-prefix pattern" {
    // 許可 prefix 内 (例: /Volumes/, /run/media/) に書込権限を持つ CI 環境は通常存在しないため、
    // INFO_UF2.TXT 不存在の検証経路を直接テストすることは難しい。 ここでは存在しないパスを与え、
    // realpath が失敗して false が返る経路のみを確認する。
    // 「INFO_UF2.TXT 不存在で false を返す」経路は openFile catch return false の挙動に依拠しており、
    // 別途 integration test もしくは実機検証で確認する。
    const testing = std.testing;
    const fake_path = switch (builtin.os.tag) {
        .macos => "/Volumes/__nonexistent_qmk_test__",
        .linux => "/run/media/__nonexistent__/__nonexistent_qmk_test__",
        else => return error.SkipZigTest,
    };
    try testing.expect(!verifyBootselDrive(testing.allocator, fake_path));
}

test "verifyBootselDrive rejects symlink to outside directory" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // symlink テストは POSIX のみ
    const testing = std.testing;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &buf);

    // tmp_dir 内に target_dir を作り、 INFO_UF2.TXT を BOOTSEL らしく配置 (偽装)
    try tmp_dir.dir.makeDir("target_dir");
    try tmp_dir.dir.writeFile(.{
        .sub_path = "target_dir/INFO_UF2.TXT",
        .data = "UF2 Bootloader v3.0\nBoard-ID: RPI-RP2\n",
    });

    // target_dir の絶対パスと、 tmp_path 内に置く symlink "RPI-RP2" の絶対パス
    const target_abs = try std.fs.path.join(testing.allocator, &.{ tmp_path, "target_dir" });
    defer testing.allocator.free(target_abs);
    const link_abs = try std.fs.path.join(testing.allocator, &.{ tmp_path, "RPI-RP2" });
    defer testing.allocator.free(link_abs);

    std.posix.symlink(target_abs, link_abs) catch |err| switch (err) {
        // CI 環境等で symlink が許可されない場合はスキップ
        error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };

    // tmp_path は /Volumes/ や /run/media/ 等の許可 prefix にないため、
    // realpath が許可 prefix を満たさず、 verifyBootselDrive は false を返すはず
    try testing.expect(!verifyBootselDrive(testing.allocator, link_abs));
}

test "copyFileWithProgress copies file contents correctly" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // チャンク境界を跨ぐサイズで src を書く (4KB+1 で 2 チャンク)
    var src_content: [copy_chunk_bytes + 1]u8 = undefined;
    for (&src_content, 0..) |*b, i| b.* = @intCast(i & 0xff);
    try tmp_dir.dir.writeFile(.{ .sub_path = "src.uf2", .data = &src_content });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &buf);
    const src_path = try std.fs.path.join(allocator, &.{ tmp_path, "src.uf2" });
    defer allocator.free(src_path);
    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "dest.uf2" });
    defer allocator.free(dest_path);

    try copyFileWithProgress(src_path, dest_path, false);

    const dest_content = try tmp_dir.dir.readFileAlloc(allocator, "dest.uf2", copy_chunk_bytes * 2);
    defer allocator.free(dest_content);
    try testing.expectEqualSlices(u8, &src_content, dest_content);
}

test "parseArgs accepts positional and options" {
    const testing = std.testing;
    var args_buf = [_][:0]u8{
        @constCast("flash"),
        @constCast("--timeout=120"),
        @constCast("--device-index=2"),
        @constCast("--verbose"),
        @constCast("firmware.uf2"),
    };
    const a = try parseArgs(&args_buf);
    try testing.expectEqualStrings("firmware.uf2", a.uf2_path);
    try testing.expectEqual(@as(u64, 120), a.timeout_seconds);
    try testing.expectEqual(@as(usize, 2), a.device_index);
    try testing.expect(a.verbose);
    // auto_reset は default で有効
    try testing.expect(a.auto_reset);
}

test "parseArgs --no-auto-reset disables auto reset" {
    const testing = std.testing;
    var args_buf = [_][:0]u8{
        @constCast("flash"),
        @constCast("--no-auto-reset"),
        @constCast("firmware.uf2"),
    };
    const a = try parseArgs(&args_buf);
    try testing.expect(!a.auto_reset);
}

test "parseArgs accepts device-path" {
    const testing = std.testing;
    var args_buf = [_][:0]u8{
        @constCast("flash"),
        @constCast("--device-path=/Volumes/RPI-RP2"),
        @constCast("firmware.uf2"),
    };
    const a = try parseArgs(&args_buf);
    try testing.expect(a.device_path != null);
    try testing.expectEqualStrings("/Volumes/RPI-RP2", a.device_path.?);
}

test "parseArgs rejects unknown options" {
    const testing = std.testing;
    var args_buf = [_][:0]u8{
        @constCast("flash"),
        @constCast("--unknown"),
        @constCast("firmware.uf2"),
    };
    const r = parseArgs(&args_buf);
    try testing.expectError(ArgsError.InvalidArgs, r);
}

test "parseArgs requires positional uf2 path" {
    const testing = std.testing;
    var args_buf = [_][:0]u8{
        @constCast("flash"),
    };
    const r = parseArgs(&args_buf);
    try testing.expectError(ArgsError.InvalidArgs, r);
}
