// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! C ABI export stubs for QMK compatibility
//! Provides `export fn` wrappers around Zig core modules,
//! allowing C code to call into the Zig implementation.
//!
//! All exported functions use C-compatible types (u8, u16, u32, pointers).
//! Function names follow QMK C naming conventions (snake_case).

const std = @import("std");
const layer_mod = @import("core").layer;
const host_mod = @import("core").host_mod;
const action_mod = @import("core").action_mod;
const keyboard_mod = @import("core").keyboard;
const event_mod = @import("core").event;
const keymap_mod = @import("core").keymap;
const report_mod = @import("core").report;
const timer = @import("hal").timer;

// ============================================================
// Keyboard lifecycle
// ============================================================

/// Initialize keyboard hardware and subsystems
export fn keyboard_init() void {
    keyboard_mod.init();
}

/// Run one iteration of the keyboard processing loop
export fn keyboard_task() void {
    keyboard_mod.task();
}

// ============================================================
// Action execution
// ============================================================

/// Execute action for a key event (C ABI wrapper)
/// C版の action_exec(keyevent_t) に相当するが、シグネチャは意図的に異なる。
/// C版は keyevent_t 構造体を値渡しするが、Zig版は C++ テストとの直接リンクを
/// 目的とせず、FFI 経由の呼び出しやテストアダプタ経由での使用を想定している。
///
/// Issue #418 で「`keymap_key_to_keycode` (KeyPos 値渡し) と signature が
/// 不統一」と再検討されたが、 Won't Do として確定:
/// - C 側からの caller 0 件 (`quantum/` および `tmk_core/` 配下 grep で確認済み)
/// - upstream へ push しない一方向同期 (CLAUDE.md 明記)
/// - upstream 完全準拠 (`KeyEvent` 値渡し) 化は YAGNI、 KeyPos 統一は
///   `event_type` (TICK/ENCODER/DIP_SWITCH 等) を渡せず将来 encoder ABI で
///   破綻するため致命的欠点あり
/// 「異なる責務 (lookup vs state transition、 production lookup vs FFI/テスト
/// アダプタ) で signature が異なる」 のは合理的設計として確定。 詳細は
/// `keymap_key_to_keycode` docstring の 「ABI 内 signature 不統一の確定」 節
/// および Issue #418 を参照。
export fn action_exec(row: u8, col: u8, pressed: bool, time: u16) void {
    const ev = if (pressed)
        event_mod.KeyEvent.keyPress(row, col, time)
    else
        event_mod.KeyEvent.keyRelease(row, col, time);
    var record = event_mod.KeyRecord{ .event = ev };
    action_mod.actionExec(&record);
}

// ============================================================
// Record processing
// ============================================================

/// Process a key record through action resolution and execution
/// C版の process_record(keyrecord_t*) に相当するが、シグネチャは意図的に異なる。
/// action_exec と同様、FFI 経由の呼び出しやテストアダプタ経由での使用を想定。
///
/// Issue #418 で signature 統一を再検討した結果、 Won't Do として確定。
/// 詳細は `action_exec` docstring および `keymap_key_to_keycode` docstring の
/// 「ABI 内 signature 不統一の確定」 節を参照。
export fn process_record(row: u8, col: u8, pressed: bool, time: u16) void {
    const ev = if (pressed)
        event_mod.KeyEvent.keyPress(row, col, time)
    else
        event_mod.KeyEvent.keyRelease(row, col, time);
    var record = event_mod.KeyRecord{ .event = ev };
    action_mod.processRecord(&record);
}

// ============================================================
// Layer management
// ============================================================

/// Turn on a specific layer
export fn layer_on(layer: u8) void {
    if (layer >= layer_mod.MAX_LAYERS) return;
    layer_mod.layerOn(@intCast(layer));
}

/// Turn off a specific layer
export fn layer_off(layer: u8) void {
    if (layer >= layer_mod.MAX_LAYERS) return;
    layer_mod.layerOff(@intCast(layer));
}

/// Clear all layers
export fn layer_clear() void {
    layer_mod.layerClear();
}

/// Set the layer state directly
export fn layer_state_set(state: u32) void {
    layer_mod.layerStateSet(state);
}

/// Check if a layer is active
export fn layer_state_is(layer: u8) bool {
    if (layer >= layer_mod.MAX_LAYERS) return false;
    return layer_mod.layerStateIs(@intCast(layer));
}

