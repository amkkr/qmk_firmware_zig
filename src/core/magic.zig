//! Magic Keycodes 処理
//! C版 quantum/process_keycode/process_magic.c に相当
//!
//! BOOTMAGIC without the boot — ランタイムで keymap_config のフラグを
//! トグル/セット/クリアし、EEPROM に永続化する。
//!
//! 処理タイミング: キー押下時（C版と同じ）。リリースは無視。
//! Magic キーコード処理後に clear_keyboard() を実行してスタック防止。
//!
//! C版との差異:
//! - AUDIO_ENABLE ソング再生: 省略
//! - EE_HANDS_LEFT/RIGHT (eeconfig_update_handedness): 省略
//!   （スプリット判定のハンドシェイクは本ファームウェアでは未実装）

const keycode_mod = @import("keycode.zig");
const keymap_mod = @import("keymap.zig");
const host = @import("host.zig");
const Keycode = keycode_mod.Keycode;
const KeymapConfig = keymap_mod.KeymapConfig;

/// Magic キーコード範囲判定
pub fn isMagicKeycode(kc: Keycode) bool {
    return kc >= keycode_mod.QK_MAGIC_SWAP_CONTROL_CAPS_LOCK and
        kc <= keycode_mod.QK_MAGIC_TOGGLE_ESCAPE_CAPS_LOCK;
}

/// Magic キーコードを処理する。
/// C版 process_magic() に相当。press 時のみ処理、release は無視。
/// 戻り値: true = 通常処理続行, false = キーを消費（Magic として処理済み）
pub fn process(kc: Keycode, pressed: bool) bool {
    if (!pressed) return true;
    if (!isMagicKeycode(kc)) return true;

    // EEPROM から現在の設定を読み出す
    var config = keymap_mod.keymap_config;

    switch (kc) {
        // Ctrl / CapsLock
        keycode_mod.CL_SWAP => config.swap_control_capslock = true,
        keycode_mod.CL_NORM => config.swap_control_capslock = false,
        keycode_mod.CL_TOGG => config.swap_control_capslock = !config.swap_control_capslock,
        keycode_mod.CL_CAPS => config.capslock_to_control = false,
        keycode_mod.CL_CTRL => config.capslock_to_control = true,

        // Escape / CapsLock
        keycode_mod.EC_SWAP => config.swap_escape_capslock = true,
        keycode_mod.EC_NORM => config.swap_escape_capslock = false,
        keycode_mod.EC_TOGG => config.swap_escape_capslock = !config.swap_escape_capslock,

        // Left Alt / Left GUI
        keycode_mod.AG_LSWP => config.swap_lalt_lgui = true,
        keycode_mod.AG_LNRM => config.swap_lalt_lgui = false,

        // Right Alt / Right GUI
        keycode_mod.AG_RSWP => config.swap_ralt_rgui = true,
        keycode_mod.AG_RNRM => config.swap_ralt_rgui = false,

        // Both Alt / GUI
        keycode_mod.AG_SWAP => {
            config.swap_lalt_lgui = true;
            config.swap_ralt_rgui = true;
        },
        keycode_mod.AG_NORM => {
            config.swap_lalt_lgui = false;
            config.swap_ralt_rgui = false;
        },
        keycode_mod.AG_TOGG => {
            config.swap_lalt_lgui = !config.swap_lalt_lgui;
            config.swap_ralt_rgui = config.swap_lalt_lgui;
        },

        // Left Ctrl / Left GUI
        keycode_mod.CG_LSWP => config.swap_lctl_lgui = true,
        keycode_mod.CG_LNRM => config.swap_lctl_lgui = false,

        // Right Ctrl / Right GUI
        keycode_mod.CG_RSWP => config.swap_rctl_rgui = true,
        keycode_mod.CG_RNRM => config.swap_rctl_rgui = false,

        // Both Ctrl / GUI
        keycode_mod.CG_SWAP => {
            config.swap_lctl_lgui = true;
            config.swap_rctl_rgui = true;
        },
        keycode_mod.CG_NORM => {
            config.swap_lctl_lgui = false;
            config.swap_rctl_rgui = false;
        },
        keycode_mod.CG_TOGG => {
            config.swap_lctl_lgui = !config.swap_lctl_lgui;
            config.swap_rctl_rgui = config.swap_lctl_lgui;
        },

        // GUI disable
        keycode_mod.GU_ON => config.no_gui = false,
        keycode_mod.GU_OFF => config.no_gui = true,
        keycode_mod.GU_TOGG => config.no_gui = !config.no_gui,

        // Grave / Escape
        keycode_mod.GE_SWAP => config.swap_grave_esc = true,
        keycode_mod.GE_NORM => config.swap_grave_esc = false,

        // Backslash / Backspace
        keycode_mod.BS_SWAP => config.swap_backslash_backspace = true,
        keycode_mod.BS_NORM => config.swap_backslash_backspace = false,
        keycode_mod.BS_TOGG => config.swap_backslash_backspace = !config.swap_backslash_backspace,

        // NKRO（切り替え前に clear_keyboard でスタック防止）
        keycode_mod.NK_ON => {
            host.clearKeyboard();
            config.nkro = true;
        },
        keycode_mod.NK_OFF => {
            host.clearKeyboard();
            config.nkro = false;
        },
        keycode_mod.NK_TOGG => {
            host.clearKeyboard();
            config.nkro = !config.nkro;
        },

        // EE_HANDS_LEFT/RIGHT は省略（スプリット判定のハンドシェイク未実装）
        // 通常アクションパイプラインに流さず、ここで消費する
        // C版同様に clearKeyboard() でスタック防止
        keycode_mod.EH_LEFT, keycode_mod.EH_RGHT => {
            host.clearKeyboard();
            return false;
        },

        else => return true,
    }

    // 設定を更新し EEPROM に永続化
    keymap_mod.updateKeymapConfig(config);

    // スタック防止のため clear_keyboard
    host.clearKeyboard();

    return false;
}

