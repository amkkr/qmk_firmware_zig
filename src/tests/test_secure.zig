// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! Secure 機能の統合テスト
//!
//! C版 tests/secure/test_secure.cpp を Zig に移植。
//! TestFixture を使用して keyboard.zig パイプライン経由での動作を検証する。
//!
//! テスト設定（C版 tests/secure/config.h 相当）:
//!   SECURE_UNLOCK_SEQUENCE: {{0,1}, {0,2}, {0,3}, {0,4}}
//!   SECURE_UNLOCK_TIMEOUT: 20ms（TEST_UNLOCK_TIMEOUT → secure.unlock_timeout に設定）
//!   SECURE_IDLE_TIMEOUT: 50ms（TEST_IDLE_TIMEOUT → secure.idle_timeout に設定）

const std = @import("std");
const testing = std.testing;

const keycode = @import("../core/keycode.zig");
const report_mod = @import("../core/report.zig");
const test_fixture = @import("../core/test_fixture.zig");
const secure = @import("../core/secure.zig");
const action_code = @import("../core/action_code.zig");
const layer = @import("../core/layer.zig");
const timer = @import("../hal/timer.zig");
const tapping = @import("../core/action_tapping.zig");

const KC = keycode.KC;
const TestFixture = test_fixture.TestFixture;
const KeymapKey = test_fixture.KeymapKey;

// ============================================================
// テスト用設定（C版 tests/secure/config.h 相当）
// ============================================================
const TEST_UNLOCK_TIMEOUT: u32 = 20;
const TEST_IDLE_TIMEOUT: u32 = 50;

const TEST_UNLOCK_SEQUENCE = [_]secure.KeyPos{
    .{ .row = 0, .col = 1 },
    .{ .row = 0, .col = 2 },
    .{ .row = 0, .col = 3 },
    .{ .row = 0, .col = 4 },
};

/// テスト共通セットアップ（C版 Secure::SetUp() 相当）
fn setupFixture(fixture: *TestFixture) void {
    fixture.setup();
    timer.mockReset();
    secure.reset();
    secure.unlock_timeout = TEST_UNLOCK_TIMEOUT;
    secure.idle_timeout = TEST_IDLE_TIMEOUT;
    secure.setUnlockSequence(&TEST_UNLOCK_SEQUENCE);
    secure.lock(); // 初期状態: ロック
}

/// シーケンスキーをリストに従ってタップする（press + scan + release + scan）
fn tapKeys(fixture: *TestFixture, keys: []const KeymapKey) void {
    for (keys) |key| {
        fixture.pressKey(key.row, key.col);
        fixture.runOneScanLoop();
        fixture.releaseKey(key.row, key.col);
        fixture.runOneScanLoop();
    }
}

// ============================================================
// test_lock: ロック/アンロックの基本動作
// ============================================================

test "test_lock: secure_unlock/lock の基本動作" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
    });

    // 初期状態: ロック中
    try testing.expect(!secure.isUnlocked());

    // アンロック
    secure.unlock();
    try testing.expect(secure.isUnlocked());

    // スキャンループを回してもアンロック維持
    fixture.runOneScanLoop();
    try testing.expect(secure.isUnlocked());

    // 再ロック
    secure.lock();
    try testing.expect(!secure.isUnlocked());

    // レポートは送信されないはず
    try testing.expectEqual(@as(usize, 0), fixture.driver.keyboard_count);
}

// ============================================================
// test_unlock_timeout: アイドルタイムアウトでロックに戻る
// ============================================================

test "test_unlock_timeout: アイドルタイムアウトでロックに戻る" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
    });

    try testing.expect(!secure.isUnlocked());
    secure.unlock();
    try testing.expect(secure.isUnlocked());

    // IDLE_TIMEOUT + 1ms 進める
    fixture.idleFor(TEST_IDLE_TIMEOUT + 1);
    try testing.expect(!secure.isUnlocked());

    // レポートは送信されないはず
    try testing.expectEqual(@as(usize, 0), fixture.driver.keyboard_count);
}

// ============================================================
// test_unlock_request: 正しいシーケンスでアンロック
// ============================================================

