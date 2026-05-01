---
name: zig-build-conventions
description: qmk_firmware_zig の build.zig 改修時の Zig 0.16 API パターン集。addAnonymousImport によるキーボード解決、std.elf によるセクションサイズ抽出、b.addSystemCommand のセキュリティ、custom step 実装、テスト統合。build/flash 関連 issue (I1, I3, S2, D2, Q2 など) 実装時の参照。
---

# Zig 0.16 build.zig 規約 (qmk_firmware_zig)

build.zig 改修時に守るべきパターンと、issue 実装で頻出する技術要素のメモ。

## Zig バージョン

- **必要**: 0.16.0 (issue I1 で確定)
- 旧 0.15.2 から 0.16.0 への API 差異は事前検証が必須
- `build.zig.zon` の `minimum_zig_version` は実環境と一致させる

## キーボード解決 (issue I3)

### 制約: `@import` は string literal のみ
Zig では `@import` の引数に runtime 値や comptime 値 (build_options.KEYBOARD のような) を渡せない。

**現状 (anti-pattern、4 箇所重複)**:
```zig
const kb = if (std.mem.eql(u8, build_options.KEYBOARD, "madbd34"))
    @import("../keyboards/madbd34.zig")
else if (std.mem.eql(u8, build_options.KEYBOARD, "madbd5"))
    @import("../keyboards/madbd5.zig")
else
    @compileError("Unknown keyboard");
```

### 推奨パターン: `addAnonymousImport`

build.zig 側で keyboard 名から該当ファイルパスを解決し、固定名 import を提供する:

```zig
// build.zig
const keyboard_path = b.fmt("src/keyboards/{s}.zig", .{keyboard});
const keyboard_module = b.createModule(.{
    .root_source_file = b.path(keyboard_path),
});
firmware_mod.addAnonymousImport("active_keyboard", keyboard_module);
```

core 側は `@import` 連鎖なしで:

```zig
// src/core/keymap.zig 等
const kb = @import("active_keyboard");
pub const MATRIX_ROWS: u8 = kb.rows;
pub const MATRIX_COLS: u8 = kb.cols;
```

新規キーボード追加 = `src/keyboards/<name>.zig` 新設のみで build.zig 編集不要。

## ELF セクションサイズ抽出 (issue S2)

### 外部ツール非依存方針

`arm-none-eabi-size` は GitHub Actions runner に標準でない。Zig 同梱の LLVM size CLI も提供されていない。`std.elf` でセクションヘッダ直接パースする:

```zig
// 簡略版例
const std = @import("std");
const elf = std.elf;

fn elfSectionSizes(elf_bytes: []const u8) !struct { text: u64, data: u64, bss: u64 } {
    var stream = std.io.fixedBufferStream(elf_bytes);
    const header = try elf.Header.read(&stream);
    
    var text: u64 = 0;
    var data: u64 = 0;
    var bss: u64 = 0;
    
    var iter = header.section_header_iterator(&stream);
    while (try iter.next()) |sh| {
        const name = ...; // section name strtab から取得
        if (std.mem.eql(u8, name, ".text")) text = sh.sh_size;
        if (std.mem.eql(u8, name, ".data")) data = sh.sh_size;
        if (std.mem.eql(u8, name, ".bss")) bss = sh.sh_size;
    }
    return .{ .text = text, .data = data, .bss = bss };
}
```

linker region サイズは `rp2040_linker.ld` 由来の定数として build.zig 内に持つ:
- FLASH: `(2048 - 4) * 1024 = 2093056` (EEPROM 4KB 引いた後)
- RAM: `256 * 1024`
- SCRATCH: `8 * 1024`

## Custom Step パターン

`FileSizeStep` (`build.zig:174-211`) と同形式:

```zig
const MyStep = struct {
    step: std.Build.Step,
    // ... fields
    
    fn create(b: *std.Build, ...) *MyStep {
        const self = b.allocator.create(MyStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "my-step",
                .owner = b,
                .makeFn = make,
            }),
            // ... field init
        };
        return self;
    }
    
    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        const self: *MyStep = @fieldParentPtr("step", step);
        // ... logic
    }
};
```

## 外部コマンド呼出のセキュリティ

### `b.addSystemCommand` は execve 経由

shell metacharacter injection は **発生しない**。引数配列は `execvp` syscall に直接渡る。
```zig
const run = b.addSystemCommand(&.{ "picotool", "load", "-f", "-u", "-v", uf2_path });
```
↑ これでよく、shell escape 不要。

### ただし以下は注意

