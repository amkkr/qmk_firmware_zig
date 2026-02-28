// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Based on TMK/QMK extrakey handling
// Original: Copyright 2012,2013 Jun Wako <wakojun@gmail.com>

//! Extrakey機能 - メディアキー・システムコントロール
//! C版 quantum/action.c の ACT_USAGE 処理に相当
//!
//! HID Usage Tables に基づき、Consumer Control (Page 0x0C) と
//! System Control (Generic Desktop Page 0x01) のキーコードを処理する。

const report_mod = @import("report.zig");
const host = @import("host.zig");
const keycode_mod = @import("keycode.zig");
const event_mod = @import("event.zig");

const ExtraReport = report_mod.ExtraReport;
const KC = keycode_mod.KC;

// ============================================================
// Usage Page 定数（action_code.zig の循環インポートを避けるためローカル定義）
// ============================================================

/// ACT_USAGE の kind ID (0b0100 = 4)
const ACT_USAGE: u4 = 0b0100;

/// Usage page IDs（action_code.UsagePage と同一値）
const PAGE_SYSTEM: u2 = 1;
const PAGE_CONSUMER: u2 = 2;

/// Action の usage フィールドを解釈する packed struct
/// action_code.Action.usage と同一レイアウト
const UsageAction = packed struct {
    code: u10,
    page: u2,
    kind: u4,
};

/// Action を u16 または usage フィールドとして解釈する packed union
/// action_code.Action のサブセット（extrakey 処理に必要な部分のみ）
const Action = packed union {
    code: u16,
    usage: UsageAction,
};

// ============================================================
// HID Usage Codes
// ============================================================

/// System Control usage codes (Generic Desktop Page 0x01)
pub const SystemUsage = struct {
    pub const POWER_DOWN: u16 = 0x81;
    pub const SLEEP: u16 = 0x82;
    pub const WAKE_UP: u16 = 0x83;
};

/// Consumer Control usage codes (Consumer Page 0x0C)
pub const ConsumerUsage = struct {
    // Display Controls
    pub const SNAPSHOT: u16 = 0x065;
    pub const BRIGHTNESS_UP: u16 = 0x06F;
    pub const BRIGHTNESS_DOWN: u16 = 0x070;
    // Transport Controls
    pub const TRANSPORT_RECORD: u16 = 0x0B2;
    pub const TRANSPORT_FAST_FORWARD: u16 = 0x0B3;
    pub const TRANSPORT_REWIND: u16 = 0x0B4;
    pub const TRANSPORT_NEXT_TRACK: u16 = 0x0B5;
    pub const TRANSPORT_PREV_TRACK: u16 = 0x0B6;
    pub const TRANSPORT_STOP: u16 = 0x0B7;
    pub const TRANSPORT_EJECT: u16 = 0x0B8;
    pub const TRANSPORT_STOP_EJECT: u16 = 0x0CC;
    pub const TRANSPORT_PLAY_PAUSE: u16 = 0x0CD;
    // Audio Controls
    pub const AUDIO_MUTE: u16 = 0x0E2;
    pub const AUDIO_VOL_UP: u16 = 0x0E9;
    pub const AUDIO_VOL_DOWN: u16 = 0x0EA;
    // Application Launch
    pub const AL_CC_CONFIG: u16 = 0x183;
    pub const AL_EMAIL: u16 = 0x18A;
    pub const AL_CALCULATOR: u16 = 0x192;
    pub const AL_LOCAL_BROWSER: u16 = 0x194;
    pub const AL_LOCK: u16 = 0x19E;
    pub const AL_CONTROL_PANEL: u16 = 0x19F;
    pub const AL_ASSISTANT: u16 = 0x1CB;
    // Generic GUI Application Controls
    pub const AC_SEARCH: u16 = 0x221;
    pub const AC_HOME: u16 = 0x223;
    pub const AC_BACK: u16 = 0x224;
    pub const AC_FORWARD: u16 = 0x225;
    pub const AC_STOP: u16 = 0x226;
    pub const AC_REFRESH: u16 = 0x227;
    pub const AC_BOOKMARKS: u16 = 0x22A;
    pub const AC_DESKTOP_SHOW_ALL_WINDOWS: u16 = 0x29F;
    pub const AC_SOFT_KEY_LEFT: u16 = 0x2A0;
};

// ============================================================
// Keycode to HID Usage conversion
// ============================================================

