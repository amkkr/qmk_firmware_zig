//! Leader Key 機能
//! C版 quantum/leader.c に相当
//!
//! QK_LEAD キーを押すとリーダーシーケンスが開始する。
//! 続けてキーを押すとシーケンスバッファに追加される。
//! タイムアウトまたはシーケンス完了で確定し、ユーザーコールバックが呼ばれる。
//!
//! 使用例:
//!   leader.setEndCallback(myLeaderEndCallback);
//!   // キー処理ループで:
//!   leader.task();
//!   if (leader.processKeycode(keycode, pressed)) { /* handled */ }
//!
//! コールバック内での使用例:
//!   fn myLeaderEndCallback(sequence: []const u16) void {
//!       if (leader.sequenceOneKey(sequence, KC.A)) {
//!           // ... KC_A シーケンス処理
//!       } else if (leader.sequenceTwoKeys(sequence, KC.B, KC.C)) {
//!           // ... KC_B, KC_C シーケンス処理
//!       }
//!   }

const timer = @import("../hal/timer.zig");
const keycode_mod = @import("keycode.zig");

const Keycode = keycode_mod.Keycode;

/// リーダーシーケンスのタイムアウト（ms）
/// C版の LEADER_TIMEOUT と同等
pub const LEADER_TIMEOUT: u16 = 300;

/// シーケンスバッファの最大長（最大5キー）
pub const MAX_SEQUENCE_LEN: usize = 5;

/// リーダーシーケンス終了コールバック型
/// sequence: バッファに追加されたキーコードのスライス
pub const LeaderEndCallback = *const fn (sequence: []const u16) void;

/// リーダー状態
var leading: bool = false;
var leader_time: u16 = 0;
var leader_sequence: [MAX_SEQUENCE_LEN]u16 = .{0} ** MAX_SEQUENCE_LEN;
var leader_sequence_size: usize = 0;

/// ユーザー定義の終了コールバック
var end_callback: ?LeaderEndCallback = null;

/// 終了コールバックを設定する
pub fn setEndCallback(cb: LeaderEndCallback) void {
    end_callback = cb;
}

/// 終了コールバックをクリアする
pub fn clearEndCallback() void {
    end_callback = null;
}

/// リーダーシーケンスを開始する
/// すでにアクティブな場合は何もしない（C版 leader_start() と同等）
pub fn leaderStart() void {
    if (leading) return;
    leading = true;
    leader_time = timer.read();
    leader_sequence_size = 0;
    leader_sequence = .{0} ** MAX_SEQUENCE_LEN;
}

/// リーダーシーケンスを終了する
/// ユーザー定義の終了コールバックを呼び出す（C版 leader_end() と同等）
pub fn leaderEnd() void {
    leading = false;
    if (end_callback) |cb| {
        cb(leader_sequence[0..leader_sequence_size]);
    }
}

/// リーダーシーケンスがアクティブかどうかを返す（C版 leader_sequence_active() と同等）
pub fn leaderSequenceActive() bool {
    return leading;
}

/// リーダーシーケンスがタイムアウトしたかどうかを返す（C版 leader_sequence_timed_out() と同等）
pub fn leaderSequenceTimedOut() bool {
    return timer.elapsed(leader_time) > LEADER_TIMEOUT;
}

/// タイマーをリセットする（C版 leader_reset_timer() と同等）
pub fn leaderResetTimer() void {
    leader_time = timer.read();
}

/// シーケンスバッファにキーコードを追加する
/// バッファが満杯の場合は false を返す（C版 leader_sequence_add() と同等）
pub fn leaderSequenceAdd(kc: u16) bool {
    if (leader_sequence_size >= MAX_SEQUENCE_LEN) {
        return false;
    }
    leader_sequence[leader_sequence_size] = kc;
    leader_sequence_size += 1;
    return true;
}

/// リーダータスク処理
/// タイムアウト時にシーケンスを終了する（C版 leader_task() と同等）
/// メインループから定期的に呼び出す必要がある
pub fn leaderTask() void {
    if (leaderSequenceActive() and leaderSequenceTimedOut()) {
        leaderEnd();
    }
}

/// QK_LEAD キーコードを処理する
/// pressed == true の場合:
///   - シーケンスがアクティブかつタイムアウトしていなければ、キーをシーケンスに追加
///   - QK_LEAD キー自体であればシーケンスを開始
/// 戻り値: true = このキーはリーダーキー処理として消費された（上位に伝播しない）
pub fn processKeycode(kc: Keycode, pressed: bool) bool {
    if (!pressed) return false;

    if (leaderSequenceActive() and !leaderSequenceTimedOut()) {
        if (kc == keycode_mod.QK_LEAD) {
            // QK_LEAD 自体はシーケンスに追加しない
            return true;
        }
        if (!leaderSequenceAdd(kc)) {
            // バッファ満杯: シーケンス終了。overflow キーはアクションパイプラインに渡す（C版互換）
            leaderEnd();
            return false;
        }
        return true;
    } else if (kc == keycode_mod.QK_LEAD) {
        leaderStart();
        return true;
    }

    return false;
}

