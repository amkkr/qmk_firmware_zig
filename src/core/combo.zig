//! Combo キー: 複数キーの同時押しで別のキーコードを発動
//! C版 quantum/process_keycode/process_combo.c の移植
//!
//! 設計:
//!   - comptime で定義されたコンボテーブルを参照
//!   - COMBO_TERM (ms) 以内に全キーが押されたらコンボとして処理
//!   - コンボキーのイベントはバッファリングし、コンボ成立/不成立で処理を分岐
//!
//! 処理フロー:
//!   1. キーイベントが来たら、いずれかのコンボの構成キーかチェック
//!   2. 構成キーならバッファに格納し、コンボ状態を更新
//!   3. 全構成キーが押されたらコンボ発動（結果キーコードを登録）
//!   4. COMBO_TERM タイムアウトでバッファを吐き出し（通常キーとして処理）
//!   5. 構成キーでないキーが来たらバッファを吐き出し

const std = @import("std");
const action = @import("action.zig");
const action_code = @import("action_code.zig");
const event_mod = @import("event.zig");
const host = @import("host.zig");
const timer = @import("../hal/timer.zig");

const KeyEvent = event_mod.KeyEvent;
const KeyRecord = event_mod.KeyRecord;
const Action = action_code.Action;
const Keycode = @import("keycode.zig").Keycode;

/// コンボ判定タイムウィンドウ (ms)
pub const COMBO_TERM: u16 = 50;

/// コンボ定義の最大数
pub const MAX_COMBOS: usize = 16;

/// キーバッファの最大サイズ
pub const KEY_BUFFER_SIZE: usize = 8;

/// コンボ定義: 2つのキーコードの同時押しで別のキーコードを発動
pub const ComboDefinition = struct {
    /// 構成キー1のキーコード
    key1: Keycode,
    /// 構成キー2のキーコード
    key2: Keycode,
    /// 発動するキーコード
    result: Keycode,
};

/// コンボの実行時状態
const ComboState = struct {
    key1_pressed: bool = false,
    key2_pressed: bool = false,
    active: bool = false,
    disabled: bool = false,
};

/// バッファリングされたキーイベント
const BufferedKey = struct {
    record: KeyRecord,
    keycode: Keycode,
};

// ============================================================
// グローバル状態
// ============================================================

/// コンボテーブル（外部から設定）
var combo_table: []const ComboDefinition = &.{};

/// コンボ状態配列
var combo_states: [MAX_COMBOS]ComboState = [_]ComboState{.{}} ** MAX_COMBOS;

/// キーバッファ
var key_buffer: [KEY_BUFFER_SIZE]BufferedKey = undefined;
var key_buffer_len: u8 = 0;

/// タイマー（0 = 非活性）
var combo_timer: u16 = 0;

/// コンボ有効フラグ
var combo_enabled: bool = true;

/// アクション解決コールバック（キーコードからアクションへの変換用）
var keycode_resolver: ?*const fn (event: KeyEvent) Keycode = null;

// ============================================================
// 初期化・設定
// ============================================================

/// コンボテーブルを設定
pub fn setComboTable(table: []const ComboDefinition) void {
    std.debug.assert(table.len <= MAX_COMBOS);
    combo_table = table;
}

/// キーコードリゾルバを設定（キーイベントからキーコードを取得するため）
pub fn setKeycodeResolver(resolver: *const fn (event: KeyEvent) Keycode) void {
    keycode_resolver = resolver;
}

/// 全状態をリセット
pub fn reset() void {
    combo_states = [_]ComboState{.{}} ** MAX_COMBOS;
    key_buffer_len = 0;
    combo_timer = 0;
    combo_enabled = true;
    combo_table = &.{};
    keycode_resolver = null;
}

/// コンボを有効化
pub fn enable() void {
    combo_enabled = true;
}

/// コンボを無効化
pub fn disable() void {
    combo_enabled = false;
    combo_timer = 0;
    dumpKeyBuffer();
    clearCombos();
}

/// コンボの有効/無効をトグル
pub fn toggle() void {
    if (combo_enabled) {
        disable();
    } else {
        enable();
    }
}

/// コンボが有効かどうか
pub fn isEnabled() bool {
    return combo_enabled;
}

// ============================================================
// コンボ処理
// ============================================================

