//! Autocorrect 機能
//! C版 quantum/process_keycode/process_autocorrect.c に相当
//!
//! よくあるタイプミスを自動的に修正する機能。
//! 辞書データ（トライ木形式）に基づいてキー入力を監視し、
//! タイプミスを検出したらバックスペース＋正しい文字列を自動送信する。
//!
//! C版との差異:
//! - process_autocorrect_user() (weak 関数): 省略。Zig ではコンパイル時テーブルや
//!   インターフェースで同等のカスタマイズが可能。
//! - apply_autocorrect() (weak 関数): 省略。同上。
//! - EEPROM 永続化: 本実装では keymap_config のメモリ内状態のみ管理。
//! - tap_count: keyboard.zig からは常に 1 を渡す。タッピング処理前に呼ばれるため
//!   正確な tap_count が利用できないアーキテクチャ上の制約による。

const host = @import("host.zig");
const keycode_mod = @import("keycode.zig");
const keymap_mod = @import("keymap.zig");
const report_mod = @import("report.zig");
const Keycode = keycode_mod.Keycode;
const KC = keycode_mod.KC;

/// デフォルト辞書データ（C版 autocorrect_data_default.h から移植）
/// トライ木形式でエンコードされたタイプミス辞書。
const default_autocorrect_data = [_]u8{
    108, 43,  0,   6,   71,  0,   7,   81,  0,   8,   199, 0,   9,   240, 1,   10,  250, 1,   11,  26,  2,   17,  53,  2,   18,  190, 2,   19,  202, 2,   21,  212, 2,   22,  20,  3,   23,  67,  3,   28,  16,  4,   0,   72,  50,  0,   22,  60,  0,   0,   11,  23,  44,  8,   11,  23,  44,  0,   132, 0,   8,   22,  18,  18,  15,  0,   132, 115, 101, 115, 0,   11,  23,  12,  26,  22,  0,   129, 99,  104, 0,   68,  94,  0,   8,   106, 0,   15,  174, 0,   21,  187, 0,   0,   12,  15,  25,  17,  12,  0,   131, 97,  108, 105, 100, 0,   74,  119, 0,   12,  129, 0,   21,  140, 0,   24,  165, 0,   0,   17,  12,  22,  0,   131, 103, 110, 101, 100, 0,   25,  21,  8,   7,   0,   131, 105, 118, 101, 100, 0,   72,  147, 0,   24,  156, 0,   0,   9,   8,   21,  0,   129, 114, 101, 100, 0,   6,   6,   18,  0,   129, 114, 101, 100, 0,   15,  6,   17,  12,  0,   129, 100, 101, 0,   18,  22,  8,   21,  11,  23,  0,   130, 104, 111,
    108, 100, 0,   4,   26,  18,  9,   0,   131, 114, 119, 97,  114, 100, 0,   68,  233, 0,   6,   246, 0,   7,   4,   1,   8,   16,  1,   10,  52,  1,   15,  81,  1,   21,  90,  1,   22,  117, 1,   23,  144, 1,   24,  215, 1,   25,  228, 1,   0,   6,   19,  22,  8,   16,  4,   17,  0,   130, 97,  99,  101, 0,   19,  4,   22,  8,   16,  4,   17,  0,   131, 112, 97,  99,  101, 0,   12,  21,  8,   25,  18,  0,   130, 114, 105, 100, 101, 0,   23,  0,   68,  25,  1,   17,  36,  1,   0,   21,  4,   24,  10,  0,   130, 110, 116, 101, 101, 0,   4,   21,  24,  4,   10,  0,   135, 117, 97,  114, 97,  110, 116, 101, 101, 0,   68,  59,  1,   7,   69,  1,   0,   24,  10,  44,  0,   131, 97,  117, 103, 101, 0,   8,   15,  12,  25,  12,  21,  19,  0,   130, 103, 101, 0,   22,  4,   9,   0,   130, 108, 115, 101, 0,   76,  97,  1,   24,  109, 1,   0,   24,  20,  4,   0,   132, 99,  113, 117, 105, 114, 101, 0,   23,  44,  0,
    130, 114, 117, 101, 0,   4,   0,   79,  126, 1,   24,  134, 1,   0,   9,   0,   131, 97,  108, 115, 101, 0,   6,   8,   5,   0,   131, 97,  117, 115, 101, 0,   4,   0,   71,  156, 1,   19,  193, 1,   21,  203, 1,   0,   18,  16,  0,   80,  166, 1,   18,  181, 1,   0,   18,  6,   4,   0,   135, 99,  111, 109, 109, 111, 100, 97,  116, 101, 0,   6,   6,   4,   0,   132, 109, 111, 100, 97,  116, 101, 0,   7,   24,  0,   132, 112, 100, 97,  116, 101, 0,   8,   19,  8,   22,  0,   132, 97,  114, 97,  116, 101, 0,   10,  8,   15,  15,  18,  6,   0,   130, 97,  103, 117, 101, 0,   8,   12,  6,   8,   21,  0,   131, 101, 105, 118, 101, 0,   12,  8,   11,  6,   0,   130, 105, 101, 102, 0,   17,  0,   76,  3,   2,   21,  16,  2,   0,   15,  8,   12,  6,   0,   133, 101, 105, 108, 105, 110, 103, 0,   12,  23,  22,  0,   131, 114, 105, 110, 103, 0,   70,  33,  2,   23,  44,  2,   0,   12,  23,  26,  22,  0,   131, 105,
    116, 99,  104, 0,   10,  12,  8,   11,  0,   129, 104, 116, 0,   72,  69,  2,   10,  80,  2,   18,  89,  2,   21,  156, 2,   24,  167, 2,   0,   22,  18,  18,  11,  6,   0,   131, 115, 101, 110, 0,   12,  21,  23,  22,  0,   129, 110, 103, 0,   12,  0,   86,  98,  2,   23,  124, 2,   0,   68,  105, 2,   22,  114, 2,   0,   12,  15,  0,   131, 105, 115, 111, 110, 0,   4,   6,   6,   18,  0,   131, 105, 111, 110, 0,   76,  131, 2,   22,  146, 2,   0,   23,  12,  19,  8,   21,  0,   134, 101, 116, 105, 116, 105, 111, 110, 0,   18,  19,  0,   131, 105, 116, 105, 111, 110, 0,   23,  24,  8,   21,  0,   131, 116, 117, 114, 110, 0,   85,  174, 2,   23,  183, 2,   0,   23,  8,   21,  0,   130, 117, 114, 110, 0,   8,   21,  0,   128, 114, 110, 0,   7,   8,   24,  22,  19,  0,   131, 101, 117, 100, 111, 0,   24,  18,  18,  15,  0,   129, 107, 117, 112, 0,   72,  219, 2,   18,  3,   3,   0,   76,  229, 2,   15,  238,
    2,   17,  248, 2,   0,   11,  23,  44,  0,   130, 101, 105, 114, 0,   23,  12,  9,   0,   131, 108, 116, 101, 114, 0,   23,  22,  12,  15,  0,   130, 101, 110, 101, 114, 0,   23,  4,   21,  8,   23,  17,  12,  0,   135, 116, 101, 114, 97,  116, 111, 114, 0,   72,  30,  3,   17,  38,  3,   24,  51,  3,   0,   15,  4,   9,   0,   129, 115, 101, 0,   4,   12,  23,  17,  18,  6,   0,   131, 97,  105, 110, 115, 0,   22,  17,  8,   6,   17,  18,  6,   0,   133, 115, 101, 110, 115, 117, 115, 0,   74,  86,  3,   11,  96,  3,   15,  118, 3,   17,  129, 3,   22,  218, 3,   24,  232, 3,   0,   11,  24,  4,   6,   0,   130, 103, 104, 116, 0,   71,  103, 3,   10,  110, 3,   0,   12,  26,  0,   129, 116, 104, 0,   17,  8,   15,  0,   129, 116, 104, 0,   22,  24,  8,   21,  0,   131, 115, 117, 108, 116, 0,   68,  139, 3,   8,   150, 3,   22,  210, 3,   0,   21,  4,   19,  19,  4,   0,   130, 101, 110, 116, 0,   85,  157,
    3,   25,  200, 3,   0,   68,  164, 3,   21,  175, 3,   0,   19,  4,   0,   132, 112, 97,  114, 101, 110, 116, 0,   4,   19,  0,   68,  185, 3,   19,  193, 3,   0,   133, 112, 97,  114, 101, 110, 116, 0,   4,   0,   131, 101, 110, 116, 0,   8,   15,  8,   21,  0,   130, 97,  110, 116, 0,   18,  6,   0,   130, 110, 115, 116, 0,   12,  9,   8,   17,  4,   16,  0,   132, 105, 102, 101, 115, 116, 0,   83,  239, 3,   23,  6,   4,   0,   87,  246, 3,   24,  254, 3,   0,   17,  12,  0,   131, 112, 117, 116, 0,   18,  0,   130, 116, 112, 117, 116, 0,   19,  24,  18,  0,   131, 116, 112, 117, 116, 0,   70,  29,  4,   8,   41,  4,   11,  51,  4,   21,  69,  4,   0,   8,   24,  20,  8,   21,  9,   0,   129, 110, 99,  121, 0,   23,  9,   4,   22,  0,   130, 101, 116, 121, 0,   6,   21,  4,   21,  12,  8,   11,  0,   135, 105, 101, 114, 97,  114, 99,  104, 121, 0,   4,   5,   12,  15,  0,   130, 114, 97,  114, 121, 0,
};