/// 状態リセット（テスト用）
pub fn reset() void {
    // Magic モジュール自体は状態を持たない。
    // keymap_config は keymap_mod.keymap_config でリセットされる。
}

// ============================================================
// Tests
// ============================================================

const std = @import("std");
const testing = std.testing;
const eeprom = @import("../hal/eeprom.zig");

fn setupTest() void {
    eeprom.mockReset();
    keymap_mod.keymap_config = .{};
    host.hostReset();
}

test "CL_SWAP: Ctrl/CapsLock スワップを有効化" {
    setupTest();
    try testing.expect(!keymap_mod.keymap_config.swap_control_capslock);
    try testing.expect(!process(keycode_mod.CL_SWAP, true)); // 消費
    try testing.expect(keymap_mod.keymap_config.swap_control_capslock);
}

test "CL_NORM: Ctrl/CapsLock スワップを無効化" {
    setupTest();
    keymap_mod.keymap_config.swap_control_capslock = true;
    _ = process(keycode_mod.CL_NORM, true);
    try testing.expect(!keymap_mod.keymap_config.swap_control_capslock);
}

test "CL_TOGG: Ctrl/CapsLock スワップをトグル" {
    setupTest();
    try testing.expect(!keymap_mod.keymap_config.swap_control_capslock);
    _ = process(keycode_mod.CL_TOGG, true);
    try testing.expect(keymap_mod.keymap_config.swap_control_capslock);
    _ = process(keycode_mod.CL_TOGG, true);
    try testing.expect(!keymap_mod.keymap_config.swap_control_capslock);
}

test "CL_CTRL: CapsLock を Ctrl として使用" {
    setupTest();
    try testing.expect(!keymap_mod.keymap_config.capslock_to_control);
    _ = process(keycode_mod.CL_CTRL, true);
    try testing.expect(keymap_mod.keymap_config.capslock_to_control);
}

