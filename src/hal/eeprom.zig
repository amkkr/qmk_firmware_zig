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

    /// Look up a ROM function by its two-character code.
    /// Must be inline so it is embedded in the caller (flashCommitImpl in RAM),
    /// not placed in .text (flash). pico-sdk uses __force_inline for the same reason.
    inline fn romFuncLookup(code: [2]u8) usize {
        const rom_table_lookup: *const fn (table: u16, code: u32) callconv(.c) usize =
            @ptrFromInt(@as(u32, @as(*const u16, @ptrFromInt(ROM_TABLE_LOOKUP_ADDR)).*));
        const func_table: u16 = @as(*const u16, @ptrFromInt(ROM_FUNC_TABLE_ADDR)).*;
        return rom_table_lookup(func_table, @as(u32, code[0]) | (@as(u32, code[1]) << 8));
    }

    /// flash_range_erase(offset: u32, count: u32, block_size: u32, block_cmd: u8)
    /// Erases `count` bytes of flash starting at `offset` (from flash start, not XIP base).
    /// Inline to ensure execution from RAM when called from flashCommitImpl.
    inline fn flashRangeErase(offset: u32, count: u32) void {
        const func: *const fn (u32, u32, u32, u8) callconv(.c) void =
            @ptrFromInt(romFuncLookup("RE".*));
        func(offset, count, FLASH_SECTOR_SIZE, 0x20); // 0x20 = sector erase command
    }

    /// flash_range_program(offset: u32, data: [*]const u8, count: u32)
    /// Programs `count` bytes to flash starting at `offset`.
    /// Inline to ensure execution from RAM when called from flashCommitImpl.
    inline fn flashRangeProgram(offset: u32, data: [*]const u8, count: u32) void {
        const func: *const fn (u32, [*]const u8, u32) callconv(.c) void =
            @ptrFromInt(romFuncLookup("RP".*));
        func(offset, data, count);
    }

    /// connect_internal_flash()
    /// Restores flash interface to default state after flash operations.
    /// Inline to ensure execution from RAM when called from flashCommitImpl.
    inline fn connectInternalFlash() void {
        const func: *const fn () callconv(.c) void =
            @ptrFromInt(romFuncLookup("IF".*));
        func();
    }

    /// flash_exit_xip()
    /// Exits XIP mode to allow direct flash access.
    /// Inline to ensure execution from RAM when called from flashCommitImpl.
    inline fn flashExitXip() void {
        const func: *const fn () callconv(.c) void =
            @ptrFromInt(romFuncLookup("EX".*));
        func();
    }

    /// flash_flush_cache()
    /// Flushes and enables the XIP cache after flash operations.
    /// Inline to ensure execution from RAM when called from flashCommitImpl.
    inline fn flashFlushCache() void {
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
/// Uses u32 arithmetic to prevent u16 wraparound for boundary addresses.
pub fn readWord(address: u16) u16 {
    const lo = readByte(address);
    const hi = readByte(@intCast(@as(u32, address) + 1));
    return @as(u16, hi) << 8 | @as(u16, lo);
}

/// Write a 16-bit word to EEPROM (little-endian)
/// Uses u32 arithmetic to prevent u16 wraparound for boundary addresses.
pub fn writeWord(address: u16, data: u16) void {
    writeByte(address, @truncate(data));
    writeByte(@intCast(@as(u32, address) + 1), @truncate(data >> 8));
}

/// Read a 32-bit double word from EEPROM (little-endian)
/// Uses u32 arithmetic to prevent u16 wraparound for boundary addresses.
pub fn readDword(address: u16) u32 {
    const lo = readWord(address);
    const hi = readWord(@intCast(@as(u32, address) + 2));
    return @as(u32, hi) << 16 | @as(u32, lo);
}

/// Write a 32-bit double word to EEPROM (little-endian)
/// Uses u32 arithmetic to prevent u16 wraparound for boundary addresses.
pub fn writeDword(address: u16, data: u32) void {
    writeWord(address, @truncate(data));
    writeWord(@intCast(@as(u32, address) + 2), @truncate(data >> 16));
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
/// On real hardware: compares RAM cache with flash contents page by page.
/// Only erases the sector if a bit needs to be flipped from 0→1 (flash
/// can only clear bits without erasing). Only programs pages that differ
/// from flash. This minimizes erase cycles and extends flash lifetime.
/// In tests: just clears the dirty flag.
///
/// Flash write procedure (RP2040):
/// 1. Disable interrupts (mandatory: XIP is unavailable during flash ops)
/// 2. Connect internal flash interface
/// 3. Exit XIP mode
/// 4. Erase the EEPROM sector (4KB) — only if required
/// 5. Program only changed 256-byte pages
/// 6. Flush XIP cache and re-enable XIP
/// 7. Re-enable interrupts
///
/// Note: On real hardware, the actual flash commit is performed by flashCommit(),
/// which is placed in the .data section (copied to RAM at startup) to ensure
/// it can execute while XIP is disabled.
pub fn flush() void {
    if (!dirty) return;

    if (is_freestanding) {
        flashCommit();
    }

    dirty = false;
}

/// Perform the actual flash erase/program sequence.
/// This function MUST execute from RAM because XIP is disabled during flash operations.
/// Placed in .data section so it is copied from flash to RAM by the startup code.
const flashCommit = if (is_freestanding) flashCommitImpl else struct {
    fn f() void {}
}.f;

/// Number of pages in EEPROM storage
const PAGES_PER_EEPROM = EEPROM_SIZE / FLASH_PAGE_SIZE;

/// Check if a sector erase is needed by comparing RAM cache with flash.
/// Flash can only clear bits (1→0) without erasing. If any bit needs to go
/// from 0→1 (i.e., a flash byte has a 0-bit where the new data has a 1-bit),
/// a sector erase is required.
/// Also determines which pages have changed and need reprogramming.
/// Returns: .{ erase_needed, page_dirty_mask }
/// Must be inline to execute from RAM (called before XIP is disabled,
/// but reading XIP data here is fine since XIP is still active).
inline fn analyzeChanges() struct { erase_needed: bool, page_dirty: [PAGES_PER_EEPROM]bool } {
    const flash_data: [*]const u8 = @ptrFromInt(XIP_BASE + EEPROM_FLASH_OFFSET);
    var erase_needed = false;
    var page_dirty = [_]bool{false} ** PAGES_PER_EEPROM;

    for (0..EEPROM_SIZE) |i| {
        const flash_byte = flash_data[i];
        const ram_byte = storage[i];
        if (flash_byte != ram_byte) {
            page_dirty[i / FLASH_PAGE_SIZE] = true;
            // Check if any bit needs 0→1 transition (requires erase)
            if ((~flash_byte & ram_byte) != 0) {
                erase_needed = true;
            }
        }
    }

    return .{ .erase_needed = erase_needed, .page_dirty = page_dirty };
}

fn flashCommitImpl() linksection(".data") void {
    // Analyze changes while XIP is still active
    const changes = analyzeChanges();

    // Check if any page actually changed
    var any_dirty = false;
    for (changes.page_dirty) |d| {
        if (d) { any_dirty = true; break; }
    }
    if (!any_dirty) return;

    // Disable interrupts: flash operations disable XIP, so any interrupt
    // handler that resides in flash would crash. We must ensure no
    // interrupts fire during the erase/program sequence.
    asm volatile ("cpsid i" ::: .{ .memory = true });

    // Prepare flash interface for direct access
    rom.connectInternalFlash();
    rom.flashExitXip();

    // Erase the EEPROM sector only if a 0→1 bit transition is needed
    if (changes.erase_needed) {
        rom.flashRangeErase(EEPROM_FLASH_OFFSET, FLASH_SECTOR_SIZE);
    }

    // Program pages that need updating:
    // - If sector was erased: reprogram ALL pages (erased data = 0xFF)
    // - If no erase: reprogram only dirty pages (0→0 transitions are fine)
    for (0..PAGES_PER_EEPROM) |page| {
        if (changes.erase_needed or changes.page_dirty[page]) {
            const offset: u32 = @intCast(page * FLASH_PAGE_SIZE);
            rom.flashRangeProgram(
                EEPROM_FLASH_OFFSET + offset,
                @as([*]const u8, @ptrCast(&storage)) + offset,
                FLASH_PAGE_SIZE,
            );
        }
    }

    // Re-enable XIP and flush cache so subsequent flash reads are correct
    rom.flashFlushCache();

    // Re-enable interrupts
    asm volatile ("cpsie i" ::: .{ .memory = true });
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

/// Analyze changes between a flash snapshot and current RAM cache (test only).
/// Returns whether a sector erase would be needed and which pages are dirty.
/// This mirrors the logic of the freestanding analyzeChanges() but works
/// with a provided flash snapshot instead of XIP-mapped memory.
pub fn mockAnalyzeChanges(flash_snapshot: []const u8) struct { erase_needed: bool, page_dirty: [PAGES_PER_EEPROM]bool } {
    var erase_needed = false;
    var page_dirty = [_]bool{false} ** PAGES_PER_EEPROM;

    for (0..EEPROM_SIZE) |i| {
        const flash_byte = flash_snapshot[i];
        const ram_byte = storage[i];
        if (flash_byte != ram_byte) {
            page_dirty[i / FLASH_PAGE_SIZE] = true;
            if ((~flash_byte & ram_byte) != 0) {
                erase_needed = true;
            }
        }
    }

    return .{ .erase_needed = erase_needed, .page_dirty = page_dirty };
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

    // PAGES_PER_EEPROM is correct
    try std.testing.expectEqual(@as(u32, 4), PAGES_PER_EEPROM);
}

test "wear leveling: no erase needed when only clearing bits (1→0)" {
    mockReset(); // storage = all 0xFF (erased flash state)

    // Simulate flash snapshot: all 0xFF (freshly erased)
    var flash_snapshot: [EEPROM_SIZE]u8 = .{0xFF} ** EEPROM_SIZE;

    // Write 0x42 to byte 0: 0xFF → 0x42 (only clears bits, no erase needed)
    writeByte(0, 0x42);

    const result = mockAnalyzeChanges(&flash_snapshot);
    try std.testing.expect(!result.erase_needed);
    try std.testing.expect(result.page_dirty[0]);
    try std.testing.expect(!result.page_dirty[1]);
    try std.testing.expect(!result.page_dirty[2]);
    try std.testing.expect(!result.page_dirty[3]);
}

test "wear leveling: erase needed when setting bits (0→1)" {
    mockReset();

    // Simulate flash that has byte 0 = 0x42 (some bits already cleared)
    var flash_snapshot: [EEPROM_SIZE]u8 = .{0xFF} ** EEPROM_SIZE;
    flash_snapshot[0] = 0x42;

    // RAM cache has byte 0 = 0xFF (need to set bits back to 1 → erase needed)
    // storage is already 0xFF from mockReset

    const result = mockAnalyzeChanges(&flash_snapshot);
    try std.testing.expect(result.erase_needed);
    try std.testing.expect(result.page_dirty[0]);
}

test "wear leveling: no changes means no dirty pages" {
    mockReset();

    // Flash snapshot matches RAM cache exactly
    var flash_snapshot: [EEPROM_SIZE]u8 = .{0xFF} ** EEPROM_SIZE;

    const result = mockAnalyzeChanges(&flash_snapshot);
    try std.testing.expect(!result.erase_needed);
    for (result.page_dirty) |d| {
        try std.testing.expect(!d);
    }
}

test "wear leveling: changes in different pages tracked independently" {
    mockReset();

    var flash_snapshot: [EEPROM_SIZE]u8 = .{0xFF} ** EEPROM_SIZE;

    // Modify byte in page 0 (offset 0)
    writeByte(0, 0x01);
    // Modify byte in page 2 (offset 512)
    writeByte(512, 0x02);

    const result = mockAnalyzeChanges(&flash_snapshot);
    try std.testing.expect(!result.erase_needed); // Only clearing bits
    try std.testing.expect(result.page_dirty[0]);
    try std.testing.expect(!result.page_dirty[1]);
    try std.testing.expect(result.page_dirty[2]);
    try std.testing.expect(!result.page_dirty[3]);
}

test "wear leveling: bit-clear only in one page, bit-set in another" {
    mockReset();

    var flash_snapshot: [EEPROM_SIZE]u8 = .{0xFF} ** EEPROM_SIZE;
    // Page 1 has a previously written value
    flash_snapshot[256] = 0x0F;

    // RAM: page 0 gets new value (bit-clear only), page 1 needs erase (0→1)
    writeByte(0, 0x42);
    writeByte(256, 0xF0); // 0x0F → 0xF0 requires 0→1 transitions

    const result = mockAnalyzeChanges(&flash_snapshot);
    try std.testing.expect(result.erase_needed);
    try std.testing.expect(result.page_dirty[0]);
    try std.testing.expect(result.page_dirty[1]);
    try std.testing.expect(!result.page_dirty[2]);
    try std.testing.expect(!result.page_dirty[3]);
}
