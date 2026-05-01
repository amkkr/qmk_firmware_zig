// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! UF2 file generator for RP2040
//! Converts raw binary firmware to UF2 format
//! See: https://github.com/microsoft/uf2
//!
//! Usage:
//!   uf2gen <input.bin> <output.uf2> [--family-id=<hex>] [--flash-base=<hex>]
//!
//! オプション:
//!   --family-id=<hex>   UF2 family id (default: 0xe48bff56 RP2040)
//!   --flash-base=<hex>  フラッシュ書込開始アドレス (default: 0x10000000 RP2040)
//!
//! 入力 raw バイナリは boot2 (offset 0、 256 bytes) + ファームウェア (offset 0x100 〜) の構成。
//! 全体を flash_base から書き込む。
//!
//! 安全機構:
//! - 入力サイズ上限を 2093056 bytes (= (2048-4)*1024、 EEPROM 4KB 予約後の FLASH 容量) に制限
//! - 各ブロックの target_addr が EEPROM 領域 (0x101FF000〜0x101FFFFF) を侵食しないことを assert

const std = @import("std");

const UF2_MAGIC_START0: u32 = 0x0A324655; // "UF2\n"
const UF2_MAGIC_START1: u32 = 0x9E5D5157;
const UF2_MAGIC_END: u32 = 0x0AB16F30;
const UF2_FLAG_FAMILY_ID: u32 = 0x00002000;
const RP2040_FAMILY_ID_DEFAULT: u32 = 0xe48bff56;
const FLASH_BASE_DEFAULT: u32 = 0x10000000;
const PAYLOAD_SIZE: u32 = 256;
const BLOCK_SIZE: u32 = 512;

/// EEPROM 予約領域開始アドレス (RP2040: 最終 4KB sector)
/// 各ブロックの target_addr がこの値以上にならないよう assert する
const EEPROM_REGION_START: u32 = 0x101FF000;

/// 入力 raw bin のサイズ上限 (= (2048-4)*1024 = 2093056 bytes)
/// (FLASH 全体 2MB から EEPROM 予約 4KB を引いた書込可能領域)
const MAX_FIRMWARE_SIZE: usize = 2093056;

const UF2Block = extern struct {
    magic_start0: u32 = UF2_MAGIC_START0,
    magic_start1: u32 = UF2_MAGIC_START1,
    flags: u32 = UF2_FLAG_FAMILY_ID,
    target_addr: u32,
    payload_size: u32 = PAYLOAD_SIZE,
    block_no: u32,
    num_blocks: u32,
    family_id: u32,
    data: [476]u8 = .{0} ** 476,
    magic_end: u32 = UF2_MAGIC_END,

    comptime {
        if (@sizeOf(UF2Block) != BLOCK_SIZE) {
            @compileError("UF2Block size must be 512 bytes");
        }
    }
};

const Args = struct {
    input_path: []const u8,
    output_path: []const u8,
    family_id: u32,
    flash_base: u32,
};

const ArgsError = error{ InvalidArgs, InvalidNumber };

const GenError = error{
    FirmwareTooLarge,
    TargetAddrOutOfRange,
};

fn printUsage() void {
    std.debug.print(
        \\Usage: uf2gen <input.bin> <output.uf2> [--family-id=<hex>] [--flash-base=<hex>]
        \\
        \\オプション:
        \\  --family-id=<hex>   UF2 family id (default: 0xe48bff56 RP2040)
        \\  --flash-base=<hex>  フラッシュ書込開始アドレス (default: 0x10000000 RP2040)
        \\
    , .{});
}

