// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zig port of quantum/secure.c
// Original: Copyright 2022 QMK

//! Secure 機能
//! C版 quantum/secure.c + quantum/process_keycode/process_secure.c に相当
//!
//! デバイスの仮想パドロック機能。一定時間操作がないと自動ロックし、
//! 特定のキーシーケンスでアンロックする。
//!
//! 状態遷移:
//!   LOCKED → (request_unlock) → PENDING → (正しいシーケンス) → UNLOCKED
//!                                       → (不正シーケンス/タイムアウト) → LOCKED
//!   UNLOCKED → (idle タイムアウト) → LOCKED
//!   UNLOCKED → (lock) → LOCKED
//!
//! C版との差異:
//! - secure_hook_user() / secure_hook_kb() (weak 関数): 省略
//! - SECURE_UNLOCK_SEQUENCE はランタイムで setUnlockSequence() により設定

const timer = @import("../hal/timer.zig");
const keycode_mod = @import("keycode.zig");
const Keycode = keycode_mod.Keycode;
const host = @import("host.zig");
const layer = @import("layer.zig");

/// セキュア状態
pub const SecureStatus = enum {
    locked,
    pending,
    unlocked,
};

/// アンロックシーケンスのキー位置（row, col ペア）
pub const KeyPos = struct {
    row: u8,
    col: u8,
};

// ============================================================
// 設定定数
// ============================================================

/// アンロックシーケンスのタイムアウト（ミリ秒）
/// PENDING 状態がこの時間を超えると LOCKED に戻る。
/// 0 の場合はタイムアウトなし。
pub var unlock_timeout: u32 = 5000;

/// アイドルタイムアウト（ミリ秒）
/// UNLOCKED 状態でこの時間操作がないと LOCKED に戻る。
/// 0 の場合はタイムアウトなし。
pub var idle_timeout: u32 = 60000;

// ============================================================
// 状態変数
// ============================================================

var status: SecureStatus = .locked;
var unlock_time: u32 = 0;
var idle_time: u32 = 0;

/// アンロックシーケンス
var unlock_sequence: []const KeyPos = &default_sequence;
var sequence_offset: u8 = 0;

const default_sequence = [_]KeyPos{.{ .row = 0, .col = 0 }};

// ============================================================
// 状態クエリ
// ============================================================

pub fn getStatus() SecureStatus {
    return status;
}

pub fn isLocked() bool {
    return status == .locked;
}

pub fn isUnlocking() bool {
    return status == .pending;
}

pub fn isUnlocked() bool {
    return status == .unlocked;
}

// ============================================================
// 状態操作
// ============================================================

/// デバイスをロックする
pub fn lock() void {
    status = .locked;
    sequence_offset = 0;
}

/// デバイスを強制アンロックする（シーケンスをバイパス）
pub fn unlock() void {
    status = .unlocked;
    idle_time = timer.read32();
    sequence_offset = 0;
}

/// アンロックシーケンスの受付を開始する
/// LOCKED 状態のときのみ PENDING に遷移する。
/// C版と同様に、押下中のキー・修飾キー・レイヤーをクリアして
/// PENDING 中にスタックするのを防ぐ。
pub fn requestUnlock() void {
    if (status == .locked) {
        status = .pending;
        unlock_time = timer.read32();
        sequence_offset = 0;
        host.clearKeyboard();
        layer.layerClear();
    }
}

/// ユーザーアクティビティを通知する（アイドルタイマーをリセット）
pub fn activityEvent() void {
    if (status == .unlocked) {
        idle_time = timer.read32();
    }
}

/// キー押下イベントを処理し、アンロックシーケンスを検証する
/// PENDING 状態でのみ意味がある。
pub fn keypressEvent(row: u8, col: u8) void {
    if (unlock_sequence.len == 0) return;

    if (sequence_offset < unlock_sequence.len and
        unlock_sequence[sequence_offset].row == row and
        unlock_sequence[sequence_offset].col == col)
    {
        sequence_offset += 1;
        if (sequence_offset >= unlock_sequence.len) {
            sequence_offset = 0;
            unlock();
        }
    } else {
        sequence_offset = 0;
        lock();
    }
}

// ============================================================
// バックグラウンドタスク
// ============================================================