/// キーイベントを処理する。コンボキーの場合は true を返しイベントを消費する。
/// keyboard.zig の task() からアクション解決前に呼ばれることを想定。
pub fn processCombo(record: *KeyRecord) bool {
    if (!combo_enabled or combo_table.len == 0) return false;

    // キーコードを解決
    const keycode = resolveKeycode(record.event);
    if (keycode == 0) return false; // KC_NO

    var is_combo_key = false;

    if (record.event.pressed) {
        // プレスイベント: 各コンボとの一致をチェック
        for (combo_table, 0..) |combo_def, i| {
            if (i >= MAX_COMBOS) break;
            var state = &combo_states[i];

            if (state.disabled or state.active) continue;

            if (keycode == combo_def.key1 and !state.key1_pressed) {
                state.key1_pressed = true;
                is_combo_key = true;
            } else if (keycode == combo_def.key2 and !state.key2_pressed) {
                state.key2_pressed = true;
                is_combo_key = true;
            }

            // 両方押された → コンボ成立
            if (state.key1_pressed and state.key2_pressed) {
                activateCombo(i);
                return true;
            }
        }

        if (is_combo_key) {
            // タイマー開始（最初のキーのみ）
            if (combo_timer == 0) {
                combo_timer = timer.read();
                if (combo_timer == 0) combo_timer = 1; // 0 は非活性を意味するので避ける
            }
            // バッファに格納
            bufferKey(record.*, keycode);
        } else {
            // コンボキーでないキーが押された → バッファを吐き出し
            if (key_buffer_len > 0) {
                dumpKeyBuffer();
                combo_timer = 0;
                clearCombos();
            }
        }
    } else {
        // リリースイベント
        var deactivated = false;
        for (combo_table, 0..) |combo_def, i| {
            if (i >= MAX_COMBOS) break;
            var state = &combo_states[i];

            if (state.active) {
                // アクティブなコンボのキーがリリースされた
                if (keycode == combo_def.key1 or keycode == combo_def.key2) {
                    if (keycode == combo_def.key1) {
                        state.key1_pressed = false;
                    }
                    if (keycode == combo_def.key2) {
                        state.key2_pressed = false;
                    }
                    // 最後のキーがリリースされたらコンボを解除
                    if (!state.key1_pressed and !state.key2_pressed) {
                        deactivateCombo(i);
                        deactivated = true;
                    }
                    is_combo_key = true;
                }
            } else if (!state.disabled) {
                // 未確定コンボのキーがリリースされた → コンボ不成立
                if (keycode == combo_def.key1 or keycode == combo_def.key2) {
                    state.disabled = true;
                }
            }
        }

        // コンボ解除後に他コンボの disabled フラグをリセット
        if (deactivated) {
            clearCombos();
        }

        if (!is_combo_key and key_buffer_len > 0) {
            // コンボキーではないリリース → バッファ吐き出し
            dumpKeyBuffer();
            combo_timer = 0;
            clearCombos();
        }
    }

    return is_combo_key;
}

/// タイムアウト処理。keyboard_task() の各サイクルで呼ぶ。
pub fn comboTask() void {
    if (!combo_enabled or combo_timer == 0) return;

    if (timer.elapsed(combo_timer) > COMBO_TERM) {
        // タイムアウト: バッファを通常キーとして処理
        dumpKeyBuffer();
        combo_timer = 0;
        clearCombos();
    }
}

// ============================================================
// 内部関数
// ============================================================

fn resolveKeycode(ev: KeyEvent) Keycode {
    if (keycode_resolver) |resolver| {
        return resolver(ev);
    }
    return 0;
}

fn bufferKey(record: KeyRecord, keycode: Keycode) void {
    if (key_buffer_len < KEY_BUFFER_SIZE) {
        key_buffer[key_buffer_len] = .{
            .record = record,
            .keycode = keycode,
        };
        key_buffer_len += 1;
    }
}

/// バッファ内のキーを通常キーとして処理
fn dumpKeyBuffer() void {
    for (0..key_buffer_len) |i| {
        var record = key_buffer[i].record;
        action.actionExec(&record);
    }
    key_buffer_len = 0;
}

/// コンボを発動
fn activateCombo(combo_index: usize) void {
    if (combo_index >= combo_table.len) return;

    var state = &combo_states[combo_index];
    state.active = true;

    const result_kc = combo_table[combo_index].result;
    const act = action_code.keycodeToAction(result_kc);

    // バッファをクリア（コンボキーのイベントは消費）
    key_buffer_len = 0;
    combo_timer = 0;

    // 結果キーコードをプレスとして発動
    var press_record = KeyRecord{
        .event = KeyEvent{
            .key = .{ .row = 0, .col = 0 },
            .time = timer.read(),
            .event_type = .combo,
            .pressed = true,
        },
    };
    action.processAction(&press_record, act);

    // 他のコンボをリセット
    for (0..combo_table.len) |j| {
        if (j >= MAX_COMBOS) break;
        if (j != combo_index) {
            combo_states[j].disabled = true;
        }
    }
}

