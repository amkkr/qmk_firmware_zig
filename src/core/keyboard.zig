//! キーボードメイン処理ループ
//! C版 quantum/keyboard.c に相当
//!
//! keyboard_task(): 1回の呼び出しで1スキャンサイクルを実行
//!   マトリックス状態取得 → 差分検出 → イベント生成 → actionExec()
//!
//! keyboard_init(): 内部状態の初期化

const builtin = @import("builtin");
const action = @import("action.zig");
const action_code = @import("action_code.zig");
const event_mod = @import("event.zig");
pub const host = @import("host.zig");
const layer = @import("layer.zig");
const keymap_mod = @import("keymap.zig");
const keycode = @import("keycode.zig");
const timer = @import("../hal/timer.zig");

const KeyEvent = event_mod.KeyEvent;
const KeyRecord = event_mod.KeyRecord;
const Keycode = keycode.Keycode;
const Action = action_code.Action;

pub const MATRIX_ROWS = keymap_mod.MATRIX_ROWS;
pub const MATRIX_COLS = keymap_mod.MATRIX_COLS;

/// マトリックス状態: 各行のビットマスク（テスト時は外部から設定可能）
var matrix_state: [MATRIX_ROWS]u32 = .{0} ** MATRIX_ROWS;
var matrix_prev: [MATRIX_ROWS]u32 = .{0} ** MATRIX_ROWS;

/// テスト用キーマップ
var test_keymap: keymap_mod.Keymap = keymap_mod.emptyKeymap();

/// テスト用: マトリックス状態を外部から設定
pub fn setMatrixRow(row: u8, value: u32) void {
    if (row < MATRIX_ROWS) {
        matrix_state[row] = value;
    }
}

/// テスト用: 特定キーをプレス
pub fn pressKey(row: u8, col: u8) void {
    if (row < MATRIX_ROWS and col < MATRIX_COLS) {
        matrix_state[row] |= @as(u32, 1) << @intCast(col);
    }
}

/// テスト用: 特定キーをリリース
pub fn releaseKey(row: u8, col: u8) void {
    if (row < MATRIX_ROWS and col < MATRIX_COLS) {
        matrix_state[row] &= ~(@as(u32, 1) << @intCast(col));
    }
}

/// テスト用: 全キーをクリア
pub fn clearAllKeys() void {
    matrix_state = .{0} ** MATRIX_ROWS;
}

/// テスト用キーマップへのアクセス
pub fn getTestKeymap() *keymap_mod.Keymap {
    return &test_keymap;
}

/// テスト用: キーマップに1キー設定
pub fn setTestKey(l: u5, row: u8, col: u8, kc: Keycode) void {
    if (row < MATRIX_ROWS and col < MATRIX_COLS and l < keymap_mod.MAX_LAYERS) {
        test_keymap[l][row][col] = kc;
    }
}

/// 初期化
pub fn init() void {
    action.reset();
    layer.resetState();
    matrix_state = .{0} ** MATRIX_ROWS;
    matrix_prev = .{0} ** MATRIX_ROWS;
    test_keymap = keymap_mod.emptyKeymap();
    timer.mockReset();
}

/// テスト用: フル初期化（ドライバ設定 + アクションリゾルバ設定含む）
pub fn initTest(driver: host.HostDriver) void {
    init();
    host.setDriver(driver);
    action.setActionResolver(keymapActionResolver);
}

/// メイン処理ループ（1スキャンサイクル）
///
/// 実機時: HAL のマトリックススキャンで matrix_state を更新してから呼ぶ
/// テスト時: pressKey/releaseKey で matrix_state を設定してから呼ぶ
pub fn task() void {
    const time = timer.read();

    // 前回状態との差分を検出してイベント生成
    for (0..MATRIX_ROWS) |row| {
        const current = matrix_state[row];
        const previous = matrix_prev[row];
        const changes = current ^ previous;

        if (changes != 0) {
            for (0..MATRIX_COLS) |col| {
                const bit = @as(u32, 1) << @intCast(col);
                if (changes & bit != 0) {
                    const pressed = (current & bit) != 0;
                    const ev = if (pressed)
                        KeyEvent.keyPress(@intCast(row), @intCast(col), time)
                    else
                        KeyEvent.keyRelease(@intCast(row), @intCast(col), time);

                    var record = KeyRecord{ .event = ev };
                    action.actionExec(&record);
                }
            }
        }
    }

    // tick イベントを送信（タッピングのタイムアウト処理用）
    var tick_record = KeyRecord{ .event = KeyEvent.tick(time) };
    action.actionExec(&tick_record);

    // 現在の状態を保存
    matrix_prev = matrix_state;
}

