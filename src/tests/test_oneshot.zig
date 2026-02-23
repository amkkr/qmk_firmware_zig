//! One-Shot Mods (OSM) テスト
//!
//! OSM の動作を tapping パイプライン経由で検証する。
//!
//! テストケース:
//! 1. OsmTapAppliesModToNextKey      — OSM タップ → 次キーに修飾適用 → その後は不適用
//! 2. OsmHoldActsAsNormalModifier    — OSM ホールド → 通常の修飾キーと同様

const std = @import("std");
const testing = std.testing;

const action = @import("../core/action.zig");
const action_code = @import("../core/action_code.zig");
const event_mod = @import("../core/event.zig");
const host_mod = @import("../core/host.zig");
const report_mod = @import("../core/report.zig");
const keycode = @import("../core/keycode.zig");
const keymap_mod = @import("../core/keymap.zig");
const layer_mod = @import("../core/layer.zig");
const tapping_mod = @import("../core/action_tapping.zig");

const Action = action_code.Action;
const KeyRecord = event_mod.KeyRecord;
const KeyEvent = event_mod.KeyEvent;
const KC = keycode.KC;
const Mod = keycode.Mod;

const TAPPING_TERM = tapping_mod.TAPPING_TERM;

const MockDriver = @import("../core/test_driver.zig").FixedTestDriver(64, 16);

// ============================================================
// テスト用キーマップリゾルバ
// ============================================================
//
//   (0,0) = OSM(LSFT) → ACTION_MODS_ONESHOT(Mod.LSFT)
//   (0,1) = KC_A      → ACTION_KEY(KC_A)

fn testActionResolver(ev: KeyEvent) Action {
    if (ev.key.row == 0) {
        return switch (ev.key.col) {
            0 => .{ .code = action_code.ACTION_MODS_ONESHOT(Mod.LSFT) },
            1 => .{ .code = action_code.ACTION_KEY(@truncate(KC.A)) },
            else => .{ .code = action_code.ACTION_NO },
        };
    }
    return .{ .code = action_code.ACTION_NO };
}

// ============================================================
// テストヘルパー
// ============================================================

var mock_driver: MockDriver = .{};

fn setup() *MockDriver {
    action.reset();
    keymap_mod.keymap_config.oneshot_enable = true;
    mock_driver = .{};
    host_mod.setDriver(host_mod.HostDriver.from(&mock_driver));
    action.setActionResolver(testActionResolver);
    return &mock_driver;
}

fn teardown() void {
    action.reset();
    host_mod.clearDriver();
}

fn press(row: u8, col: u8, time: u16) void {
    var record = KeyRecord{ .event = KeyEvent.keyPress(row, col, time) };
    action.actionExec(&record);
}

fn release(row: u8, col: u8, time: u16) void {
    var record = KeyRecord{ .event = KeyEvent.keyRelease(row, col, time) };
    action.actionExec(&record);
}

fn tick(time: u16) void {
    var record = KeyRecord{ .event = KeyEvent.tick(time) };
    action.actionExec(&record);
}

// ============================================================
// 1. OsmTapAppliesModToNextKey
//    OSM(LSFT) をタップ → 次の KC_A にシフトが適用 → その後は不適用
// ============================================================

test "OsmTapAppliesModToNextKey" {
    const mock = setup();
    defer teardown();

    // OSM(LSFT) をプレス
    press(0, 0, 100);

    // TAPPING_TERM 以内にリリース → タップとして処理
    release(0, 0, 150);

    // oneshot_mods が設定されている
    try testing.expectEqual(@as(u8, 0x02), host_mod.getOneshotMods());

    // 次のキー KC_A を押す
    const count_before_a = mock.keyboard_count;
    press(0, 1, 200);

    // KC_A + LSHIFT が含まれるレポートが送信される
    try testing.expect(mock.keyboard_count > count_before_a);
    var found_shifted_a = false;
    var i: usize = count_before_a;
    while (i < mock.keyboard_count) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x04) and
            mock.keyboard_reports[i].mods & report_mod.ModBit.LSHIFT != 0)
        {
            found_shifted_a = true;
            break;
        }
    }
    try testing.expect(found_shifted_a);

    // oneshot_mods がクリアされている
    try testing.expectEqual(@as(u8, 0), host_mod.getOneshotMods());

    // KC_A をリリース
    release(0, 1, 250);
    try testing.expect(mock.lastKeyboardReport().isEmpty());

    // さらにもう一度 KC_A を押す → シフトなし
    const count_before_a2 = mock.keyboard_count;
    press(0, 1, 300);
    try testing.expect(mock.keyboard_count > count_before_a2);

    // 最新レポートに LSHIFT が含まれないことを確認
    var found_unshifted_a = false;
    i = count_before_a2;
    while (i < mock.keyboard_count) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x04) and
            mock.keyboard_reports[i].mods & report_mod.ModBit.LSHIFT == 0)
        {
            found_unshifted_a = true;
            break;
        }
    }
    try testing.expect(found_unshifted_a);

    release(0, 1, 350);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// ============================================================
// 2. OsmHoldActsAsNormalModifier
//    OSM(LSFT) をホールド → 通常の LSHIFT として動作
// ============================================================

test "OsmHoldActsAsNormalModifier" {
    const mock = setup();
    defer teardown();

    // OSM(LSFT) をプレス
    press(0, 0, 100);

    // TAPPING_TERM 超過
    tick(100 + TAPPING_TERM + 1);

    // LSHIFT がレポートされる（ホールド動作）
    try testing.expect(mock.keyboard_count >= 1);
    var found_shift = false;
    var i: usize = 0;
    while (i < mock.keyboard_count) : (i += 1) {
        if (mock.keyboard_reports[i].mods & report_mod.ModBit.LSHIFT != 0) {
            found_shift = true;
            break;
        }
    }
    try testing.expect(found_shift);

    // oneshot_mods は設定されない（ホールド動作）
    try testing.expectEqual(@as(u8, 0), host_mod.getOneshotMods());

    // リリース → 修飾キーがクリアされる
    release(0, 0, 100 + TAPPING_TERM + 50);
    try testing.expectEqual(@as(u8, 0), mock.lastKeyboardReport().mods);
}
