//! Key Override 機能
//! C版 quantum/process_keycode/process_key_override.c の移植
//!
//! 特定の修飾キーとキーの組み合わせを別のキーコードにオーバーライドする。
//! 例: Shift + Backspace → Delete
//!
//! オーバーライドテーブル（KeyOverride スライス）で設定する。
//! 複雑なステートマシンで現在のアクティブオーバーライドを追跡する。

const host = @import("host.zig");
const keycode_mod = @import("keycode.zig");
const report_mod = @import("report.zig");
const layer_mod = @import("layer.zig");
const timer = @import("../hal/timer.zig");
const KC = keycode_mod.KC;
const Keycode = keycode_mod.Keycode;

/// Key Override 有効化条件のビットフィールド
pub const KoOption = struct {
    /// トリガーキー押下時にアクティベーション許可
    pub const activation_trigger_down: u8 = (1 << 0);
    /// 必須修飾キー押下時にアクティベーション許可
    pub const activation_required_mod_down: u8 = (1 << 1);
    /// 否定修飾キーリリース時にアクティベーション許可
    pub const activation_negative_mod_up: u8 = (1 << 2);
    /// 全アクティベーション許可
    pub const all_activations: u8 = activation_trigger_down | activation_required_mod_down | activation_negative_mod_up;
    /// いずれか1つの修飾キーでアクティベーション（OR モード）
    pub const one_mod: u8 = (1 << 3);
    /// オーバーライド解除後にトリガーキーを再登録しない
    pub const no_reregister_trigger: u8 = (1 << 4);
    /// 他キー押下でもオーバーライドを解除しない
    pub const no_unregister_on_other_key_down: u8 = (1 << 5);
    /// デフォルトオプション
    pub const default: u8 = all_activations;
};

/// Key Override 定義
pub const KeyOverride = struct {
    /// トリガーキーコード（KC.NO = 修飾キーのみでトリガー）
    trigger: Keycode,
    /// 必須修飾キー（8ビット HID mod ビットマスク）
    trigger_mods: u8,
    /// 適用レイヤーのビットマスク（ビットi = レイヤーi）
    layers: u32,
    /// 否定修飾キーマスク（これが押されていたら不一致）
    negative_mod_mask: u8,
    /// アクティブ時に抑制する修飾キー
    suppressed_mods: u8,
    /// 置換キーコード（修飾キー付きも可、例: C(KC.A) = 0x0104）
    replacement: Keycode,
    /// オプションフラグ
    options: u8,

    /// 基本的な Key Override を作成するコンビニエンス関数
    /// C版 ko_make_basic に相当
    pub fn basic(trigger_mods: u8, trigger: Keycode, replacement: Keycode) KeyOverride {
        return withLayers(trigger_mods, trigger, replacement, 0xFFFFFFFF);
    }

    /// レイヤー指定付きの Key Override を作成
    /// C版 ko_make_with_layers に相当
    pub fn withLayers(trigger_mods: u8, trigger: Keycode, replacement: Keycode, layers: u32) KeyOverride {
        return withLayersAndNegmods(trigger_mods, trigger, replacement, layers, 0);
    }

    /// レイヤーと否定修飾キー指定付きの Key Override を作成
    /// C版 ko_make_with_layers_and_negmods に相当
    pub fn withLayersAndNegmods(trigger_mods: u8, trigger: Keycode, replacement: Keycode, layers: u32, negative_mask: u8) KeyOverride {
        return withLayersNegmodsAndOptions(trigger_mods, trigger, replacement, layers, negative_mask, KoOption.default);
    }

    /// 全パラメータ指定の Key Override を作成
    /// C版 ko_make_with_layers_negmods_and_options に相当
    pub fn withLayersNegmodsAndOptions(trigger_mods: u8, trigger: Keycode, replacement: Keycode, layers: u32, negative_mask: u8, options: u8) KeyOverride {
        return .{
            .trigger = trigger,
            .trigger_mods = trigger_mods,
            .layers = layers,
            .negative_mod_mask = negative_mask,
            .suppressed_mods = trigger_mods,
            .replacement = replacement,
            .options = options,
        };
    }
};

// ============================================================
// 内部状態
// ============================================================

