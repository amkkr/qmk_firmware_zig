# 動的 keymap (VIA / Vial / EEPROM 書き換え) 機能を再導入する場合の設計方針

## 背景

PR #407 (Issue #400) で `src/core/keymap_state.zig` を完全削除し、production binary
の keymap storage を `kb_mod.default_keymap` (flash 上の静的 const) に統一した。

これにより:

- production binary の `.bss` から `current_keymap: Keymap` (約 2.5 KB) が消え、RAM 使用量を削減
- production lookup が `keymap_key_to_keycode(&kb_mod.default_keymap, ...)` に直結し、間接化を 1 段排除
- production / test の storage 種別が「flash の static const」/「BSS の mutable storage」と明確に分離

代償として **runtime での keymap 書き換えは構造的に不可能** になった
(`kb_mod.default_keymap` は `pub const` で flash に配置され、書き換えできない)。

将来 VIA / Vial / EEPROM 書き換え等の動的 keymap 機能を追加する場合、mutable な BSS keymap
storage を再導入する必要がある。本ドキュメントはその設計方針を記録する。

### `git revert` で済まない理由

PR #407 以降、後続 PR (#419 等) が `keymap_state` 削除後の API (panic 化された
`defaultKeymapLookup`、`keyboard.init()` 内の `keymap_lookup` リセット契約)
に依存している。 単純な `git revert <PR #407>` では後続変更とコンフリクトし、
storage を機械的に戻すだけでは現行設計の整合性が崩れる。 そのため新規実装に近い
形で動的 keymap 経路を組み立てる必要があり、本ドキュメントはその設計方針を示す。

## 経緯となる PR (時系列)

