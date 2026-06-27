---
name: build-flash-improvements
description: qmk_firmware_zig のビルド・flash 周り改善の issue ロードマップ (13件)。Zig 0.16.0 / RP2040 / 1人メンテナの前提で、Devil's Advocate レビュー 3 ラウンドを経て収束した実装計画。各 issue の背景・提案・受け入れ基準・依存関係を記載。
---

# qmk_firmware_zig ビルド・flash 改善 ロードマップ

このドキュメントは、ビルド・flash 開発体験 (DX) とセキュリティに関する 13 件の改善 issue をまとめたもの。Devil's Advocate レビュー 3 ラウンドを経て収束済み。各 issue は GitHub issue として起票され、PR ベースで実装される。

## 凡例
- 優先度: H(High) / M(Medium) / L(Low)
- 工数: s(small, 数時間) / m(medium, 1-2日) / l(large, 数日)
- セキュリティ影響: ★(向上) / ◎(中立) / ▲(注意要)

## 実装順序

| Wave | issue | 並行可 |
|---|---|---|
| 1 (基盤、逐次) | I1 → I3 | - |
| 2 (Wave 1 後、並行可) | I2, I4, S1, S2, Q5 | yes |
| 3 (Wave 2 後) | S3, D1, D2, D3, Q2 | yes |
| 4 (optional) | Q3 | - |

**1 人メンテナを考慮し、Wave 1 は逐次進行を強く推奨**。Wave 2 以降は priority drift があるため Wave 1 完了後に再評価。

---

## Phase 0: 基盤整備

### I1. Zig バージョンを 0.16.0 に統一 [H, m, ◎]

**背景**
- `build.zig.zon` `minimum_zig_version = "0.15.2"`、CI も 0.15.2、実環境は 0.16.0
- 0.15→0.16 で `addObjCopy` 等の API 差異の可能性

**事前検証 (AC 0)**
build.zig 使用 API について 0.16.0 リリースノート確認 + ローカル `zig build verify` 実行:
- `b.path()`, `b.fmt()`, `b.standardOptimizeOption()`, `b.resolveTargetQuery()`
- `b.createModule()`, `b.addExecutable()`, `b.addInstallArtifact()`, `b.addRunArtifact()`
- `b.addOptions()`, `build_opts.createModule()`
- `b.addTest()`, `b.getInstallStep()`, `b.getInstallPath()`, `b.addInstallFile()`
- `firmware.addObjCopy()`, `firmware.setLinkerScript()`

**提案**
1. AC 0 を実行、失敗時の API 差分箇所をログに記録 + 修正
2. `build.zig.zon` `minimum_zig_version = "0.16.0"`
3. `CLAUDE.md`, `README.md` の "0.15.2" を "0.16.0" へ + README に「Zig 0.16.0 以上が必要」明記
4. `.github/workflows/zig_test.yml` `version: 0.16.0`

**Acceptance Criteria**
- [ ] AC 0: 0.16.0 でローカル `zig build verify` が緑、失敗時の差分対応完了
- [ ] CI が緑
- [ ] 4 ファイルの Zig バージョン表記が統一
- [ ] README に「Zig 0.16.0 以上が必要」明記

**依存**: なし

---

### I2. ドキュメントと実装の乖離を修正 [M, s, ◎]

**背景**
- `CLAUDE.md:45` / `README.md:26` の `-Dboot2=path/to/boot2.bin` は build.zig に未実装
- `CLAUDE.md:11,254` の "38キー" vs `src/keyboards/madbd34.zig:29` `key_count: 41` (実装が正)
- BOOTSEL モード入り方が README に未記載
- トラブルシュートが未記載

**提案**
1. `-Dboot2=` 記述を削除（boot2 は `src/hal/boot2.zig` 埋込済）
2. CLAUDE.md の "38" を実装値 "41" に修正
3. README に "## RP2040 BOOTSEL モードに入る方法" + "## トラブルシューティング" セクション追加

