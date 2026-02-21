//! UF2 file generator for RP2040
//! Converts raw binary firmware to UF2 format
//! See: https://github.com/microsoft/uf2

const std = @import("std");

const UF2_MAGIC_START0: u32 = 0x0A324655; // "UF2\n"
const UF2_MAGIC_START1: u32 = 0x9E5D5157;
const UF2_MAGIC_END: u32 = 0x0AB16F30;
const UF2_FLAG_FAMILY_ID: u32 = 0x00002000;
const RP2040_FAMILY_ID: u32 = 0xe48bff56;
const FLASH_BASE: u32 = 0x10000000;
const PAYLOAD_SIZE: u32 = 256;
const BLOCK_SIZE: u32 = 512;

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

    if (args.len != 3) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("Usage: uf2gen <input.bin> <output.uf2>\n", .{});
        return error.InvalidArgs;
    }

    const input_path = args[1];
    const output_path = args[2];

    const input_file = try std.fs.cwd().openFile(input_path, .{});
    defer input_file.close();

    const data = try input_file.readToEndAlloc(std.heap.page_allocator, 2 * 1024 * 1024);
    defer std.heap.page_allocator.free(data);

    const num_blocks: u32 = @intCast((data.len + PAYLOAD_SIZE - 1) / PAYLOAD_SIZE);

    const output_file = try std.fs.cwd().createFile(output_path, .{});
    defer output_file.close();

    var i: u32 = 0;
    while (i < num_blocks) : (i += 1) {
        var block = UF2Block{
            .target_addr = FLASH_BASE + i * PAYLOAD_SIZE,
            .block_no = i,
            .num_blocks = num_blocks,
        };

        const start = i * PAYLOAD_SIZE;
        const end = @min(start + PAYLOAD_SIZE, @as(u32, @intCast(data.len)));
        @memcpy(block.data[0 .. end - start], data[start..end]);

        try output_file.writeAll(std.mem.asBytes(&block));
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("Created {s}: {d} blocks, {d} bytes\n", .{ output_path, num_blocks, data.len });
}