/// 登録されたオーバーライドテーブル
var overrides: []const KeyOverride = &.{};

/// 現在アクティブなオーバーライドのインデックス（null = なし）
var active_override_index: ?usize = null;

/// アクティブオーバーライドのトリガーキーが押下中か
var active_override_trigger_is_down: bool = false;

/// 最後に押された非修飾キーのキーコード
var last_key_down: Keycode = 0;

/// 最後のキー押下時刻
var last_key_down_time: u32 = 0;

/// 遅延登録するキーコード（0 = なし）
var deferred_register: Keycode = 0;

/// 遅延の基準時刻
var defer_reference_time: u32 = 0;

/// 遅延時間（ms）
var defer_delay: u32 = 0;

/// Key Override の有効/無効
var enabled: bool = true;

/// キーリピート遅延（ms）
const KEY_OVERRIDE_REPEAT_DELAY: u32 = 500;

// ============================================================
// 公開API
// ============================================================

/// オーバーライドテーブルを設定する
pub fn setOverrides(table: []const KeyOverride) void {
    overrides = table;
}

/// Key Override を有効化する
pub fn on() void {
    enabled = true;
}

/// Key Override を無効化する
pub fn off() void {
    enabled = false;
    _ = clearActiveOverride(false);
}

/// Key Override をトグルする
pub fn toggle() void {
    if (enabled) {
        off();
    } else {
        on();
    }
}

/// Key Override が有効かどうかを返す
pub fn isEnabled() bool {
    return enabled;
}

/// 状態をリセットする（テスト用）
pub fn reset() void {
    active_override_index = null;
    active_override_trigger_is_down = false;
    last_key_down = 0;
    last_key_down_time = 0;
    deferred_register = 0;
    defer_reference_time = 0;
    defer_delay = 0;
    enabled = true;
    overrides = &.{};
    host.clearWeakOverrideMods();
    host.clearSuppressedOverrideMods();
}

/// 遅延登録を処理する（メインループから毎サイクル呼ぶ）
/// C版 key_override_task() に相当
pub fn task() void {
    if (deferred_register == 0) return;

    if (timer.elapsed32(defer_reference_time) >= defer_delay) {
        registerCode16(deferred_register);
        deferred_register = 0;
        defer_reference_time = 0;
        defer_delay = 0;
    }
}

/// キーイベントを処理する
/// C版 process_key_override() に相当
/// 戻り値: true = 通常通りキーアクションを処理、false = キーを飲み込む
pub fn processKeyOverride(kc: Keycode, pressed: bool) bool {
    const is_mod = isModifierKeycode(kc);

    if (pressed) {
        if (kc == keycode_mod.QK_KEY_OVERRIDE_TOGGLE) {
            toggle();
            return false;
        }
        if (kc == keycode_mod.QK_KEY_OVERRIDE_ON) {
            on();
            return false;
        }
        if (kc == keycode_mod.QK_KEY_OVERRIDE_OFF) {
            off();
            return false;
        }
    }

    if (!enabled) return true;

    // 実効修飾キーの計算
    // C版同様: oneshot_mods も含める（oneshot Shift + Backspace → Delete 等に必要）
    var effective_mods = host.getMods() | host.getOneshotMods();

    if (is_mod) {
        // get_mods() はこのイベント処理後に更新されるので、手動で反映
        if (pressed) {
            effective_mods |= modBit(kc);
        } else {
            effective_mods &= ~modBit(kc);
        }
    } else {
        if (pressed) {
            last_key_down = kc;
            last_key_down_time = timer.read32();
            deferred_register = 0;
        }

        // 最後に押されたキーが離されたらリセット
        if (!pressed and kc == last_key_down) {
            last_key_down = 0;
            last_key_down_time = 0;
            deferred_register = 0;
        }
    }

    var send_key_action = true;
    var activated = false;

    // 非修飾キーのリリースイベントはオーバーライドをアクティベートしない
    if (is_mod or pressed) {
        // C版は read_source_layers_cache() で単一ソースレイヤーを取得してチェックするが、
        // Zig版はキーコードレベルで処理するためソースレイヤー情報がない。
        // 代わりにアクティブレイヤー全体のビットマスクとの AND で判定する。
        // 実用上、いずれかのアクティブレイヤーが layers に含まれていれば一致とする。
        const layer_state = layer_mod.getLayerState() | layer_mod.getDefaultLayerState();
        send_key_action = tryActivatingOverride(kc, layer_state, pressed, is_mod, effective_mods, &activated);

        if (!send_key_action) {
            host.sendKeyboardReport();
        }
    }

    if (!activated and active_override_index != null) {
        const active = overrides[active_override_index.?];
        if (is_mod) {
            // 必須修飾キーが離されたか、否定修飾キーが押された場合
            if (!matchesActiveMods(active, effective_mods)) {
                _ = clearActiveOverride(true);
            }
        } else {
            var should_deactivate = false;

            // トリガーキーがリリースされた場合
            if (kc == active.trigger and !pressed) {
                should_deactivate = true;
                active_override_trigger_is_down = false;
            }

            // 他のキーが押された場合（オプションで無効化可能）
            if (pressed and (active.options & KoOption.no_unregister_on_other_key_down) == 0) {
                should_deactivate = true;
            }

            if (should_deactivate) {
                _ = clearActiveOverride(false);
            }
        }
    }

    return send_key_action;
}