const AUTOCORRECT_MIN_LENGTH: u8 = 5;
const AUTOCORRECT_MAX_LENGTH: u8 = 10;

/// MOD_MASK_SHIFT: 左Shift | 右Shift (HID 8ビット)
const MOD_MASK_SHIFT: u8 = report_mod.ModBit.LSHIFT | report_mod.ModBit.RSHIFT;

// ============================================================
// 状態変数
// ============================================================

var typo_buffer: [AUTOCORRECT_MAX_LENGTH]u8 = .{KC.SPC} ++ .{0} ** (AUTOCORRECT_MAX_LENGTH - 1);
var typo_buffer_size: u8 = 1;

/// 辞書データへのポインタ（カスタム辞書に差し替え可能）
var autocorrect_data: []const u8 = &default_autocorrect_data;

// ============================================================
// 有効/無効管理
// ============================================================

pub fn isEnabled() bool {
    return keymap_mod.keymap_config.autocorrect_enable;
}

pub fn enable() void {
    keymap_mod.keymap_config.autocorrect_enable = true;
}

pub fn disable() void {
    keymap_mod.keymap_config.autocorrect_enable = false;
    typo_buffer_size = 0;
}

pub fn toggle() void {
    keymap_mod.keymap_config.autocorrect_enable = !keymap_mod.keymap_config.autocorrect_enable;
    typo_buffer_size = 0;
}

