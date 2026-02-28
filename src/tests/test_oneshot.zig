// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! One-Shot Mods (OSM) テスト
//!
//! OSM の動作を tapping パイプライン経由で検証する。
//!
//! テストケース:
//! 1. OsmTapAppliesModToNextKey           — OSM タップ → 次キーに修飾適用 → その後は不適用
//! 2. OsmHoldActsAsNormalModifier         — OSM ホールド → 通常の修飾キーと同様
//! 3. OsmWithoutAdditionalKeypressDoesNothing — OSM タップのみ → キーレポートなし
//! 4. OsmChainingTwoOSMs                  — OSM(LSFT) + OSM(LCTL) → 次キーに両方適用
//! 5. OsmHoldWithRegularKey               — OSM ホールド中に通常キー → mod+key
//! 6. OsmRightModTap                      — OSM(RSFT) タップ → 右シフトが次キーに適用
//! 7. OsmAllLeftMods                      — 全左修飾キーの OSM タップ → 各modが正しく適用
//! 8. OsmAllRightMods                     — 全右修飾キーの OSM タップ → 各modが正しく適用

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
//   (0,2) = OSM(LCTL) → ACTION_MODS_ONESHOT(Mod.LCTL)
//   (0,3) = OSM(RSFT) → right shift one-shot (C版互換直接値)
//   (0,4) = OSM(LALT) → ACTION_MODS_ONESHOT(Mod.LALT)
//   (0,5) = OSM(LGUI) → ACTION_MODS_ONESHOT(Mod.LGUI)
//   (0,6) = OSM(RCTL) → right ctrl one-shot (C版互換直接値)
//   (0,7) = OSM(RALT) → right alt one-shot (C版互換直接値)
//   (1,0) = OSM(RGUI) → right gui one-shot (C版互換直接値)

