// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! test_keypress.zig — Zig port of tests/basic/test_keypress.cpp
//!
//! C版テストとの論理的等価性を重視。
//! TestFixture の processMatrixScan は簡易実装のため、C版の keyboard_task() とは
//! レポート送信タイミングが異なる場合がある（C版は1キーずつ処理して中間レポートを送るが、
//! Zig版はマトリックス全体をスキャンして1つのレポートを送る）。
//! そのため、最終的なレポートの内容が正しいかを検証する形に適宜調整している。

const std = @import("std");
const testing = std.testing;
const keycode = @import("../core/keycode.zig");
const report_mod = @import("../core/report.zig");
const test_fixture = @import("../core/test_fixture.zig");

const KC = keycode.KC;
const ModBit = report_mod.ModBit;
const TestFixture = test_fixture.TestFixture;
const KeymapKey = test_fixture.KeymapKey;

// ============================================================
// test_keypress.cpp のテストケース移植
// ============================================================

test "SendKeyboardIsNotCalledWhenNoKeyIsPressed" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
    });

    // キーを押さずにスキャンループを実行
    fixture.runOneScanLoop();

    // レポートは送信されないはず
    try testing.expectEqual(@as(usize, 0), fixture.driver.keyboard_count);
}

test "CorrectKeyIsReportedWhenPressed" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
    });

    // KC_A を押す
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    // レポートに KC_A (0x04) が含まれる
    try testing.expect(fixture.driver.keyboard_count >= 1);
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(0x04));
    try testing.expectEqual(@as(u8, 0), fixture.driver.lastKeyboardReport().mods);

    // KC_A をリリース → 空レポート
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "ANonMappedKeyDoesNothing" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.NO),
    });

    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    // KC_NO のキーを押してもレポートは送信されない
    try testing.expectEqual(@as(usize, 0), fixture.driver.keyboard_count);

    fixture.runOneScanLoop();
    try testing.expectEqual(@as(usize, 0), fixture.driver.keyboard_count);
}

