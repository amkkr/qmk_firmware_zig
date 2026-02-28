# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

QMK Firmware のカスタムキーボードファームウェアを C から Zig へ移行するプロジェクト。
upstream: <https://github.com/qmk/qmk_firmware>

- **一方向同期のみ**: upstream から取り込むことはあるが、upstream へ push しない
- 対象キーボード: madbd5（デフォルト、RP2040, 5x16, 60キー）、madbd34（RP2040, 4x12スプリット, 38キー）

## Communication Rules

**日本語で対応すること。** コード変更の説明、実装方針の議論、PRの説明文すべて日本語。

## Build Commands

### C版（既存）

```bash
make madbd34:default              # ビルド
make madbd34:default:flash        # ビルド＋フラッシュ
make test:all                     # Cユニットテスト実行
qmk lint -kb madbd34              # キーボード定義のlint
```

### Zig版（移行中）

Zig バージョン: **0.15.2**

```bash
zig build                         # ファームウェアビルド（RP2040 クロスコンパイル）
zig build test                    # 全テスト実行（ホストネイティブ）
zig build verify                  # CI用: テスト + ファームウェアコンパイル検証
zig build uf2                     # UF2 形式に変換
zig build flash                   # UF2 ビルド → RP2040 BOOTSEL ドライブへコピー
```

ビルドオプション:

```bash
zig build -Dkeyboard=madbd5       # 対象キーボード（デフォルト: madbd5）
zig build -Dkeymap=default        # 対象キーマップ（デフォルト: default）
zig build -Dboot2=path/to/boot2.bin  # 第2段ブートローダーバイナリ（実機書き込み時に必要）
```

### QMK CLI

キーボードやキーマップの作成には必ず QMK CLI を使用する。`mkdir` や `touch` での手動作成は禁止。

```bash
qmk new-keyboard -kb <name> -u <username>
qmk new-keymap -kb <keyboard> -km <keymap>
```

参照: <https://docs.qmk.fm/>

## Architecture

### C版（upstream由来）

処理フロー: マトリックススキャン → デバウンス → キーイベント生成 → アクション解決 → アクション実行 → HIDレポート送信

- `quantum/keyboard.c` - メインループ (`keyboard_init()`, `keyboard_task()`)
- `quantum/action.c` - アクション処理の中核（約44KB、最大のファイル）
- `quantum/action_tapping.c` - タップ/ホールド判定ステートマシン
- `quantum/action_layer.c` - レイヤー管理
- `quantum/matrix.c` - マトリックススキャン
- `quantum/keycode.h` - キーコード定義
- `quantum/action_code.h` - アクションコード（16bit packed union）
- `tmk_core/protocol/host.c` - ホストドライバインターフェース
- `tmk_core/protocol/report.h` - HIDレポート構造体
- `platforms/chibios/` - RP2040向けプラットフォーム実装（ChibiOS RTOS）
- `tests/` - googletest ベースのユニットテスト（ホストネイティブ実行）

### Zig版（移行先）

処理フロー（C版と同等）: マトリックススキャン → デバウンス → キーイベント生成 → アクション解決 → タッピング判定 → アクション実行 → HIDレポート送信

