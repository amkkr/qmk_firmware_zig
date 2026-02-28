// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! RP2040 クロック初期化モジュール
//!
//! RP2040のクロックツリーを初期化する。
//! リセット後のリングオシレータ（~6MHz）から、以下のクロック構成へ移行する:
//! - XOSC: 12MHz 外部クリスタル
//! - PLL_SYS: 125MHz（clk_sys用）
//! - PLL_USB: 48MHz（USB用）
//! - clk_ref: XOSCベース（12MHz）
//! - clk_sys: PLL_SYSベース（125MHz）
//! - clk_usb: PLL_USBベース（48MHz）
//! - clk_peri: clk_sysベース（125MHz）
//!
//! 参照: RP2040データシート Section 2.15 "Clocks", Section 2.18 "PLL"

const std = @import("std");
const builtin = @import("builtin");

const is_test = builtin.is_test;

// ============================================================
// レジスタベースアドレス
// ============================================================

pub const XOSC_BASE: u32 = 0x40024000;
pub const PLL_SYS_BASE: u32 = 0x40028000;
pub const PLL_USB_BASE: u32 = 0x4002C000;
pub const CLOCKS_BASE: u32 = 0x40008000;
pub const RESETS_BASE: u32 = 0x4000C000;
pub const WATCHDOG_BASE: u32 = 0x40058000;

// ============================================================
// アトミックレジスタアクセスオフセット（RP2040 SIO）
// ============================================================

/// レジスタの指定ビットをセット（Read-Modify-Writeなしでアトミック）
const ATOMIC_SET: u32 = 0x2000;
/// レジスタの指定ビットをクリア（Read-Modify-Writeなしでアトミック）
const ATOMIC_CLR: u32 = 0x3000;

// ============================================================
// XOSC レジスタ
// ============================================================

pub const XoscRegs = struct {
    /// XOSC制御レジスタ
    pub const CTRL: u32 = XOSC_BASE + 0x00;
    /// XOSCステータスレジスタ
    pub const STATUS: u32 = XOSC_BASE + 0x04;
    /// XOSC起動遅延設定
    pub const STARTUP: u32 = XOSC_BASE + 0x0C;

    // CTRL フィールド
    pub const CTRL_ENABLE_BITS: u32 = 0x00FAB000;
    /// XOSCシャットダウン時に使用（将来のスリープモード実装用）
    pub const CTRL_DISABLE_BITS: u32 = 0x00D1E000;
    pub const CTRL_FREQ_RANGE_1_15MHZ: u32 = 0xAA0;

    // STATUS フィールド
    pub const STATUS_STABLE_BIT: u32 = 1 << 31;

    /// 起動遅延値: (((12_000_000 / 1000) + 128) / 256) = 47
    /// 256XOSCサイクルを1単位とした待機カウント数
    pub const STARTUP_DELAY: u32 = 47;
};

// ============================================================
// PLL レジスタ
// ============================================================

pub const PllRegs = struct {
    // レジスタオフセット（ベースアドレスからの相対）
    pub const CS_OFFSET: u32 = 0x00;
    pub const PWR_OFFSET: u32 = 0x04;
    pub const FBDIV_INT_OFFSET: u32 = 0x08;
    pub const PRIM_OFFSET: u32 = 0x0C;

    // CS フィールド
    pub const CS_LOCK_BIT: u32 = 1 << 31;

    // PWR フィールド
    pub const PWR_PD_BIT: u32 = 1 << 0;
    pub const PWR_DSMPD_BIT: u32 = 1 << 1;
    pub const PWR_POSTDIVPD_BIT: u32 = 1 << 3;
    pub const PWR_VCOPD_BIT: u32 = 1 << 5;

    /// PLL_SYS設定: 12MHz * 125 / 6 / 2 = 125MHz
    pub const SYS_FBDIV: u32 = 125;
    pub const SYS_POSTDIV1: u32 = 6;
    pub const SYS_POSTDIV2: u32 = 2;

    /// PLL_USB設定: 12MHz * 100 / 5 / 5 = 48MHz
    pub const USB_FBDIV: u32 = 100;
    pub const USB_POSTDIV1: u32 = 5;
    pub const USB_POSTDIV2: u32 = 5;
};

// ============================================================
// クロックレジスタ
// ============================================================

