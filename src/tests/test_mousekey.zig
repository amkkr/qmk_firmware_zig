//! test_mousekey.zig — Zig port of tests/mousekeys/test_mousekeys.cpp
//!
//! C版テストとの論理的等価性を重視。
//! C版では TestFixture 経由で keyboard_task() → mousekey_task() と処理されるが、
//! Zig版ではマウスキーパイプラインが keyboard.task() にまだ統合されていないため、
//! mousekey モジュールの on()/off()/task()/send() を直接呼び出してテストする。
//!
//! 参照: tests/mousekeys/test_mousekeys.cpp

const std = @import("std");
const testing = std.testing;
const mousekey = @import("../core/mousekey.zig");
const report_mod = @import("../core/report.zig");
const host_mod = @import("../core/host.zig");
const keycode = @import("../core/keycode.zig");
const timer = @import("../hal/timer.zig");

const KC = keycode.KC;
const MouseReport = report_mod.MouseReport;
const MouseBtn = report_mod.MouseBtn;

/// テスト用マウスドライバ（マウスレポートを記録する）
const TestMouseDriver = struct {
    keyboard_count: usize = 0,
    mouse_count: usize = 0,
    extra_count: usize = 0,
    last_mouse: MouseReport = .{},
    leds: u8 = 0,

    pub fn keyboardLeds(self: *TestMouseDriver) u8 {
        return self.leds;
    }

    pub fn sendKeyboard(self: *TestMouseDriver, _: report_mod.KeyboardReport) void {
        self.keyboard_count += 1;
    }

    pub fn sendMouse(self: *TestMouseDriver, r: MouseReport) void {
        self.mouse_count += 1;
        self.last_mouse = r;
    }

    pub fn sendExtra(self: *TestMouseDriver, _: report_mod.ExtraReport) void {
        self.extra_count += 1;
    }

    pub fn reset(self: *TestMouseDriver) void {
        self.keyboard_count = 0;
        self.mouse_count = 0;
        self.extra_count = 0;
        self.last_mouse = .{};
        self.leds = 0;
    }
};

/// テスト共通セットアップ
///
/// mousekey モジュールの状態をリセットし、テスト用ドライバを設定する。
fn setupMouseTest(driver: *TestMouseDriver) void {
    driver.reset();
    mousekey.clear();
    timer.mockReset();
    mousekey.setConfig(mousekey.default_config);
    host_mod.setDriver(host_mod.HostDriver.from(driver));
}

fn teardownMouseTest() void {
    host_mod.clearDriver();
    mousekey.clear();
}

// ============================================================
// C版テスト移植: tests/mousekeys/test_mousekeys.cpp
// ============================================================

// SendMouseNotCalledWhenNoKeyIsPressed
// マウスキーが押されていないときは sendMouse が呼ばれないことを検証
test "SendMouseNotCalledWhenNoKeyIsPressed" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    // キーを押さずに task() を実行
    mousekey.task();

    // マウスレポートは送信されないはず
    try testing.expectEqual(@as(usize, 0), driver.mouse_count);
}

// PressAndHoldCursorUpIsCorrectlyReported
// カーソル上キーを押し続けた場合の動作を検証
// C版: 初回 y=-8、MOUSEKEY_INTERVAL(20ms)経過後 y=-2（遅延リピート中）、
//      リリース後は空レポート
// Zig版: mousekey.interval=20ms, delay_ms=100ms
// 注意: C版との違い — C版では初回 on() で y=-8 を設定し send()、
//       interval後に task() 内で再計算して send() する（repeat=1なので y=-2相当）。
//       Zig版では同じ挙動を on()/send()/task() の組み合わせで検証する。
test "PressAndHoldCursorUpIsCorrectlyReported" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    // カーソル上キーを押す → 初回レポート: y=-8（move_delta=8）
    mousekey.on(KC.MS_UP);
    mousekey.send();

    try testing.expect(driver.mouse_count >= 1);
    try testing.expectEqual(@as(i8, -8), driver.last_mouse.y);

    const count_after_press = driver.mouse_count;

    // delay_ms (100ms) 経過後に task() を実行 → リピート開始（repeat=1）
    // repeat=1 のとき: unit = (8 * 10 * 1) / 30 = 2
    timer.mockAdvance(101);
    mousekey.task();

    // リピートが発生してレポートが追加送信されるはず
    // repeat=1: unit = (8 * 10 * 1) / 30 = 2 → y == -2
    try testing.expect(driver.mouse_count > count_after_press);
    try testing.expectEqual(@as(i8, -2), driver.last_mouse.y);

    // キーをリリース → 空レポート
    mousekey.off(KC.MS_UP);
    mousekey.send();

    try testing.expectEqual(@as(i8, 0), driver.last_mouse.y);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.x);
    try testing.expectEqual(@as(u8, 0), driver.last_mouse.buttons);
}