fn parseArgs(raw_args: [][:0]u8) ArgsError!Args {
    var positional = std.ArrayList([]const u8){};
    defer positional.deinit(std.heap.page_allocator);

    var family_id: u32 = RP2040_FAMILY_ID_DEFAULT;
    var flash_base: u32 = FLASH_BASE_DEFAULT;

    var i: usize = 1;
    while (i < raw_args.len) : (i += 1) {
        const arg = raw_args[i];
        if (std.mem.startsWith(u8, arg, "--family-id=")) {
            const v = arg["--family-id=".len..];
            const stripped = stripHexPrefix(v);
            family_id = std.fmt.parseUnsigned(u32, stripped, 16) catch {
                std.debug.print("Error: --family-id の値が不正です (hex): {s}\n", .{v});
                return ArgsError.InvalidNumber;
            };
        } else if (std.mem.startsWith(u8, arg, "--flash-base=")) {
            const v = arg["--flash-base=".len..];
            const stripped = stripHexPrefix(v);
            flash_base = std.fmt.parseUnsigned(u32, stripped, 16) catch {
                std.debug.print("Error: --flash-base の値が不正です (hex): {s}\n", .{v});
                return ArgsError.InvalidNumber;
            };
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("Error: 未知のオプション: {s}\n", .{arg});
            return ArgsError.InvalidArgs;
        } else {
            positional.append(std.heap.page_allocator, arg) catch return ArgsError.InvalidArgs;
        }
    }

    if (positional.items.len != 2) {
        std.debug.print("Error: 入力 .bin と出力 .uf2 のパスを指定してください (現在 {d} 個)\n", .{positional.items.len});
        return ArgsError.InvalidArgs;
    }

    return Args{
        .input_path = positional.items[0],
        .output_path = positional.items[1],
        .family_id = family_id,
        .flash_base = flash_base,
    };
}

fn stripHexPrefix(s: []const u8) []const u8 {
    if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X")) {
        return s[2..];
    }
    return s;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    const args = parseArgs(raw_args) catch |err| switch (err) {
        ArgsError.InvalidArgs, ArgsError.InvalidNumber => {
            printUsage();
            return error.InvalidArgs;
        },
    };

    // 入力 raw バイナリを読み込み
    const input_file = try std.fs.cwd().openFile(args.input_path, .{});
    defer input_file.close();
    const firmware_data = try input_file.readToEndAlloc(allocator, MAX_FIRMWARE_SIZE + 1);
    defer allocator.free(firmware_data);

    // サイズ上限チェック (EEPROM 予約領域を侵食しない)
    if (firmware_data.len > MAX_FIRMWARE_SIZE) {
        std.debug.print(
            "Error: ファームウェアサイズ {d} bytes がフラッシュ容量上限 {d} bytes を超えています (EEPROM 領域 0x{X:0>8} を保護)\n",
            .{ firmware_data.len, MAX_FIRMWARE_SIZE, EEPROM_REGION_START },
        );
        return GenError.FirmwareTooLarge;
    }

    const output_file = try std.fs.cwd().createFile(args.output_path, .{});
    defer output_file.close();

    // RP2040 のデフォルト構成のときのみ EEPROM 領域 (0x101FF000-) を保護。
    // それ以外 (--flash-base が変更された場合) は EEPROM チェックをスキップ
    // (RP2350 等、 異なる MCU では EEPROM の位置が異なるため)。
    const eeprom_protect_start: ?u32 = if (args.flash_base == FLASH_BASE_DEFAULT)
        EEPROM_REGION_START
    else
        null;

    var num_blocks: u32 = undefined;
    const blocks = try generateUf2Blocks(allocator, firmware_data, args.family_id, args.flash_base, eeprom_protect_start, &num_blocks);
    defer allocator.free(blocks);
    try output_file.writeAll(blocks);

    std.debug.print("Created {s}: {d} blocks, {d} bytes (family=0x{X:0>8}, base=0x{X:0>8})\n", .{
        args.output_path,
        num_blocks,
        firmware_data.len,
        args.family_id,
        args.flash_base,
    });
}