// ============================================================
// キーコードフィルタリング
// C版 process_autocorrect_default_handler() に相当
// ============================================================

/// キーコードがオートコレクトの処理対象かどうかを判定し、
/// 必要に応じてキーコードを基本キーコードに変換する。
/// 戻り値: .skip = このキーはオートコレクト対象外, .process = 処理続行（keycode が変換済み）
const FilterResult = union(enum) {
    skip,
    process: struct { keycode: Keycode, mods: u8 },
};

fn filterKeycode(kc: Keycode, mods_in: u8, tap_count: u8) FilterResult {
    var result_kc = kc;
    var mods = mods_in;

    // レイヤー操作・修飾キー（Shift除く）・One-Shot系は除外
    if (result_kc == KC.LEFT_SHIFT or result_kc == KC.RIGHT_SHIFT or result_kc == KC.CAPS_LOCK) {
        return .skip;
    }

    // QK_TO〜QK_LAYER_TAP_TOGGLE_MAX (レイヤー/モッド操作): 除外
    // C版: QK_TO, QK_MOMENTARY, QK_DEF_LAYER, QK_TOGGLE_LAYER,
    //       QK_ONE_SHOT_LAYER, QK_ONE_SHOT_MOD, QK_LAYER_TAP_TOGGLE
    if (result_kc >= keycode_mod.QK_TO and result_kc <= keycode_mod.QK_LAYER_TAP_TOGGLE_MAX) {
        return .skip;
    }

    // QK_LAYER_MOD: 除外
    if (result_kc >= keycode_mod.QK_LAYER_MOD and result_kc <= keycode_mod.QK_LAYER_MOD_MAX) {
        return .skip;
    }

    // Shifted keycodes (QK_LSFT..QK_LSFT+255, QK_RSFT..QK_RSFT+255)
    const QK_LSFT: Keycode = 0x0200;
    const QK_RSFT: Keycode = 0x1200;
    if (result_kc >= QK_LSFT and result_kc <= QK_LSFT + 255) {
        mods |= report_mod.ModBit.LSHIFT;
        result_kc = result_kc & 0x00FF;
        return .{ .process = .{ .keycode = result_kc, .mods = mods } };
    }
    if (result_kc >= QK_RSFT and result_kc <= QK_RSFT + 255) {
        mods |= report_mod.ModBit.RSHIFT;
        result_kc = result_kc & 0x00FF;
        return .{ .process = .{ .keycode = result_kc, .mods = mods } };
    }

    // Layer-Tap: ホールド（tap_count==0）は除外、タップ時は基本キーコードを抽出
    if (result_kc >= keycode_mod.QK_LAYER_TAP and result_kc <= keycode_mod.QK_LAYER_TAP_MAX) {
        if (tap_count == 0) return .skip;
        result_kc = result_kc & 0x00FF;
        return .{ .process = .{ .keycode = result_kc, .mods = mods } };
    }

    // Mod-Tap: ホールド（tap_count==0）は除外、タップ時は基本キーコードを抽出
    if (result_kc >= keycode_mod.QK_MOD_TAP and result_kc <= keycode_mod.QK_MOD_TAP_MAX) {
        if (tap_count == 0) return .skip;
        result_kc = result_kc & 0x00FF;
        return .{ .process = .{ .keycode = result_kc, .mods = mods } };
    }

    // Swap Hands: 特殊操作キー（SH_TG, SH_ON 等）またはホールドは除外、
    // タップ時は基本キーコードを抽出。C版 QK_SWAP_HANDS ... QK_SWAP_HANDS_MAX に相当。
    if (result_kc >= keycode_mod.QK_SWAP_HANDS and result_kc <= keycode_mod.QK_SWAP_HANDS_MAX) {
        if (keycode_mod.isSwapHandsSpecialKey(result_kc) or tap_count == 0) {
            return .skip;
        }
        result_kc = result_kc & 0x00FF;
        return .{ .process = .{ .keycode = result_kc, .mods = mods } };
    }

    // Shift 以外のモッドがアクティブなら処理しない
    if ((mods & ~MOD_MASK_SHIFT) != 0) {
        typo_buffer_size = 0;
        return .skip;
    }

    return .{ .process = .{ .keycode = result_kc, .mods = mods } };
}

