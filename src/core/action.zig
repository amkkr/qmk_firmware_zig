// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later
//
// Zig port of quantum/action.c
// Original: Copyright 2012,2013 Jun Wako <wakojun@gmail.com>

//! アクション処理の中核
//! C版 quantum/action.c に相当
//!
//! キーイベントをアクションに変換し、実行する。
//! - 基本キー、修飾キー
//! - Mod-Tap（ホールドで修飾、タップでキー）
//! - Layer-Tap（ホールドでレイヤー、タップでキー）
//! - レイヤー切替（MO, TO, TG, DF）

const action_code = @import("action_code.zig");
const event_mod = @import("event.zig");
const keycode_mod = @import("keycode.zig");
const layer = @import("layer.zig");
pub const host = @import("host.zig");
const tapping = @import("action_tapping.zig");
const extrakey = @import("extrakey.zig");
const mousekey = @import("mousekey.zig");
const auto_shift = @import("auto_shift.zig");
const keymap_mod = @import("keymap.zig");
const report_mod = @import("report.zig");
pub const swap_hands = @import("swap_hands.zig");
const caps_word = @import("caps_word.zig");
const repeat_key = @import("repeat_key.zig");
const layer_lock = @import("layer_lock.zig");
const key_lock = @import("key_lock.zig");
const grave_esc = @import("grave_esc.zig");

const Action = action_code.Action;
const ActionKind = action_code.ActionKind;
const KeyRecord = event_mod.KeyRecord;
const KeyEvent = event_mod.KeyEvent;

/// Action resolver callback type
/// Given a KeyEvent, return the action code to execute.
pub const ActionResolver = *const fn (event: KeyEvent) Action;

var action_resolver: ?ActionResolver = null;

/// 直前に解決されたキーコード（Key Lock 用）
/// keyboard.zig の keymapActionResolver から設定され、processRecord で参照される。
var last_resolved_keycode: keycode_mod.Keycode = 0;

/// RETRO_TAPPING: 最後に押されたキーの位置
var retro_tap_curr_key: event_mod.KeyPos = .{ .row = 0, .col = 0 };
/// RETRO_TAPPING: 最後に押されたキーがそのまま離されたか（他キー割り込みなし）
var retro_tap_primed: bool = false;

/// ONESHOT_TAP_TOGGLE: OSM/OSL をロックするために必要なタップ回数
/// C版 action.c の ONESHOT_TAP_TOGGLE に相当
/// 0 の場合はタップトグル無効
pub var oneshot_tap_toggle: u8 = 0;

pub fn setActionResolver(resolver: ActionResolver) void {
    action_resolver = resolver;
}

pub fn getActionResolver() ?ActionResolver {
    return action_resolver;
}

/// キーコード解決時に呼ばれるセッター（keyboard.zig から使用）
pub fn setLastResolvedKeycode(kc: keycode_mod.Keycode) void {
    last_resolved_keycode = kc;
}

fn resolveAction(event: KeyEvent) Action {
    if (action_resolver) |resolver| {
        return resolver(event);
    }
    return .{ .code = action_code.ACTION_NO };
}

/// Layer tap operations (encoded in the key.code field)
const OP_TAP_TOGGLE: u8 = 0xF0;
const OP_ON_OFF: u8 = 0xF1;
const OP_OFF_ON: u8 = 0xF2;
const OP_SET_CLEAR: u8 = 0xF3;
const OP_ONESHOT: u8 = 0xF4;

/// Tap Toggle のトグルに必要なタップ回数（C版 TAPPING_TOGGLE=5 に対応）
pub const TAPPING_TOGGLE: u8 = 5;

/// Main entry point: execute action for a key event
pub fn actionExec(record: *KeyRecord) void {
    // ONESHOT_TIMEOUT: タイムアウトチェック
    // C版 action_exec() 冒頭の ONESHOT_TIMEOUT チェックに相当
    if (host.oneshot_timeout > 0) {
        if (host.hasOneshotModsTimedOut()) {
            host.clearOneshotMods();
            host.sendKeyboardReport();
        }
        if (host.hasOneshotLayerTimedOut()) {
            host.clearOneshotLayerState(host.OneshotState.PRESSED | host.OneshotState.OTHER_KEY_PRESSED);
        }
    }

    // RETRO_TAPPING: 生のキーイベントに基づいて retro_tap_primed を追跡する。
    // C版 action_exec() 冒頭の retro_tap_curr_key / retro_tap_primed 更新に相当。
    if (tapping.retro_tapping and !record.event.isTick()) {
        const ev = record.event;
        if (ev.pressed) {
            retro_tap_primed = false;
            retro_tap_curr_key = ev.key;
        } else if (ev.key.row == retro_tap_curr_key.row and ev.key.col == retro_tap_curr_key.col) {
            retro_tap_primed = true;
        }
    }
    tapping.actionTappingProcess(record);
}

/// Process a record through action resolution and execution
/// C版 process_record_quantum() と同様に、Key Lock をアクション実行前にチェックする。
pub fn processRecord(keyp: *KeyRecord) void {
    const act = resolveAction(keyp.event);

    // Key Lock: アクション実行前にキーコードを検査
    // C版 quantum.c の process_key_lock(&keycode, record) に相当
    var kc = last_resolved_keycode;
    if (!key_lock.processKeyLock(&kc, keyp.event.pressed)) {
        return;
    }

    processAction(keyp, act);
}

/// Determine if a record has a tap action (mod-tap or layer-tap with a tap keycode)
pub fn isTapRecord(keyp: *const KeyRecord) bool {
    const act = resolveAction(keyp.event);
    return isTapAction(act);
}

/// Check if an action is a tap-type action
pub fn isTapAction(act: Action) bool {
    const kind = act.kind.id;
    switch (kind) {
        .mods_tap, .rmods_tap => {
            const code = act.key.code;
            // MODS_ONESHOT (0x00) はタップアクション（C版 is_tap_action 互換）
            if (code == action_code.MODS_ONESHOT) return true;
            // MODS_TAP_TOGGLE (0x01) もタップアクション
            if (code == action_code.MODS_TAP_TOGGLE) return true;
            // Tap action if there's a tap keycode
            return code != 0;
        },
        .layer_tap, .layer_tap_ext => {
            const code = act.key.code;
            // OSL (OP_ONESHOT) はタップアクション（C版 is_tap_action 互換）
            if (code == OP_ONESHOT) return true;
            // Regular layer-tap key (not special operation)
            return code != 0 and code < OP_TAP_TOGGLE;
        },
        .swap_hands => {
            const code = act.key.code;
            // SH_T(kc): C版と同様 KC_NO(0x00)〜KC_RIGHT_GUI(0xE7) がタップアクション
            // C版では OP_SH_TAP_TOGGLE(0xF1) は default フォールスルーで code <= 0xE7 評価され false
            // 特殊操作コード (0xF0-0xF6) はタップアクションではない
            return code != 0 and code <= 0xE7;
        },
        else => return false,
    }
}

