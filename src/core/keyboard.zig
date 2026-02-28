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
const tap_dance = @import("tap_dance.zig");
const leader = @import("leader.zig");
const tri_layer = @import("tri_layer.zig");
const timer = @import("../hal/timer.zig");
const caps_word = @import("caps_word.zig");
const repeat_key = @import("repeat_key.zig");
const layer_lock = @import("layer_lock.zig");
const space_cadet = @import("space_cadet.zig");
const key_override = @import("key_override.zig");
const autocorrect = @import("autocorrect.zig");
const secure = @import("secure.zig");
const magic = @import("magic.zig");

const KeyEvent = event_mod.KeyEvent;
const KeyRecord = event_mod.KeyRecord;
const Keycode = keycode.Keycode;
const Action = action_code.Action;

pub const MATRIX_ROWS = keymap_mod.MATRIX_ROWS;
pub const MATRIX_COLS = keymap_mod.MATRIX_COLS;

/// マトリックス状態: 各行のビットマスク（テスト時は外部から設定可能）
var matrix_state: [MATRIX_ROWS]u32 = .{0} ** MATRIX_ROWS;
var matrix_prev: [MATRIX_ROWS]u32 = .{0} ** MATRIX_ROWS;

/// Secure アンロック中に消費されたキーの追跡ビットマスク
/// PENDING 中にプレスされたキーのリリースを抑制するために使用
var secure_consumed: [MATRIX_ROWS]u32 = .{0} ** MATRIX_ROWS;

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
    tap_dance.reset();
    leader.reset();
    tri_layer.reset();
    caps_word.reset();
    repeat_key.reset();
    layer_lock.reset();
    space_cadet.reset();
    key_override.reset();
    autocorrect.reset();
    secure.reset();
    matrix_state = .{0} ** MATRIX_ROWS;
    matrix_prev = .{0} ** MATRIX_ROWS;
    secure_consumed = .{0} ** MATRIX_ROWS;
    test_keymap = keymap_mod.emptyKeymap();
}

