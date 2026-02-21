//! EEPROM emulation for RP2040
//! Based on drivers/eeprom/eeprom_custom.c
//!
//! Emulates EEPROM using RP2040 flash memory.
//! On real hardware: flash-based persistent storage with wear leveling.
//! In tests: RAM-backed mock.

const std = @import("std");
const builtin = @import("builtin");

const is_freestanding = builtin.os.tag == .freestanding;

/// EEPROM size (1KB, matching QMK default for RP2040)
pub const EEPROM_SIZE = 1024;

// ============================================================
// Storage
// ============================================================

// Mock storage (used for both test and initial freestanding implementation)
var storage: [EEPROM_SIZE]u8 = .{0xFF} ** EEPROM_SIZE;

// ============================================================
// Public EEPROM API
// ============================================================

/// Initialize EEPROM subsystem
pub fn init() void {
    // On real hardware: read flash sector into RAM cache
    // For now: storage is already initialized
}

/// Read a single byte from EEPROM
pub fn readByte(address: u16) u8 {
    if (address >= EEPROM_SIZE) return 0xFF;
    return storage[address];
}

/// Write a single byte to EEPROM
pub fn writeByte(address: u16, data: u8) void {
    if (address >= EEPROM_SIZE) return;
    storage[address] = data;
    // On real hardware: mark dirty, flush to flash on demand
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
        const addr = @as(u32, address) + @as(u32, i);
        b.* = if (addr < EEPROM_SIZE) storage[@intCast(addr)] else 0xFF;
    }
}

/// Write a block of bytes to EEPROM
/// Uses u32 arithmetic to prevent u16 wraparound for large addresses.
/// Stops writing when address exceeds EEPROM_SIZE.
pub fn writeBlock(address: u16, data: []const u8) void {
    for (data, 0..) |b, i| {
        const addr = @as(u32, address) + @as(u32, i);
        if (addr >= EEPROM_SIZE) break;
        storage[@intCast(addr)] = b;
    }
}

/// Erase all EEPROM data (set to 0xFF)
pub fn erase() void {
    storage = .{0xFF} ** EEPROM_SIZE;
}

// ============================================================
// Mock helpers (test only)
// ============================================================

/// テスト専用: EEPROMを消去状態（0xFF）にリセットする
pub fn mockReset() void {
    erase();
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