// ============================================================
// メイン処理
// C版 process_autocorrect() に相当
// ============================================================

/// Autocorrect のキー処理。keyboard.zig のパイプラインから呼ばれる。
/// keycode: 解決済みキーコード
/// pressed: キーが押下されたか
/// tap_count: タップカウント（Mod-Tap/Layer-Tap 用、通常キーは 0 以外で良い）
/// 戻り値: true = 通常処理続行, false = キーを消費（修正を自動送信済み）
pub fn process(kc: Keycode, pressed: bool, tap_count: u8) bool {
    var mods = host.getMods() | host.getOneshotMods();

    // Autocorrect ON/OFF/Toggle キーコード処理
    if (kc >= keycode_mod.AC_ON and kc <= keycode_mod.AC_TOGG) {
        if (pressed) {
            if (kc == keycode_mod.AC_ON) {
                enable();
            } else if (kc == keycode_mod.AC_OFF) {
                disable();
            } else if (kc == keycode_mod.AC_TOGG) {
                toggle();
            }
            return false;
        }
        return true;
    }

    if (!keymap_mod.keymap_config.autocorrect_enable) {
        typo_buffer_size = 0;
        return true;
    }

    // リリースイベントは無視
    if (!pressed) {
        return true;
    }

    // キーコードフィルタリング
    const filter = filterKeycode(kc, mods, tap_count);
    switch (filter) {
        .skip => return true,
        .process => |p| {
            mods = p.mods;
            return processFiltered(p.keycode, mods);
        },
    }
}

/// フィルタ済みキーコードでの Autocorrect 処理
fn processFiltered(kc_in: Keycode, mods: u8) bool {
    var kc = kc_in;

    // キーコード分類
    if (kc >= KC.A and kc <= KC.Z) {
        // アルファベット: そのまま処理
    } else if ((kc >= KC.@"1" and kc <= KC.@"0") or
        (kc >= KC.TAB and kc <= KC.SEMICOLON) or
        (kc >= KC.GRAVE and kc <= KC.SLASH))
    {
        // 数字、タブ〜セミコロン、グレーブ〜スラッシュ: ワード境界
        kc = KC.SPC;
    } else if (kc == KC.ENTER) {
        // Enter: バッファリセット + ワード境界
        typo_buffer_size = 0;
        kc = KC.SPC;
    } else if (kc == KC.BACKSPACE) {
        // バックスペース: バッファから最後の文字を削除
        if (typo_buffer_size > 0) {
            typo_buffer_size -= 1;
        }
        return true;
    } else if (kc == KC.QUOTE) {
        // クォート: Shift 押下時はワード境界（ダブルクォート）
        if ((mods & MOD_MASK_SHIFT) != 0) {
            kc = KC.SPC;
        }
    } else {
        // その他: バッファクリア
        typo_buffer_size = 0;
        return true;
    }

    // バッファがフルの場合、最古の文字をローテーション
    if (typo_buffer_size >= AUTOCORRECT_MAX_LENGTH) {
        var i: u8 = 0;
        while (i < AUTOCORRECT_MAX_LENGTH - 1) : (i += 1) {
            typo_buffer[i] = typo_buffer[i + 1];
        }
        typo_buffer_size = AUTOCORRECT_MAX_LENGTH - 1;
    }

    // キーコードをバッファに追加
    typo_buffer[typo_buffer_size] = @truncate(kc);
    typo_buffer_size += 1;

    // 最短ワード長未満ならスキップ
    if (typo_buffer_size < AUTOCORRECT_MIN_LENGTH) {
        return true;
    }

    // トライ木検索
    return searchTrie();
}