**Acceptance Criteria**
- [ ] ドキュメントの全ビルドコマンド例が現行 build.zig で動作
- [ ] 新規開発者が README のみで初回フラッシュまで到達可能
- [ ] CLAUDE.md の madbd34 キー数が "41" に修正

**依存**: なし

---

### I3. keyboard 定義の二重管理を解消（addAnonymousImport 方式）[H, l, ◎]

**統合**: 不正 keyboard 時のエラー改善も含む

**背景**
- `build.zig:7-10` の `keyboard_configs` (rows/cols) と `src/keyboards/<name>.zig` (rows/cols) が二重管理
- `src/main.zig:15-18`, `src/core/layer.zig:21-24`, `src/core/action_tapping.zig:27-30`, `src/hal/usb_descriptors.zig:17-20` で `if (mem.eql(...)) @import(...)` 連鎖が **4 箇所重複**
- Zig は `@import` の引数に runtime/comptime キーから分岐できない

**実装方針 (addAnonymousImport 方式)**
1. build.zig 側で `-Dkeyboard=<name>` から該当 `.zig` ファイルパスを解決
2. `firmware_mod.addAnonymousImport("active_keyboard", .{ .root_source_file = b.path(b.fmt("src/keyboards/{s}.zig", .{keyboard})) })` で固定名 import 提供
3. core 側は `const kb = @import("active_keyboard");` で参照、 `kb.rows`, `kb.cols` を直接使用
4. 4 箇所の if 連鎖を削除可能

**影響ファイル (修正必須)**
- `build.zig:7-28` (keyboard_configs / addOption MATRIX_ROWS/COLS 削除)
- `src/main.zig:15-18` (if 連鎖削除)
- `src/core/keymap.zig:21-22` (build_options → `@import("active_keyboard")` 参照)
- `src/core/layer.zig:21-24, 192-194` (同)
- `src/core/keyboard.zig:46-47` (keymap_mod 経由のままで可)
- `src/core/action_tapping.zig:27-30` (if 連鎖削除)
- `src/hal/usb_descriptors.zig:17-20` (if 連鎖削除)
- `src/core/test_fixture.zig:23-24` (確認のみ)

**提案**
1. `addAnonymousImport` 方式で active_keyboard 固定名提供
2. core 側 4 ファイルの if 連鎖削除
3. build.zig の keyboard_configs / addOption 削除
4. **不正 keyboard 時のエラー改善**: panic ではなく Build error として返す、有効リストを動的生成、日本語化
   - 事前調査: Zig 0.16.0 std.Build で `b.failureMessage` 相当があるか確認、なければ `return error.InvalidKeyboard` 等で代替

**Acceptance Criteria**
- [ ] 新規キーボード追加が `src/keyboards/<name>.zig` 新設のみで完結（build.zig 編集不要）
- [ ] core 側 4 箇所の if 連鎖が削除されている
- [ ] 全テスト緑、両既存キーボードのファーム動作不変
- [ ] `zig build -Dkeyboard=foo` で日本語エラー + 有効リスト自動表示（panic ではない）
- [ ] `zig build test` (-Dkeyboard 未指定) で madbd5 が解決されてテスト緑
- [ ] `zig build test` で test-compat が緑

**依存**: I1

---

### I4. CI 改善（multi-OS matrix + zig fmt + verify + cache）[H, s, ◎]

**背景**
- `.github/workflows/zig_test.yml` は ubuntu のみ
- `zig fmt --check` がない
- `zig build test` + `zig build` を別呼出（`verify` step 未活用）
- zig cache を使っていない

**提案**
1. `strategy.matrix.os: [ubuntu-latest, macos-latest, windows-latest]`
2. `zig fmt --check src tools build.zig` ステップ追加
3. `zig build test` + `zig build` を `zig build verify` に統合
4. `actions/cache` で `~/.cache/zig`, `.zig-cache` をキャッシュ