| PR | 概要 |
|---|---|
| [#394] | `var test_keymap` を新モジュール `core/keymap_state.zig` (`current_keymap` + `getKeymap()`) に分離。 production / test 兼用の global storage |
| [#398] | 依存性注入により `core/keyboard.zig` から `keymap_state` 直接参照を排除。`KeymapLookupFn` (`fn (u5, u8, u8) Keycode`) と `setKeymapLookup` API を導入 |
| [#402] | `core/keyboard.zig` と `core/test_fixture.zig` に同名で存在していた `var test_keymap` の衝突を rename で解消 |
| [#404] | C ABI export `keymap_key_to_keycode` も `keyboard.keymapLookup` 経由に統一。同一 keymap データへのアクセス経路が 1 本化 |
| [#407] | `keymap_state.zig` 完全削除。`productionKeymapLookup` を `&kb_mod.default_keymap` 直参照に変更。**Issue #400 で本ドキュメントの起点となる「動的 keymap の予定なし」という前提に基づく決断** |
| [#419] | `defaultKeymapLookup` を panic 化し、`setKeymapLookup` 呼び忘れをサイレントバグ化させない (Issue #401) |

[#394]: https://github.com/amkkr/qmk_firmware_zig/pull/394
[#398]: https://github.com/amkkr/qmk_firmware_zig/pull/398
[#402]: https://github.com/amkkr/qmk_firmware_zig/pull/402
[#404]: https://github.com/amkkr/qmk_firmware_zig/pull/404
[#407]: https://github.com/amkkr/qmk_firmware_zig/pull/407
[#419]: https://github.com/amkkr/qmk_firmware_zig/pull/419

## 現状の keymap データフロー

PR #407 以降の現状:

```
[production binary]
  kb_mod.default_keymap (flash, pub const)
        ▲
        │ &kb_mod.default_keymap (直参照)
        │
  productionKeymapLookup (src/main.zig)
        ▲
        │ setKeymapLookup() で起動時注入
        │
  keyboard.keymap_lookup (var, KeymapLookupFn)
        ▲
        ├──────────── action.resolveKeycode 経由 (内部 lookup)
        └──────────── keymap_key_to_keycode (C ABI export)

[test binary]
  test_fixture.fixture_test_keymap (BSS, mutable)
        ▲
        │ fixtureKeymapLookup (test_fixture.zig)
        │
  keyboard.keymap_lookup (test setup で TestFixture が注入)
```

依存性注入 (`KeymapLookupFn`) は維持されているため、**lookup 関数を差し替えるだけで動的 keymap に対応できる構造は残されている**。

つまり「BSS 上の mutable storage と、それを引く lookup 関数」を再導入し、`productionKeymapLookup`
の差し替え + 起動時のロード処理を加えれば良い。

## 再導入時に必要な作業

### 1. mutable storage モジュールの再導入

`src/core/keymap_state.zig` に相当するモジュールを再作成する。最小実装は PR #407 で削除された
版と同等で良い (Issue #400 のコミット履歴参照)。

```zig
// src/core/keymap_state.zig
const keymap_mod = @import("keymap.zig");
const Keymap = keymap_mod.Keymap;

var current_keymap: Keymap = keymap_mod.emptyKeymap();

pub inline fn getKeymap() *Keymap {
    return &current_keymap;
}
```

**注意点**:

- `inline` 指定は呼び出し側で常にインライン展開させ、関数呼び出しコストを排除するため (LTO 不在環境でもインライン化させる意図)
- 動的 keymap で書き込み API を露出する場合は `setKey` / `loadFromEeprom` 等のメソッドを追加
- VIA / Vial 連携時は EEPROM 書き換え後に `current_keymap` を再ロードする必要がある (キャッシュ整合性)

### 2. `core/core.zig` で再 export

```zig
// src/core/core.zig
pub const keymap_state = @import("keymap_state.zig");
```

### 3. `src/main.zig` の `productionKeymapLookup` を BSS 経由に戻す

```zig
// src/main.zig (startup ブロック内)
const keymap_state = @import("core").keymap_state;

fn productionKeymapLookup(l: u5, row: u8, col: u8) Keycode {
    return keymap_mod.keymapKeyToKeycode(keymap_state.getKeymap(), l, row, col);
}
```

### 4. startup での初期ロード処理を再追加

```zig
// src/main.zig main() 内、 keyboard.init() の後
keyboard.init();
keymap_state.getKeymap().* = kb_mod.default_keymap;  // flash → BSS への初期コピー
keyboard.setKeymapLookup(productionKeymapLookup);
action_mod.setActionResolver(keyboard.keymapActionResolver);
```

EEPROM 書き換え機能を追加する場合、初期ロードの前後で:

- EEPROM に有効な keymap が保存されていればそれを優先ロード
- なければ `kb_mod.default_keymap` をフォールバックとしてロード
- ユーザー書き込み時は EEPROM へ永続化 + `current_keymap` も同時更新

の流れになる。

### 5. C ABI export (`compat/qmk_abi.zig`) は変更不要

現状 `keymap_key_to_keycode` は `keyboard_mod.keymapLookup` 経由で注入済み lookup を呼ぶため、
production lookup を BSS 経由に差し替えるだけで自動的に追従する (PR #404 の DRY 統一の効果)。

### 6. `keyboard.init()` の lookup リセット契約 (PR #419)

PR #419 (Issue #401) で `keyboard.init()` は内部で `keymap_lookup = defaultKeymapLookup` に
リセットする契約に統一されている。**起動 / リセット後は必ず `setKeymapLookup` を再呼び出しする**
契約を維持すること (動的 keymap 機能で reload を行う場合も同様)。

## 参考: 削除された keymap_state.zig (PR #407 時点)

PR #407 の削除コミット `220ec49e` の **parent** で全文確認可能 (削除コミット本体では
ファイル自体が消えているため `^` で 1 つ前を参照する):

```bash
git show 220ec49e^:src/core/keymap_state.zig
# 等価: git show 99babb51^:src/core/keymap_state.zig
```

## 関連 Issue

- [#400] keymap_state を完全削除して default_keymap 直参照化 (本ドキュメントの起点)
- [#403] `KeymapLookupFn` の signature を維持する判断 (Won't Do として close)
- [#406] ABI export の signature を `(layer, KeyPos)` 値渡しに変更
- [#408] 本ドキュメント作成

[#400]: https://github.com/amkkr/qmk_firmware_zig/issues/400
[#403]: https://github.com/amkkr/qmk_firmware_zig/issues/403
[#406]: https://github.com/amkkr/qmk_firmware_zig/issues/406
[#408]: https://github.com/amkkr/qmk_firmware_zig/issues/408
