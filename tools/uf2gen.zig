// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! UF2 file generator for RP2040
//! Converts raw binary firmware to UF2 format
//! See: https://github.com/microsoft/uf2
//!
//! Usage:
//!   uf2gen <input.bin> <output.uf2> [boot2.bin]
//!
//! If boot2.bin is provided (256 bytes, CRC32-padded), it will be placed at
//! flash address 0x10000000. Firmware is placed at 0x10000100.
//! If boot2.bin is omitted, firmware starts at 0x10000100 without boot2.
//!
//! Boot2 binaries can be obtained from pico-sdk (boot_stage2/).

const std = @import("std");

const UF2_MAGIC_START0: u32 = 0x0A324655; // "UF2\n"
const UF2_MAGIC_START1: u32 = 0x9E5D5157;
const UF2_MAGIC_END: u32 = 0x0AB16F30;
const UF2_FLAG_FAMILY_ID: u32 = 0x00002000;
const RP2040_FAMILY_ID: u32 = 0xe48bff56;
const FLASH_BASE: u32 = 0x10000000;
const FIRMWARE_BASE: u32 = 0x10000100; // Application starts after 256-byte boot2
const PAYLOAD_SIZE: u32 = 256;
const BLOCK_SIZE: u32 = 512;
const BOOT2_SIZE: u32 = 256;

const UF2Block = extern struct {
    magic_start0: u32 = UF2_MAGIC_START0,
    magic_start1: u32 = UF2_MAGIC_START1,
    flags: u32 = UF2_FLAG_FAMILY_ID,
    target_addr: u32,
    payload_size: u32 = PAYLOAD_SIZE,
    block_no: u32,
    num_blocks: u32,
    family_id: u32 = RP2040_FAMILY_ID,
    data: [476]u8 = .{0} ** 476,
    magic_end: u32 = UF2_MAGIC_END,

    comptime {
        if (@sizeOf(UF2Block) != BLOCK_SIZE) {
            @compileError("UF2Block size must be 512 bytes");
        }
    }
};

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    if (args.len < 3 or args.len > 4) {
        std.debug.print("Usage: uf2gen <input.bin> <output.uf2> [boot2.bin]\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("  boot2.bin  Optional: 256-byte boot2 binary (from pico-sdk boot_stage2/)\n", .{});
        std.debug.print("             Required for firmware to boot on real RP2040 hardware.\n", .{});
        return error.InvalidArgs;
    }

    const input_path = args[1];
    const output_path = args[2];
    const boot2_path: ?[]const u8 = if (args.len == 4) args[3] else null;

    // Read firmware binary
    const input_file = try std.fs.cwd().openFile(input_path, .{});
    defer input_file.close();
    const firmware_data = try input_file.readToEndAlloc(std.heap.page_allocator, 2 * 1024 * 1024);
    defer std.heap.page_allocator.free(firmware_data);

    // Read boot2 binary (optional)
    var boot2_data: ?[]u8 = null;
    defer if (boot2_data) |d| std.heap.page_allocator.free(d);
    if (boot2_path) |path| {
        const boot2_file = try std.fs.cwd().openFile(path, .{});
        defer boot2_file.close();
        const data = try boot2_file.readToEndAlloc(std.heap.page_allocator, BOOT2_SIZE + 1);
        if (data.len != BOOT2_SIZE) {
            std.debug.print("Error: boot2.bin must be exactly {d} bytes (got {d})\n", .{ BOOT2_SIZE, data.len });
            return error.InvalidBoot2Size;
        }
        boot2_data = data;
    } else {
        std.debug.print(
            "Warning: no boot2.bin provided. Firmware will not boot on real hardware.\n" ++
                "         Use `zig build uf2 -Dboot2=<path>` to include boot2.\n",
            .{},
        );
    }

    // Calculate total block count
    const firmware_blocks: u32 = @intCast((firmware_data.len + PAYLOAD_SIZE - 1) / PAYLOAD_SIZE);
    const boot2_blocks: u32 = if (boot2_data != null) 1 else 0;
    const num_blocks: u32 = boot2_blocks + firmware_blocks;

    const output_file = try std.fs.cwd().createFile(output_path, .{});
    defer output_file.close();

    var block_no: u32 = 0;

    // Write boot2 block at 0x10000000
    if (boot2_data) |b2| {
        var block = UF2Block{
            .target_addr = FLASH_BASE,
            .block_no = block_no,
            .num_blocks = num_blocks,
        };
        @memcpy(block.data[0..BOOT2_SIZE], b2);
        try output_file.writeAll(std.mem.asBytes(&block));
        block_no += 1;
    }

    // Write firmware blocks starting at 0x10000100
    var i: u32 = 0;
    while (i < firmware_blocks) : (i += 1) {
        var block = UF2Block{
            .target_addr = FIRMWARE_BASE + i * PAYLOAD_SIZE,
            .block_no = block_no,
            .num_blocks = num_blocks,
        };

        const start = i * PAYLOAD_SIZE;
        const end = @min(start + PAYLOAD_SIZE, @as(u32, @intCast(firmware_data.len)));
        @memcpy(block.data[0 .. end - start], firmware_data[start..end]);

        try output_file.writeAll(std.mem.asBytes(&block));
        block_no += 1;
    }

    std.debug.print("Created {s}: {d} blocks ({d} firmware + {d} boot2), {d} bytes firmware\n", .{
        output_path,
        num_blocks,
        firmware_blocks,
        boot2_blocks,
        firmware_data.len,
    });
}
