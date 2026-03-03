// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zig port of quantum/action_tapping.c
// Original: Copyright 2011,2012,2013 Jun Wako <wakojun@gmail.com>

//! タップ/ホールド判定ステートマシン
//! C版 quantum/action_tapping.c に相当
//!
//! ステートマシン:
//!   1. リセット状態（tapping_keyが空）
//!   2. タップキー押下中状態
//!   3. タップキー解放後状態

const std = @import("std");
const action = @import("action.zig");
const event_mod = @import("event.zig");
const host = @import("host.zig");
const build_options = @import("build_options");

const KeyRecord = event_mod.KeyRecord;
const KeyEvent = event_mod.KeyEvent;

/// キーボード定義モジュール（comptime 選択）
/// per-key タッピング設定コールバックの解決に使用
const kb = if (std.mem.eql(u8, build_options.KEYBOARD, "madbd34"))
    @import("../keyboards/madbd34.zig")
else
    @import("../keyboards/madbd5.zig");

pub const DEFAULT_TAPPING_TERM: u16 = 200;
/// 後方互換エイリアス（既存テスト・フィクスチャで参照されるため）
pub const TAPPING_TERM: u16 = DEFAULT_TAPPING_TERM;
/// 動的に変更可能なタッピングターム（Dynamic Tapping Term で増減される）
pub var tapping_term: u16 = DEFAULT_TAPPING_TERM;
pub const DEFAULT_QUICK_TAP_TERM: u16 = 200;
pub const QUICK_TAP_TERM: u16 = DEFAULT_QUICK_TAP_TERM;
pub const WAITING_BUFFER_SIZE: u8 = 8;

/// PERMISSIVE_HOLD: 他キーの press+release が TAPPING_TERM 以内に完結した場合、
/// タップ/ホールドキーをホールドとして判定する。
/// C版 #define PERMISSIVE_HOLD に相当。
pub var permissive_hold: bool = false;

/// HOLD_ON_OTHER_KEY_PRESS: 他キーが TAPPING_TERM 以内に押下された時点で
/// タップ/ホールドキーをホールドとして即座に判定する。
/// C版 #define HOLD_ON_OTHER_KEY_PRESS に相当。
pub var hold_on_other_key_press: bool = false;

/// RETRO_TAPPING: TAPPING_TERM 超過後に他キーの割り込みなしでリリースされた場合、
/// ホールドアクション実行後にタップキーも送信する。
/// C版 #define RETRO_TAPPING に相当。
pub var retro_tapping: bool = false;

var tapping_key: KeyRecord = .{ .event = KeyEvent.tick(0) };
var waiting_buffer: [WAITING_BUFFER_SIZE]KeyRecord = initWaitingBuffer();
var waiting_buffer_head: u8 = 0;
var waiting_buffer_tail: u8 = 0;

fn initWaitingBuffer() [WAITING_BUFFER_SIZE]KeyRecord {
    var buf: [WAITING_BUFFER_SIZE]KeyRecord = undefined;
    for (&buf) |*entry| {
        entry.* = .{ .event = KeyEvent.tick(0) };
    }
    return buf;
}

// ============================================================
// Per-key タッピング設定コールバック
// ============================================================
// C版の TAPPING_TERM_PER_KEY / QUICK_TAP_TERM_PER_KEY /
// PERMISSIVE_HOLD_PER_KEY / HOLD_ON_OTHER_KEY_PRESS_PER_KEY に相当。
// キーボード定義モジュール(kb)に対応する関数が定義されていれば、
// @hasDecl で comptime 検出して呼び出す。
// 未定義の場合はグローバル設定値を使用する。

/// tapping_key に対する tapping term を取得する。
/// C版 GET_TAPPING_TERM(keycode, record) に相当。
/// kb.get_tapping_term(*const KeyRecord) が定義されていれば呼び出す。
fn getTappingTermForKey(record: *const KeyRecord) u16 {
    if (@hasDecl(kb, "get_tapping_term")) {
        return kb.get_tapping_term(record);
    }
    return tapping_term;
}

/// tapping_key に対する quick tap term を取得する。
/// C版 GET_QUICK_TAP_TERM(keycode, record) に相当。
fn getQuickTapTermForKey(record: *const KeyRecord) u16 {
    if (@hasDecl(kb, "get_quick_tap_term")) {
        return kb.get_quick_tap_term(record);
    }
    return QUICK_TAP_TERM;
}

/// tapping_key に対する permissive hold 設定を取得する。
/// C版 get_permissive_hold(keycode, record) に相当。
fn getPermissiveHoldForKey(record: *const KeyRecord) bool {
    if (@hasDecl(kb, "get_permissive_hold")) {
        return kb.get_permissive_hold(record);
    }
    return permissive_hold;
}