test "test_unlock_request: 正しいシーケンスでアンロック" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.NO), // key_mo 相当（MO(1)は省略）
        KeymapKey.init(0, 0, 1, KC.A), // key_a
        KeymapKey.init(0, 0, 2, KC.B), // key_b
        KeymapKey.init(0, 0, 3, KC.C), // key_c
        KeymapKey.init(0, 0, 4, KC.D), // key_d
    });

    try testing.expect(secure.isLocked());
    secure.requestUnlock();
    try testing.expect(secure.isUnlocking());

    // シーケンスキーをタップ（アンロック中はレポートなし）
    tapKeys(&fixture, &.{
        KeymapKey.init(0, 0, 1, KC.A),
        KeymapKey.init(0, 0, 2, KC.B),
        KeymapKey.init(0, 0, 3, KC.C),
        KeymapKey.init(0, 0, 4, KC.D),
    });

    try testing.expect(secure.isUnlocked());

    // requestUnlock() の clearKeyboard() による空レポート1件のみ
    // シーケンスキー自体のレポートは送信されない
    try testing.expectEqual(@as(usize, 1), fixture.driver.keyboard_count);
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

// ============================================================
// test_unlock_request_fail: 最初のキーが間違うとフォールバック
// ============================================================

test "test_unlock_request_fail: 間違ったキーから始まるとアンロック失敗" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.E), // key_e: 間違ったキー
        KeymapKey.init(0, 0, 1, KC.A), // key_a
        KeymapKey.init(0, 0, 2, KC.B), // key_b
        KeymapKey.init(0, 0, 3, KC.C), // key_c
        KeymapKey.init(0, 0, 4, KC.D), // key_d
    });

    try testing.expect(secure.isLocked());
    secure.requestUnlock();
    try testing.expect(secure.isUnlocking());

    // key_e（間違ったキー）をタップ → ロックに戻る
    fixture.pressKey(0, 0); // key_e
    fixture.runOneScanLoop();
    // 間違いでLOCKEDに → その後のキーは通常処理される
    try testing.expect(secure.isLocked());
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // その後のキーは通常処理（KC_A, KC_B, KC_C, KC_D がレポートに含まれる）
    tapKeys(&fixture, &.{
        KeymapKey.init(0, 0, 1, KC.A),
        KeymapKey.init(0, 0, 2, KC.B),
        KeymapKey.init(0, 0, 3, KC.C),
        KeymapKey.init(0, 0, 4, KC.D),
    });

    try testing.expect(!secure.isUnlocked());

    // 通常キーのレポートが送信される
    try testing.expect(fixture.driver.keyboard_count > 0);
}

// ============================================================
// test_unlock_request_timeout: アンロックリクエストのタイムアウト
// ============================================================

test "test_unlock_request_timeout: PENDING 中にタイムアウトするとロックに戻る" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.A),
    });

    try testing.expect(!secure.isUnlocked());
    secure.requestUnlock();
    try testing.expect(secure.isUnlocking());

    // タイムアウト後
    fixture.idleFor(TEST_UNLOCK_TIMEOUT + 1);
    try testing.expect(!secure.isUnlocking());
    try testing.expect(!secure.isUnlocked());

    // requestUnlock() の clearKeyboard() による空レポート1件のみ
    try testing.expectEqual(@as(usize, 1), fixture.driver.keyboard_count);
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}

// ============================================================
// test_unlock_request_fail_mid: シーケンス途中での間違い
// ============================================================

test "test_unlock_request_fail_mid: シーケンス途中で間違えるとアンロック失敗" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.E), // key_e: 間違ったキー
        KeymapKey.init(0, 0, 1, KC.A), // key_a (row=0, col=1)
        KeymapKey.init(0, 0, 2, KC.B), // key_b (row=0, col=2)
        KeymapKey.init(0, 0, 3, KC.C), // key_c (row=0, col=3)
        KeymapKey.init(0, 0, 4, KC.D), // key_d (row=0, col=4)
    });

    secure.requestUnlock();
    try testing.expect(secure.isUnlocking());

    // シーケンス: A, B は正しい、E（col=0）で間違え
    fixture.pressKey(0, 1); // key_a → sequence[0] 正しい
    fixture.runOneScanLoop();
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();
    try testing.expect(secure.isUnlocking()); // まだ PENDING

    fixture.pressKey(0, 2); // key_b → sequence[1] 正しい
    fixture.runOneScanLoop();
    fixture.releaseKey(0, 2);
    fixture.runOneScanLoop();
    try testing.expect(secure.isUnlocking()); // まだ PENDING

    fixture.pressKey(0, 0); // key_e → 間違い → LOCKED
    fixture.runOneScanLoop();
    try testing.expect(secure.isLocked());
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // その後のキーは通常処理
    tapKeys(&fixture, &.{
        KeymapKey.init(0, 0, 3, KC.C),
        KeymapKey.init(0, 0, 4, KC.D),
    });

    try testing.expect(!secure.isUnlocking());
    try testing.expect(!secure.isUnlocked());

    // C, D のレポートが送信される
    try testing.expect(fixture.driver.keyboard_count > 0);
}

// ============================================================
// test_unlock_request_fail_out_of_order: 順序違いでのアンロック失敗
// ============================================================