/// コンボを解除（リリース処理）
fn deactivateCombo(combo_index: usize) void {
    if (combo_index >= combo_table.len) return;

    var state = &combo_states[combo_index];
    state.active = false;

    const result_kc = combo_table[combo_index].result;
    const act = action_code.keycodeToAction(result_kc);

    var release_record = KeyRecord{
        .event = KeyEvent{
            .key = .{ .row = 0, .col = 0 },
            .time = timer.read(),
            .event_type = .combo,
            .pressed = false,
        },
    };
    action.processAction(&release_record, act);

    // 他コンボの disabled フラグをリセットして次のコンボが発動できるようにする
    clearCombos();
}

/// 全コンボ状態をリセット（アクティブなコンボ以外）
fn clearCombos() void {
    for (0..MAX_COMBOS) |i| {
        if (!combo_states[i].active) {
            combo_states[i] = .{};
        }
    }
}

// ============================================================
// テスト
// ============================================================

const testing = std.testing;
const keycode_mod = @import("keycode.zig");
const KC = keycode_mod.KC;
const report_mod = @import("report.zig");
const FixedTestDriver = @import("test_driver.zig").FixedTestDriver;

const TestDriver = FixedTestDriver(64, 16);

fn setupTest() *TestDriver {
    const S = struct {
        var driver: TestDriver = .{};
    };
    S.driver = .{};
    reset();
    action.reset();
    timer.mockReset();
    host.setDriver(host.HostDriver.from(&S.driver));
    action.setActionResolver(testActionResolver);
    return &S.driver;
}

/// テスト用アクションリゾルバ: キーコードリゾルバ経由で解決
fn testActionResolver(ev: KeyEvent) Action {
    const kc = testKeycodeResolver(ev);
    return action_code.keycodeToAction(kc);
}

fn teardownTest() void {
    host.clearDriver();
    reset();
}

/// テスト用キーコードリゾルバ: row/col から直接キーコードに変換
/// (0,0)=KC.J, (0,1)=KC.K, (0,2)=KC.L, (0,3)=KC.A
fn testKeycodeResolver(ev: KeyEvent) Keycode {
    const map = [4]Keycode{ KC.J, KC.K, KC.L, KC.A };
    if (ev.key.col < map.len) return map[ev.key.col];
    return KC.NO;
}

const test_combos = [_]ComboDefinition{
    .{ .key1 = KC.J, .key2 = KC.K, .result = KC.ESCAPE },
};

test "combo: 2キー同時押しでコンボ発動" {
    const driver = setupTest();
    defer teardownTest();

    setComboTable(&test_combos);
    setKeycodeResolver(testKeycodeResolver);

    // J を押す
    var press_j = KeyRecord{ .event = KeyEvent.keyPress(0, 0, timer.read()) };
    const consumed_j = processCombo(&press_j);
    try testing.expect(consumed_j); // バッファリングされる

    // K を押す（COMBO_TERM 内）
    timer.mockAdvance(10);
    var press_k = KeyRecord{ .event = KeyEvent.keyPress(0, 1, timer.read()) };
    const consumed_k = processCombo(&press_k);
    try testing.expect(consumed_k);

    // コンボが発動し、ESC が登録されるはず
    try testing.expect(driver.keyboard_count >= 1);
    try testing.expect(driver.lastKeyboardReport().hasKey(KC.ESCAPE));
}

test "combo: COMBO_TERM 超過でバッファ吐き出し" {
    const driver = setupTest();
    defer teardownTest();

    setComboTable(&test_combos);
    setKeycodeResolver(testKeycodeResolver);

    // J を押す
    var press_j = KeyRecord{ .event = KeyEvent.keyPress(0, 0, timer.read()) };
    _ = processCombo(&press_j);

    // COMBO_TERM を超過
    timer.mockAdvance(COMBO_TERM + 10);
    comboTask();

    // バッファが吐き出され、J が通常キーとして処理されるはず
    try testing.expect(driver.keyboard_count >= 1);
    try testing.expect(driver.lastKeyboardReport().hasKey(KC.J));
}

test "combo: コンボキー以外のキーでバッファ吐き出し" {
    const driver = setupTest();
    defer teardownTest();

    setComboTable(&test_combos);
    setKeycodeResolver(testKeycodeResolver);

    // J を押す（コンボキー）
    var press_j = KeyRecord{ .event = KeyEvent.keyPress(0, 0, timer.read()) };
    _ = processCombo(&press_j);

    // A を押す（コンボキーではない）
    timer.mockAdvance(5);
    var press_a = KeyRecord{ .event = KeyEvent.keyPress(0, 3, timer.read()) };
    const consumed_a = processCombo(&press_a);
    try testing.expect(!consumed_a); // コンボキーではないので消費されない

    // J が通常キーとして処理されるはず
    try testing.expect(driver.keyboard_count >= 1);
    try testing.expect(driver.lastKeyboardReport().hasKey(KC.J));
}

