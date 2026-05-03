// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! 現在アクティブな keymap のグローバルストレージ
//!
//! production / test のいずれにおいても「keyboard.task() / 各 resolver が
//! 参照する keymap 」 はこのモジュールが保持する。 旧設計では
//! `core/keyboard.zig` 内の `var test_keymap` がこの役割を担っていたが、
//! production binary に "test_" プレフィックス API が露出する関心混在を
//! 解消するため独立モジュールへ分離した (Issue #391)。
//!
//! 用途別の主な利用箇所:
//!   - production startup (`src/main.zig`):
//!       `getKeymap().* = kb.default_keymap;` で keymap をロード
//!   - test (`src/core/test_fixture.zig`, 兄弟テスト):
//!       `getKeymap().* = ...;` または `setKey()` で人工キーマップを構築
//!   - resolver (`src/core/keyboard.zig` の keymapActionResolver / resolveKeycode):
//!       `getKeymap()` 経由で keycode を引く

const keymap_mod = @import("keymap.zig");
const keycode_mod = @import("keycode.zig");

const Keymap = keymap_mod.Keymap;
const Keycode = keycode_mod.Keycode;

/// 現在アクティブな keymap (BSS 配置、 初期値は emptyKeymap)
var current_keymap: Keymap = keymap_mod.emptyKeymap();

/// 現在アクティブな keymap への可変ポインタを返す
/// `inline` 指定は production binary に追加関数を export させない (LTO 不在環境でも
/// resolver からの呼び出しが直接アドレス参照に展開されるようにする) ため。
pub inline fn getKeymap() *Keymap {
    return &current_keymap;
}

/// 1 キーをセットする (範囲外は no-op)
pub fn setKey(l: u5, row: u8, col: u8, kc: Keycode) void {
    if (row < keymap_mod.MATRIX_ROWS and col < keymap_mod.MATRIX_COLS and l < keymap_mod.MAX_LAYERS) {
        current_keymap[l][row][col] = kc;
    }
}

/// keymap を空 (KC_NO 全埋め) にリセットする
pub fn reset() void {
    current_keymap = keymap_mod.emptyKeymap();
}
