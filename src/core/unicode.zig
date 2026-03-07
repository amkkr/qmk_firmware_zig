// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! Unicode 入力処理
//! C版 quantum/unicode/unicode.c, quantum/unicode/ucis.c に相当
//!
//! OS別のUnicode入力方式を管理し、Unicode キーコードを
//! OS固有のキーシーケンスに変換して送信する。
//!
//! サポートする入力方式:
//!   - Basic Unicode: キーコードに直接15bitコードポイントを埋め込む（U+0000-U+7FFF）
//!   - Unicode Map: comptime テーブルのインデックスで32bitコードポイントを参照（U+10FFFF まで）
//!   - UCIS (Unicode Input System): ニーモニック文字列でコードポイントを検索・入力
//!
//! 入力フロー:
//!   1. unicodeInputStart(): OS別の開始シーケンスを送信
//!   2. registerHex32(): コードポイントを16進数で一桁ずつ入力
//!   3. unicodeInputFinish(): OS別の終了シーケンスを送信

const keycode_mod = @import("keycode.zig");
const host = @import("host.zig");
const Keycode = keycode_mod.Keycode;
const KC = keycode_mod.KC;

/// Unicode 入力モード（OS別の入力方式）
pub const UnicodeMode = enum(u8) {
    macos,
    linux,
    windows,
    bsd,
    wincompose,
    emacs,
};

/// Unicode モード数
const MODE_COUNT = @typeInfo(UnicodeMode).@"enum".fields.len;

/// Shift キービットマスク（LSFT = 0x02, RSFT = 0x20）
const SHIFT_MODS_MASK: u8 = 0x02 | 0x20;

/// 現在の Unicode 入力モード
var unicode_mode: UnicodeMode = .linux;

/// Unicode 入力中に保存する修飾キー状態
var saved_mods: u8 = 0;

// ============================================================
// Unicode Map テーブル（comptime 設定）
// ============================================================

/// Unicode Map テーブル型: 32bit コードポイントの配列
/// ユーザーは setUnicodeMap() で comptime テーブルを設定する。
/// C版 unicode_map[] に相当。
var unicode_map: ?[]const u32 = null;

/// Unicode Map テーブルを設定する
pub fn setUnicodeMap(map: []const u32) void {
    unicode_map = map;
}

/// Unicode Map テーブルをクリアする（テスト用）
pub fn clearUnicodeMap() void {
    unicode_map = null;
}

/// Unicode Map インデックスからコードポイントを取得する
/// C版 unicodemap_get_code_point() に相当
pub fn unicodeMapGetCodePoint(index: u14) ?u32 {
    if (unicode_map) |map| {
        if (index < map.len) {
            return map[index];
        }
    }
    return null;
}

// ============================================================
// UCIS (Unicode Input System)
// ============================================================

/// UCIS シンボル定義: ニーモニック文字列と対応するコードポイント列
/// C版 ucis_symbol_t に相当
pub const UcisSymbol = struct {
    /// ニーモニック文字列（例: "smile", "heart"）
    mnemonic: []const u8,
    /// 対応するコードポイント列（最大 UCIS_MAX_CODE_POINTS 個、0 でターミネート）
    code_points: []const u32,
};

/// UCIS 最大入力長
pub const UCIS_MAX_INPUT_LENGTH: u8 = 32;

/// UCIS 状態
var ucis_active: bool = false;
var ucis_count: u8 = 0;
var ucis_input: [UCIS_MAX_INPUT_LENGTH]u8 = .{0} ** UCIS_MAX_INPUT_LENGTH;

/// UCIS シンボルテーブル（ユーザーが設定）
var ucis_symbol_table: ?[]const UcisSymbol = null;

/// UCIS シンボルテーブルを設定する
pub fn setUcisSymbolTable(table: []const UcisSymbol) void {
    ucis_symbol_table = table;
}

/// UCIS シンボルテーブルをクリアする（テスト用）
pub fn clearUcisSymbolTable() void {
    ucis_symbol_table = null;
}