/// タッピング判定中に修飾キー/レイヤーキーのリリースを遅延すべきか判定する。
/// C版 process_tapping() の "Modifier/Layer should be retained till end of this tapping" ロジックに相当。
/// tap_count: リリースされるキーの tap.count（keyp->tap.count）
pub fn shouldRetainReleaseDuringTapping(event: KeyEvent, tap_count: u8) bool {
    const act = resolveAction(event);
    const kind = act.kind.id;
    switch (kind) {
        .mods, .rmods => {
            if (act.key.mods != 0 and act.key.code == 0) return true;
            if (act.key.code >= 0xE0 and act.key.code <= 0xE7) return true;
        },
        .mods_tap, .rmods_tap => {
            if (act.key.mods != 0 and tap_count == 0) return true;
            if (act.key.code >= 0xE0 and act.key.code <= 0xE7) return true;
        },
        .layer_tap, .layer_tap_ext => {
            const code = act.layer_tap.code;
            if (code < OP_TAP_TOGGLE) return true;
            // C版 (action_tapping.c:430): tap_count == 0 の時は break → 保持
            if (code == OP_TAP_TOGGLE and tap_count == 0) return true;
            if (code == OP_ON_OFF or code == OP_OFF_ON or code == OP_SET_CLEAR) return true;
        },
        else => {},
    }
    return false;
}

/// Execute an action based on its kind
pub fn processAction(keyp: *KeyRecord, act: Action) void {
    if (act.code == action_code.ACTION_NO or act.code == action_code.ACTION_TRANSPARENT) return;

    const ev = keyp.event;
    const kind = act.kind.id;

    // One-Shot Swap Hands チェック: swap_hands 以外のキーイベントで解除判定
    // processSpecialAction の前に配置し、early return でスキップされないようにする
    if (kind != .swap_hands) {
        swap_hands.oneshotCheck(ev.pressed);
    }

    // 特殊アクション（Caps Word, Repeat Key, Layer Lock, Grave Escape）の処理
    if (processSpecialAction(ev, act)) return;

    // ---- do_release_oneshot 前処理（C版 process_action の先頭ロジック） ----
    // OSL がアクティブで、修飾キー以外のキーが押された場合、
    // OTHER_KEY_PRESSED フラグをクリアして OSL 解除準備をする
    var do_release_oneshot = false;
    if (host.isOneshotLayerActive() and ev.pressed and keymap_mod.keymap_config.oneshot_enable) {
        const is_modifier_action = blk: {
            if (kind == .mods or kind == .rmods) {
                // C版 IS_MODIFIER_KEYCODE(action.key.code) と等価
                break :blk report_mod.isModifierKeycode(act.key.code);
            }
            if (kind == .mods_tap or kind == .rmods_tap) {
                // mod-tap のホールド状態（tap.count==0）またはOSM/TAP_TOGGLE
                break :blk act.layer_tap.code <= action_code.MODS_TAP_TOGGLE or keyp.tap.count == 0;
            }
            break :blk false;
        };
        if (kind == .usage or !is_modifier_action) {
            host.clearOneshotLayerState(host.OneshotState.OTHER_KEY_PRESSED);
            do_release_oneshot = !host.isOneshotLayerActive();
        }
    }

    // Caps Word 処理: 基本キーアクション（mods/rmods）の場合、
    // キー押下時に Caps Word のフィルタリングを適用
    if (caps_word.isActive()) {
        if (kind == .mods or kind == .rmods) {
            const kc = act.key.code;
            _ = caps_word.process(kc, ev.pressed);
        }
    }

    switch (kind) {
        .mods, .rmods => processModsAction(ev, act),
        .mods_tap, .rmods_tap => processModsTapAction(keyp, act),
        .usage => extrakey.processUsageAction(ev, act.code),
        .mousekey => processMousekeyAction(ev, act),
        .layer => processLayerAction(ev, act),
        .layer_mods => processLayerModsAction(ev, act),
        .layer_tap, .layer_tap_ext => processLayerTapAction(keyp, act),
        .swap_hands => swap_hands.processSwapHandsAction(keyp, act),
        else => {
            if (@import("builtin").is_test) {
                @import("std").log.warn("unhandled action kind: {}", .{@intFromEnum(kind)});
            }
        },
    }

    // C版 action.c:830-847: layer アクション後は do_release_oneshot をクリア
    // layer_tap/layer_tap_ext の処理中に OSL 解除が起きないようにする
    switch (kind) {
        .layer, .layer_mods, .layer_tap, .layer_tap_ext => do_release_oneshot = false,
        else => {},
    }

    // ---- do_release_oneshot 後処理（C版 process_action の末尾ロジック） ----
    // OSL が解除されるべき場合、キーを一時的にリリースしてからレイヤーをオフにする
    if (do_release_oneshot and (host.getOneshotLayerState() & host.OneshotState.PRESSED) == 0) {
        const osl_layer = host.getOneshotLayer();
        keyp.event.pressed = false;
        layer.layerOn(osl_layer);
        processRecord(keyp);
        layer.layerOff(osl_layer);
    }
}

/// Process mousekey actions (ACT_MOUSEKEY)
/// C版 register_mouse() に相当。
fn processMousekeyAction(ev: KeyEvent, act: Action) void {
    const code: keycode_mod.Keycode = act.key.code;
    if (ev.pressed) {
        mousekey.on(code);
    } else {
        mousekey.off(code);
    }
    mousekey.send();
}

/// 特殊アクション（Caps Word, Repeat Key, Layer Lock, Grave Escape）の処理
/// 処理した場合は true を返す
fn processSpecialAction(ev: KeyEvent, act: Action) bool {
    switch (act.code) {
        action_code.ACTION_CAPS_WORD_TOGGLE => {
            if (ev.pressed) {
                caps_word.toggle();
            }
            return true;
        },
        action_code.ACTION_REPEAT_KEY => {
            // C版同様: Repeat Key は Caps Word の許可リストに含まれないため解除
            if (ev.pressed and caps_word.isActive()) caps_word.deactivate();
            repeat_key.processRepeatKey(ev.pressed);
            return true;
        },
        action_code.ACTION_ALT_REPEAT_KEY => {
            // C版同様: Alt Repeat Key は Caps Word の許可リストに含まれないため解除
            if (ev.pressed and caps_word.isActive()) caps_word.deactivate();
            repeat_key.processAltRepeatKey(ev.pressed);
            return true;
        },
        action_code.ACTION_LAYER_LOCK => {
            // C版同様: Layer Lock は Caps Word の許可リストに含まれないため解除
            if (ev.pressed and caps_word.isActive()) caps_word.deactivate();
            layer_lock.processLayerLock(ev.pressed);
            return true;
        },
        action_code.ACTION_GRAVE_ESCAPE => {
            grave_esc.processGraveEsc(ev.pressed);
            return true;
        },
        else => return false,
    }
}

