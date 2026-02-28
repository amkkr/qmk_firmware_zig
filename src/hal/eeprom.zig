// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! EEPROM emulation for RP2040
//! Based on drivers/eeprom/eeprom_custom.c
//!
//! Emulates EEPROM using RP2040 flash memory.
//! On real hardware: flash-based persistent storage using the last 4KB sector.
//! In tests: RAM-backed mock.
//!
//! RP2040 flash write procedure:
//! 1. ROM function table lookup for flash_range_erase / flash_range_program
//! 2. Disable interrupts (XIP becomes unavailable during flash operations)
//! 3. Call ROM functions with flash offset (not absolute address)
//! 4. Re-enable interrupts

const std = @import("std");
const builtin = @import("builtin");

const is_freestanding = builtin.os.tag == .freestanding;

/// EEPROM size (1KB, matching QMK default for RP2040)
pub const EEPROM_SIZE = 1024;

/// Flash sector size (RP2040 minimum erase unit)
const FLASH_SECTOR_SIZE = 4096;

/// Flash page size (RP2040 minimum program unit)
const FLASH_PAGE_SIZE = 256;

/// Total flash size (2MB for W25Q016JV)
const FLASH_TOTAL_SIZE = 2 * 1024 * 1024;

/// EEPROM storage offset from flash base (last sector of 2MB flash)
const EEPROM_FLASH_OFFSET = FLASH_TOTAL_SIZE - FLASH_SECTOR_SIZE;

/// XIP base address (flash is memory-mapped here via XIP)
const XIP_BASE: u32 = 0x10000000;

// ============================================================
// RP2040 ROM Function Table (freestanding only)
// ============================================================

const rom = if (is_freestanding) struct {
    /// RP2040 ROM function table lookup
    /// ROM stores a table of function pointers that can be looked up by two-character code.
    /// See RP2040 datasheet section 2.8.3 "Bootrom Contents"

    const ROM_TABLE_LOOKUP_ADDR: u32 = 0x00000018;
    const ROM_FUNC_TABLE_ADDR: u32 = 0x00000014;

    /// Look up a ROM function by its two-character code
    fn romFuncLookup(code: [2]u8) usize {
        const rom_table_lookup: *const fn (table: u16, code: u32) callconv(.c) usize =
            @ptrFromInt(@as(u32, @as(*const u16, @ptrFromInt(ROM_TABLE_LOOKUP_ADDR)).*));
        const func_table: u16 = @as(*const u16, @ptrFromInt(ROM_FUNC_TABLE_ADDR)).*;
        return rom_table_lookup(func_table, @as(u32, code[0]) | (@as(u32, code[1]) << 8));
    }

    /// flash_range_erase(offset: u32, count: u32, block_size: u32, block_cmd: u8)
    /// Erases `count` bytes of flash starting at `offset` (from flash start, not XIP base).
    fn flashRangeErase(offset: u32, count: u32) void {
        const func: *const fn (u32, u32, u32, u8) callconv(.c) void =
            @ptrFromInt(romFuncLookup("RE".*));
        func(offset, count, FLASH_SECTOR_SIZE, 0x20); // 0x20 = sector erase command
    }

    /// flash_range_program(offset: u32, data: [*]const u8, count: u32)
    /// Programs `count` bytes to flash starting at `offset`.
    fn flashRangeProgram(offset: u32, data: [*]const u8, count: u32) void {
        const func: *const fn (u32, [*]const u8, u32) callconv(.c) void =
            @ptrFromInt(romFuncLookup("RP".*));
        func(offset, data, count);
    }

    /// connect_internal_flash()
    /// Restores flash interface to default state after flash operations.
    fn connectInternalFlash() void {
        const func: *const fn () callconv(.c) void =
            @ptrFromInt(romFuncLookup("IF".*));
        func();
    }

    /// flash_exit_xip()
    /// Exits XIP mode to allow direct flash access.
    fn flashExitXip() void {
        const func: *const fn () callconv(.c) void =
            @ptrFromInt(romFuncLookup("EX".*));
        func();
    }

    /// flash_flush_cache()
    /// Flushes and enables the XIP cache after flash operations.
    fn flashFlushCache() void {
        const func: *const fn () callconv(.c) void =
            @ptrFromInt(romFuncLookup("FC".*));
        func();
    }
} else struct {};

// ============================================================
// Storage
// ============================================================

/// RAM cache of EEPROM contents
var storage: [EEPROM_SIZE]u8 = .{0xFF} ** EEPROM_SIZE;

/// Dirty flag: true when RAM cache has been modified and needs to be flushed to flash
var dirty: bool = false;

