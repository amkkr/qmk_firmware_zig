// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zig port of quantum/process_keycode/process_repeat_key.c
// Original: Copyright 2022-2023 Google LLC (Apache-2.0)

//! Repeat Key 機能
//! C版 quantum/repeat_key.c に相当
//!
//! Repeat Key は直前に押したキーを再送信するキー。
//! 直前のキーコード（Keycode, u16）を記録し、Repeat Key 押下時に
//! register/unregister を実行する。
//! Modified keycode（S(KC_x) 等）にも対応し、キーコードに含まれる
//! モッド情報を weak mods として再適用する。

const host = @import("host.zig");
const keycode = @import("keycode.zig");
// NOTE: circular import with auto_shift.zig
// repeat_key → auto_shift: isEnabled / isAutoShiftable / AUTO_SHIFT_TIMEOUT を参照
// auto_shift → repeat_key: finishAutoShift 内で setLastKeycode を呼び出す
// Zig はファイル単位の循環参照を許容するため、この構造は意図的なものである。
const auto_shift = @import("auto_shift.zig");
const report_mod = @import("report.zig");
const Keycode = keycode.Keycode;
const KC = keycode.KC;

/// 直前に押されたキーコード（Keycode, u16）
/// Basic keycode (0x00-0xFF) または Modified keycode (S(KC_x) 等, 0x0100-0x1FFF) を保持
var last_keycode: Keycode = 0;
/// 直前のキー押下時に適用されていた修飾キー（8bit HID format）
/// Modified keycode 内のモッドとは別に、物理的に押されている修飾キー等を記録
var last_mods: u8 = 0;

/// 直前のキーコードを記録する
/// action.zig の processModsAction 等から呼び出される
///
/// kc: Basic keycode または Modified keycode (S(KC_x) 等)
/// mods: キー押下時のアクティブな修飾キー（8bit HID format）
///       Modified keycode 内のモッドは含めない（keycode 自体に埋め込まれているため）
pub fn setLastKeycode(kc: Keycode, mods: u8) void {
    // 修飾キー自体は記録しない（basic keycode 範囲の修飾キー: 0xE0-0xE7）
    if (kc >= KC.LEFT_CTRL and kc <= KC.RIGHT_GUI) return;
    // KC_NO は記録しない
    if (kc == 0) return;
    last_keycode = kc;
    last_mods = mods;
}

/// 記録されている直前のキーコードを取得
/// Basic keycode または Modified keycode (S(KC_x) 等) を返す
pub fn getLastKeycode() Keycode {
    return last_keycode;
}

/// 記録されている直前の修飾キーを取得
pub fn getLastMods() u8 {
    return last_mods;
}

/// Keycode から basic keycode を抽出する
/// Modified keycode の場合は下位8bitを返し、basic keycode はそのまま返す
fn extractBasicKeycode(kc: Keycode) u8 {
    if (keycode.isMods(kc)) {
        return keycode.modsGetBasicKeycode(kc);
    }
    return @truncate(kc);
}

/// Keycode に含まれるモッドを 8bit HID format で抽出する
/// Modified keycode の場合は 5-bit mod encoding → 8bit HID に変換して返す
/// Basic keycode の場合は 0 を返す
fn extractModsFromKeycode(kc: Keycode) u8 {
    if (keycode.isMods(kc)) {
        return host.modFiveBitToEightBit(keycode.modsGetMods(kc));
    }
    return 0;
}

/// press 時に登録したキーコード・修飾キーを保持する（C版 registered_record 相当）
/// ローリングプレスで last_keycode が変わってもキースタックを防ぐ
var registered_keycode: u8 = 0;
var registered_mods: u8 = 0;
/// OSM 連携: press 時に追加した oneshot_mods を保持（release 時のクリーンアップ用）
var registered_osm: u8 = 0;

/// Auto Shift 連携用: Repeat Key の press 時刻を保持
var repeat_press_time: u16 = 0;