/// Process basic modifier actions (hold for mod, with optional key)
/// keycodeConfig / modConfig を適用してスワップ設定を反映する。
/// C版 keymap_common.c では ACTION_MODS_KEY 生成時に mod_config() / keycode_config() の両方が適用される。
fn processModsAction(ev: KeyEvent, act: Action) void {
    const mods = act.key.mods;
    const kc = keymap_mod.keycodeConfig(act.key.code);
    const mods5 = modFourBitToFiveBit(mods, act.kind.id == .rmods);
    const mods_hid = keymap_mod.modConfig(host.modFiveBitToEightBit(mods5));

    // Auto Shift: 修飾なしの基本キーで、Auto Shift 対象の場合は委譲
    if (mods_hid == 0 and kc != 0) {
        if (auto_shift.processAutoShift(@as(u16, kc), ev.pressed, ev.time)) {
            return;
        }
    }

    if (ev.pressed) {
        // Repeat Key: addMods 前のモッド状態を保存（Modified keycode 由来のモッドを除外するため）
        const pre_mods = host.getMods() | host.getWeakMods();
        if (mods_hid != 0) host.addMods(mods_hid);
        if (kc != 0) {
            host.registerCode(kc);
            // Repeat Key 用に直前のキーを記録
            // Modified keycode の場合は act.code の上位8bit（modビット）を保持しつつ、
            // 下位8bitを keycodeConfig 適用済みの kc で置き換える。
            const repeat_kc: keycode_mod.Keycode = if (mods_hid != 0)
                (act.code & 0xFF00) | @as(keycode_mod.Keycode, kc)
            else
                @as(keycode_mod.Keycode, kc);
            repeat_key.setLastKeycode(repeat_kc, pre_mods);
        }
        host.sendKeyboardReport();
    } else {
        if (kc != 0) host.unregisterCode(kc);
        if (mods_hid != 0) host.delMods(mods_hid);
        host.sendKeyboardReport();
    }
}

/// Process mod-tap actions (hold for modifier, tap for keycode)
fn processModsTapAction(keyp: *KeyRecord, act: Action) void {
    const ev = keyp.event;
    const mods = act.key.mods;
    const kc = act.key.code;
    const is_right = act.kind.id == .rmods_tap;
    const mods5 = modFourBitToFiveBit(mods, is_right);
    // C版 mod_config() に相当: modConfig を全ケースに適用（processModsAction と対称）
    const mods_hid = keymap_mod.modConfig(host.modFiveBitToEightBit(mods5));

    switch (kc) {
        action_code.MODS_ONESHOT => {
            // One-Shot Modifier (OSM) の場合は専用処理
            // C版と同様に modConfig 適用済みの8ビットHID形式を渡す
            processOneShotModsAction(keyp, mods_hid);
            return;
        },
        action_code.MODS_TAP_TOGGLE => {
            // MODS_TAP_TOGGLE: タップ TAPPING_TOGGLE 回でモッド固定
            // C版 quantum/action.c の MODS_TAP_TOGGLE 処理に相当
            if (ev.pressed) {
                if (keyp.tap.count <= TAPPING_TOGGLE) {
                    host.addMods(mods_hid);
                    host.sendKeyboardReport();
                }
            } else {
                if (keyp.tap.count < TAPPING_TOGGLE) {
                    host.delMods(mods_hid);
                    host.sendKeyboardReport();
                }
            }
        },
        else => {
            // 通常のmod-tap: ホールドでmod、タップでキー
            const configured_kc = keymap_mod.keycodeConfig(kc);
            if (ev.pressed) {
                if (keyp.tap.count > 0) {
                    // Tapped: register the tap keycode
                    if (configured_kc != 0) {
                        // Caps Word: タップキーにも Shift を適用
                        if (caps_word.isActive()) {
                            _ = caps_word.process(kc, true);
                        }
                        host.registerCode(configured_kc);
                        // Repeat Key: タップキーも記録（weak_mods も含める：Caps Word の LSHIFT 等）
                        repeat_key.setLastKeycode(@as(keycode_mod.Keycode, configured_kc), host.getMods() | host.getWeakMods());
                        host.sendKeyboardReport();
                    }
                } else {
                    // Held: register modifier
                    if (mods_hid != 0) {
                        host.addMods(mods_hid);
                        host.sendKeyboardReport();
                    }
                }
            } else {
                if (keyp.tap.count > 0) {
                    // Release tap
                    if (configured_kc != 0) {
                        if (caps_word.isActive()) {
                            _ = caps_word.process(kc, false);
                        }
                        host.unregisterCode(configured_kc);
                        host.sendKeyboardReport();
                    }
                } else {
                    // Release hold
                    if (mods_hid != 0) {
                        host.delMods(mods_hid);
                        host.sendKeyboardReport();
                    }
                    // RETRO_TAPPING: ホールド後リリース時に他キー割り込みがなければタップキーも送信
                    if (tapping.retro_tapping and retro_tap_primed and
                        retro_tap_curr_key.row == keyp.event.key.row and
                        retro_tap_curr_key.col == keyp.event.key.col)
                    {
                        retro_tap_primed = false;
                        const retro_kc = keymap_mod.keycodeConfig(kc);
                        if (retro_kc != 0) {
                            host.registerCode(retro_kc);
                            host.sendKeyboardReport();
                            host.unregisterCode(retro_kc);
                            host.sendKeyboardReport();
                        }
                    }
                }
            }
        },
    }
}

/// One-Shot Modifier (OSM) のアクション処理
/// C版 quantum/action.c の ACT_MODS_TAP/MODS_ONESHOT 処理に相当
///
/// タップ時: addOneshotMods(mods_hid) で OSM を設定
///   → 次のキー入力時に sendKeyboardReport() で一時的に適用されクリアされる
/// ホールド時: 通常の修飾キーとして動作（addMods/delMods）
///
/// 注意: mods_hid は modConfig 適用済みの8ビットHID形式。
/// 呼び出し元（processModsTapAction）で modFiveBitToEightBit + modConfig を適用済み。
fn processOneShotModsAction(keyp: *KeyRecord, mods_hid: u8) void {
    const ev = keyp.event;

    // C版互換: oneshot_enable が false の場合、通常の修飾キーとして動作
    if (!keymap_mod.keymap_config.oneshot_enable) {
        if (ev.pressed) {
            host.addMods(mods_hid);
        } else {
            host.delMods(mods_hid);
        }
        host.sendKeyboardReport();
        return;
    }

    if (ev.pressed) {
        if (keyp.tap.count > 0) {
            // ONESHOT_TAP_TOGGLE: タップ回数がしきい値に達したらロック
            // C版 action.c の ONESHOT_TAP_TOGGLE 処理に相当
            if (oneshot_tap_toggle > 0 and keyp.tap.count == oneshot_tap_toggle and !keyp.tap.interrupted) {
                host.addOneshotLockedMods(mods_hid);
                host.sendKeyboardReport();
            } else if (keyp.tap.count == 1) {
                // タップ: One-Shot Mods を設定（8ビットHIDmod形式で格納）
                // C版互換: OSM設定時はレポートを送信しない（次キー押下時に適用）
                host.addOneshotMods(mods_hid);
            } else {
                // 複数タップ: 通常のmod toggle として扱う（C版互換）
                host.addMods(mods_hid);
                host.sendKeyboardReport();
            }
        } else {
            // ホールド: 通常の修飾キーとして登録
            host.addMods(mods_hid);
            host.sendKeyboardReport();
        }
    } else {
        if (keyp.tap.count > 0) {
            // タップリリース: OSMは次キーまで保持（レポート送信不要）
            if (oneshot_tap_toggle > 0 and keyp.tap.count == oneshot_tap_toggle and !keyp.tap.interrupted) {
                // タップトグルでロック: リリース時は何もしない
            } else if (keyp.tap.count > 1) {
                host.delMods(mods_hid);
                host.sendKeyboardReport();
            }
        } else {
            // ホールドリリース: 修飾キーを解除
            host.delMods(mods_hid);
            host.sendKeyboardReport();
        }
    }
}