// ============================================================
// Public EEPROM API
// ============================================================

/// Initialize EEPROM subsystem
/// On real hardware: reads the EEPROM sector from flash into the RAM cache.
/// In tests: storage is already initialized to erased state (0xFF).
pub fn init() void {
    if (is_freestanding) {
        // Read EEPROM sector from flash (via XIP memory-mapped access)
        const flash_addr: [*]const u8 = @ptrFromInt(XIP_BASE + EEPROM_FLASH_OFFSET);
        @memcpy(&storage, flash_addr[0..EEPROM_SIZE]);
    }
    dirty = false;
}

/// Read a single byte from EEPROM
pub fn readByte(address: u16) u8 {
    if (address >= EEPROM_SIZE) return 0xFF;
    return storage[address];
}

/// Write a single byte to EEPROM
pub fn writeByte(address: u16, data: u8) void {
    if (address >= EEPROM_SIZE) return;
    if (storage[address] != data) {
        storage[address] = data;
        dirty = true;
    }
}

/// Read a 16-bit word from EEPROM (little-endian)
pub fn readWord(address: u16) u16 {
    const lo = readByte(address);
    const hi = readByte(address + 1);
    return @as(u16, hi) << 8 | @as(u16, lo);
}

/// Write a 16-bit word to EEPROM (little-endian)
pub fn writeWord(address: u16, data: u16) void {
    writeByte(address, @truncate(data));
    writeByte(address + 1, @truncate(data >> 8));
}

/// Read a 32-bit double word from EEPROM (little-endian)
pub fn readDword(address: u16) u32 {
    const lo = readWord(address);
    const hi = readWord(address + 2);
    return @as(u32, hi) << 16 | @as(u32, lo);
}

/// Write a 32-bit double word to EEPROM (little-endian)
pub fn writeDword(address: u16, data: u32) void {
    writeWord(address, @truncate(data));
    writeWord(address + 2, @truncate(data >> 16));
}

/// Read a block of bytes from EEPROM
/// Uses u32 arithmetic to prevent u16 wraparound for large addresses.
/// Out-of-bounds bytes are filled with 0xFF (erased state).
pub fn readBlock(address: u16, buf: []u8) void {
    for (buf, 0..) |*b, i| {
        const addr = @as(u32, address) + @as(u32, @intCast(i));
        b.* = if (addr < EEPROM_SIZE) storage[@intCast(addr)] else 0xFF;
    }
}

/// Write a block of bytes to EEPROM
/// Uses u32 arithmetic to prevent u16 wraparound for large addresses.
/// Stops writing when address exceeds EEPROM_SIZE.
pub fn writeBlock(address: u16, data: []const u8) void {
    for (data, 0..) |b, i| {
        const addr = @as(u32, address) + @as(u32, @intCast(i));
        if (addr >= EEPROM_SIZE) break;
        if (storage[@intCast(addr)] != b) {
            storage[@intCast(addr)] = b;
            dirty = true;
        }
    }
}

/// Erase all EEPROM data (set to 0xFF)
pub fn erase() void {
    storage = .{0xFF} ** EEPROM_SIZE;
    dirty = true;
}

/// Flush RAM cache to flash if dirty.
/// On real hardware: performs sector erase + page program.
/// In tests: just clears the dirty flag.
///
/// Flash write procedure (RP2040):
/// 1. Disable interrupts (mandatory: XIP is unavailable during flash ops)
/// 2. Connect internal flash interface
/// 3. Exit XIP mode
/// 4. Erase the EEPROM sector (4KB)
/// 5. Program the data in 256-byte pages
/// 6. Flush XIP cache and re-enable XIP
/// 7. Re-enable interrupts
pub fn flush() void {
    if (!dirty) return;

    if (is_freestanding) {
        // Disable interrupts: flash operations disable XIP, so any interrupt
        // handler that resides in flash would crash. We must ensure no
        // interrupts fire during the erase/program sequence.
        asm volatile ("cpsid i");

        // Prepare flash interface for direct access
        rom.connectInternalFlash();
        rom.flashExitXip();

        // Erase the EEPROM sector (4KB)
        rom.flashRangeErase(EEPROM_FLASH_OFFSET, FLASH_SECTOR_SIZE);

        // Program EEPROM data in 256-byte pages
        // EEPROM_SIZE (1024) = 4 pages of 256 bytes
        // The sector is 4KB but we only write EEPROM_SIZE bytes;
        // the rest remains erased (0xFF).
        var offset: u32 = 0;
        while (offset < EEPROM_SIZE) : (offset += FLASH_PAGE_SIZE) {
            rom.flashRangeProgram(
                EEPROM_FLASH_OFFSET + offset,
                @as([*]const u8, @ptrCast(&storage)) + offset,
                FLASH_PAGE_SIZE,
            );
        }

        // Re-enable XIP and flush cache so subsequent flash reads are correct
        rom.flashFlushCache();

        // Re-enable interrupts
        asm volatile ("cpsie i");
    }

    dirty = false;
}

