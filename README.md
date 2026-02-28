# QMK Firmware Zig

[QMK Firmware](https://github.com/qmk/qmk_firmware) を C から Zig へ移行するプロジェクト。

RP2040 (ARM Cortex-M0+) ベースのカスタムキーボード向けファームウェアを、ChibiOS RTOS 依存を排除し、Zig のみで実装する。

## 必要環境

- [Zig](https://ziglang.org/) 0.15.2

## ビルド

```bash
zig build                         # ファームウェアビルド（RP2040 クロスコンパイル）
zig build test                    # 全テスト実行（ホストネイティブ）
zig build verify                  # CI用: テスト + ファームウェアコンパイル検証
zig build uf2                     # UF2 形式に変換
zig build flash                   # UF2 ビルド → RP2040 BOOTSEL ドライブへコピー
```

### ビルドオプション

```bash
zig build -Dkeyboard=madbd5       # 対象キーボード（デフォルト: madbd5）
zig build -Dkeymap=default        # 対象キーマップ（デフォルト: default）
zig build -Dboot2=path/to/boot2.bin  # 第2段ブートローダーバイナリ（実機書き込み時に必要）
```

## アーキテクチャ

処理フロー: マトリックススキャン → デバウンス → キーイベント生成 → アクション解決 → タッピング判定 → アクション実行 → HID レポート送信

```
src/
├── main.zig              # エントリポイント（RP2040 スタートアップ含む）
├── core/                 # コアロジック
│   ├── keyboard.zig      # メインループ
│   ├── action.zig        # アクション解決・実行
│   ├── action_tapping.zig # タップ/ホールド判定
│   ├── keycode.zig       # キーコード定義
│   ├── layer.zig         # レイヤー管理
│   ├── host.zig          # HID ドライバインターフェース
│   └── ...               # 機能モジュール（Combo, Tap Dance, Leader Key 等）
├── hal/                  # ハードウェア抽象化層（RP2040）
│   ├── gpio.zig          # GPIO ドライバ
│   ├── usb.zig           # USB デバイスドライバ
│   ├── timer.zig         # タイマー
│   └── ...
├── tests/                # テスト
├── keyboards/            # キーボード定義
└── compat/               # C ABI 互換性検証
```

### 設計方針

- **マクロ → comptime**: C の `#define LAYOUT(...)` を Zig のコンパイル時関数に置換
- **weak シンボル → インターフェース**: `__attribute__((weak))` を Zig のコンパイル時ポリモーフィズムに再設計
- **ChibiOS 排除**: RTOS 依存を排除し、RP2040 レジスタに直接アクセス
- **テスト**: 各 HAL モジュールはホストネイティブでモック実行可能

## ライセンス

[GNU General Public License v2.0](LICENSE)

このプロジェクトは [QMK Firmware](https://github.com/qmk/qmk_firmware) からの派生著作物です。各ファイルの元の著作権表示はソースコード内のヘッダーを参照してください。