/// Process layer switch actions (ACT_LAYER)
///
/// C版ではACT_LAYERのparamはlayer_bitop構造体で解釈される:
///   bits[3:0]=bits, bit[4]=xbit, bits[7:5]=part, bits[9:8]=on, bits[11:10]=op
///
/// on==0 の場合はデフォルトレイヤー操作（リリース時に実行）
/// on!=0 の場合はレイヤーstate操作（ON_PRESS/ON_RELEASE/ON_BOTHに基づく）
fn processLayerAction(ev: KeyEvent, act: Action) void {
    const bitop = act.layer_bitop;
    const shift: u5 = @as(u5, bitop.part) * 4;
    const bits: layer.LayerState = @as(layer.LayerState, bitop.bits) << shift;
    const mask: layer.LayerState = if (bitop.xbit != 0) ~(@as(layer.LayerState, 0xf) << shift) else 0;

    if (bitop.on == 0) {
        // Default Layer Bitwise Operation (on release)
        if (!ev.pressed) {
            switch (bitop.op) {
                action_code.OP_BIT_AND => layer.defaultLayerAnd(bits | mask),
                action_code.OP_BIT_OR => layer.defaultLayerOr(bits | mask),
                action_code.OP_BIT_XOR => layer.defaultLayerXor(bits | mask),
                action_code.OP_BIT_SET => layer.defaultLayerSet(bits | mask),
            }
        }
    } else {
        // Layer Bitwise Operation
        const should_act = if (ev.pressed) (bitop.on & action_code.ON_PRESS != 0) else (bitop.on & action_code.ON_RELEASE != 0);
        if (should_act) {
            switch (bitop.op) {
                action_code.OP_BIT_AND => layer.layerAnd(bits | mask),
                action_code.OP_BIT_OR => layer.layerOr(bits | mask),
                action_code.OP_BIT_XOR => layer.layerXor(bits | mask),
                action_code.OP_BIT_SET => layer.layerStateSet(bits | mask),
            }
        }
    }
}

/// Process layer + modifier actions
/// layer_mods の mods フィールドは8ビットHIDフォーマットで格納されているため、
/// 5ビット変換不要の addMods/delMods を使用する（C版 register_mods/unregister_mods 相当）。
/// keymap_config によるモッドスワップも適用する（C版 mod_config() 相当）。
fn processLayerModsAction(ev: KeyEvent, act: Action) void {
    const l: u5 = act.layer_mods.layer;
    const mods = keymap_mod.modConfig(act.layer_mods.mods);

    if (ev.pressed) {
        layer.layerOn(l);
        host.addMods(mods);
        host.sendKeyboardReport();
    } else {
        // Layer Lock でロック中のレイヤーは layerOff/delMods をスキップ
        if (!layer_lock.isLayerLocked(l)) {
            host.delMods(mods);
            layer.layerOff(l);
        }
        host.sendKeyboardReport();
    }
}

/// Process layer-tap actions (hold for layer, tap for keycode)
fn processLayerTapAction(keyp: *KeyRecord, act: Action) void {
    const ev = keyp.event;
    const code = act.key.code;

    // Calculate layer from val field
    const l: u5 = @truncate(act.layer_tap.val);

    if (code >= OP_TAP_TOGGLE) {
        // Special layer operations
        processLayerTapSpecial(keyp, l, code);
        return;
    }

    // Regular layer-tap: hold=layer, tap=keycode
    const configured_code = keymap_mod.keycodeConfig(code);
    if (ev.pressed) {
        if (keyp.tap.count > 0) {
            // Tapped: register the tap keycode
            if (configured_code != 0) {
                // Caps Word: タップキーにも Shift を適用
                if (caps_word.isActive()) {
                    _ = caps_word.process(code, true);
                }
                host.registerCode(configured_code);
                // Repeat Key: タップキーも記録（weak_mods も含める：Caps Word の LSHIFT 等）
                repeat_key.setLastKeycode(@as(keycode_mod.Keycode, configured_code), host.getMods() | host.getWeakMods());
                host.sendKeyboardReport();
            }
        } else {
            // Held: activate layer
            layer.layerOn(l);
        }
    } else {
        if (keyp.tap.count > 0) {
            // Release tap
            if (configured_code != 0) {
                if (caps_word.isActive()) {
                    _ = caps_word.process(code, false);
                }
                host.unregisterCode(configured_code);
                host.sendKeyboardReport();
            }
        } else {
            // Release hold
            // Layer Lock でロック中のレイヤーは layerOff をスキップ
            if (!layer_lock.isLayerLocked(l)) {
                layer.layerOff(l);
            }
            // RETRO_TAPPING: ホールド後リリース時に他キー割り込みがなければタップキーも送信
            if (tapping.retro_tapping and retro_tap_primed and
                retro_tap_curr_key.row == keyp.event.key.row and
                retro_tap_curr_key.col == keyp.event.key.col)
            {
                retro_tap_primed = false;
                const retro_code = keymap_mod.keycodeConfig(code);
                if (retro_code != 0) {
                    host.registerCode(retro_code);
                    host.sendKeyboardReport();
                    host.unregisterCode(retro_code);
                    host.sendKeyboardReport();
                }
            }
        }
    }
}

/// Process special layer tap operations (MO, TG, TO, TT, OSL, etc.)
/// C版 quantum/action.c の ACT_LAYER_TAP switch 処理に相当。
fn processLayerTapSpecial(keyp: *KeyRecord, l: u5, code: u8) void {
    const ev = keyp.event;
    const tap_count = keyp.tap.count;
    switch (code) {
        OP_TAP_TOGGLE => {
            // Layer tap toggle (TT)
            // C版: press 時 tap_count < TAPPING_TOGGLE なら layer_invert
            //       release 時 tap_count <= TAPPING_TOGGLE なら layer_invert
            // → tap_count == TAPPING_TOGGLE: pressでinvertなし、releaseでinvertあり（ラッチON）
            // → tap_count > TAPPING_TOGGLE: press/releaseともinvertなし（固定）
            if (ev.pressed) {
                if (tap_count < TAPPING_TOGGLE) {
                    layer.layerInvert(l);
                }
            } else {
                if (tap_count <= TAPPING_TOGGLE) {
                    layer.layerInvert(l);
                }
            }
        },
        OP_ON_OFF => {
            // Momentary layer (MO)
            if (ev.pressed) {
                layer.layerOn(l);
            } else {
                // Layer Lock でロック中のレイヤーは layerOff をスキップ
                if (!layer_lock.isLayerLocked(l)) {
                    layer.layerOff(l);
                }
            }
        },
        OP_OFF_ON => {
            if (ev.pressed) {
                layer.layerOff(l);
            } else {
                layer.layerOn(l);
            }
        },
        OP_SET_CLEAR => {
            // TO
            if (ev.pressed) {
                layer.layerMove(l);
            }
        },
        OP_ONESHOT => {
            // One-Shot Layer (OSL)
            // no_action_tapping=true の場合、keycodeToAction で OSL は
            // ACTION_LAYER_MOMENTARY (OP_ON_OFF) に変換されるため、
            // OP_ONESHOT に到達する時点で常に oneshot 動作が有効
            processOneShotLayerAction(keyp, l);
        },
        else => {},
    }
}

