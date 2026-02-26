//! Dynamic Macros - キーボード上でのマクロ録音・再生機能
//! Based on quantum/process_keycode/process_dynamic_macro.c
//!
//! 使い方:
//! - DM_REC1 / DM_REC2: マクロ1/2の録音開始
//! - DM_RSTP: 録音停止
//! - DM_PLY1 / DM_PLY2: マクロ1/2の再生
//!
//! 再生はコールバック方式で行う。再生されたキーコードを受け取る関数を
//! setPlayCallback() で登録する。

const std = @import("std");
const keycode_mod = @import("keycode.zig");
const Keycode = keycode_mod.Keycode;
const KC = keycode_mod.KC;

// ============================================================
// 設定
// ============================================================

/// 1マクロあたりの最大記録キー数
pub const DYNAMIC_MACRO_SIZE: usize = 32;

// ============================================================
// マクロ状態
// ============================================================

/// マクロの録音状態
pub const MacroState = enum {
    /// 録音していない（待機中）
    idle,
    /// マクロ1を録音中
    recording1,
    /// マクロ2を録音中
    recording2,
};

// ============================================================
// モジュール状態
// ============================================================

var state: MacroState = .idle;
var macro1: [DYNAMIC_MACRO_SIZE]Keycode = undefined;
var macro2: [DYNAMIC_MACRO_SIZE]Keycode = undefined;
var macro1_len: usize = 0;
var macro2_len: usize = 0;

/// 再生コールバック: 再生されたキーコードを受け取る関数
/// pressed=true でキー押下、pressed=false でキー解放
var play_callback: ?*const fn (kc: Keycode, pressed: bool) void = null;

// ============================================================
// パブリックAPI
// ============================================================

/// 再生コールバックを登録する
pub fn setPlayCallback(cb: *const fn (kc: Keycode, pressed: bool) void) void {
    play_callback = cb;
}

/// 再生コールバックを解除する
pub fn clearPlayCallback() void {
    play_callback = null;
}

/// 現在のマクロ状態を取得する
pub fn getState() MacroState {
    return state;
}

/// マクロ1の長さを取得する
pub fn getMacro1Len() usize {
    return macro1_len;
}

/// マクロ2の長さを取得する
pub fn getMacro2Len() usize {
    return macro2_len;
}

/// 状態をリセットする（テスト用）
pub fn reset() void {
    state = .idle;
    macro1_len = 0;
    macro2_len = 0;
}

/// キーコードを処理する
///
/// - DM_REC1/DM_REC2: 録音開始
/// - DM_RSTP: 録音停止
/// - DM_PLY1/DM_PLY2: 再生
/// - 録音中: 通常キーをバッファに追加
///
/// 返り値が true の場合はこのキーコードを消費済み（通常処理をスキップする）
pub fn process(kc: Keycode, pressed: bool) bool {
    if (!pressed) {
        // DM系キーはキー離し時には何もしない
        if (kc == keycode_mod.DM_REC1 or kc == keycode_mod.DM_REC2 or
            kc == keycode_mod.DM_RSTP or kc == keycode_mod.DM_PLY1 or kc == keycode_mod.DM_PLY2)
        {
            return true;
        }
        // 録音中は離しイベントも記録しない（シンプルな実装）
        return false;
    }

    switch (kc) {
        keycode_mod.DM_REC1 => {
            state = .recording1;
            macro1_len = 0;
            return true;
        },
        keycode_mod.DM_REC2 => {
            state = .recording2;
            macro2_len = 0;
            return true;
        },
        keycode_mod.DM_RSTP => {
            state = .idle;
            return true;
        },
        keycode_mod.DM_PLY1 => {
            playMacro(macro1[0..macro1_len]);
            return true;
        },
        keycode_mod.DM_PLY2 => {
            playMacro(macro2[0..macro2_len]);
            return true;
        },
        else => {},
    }

    // 録音中は通常キーをバッファに追加
    switch (state) {
        .recording1 => {
            if (macro1_len < DYNAMIC_MACRO_SIZE) {
                macro1[macro1_len] = kc;
                macro1_len += 1;
            }
            // バッファに記録したが通常処理は続ける（false を返す）
            return false;
        },
        .recording2 => {
            if (macro2_len < DYNAMIC_MACRO_SIZE) {
                macro2[macro2_len] = kc;
                macro2_len += 1;
            }
            return false;
        },
        .idle => return false,
    }
}

/// マクロを再生する（コールバック経由）
fn playMacro(buf: []const Keycode) void {
    if (play_callback) |cb| {
        for (buf) |kc| {
            cb(kc, true);
            cb(kc, false);
        }
    }
}

// ============================================================
// テスト
// ============================================================

const testing = std.testing;

test "dynamic_macro: 初期状態は idle" {
    reset();
    try testing.expectEqual(MacroState.idle, getState());
    try testing.expectEqual(@as(usize, 0), getMacro1Len());
    try testing.expectEqual(@as(usize, 0), getMacro2Len());
}

test "dynamic_macro: DM_REC1 で録音開始" {
    reset();

    const consumed = process(keycode_mod.DM_REC1, true);
    try testing.expect(consumed);
    try testing.expectEqual(MacroState.recording1, getState());
}