/// tapping_key に対する hold on other key press 設定を取得する。
/// C版 get_hold_on_other_key_press(keycode, record) に相当。
fn getHoldOnOtherKeyPressForKey(record: *const KeyRecord) bool {
    if (@hasDecl(kb, "get_hold_on_other_key_press")) {
        return kb.get_hold_on_other_key_press(record);
    }
    return hold_on_other_key_press;
}

pub fn actionTappingProcess(record: *KeyRecord) void {
    if (processTapping(record)) {
        return;
    } else {
        if (!waitingBufferEnq(record.*)) {
            host.clearKeyboard();
            waitingBufferClear();
            tapping_key = .{ .event = KeyEvent.tick(0) };
        }
    }

    if (!record.event.isTick() and waiting_buffer_head != waiting_buffer_tail) {
        var tail = waiting_buffer_tail;
        while (tail != waiting_buffer_head) {
            if (processTapping(&waiting_buffer[tail])) {
                tail = (tail + 1) % WAITING_BUFFER_SIZE;
                waiting_buffer_tail = tail;
            } else {
                break;
            }
        }
    }
}

fn processTapping(keyp: *KeyRecord) bool {
    const ev = keyp.event;

    // リセット状態
    if (tapping_key.event.isTick()) {
        if (ev.isTick()) {
            return true;
        } else if (ev.pressed and action.isTapRecord(keyp)) {
            tapping_key = keyp.*;
            waitingBufferScanTap();
            return true;
        } else {
            action.processRecord(keyp);
            return true;
        }
    }

    // 押下中状態
    if (tapping_key.event.pressed) {
        if (withinTappingTerm(ev)) {
            if (ev.isTick()) {
                return true;
            }

            if (tapping_key.tap.count == 0) {
                if (isTappingRecord(keyp) and !ev.pressed) {
                    // First tap
                    tapping_key.tap.count = 1;
                    action.processRecord(&tapping_key);
                    keyp.tap = tapping_key.tap;
                    return false;
                } else if (!ev.pressed and waitingBufferTyped(ev) and getPermissiveHoldForKey(&tapping_key)) {
                    // PERMISSIVE_HOLD: 他キーの press+release が TAPPING_TERM 以内に完結
                    // → ホールドとして確定させる
                    action.processRecord(&tapping_key);
                    tapping_key = .{ .event = KeyEvent.tick(0) };
                    return false;
                } else if (!ev.pressed and !waitingBufferTyped(ev)) {
                    // C版互換: タッピング開始前に押されたキーのリリース処理。
                    // 修飾キー/レイヤーキーはタッピング終了まで保持する。
                    if (action.shouldRetainReleaseDuringTapping(ev, keyp.tap.count)) {
                        return false;
                    }
                    action.processRecord(keyp);
                    return true;
                } else {
                    if (ev.pressed) {
                        tapping_key.tap.interrupted = true;
                        if (getHoldOnOtherKeyPressForKey(&tapping_key)) {
                            // HOLD_ON_OTHER_KEY_PRESS: 他キー押下時点でホールドとして即座に確定
                            action.processRecord(&tapping_key);
                            tapping_key = .{ .event = KeyEvent.tick(0) };
                        }
                    }
                    return false;
                }
            } else {
                // tap_count > 0
                if (isTappingRecord(keyp) and !ev.pressed) {
                    keyp.tap = tapping_key.tap;
                    action.processRecord(keyp);
                    tapping_key = keyp.*;
                    return true;
                } else if (action.isTapRecord(keyp) and ev.pressed) {
                    if (tapping_key.tap.count > 1) {
                        var unreg = KeyRecord{
                            .tap = tapping_key.tap,
                            .event = KeyEvent.keyRelease(tapping_key.event.key.row, tapping_key.event.key.col, ev.time),
                        };
                        action.processRecord(&unreg);
                    }
                    tapping_key = keyp.*;
                    waitingBufferScanTap();
                    return true;
                } else {
                    action.processRecord(keyp);
                    return true;
                }
            }
        } else {
            // After TAPPING_TERM
            if (tapping_key.tap.count == 0) {
                action.processRecord(&tapping_key);
                tapping_key = .{ .event = KeyEvent.tick(0) };
                return false;
            } else {
                if (ev.isTick()) return true;
                if (isTappingRecord(keyp) and !ev.pressed) {
                    keyp.tap = tapping_key.tap;
                    action.processRecord(keyp);
                    tapping_key = .{ .event = KeyEvent.tick(0) };
                    return true;
                } else if (action.isTapRecord(keyp) and ev.pressed) {
                    if (tapping_key.tap.count > 1) {
                        var unreg = KeyRecord{
                            .tap = tapping_key.tap,
                            .event = KeyEvent.keyRelease(tapping_key.event.key.row, tapping_key.event.key.col, ev.time),
                        };
                        action.processRecord(&unreg);
                    }
                    tapping_key = keyp.*;
                    waitingBufferScanTap();
                    return true;
                } else {
                    action.processRecord(keyp);
                    return true;
                }
            }
        }
    }
    // 解放後状態
    else {
        if (withinTappingTerm(ev)) {
            if (ev.isTick()) return true;
            if (ev.pressed) {
                if (isTappingRecord(keyp)) {
                    if (withinQuickTapTerm(ev) and !tapping_key.tap.interrupted and tapping_key.tap.count > 0) {
                        keyp.tap = tapping_key.tap;
                        if (keyp.tap.count < 15) keyp.tap.count += 1;
                        action.processRecord(keyp);
                        tapping_key = keyp.*;
                        return true;
                    }
                    tapping_key = keyp.*;
                    return true;
                } else if (action.isTapRecord(keyp)) {
                    tapping_key = keyp.*;
                    waitingBufferScanTap();
                    return true;
                } else {
                    tapping_key.tap.interrupted = true;
                    action.processRecord(keyp);
                    return true;
                }
            } else {
                action.processRecord(keyp);
                return true;
            }
        } else {
            tapping_key = .{ .event = KeyEvent.tick(0) };
            return false;
        }
    }
}