// ============================================================
// シーケンス比較ヘルパー関数（C版の leader_sequence_one_key 等に相当）
// ============================================================

/// 内部: シーケンスバッファが指定の5キーと一致するか確認
fn sequenceIs(seq: []const u16, kc1: u16, kc2: u16, kc3: u16, kc4: u16, kc5: u16) bool {
    const get = struct {
        fn f(s: []const u16, i: usize) u16 {
            return if (i < s.len) s[i] else 0;
        }
    }.f;
    return get(seq, 0) == kc1 and get(seq, 1) == kc2 and get(seq, 2) == kc3 and get(seq, 3) == kc4 and get(seq, 4) == kc5;
}

/// 1キーシーケンスと一致するか確認（C版 leader_sequence_one_key() と同等）
pub fn sequenceOneKey(seq: []const u16, kc: u16) bool {
    return sequenceIs(seq, kc, 0, 0, 0, 0);
}

/// 2キーシーケンスと一致するか確認（C版 leader_sequence_two_keys() と同等）
pub fn sequenceTwoKeys(seq: []const u16, kc1: u16, kc2: u16) bool {
    return sequenceIs(seq, kc1, kc2, 0, 0, 0);
}

/// 3キーシーケンスと一致するか確認（C版 leader_sequence_three_keys() と同等）
pub fn sequenceThreeKeys(seq: []const u16, kc1: u16, kc2: u16, kc3: u16) bool {
    return sequenceIs(seq, kc1, kc2, kc3, 0, 0);
}

/// 4キーシーケンスと一致するか確認（C版 leader_sequence_four_keys() と同等）
pub fn sequenceFourKeys(seq: []const u16, kc1: u16, kc2: u16, kc3: u16, kc4: u16) bool {
    return sequenceIs(seq, kc1, kc2, kc3, kc4, 0);
}

/// 5キーシーケンスと一致するか確認（C版 leader_sequence_five_keys() と同等）
pub fn sequenceFiveKeys(seq: []const u16, kc1: u16, kc2: u16, kc3: u16, kc4: u16, kc5: u16) bool {
    return sequenceIs(seq, kc1, kc2, kc3, kc4, kc5);
}

/// 現在のシーケンスバッファを取得（テスト用）
pub fn getSequence() []const u16 {
    return leader_sequence[0..leader_sequence_size];
}

/// 内部状態をリセットする（テスト用）
pub fn reset() void {
    leading = false;
    leader_time = 0;
    leader_sequence = .{0} ** MAX_SEQUENCE_LEN;
    leader_sequence_size = 0;
    end_callback = null;
}

// ============================================================
// Tests
// ============================================================

const testing = @import("std").testing;
const KC = keycode_mod.KC;

test "leaderStart sets active state" {
    reset();
    try testing.expect(!leaderSequenceActive());
    leaderStart();
    try testing.expect(leaderSequenceActive());
    reset();
}

test "leaderStart is idempotent" {
    reset();
    leaderStart();
    leaderStart(); // 2回目は無視
    try testing.expect(leaderSequenceActive());
    reset();
}

test "leaderEnd clears active state" {
    reset();
    leaderStart();
    leaderEnd();
    try testing.expect(!leaderSequenceActive());
    reset();
}

test "leaderEnd calls callback with sequence" {
    reset();
    const TestHelper = struct {
        var called: bool = false;
        var received_len: usize = 0;
        var received: [5]u16 = .{0} ** 5;

        fn cb(seq: []const u16) void {
            called = true;
            received_len = seq.len;
            for (seq, 0..) |k, i| {
                if (i < 5) received[i] = k;
            }
        }
    };

    setEndCallback(TestHelper.cb);
    leaderStart();
    _ = leaderSequenceAdd(KC.A);
    _ = leaderSequenceAdd(KC.B);
    leaderEnd();

    try testing.expect(TestHelper.called);
    try testing.expectEqual(@as(usize, 2), TestHelper.received_len);
    try testing.expectEqual(KC.A, TestHelper.received[0]);
    try testing.expectEqual(KC.B, TestHelper.received[1]);
    reset();
}

test "leaderSequenceAdd fills buffer up to MAX" {
    reset();
    leaderStart();
    for (0..MAX_SEQUENCE_LEN) |i| {
        try testing.expect(leaderSequenceAdd(@intCast(i + 1)));
    }
    // バッファ満杯: 追加失敗
    try testing.expect(!leaderSequenceAdd(0x99));
    try testing.expectEqual(MAX_SEQUENCE_LEN, leader_sequence_size);
    reset();
}

test "leaderSequenceTimedOut respects LEADER_TIMEOUT" {
    reset();
    timer.mockReset();
    leaderStart();
    try testing.expect(!leaderSequenceTimedOut());
    timer.mockAdvance(LEADER_TIMEOUT + 1);
    try testing.expect(leaderSequenceTimedOut());
    reset();
    timer.mockReset();
}

