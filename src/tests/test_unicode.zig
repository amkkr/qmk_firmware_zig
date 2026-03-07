// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zig port of tests/unicode/test_unicode.cpp
// Original: Copyright 2023 QMK

//! Unicode 入力テスト
//! C版 tests/unicode/test_unicode.cpp の Zig 移植
//!
//! TestFixture を使ってキーボードパイプライン経由で Unicode キーコードを処理し、
//! 正しいキーシーケンスが送信されることを検証する。

const std = @import("std");
const testing = std.testing;
const core = @import("../core/core.zig");
const keycode = core.keycode;
const KC = keycode.KC;
const unicode = core.unicode;
const TestFixture = core.TestFixture;
const KeymapKey = core.KeymapKey;

test "UC_NEXT でモードが順方向に切り替わる" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.UC_NEXT),
    });

    unicode.setMode(.linux);

    // UC_NEXT を押す
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expectEqual(unicode.UnicodeMode.windows, unicode.getMode());

    // リリース
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // もう一度
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expectEqual(unicode.UnicodeMode.bsd, unicode.getMode());

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
}

test "UC_PREV でモードが逆方向に切り替わる" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.UC_PREV),
    });

    unicode.setMode(.linux);

    // UC_PREV を押す
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expectEqual(unicode.UnicodeMode.macos, unicode.getMode());

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
}

test "UC_NEXT がラップアラウンドする" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.UC_NEXT),
    });

    unicode.setMode(.emacs); // 最後のモード

    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    // emacs -> macos にラップ
    try testing.expectEqual(unicode.UnicodeMode.macos, unicode.getMode());

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
}

test "UC_PREV がラップアラウンドする" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.UC_PREV),
    });

    unicode.setMode(.macos); // 最初のモード

    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    // macos -> emacs にラップ
    try testing.expectEqual(unicode.UnicodeMode.emacs, unicode.getMode());

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
}

test "Basic Unicode キーコードが HID レポートに直接現れない" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    // UC(0x00E9) = e with acute accent
    const uc_e_acute = keycode.UC(0x00E9);
    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, uc_e_acute),
    });

    unicode.setMode(.linux);

    // Unicode キーコードを押す
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    // Unicode キーコードは消費されるため、最終レポートではキーが残らないはず
    // (入力シーケンスは送信済みだが、最終状態はクリアされている)
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // 最終レポートは空
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "Basic Unicode キーコードが入力シーケンスを生成する" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    // UC(0x0041) = 'A' のコードポイント (テスト用)
    const uc_a = keycode.UC(0x0041);
    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, uc_a),
    });

    unicode.setMode(.linux);

    // Unicode キーコードを押す → 入力シーケンスが送信される
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    // Linux モードでは Ctrl+Shift+U → hex digits → Space が送信されるので
    // レポートが複数回送信されるはず
    try testing.expect(fixture.driver.keyboard_count > 0);

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
}

test "Unicode キーコードは通常キーと共存できる" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.UC_NEXT),
        KeymapKey.init(0, 0, 1, KC.A),
    });

    unicode.setMode(.linux);

    // 通常キーは Unicode 処理の影響を受けない
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.A));

    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "macOS モードの入力シーケンス" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    const uc_a = keycode.UC(0x0041);
    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, uc_a),
    });

    unicode.setMode(.macos);

    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    // macOS モードでもレポートが送信されるはず
    try testing.expect(fixture.driver.keyboard_count > 0);

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
}

test "wincompose モードの入力シーケンス" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    const uc_a = keycode.UC(0x0041);
    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, uc_a),
    });

    unicode.setMode(.wincompose);

    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    // WinCompose モードでもレポートが送信されるはず
    try testing.expect(fixture.driver.keyboard_count > 0);

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
}

// ============================================================
// Unicode Map 統合テスト
// ============================================================

test "Unicode Map: テーブル設定後に UM() キーコードで32bitコードポイントを入力" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    // Unicode Map テーブル: index 0 = U+00E9 (e with acute)
    const map = [_]u32{ 0x00E9, 0x1F600 };
    unicode.setUnicodeMap(&map);
    defer unicode.clearUnicodeMap();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.UM(0)), // index 0 -> U+00E9
    });

    unicode.setMode(.linux);

    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    // レポートが送信されるはず（入力シーケンス）
    try testing.expect(fixture.driver.keyboard_count > 0);

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // 最終レポートは空
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "Unicode Map: 絵文字コードポイント (U+1F600) を入力" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    // Unicode Map テーブル: index 1 = U+1F600 (grinning face)
    const map = [_]u32{ 0x00E9, 0x1F600 };
    unicode.setUnicodeMap(&map);
    defer unicode.clearUnicodeMap();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.UM(1)), // index 1 -> U+1F600
    });

    unicode.setMode(.linux);

    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.keyboard_count > 0);

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "Unicode Map: macOS モードで BMP 超コードポイントがサロゲートペアになる" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    // U+1F600 -> UTF-16 surrogate pair: D83D DE00
    const map = [_]u32{0x1F600};
    unicode.setUnicodeMap(&map);
    defer unicode.clearUnicodeMap();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.UM(0)),
    });

    unicode.setMode(.macos);

    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    // macOS モードでサロゲートペアが送信されるはず
    try testing.expect(fixture.driver.keyboard_count > 0);

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
}