fn withinTappingTerm(ev: KeyEvent) bool {
    return timerDiff16(ev.time, tapping_key.event.time) < getTappingTermForKey(&tapping_key);
}

/// Quick Tap判定: 前回のタップから十分短い時間内かどうか
///
/// 注意: C版との差異あり。C版（action_tapping.c）では前回タップの「リリース時刻」を
/// 基準にしているが、本実装では前回タップの「プレス時刻」（tapping_key.event.time）を
/// 基準にしている。Quick Tap Termが十分に長い場合は実用上の差異は小さい。
fn withinQuickTapTerm(ev: KeyEvent) bool {
    return timerDiff16(ev.time, tapping_key.event.time) < getQuickTapTermForKey(&tapping_key);
}

fn timerDiff16(a: u16, b: u16) u16 {
    return a -% b;
}

fn isTappingRecord(record: *const KeyRecord) bool {
    return record.event.key.col == tapping_key.event.key.col and
        record.event.key.row == tapping_key.event.key.row;
}

fn waitingBufferEnq(record: KeyRecord) bool {
    if (record.event.isTick()) return true;
    if ((waiting_buffer_head + 1) % WAITING_BUFFER_SIZE == waiting_buffer_tail) return false;
    waiting_buffer[waiting_buffer_head] = record;
    waiting_buffer_head = (waiting_buffer_head + 1) % WAITING_BUFFER_SIZE;
    return true;
}

fn waitingBufferClear() void {
    waiting_buffer_head = 0;
    waiting_buffer_tail = 0;
}

fn waitingBufferTyped(ev: KeyEvent) bool {
    var i = waiting_buffer_tail;
    while (i != waiting_buffer_head) : (i = (i + 1) % WAITING_BUFFER_SIZE) {
        const buf_ev = waiting_buffer[i].event;
        if (buf_ev.key.col == ev.key.col and buf_ev.key.row == ev.key.row and buf_ev.pressed != ev.pressed) {
            return true;
        }
    }
    return false;
}

fn waitingBufferScanTap() void {
    if (tapping_key.tap.count > 0 or !tapping_key.event.pressed) return;
    var i = waiting_buffer_tail;
    while (i != waiting_buffer_head) : (i = (i + 1) % WAITING_BUFFER_SIZE) {
        const buf_ev = waiting_buffer[i].event;
        if (!buf_ev.isTick() and
            buf_ev.key.col == tapping_key.event.key.col and
            buf_ev.key.row == tapping_key.event.key.row and
            !buf_ev.pressed and
            timerDiff16(buf_ev.time, tapping_key.event.time) < getTappingTermForKey(&tapping_key))
        {
            tapping_key.tap.count = 1;
            waiting_buffer[i].tap.count = 1;
            action.processRecord(&tapping_key);
            return;
        }
    }
}

pub fn reset() void {
    tapping_key = .{ .event = KeyEvent.tick(0) };
    waiting_buffer = initWaitingBuffer();
    waiting_buffer_head = 0;
    waiting_buffer_tail = 0;
    tapping_term = DEFAULT_TAPPING_TERM;
}

test {
    _ = @import("action_tapping_test.zig");
}