/// Move to a specific layer (exclusive)
export fn layer_move(layer: u8) void {
    if (layer >= layer_mod.MAX_LAYERS) return;
    layer_mod.layerMove(@intCast(layer));
}

// ============================================================
// Key registration
// ============================================================

/// Register a keycode (add to HID report)
/// C版の register_code(uint8_t) に相当
export fn register_code(kc: u8) void {
    host_mod.registerCode(kc);
}

/// Unregister a keycode (remove from HID report)
/// C版の unregister_code(uint8_t) に相当
export fn unregister_code(kc: u8) void {
    host_mod.unregisterCode(kc);
}

// ============================================================
// Host / Report
// ============================================================

/// Clear all keyboard state and send empty report
export fn clear_keyboard() void {
    host_mod.clearKeyboard();
}

/// Send the current keyboard report
export fn send_keyboard_report() void {
    host_mod.sendKeyboardReport();
}

// ============================================================
// Host driver management
// ============================================================

/// C ABI 互換のホストドライバ関数ポインタテーブル
/// C版の host_driver_t に相当（tmk_core/protocol/host_driver.h）
///
/// フィールド順は C版と完全一致:
///   keyboard_leds, send_keyboard, send_nkro, send_mouse, send_extra
///
pub const CHostDriver = extern struct {
    keyboard_leds: ?*const fn () callconv(.c) u8,
    send_keyboard: ?*const fn (*const report_mod.KeyboardReport) callconv(.c) void,
    send_nkro: ?*const fn (*const report_mod.NkroReport) callconv(.c) void,
    send_mouse: ?*const fn (*const report_mod.MouseReport) callconv(.c) void,
    send_extra: ?*const fn (*const report_mod.ExtraReport) callconv(.c) void,
};

/// C ABI ドライバアダプタ
/// CHostDriver の関数ポインタを HostDriver インターフェースに変換する
const CDriverAdapter = struct {
    c_driver: *const CHostDriver,

    pub fn keyboardLeds(self: *CDriverAdapter) u8 {
        if (self.c_driver.keyboard_leds) |f| return f();
        return 0;
    }

    pub fn sendKeyboard(self: *CDriverAdapter, r: report_mod.KeyboardReport) void {
        if (self.c_driver.send_keyboard) |f| f(&r);
    }

    pub fn sendNkro(self: *CDriverAdapter, r: report_mod.NkroReport) void {
        if (self.c_driver.send_nkro) |f| f(&r);
    }

    pub fn sendMouse(self: *CDriverAdapter, r: report_mod.MouseReport) void {
        if (self.c_driver.send_mouse) |f| f(&r);
    }

    pub fn sendExtra(self: *CDriverAdapter, r: report_mod.ExtraReport) void {
        if (self.c_driver.send_extra) |f| f(&r);
    }
};

var c_driver_adapter: CDriverAdapter = .{ .c_driver = &empty_c_driver };
const empty_c_driver = CHostDriver{
    .keyboard_leds = null,
    .send_keyboard = null,
    .send_nkro = null,
    .send_mouse = null,
    .send_extra = null,
};

/// Set host driver (C ABI wrapper)
/// C版の host_set_driver(host_driver_t*) に相当
///
/// 注意: driver ポインタは内部に保持され、ドライバが使用される間（次の
/// host_set_driver(null) 呼び出しまで）有効であり続ける必要がある。
/// C版 host_set_driver と同様のライフタイム制約。
export fn host_set_driver(driver: ?*const CHostDriver) void {
    if (driver) |d| {
        c_driver_adapter = .{ .c_driver = d };
        host_mod.setDriver(host_mod.HostDriver.from(&c_driver_adapter));
    } else {
        c_driver_adapter = .{ .c_driver = &empty_c_driver };
        host_mod.clearDriver();
    }
}

/// Get host driver (C ABI wrapper)
/// 現在ドライバが設定されているかどうかを返す（簡易版）
export fn host_get_driver() ?*const CHostDriver {
    if (host_mod.getDriver() != null) {
        return c_driver_adapter.c_driver;
    }
    return null;
}

// ============================================================
// Timer
// ============================================================

/// Read current time in milliseconds (16-bit)
export fn timer_read() u16 {
    return timer.read();
}

/// Read current time in milliseconds (32-bit)
export fn timer_read32() u32 {
    return timer.read32();
}

/// Clear (reset) the timer
/// Note: テスト環境では `timer.init()` が `mock_timer_ms = 0` にリセットするため
/// 期待通り動作する。freestanding（実機）では `timer.init()` は no-op のため、
/// RP2040 のハードウェアタイマーはリセットされず、QMK C の `timer_clear()` の
/// セマンティクス（タイマーカウンタのリセット）と一致しない。
/// Phase 1 ではテスト専用なので動作上の問題はない。
export fn timer_clear() void {
    timer.init();
}