/// One-Shot Layer (OSL) のアクション処理
/// C版 quantum/action.c の ACT_LAYER_TAP/OP_ONESHOT 処理に相当
///
/// C版互換: tap_count に関わらず常に oneshot 挙動を行う。
/// 押下時: setOneshotLayer(l, START) でレイヤーを有効化
///   → 次のキー入力時に do_release_oneshot ロジックでレイヤーが解除される
/// リリース時: clearOneshotLayerState(PRESSED) でフラグをクリア
///   → tap_count > 1 の場合は OTHER_KEY_PRESSED もクリア（即時解除）
fn processOneShotLayerAction(keyp: *KeyRecord, l: u5) void {
    const ev = keyp.event;

    // oneshot_enable が false の場合、通常の MO() として動作
    if (!keymap_mod.keymap_config.oneshot_enable) {
        if (ev.pressed) {
            layer.layerOn(l);
        } else {
            layer.layerOff(l);
        }
        return;
    }

    if (ev.pressed) {
        // ONESHOT_TAP_TOGGLE: タップ回数がしきい値に達したらトグル
        // C版 action.c の ONESHOT_TAP_TOGGLE 処理に相当
        if (oneshot_tap_toggle > 0 and keyp.tap.count == oneshot_tap_toggle and !keyp.tap.interrupted) {
            // TOGGLED 状態: レイヤーをロック（タイムアウトしない）
            host.setOneshotLayer(l, host.OneshotState.TOGGLED);
        } else {
            host.setOneshotLayer(l, host.OneshotState.START);
        }
    } else {
        if (oneshot_tap_toggle > 0 and keyp.tap.count == oneshot_tap_toggle and !keyp.tap.interrupted) {
            // TOGGLED リリース: 何もしない（レイヤーはロックされたまま）
        } else {
            host.clearOneshotLayerState(host.OneshotState.PRESSED);
            if (keyp.tap.count > 1) {
                host.clearOneshotLayerState(host.OneshotState.OTHER_KEY_PRESSED);
            }
        }
    }
}

/// Convert 4-bit modifier field to 5-bit encoding (adds right-modifier flag)
fn modFourBitToFiveBit(mods4: u4, is_right: bool) u8 {
    var result: u8 = @as(u8, mods4);
    if (is_right) result |= 0x10;
    return result;
}

pub fn reset() void {
    host.hostReset();
    layer.resetState();
    tapping.reset();
    tapping.permissive_hold = false;
    tapping.hold_on_other_key_press = false;
    tapping.retro_tapping = false;
    retro_tap_primed = false;
    retro_tap_curr_key = .{ .row = 0, .col = 0 };
    oneshot_tap_toggle = 0;
    auto_shift.reset();
    keymap_mod.keymap_config = .{};
    swap_hands.reset();
    key_lock.reset();
}

// ============================================================
// Tests
// ============================================================

const testing = @import("std").testing;

const MockDriver = @import("test_driver.zig").FixedTestDriver(32, 4);

fn testResolver(ev: KeyEvent) Action {
    _ = ev;
    return .{ .code = action_code.ACTION_KEY(0x04) }; // KC_A
}

test "basic key action" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();
    setActionResolver(testResolver);

    // Press key -> should register KC_A
    var record = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processAction(&record, .{ .code = action_code.ACTION_KEY(0x04) });
    try testing.expect(mock.lastKeyboardReport().hasKey(0x04));

    // Release key -> should unregister KC_A
    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 200) };
    processAction(&release, .{ .code = action_code.ACTION_KEY(0x04) });
    try testing.expect(!mock.lastKeyboardReport().hasKey(0x04));
}

test "mod-tap hold" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // SFT_T(KC_A): mods_tap, mods=0x2 (LSFT), code=0x04 (KC_A)
    const act = Action{ .code = action_code.ACTION_MODS_TAP_KEY(0x02, 0x04) };

    // Hold (tap.count == 0) -> register modifier
    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processAction(&press, act);
    try testing.expectEqual(@as(u8, 0x02), mock.lastKeyboardReport().mods); // LSHIFT

    // Release hold
    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 400) };
    processAction(&release, act);
    try testing.expectEqual(@as(u8, 0x00), mock.lastKeyboardReport().mods);
}

test "mod-tap tap" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    const act = Action{ .code = action_code.ACTION_MODS_TAP_KEY(0x02, 0x04) };

    // Tap (tap.count > 0) -> register key
    var press = KeyRecord{
        .event = KeyEvent.keyPress(0, 0, 100),
        .tap = .{ .count = 1 },
    };
    processAction(&press, act);
    try testing.expect(mock.lastKeyboardReport().hasKey(0x04));
    try testing.expectEqual(@as(u8, 0x00), mock.lastKeyboardReport().mods);

    // Release tap
    var release = KeyRecord{
        .event = KeyEvent.keyRelease(0, 0, 150),
        .tap = .{ .count = 1 },
    };
    processAction(&release, act);
    try testing.expect(!mock.lastKeyboardReport().hasKey(0x04));
}

test "layer-tap hold" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // LT(1, KC_A): layer_tap, layer=1, code=0x04
    const act = Action{ .code = action_code.ACTION_LAYER_TAP_KEY(1, 0x04) };

    // Hold -> activate layer
    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processAction(&press, act);
    try testing.expect(layer.layerStateIs(1));

    // Release -> deactivate layer
    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 400) };
    processAction(&release, act);
    try testing.expect(!layer.layerStateIs(1));
}

test "layer-tap tap" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    const act = Action{ .code = action_code.ACTION_LAYER_TAP_KEY(1, 0x04) };

    // Tap -> register key
    var press = KeyRecord{
        .event = KeyEvent.keyPress(0, 0, 100),
        .tap = .{ .count = 1 },
    };
    processAction(&press, act);
    try testing.expect(mock.lastKeyboardReport().hasKey(0x04));
    try testing.expect(!layer.layerStateIs(1));

    // Release tap
    var release = KeyRecord{
        .event = KeyEvent.keyRelease(0, 0, 150),
        .tap = .{ .count = 1 },
    };
    processAction(&release, act);
    try testing.expect(!mock.lastKeyboardReport().hasKey(0x04));
}

test "MO layer action" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // MO(1): ACTION_LAYER_MOMENTARY(1) = layer_tap with OP_ON_OFF
    const act = Action{ .code = action_code.ACTION_LAYER_MOMENTARY(1) };

    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processAction(&press, act);
    try testing.expect(layer.layerStateIs(1));

    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 400) };
    processAction(&release, act);
    try testing.expect(!layer.layerStateIs(1));
}