pub const ClockRegs = struct {
    // clk_ref レジスタ
    pub const CLK_REF_CTRL: u32 = CLOCKS_BASE + 0x30;
    pub const CLK_REF_DIV: u32 = CLOCKS_BASE + 0x34;
    pub const CLK_REF_SELECTED: u32 = CLOCKS_BASE + 0x38;

    // clk_sys レジスタ
    pub const CLK_SYS_CTRL: u32 = CLOCKS_BASE + 0x3C;
    pub const CLK_SYS_DIV: u32 = CLOCKS_BASE + 0x40;
    pub const CLK_SYS_SELECTED: u32 = CLOCKS_BASE + 0x44;

    // clk_peri レジスタ
    pub const CLK_PERI_CTRL: u32 = CLOCKS_BASE + 0x48;

    // clk_usb レジスタ
    pub const CLK_USB_CTRL: u32 = CLOCKS_BASE + 0x54;
    pub const CLK_USB_DIV: u32 = CLOCKS_BASE + 0x58;

    // clk_ref ソース選択
    pub const CLK_REF_SRC_ROSC: u32 = 0x0;
    pub const CLK_REF_SRC_AUX: u32 = 0x1;
    pub const CLK_REF_SRC_XOSC: u32 = 0x2;

    // clk_sys ソース選択
    pub const CLK_SYS_SRC_REF: u32 = 0x0;
    pub const CLK_SYS_SRC_AUX: u32 = 0x1;
    pub const CLK_SYS_AUXSRC_PLL_SYS: u32 = 0x0 << 5;

    // clk_peri AUXSRC
    pub const CLK_PERI_AUXSRC_CLK_SYS: u32 = 0x0 << 5;
    pub const CLK_PERI_ENABLE_BIT: u32 = 1 << 11;

    // clk_usb AUXSRC
    pub const CLK_USB_AUXSRC_PLL_USB: u32 = 0x0 << 5;
    pub const CLK_USB_ENABLE_BIT: u32 = 1 << 11;

    // 分周器: 整数部1、小数部0 → 1:1分周（分周なし）
    pub const DIV_1: u32 = 1 << 8;
};

// ============================================================
// RESETSレジスタ
// ============================================================

pub const ResetsRegs = struct {
    pub const RESET: u32 = RESETS_BASE + 0x00;
    pub const RESET_DONE: u32 = RESETS_BASE + 0x08;

    pub const PLL_SYS_BIT: u32 = 1 << 12;
    pub const PLL_USB_BIT: u32 = 1 << 13;
};

// ============================================================
// Watchdog tick レジスタ
// ============================================================

pub const WatchdogRegs = struct {
    pub const TICK: u32 = WATCHDOG_BASE + 0x2C;

    /// clk_ref = 12MHzのとき1μsごとにtick発生
    pub const TICK_CYCLES_12MHZ: u32 = 12;
    pub const TICK_ENABLE_BIT: u32 = 1 << 9;
};

// ============================================================
// レジスタアクセス関数
// ============================================================

/// MMIO揮発性レジスタ読み出し
inline fn regRead(address: u32) u32 {
    if (is_test) return 0;
    return @as(*volatile u32, @ptrFromInt(address)).*;
}

/// MMIO揮発性レジスタ書き込み
inline fn regWrite(address: u32, value: u32) void {
    if (is_test) return;
    @as(*volatile u32, @ptrFromInt(address)).* = value;
}

/// アトミックビットセット（SET aliasを使用）
inline fn regSet(address: u32, bits: u32) void {
    regWrite(address + ATOMIC_SET, bits);
}

/// アトミックビットクリア（CLR aliasを使用）
inline fn regClear(address: u32, bits: u32) void {
    regWrite(address + ATOMIC_CLR, bits);
}

// ============================================================
// クロック初期化
// ============================================================

