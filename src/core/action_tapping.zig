// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zig port of quantum/action_tapping.c
// Original: Jun Wako (TMK)

//! タップ/ホールド判定ステートマシン
//! C版 quantum/action_tapping.c に相当
//!
//! ステートマシン:
//!   1. リセット状態（tapping_keyが空）
//!   2. タップキー押下中状態
//!   3. タップキー解放後状態

const action = @import("action.zig");
const event_mod = @import("event.zig");
const host = @import("host.zig");

const KeyRecord = event_mod.KeyRecord;
const KeyEvent = event_mod.KeyEvent;

pub const TAPPING_TERM: u16 = 200;
pub const QUICK_TAP_TERM: u16 = 200;
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
                } else if (!ev.pressed and waitingBufferTyped(ev) and permissive_hold) {
                    // PERMISSIVE_HOLD: 他キーの press+release が TAPPING_TERM 以内に完結
                    // → ホールドとして確定させる
                    action.processRecord(&tapping_key);
                    tapping_key = .{ .event = KeyEvent.tick(0) };
                    return false;
                } else if (!ev.pressed and !waitingBufferTyped(ev)) {
                    action.processRecord(keyp);
                    return true;
                } else {
                    if (ev.pressed) {
                        tapping_key.tap.interrupted = true;
                        if (hold_on_other_key_press) {
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
    return timerDiff16(ev.time, tapping_key.event.time) < TAPPING_TERM;
}

/// Quick Tap判定: 前回のタップから十分短い時間内かどうか
///
/// 注意: C版との差異あり。C版（action_tapping.c）では前回タップの「リリース時刻」を
/// 基準にしているが、本実装では前回タップの「プレス時刻」（tapping_key.event.time）を
/// 基準にしている。Quick Tap Termが十分に長い場合は実用上の差異は小さい。
fn withinQuickTapTerm(ev: KeyEvent) bool {
    return timerDiff16(ev.time, tapping_key.event.time) < QUICK_TAP_TERM;
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
            timerDiff16(buf_ev.time, tapping_key.event.time) < TAPPING_TERM)
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
}

test {
    _ = @import("action_tapping_test.zig");
}