// ============================================================
// 内部関数
// ============================================================

/// キーコードから修飾キービットを除去する
/// C版 clear_mods_from() に相当
fn clearModsFrom(kc: Keycode) Keycode {
    // QK_MODS 範囲 (0x0100-0x1FFF) のみ処理
    if (kc < 0x0100 or kc > 0x1FFF) return kc;
    const all_mods: u16 = 0x1F00; // QK_LCTL | QK_LSFT | QK_LALT | QK_LGUI | QK_RCTL | QK_RSFT | QK_RALT | QK_RGUI
    return kc & ~all_mods;
}

/// キーコードから修飾キービットを抽出する（8ビット HID 形式）
/// C版 extract_mod_bits() に相当
fn extractModBits(kc: Keycode) u8 {
    // QK_MODS 範囲 (0x0100-0x1FFF) のみ処理
    if (kc < 0x0100 or kc > 0x1FFF) return 0;

    var mods_to_send: u8 = 0;
    if (kc & 0x1000 != 0) {
        // Right mod flag
        if (kc & 0x0100 != 0) mods_to_send |= report_mod.ModBit.RCTRL;
        if (kc & 0x0200 != 0) mods_to_send |= report_mod.ModBit.RSHIFT;
        if (kc & 0x0400 != 0) mods_to_send |= report_mod.ModBit.RALT;
        if (kc & 0x0800 != 0) mods_to_send |= report_mod.ModBit.RGUI;
    } else {
        if (kc & 0x0100 != 0) mods_to_send |= report_mod.ModBit.LCTRL;
        if (kc & 0x0200 != 0) mods_to_send |= report_mod.ModBit.LSHIFT;
        if (kc & 0x0400 != 0) mods_to_send |= report_mod.ModBit.LALT;
        if (kc & 0x0800 != 0) mods_to_send |= report_mod.ModBit.LGUI;
    }
    return mods_to_send;
}

/// 修飾キーの条件がオーバーライドと一致するか
/// C版 key_override_matches_active_modifiers() に相当
fn matchesActiveMods(override: KeyOverride, mods: u8) bool {
    // 否定修飾キーチェック
    if ((override.negative_mod_mask & mods) != 0) return false;

    // 修飾キー不要なら即 true
    if (override.trigger_mods == 0) return true;

    if (override.options & KoOption.one_mod != 0) {
        // OR モード: いずれか1つの trigger_mods が押されていればOK
        return (override.trigger_mods & mods) != 0;
    } else {
        // AND モード: 全 trigger_mods が押されている必要あり（左右どちらでも可）
        const one_sided_required: u8 = (override.trigger_mods & 0x0F) | (override.trigger_mods >> 4);
        const active_required: u8 = override.trigger_mods & mods;
        const one_sided_active: u8 = (active_required & 0x0F) | (active_required >> 4);
        return one_sided_active == one_sided_required;
    }
}

