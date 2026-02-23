//! Mousekey - キーボードによるマウス操作
//! Based on quantum/mousekey.c, quantum/mousekey.h
//!
//! マウスカーソル移動、ボタンクリック、スクロールホイール操作をキーで実行する。
//! デフォルト加速モードを実装（upstream の MK_3_SPEED / MK_KINETIC_SPEED / MOUSEKEY_INERTIA は未対応）。

const std = @import("std");
const builtin = @import("builtin");
const report_mod = @import("report.zig");
const host_mod = @import("host.zig");
const keycode_mod = @import("keycode.zig");
const MouseReport = report_mod.MouseReport;
const MouseBtn = report_mod.MouseBtn;
const KC = keycode_mod.KC;
const Keycode = keycode_mod.Keycode;

const timer = @import("../hal/timer.zig");

// ============================================================
// 設定パラメータ（upstream のデフォルト値に準拠）
// ============================================================

pub const Config = struct {
    /// マウス移動1ステップのピクセル数
    move_delta: u8 = 8,
    /// 最大移動値（HID レポートの i8 範囲内）
    move_max: u8 = 127,
    /// キー押下からリピート開始までの遅延（ms）
    /// upstream MOUSEKEY_DELAY=10 → mk_delay=1 → 実遅延 10ms だが、
    /// 本実装では直接 ms 値を保持する（upstream デフォルト: 300ms は未使用の古い定義、
    /// 実際のデフォルトは MOUSEKEY_DELAY=10 → 10*10=100ms）
    delay_ms: u16 = 100,
    /// リピート間隔（ms）
    interval: u16 = 20,
    /// 最大速度倍率
    max_speed: u8 = 10,
    /// 最大速度に到達するまでのリピート回数
    time_to_max: u8 = 30,
    /// ホイール移動1ステップの量
    wheel_delta: u8 = 1,
    /// ホイール最大値
    wheel_max: u8 = 127,
    /// ホイールキー押下からリピート開始までの遅延（ms）
    wheel_delay_ms: u16 = 100,
    /// ホイールリピート間隔（ms）
    wheel_interval: u16 = 80,
    /// ホイール最大速度倍率
    wheel_max_speed: u8 = 8,
    /// ホイール最大速度に到達するまでのリピート回数
    wheel_time_to_max: u8 = 40,
};

/// デフォルト設定
pub const default_config = Config{};

// ============================================================
// モジュール状態
// ============================================================

var config: Config = default_config;
var mouse_report: MouseReport = .{};
var mousekey_accel: u8 = 0;
var mousekey_repeat: u8 = 0;
var mousekey_wheel_repeat: u8 = 0;
var last_timer_c: u16 = 0;
var last_timer_w: u16 = 0;

// ============================================================
// 内部ヘルパー関数
// ============================================================

/// 1/sqrt(2) の近似計算（対角移動の速度補正用）
/// 181/256 ≈ 0.707
fn timesInvSqrt2(x: i8) i8 {
    const n: i16 = @as(i16, x) * 181;
    const d: i16 = 256;
    if (n < 0) {
        return @intCast(@divTrunc(n - @divTrunc(d, 2), d));
    } else {
        return @intCast(@divTrunc(n + @divTrunc(d, 2), d));
    }
}

/// 移動速度を計算（加速カーブ付き）
/// u32 中間値で計算し、大きな設定値でもオーバーフローしない
fn moveUnit() u8 {
    var unit: u32 = 0;
    if (mousekey_accel & (1 << 0) != 0) {
        unit = (@as(u32, config.move_delta) * @as(u32, config.max_speed)) / 4;
    } else if (mousekey_accel & (1 << 1) != 0) {
        unit = (@as(u32, config.move_delta) * @as(u32, config.max_speed)) / 2;
    } else if (mousekey_accel & (1 << 2) != 0) {
        unit = @as(u32, config.move_delta) * @as(u32, config.max_speed);
    } else if (mousekey_repeat == 0) {
        unit = @as(u32, config.move_delta);
    } else if (mousekey_repeat >= config.time_to_max) {
        unit = @as(u32, config.move_delta) * @as(u32, config.max_speed);
    } else {
        unit = (@as(u32, config.move_delta) * @as(u32, config.max_speed) * @as(u32, mousekey_repeat)) / @as(u32, config.time_to_max);
    }
    if (unit > config.move_max) return config.move_max;
    if (unit == 0) return 1;
    return @intCast(unit);
}

