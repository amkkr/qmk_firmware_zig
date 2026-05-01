// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! RP2040 BOOTSEL flash tool
//! Detects RP2040 in BOOTSEL mode and copies UF2 firmware file to it.
//!
//! Usage:
//!   flash <firmware.uf2>
//!
//! The tool searches for the RP2040 BOOTSEL drive ("RPI-RP2") at:
//!   - macOS:   /Volumes/RPI-RP2
//!   - Linux:   /run/media/<user>/RPI-RP2, /media/<user>/RPI-RP2, /mnt/RPI-RP2
//!   - Windows: D:\ through Z:\ (checks INFO_UF2.TXT)
//!
//! 検出されたパスは INFO_UF2.TXT の内容と realpath での正規化結果で検証する。
//! USER 環境変数は許可リスト [A-Za-z0-9._-]{1,32} で内容を検証し、 違反時は次経路へ fallback する。

const std = @import("std");
const builtin = @import("builtin");

const BOOTSEL_VOLUME_NAME = "RPI-RP2";

/// USER 環境変数として許可される最大長 (path injection 緩和)
const MAX_USER_LEN: usize = 32;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        std.debug.print("Usage: flash <firmware.uf2>\n", .{});
        return error.InvalidArgs;
    }

    const uf2_path = args[1];

    // Verify UF2 file exists
    std.fs.cwd().access(uf2_path, .{}) catch {
        std.debug.print("Error: UF2 file not found: {s}\n", .{uf2_path});
        return error.Uf2NotFound;
    };

    // Detect BOOTSEL drive (wait for it if not found)
    const bootsel_path = detectBootselDrive(allocator) catch |err| switch (err) {
        error.BootselNotFound => try waitForBootselDrive(allocator),
        else => return err,
    };
    defer allocator.free(bootsel_path);

    std.debug.print("RP2040 BOOTSEL ドライブを検出: {s}\n", .{bootsel_path});

    // Copy UF2 file to BOOTSEL drive
    const dest_path = std.fs.path.join(allocator, &.{ bootsel_path, std.fs.path.basename(uf2_path) }) catch {
        return error.OutOfMemory;
    };
    defer allocator.free(dest_path);

    std.debug.print("フラッシュ中: {s} -> {s}\n", .{ uf2_path, dest_path });

    // TOCTOU 緩和: 書込直前にもう一度ドライブ妥当性を検証
    if (!verifyBootselDrive(allocator, bootsel_path)) {
        std.debug.print("Error: 書込直前の検証で BOOTSEL ドライブが妥当でないと判定されました: {s}\n", .{bootsel_path});
        return error.BootselNotFound;
    }

    std.fs.cwd().copyFile(uf2_path, std.fs.cwd(), dest_path, .{}) catch |err| {
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

const reboot_confirm_seconds = 5;
const reboot_poll_interval_ms = 500;

/// BOOTSEL ドライブが消失する (RP2040 が再起動して unmount される) のを reboot_confirm_seconds 秒待機する。
/// 消失を確認できれば true、 タイムアウトで残存していれば false を返す。
fn waitForBootselDisappear(bootsel_path: []const u8) bool {
    const max_iterations = reboot_confirm_seconds * std.time.ms_per_s / reboot_poll_interval_ms;
    var i: usize = 0;
    while (i < max_iterations) : (i += 1) {
        std.Thread.sleep(reboot_poll_interval_ms * std.time.ns_per_ms);
        // realpath が失敗 = ディレクトリ消失と判定
        var realbuf: [std.fs.max_path_bytes]u8 = undefined;
        _ = std.fs.realpath(bootsel_path, &realbuf) catch {
            return true;
        };
    }
    return false;
}

const timeout_seconds = 60;
const poll_interval_ms = 500;

fn waitForBootselDrive(allocator: std.mem.Allocator) ![]const u8 {
    std.debug.print(
        \\RP2040 を BOOTSEL モードで接続してください...
        \\  (BOOT ボタンを押しながら USB ケーブルを接続)
        \\  {d}秒以内に検出されない場合はタイムアウトします。
        \\
    , .{timeout_seconds});

    for (0..timeout_seconds * std.time.ms_per_s / poll_interval_ms) |_| {
        std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms);
        if (detectBootselDrive(allocator)) |path| {
            return path;
        } else |err| {
            if (err != error.BootselNotFound) return err;
        }
    }

    std.debug.print("Error: タイムアウト。RP2040 が検出されませんでした。\n", .{});
    return error.BootselNotFound;
}