/// トライ木でタイプミスを検索し、修正を適用する。
/// C版のトライ木検索ロジック（process_autocorrect の後半部分）を移植。
fn searchTrie() bool {
    var state: u16 = 0;
    var code: u8 = autocorrect_data[state];

    var i: i16 = @as(i16, typo_buffer_size) - 1;
    while (i >= 0) : (i -= 1) {
        const key_i = typo_buffer[@intCast(i)];

        if (code & 64 != 0) {
            // 複数子ノード: 一致するキーを線形探索
            code &= 63;
            while (code != key_i) {
                if (code == 0) return true;
                state += 3;
                if (state >= autocorrect_data.len) return true;
                code = autocorrect_data[state];
            }
            // 子ノードへのリンクを取得
            if (state + 2 >= autocorrect_data.len) return true;
            state = @as(u16, autocorrect_data[state + 1]) | (@as(u16, autocorrect_data[state + 2]) << 8);
        } else if (code != key_i) {
            // 単一子ノード: 不一致
            return true;
        } else {
            // 単一子ノード: 一致
            state += 1;
            if (state >= autocorrect_data.len) return true;
            code = autocorrect_data[state];
            if (code == 0) {
                state += 1;
            }
        }

        // 範囲チェック
        if (state >= autocorrect_data.len) {
            return true;
        }

        code = autocorrect_data[state];

        if (code & 128 != 0) {
            // タイプミス検出! 修正を適用
            const backspaces: u8 = code & 63;
            const changes_start = state + 1;

            applyCorrection(backspaces, changes_start);

            if (typo_buffer_size > 0 and typo_buffer[typo_buffer_size - 1] == KC.SPC) {
                typo_buffer[0] = KC.SPC;
                typo_buffer_size = 1;
                return true;
            } else {
                typo_buffer_size = 0;
                return false;
            }
        }
    }
    return true;
}

/// 修正を適用: バックスペースを送信してから正しい文字列を送信する
/// C版の tap_code(KC_BSPC) + send_string_P(str) に相当
fn applyCorrection(backspaces: u8, changes_start: u16) void {
    // バックスペースを送信
    var bs: u8 = 0;
    while (bs < backspaces) : (bs += 1) {
        tapCode(KC.BACKSPACE);
    }

    // 修正文字列を送信
    var pos = changes_start;
    while (pos < autocorrect_data.len) : (pos += 1) {
        const ch = autocorrect_data[pos];
        if (ch == 0) break;
        sendChar(ch);
    }
}

/// 1キーをタップ（press + report + release + report）
/// C版 tap_code() に相当
fn tapCode(kc: u8) void {
    host.registerCode(kc);
    host.sendKeyboardReport();
    host.unregisterCode(kc);
    host.sendKeyboardReport();
}

/// ASCII 文字を対応するキーコードのタップとして送信
/// C版 send_string_P() に相当（1文字ずつ）
fn sendChar(ch: u8) void {
    // ASCII → HID キーコード + Shift 変換
    const result = asciiToKeycode(ch);
    if (result.keycode == 0) return;

    if (result.needs_shift) {
        host.addWeakMods(report_mod.ModBit.LSHIFT);
    }
    tapCode(result.keycode);
    if (result.needs_shift) {
        host.delWeakMods(report_mod.ModBit.LSHIFT);
    }
}

const AsciiKeycodeResult = struct {
    keycode: u8,
    needs_shift: bool,
};