// PressAndHoldButtonOneCorrectlyReported
// マウスボタン1を押し続けた場合の動作を検証
// ボタンはリピートしない（押下時のみレポート送信）
test "PressAndHoldButtonOneCorrectlyReported" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    // ボタン1を押す → レポート: buttons=1
    mousekey.on(KC.MS_BTN1);
    mousekey.send();

    try testing.expect(driver.mouse_count >= 1);
    try testing.expectEqual(@as(u8, MouseBtn.BTN1), driver.last_mouse.buttons);

    // interval 経過後に task() を実行 → ボタンはリピートしない
    // task() はボタン変化がないためレポートを送信しない
    const count_before = driver.mouse_count;
    timer.mockAdvance(21);
    mousekey.task();
    // ボタンだけ押している場合はshouldSend()がx/y/v/hのみ検査しbuttonsを見ないためレポート送信なし
    try testing.expectEqual(count_before, driver.mouse_count);

    // キーをリリース → 空レポート
    mousekey.off(KC.MS_BTN1);
    mousekey.send();

    try testing.expectEqual(@as(u8, 0), driver.last_mouse.buttons);
}

// PressAndReleaseIsCorrectlyReported — 各マウスキーのパラメタライズドテスト相当
// C版 INSTANTIATE_TEST_CASE_P のテストケースを個別にテストとして移植
//
// 各キーを押してリリースしたとき、期待するレポート値が得られることを検証する。

test "PressAndRelease_Button1" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    mousekey.on(KC.MS_BTN1);
    mousekey.send();
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.x);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.y);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.h);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.v);
    try testing.expectEqual(@as(u8, 1), driver.last_mouse.buttons);

    mousekey.off(KC.MS_BTN1);
    mousekey.send();
    try testing.expectEqual(@as(u8, 0), driver.last_mouse.buttons);

    // 追加スキャン後もレポートなし
    const count = driver.mouse_count;
    mousekey.task();
    try testing.expectEqual(count, driver.mouse_count);
}

test "PressAndRelease_Button2" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    mousekey.on(KC.MS_BTN2);
    mousekey.send();
    try testing.expectEqual(@as(u8, 2), driver.last_mouse.buttons);

    mousekey.off(KC.MS_BTN2);
    mousekey.send();
    try testing.expectEqual(@as(u8, 0), driver.last_mouse.buttons);
}

test "PressAndRelease_Button3" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    mousekey.on(KC.MS_BTN3);
    mousekey.send();
    try testing.expectEqual(@as(u8, 4), driver.last_mouse.buttons);

    mousekey.off(KC.MS_BTN3);
    mousekey.send();
    try testing.expectEqual(@as(u8, 0), driver.last_mouse.buttons);
}

test "PressAndRelease_Button4" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    mousekey.on(KC.MS_BTN4);
    mousekey.send();
    try testing.expectEqual(@as(u8, 8), driver.last_mouse.buttons);

    mousekey.off(KC.MS_BTN4);
    mousekey.send();
    try testing.expectEqual(@as(u8, 0), driver.last_mouse.buttons);
}

test "PressAndRelease_Button5" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    mousekey.on(KC.MS_BTN5);
    mousekey.send();
    try testing.expectEqual(@as(u8, 16), driver.last_mouse.buttons);

    mousekey.off(KC.MS_BTN5);
    mousekey.send();
    try testing.expectEqual(@as(u8, 0), driver.last_mouse.buttons);
}

test "PressAndRelease_Button6" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    mousekey.on(KC.MS_BTN6);
    mousekey.send();
    try testing.expectEqual(@as(u8, 32), driver.last_mouse.buttons);

    mousekey.off(KC.MS_BTN6);
    mousekey.send();
    try testing.expectEqual(@as(u8, 0), driver.last_mouse.buttons);
}

test "PressAndRelease_Button7" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    mousekey.on(KC.MS_BTN7);
    mousekey.send();
    try testing.expectEqual(@as(u8, 64), driver.last_mouse.buttons);

    mousekey.off(KC.MS_BTN7);
    mousekey.send();
    try testing.expectEqual(@as(u8, 0), driver.last_mouse.buttons);
}