/// UCIS セッションを開始する
/// C版 ucis_start() に相当
pub fn ucisStart() void {
    ucis_active = true;
    ucis_count = 0;
    ucis_input = .{0} ** UCIS_MAX_INPUT_LENGTH;
}

/// UCIS がアクティブかどうか
pub fn ucisIsActive() bool {
    return ucis_active;
}

/// UCIS 入力バッファのカウント
pub fn ucisGetCount() u8 {
    return ucis_count;
}

/// キーコードを文字に変換する（A-Z, 0-9 のみ対応）
/// C版 keycode_to_char() に相当
fn keycodeToChar(kc: Keycode) ?u8 {
    if (kc >= KC.A and kc <= KC.Z) {
        return @as(u8, 'a') + @as(u8, @truncate(kc - KC.A));
    } else if (kc >= KC.@"1" and kc <= KC.@"9") {
        return @as(u8, '1') + @as(u8, @truncate(kc - KC.@"1"));
    } else if (kc == KC.@"0") {
        return '0';
    }
    return null;
}

/// UCIS 入力バッファに文字を追加する
/// C版 ucis_add() に相当
/// 戻り値: true = 追加成功, false = 変換不可 or バッファフル
pub fn ucisAdd(kc: Keycode) bool {
    if (ucis_count >= UCIS_MAX_INPUT_LENGTH) return false;
    if (keycodeToChar(kc)) |c| {
        ucis_input[ucis_count] = c;
        ucis_count += 1;
        return true;
    }
    return false;
}

/// UCIS 入力バッファから最後の文字を削除する
/// C版 ucis_remove_last() に相当
pub fn ucisRemoveLast() bool {
    if (ucis_count > 0) {
        ucis_count -= 1;
        ucis_input[ucis_count] = 0;
        return true;
    }
    return false;
}

/// ニーモニック文字列と入力バッファを照合する
/// C版 match_mnemonic() に相当
fn matchMnemonic(mnemonic: []const u8) bool {
    if (mnemonic.len != ucis_count) return false;
    for (0..ucis_count) |i| {
        if (ucis_input[i] != mnemonic[i]) {
            return false;
        }
    }
    return true;
}

/// UCIS 入力を確定し、マッチしたシンボルの Unicode コードポイントを送信する
/// C版 ucis_finish() に相当
/// 戻り値: true = マッチ成功, false = マッチなし
pub fn ucisFinish() bool {
    var found = false;
    var found_index: usize = 0;

    if (ucis_symbol_table) |table| {
        for (table, 0..) |sym, i| {
            if (matchMnemonic(sym.mnemonic)) {
                found = true;
                found_index = i;
                break;
            }
        }
    }

    if (found) {
        // 入力した文字を Backspace で削除
        for (0..ucis_count) |_| {
            tapCode(KC.BACKSPACE);
        }
        // マッチしたシンボルのコードポイントを送信
        // found == true の場合 ucis_symbol_table は常に non-null が保証されている
        const table = ucis_symbol_table orelse unreachable;
        for (table[found_index].code_points) |cp| {
            if (cp == 0) break;
            registerUnicode(cp);
        }
    }

    ucis_active = false;
    return found;
}

/// UCIS セッションをキャンセルする
/// C版 ucis_cancel() に相当
pub fn ucisCancel() void {
    ucis_active = false;
    ucis_count = 0;
}

// ============================================================
// モード管理
// ============================================================

/// 現在の Unicode 入力モードを取得する
pub fn getMode() UnicodeMode {
    return unicode_mode;
}

/// Unicode 入力モードを設定する
pub fn setMode(mode: UnicodeMode) void {
    unicode_mode = mode;
}

/// Unicode 入力モードを循環する
/// forward=true: 次のモード、forward=false: 前のモード
pub fn cycleMode(forward: bool) void {
    const current = @intFromEnum(unicode_mode);
    const next = if (forward)
        (current + 1) % MODE_COUNT
    else
        (current + MODE_COUNT - 1) % MODE_COUNT;
    unicode_mode = @enumFromInt(next);
}

// ============================================================
// キーコード処理
// ============================================================