/// raw firmware bytes から UF2 blocks を生成し allocator で確保したバッファを返す。
/// 呼出側は free すること。
/// `eeprom_protect_start` が non-null の場合、 各 block の target_addr がその値以上
/// にならないよう assert する (RP2040 では `0x101FF000` を渡して EEPROM 領域を保護)。
/// `eeprom_protect_start` が null の場合は領域チェックをスキップ (他 MCU 対応)。
/// num_blocks_out に最終ブロック数を書き込む。
fn generateUf2Blocks(
    allocator: std.mem.Allocator,
    firmware_data: []const u8,
    family_id: u32,
    flash_base: u32,
    eeprom_protect_start: ?u32,
    num_blocks_out: *u32,
) ![]u8 {
    const num_blocks: u32 = @intCast((firmware_data.len + PAYLOAD_SIZE - 1) / PAYLOAD_SIZE);
    num_blocks_out.* = num_blocks;

    const output = try allocator.alloc(u8, @as(usize, num_blocks) * BLOCK_SIZE);
    errdefer allocator.free(output);

    var i: u32 = 0;
    while (i < num_blocks) : (i += 1) {
        const start = i * PAYLOAD_SIZE;
        const end_u32 = @min(start + PAYLOAD_SIZE, @as(u32, @intCast(firmware_data.len)));
        const target_addr = flash_base + start;

        // EEPROM 領域への書込を防止 (eeprom_protect_start が指定されたとき)
        if (eeprom_protect_start) |eeprom_start| {
            if (target_addr + (end_u32 - start) > eeprom_start) {
                std.debug.print(
                    "Error: target_addr 0x{X:0>8} が EEPROM 予約領域 0x{X:0>8} に到達します (block_no={d}, payload={d})\n",
                    .{ target_addr, eeprom_start, i, end_u32 - start },
                );
                return GenError.TargetAddrOutOfRange;
            }
        }

        var block = UF2Block{
            .target_addr = target_addr,
            .block_no = i,
            .num_blocks = num_blocks,
            .family_id = family_id,
        };

        @memcpy(block.data[0 .. end_u32 - start], firmware_data[start..end_u32]);

        const block_offset = @as(usize, i) * BLOCK_SIZE;
        @memcpy(output[block_offset .. block_offset + BLOCK_SIZE], std.mem.asBytes(&block));
    }

    return output;
}

test "generateUf2Blocks produces correct block count for normal size" {
    const testing = std.testing;

    // 4KB のテストデータ -> 16 blocks (256 byte payload x 16)
    const data = [_]u8{0xAB} ** 4096;
    var num_blocks: u32 = 0;
    const blocks = try generateUf2Blocks(testing.allocator, &data, RP2040_FAMILY_ID_DEFAULT, FLASH_BASE_DEFAULT, EEPROM_REGION_START, &num_blocks);
    defer testing.allocator.free(blocks);

    try testing.expectEqual(@as(u32, 16), num_blocks);
    try testing.expectEqual(@as(usize, 16 * BLOCK_SIZE), blocks.len);

    // 最初のブロックの target_addr 確認
    const first_target_addr = std.mem.readInt(u32, blocks[12..16], .little);
    try testing.expectEqual(FLASH_BASE_DEFAULT, first_target_addr);
}

test "generateUf2Blocks rounds up partial last block" {
    const testing = std.testing;

    // 257 byte -> 2 blocks (1 完全 + 1 部分)
    const data = [_]u8{0x42} ** 257;
    var num_blocks: u32 = 0;
    const blocks = try generateUf2Blocks(testing.allocator, &data, RP2040_FAMILY_ID_DEFAULT, FLASH_BASE_DEFAULT, EEPROM_REGION_START, &num_blocks);
    defer testing.allocator.free(blocks);

    try testing.expectEqual(@as(u32, 2), num_blocks);
}