test "isTapAction" {
    // mod-tap with keycode
    try testing.expect(isTapAction(.{ .code = action_code.ACTION_MODS_TAP_KEY(0x02, 0x04) }));
    // layer-tap with keycode
    try testing.expect(isTapAction(.{ .code = action_code.ACTION_LAYER_TAP_KEY(1, 0x04) }));
    // basic key
    try testing.expect(!isTapAction(.{ .code = action_code.ACTION_KEY(0x04) }));
    // MO (layer-tap with code=0)
    try testing.expect(!isTapAction(.{ .code = action_code.ACTION_LAYER_MOMENTARY(1) }));
    // OSM (MODS_ONESHOT) はタップアクション
    try testing.expect(isTapAction(.{ .code = action_code.ACTION_MODS_ONESHOT(0x01) }));
    // MODS_TAP_TOGGLE もタップアクション
    try testing.expect(isTapAction(.{ .code = action_code.ACTION_MODS_TAP_TOGGLE(0x02) }));
}

test "layer bitwise OP_BIT_OR on press" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // ACTION_LAYER_BITOP(OP_BIT_OR, part=0, bits=0b00010, ON_PRESS)
    const act = Action{ .code = action_code.ACTION_LAYER_BITOP(action_code.OP_BIT_OR, 0, 0b00010, action_code.ON_PRESS) };

    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processAction(&press, act);
    try testing.expect(layer.layerStateIs(1));

    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 200) };
    processAction(&release, act);
    try testing.expect(layer.layerStateIs(1));
}

test "layer bitwise OP_BIT_XOR on release (TG equivalent)" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // ACTION_LAYER_TOGGLE(1) = ACTION_LAYER_BITOP(OP_BIT_XOR, 0, 0b00010, ON_RELEASE)
    const act = Action{ .code = action_code.ACTION_LAYER_TOGGLE(1) };

    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processAction(&press, act);
    try testing.expect(!layer.layerStateIs(1));

    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 200) };
    processAction(&release, act);
    try testing.expect(layer.layerStateIs(1));

    var press2 = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 300) };
    processAction(&press2, act);
    try testing.expect(layer.layerStateIs(1));

    var release2 = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 400) };
    processAction(&release2, act);
    try testing.expect(!layer.layerStateIs(1));
}

test "layer bitwise OP_BIT_SET on press (TO equivalent)" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    layer.layerOn(1);
    layer.layerOn(3);

    // ACTION_LAYER_GOTO(2) = ACTION_LAYER_BITOP(OP_BIT_SET, 0, 0b00100, ON_PRESS)
    const act = Action{ .code = action_code.ACTION_LAYER_GOTO(2) };

    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processAction(&press, act);
    try testing.expect(layer.layerStateIs(2));
    try testing.expect(!layer.layerStateIs(1));
    try testing.expect(!layer.layerStateIs(3));
}

test "layer bitwise OP_BIT_AND" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    layer.layerOn(0);
    layer.layerOn(1);
    layer.layerOn(2);

    // AND with bits=0b0011 (part=0, ON_PRESS): layer_state &= 0b0011
    const act = Action{ .code = action_code.ACTION_LAYER_BITOP(action_code.OP_BIT_AND, 0, 0b00011, action_code.ON_PRESS) };

    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processAction(&press, act);

    try testing.expect(layer.layerStateIs(0));
    try testing.expect(layer.layerStateIs(1));
    try testing.expect(!layer.layerStateIs(2));
}

test "default layer bitwise OP_BIT_SET (DF equivalent)" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // ACTION_DEFAULT_LAYER_SET(1) = ACTION_LAYER_BITOP(OP_BIT_SET, 0, 0b00010, 0)
    const act = Action{ .code = action_code.ACTION_DEFAULT_LAYER_SET(1) };

    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processAction(&press, act);
    try testing.expectEqual(@as(layer.LayerState, 1), layer.getDefaultLayerState());

    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 200) };
    processAction(&release, act);
    try testing.expectEqual(@as(layer.LayerState, 0b10), layer.getDefaultLayerState());
}

test "layer bitwise OP_BIT_OR on both" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // ON_BOTH: press and release
    const act = Action{ .code = action_code.ACTION_LAYER_BITOP(action_code.OP_BIT_OR, 0, 0b00010, action_code.ON_BOTH) };

    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processAction(&press, act);
    try testing.expect(layer.layerStateIs(1));

    layer.layerClear();
    try testing.expect(!layer.layerStateIs(1));

    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 200) };
    processAction(&release, act);
    try testing.expect(layer.layerStateIs(1));
}

test "processLayerModsAction press and release" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // ACTION_LAYER_MODS(1, 0x40): layer 1 + RALT(0x40)
    const act = Action{ .code = action_code.ACTION_LAYER_MODS(1, 0x40) };

    // Press -> layer 1 on + mods=0x40
    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processAction(&press, act);
    try testing.expect(layer.layerStateIs(1));
    try testing.expectEqual(@as(u8, 0x40), mock.lastKeyboardReport().mods);

    // Release -> layer 1 off + mods=0x00
    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 200) };
    processAction(&release, act);
    try testing.expect(!layer.layerStateIs(1));
    try testing.expectEqual(@as(u8, 0x00), mock.lastKeyboardReport().mods);
}

test "OSM tap sets oneshot mods" {
    reset();
    keymap_mod.keymap_config.oneshot_enable = true;
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // OSM(LSFT): ACTION_MODS_ONESHOT(0x02) → mods_tap, mods=0x02, code=0x00
    const act = Action{ .code = action_code.ACTION_MODS_ONESHOT(0x02) };

    // タップ（tap.count=1）→ oneshot_mods が設定される
    var press = KeyRecord{
        .event = KeyEvent.keyPress(0, 0, 100),
        .tap = .{ .count = 1 },
    };
    processAction(&press, act);
    try testing.expectEqual(@as(u8, 0x02), host.getOneshotMods());

    // リリース（tap.count=1）→ oneshot_mods は保持される
    var release = KeyRecord{
        .event = KeyEvent.keyRelease(0, 0, 150),
        .tap = .{ .count = 1 },
    };
    processAction(&release, act);
    try testing.expectEqual(@as(u8, 0x02), host.getOneshotMods());

    // 次のキーを押す → oneshot_mods がレポートに含まれ、クリアされる
    host.registerCode(0x04); // KC_A
    host.sendKeyboardReport();
    try testing.expect(mock.lastKeyboardReport().hasKey(0x04));
    try testing.expectEqual(@as(u8, 0x02), mock.lastKeyboardReport().mods);
    try testing.expectEqual(@as(u8, 0), host.getOneshotMods()); // クリア済み

    // さらにもう一度送信 → mods はクリア
    host.sendKeyboardReport();
    try testing.expectEqual(@as(u8, 0x00), mock.lastKeyboardReport().mods);
}

test "OSM hold acts as normal modifier" {
    reset();
    keymap_mod.keymap_config.oneshot_enable = true;
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // OSM(LSFT): ACTION_MODS_ONESHOT(0x02)
    const act = Action{ .code = action_code.ACTION_MODS_ONESHOT(0x02) };

    // ホールド（tap.count=0）→ 通常の修飾キーとして動作
    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processAction(&press, act);
    try testing.expectEqual(@as(u8, 0x02), mock.lastKeyboardReport().mods);
    try testing.expectEqual(@as(u8, 0), host.getOneshotMods()); // OSMは設定されない

    // リリース → 修飾キーがクリアされる
    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 400) };
    processAction(&release, act);
    try testing.expectEqual(@as(u8, 0x00), mock.lastKeyboardReport().mods);
}