/// QMK内部キーコードからSystem Control HID Usage Codeに変換
pub fn keycodeToSystem(kc: u8) u16 {
    return switch (kc) {
        @as(u8, @truncate(KC.SYSTEM_POWER)) => SystemUsage.POWER_DOWN,
        @as(u8, @truncate(KC.SYSTEM_SLEEP)) => SystemUsage.SLEEP,
        @as(u8, @truncate(KC.SYSTEM_WAKE)) => SystemUsage.WAKE_UP,
        else => 0,
    };
}

/// QMK内部キーコードからConsumer Control HID Usage Codeに変換
pub fn keycodeToConsumer(kc: u8) u16 {
    return switch (kc) {
        @as(u8, @truncate(KC.AUDIO_MUTE)) => ConsumerUsage.AUDIO_MUTE,
        @as(u8, @truncate(KC.AUDIO_VOL_UP)) => ConsumerUsage.AUDIO_VOL_UP,
        @as(u8, @truncate(KC.AUDIO_VOL_DOWN)) => ConsumerUsage.AUDIO_VOL_DOWN,
        @as(u8, @truncate(KC.MEDIA_NEXT_TRACK)) => ConsumerUsage.TRANSPORT_NEXT_TRACK,
        @as(u8, @truncate(KC.MEDIA_PREV_TRACK)) => ConsumerUsage.TRANSPORT_PREV_TRACK,
        @as(u8, @truncate(KC.MEDIA_FAST_FORWARD)) => ConsumerUsage.TRANSPORT_FAST_FORWARD,
        @as(u8, @truncate(KC.MEDIA_REWIND)) => ConsumerUsage.TRANSPORT_REWIND,
        @as(u8, @truncate(KC.MEDIA_STOP)) => ConsumerUsage.TRANSPORT_STOP,
        // QMK upstream互換: KC_EJCT は TRANSPORT_EJECT(0xB8) ではなく
        // TRANSPORT_STOP_EJECT(0xCC) にマップされる
        @as(u8, @truncate(KC.MEDIA_EJECT)) => ConsumerUsage.TRANSPORT_STOP_EJECT,
        @as(u8, @truncate(KC.MEDIA_PLAY_PAUSE)) => ConsumerUsage.TRANSPORT_PLAY_PAUSE,
        @as(u8, @truncate(KC.MEDIA_SELECT)) => ConsumerUsage.AL_CC_CONFIG,
        @as(u8, @truncate(KC.MAIL)) => ConsumerUsage.AL_EMAIL,
        @as(u8, @truncate(KC.CALCULATOR)) => ConsumerUsage.AL_CALCULATOR,
        @as(u8, @truncate(KC.MY_COMPUTER)) => ConsumerUsage.AL_LOCAL_BROWSER,
        @as(u8, @truncate(KC.CONTROL_PANEL)) => ConsumerUsage.AL_CONTROL_PANEL,
        @as(u8, @truncate(KC.ASSISTANT)) => ConsumerUsage.AL_ASSISTANT,
        @as(u8, @truncate(KC.WWW_SEARCH)) => ConsumerUsage.AC_SEARCH,
        @as(u8, @truncate(KC.WWW_HOME)) => ConsumerUsage.AC_HOME,
        @as(u8, @truncate(KC.WWW_BACK)) => ConsumerUsage.AC_BACK,
        @as(u8, @truncate(KC.WWW_FORWARD)) => ConsumerUsage.AC_FORWARD,
        @as(u8, @truncate(KC.WWW_STOP)) => ConsumerUsage.AC_STOP,
        @as(u8, @truncate(KC.WWW_REFRESH)) => ConsumerUsage.AC_REFRESH,
        @as(u8, @truncate(KC.WWW_FAVORITES)) => ConsumerUsage.AC_BOOKMARKS,
        @as(u8, @truncate(KC.BRIGHTNESS_UP)) => ConsumerUsage.BRIGHTNESS_UP,
        @as(u8, @truncate(KC.BRIGHTNESS_DOWN)) => ConsumerUsage.BRIGHTNESS_DOWN,
        // QMK upstream互換: macOS Mission Control に対応
        // HID Usage Table 上は AC Desktop Show All Windows (0x29F)
        @as(u8, @truncate(KC.MISSION_CONTROL)) => ConsumerUsage.AC_DESKTOP_SHOW_ALL_WINDOWS,
        // QMK upstream互換: macOS Launchpad に対応
        // HID Usage Table 上は AC Soft Key Left (0x2A0)
        @as(u8, @truncate(KC.LAUNCHPAD)) => ConsumerUsage.AC_SOFT_KEY_LEFT,
        else => 0,
    };
}

// ============================================================
// Action constructor functions
// ============================================================