test "CL_CAPS: CapsLock を Ctrl として使用を解除" {
    setupTest();
    keymap_mod.keymap_config.capslock_to_control = true;
    _ = process(keycode_mod.CL_CAPS, true);
    try testing.expect(!keymap_mod.keymap_config.capslock_to_control);
}

test "AG_SWAP / AG_NORM: Alt/GUI 両方スワップ/ノーマル" {
    setupTest();
    _ = process(keycode_mod.AG_SWAP, true);
    try testing.expect(keymap_mod.keymap_config.swap_lalt_lgui);
    try testing.expect(keymap_mod.keymap_config.swap_ralt_rgui);
    _ = process(keycode_mod.AG_NORM, true);
    try testing.expect(!keymap_mod.keymap_config.swap_lalt_lgui);
    try testing.expect(!keymap_mod.keymap_config.swap_ralt_rgui);
}

test "AG_TOGG: Alt/GUI スワップをトグル" {
    setupTest();
    _ = process(keycode_mod.AG_TOGG, true);
    try testing.expect(keymap_mod.keymap_config.swap_lalt_lgui);
    try testing.expect(keymap_mod.keymap_config.swap_ralt_rgui);
    _ = process(keycode_mod.AG_TOGG, true);
    try testing.expect(!keymap_mod.keymap_config.swap_lalt_lgui);
    try testing.expect(!keymap_mod.keymap_config.swap_ralt_rgui);
}

test "CG_SWAP / CG_NORM: Ctrl/GUI 両方スワップ/ノーマル" {
    setupTest();
    _ = process(keycode_mod.CG_SWAP, true);
    try testing.expect(keymap_mod.keymap_config.swap_lctl_lgui);
    try testing.expect(keymap_mod.keymap_config.swap_rctl_rgui);
    _ = process(keycode_mod.CG_NORM, true);
    try testing.expect(!keymap_mod.keymap_config.swap_lctl_lgui);
    try testing.expect(!keymap_mod.keymap_config.swap_rctl_rgui);
}

test "CG_TOGG: Ctrl/GUI スワップをトグル" {
    setupTest();
    _ = process(keycode_mod.CG_TOGG, true);
    try testing.expect(keymap_mod.keymap_config.swap_lctl_lgui);
    try testing.expect(keymap_mod.keymap_config.swap_rctl_rgui);
    _ = process(keycode_mod.CG_TOGG, true);
    try testing.expect(!keymap_mod.keymap_config.swap_lctl_lgui);
    try testing.expect(!keymap_mod.keymap_config.swap_rctl_rgui);
}

test "GU_OFF / GU_ON / GU_TOGG: GUI 無効化" {
    setupTest();
    _ = process(keycode_mod.GU_OFF, true);
    try testing.expect(keymap_mod.keymap_config.no_gui);
    _ = process(keycode_mod.GU_ON, true);
    try testing.expect(!keymap_mod.keymap_config.no_gui);
    _ = process(keycode_mod.GU_TOGG, true);
    try testing.expect(keymap_mod.keymap_config.no_gui);
    _ = process(keycode_mod.GU_TOGG, true);
    try testing.expect(!keymap_mod.keymap_config.no_gui);
}

test "GE_SWAP / GE_NORM: Grave/Escape スワップ" {
    setupTest();
    _ = process(keycode_mod.GE_SWAP, true);
    try testing.expect(keymap_mod.keymap_config.swap_grave_esc);
    _ = process(keycode_mod.GE_NORM, true);
    try testing.expect(!keymap_mod.keymap_config.swap_grave_esc);
}

test "BS_SWAP / BS_NORM / BS_TOGG: Backslash/Backspace スワップ" {
    setupTest();
    _ = process(keycode_mod.BS_SWAP, true);
    try testing.expect(keymap_mod.keymap_config.swap_backslash_backspace);
    _ = process(keycode_mod.BS_NORM, true);
    try testing.expect(!keymap_mod.keymap_config.swap_backslash_backspace);
    _ = process(keycode_mod.BS_TOGG, true);
    try testing.expect(keymap_mod.keymap_config.swap_backslash_backspace);
}