test "isTapAction: OSL is tap action" {
    // OSL(1): layer_tap with OP_ONESHOT
    try testing.expect(isTapAction(.{ .code = action_code.ACTION_LAYER_ONESHOT(1) }));
    // OSL(3)
    try testing.expect(isTapAction(.{ .code = action_code.ACTION_LAYER_ONESHOT(3) }));
}

test "OSL tap activates layer for next key then deactivates" {
    reset();
    keymap_mod.keymap_config.oneshot_enable = true;
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // OSL(1): ACTION_LAYER_ONESHOT(1)
    const osl_act = Action{ .code = action_code.ACTION_LAYER_ONESHOT(1) };

    // タップ（tap.count=1）→ OSL が START 状態で設定される
    var press = KeyRecord{
        .event = KeyEvent.keyPress(0, 0, 100),
        .tap = .{ .count = 1 },
    };
    processAction(&press, osl_act);
    try testing.expect(host.isOneshotLayerActive());
    try testing.expectEqual(@as(u5, 1), host.getOneshotLayer());
    try testing.expect(layer.layerStateIs(1));

    // タップリリース → PRESSED フラグがクリアされる
    var release = KeyRecord{
        .event = KeyEvent.keyRelease(0, 0, 150),
        .tap = .{ .count = 1 },
    };
    processAction(&release, osl_act);
    // OTHER_KEY_PRESSED がまだ残っているのでレイヤーはアクティブ
    try testing.expect(host.isOneshotLayerActive());
    try testing.expect(layer.layerStateIs(1));

    // 次のキーを押す → do_release_oneshot でレイヤーが解除される
    const key_act = Action{ .code = action_code.ACTION_KEY(0x04) }; // KC_A
    var key_press = KeyRecord{ .event = KeyEvent.keyPress(1, 0, 200) };
    processAction(&key_press, key_act);
    // キーが登録された後、do_release_oneshot によりリリースも実行される
    try testing.expect(!host.isOneshotLayerActive());
    try testing.expect(!layer.layerStateIs(1));
}

test "OSL hold also uses oneshot behavior (C-compat)" {
    reset();
    keymap_mod.keymap_config.oneshot_enable = true;
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    const osl_act = Action{ .code = action_code.ACTION_LAYER_ONESHOT(1) };

    // ホールド（tap.count=0）→ C版互換: tap_count に関わらず oneshot 挙動
    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processAction(&press, osl_act);
    try testing.expect(layer.layerStateIs(1));
    try testing.expect(host.isOneshotLayerActive()); // OSL状態でもある

    // リリース（tap.count=0）→ PRESSED クリア。OTHER_KEY_PRESSED が残るのでレイヤー維持
    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 400) };
    processAction(&release, osl_act);
    // OTHER_KEY_PRESSED が残っているのでレイヤーはまだアクティブ
    try testing.expect(host.isOneshotLayerActive());
    try testing.expect(layer.layerStateIs(1));

    // 次のキーを押す → do_release_oneshot でレイヤーが解除される
    const key_act = Action{ .code = action_code.ACTION_KEY(0x04) };
    var key_press = KeyRecord{ .event = KeyEvent.keyPress(1, 0, 500) };
    processAction(&key_press, key_act);
    try testing.expect(!host.isOneshotLayerActive());
    try testing.expect(!layer.layerStateIs(1));
}

test "OSL disabled: acts as plain MO" {
    reset();
    keymap_mod.keymap_config.oneshot_enable = false;
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    const osl_act = Action{ .code = action_code.ACTION_LAYER_ONESHOT(2) };

    // タップでも MO として動作
    var press = KeyRecord{
        .event = KeyEvent.keyPress(0, 0, 100),
        .tap = .{ .count = 1 },
    };
    processAction(&press, osl_act);
    try testing.expect(layer.layerStateIs(2));
    try testing.expect(!host.isOneshotLayerActive());

    var release = KeyRecord{
        .event = KeyEvent.keyRelease(0, 0, 150),
        .tap = .{ .count = 1 },
    };
    processAction(&release, osl_act);
    try testing.expect(!layer.layerStateIs(2));
}

test "OSL modifier key does not trigger release" {
    reset();
    keymap_mod.keymap_config.oneshot_enable = true;
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    const osl_act = Action{ .code = action_code.ACTION_LAYER_ONESHOT(1) };

    // OSL(1) をタップ
    var osl_press = KeyRecord{
        .event = KeyEvent.keyPress(0, 0, 100),
        .tap = .{ .count = 1 },
    };
    processAction(&osl_press, osl_act);
    var osl_release = KeyRecord{
        .event = KeyEvent.keyRelease(0, 0, 150),
        .tap = .{ .count = 1 },
    };
    processAction(&osl_release, osl_act);
    try testing.expect(host.isOneshotLayerActive());

    // 修飾キーを押す → OSL は解除されない
    const mod_act = Action{ .code = action_code.ACTION_KEY(0xE1) }; // KC_LSHIFT (0xE1)
    var mod_press = KeyRecord{ .event = KeyEvent.keyPress(1, 0, 200) };
    processAction(&mod_press, mod_act);
    try testing.expect(host.isOneshotLayerActive());
    try testing.expect(layer.layerStateIs(1));
}

test "OSL double tap deactivates immediately" {
    reset();
    keymap_mod.keymap_config.oneshot_enable = true;
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    const osl_act = Action{ .code = action_code.ACTION_LAYER_ONESHOT(1) };

    // ダブルタップ（tap.count=2）
    var press = KeyRecord{
        .event = KeyEvent.keyPress(0, 0, 100),
        .tap = .{ .count = 2 },
    };
    processAction(&press, osl_act);
    try testing.expect(host.isOneshotLayerActive());

    // リリース（tap.count=2）→ PRESSED と OTHER_KEY_PRESSED の両方がクリアされる
    var release = KeyRecord{
        .event = KeyEvent.keyRelease(0, 0, 150),
        .tap = .{ .count = 2 },
    };
    processAction(&release, osl_act);
    try testing.expect(!host.isOneshotLayerActive());
    try testing.expect(!layer.layerStateIs(1));
}

test "OSM right modifier tap sets correct HID bits" {
    reset();
    keymap_mod.keymap_config.oneshot_enable = true;
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // RSFT OSM: rmods_tap kind, mods=0x02 (SHIFT), code=MODS_ONESHOT(0x00)
    // ActionKind.rmods_tap=0x03, param = 0x02<<8 | 0x00 = 0x0200
    const act = Action{ .code = action_code.ACTION(@intFromEnum(action_code.ActionKind.rmods_tap), @as(u12, 0x02) << 8 | @as(u12, action_code.MODS_ONESHOT)) };

    // タップ（tap.count=1）→ oneshot_mods が設定される（8ビットHID形式 RSHIFT=0x20）
    var press = KeyRecord{
        .event = KeyEvent.keyPress(0, 0, 100),
        .tap = .{ .count = 1 },
    };
    processAction(&press, act);
    try testing.expectEqual(@as(u8, 0x20), host.getOneshotMods()); // RSHIFT HID bit

    // リリース
    var release = KeyRecord{
        .event = KeyEvent.keyRelease(0, 0, 150),
        .tap = .{ .count = 1 },
    };
    processAction(&release, act);
    try testing.expectEqual(@as(u8, 0x20), host.getOneshotMods()); // 保持される

    // 次のキー入力で OSM が適用されてクリアされることを確認
    host.registerCode(0x04); // KC_A
    host.sendKeyboardReport();
    try testing.expectEqual(@as(u8, 0x20), mock.lastKeyboardReport().mods); // OSM適用済みレポート
    try testing.expectEqual(@as(u8, 0), host.getOneshotMods()); // OSMクリア
}

