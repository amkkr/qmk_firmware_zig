//! Dynamic Tapping Term テスト - 統合テスト

const std = @import("std");
const testing = std.testing;

const keycode = @import("core").keycode;
const test_fixture = @import("core").test_fixture;
const tapping = @import("core").action_tapping;
const timer = @import("hal").timer;
const KC = keycode.KC;
const TestFixture = test_fixture.TestFixture;
const KeymapKey = test_fixture.KeymapKey;

fn tapKey(fixture: *TestFixture, row: u8, col: u8) void {
    fixture.pressKey(row, col);
    fixture.runOneScanLoop();
    fixture.releaseKey(row, col);
    fixture.runOneScanLoop();
}

test "DT_UP increases tapping_term via pipeline" {
    var fixture: TestFixture = undefined;
    TestFixture.initWithKeymap(&fixture, &[_]KeymapKey{
        .{ .layer = 0, .row = 0, .col = 0, .code = keycode.DT_UP },
    });
    defer fixture.deinit();
    timer.mockReset();
    const initial = tapping.tapping_term;
    tapKey(&fixture, 0, 0);
    try testing.expectEqual(initial + 5, tapping.tapping_term);
}

test "DT_DOWN decreases tapping_term via pipeline" {
    var fixture: TestFixture = undefined;
    TestFixture.initWithKeymap(&fixture, &[_]KeymapKey{
        .{ .layer = 0, .row = 0, .col = 0, .code = keycode.DT_DOWN },
    });
    defer fixture.deinit();
    timer.mockReset();
    const initial = tapping.tapping_term;
    tapKey(&fixture, 0, 0);
    try testing.expectEqual(initial - 5, tapping.tapping_term);
}

test "DT_DOWN saturates at 0 via pipeline" {
    var fixture: TestFixture = undefined;
    TestFixture.initWithKeymap(&fixture, &[_]KeymapKey{
        .{ .layer = 0, .row = 0, .col = 0, .code = keycode.DT_DOWN },
    });
    defer fixture.deinit();
    timer.mockReset();
    tapping.tapping_term = 3;
    tapKey(&fixture, 0, 0);
    try testing.expectEqual(@as(u16, 0), tapping.tapping_term);
}

test "DT_UP is consumed and produces no HID report" {
    var fixture: TestFixture = undefined;
    TestFixture.initWithKeymap(&fixture, &[_]KeymapKey{
        .{ .layer = 0, .row = 0, .col = 0, .code = keycode.DT_UP },
    });
    defer fixture.deinit();
    timer.mockReset();
    const count_before = fixture.driver.keyboard_count;
    tapKey(&fixture, 0, 0);
    try testing.expectEqual(count_before, fixture.driver.keyboard_count);
}

test "DT_DOWN is consumed and produces no HID report" {
    var fixture: TestFixture = undefined;
    TestFixture.initWithKeymap(&fixture, &[_]KeymapKey{
        .{ .layer = 0, .row = 0, .col = 0, .code = keycode.DT_DOWN },
    });
    defer fixture.deinit();
    timer.mockReset();
    const count_before = fixture.driver.keyboard_count;
    tapKey(&fixture, 0, 0);
    try testing.expectEqual(count_before, fixture.driver.keyboard_count);
}

test "DT_PRNT is consumed and produces no HID report" {
    var fixture: TestFixture = undefined;
    TestFixture.initWithKeymap(&fixture, &[_]KeymapKey{
        .{ .layer = 0, .row = 0, .col = 0, .code = keycode.DT_PRNT },
    });
    defer fixture.deinit();
    timer.mockReset();
    const count_before = fixture.driver.keyboard_count;
    tapKey(&fixture, 0, 0);
    try testing.expectEqual(count_before, fixture.driver.keyboard_count);
}

test "cumulative DT_UP via pipeline" {
    var fixture: TestFixture = undefined;
    TestFixture.initWithKeymap(&fixture, &[_]KeymapKey{
        .{ .layer = 0, .row = 0, .col = 0, .code = keycode.DT_UP },
    });
    defer fixture.deinit();
    timer.mockReset();
    const initial = tapping.tapping_term;
    tapKey(&fixture, 0, 0);
    tapKey(&fixture, 0, 0);
    tapKey(&fixture, 0, 0);
    try testing.expectEqual(initial + 15, tapping.tapping_term);
}