/// キーマップベースのアクションリゾルバ（test_fixture からも使用）
pub fn keymapActionResolver(ev: KeyEvent) Action {
    const km = &test_keymap;

    const keymapFn = struct {
        fn f(l: u5, row: u8, col: u8) Keycode {
            return keymap_mod.keymapKeyToKeycode(&test_keymap, l, row, col);
        }
    }.f;

    const resolved_layer = layer.layerSwitchGetLayer(keymapFn, ev.key.row, ev.key.col);

    if (ev.pressed) {
        layer.updateSourceLayersCache(ev.key.row, ev.key.col, resolved_layer);
    }

    const use_layer = if (ev.pressed) resolved_layer else layer.readSourceLayersCache(ev.key.row, ev.key.col);
    const kc = keymap_mod.keymapKeyToKeycode(km, use_layer, ev.key.row, ev.key.col);
    return action_code.keycodeToAction(kc);
}

// ============================================================
// Tests
// ============================================================

const std = @import("std");
const testing = std.testing;
const report_mod = @import("report.zig");
const tapping = @import("action_tapping.zig");
const FixedTestDriver = @import("test_driver.zig").FixedTestDriver;

const TestMockDriver = FixedTestDriver(64, 16);

var mock_driver: TestMockDriver = .{};

fn setup() *TestMockDriver {
    mock_driver = .{};
    initTest(host.HostDriver.from(&mock_driver));
    return &mock_driver;
}

fn teardown() void {
    host.clearDriver();
}

test "keyboard_task: 単一キー押下→リリースでHIDレポートが正しく生成される" {
    const mock = setup();
    defer teardown();

    // (0,0) に KC_A を配置
    test_keymap[0][0][0] = keycode.KC.A;

    // キーを押す
    pressKey(0, 0);
    task();

    try testing.expect(mock.keyboard_count >= 1);
    try testing.expect(mock.lastKeyboardReport().hasKey(0x04)); // KC_A

    // キーを離す
    releaseKey(0, 0);
    task();

    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

test "keyboard_task: 修飾キーがmodsに正しく反映される" {
    const mock = setup();
    defer teardown();

    // (0,0) に LSHIFT を配置
    test_keymap[0][0][0] = keycode.KC.LEFT_SHIFT;

    pressKey(0, 0);
    task();

    try testing.expect(mock.keyboard_count >= 1);
    try testing.expectEqual(
        report_mod.ModBit.LSHIFT,
        mock.lastKeyboardReport().mods & report_mod.ModBit.LSHIFT,
    );

    releaseKey(0, 0);
    task();

    try testing.expectEqual(@as(u8, 0), mock.lastKeyboardReport().mods);
}

test "keyboard_task: MO()レイヤー切替が動作する" {
    _ = setup();
    defer teardown();

    const TAPPING_TERM = tapping.TAPPING_TERM;

    // Layer 0: (0,0) = MO(1), (0,1) = KC_A
    // Layer 1: (0,1) = KC_B
    test_keymap[0][0][0] = keycode.MO(1);
    test_keymap[0][0][1] = keycode.KC.A;
    test_keymap[1][0][1] = keycode.KC.B;

    // MO(1) をプレス
    pressKey(0, 0);
    task();

    // TAPPING_TERM を超えてホールド確定させる
    timer.mockAdvance(TAPPING_TERM + 1);
    task();

    try testing.expect(layer.layerStateIs(1));

    // MO(1) をリリース
    releaseKey(0, 0);
    task();

    try testing.expect(!layer.layerStateIs(1));
}