test "PressAndRelease_Button8" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    mousekey.on(KC.MS_BTN8);
    mousekey.send();
    try testing.expectEqual(@as(u8, 128), driver.last_mouse.buttons);

    mousekey.off(KC.MS_BTN8);
    mousekey.send();
    try testing.expectEqual(@as(u8, 0), driver.last_mouse.buttons);
}

test "PressAndRelease_CursorUp" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    // C版期待値: x=0, y=-8, h=0, v=0, buttons=0
    mousekey.on(KC.MS_UP);
    mousekey.send();
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.x);
    try testing.expectEqual(@as(i8, -8), driver.last_mouse.y);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.h);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.v);
    try testing.expectEqual(@as(u8, 0), driver.last_mouse.buttons);

    mousekey.off(KC.MS_UP);
    mousekey.send();
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.y);
}

test "PressAndRelease_CursorDown" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    // C版期待値: x=0, y=8, h=0, v=0, buttons=0
    mousekey.on(KC.MS_DOWN);
    mousekey.send();
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.x);
    try testing.expectEqual(@as(i8, 8), driver.last_mouse.y);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.h);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.v);
    try testing.expectEqual(@as(u8, 0), driver.last_mouse.buttons);

    mousekey.off(KC.MS_DOWN);
    mousekey.send();
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.y);
}

test "PressAndRelease_CursorLeft" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    // C版期待値: x=-8, y=0, h=0, v=0, buttons=0
    mousekey.on(KC.MS_LEFT);
    mousekey.send();
    try testing.expectEqual(@as(i8, -8), driver.last_mouse.x);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.y);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.h);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.v);
    try testing.expectEqual(@as(u8, 0), driver.last_mouse.buttons);

    mousekey.off(KC.MS_LEFT);
    mousekey.send();
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.x);
}

test "PressAndRelease_CursorRight" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    // C版期待値: x=8, y=0, h=0, v=0, buttons=0
    mousekey.on(KC.MS_RIGHT);
    mousekey.send();
    try testing.expectEqual(@as(i8, 8), driver.last_mouse.x);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.y);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.h);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.v);
    try testing.expectEqual(@as(u8, 0), driver.last_mouse.buttons);

    mousekey.off(KC.MS_RIGHT);
    mousekey.send();
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.x);
}

test "PressAndRelease_WheelUp" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    // C版期待値: x=0, y=0, h=0, v=1, buttons=0
    mousekey.on(KC.MS_WH_UP);
    mousekey.send();
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.x);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.y);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.h);
    try testing.expectEqual(@as(i8, 1), driver.last_mouse.v);
    try testing.expectEqual(@as(u8, 0), driver.last_mouse.buttons);

    mousekey.off(KC.MS_WH_UP);
    mousekey.send();
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.v);
}

test "PressAndRelease_WheelDown" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    // C版期待値: x=0, y=0, h=0, v=-1, buttons=0
    mousekey.on(KC.MS_WH_DOWN);
    mousekey.send();
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.x);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.y);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.h);
    try testing.expectEqual(@as(i8, -1), driver.last_mouse.v);
    try testing.expectEqual(@as(u8, 0), driver.last_mouse.buttons);

    mousekey.off(KC.MS_WH_DOWN);
    mousekey.send();
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.v);
}

test "PressAndRelease_WheelLeft" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    // C版期待値: x=0, y=0, h=-1, v=0, buttons=0
    mousekey.on(KC.MS_WH_LEFT);
    mousekey.send();
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.x);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.y);
    try testing.expectEqual(@as(i8, -1), driver.last_mouse.h);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.v);
    try testing.expectEqual(@as(u8, 0), driver.last_mouse.buttons);

    mousekey.off(KC.MS_WH_LEFT);
    mousekey.send();
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.h);
}

test "PressAndRelease_WheelRight" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    // C版期待値: x=0, y=0, h=1, v=0, buttons=0
    mousekey.on(KC.MS_WH_RIGHT);
    mousekey.send();
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.x);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.y);
    try testing.expectEqual(@as(i8, 1), driver.last_mouse.h);
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.v);
    try testing.expectEqual(@as(u8, 0), driver.last_mouse.buttons);

    mousekey.off(KC.MS_WH_RIGHT);
    mousekey.send();
    try testing.expectEqual(@as(i8, 0), driver.last_mouse.h);
}

// ============================================================
// 追加テスト: mousekey の加速・タイマー動作
// ============================================================