/// Unicode キーコードを処理する
/// 戻り値: true = 通常処理続行, false = キーを消費（Unicode として処理済み）
pub fn process(kc: Keycode, pressed: bool) bool {
    // UC_NEXT / UC_PREV
    if (kc == keycode_mod.UC_NEXT) {
        if (pressed) {
            cycleMode(true);
        }
        return false;
    }
    if (kc == keycode_mod.UC_PREV) {
        if (pressed) {
            cycleMode(false);
        }
        return false;
    }

    // Unicode Map Pair (0xC000-0xFFFF): Shift対応ペア
    // isUnicodeMapPair は isUnicodeMap より先にチェック（範囲が重ならないため順序は重要）
    if (keycode_mod.isUnicodeMapPair(kc)) {
        if (pressed) {
            const indices = keycode_mod.unicodeMapPairGetIndices(kc);
            const shifted = (host.getMods() & SHIFT_MODS_MASK) != 0;
            const index = if (shifted) indices.shifted else indices.normal;
            if (unicodeMapGetCodePoint(index)) |cp| {
                // Shift を一時的に解除してコードポイントを送信
                if (shifted) {
                    const mods = host.getMods();
                    host.setMods(mods & ~SHIFT_MODS_MASK);
                    host.sendKeyboardReport();
                    registerUnicode(cp);
                    host.setMods(mods);
                    host.sendKeyboardReport();
                } else {
                    registerUnicode(cp);
                }
            }
        }
        return false;
    }

    // Unicode Map (0x8000-0xBFFF): unicode_map テーブルが設定されている場合はインデックス参照
    // テーブル未設定時は Basic Unicode として直接コードポイントを使用（後方互換）
    if (keycode_mod.isUnicodeMap(kc)) {
        if (pressed) {
            if (unicode_map != null) {
                // Unicode Map モード: テーブルからコードポイントを取得
                const index = keycode_mod.unicodeMapGetIndex(kc);
                if (unicodeMapGetCodePoint(index)) |cp| {
                    registerUnicode(cp);
                }
            } else {
                // レガシーモード: 下位15bitをコードポイントとして直接使用
                const code_point = keycode_mod.unicodeGetCodePoint(kc);
                registerUnicode(@as(u32, code_point));
            }
        }
        return false;
    }

    // それ以外は通常処理に回す
    return true;
}

// ============================================================
// Unicode 入力シーケンス
// ============================================================

/// 32bit コードポイントを登録（入力シーケンス全体を送信）する
/// C版 register_unicode() に相当
/// macOS の UTF-16 サロゲートペア対応を含む
pub fn registerUnicode(code_point: u32) void {
    if (code_point > 0x10FFFF) return;

    // Windows モードは BMP のみサポート
    if (code_point > 0xFFFF and unicode_mode == .windows) return;

    unicodeInputStart();

    if (code_point > 0xFFFF and unicode_mode == .macos) {
        // macOS: UTF-16 サロゲートペアに変換
        const cp = code_point - 0x10000;
        const hi = (cp >> 10) + 0xD800;
        const lo = (cp & 0x3FF) + 0xDC00;
        registerHex32(hi);
        registerHex32(lo);
    } else {
        registerHex32(code_point);
    }

    unicodeInputFinish();
}

/// UTF-8 文字列の各文字を Unicode として送信する
/// C版 send_unicode_string() に相当
pub fn sendUnicodeString(str: []const u8) void {
    var i: usize = 0;
    while (i < str.len) {
        const result = decodeUtf8(str[i..]);
        if (result.code_point) |cp| {
            registerUnicode(cp);
        }
        i += result.bytes_consumed;
    }
}

/// UTF-8 デコード結果
pub const Utf8DecodeResult = struct {
    code_point: ?u32,
    bytes_consumed: usize,
};