/// ホイール速度を計算（加速カーブ付き）
/// u32 中間値で計算し、大きな設定値でもオーバーフローしない
fn wheelUnit() u8 {
    var unit: u32 = 0;
    if (mousekey_accel & (1 << 0) != 0) {
        unit = (@as(u32, config.wheel_delta) * @as(u32, config.wheel_max_speed)) / 4;
    } else if (mousekey_accel & (1 << 1) != 0) {
        unit = (@as(u32, config.wheel_delta) * @as(u32, config.wheel_max_speed)) / 2;
    } else if (mousekey_accel & (1 << 2) != 0) {
        unit = @as(u32, config.wheel_delta) * @as(u32, config.wheel_max_speed);
    } else if (mousekey_wheel_repeat == 0) {
        unit = @as(u32, config.wheel_delta);
    } else if (mousekey_wheel_repeat >= config.wheel_time_to_max) {
        unit = @as(u32, config.wheel_delta) * @as(u32, config.wheel_max_speed);
    } else {
        unit = (@as(u32, config.wheel_delta) * @as(u32, config.wheel_max_speed) * @as(u32, mousekey_wheel_repeat)) / @as(u32, config.wheel_time_to_max);
    }
    if (unit > config.wheel_max) return config.wheel_max;
    if (unit == 0) return 1;
    return @intCast(unit);
}

/// キーコードからマウスボタンかどうか判定
fn isMouseButton(code: u8) bool {
    return code >= @as(u8, @truncate(KC.MS_BTN1)) and code <= @as(u8, @truncate(KC.MS_BTN8));
}

// ============================================================
// パブリックAPI
// ============================================================

/// 設定を変更
pub fn setConfig(cfg: Config) void {
    config = cfg;
}

/// 現在の設定を取得
pub fn getConfig() Config {
    return config;
}

/// 定期実行タスク - マウスレポートの更新と送信
pub fn task() void {
    const tmpmr = mouse_report;

    mouse_report.x = 0;
    mouse_report.y = 0;
    mouse_report.v = 0;
    mouse_report.h = 0;

    // カーソル移動の処理
    if ((tmpmr.x != 0 or tmpmr.y != 0) and
        timer.elapsed(last_timer_c) > if (mousekey_repeat != 0) config.interval else config.delay_ms)
    {
        if (mousekey_repeat != 255) mousekey_repeat += 1;
        if (tmpmr.x != 0) {
            const unit_val = moveUnit();
            mouse_report.x = if (tmpmr.x > 0)
                @intCast(unit_val)
            else
                -@as(i8, @intCast(unit_val));
        }
        if (tmpmr.y != 0) {
            const unit_val = moveUnit();
            mouse_report.y = if (tmpmr.y > 0)
                @intCast(unit_val)
            else
                -@as(i8, @intCast(unit_val));
        }

        // 対角移動の補正 [1/sqrt(2)]
        // 補正後に0になった場合は元の方向を維持する
        if (mouse_report.x != 0 and mouse_report.y != 0) {
            mouse_report.x = timesInvSqrt2(mouse_report.x);
            if (mouse_report.x == 0) mouse_report.x = if (tmpmr.x > 0) @as(i8, 1) else -1;
            mouse_report.y = timesInvSqrt2(mouse_report.y);
            if (mouse_report.y == 0) mouse_report.y = if (tmpmr.y > 0) @as(i8, 1) else -1;
        }
    }

    // スクロールの処理
    if ((tmpmr.v != 0 or tmpmr.h != 0) and
        timer.elapsed(last_timer_w) > if (mousekey_wheel_repeat != 0) config.wheel_interval else config.wheel_delay_ms)
    {
        if (mousekey_wheel_repeat != 255) mousekey_wheel_repeat += 1;
        if (tmpmr.v != 0) {
            const unit_val = wheelUnit();
            mouse_report.v = if (tmpmr.v > 0)
                @intCast(unit_val)
            else
                -@as(i8, @intCast(unit_val));
        }
        if (tmpmr.h != 0) {
            const unit_val = wheelUnit();
            mouse_report.h = if (tmpmr.h > 0)
                @intCast(unit_val)
            else
                -@as(i8, @intCast(unit_val));
        }

        // 対角スクロールの補正
        // 補正後に0になった場合は元の方向を維持する
        if (mouse_report.v != 0 and mouse_report.h != 0) {
            mouse_report.v = timesInvSqrt2(mouse_report.v);
            if (mouse_report.v == 0) mouse_report.v = if (tmpmr.v > 0) @as(i8, 1) else -1;
            mouse_report.h = timesInvSqrt2(mouse_report.h);
            if (mouse_report.h == 0) mouse_report.h = if (tmpmr.h > 0) @as(i8, 1) else -1;
        }
    }

    if (mouse_report.buttons != tmpmr.buttons or shouldSend(&mouse_report)) {
        send();
    }

    // 状態を復元（方向情報を保持するため）
    mouse_report = tmpmr;
}