/// アクティベーションイベントが許可されているか
/// C版 check_activation_event() に相当
fn checkActivationEvent(override: KeyOverride, key_down: bool, is_mod: bool) bool {
    var options = override.options;

    if ((options & KoOption.all_activations) == 0) {
        options = KoOption.all_activations;
    }

    if (is_mod) {
        if (key_down) {
            return (options & KoOption.activation_required_mod_down) != 0;
        } else {
            return (options & KoOption.activation_negative_mod_up) != 0;
        }
    } else {
        if (key_down) {
            return (options & KoOption.activation_trigger_down) != 0;
        } else {
            return false;
        }
    }
}

/// アクティブなオーバーライドをクリアする
/// C版 clear_active_override() に相当
fn clearActiveOverride(allow_reregister: bool) ?usize {
    if (active_override_index == null) return null;

    const idx = active_override_index.?;
    const active = overrides[idx];

    deferred_register = 0;

    // 抑制修飾キーをクリア
    host.clearSuppressedOverrideMods();

    // 弱いオーバーライド修飾キーをクリア
    host.clearWeakOverrideMods();

    const mod_free_replacement = clearModsFrom(active.replacement);

    const unregister_replacement = mod_free_replacement != KC.NO and
        mod_free_replacement <= 0x00FF;

    if (unregister_replacement) {
        if (report_mod.isModifierKeycode(@truncate(mod_free_replacement))) {
            // C版同様: 修飾キー replacement は先にレポートを送信してから unregister する
            host.sendKeyboardReport();
            host.unregisterCode(@truncate(mod_free_replacement));
        } else {
            // unregister_replacement が true の時点で mod_free_replacement <= 0x00FF は保証済み
            host.getReport().removeKey(@truncate(mod_free_replacement));
        }
    }

    const trigger = active.trigger;
    const reregister_trigger = allow_reregister and
        (active.options & KoOption.no_reregister_trigger) == 0 and
        active_override_trigger_is_down and
        trigger != KC.NO and
        trigger <= 0x00FF;

    if (reregister_trigger) {
        scheduleDeferredRegister(trigger);
    }

    host.sendKeyboardReport();

    active_override_index = null;
    active_override_trigger_is_down = false;

    return idx;
}

/// 遅延登録をスケジュールする
/// C版 schedule_deferred_register() に相当
fn scheduleDeferredRegister(kc: Keycode) void {
    if (timer.elapsed32(last_key_down_time) < KEY_OVERRIDE_REPEAT_DELAY) {
        defer_reference_time = last_key_down_time;
        defer_delay = KEY_OVERRIDE_REPEAT_DELAY;
    } else {
        defer_reference_time = timer.read32();
        defer_delay = 50;
    }
    deferred_register = kc;
}

/// オーバーライドのアクティベーションを試みる
/// C版 try_activating_override() に相当
fn tryActivatingOverride(kc: Keycode, layer_state: u32, key_down: bool, is_mod: bool, active_mods: u8, activated: *bool) bool {
    if (overrides.len == 0) {
        activated.* = false;
        return true;
    }

    for (overrides, 0..) |override, i| {
        // 修飾キーが押されていないのにオーバーライドが修飾キーを要求している場合はスキップ（高速フィルタ）
        if (active_mods == 0 and override.trigger_mods != 0) continue;

        // レイヤーチェック
        if ((override.layers & layer_state) == 0) continue;

        // アクティベーションイベントチェック
        if (!checkActivationEvent(override, key_down, is_mod)) continue;

        const is_trigger = override.trigger == kc;

        // トリガーがリリースされた場合はスキップ
        if (is_trigger and !key_down) continue;

        const no_trigger = override.trigger == KC.NO;

        // 既にアクティブな場合はスキップ
        if (active_override_index) |active_idx| {
            if (active_idx == i) continue;
        }

        // 修飾キー条件の詳細チェック
        if (!matchesActiveMods(override, active_mods)) continue;

        // トリガーが押下中かチェック
        const trigger_down = is_trigger and key_down;
        const should_activate = no_trigger or trigger_down or last_key_down == override.trigger;

        if (!should_activate) continue;

        // アクティベーション
        _ = clearActiveOverride(false);

        active_override_index = i;
        active_override_trigger_is_down = true;

        host.setSuppressedOverrideMods(override.suppressed_mods);

        if (!trigger_down and !no_trigger) {
            // トリガーキーがレポートに既に登録されている場合は削除
            if (override.trigger <= 0x00FF) {
                if (report_mod.isModifierKeycode(@truncate(override.trigger))) {
                    host.unregisterCode(@truncate(override.trigger));
                } else {
                    host.getReport().removeKey(@truncate(override.trigger));
                }
            }
        }

        const mod_free_replacement = clearModsFrom(override.replacement);

        const register_replacement = mod_free_replacement != KC.NO and
            mod_free_replacement <= 0x00FF;

        if (register_replacement) {
            const override_mods = extractModBits(override.replacement);
            host.setWeakOverrideMods(override_mods);

            if (is_mod) {
                // 修飾キーイベントでトリガーされた場合は遅延登録
                scheduleDeferredRegister(mod_free_replacement);
                host.sendKeyboardReport();
            } else {
                // register_replacement が true の時点で mod_free_replacement <= 0x00FF は保証済み
                _ = host.getReport().addKey(@truncate(mod_free_replacement));
            }
        } else {
            host.sendKeyboardReport();
        }

        activated.* = true;

        // トリガー押下の場合はキーアクションを抑制
        return !trigger_down;
    }

    activated.* = false;
    return true;
}