1. **PATH 攻撃**: 外部ツール (picotool, openocd) が PATH 上の偽バイナリにヒット
   - `which`/`where` で絶対パス解決推奨 (実装コスト次第)
2. **設定ファイル探索**: openocd の `-s <search_dir>` が CWD ベースで cfg を探す
   - 絶対パス指定 (`-s /opt/openocd/scripts`)
3. **入力検証 (UX)**: keyboard/keymap 引数は build.zig で `[A-Za-z0-9_-]+` 検証
   - セキュリティ目的ではなく、build エラー早期化

## addInstallStep への依存

`b.getInstallStep()` のデフォルト挙動:
```zig
b.installArtifact(firmware);  // ELF を install
// UF2 も install したい場合:
b.getInstallStep().dependOn(&uf2_install.step);
```

`zig build` 単発で UF2 まで生成したい場合 (issue Q2)、`b.getInstallStep().dependOn(&uf2_install.step)` を追加。

## Step 間の順序保証

`step.dependOn(other)` で依存順を明示:
```zig
flash_run.step.dependOn(&uf2_size_step.step);  // サイズ表示 → flash
```

複数の `dependOn` を同じ step に書いても順序は保証されない (DAG なので並列実行可)。出力順を保証したいなら **チェーン状の依存** にする。

## テスト統合

### 既存パターン
```zig
const test_step = b.step("test", "Run unit tests");
const tests = b.addTest(.{ .root_module = test_mod });
const run_tests = b.addRunArtifact(tests);
test_step.dependOn(&run_tests.step);
```

### tools/ 内のテスト
`tools/flash.zig` の test ブロックを `zig build test` で実行:
```zig
const flash_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("tools/flash.zig"),
        .target = native_target,
    }),
});
const run_flash_tests = b.addRunArtifact(flash_tests);
test_step.dependOn(&run_flash_tests.step);
```

### `zig build verify` パターン
CI 用の集約 step:
```zig
const verify_step = b.step("verify", "Run tests and verify firmware compilation");
verify_step.dependOn(&run_tests.step);
verify_step.dependOn(&firmware.step);
```

## ビルドオプション

### 標準形
```zig
const keyboard = b.option([]const u8, "keyboard", "Target keyboard") orelse "madbd5";
const bootmagic_row = b.option(u8, "BOOTMAGIC_ROW", "...") orelse 0;
```

### モジュール経由で expose
```zig
const build_opts = b.addOptions();
build_opts.addOption(u8, "BOOTMAGIC_ROW", bootmagic_row);
build_opts.addOption([]const u8, "KEYBOARD", keyboard);
firmware_mod.addImport("build_options", build_opts.createModule());
```

core 側は `@import("build_options").BOOTMAGIC_ROW` で参照。

### 不正値時のエラー処理 (issue I3 で改善)

**現状 (anti-pattern)**:
```zig
const kb_config = keyboard_configs.get(keyboard) orelse
    std.debug.panic("Unknown keyboard: '{s}'. Known: madbd34, madbd5", .{keyboard});
```

panic はスタックトレースが冗長。Build error として返す方が UX 良い。0.16.0 で `b.failureMessage` 相当が利用可能か確認。なければ `return error.InvalidKeyboard` 等で代替。

## CI 連携 (issue I4)

### multi-OS matrix
```yaml
strategy:
  matrix:
    os: [ubuntu-latest, macos-latest, windows-latest]
runs-on: ${{ matrix.os }}
```

### キャッシュ
```yaml
- uses: actions/cache@v4
  with:
    path: |
      ~/.cache/zig
      .zig-cache
    key: zig-${{ matrix.os }}-${{ hashFiles('build.zig.zon') }}
```

### `zig build verify` 統合
```yaml
- name: Verify
  run: zig build verify
```

`test` + `build` 別呼出より効率的（共通モジュールの再コンパイル削減）。

### shallow clone と git rev-parse (issue Q3)
GitHub Actions の `actions/checkout@v6` のデフォルトは `fetch-depth: 1`。`git rev-parse --short HEAD` は動くが `git describe` 系 tag ベースは動かない。

```zig
// build.zig 内で git 実行
const git_hash = blk: {
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "git", "rev-parse", "--short=12", "HEAD" },
    }) catch break :blk "";
    break :blk std.mem.trim(u8, result.stdout, " \n\t");
};
build_opts.addOption([]const u8, "GIT_HASH", git_hash);
```

git 不在 / shallow clone fail 時は空文字 + warning 継続。

## 関連 skills

- `build-flash-improvements.md`: 13件 issue ロードマップ
- `rp2040-flash-knowledge.md`: RP2040 flash 専門知識