/// タイムアウト処理。keyboard.zig の task() から毎スキャン呼ばれる。
pub fn task() void {
    // アンロックシーケンスのタイムアウト
    if (unlock_timeout != 0 and status == .pending) {
        if (timer.elapsed32(unlock_time) >= unlock_timeout) {
            lock();
        }
    }

    // アイドルタイムアウト
    if (idle_timeout != 0 and status == .unlocked) {
        if (timer.elapsed32(idle_time) >= idle_timeout) {
            lock();
        }
    }
}

// ============================================================
// キーコード処理
// C版 process_secure.c の preprocess_secure() + process_secure() に相当
// ============================================================

/// キーコード処理: SE_LOCK/SE_UNLK/SE_TOGG/SE_REQ を処理する。
/// C版ではリリース時に処理する。
/// 戻り値: true = 通常処理続行, false = キーを消費
pub fn processKeycode(kc: Keycode, pressed: bool) bool {
    if (!pressed) {
        if (kc == keycode_mod.SE_LOCK) {
            lock();
            return false;
        }
        if (kc == keycode_mod.SE_UNLK) {
            unlock();
            return false;
        }
        if (kc == keycode_mod.SE_TOGG) {
            if (isLocked()) {
                unlock();
            } else {
                lock();
            }
            return false;
        }
        if (kc == keycode_mod.SE_REQ) {
            requestUnlock();
            return false;
        }
    }
    return true;
}

// ============================================================
// 設定 / リセット
// ============================================================

/// アンロックシーケンスを設定する
pub fn setUnlockSequence(sequence: []const KeyPos) void {
    unlock_sequence = sequence;
}

/// 全状態をリセットする
pub fn reset() void {
    status = .locked;
    unlock_time = 0;
    idle_time = 0;
    sequence_offset = 0;
    unlock_sequence = &default_sequence;
    unlock_timeout = 5000;
    idle_timeout = 60000;
}

// ============================================================
// テスト
// ============================================================

const std = @import("std");
const testing = std.testing;
const FixedTestDriver = @import("test_driver.zig").FixedTestDriver;
const TestMockDriver = FixedTestDriver(128, 16);

/// テスト用アンロックシーケンス: (0,1), (0,2), (0,3), (0,4)
/// C版 tests/secure/config.h の SECURE_UNLOCK_SEQUENCE に相当
const test_sequence = [_]KeyPos{
    .{ .row = 0, .col = 1 },
    .{ .row = 0, .col = 2 },
    .{ .row = 0, .col = 3 },
    .{ .row = 0, .col = 4 },
};

fn setupTest() *TestMockDriver {
    const mock = struct {
        var driver: TestMockDriver = .{};
    };
    mock.driver = .{};
    host.hostReset();
    host.setDriver(host.HostDriver.from(&mock.driver));
    timer.mockReset();
    reset();
    setUnlockSequence(&test_sequence);
    unlock_timeout = 20;
    idle_timeout = 50;
    lock();
    return &mock.driver;
}

fn teardownTest() void {
    host.clearDriver();
}

test "lock/unlock 基本操作" {
    _ = setupTest();
    defer teardownTest();

    try testing.expect(!isUnlocked());
    unlock();
    try testing.expect(isUnlocked());
    lock();
    try testing.expect(!isUnlocked());
}

test "アイドルタイムアウトでロック" {
    _ = setupTest();
    defer teardownTest();

    try testing.expect(!isUnlocked());
    unlock();
    try testing.expect(isUnlocked());
    timer.mockAdvance(idle_timeout + 1);
    task();
    try testing.expect(!isUnlocked());
}

test "アンロックリクエスト: 正しいシーケンスでアンロック" {
    _ = setupTest();
    defer teardownTest();

    try testing.expect(isLocked());
    requestUnlock();
    try testing.expect(isUnlocking());
    keypressEvent(0, 1);
    keypressEvent(0, 2);
    keypressEvent(0, 3);
    keypressEvent(0, 4);
    try testing.expect(isUnlocked());
}

test "アンロックリクエスト: 最初のキーが不正でロック" {
    _ = setupTest();
    defer teardownTest();

    try testing.expect(isLocked());
    requestUnlock();
    try testing.expect(isUnlocking());
    // 不正なキー (0,0) を押す
    keypressEvent(0, 0);
    try testing.expect(isLocked());
    try testing.expect(!isUnlocking());
}