/// UTF-8 バイト列から1文字をデコードする
/// C版 decode_utf8() に相当
///
/// 注意: 組み込み用途の簡略実装のため、継続バイト（10xxxxxx）の妥当性検証を省略している。
/// 不正なバイト列（例: 0x80-0xBF から始まる列や、継続バイトが 10xxxxxx でないもの）は
/// 誤ったコードポイントとして解釈される可能性がある。
/// 正しい入力（有効な UTF-8 文字列）が前提であり、不正入力の検証は呼び出し元の責任とする。
pub fn decodeUtf8(bytes: []const u8) Utf8DecodeResult {
    if (bytes.len == 0) {
        return .{ .code_point = null, .bytes_consumed = 0 };
    }

    const b0 = bytes[0];

    // 1バイト文字 (0xxxxxxx)
    if (b0 < 0x80) {
        return .{ .code_point = b0, .bytes_consumed = 1 };
    }

    // 2バイト文字 (110xxxxx 10xxxxxx)
    if (b0 >= 0xC0 and b0 < 0xE0) {
        if (bytes.len < 2) return .{ .code_point = null, .bytes_consumed = 1 };
        const cp = (@as(u32, b0 & 0x1F) << 6) |
            @as(u32, bytes[1] & 0x3F);
        return .{ .code_point = cp, .bytes_consumed = 2 };
    }

    // 3バイト文字 (1110xxxx 10xxxxxx 10xxxxxx)
    if (b0 >= 0xE0 and b0 < 0xF0) {
        if (bytes.len < 3) return .{ .code_point = null, .bytes_consumed = 1 };
        const cp = (@as(u32, b0 & 0x0F) << 12) |
            (@as(u32, bytes[1] & 0x3F) << 6) |
            @as(u32, bytes[2] & 0x3F);
        return .{ .code_point = cp, .bytes_consumed = 3 };
    }

    // 4バイト文字 (11110xxx 10xxxxxx 10xxxxxx 10xxxxxx)
    if (b0 >= 0xF0 and b0 < 0xF8) {
        if (bytes.len < 4) return .{ .code_point = null, .bytes_consumed = 1 };
        const cp = (@as(u32, b0 & 0x07) << 18) |
            (@as(u32, bytes[1] & 0x3F) << 12) |
            (@as(u32, bytes[2] & 0x3F) << 6) |
            @as(u32, bytes[3] & 0x3F);
        return .{ .code_point = cp, .bytes_consumed = 4 };
    }

    // 不正なバイト
    return .{ .code_point = null, .bytes_consumed = 1 };
}

/// OS別の Unicode 入力開始シーケンスを送信する
pub fn unicodeInputStart() void {
    // 既存の修飾キーを保存して一旦クリアする
    saved_mods = host.getMods();
    host.setMods(0);
    host.sendKeyboardReport();

    switch (unicode_mode) {
        .macos => {
            // macOS: Option キーを押す（Hex Input が有効である前提）
            host.registerCode(KC.LEFT_ALT);
            host.sendKeyboardReport();
        },
        .linux, .bsd => {
            // Linux/BSD: Ctrl+Shift+U を押す
            host.registerCode(KC.LEFT_CTRL);
            host.registerCode(KC.LEFT_SHIFT);
            host.registerCode(KC.U);
            host.sendKeyboardReport();
            // U を離す（Ctrl+Shift は押したまま）
            host.unregisterCode(KC.U);
            host.sendKeyboardReport();
        },
        .windows => {
            // Windows: Alt キーを押す（Alt code 入力、Numpad 使用）
            host.registerCode(KC.LEFT_ALT);
            host.sendKeyboardReport();
        },
        .wincompose => {
            // WinCompose: Right Alt をタップ → U をタップ
            tapCode(KC.RIGHT_ALT);
            tapCode(KC.U);
        },
        .emacs => {
            // Emacs: Ctrl+X をタップ → 8 をタップ → Return をタップ
            host.registerCode(KC.LEFT_CTRL);
            host.sendKeyboardReport();
            tapCode(KC.X);
            host.unregisterCode(KC.LEFT_CTRL);
            host.sendKeyboardReport();
            tapCode(KC.@"8");
            tapCode(KC.ENTER);
        },
    }
}