**Acceptance Criteria**
- [ ] 3 OS で `zig build verify` が緑（ユニットテスト + cross-compile）
- [ ] 実機 flash テストは I4 の対象外と明記
- [ ] フォーマット崩れ PR が CI で弾かれる
- [ ] 2 回目以降の `zig build verify` 実行時間が初回比 30% 以上短縮、または 60 秒以内

**依存**: I1

---

## Phase 1: セキュリティ・データ保護

### S1. BOOTSEL ドライブ検証の強化（誤書込防止）[H, l, ◎]

**スコープ明確化**
- **目的**: 誤書込防止 (accidental write)
- **想定外**: 敵対的攻撃の防御 (将来 D2 picotool バックエンドで USB VID/PID 検証等が可能)

**背景**
- `tools/flash.zig:100-106` (macOS) / `108-132` (Linux) で INFO_UF2.TXT 未検証
- `std.fs.realpath` 未使用 → symlink 経由で意図しない場所へ書込
- `flash.zig:110` の `USER` env を未検証で `/media/{s}/...` に展開
- Linux 検出順序が古いディストリ前提（`/media` 優先）

**提案**
1. 検出ロジックを `verifyBootselDrive(path)` に集約:
   - `<path>/INFO_UF2.TXT` 存在 + "UF2 Bootloader" 部分一致
   - `Board-ID: RPI-RP2` 行を partial match
2. `std.fs.realpathAlloc()` で正規化、symlink 先が想定外なら拒否
3. `std.posix.getenv` のまま、戻り値の内容を許可リスト `[A-Za-z0-9._-]{1,32}` で検証（違反は次経路へ fallback）
4. Linux 検出順序を `/run/media/$USER/` → `/media/$USER/` → `/mnt/` に変更
5. 書込直前 (`flash.zig:56`) に再度 INFO_UF2.TXT を確認（軽量 TOCTOU 緩和）

**Acceptance Criteria**
- [ ] INFO_UF2.TXT がない偽 RPI-RP2 ディレクトリで abort + 日本語エラー
- [ ] symlink 化された `/Volumes/RPI-RP2` で abort
- [ ] `USER=foo;bar` で fallback、`/mnt/RPI-RP2` 経由で正常検出
- [ ] Linux で `/run/media/$USER/RPI-RP2` を優先検出
- [ ] symlink テスト: Windows runner では skip + 明示コメント
- [ ] 既存の正常書込パスが動作

**依存**: なし

---

### S2. ファームウェアサイズ + メモリ使用状況の可視化と保護 [H, m, ★]

**統合**: ELF/UF2 セクションサイズ表示、uf2gen --family-id

**背景**
- `tools/uf2gen.zig:71-83` のブロック生成ループに範囲チェックなし
- `firmware_data.len` が 2044*1024 を超えると target_addr が EEPROM 領域 `0x101FF000` に到達 → ユーザー設定 (eeconfig) 破壊
- `FileSizeStep` (`build.zig:174-211`) は size のみ
- family_id がハードコード (RP2350 対応の余地なし)

**正しい計算**
- FLASH 全体: `(2048-4)*1024 = 2093056 byte` (boot2 含む内訳、EEPROM 4KB 引いた後)
- target_addr の上限: `< 0x101FF000`

**実装方針**
- セクションサイズ表示は `std.elf` でセクションヘッダ直接パース (約 80-100 行、外部ツール非依存)
- arm-none-eabi-size は依存しない
- uf2gen の `main` から `generateUf2Blocks` 関数を切り出してテスト容易化

**提案**
1. **uf2gen 側**:
   - `generateUf2Blocks(firmware: []const u8, family_id: u32, flash_base: u32, writer: anytype)` を切り出し
   - 各ブロックの target_addr が `0x101FF000` 未満であることを assert
   - 入力 .bin サイズが `2093056` 超なら日本語エラー + 非ゼロ終了
   - `--family-id=<hex>` (default 0xe48bff56)、`--flash-base=<hex>` (default 0x10000000) オプション追加
