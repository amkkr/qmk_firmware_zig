// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zig port of quantum/mousekey.c
// Original: Copyright 2011 Jun Wako <wakojun@gmail.com>

//! Mousekey - キーボードによるマウス操作
//! Based on quantum/mousekey.c, quantum/mousekey.h
//!
//! マウスカーソル移動、ボタンクリック、スクロールホイール操作をキーで実行する。
//!
//! 4つの加速モードをサポート:
//! - **default**: デフォルト加速モード（時間経過で加速、ACCEL0/1/2で固定速度切替）
//! - **three_speed**: 3段階速度切替モード（MK_3_SPEED 相当、離散的な速度レベル）
//! - **kinetic_speed**: 運動学ベース加速モード（MK_KINETIC_SPEED 相当、二次関数的加速）
//! - **inertia**: 慣性モード（MOUSEKEY_INERTIA 相当、摩擦と慣性によるモメンタム移動）

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
// 加速モード
// ============================================================

/// マウスキーの加速モード（upstream の #ifdef 分岐に相当）
pub const AccelMode = enum {
    /// デフォルト加速モード（時間経過で線形加速、ACCEL0/1/2で固定速度切替）
    default,
    /// 3段階速度切替モード（MK_3_SPEED 相当）
    /// ACCEL0=slow, ACCEL1=normal, ACCEL2=fast の離散的速度レベル
    three_speed,
    /// 運動学ベース加速モード（MK_KINETIC_SPEED 相当）
    /// current_speed = initial + acceleration * T/50 + acceleration * (T/50)^2 / 2
    kinetic_speed,
    /// 慣性モード（MOUSEKEY_INERTIA 相当）
    /// 摩擦と加速による物理シミュレーション、キーリリース後も慣性で移動継続
    inertia,
};

// ============================================================
// 設定パラメータ
// ============================================================