test "combo: コンボ発動後のリリースでキーが解除される" {
    const driver = setupTest();
    defer teardownTest();

    setComboTable(&test_combos);
    setKeycodeResolver(testKeycodeResolver);

    // J + K でコンボ発動
    var press_j = KeyRecord{ .event = KeyEvent.keyPress(0, 0, timer.read()) };
    _ = processCombo(&press_j);
    timer.mockAdvance(5);
    var press_k = KeyRecord{ .event = KeyEvent.keyPress(0, 1, timer.read()) };
    _ = processCombo(&press_k);

    // ESC が登録されている
    try testing.expect(driver.lastKeyboardReport().hasKey(KC.ESCAPE));

    // J をリリース
    timer.mockAdvance(10);
    var release_j = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, timer.read()) };
    _ = processCombo(&release_j);

    // K をリリース → 最後のキーなのでコンボ解除
    timer.mockAdvance(5);
    var release_k = KeyRecord{ .event = KeyEvent.keyRelease(0, 1, timer.read()) };
    _ = processCombo(&release_k);

    // ESC が解除されている
    try testing.expect(!driver.lastKeyboardReport().hasKey(KC.ESCAPE));
}

test "combo: 無効化時はコンボが発動しない" {
    const driver = setupTest();
    defer teardownTest();

    setComboTable(&test_combos);
    setKeycodeResolver(testKeycodeResolver);
    disable();

    var press_j = KeyRecord{ .event = KeyEvent.keyPress(0, 0, timer.read()) };
    const consumed = processCombo(&press_j);
    try testing.expect(!consumed);

    // レポートは送信されない
    try testing.expectEqual(@as(usize, 0), driver.keyboard_count);
}

test "combo: enable/disable/toggle" {
    reset();

    try testing.expect(isEnabled());
    disable();
    try testing.expect(!isEnabled());
    enable();
    try testing.expect(isEnabled());
    toggle();
    try testing.expect(!isEnabled());
    toggle();
    try testing.expect(isEnabled());
}

test "combo: 複数コンボ定義" {
    const driver = setupTest();
    defer teardownTest();

    const multi_combos = [_]ComboDefinition{
        .{ .key1 = KC.J, .key2 = KC.K, .result = KC.ESCAPE },
        .{ .key1 = KC.K, .key2 = KC.L, .result = KC.TAB },
    };
    setComboTable(&multi_combos);
    setKeycodeResolver(testKeycodeResolver);

    // K + L でコンボ発動
    var press_k = KeyRecord{ .event = KeyEvent.keyPress(0, 1, timer.read()) };
    _ = processCombo(&press_k);
    timer.mockAdvance(5);
    var press_l = KeyRecord{ .event = KeyEvent.keyPress(0, 2, timer.read()) };
    _ = processCombo(&press_l);

    // TAB が登録される（ESC ではない）
    try testing.expect(driver.lastKeyboardReport().hasKey(KC.TAB));
    try testing.expect(!driver.lastKeyboardReport().hasKey(KC.ESCAPE));
}

test "combo: コンボ解除後に別のコンボが発動できる" {
    const driver = setupTest();
    defer teardownTest();

    const multi_combos = [_]ComboDefinition{
        .{ .key1 = KC.J, .key2 = KC.K, .result = KC.ESCAPE },
        .{ .key1 = KC.K, .key2 = KC.L, .result = KC.TAB },
    };
    setComboTable(&multi_combos);
    setKeycodeResolver(testKeycodeResolver);

    // 1回目: J+K でコンボ発動 → ESC
    var press_j = KeyRecord{ .event = KeyEvent.keyPress(0, 0, timer.read()) };
    _ = processCombo(&press_j);
    timer.mockAdvance(5);
    var press_k = KeyRecord{ .event = KeyEvent.keyPress(0, 1, timer.read()) };
    _ = processCombo(&press_k);
    try testing.expect(driver.lastKeyboardReport().hasKey(KC.ESCAPE));

    // J・K をリリース → コンボ解除
    timer.mockAdvance(10);
    var release_j = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, timer.read()) };
    _ = processCombo(&release_j);
    timer.mockAdvance(5);
    var release_k = KeyRecord{ .event = KeyEvent.keyRelease(0, 1, timer.read()) };
    _ = processCombo(&release_k);
    try testing.expect(!driver.lastKeyboardReport().hasKey(KC.ESCAPE));

    // 2回目: K+L でコンボ発動 → TAB（disabled フラグがリセットされていること）
    timer.mockAdvance(50);
    var press_k2 = KeyRecord{ .event = KeyEvent.keyPress(0, 1, timer.read()) };
    _ = processCombo(&press_k2);
    timer.mockAdvance(5);
    var press_l = KeyRecord{ .event = KeyEvent.keyPress(0, 2, timer.read()) };
    _ = processCombo(&press_l);
    try testing.expect(driver.lastKeyboardReport().hasKey(KC.TAB));
}