/// 16ビットキーコードを登録する（修飾ビット含む）
/// C版 register_code16() の簡易版
fn registerCode16(kc: Keycode) void {
    const mods = extractModBits(kc);
    if (mods != 0) host.addWeakMods(mods);
    const basic_kc: u8 = @truncate(clearModsFrom(kc));
    if (basic_kc != 0) host.registerCode(basic_kc);
    host.sendKeyboardReport();
    if (mods != 0) host.delWeakMods(mods);
}

/// 基本キーコードが修飾キーかどうか
inline fn isModifierKeycode(kc: Keycode) bool {
    return kc >= 0xE0 and kc <= 0xE7;
}

/// 修飾キーコードからビットマスクを取得
/// C版 MOD_BIT(code) に相当: (1 << (code & 0x07))
inline fn modBit(kc: Keycode) u8 {
    return @as(u8, 1) << @as(u3, @truncate(kc & 0x07));
}

// ============================================================
// Tests
// ============================================================

const std = @import("std");
const testing = std.testing;
const FixedTestDriver = @import("test_driver.zig").FixedTestDriver;
const MockDriver = FixedTestDriver(64, 16);

fn setupTest() *MockDriver {
    const static = struct {
        var mock: MockDriver = .{};
    };
    static.mock = .{};
    reset();
    host.hostReset();
    layer_mod.resetState();
    host.setDriver(host.HostDriver.from(&static.mock));
    return &static.mock;
}

fn teardownTest() void {
    host.clearDriver();
}

test "key_override: initial state" {
    reset();
    try testing.expect(isEnabled());
    try testing.expect(active_override_index == null);
}

test "key_override: toggle on/off" {
    reset();
    try testing.expect(isEnabled());
    toggle();
    try testing.expect(!isEnabled());
    toggle();
    try testing.expect(isEnabled());
}

test "key_override: basic shift+backspace -> delete" {
    const mock = setupTest();
    defer teardownTest();

    const table = [_]KeyOverride{
        KeyOverride.basic(report_mod.ModBit.LSHIFT, KC.BSPC, KC.DEL),
    };
    setOverrides(&table);

    // Shift を押す
    host.addMods(report_mod.ModBit.LSHIFT);
    _ = processKeyOverride(KC.LEFT_SHIFT, true);

    // Backspace を押す → Delete に置換されるはず
    const result = processKeyOverride(KC.BSPC, true);

    // トリガーキー押下なのでキーアクションは抑制される
    try testing.expect(!result);

    // Delete がレポートに追加されている
    try testing.expect(mock.keyboard_count >= 1);

    // Backspace を離す
    _ = processKeyOverride(KC.BSPC, false);

    // Shift を離す
    host.delMods(report_mod.ModBit.LSHIFT);
    _ = processKeyOverride(KC.LEFT_SHIFT, false);

    // オーバーライドが解除されている
    try testing.expect(active_override_index == null);
}