```
src/
├── main.zig                       # エントリポイント（RP2040スタートアップ含む）
├── core/                          # コアロジック
│   ├── core.zig                   # モジュール再エクスポート
│   │
│   │  # --- データ型定義 ---
│   ├── keycode.zig                # キーコード定義（HID Usage Table 準拠、u16）
│   ├── action_code.zig            # アクションコード（16bit packed union、C版 action_t 互換）
│   ├── event.zig                  # キーイベント・キーポジション構造体
│   ├── report.zig                 # USB HID レポート構造体（キーボード、マウス、Consumer）
│   │
│   │  # --- コア処理パイプライン ---
│   ├── keyboard.zig               # メインループ（keyboard_init / keyboard_task）
│   ├── matrix.zig                 # COL2ROW マトリックススキャン
│   ├── debounce.zig               # 対称遅延キー単位デバウンス（sym_defer_pk）
│   ├── keymap.zig                 # キーマップデータ構造と comptime LAYOUT 関数
│   ├── layer.zig                  # レイヤー状態管理（ビットマスク、MO/TO/TG/DF 操作）
│   ├── action.zig                 # アクション解決・実行（基本キー、Mod-Tap、Layer-Tap）
│   ├── action_tapping.zig         # タップ/ホールド判定ステートマシン
│   ├── host.zig                   # HostDriver インターフェース、レポート状態管理
│   ├── extrakey.zig               # メディアキー・システムコントロール（Consumer / System）
│   │
│   │  # --- 設定・永続化 ---
│   ├── eeconfig.zig               # EEPROM 設定 API（KeymapConfig 永続化）
│   ├── bootmagic.zig              # Bootmagic Lite（起動時キー押下で EEPROM リセット＋ブートローダー）
│   ├── magic.zig                  # Magic Keycodes（ランタイムで Ctrl/Caps スワップ等を EEPROM に永続化）
│   │
│   │  # --- 機能モジュール ---
│   ├── auto_shift.zig             # Auto Shift（長押しで自動 Shift 適用）
│   ├── autocorrect.zig            # Autocorrect（トライ木辞書によるタイプミス自動修正）
│   ├── caps_word.zig              # Caps Word（英字キーに自動 Shift、非英字で自動解除）
│   ├── combo.zig                  # Combo キー（複数キー同時押しで別キーコード発動）
│   ├── dynamic_macro.zig          # Dynamic Macros（キーボード上でのマクロ録音・再生）
│   ├── grave_esc.zig              # Grave Escape（Shift/GUI 時は Grave、それ以外は Escape）
│   ├── key_lock.zig               # Key Lock（次に押したキーを押しっぱなしにロック）
│   ├── key_override.zig           # Key Override（修飾キー＋キーの組み合わせを別キーに上書き）
│   ├── layer_lock.zig             # Layer Lock（MO レイヤーをロックして維持）
│   ├── leader.zig                 # Leader Key（キーシーケンスでアクション発動）
│   ├── mousekey.zig               # Mousekey（キーボードによるマウスカーソル・ボタン・スクロール操作）
│   ├── repeat_key.zig             # Repeat Key（直前に押したキーを再送信）
│   ├── secure.zig                 # Secure（仮想パドロック、タイムアウト自動ロック＋キーシーケンスアンロック）
│   ├── space_cadet.zig            # Space Cadet（Shift/Ctrl/Alt タップで括弧文字入力）
│   ├── swap_hands.zig             # Swap Hands（左右の手の入れ替え）
│   ├── tap_dance.zig              # Tap Dance（同一キー連続タップ回数で異なるアクション）
│   ├── tri_layer.zig              # Tri Layer（Lower＋Upper 同時有効で Adjust レイヤー自動有効化）
│   │
│   │  # --- テストインフラ ---
│   ├── action_tapping_test.zig    # タッピングのユニットテスト
│   ├── test_driver.zig            # モック HID ドライバ（テスト用）
│   └── test_fixture.zig           # キーボードシミュレーション環境（テスト用）
├── hal/                           # ハードウェア抽象化層（RP2040）
│   ├── hal.zig                    # モジュール再エクスポート
│   ├── gpio.zig                   # GPIO ドライバ（レジスタ直接アクセス / テスト時モック）
│   ├── timer.zig                  # タイマー（ミリ秒精度 / テスト時モック）
│   ├── eeprom.zig                 # フラッシュベース EEPROM エミュレーション
│   ├── usb.zig                    # USB デバイスドライバ（RP2040 USB ペリフェラル直接制御）
│   ├── usb_descriptors.zig        # USB/HID ディスクリプタ定義
│   ├── boot2.zig                  # 第2段ブートローダー（W25Q080 互換、XIP 設定）
│   ├── clock.zig                  # クロックツリー初期化（XOSC→PLL→125MHz/48MHz）
│   ├── bootloader.zig             # BOOTSEL モードジャンプ（Watchdog リセット）
│   └── vector_table.zig           # ARM Cortex-M0+ 割り込みベクタテーブル
├── tests/                         # 移植済み C 版テスト（upstream tests/ と論理的等価）
│   ├── integration_test.zig       # End-to-End パイプライン検証
│   ├── test_keypress.zig          # キープレス処理テスト
│   ├── test_action_layer.zig      # レイヤー切替テスト
│   ├── test_tapping.zig           # タップ/ホールドテスト
│   ├── test_oneshot.zig           # ワンショットテスト
│   ├── test_mousekey.zig          # マウスキーテスト
│   ├── test_tap_hold_config.zig   # タップホールド設定テスト
│   └── test_secure.zig            # セキュアモードテスト
├── compat/                        # C ABI 互換性検証
│   ├── qmk_abi.zig                # C版との構造体レイアウト互換チェック
│   └── abi_test.zig               # ABI テスト
├── drivers/                       # ドライバ（未実装）
└── keyboards/                     # キーボード定義（build_options.KEYBOARD で comptime 選択）
    ├── madbd34.zig                # madbd34 キーボード定義（4x12 スプリット、RP2040）
    └── madbd5.zig                 # madbd5 キーボード定義（5x16、60キー、RP2040）
```

補足:

- `tools/uf2gen.zig` — ELF→UF2 変換ツール
- `tools/flash.zig` — RP2040 BOOTSEL ドライブへの書き込みツール

設計方針:

- 各 HAL モジュールは `builtin.os.tag == .freestanding` で実機/テストを切り替え
- テスト時はモック実装が自動的に使用され、ホストネイティブで `zig build test` 実行可能

### 移行上の重要ポイント

- **マクロ → comptime**: C の `#define LAYOUT(...)` や `ACTION()` マクロを Zig のコンパイル時関数に置き換え
- **weak シンボル → インターフェース**: `__attribute__((weak))` パターンを Zig のコンパイル時ポリモーフィズムに再設計
- **`#ifdef` → ビルドオプション**: 機能フラグを Zig の `build.zig` オプションに移行
- **packed union**: `action_t` のビットフィールドを Zig の packed struct/union で表現
- **ChibiOS 排除**: RTOS依存を排除し、RP2040レジスタに直接アクセス

## Testing

テストは upstream の `tests/` にある googletest テストケースと論理的に等価になるよう設計する。

```bash
# C版テスト（回帰テスト用）
make test:all
make test:basic         # 基本テストのみ

# Zig版テスト
zig build test
```

### Zig テスト構造

- テストのエントリポイントは `src/main.zig` の `test` ブロック
- `@import("std").testing.refAllDecls()` で `core`、`hal`、`keyboards` の全テストを自動収集
- `src/tests/` の各ファイルも `main.zig` から明示的に `@import` される
- テスト用フィクスチャ: `src/core/test_fixture.zig`（`TestFixture` 構造体でキーボードシミュレーション）
- テスト用モックドライバ: `src/core/test_driver.zig`（HID レポート捕捉用）
- 新しいテストファイルを追加する場合は、`src/main.zig` の test ブロックに `@import` を追加すること

### upstream テスト対応表

| upstream (C/googletest) | Zig版 |
|---|---|
| `tests/basic/test_keypress.cpp` | `src/tests/test_keypress.zig` |
| `tests/basic/test_action_layer.cpp` | `src/tests/test_action_layer.zig` |
| `tests/basic/test_tapping.cpp` | `src/tests/test_tapping.zig` |
| `tests/mousekeys/` | `src/tests/test_mousekey.zig` |

## Custom Keyboards

### madbd5（デフォルト）

- プロセッサ: RP2040 (ARM Cortex-M0+)
- マトリックス: 5行 x 16列（COL2ROW）、60キー
- ピン: Cols GP5-GP7,GP9-GP20 / Rows GP21-GP22,GP26-GP28
- レイヤー: QWERTY+numpad, 数字/記号, ナビゲーション, ファンクション/メディア/マウス, ゲーミングベース, ゲーミング記号, ゲーミングFn/Nav（7レイヤー）
- 設定: `keyboards/madbd5/keyboard.json`
- キーマップ: `keyboards/madbd5/keymaps/default/keymap.c`
- Zig定義: `src/keyboards/madbd5.zig`

### madbd34

- プロセッサ: RP2040 (ARM Cortex-M0+)
- マトリックス: 4行 x 12列（COL2ROW）、38キー
- ピン: Cols GP8-13,GP18-22,GP26 / Rows GP14-17
- レイヤー: QWERTY, 数字/記号, ナビゲーション, ファンクション/メディア/マウス（4レイヤー）
- 設定: `keyboards/madbd34/keyboard.json`
- キーマップ: `keyboards/madbd34/keymaps/default/keymap.c`
- Zig定義: `src/keyboards/madbd34.zig`

## Git Branch Operation Rules

1. **masterへの直接コミット禁止**
2. **ブランチ必須**: `feat/`, `fix/`, `chore/`, `refactor/`, `update/` プレフィックス
3. **PR必須**: 直接マージ禁止、必ず GitHub PR を通す
4. **rebase禁止**: コンフリクト解決は `git merge` を使用
5. **PRテンプレート**: `.github/pull_request_template.md` に従う
6. **PRタイトル**: ブランチ名と同様のプレフィックスをつける（例: `feat: USB HIDドライバの実装`）
7. **レビュー依頼**: PR作成後またはPRにコミットをpushした後は、PRに `@claude` メンションのみのコメントでレビューを依頼すること
8. **レビュー依頼前の確認**: レビュー依頼の前に以下を確認すること
    1. masterブランチとコンフリクトが発生していないこと
    2. CIが通っていること（GitHub Actionsのステータスを確認）

### コンフリクト解決手順

```bash
git checkout master
git pull origin master
git checkout <branch>
git merge master
# コンフリクト解決後
git add <files>
git commit
git push origin <branch>
```