test "NK_ON / NK_OFF / NK_TOGG: NKRO 切り替え" {
    setupTest();
    _ = process(keycode_mod.NK_ON, true);
    try testing.expect(keymap_mod.keymap_config.nkro);
    _ = process(keycode_mod.NK_OFF, true);
    try testing.expect(!keymap_mod.keymap_config.nkro);
    _ = process(keycode_mod.NK_TOGG, true);
    try testing.expect(keymap_mod.keymap_config.nkro);
    _ = process(keycode_mod.NK_TOGG, true);
    try testing.expect(!keymap_mod.keymap_config.nkro);
}

test "EC_SWAP / EC_NORM / EC_TOGG: Escape/CapsLock スワップ" {
    setupTest();
    _ = process(keycode_mod.EC_SWAP, true);
    try testing.expect(keymap_mod.keymap_config.swap_escape_capslock);
    _ = process(keycode_mod.EC_NORM, true);
    try testing.expect(!keymap_mod.keymap_config.swap_escape_capslock);
    _ = process(keycode_mod.EC_TOGG, true);
    try testing.expect(keymap_mod.keymap_config.swap_escape_capslock);
}

test "左右個別スワップ: AG_LSWP/AG_LNRM/AG_RSWP/AG_RNRM" {
    setupTest();
    _ = process(keycode_mod.AG_LSWP, true);
    try testing.expect(keymap_mod.keymap_config.swap_lalt_lgui);
    try testing.expect(!keymap_mod.keymap_config.swap_ralt_rgui);
    _ = process(keycode_mod.AG_RSWP, true);
    try testing.expect(keymap_mod.keymap_config.swap_ralt_rgui);
    _ = process(keycode_mod.AG_LNRM, true);
    try testing.expect(!keymap_mod.keymap_config.swap_lalt_lgui);
    _ = process(keycode_mod.AG_RNRM, true);
    try testing.expect(!keymap_mod.keymap_config.swap_ralt_rgui);
}

test "左右個別スワップ: CG_LSWP/CG_LNRM/CG_RSWP/CG_RNRM" {
    setupTest();
    _ = process(keycode_mod.CG_LSWP, true);
    try testing.expect(keymap_mod.keymap_config.swap_lctl_lgui);
    try testing.expect(!keymap_mod.keymap_config.swap_rctl_rgui);
    _ = process(keycode_mod.CG_RSWP, true);
    try testing.expect(keymap_mod.keymap_config.swap_rctl_rgui);
    _ = process(keycode_mod.CG_LNRM, true);
    try testing.expect(!keymap_mod.keymap_config.swap_lctl_lgui);
    _ = process(keycode_mod.CG_RNRM, true);
    try testing.expect(!keymap_mod.keymap_config.swap_rctl_rgui);
}

test "release イベントは無視される" {
    setupTest();
    try testing.expect(process(keycode_mod.CL_SWAP, false)); // release → true (無視)
    try testing.expect(!keymap_mod.keymap_config.swap_control_capslock);
}

test "非 Magic キーコードは無視される" {
    setupTest();
    try testing.expect(process(keycode_mod.KC.A, true)); // 通常キー → true
    try testing.expect(process(0x6FFF, true)); // Magic 範囲外
    try testing.expect(process(0x7100, true)); // Magic 範囲外（上限超え）
}

test "EEPROM 永続化: 設定変更後に EEPROM に書き込まれる" {
    setupTest();
    const eeconfig = @import("eeconfig.zig");
    eeconfig.enable();
    _ = process(keycode_mod.CL_SWAP, true);
    // EEPROM から読み直して一致を確認
    const raw = eeprom.readWord(eeconfig.EECONFIG_KEYMAP_ADDR);
    const saved: KeymapConfig = @bitCast(raw);
    try testing.expect(saved.swap_control_capslock);
}
