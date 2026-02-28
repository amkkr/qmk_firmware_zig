//! Unicode 入力処理
//! C版 quantum/process_keycode/process_unicode.c, process_unicode_common.c に相当
//!
//! OS別のUnicode入力方式を管理し、Basic Unicode キーコード（0x8000-0xFFFF）を
//! OS固有のキーシーケンスに変換して送信する。
//!
//! 入力フロー:
//!   1. unicodeInputStart(): OS別の開始シーケンスを送信
//!   2. registerHex(): コードポイントを16進数で一桁ずつ入力
//!   3. unicodeInputFinish(): OS別の終了シーケンスを送信
//!
//! 将来対応: Unicode Map (32bit コードポイント), UCIS

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

/// 現在の Unicode 入力モード
var unicode_mode: UnicodeMode = .linux;

/// Unicode 入力中に保存する修飾キー状態
var saved_mods: u8 = 0;

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

    // Basic Unicode (0x8000-0xFFFF)
    if (keycode_mod.isUnicode(kc)) {
        if (pressed) {
            const code_point = keycode_mod.unicodeGetCodePoint(kc);
            unicodeInputStart();
            registerHex(@as(u32, code_point));
            unicodeInputFinish();
        }
        return false;
    }

    // それ以外は通常処理に回す
    return true;
}

/// OS別の Unicode 入力開始シーケンスを送信する
fn unicodeInputStart() void {
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
fn unicodeInputFinish() void {
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

/// コードポイントを16進数で入力する（上位の0は省略）
fn registerHex(code_point: u32) void {
    // 最大桁数を決定（上位0を省略するため、最上位の非0桁から開始）
    // コードポイント 0 の場合は "0" を入力する
    var started = false;

    // 15bit なので最大 0x7FFF (4桁)
    var shift: u5 = 12;
    while (true) : (shift -= 4) {
        const digit: u4 = @truncate((code_point >> shift) & 0xF);
        if (digit != 0 or started or shift == 0) {
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
