//! Tap Dance 機能
//! C版 quantum/process_keycode/process_tap_dance.c に相当
//!
//! 同一キーの連続タップ回数に応じて異なるアクションを実行する。
//! - 1タップ: on_tap アクション
//! - 2タップ: on_double_tap アクション
//! - ホールド: on_hold アクション
//! - 2タップ+ホールド: on_tap_hold アクション
//!
//! TAPPING_TERM 内の連続タップをカウントし、タイムアウトまたは
//! 他のキー入力による割り込みでダンスを確定する。

const action_code = @import("action_code.zig");
const host = @import("host.zig");
const keycode_mod = @import("keycode.zig");
const timer = @import("../hal/timer.zig");

const Action = action_code.Action;
const Keycode = keycode_mod.Keycode;

/// Tap Dance で使用するタッピングターム（ms）
pub const TAPPING_TERM: u16 = 200;

/// 同時にアクティブにできる Tap Dance の最大数
pub const MAX_SIMULTANEOUS: u8 = 3;

/// Tap Dance アクション定義
/// タップ数に応じて異なるキーコードを送信する
pub const TapDanceAction = struct {
    /// 1タップ時のキーコード
    on_tap: Keycode = keycode_mod.KC.NO,
    /// 2タップ時のキーコード
    on_double_tap: Keycode = keycode_mod.KC.NO,
    /// ホールド時のキーコード
    on_hold: Keycode = keycode_mod.KC.NO,
    /// 2タップ+ホールド時のキーコード
    on_tap_hold: Keycode = keycode_mod.KC.NO,
};

/// Tap Dance の状態
pub const TapDanceState = struct {
    /// タップ回数
    count: u8 = 0,
    /// 現在押下中か
    pressed: bool = false,
    /// ダンス確定済みか
    finished: bool = false,
    /// 他のキーによって割り込まれたか
    interrupted: bool = false,
    /// 使用中か
    in_use: bool = false,
    /// Tap Dance テーブルのインデックス
    index: u8 = 0,
    /// 最後のタップ時刻
    last_tap_time: u16 = 0,
    /// 確定時に登録したキーコード（リセット時の解除用）
    registered_kc: Keycode = 0,
};

/// Tap Dance 状態スロット
var states: [MAX_SIMULTANEOUS]TapDanceState = [_]TapDanceState{.{}} ** MAX_SIMULTANEOUS;

/// 現在アクティブな Tap Dance キーコード（0 = なし）
var active_td: Keycode = 0;

/// Tap Dance アクションテーブル（comptime または実行時に設定）
var td_actions: ?[]const TapDanceAction = null;

/// Tap Dance アクションテーブルを設定する
pub fn setActions(actions: []const TapDanceAction) void {
    td_actions = actions;
}

/// Tap Dance アクションテーブルを取得する
pub fn getActions() ?[]const TapDanceAction {
    return td_actions;
}

/// 状態をリセットする
pub fn reset() void {
    states = [_]TapDanceState{.{}} ** MAX_SIMULTANEOUS;
    active_td = 0;
}

/// 指定インデックスの状態を取得（割り当て済みのもののみ）
fn getState(td_index: u8) ?*TapDanceState {
    return getOrAllocateState(td_index, false);
}

/// 指定インデックスの状態を取得、または新規割り当て
fn getOrAllocateState(td_index: u8, allocate: bool) ?*TapDanceState {
    const actions = td_actions orelse return null;
    if (td_index >= actions.len) return null;

    // 既存のスロットを検索
    for (&states) |*s| {
        if (s.in_use and s.index == td_index) {
            return s;
        }
    }

    if (!allocate) return null;

    // 空きスロットを検索
    for (&states) |*s| {
        if (!s.in_use) {
            s.index = td_index;
            s.in_use = true;
            return s;
        }
    }

    return null;
}

/// Tap Dance のプリプロセス
/// 他のキーが押されたときに、アクティブな Tap Dance を確定する。
/// 戻り値: true = Tap Dance が割り込み確定された（キーマップの再検索が必要）
pub fn preprocess(keycode: Keycode, pressed: bool) bool {
    if (!pressed) return false;
    if (active_td == 0 or keycode == active_td) return false;

    const td_index = getTdIndex(active_td);
    const actions = td_actions orelse return false;
    if (td_index >= actions.len) return false;

    const state = getState(td_index) orelse return false;
    state.interrupted = true;
    finishDance(td_index, state);

    return true;
}

/// Tap Dance キーコードを処理する
/// 戻り値: true = このキーコードは Tap Dance として処理された
pub fn process(keycode: Keycode, pressed: bool) bool {
    if (!isTapDance(keycode)) return false;

    const td_index = getTdIndex(keycode);
    const actions = td_actions orelse return false;
    if (td_index >= actions.len) return false;

    const state = getOrAllocateState(td_index, pressed) orelse return false;
    state.pressed = pressed;

    if (pressed) {
        state.last_tap_time = timer.read();
        state.count += 1;
        // 2タップで即座に確定するケースをチェック
        if (state.count >= 2 and actions[td_index].on_double_tap != keycode_mod.KC.NO) {
            // on_double_tap があれば後で確定時に判断
        }
        active_td = if (state.finished) 0 else keycode;
    } else {
        if (state.finished) {
            resetState(td_index, state);
            if (active_td == keycode) {
                active_td = 0;
            }
        }
    }

    return true;
}