/// マウスレポートに変化があるか判定
fn hasChanged(a: *const MouseReport, b: *const MouseReport) bool {
    return a.buttons != b.buttons or a.x != b.x or a.y != b.y or a.v != b.v or a.h != b.h;
}

/// レポートを送信すべきか判定
fn shouldSend(report: *const MouseReport) bool {
    return report.x != 0 or report.y != 0 or report.v != 0 or report.h != 0;
}

/// キー押下時の処理
pub fn on(code: Keycode) void {
    const c: u8 = @truncate(code);
    if (c == @as(u8, @truncate(KC.MS_UP))) {
        const unit_val = moveUnit();
        mouse_report.y = -@as(i8, @intCast(unit_val));
    } else if (c == @as(u8, @truncate(KC.MS_DOWN))) {
        mouse_report.y = @intCast(moveUnit());
    } else if (c == @as(u8, @truncate(KC.MS_LEFT))) {
        const unit_val = moveUnit();
        mouse_report.x = -@as(i8, @intCast(unit_val));
    } else if (c == @as(u8, @truncate(KC.MS_RIGHT))) {
        mouse_report.x = @intCast(moveUnit());
    } else if (c == @as(u8, @truncate(KC.MS_WH_UP))) {
        mouse_report.v = @intCast(wheelUnit());
    } else if (c == @as(u8, @truncate(KC.MS_WH_DOWN))) {
        const unit_val = wheelUnit();
        mouse_report.v = -@as(i8, @intCast(unit_val));
    } else if (c == @as(u8, @truncate(KC.MS_WH_LEFT))) {
        const unit_val = wheelUnit();
        mouse_report.h = -@as(i8, @intCast(unit_val));
    } else if (c == @as(u8, @truncate(KC.MS_WH_RIGHT))) {
        mouse_report.h = @intCast(wheelUnit());
    } else if (isMouseButton(c)) {
        const shift: u3 = @intCast(c - @as(u8, @truncate(KC.MS_BTN1)));
        mouse_report.buttons |= @as(u8, 1) << shift;
    } else if (c == @as(u8, @truncate(KC.MS_ACCEL0))) {
        mousekey_accel |= (1 << 0);
    } else if (c == @as(u8, @truncate(KC.MS_ACCEL1))) {
        mousekey_accel |= (1 << 1);
    } else if (c == @as(u8, @truncate(KC.MS_ACCEL2))) {
        mousekey_accel |= (1 << 2);
    }
}

/// キー解放時の処理
pub fn off(code: Keycode) void {
    const c: u8 = @truncate(code);
    if (c == @as(u8, @truncate(KC.MS_UP)) and mouse_report.y < 0) {
        mouse_report.y = 0;
    } else if (c == @as(u8, @truncate(KC.MS_DOWN)) and mouse_report.y > 0) {
        mouse_report.y = 0;
    } else if (c == @as(u8, @truncate(KC.MS_LEFT)) and mouse_report.x < 0) {
        mouse_report.x = 0;
    } else if (c == @as(u8, @truncate(KC.MS_RIGHT)) and mouse_report.x > 0) {
        mouse_report.x = 0;
    } else if (c == @as(u8, @truncate(KC.MS_WH_UP)) and mouse_report.v > 0) {
        mouse_report.v = 0;
    } else if (c == @as(u8, @truncate(KC.MS_WH_DOWN)) and mouse_report.v < 0) {
        mouse_report.v = 0;
    } else if (c == @as(u8, @truncate(KC.MS_WH_LEFT)) and mouse_report.h < 0) {
        mouse_report.h = 0;
    } else if (c == @as(u8, @truncate(KC.MS_WH_RIGHT)) and mouse_report.h > 0) {
        mouse_report.h = 0;
    } else if (isMouseButton(c)) {
        const shift: u3 = @intCast(c - @as(u8, @truncate(KC.MS_BTN1)));
        mouse_report.buttons &= ~(@as(u8, 1) << shift);
    } else if (c == @as(u8, @truncate(KC.MS_ACCEL0))) {
        mousekey_accel &= ~@as(u8, 1 << 0);
    } else if (c == @as(u8, @truncate(KC.MS_ACCEL1))) {
        mousekey_accel &= ~@as(u8, 1 << 1);
    } else if (c == @as(u8, @truncate(KC.MS_ACCEL2))) {
        mousekey_accel &= ~@as(u8, 1 << 2);
    }

    if (mouse_report.x == 0 and mouse_report.y == 0) {
        mousekey_repeat = 0;
    }
    if (mouse_report.v == 0 and mouse_report.h == 0) {
        mousekey_wheel_repeat = 0;
    }
}