/// テスト用: フル初期化（ドライバ設定 + アクションリゾルバ設定含む）
pub fn initTest(driver: host.HostDriver) void {
    init();
    timer.mockReset();
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

                    // Layer Lock アクティビティトリガー:
                    // C版 process_layer_lock() 互換で全キーイベントでタイムアウトをリセット
                    layer_lock.activityTrigger();

                    // Secure プリプロセス: アンロック中はキー入力をシーケンス照合に使用
                    // C版 preprocess_secure() 互換:
                    //   press イベントはシーケンス照合に渡す（離しイベントはスキップ、
                    //   ホールド中のキーのリリースで誤って照合が失敗しないように）
                    //   シーケンス完了で内部状態が変化しても、そのイベントは通常処理しない
                    if (secure.isUnlocking()) {
                        if (pressed) {
                            secure.keypressEvent(@intCast(row), @intCast(col));
                            secure_consumed[row] |= bit;
                        }
                        continue;
                    }

                    // PENDING 中に消費されたキーのリリースを抑制
                    // （シーケンス完了で UNLOCKED に遷移した後、最終キーのリリースが
                    //  通常処理に漏れてレポート送信されるのを防ぐ）
                    if (!pressed and (secure_consumed[row] & bit != 0)) {
                        secure_consumed[row] &= ~bit;
                        continue;
                    }

                    // キーコードを解決し、Tap Dance / Leader Key ならインターセプト
                    const kc = resolveKeycode(ev);
                    if (keycode.isTapDance(kc)) {
                        // Tap Dance プリプロセス: 別キー押下でアクティブな TD を確定
                        _ = tap_dance.preprocess(kc, pressed);
                        // Tap Dance 処理
                        _ = tap_dance.process(kc, pressed);
                    } else if (tri_layer.processTriLayer(kc, pressed)) {
                        // Tri Layer として処理済み: アクションパイプラインに渡さない
                    } else if (leader.processKeycode(kc, pressed)) {
                        // Leader Key として処理済み: アクションパイプラインに渡さない
                    } else {
                        // 非TD/非Leader キー: まず TD 確定を行う
                        if (pressed) {
                            _ = tap_dance.preprocess(kc, pressed);
                        }
                        // Key Override プリプロセス: オーバーライド条件に一致すれば消費
                        const ko_pass = key_override.processKeyOverride(kc, pressed);
                        if (ko_pass and space_cadet.process(kc, pressed)) {
                            // Space Cadet プリプロセス: SC キーなら消費、通常キーなら sc_last リセット
                            // Space Cadet が処理しなかった → Autocorrect → 通常アクションパイプラインへ
                            // 注意: tap_count=1 は固定値。タッピング判定（actionExec）の前に
                            // 呼ばれるため正確な tap_count は利用不可。Mod-Tap/Layer-Tap の
                            // ホールド時は filterKeycode で skip されず基本キーコードが抽出される
                            // が、ホールド中は actionExec 側でキーが処理されるため実害はない。
                            // Magic キーコード処理（CL_SWAP, AG_TOGG 等）
                            if (magic.process(kc, pressed) and autocorrect.process(kc, pressed, 1)) {
                                // Secure キーコード処理（SE_LOCK/SE_UNLK/SE_TOGG/SE_REQ）
                                if (secure.processKeycode(kc, pressed)) {
                                    var record = KeyRecord{ .event = ev };
                                    action.actionExec(&record);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // tick イベントを送信（タッピングのタイムアウト処理用）
    var tick_record = KeyRecord{ .event = KeyEvent.tick(time) };
    action.actionExec(&tick_record);

    // Tap Dance タイムアウト処理
    tap_dance.task();

    // Leader Key タイムアウト処理
    leader.leaderTask();

    // Key Override 遅延登録処理
    key_override.task();

    // Secure タイムアウト処理
    secure.task();

    // Layer Lock タイムアウト・レイヤー状態同期処理
    layer_lock.task();
    layer_lock.syncWithLayerState();

    // 現在の状態を保存
    matrix_prev = matrix_state;
}

/// キーコードをキーマップから解決する（Tap Dance 判定用）
/// pressed 時はソースレイヤーキャッシュも更新する（TD ブランチでも正しいレイヤーが使われるように）
fn resolveKeycode(ev: KeyEvent) Keycode {
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
    return keymap_mod.keymapKeyToKeycode(&test_keymap, use_layer, ev.key.row, ev.key.col);
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
    action.setLastResolvedKeycode(kc);
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

test "keyboard_task: TD()タップダンスがパイプライン経由で動作する" {
    const mock = setup();
    defer teardown();

    // Tap Dance テーブルを設定
    const td_actions = [_]tap_dance.TapDanceAction{
        .{ .on_tap = keycode.KC.A, .on_double_tap = keycode.KC.B, .on_hold = keycode.KC.LEFT_SHIFT },
    };
    tap_dance.setActions(&td_actions);
    defer tap_dance.reset();

    // (0,0) に TD(0) を配置
    test_keymap[0][0][0] = keycode.TD(0);

    // TD キーをプレス→リリース（1タップ）
    pressKey(0, 0);
    task();
    releaseKey(0, 0);
    task();

    // TAPPING_TERM 経過でダンス確定
    timer.mockAdvance(tap_dance.TAPPING_TERM + 1);
    task();

    // KC_A (0x04) が送信されているはず
    try testing.expect(mock.keyboard_count >= 1);
    var found_a = false;
    for (0..@min(mock.keyboard_count, 64)) |i| {
        if (mock.keyboard_reports[i].hasKey(0x04)) {
            found_a = true;
            break;
        }
    }
    try testing.expect(found_a);
}

test "keyboard_task: Caps Word トグルが動作する" {
    _ = setup();
    defer teardown();

    // (0,0) = CW_TOGG, (0,1) = KC_A
    test_keymap[0][0][0] = keycode.CW_TOGG;
    test_keymap[0][0][1] = keycode.KC.A;

    try testing.expect(!caps_word.isActive());

    // CW_TOGG を押す -> Caps Word が有効化される
    pressKey(0, 0);
    task();
    try testing.expect(caps_word.isActive());

    // CW_TOGG を離す
    releaseKey(0, 0);
    task();
    try testing.expect(caps_word.isActive()); // 有効のまま

    // もう一度 CW_TOGG を押す -> 無効化
    pressKey(0, 0);
    task();
    try testing.expect(!caps_word.isActive());

    releaseKey(0, 0);
    task();
}

test "keyboard_task: Caps Word で英字キーに LSHIFT が適用される" {
    const mock = setup();
    defer teardown();

    // (0,0) = CW_TOGG, (0,1) = KC_A
    test_keymap[0][0][0] = keycode.CW_TOGG;
    test_keymap[0][0][1] = keycode.KC.A;

    // Caps Word を有効化
    pressKey(0, 0);
    task();
    releaseKey(0, 0);
    task();
    try testing.expect(caps_word.isActive());

    // KC_A を押す -> LSHIFT が weak mods に追加されレポートに反映される
    pressKey(0, 1);
    task();

    try testing.expect(mock.lastKeyboardReport().hasKey(keycode.KC.A));
    try testing.expectEqual(
        report_mod.ModBit.LSHIFT,
        mock.lastKeyboardReport().mods & report_mod.ModBit.LSHIFT,
    );

    releaseKey(0, 1);
    task();
}

test "keyboard_task: Repeat Key が直前のキーを再送する" {
    const mock = setup();
    defer teardown();

    // (0,0) = KC_A, (0,1) = QK_REP
    test_keymap[0][0][0] = keycode.KC.A;
    test_keymap[0][0][1] = keycode.QK_REP;

    // KC_A を押す
    pressKey(0, 0);
    task();
    try testing.expect(mock.lastKeyboardReport().hasKey(keycode.KC.A));

    // KC_A を離す
    releaseKey(0, 0);
    task();

    // QK_REP を押す -> KC_A が再送される
    pressKey(0, 1);
    task();
    try testing.expect(mock.lastKeyboardReport().hasKey(keycode.KC.A));

    // QK_REP を離す
    releaseKey(0, 1);
    task();
    try testing.expect(!mock.lastKeyboardReport().hasKey(keycode.KC.A));
}

test "keyboard_task: Layer Lock がレイヤーをロックする" {
    _ = setup();
    defer teardown();

    const TAPPING_TERM = tapping.TAPPING_TERM;

    // Layer 0: (0,0) = MO(1), (0,1) = KC_A
    // Layer 1: (0,1) = QK_LLCK
    test_keymap[0][0][0] = keycode.MO(1);
    test_keymap[0][0][1] = keycode.KC.A;
    test_keymap[1][0][1] = keycode.QK_LLCK;

    // MO(1) を押してホールド
    pressKey(0, 0);
    task();
    timer.mockAdvance(TAPPING_TERM + 1);
    task();
    try testing.expect(layer.layerStateIs(1));

    // Layer Lock を押す -> レイヤー1がロックされる
    pressKey(0, 1);
    task();
    try testing.expect(layer_lock.isLayerLocked(1));
    try testing.expect(layer.layerStateIs(1));

    // Layer Lock を離す
    releaseKey(0, 1);
    task();

    // MO(1) を離す -> ロックされているのでレイヤー1は維持される
    releaseKey(0, 0);
    task();
    // Layer Lock がロック中のレイヤーの layerOff をスキップする
    try testing.expect(layer_lock.isLayerLocked(1));
    try testing.expect(layer.layerStateIs(1)); // レイヤー1はまだアクティブ
}

test "keyboard_task: Layer Lock アイドルタイムアウトが他キー入力でリセットされる" {
    _ = setup();
    defer teardown();

    const TAPPING_TERM = tapping.TAPPING_TERM;
    const TIMEOUT: u32 = 5000;

    // Layer 0: (0,0) = MO(1), (0,1) = KC_A
    // Layer 1: (0,1) = QK_LLCK, (0,2) = KC_B
    test_keymap[0][0][0] = keycode.MO(1);
    test_keymap[0][0][1] = keycode.KC.A;
    test_keymap[1][0][1] = keycode.QK_LLCK;
    test_keymap[1][0][2] = keycode.KC.B;

    // アイドルタイムアウトを設定
    layer_lock.idle_timeout = TIMEOUT;

    // MO(1) を押してホールド確定
    pressKey(0, 0);
    task();
    timer.mockAdvance(TAPPING_TERM + 1);
    task();
    try testing.expect(layer.layerStateIs(1));

    // Layer Lock を押してレイヤー1をロック
    pressKey(0, 1);
    task();
    try testing.expect(layer_lock.isLayerLocked(1));
    releaseKey(0, 1);
    task();

    // MO(1) を離す（ロック中なのでレイヤー1は維持）
    releaseKey(0, 0);
    task();
    try testing.expect(layer_lock.isLayerLocked(1));
    try testing.expect(layer.layerStateIs(1));

    // タイムアウトの半分経過
    timer.mockAdvance(TIMEOUT / 2);
    task();
    try testing.expect(layer_lock.isLayerLocked(1)); // まだロック中

    // 別のキーを押す -> activityTrigger によりタイマーリセット
    pressKey(0, 2);
    task();
    releaseKey(0, 2);
    task();

    // さらにタイムアウトの半分+少し経過（リセットされなければタイムアウト超過）
    timer.mockAdvance(TIMEOUT / 2 + 100);
    task();
    // activityTrigger でリセットされているので、まだロック中のはず
    try testing.expect(layer_lock.isLayerLocked(1));
    try testing.expect(layer.layerStateIs(1));

    // さらにタイムアウト分経過 → タイムアウトでロック解除
    timer.mockAdvance(TIMEOUT);
    task();
    try testing.expect(!layer_lock.isLayerLocked(1));
}

test "keyboard_task: Tri Layer — Lower+Upper で Adjust が有効になる" {
    _ = setup();
    defer teardown();

    // (0,0) = TL_LOWR, (0,1) = TL_UPPR（layer 0）
    test_keymap[0][0][0] = keycode.TL_LOWR;
    test_keymap[0][0][1] = keycode.TL_UPPR;
    // 上位レイヤーはフォールスルーさせる
    for (1..keymap_mod.MAX_LAYERS) |l| {
        test_keymap[l][0][0] = keycode.KC.TRNS;
        test_keymap[l][0][1] = keycode.KC.TRNS;
    }

    // Lower を押す -> レイヤー1のみ
    pressKey(0, 0);
    task();
    try testing.expect(layer.layerStateIs(1));
    try testing.expect(!layer.layerStateIs(3));

    // Upper を押す -> レイヤー1+2+3(adjust)
    pressKey(0, 1);
    task();
    try testing.expect(layer.layerStateIs(1));
    try testing.expect(layer.layerStateIs(2));
    try testing.expect(layer.layerStateIs(3));

    // Lower を離す -> adjust が OFF
    releaseKey(0, 0);
    task();
    try testing.expect(!layer.layerStateIs(1));
    try testing.expect(!layer.layerStateIs(3));
    try testing.expect(layer.layerStateIs(2));

    // Upper を離す
    releaseKey(0, 1);
    task();
    try testing.expect(!layer.layerStateIs(2));
}