test "dynamic_macro: DM_REC2 で録音開始" {
    reset();

    const consumed = process(keycode_mod.DM_REC2, true);
    try testing.expect(consumed);
    try testing.expectEqual(MacroState.recording2, getState());
}

test "dynamic_macro: DM_RSTP で録音停止" {
    reset();

    _ = process(keycode_mod.DM_REC1, true);
    try testing.expectEqual(MacroState.recording1, getState());

    const consumed = process(keycode_mod.DM_RSTP, true);
    try testing.expect(consumed);
    try testing.expectEqual(MacroState.idle, getState());
}

test "dynamic_macro: 録音中にキーが記録される" {
    reset();

    _ = process(keycode_mod.DM_REC1, true);
    _ = process(KC.A, true);
    _ = process(KC.B, true);
    _ = process(KC.C, true);
    _ = process(keycode_mod.DM_RSTP, true);

    try testing.expectEqual(@as(usize, 3), getMacro1Len());
    try testing.expectEqual(MacroState.idle, getState());
}

test "dynamic_macro: マクロ1の録音と再生" {
    reset();

    // 再生されたキーコードを記録するコールバック
    const S = struct {
        var played: [DYNAMIC_MACRO_SIZE]Keycode = undefined;
        var played_count: usize = 0;

        fn cb(kc: Keycode, pressed: bool) void {
            if (pressed) {
                played[played_count] = kc;
                played_count += 1;
            }
        }
    };
    S.played_count = 0;
    setPlayCallback(S.cb);
    defer clearPlayCallback();

    // 録音: A, B
    _ = process(keycode_mod.DM_REC1, true);
    _ = process(KC.A, true);
    _ = process(KC.B, true);
    _ = process(keycode_mod.DM_RSTP, true);

    // 再生
    const consumed = process(keycode_mod.DM_PLY1, true);
    try testing.expect(consumed);
    try testing.expectEqual(@as(usize, 2), S.played_count);
    try testing.expectEqual(KC.A, S.played[0]);
    try testing.expectEqual(KC.B, S.played[1]);
}

test "dynamic_macro: マクロ2の録音と再生" {
    reset();

    const S = struct {
        var played: [DYNAMIC_MACRO_SIZE]Keycode = undefined;
        var played_count: usize = 0;

        fn cb(kc: Keycode, pressed: bool) void {
            if (pressed) {
                played[played_count] = kc;
                played_count += 1;
            }
        }
    };
    S.played_count = 0;
    setPlayCallback(S.cb);
    defer clearPlayCallback();

    // マクロ2に録音: C, D
    _ = process(keycode_mod.DM_REC2, true);
    _ = process(KC.C, true);
    _ = process(KC.D, true);
    _ = process(keycode_mod.DM_RSTP, true);

    // マクロ2再生
    _ = process(keycode_mod.DM_PLY2, true);
    try testing.expectEqual(@as(usize, 2), S.played_count);
    try testing.expectEqual(KC.C, S.played[0]);
    try testing.expectEqual(KC.D, S.played[1]);
}

test "dynamic_macro: バッファサイズ上限を超えても安全" {
    reset();

    _ = process(keycode_mod.DM_REC1, true);
    // DYNAMIC_MACRO_SIZE + 5 個のキーを録音しようとする
    for (0..DYNAMIC_MACRO_SIZE + 5) |_| {
        _ = process(KC.A, true);
    }
    _ = process(keycode_mod.DM_RSTP, true);

    // 上限を超えた分は無視される
    try testing.expectEqual(DYNAMIC_MACRO_SIZE, getMacro1Len());
}

test "dynamic_macro: DM_REC1録音中に別マクロ(DM_REC2)を開始すると切り替わる" {
    reset();

    _ = process(keycode_mod.DM_REC1, true);
    try testing.expectEqual(MacroState.recording1, getState());

    _ = process(KC.A, true);

    // マクロ2の録音開始
    _ = process(keycode_mod.DM_REC2, true);
    try testing.expectEqual(MacroState.recording2, getState());
    // マクロ1は1つ録音されたまま
    try testing.expectEqual(@as(usize, 1), getMacro1Len());

    _ = process(keycode_mod.DM_RSTP, true);
}

test "dynamic_macro: コールバック未設定でも再生はパニックしない" {
    reset();
    clearPlayCallback();

    _ = process(keycode_mod.DM_REC1, true);
    _ = process(KC.A, true);
    _ = process(keycode_mod.DM_RSTP, true);

    // コールバックなしで再生しても問題ない
    const consumed = process(keycode_mod.DM_PLY1, true);
    try testing.expect(consumed);
}

test "dynamic_macro: DM系キーのキー離しイベントは消費される" {
    reset();

    // DM_REC1のキー離し
    const consumed1 = process(keycode_mod.DM_REC1, false);
    try testing.expect(consumed1);

    const consumed2 = process(keycode_mod.DM_PLY1, false);
    try testing.expect(consumed2);

    const consumed3 = process(keycode_mod.DM_RSTP, false);
    try testing.expect(consumed3);
}

test "dynamic_macro: 通常キーのキー離しは消費されない" {
    reset();

    const consumed = process(KC.A, false);
    try testing.expect(!consumed);
}