/// Repeat Key が押されたときの処理
/// 直前に記録されたキーコードを送信する
/// Modified keycode の場合、キーコード内のモッドも weak mods として適用する
///
/// OSM 連携: press 時に oneshot_mods も weak mods に追加する（C版互換）。
///   oneshot_mods は sendKeyboardReport 時にレポートに含まれた後クリアされるため、
///   Repeat Key 2回目以降では自動的に適用されない（ワンショット動作を維持）。
///
/// Auto Shift 連携: 繰り返すキーが Auto Shift 対象の場合、
///   press で保留し release 時に保持時間で Shift 適用を判定する（C版互換）。
pub fn processRepeatKey(pressed: bool, time: u16) void {
    if (last_keycode == 0) return;

    // Auto Shift 有効かつ繰り返すキーが Auto Shift 対象の場合は専用処理
    if (auto_shift.isEnabled() and auto_shift.isAutoShiftable(@as(u16, extractBasicKeycode(last_keycode)))) {
        processRepeatKeyAutoShift(pressed, time);
        return;
    }

    if (pressed) {
        // press 時のキーコード・修飾キーを保存（release 時に使用）
        registered_keycode = extractBasicKeycode(last_keycode);
        // last_mods（物理キー由来）+ keycode 内のモッド（Modified keycode 由来）を統合
        registered_mods = last_mods | extractModsFromKeycode(last_keycode);
        // 直前のキーの修飾キーを一時的に適用
        if (registered_mods != 0) {
            host.addWeakMods(registered_mods);
        }
        // OSM 連携: oneshot_mods も weak mods に追加して保持
        // release 時にクリーンアップするため registered_osm に保存
        registered_osm = host.getOneshotMods();
        if (registered_osm != 0) {
            host.addWeakMods(registered_osm);
        }
        host.registerCode(registered_keycode);
        host.sendKeyboardReport();
    } else {
        host.unregisterCode(registered_keycode);
        if (registered_mods != 0) {
            host.delWeakMods(registered_mods);
        }
        if (registered_osm != 0) {
            host.delWeakMods(registered_osm);
            registered_osm = 0;
        }
        host.sendKeyboardReport();
    }
}

/// Auto Shift 連携時の Repeat Key 処理
/// C版の repeat_key_invoke → process_record → process_auto_shift の流れを再現する。
/// press 時にタイムスタンプを記録して保留し、release 時に保持時間で Shift を判定する。
/// NOTE: OSM mods は Auto Shift パスでは適用されない（C版も同様に未対応）。
/// Auto Shift の press では sendKeyboardReport が呼ばれないため OSM が消費されず、
/// OSM + Auto Shift Repeat の組み合わせは想定外の動作になる。
fn processRepeatKeyAutoShift(pressed: bool, time: u16) void {
    if (pressed) {
        registered_keycode = extractBasicKeycode(last_keycode);
        registered_mods = last_mods | extractModsFromKeycode(last_keycode);
        repeat_press_time = time;
        // Auto Shift: press 時は送信を保留する（release 時に判定）
    } else {
        // release: 保持時間を判定して Shift を適用
        const elapsed = time -% repeat_press_time;
        const shifted = elapsed >= auto_shift.AUTO_SHIFT_TIMEOUT;

        if (shifted) {
            host.addWeakMods(report_mod.ModBit.LSHIFT);
        }
        if (registered_mods != 0) {
            host.addWeakMods(registered_mods);
        }

        host.registerCode(registered_keycode);
        host.sendKeyboardReport();

        host.unregisterCode(registered_keycode);
        if (shifted) {
            host.delWeakMods(report_mod.ModBit.LSHIFT);
        }
        if (registered_mods != 0) {
            host.delWeakMods(registered_mods);
        }
        host.sendKeyboardReport();
    }
}

// ============================================================
// Alt Repeat Key
// ============================================================

/// press 時に登録した alt キーコード・修飾キーを保持する
var alt_registered_keycode: u8 = 0;
var alt_registered_mods: u8 = 0;

/// デフォルトの代替キーコードマッピング
/// C版 get_alt_repeat_key_keycode() のデフォルト実装に相当。
/// ナビゲーションキーの方向を反転する。
/// basic keycode 部分で判定するため、Modified keycode にも対応。
fn getAltKeycode(kc: Keycode) Keycode {
    const basic_kc = extractBasicKeycode(kc);
    return switch (basic_kc) {
        KC.LEFT => KC.RIGHT,
        KC.RIGHT => KC.LEFT,
        KC.UP => KC.DOWN,
        KC.DOWN => KC.UP,
        KC.HOME => KC.END,
        KC.END => KC.HOME,
        KC.PAGE_UP => KC.PAGE_DOWN,
        KC.PAGE_DOWN => KC.PAGE_UP,
        else => 0, // マッピングなし
    };
}

/// Alt Repeat Key が押されたときの処理
/// 直前に記録されたキーコードの代替キーを送信する
pub fn processAltRepeatKey(pressed: bool) void {
    if (last_keycode == 0) return;

    if (pressed) {
        const alt_kc = getAltKeycode(last_keycode);
        if (alt_kc == 0) {
            // マッピングなし: stale 値をクリアして早期リターン
            alt_registered_keycode = 0;
            alt_registered_mods = 0;
            return;
        }
        alt_registered_keycode = extractBasicKeycode(alt_kc);
        // 代替キーには元のキーと同じ修飾キーを適用
        // last_mods + keycode 内のモッドを統合
        alt_registered_mods = last_mods | extractModsFromKeycode(last_keycode);
        if (alt_registered_mods != 0) {
            host.addWeakMods(alt_registered_mods);
        }
        host.registerCode(alt_registered_keycode);
        host.sendKeyboardReport();
    } else {
        if (alt_registered_keycode == 0) return;
        host.unregisterCode(alt_registered_keycode);
        if (alt_registered_mods != 0) {
            host.delWeakMods(alt_registered_mods);
        }
        host.sendKeyboardReport();
    }
}