/// クロックツリー全体を初期化する
///
/// 初期化シーケンス:
/// 1. XOSCを起動し安定化を待つ
/// 2. clk_refをXOSCに切り替え
/// 3. PLL_SYSを設定（125MHz）
/// 4. PLL_USBを設定（48MHz）
/// 5. clk_sysをPLL_SYSに切り替え
/// 6. clk_usbをPLL_USBに切り替え
/// 7. clk_periをclk_sysから設定
/// 8. Watchdogのtickを設定
pub fn init() void {
    if (is_test) return;

    // 1. XOSC起動
    initXosc();

    // 2. clk_refをXOSCに切り替え（PLLの基準クロックとして必要）
    configClkRef();

    // 3. clk_sysを一旦clk_refに退避（PLL再設定前の安全策）
    //    clk_sysのソースをrefに設定し、切り替え完了を待つ
    regWrite(ClockRegs.CLK_SYS_CTRL, ClockRegs.CLK_SYS_SRC_REF);
    while (regRead(ClockRegs.CLK_SYS_SELECTED) & 1 == 0) {}

    // 4. PLL_SYS設定（12MHz → 125MHz）
    initPll(PLL_SYS_BASE, PllRegs.SYS_FBDIV, PllRegs.SYS_POSTDIV1, PllRegs.SYS_POSTDIV2);

    // 5. PLL_USB設定（12MHz → 48MHz）
    initPll(PLL_USB_BASE, PllRegs.USB_FBDIV, PllRegs.USB_POSTDIV1, PllRegs.USB_POSTDIV2);

    // 6. clk_sysをPLL_SYSに切り替え
    configClkSys();

    // 7. clk_usbをPLL_USBに切り替え
    configClkUsb();

    // 8. clk_periをclk_sysから設定
    configClkPeri();

    // 9. Watchdog tickの設定（clk_ref=12MHz基準で1μsタイマー）
    configWatchdogTick();
}

/// XOSC（外部クリスタルオシレータ）を起動する
///
/// 12MHz外部クリスタルを起動し、安定するまで待機する。
/// RP2040データシート Section 2.16.3 参照。
fn initXosc() void {
    if (is_test) return;
    // 起動遅延を設定
    regWrite(XoscRegs.STARTUP, XoscRegs.STARTUP_DELAY);

    // XOSCを有効化（周波数レンジ1-15MHzとENABLEを同時に設定）
    regWrite(XoscRegs.CTRL, XoscRegs.CTRL_FREQ_RANGE_1_15MHZ | XoscRegs.CTRL_ENABLE_BITS);

    // 安定化を待つ
    while (regRead(XoscRegs.STATUS) & XoscRegs.STATUS_STABLE_BIT == 0) {}
}

/// PLLを初期化する
///
/// VCO周波数 = FREF * FBDIV
/// 出力周波数 = VCO / (POSTDIV1 * POSTDIV2)
///
/// PLL_SYS: 12MHz * 125 / (6 * 2) = 125MHz
/// PLL_USB: 12MHz * 100 / (5 * 5) = 48MHz
///
/// RP2040データシート Section 2.18.2 参照。
fn initPll(pll_base: u32, fbdiv: u32, postdiv1: u32, postdiv2: u32) void {
    if (is_test) return;
    const cs = pll_base + PllRegs.CS_OFFSET;
    const pwr = pll_base + PllRegs.PWR_OFFSET;
    const fbdiv_reg = pll_base + PllRegs.FBDIV_INT_OFFSET;
    const prim = pll_base + PllRegs.PRIM_OFFSET;

    // PLLをリセット解除
    const reset_bit = if (pll_base == PLL_SYS_BASE) ResetsRegs.PLL_SYS_BIT else ResetsRegs.PLL_USB_BIT;
    resetSubsystem(reset_bit);

    // FBDIVを設定
    regWrite(fbdiv_reg, fbdiv);

    // VCOとPLL本体の電源をオン（PD=0, VCOPD=0）、ポストディバイダは一旦オフのまま
    regWrite(pwr, PllRegs.PWR_DSMPD_BIT | PllRegs.PWR_POSTDIVPD_BIT);

    // VCOがロックするまで待つ
    while (regRead(cs) & PllRegs.CS_LOCK_BIT == 0) {}

    // ポストディバイダを設定
    regWrite(prim, (postdiv1 << 16) | (postdiv2 << 12));

    // ポストディバイダの電源をオン
    regClear(pwr, PllRegs.PWR_POSTDIVPD_BIT);
}

/// clk_refをXOSCに切り替える
fn configClkRef() void {
    if (is_test) return;
    // 分周器を1:1に設定
    regWrite(ClockRegs.CLK_REF_DIV, ClockRegs.DIV_1);

    // ソースをXOSCに設定
    regWrite(ClockRegs.CLK_REF_CTRL, ClockRegs.CLK_REF_SRC_XOSC);

    // 切り替え完了を待つ（CLK_REF_SELECTEDのビット2がセットされるまで）
    while (regRead(ClockRegs.CLK_REF_SELECTED) & (1 << 2) == 0) {}
}

