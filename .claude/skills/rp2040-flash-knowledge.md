---
name: rp2040-flash-knowledge
description: RP2040 のファームウェア書き込み (flash) に関する技術仕様。BOOTSEL モード検出、UF2 ファイル形式、CDC 1200bps reset、picotool/openocd/probe-rs の比較、ファームウェアサイズ制約、Family ID 一覧。build/flash 関連 issue 実装時の参照。
---

# RP2040 Flash 技術仕様

このドキュメントは qmk_firmware_zig の build/flash 関連 issue 実装時の参考資料。RP2040 BOOTSEL の挙動、UF2 形式、リセット手法、外部ツールの選択について網羅的に記載。

## BOOTSEL モード

### 入り方
1. **物理ボタン**: BOOTSEL ボタンを押しながら USB ケーブル接続（電源投入 / リセット）
2. **ROM 関数経由**: 実行中ファームから `reset_usb_boot(0, 0)` 呼出 (= `src/hal/bootloader.zig:43` の `bootloader.jump()`)
3. **CDC 1200bps トリガ**: USB CDC ACM の line_coding を 1200bps に設定 → ファーム側で検出して ROM 関数呼出 (issue D1)

### USB 識別子
- VID: `0x2E8A` (Raspberry Pi)
- PID: `0x0003` (RP2040 BOOTSEL)
- PID: `0x000F` (RP2350 BOOTSEL)
- USB MSC でストレージとして列挙される

### マウントポイント
| OS | パス |
|---|---|
| macOS | `/Volumes/RPI-RP2` |
| Linux (systemd-mount) | `/run/media/$USER/RPI-RP2` |
| Linux (udisks 旧) | `/media/$USER/RPI-RP2` |
| Linux (手動 mount) | `/mnt/RPI-RP2` |
| Windows | D:〜Z: ドライブ |

### INFO_UF2.TXT 内容例
```
UF2 Bootloader v3.0
Model: Raspberry Pi RP2
Board-ID: RPI-RP2
```

検証時は **Board-ID 行を partial match** が安全（bootloader version で内容が変わる）。

## UF2 ファイル形式

### Block 構造 (512 バイト固定)

| オフセット | サイズ | 名前 | 値 |
|---|---|---|---|
| 0-3 | 4B | magicStart0 | `0x0A324655` ("UF2\n") |
| 4-7 | 4B | magicStart1 | `0x9E5D5157` |
| 8-11 | 4B | flags | bitfield |
| 12-15 | 4B | targetAddr | フラッシュアドレス |
| 16-19 | 4B | payloadSize | 通常 256 |
| 20-23 | 4B | blockNo | 0-indexed |
| 24-27 | 4B | numBlocks | 総数 |
| 28-31 | 4B | familyID/fileSize | flag で切替 |
| 32-507 | 476B | data | ペイロード+padding |
| 508-511 | 4B | magicEnd | `0x0AB16F30` |

### Flag bits
- `0x00000001` notMainFlash
- `0x00001000` fileContainer
- `0x00002000` familyIDPresent (RP2040 は必須)
- `0x00004000` md5Checksum
- `0x00008000` extensionTags

### Family ID 一覧
| デバイス | Family ID |
|---|---|
| RP2040 | `0xe48bff56` |
| RP2XXX_ABSOLUTE | `0xe48bff57` |
| RP2XXX_DATA | `0xe48bff58` |
| RP2350_ARM_S | `0xe48bff59` |
| RP2350_RISCV | `0xe48bff5a` |
| RP2350_ARM_NS | `0xe48bff5b` |

## RP2040 メモリマップ

### Flash (XIP)
- ベース: `0x10000000`
- サイズ: 2MB (W25Q16JV 想定) - EEPROM 予約(4KB) = 2,093,056 bytes
  - 計算根拠: `0x101FF000 - 0x10000000 = 0x1FF000 = 2,093,056`
  - boot2 (256B) はこのフラッシュ書込可能領域の **先頭 (0x10000000-0x100000FF)** に配置されるため、内訳に含まれる (二重カウントしない)
- ファームウェア書込み可能上限: `0x101FF000` 未満
- EEPROM予約領域: `0x101FF000-0x101FFFFF` (4KB、最終 sector)

### SRAM
- メイン: `0x20000000-0x2003FFFF` (256KB)
- Scratch X: `0x20040000-0x20040FFF` (4KB)
- Scratch Y: `0x20041000-0x20041FFF` (4KB)

### boot2
- 256 バイト固定、フラッシュ先頭 (0x10000000-0x100000FF)
- W25Q080 互換の XIP 設定 (現状 `src/hal/boot2.zig` で埋込済)
- BOOTROM の CRC32 チェック対象

## flash 手段の比較

### 1. BOOTSEL ドライブコピー (現状)
- 手段: ストレージにマウントして UF2 をコピー
- 長所: 外部ツール不要
- 短所: 物理ボタン必要、書込検証なし
- 適用: デフォルト

