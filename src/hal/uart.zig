// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! RP2040 UART0 デバッグ出力ドライバ
//!
//! UART0 TX (GP0) を使用してデバッグログを出力する。
//! ボーレート: 115200bps, 8N1
//! ペリフェラルクロック: 125MHz (clk_peri = clk_sys)
//!
//! freestanding 時のみ実レジスタ操作、テスト時は no-op。
//!
//! 参照: RP2040 データシート Section 4.2 "UART"

const std = @import("std");
const builtin = @import("builtin");

const is_freestanding = builtin.os.tag == .freestanding;

// ============================================================
// レジスタ定義
// ============================================================

const UART0_BASE: u32 = 0x40034000;

const UartRegs = struct {
    /// データレジスタ
    const UARTDR: u32 = UART0_BASE + 0x00;
    /// フラグレジスタ
    const UARTFR: u32 = UART0_BASE + 0x18;
    /// 整数部ボーレートレジスタ
    const UARTIBRD: u32 = UART0_BASE + 0x24;
    /// 小数部ボーレートレジスタ
    const UARTFBRD: u32 = UART0_BASE + 0x28;
    /// ライン制御レジスタ
    const UARTLCR_H: u32 = UART0_BASE + 0x2C;
    /// 制御レジスタ
    const UARTCR: u32 = UART0_BASE + 0x30;

    // フラグビット
    /// TX FIFO フル
    const FR_TXFF: u32 = 1 << 5;
    /// UART ビジー
    const FR_BUSY: u32 = 1 << 3;

    // ライン制御ビット
    /// 8ビットワード長 (WLEN = 0b11)
    const LCR_WLEN_8: u32 = 0b11 << 5;
    /// FIFO 有効化
    const LCR_FEN: u32 = 1 << 4;
    /// 8N1 = WLEN_8 | FEN = 0x70
    const LCR_8N1: u32 = LCR_WLEN_8 | LCR_FEN;

    // 制御ビット
    /// UART 有効化
    const CR_UARTEN: u32 = 1 << 0;
    /// TX 有効化
    const CR_TXE: u32 = 1 << 8;

    // ボーレート設定 (115200bps @ 125MHz)
    // IBRD = 125000000 / (16 * 115200) = 67
    // FBRD = round(((125000000 % (16 * 115200)) * 64) / (16 * 115200)) = 52
    const IBRD_115200: u32 = 67;
    const FBRD_115200: u32 = 52;
};

// ============================================================
// RESETS / GPIO レジスタ
// ============================================================

const RESETS_BASE: u32 = 0x4000C000;
const ATOMIC_SET: u32 = 0x2000;
const ATOMIC_CLR: u32 = 0x3000;

const RESETS_RESET: u32 = RESETS_BASE + 0x00;
const RESETS_RESET_DONE: u32 = RESETS_BASE + 0x08;
/// UART0 リセットビット (bit 22)
const RESETS_UART0_BIT: u32 = 1 << 22;

const IO_BANK0_BASE: u32 = 0x40014000;
const PADS_BANK0_BASE: u32 = 0x4001C000;

// ============================================================
// レジスタアクセス関数
// ============================================================

inline fn regRead(address: u32) u32 {
    if (!is_freestanding) return 0;
    return @as(*volatile u32, @ptrFromInt(address)).*;
}

inline fn regWrite(address: u32, value: u32) void {
    if (!is_freestanding) return;
    @as(*volatile u32, @ptrFromInt(address)).* = value;
}

// ============================================================
// UART 初期化・送信
// ============================================================

/// UART0 を初期化する
///
/// 初期化シーケンス:
/// 1. UART0 のリセット解除
/// 2. GP0 を UART0 TX に設定 (FUNCSEL = 2)
/// 3. ボーレート設定 (115200bps)
/// 4. ライン制御設定 (8N1)
/// 5. UART 有効化
pub fn init() void {
    if (!is_freestanding) return;

    // 1. UART0 リセット解除
    regWrite(RESETS_RESET + ATOMIC_SET, RESETS_UART0_BIT);
    regWrite(RESETS_RESET + ATOMIC_CLR, RESETS_UART0_BIT);
    while (regRead(RESETS_RESET_DONE) & RESETS_UART0_BIT == 0) {}

    // 2. GP0 を UART0 TX に設定
    // PAD 設定: 出力有効 (OD=0), IE=1, DRIVE=4mA, SCHMITT=1
    // PAD のデフォルト値は 0x56 (IE=1, OD=0, PUE=0, PDE=1, SCHMITT=1, SLEWFAST=0, DRIVE=4mA)
    // TX 出力なので PDE/PUE は不要、デフォルトで問題ない
    regWrite(PADS_BANK0_BASE + 0x04 + 0 * 4, 0x56);
    // IO_BANK0 GPIO0_CTRL: FUNCSEL = 2 (UART)
    regWrite(IO_BANK0_BASE + 0x004 + 0 * 8, 2);

    // 3. ボーレート設定
    regWrite(UartRegs.UARTIBRD, UartRegs.IBRD_115200);
    regWrite(UartRegs.UARTFBRD, UartRegs.FBRD_115200);

    // 4. ライン制御設定 (8N1, FIFO有効)
    // LCR_H への書き込みでボーレート設定が反映される
    regWrite(UartRegs.UARTLCR_H, UartRegs.LCR_8N1);

    // 5. UART 有効化 (UARTEN + TXE)
    regWrite(UartRegs.UARTCR, UartRegs.CR_UARTEN | UartRegs.CR_TXE);
}

