# QMK Firmware Zig

[QMK Firmware](https://github.com/qmk/qmk_firmware) を C から Zig へ移行するプロジェクト。

RP2040 (ARM Cortex-M0+) ベースのカスタムキーボード向けファームウェアを、ChibiOS RTOS 依存を排除し、Zig のみで実装する。

## 必要環境

- [Zig](https://ziglang.org/) 0.16.0 以上

## ビルド

```bash
zig build                         # ファームウェアビルド (ELF + UF2 を zig-out/ へ出力)
zig build elf                     # ELF のみ生成 (UF2 変換なし)
zig build uf2                     # UF2 のみ生成 (ELF なし)
zig build test                    # 全テスト実行（ホストネイティブ）
zig build verify                  # CI用: テスト + ファームウェアコンパイル検証
zig build flash                   # UF2 ビルド → RP2040 BOOTSEL ドライブへコピー
```

### ビルドオプション

```bash
zig build -Dkeyboard=madbd5       # 対象キーボード（デフォルト: madbd5）
zig build -Dkeymap=default        # 対象キーマップ（デフォルト: default）
zig build flash -Dflasher=picotool # flash バックエンド（bootsel|picotool|openocd|probers、デフォルト: bootsel）
```

## RP2040 BOOTSEL モードに入る方法

`zig build flash` は RP2040 が BOOTSEL モードでマウントされている前提で UF2 をコピーする。BOOTSEL モードに入るには:

1. **物理 BOOT ボタン**: BOOTSEL ボタンを押しながら USB ケーブルを接続（または再接続）。`/Volumes/RPI-RP2` (macOS) / `/run/media/$USER/RPI-RP2` (Linux) / D:〜Z:\ (Windows) にマウントされる。
2. **既に通常モードで動作している場合**: 一度ケーブルを抜き、 BOOT ボタンを押した状態で再接続する。

接続成功後に `zig build flash` を実行すると、検出された BOOTSEL ドライブへ UF2 がコピーされ、 RP2040 は自動的に再起動する。

## トラブルシューティング

### `zig build flash` で `Error: タイムアウト。RP2040 が検出されませんでした。` と表示される

- BOOT ボタンを押した状態で USB を再接続したか確認
- USB ハブ経由ではなくマシンに直接接続してみる
- 別の USB ポート / ケーブルを試す

### `RPI-RP2` ドライブがマウントされない

- macOS: 「Finder の設定 → サイドバー → 外部ディスク」を有効化
- Linux: `udisksctl mount -b /dev/sdX` 等で手動マウント。 `lsblk` で RP2040 の MSC を確認
- Windows: 「ディスクの管理」でドライブレターが付いているか確認

### Bootmagic で意図せずブートローダーに入る

- `zig build -DBOOTMAGIC_ROW=N -DBOOTMAGIC_COLUMN=M` で位置を変更
- デフォルトは常に `(0, 0)` (build.zig 既定値)。 該当する物理キーはキーボード定義 (`src/keyboards/<name>.zig` の LAYOUT) により異なる

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