fn testActionResolver(ev: KeyEvent) Action {
    if (ev.key.row == 0) {
        return switch (ev.key.col) {
            0 => .{ .code = action_code.ACTION_MODS_ONESHOT(Mod.LSFT) },
            1 => .{ .code = action_code.ACTION_KEY(@truncate(KC.A)) },
            2 => .{ .code = action_code.ACTION_MODS_ONESHOT(Mod.LCTL) },
            // OSM(RSFT): ACTION(ACT_RMODS_TAP, RSFT_5bit<<8 | MODS_ONESHOT)
            3 => .{ .code = action_code.ACTION(@intFromEnum(action_code.ActionKind.rmods_tap), @as(u12, 0x02) << 8 | @as(u12, action_code.MODS_ONESHOT)) },
            4 => .{ .code = action_code.ACTION_MODS_ONESHOT(Mod.LALT) },
            5 => .{ .code = action_code.ACTION_MODS_ONESHOT(Mod.LGUI) },
            // OSM(RCTL): ACTION(ACT_RMODS_TAP, RCTL_5bit<<8 | MODS_ONESHOT)
            6 => .{ .code = action_code.ACTION(@intFromEnum(action_code.ActionKind.rmods_tap), @as(u12, 0x01) << 8 | @as(u12, action_code.MODS_ONESHOT)) },
            // OSM(RALT): ACTION(ACT_RMODS_TAP, RALT_5bit<<8 | MODS_ONESHOT)
            7 => .{ .code = action_code.ACTION(@intFromEnum(action_code.ActionKind.rmods_tap), @as(u12, 0x04) << 8 | @as(u12, action_code.MODS_ONESHOT)) },
            else => .{ .code = action_code.ACTION_NO },
        };
    }
    if (ev.key.row == 1) {
        return switch (ev.key.col) {
            // OSM(RGUI): ACTION(ACT_RMODS_TAP, RGUI_5bit<<8 | MODS_ONESHOT)
            0 => .{ .code = action_code.ACTION(@intFromEnum(action_code.ActionKind.rmods_tap), @as(u12, 0x08) << 8 | @as(u12, action_code.MODS_ONESHOT)) },
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

/// レポート内でキー+modsが見つかるか検索
fn findReportWithKeyAndMods(mock: *const MockDriver, start: usize, key: u8, mods_mask: u8, mods_expected: bool) bool {
    var i: usize = start;
    while (i < mock.keyboard_count) : (i += 1) {
        const has_key = mock.keyboard_reports[i].hasKey(key);
        const has_mods = (mock.keyboard_reports[i].mods & mods_mask) != 0;
        if (has_key and (has_mods == mods_expected)) {
            return true;
        }
    }
    return false;
}

/// レポート内で指定modsが見つかるか検索
fn findReportWithMods(mock: *const MockDriver, start: usize, mods_mask: u8) bool {
    var i: usize = start;
    while (i < mock.keyboard_count) : (i += 1) {
        if ((mock.keyboard_reports[i].mods & mods_mask) != 0) {
            return true;
        }
    }
    return false;
}

// ============================================================
// 1. OsmTapAppliesModToNextKey
//    OSM(LSFT) をタップ → 次の KC_A にシフトが適用 → その後は不適用
//    C版 OSMWithAdditionalKeypress 相当
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
    try testing.expect(findReportWithKeyAndMods(mock, count_before_a, 0x04, report_mod.ModBit.LSHIFT, true));

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
    try testing.expect(findReportWithKeyAndMods(mock, count_before_a2, 0x04, report_mod.ModBit.LSHIFT, false));

    release(0, 1, 350);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// ============================================================
// 2. OsmHoldActsAsNormalModifier
//    OSM(LSFT) をホールド → 通常の LSHIFT として動作
//    C版 OSMAsRegularModifierWithAdditionalKeypress 相当
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
    try testing.expect(findReportWithMods(mock, 0, report_mod.ModBit.LSHIFT));

    // oneshot_mods は設定されない（ホールド動作）
    try testing.expectEqual(@as(u8, 0), host_mod.getOneshotMods());

    // リリース → 修飾キーがクリアされる
    release(0, 0, 100 + TAPPING_TERM + 50);
    try testing.expectEqual(@as(u8, 0), mock.lastKeyboardReport().mods);
}

// ============================================================
// 3. OsmWithoutAdditionalKeypressDoesNothing
//    OSM(LSFT) をタップ（追加キーなし） → レポートは送信されない
//    C版 OSMWithoutAdditionalKeypressDoesNothing 相当
// ============================================================

test "OsmWithoutAdditionalKeypressDoesNothing" {
    const mock = setup();
    defer teardown();

    const count_before = mock.keyboard_count;

    // OSM(LSFT) をタップ
    press(0, 0, 100);
    release(0, 0, 150);

    // OSM タップのみではキーボードレポートが送信されない（OSMは次キーまで保留）
    // C版 OSMWithoutAdditionalKeypressDoesNothing と同等:
    // OSM のタップはレポートを発行せず、oneshot_mods を設定するのみ
    try testing.expectEqual(count_before, mock.keyboard_count);

    // oneshot_mods は設定されている（次のキー入力を待っている状態）
    try testing.expectEqual(@as(u8, 0x02), host_mod.getOneshotMods());

    // oneshot_mods クリア
    host_mod.clearOneshotMods();
}

// ============================================================
// 4. OsmChainingTwoOSMs
//    OSM(LSFT) タップ → OSM(LCTL) タップ → 次キーに両方適用
//    C版 OSMChainingTwoOSMs 相当
// ============================================================

test "OsmChainingTwoOSMs" {
    const mock = setup();
    defer teardown();

    // OSM(LSFT) をタップ
    press(0, 0, 100);
    release(0, 0, 150);

    // TAPPING_TERM + 1 待機してタッピング状態をリセット
    tick(150 + TAPPING_TERM + 1);

    // oneshot_mods に LSHIFT が設定されている
    try testing.expect(host_mod.getOneshotMods() & report_mod.ModBit.LSHIFT != 0);

    // OSM(LCTL) をタップ
    press(0, 2, 400);
    release(0, 2, 450);

    // TAPPING_TERM + 1 待機
    tick(450 + TAPPING_TERM + 1);

    // oneshot_mods に LSHIFT と LCTRL の両方が設定されている
    const osm = host_mod.getOneshotMods();
    try testing.expect(osm & report_mod.ModBit.LSHIFT != 0);
    try testing.expect(osm & report_mod.ModBit.LCTRL != 0);

    // KC_A を押す → 両方の修飾が適用される
    const count_before = mock.keyboard_count;
    press(0, 1, 700);

    try testing.expect(mock.keyboard_count > count_before);

    // LSHIFT + LCTRL + KC_A が含まれるレポートを検索
    var found = false;
    var i: usize = count_before;
    while (i < mock.keyboard_count) : (i += 1) {
        if (mock.keyboard_reports[i].hasKey(0x04) and
            mock.keyboard_reports[i].mods & report_mod.ModBit.LSHIFT != 0 and
            mock.keyboard_reports[i].mods & report_mod.ModBit.LCTRL != 0)
        {
            found = true;
            break;
        }
    }
    try testing.expect(found);

    // oneshot_mods がクリアされている
    try testing.expectEqual(@as(u8, 0), host_mod.getOneshotMods());

    // KC_A をリリース
    release(0, 1, 750);
    try testing.expect(mock.lastKeyboardReport().isEmpty());

    // もう一度 KC_A を押す → 修飾なし
    const count_before2 = mock.keyboard_count;
    press(0, 1, 800);
    try testing.expect(mock.keyboard_count > count_before2);
    try testing.expect(findReportWithKeyAndMods(mock, count_before2, 0x04, report_mod.ModBit.LSHIFT, false));

    release(0, 1, 850);
}

// ============================================================
// 5. OsmHoldWithRegularKey
//    OSM(LSFT) ホールド中に KC_A → LSHIFT+A として動作
//    C版 OSMAsRegularModifierWithAdditionalKeypress の詳細版
// ============================================================

test "OsmHoldWithRegularKey" {
    const mock = setup();
    defer teardown();

    // OSM(LSFT) をプレス
    press(0, 0, 100);

    // TAPPING_TERM 超過 → ホールド動作（通常修飾キー）
    tick(100 + TAPPING_TERM + 1);

    // LSHIFT がレポートされている
    try testing.expect(findReportWithMods(mock, 0, report_mod.ModBit.LSHIFT));

    // KC_A を押す
    const count_before = mock.keyboard_count;
    press(0, 1, 100 + TAPPING_TERM + 10);

    // LSHIFT + KC_A がレポートされる
    try testing.expect(findReportWithKeyAndMods(mock, count_before, 0x04, report_mod.ModBit.LSHIFT, true));

    // KC_A をリリース
    release(0, 1, 100 + TAPPING_TERM + 60);

    // OSM(LSFT) をリリース
    release(0, 0, 100 + TAPPING_TERM + 70);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// ============================================================
// 6. OsmRightModTap
//    OSM(RSFT) タップ → 次キーに右シフトが適用
// ============================================================

test "OsmRightModTap" {
    const mock = setup();
    defer teardown();

    // OSM(RSFT) をタップ (row=0, col=3)
    press(0, 3, 100);
    release(0, 3, 150);

    // oneshot_mods に RSHIFT (0x20) が設定されている
    try testing.expectEqual(@as(u8, report_mod.ModBit.RSHIFT), host_mod.getOneshotMods());

    // TAPPING_TERM + 1 待機
    tick(150 + TAPPING_TERM + 1);

    // KC_A を押す
    const count_before = mock.keyboard_count;
    press(0, 1, 400);
    try testing.expect(mock.keyboard_count > count_before);

    // RSHIFT + KC_A が含まれるレポートを確認
    try testing.expect(findReportWithKeyAndMods(mock, count_before, 0x04, report_mod.ModBit.RSHIFT, true));

    // oneshot_mods がクリアされている
    try testing.expectEqual(@as(u8, 0), host_mod.getOneshotMods());

    release(0, 1, 450);
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

// ============================================================
// 7. OsmAllLeftMods
//    全左修飾キーの OSM タップ → 各 mod が正しく次キーに適用される
//    C版 INSTANTIATE_TEST_CASE_P の左修飾版
// ============================================================

test "OsmAllLeftMods" {
    // OSM(LCTL) テスト
    {
        const mock = setup();
        defer teardown();

        press(0, 2, 100); // OSM(LCTL)
        release(0, 2, 150);
        try testing.expect(host_mod.getOneshotMods() & report_mod.ModBit.LCTRL != 0);

        tick(150 + TAPPING_TERM + 1);

        const count_before = mock.keyboard_count;
        press(0, 1, 400); // KC_A
        try testing.expect(mock.keyboard_count > count_before);
        try testing.expect(findReportWithKeyAndMods(mock, count_before, 0x04, report_mod.ModBit.LCTRL, true));
        try testing.expectEqual(@as(u8, 0), host_mod.getOneshotMods());
        release(0, 1, 450);
    }

    // OSM(LALT) テスト
    {
        const mock = setup();
        defer teardown();

        press(0, 4, 100); // OSM(LALT)
        release(0, 4, 150);
        try testing.expect(host_mod.getOneshotMods() & report_mod.ModBit.LALT != 0);

        tick(150 + TAPPING_TERM + 1);

        const count_before = mock.keyboard_count;
        press(0, 1, 400);
        try testing.expect(mock.keyboard_count > count_before);
        try testing.expect(findReportWithKeyAndMods(mock, count_before, 0x04, report_mod.ModBit.LALT, true));
        try testing.expectEqual(@as(u8, 0), host_mod.getOneshotMods());
        release(0, 1, 450);
    }

    // OSM(LGUI) テスト
    {
        const mock = setup();
        defer teardown();

        press(0, 5, 100); // OSM(LGUI)
        release(0, 5, 150);
        try testing.expect(host_mod.getOneshotMods() & report_mod.ModBit.LGUI != 0);

        tick(150 + TAPPING_TERM + 1);

        const count_before = mock.keyboard_count;
        press(0, 1, 400);
        try testing.expect(mock.keyboard_count > count_before);
        try testing.expect(findReportWithKeyAndMods(mock, count_before, 0x04, report_mod.ModBit.LGUI, true));
        try testing.expectEqual(@as(u8, 0), host_mod.getOneshotMods());
        release(0, 1, 450);
    }
}

// ============================================================
// 8. OsmAllRightMods
//    全右修飾キーの OSM タップ → 各 mod が正しく次キーに適用される
//    C版 INSTANTIATE_TEST_CASE_P の右修飾版
// ============================================================

test "OsmAllRightMods" {
    // OSM(RCTL) テスト
    {
        const mock = setup();
        defer teardown();

        press(0, 6, 100); // OSM(RCTL)
        release(0, 6, 150);
        try testing.expect(host_mod.getOneshotMods() & report_mod.ModBit.RCTRL != 0);

        tick(150 + TAPPING_TERM + 1);

        const count_before = mock.keyboard_count;
        press(0, 1, 400);
        try testing.expect(mock.keyboard_count > count_before);
        try testing.expect(findReportWithKeyAndMods(mock, count_before, 0x04, report_mod.ModBit.RCTRL, true));
        try testing.expectEqual(@as(u8, 0), host_mod.getOneshotMods());
        release(0, 1, 450);
    }

    // OSM(RALT) テスト
    {
        const mock = setup();
        defer teardown();

        press(0, 7, 100); // OSM(RALT)
        release(0, 7, 150);
        try testing.expect(host_mod.getOneshotMods() & report_mod.ModBit.RALT != 0);

        tick(150 + TAPPING_TERM + 1);

        const count_before = mock.keyboard_count;
        press(0, 1, 400);
        try testing.expect(mock.keyboard_count > count_before);
        try testing.expect(findReportWithKeyAndMods(mock, count_before, 0x04, report_mod.ModBit.RALT, true));
        try testing.expectEqual(@as(u8, 0), host_mod.getOneshotMods());
        release(0, 1, 450);
    }

    // OSM(RGUI) テスト
    {
        const mock = setup();
        defer teardown();

        press(1, 0, 100); // OSM(RGUI)
        release(1, 0, 150);
        try testing.expect(host_mod.getOneshotMods() & report_mod.ModBit.RGUI != 0);

        tick(150 + TAPPING_TERM + 1);

        const count_before = mock.keyboard_count;
        press(0, 1, 400);
        try testing.expect(mock.keyboard_count > count_before);
        try testing.expect(findReportWithKeyAndMods(mock, count_before, 0x04, report_mod.ModBit.RGUI, true));
        try testing.expectEqual(@as(u8, 0), host_mod.getOneshotMods());
        release(0, 1, 450);
    }
}