test "leaderTask ends sequence on timeout" {
    reset();
    timer.mockReset();
    leaderStart();
    try testing.expect(leaderSequenceActive());
    timer.mockAdvance(LEADER_TIMEOUT + 1);
    leaderTask();
    try testing.expect(!leaderSequenceActive());
    reset();
    timer.mockReset();
}

test "processKeycode QK_LEAD starts sequence" {
    reset();
    try testing.expect(!leaderSequenceActive());
    const consumed = processKeycode(keycode_mod.QK_LEAD, true);
    try testing.expect(consumed);
    try testing.expect(leaderSequenceActive());
    reset();
}

test "processKeycode adds keys to sequence while active" {
    reset();
    timer.mockReset();
    _ = processKeycode(keycode_mod.QK_LEAD, true);
    const consumed = processKeycode(KC.A, true);
    // シーケンス追加成功時は true（消費済み: アクションパイプラインに渡さない）
    try testing.expect(consumed);
    try testing.expectEqual(@as(usize, 1), leader_sequence_size);
    try testing.expectEqual(KC.A, leader_sequence[0]);
    reset();
    timer.mockReset();
}

test "processKeycode ignores release events" {
    reset();
    timer.mockReset();
    _ = processKeycode(keycode_mod.QK_LEAD, true);
    const consumed = processKeycode(KC.A, false);
    try testing.expect(!consumed);
    try testing.expectEqual(@as(usize, 0), leader_sequence_size);
    reset();
    timer.mockReset();
}

test "processKeycode ends sequence when buffer full" {
    reset();
    timer.mockReset();
    _ = processKeycode(keycode_mod.QK_LEAD, true);
    for (0..MAX_SEQUENCE_LEN) |i| {
        _ = processKeycode(@intCast(KC.A + i), true);
    }
    // バッファ満杯: 次のキーで leaderEnd() が呼ばれアクティブでなくなる
    // overflow キーは消費されず action pipeline に渡る（C版互換: return false）
    try testing.expect(!processKeycode(KC.Z, true));
    try testing.expect(!leaderSequenceActive());
    reset();
    timer.mockReset();
}

test "processKeycode QK_LEAD during active sequence is consumed but ignored" {
    reset();
    timer.mockReset();
    _ = processKeycode(keycode_mod.QK_LEAD, true); // シーケンス開始
    const consumed = processKeycode(keycode_mod.QK_LEAD, true); // シーケンス中のQK_LEAD
    try testing.expect(consumed); // 消費される
    // シーケンスには追加されない
    try testing.expectEqual(@as(usize, 0), leader_sequence_size);
    reset();
    timer.mockReset();
}

test "sequenceOneKey matches correctly" {
    const seq1 = [_]u16{KC.A};
    try testing.expect(sequenceOneKey(&seq1, KC.A));
    try testing.expect(!sequenceOneKey(&seq1, KC.B));

    const seq2 = [_]u16{ KC.A, KC.B };
    try testing.expect(!sequenceOneKey(&seq2, KC.A));
}

test "sequenceTwoKeys matches correctly" {
    const seq = [_]u16{ KC.A, KC.B };
    try testing.expect(sequenceTwoKeys(&seq, KC.A, KC.B));
    try testing.expect(!sequenceTwoKeys(&seq, KC.A, KC.C));
    try testing.expect(!sequenceTwoKeys(&seq, KC.B, KC.A));
}

test "sequenceThreeKeys matches correctly" {
    const seq = [_]u16{ KC.A, KC.B, KC.C };
    try testing.expect(sequenceThreeKeys(&seq, KC.A, KC.B, KC.C));
    try testing.expect(!sequenceThreeKeys(&seq, KC.A, KC.B, KC.D));
}

test "sequenceFourKeys matches correctly" {
    const seq = [_]u16{ KC.A, KC.B, KC.C, KC.D };
    try testing.expect(sequenceFourKeys(&seq, KC.A, KC.B, KC.C, KC.D));
    try testing.expect(!sequenceFourKeys(&seq, KC.A, KC.B, KC.C, KC.E));
}

test "sequenceFiveKeys matches correctly" {
    const seq = [_]u16{ KC.A, KC.B, KC.C, KC.D, KC.E };
    try testing.expect(sequenceFiveKeys(&seq, KC.A, KC.B, KC.C, KC.D, KC.E));
    try testing.expect(!sequenceFiveKeys(&seq, KC.A, KC.B, KC.C, KC.D, KC.F));
}

test "getSequence returns current buffer" {
    reset();
    leaderStart();
    _ = leaderSequenceAdd(KC.X);
    _ = leaderSequenceAdd(KC.Y);
    const seq = getSequence();
    try testing.expectEqual(@as(usize, 2), seq.len);
    try testing.expectEqual(KC.X, seq[0]);
    try testing.expectEqual(KC.Y, seq[1]);
    reset();
}