/// Check if the RAM cache has been modified since last flush
pub fn isDirty() bool {
    return dirty;
}

// ============================================================
// Mock helpers (test only)
// ============================================================

/// Reset EEPROM to erased state (test only)
pub fn mockReset() void {
    storage = .{0xFF} ** EEPROM_SIZE;
    dirty = false;
}

// ============================================================
// Tests
// ============================================================

test "EEPROM read/write byte" {
    mockReset();
    try std.testing.expectEqual(@as(u8, 0xFF), readByte(0)); // Erased state

    writeByte(0, 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), readByte(0));

    writeByte(100, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), readByte(100));
}

test "EEPROM read/write word" {
    mockReset();
    writeWord(0, 0x1234);
    try std.testing.expectEqual(@as(u16, 0x1234), readWord(0));
    // Check byte order (little-endian)
    try std.testing.expectEqual(@as(u8, 0x34), readByte(0));
    try std.testing.expectEqual(@as(u8, 0x12), readByte(1));
}

test "EEPROM read/write dword" {
    mockReset();
    writeDword(0, 0xDEADBEEF);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), readDword(0));
}

test "EEPROM read/write block" {
    mockReset();
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    writeBlock(10, &data);

    var buf: [4]u8 = undefined;
    readBlock(10, &buf);
    try std.testing.expectEqualSlices(u8, &data, &buf);
}

test "EEPROM out of bounds" {
    mockReset();
    try std.testing.expectEqual(@as(u8, 0xFF), readByte(EEPROM_SIZE)); // Out of bounds
    writeByte(EEPROM_SIZE, 0x42); // Should not crash
}

test "EEPROM erase" {
    mockReset();
    writeByte(0, 0x42);
    erase();
    try std.testing.expectEqual(@as(u8, 0xFF), readByte(0));
}

test "EEPROM dirty flag management" {
    mockReset();

    // Initially not dirty
    try std.testing.expect(!isDirty());

    // Writing a different value sets dirty
    writeByte(0, 0x42);
    try std.testing.expect(isDirty());

    // Flush clears dirty
    flush();
    try std.testing.expect(!isDirty());

    // Writing the same value does not set dirty
    writeByte(0, 0x42);
    try std.testing.expect(!isDirty());

    // Writing a different value sets dirty again
    writeByte(0, 0x43);
    try std.testing.expect(isDirty());
}

test "EEPROM erase sets dirty" {
    mockReset();
    try std.testing.expect(!isDirty());

    erase();
    try std.testing.expect(isDirty());

    flush();
    try std.testing.expect(!isDirty());
}

test "EEPROM writeBlock dirty tracking" {
    mockReset();
    try std.testing.expect(!isDirty());

    // Writing new data sets dirty
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    writeBlock(10, &data);
    try std.testing.expect(isDirty());

    flush();
    try std.testing.expect(!isDirty());

    // Writing the same data does not set dirty
    writeBlock(10, &data);
    try std.testing.expect(!isDirty());
}

test "EEPROM flush without dirty is no-op" {
    mockReset();
    try std.testing.expect(!isDirty());

    // Flush when not dirty should be a no-op
    flush();
    try std.testing.expect(!isDirty());
}

test "EEPROM init resets dirty flag" {
    mockReset();
    writeByte(0, 0x42);
    try std.testing.expect(isDirty());

    // init() should clear dirty flag (in test mode, storage stays as-is)
    init();
    try std.testing.expect(!isDirty());
}

test "EEPROM flash layout constants" {
    // EEPROM fits within one sector
    try std.testing.expect(EEPROM_SIZE <= FLASH_SECTOR_SIZE);

    // EEPROM offset is sector-aligned
    try std.testing.expectEqual(@as(u32, 0), EEPROM_FLASH_OFFSET % FLASH_SECTOR_SIZE);

    // EEPROM offset is within flash bounds
    try std.testing.expect(EEPROM_FLASH_OFFSET + FLASH_SECTOR_SIZE <= FLASH_TOTAL_SIZE);

    // EEPROM size is page-aligned (for efficient programming)
    try std.testing.expectEqual(@as(u32, 0), EEPROM_SIZE % FLASH_PAGE_SIZE);
}