test "test_unlock_request_fail_out_of_order: 順序が違うとアンロック失敗" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.E), // key_e
        KeymapKey.init(0, 0, 1, KC.A), // key_a
        KeymapKey.init(0, 0, 2, KC.B), // key_b
        KeymapKey.init(0, 0, 3, KC.C), // key_c
        KeymapKey.init(0, 0, 4, KC.D), // key_d
    });

    secure.requestUnlock();
    try testing.expect(secure.isUnlocking());

    // A は正しいが D を先に押してしまう（順序違い）
    fixture.pressKey(0, 1); // key_a → sequence[0] 正しい
    fixture.runOneScanLoop();
    fixture.releaseKey(0, 1);
    fixture.runOneScanLoop();

    fixture.pressKey(0, 4); // key_d → sequence[1] 期待は col=2、間違い
    fixture.runOneScanLoop();
    try testing.expect(secure.isLocked()); // 間違いでLOCKED
    fixture.releaseKey(0, 4);
    fixture.runOneScanLoop();

    // その後のキーは通常処理
    tapKeys(&fixture, &.{
        KeymapKey.init(0, 0, 2, KC.B),
        KeymapKey.init(0, 0, 3, KC.C),
    });

    try testing.expect(secure.isLocked());
    try testing.expect(!secure.isUnlocking());
    try testing.expect(!secure.isUnlocked());

    // B, C のレポートが送信される
    try testing.expect(fixture.driver.keyboard_count > 0);
}

// ============================================================
// test_unlock_request_mid_stroke: キー押下中にリクエストが発行される
// ============================================================

test "test_unlock_request_mid_stroke: キー押下中のリクエスト発行" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.E), // key_e
        KeymapKey.init(0, 0, 1, KC.A), // key_a
        KeymapKey.init(0, 0, 2, KC.B), // key_b
        KeymapKey.init(0, 0, 3, KC.C), // key_c
        KeymapKey.init(0, 0, 4, KC.D), // key_d
    });

    try testing.expect(secure.isLocked());

    // key_e を押す（まだ LOCKED → 通常処理 → レポートにEが出る）
    fixture.pressKey(0, 0); // key_e
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.keyboard_count >= 1);
    try testing.expect(fixture.driver.lastKeyboardReport().hasKey(@truncate(KC.E)));

    // 押したまま secure_request_unlock() 発行 → PENDING
    secure.requestUnlock();

    // key_e を離す（PENDING 中 → release イベントはブロック）
    fixture.releaseKey(0, 0); // key_e release
    fixture.runOneScanLoop();
    try testing.expect(secure.isUnlocking());

    // 正しいシーケンスをタップ → アンロック
    tapKeys(&fixture, &.{
        KeymapKey.init(0, 0, 1, KC.A),
        KeymapKey.init(0, 0, 2, KC.B),
        KeymapKey.init(0, 0, 3, KC.C),
        KeymapKey.init(0, 0, 4, KC.D),
    });
    try testing.expect(secure.isUnlocked());

    // key_e のプレスレポートと空レポートが送信済み
    // （アンロック後のシーケンスキーのリリースは処理されるが、プレスが無いので空）
    try testing.expect(fixture.driver.keyboard_count >= 1);
}

// ============================================================
// test_unlock_request_mods: モッドキー押下中のリクエスト
// ============================================================

test "test_unlock_request_mods: モッドキー押下中にリクエスト発行" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, KC.LEFT_SHIFT), // key_lsft
        KeymapKey.init(0, 0, 1, KC.A), // key_a
        KeymapKey.init(0, 0, 2, KC.B), // key_b
        KeymapKey.init(0, 0, 3, KC.C), // key_c
        KeymapKey.init(0, 0, 4, KC.D), // key_d
    });

    try testing.expect(secure.isLocked());

    // LSHIFT を押す → SHIFTレポートが出る
    fixture.pressKey(0, 0); // key_lsft
    fixture.runOneScanLoop();
    try testing.expect(fixture.driver.keyboard_count >= 1);
    try testing.expect(fixture.driver.lastKeyboardReport().mods & report_mod.ModBit.LSHIFT != 0);

    // PENDING 状態に → clearKeyboard() で LSHIFT がクリアされる
    secure.requestUnlock();

    // requestUnlock() 後のスキャンで空レポートが送信されることを確認
    // （clearKeyboard により real_mods がクリアされている）
    fixture.runOneScanLoop();
    try testing.expectEqual(@as(u8, 0), fixture.driver.lastKeyboardReport().mods);

    // LSHIFT を離す（PENDING 中 → ブロック、シーケンス照合には使われない）
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(secure.isUnlocking());

    // 正しいシーケンスでアンロック
    tapKeys(&fixture, &.{
        KeymapKey.init(0, 0, 1, KC.A),
        KeymapKey.init(0, 0, 2, KC.B),
        KeymapKey.init(0, 0, 3, KC.C),
        KeymapKey.init(0, 0, 4, KC.D),
    });
    try testing.expect(secure.isUnlocked());
}