/// clk_sysをPLL_SYSに切り替える
fn configClkSys() void {
    if (is_test) return;
    // 分周器を1:1に設定
    regWrite(ClockRegs.CLK_SYS_DIV, ClockRegs.DIV_1);

    // AUXSRCをPLL_SYSに設定（SRCはまだrefのまま）
    regWrite(ClockRegs.CLK_SYS_CTRL, ClockRegs.CLK_SYS_AUXSRC_PLL_SYS);

    // SRCをAUXに切り替え
    regWrite(ClockRegs.CLK_SYS_CTRL, ClockRegs.CLK_SYS_AUXSRC_PLL_SYS | ClockRegs.CLK_SYS_SRC_AUX);

    // 切り替え完了を待つ（CLK_SYS_SELECTEDのビット1がセットされるまで）
    while (regRead(ClockRegs.CLK_SYS_SELECTED) & (1 << 1) == 0) {}
}

/// clk_usbをPLL_USBに切り替える
fn configClkUsb() void {
    if (is_test) return;
    // 分周器を1:1に設定
    regWrite(ClockRegs.CLK_USB_DIV, ClockRegs.DIV_1);

    // AUXSRCをPLL_USBに設定し、有効化
    regWrite(ClockRegs.CLK_USB_CTRL, ClockRegs.CLK_USB_AUXSRC_PLL_USB | ClockRegs.CLK_USB_ENABLE_BIT);
}

/// clk_periをclk_sysから設定する
fn configClkPeri() void {
    if (is_test) return;
    // AUXSRCをclk_sysに設定し、有効化
    regWrite(ClockRegs.CLK_PERI_CTRL, ClockRegs.CLK_PERI_AUXSRC_CLK_SYS | ClockRegs.CLK_PERI_ENABLE_BIT);
}

/// Watchdogのtickを設定する
///
/// clk_ref（12MHz）をベースに1μsのtickを生成する。
/// タイマー等のペリフェラルで使用される。
fn configWatchdogTick() void {
    if (is_test) return;
    regWrite(WatchdogRegs.TICK, WatchdogRegs.TICK_CYCLES_12MHZ | WatchdogRegs.TICK_ENABLE_BIT);
}

/// サブシステムをリセット解除する
///
/// RESETレジスタの対象ビットをクリアしてリセット解除し、
/// RESET_DONEで完了を確認する。
fn resetSubsystem(bit: u32) void {
    if (is_test) return;
    // リセットアサート
    regSet(ResetsRegs.RESET, bit);
    // リセット解除
    regClear(ResetsRegs.RESET, bit);
    // リセット完了を待つ
    while (regRead(ResetsRegs.RESET_DONE) & bit == 0) {}
}

// ============================================================
// 周波数定数（他モジュールから参照用）
// ============================================================

/// システムクロック周波数（Hz）
pub const SYS_CLK_HZ: u32 = 125_000_000;

/// USBクロック周波数（Hz）
pub const USB_CLK_HZ: u32 = 48_000_000;

/// リファレンスクロック周波数（Hz）
pub const REF_CLK_HZ: u32 = 12_000_000;

/// XOSCクリスタル周波数（Hz）
pub const XOSC_HZ: u32 = 12_000_000;

// ============================================================
// テスト
// ============================================================