test "key_override: no override when mods don't match" {
    _ = setupTest();
    defer teardownTest();

    const table = [_]KeyOverride{
        KeyOverride.basic(report_mod.ModBit.LSHIFT, KC.BSPC, KC.DEL),
    };
    setOverrides(&table);

    // Shift なしで Backspace を押す → オーバーライドなし
    const result = processKeyOverride(KC.BSPC, true);
    try testing.expect(result); // 通常通り処理

    try testing.expect(active_override_index == null);
}

test "key_override: negative mod prevents activation" {
    _ = setupTest();
    defer teardownTest();

    const table = [_]KeyOverride{
        KeyOverride.withLayersAndNegmods(
            report_mod.ModBit.LSHIFT,
            KC.BSPC,
            KC.DEL,
            0xFFFFFFFF,
            report_mod.ModBit.LCTRL, // Ctrl が押されていたら不一致
        ),
    };
    setOverrides(&table);

    // Shift + Ctrl を押す
    host.addMods(report_mod.ModBit.LSHIFT | report_mod.ModBit.LCTRL);
    _ = processKeyOverride(KC.LEFT_SHIFT, true);
    _ = processKeyOverride(KC.LEFT_CTRL, true);

    // Backspace を押す → 否定修飾キーにより不一致
    const result = processKeyOverride(KC.BSPC, true);
    try testing.expect(result); // 通常通り処理
    try testing.expect(active_override_index == null);

    host.delMods(report_mod.ModBit.LSHIFT | report_mod.ModBit.LCTRL);
}

test "key_override: layer filtering" {
    _ = setupTest();
    defer teardownTest();

    const table = [_]KeyOverride{
        KeyOverride.withLayers(
            report_mod.ModBit.LSHIFT,
            KC.BSPC,
            KC.DEL,
            0x02, // レイヤー1のみ
        ),
    };
    setOverrides(&table);

    // レイヤー0 のみアクティブ → 不一致
    host.addMods(report_mod.ModBit.LSHIFT);
    _ = processKeyOverride(KC.LEFT_SHIFT, true);

    var result = processKeyOverride(KC.BSPC, true);
    try testing.expect(result);
    try testing.expect(active_override_index == null);

    _ = processKeyOverride(KC.BSPC, false);

    // レイヤー1 をアクティブにする
    layer_mod.layerOn(1);

    result = processKeyOverride(KC.BSPC, true);
    try testing.expect(!result); // オーバーライド発動
    try testing.expect(active_override_index != null);

    layer_mod.layerOff(1);
    host.delMods(report_mod.ModBit.LSHIFT);
}

test "key_override: deactivates when trigger released" {
    _ = setupTest();
    defer teardownTest();

    const table = [_]KeyOverride{
        KeyOverride.basic(report_mod.ModBit.LSHIFT, KC.BSPC, KC.DEL),
    };
    setOverrides(&table);

    host.addMods(report_mod.ModBit.LSHIFT);
    _ = processKeyOverride(KC.LEFT_SHIFT, true);

    // アクティベーション
    _ = processKeyOverride(KC.BSPC, true);
    try testing.expect(active_override_index != null);

    // トリガーリリース → 解除
    _ = processKeyOverride(KC.BSPC, false);
    try testing.expect(active_override_index == null);

    host.delMods(report_mod.ModBit.LSHIFT);
}

test "key_override: deactivates when mod released" {
    _ = setupTest();
    defer teardownTest();

    const table = [_]KeyOverride{
        KeyOverride.basic(report_mod.ModBit.LSHIFT, KC.BSPC, KC.DEL),
    };
    setOverrides(&table);

    host.addMods(report_mod.ModBit.LSHIFT);
    _ = processKeyOverride(KC.LEFT_SHIFT, true);

    // アクティベーション
    _ = processKeyOverride(KC.BSPC, true);
    try testing.expect(active_override_index != null);

    // Shift リリース → 解除
    host.delMods(report_mod.ModBit.LSHIFT);
    _ = processKeyOverride(KC.LEFT_SHIFT, false);
    try testing.expect(active_override_index == null);
}