/// ACTION(kind, param) = (kind << 12) | param
inline fn ACTION(kind: u4, param: u12) u16 {
    return (@as(u16, kind) << 12) | @as(u16, param);
}

/// System Control アクションコードを構築
/// ACTION_USAGE_SYSTEM(id) = ACTION(ACT_USAGE, PAGE_SYSTEM << 10 | id)
pub inline fn actionUsageSystem(usage: u10) u16 {
    return ACTION(ACT_USAGE, @as(u12, PAGE_SYSTEM) << 10 | @as(u12, usage));
}

/// Consumer Control アクションコードを構築
/// ACTION_USAGE_CONSUMER(id) = ACTION(ACT_USAGE, PAGE_CONSUMER << 10 | id)
pub inline fn actionUsageConsumer(usage: u10) u16 {
    return ACTION(ACT_USAGE, @as(u12, PAGE_CONSUMER) << 10 | @as(u12, usage));
}

// ============================================================
// Extrakey処理
// ============================================================

/// Usage アクション (ACT_USAGE) を処理する
/// C版 quantum/action.c の case ACT_USAGE に相当
/// action_code からの u16 コードを受け取り、usage フィールドとして解釈する
pub fn processUsageAction(ev: event_mod.KeyEvent, act_code: u16) void {
    const act: Action = .{ .code = act_code };
    const page = act.usage.page;
    const usage_code = act.usage.code;

    switch (page) {
        PAGE_SYSTEM => {
            hostSystemSend(if (ev.pressed) usage_code else 0);
        },
        PAGE_CONSUMER => {
            hostConsumerSend(if (ev.pressed) usage_code else 0);
        },
        else => {},
    }
}

/// System Control レポートを送信
pub fn hostSystemSend(usage: u16) void {
    const r = ExtraReport.system(usage);
    host.sendExtra(&r);
}

/// Consumer Control レポートを送信
pub fn hostConsumerSend(usage: u16) void {
    const r = ExtraReport.consumer(usage);
    host.sendExtra(&r);
}

/// register_code() から呼ばれる Extrakey 登録処理
/// キーコードがExtrakey範囲の場合、対応するHIDレポートを送信する
pub fn registerExtrakey(kc: u8) void {
    if (kc >= @as(u8, @truncate(KC.SYSTEM_POWER)) and kc <= @as(u8, @truncate(KC.SYSTEM_WAKE))) {
        const usage = keycodeToSystem(kc);
        if (usage != 0) hostSystemSend(usage);
    } else if (kc >= @as(u8, @truncate(KC.AUDIO_MUTE)) and kc <= @as(u8, @truncate(KC.LAUNCHPAD))) {
        const usage = keycodeToConsumer(kc);
        if (usage != 0) hostConsumerSend(usage);
    }
}

/// unregister_code() から呼ばれる Extrakey 解除処理
/// System/Consumer の usage を 0 にしてリリースする
pub fn unregisterExtrakey(kc: u8) void {
    if (kc >= @as(u8, @truncate(KC.SYSTEM_POWER)) and kc <= @as(u8, @truncate(KC.SYSTEM_WAKE))) {
        hostSystemSend(0);
    } else if (kc >= @as(u8, @truncate(KC.AUDIO_MUTE)) and kc <= @as(u8, @truncate(KC.LAUNCHPAD))) {
        hostConsumerSend(0);
    }
}

// ============================================================
// Tests
// ============================================================

const testing = @import("std").testing;

/// テスト用モックドライバ（Extra レポートの送信を記録）
const MockExtraDriver = struct {
    extra_count: usize = 0,
    last_extra: ExtraReport = .{},

    pub fn keyboardLeds(_: *@This()) u8 {
        return 0;
    }
    pub fn sendKeyboard(_: *@This(), _: report_mod.KeyboardReport) void {}
    pub fn sendMouse(_: *@This(), _: report_mod.MouseReport) void {}
    pub fn sendExtra(self: *@This(), r: ExtraReport) void {
        self.extra_count += 1;
        self.last_extra = r;
    }
};

test "keycodeToSystem" {
    try testing.expectEqual(SystemUsage.POWER_DOWN, keycodeToSystem(@truncate(KC.SYSTEM_POWER)));
    try testing.expectEqual(SystemUsage.SLEEP, keycodeToSystem(@truncate(KC.SYSTEM_SLEEP)));
    try testing.expectEqual(SystemUsage.WAKE_UP, keycodeToSystem(@truncate(KC.SYSTEM_WAKE)));
    try testing.expectEqual(@as(u16, 0), keycodeToSystem(0x04)); // KC_A
}