/// ASCII 文字から HID キーコードへの変換
/// C版 send_string.c のルックアップテーブルに相当
fn asciiToKeycode(ch: u8) AsciiKeycodeResult {
    return switch (ch) {
        'a'...'z' => .{ .keycode = ch - 'a' + @as(u8, KC.A), .needs_shift = false },
        'A'...'Z' => .{ .keycode = ch - 'A' + @as(u8, KC.A), .needs_shift = true },
        '1'...'9' => .{ .keycode = ch - '1' + @as(u8, KC.@"1"), .needs_shift = false },
        '0' => .{ .keycode = @as(u8, KC.@"0"), .needs_shift = false },
        ' ' => .{ .keycode = @as(u8, KC.SPC), .needs_shift = false },
        '-' => .{ .keycode = @as(u8, KC.MINUS), .needs_shift = false },
        '=' => .{ .keycode = @as(u8, KC.EQUAL), .needs_shift = false },
        '[' => .{ .keycode = @as(u8, KC.LEFT_BRACKET), .needs_shift = false },
        ']' => .{ .keycode = @as(u8, KC.RIGHT_BRACKET), .needs_shift = false },
        '\\' => .{ .keycode = @as(u8, KC.BACKSLASH), .needs_shift = false },
        ';' => .{ .keycode = @as(u8, KC.SEMICOLON), .needs_shift = false },
        '\'' => .{ .keycode = @as(u8, KC.QUOTE), .needs_shift = false },
        '`' => .{ .keycode = @as(u8, KC.GRAVE), .needs_shift = false },
        ',' => .{ .keycode = @as(u8, KC.COMMA), .needs_shift = false },
        '.' => .{ .keycode = @as(u8, KC.DOT), .needs_shift = false },
        '/' => .{ .keycode = @as(u8, KC.SLASH), .needs_shift = false },
        '!' => .{ .keycode = @as(u8, KC.@"1"), .needs_shift = true },
        '@' => .{ .keycode = @as(u8, KC.@"2"), .needs_shift = true },
        '#' => .{ .keycode = @as(u8, KC.@"3"), .needs_shift = true },
        '$' => .{ .keycode = @as(u8, KC.@"4"), .needs_shift = true },
        '%' => .{ .keycode = @as(u8, KC.@"5"), .needs_shift = true },
        '^' => .{ .keycode = @as(u8, KC.@"6"), .needs_shift = true },
        '&' => .{ .keycode = @as(u8, KC.@"7"), .needs_shift = true },
        '*' => .{ .keycode = @as(u8, KC.@"8"), .needs_shift = true },
        '(' => .{ .keycode = @as(u8, KC.@"9"), .needs_shift = true },
        ')' => .{ .keycode = @as(u8, KC.@"0"), .needs_shift = true },
        '_' => .{ .keycode = @as(u8, KC.MINUS), .needs_shift = true },
        '+' => .{ .keycode = @as(u8, KC.EQUAL), .needs_shift = true },
        '{' => .{ .keycode = @as(u8, KC.LEFT_BRACKET), .needs_shift = true },
        '}' => .{ .keycode = @as(u8, KC.RIGHT_BRACKET), .needs_shift = true },
        '|' => .{ .keycode = @as(u8, KC.BACKSLASH), .needs_shift = true },
        ':' => .{ .keycode = @as(u8, KC.SEMICOLON), .needs_shift = true },
        '"' => .{ .keycode = @as(u8, KC.QUOTE), .needs_shift = true },
        '~' => .{ .keycode = @as(u8, KC.GRAVE), .needs_shift = true },
        '<' => .{ .keycode = @as(u8, KC.COMMA), .needs_shift = true },
        '>' => .{ .keycode = @as(u8, KC.DOT), .needs_shift = true },
        '?' => .{ .keycode = @as(u8, KC.SLASH), .needs_shift = true },
        '\t' => .{ .keycode = @as(u8, KC.TAB), .needs_shift = false },
        '\n' => .{ .keycode = @as(u8, KC.ENTER), .needs_shift = false },
        else => .{ .keycode = 0, .needs_shift = false },
    };
}

// ============================================================
// リセット / カスタム辞書設定
// ============================================================

pub fn reset() void {
    typo_buffer = .{KC.SPC} ++ .{0} ** (AUTOCORRECT_MAX_LENGTH - 1);
    typo_buffer_size = 1;
    autocorrect_data = &default_autocorrect_data;
}

/// カスタム辞書データを設定する（テスト用）
pub fn setDictionary(data: []const u8) void {
    autocorrect_data = data;
}

