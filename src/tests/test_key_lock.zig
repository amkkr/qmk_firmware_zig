// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! test_key_lock.zig — Key Lock 統合テスト
//!
//! TestFixture を使用してキーマップ経由の QK_LOCK パイプラインを検証する。
//! QK_LOCK → 次のキー → そのキーがロック（押しっぱなし）される動作を
//! アクション解決パイプライン経由で検証する。

const std = @import("std");
const testing = std.testing;
const keycode = @import("../core/keycode.zig");
const report_mod = @import("../core/report.zig");
const test_fixture = @import("../core/test_fixture.zig");

const KC = keycode.KC;
const TestFixture = test_fixture.TestFixture;
const KeymapKey = test_fixture.KeymapKey;

test "QK_LOCK then key press locks the key" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.QK_LOCK),
        KeymapKey.init(0, 0, 1, KC.A),
    });

    // QK_LOCK を押す→リリース（watching 状態にする）
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // KC_A を押す → ロックされる
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.A));

    // KC_A をリリースしても、ロックされているので A は維持される
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.A));

    // 再度 KC_A を押してリリース → ロック解除
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();

    try testing.expect(!fixture.driver.lastKeyboardReport().hasKey(KC.A));
}

test "QK_LOCK pressed twice cancels watching" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.QK_LOCK),
        KeymapKey.init(0, 0, 1, KC.B),
    });

    // QK_LOCK を2回押す（watching をトグルして解除）
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // KC_B を押す → 通常動作（ロックされない）
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(KC.B));

    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();
    try testing.expect(!fixture.driver.lastKeyboardReport().hasKey(KC.B));
}