test "keycodeToConsumer" {
    try testing.expectEqual(ConsumerUsage.AUDIO_MUTE, keycodeToConsumer(@truncate(KC.AUDIO_MUTE)));
    try testing.expectEqual(ConsumerUsage.AUDIO_VOL_UP, keycodeToConsumer(@truncate(KC.AUDIO_VOL_UP)));
    try testing.expectEqual(ConsumerUsage.AUDIO_VOL_DOWN, keycodeToConsumer(@truncate(KC.AUDIO_VOL_DOWN)));
    try testing.expectEqual(ConsumerUsage.TRANSPORT_NEXT_TRACK, keycodeToConsumer(@truncate(KC.MEDIA_NEXT_TRACK)));
    try testing.expectEqual(ConsumerUsage.TRANSPORT_PREV_TRACK, keycodeToConsumer(@truncate(KC.MEDIA_PREV_TRACK)));
    try testing.expectEqual(ConsumerUsage.TRANSPORT_STOP, keycodeToConsumer(@truncate(KC.MEDIA_STOP)));
    try testing.expectEqual(ConsumerUsage.TRANSPORT_PLAY_PAUSE, keycodeToConsumer(@truncate(KC.MEDIA_PLAY_PAUSE)));
    try testing.expectEqual(ConsumerUsage.AL_CC_CONFIG, keycodeToConsumer(@truncate(KC.MEDIA_SELECT)));
    try testing.expectEqual(ConsumerUsage.AL_EMAIL, keycodeToConsumer(@truncate(KC.MAIL)));
    try testing.expectEqual(ConsumerUsage.AL_CALCULATOR, keycodeToConsumer(@truncate(KC.CALCULATOR)));
    try testing.expectEqual(ConsumerUsage.AL_LOCAL_BROWSER, keycodeToConsumer(@truncate(KC.MY_COMPUTER)));
    try testing.expectEqual(ConsumerUsage.AC_SEARCH, keycodeToConsumer(@truncate(KC.WWW_SEARCH)));
    try testing.expectEqual(ConsumerUsage.AC_HOME, keycodeToConsumer(@truncate(KC.WWW_HOME)));
    try testing.expectEqual(ConsumerUsage.AC_BACK, keycodeToConsumer(@truncate(KC.WWW_BACK)));
    try testing.expectEqual(ConsumerUsage.AC_FORWARD, keycodeToConsumer(@truncate(KC.WWW_FORWARD)));
    try testing.expectEqual(ConsumerUsage.AC_STOP, keycodeToConsumer(@truncate(KC.WWW_STOP)));
    try testing.expectEqual(ConsumerUsage.AC_REFRESH, keycodeToConsumer(@truncate(KC.WWW_REFRESH)));
    try testing.expectEqual(ConsumerUsage.AC_BOOKMARKS, keycodeToConsumer(@truncate(KC.WWW_FAVORITES)));
    try testing.expectEqual(ConsumerUsage.BRIGHTNESS_UP, keycodeToConsumer(@truncate(KC.BRIGHTNESS_UP)));
    try testing.expectEqual(ConsumerUsage.BRIGHTNESS_DOWN, keycodeToConsumer(@truncate(KC.BRIGHTNESS_DOWN)));
    try testing.expectEqual(ConsumerUsage.AL_CONTROL_PANEL, keycodeToConsumer(@truncate(KC.CONTROL_PANEL)));
    try testing.expectEqual(ConsumerUsage.AL_ASSISTANT, keycodeToConsumer(@truncate(KC.ASSISTANT)));
    try testing.expectEqual(ConsumerUsage.AC_DESKTOP_SHOW_ALL_WINDOWS, keycodeToConsumer(@truncate(KC.MISSION_CONTROL)));
    try testing.expectEqual(ConsumerUsage.AC_SOFT_KEY_LEFT, keycodeToConsumer(@truncate(KC.LAUNCHPAD)));
    try testing.expectEqual(@as(u16, 0), keycodeToConsumer(0x04)); // KC_A
}

test "actionUsageSystem" {
    const action_code = @import("action_code.zig");
    // ACTION_USAGE_SYSTEM(0x81) = ACTION(ACT_USAGE, PAGE_SYSTEM<<10 | 0x81)
    // = (4 << 12) | (1 << 10) | 0x81 = 0x4000 | 0x400 | 0x81 = 0x4481
    const act = actionUsageSystem(SystemUsage.POWER_DOWN);
    try testing.expectEqual(@as(u16, 0x4481), act);

    const action = action_code.Action{ .code = act };
    try testing.expectEqual(action_code.ActionKind.usage, action.kind.id);
    try testing.expectEqual(@as(u2, @intFromEnum(action_code.UsagePage.system)), action.usage.page);
    try testing.expectEqual(@as(u10, SystemUsage.POWER_DOWN), action.usage.code);
}