/// タイマーベースの Tap Dance タスク
/// TAPPING_TERM を超えたらダンスを確定する
pub fn task() void {
    if (active_td == 0) return;

    const td_index = getTdIndex(active_td);
    const state = getState(td_index) orelse return;

    if (timerElapsed(state.last_tap_time) <= TAPPING_TERM) return;

    if (!state.interrupted) {
        finishDance(td_index, state);
    }
}

/// ダンスを確定する
fn finishDance(td_index: u8, state: *TapDanceState) void {
    if (state.finished) return;
    state.finished = true;

    const actions = td_actions orelse return;
    if (td_index >= actions.len) return;
    const td_action = actions[td_index];

    // タップ数と押下状態に応じてアクションを決定
    const kc: Keycode = if (state.pressed) blk: {
        // ホールド中
        break :blk if (state.count >= 2) td_action.on_tap_hold else td_action.on_hold;
    } else blk: {
        // リリース済み（タップ）
        break :blk if (state.count >= 2) td_action.on_double_tap else td_action.on_tap;
    };

    state.registered_kc = kc;
    registerKeycode(kc);
    host.sendKeyboardReport();

    active_td = 0;

    if (!state.pressed) {
        // キーはすでにリリースされているので即リセット
        unregisterAndReset(state);
    }
}

/// 状態をリセットし、登録したキーコードを解除する
fn resetState(_: u8, state: *TapDanceState) void {
    unregisterAndReset(state);
}

/// キーコード解除とスロットクリア
fn unregisterAndReset(state: *TapDanceState) void {
    // 確定時に登録したキーコードを解除
    if (state.registered_kc != 0) {
        unregisterKeycode(state.registered_kc);
        host.sendKeyboardReport();
    }

    // スロットをクリア
    state.* = .{};
}

/// キーコードを HID レポートに登録する
fn registerKeycode(kc: Keycode) void {
    if (kc == keycode_mod.KC.NO) return;
    if (kc <= 0x00FF) {
        // Basic keycode
        if (kc >= 0xE0 and kc <= 0xE7) {
            // Modifier keycode
            host.registerCode(@truncate(kc));
        } else {
            host.registerCode(@truncate(kc));
        }
    }
}

/// キーコードを HID レポートから解除する
fn unregisterKeycode(kc: Keycode) void {
    if (kc == keycode_mod.KC.NO) return;
    if (kc <= 0x00FF) {
        host.unregisterCode(@truncate(kc));
    }
}

/// Tap Dance キーコードかどうか判定
pub fn isTapDance(kc: Keycode) bool {
    return kc >= keycode_mod.QK_TAP_DANCE and kc <= keycode_mod.QK_TAP_DANCE_MAX;
}

/// Tap Dance キーコードからインデックスを取得
pub fn getTdIndex(kc: Keycode) u8 {
    return @truncate(kc & 0xFF);
}

/// タイマー経過時間を計算
fn timerElapsed(start: u16) u16 {
    return timer.read() -% start;
}

// ============================================================
// Tests
// ============================================================

const testing = @import("std").testing;
const report_mod = @import("report.zig");
const FixedTestDriver = @import("test_driver.zig").FixedTestDriver;

const MockDriver = FixedTestDriver(32, 4);

fn setupTest() *MockDriver {
    const static = struct {
        var mock: MockDriver = .{};
    };
    reset();
    host.hostReset();
    static.mock = .{};
    host.setDriver(host.HostDriver.from(&static.mock));
    return &static.mock;
}

fn teardownTest() void {
    host.clearDriver();
    reset();
    td_actions = null;
}

test "isTapDance" {
    try testing.expect(isTapDance(keycode_mod.TD(0)));
    try testing.expect(isTapDance(keycode_mod.TD(1)));
    try testing.expect(isTapDance(keycode_mod.TD(255)));
    try testing.expect(!isTapDance(keycode_mod.KC.A));
    try testing.expect(!isTapDance(keycode_mod.MO(1)));
}

test "getTdIndex" {
    try testing.expectEqual(@as(u8, 0), getTdIndex(keycode_mod.TD(0)));
    try testing.expectEqual(@as(u8, 1), getTdIndex(keycode_mod.TD(1)));
    try testing.expectEqual(@as(u8, 255), getTdIndex(keycode_mod.TD(255)));
}