test "アンロックリクエスト: タイムアウトでロック" {
    _ = setupTest();
    defer teardownTest();

    try testing.expect(!isUnlocked());
    requestUnlock();
    try testing.expect(isUnlocking());
    timer.mockAdvance(unlock_timeout + 1);
    task();
    try testing.expect(!isUnlocking());
    try testing.expect(!isUnlocked());
}

test "アンロックリクエスト: 途中で不正キーが入るとロック" {
    _ = setupTest();
    defer teardownTest();

    try testing.expect(!isUnlocked());
    requestUnlock();
    try testing.expect(isUnlocking());
    keypressEvent(0, 1);
    keypressEvent(0, 2);
    // 不正なキー (0,0) を途中で押す
    keypressEvent(0, 0);
    try testing.expect(isLocked());
    try testing.expect(!isUnlocking());
}

test "アンロックリクエスト: 順序が不正でロック" {
    _ = setupTest();
    defer teardownTest();

    try testing.expect(!isUnlocked());
    requestUnlock();
    try testing.expect(isUnlocking());
    keypressEvent(0, 1);
    // (0,2) の代わりに (0,4) を押す: 順序不正
    keypressEvent(0, 4);
    try testing.expect(isLocked());
    try testing.expect(!isUnlocking());
}

test "PENDING 中はキー押下をシーケンス照合に使い、リリースは無視" {
    _ = setupTest();
    defer teardownTest();

    requestUnlock();
    try testing.expect(isUnlocking());

    // press: シーケンス照合に渡し、まだ PENDING であることを確認
    keypressEvent(0, 1);
    try testing.expect(isUnlocking());

    // release: isUnlocking() == true だが keypressEvent は呼ばない
    // （ホールド中のキーのリリースで誤ってシーケンス失敗にならないようにする）
    try testing.expect(isUnlocking());

    // PENDING 中の press でシーケンスが進む
    keypressEvent(0, 2);
    keypressEvent(0, 3);
    keypressEvent(0, 4);
    try testing.expect(isUnlocked());
}

test "processKeycode: SE_LOCK でロック" {
    _ = setupTest();
    defer teardownTest();

    unlock();
    try testing.expect(isUnlocked());

    // リリース時に処理
    try testing.expect(processKeycode(keycode_mod.SE_LOCK, true)); // press は無視
    try testing.expect(!processKeycode(keycode_mod.SE_LOCK, false)); // release で処理
    try testing.expect(isLocked());
}

test "processKeycode: SE_UNLK でアンロック" {
    _ = setupTest();
    defer teardownTest();

    try testing.expect(isLocked());
    try testing.expect(!processKeycode(keycode_mod.SE_UNLK, false));
    try testing.expect(isUnlocked());
}

test "processKeycode: SE_TOGG でトグル" {
    _ = setupTest();
    defer teardownTest();

    try testing.expect(isLocked());
    _ = processKeycode(keycode_mod.SE_TOGG, false);
    try testing.expect(isUnlocked());
    _ = processKeycode(keycode_mod.SE_TOGG, false);
    try testing.expect(isLocked());
}

test "processKeycode: SE_REQ でアンロックリクエスト" {
    _ = setupTest();
    defer teardownTest();

    try testing.expect(isLocked());
    _ = processKeycode(keycode_mod.SE_REQ, false);
    try testing.expect(isUnlocking());
}

test "activityEvent: アイドルタイマーをリセット" {
    _ = setupTest();
    defer teardownTest();

    unlock();
    timer.mockAdvance(30);
    activityEvent(); // アイドルタイマーリセット
    timer.mockAdvance(30); // 合計60ms だが activityEvent から30ms
    task();
    try testing.expect(isUnlocked()); // まだロックされない

    timer.mockAdvance(idle_timeout + 1); // activityEvent 後から 50ms+1
    task();
    try testing.expect(isLocked());
}

test "unlock_timeout=0: アンロックシーケンスのタイムアウト無効" {
    _ = setupTest();
    defer teardownTest();

    unlock_timeout = 0;
    requestUnlock();
    try testing.expect(isUnlocking());
    timer.mockAdvance(100000);
    task();
    try testing.expect(isUnlocking()); // タイムアウトしない
}

test "idle_timeout=0: アイドルタイムアウト無効" {
    _ = setupTest();
    defer teardownTest();

    idle_timeout = 0;
    unlock();
    try testing.expect(isUnlocked());
    timer.mockAdvance(100000);
    task();
    try testing.expect(isUnlocked()); // タイムアウトしない
}
