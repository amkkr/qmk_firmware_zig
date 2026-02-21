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
| Foundation | ビルドシステム、コアデータ型、テストインフラ | 未着手 |
| HAL | GPIO, Timer, EEPROM, マトリックススキャン, USB HID | 未着手 |
| Core | キーマップシステム、レイヤー管理、アクション処理 | 未着手 |
| Feature | Bootmagic, Mousekey, Extrakey | 未着手 |
| Keyboard | madbd34 キーボード定義、統合テスト | 未着手 |

## ビルド（既存 C 版）

```bash
# madbd34 のデフォルトキーマップをビルド
make madbd34:default

# ビルド＋フラッシュ
make madbd34:default:flash
```

## upstream

- [QMK Firmware](https://github.com/qmk/qmk_firmware)
- [QMK ドキュメント](https://docs.qmk.fm)

## ライセンス

[GPL-2.0-or-later](LICENSE)
