# QMK Firmware Zig

[QMK Firmware](https://github.com/qmk/qmk_firmware) のカスタムキーボードファームウェアを C から Zig へ移行するプロジェクト。

## 概要

このリポジトリは [qmk/qmk_firmware](https://github.com/qmk/qmk_firmware) のフォークをベースに、ファームウェアのコア部分を Zig で再実装することを目指しています。

### 対象キーボード

| キーボード | プロセッサ | 説明 |
|-----------|-----------|------|
| madbd34 | RP2040 | 4x12 スプリットキーボード（38キー、4レイヤー） |

### 移行方針

- RP2040 (ARM Cortex-M0+) をターゲットプラットフォームとする
- ChibiOS への依存を排除し、Zig で直接ハードウェアを制御する
- upstream のテストケースと論理的に等価なテストを Zig で実装する
- コンパイル時機能を活用し、C のマクロベース設計を型安全な設計に置き換える

## プロジェクト状況

移行は以下のフェーズで進行中です。詳細は [Issues](https://github.com/amkkr/qmk_firmware_zig/issues) を参照してください。

| フェーズ | 内容 | 状態 |
|---------|------|------|
| Foundation | ビルドシステム、コアデータ型、テストインフラ | 完了 |
| HAL | GPIO, Timer, EEPROM, Boot2, クロック初期化, USB HID | 完了 |
| Core | マトリックススキャン, デバウンス, キーマップ, レイヤー管理, アクション処理 | 完了 |
| Feature | Bootmagic, Mousekey, Extrakey | 進行中 |
| Keyboard | madbd34 キーボード定義、統合テスト | 未着手 |

### 実装済みモジュール

**Core** (`src/core/`)

| モジュール | ファイル | 説明 |
|-----------|---------|------|
| キーコード | `keycode.zig` | キーコード定義（HID Usage Table 準拠、u16） |
| アクションコード | `action_code.zig` | 16bit packed union によるアクション型定義 |
| イベント | `event.zig` | キーイベント・キーポジション構造体 |
| HIDレポート | `report.zig` | USB HID レポート構造体（キーボード、マウス、Consumer） |
| マトリックススキャン | `matrix.zig` | COL2ROW 方式のキーマトリックススキャン |
| デバウンス | `debounce.zig` | 対称遅延キー単位デバウンス（sym_defer_pk） |
| キーマップ | `keymap.zig` | キーマップデータ構造と comptime LAYOUT 関数 |
| レイヤー管理 | `layer.zig` | レイヤー状態ビットマスクとレイヤー操作 |
| アクション処理 | `action.zig` | アクション解決・実行の中核 |
| タッピング | `action_tapping.zig` | タップ/ホールド判定ステートマシン |
| ホストドライバ | `host.zig` | HID レポート送信インターフェース |
| テストドライバ | `test_driver.zig` | モック HID ドライバ（テスト用） |
| テストフィクスチャ | `test_fixture.zig` | キーボードシミュレーション環境（テスト用） |

**HAL** (`src/hal/`)

| モジュール | ファイル | 説明 |
|-----------|---------|------|
| GPIO | `gpio.zig` | RP2040 GPIO ドライバ（レジスタ直接アクセス / テスト時モック） |
| タイマー | `timer.zig` | RP2040 タイマー（ミリ秒精度 / テスト時モック） |
| EEPROM | `eeprom.zig` | RP2040 フラッシュによる EEPROM エミュレーション |
| USB | `usb.zig` | RP2040 USB デバイスドライバ（ChibiOS 不要） |
| USB ディスクリプタ | `usb_descriptors.zig` | USB/HID ディスクリプタ定義 |
| Boot2 | `boot2.zig` | RP2040 第2段ブートローダー（W25Q080 互換） |
| クロック | `clock.zig` | RP2040 クロックツリー初期化（XOSC, PLL, clk_sys） |
| ブートローダー | `bootloader.zig` | BOOTSEL モードへのジャンプ |
| ベクタテーブル | `vector_table.zig` | ARM Cortex-M0+ 割り込みベクタテーブル |

## ビルド

### 前提条件

- [Zig](https://ziglang.org/download/)（0.14.0 以降）
- 外部依存なし（`git clone` + `zig build` で即ビルド可能）

### Zig 版

```bash
# ファームウェアビルド（RP2040 クロスコンパイル）
zig build

# ユニットテスト実行（ホストネイティブ）
zig build test

# UF2 ファイル生成（フラッシュ書き込み用）
zig build uf2

# キーボード・キーマップの指定
zig build -Dkeyboard=madbd34 -Dkeymap=default

# リリースビルド
zig build -Doptimize=ReleaseSafe

# ビルドキャッシュの削除
rm -rf .zig-cache zig-out
```

### 既存 C 版

```bash
# madbd34 のデフォルトキーマップをビルド
make madbd34:default

# ビルド＋フラッシュ
make madbd34:default:flash
```

## upstream

- [QMK Firmware](https://github.com/qmk/qmk_firmware)
- [QMK ドキュメント](https://docs.qmk.fm)
