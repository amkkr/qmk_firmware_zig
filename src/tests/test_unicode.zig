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