test "レジスタアドレスの正当性" {
    // XOSC レジスタアドレス
    try std.testing.expectEqual(@as(u32, 0x40024000), XoscRegs.CTRL);
    try std.testing.expectEqual(@as(u32, 0x40024004), XoscRegs.STATUS);
    try std.testing.expectEqual(@as(u32, 0x4002400C), XoscRegs.STARTUP);

    // PLL_SYS レジスタアドレス
    try std.testing.expectEqual(@as(u32, 0x40028000), PLL_SYS_BASE + PllRegs.CS_OFFSET);
    try std.testing.expectEqual(@as(u32, 0x40028004), PLL_SYS_BASE + PllRegs.PWR_OFFSET);
    try std.testing.expectEqual(@as(u32, 0x40028008), PLL_SYS_BASE + PllRegs.FBDIV_INT_OFFSET);
    try std.testing.expectEqual(@as(u32, 0x4002800C), PLL_SYS_BASE + PllRegs.PRIM_OFFSET);

    // PLL_USB レジスタアドレス
    try std.testing.expectEqual(@as(u32, 0x4002C000), PLL_USB_BASE + PllRegs.CS_OFFSET);
    try std.testing.expectEqual(@as(u32, 0x4002C004), PLL_USB_BASE + PllRegs.PWR_OFFSET);
    try std.testing.expectEqual(@as(u32, 0x4002C008), PLL_USB_BASE + PllRegs.FBDIV_INT_OFFSET);
    try std.testing.expectEqual(@as(u32, 0x4002C00C), PLL_USB_BASE + PllRegs.PRIM_OFFSET);

    // CLOCKSレジスタアドレス
    try std.testing.expectEqual(@as(u32, 0x40008030), ClockRegs.CLK_REF_CTRL);
    try std.testing.expectEqual(@as(u32, 0x40008034), ClockRegs.CLK_REF_DIV);
    try std.testing.expectEqual(@as(u32, 0x40008038), ClockRegs.CLK_REF_SELECTED);
    try std.testing.expectEqual(@as(u32, 0x4000803C), ClockRegs.CLK_SYS_CTRL);
    try std.testing.expectEqual(@as(u32, 0x40008040), ClockRegs.CLK_SYS_DIV);
    try std.testing.expectEqual(@as(u32, 0x40008044), ClockRegs.CLK_SYS_SELECTED);
    try std.testing.expectEqual(@as(u32, 0x40008048), ClockRegs.CLK_PERI_CTRL);
    try std.testing.expectEqual(@as(u32, 0x40008054), ClockRegs.CLK_USB_CTRL);
    try std.testing.expectEqual(@as(u32, 0x40008058), ClockRegs.CLK_USB_DIV);

    // RESETS レジスタアドレス
    try std.testing.expectEqual(@as(u32, 0x4000C000), ResetsRegs.RESET);
    try std.testing.expectEqual(@as(u32, 0x4000C008), ResetsRegs.RESET_DONE);

    // Watchdog レジスタアドレス
    try std.testing.expectEqual(@as(u32, 0x4005802C), WatchdogRegs.TICK);
}

test "PLL周波数計算の検証" {
    // PLL_SYS: 12MHz * 125 / (6 * 2) = 125MHz
    const sys_vco = XOSC_HZ * PllRegs.SYS_FBDIV;
    const sys_freq = sys_vco / (PllRegs.SYS_POSTDIV1 * PllRegs.SYS_POSTDIV2);
    try std.testing.expectEqual(SYS_CLK_HZ, sys_freq);

    // PLL_USB: 12MHz * 100 / (5 * 5) = 48MHz
    const usb_vco = XOSC_HZ * PllRegs.USB_FBDIV;
    const usb_freq = usb_vco / (PllRegs.USB_POSTDIV1 * PllRegs.USB_POSTDIV2);
    try std.testing.expectEqual(USB_CLK_HZ, usb_freq);
}

test "VCO周波数がRP2040の有効範囲内であることを確認" {
    // RP2040のVCO有効範囲: 750MHz - 1600MHz
    const VCO_MIN: u32 = 750_000_000;
    const VCO_MAX: u32 = 1_600_000_000;

    const sys_vco = XOSC_HZ * PllRegs.SYS_FBDIV;
    try std.testing.expect(sys_vco >= VCO_MIN);
    try std.testing.expect(sys_vco <= VCO_MAX);

    const usb_vco = XOSC_HZ * PllRegs.USB_FBDIV;
    try std.testing.expect(usb_vco >= VCO_MIN);
    try std.testing.expect(usb_vco <= VCO_MAX);
}

test "FBDIV値がRP2040の有効範囲内であることを確認" {
    // RP2040のFBDIV有効範囲: 16 - 320
    try std.testing.expect(PllRegs.SYS_FBDIV >= 16);
    try std.testing.expect(PllRegs.SYS_FBDIV <= 320);
    try std.testing.expect(PllRegs.USB_FBDIV >= 16);
    try std.testing.expect(PllRegs.USB_FBDIV <= 320);
}

