// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! production runtime 専用の keymap グローバルストレージ
//!
//! このモジュールは **production binary でのみ使用される** keymap storage を
//! 提供する。 旧設計では `core/keyboard.zig` 内の `var test_keymap` が
//! production / test 兼用の役割を担っていたが、 production binary に
//! "test_" プレフィックス API が露出する関心混在を解消するため、
//! まず独立モジュールへ分離し (Issue #391)、 その後 PR #395 で test 経路と
//! resolver 経路からも切り離して production 専用化した。
//!
//! 参照元 (production のみ):
//!   - `src/main.zig` (production startup):
//!       `keymap_state.getKeymap().* = kb.default_keymap;` で起動時に keymap をロード
//!       し、 `productionKeymapLookup` 経由で `keyboard.setKeymapLookup` に注入する
//!   - `src/compat/qmk_abi.zig` (C ABI export):
//!       `keymap_key_to_keycode` ABI 関数が production storage を参照する
//!
//! 非参照 (依存性注入により切り離し済み):
//!   - `core/keyboard.zig` 本体およびそのテストはこのモジュールを参照しない。
//!     resolver は注入された `keyboard.keymap_lookup` 経由で keycode を引く。
//!   - test 用 keymap は `core/test_fixture.zig` の独立した `test_keymap`
//!     storage が保持し、 fixture 側で setKey / resetKeymap / 専用 lookup を
//!     提供する。 production storage と test storage は完全に分離されている。

const keymap_mod = @import("keymap.zig");

const Keymap = keymap_mod.Keymap;

/// 現在アクティブな keymap (BSS 配置、 初期値は emptyKeymap)
var current_keymap: Keymap = keymap_mod.emptyKeymap();

/// 現在アクティブな keymap への可変ポインタを返す
/// `inline` 指定は production binary に追加関数を export させない (LTO 不在環境でも
/// resolver からの呼び出しが直接アドレス参照に展開されるようにする) ため。
pub inline fn getKeymap() *Keymap {
    return &current_keymap;
}