2. **build.zig 側 (`FileSizeStep` → `MemoryUsageStep` 拡張)**:
   - `std.elf` で ELF を読み、`.text/.data/.bss` セクションサイズを取得
   - linker region サイズと比較表示（stderr）
   - 出力例:
     ```
     madbd5_default.elf:
       .text: 45.2 KB / 2044 KB (2.2%)
       .data:  1.1 KB /  256 KB (0.4%)
       .bss:   8.4 KB /  256 KB (3.3%)
       stack:  4.0 KB /    8 KB (50.0%)
     ```
   - RAM > 80% / FLASH > 90% で warning（exit code 0 維持）

**Acceptance Criteria**
- [ ] 上限超 .bin で uf2gen が非ゼロ終了 + 日本語エラー
- [ ] target_addr が EEPROM 領域に到達しない assertion
- [ ] 最終ブロックの 256B 境界処理が EEPROM 領域 (0x101FF000-0x101FFFFF) を破壊しないテスト
- [ ] `generateUf2Blocks` 関数が単体テスト可能（境界値、超過、正常）
- [ ] uf2gen に `--family-id=<hex>` `--flash-base=<hex>` オプション存在、default 動作不変
- [ ] `zig build` 終了時に各セクションサイズ + 容量比 stderr 表示
- [ ] 容量超過 warning（exit code 0）
- [ ] 外部ツール非依存（arm-none-eabi-size 等）

**依存**: I1

---

### S3. copyFile 後の RP2040 切断確認 [M, s, ◎]

**背景**
- `tools/flash.zig:56` の `copyFile` 成功は OS バッファ書込時点で返る
- 異常切断しても "成功" と表示
- 実際の書込完了 = `/Volumes/RPI-RP2` が消える、で確認可能

**提案**
1. `copyFile` 後に 5 秒間 BOOTSEL ドライブの存在をポーリング（根拠: RP2040 リブート時間 + OS unmount 待ちの実測値 2-3 秒）
2. 消えれば "RP2040 の再起動を確認しました" 表示
3. 消えなければ "書込は完了したが RP2040 の再起動が確認できませんでした" 警告
4. 失敗時のエラーメッセージに OS errno を含める

**Acceptance Criteria**
- [ ] 書込成功時に "再起動確認" 表示
- [ ] 異常時に詳細エラー（errno付）
- [ ] ポーリング 5 秒（実装コメントに根拠記載）
- [ ] 既存テスト緑

**依存**: S1

---

## Phase 2: DX 改善（flash 自動化）

### D1. CDC 1200bps トリガで bootloader.jump フック + ホスト側 1200bps タッチ [M, m, ◎]

**背景**
- 物理 BOOT ボタン押下 + USB 抜き差しが必要
- 既存の `set_line_coding` ハンドラ (`src/hal/usb.zig:1264`) は dwDTERate を保存するのみ
- CDC は `src/hal/usb_descriptors.zig:86-87` で既に実装済

**提案**
1. **ファーム側 (`src/hal/usb.zig:1264-1273` 周辺)**:
   - `cdc_line_coding.dwDTERate == 1200` を検出した時に `bootloader.jump()` (`src/hal/bootloader.zig:43`) 呼出
   - 既存テストとの統合 (`usb.zig:2409-2430` の line_coding 処理テスト)
2. **ホスト側 (`tools/flash.zig`)**:
   - BOOTSEL ドライブが見つからなければ:
     - macOS: `/dev/cu.usbmodem*` を VID=0x2E8A でフィルタ → 1200bps で短時間 open → close
     - Linux: `/dev/ttyACM*` 同様
     - Windows: `COM*` を `SetCommState` で 1200bps 設定
   - 5 秒間 BOOTSEL ドライブ出現を待機