/// OS別の Unicode 入力終了シーケンスを送信する
pub fn unicodeInputFinish() void {
    switch (unicode_mode) {
        .macos => {
            // macOS: Option キーを離す
            host.unregisterCode(KC.LEFT_ALT);
            host.sendKeyboardReport();
        },
        .linux, .bsd => {
            // Linux/BSD: Space をタップして確定、Ctrl+Shift を離す
            tapCode(KC.SPACE);
            host.unregisterCode(KC.LEFT_CTRL);
            host.unregisterCode(KC.LEFT_SHIFT);
            host.sendKeyboardReport();
        },
        .windows => {
            // Windows: Alt キーを離す
            host.unregisterCode(KC.LEFT_ALT);
            host.sendKeyboardReport();
        },
        .wincompose => {
            // WinCompose: 追加の終了シーケンスなし
        },
        .emacs => {
            // Emacs: Return をタップして確定
            tapCode(KC.ENTER);
        },
    }

    // 保存した修飾キーを復元する
    host.setMods(saved_mods);
    host.sendKeyboardReport();
}

/// OS別の Unicode 入力キャンセルシーケンスを送信する
/// C版 unicode_input_cancel() に相当
pub fn unicodeInputCancel() void {
    switch (unicode_mode) {
        .macos => {
            host.unregisterCode(KC.LEFT_ALT);
            host.sendKeyboardReport();
        },
        .linux, .bsd => {
            tapCode(KC.ESCAPE);
        },
        .windows => {
            host.unregisterCode(KC.LEFT_ALT);
            host.sendKeyboardReport();
        },
        .wincompose => {
            tapCode(KC.ESCAPE);
        },
        .emacs => {
            // Ctrl+G でキャンセル
            host.registerCode(KC.LEFT_CTRL);
            host.sendKeyboardReport();
            tapCode(KC.G);
            host.unregisterCode(KC.LEFT_CTRL);
            host.sendKeyboardReport();
        },
    }

    // 保存した修飾キーを復元する
    host.setMods(saved_mods);
    host.sendKeyboardReport();
}

/// コードポイントを16進数で入力する（32bit 対応、上位の0は省略）
/// C版 register_hex32() に相当
/// WinCompose モードでは先頭が A-F の場合にリーディングゼロを付加
fn registerHex32(code_point: u32) void {
    var started = false;
    const needs_leading_zero = (unicode_mode == .wincompose);

    // 最大 8 ニブル（32bit）
    var shift: u5 = 28;
    while (true) : (shift -= 4) {
        const digit: u4 = @truncate((code_point >> shift) & 0xF);

        // WinCompose: 先頭が A-F の場合にリーディングゼロを付加
        if (!started and needs_leading_zero and digit > 9) {
            tapCode(hexToKeycode(0));
        }

        // 下位16bit（4ニブル）以降は常に送信
        const must_send = shift < 16;

        if (digit != 0 or started or must_send) {
            started = true;
            tapCode(hexToKeycode(digit));
        }
        if (shift == 0) break;
    }
}

/// 16進数の1桁をキーコードに変換する
fn hexToKeycode(digit: u4) u8 {
    return switch (digit) {
        0x0 => KC.@"0",
        0x1 => KC.@"1",
        0x2 => KC.@"2",
        0x3 => KC.@"3",
        0x4 => KC.@"4",
        0x5 => KC.@"5",
        0x6 => KC.@"6",
        0x7 => KC.@"7",
        0x8 => KC.@"8",
        0x9 => KC.@"9",
        0xA => KC.A,
        0xB => KC.B,
        0xC => KC.C,
        0xD => KC.D,
        0xE => KC.E,
        0xF => KC.F,
    };
}

/// キーコードをタップする（press → report送信 → release → report送信）
fn tapCode(kc: u8) void {
    host.registerCode(kc);
    host.sendKeyboardReport();
    host.unregisterCode(kc);
    host.sendKeyboardReport();
}

/// 状態リセット（テスト用）
pub fn reset() void {
    unicode_mode = .linux;
    saved_mods = 0;
    ucis_active = false;
    ucis_count = 0;
    ucis_input = .{0} ** UCIS_MAX_INPUT_LENGTH;
}