// ============================================================
// test_unlock_request_on_layer: レイヤーキー押下中のリクエスト
// ============================================================

test "test_unlock_request_on_layer: MO() 押下中にリクエスト発行するとレイヤーがクリアされる" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.MO(1)), // MO(1)
        KeymapKey.init(0, 0, 1, KC.A), // key_a
        KeymapKey.init(0, 0, 2, KC.B), // key_b
        KeymapKey.init(0, 0, 3, KC.C), // key_c
        KeymapKey.init(0, 0, 4, KC.D), // key_d
    });

    try testing.expect(secure.isLocked());

    // MO(1) を押す
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();

    // TAPPING_TERM を超えてホールド確定
    fixture.idleFor(tapping.TAPPING_TERM + 1);
    try testing.expect(layer.layerStateIs(1));

    // requestUnlock() → layerClear() でレイヤーがクリアされる
    secure.requestUnlock();
    try testing.expect(secure.isUnlocking());
    try testing.expect(!layer.layerStateIs(1));

    // MO(1) を離す（PENDING 中 → ブロック）
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    // 正しいシーケンスでアンロック
    tapKeys(&fixture, &.{
        KeymapKey.init(0, 0, 1, KC.A),
        KeymapKey.init(0, 0, 2, KC.B),
        KeymapKey.init(0, 0, 3, KC.C),
        KeymapKey.init(0, 0, 4, KC.D),
    });
    try testing.expect(secure.isUnlocked());
    try testing.expect(!layer.layerStateIs(1)); // レイヤーはクリアされたまま
}

// ============================================================
// QK_SECURE_* キーコードの処理テスト
// ============================================================

test "QK_SECURE_LOCK キーでロック" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.QK_SECURE_LOCK),
    });

    secure.unlock();
    try testing.expect(secure.isUnlocked());

    // QK_SECURE_LOCK をタップ → release 時にロック
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(secure.isLocked());
    // レポートは送信されないはず
    try testing.expectEqual(@as(usize, 0), fixture.driver.keyboard_count);
}

test "QK_SECURE_UNLOCK キーでアンロック" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.QK_SECURE_UNLOCK),
    });

    try testing.expect(secure.isLocked());

    // QK_SECURE_UNLOCK をタップ → release 時にアンロック
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();

    try testing.expect(secure.isUnlocked());
    try testing.expectEqual(@as(usize, 0), fixture.driver.keyboard_count);
}

test "QK_SECURE_TOGGLE キーでトグル" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.QK_SECURE_TOGGLE),
    });

    try testing.expect(secure.isLocked());

    // ロック → アンロック
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(secure.isUnlocked());

    // アンロック → ロック
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(secure.isLocked());

    try testing.expectEqual(@as(usize, 0), fixture.driver.keyboard_count);
}

test "QK_SECURE_REQUEST キーでアンロックリクエスト" {
    var fixture = TestFixture.init();
    setupFixture(&fixture);
    defer fixture.deinit();

    fixture.setKeymap(&.{
        KeymapKey.init(0, 0, 0, keycode.QK_SECURE_REQUEST),
        KeymapKey.init(0, 0, 1, KC.A),
        KeymapKey.init(0, 0, 2, KC.B),
        KeymapKey.init(0, 0, 3, KC.C),
        KeymapKey.init(0, 0, 4, KC.D),
    });

    try testing.expect(secure.isLocked());

    // QK_SECURE_REQUEST をタップ → PENDING
    fixture.pressKey(0, 0);
    fixture.runOneScanLoop();
    fixture.releaseKey(0, 0);
    fixture.runOneScanLoop();
    try testing.expect(secure.isUnlocking());

    // 正しいシーケンス → アンロック
    tapKeys(&fixture, &.{
        KeymapKey.init(0, 0, 1, KC.A),
        KeymapKey.init(0, 0, 2, KC.B),
        KeymapKey.init(0, 0, 3, KC.C),
        KeymapKey.init(0, 0, 4, KC.D),
    });
    try testing.expect(secure.isUnlocked());

    // requestUnlock() の clearKeyboard() による空レポート1件のみ
    try testing.expectEqual(@as(usize, 1), fixture.driver.keyboard_count);
    try testing.expect(fixture.driver.lastKeyboardReport().isEmpty());
}
