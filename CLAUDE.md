# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

QMK Firmware のカスタムキーボードファームウェアを C から Zig へ移行するプロジェクト。
upstream: https://github.com/qmk/qmk_firmware

- **一方向同期のみ**: upstream から取り込むことはあるが、upstream へ push しない
- 対象キーボード: madbd34（RP2040, 4x12スプリット, 38キー）

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

```bash
zig build                         # ビルド
zig build test                    # テスト実行
```

### QMK CLI

キーボードやキーマップの作成には必ず QMK CLI を使用する。`mkdir` や `touch` での手動作成は禁止。

```bash
qmk new-keyboard -kb <name> -u <username>
qmk new-keymap -kb <keyboard> -km <keymap>
```

参照: https://docs.qmk.fm/

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
│   ├── keycode.zig                # キーコード定義（HID Usage Table 準拠、u16）
│   ├── action_code.zig            # アクションコード（16bit packed union、C版 action_t 互換）
│   ├── event.zig                  # キーイベント・キーポジション構造体
│   ├── report.zig                 # USB HID レポート構造体（キーボード、マウス、Consumer）
│   ├── matrix.zig                 # COL2ROW マトリックススキャン
│   ├── debounce.zig               # 対称遅延キー単位デバウンス（sym_defer_pk）
│   ├── keymap.zig                 # キーマップデータ構造と comptime LAYOUT 関数
│   ├── layer.zig                  # レイヤー状態管理（ビットマスク、MO/TO/TG/DF 操作）
│   ├── action.zig                 # アクション解決・実行（基本キー、Mod-Tap、Layer-Tap）
│   ├── action_tapping.zig         # タップ/ホールド判定ステートマシン
│   ├── action_tapping_test.zig    # タッピングのユニットテスト
│   ├── host.zig                   # HostDriver インターフェース、レポート状態管理
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
├── drivers/                       # ドライバ（未実装）
└── keyboards/                     # キーボード定義（未実装）
```

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

主要テストファイル（upstream参照）:
- `tests/basic/test_keypress.cpp` - キープレス処理
- `tests/basic/test_action_layer.cpp` - レイヤー切替
- `tests/basic/test_tapping.cpp` - タップ/ホールド
- `tests/mousekeys/` - マウスキー

## Custom Keyboards

### madbd34

- プロセッサ: RP2040 (ARM Cortex-M0+)
- マトリックス: 4行 x 12列（COL2ROW）
- ピン: Cols GP8-13,GP18-22,GP26 / Rows GP14-17
- レイヤー: QWERTY, 数字/記号, ナビゲーション, ファンクション/メディア/マウス
- 設定: `keyboards/madbd34/keyboard.json`
- キーマップ: `keyboards/madbd34/keymaps/default/keymap.c`

## Git Branch Operation Rules

1. **masterへの直接コミット禁止**
2. **ブランチ必須**: `feat/`, `fix/`, `chore/`, `refactor/`, `update/` プレフィックス
3. **PR必須**: 直接マージ禁止、必ず GitHub PR を通す
4. **rebase禁止**: コンフリクト解決は `git merge` を使用
5. **PRテンプレート**: `.github/pull_request_template.md` に従う
6. **PRタイトル**: ブランチ名と同様のプレフィックスをつける（例: `feat: USB HIDドライバの実装`）

### レビュー依頼前の必須チェック

PR を push した後、レビューを依頼する（`@claude` メンション等）前に以下を必ず確認する:

1. **コンフリクトの確認**: `gh pr view <number> --json mergeable` でマージ可能か確認。コンフリクトがある場合はコンフリクト解決手順に従って解消してから依頼する
2. **CIの確認**: `gh pr checks <number>` で全CIチェックが通っていることを確認。失敗している場合は原因を修正してから依頼する

### レビューコメント対応

レビュー（`@claude` 自動レビュー、チームメンバーレビュー等）のコメントを受け取ったら:

1. **コメント確認**: `gh api repos/{owner}/{repo}/pulls/<number>/reviews` および `gh api repos/{owner}/{repo}/issues/<number>/comments` でレビューコメントを確認する
2. **指摘対応**: critical/suggestion レベルの指摘は修正する。nit レベルは任意だが対応が望ましい
3. **修正後の再確認**: 修正をコミット・プッシュした後、コンフリクトとCIを再確認してからレビュー再依頼する

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