### 2. picotool (Raspberry Pi 公式)
```bash
# インストール
brew install picotool          # macOS
# Linux: pico-sdk + libusb 1.0 + cmake + pkgconf

# 使用例
picotool load -f -u -v firmware.uf2   # 書込 + verify + reboot
picotool reboot -f -u                 # 動作中→BOOTSEL
picotool info -a                      # ファーム情報
```
- 長所: BOOTSEL自動化 (`-f -u`)、verify、metadata表示
- 短所: 外部ツール必要、Linux で udev rules 必要

### 3. openocd (Picoprobe / CMSIS-DAP)
```bash
openocd -s <search> -f interface/cmsis-dap.cfg -f target/rp2040.cfg \
  -c "program firmware.elf verify reset exit"
```
- 長所: SWD 経由でブリック復旧可能、ELF 直接書込、デバッグ可能
- 短所: 外部プローブ必要 (Pico-Pico、CMSIS-DAP等)

### 4. probe-rs (Rust製、組込Rustデファクト)
```bash
brew install probe-rs            # macOS
probe-rs run --chip RP2040 firmware.elf
```
- 長所: モダン CLI、RTT log、cross-platform
- 短所: 外部プローブ必要

## CDC 1200bps reset の仕組み

Arduino IDE / PlatformIO / picotool すべて対応する標準ポータブルな手法。

### ファーム側 (issue D1)
```zig
// src/hal/usb.zig の set_line_coding ハンドラに追加
.set_line_coding => {
    self.cdc_line_coding = @bitCast(buf);
    if (self.cdc_line_coding.dwDTERate == 1200) {
        bootloader.jump();
    }
},
```

### ホスト側 (tools/flash.zig)
```
macOS:   /dev/cu.usbmodem* を 1200bps で短時間 open/close
Linux:   /dev/ttyACM* を 1200bps で短時間 open/close
Windows: COM* を SetCommState(1200) 後 close
```

タッチ後、500ms-2s で BOOTSEL ドライブが出現する。

## セキュリティ

### RP2040 のハード制約
- **OTP なし**: ファームウェア署名検証はハードでは不可能
- **secure boot なし**: BootROM は boot2 の CRC32 検証のみ
- 改ざん検出はソフトウェアでハッシュ埋込 + 起動時自己検証が必要だが、攻撃者がフラッシュ書込権限を持つなら無意味

### RP2350 (将来)
- OTP 搭載、secure boot 対応、`picotool sign` で署名付き UF2 生成可能

### 誤書込防止 vs 攻撃防御の区別
- **誤書込防止**: INFO_UF2.TXT 検証、realpath 正規化、USER env 内容検証 (issue S1)
- **攻撃防御 (将来 D2 経由)**: USB VID/PID = 0x2E8A:0x0003 を libusb/IOKit で取得、シリアル番号比較

INFO_UF2.TXT 検証は誤書込防止であり、敵対者が偽 INFO_UF2.TXT を置けば突破可能 → セキュリティ目的の用途には picotool バックエンドを推奨。

### path traversal / symlink
- macOS/Linux で `realpath` 未使用だと `/Volumes/RPI-RP2` がシンボリックリンクの場合に意図外パスへ書込
- `std.fs.realpathAlloc()` で正規化 + symlink 拒否を推奨

### 外部コマンド呼出
- `b.addSystemCommand` は `execve` 経由 (shell 非経由) のため shell metacharacter injection なし
- ただし openocd の `-s <search_dir>` は CWD ベースで cfg を探すため、絶対パス指定推奨

## 関連ファイル (qmk_firmware_zig)

- `tools/flash.zig`: BOOTSEL ドライブ検出 + UF2 コピー
- `tools/uf2gen.zig`: ELF → raw bin → UF2 変換
- `src/hal/boot2.zig`: W25Q080 互換 boot2 (256B 埋込)
- `src/hal/bootloader.zig:43`: `jump()` (BOOTSEL モードへ遷移)
- `src/hal/rp2040_linker.ld`: メモリマップ (FLASH/RAM/SCRATCH 定義)
- `src/hal/usb.zig:299, 387, 1264-1273`: CDC line_coding 処理
- `src/hal/usb_descriptors.zig:86-87`: CDC interface 定義 (4-5)

## 参考リンク

- [picotool](https://github.com/raspberrypi/picotool)
- [Microsoft UF2 仕様](https://github.com/microsoft/uf2)
- [uf2families.json](https://github.com/microsoft/uf2/blob/master/utils/uf2families.json)
- [RP2040 datasheet](https://datasheets.raspberrypi.com/rp2040/rp2040-datasheet.pdf)
- [pico-sdk reset_interface](https://github.com/raspberrypi/pico-sdk)
- [QMK RP2040 platform docs](https://github.com/qmk/qmk_firmware/blob/master/docs/platformdev_rp2040.md)