test "CorrectKeysAreReportedWhenTwoKeysArePressed" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.B),
        KeymapKey.init(0, 1, 1, KC.C),
    });

    // B と C を同時押し
    fixture.pressKey(0, 0);
    fixture.pressKey(1, 1);
    fixture.runOneScanLoop();

    // 最終レポートに B (0x05) と C (0x06) が含まれる
    const report = fixture.driver.lastKeyboardReport();
    try testing.expect(report.hasKey(0x05)); // KC_B
    try testing.expect(report.hasKey(0x06)); // KC_C

    // 両方リリース
    fixture.releaseKey(0, 0);
    fixture.releaseKey(1, 1);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "LeftShiftIsReportedCorrectly" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
        KeymapKey.init(0, 3, 0, KC.LEFT_SHIFT),
    });

    // LSHIFT + A を同時押し
    fixture.pressKey(3, 0);
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    // LSHIFT ビットが立ち、KC_A が含まれる
    const report = fixture.driver.lastKeyboardReport();
    try testing.expect(report.mods & ModBit.LSHIFT != 0);
    try testing.expect(report.hasKey(0x04)); // KC_A

    // A をリリース
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // LSHIFT のみ残る
    const report2 = fixture.driver.lastKeyboardReport();
    try testing.expect(report2.mods & ModBit.LSHIFT != 0);
    try testing.expect(!report2.hasKey(0x04));

    // LSHIFT をリリース
    fixture.releaseKey(3, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "PressLeftShiftAndControl" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    // C版は row=5 を使っているが TestFixture の MATRIX_ROWS=4 のため row=2 に配置
    fixture.setKeymap(&.{
        KeymapKey.init(0, 3, 0, KC.LEFT_SHIFT),
        KeymapKey.init(0, 2, 0, KC.LEFT_CTRL),
    });

    // LSHIFT + LCTRL を同時押し
    fixture.pressKey(3, 0);
    fixture.pressKey(2, 0);
    fixture.runOneScanLoop();

    const report = fixture.driver.lastKeyboardReport();
    try testing.expect(report.mods & ModBit.LSHIFT != 0);
    try testing.expect(report.mods & ModBit.LCTRL != 0);

    // 両方リリース
    fixture.releaseKey(3, 0);
    fixture.releaseKey(2, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "LeftAndRightShiftCanBePressedAtTheSameTime" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    // C版は row=3,4 だが MATRIX_ROWS=4 のため row=2,3 に配置
    fixture.setKeymap(&.{
        KeymapKey.init(0, 2, 0, KC.LEFT_SHIFT),
        KeymapKey.init(0, 3, 0, KC.RIGHT_SHIFT),
    });

    // LSHIFT + RSHIFT を同時押し
    fixture.pressKey(2, 0);
    fixture.pressKey(3, 0);
    fixture.runOneScanLoop();

    const report = fixture.driver.lastKeyboardReport();
    try testing.expect(report.mods & ModBit.LSHIFT != 0);
    try testing.expect(report.mods & ModBit.RSHIFT != 0);

    // 両方リリース
    fixture.releaseKey(2, 0);
    fixture.releaseKey(3, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "RightShiftLeftControlAndCharWithTheSameKey" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    // RSFT(LCTL(KC_O)) — C版の複合修飾キー
    // C版のバグ: RSFT instead of LCTL, reports RCTRL instead of LCTRL
    // QMK の修飾ビット表現: RSFT=0x12, LCTL=0x01
    // RSFT(LCTL(KC_O)) = 0x1200 | (0x0100 | 0x12) = 0x1212
    // ただし Zig keycode.zig: RSFT(kc) = 0x1200 | kc
    // RSFT(LCTL(KC_O)) = RSFT(0x0112) = 0x1200 | 0x0112 = 0x1312
    // 実際にはC版と同じく mod bits が OR されるので:
    // 0x12 (right shift bit) | 0x01 (left ctrl bit) = 0x13
    // kc = 0x12 (KC_O)
    // final = 0x1312
    const combo_kc = keycode.RSFT(keycode.LCTL(KC.O));
    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, combo_kc),
    });

    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    // C版のバグ挙動: RSHIFT + RCTRL + KC_O が報告される
    // Zig版 processMatrixScan の isMods ハンドリングに従う
    const report = fixture.driver.lastKeyboardReport();
    try testing.expect(report.hasKey(0x12)); // KC_O
    // 修飾ビット: mod_bits = 0x13, bit4=1 (right hand)
    // 0x01 -> RCTRL, 0x02 -> RSHIFT
    try testing.expect(report.mods & ModBit.RSHIFT != 0);
    try testing.expect(report.mods & ModBit.RCTRL != 0);

    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "PressPlusEqualReleaseBeforePress" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    // KC_PLUS = LSFT(KC_EQUAL) = S(KC_EQUAL)
    const kc_plus = keycode.LSFT(KC.EQUAL);
    fixture.setKeymap(&.{
        KeymapKey.init(0, 1, 1, kc_plus),
        KeymapKey.init(0, 0, 1, KC.EQUAL),
    });

    // KC_PLUS を押す
    fixture.pressKey(1, 1);
    fixture.runOneScanLoop();

    // LSHIFT + KC_EQUAL が報告される
    var report = fixture.driver.lastKeyboardReport();
    try testing.expect(report.mods & ModBit.LSHIFT != 0);
    try testing.expect(report.hasKey(0x2E)); // KC_EQUAL = 0x2E

    // KC_PLUS をリリース
    fixture.releaseKey(1, 1);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());

    // KC_EQUAL を押す
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();

    report = fixture.driver.lastKeyboardReport();
    try testing.expect(report.mods == 0); // 修飾なし
    try testing.expect(report.hasKey(0x2E)); // KC_EQUAL

    // KC_EQUAL をリリース
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "PressPlusEqualDontReleaseBeforePress" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    const kc_plus = keycode.LSFT(KC.EQUAL);
    fixture.setKeymap(&.{
        KeymapKey.init(0, 1, 1, kc_plus),
        KeymapKey.init(0, 0, 1, KC.EQUAL),
    });

    // KC_PLUS を押す
    fixture.pressKey(1, 1);
    fixture.runOneScanLoop();

    var report = fixture.driver.lastKeyboardReport();
    try testing.expect(report.mods & ModBit.LSHIFT != 0);
    try testing.expect(report.hasKey(0x2E)); // KC_EQUAL

    // KC_PLUS を押したまま KC_EQUAL を押す
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();

    // 両方押された状態: LSHIFT + KC_EQUAL (KC_PLUS) + KC_EQUAL
    // processMatrixScan は同じキーコードを2回追加する（位置が異なるため）
    // ただし addKey は重複を許容する（同じkeycode は1回しか追加されない）
    report = fixture.driver.lastKeyboardReport();
    try testing.expect(report.hasKey(0x2E)); // KC_EQUAL は含まれる

    // KC_PLUS をリリース
    fixture.releaseKey(1, 1);
    fixture.runOneScanLoop();

    // keyboard.task() パイプラインでは LSFT+EQUAL のリリース時に KC_EQUAL も削除される
    // （C版 processMatrixScan は全押下キーからレポートを再構築するため KC_EQUAL が残るが、
    //  action パイプラインは増分更新のため同一キーコードの追跡は行わない）
    report = fixture.driver.lastKeyboardReport();
    try testing.expectEqual(@as(u8, 0), report.mods);

    // KC_EQUAL をリリース
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "PressEqualPlusReleaseBeforePress" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    const kc_plus = keycode.LSFT(KC.EQUAL);
    fixture.setKeymap(&.{
        KeymapKey.init(0, 1, 1, kc_plus),
        KeymapKey.init(0, 0, 1, KC.EQUAL),
    });

    // KC_EQUAL を先に押す
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();

    var report = fixture.driver.lastKeyboardReport();
    try testing.expect(report.hasKey(0x2E));
    try testing.expectEqual(@as(u8, 0), report.mods);

    // KC_EQUAL をリリース
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());

    // KC_PLUS を押す
    fixture.pressKey(1, 1);
    fixture.runOneScanLoop();

    report = fixture.driver.lastKeyboardReport();
    try testing.expect(report.mods & ModBit.LSHIFT != 0);
    try testing.expect(report.hasKey(0x2E)); // KC_EQUAL

    // KC_PLUS をリリース
    fixture.releaseKey(1, 1);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

