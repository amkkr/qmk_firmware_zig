//! Autocorrect テスト - C版 tests/autocorrect/test_autocorrect.cpp の完全移植
//!
//! C版テストケースを Zig の autocorrect API で論理的に等価に再現する。
//! C版では TestFixture を通してキーボード全体をシミュレーションするが、
//! Zig版では autocorrect.process() を直接呼び、修正時に送信される
//! HID レポートの順序と内容を厳密に検証する。
//!
//! C版テスト対応:
//! 1. OnOffToggle                    — 有効/無効/トグル
//! 2. fales_to_false_autocorrection  — "fales" → "false" 修正レポート順序検証
//! 3. fales_disabled_autocorrect     — 無効時は修正されない
//! 4. falsify_should_not_autocorrect — "falsify" は修正されない
//! 5. ture_to_true_autocorrect       — "ture" → "true" 修正レポート順序検証
//! 6. overture_should_not_autocorrect — "overture" は修正されない

const std = @import("std");
const testing = std.testing;

const autocorrect = @import("../core/autocorrect.zig");
const host = @import("../core/host.zig");
const keycode_mod = @import("../core/keycode.zig");
const keymap_mod = @import("../core/keymap.zig");
const report_mod = @import("../core/report.zig");

const KC = keycode_mod.KC;
const Keycode = keycode_mod.Keycode;
const KeyboardReport = report_mod.KeyboardReport;
const FixedTestDriver = @import("../core/test_driver.zig").FixedTestDriver;
const TestDriver = FixedTestDriver(128, 16);

fn setupTest() *TestDriver {
    const S = struct {
        var driver: TestDriver = .{};
    };
    S.driver = .{};
    host.hostReset();
    host.setDriver(host.HostDriver.from(&S.driver));
    keymap_mod.keymap_config = .{};
    autocorrect.reset();
    autocorrect.enable();
    return &S.driver;
}

fn teardownTest() void {
    host.clearDriver();
}

/// テスト用: キーをタップ（press + release 相当の process 呼び出し）
fn tapKey(kc: Keycode) bool {
    const press_result = autocorrect.process(kc, true, 1);
    _ = autocorrect.process(kc, false, 1);
    return press_result;
}

// ============================================================
// C版 OnOffToggle の移植
// ============================================================

test "OnOffToggle" {
    _ = setupTest();
    defer teardownTest();

    try testing.expect(autocorrect.isEnabled());

    autocorrect.disable();
    try testing.expect(!autocorrect.isEnabled());
    autocorrect.disable();
    try testing.expect(!autocorrect.isEnabled());

    autocorrect.enable();
    try testing.expect(autocorrect.isEnabled());
    autocorrect.enable();
    try testing.expect(autocorrect.isEnabled());

    autocorrect.toggle();
    try testing.expect(!autocorrect.isEnabled());
    autocorrect.toggle();
    try testing.expect(autocorrect.isEnabled());
}

// ============================================================
// C版 fales_to_false_autocorrection の移植
// "fales" とタイプすると autocorrect が Backspace + "se" を送信する
// ============================================================

test "fales_to_false_autocorrection" {
    const driver = setupTest();
    defer teardownTest();

    // F, A, L, E は修正を発動しない（通常処理続行）
    try testing.expect(tapKey(KC.F));
    try testing.expect(tapKey(KC.A));
    try testing.expect(tapKey(KC.L));
    try testing.expect(tapKey(KC.E));

    // autocorrect はこの時点ではレポートを送信しない
    try testing.expectEqual(@as(usize, 0), driver.keyboard_count);

    // S をタイプすると "fales" パターンにマッチし修正が発動
    // process() は false を返す（キー消費）
    const result = tapKey(KC.S);
    try testing.expect(!result);

    // 修正レポートの検証:
    // C版期待値（空レポートを除いた非空レポートの順序）:
    //   KC_BACKSPACE  -- "e" を削除
    //   KC_S          -- 's' を送信
    //   KC_E          -- 'e' を送信
    //
    // autocorrect の applyCorrection は tapCode() で register+send+unregister+send するため
    // 各キーについて2つのレポート（キー付き + 空）が生成される
    try testing.expect(driver.keyboard_count >= 6);

    // Backspace (register + send)
    try testing.expect(driver.keyboard_reports[0].hasKey(KC.BACKSPACE));
    // Backspace (unregister + send) → 空レポート
    try testing.expect(driver.keyboard_reports[1].isEmpty());
    // 's' (register + send)
    try testing.expect(driver.keyboard_reports[2].hasKey(KC.S));
    // 's' (unregister + send) → 空レポート
    try testing.expect(driver.keyboard_reports[3].isEmpty());
    // 'e' (register + send)
    try testing.expect(driver.keyboard_reports[4].hasKey(KC.E));
    // 'e' (unregister + send) → 空レポート
    try testing.expect(driver.keyboard_reports[5].isEmpty());
}