/// HIDレポートを送信
pub fn send() void {
    const time = timer.read();
    if (mouse_report.x != 0 or mouse_report.y != 0) last_timer_c = time;
    if (mouse_report.v != 0 or mouse_report.h != 0) last_timer_w = time;
    host_mod.sendMouse(&mouse_report);
}

/// 状態をクリア
pub fn clear() void {
    mouse_report = .{};
    mousekey_repeat = 0;
    mousekey_wheel_repeat = 0;
    mousekey_accel = 0;
    last_timer_c = 0;
    last_timer_w = 0;
}

/// 現在のマウスレポートを取得
pub fn getReport() MouseReport {
    return mouse_report;
}

// ============================================================
// テスト
// ============================================================

const testing = std.testing;

const MockMouseDriver = struct {
    keyboard_count: usize = 0,
    mouse_count: usize = 0,
    extra_count: usize = 0,
    last_mouse: MouseReport = .{},
    leds: u8 = 0,

    pub fn keyboardLeds(self: *MockMouseDriver) u8 {
        return self.leds;
    }

    pub fn sendKeyboard(self: *MockMouseDriver, _: report_mod.KeyboardReport) void {
        self.keyboard_count += 1;
    }

    pub fn sendMouse(self: *MockMouseDriver, r: MouseReport) void {
        self.mouse_count += 1;
        self.last_mouse = r;
    }

    pub fn sendExtra(self: *MockMouseDriver, _: report_mod.ExtraReport) void {
        self.extra_count += 1;
    }
};

fn setupTest() *MockMouseDriver {
    const S = struct {
        var mock = MockMouseDriver{};
    };
    S.mock = MockMouseDriver{};
    clear();
    timer.mockReset();
    config = default_config;
    host_mod.setDriver(host_mod.HostDriver.from(&S.mock));
    return &S.mock;
}

fn teardownTest() void {
    host_mod.clearDriver();
    clear();
}

test "mousekey on/off - カーソル上移動" {
    const mock = setupTest();
    defer teardownTest();

    on(KC.MS_UP);
    send();
    try testing.expectEqual(@as(usize, 1), mock.mouse_count);
    try testing.expect(mock.last_mouse.y < 0);

    off(KC.MS_UP);
    send();
    try testing.expectEqual(@as(i8, 0), mock.last_mouse.y);
}

test "mousekey on/off - カーソル下移動" {
    const mock = setupTest();
    defer teardownTest();

    on(KC.MS_DOWN);
    send();
    try testing.expect(mock.last_mouse.y > 0);

    off(KC.MS_DOWN);
    send();
    try testing.expectEqual(@as(i8, 0), mock.last_mouse.y);
}

test "mousekey on/off - カーソル左右移動" {
    const mock = setupTest();
    defer teardownTest();

    on(KC.MS_LEFT);
    send();
    try testing.expect(mock.last_mouse.x < 0);
    off(KC.MS_LEFT);

    on(KC.MS_RIGHT);
    send();
    try testing.expect(mock.last_mouse.x > 0);

    off(KC.MS_RIGHT);
    send();
    try testing.expectEqual(@as(i8, 0), mock.last_mouse.x);
}

test "mousekey on/off - ボタン操作" {
    const mock = setupTest();
    defer teardownTest();

    on(KC.MS_BTN1);
    send();
    try testing.expectEqual(@as(u8, MouseBtn.BTN1), mock.last_mouse.buttons);

    on(KC.MS_BTN2);
    send();
    try testing.expectEqual(@as(u8, MouseBtn.BTN1 | MouseBtn.BTN2), mock.last_mouse.buttons);

    off(KC.MS_BTN1);
    send();
    try testing.expectEqual(@as(u8, MouseBtn.BTN2), mock.last_mouse.buttons);

    off(KC.MS_BTN2);
    send();
    try testing.expectEqual(@as(u8, 0), mock.last_mouse.buttons);
}