test "key_override: deactivates when other key pressed" {
    _ = setupTest();
    defer teardownTest();

    const table = [_]KeyOverride{
        KeyOverride.basic(report_mod.ModBit.LSHIFT, KC.BSPC, KC.DEL),
    };
    setOverrides(&table);

    host.addMods(report_mod.ModBit.LSHIFT);
    _ = processKeyOverride(KC.LEFT_SHIFT, true);

    // アクティベーション
    _ = processKeyOverride(KC.BSPC, true);
    try testing.expect(active_override_index != null);

    // 別キー押下 → 解除
    _ = processKeyOverride(KC.A, true);
    try testing.expect(active_override_index == null);
}

test "key_override: no_unregister_on_other_key_down option" {
    _ = setupTest();
    defer teardownTest();

    const table = [_]KeyOverride{
        KeyOverride.withLayersNegmodsAndOptions(
            report_mod.ModBit.LSHIFT,
            KC.BSPC,
            KC.DEL,
            0xFFFFFFFF,
            0,
            KoOption.default | KoOption.no_unregister_on_other_key_down,
        ),
    };
    setOverrides(&table);

    host.addMods(report_mod.ModBit.LSHIFT);
    _ = processKeyOverride(KC.LEFT_SHIFT, true);

    // アクティベーション
    _ = processKeyOverride(KC.BSPC, true);
    try testing.expect(active_override_index != null);

    // 別キー押下 → オプションにより解除されない
    _ = processKeyOverride(KC.A, true);
    try testing.expect(active_override_index != null);

    host.delMods(report_mod.ModBit.LSHIFT);
}

test "key_override: one_mod option (OR mode)" {
    _ = setupTest();
    defer teardownTest();

    const table = [_]KeyOverride{
        KeyOverride.withLayersNegmodsAndOptions(
            report_mod.ModBit.LSHIFT | report_mod.ModBit.LCTRL,
            KC.BSPC,
            KC.DEL,
            0xFFFFFFFF,
            0,
            KoOption.default | KoOption.one_mod,
        ),
    };
    setOverrides(&table);

    // Shift のみで発動（OR モード）
    host.addMods(report_mod.ModBit.LSHIFT);
    _ = processKeyOverride(KC.LEFT_SHIFT, true);

    const result = processKeyOverride(KC.BSPC, true);
    try testing.expect(!result); // 発動
    try testing.expect(active_override_index != null);

    host.delMods(report_mod.ModBit.LSHIFT);
}

test "key_override: disabled state passes through" {
    _ = setupTest();
    defer teardownTest();

    const table = [_]KeyOverride{
        KeyOverride.basic(report_mod.ModBit.LSHIFT, KC.BSPC, KC.DEL),
    };
    setOverrides(&table);

    off();

    host.addMods(report_mod.ModBit.LSHIFT);
    _ = processKeyOverride(KC.LEFT_SHIFT, true);

    const result = processKeyOverride(KC.BSPC, true);
    try testing.expect(result); // 無効化されているので通常処理
    try testing.expect(active_override_index == null);

    host.delMods(report_mod.ModBit.LSHIFT);
}

test "key_override: KO_TOGG keycode toggles" {
    _ = setupTest();
    defer teardownTest();

    try testing.expect(isEnabled());
    _ = processKeyOverride(keycode_mod.KO_TOGG, true);
    try testing.expect(!isEnabled());
    _ = processKeyOverride(keycode_mod.KO_TOGG, true);
    try testing.expect(isEnabled());
}

test "key_override: mod activation triggers override" {
    _ = setupTest();
    defer teardownTest();

    const table = [_]KeyOverride{
        KeyOverride.basic(report_mod.ModBit.LSHIFT, KC.BSPC, KC.DEL),
    };
    setOverrides(&table);

    // まず Backspace を押す
    _ = processKeyOverride(KC.BSPC, true);
    try testing.expect(active_override_index == null); // まだ発動しない

    // Shift を押す → 遅延付きで発動
    host.addMods(report_mod.ModBit.LSHIFT);
    _ = processKeyOverride(KC.LEFT_SHIFT, true);
    try testing.expect(active_override_index != null); // 修飾キー押下で発動

    host.delMods(report_mod.ModBit.LSHIFT);
}