/// バイト列を送信する
pub fn write(data: []const u8) void {
    if (!is_freestanding) return;

    for (data) |byte| {
        // TX FIFO に空きができるまで待つ
        while (regRead(UartRegs.UARTFR) & UartRegs.FR_TXFF != 0) {}
        regWrite(UartRegs.UARTDR, byte);
    }
}

/// フォーマット付きデバッグ出力
pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (!is_freestanding) return;

    const writer = Writer{ .context = {} };
    std.fmt.format(writer, fmt, args) catch {};
}

const Writer = std.io.GenericWriter(void, error{}, writeFn);

fn writeFn(_: void, data: []const u8) error{}!usize {
    write(data);
    return data.len;
}

// ============================================================
// テスト
// ============================================================

test "init はテスト環境でクラッシュしない" {
    init();
}

test "write はテスト環境でクラッシュしない" {
    write("hello");
}

test "print はテスト環境でクラッシュしない" {
    print("test {d}\n", .{42});
}

test "UART0 レジスタアドレスの正当性" {
    try std.testing.expectEqual(@as(u32, 0x40034000), UartRegs.UARTDR);
    try std.testing.expectEqual(@as(u32, 0x40034018), UartRegs.UARTFR);
    try std.testing.expectEqual(@as(u32, 0x40034024), UartRegs.UARTIBRD);
    try std.testing.expectEqual(@as(u32, 0x40034028), UartRegs.UARTFBRD);
    try std.testing.expectEqual(@as(u32, 0x4003402C), UartRegs.UARTLCR_H);
    try std.testing.expectEqual(@as(u32, 0x40034030), UartRegs.UARTCR);
}

test "ボーレート設定値の検証 (115200bps @ 125MHz)" {
    // IBRD = 125000000 / (16 * 115200) = 67.816... → 67
    const peri_clk: u32 = 125_000_000;
    const baud: u32 = 115200;
    const ibrd = peri_clk / (16 * baud);
    try std.testing.expectEqual(@as(u32, 67), ibrd);
    try std.testing.expectEqual(UartRegs.IBRD_115200, ibrd);

    // FBRD = round(((125000000 % (16 * 115200)) * 64) / (16 * 115200))
    // = round((1504000 * 64) / 1843200) = round(96256000 / 1843200) = round(52.22...) = 52
    const remainder = peri_clk % (16 * baud);
    const fbrd = (remainder * 64 + (16 * baud) / 2) / (16 * baud);
    try std.testing.expectEqual(@as(u32, 52), fbrd);
    try std.testing.expectEqual(UartRegs.FBRD_115200, fbrd);
}

test "ライン制御ビットの検証" {
    // LCR_8N1 = WLEN_8 | FEN = (0b11 << 5) | (1 << 4) = 0x60 | 0x10 = 0x70
    try std.testing.expectEqual(@as(u32, 0x70), UartRegs.LCR_8N1);
}

test "制御レジスタビットの検証" {
    try std.testing.expectEqual(@as(u32, 1 << 0), UartRegs.CR_UARTEN);
    try std.testing.expectEqual(@as(u32, 1 << 8), UartRegs.CR_TXE);
}

test "RESETS UART0 ビットの検証" {
    try std.testing.expectEqual(@as(u32, 1 << 22), RESETS_UART0_BIT);
}

test "フラグレジスタビットの検証" {
    try std.testing.expectEqual(@as(u32, 1 << 5), UartRegs.FR_TXFF);
    try std.testing.expectEqual(@as(u32, 1 << 3), UartRegs.FR_BUSY);
}