test "mousekey on/off - 全ボタン BTN1-BTN5" {
    const mock = setupTest();
    defer teardownTest();

    on(KC.MS_BTN1);
    send();
    try testing.expectEqual(@as(u8, 0x01), mock.last_mouse.buttons);

    clear();
    on(KC.MS_BTN2);
    send();
    try testing.expectEqual(@as(u8, 0x02), mock.last_mouse.buttons);

    clear();
    on(KC.MS_BTN3);
    send();
    try testing.expectEqual(@as(u8, 0x04), mock.last_mouse.buttons);

    clear();
    on(KC.MS_BTN4);
    send();
    try testing.expectEqual(@as(u8, 0x08), mock.last_mouse.buttons);

    clear();
    on(KC.MS_BTN5);
    send();
    try testing.expectEqual(@as(u8, 0x10), mock.last_mouse.buttons);
}

test "mousekey on/off - 縦スクロール" {
    const mock = setupTest();
    defer teardownTest();

    on(KC.MS_WH_UP);
    send();
    try testing.expect(mock.last_mouse.v > 0);

    off(KC.MS_WH_UP);

    on(KC.MS_WH_DOWN);
    send();
    try testing.expect(mock.last_mouse.v < 0);

    off(KC.MS_WH_DOWN);
    send();
    try testing.expectEqual(@as(i8, 0), mock.last_mouse.v);
}

test "mousekey on/off - 横スクロール" {
    const mock = setupTest();
    defer teardownTest();

    on(KC.MS_WH_LEFT);
    send();
    try testing.expect(mock.last_mouse.h < 0);
    off(KC.MS_WH_LEFT);

    on(KC.MS_WH_RIGHT);
    send();
    try testing.expect(mock.last_mouse.h > 0);

    off(KC.MS_WH_RIGHT);
    send();
    try testing.expectEqual(@as(i8, 0), mock.last_mouse.h);
}

test "mousekey clear - 状態リセット" {
    _ = setupTest();
    defer teardownTest();

    on(KC.MS_BTN1);
    on(KC.MS_UP);
    on(KC.MS_WH_UP);

    clear();

    const report = getReport();
    try testing.expect(report.isEmpty());
}

test "mousekey 初回移動量 - MOVE_DELTA=8" {
    const mock = setupTest();
    defer teardownTest();

    on(KC.MS_UP);
    send();
    try testing.expectEqual(@as(i8, -8), mock.last_mouse.y);

    clear();
    on(KC.MS_DOWN);
    send();
    try testing.expectEqual(@as(i8, 8), mock.last_mouse.y);

    clear();
    on(KC.MS_LEFT);
    send();
    try testing.expectEqual(@as(i8, -8), mock.last_mouse.x);

    clear();
    on(KC.MS_RIGHT);
    send();
    try testing.expectEqual(@as(i8, 8), mock.last_mouse.x);
}

test "mousekey 初回ホイール量 - WHEEL_DELTA=1" {
    const mock = setupTest();
    defer teardownTest();

    on(KC.MS_WH_UP);
    send();
    try testing.expectEqual(@as(i8, 1), mock.last_mouse.v);

    clear();
    on(KC.MS_WH_DOWN);
    send();
    try testing.expectEqual(@as(i8, -1), mock.last_mouse.v);

    clear();
    on(KC.MS_WH_LEFT);
    send();
    try testing.expectEqual(@as(i8, -1), mock.last_mouse.h);

    clear();
    on(KC.MS_WH_RIGHT);
    send();
    try testing.expectEqual(@as(i8, 1), mock.last_mouse.h);
}

test "mousekey ACCEL0 で速度 1/4" {
    const mock = setupTest();
    defer teardownTest();

    on(KC.MS_ACCEL0);
    on(KC.MS_RIGHT);
    send();
    // ACCEL0: (8 * 10) / 4 = 20
    try testing.expectEqual(@as(i8, 20), mock.last_mouse.x);

    off(KC.MS_ACCEL0);
    off(KC.MS_RIGHT);
}