test "generateUf2Blocks rejects firmware reaching EEPROM region" {
    const testing = std.testing;

    // EEPROM 直前ぎりぎりにブロックを置くと侵食するケース。
    // flash_base = 0x101FEF00 (= 0x101FF000 - 0x100) から 257 byte 書くと
    // 2 ブロック目の終端が 0x101FF100 となり 0x101FF000 を越える
    const data = [_]u8{0x55} ** 257;
    var num_blocks: u32 = 0;
    const result = generateUf2Blocks(
        testing.allocator,
        &data,
        RP2040_FAMILY_ID_DEFAULT,
        EEPROM_REGION_START - 0x100, // 0x101FEF00
        EEPROM_REGION_START,
        &num_blocks,
    );
    try testing.expectError(GenError.TargetAddrOutOfRange, result);
}

test "generateUf2Blocks skips EEPROM check when eeprom_protect_start is null" {
    const testing = std.testing;

    // RP2350 等、 異なる MCU で 0x101FF000 を超えるアドレスに書き込む場合の動作確認
    const data = [_]u8{0x33} ** 257;
    var num_blocks: u32 = 0;
    // EEPROM チェックをスキップ (null) して、 0x101FF000 を越えるアドレスでも成功
    const blocks = try generateUf2Blocks(
        testing.allocator,
        &data,
        RP2040_FAMILY_ID_DEFAULT,
        EEPROM_REGION_START - 0x100, // 0x101FEF00
        null,
        &num_blocks,
    );
    defer testing.allocator.free(blocks);
    try testing.expectEqual(@as(u32, 2), num_blocks);
}

test "generateUf2Blocks does not corrupt boot2 region" {
    const testing = std.testing;

    // boot2 領域 (0x10000000-0x100000FF) はファームウェア先頭 256 byte。
    // generateUf2Blocks は flash_base から書くため、 最終ブロックは boot2 を侵食しない。
    // 検証: 最終ブロックの target_addr > 0x100000FF を確認 (1KB 入力なら 4 ブロック、
    //       最終ブロック target_addr = 0x10000300 となり boot2 領域外)
    const data = [_]u8{0x77} ** 1024;
    var num_blocks: u32 = 0;
    const blocks = try generateUf2Blocks(testing.allocator, &data, RP2040_FAMILY_ID_DEFAULT, FLASH_BASE_DEFAULT, EEPROM_REGION_START, &num_blocks);
    defer testing.allocator.free(blocks);

    try testing.expectEqual(@as(u32, 4), num_blocks);

    // 最終ブロック (block_no=3) の target_addr を確認
    const last_block_offset = (num_blocks - 1) * BLOCK_SIZE;
    const last_target_addr = std.mem.readInt(u32, blocks[last_block_offset + 12 ..][0..4], .little);
    // 最終 target_addr = 0x10000000 + 3 * 256 = 0x10000300
    try testing.expectEqual(@as(u32, FLASH_BASE_DEFAULT + 3 * 256), last_target_addr);
    // boot2 領域 (0x10000000-0x100000FF) を超えていることを確認
    try testing.expect(last_target_addr > FLASH_BASE_DEFAULT + 0xFF);
}

test "generateUf2Blocks honors custom family_id" {
    const testing = std.testing;
    const data = [_]u8{0x11} ** 256;
    var num_blocks: u32 = 0;
    const custom_family: u32 = 0xe48bff59; // RP2350_ARM_S
    const blocks = try generateUf2Blocks(testing.allocator, &data, custom_family, FLASH_BASE_DEFAULT, &num_blocks);
    defer testing.allocator.free(blocks);

    // family_id は block 内 offset 28
    const family_in_block = std.mem.readInt(u32, blocks[28..32], .little);
    try testing.expectEqual(custom_family, family_in_block);
}

test "stripHexPrefix removes 0x and 0X" {
    const testing = std.testing;
    try testing.expectEqualStrings("ABCD", stripHexPrefix("0xABCD"));
    try testing.expectEqualStrings("1234", stripHexPrefix("0X1234"));
    try testing.expectEqualStrings("DEAD", stripHexPrefix("DEAD"));
    try testing.expectEqualStrings("", stripHexPrefix(""));
}