/// Set mock timer to specific value (test only)
export fn set_time(ms: u32) void {
    timer.mockSet(ms);
}

/// Advance mock timer (test only)
export fn advance_time(ms: u32) void {
    timer.mockAdvance(ms);
}

// ============================================================
// Keymap
// ============================================================

/// Get keycode at given layer and position (C ABI export)
/// 依存性注入された keymap lookup (`keyboard.keymapLookup`) 経由で参照する。
/// production binary では `productionKeymapLookup` 経由で `kb_mod.default_keymap`
/// (flash 上の静的 const) を引き、 test binary では `test_fixture.fixture_test_keymap`
/// もしくは `keyboard.kb_test_keymap` (BSS、 後者は keyboard.zig 内テスト経路) を引く
/// ため、 ABI からそれぞれの実体を直接触ることはない (DRY 統一)。
///
/// ## Signature: `(layer: u8, key_pos: KeyPos) u16` (Issue #406)
///
/// 元 issue #399 で提案された型安全な signature を採用 (Issue #406)。
/// 内部 `KeymapLookupFn` は `(layer, row, col)` のままだが、 ABI export だけは
/// `KeyPos` 構造体を受け取る形に変更。
/// 利点:
/// - 型安全 (KeyPos 構造体で row/col をまとめて引数順序ミスを防止)
/// - 将来の拡張性 (KeyPos に追加情報を持たせる余地)
/// - upstream C 版 QMK の `keymap_key_to_keycode(uint8_t layer, keypos_t key)`
///   と完全一致 (値渡し)
/// - Cortex-M0+ AAPCS では 2 byte packed struct は r0 レジスタ 1 本に収まり、
///   ポインタ渡しより効率的
/// - アラインメント問題は packed struct (`@sizeOf == 2`) の設計上発生しない
///
/// 内部 lookup signature を維持する理由は `core/keyboard.zig` の
/// `KeymapLookupFn` docstring 参照 (Issue #403 で確定)。
///
/// ## ABI 内 signature 不統一の確定 (Issue #418, Won't Do)
///
/// 本ファイル内の他の export 関数 (`action_exec`, `process_record`) は
/// `(row: u8, col: u8, ...)` 平置き signature を維持しており、
/// `keymap_key_to_keycode` だけ `KeyPos` 値渡しを採用しているため ABI 内
/// signature は不統一。 これは Issue #418 で 3 案 (A: upstream 完全準拠 /
/// B: KeyPos 統一 / C: 現状維持 + 明文化) を比較検討した結果、 案 C を採用し
/// **意図的設計として確定** したもの。
///
/// 統一しない理由:
/// - **責務が異なる**: `keymap_key_to_keycode` は副作用のない lookup、
///   `action_exec` / `process_record` は state transition。 異なる責務に
///   異なる signature を割り当てるのは合理的。
/// - **ターゲットが異なる**: `keymap_key_to_keycode` は upstream の
///   `keymap_key_to_keycode(uint8_t layer, keypos_t key)` と完全一致して
///   いるため upstream 整合を優先、 `action_exec` / `process_record` は
///   FFI / テストアダプタ向けで C++ テスト直接リンクを想定していないため
///   平置き signature が合理的。
/// - **YAGNI**: C 側からの caller 0 件 (`quantum/` および `tmk_core/`
///   配下 grep で確認済み、 PR #404 / PR #417 でも追認済み)、 upstream へ
///   push しない一方向同期 (CLAUDE.md 明記) のため、 統一の実利益が薄い。
/// - **案 B (KeyPos 統一) の致命的欠点**: upstream の `keyevent_t` は
///   `event_type` (TICK / ENCODER / DIP_SWITCH 等 7 種類) を持つため
///   `KeyPos` だけでは将来 encoder ABI 等で破綻し、 二重変換ロジックが
///   永続化する。
/// - **案 A (upstream 完全準拠) の過剰投資**: `KeyEvent` / `KeyRecord` の
///   `extern struct` 化 + C ABI layout 互換確保コストに対し、 想定する
///   C 側 caller が存在しない。 ただし公平性のため明記すると、 案 A は将来
///   encoder ABI 等で `event_type` (TICK / ENCODER / DIP_SWITCH 等) を
///   渡せる拡張性メリットを持つ。 現時点では encoder 等の C 側 caller 自体が
///   未実装で YAGNI、 必要になった時点で再評価する。
///
/// PR #413 (Issue #403, `KeymapLookupFn` 内部 signature 維持) と同じ
/// Won't Do パターンとして処理。 今後 C 側 caller が登場する等で前提が
/// 崩れた場合のみ再検討する。
///
/// 注意: `KeyPos` は `packed struct { col: u8, row: u8 }` で `@sizeOf == 2`。
/// C 側から呼ぶ場合は `keypos_t` (col, row 順) のレイアウトが必要。
export fn keymap_key_to_keycode(layer: u8, key_pos: event_mod.KeyPos) u16 {
    if (layer >= keymap_mod.MAX_LAYERS) return 0;
    return keyboard_mod.keymapLookup(@intCast(layer), key_pos.row, key_pos.col);
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "qmk_abi: layer_on/off/state_is" {
    layer_mod.resetState();
    layer_on(1);
    try testing.expect(layer_state_is(1));
    layer_off(1);
    try testing.expect(!layer_state_is(1));
}

test "qmk_abi: layer_clear" {
    layer_mod.resetState();
    layer_on(1);
    layer_on(3);
    layer_clear();
    try testing.expect(!layer_state_is(1));
    try testing.expect(!layer_state_is(3));
}

test "qmk_abi: layer_state_set" {
    layer_mod.resetState();
    layer_state_set(0b1010);
    try testing.expect(layer_state_is(1));
    try testing.expect(layer_state_is(3));
    try testing.expect(!layer_state_is(2));
}

test "qmk_abi: layer_move" {
    layer_mod.resetState();
    layer_on(1);
    layer_on(2);
    layer_move(3);
    try testing.expect(!layer_state_is(1));
    try testing.expect(!layer_state_is(2));
    try testing.expect(layer_state_is(3));
}

test "qmk_abi: layer boundary check" {
    layer_mod.resetState();
    // Should not crash with out-of-range layer
    layer_on(255);
    try testing.expect(!layer_state_is(255));
    layer_off(255);
    layer_move(255);
}

test "qmk_abi: timer_read/read32" {
    timer.mockReset();
    try testing.expectEqual(@as(u16, 0), timer_read());
    try testing.expectEqual(@as(u32, 0), timer_read32());
}

test "qmk_abi: set_time/advance_time" {
    timer.mockReset();
    set_time(100);
    try testing.expectEqual(@as(u32, 100), timer_read32());
    advance_time(50);
    try testing.expectEqual(@as(u32, 150), timer_read32());
}

test "qmk_abi: timer_clear resets timer" {
    timer.mockReset();
    set_time(500);
    timer_clear();
    try testing.expectEqual(@as(u32, 0), timer_read32());
}

test "qmk_abi: keyboard_init/task lifecycle" {
    keyboard_init();
    keyboard_task();
}

test "qmk_abi: register_code/unregister_code with mock driver" {
    const FixedTestDriver = @import("core").test_driver.FixedTestDriver;
    const MockDriver = FixedTestDriver(32, 4);

    keyboard_init();
    var mock = MockDriver{};
    host_mod.setDriver(host_mod.HostDriver.from(&mock));
    defer host_mod.clearDriver();

    register_code(0x04); // KC_A
    send_keyboard_report();
    try testing.expect(mock.lastKeyboardReport().hasKey(0x04));

    unregister_code(0x04);
    send_keyboard_report();
    try testing.expect(!mock.lastKeyboardReport().hasKey(0x04));
}

test "qmk_abi: register_code modifier key" {
    const FixedTestDriver = @import("core").test_driver.FixedTestDriver;
    const MockDriver = FixedTestDriver(32, 4);

    keyboard_init();
    host_mod.hostReset(); // real_mods を確実にクリアして前テストの影響を排除
    var mock = MockDriver{};
    host_mod.setDriver(host_mod.HostDriver.from(&mock));
    defer host_mod.clearDriver();

    register_code(0xE1); // LSHIFT
    send_keyboard_report();
    try testing.expectEqual(@as(u8, 0x02), mock.lastKeyboardReport().mods);

    unregister_code(0xE1);
    send_keyboard_report();
    try testing.expectEqual(@as(u8, 0x00), mock.lastKeyboardReport().mods);
}

test "qmk_abi: clear_keyboard clears all state" {
    const FixedTestDriver = @import("core").test_driver.FixedTestDriver;
    const MockDriver = FixedTestDriver(32, 4);

    keyboard_init();
    var mock = MockDriver{};
    host_mod.setDriver(host_mod.HostDriver.from(&mock));
    defer host_mod.clearDriver();

    register_code(0x04);
    register_code(0xE1);
    clear_keyboard();
    try testing.expect(mock.lastKeyboardReport().isEmpty());
}

test "qmk_abi: host_set_driver/host_get_driver null" {
    keyboard_init();
    host_set_driver(null);
    try testing.expectEqual(@as(?*const CHostDriver, null), host_get_driver());
}

/// Issue #401 のテスト用 file-scope な lookup スタブ。
/// 「ABI 経由で action_exec / process_record を呼んでもクラッシュしない」 を
/// 検証するため、 panic しない最小の lookup として常に `KC.NO` を返す。
///
/// anonymous struct (test 内 inline 定義) ではなく file-scope に出した理由:
/// 関数ポインタ取得を test 関数本体の comptime コンテキスト外で完結させ、
/// test 順序を入れ替えても挙動が変わらないことを構造的に保証する。
fn testNoCrashLookup(_: u5, _: u8, _: u8) @import("core").keycode.Keycode {
    return @import("core").keycode.KC.NO;
}

test "qmk_abi: action_exec does not crash" {
    // 「ABI 経由で action_exec を呼んでもクラッシュしない」 を純粋に検証する。
    // Issue #401: defaultKeymapLookup が panic 化されたため、 keymap_lookup を
    // 呼びうるパスを通すテストは明示的に lookup と action_resolver を注入する。
    //
    // 呼び出し順序契約: keyboard_init() は内部で keymap_lookup と action_resolver を
    // リセットするため、 必ず init の **後に** setKeymapLookup / setActionResolver
    // を呼ぶこと。
    keyboard_init();
    keyboard_mod.setKeymapLookup(testNoCrashLookup);
    defer keyboard_mod.resetKeymapLookupToPanic();
    action_mod.setActionResolver(keyboard_mod.keymapActionResolver);

    action_exec(0, 0, true, 100);
    action_exec(0, 0, false, 200);
}

test "qmk_abi: process_record does not crash" {
    // Issue #401: action_exec does not crash と同様の理由で lookup / resolver を注入。
    keyboard_init();
    keyboard_mod.setKeymapLookup(testNoCrashLookup);
    defer keyboard_mod.resetKeymapLookupToPanic();
    action_mod.setActionResolver(keyboard_mod.keymapActionResolver);

    process_record(0, 0, true, 100);
    process_record(0, 0, false, 200);
}

test "qmk_abi: keymap_key_to_keycode returns keycode from injected lookup" {
    const keycode_mod = @import("core").keycode;
    const km_mod = @import("core").keymap;

    // ABI export `keymap_key_to_keycode` は注入済み lookup (`keyboard.keymapLookup`)
    // 経由でキーマップを参照する。 test 用に専用 storage と lookup を注入し、
    // ABI 経由のルックアップ経路を検証する。
    const TestKeymapStorage = struct {
        var km: km_mod.Keymap = km_mod.emptyKeymap();
        fn lookup(l: u5, row: u8, col: u8) keycode_mod.Keycode {
            return km_mod.keymapKeyToKeycode(&km, l, row, col);
        }
    };

    keyboard_init();
    TestKeymapStorage.km = km_mod.emptyKeymap();
    keyboard_mod.setKeymapLookup(TestKeymapStorage.lookup);
    defer keyboard_mod.resetKeymapLookupToPanic();

    try testing.expectEqual(@as(u16, 0), keymap_key_to_keycode(0, event_mod.KeyPos{ .col = 0, .row = 0 }));

    // 注入された storage にキーを設定
    TestKeymapStorage.km[0][0][0] = keycode_mod.KC.A;
    try testing.expectEqual(keycode_mod.KC.A, keymap_key_to_keycode(0, event_mod.KeyPos{ .col = 0, .row = 0 }));

    // 範囲外のレイヤーは 0 を返す
    try testing.expectEqual(@as(u16, 0), keymap_key_to_keycode(255, event_mod.KeyPos{ .col = 0, .row = 0 }));

    // 別の (row, col) を別キーコードで検証 (KeyPos 経由のフィールドアクセス確認)
    TestKeymapStorage.km[0][2][3] = keycode_mod.KC.B;
    try testing.expectEqual(keycode_mod.KC.B, keymap_key_to_keycode(0, event_mod.KeyPos{ .col = 3, .row = 2 }));
}