test "mousekey ACCEL1 で速度 1/2" {
    const mock = setupTest();
    defer teardownTest();

    on(KC.MS_ACCEL1);
    on(KC.MS_RIGHT);
    send();
    // ACCEL1: (8 * 10) / 2 = 40
    try testing.expectEqual(@as(i8, 40), mock.last_mouse.x);

    off(KC.MS_ACCEL1);
    off(KC.MS_RIGHT);
}

test "mousekey ACCEL2 で最大速度" {
    const mock = setupTest();
    defer teardownTest();

    on(KC.MS_ACCEL2);
    on(KC.MS_RIGHT);
    send();
    // ACCEL2: 8 * 10 = 80
    try testing.expectEqual(@as(i8, 80), mock.last_mouse.x);

    off(KC.MS_ACCEL2);
    off(KC.MS_RIGHT);
}

test "mousekey task - カーソルリピートと加速" {
    const mock = setupTest();
    defer teardownTest();

    on(KC.MS_RIGHT);
    send();
    try testing.expectEqual(@as(i8, 8), mock.last_mouse.x);

    // delay期間（100ms）経過後にtaskを実行すると加速が開始される
    timer.mockAdvance(101);
    task();
    try testing.expect(mock.mouse_count >= 2);
    try testing.expect(mock.last_mouse.x > 0);

    off(KC.MS_RIGHT);
}

test "mousekey task - ホイールリピート" {
    const mock = setupTest();
    defer teardownTest();

    on(KC.MS_WH_UP);
    send();
    try testing.expectEqual(@as(i8, 1), mock.last_mouse.v);

    // wheel_delay期間経過後にtaskを実行
    timer.mockAdvance(101);
    task();
    try testing.expect(mock.last_mouse.v > 0);

    off(KC.MS_WH_UP);
}

test "mousekey timesInvSqrt2 - 対角移動補正" {
    try testing.expectEqual(@as(i8, 57), timesInvSqrt2(80));
    try testing.expectEqual(@as(i8, -57), timesInvSqrt2(-80));
    try testing.expectEqual(@as(i8, 0), timesInvSqrt2(0));
    try testing.expectEqual(@as(i8, 1), timesInvSqrt2(1));
}

test "mousekey off でリピートカウンタがリセットされる" {
    _ = setupTest();
    defer teardownTest();

    on(KC.MS_RIGHT);
    send();

    // send()によりlast_timer_cが更新されるので、追加で時間経過させる
    timer.mockAdvance(101);
    task();
    // task後にmouse_reportが復元されるのでmousekey_repeatは増加しているはず
    // ただしtask内でrepeatをインクリメントした後に状態が復元される
    // task()は: tmpmr = report, report.x=0, 条件チェック, repeat++, report復元
    // repeat は 1 になっているはず

    // キー解放でリセット
    off(KC.MS_RIGHT);
    try testing.expectEqual(@as(u8, 0), mousekey_repeat);
}

test "mousekey isMouseKey キーコード判定" {
    try testing.expect(keycode_mod.isMouseKey(KC.MS_UP));
    try testing.expect(keycode_mod.isMouseKey(KC.MS_DOWN));
    try testing.expect(keycode_mod.isMouseKey(KC.MS_LEFT));
    try testing.expect(keycode_mod.isMouseKey(KC.MS_RIGHT));
    try testing.expect(keycode_mod.isMouseKey(KC.MS_BTN1));
    try testing.expect(keycode_mod.isMouseKey(KC.MS_BTN5));
    try testing.expect(keycode_mod.isMouseKey(KC.MS_WH_UP));
    try testing.expect(keycode_mod.isMouseKey(KC.MS_WH_DOWN));
    try testing.expect(keycode_mod.isMouseKey(KC.MS_WH_LEFT));
    try testing.expect(keycode_mod.isMouseKey(KC.MS_WH_RIGHT));
    try testing.expect(keycode_mod.isMouseKey(KC.MS_ACCEL0));
    try testing.expect(keycode_mod.isMouseKey(KC.MS_ACCEL1));
    try testing.expect(keycode_mod.isMouseKey(KC.MS_ACCEL2));
    try testing.expect(!keycode_mod.isMouseKey(KC.A));
    try testing.expect(!keycode_mod.isMouseKey(KC.SPACE));
}

test "mousekey ドライバー未設定でもパニックしない" {
    clear();
    timer.mockReset();
    host_mod.clearDriver();

    on(KC.MS_UP);
    send();

    clear();
}