fn detectBootselDrive(allocator: std.mem.Allocator) ![]const u8 {
    return switch (builtin.os.tag) {
        .macos => detectBootselMacos(allocator),
        .linux => detectBootselLinux(allocator),
        .windows => detectBootselWindows(allocator),
        else => {
            std.debug.print("Warning: 未対応の OS です。手動で UF2 ファイルをコピーしてください。\n", .{});
            return error.BootselNotFound;
        },
    };
}

fn detectBootselMacos(allocator: std.mem.Allocator) ![]const u8 {
    const path = "/Volumes/" ++ BOOTSEL_VOLUME_NAME;
    if (verifyBootselDrive(allocator, path)) {
        return try allocator.dupe(u8, path);
    }
    return error.BootselNotFound;
}

fn detectBootselLinux(allocator: std.mem.Allocator) ![]const u8 {
    // USER 環境変数を許可リストで検証 (違反時は次経路へ fallback)
    if (std.posix.getenv("USER")) |user| {
        if (isValidUser(user)) {
            // /run/media/$USER/RPI-RP2 を最優先 (systemd-mount, 近年のディストリの既定)
            const run_media_path = try std.fmt.allocPrint(allocator, "/run/media/{s}/" ++ BOOTSEL_VOLUME_NAME, .{user});
            if (verifyBootselDrive(allocator, run_media_path)) {
                return run_media_path;
            }
            allocator.free(run_media_path);

            // /media/$USER/RPI-RP2 (旧 udisks)
            const media_path = try std.fmt.allocPrint(allocator, "/media/{s}/" ++ BOOTSEL_VOLUME_NAME, .{user});
            if (verifyBootselDrive(allocator, media_path)) {
                return media_path;
            }
            allocator.free(media_path);
        }
    }

    // /mnt/RPI-RP2 (手動 mount のフォールバック)
    const mnt_path = "/mnt/" ++ BOOTSEL_VOLUME_NAME;
    if (verifyBootselDrive(allocator, mnt_path)) {
        return try allocator.dupe(u8, mnt_path);
    }

    return error.BootselNotFound;
}

fn detectBootselWindows(allocator: std.mem.Allocator) ![]const u8 {
    // ドライブレター D: 〜 Z: をスキャン
    const drive_letters = "DEFGHIJKLMNOPQRSTUVWXYZ";
    for (drive_letters) |letter| {
        const drive_path = try std.fmt.allocPrint(allocator, "{c}:\\", .{letter});
        if (verifyBootselDrive(allocator, drive_path)) {
            return drive_path;
        }
        allocator.free(drive_path);
    }

    return error.BootselNotFound;
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

test "copyFile copies file contents correctly" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Write source file content
    const src_content = "test UF2 content\x00\x01\x02";
    try tmp_dir.dir.writeFile(.{ .sub_path = "src.uf2", .data = src_content });

    // Build absolute paths for copyFile
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &buf);
    const src_path = try std.fs.path.join(allocator, &.{ tmp_path, "src.uf2" });
    defer allocator.free(src_path);
    const dest_path = try std.fs.path.join(allocator, &.{ tmp_path, "dest.uf2" });
    defer allocator.free(dest_path);

    // Use std.fs.cwd().copyFile (standard library function)
    try std.fs.cwd().copyFile(src_path, std.fs.cwd(), dest_path, .{});

    // Verify file contents match
    const dest_content = try tmp_dir.dir.readFileAlloc(allocator, "dest.uf2", 1024);
    defer allocator.free(dest_content);
    try testing.expectEqualStrings(src_content, dest_content);
}