test "single tap sends on_tap keycode" {
    const mock = setupTest();
    defer teardownTest();

    const actions = [_]TapDanceAction{
        .{ .on_tap = keycode_mod.KC.A, .on_double_tap = keycode_mod.KC.B, .on_hold = keycode_mod.KC.LEFT_SHIFT },
    };
    setActions(&actions);

    const td_kc = keycode_mod.TD(0);

    // プレス
    _ = process(td_kc, true);
    // リリース（TAPPING_TERM 内）
    _ = process(td_kc, false);

    // TAPPING_TERM 経過でダンス確定
    timer.mockAdvance(TAPPING_TERM + 1);
    task();

    // KC_A が登録・送信されているはず
    try testing.expect(mock.keyboard_count >= 1);
    var found_a = false;
    for (0..@min(mock.keyboard_count, 32)) |i| {
        if (mock.keyboard_reports[i].hasKey(0x04)) {
            found_a = true;
            break;
        }
    }
    try testing.expect(found_a);
}

test "double tap sends on_double_tap keycode" {
    const mock = setupTest();
    defer teardownTest();

    const actions = [_]TapDanceAction{
        .{ .on_tap = keycode_mod.KC.A, .on_double_tap = keycode_mod.KC.B, .on_hold = keycode_mod.KC.LEFT_SHIFT },
    };
    setActions(&actions);

    const td_kc = keycode_mod.TD(0);

    // 1タップ
    _ = process(td_kc, true);
    _ = process(td_kc, false);

    // 2タップ（TAPPING_TERM 内）
    timer.mockAdvance(50);
    _ = process(td_kc, true);
    _ = process(td_kc, false);

    // TAPPING_TERM 経過でダンス確定
    timer.mockAdvance(TAPPING_TERM + 1);
    task();

    // KC_B が登録・送信されているはず
    try testing.expect(mock.keyboard_count >= 1);
    var found_b = false;
    for (0..@min(mock.keyboard_count, 32)) |i| {
        if (mock.keyboard_reports[i].hasKey(0x05)) {
            found_b = true;
            break;
        }
    }
    try testing.expect(found_b);
}

test "hold sends on_hold keycode" {
    const mock = setupTest();
    defer teardownTest();

    const actions = [_]TapDanceAction{
        .{ .on_tap = keycode_mod.KC.A, .on_double_tap = keycode_mod.KC.B, .on_hold = keycode_mod.KC.LEFT_SHIFT },
    };
    setActions(&actions);

    const td_kc = keycode_mod.TD(0);

    // プレス（リリースしない）
    _ = process(td_kc, true);

    // TAPPING_TERM 経過でホールド確定
    timer.mockAdvance(TAPPING_TERM + 1);
    task();

    // LSHIFT が登録されているはず
    try testing.expect(mock.keyboard_count >= 1);
    var found_shift = false;
    for (0..@min(mock.keyboard_count, 32)) |i| {
        if (mock.keyboard_reports[i].mods & report_mod.ModBit.LSHIFT != 0) {
            found_shift = true;
            break;
        }
    }
    try testing.expect(found_shift);

    // リリース
    _ = process(td_kc, false);
    // リリース後にmodsがクリアされるはず
    try testing.expectEqual(@as(u8, 0), mock.lastKeyboardReport().mods);
}

test "interrupted tap dance finishes immediately" {
    const mock = setupTest();
    defer teardownTest();

    const actions = [_]TapDanceAction{
        .{ .on_tap = keycode_mod.KC.A, .on_double_tap = keycode_mod.KC.B, .on_hold = keycode_mod.KC.LEFT_SHIFT },
    };
    setActions(&actions);

    const td_kc = keycode_mod.TD(0);

    // TD キーをプレス
    _ = process(td_kc, true);
    _ = process(td_kc, false);

    // 別のキーで割り込み
    _ = preprocess(keycode_mod.KC.C, true);

    // KC_A が即座に確定されているはず
    try testing.expect(mock.keyboard_count >= 1);
    var found_a = false;
    for (0..@min(mock.keyboard_count, 32)) |i| {
        if (mock.keyboard_reports[i].hasKey(0x04)) {
            found_a = true;
            break;
        }
    }
    try testing.expect(found_a);
}

test "tap dance state allocation and deallocation" {
    _ = setupTest();
    defer teardownTest();

    const actions = [_]TapDanceAction{
        .{ .on_tap = keycode_mod.KC.A },
        .{ .on_tap = keycode_mod.KC.B },
    };
    setActions(&actions);

    // 状態が未割り当て
    try testing.expect(getState(0) == null);
    try testing.expect(getState(1) == null);

    // 割り当て
    const s0 = getOrAllocateState(0, true);
    try testing.expect(s0 != null);
    try testing.expect(getState(0) != null);

    // 同じインデックスは同じスロット
    const s0_again = getOrAllocateState(0, true);
    try testing.expect(s0_again == s0);

    // 別のインデックスは別のスロット
    const s1 = getOrAllocateState(1, true);
    try testing.expect(s1 != null);
    try testing.expect(s1 != s0);
}

test "reset clears all state" {
    _ = setupTest();
    defer teardownTest();

    const actions = [_]TapDanceAction{
        .{ .on_tap = keycode_mod.KC.A },
    };
    setActions(&actions);

    _ = getOrAllocateState(0, true);
    active_td = keycode_mod.TD(0);

    reset();

    try testing.expect(getState(0) == null);
    try testing.expectEqual(@as(Keycode, 0), active_td);
}