// ============================================================
// Tests
// ============================================================

const std = @import("std");
const testing = std.testing;

test "UnicodeMode 初期値は linux" {
    reset();
    try testing.expectEqual(UnicodeMode.linux, getMode());
}

test "setMode / getMode" {
    reset();
    setMode(.macos);
    try testing.expectEqual(UnicodeMode.macos, getMode());
    setMode(.windows);
    try testing.expectEqual(UnicodeMode.windows, getMode());
}

test "cycleMode forward" {
    reset();
    setMode(.macos);
    cycleMode(true); // macos -> linux
    try testing.expectEqual(UnicodeMode.linux, getMode());
    cycleMode(true); // linux -> windows
    try testing.expectEqual(UnicodeMode.windows, getMode());
    cycleMode(true); // windows -> bsd
    try testing.expectEqual(UnicodeMode.bsd, getMode());
    cycleMode(true); // bsd -> wincompose
    try testing.expectEqual(UnicodeMode.wincompose, getMode());
    cycleMode(true); // wincompose -> emacs
    try testing.expectEqual(UnicodeMode.emacs, getMode());
    cycleMode(true); // emacs -> macos (wrap)
    try testing.expectEqual(UnicodeMode.macos, getMode());
}

test "cycleMode backward" {
    reset();
    setMode(.macos);
    cycleMode(false); // macos -> emacs (wrap)
    try testing.expectEqual(UnicodeMode.emacs, getMode());
    cycleMode(false); // emacs -> wincompose
    try testing.expectEqual(UnicodeMode.wincompose, getMode());
}

test "hexToKeycode" {
    try testing.expectEqual(KC.@"0", hexToKeycode(0));
    try testing.expectEqual(KC.@"9", hexToKeycode(9));
    try testing.expectEqual(KC.A, hexToKeycode(0xA));
    try testing.expectEqual(KC.F, hexToKeycode(0xF));
}

test "isUnicode / unicodeGetCodePoint" {
    // Basic Unicode range
    try testing.expect(keycode_mod.isUnicode(0x8000));
    try testing.expect(keycode_mod.isUnicode(0xFFFF));
    try testing.expect(!keycode_mod.isUnicode(0x7FFF));
    try testing.expect(!keycode_mod.isUnicode(0x0000));

    // Code point extraction
    try testing.expectEqual(@as(u15, 0), keycode_mod.unicodeGetCodePoint(0x8000));
    try testing.expectEqual(@as(u15, 0x7FFF), keycode_mod.unicodeGetCodePoint(0xFFFF));
    try testing.expectEqual(@as(u15, 0x00E9), keycode_mod.unicodeGetCodePoint(keycode_mod.UC(0x00E9)));
}

test "UC() コンストラクタ" {
    try testing.expectEqual(@as(Keycode, 0x8000), keycode_mod.UC(0));
    try testing.expectEqual(@as(Keycode, 0x80E9), keycode_mod.UC(0x00E9)); // e with acute
    try testing.expectEqual(@as(Keycode, 0xFFFF), keycode_mod.UC(0x7FFF));
}

test "process: UC_NEXT でモードが前進する" {
    reset();
    setMode(.linux);
    try testing.expect(!process(keycode_mod.UC_NEXT, true)); // 消費
    try testing.expectEqual(UnicodeMode.windows, getMode());
}

test "process: UC_PREV でモードが後退する" {
    reset();
    setMode(.linux);
    try testing.expect(!process(keycode_mod.UC_PREV, true)); // 消費
    try testing.expectEqual(UnicodeMode.macos, getMode());
}

test "process: UC_NEXT release は無視される" {
    reset();
    setMode(.linux);
    try testing.expect(!process(keycode_mod.UC_NEXT, false)); // 消費（だがモードは変わらない）
    try testing.expectEqual(UnicodeMode.linux, getMode());
}