3. `--no-auto-reset` で従来動作にフォールバック

**Acceptance Criteria**
- [ ] キーボード通常モード接続中に `zig build flash` 一発で BOOTSEL → 書込完了
- [ ] 既存物理 BOOTSEL 経路もフォールバックで動作
- [ ] `--no-auto-reset` で従来動作
- [ ] CI で ホスト側 1200bps open ロジックの単体テスト（mock tty）
- [ ] USB descriptor (HID 0-3, CDC 4-5) 不変、既存キーマップ動作不変

**セキュリティ注意**: 既に CDC が公開されているため、悪意あるホストプロセスが意図せず BOOTSEL に落とす可能性は既存リスク。BadUSB 観点では DoS 程度の影響。

**依存**: なし (S1 推奨だが必須ではない)

---

### D2. flasher バックエンド選択（`-Dflasher`）[M, m, ◎]

**背景**
- 現状 BOOTSEL コピー一択
- picotool/openocd/probe-rs を使う環境で手動運用必要

**提案**
1. `zig build flash -Dflasher=bootsel|picotool|openocd|probers` で切替
2. `picotool` バックエンド: `picotool load -f -u -v <abs_uf2_path>`
3. `openocd` バックエンド: `openocd -s <abs_search_dir> -f interface/cmsis-dap.cfg -f target/rp2040.cfg -c "program <abs_elf> verify reset exit"`
4. `probers` バックエンド: `probe-rs run --chip RP2040 <abs_elf>`
5. デフォルトは `bootsel`（後方互換）
6. 外部ツール不在時はインストール手順を含むエラー

**Acceptance Criteria**
- [ ] 4 バックエンドのコード経路が build.zig に存在
- [ ] picotool 不在時に明示エラー + `brew install picotool` 案内
- [ ] デフォルト動作不変（後方互換）
- [ ] 入力検証 (UX): keyboard/keymap 引数を `[A-Za-z0-9_-]+` のみ許可、違反で build エラー
- [ ] openocd の検索ディレクトリ絶対パス指定 (`-s <abs>`) で **設定ファイルインジェクション対策** (CWD ベースで `interface/cmsis-dap.cfg` 等が読み込まれるのを防ぐ)
- [ ] 外部ツール本体 (`picotool`, `openocd`, `probe-rs`) は `which`/`where` 解決済の絶対パスで起動し、 **PATH 攻撃対策** (PATH 上の偽バイナリ実行を防ぐ)

**依存**: I1

---

### D3. flash CLI 改善 [M, m, ◎]

**統合**: マルチ RP2040 検出と選択

**背景**
- `flash.zig:64` `timeout_seconds = 60` 固定
- 大きい UF2 でも進捗なし
- メッセージが日本語/英語混在
- 複数 RP2040 接続時に最初に見つかったものに書込

**提案**
1. CLI 引数:
   - `--timeout=<sec>` (default 60, env `QMK_FLASH_TIMEOUT_SEC`)
   - `--device-path=<path>` (検出スキップ、明示パス指定)
   - `--device-index=<n>` (複数検出時の n 番目を指定)
   - `--verbose` (詳細ログ)
2. `copyFile` を 4KB チャンクループに変更、500ms ごとに進捗 (`\r{percent}% ({bytes}/{total})`)
3. 全 print を日本語化（Usage / Error 含む）
4. 複数検出時は INFO_UF2.TXT 内の `Board-ID` + シリアル番号を表示

**Acceptance Criteria**
- [ ] `flash --help` で全引数日本語表示
- [ ] `> 100KB` の UF2 で進捗表示が更新される、または mock writer 経由の進捗呼出を検証
- [ ] 2 台同時 BOOTSEL 接続時、両方検出されてエラー or 選択促し
- [ ] `--device-path=/Volumes/RPI-RP2` で指定可能
- [ ] `--device-index=1` で指定可能
- [ ] CI で各 CLI 引数経路のテスト