/// 状態のリセット
pub fn reset() void {
    last_keycode = 0;
    last_mods = 0;
    registered_keycode = 0;
    registered_mods = 0;
    registered_osm = 0;
    repeat_press_time = 0;
    alt_registered_keycode = 0;
    alt_registered_mods = 0;
}

// ============================================================
// Tests
// ============================================================

const testing = @import("std").testing;
const FixedTestDriver = @import("test_driver.zig").FixedTestDriver(32, 4);

test "repeat key: initial state" {
    reset();
    try testing.expectEqual(@as(Keycode, 0), getLastKeycode());
    try testing.expectEqual(@as(u8, 0), getLastMods());
}

test "repeat key: setLastKeycode records basic key" {
    reset();

    setLastKeycode(KC.A, 0);
    try testing.expectEqual(KC.A, getLastKeycode());
    try testing.expectEqual(@as(u8, 0), getLastMods());
}

test "repeat key: setLastKeycode records mods" {
    reset();

    setLastKeycode(KC.A, 0x02); // LSHIFT
    try testing.expectEqual(KC.A, getLastKeycode());
    try testing.expectEqual(@as(u8, 0x02), getLastMods());
}

test "repeat key: setLastKeycode records shifted keycode" {
    reset();

    // S(KC_1) = LSFT(KC.@"1") = 0x021E
    const shifted_1 = keycode.S(KC.@"1");
    setLastKeycode(shifted_1, 0);
    try testing.expectEqual(shifted_1, getLastKeycode());
    try testing.expectEqual(@as(u8, 0), getLastMods());
}

test "repeat key: modifier keys are not recorded" {
    reset();

    setLastKeycode(KC.A, 0);
    setLastKeycode(KC.LEFT_SHIFT, 0); // LSHIFT keycode (0xE1)
    try testing.expectEqual(KC.A, getLastKeycode()); // 変わらない
}

test "repeat key: KC_NO is not recorded" {
    reset();

    setLastKeycode(KC.A, 0);
    setLastKeycode(0, 0);
    try testing.expectEqual(KC.A, getLastKeycode()); // 変わらない
}

test "repeat key: processRepeatKey sends last key" {
    reset();
    auto_shift.reset();
    host.hostReset();
    var mock = FixedTestDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    setLastKeycode(KC.A, 0);

    // Repeat Key を押す
    processRepeatKey(true, 0);
    try testing.expect(mock.lastKeyboardReport().hasKey(KC.A));

    // Repeat Key を離す
    processRepeatKey(false, 0);
    try testing.expect(!mock.lastKeyboardReport().hasKey(KC.A));
}

test "repeat key: processRepeatKey with mods" {
    reset();
    auto_shift.reset();
    host.hostReset();
    var mock = FixedTestDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    setLastKeycode(KC.A, 0x02); // LSHIFT

    processRepeatKey(true, 0);
    try testing.expect(mock.lastKeyboardReport().hasKey(KC.A));
    try testing.expectEqual(@as(u8, 0x02), mock.lastKeyboardReport().mods);

    processRepeatKey(false, 0);
    try testing.expect(!mock.lastKeyboardReport().hasKey(KC.A));
}

test "repeat key: processRepeatKey with shifted keycode" {
    reset();
    auto_shift.reset();
    host.hostReset();
    var mock = FixedTestDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // S(KC_1) を記録（Modified keycode: LSFT + KC_1）
    setLastKeycode(keycode.S(KC.@"1"), 0);

    // Repeat Key を押す → Shift+1 (= !) が送信される
    processRepeatKey(true, 0);
    try testing.expect(mock.lastKeyboardReport().hasKey(KC.@"1"));
    try testing.expect(mock.lastKeyboardReport().mods & report_mod.ModBit.LSHIFT != 0);

    // Repeat Key を離す
    processRepeatKey(false, 0);
    try testing.expect(!mock.lastKeyboardReport().hasKey(KC.@"1"));
}

test "repeat key: processRepeatKey with shifted keycode and additional mods" {
    reset();
    auto_shift.reset();
    host.hostReset();
    var mock = FixedTestDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // S(KC_1) を RALT 押下中に記録
    setLastKeycode(keycode.S(KC.@"1"), report_mod.ModBit.RALT);

    // Repeat Key を押す → RALT+Shift+1 が送信される
    processRepeatKey(true, 0);
    try testing.expect(mock.lastKeyboardReport().hasKey(KC.@"1"));
    try testing.expect(mock.lastKeyboardReport().mods & report_mod.ModBit.LSHIFT != 0);
    try testing.expect(mock.lastKeyboardReport().mods & report_mod.ModBit.RALT != 0);

    processRepeatKey(false, 0);
    try testing.expect(!mock.lastKeyboardReport().hasKey(KC.@"1"));
}