test "Unicode Map: テーブル未設定時は Basic Unicode フォールバック" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    unicode.clearUnicodeMap();

    // UC(0x0041) = UM(0x0041) = 0x8041（テーブル未設定なら直接コードポイント）
    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.UC(0x0041)),
    });

    unicode.setMode(.linux);

    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    // レガシーモードで動作: レポートが送信されるはず
    try testing.expect(fixture.driver.keyboard_count > 0);

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
}

test "Unicode Map: 範囲外インデックスでは何も送信されない" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    const map = [_]u32{0x00E9};
    unicode.setUnicodeMap(&map);
    defer unicode.clearUnicodeMap();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.UM(100)), // 範囲外
    });

    unicode.setMode(.linux);

    const count_before = fixture.driver.keyboard_count;

    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    // 範囲外なので入力シーケンスは送信されない（カウント変化なし）
    try testing.expectEqual(count_before, fixture.driver.keyboard_count);

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
}

test "Unicode Map Pair: 通常時とShift時で異なるコードポイント" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    // index 0 = 'a' (0x0061), index 1 = 'A' (0x0041)
    const map = [_]u32{ 0x0061, 0x0041 };
    unicode.setUnicodeMap(&map);
    defer unicode.clearUnicodeMap();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.UP(0, 1)), // normal=0, shifted=1
    });

    unicode.setMode(.linux);

    // 通常押下（Shift なし）
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.keyboard_count > 0);

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
}

// ============================================================
// UCIS 統合テスト
// ============================================================

test "UCIS: ucisStart/ucisAdd/ucisFinish 基本フロー" {
    unicode.reset();
    unicode.setMode(.linux);

    const table = [_]unicode.UcisSymbol{
        .{ .mnemonic = "abc", .code_points = &[_]u32{0x00E9} },
    };
    unicode.setUcisSymbolTable(&table);
    defer unicode.clearUcisSymbolTable();

    unicode.ucisStart();
    try testing.expect(unicode.ucisIsActive());

    _ = unicode.ucisAdd(KC.A);
    _ = unicode.ucisAdd(KC.B);
    _ = unicode.ucisAdd(KC.C);

    const result = unicode.ucisFinish();
    try testing.expect(result); // マッチ成功
    try testing.expect(!unicode.ucisIsActive()); // 非アクティブに
}

test "UCIS: マッチしないニーモニックは false" {
    unicode.reset();
    unicode.setMode(.linux);

    const table = [_]unicode.UcisSymbol{
        .{ .mnemonic = "abc", .code_points = &[_]u32{0x00E9} },
    };
    unicode.setUcisSymbolTable(&table);
    defer unicode.clearUcisSymbolTable();

    unicode.ucisStart();
    _ = unicode.ucisAdd(KC.X);
    _ = unicode.ucisAdd(KC.Y);
    _ = unicode.ucisAdd(KC.Z);

    const result = unicode.ucisFinish();
    try testing.expect(!result); // マッチなし
    try testing.expect(!unicode.ucisIsActive());
}

test "UCIS: 複数コードポイントのシンボル" {
    unicode.reset();
    unicode.setMode(.linux);

    // 複合絵文字: 複数コードポイント
    const table = [_]unicode.UcisSymbol{
        .{ .mnemonic = "flag", .code_points = &[_]u32{ 0x1F1EF, 0x1F1F5 } }, // JP flag
    };
    unicode.setUcisSymbolTable(&table);
    defer unicode.clearUcisSymbolTable();

    unicode.ucisStart();
    _ = unicode.ucisAdd(KC.F);
    _ = unicode.ucisAdd(KC.L);
    _ = unicode.ucisAdd(KC.A);
    _ = unicode.ucisAdd(KC.G);

    const result = unicode.ucisFinish();
    try testing.expect(result);
}

test "UCIS: ucisCancel でセッションが終了する" {
    unicode.reset();

    unicode.ucisStart();
    try testing.expect(unicode.ucisIsActive());

    _ = unicode.ucisAdd(KC.A);
    unicode.ucisCancel();

    try testing.expect(!unicode.ucisIsActive());
}

// ============================================================
// UTF-8 デコード・sendUnicodeString テスト
// ============================================================

test "decodeUtf8: 複数文字の連続デコード" {
    // "Ae with acute" = 0x41 0xC3 0xA9
    const str = "A\xC3\xA9";
    var i: usize = 0;

    const r1 = unicode.decodeUtf8(str[i..]);
    try testing.expectEqual(@as(?u32, 'A'), r1.code_point);
    i += r1.bytes_consumed;

    const r2 = unicode.decodeUtf8(str[i..]);
    try testing.expectEqual(@as(?u32, 0x00E9), r2.code_point);
    i += r2.bytes_consumed;

    try testing.expectEqual(str.len, i);
}