test "actionUsageConsumer" {
    const action_code = @import("action_code.zig");
    // ACTION_USAGE_CONSUMER(0xE2) = ACTION(ACT_USAGE, PAGE_CONSUMER<<10 | 0xE2)
    // = (4 << 12) | (2 << 10) | 0xE2 = 0x4000 | 0x800 | 0xE2 = 0x48E2
    const act = actionUsageConsumer(@truncate(ConsumerUsage.AUDIO_MUTE));
    try testing.expectEqual(@as(u16, 0x48E2), act);

    const action = action_code.Action{ .code = act };
    try testing.expectEqual(action_code.ActionKind.usage, action.kind.id);
    try testing.expectEqual(@as(u2, @intFromEnum(action_code.UsagePage.consumer)), action.usage.page);
    try testing.expectEqual(@as(u10, @truncate(ConsumerUsage.AUDIO_MUTE)), action.usage.code);
}

test "processUsageAction system press and release" {
    var mock = MockExtraDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // System Power press
    const act_code = actionUsageSystem(SystemUsage.POWER_DOWN);
    const press = event_mod.KeyEvent.keyPress(0, 0, 100);
    processUsageAction(press, act_code);

    try testing.expectEqual(@as(usize, 1), mock.extra_count);
    try testing.expectEqual(@as(u8, @intFromEnum(report_mod.ReportId.system)), mock.last_extra.report_id);
    try testing.expectEqual(SystemUsage.POWER_DOWN, mock.last_extra.usage);

    // System Power release
    const release = event_mod.KeyEvent.keyRelease(0, 0, 200);
    processUsageAction(release, act_code);

    try testing.expectEqual(@as(usize, 2), mock.extra_count);
    try testing.expectEqual(@as(u16, 0), mock.last_extra.usage);
}

test "processUsageAction consumer press and release" {
    var mock = MockExtraDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // Audio Mute press
    const act_code = actionUsageConsumer(@truncate(ConsumerUsage.AUDIO_MUTE));
    const press = event_mod.KeyEvent.keyPress(0, 0, 100);
    processUsageAction(press, act_code);

    try testing.expectEqual(@as(usize, 1), mock.extra_count);
    try testing.expectEqual(@as(u8, @intFromEnum(report_mod.ReportId.consumer)), mock.last_extra.report_id);
    try testing.expectEqual(@as(u16, ConsumerUsage.AUDIO_MUTE), mock.last_extra.usage);

    // Audio Mute release
    const release = event_mod.KeyEvent.keyRelease(0, 0, 200);
    processUsageAction(release, act_code);

    try testing.expectEqual(@as(usize, 2), mock.extra_count);
    try testing.expectEqual(@as(u16, 0), mock.last_extra.usage);
}

test "registerExtrakey and unregisterExtrakey system" {
    var mock = MockExtraDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // Register system power
    registerExtrakey(@truncate(KC.SYSTEM_POWER));
    try testing.expectEqual(@as(usize, 1), mock.extra_count);
    try testing.expectEqual(@as(u8, @intFromEnum(report_mod.ReportId.system)), mock.last_extra.report_id);
    try testing.expectEqual(SystemUsage.POWER_DOWN, mock.last_extra.usage);

    // Unregister system power
    unregisterExtrakey(@truncate(KC.SYSTEM_POWER));
    try testing.expectEqual(@as(usize, 2), mock.extra_count);
    try testing.expectEqual(@as(u16, 0), mock.last_extra.usage);
}

test "registerExtrakey and unregisterExtrakey consumer" {
    var mock = MockExtraDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // Register volume up
    registerExtrakey(@truncate(KC.AUDIO_VOL_UP));
    try testing.expectEqual(@as(usize, 1), mock.extra_count);
    try testing.expectEqual(@as(u8, @intFromEnum(report_mod.ReportId.consumer)), mock.last_extra.report_id);
    try testing.expectEqual(ConsumerUsage.AUDIO_VOL_UP, mock.last_extra.usage);

    // Unregister volume up
    unregisterExtrakey(@truncate(KC.AUDIO_VOL_UP));
    try testing.expectEqual(@as(usize, 2), mock.extra_count);
    try testing.expectEqual(@as(u16, 0), mock.last_extra.usage);
}