test "key_override: trigger KC_NO (mod-only override)" {
    const mock = setupTest();
    defer teardownTest();

    const table = [_]KeyOverride{
        KeyOverride.basic(report_mod.ModBit.LSHIFT, KC.NO, KC.A),
    };
    setOverrides(&table);

    // Shift を押す → KC_NO トリガーなので修飾キーだけで発動
    host.addMods(report_mod.ModBit.LSHIFT);
    _ = processKeyOverride(KC.LEFT_SHIFT, true);
    try testing.expect(active_override_index != null);

    // 遅延登録を処理
    timer.mockAdvance(KEY_OVERRIDE_REPEAT_DELAY + 1);
    task();

    // KC_A が登録されている
    try testing.expect(mock.keyboard_count >= 1);

    host.delMods(report_mod.ModBit.LSHIFT);
}

test "key_override: deferred register with task" {
    const mock = setupTest();
    defer teardownTest();

    const table = [_]KeyOverride{
        KeyOverride.basic(report_mod.ModBit.LSHIFT, KC.BSPC, KC.DEL),
    };
    setOverrides(&table);

    // Backspace を先に押す
    _ = processKeyOverride(KC.BSPC, true);

    // Shift を押す → 修飾キーイベントでトリガーされるので遅延登録
    host.addMods(report_mod.ModBit.LSHIFT);
    _ = processKeyOverride(KC.LEFT_SHIFT, true);
    try testing.expect(active_override_index != null);
    try testing.expect(deferred_register != 0);

    // まだタイマーが足りない
    task();
    const count_before = mock.keyboard_count;

    // 遅延時間経過
    timer.mockAdvance(KEY_OVERRIDE_REPEAT_DELAY + 1);
    task();

    // 遅延登録が実行された
    try testing.expect(deferred_register == 0);
    try testing.expect(mock.keyboard_count > count_before);

    host.delMods(report_mod.ModBit.LSHIFT);
}

test "key_override: clearModsFrom" {
    try testing.expectEqual(@as(Keycode, KC.A), clearModsFrom(KC.A));
    try testing.expectEqual(@as(Keycode, KC.A), clearModsFrom(0x0204)); // S(KC_A) = 0x0200 | 0x04
    try testing.expectEqual(@as(Keycode, KC.A), clearModsFrom(0x0104)); // C(KC_A) = 0x0100 | 0x04
    try testing.expectEqual(@as(Keycode, 0), clearModsFrom(0x0200)); // S(KC_NO) = shift without key
}

test "key_override: extractModBits" {
    try testing.expectEqual(@as(u8, 0), extractModBits(KC.A));
    try testing.expectEqual(report_mod.ModBit.LSHIFT, extractModBits(0x0204)); // S(KC_A)
    try testing.expectEqual(report_mod.ModBit.LCTRL, extractModBits(0x0104)); // C(KC_A)
    try testing.expectEqual(report_mod.ModBit.RSHIFT, extractModBits(0x1204)); // RS(KC_A)
}

test "key_override: matchesActiveMods AND mode" {
    const override = KeyOverride.basic(report_mod.ModBit.LSHIFT | report_mod.ModBit.LCTRL, KC.A, KC.B);

    // 両方押されている → 一致
    try testing.expect(matchesActiveMods(override, report_mod.ModBit.LSHIFT | report_mod.ModBit.LCTRL));

    // Shift のみ → 不一致
    try testing.expect(!matchesActiveMods(override, report_mod.ModBit.LSHIFT));

    // なにも押されていない → 不一致
    try testing.expect(!matchesActiveMods(override, 0));
}

test "key_override: matchesActiveMods with no required mods" {
    const override = KeyOverride{
        .trigger = KC.A,
        .trigger_mods = 0,
        .layers = 0xFFFFFFFF,
        .negative_mod_mask = 0,
        .suppressed_mods = 0,
        .replacement = KC.B,
        .options = KoOption.default,
    };

    // 修飾キー不要 → 常に一致
    try testing.expect(matchesActiveMods(override, 0));
    try testing.expect(matchesActiveMods(override, report_mod.ModBit.LSHIFT));
}