// ============================================================
// テスト
// ============================================================

const std = @import("std");
const testing = std.testing;
const FixedTestDriver = @import("test_driver.zig").FixedTestDriver;
const TestMockDriver = FixedTestDriver(128, 16);

fn setupTest() *TestMockDriver {
    const mock = struct {
        var driver: TestMockDriver = .{};
    };
    mock.driver = .{};
    host.hostReset();
    host.setDriver(host.HostDriver.from(&mock.driver));
    keymap_mod.keymap_config = .{};
    reset();
    enable();
    return &mock.driver;
}

fn teardownTest() void {
    host.clearDriver();
}

/// テスト用: キーをタップ（press + release）
fn tapKey(kc: Keycode) bool {
    const press_result = process(kc, true, 1);
    _ = process(kc, false, 1);
    return press_result;
}

test "有効/無効/トグル" {
    _ = setupTest();
    defer teardownTest();

    try testing.expect(isEnabled());

    disable();
    try testing.expect(!isEnabled());
    disable();
    try testing.expect(!isEnabled());

    enable();
    try testing.expect(isEnabled());
    enable();
    try testing.expect(isEnabled());

    toggle();
    try testing.expect(!isEnabled());
    toggle();
    try testing.expect(isEnabled());
}

test "AC_ON/AC_OFF/AC_TOGG キーコードで有効/無効切替" {
    _ = setupTest();
    defer teardownTest();

    try testing.expect(isEnabled());

    // AC_OFF で無効化
    _ = process(keycode_mod.AC_OFF, true, 0);
    try testing.expect(!isEnabled());

    // AC_ON で有効化
    _ = process(keycode_mod.AC_ON, true, 0);
    try testing.expect(isEnabled());

    // AC_TOGG でトグル
    _ = process(keycode_mod.AC_TOGG, true, 0);
    try testing.expect(!isEnabled());
    _ = process(keycode_mod.AC_TOGG, true, 0);
    try testing.expect(isEnabled());
}

test "fales → false 自動修正" {
    const mock = setupTest();
    defer teardownTest();

    // "fales" をタイプ → 自動修正で backspace + "se" が送信される
    _ = tapKey(KC.F);
    _ = tapKey(KC.A);
    _ = tapKey(KC.L);
    _ = tapKey(KC.E);
    const result = tapKey(KC.S);

    // 最後のキー "s" は消費される（false を返す）
    try testing.expect(!result);

    // レポートが送信されたはず
    try testing.expect(mock.keyboard_count > 0);

    // バックスペースが含まれているか確認
    var found_bspc = false;
    for (0..@min(mock.keyboard_count, 128)) |i| {
        if (mock.keyboard_reports[i].hasKey(KC.BACKSPACE)) {
            found_bspc = true;
            break;
        }
    }
    try testing.expect(found_bspc);
}

test "無効時は自動修正されない" {
    const mock = setupTest();
    defer teardownTest();

    disable();
    const initial_count = mock.keyboard_count;

    _ = tapKey(KC.F);
    _ = tapKey(KC.A);
    _ = tapKey(KC.L);
    _ = tapKey(KC.E);
    const result = tapKey(KC.S);

    // 無効時は全てのキーが通過（true を返す）
    try testing.expect(result);

    // バックスペースが送信されていないこと
    var found_bspc = false;
    for (initial_count..@min(mock.keyboard_count, 128)) |i| {
        if (mock.keyboard_reports[i].hasKey(KC.BACKSPACE)) {
            found_bspc = true;
            break;
        }
    }
    try testing.expect(!found_bspc);
}

test "falsify は自動修正されない" {
    _ = setupTest();
    defer teardownTest();

    // "falsify" は辞書に登録されていないので修正されない
    try testing.expect(tapKey(KC.F));
    try testing.expect(tapKey(KC.A));
    try testing.expect(tapKey(KC.L));
    try testing.expect(tapKey(KC.S));
    try testing.expect(tapKey(KC.I));
    try testing.expect(tapKey(KC.F));
    try testing.expect(tapKey(KC.Y));
}

test "ture → true 自動修正（ワード境界あり）" {
    const mock = setupTest();
    defer teardownTest();

    // ":ture" はワード境界（スペース）を含むパターン
    // バッファ初期状態で KC_SPC が入っている
    _ = tapKey(KC.T);
    _ = tapKey(KC.U);
    _ = tapKey(KC.R);
    _ = tapKey(KC.E);

    // 修正が発動したか確認: バックスペースが含まれているはず
    var found_bspc = false;
    for (0..@min(mock.keyboard_count, 128)) |i| {
        if (mock.keyboard_reports[i].hasKey(KC.BACKSPACE)) {
            found_bspc = true;
            break;
        }
    }
    try testing.expect(found_bspc);
}

