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
//!   - Linux:   /media/<user>/RPI-RP2, /mnt/RPI-RP2, /run/media/<user>/RPI-RP2
//!   - Windows: D:\ through Z:\ (checks volume label "RPI-RP2")

const std = @import("std");
const builtin = @import("builtin");

const BOOTSEL_VOLUME_NAME = "RPI-RP2";

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
        error.BootselNotFound => waitForBootselDrive(allocator) catch |e| return e,
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

    std.fs.cwd().copyFile(uf2_path, std.fs.cwd(), dest_path, .{}) catch |err| {
        std.debug.print("Error: UF2 ファイルのコピーに失敗しました: {}\n", .{err});
        return error.CopyFailed;
    };

    std.debug.print("フラッシュ完了。RP2040 が自動的に再起動します。\n", .{});
}

const timeout_seconds = 60;

fn waitForBootselDrive(allocator: std.mem.Allocator) ![]const u8 {
    std.debug.print(
        \\RP2040 を BOOTSEL モードで接続してください...
        \\  (BOOT ボタンを押しながら USB ケーブルを接続)
        \\  {d}秒以内に検出されない場合はタイムアウトします。
        \\
    , .{timeout_seconds});

    for (0..timeout_seconds * 2) |_| {
        std.time.sleep(500 * std.time.ns_per_ms);
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
    if (isDirectory(path)) {
        return try allocator.dupe(u8, path);
    }
    return error.BootselNotFound;
}

fn detectBootselLinux(allocator: std.mem.Allocator) ![]const u8 {
    // Try /media/$USER/RPI-RP2
    if (std.posix.getenv("USER")) |user| {
        const media_path = try std.fmt.allocPrint(allocator, "/media/{s}/" ++ BOOTSEL_VOLUME_NAME, .{user});
        if (isDirectory(media_path)) {
            return media_path;
        }
        allocator.free(media_path);

        // Try /run/media/$USER/RPI-RP2
        const run_media_path = try std.fmt.allocPrint(allocator, "/run/media/{s}/" ++ BOOTSEL_VOLUME_NAME, .{user});
        if (isDirectory(run_media_path)) {
            return run_media_path;
        }
        allocator.free(run_media_path);
    }

    // Try /mnt/RPI-RP2
    const mnt_path = "/mnt/" ++ BOOTSEL_VOLUME_NAME;
    if (isDirectory(mnt_path)) {
        return try allocator.dupe(u8, mnt_path);
    }

    return error.BootselNotFound;
}

fn detectBootselWindows(allocator: std.mem.Allocator) ![]const u8 {
    // Check drive letters D: through Z:
    const drive_letters = "DEFGHIJKLMNOPQRSTUVWXYZ";
    for (drive_letters) |letter| {
        const drive_path = try std.fmt.allocPrint(allocator, "{c}:\\", .{letter});
        errdefer allocator.free(drive_path);

        // Check if the drive exists and is accessible
        if (isDirectory(drive_path)) {
            // Check for INFO_UF2.TXT which is present on RP2040 BOOTSEL drives
            const info_path = try std.fmt.allocPrint(allocator, "{c}:\\INFO_UF2.TXT", .{letter});
            defer allocator.free(info_path);

            if (fileExists(info_path)) {
                return drive_path;
            }
        }
        allocator.free(drive_path);
    }

    return error.BootselNotFound;
}

fn isDirectory(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
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