test "ポストディバイダ値がRP2040の有効範囲内であることを確認" {
    // POSTDIV1, POSTDIV2: 1-7、POSTDIV1 >= POSTDIV2
    try std.testing.expect(PllRegs.SYS_POSTDIV1 >= 1);
    try std.testing.expect(PllRegs.SYS_POSTDIV1 <= 7);
    try std.testing.expect(PllRegs.SYS_POSTDIV2 >= 1);
    try std.testing.expect(PllRegs.SYS_POSTDIV2 <= 7);
    try std.testing.expect(PllRegs.SYS_POSTDIV1 >= PllRegs.SYS_POSTDIV2);

    try std.testing.expect(PllRegs.USB_POSTDIV1 >= 1);
    try std.testing.expect(PllRegs.USB_POSTDIV1 <= 7);
    try std.testing.expect(PllRegs.USB_POSTDIV2 >= 1);
    try std.testing.expect(PllRegs.USB_POSTDIV2 <= 7);
    try std.testing.expect(PllRegs.USB_POSTDIV1 >= PllRegs.USB_POSTDIV2);
}

test "XOSC起動遅延の計算が正しいことを確認" {
    // STARTUP_DELAY = ((XOSC_HZ / 1000) + 128) / 256
    // = (12000 + 128) / 256 = 12128 / 256 = 47
    const calculated_delay = ((XOSC_HZ / 1000) + 128) / 256;
    try std.testing.expectEqual(XoscRegs.STARTUP_DELAY, calculated_delay);
}

test "周波数定数の整合性" {
    try std.testing.expectEqual(@as(u32, 125_000_000), SYS_CLK_HZ);
    try std.testing.expectEqual(@as(u32, 48_000_000), USB_CLK_HZ);
    try std.testing.expectEqual(@as(u32, 12_000_000), REF_CLK_HZ);
    try std.testing.expectEqual(@as(u32, 12_000_000), XOSC_HZ);
}

test "ビットフィールド定数の検証" {
    // XOSC
    try std.testing.expectEqual(@as(u32, 1 << 31), XoscRegs.STATUS_STABLE_BIT);

    // PLL
    try std.testing.expectEqual(@as(u32, 1 << 31), PllRegs.CS_LOCK_BIT);
    try std.testing.expectEqual(@as(u32, 1 << 0), PllRegs.PWR_PD_BIT);
    try std.testing.expectEqual(@as(u32, 1 << 5), PllRegs.PWR_VCOPD_BIT);
    try std.testing.expectEqual(@as(u32, 1 << 3), PllRegs.PWR_POSTDIVPD_BIT);

    // Clocks
    try std.testing.expectEqual(@as(u32, 1 << 11), ClockRegs.CLK_PERI_ENABLE_BIT);
    try std.testing.expectEqual(@as(u32, 1 << 11), ClockRegs.CLK_USB_ENABLE_BIT);

    // RESETS
    try std.testing.expectEqual(@as(u32, 1 << 12), ResetsRegs.PLL_SYS_BIT);
    try std.testing.expectEqual(@as(u32, 1 << 13), ResetsRegs.PLL_USB_BIT);

    // Watchdog
    try std.testing.expectEqual(@as(u32, 1 << 9), WatchdogRegs.TICK_ENABLE_BIT);
}

test "PRIMレジスタのポストディバイダ値エンコーディング" {
    // PRIM = (POSTDIV1 << 16) | (POSTDIV2 << 12)
    const sys_prim = (PllRegs.SYS_POSTDIV1 << 16) | (PllRegs.SYS_POSTDIV2 << 12);
    try std.testing.expectEqual(@as(u32, (6 << 16) | (2 << 12)), sys_prim);

    const usb_prim = (PllRegs.USB_POSTDIV1 << 16) | (PllRegs.USB_POSTDIV2 << 12);
    try std.testing.expectEqual(@as(u32, (5 << 16) | (5 << 12)), usb_prim);
}

test "アトミックレジスタオフセットの検証" {
    try std.testing.expectEqual(@as(u32, 0x2000), ATOMIC_SET);
    try std.testing.expectEqual(@as(u32, 0x3000), ATOMIC_CLR);
}

test "Watchdog tick設定値の検証" {
    // 12MHzクロックで1μsあたり12サイクル
    try std.testing.expectEqual(@as(u32, 12), WatchdogRegs.TICK_CYCLES_12MHZ);
    // TICK_ENABLE_BITはbit 9
    try std.testing.expectEqual(@as(u32, 0x200), WatchdogRegs.TICK_ENABLE_BIT);
    // 設定値 = CYCLES | ENABLE = 12 | 512 = 524
    const tick_value = WatchdogRegs.TICK_CYCLES_12MHZ | WatchdogRegs.TICK_ENABLE_BIT;
    try std.testing.expectEqual(@as(u32, 0x20C), tick_value);
}