test "repeat key: no-op when no key recorded" {
    reset();
    auto_shift.reset();
    host.hostReset();
    var mock = FixedTestDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // 何も記録されていない状態で Repeat Key を押しても何も起こらない
    processRepeatKey(true, 0);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);
}

test "repeat key: reset clears state" {
    setLastKeycode(KC.B, 0x04);
    try testing.expectEqual(KC.B, getLastKeycode());

    reset();
    try testing.expectEqual(@as(Keycode, 0), getLastKeycode());
    try testing.expectEqual(@as(u8, 0), getLastMods());
}

// ============================================================
// Alt Repeat Key Tests
// ============================================================

test "alt repeat key: navigation key reversal" {
    reset();
    host.hostReset();
    var mock = FixedTestDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // LEFT → RIGHT
    setLastKeycode(KC.LEFT, 0);
    processAltRepeatKey(true);
    try testing.expect(mock.lastKeyboardReport().hasKey(KC.RIGHT));
    processAltRepeatKey(false);
    try testing.expect(!mock.lastKeyboardReport().hasKey(KC.RIGHT));
}

test "alt repeat key: UP reverses to DOWN" {
    reset();
    host.hostReset();
    var mock = FixedTestDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    setLastKeycode(KC.UP, 0);
    processAltRepeatKey(true);
    try testing.expect(mock.lastKeyboardReport().hasKey(KC.DOWN));
    processAltRepeatKey(false);
    try testing.expect(!mock.lastKeyboardReport().hasKey(KC.DOWN));
}

test "alt repeat key: HOME reverses to END" {
    reset();
    host.hostReset();
    var mock = FixedTestDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    setLastKeycode(KC.HOME, 0);
    processAltRepeatKey(true);
    try testing.expect(mock.lastKeyboardReport().hasKey(KC.END));
    processAltRepeatKey(false);
    try testing.expect(!mock.lastKeyboardReport().hasKey(KC.END));
}

test "alt repeat key: PGUP reverses to PGDN" {
    reset();
    host.hostReset();
    var mock = FixedTestDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    setLastKeycode(KC.PAGE_UP, 0);
    processAltRepeatKey(true);
    try testing.expect(mock.lastKeyboardReport().hasKey(KC.PAGE_DOWN));
    processAltRepeatKey(false);
    try testing.expect(!mock.lastKeyboardReport().hasKey(KC.PAGE_DOWN));
}

test "alt repeat key: no mapping for regular key" {
    reset();
    host.hostReset();
    var mock = FixedTestDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    setLastKeycode(KC.A, 0);
    processAltRepeatKey(true);
    // マッピングがないため何も送信されない
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);
}

test "alt repeat key: preserves mods" {
    reset();
    host.hostReset();
    var mock = FixedTestDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    setLastKeycode(KC.LEFT, 0x02); // LSHIFT + LEFT
    processAltRepeatKey(true);
    try testing.expect(mock.lastKeyboardReport().hasKey(KC.RIGHT));
    try testing.expectEqual(@as(u8, 0x02), mock.lastKeyboardReport().mods);
    processAltRepeatKey(false);
    try testing.expect(!mock.lastKeyboardReport().hasKey(KC.RIGHT));
}

test "alt repeat key: no-op when no key recorded" {
    reset();
    host.hostReset();
    var mock = FixedTestDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    processAltRepeatKey(true);
    try testing.expectEqual(@as(usize, 0), mock.keyboard_count);
}

test "alt repeat key: no stale unregister after mapping miss" {
    // 再現シナリオ: マッピングあり → マッピングなし → release で stale unregister が起きないこと
    reset();
    host.hostReset();
    var mock = FixedTestDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // 1. LEFT → RIGHT を送信（成功）
    setLastKeycode(KC.LEFT, 0x02);
    processAltRepeatKey(true);
    try testing.expect(mock.lastKeyboardReport().hasKey(KC.RIGHT));
    processAltRepeatKey(false);
    try testing.expect(!mock.lastKeyboardReport().hasKey(KC.RIGHT));

    const count_after_first = mock.keyboard_count;

    // 2. KC.A はマッピングなし → press は no-op
    setLastKeycode(KC.A, 0);
    processAltRepeatKey(true);
    try testing.expectEqual(count_after_first, mock.keyboard_count); // 送信なし

    // 3. release でも stale な unregisterCode が呼ばれないこと
    processAltRepeatKey(false);
    try testing.expectEqual(count_after_first, mock.keyboard_count); // 送信なし
}