test "overture は自動修正されない" {
    const mock = setupTest();
    defer teardownTest();

    // "overture" は "ture" を含むが、ワード境界がないので修正されない
    _ = tapKey(KC.O);
    _ = tapKey(KC.V);
    _ = tapKey(KC.E);
    _ = tapKey(KC.R);
    _ = tapKey(KC.T);
    _ = tapKey(KC.U);
    _ = tapKey(KC.R);
    _ = tapKey(KC.E);

    // バックスペースが送信されていないこと
    var found_bspc = false;
    for (0..@min(mock.keyboard_count, 128)) |i| {
        if (mock.keyboard_reports[i].hasKey(KC.BACKSPACE)) {
            found_bspc = true;
            break;
        }
    }
    try testing.expect(!found_bspc);
}

test "バックスペースでバッファから文字を削除" {
    _ = setupTest();
    defer teardownTest();

    _ = tapKey(KC.F);
    _ = tapKey(KC.A);
    _ = tapKey(KC.L);

    // バックスペースでバッファから 'l' を削除
    _ = tapKey(KC.BACKSPACE);

    // 修正パターン "fales" にならないよう 'x', 's' をタイプ
    _ = tapKey(KC.X);
    try testing.expect(tapKey(KC.S));
}

test "Enter キーでバッファリセット" {
    _ = setupTest();
    defer teardownTest();

    _ = tapKey(KC.F);
    _ = tapKey(KC.A);
    _ = tapKey(KC.L);

    // Enter でバッファリセット
    _ = tapKey(KC.ENTER);

    // "es" をタイプしても修正されない
    try testing.expect(tapKey(KC.E));
    try testing.expect(tapKey(KC.S));
}

test "Shift 以外のモッドでバッファクリア" {
    _ = setupTest();
    defer teardownTest();

    _ = tapKey(KC.F);
    _ = tapKey(KC.A);

    // Ctrl を追加
    host.addMods(report_mod.ModBit.LCTRL);

    // Ctrl がアクティブな間はバッファクリア
    _ = tapKey(KC.L);

    host.delMods(report_mod.ModBit.LCTRL);

    // バッファがクリアされたので "es" をタイプしても修正されない
    try testing.expect(tapKey(KC.E));
    try testing.expect(tapKey(KC.S));
}

test "asciiToKeycode 基本変換" {
    const a = asciiToKeycode('a');
    try testing.expectEqual(KC.A, @as(Keycode, a.keycode));
    try testing.expect(!a.needs_shift);

    const z = asciiToKeycode('z');
    try testing.expectEqual(KC.Z, @as(Keycode, z.keycode));
    try testing.expect(!z.needs_shift);

    const big_a = asciiToKeycode('A');
    try testing.expectEqual(KC.A, @as(Keycode, big_a.keycode));
    try testing.expect(big_a.needs_shift);

    const one = asciiToKeycode('1');
    try testing.expectEqual(KC.@"1", @as(Keycode, one.keycode));
    try testing.expect(!one.needs_shift);

    const excl = asciiToKeycode('!');
    try testing.expectEqual(KC.@"1", @as(Keycode, excl.keycode));
    try testing.expect(excl.needs_shift);
}

test "リリースイベントは常に true" {
    _ = setupTest();
    defer teardownTest();

    try testing.expect(process(KC.A, false, 1));
    try testing.expect(process(KC.S, false, 1));
}

test "filterKeycode: Layer-Tap ホールドは除外" {
    const lt_a = keycode_mod.LT(1, KC.A);
    // tap_count == 0 はホールド → skip
    const result = filterKeycode(lt_a, 0, 0);
    switch (result) {
        .skip => {},
        .process => try testing.expect(false),
    }
}

test "filterKeycode: Mod-Tap タップは基本キーコード抽出" {
    const mt_a = keycode_mod.MT(keycode_mod.Mod.LCTL, KC.A);
    // tap_count > 0 はタップ → 基本キーコード
    const result = filterKeycode(mt_a, 0, 1);
    switch (result) {
        .skip => try testing.expect(false),
        .process => |p| try testing.expectEqual(KC.A, p.keycode),
    }
}

test {
    _ = @import("autocorrect.zig");
}