test "ACT_MOUSEKEY dispatch" {
    reset();
    const timer = @import("../hal/timer.zig");
    timer.mockReset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // ACTION_MOUSEKEY(KC_MS_BTN1=0xD1)
    const act = Action{ .code = action_code.ACTION_MOUSEKEY(0xD1) };

    // Press -> mousekey.on + send
    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processAction(&press, act);
    try testing.expect(mock.mouse_count > 0);
    try testing.expectEqual(@as(u8, 0x01), mock.lastMouseReport().buttons);

    // Release -> mousekey.off + send
    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 200) };
    processAction(&release, act);
    try testing.expectEqual(@as(u8, 0x00), mock.lastMouseReport().buttons);

    mousekey.clear();
}

test "TT layer tap toggle - tap count based" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    const act = Action{ .code = action_code.ACTION_LAYER_TAP_TOGGLE(1) };

    // 1回目のタップ (tap_count=1): press→invert(on), release→invert(off)
    var press1 = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100), .tap = .{ .count = 1 } };
    processAction(&press1, act);
    try testing.expect(layer.layerStateIs(1));

    var release1 = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 150), .tap = .{ .count = 1 } };
    processAction(&release1, act);
    try testing.expect(!layer.layerStateIs(1));

    // TAPPING_TOGGLE(5) 回目のタップ:
    // press時: tap_count(5) < TAPPING_TOGGLE(5) = false → invertされない
    // release時: tap_count(5) <= TAPPING_TOGGLE(5) = true → invert → on
    var press5 = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 500), .tap = .{ .count = TAPPING_TOGGLE } };
    processAction(&press5, act);
    try testing.expect(!layer.layerStateIs(1)); // invertされない → offのまま

    var release5 = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 550), .tap = .{ .count = TAPPING_TOGGLE } };
    processAction(&release5, act);
    try testing.expect(layer.layerStateIs(1)); // invert → on

    // TAPPING_TOGGLE+1 回目のタップ: press→invertされない, release→invertされない → 固定
    // 現在 layer 1 は on 状態
    var press6 = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 600), .tap = .{ .count = TAPPING_TOGGLE + 1 } };
    processAction(&press6, act);
    try testing.expect(layer.layerStateIs(1)); // tap_count >= TAPPING_TOGGLE → invertされない

    var release6 = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 650), .tap = .{ .count = TAPPING_TOGGLE + 1 } };
    processAction(&release6, act);
    try testing.expect(layer.layerStateIs(1)); // tap_count > TAPPING_TOGGLE → invertされない → 固定
}

test "MODS_TAP_TOGGLE - tap count based" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // MODS_TAP_TOGGLE(LSFT=0x02)
    const act = Action{ .code = action_code.ACTION_MODS_TAP_TOGGLE(0x02) };

    // 1回目のタップ: press→register, release→unregister
    var press1 = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100), .tap = .{ .count = 1 } };
    processAction(&press1, act);
    try testing.expectEqual(@as(u8, 0x02), mock.lastKeyboardReport().mods);

    var release1 = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 150), .tap = .{ .count = 1 } };
    processAction(&release1, act);
    try testing.expectEqual(@as(u8, 0x00), mock.lastKeyboardReport().mods);

    // TAPPING_TOGGLE 回目のタップ: press→register, release→unregisterされない → 固定
    var press5 = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 500), .tap = .{ .count = TAPPING_TOGGLE } };
    processAction(&press5, act);
    try testing.expectEqual(@as(u8, 0x02), mock.lastKeyboardReport().mods);

    var release5 = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 550), .tap = .{ .count = TAPPING_TOGGLE } };
    processAction(&release5, act);
    // tap_count == TAPPING_TOGGLE → !(tap_count < TAPPING_TOGGLE) → unregisterされない → 固定
    try testing.expectEqual(@as(u8, 0x02), mock.lastKeyboardReport().mods);
}

test "keycodeConfig swap_grave_esc" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    keymap_mod.keymap_config.swap_grave_esc = true;

    // KC_GRAVE(0x35) をプレス → keycodeConfig により KC_ESCAPE(0x29) に変換される
    const act = Action{ .code = action_code.ACTION_KEY(0x35) };
    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processAction(&press, act);
    try testing.expect(mock.lastKeyboardReport().hasKey(0x29)); // KC_ESCAPE
    try testing.expect(!mock.lastKeyboardReport().hasKey(0x35));

    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 200) };
    processAction(&release, act);
    try testing.expect(!mock.lastKeyboardReport().hasKey(0x29));
}

test "keycodeConfig swap_backslash_backspace" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    keymap_mod.keymap_config.swap_backslash_backspace = true;

    // KC_BACKSLASH(0x31) → KC_BACKSPACE(0x2A)
    const act = Action{ .code = action_code.ACTION_KEY(0x31) };
    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processAction(&press, act);
    try testing.expect(mock.lastKeyboardReport().hasKey(0x2A)); // KC_BACKSPACE

    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 200) };
    processAction(&release, act);
    try testing.expect(!mock.lastKeyboardReport().hasKey(0x2A));
}

test "modConfig swap_lalt_lgui for mods action" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    keymap_mod.keymap_config.swap_lalt_lgui = true;

    // ACTION_MODS_KEY(LALT=0x04, KC_A=0x04): modConfig で LGUI に変換される
    // 5ビットmods: 0x04 (LALT) → modFourBitToFiveBit(0x4, false) = 0x04
    // modFiveBitToEightBit(0x04) = 0x04 (LALT HID)
    // modConfig(0x04) = 0x08 (LGUI HID) ← swap適用
    const act = Action{ .code = action_code.ACTION_MODS_KEY(0x04, 0x04) };

    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processAction(&press, act);
    try testing.expectEqual(@as(u8, report_mod.ModBit.LGUI), mock.lastKeyboardReport().mods);
    try testing.expect(mock.lastKeyboardReport().hasKey(0x04));

    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 200) };
    processAction(&release, act);
    try testing.expectEqual(@as(u8, 0x00), mock.lastKeyboardReport().mods);
}

test "modConfig swap_lalt_lgui for layer_mods" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    keymap_mod.keymap_config.swap_lalt_lgui = true;

    // ACTION_LAYER_MODS(1, LALT=0x04): modConfig で LGUI(0x08) に変換される
    const act = Action{ .code = action_code.ACTION_LAYER_MODS(1, report_mod.ModBit.LALT) };

    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processAction(&press, act);
    try testing.expect(layer.layerStateIs(1));
    try testing.expectEqual(@as(u8, report_mod.ModBit.LGUI), mock.lastKeyboardReport().mods);

    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 200) };
    processAction(&release, act);
    try testing.expect(!layer.layerStateIs(1));
    try testing.expectEqual(@as(u8, 0x00), mock.lastKeyboardReport().mods);
}