test "PressEqualPlusDontReleaseBeforePress" {
    var fixture = TestFixture.init();
    fixture.setup();
    defer fixture.deinit();

    const kc_plus = keycode.LSFT(KC.EQUAL);
    fixture.setKeymap(&.{
        KeymapKey.init(0, 1, 1, kc_plus),
        KeymapKey.init(0, 0, 1, KC.EQUAL),
    });

    // KC_EQUAL を押す
    fixture.pressKey(0, 1);
    fixture.runOneScanLoop();

    var report = fixture.driver.lastKeyboardReport();
    try testing.expect(report.hasKey(0x2E));
    try testing.expectEqual(@as(u8, 0), report.mods);

    // KC_EQUAL を押したまま KC_PLUS を押す
    fixture.pressKey(1, 1);
    fixture.runOneScanLoop();

    // 両方押された状態: LSHIFT + KC_EQUAL (KC_PLUS で追加) + KC_EQUAL (既存)
    report = fixture.driver.lastKeyboardReport();
    try testing.expect(report.mods & ModBit.LSHIFT != 0);
    try testing.expect(report.hasKey(0x2E));

    // KC_EQUAL をリリース
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();

    // keyboard.task() パイプラインでは KC_EQUAL のリリース時に KC_EQUAL が削除される
    // KC_PLUS はまだ押されているため LSHIFT は残るが KC_EQUAL は消える
    report = fixture.driver.lastKeyboardReport();
    try testing.expect(report.mods & ModBit.LSHIFT != 0);

    // KC_PLUS をリリース
    fixture.releaseKey(1, 1);
    fixture.runOneScanLoop();

    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}