test "process: 通常キーコードは消費されない" {
    reset();
    try testing.expect(process(KC.A, true));
    try testing.expect(process(KC.SPACE, false));
    try testing.expect(process(0x7C16, true)); // Grave Escape
}

// ============================================================
// Unicode Map テスト
// ============================================================

test "unicodeMapGetCodePoint: テーブル設定前は null" {
    clearUnicodeMap();
    try testing.expectEqual(@as(?u32, null), unicodeMapGetCodePoint(0));
}

test "unicodeMapGetCodePoint: テーブルからコードポイントを取得" {
    const map = [_]u32{ 0x00E9, 0x1F600, 0x10FFFF };
    setUnicodeMap(&map);
    defer clearUnicodeMap();

    try testing.expectEqual(@as(?u32, 0x00E9), unicodeMapGetCodePoint(0));
    try testing.expectEqual(@as(?u32, 0x1F600), unicodeMapGetCodePoint(1));
    try testing.expectEqual(@as(?u32, 0x10FFFF), unicodeMapGetCodePoint(2));
}

test "unicodeMapGetCodePoint: 範囲外インデックスは null" {
    const map = [_]u32{0x00E9};
    setUnicodeMap(&map);
    defer clearUnicodeMap();

    try testing.expectEqual(@as(?u32, null), unicodeMapGetCodePoint(1));
    try testing.expectEqual(@as(?u32, null), unicodeMapGetCodePoint(100));
}

test "UM() / isUnicodeMap キーコード" {
    // UM(0) = 0x8000
    try testing.expectEqual(@as(Keycode, 0x8000), keycode_mod.UM(0));
    // UM(0x3FFF) = 0xBFFF
    try testing.expectEqual(@as(Keycode, 0xBFFF), keycode_mod.UM(0x3FFF));
    // 範囲チェック
    try testing.expect(keycode_mod.isUnicodeMap(0x8000));
    try testing.expect(keycode_mod.isUnicodeMap(0xBFFF));
    try testing.expect(!keycode_mod.isUnicodeMap(0xC000));
    try testing.expect(!keycode_mod.isUnicodeMap(0x7FFF));
}

test "UP() / isUnicodeMapPair キーコード" {
    // UP(0, 1) = 0xC000 | (0 << 7) | 1 = 0xC001
    try testing.expectEqual(@as(Keycode, 0xC001), keycode_mod.UP(0, 1));
    // 範囲チェック
    try testing.expect(keycode_mod.isUnicodeMapPair(0xC000));
    try testing.expect(keycode_mod.isUnicodeMapPair(0xFFFF));
    try testing.expect(!keycode_mod.isUnicodeMapPair(0xBFFF));
    try testing.expect(!keycode_mod.isUnicodeMapPair(0x7FFF));
}

// ============================================================
// UCIS テスト
// ============================================================

test "UCIS: 初期状態は非アクティブ" {
    reset();
    try testing.expect(!ucisIsActive());
    try testing.expectEqual(@as(u8, 0), ucisGetCount());
}

test "UCIS: ucisStart でアクティブになる" {
    reset();
    ucisStart();
    try testing.expect(ucisIsActive());
    try testing.expectEqual(@as(u8, 0), ucisGetCount());
}

test "UCIS: ucisAdd で文字が追加される" {
    reset();
    ucisStart();
    try testing.expect(ucisAdd(KC.A));
    try testing.expectEqual(@as(u8, 1), ucisGetCount());
    try testing.expect(ucisAdd(KC.B));
    try testing.expectEqual(@as(u8, 2), ucisGetCount());
}

test "UCIS: ucisAdd で数字が追加される" {
    reset();
    ucisStart();
    try testing.expect(ucisAdd(KC.@"1"));
    try testing.expect(ucisAdd(KC.@"0"));
    try testing.expectEqual(@as(u8, 2), ucisGetCount());
}

test "UCIS: ucisAdd で無効なキーコードは拒否される" {
    reset();
    ucisStart();
    try testing.expect(!ucisAdd(KC.SPACE));
    try testing.expect(!ucisAdd(KC.ENTER));
    try testing.expectEqual(@as(u8, 0), ucisGetCount());
}

