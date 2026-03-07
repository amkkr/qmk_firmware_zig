// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! test_grave_esc.zig — Grave Escape 統合テスト
//!
//! TestFixture を使用してキーマップ経由の QK_GESC パイプラインを検証する。
//! インラインテスト（grave_esc.zig 内）は関数単体テスト、
//! ここではアクション解決パイプライン経由のエンドツーエンドテスト。

const std = @import("std");
const testing = std.testing;
const keycode = @import("../core/keycode.zig");
const test_fixture = @import("../core/test_fixture.zig");

const KC = keycode.KC;
const TestFixture = test_fixture.TestFixture;
const KeymapKey = test_fixture.KeymapKey;

test "QK_GESC in keymap sends ESC without modifiers" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.QK_GESC),
    });

    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.keyboard_count >= 1);
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.ESCAPE));
    try testing.expect(!fixture.driver.lastKeyboardReport().hasKey(KC.GRAVE));

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(!fixture.driver.lastKeyboardReport().hasKey(KC.ESCAPE));
}

test "QK_GESC in keymap sends GRAVE when SHIFT is held" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.LEFT_SHIFT),
        KeymapKey.init(0, 0, 1, keycode.QK_GESC),
    });

    // SHIFT を押す
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    // QK_GESC を押す → GRAVE が送信されるはず
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.GRAVE));
    try testing.expect(!fixture.driver.lastKeyboardReport().hasKey(KC.ESCAPE));

    // QK_GESC をリリース
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();

    try testing.expect(!fixture.driver.lastKeyboardReport().hasKey(KC.GRAVE));

    // SHIFT をリリース
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
}

test "QK_GESC in keymap sends GRAVE when GUI is held" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.LEFT_GUI),
        KeymapKey.init(0, 0, 1, keycode.QK_GESC),
    });

    // GUI を押す
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    // QK_GESC を押す → GRAVE が送信されるはず
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.GRAVE));
    try testing.expect(!fixture.driver.lastKeyboardReport().hasKey(KC.ESCAPE));

    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
}