// ============================================================
// C版 fales_disabled_autocorrect の移植
// 無効時は "fales" をタイプしても修正されない
// ============================================================

test "fales_disabled_autocorrect" {
    const driver = setupTest();
    defer teardownTest();

    autocorrect.disable();

    // 全てのキーが通常処理続行（true を返す）
    try testing.expect(tapKey(KC.F));
    try testing.expect(tapKey(KC.A));
    try testing.expect(tapKey(KC.L));
    try testing.expect(tapKey(KC.E));
    try testing.expect(tapKey(KC.S));

    // 修正レポートは送信されない
    try testing.expectEqual(@as(usize, 0), driver.keyboard_count);

    autocorrect.enable();
}

// ============================================================
// C版 falsify_should_not_autocorrect の移植
// "falsify" は辞書に含まれるが "fals" の後に "ify" が続くため修正されない
// ============================================================

test "falsify_should_not_autocorrect" {
    const driver = setupTest();
    defer teardownTest();

    try testing.expect(tapKey(KC.F));
    try testing.expect(tapKey(KC.A));
    try testing.expect(tapKey(KC.L));
    try testing.expect(tapKey(KC.S));
    try testing.expect(tapKey(KC.I));
    try testing.expect(tapKey(KC.F));
    try testing.expect(tapKey(KC.Y));

    // 修正レポートは送信されない
    try testing.expectEqual(@as(usize, 0), driver.keyboard_count);
}

// ============================================================
// C版 ture_to_true_autocorrect の移植
// スペース（バッファ初期値）+ "ture" とタイプすると
// autocorrect が Backspace x 2 + "rue" を送信する
// ============================================================

test "ture_to_true_autocorrect" {
    const driver = setupTest();
    defer teardownTest();

    // バッファ初期状態で SPC が入っている（ワード境界として機能）
    // T, U, R はまだ修正しない
    try testing.expect(tapKey(KC.T));
    try testing.expect(tapKey(KC.U));
    try testing.expect(tapKey(KC.R));
    try testing.expectEqual(@as(usize, 0), driver.keyboard_count);

    // E で "ture" パターンにマッチし修正が発動
    // C版期待値: BACKSPACE x 2 + "rue"
    // process() は false を返す（キー消費）
    const result = tapKey(KC.E);
    try testing.expect(!result);

    // 修正レポートの検証:
    // Backspace x 2 → 'r' → 'u' → 'e' の各 tapCode で register+send+unregister+send
    try testing.expect(driver.keyboard_count >= 10);

    // 1st Backspace
    try testing.expect(driver.keyboard_reports[0].hasKey(KC.BACKSPACE));
    try testing.expect(driver.keyboard_reports[1].isEmpty());
    // 2nd Backspace
    try testing.expect(driver.keyboard_reports[2].hasKey(KC.BACKSPACE));
    try testing.expect(driver.keyboard_reports[3].isEmpty());
    // 'r'
    try testing.expect(driver.keyboard_reports[4].hasKey(KC.R));
    try testing.expect(driver.keyboard_reports[5].isEmpty());
    // 'u'
    try testing.expect(driver.keyboard_reports[6].hasKey(KC.U));
    try testing.expect(driver.keyboard_reports[7].isEmpty());
    // 'e'
    try testing.expect(driver.keyboard_reports[8].hasKey(KC.E));
    try testing.expect(driver.keyboard_reports[9].isEmpty());
}

// ============================================================
// C版 overture_should_not_autocorrect の移植
// "overture" は "ture" を含むがワード境界がないため修正されない
// ============================================================

test "overture_should_not_autocorrect" {
    const driver = setupTest();
    defer teardownTest();

    try testing.expect(tapKey(KC.O));
    try testing.expect(tapKey(KC.V));
    try testing.expect(tapKey(KC.E));
    try testing.expect(tapKey(KC.R));
    try testing.expect(tapKey(KC.T));
    try testing.expect(tapKey(KC.U));
    try testing.expect(tapKey(KC.R));
    try testing.expect(tapKey(KC.E));

    // 修正レポートは送信されない
    try testing.expectEqual(@as(usize, 0), driver.keyboard_count);
}