test "UCIS: ucisRemoveLast で文字が削除される" {
    reset();
    ucisStart();
    _ = ucisAdd(KC.A);
    _ = ucisAdd(KC.B);
    try testing.expectEqual(@as(u8, 2), ucisGetCount());

    try testing.expect(ucisRemoveLast());
    try testing.expectEqual(@as(u8, 1), ucisGetCount());

    try testing.expect(ucisRemoveLast());
    try testing.expectEqual(@as(u8, 0), ucisGetCount());

    // 空の状態で削除は失敗
    try testing.expect(!ucisRemoveLast());
}

test "UCIS: ucisCancel で非アクティブになる" {
    reset();
    ucisStart();
    _ = ucisAdd(KC.A);
    ucisCancel();
    try testing.expect(!ucisIsActive());
}

test "UCIS: ucisFinish でテーブルなしは false" {
    reset();
    clearUcisSymbolTable();
    ucisStart();
    _ = ucisAdd(KC.A);
    try testing.expect(!ucisFinish());
    try testing.expect(!ucisIsActive());
}

test "UCIS: matchMnemonic 一致テスト" {
    reset();
    ucisStart();
    _ = ucisAdd(KC.A);
    _ = ucisAdd(KC.B);
    _ = ucisAdd(KC.C);

    try testing.expect(matchMnemonic("abc"));
    try testing.expect(!matchMnemonic("ab"));
    try testing.expect(!matchMnemonic("abcd"));
    try testing.expect(!matchMnemonic("abd"));
}

test "UCIS: keycodeToChar 変換" {
    try testing.expectEqual(@as(?u8, 'a'), keycodeToChar(KC.A));
    try testing.expectEqual(@as(?u8, 'z'), keycodeToChar(KC.Z));
    try testing.expectEqual(@as(?u8, '0'), keycodeToChar(KC.@"0"));
    try testing.expectEqual(@as(?u8, '1'), keycodeToChar(KC.@"1"));
    try testing.expectEqual(@as(?u8, '9'), keycodeToChar(KC.@"9"));
    try testing.expectEqual(@as(?u8, null), keycodeToChar(KC.SPACE));
}

// ============================================================
// UTF-8 デコードテスト
// ============================================================

test "decodeUtf8: ASCII" {
    const result = decodeUtf8("A");
    try testing.expectEqual(@as(?u32, 'A'), result.code_point);
    try testing.expectEqual(@as(usize, 1), result.bytes_consumed);
}

test "decodeUtf8: 2バイト文字" {
    // U+00E9 (e with acute) = 0xC3 0xA9
    const result = decodeUtf8("\xC3\xA9");
    try testing.expectEqual(@as(?u32, 0x00E9), result.code_point);
    try testing.expectEqual(@as(usize, 2), result.bytes_consumed);
}

test "decodeUtf8: 3バイト文字" {
    // U+3042 (hiragana a) = 0xE3 0x81 0x82
    const result = decodeUtf8("\xE3\x81\x82");
    try testing.expectEqual(@as(?u32, 0x3042), result.code_point);
    try testing.expectEqual(@as(usize, 3), result.bytes_consumed);
}

test "decodeUtf8: 4バイト文字" {
    // U+1F600 (grinning face) = 0xF0 0x9F 0x98 0x80
    const result = decodeUtf8("\xF0\x9F\x98\x80");
    try testing.expectEqual(@as(?u32, 0x1F600), result.code_point);
    try testing.expectEqual(@as(usize, 4), result.bytes_consumed);
}

test "decodeUtf8: 空バイト列" {
    const result = decodeUtf8("");
    try testing.expectEqual(@as(?u32, null), result.code_point);
    try testing.expectEqual(@as(usize, 0), result.bytes_consumed);
}

test "decodeUtf8: 不完全な2バイト文字" {
    const result = decodeUtf8("\xC3");
    try testing.expectEqual(@as(?u32, null), result.code_point);
    try testing.expectEqual(@as(usize, 1), result.bytes_consumed);
}