**依存**: S1

---

### Q2. zig build で UF2 まで生成（後方互換維持）[M, s, ◎]

**背景**
- `zig build` 単独だと ELF のみ、UF2 が出ない
- QMK 慣習や PlatformIO 等の他ツールでは flash 成果物 (.uf2/.bin/.hex) が直接出る
- 初回ユーザー困惑

**提案**
1. `b.getInstallStep().dependOn(&uf2_install.step)` を追加
2. `zig build` 単発で ELF と UF2 の両方を install 出力
3. 後方互換: ELF のみ欲しい場合は `zig build elf` を別 step 追加

**Acceptance Criteria**
- [ ] `zig build` で `zig-out/madbd5_default.uf2` も生成される
- [ ] `zig build elf` で ELF のみ生成（任意 step）
- [ ] CI workflow の `zig build verify` 所要時間が、Q2 適用前の同一構成と比較して 2 秒以上の増加なし（実測値ログで確認）

**依存**: なし

---

### Q5. flash_run の依存関係整理（出力順序保証）[L, s, ◎]

**背景**
- `build.zig:78-81` で `flash_step.dependOn(&flash_run.step)` と `flash_step.dependOn(uf2_size_step)` の両方
- `uf2_size_step` と `flash_run` の実行順序が保証されない → 出力混在

**提案**
- `addFlashStep` 内で `flash_run.step` が UF2 サイズ表示 step に depend するよう修正
- `flash_step.dependOn` の重複を削除
- 注: S2 完了後は `uf2_size_step` が `MemoryUsageStep` に置換される可能性があるため、実装時の step 名を確認

**Acceptance Criteria**
- [ ] `zig build flash` 出力順が UF2サイズ表示 → flash で安定

**依存**: なし

---

## Phase 3: 品質

### Q3. Git hash + SHA256 のビルド時埋込 [M, s, ◎]

**背景**
- 個体識別ができず、特定ビルドのバグ報告で再現性が取れない
- `picotool info` でファーム情報を見られる手段がない

**提案**
1. `build.zig` で `git rev-parse --short=12 HEAD` を実行 (`--short=12` 固定で reproducible)
2. 結果を `build_options.GIT_HASH` として expose
3. UF2 ファイル全体 (`{name}.uf2`) の SHA256 を計算し、ビルドログに stderr 表示
4. オプション: USB string descriptor の serial に GIT_HASH を含める

**Acceptance Criteria**
- [ ] `zig build` 出力に GIT_HASH と UF2 の SHA256 が表示
- [ ] git 不在時 / shallow clone (fetch-depth=1) で空文字 + warning でビルド継続
- [ ] reproducible: 同 commit + 同 zig version + 同 OS で SHA256 一致

**依存**: なし

---

## サマリ表

| ID | 優先度 | 工数 | セキュリティ | 依存 |
|---|---|---|---|---|
| I1 | H | m | ◎ | - |
| I2 | M | s | ◎ | - |
| I3 | H | l | ◎ | I1 |
| I4 | H | s | ◎ | I1 |
| S1 | H | l | ◎ | - |
| S2 | H | m | ★ | I1 |
| S3 | M | s | ◎ | S1 |
| D1 | M | m | ◎ | - |
| D2 | M | m | ◎ | I1 |
| D3 | M | m | ◎ | S1 |
| Q2 | M | s | ◎ | - |
| Q3 | M | s | ◎ | - |
| Q5 | L | s | ◎ | - |

合計 13 件。

## 関連 skills

- `rp2040-flash-knowledge.md`: RP2040 flash の専門知識（BOOTSEL検出、UF2形式、CDC 1200bps reset）
- `zig-build-conventions.md`: build.zig 改修時の Zig 0.16 API 規約