// delay_ms 経過前は task() がリピートしないことを検証
test "NoRepeatBeforeDelayExpires" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    mousekey.on(KC.MS_RIGHT);
    mousekey.send();

    const count_after_press = driver.mouse_count;
    try testing.expectEqual(@as(i8, 8), driver.last_mouse.x);

    // delay_ms(100ms) 未満の時間経過
    timer.mockAdvance(50);
    mousekey.task();

    // リピートは発生しない（delay 未満のため）
    try testing.expectEqual(count_after_press, driver.mouse_count);

    mousekey.off(KC.MS_RIGHT);
}

// delay_ms 経過後に task() がリピートを開始することを検証
test "RepeatStartsAfterDelay" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    mousekey.on(KC.MS_RIGHT);
    mousekey.send();

    const count_after_press = driver.mouse_count;

    // delay_ms(100ms) 超過
    timer.mockAdvance(101);
    mousekey.task();

    // リピートが発生した（mouse_count が増えた）
    try testing.expect(driver.mouse_count > count_after_press);
    try testing.expect(driver.last_mouse.x > 0);

    mousekey.off(KC.MS_RIGHT);
}

// 加速: ACCEL0 (1/4最大速度) の検証
test "Accel0_QuarterMaxSpeed" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    mousekey.on(KC.MS_ACCEL0);
    mousekey.on(KC.MS_RIGHT);
    mousekey.send();

    // ACCEL0: (8 * 10) / 4 = 20
    try testing.expectEqual(@as(i8, 20), driver.last_mouse.x);

    mousekey.off(KC.MS_ACCEL0);
    mousekey.off(KC.MS_RIGHT);
}

// 加速: ACCEL1 (1/2最大速度) の検証
test "Accel1_HalfMaxSpeed" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    mousekey.on(KC.MS_ACCEL1);
    mousekey.on(KC.MS_RIGHT);
    mousekey.send();

    // ACCEL1: (8 * 10) / 2 = 40
    try testing.expectEqual(@as(i8, 40), driver.last_mouse.x);

    mousekey.off(KC.MS_ACCEL1);
    mousekey.off(KC.MS_RIGHT);
}

// 加速: ACCEL2 (最大速度) の検証
test "Accel2_FullMaxSpeed" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    mousekey.on(KC.MS_ACCEL2);
    mousekey.on(KC.MS_RIGHT);
    mousekey.send();

    // ACCEL2: 8 * 10 = 80
    try testing.expectEqual(@as(i8, 80), driver.last_mouse.x);

    mousekey.off(KC.MS_ACCEL2);
    mousekey.off(KC.MS_RIGHT);
}

// ホイール遅延前はリピートしないことを検証
test "WheelNoRepeatBeforeDelay" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    mousekey.on(KC.MS_WH_UP);
    mousekey.send();

    const count_after_press = driver.mouse_count;
    try testing.expectEqual(@as(i8, 1), driver.last_mouse.v);

    // wheel_delay_ms(100ms) 未満
    timer.mockAdvance(50);
    mousekey.task();

    try testing.expectEqual(count_after_press, driver.mouse_count);

    mousekey.off(KC.MS_WH_UP);
}

// ホイール delay 経過後にリピートが開始することを検証
test "WheelRepeatStartsAfterDelay" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    mousekey.on(KC.MS_WH_UP);
    mousekey.send();

    const count_after_press = driver.mouse_count;

    // wheel_delay_ms(100ms) 超過
    timer.mockAdvance(101);
    mousekey.task();

    try testing.expect(driver.mouse_count > count_after_press);
    try testing.expect(driver.last_mouse.v > 0);

    mousekey.off(KC.MS_WH_UP);
}

// clear() 後は状態がリセットされることを検証
test "ClearResetsState" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    mousekey.on(KC.MS_BTN1);
    mousekey.on(KC.MS_UP);
    mousekey.on(KC.MS_WH_UP);

    mousekey.clear();

    const report = mousekey.getReport();
    try testing.expect(report.isEmpty());
}

// off() 後にリピートカウンタがリセットされることを検証
test "OffResetsRepeatCounter" {
    var driver = TestMouseDriver{};
    setupMouseTest(&driver);
    defer teardownMouseTest();

    mousekey.on(KC.MS_RIGHT);
    mousekey.send();

    timer.mockAdvance(101);
    mousekey.task();

    // キー解放でリピートカウンタがリセットされる
    mousekey.off(KC.MS_RIGHT);
    const report = mousekey.getReport();
    try testing.expectEqual(@as(i8, 0), report.x);
}