/// デフォルト加速モードの設定（upstream のデフォルト値に準拠）
pub const Config = struct {
    /// マウス移動1ステップのピクセル数
    move_delta: u8 = 8,
    /// 最大移動値（HID レポートの i8 範囲内）
    move_max: u8 = 127,
    /// キー押下からリピート開始までの遅延（ms）
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

/// 3段階速度切替モードの設定（MK_3_SPEED 相当）
pub const ThreeSpeedConfig = struct {
    /// 速度レベルごとのカーソル移動オフセット [unmod, speed0, speed1, speed2]
    c_offsets: [4]u16 = .{ 16, 16, 4, 32 },
    /// 速度レベルごとのカーソル移動間隔（ms）[unmod, speed0, speed1, speed2]
    c_intervals: [4]u16 = .{ 16, 32, 16, 16 },
    /// 速度レベルごとのホイール移動オフセット [unmod, speed0, speed1, speed2]
    w_offsets: [4]u16 = .{ 1, 1, 1, 1 },
    /// 速度レベルごとのホイール移動間隔（ms）[unmod, speed0, speed1, speed2]
    w_intervals: [4]u16 = .{ 40, 360, 120, 20 },
    /// momentary accel 有効（キーリリースで速度がデフォルトに戻る）
    momentary_accel: bool = false,
};

/// 運動学ベース加速モードの設定（MK_KINETIC_SPEED 相当）
pub const KineticSpeedConfig = struct {
    /// 移動1ステップのピクセル数
    move_delta: u8 = 16,
    /// 最大移動値
    move_max: u8 = 127,
    /// キー押下からリピート開始までの遅延（ms）
    delay_ms: u16 = 50,
    /// リピート間隔（ms）
    interval: u16 = 10,
    /// 初速度（units/s）
    initial_speed: u16 = 100,
    /// 基本速度（最大到達速度、units/s）
    base_speed: u16 = 5000,
    /// 減速速度（ACCEL0 押下時の固定速度）
    decelerated_speed: u16 = 400,
    /// 加速速度（ACCEL2 押下時の固定速度）
    accelerated_speed: u16 = 3000,
    /// ホイール初期移動回数/秒
    wheel_initial_movements: u16 = 16,
    /// ホイール基本移動回数/秒（最大到達値）
    wheel_base_movements: u16 = 32,
    /// ホイール加速移動回数/秒（ACCEL2 押下時）
    wheel_accelerated_movements: u16 = 48,
    /// ホイール減速移動回数/秒（ACCEL0 押下時）
    wheel_decelerated_movements: u16 = 8,
};

/// 慣性モードの設定（MOUSEKEY_INERTIA 相当）
pub const InertiaConfig = struct {
    /// 移動1ステップのピクセル数（初回移動量）
    move_delta: u8 = 1,
    /// 最大移動値
    move_max: u8 = 127,
    /// キー押下からリピート開始までの遅延（ms）
    delay_ms: u16 = 1500,
    /// リピート間隔（ms）（16ms ≈ 60fps）
    interval: u16 = 16,
    /// 最大速度倍率
    max_speed: u8 = 32,
    /// 最大速度に到達するまでのステップ数
    time_to_max: u8 = 32,
    /// 摩擦係数（0-255、大きいほど早く減速）
    friction: u8 = 24,
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
pub const default_three_speed_config = ThreeSpeedConfig{};
pub const default_kinetic_speed_config = KineticSpeedConfig{};
pub const default_inertia_config = InertiaConfig{};

// ============================================================
// モジュール状態
// ============================================================

var accel_mode: AccelMode = .default;
var config: Config = default_config;
var three_speed_config: ThreeSpeedConfig = default_three_speed_config;
var kinetic_speed_config: KineticSpeedConfig = default_kinetic_speed_config;
var inertia_config: InertiaConfig = default_inertia_config;

var mouse_report: MouseReport = .{};
var mousekey_accel: u8 = 0;
var mousekey_repeat: u8 = 0;
var mousekey_wheel_repeat: u8 = 0;
var last_timer_c: u16 = 0;
var last_timer_w: u16 = 0;

// MK_3_SPEED 状態
/// 速度レベルインデックス: 0=unmod, 1=speed0, 2=speed1, 3=speed2
var mk_speed: u8 = 1; // デフォルトは speed1 (normal)

// MK_KINETIC_SPEED 状態
var mouse_timer: u16 = 0;
/// kinetic_speed モードでのホイールインターバル（動的に変更される）
var kinetic_wheel_interval: u16 = 0;

// MOUSEKEY_INERTIA 状態
/// フレーム状態: 0=非アクティブ, 1=初回フレーム, 2+=リピート中
var mousekey_frame: u8 = 0;
/// X方向: -1=左, 0=ニュートラル, 1=右
var mousekey_x_dir: i8 = 0;
/// Y方向: -1=上, 0=ニュートラル, 1=下
var mousekey_y_dir: i8 = 0;
/// X軸の慣性（速度）、-time_to_max から +time_to_max
var mousekey_x_inertia: i8 = 0;
/// Y軸の慣性（速度）、-time_to_max から +time_to_max
var mousekey_y_inertia: i8 = 0;

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

/// デフォルト加速モードの移動速度計算
fn moveUnitDefault() u8 {
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

/// デフォルト加速モードのホイール速度計算
fn wheelUnitDefault() u8 {
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

/// 運動学モードの移動速度計算
fn moveUnitKinetic() u8 {
    var speed: u32 = kinetic_speed_config.initial_speed;

    if (mousekey_accel & (1 << 0) != 0) {
        speed = kinetic_speed_config.decelerated_speed;
    } else if (mousekey_accel & (1 << 2) != 0) {
        speed = kinetic_speed_config.accelerated_speed;
    } else if (mousekey_repeat != 0 and mouse_timer != 0) {
        const time_elapsed: u32 = @as(u32, timer.elapsed(mouse_timer)) / 50;
        speed = @as(u32, kinetic_speed_config.initial_speed) +
            @as(u32, kinetic_speed_config.move_delta) * time_elapsed +
            (@as(u32, kinetic_speed_config.move_delta) * time_elapsed * time_elapsed) / 2;
        if (speed > kinetic_speed_config.base_speed) {
            speed = kinetic_speed_config.base_speed;
        }
    }

    // USB マウス速度に変換 (1 ~ 127)
    const divisor: u32 = 1000 / @as(u32, kinetic_speed_config.interval);
    speed = speed / divisor;

    if (speed > kinetic_speed_config.move_max) {
        return kinetic_speed_config.move_max;
    } else if (speed < 1) {
        return 1;
    }
    return @intCast(speed);
}

/// 運動学モードのホイール速度計算
/// upstream と同様、ホイールインターバルを動的に変更し、常に1を返す
fn wheelUnitKinetic() u8 {
    var speed: u32 = kinetic_speed_config.wheel_initial_movements;

    if (mousekey_accel & (1 << 0) != 0) {
        speed = kinetic_speed_config.wheel_decelerated_movements;
    } else if (mousekey_accel & (1 << 2) != 0) {
        speed = kinetic_speed_config.wheel_accelerated_movements;
    } else if (mousekey_wheel_repeat != 0 and mouse_timer != 0) {
        // kinetic_wheel_interval (ms) が最大速度時のインターバル (1000/wheel_base_movements ms) より
        // 大きい場合、まだ加速の余地があるので加速計算を実行する。
        if (kinetic_wheel_interval > 1000 / @as(u16, kinetic_speed_config.wheel_base_movements)) {
            const time_elapsed: u32 = @as(u32, timer.elapsed(mouse_timer)) / 50;
            speed = @as(u32, kinetic_speed_config.wheel_initial_movements) +
                1 * time_elapsed +
                (1 * time_elapsed * time_elapsed) / 2;
        }
        if (speed > kinetic_speed_config.wheel_base_movements) {
            speed = kinetic_speed_config.wheel_base_movements;
        }
    }

    if (speed > 0) {
        kinetic_wheel_interval = @intCast(1000 / speed);
    }
    return 1;
}

/// 慣性モードの移動速度計算（軸ごと）
/// 純粋な計算関数。mousekey_frame の更新は呼び出し側（onInertia / taskInertia）で行う。
fn moveUnitInertia(axis: u1) i8 {
    var unit: i16 = undefined;

    const inertia_val: i8 = if (axis == 1) mousekey_y_inertia else mousekey_x_inertia;
    const dir: i8 = if (axis == 1) mousekey_y_dir else mousekey_x_dir;

    if (mousekey_frame < 2) {
        // 初回フレーム: 初期キー押下で1ピクセル移動
        // mousekey_frame のセットは呼び出し側（onInertia）が担う
        unit = @as(i16, dir) * @as(i16, inertia_config.move_delta);
    } else {
        // 二次関数的加速: percent = (inertia / time_to_max)^2
        var percent: i16 = @divTrunc(@as(i16, inertia_val) << 8, @as(i16, inertia_config.time_to_max));
        percent = @intCast(@divTrunc(@as(i32, percent) * @as(i32, percent), 256));
        if (inertia_val < 0) percent = -percent;

        // unit = sign(inertia) + (percent of max speed)
        if (inertia_val > 0) {
            unit = 1;
        } else if (inertia_val < 0) {
            unit = -1;
        } else {
            unit = 0;
        }

        unit = unit + @as(i16, @intCast(@divTrunc(@as(i32, inertia_config.max_speed) * @as(i32, percent), 256)));
    }

    const move_max_i16: i16 = @as(i16, inertia_config.move_max);
    if (unit > move_max_i16) {
        return @intCast(move_max_i16);
    } else if (unit < -move_max_i16) {
        return @intCast(-move_max_i16);
    }
    return @intCast(unit);
}

/// 慣性モードの加速・減速計算
fn calcInertia(direction: i8, velocity: i8) i8 {
    var vel: i16 = @as(i16, velocity);

    // 減速（摩擦）
    if (direction > -1 and vel < 0) {
        vel = @divTrunc((vel + 1) * (256 - @as(i16, inertia_config.friction)), 256);
    } else if (direction < 1 and vel > 0) {
        vel = @divTrunc(vel * (256 - @as(i16, inertia_config.friction)), 256);
    }

    // 加速
    const ttm: i16 = @as(i16, inertia_config.time_to_max);
    if (direction > 0 and vel < ttm) {
        vel += 1;
    } else if (direction < 0 and vel > -ttm) {
        vel -= 1;
    }

    // i8 範囲にクランプ
    if (vel > 127) return 127;
    if (vel < -128) return -128;
    return @intCast(vel);
}

/// キーコードからマウスボタンかどうか判定
fn isMouseButton(code: u8) bool {
    return code >= @as(u8, @truncate(KC.MS_BTN1)) and code <= @as(u8, @truncate(KC.MS_BTN8));
}

/// 対角移動の補正を適用（cursor）
fn applyDiagonalCorrection(x: i8, y: i8, orig_x_positive: bool, orig_y_positive: bool) struct { x: i8, y: i8 } {
    var rx = timesInvSqrt2(x);
    if (rx == 0) rx = if (orig_x_positive) @as(i8, 1) else -1;
    var ry = timesInvSqrt2(y);
    if (ry == 0) ry = if (orig_y_positive) @as(i8, 1) else -1;
    return .{ .x = rx, .y = ry };
}

// ============================================================
// 公開 API: モード・設定
// ============================================================

/// 加速モードを設定
pub fn setAccelMode(mode: AccelMode) void {
    accel_mode = mode;
    // モード切替時に状態をリセット
    clear();
    // 3段階モード初期化
    // upstream: non-momentary デフォルトは mkspd_1 (index 2 = speed1/normal)
    //           momentary デフォルトは mkspd_unmod (index 0)
    if (mode == .three_speed) {
        mk_speed = if (three_speed_config.momentary_accel) 0 else 2;
    }
    // kinetic_speed モード初期化
    if (mode == .kinetic_speed) {
        kinetic_wheel_interval = @intCast(1000 / @as(u32, kinetic_speed_config.wheel_initial_movements));
    }
}

/// 現在の加速モードを取得
pub fn getAccelMode() AccelMode {
    return accel_mode;
}

/// デフォルトモードの設定を変更
pub fn setConfig(cfg: Config) void {
    config = cfg;
}

/// 現在のデフォルトモード設定を取得
pub fn getConfig() Config {
    return config;
}

/// 3段階速度モードの設定を変更
pub fn setThreeSpeedConfig(cfg: ThreeSpeedConfig) void {
    three_speed_config = cfg;
}

/// 3段階速度モードの設定を取得
pub fn getThreeSpeedConfig() ThreeSpeedConfig {
    return three_speed_config;
}

/// 運動学モードの設定を変更
pub fn setKineticSpeedConfig(cfg: KineticSpeedConfig) void {
    kinetic_speed_config = cfg;
}

/// 運動学モードの設定を取得
pub fn getKineticSpeedConfig() KineticSpeedConfig {
    return kinetic_speed_config;
}

/// 慣性モードの設定を変更
pub fn setInertiaConfig(cfg: InertiaConfig) void {
    inertia_config = cfg;
}

/// 慣性モードの設定を取得
pub fn getInertiaConfig() InertiaConfig {
    return inertia_config;
}

// ============================================================
// 公開 API: キー操作
// ============================================================

/// キー押下時の処理
pub fn on(code: Keycode) void {
    const c: u8 = @truncate(code);

    switch (accel_mode) {
        .three_speed => onThreeSpeed(c),
        .kinetic_speed => onDefault(c),
        .inertia => onInertia(c),
        .default => onDefault(c),
    }
}

/// キー解放時の処理
pub fn off(code: Keycode) void {
    const c: u8 = @truncate(code);

    switch (accel_mode) {
        .three_speed => offThreeSpeed(c),
        .inertia => offInertia(c),
        .default, .kinetic_speed => offDefault(c),
    }

    // キネティックモード固有のタイマーリセット
    if (accel_mode == .kinetic_speed) {
        if (mouse_report.x == 0 and mouse_report.y == 0) {
            mouse_timer = 0;
        }
    }
}

/// 定期実行タスク - マウスレポートの更新と送信
pub fn task() void {
    switch (accel_mode) {
        .three_speed => taskThreeSpeed(),
        .inertia => taskInertia(),
        .default, .kinetic_speed => taskDefault(),
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
    // kinetic_speed 状態
    mouse_timer = 0;
    kinetic_wheel_interval = 0;
    // inertia 状態
    mousekey_frame = 0;
    mousekey_x_dir = 0;
    mousekey_y_dir = 0;
    mousekey_x_inertia = 0;
    mousekey_y_inertia = 0;
}

/// 現在のマウスレポートを取得
pub fn getReport() MouseReport {
    return mouse_report;
}

// ============================================================
// デフォルトモード実装
// ============================================================

fn onDefault(c: u8) void {
    // kinetic_speed モードのタイマー開始
    if (accel_mode == .kinetic_speed) {
        if (mouse_timer == 0 and (isCursorKey(c) or isWheelKey(c))) {
            mouse_timer = timer.read();
        }
    }

    if (c == @as(u8, @truncate(KC.MS_UP))) {
        const unit_val = if (accel_mode == .kinetic_speed) moveUnitKinetic() else moveUnitDefault();
        mouse_report.y = -@as(i8, @intCast(unit_val));
    } else if (c == @as(u8, @truncate(KC.MS_DOWN))) {
        mouse_report.y = @intCast(if (accel_mode == .kinetic_speed) moveUnitKinetic() else moveUnitDefault());
    } else if (c == @as(u8, @truncate(KC.MS_LEFT))) {
        const unit_val = if (accel_mode == .kinetic_speed) moveUnitKinetic() else moveUnitDefault();
        mouse_report.x = -@as(i8, @intCast(unit_val));
    } else if (c == @as(u8, @truncate(KC.MS_RIGHT))) {
        mouse_report.x = @intCast(if (accel_mode == .kinetic_speed) moveUnitKinetic() else moveUnitDefault());
    } else if (c == @as(u8, @truncate(KC.MS_WH_UP))) {
        mouse_report.v = @intCast(if (accel_mode == .kinetic_speed) wheelUnitKinetic() else wheelUnitDefault());
    } else if (c == @as(u8, @truncate(KC.MS_WH_DOWN))) {
        const unit_val = if (accel_mode == .kinetic_speed) wheelUnitKinetic() else wheelUnitDefault();
        mouse_report.v = -@as(i8, @intCast(unit_val));
    } else if (c == @as(u8, @truncate(KC.MS_WH_LEFT))) {
        const unit_val = if (accel_mode == .kinetic_speed) wheelUnitKinetic() else wheelUnitDefault();
        mouse_report.h = -@as(i8, @intCast(unit_val));
    } else if (c == @as(u8, @truncate(KC.MS_WH_RIGHT))) {
        mouse_report.h = @intCast(if (accel_mode == .kinetic_speed) wheelUnitKinetic() else wheelUnitDefault());
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

fn offDefault(c: u8) void {
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

fn taskDefault() void {
    const tmpmr = mouse_report;

    mouse_report.x = 0;
    mouse_report.y = 0;
    mouse_report.v = 0;
    mouse_report.h = 0;

    // カーソル移動の処理
    const cursor_delay = if (accel_mode == .kinetic_speed) kinetic_speed_config.delay_ms else config.delay_ms;
    const cursor_interval = if (accel_mode == .kinetic_speed) kinetic_speed_config.interval else config.interval;
    if ((tmpmr.x != 0 or tmpmr.y != 0) and
        timer.elapsed(last_timer_c) > if (mousekey_repeat != 0) cursor_interval else cursor_delay)
    {
        if (mousekey_repeat != 255) mousekey_repeat += 1;
        if (tmpmr.x != 0) {
            const unit_val = if (accel_mode == .kinetic_speed) moveUnitKinetic() else moveUnitDefault();
            mouse_report.x = if (tmpmr.x > 0)
                @intCast(unit_val)
            else
                -@as(i8, @intCast(unit_val));
        }
        if (tmpmr.y != 0) {
            const unit_val = if (accel_mode == .kinetic_speed) moveUnitKinetic() else moveUnitDefault();
            mouse_report.y = if (tmpmr.y > 0)
                @intCast(unit_val)
            else
                -@as(i8, @intCast(unit_val));
        }

        // 対角移動の補正
        if (mouse_report.x != 0 and mouse_report.y != 0) {
            const corrected = applyDiagonalCorrection(mouse_report.x, mouse_report.y, tmpmr.x > 0, tmpmr.y > 0);
            mouse_report.x = corrected.x;
            mouse_report.y = corrected.y;
        }
    }

    // スクロールの処理
    const wheel_delay = if (accel_mode == .kinetic_speed) cursor_delay else config.wheel_delay_ms;
    const wheel_interval_val = if (accel_mode == .kinetic_speed) kinetic_wheel_interval else config.wheel_interval;
    if ((tmpmr.v != 0 or tmpmr.h != 0) and
        timer.elapsed(last_timer_w) > if (mousekey_wheel_repeat != 0) wheel_interval_val else wheel_delay)
    {
        if (mousekey_wheel_repeat != 255) mousekey_wheel_repeat += 1;
        if (tmpmr.v != 0) {
            const unit_val = if (accel_mode == .kinetic_speed) wheelUnitKinetic() else wheelUnitDefault();
            mouse_report.v = if (tmpmr.v > 0)
                @intCast(unit_val)
            else
                -@as(i8, @intCast(unit_val));
        }
        if (tmpmr.h != 0) {
            const unit_val = if (accel_mode == .kinetic_speed) wheelUnitKinetic() else wheelUnitDefault();
            mouse_report.h = if (tmpmr.h > 0)
                @intCast(unit_val)
            else
                -@as(i8, @intCast(unit_val));
        }

        // 対角スクロールの補正
        if (mouse_report.v != 0 and mouse_report.h != 0) {
            mouse_report.v = timesInvSqrt2(mouse_report.v);
            if (mouse_report.v == 0) mouse_report.v = if (tmpmr.v > 0) @as(i8, 1) else -1;
            mouse_report.h = timesInvSqrt2(mouse_report.h);
            if (mouse_report.h == 0) mouse_report.h = if (tmpmr.h > 0) @as(i8, 1) else -1;
        }
    }

    if (shouldSend(&mouse_report)) {
        send();
    }

    // 状態を復元（方向情報を保持するため）
    mouse_report = tmpmr;
}

// ============================================================
// 3段階速度モード実装 (MK_3_SPEED)
// ============================================================

fn adjustSpeed() void {
    const c_offset: i8 = @intCast(@min(three_speed_config.c_offsets[mk_speed], 127));
    const w_offset: i8 = @intCast(@min(three_speed_config.w_offsets[mk_speed], 127));

    if (mouse_report.x > 0) mouse_report.x = c_offset;
    if (mouse_report.x < 0) mouse_report.x = -c_offset;
    if (mouse_report.y > 0) mouse_report.y = c_offset;
    if (mouse_report.y < 0) mouse_report.y = -c_offset;
    if (mouse_report.h > 0) mouse_report.h = w_offset;
    if (mouse_report.h < 0) mouse_report.h = -w_offset;
    if (mouse_report.v > 0) mouse_report.v = w_offset;
    if (mouse_report.v < 0) mouse_report.v = -w_offset;

    // 対角移動の補正
    if (mouse_report.x != 0 and mouse_report.y != 0) {
        mouse_report.x = timesInvSqrt2(mouse_report.x);
        if (mouse_report.x == 0) mouse_report.x = 1;
        mouse_report.y = timesInvSqrt2(mouse_report.y);
        if (mouse_report.y == 0) mouse_report.y = 1;
    }
    if (mouse_report.h != 0 and mouse_report.v != 0) {
        mouse_report.h = timesInvSqrt2(mouse_report.h);
        mouse_report.v = timesInvSqrt2(mouse_report.v);
    }
}

fn onThreeSpeed(c: u8) void {
    const c_offset: i8 = @intCast(@min(three_speed_config.c_offsets[mk_speed], 127));
    const w_offset: i8 = @intCast(@min(three_speed_config.w_offsets[mk_speed], 127));
    const old_speed = mk_speed;

    if (c == @as(u8, @truncate(KC.MS_UP))) {
        mouse_report.y = -c_offset;
    } else if (c == @as(u8, @truncate(KC.MS_DOWN))) {
        mouse_report.y = c_offset;
    } else if (c == @as(u8, @truncate(KC.MS_LEFT))) {
        mouse_report.x = -c_offset;
    } else if (c == @as(u8, @truncate(KC.MS_RIGHT))) {
        mouse_report.x = c_offset;
    } else if (c == @as(u8, @truncate(KC.MS_WH_UP))) {
        mouse_report.v = w_offset;
    } else if (c == @as(u8, @truncate(KC.MS_WH_DOWN))) {
        mouse_report.v = -w_offset;
    } else if (c == @as(u8, @truncate(KC.MS_WH_LEFT))) {
        mouse_report.h = -w_offset;
    } else if (c == @as(u8, @truncate(KC.MS_WH_RIGHT))) {
        mouse_report.h = w_offset;
    } else if (isMouseButton(c)) {
        const shift: u3 = @intCast(c - @as(u8, @truncate(KC.MS_BTN1)));
        mouse_report.buttons |= @as(u8, 1) << shift;
    } else if (c == @as(u8, @truncate(KC.MS_ACCEL0))) {
        mk_speed = 1; // speed0
    } else if (c == @as(u8, @truncate(KC.MS_ACCEL1))) {
        mk_speed = 2; // speed1
    } else if (c == @as(u8, @truncate(KC.MS_ACCEL2))) {
        mk_speed = 3; // speed2
    }

    if (mk_speed != old_speed) adjustSpeed();
}

fn offThreeSpeed(c: u8) void {
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
    } else if (three_speed_config.momentary_accel) {
        const mkspd_default: u8 = 0; // unmod
        if (c == @as(u8, @truncate(KC.MS_ACCEL0)) or
            c == @as(u8, @truncate(KC.MS_ACCEL1)) or
            c == @as(u8, @truncate(KC.MS_ACCEL2)))
        {
            const prev_speed = mk_speed;
            mk_speed = mkspd_default;
            if (mk_speed != prev_speed) adjustSpeed();
        }
    }
}

fn taskThreeSpeed() void {
    const tmpmr = mouse_report;
    mouse_report.x = 0;
    mouse_report.y = 0;
    mouse_report.v = 0;
    mouse_report.h = 0;

    if ((tmpmr.x != 0 or tmpmr.y != 0) and timer.elapsed(last_timer_c) > three_speed_config.c_intervals[mk_speed]) {
        mouse_report.x = tmpmr.x;
        mouse_report.y = tmpmr.y;
    }
    if ((tmpmr.h != 0 or tmpmr.v != 0) and timer.elapsed(last_timer_w) > three_speed_config.w_intervals[mk_speed]) {
        mouse_report.v = tmpmr.v;
        mouse_report.h = tmpmr.h;
    }

    if (shouldSend(&mouse_report)) {
        send();
    }
    mouse_report = tmpmr;
}

// ============================================================
// 慣性モード実装 (MOUSEKEY_INERTIA)
// ============================================================

fn onInertia(c: u8) void {
    // カーソルキー: 方向を設定し、初回フレームの移動量を計算
    if (c == @as(u8, @truncate(KC.MS_UP)) or c == @as(u8, @truncate(KC.MS_DOWN))) {
        mousekey_y_dir = if (c == @as(u8, @truncate(KC.MS_DOWN))) @as(i8, 1) else @as(i8, -1);
        if (mousekey_frame < 2) {
            // moveUnitInertia の副作用を排除し、ここで明示的にフレームを初期化する
            mousekey_frame = 1;
            mouse_report.y = moveUnitInertia(1);
        }
    } else if (c == @as(u8, @truncate(KC.MS_LEFT)) or c == @as(u8, @truncate(KC.MS_RIGHT))) {
        mousekey_x_dir = if (c == @as(u8, @truncate(KC.MS_RIGHT))) @as(i8, 1) else @as(i8, -1);
        if (mousekey_frame < 2) {
            // moveUnitInertia の副作用を排除し、ここで明示的にフレームを初期化する
            mousekey_frame = 1;
            mouse_report.x = moveUnitInertia(0);
        }
    }
    // ホイール・ボタン・アクセルはデフォルトモードと共通
    else if (c == @as(u8, @truncate(KC.MS_WH_UP))) {
        mouse_report.v = @intCast(wheelUnitInertiaDefault());
    } else if (c == @as(u8, @truncate(KC.MS_WH_DOWN))) {
        const unit_val = wheelUnitInertiaDefault();
        mouse_report.v = -@as(i8, @intCast(unit_val));
    } else if (c == @as(u8, @truncate(KC.MS_WH_LEFT))) {
        const unit_val = wheelUnitInertiaDefault();
        mouse_report.h = -@as(i8, @intCast(unit_val));
    } else if (c == @as(u8, @truncate(KC.MS_WH_RIGHT))) {
        mouse_report.h = @intCast(wheelUnitInertiaDefault());
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

fn offInertia(c: u8) void {
    // 慣性モード: キーリリースは方向をクリアする（反対方向が押されていない場合）
    if (c == @as(u8, @truncate(KC.MS_UP)) and mousekey_y_dir < 1) {
        mousekey_y_dir = 0;
    } else if (c == @as(u8, @truncate(KC.MS_DOWN)) and mousekey_y_dir > -1) {
        mousekey_y_dir = 0;
    } else if (c == @as(u8, @truncate(KC.MS_LEFT)) and mousekey_x_dir < 1) {
        mousekey_x_dir = 0;
    } else if (c == @as(u8, @truncate(KC.MS_RIGHT)) and mousekey_x_dir > -1) {
        mousekey_x_dir = 0;
    }
    // ホイール・ボタン・アクセルはデフォルトモードと共通
    else if (c == @as(u8, @truncate(KC.MS_WH_UP)) and mouse_report.v > 0) {
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

fn taskInertia() void {
    const tmpmr = mouse_report;

    mouse_report.x = 0;
    mouse_report.y = 0;
    mouse_report.v = 0;
    mouse_report.h = 0;

    // 慣性カーソル移動処理
    if (mousekey_frame != 0 and
        timer.elapsed(last_timer_c) > if (mousekey_frame > 1) inertia_config.interval else inertia_config.delay_ms)
    {
        mousekey_x_inertia = calcInertia(mousekey_x_dir, mousekey_x_inertia);
        mousekey_y_inertia = calcInertia(mousekey_y_dir, mousekey_y_inertia);

        mouse_report.x = moveUnitInertia(0);
        mouse_report.y = moveUnitInertia(1);

        // sticky "drift" 防止
        var restored_tmpmr = tmpmr;
        if (mousekey_x_dir == 0 and mousekey_x_inertia == 0) restored_tmpmr.x = 0;
        if (mousekey_y_dir == 0 and mousekey_y_inertia == 0) restored_tmpmr.y = 0;

        if (mousekey_frame < 2) mousekey_frame += 1;

        // 移動キーも慣性もない場合はアニメーション停止
        if (mousekey_x_dir == 0 and mousekey_y_dir == 0 and mousekey_x_inertia == 0 and mousekey_y_inertia == 0) {
            mousekey_frame = 0;
            mouse_report.x = 0;
            mouse_report.y = 0;
        }

        // ホイール処理
        if ((restored_tmpmr.v != 0 or restored_tmpmr.h != 0) and
            timer.elapsed(last_timer_w) > if (mousekey_wheel_repeat != 0) inertia_config.wheel_interval else inertia_config.wheel_delay_ms)
        {
            if (mousekey_wheel_repeat != 255) mousekey_wheel_repeat += 1;
            if (restored_tmpmr.v != 0) {
                const unit_val = wheelUnitInertiaDefault();
                mouse_report.v = if (restored_tmpmr.v > 0)
                    @intCast(unit_val)
                else
                    -@as(i8, @intCast(unit_val));
            }
            if (restored_tmpmr.h != 0) {
                const unit_val = wheelUnitInertiaDefault();
                mouse_report.h = if (restored_tmpmr.h > 0)
                    @intCast(unit_val)
                else
                    -@as(i8, @intCast(unit_val));
            }

            // 対角スクロールの補正
            if (mouse_report.v != 0 and mouse_report.h != 0) {
                mouse_report.v = timesInvSqrt2(mouse_report.v);
                if (mouse_report.v == 0) mouse_report.v = if (restored_tmpmr.v > 0) @as(i8, 1) else -1;
                mouse_report.h = timesInvSqrt2(mouse_report.h);
                if (mouse_report.h == 0) mouse_report.h = if (restored_tmpmr.h > 0) @as(i8, 1) else -1;
            }
        }

        if (shouldSend(&mouse_report)) {
            send();
        }
        mouse_report = restored_tmpmr;
        return;
    }

    // 移動キーも慣性もない場合はリセット
    if (mousekey_x_dir == 0 and mousekey_y_dir == 0 and mousekey_x_inertia == 0 and mousekey_y_inertia == 0) {
        mousekey_frame = 0;
        var restored_tmpmr = tmpmr;
        restored_tmpmr.x = 0;
        restored_tmpmr.y = 0;

        // ホイール処理（カーソル移動がなくてもホイールは動作する）
        if ((restored_tmpmr.v != 0 or restored_tmpmr.h != 0) and
            timer.elapsed(last_timer_w) > if (mousekey_wheel_repeat != 0) inertia_config.wheel_interval else inertia_config.wheel_delay_ms)
        {
            if (mousekey_wheel_repeat != 255) mousekey_wheel_repeat += 1;
            if (restored_tmpmr.v != 0) {
                const unit_val = wheelUnitInertiaDefault();
                mouse_report.v = if (restored_tmpmr.v > 0)
                    @intCast(unit_val)
                else
                    -@as(i8, @intCast(unit_val));
            }
            if (restored_tmpmr.h != 0) {
                const unit_val = wheelUnitInertiaDefault();
                mouse_report.h = if (restored_tmpmr.h > 0)
                    @intCast(unit_val)
                else
                    -@as(i8, @intCast(unit_val));
            }
        }

        if (shouldSend(&mouse_report)) {
            send();
        }
        mouse_report = restored_tmpmr;
        return;
    }

    // ホイール処理（タイマー未到達時）
    if ((tmpmr.v != 0 or tmpmr.h != 0) and
        timer.elapsed(last_timer_w) > if (mousekey_wheel_repeat != 0) inertia_config.wheel_interval else inertia_config.wheel_delay_ms)
    {
        if (mousekey_wheel_repeat != 255) mousekey_wheel_repeat += 1;
        if (tmpmr.v != 0) {
            const unit_val = wheelUnitInertiaDefault();
            mouse_report.v = if (tmpmr.v > 0)
                @intCast(unit_val)
            else
                -@as(i8, @intCast(unit_val));
        }
        if (tmpmr.h != 0) {
            const unit_val = wheelUnitInertiaDefault();
            mouse_report.h = if (tmpmr.h > 0)
                @intCast(unit_val)
            else
                -@as(i8, @intCast(unit_val));
        }
    }

    if (shouldSend(&mouse_report)) {
        send();
    }
    mouse_report = tmpmr;
}

/// 慣性モード用ホイール速度計算（デフォルトと同じ加速カーブを使用）
fn wheelUnitInertiaDefault() u8 {
    var unit: u32 = 0;
    if (mousekey_accel & (1 << 0) != 0) {
        unit = (@as(u32, inertia_config.wheel_delta) * @as(u32, inertia_config.wheel_max_speed)) / 4;
    } else if (mousekey_accel & (1 << 1) != 0) {
        unit = (@as(u32, inertia_config.wheel_delta) * @as(u32, inertia_config.wheel_max_speed)) / 2;
    } else if (mousekey_accel & (1 << 2) != 0) {
        unit = @as(u32, inertia_config.wheel_delta) * @as(u32, inertia_config.wheel_max_speed);
    } else if (mousekey_wheel_repeat == 0) {
        unit = @as(u32, inertia_config.wheel_delta);
    } else if (mousekey_wheel_repeat >= inertia_config.wheel_time_to_max) {
        unit = @as(u32, inertia_config.wheel_delta) * @as(u32, inertia_config.wheel_max_speed);
    } else {
        unit = (@as(u32, inertia_config.wheel_delta) * @as(u32, inertia_config.wheel_max_speed) * @as(u32, mousekey_wheel_repeat)) / @as(u32, inertia_config.wheel_time_to_max);
    }
    if (unit > inertia_config.wheel_max) return inertia_config.wheel_max;
    if (unit == 0) return 1;
    return @intCast(unit);
}

// ============================================================
// ユーティリティ
// ============================================================

/// レポートを送信すべきか判定
fn shouldSend(report: *const MouseReport) bool {
    return report.x != 0 or report.y != 0 or report.v != 0 or report.h != 0;
}

/// カーソル移動キーか判定
fn isCursorKey(c: u8) bool {
    return c == @as(u8, @truncate(KC.MS_UP)) or
        c == @as(u8, @truncate(KC.MS_DOWN)) or
        c == @as(u8, @truncate(KC.MS_LEFT)) or
        c == @as(u8, @truncate(KC.MS_RIGHT));
}

/// ホイールキーか判定
fn isWheelKey(c: u8) bool {
    return c == @as(u8, @truncate(KC.MS_WH_UP)) or
        c == @as(u8, @truncate(KC.MS_WH_DOWN)) or
        c == @as(u8, @truncate(KC.MS_WH_LEFT)) or
        c == @as(u8, @truncate(KC.MS_WH_RIGHT));
}

// ============================================================
// 後方互換 API（moveUnit / wheelUnit を公開）
// ============================================================

/// 移動速度を計算（現在のモードに応じた計算を実行）
/// デフォルトモード・運動学モードで使用
pub fn moveUnit() u8 {
    return switch (accel_mode) {
        .kinetic_speed => moveUnitKinetic(),
        else => moveUnitDefault(),
    };
}

/// ホイール速度を計算（現在のモードに応じた計算を実行）
pub fn wheelUnit() u8 {
    return switch (accel_mode) {
        .kinetic_speed => wheelUnitKinetic(),
        else => wheelUnitDefault(),
    };
}

// ============================================================
// テスト用内部状態アクセサ
// ============================================================

/// テスト用: 現在の速度レベルを取得（three_speed モード）
pub fn getSpeedLevel() u8 {
    return mk_speed;
}

/// テスト用: 現在のマウスタイマーを取得（kinetic_speed モード）
pub fn getMouseTimer() u16 {
    return mouse_timer;
}

/// テスト用: 慣性状態を取得
pub fn getInertiaState() struct { frame: u8, x_dir: i8, y_dir: i8, x_inertia: i8, y_inertia: i8 } {
    return .{
        .frame = mousekey_frame,
        .x_dir = mousekey_x_dir,
        .y_dir = mousekey_y_dir,
        .x_inertia = mousekey_x_inertia,
        .y_inertia = mousekey_y_inertia,
    };
}

/// テスト用: kinetic_wheel_interval を取得
pub fn getKineticWheelInterval() u16 {
    return kinetic_wheel_interval;
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

    pub fn sendNkro(_: *MockMouseDriver, _: report_mod.NkroReport) void {}

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
    accel_mode = .default;
    config = default_config;
    three_speed_config = default_three_speed_config;
    kinetic_speed_config = default_kinetic_speed_config;
    inertia_config = default_inertia_config;
    host_mod.setDriver(host_mod.HostDriver.from(&S.mock));
    return &S.mock;
}

fn teardownTest() void {
    host_mod.clearDriver();
    clear();
    accel_mode = .default;
}

// ============================================================
// デフォルトモードテスト（既存テストの維持）
// ============================================================

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

// ============================================================
// 3段階速度モード (MK_3_SPEED) テスト
// ============================================================

test "three_speed - 基本カーソル移動（デフォルト速度 speed1）" {
    const mock = setupTest();
    defer teardownTest();

    setAccelMode(.three_speed);
    // speed1 のデフォルト c_offset = 4
    on(KC.MS_RIGHT);
    send();
    try testing.expectEqual(@as(i8, 4), mock.last_mouse.x);

    off(KC.MS_RIGHT);
    send();
    try testing.expectEqual(@as(i8, 0), mock.last_mouse.x);
}

test "three_speed - ACCEL0 で slow 速度" {
    const mock = setupTest();
    defer teardownTest();

    setAccelMode(.three_speed);
    // ACCEL0 → speed0, c_offset = 16 (upstream MK_C_OFFSET_0 と同値)
    on(KC.MS_ACCEL0);
    on(KC.MS_RIGHT);
    send();
    try testing.expectEqual(@as(i8, 16), mock.last_mouse.x);

    off(KC.MS_ACCEL0);
    off(KC.MS_RIGHT);
}

test "three_speed - ACCEL2 で fast 速度" {
    const mock = setupTest();
    defer teardownTest();

    setAccelMode(.three_speed);
    // ACCEL2 → speed2, c_offset = 32
    on(KC.MS_ACCEL2);
    on(KC.MS_RIGHT);
    send();
    try testing.expectEqual(@as(i8, 32), mock.last_mouse.x);

    off(KC.MS_ACCEL2);
    off(KC.MS_RIGHT);
}

test "three_speed - 速度切替で既存移動量が更新される" {
    const mock = setupTest();
    defer teardownTest();

    setAccelMode(.three_speed);
    on(KC.MS_RIGHT);
    send();
    try testing.expectEqual(@as(i8, 4), mock.last_mouse.x); // speed1

    // ACCEL2 押下 → speed2 に切替、adjustSpeed() で x が 32 に更新
    on(KC.MS_ACCEL2);
    send();
    try testing.expectEqual(@as(i8, 32), mock.last_mouse.x);

    off(KC.MS_ACCEL2);
    off(KC.MS_RIGHT);
}

test "three_speed - task でインターバルごとにレポート送信" {
    const mock = setupTest();
    defer teardownTest();

    setAccelMode(.three_speed);
    on(KC.MS_RIGHT);
    send();
    const count1 = mock.mouse_count;

    // speed1 の interval = 16ms 超過
    timer.mockAdvance(17);
    task();
    try testing.expect(mock.mouse_count > count1);
    try testing.expectEqual(@as(i8, 4), mock.last_mouse.x);

    off(KC.MS_RIGHT);
}

test "three_speed - ホイール移動" {
    const mock = setupTest();
    defer teardownTest();

    setAccelMode(.three_speed);
    // speed1 の w_offset = 1
    on(KC.MS_WH_UP);
    send();
    try testing.expectEqual(@as(i8, 1), mock.last_mouse.v);

    off(KC.MS_WH_UP);
    send();
    try testing.expectEqual(@as(i8, 0), mock.last_mouse.v);
}

test "three_speed - momentary_accel でキーリリース時に速度復帰" {
    const mock = setupTest();
    defer teardownTest();

    var cfg = default_three_speed_config;
    cfg.momentary_accel = true;
    setThreeSpeedConfig(cfg);
    setAccelMode(.three_speed);

    // momentary_accel 有効時のデフォルト速度は unmod (index 0), c_offset = 16
    on(KC.MS_RIGHT);
    send();
    try testing.expectEqual(@as(i8, 16), mock.last_mouse.x); // unmod offset

    // ACCEL2 押下 → speed2, c_offset = 32
    on(KC.MS_ACCEL2);
    send();
    try testing.expectEqual(@as(i8, 32), mock.last_mouse.x);

    // ACCEL2 リリース → unmod に戻る, c_offset = 16
    off(KC.MS_ACCEL2);
    send();
    try testing.expectEqual(@as(i8, 16), mock.last_mouse.x);

    off(KC.MS_RIGHT);
}

test "three_speed - ボタン操作" {
    const mock = setupTest();
    defer teardownTest();

    setAccelMode(.three_speed);
    on(KC.MS_BTN1);
    send();
    try testing.expectEqual(@as(u8, MouseBtn.BTN1), mock.last_mouse.buttons);

    off(KC.MS_BTN1);
    send();
    try testing.expectEqual(@as(u8, 0), mock.last_mouse.buttons);
}

// ============================================================
// 運動学モード (MK_KINETIC_SPEED) テスト
// ============================================================

test "kinetic_speed - 初回移動" {
    const mock = setupTest();
    defer teardownTest();

    setAccelMode(.kinetic_speed);
    on(KC.MS_RIGHT);
    send();
    // 初速度: initial_speed=100, interval=10, speed = 100 / (1000/10) = 1
    try testing.expectEqual(@as(i8, 1), mock.last_mouse.x);

    off(KC.MS_RIGHT);
}

test "kinetic_speed - ACCEL0 で減速" {
    const mock = setupTest();
    defer teardownTest();

    setAccelMode(.kinetic_speed);
    on(KC.MS_ACCEL0);
    on(KC.MS_RIGHT);
    send();
    // decelerated_speed=400, speed = 400 / 100 = 4
    try testing.expectEqual(@as(i8, 4), mock.last_mouse.x);

    off(KC.MS_ACCEL0);
    off(KC.MS_RIGHT);
}

test "kinetic_speed - ACCEL2 で加速" {
    const mock = setupTest();
    defer teardownTest();

    setAccelMode(.kinetic_speed);
    on(KC.MS_ACCEL2);
    on(KC.MS_RIGHT);
    send();
    // accelerated_speed=3000, speed = 3000 / 100 = 30
    try testing.expectEqual(@as(i8, 30), mock.last_mouse.x);

    off(KC.MS_ACCEL2);
    off(KC.MS_RIGHT);
}

test "kinetic_speed - 時間経過で加速" {
    const mock = setupTest();
    defer teardownTest();

    setAccelMode(.kinetic_speed);
    on(KC.MS_RIGHT);
    send();
    const initial_x = mock.last_mouse.x;

    // delay 経過後に task 実行
    timer.mockAdvance(51);
    task();
    // 加速が発生するはず
    try testing.expect(mock.mouse_count >= 2);
    try testing.expect(mock.last_mouse.x >= initial_x);

    off(KC.MS_RIGHT);
}

test "kinetic_speed - ホイール動作" {
    const mock = setupTest();
    defer teardownTest();

    setAccelMode(.kinetic_speed);
    on(KC.MS_WH_UP);
    send();
    // ホイールは常に unit=1 を返す
    try testing.expectEqual(@as(i8, 1), mock.last_mouse.v);

    off(KC.MS_WH_UP);
}

test "kinetic_speed - ホイール kinetic 加速で kinetic_wheel_interval が変化する" {
    // kinetic_wheel_interval (ms) と 1000/wheel_base_movements (ms) を比較し、
    // 最大速度に達するまで加速計算を実行する。
    _ = setupTest();
    defer teardownTest();

    // タイマーを 0 以外にしておく（mouse_timer との区別のため）
    timer.mockAdvance(10);

    setAccelMode(.kinetic_speed);
    on(KC.MS_WH_UP);
    send();
    // 初回送信後: kinetic_wheel_interval = 1000 / wheel_initial_movements = 1000 / 16 = 62
    const interval_after_first = getKineticWheelInterval();
    try testing.expectEqual(@as(u16, 62), interval_after_first);

    // ホイールインターバル(62ms)を超える時間を進めて task() を実行し、リピートを発生させる。
    // last_timer_w は send() 呼び出し時(10ms)に記録される。
    // 経過時間 = 10 + 70 - 10 = 70ms > 62ms → リピート発生。
    // mouse_timer からの経過: 70ms, time_elapsed = 70/50 = 1
    // speed = 16 + 1*1 + (1*1*1)/2 = 17 → interval = 1000/17 = 58 < 62
    timer.mockAdvance(70);
    task();

    const interval_after_repeat = getKineticWheelInterval();
    try testing.expect(interval_after_repeat < interval_after_first);

    off(KC.MS_WH_UP);
}

test "kinetic_speed - ボタン操作" {
    const mock = setupTest();
    defer teardownTest();

    setAccelMode(.kinetic_speed);
    on(KC.MS_BTN1);
    send();
    try testing.expectEqual(@as(u8, MouseBtn.BTN1), mock.last_mouse.buttons);

    off(KC.MS_BTN1);
    send();
    try testing.expectEqual(@as(u8, 0), mock.last_mouse.buttons);
}

test "kinetic_speed - キーリリースでタイマーリセット" {
    _ = setupTest();
    defer teardownTest();

    // timer.read() が 0 だと mouse_timer=0 と未設定が区別できないため、
    // タイマーを進めてからテストする
    timer.mockAdvance(10);

    setAccelMode(.kinetic_speed);
    on(KC.MS_RIGHT);
    send();
    try testing.expect(mouse_timer != 0);

    off(KC.MS_RIGHT);
    // x=0, y=0 になったのでタイマーがリセットされるはず
    try testing.expectEqual(@as(u16, 0), mouse_timer);
}

// ============================================================
// 慣性モード (MOUSEKEY_INERTIA) テスト
// ============================================================

test "inertia - 初回キー押下で1ピクセル移動" {
    const mock = setupTest();
    defer teardownTest();

    setAccelMode(.inertia);
    on(KC.MS_RIGHT);
    send();
    // move_delta=1, direction=1 → unit = 1*1 = 1
    try testing.expectEqual(@as(i8, 1), mock.last_mouse.x);
    try testing.expectEqual(@as(i8, 1), mousekey_x_dir);

    off(KC.MS_RIGHT);
}

test "inertia - 方向状態の管理" {
    _ = setupTest();
    defer teardownTest();

    setAccelMode(.inertia);

    on(KC.MS_RIGHT);
    try testing.expectEqual(@as(i8, 1), mousekey_x_dir);

    off(KC.MS_RIGHT);
    try testing.expectEqual(@as(i8, 0), mousekey_x_dir);

    on(KC.MS_LEFT);
    try testing.expectEqual(@as(i8, -1), mousekey_x_dir);

    off(KC.MS_LEFT);
    try testing.expectEqual(@as(i8, 0), mousekey_x_dir);

    on(KC.MS_UP);
    try testing.expectEqual(@as(i8, -1), mousekey_y_dir);

    off(KC.MS_UP);
    try testing.expectEqual(@as(i8, 0), mousekey_y_dir);

    on(KC.MS_DOWN);
    try testing.expectEqual(@as(i8, 1), mousekey_y_dir);

    off(KC.MS_DOWN);
}

test "inertia - calcInertia 加速" {
    // 右方向に加速
    var vel = calcInertia(1, 0);
    try testing.expectEqual(@as(i8, 1), vel);
    vel = calcInertia(1, vel);
    try testing.expectEqual(@as(i8, 2), vel);

    // 左方向に加速
    vel = calcInertia(-1, 0);
    try testing.expectEqual(@as(i8, -1), vel);
    vel = calcInertia(-1, vel);
    try testing.expectEqual(@as(i8, -2), vel);
}

test "inertia - calcInertia 摩擦による減速" {
    // 正の速度で方向なし → 摩擦で減速
    const vel = calcInertia(0, 10);
    // (10 * (256 - 24)) / 256 = 10 * 232 / 256 = 2320 / 256 = 9 (切り捨て)
    try testing.expectEqual(@as(i8, 9), vel);

    // 負の速度で方向なし → 摩擦で減速
    const vel2 = calcInertia(0, -10);
    // (-10 + 1) * (256 - 24) / 256 = -9 * 232 / 256 = -2088 / 256 = -8
    try testing.expectEqual(@as(i8, -8), vel2);
}

test "inertia - calcInertia 最大速度制限" {
    // time_to_max = 32 に到達したら加速しない
    const vel = calcInertia(1, 32);
    try testing.expectEqual(@as(i8, 32), vel);

    const vel2 = calcInertia(-1, -32);
    try testing.expectEqual(@as(i8, -32), vel2);
}

test "inertia - task でフレーム進行と加速" {
    const mock = setupTest();
    defer teardownTest();

    setAccelMode(.inertia);
    on(KC.MS_RIGHT);
    send();
    try testing.expectEqual(@as(i8, 1), mock.last_mouse.x);
    try testing.expectEqual(@as(u8, 1), mousekey_frame);

    // delay (1500ms) 経過後にフレーム進行
    timer.mockAdvance(1501);
    task();
    try testing.expect(mock.mouse_count >= 2);
    try testing.expect(mousekey_frame >= 2);
    // 慣性が加速していることを確認
    try testing.expect(mousekey_x_inertia > 0);

    off(KC.MS_RIGHT);
}

test "inertia - キーリリース後も慣性で移動継続" {
    const mock = setupTest();
    defer teardownTest();

    setAccelMode(.inertia);
    on(KC.MS_RIGHT);
    send();

    // delay 経過後にフレーム進行して慣性を蓄積
    timer.mockAdvance(1501);
    task();
    try testing.expect(mousekey_x_inertia > 0);

    // さらにフレームを進行させて慣性を十分に蓄積
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        timer.mockAdvance(17);
        task();
    }
    try testing.expect(mousekey_x_inertia > 0);

    // キーリリース（方向はクリアされるが慣性は残る）
    off(KC.MS_RIGHT);
    try testing.expectEqual(@as(i8, 0), mousekey_x_dir);
    try testing.expect(mousekey_x_inertia > 0); // 慣性は残っている

    // 次の task() でも慣性による移動が発生する
    timer.mockAdvance(17);
    const count_before = mock.mouse_count;
    task();
    // 慣性が残っているのでキーリリース後もレポートが送信される
    try testing.expect(mock.mouse_count > count_before);
}

test "inertia - ボタン操作" {
    const mock = setupTest();
    defer teardownTest();

    setAccelMode(.inertia);
    on(KC.MS_BTN1);
    send();
    try testing.expectEqual(@as(u8, MouseBtn.BTN1), mock.last_mouse.buttons);

    off(KC.MS_BTN1);
    send();
    try testing.expectEqual(@as(u8, 0), mock.last_mouse.buttons);
}

test "inertia - ホイール操作" {
    const mock = setupTest();
    defer teardownTest();

    setAccelMode(.inertia);
    on(KC.MS_WH_UP);
    send();
    try testing.expectEqual(@as(i8, 1), mock.last_mouse.v);

    off(KC.MS_WH_UP);
    send();
    try testing.expectEqual(@as(i8, 0), mock.last_mouse.v);
}

test "inertia - clear で全状態リセット" {
    _ = setupTest();
    defer teardownTest();

    setAccelMode(.inertia);
    on(KC.MS_RIGHT);
    send();

    clear();

    try testing.expectEqual(@as(u8, 0), mousekey_frame);
    try testing.expectEqual(@as(i8, 0), mousekey_x_dir);
    try testing.expectEqual(@as(i8, 0), mousekey_y_dir);
    try testing.expectEqual(@as(i8, 0), mousekey_x_inertia);
    try testing.expectEqual(@as(i8, 0), mousekey_y_inertia);
    try testing.expect(getReport().isEmpty());
}

// ============================================================
// モード切替テスト
// ============================================================

test "accel_mode - デフォルトは default モード" {
    _ = setupTest();
    defer teardownTest();

    try testing.expectEqual(AccelMode.default, getAccelMode());
}

test "accel_mode - モード切替で状態がリセットされる" {
    const mock = setupTest();
    defer teardownTest();

    on(KC.MS_RIGHT);
    send();
    try testing.expect(mock.last_mouse.x > 0);

    setAccelMode(.three_speed);
    try testing.expect(getReport().isEmpty());
    try testing.expectEqual(AccelMode.three_speed, getAccelMode());
}

test "accel_mode - 各モードの設定変更と取得" {
    _ = setupTest();
    defer teardownTest();

    // three_speed
    var ts_cfg = default_three_speed_config;
    ts_cfg.c_offsets[0] = 99;
    setThreeSpeedConfig(ts_cfg);
    try testing.expectEqual(@as(u16, 99), getThreeSpeedConfig().c_offsets[0]);

    // kinetic_speed
    var ks_cfg = default_kinetic_speed_config;
    ks_cfg.initial_speed = 200;
    setKineticSpeedConfig(ks_cfg);
    try testing.expectEqual(@as(u16, 200), getKineticSpeedConfig().initial_speed);

    // inertia
    var in_cfg = default_inertia_config;
    in_cfg.friction = 48;
    setInertiaConfig(in_cfg);
    try testing.expectEqual(@as(u8, 48), getInertiaConfig().friction);
}
