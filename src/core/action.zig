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
const auto_shift = @import("auto_shift.zig");
const keymap_mod = @import("keymap.zig");
const report_mod = @import("report.zig");
pub const swap_hands = @import("swap_hands.zig");
const caps_word = @import("caps_word.zig");
const repeat_key = @import("repeat_key.zig");
const layer_lock = @import("layer_lock.zig");

const Action = action_code.Action;
const ActionKind = action_code.ActionKind;
const KeyRecord = event_mod.KeyRecord;
const KeyEvent = event_mod.KeyEvent;

/// Action resolver callback type
/// Given a KeyEvent, return the action code to execute.
pub const ActionResolver = *const fn (event: KeyEvent) Action;

var action_resolver: ?ActionResolver = null;

pub fn setActionResolver(resolver: ActionResolver) void {
    action_resolver = resolver;
}

pub fn getActionResolver() ?ActionResolver {
    return action_resolver;
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

/// Main entry point: execute action for a key event
pub fn actionExec(record: *KeyRecord) void {
    tapping.actionTappingProcess(record);
}

/// Process a record through action resolution and execution
pub fn processRecord(keyp: *KeyRecord) void {
    const act = resolveAction(keyp.event);
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

/// Execute an action based on its kind
pub fn processAction(keyp: *KeyRecord, act: Action) void {
    if (act.code == action_code.ACTION_NO or act.code == action_code.ACTION_TRANSPARENT) return;

    // 特殊アクション（Caps Word, Repeat Key, Layer Lock）の処理
    if (processSpecialAction(keyp.event, act)) return;

    const ev = keyp.event;
    const kind = act.kind.id;

    // Caps Word 処理: 基本キーアクション（mods/rmods）の場合、
    // キー押下時に Caps Word のフィルタリングを適用
    if (caps_word.isActive()) {
        if (kind == .mods or kind == .rmods) {
            const kc = act.key.code;
            _ = caps_word.process(kc, ev.pressed);
        }
    }

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

    switch (kind) {
        .mods, .rmods => processModsAction(ev, act),
        .mods_tap, .rmods_tap => processModsTapAction(keyp, act),
        .usage => extrakey.processUsageAction(ev, act.code),
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

/// 特殊アクション（Caps Word, Repeat Key, Layer Lock）の処理
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
            repeat_key.processRepeatKey(ev.pressed);
            return true;
        },
        action_code.ACTION_ALT_REPEAT_KEY => {
            // Alt Repeat Key は未実装（将来拡張用）
            return true;
        },
        action_code.ACTION_LAYER_LOCK => {
            layer_lock.processLayerLock(ev.pressed);
            return true;
        },
        else => return false,
    }
}

/// Process basic modifier actions (hold for mod, with optional key)
fn processModsAction(ev: KeyEvent, act: Action) void {
    const mods = act.key.mods;
    const kc = act.key.code;
    const mods8 = modFourBitToFiveBit(mods, act.kind.id == .rmods);

    // Auto Shift: 修飾なしの基本キーで、Auto Shift 対象の場合は委譲
    if (mods8 == 0 and kc != 0) {
        if (auto_shift.processAutoShift(@as(u16, kc), ev.pressed, ev.time)) {
            return;
        }
    }

    if (ev.pressed) {
        if (mods8 != 0) host.registerMods(mods8);
        if (kc != 0) {
            host.registerCode(kc);
            // Repeat Key 用に直前のキーを記録（weak_mods も含める：Caps Word の LSHIFT 等）
            repeat_key.setLastKeycode(kc, host.getMods() | host.getWeakMods());
        }
        host.sendKeyboardReport();
    } else {
        if (kc != 0) host.unregisterCode(kc);
        if (mods8 != 0) host.unregisterMods(mods8);
        host.sendKeyboardReport();
    }
}

/// Process mod-tap actions (hold for modifier, tap for keycode)
fn processModsTapAction(keyp: *KeyRecord, act: Action) void {
    const ev = keyp.event;
    const mods = act.key.mods;
    const kc = act.key.code;
    const is_right = act.kind.id == .rmods_tap;
    const mods8 = modFourBitToFiveBit(mods, is_right);

    // One-Shot Modifier (OSM) の場合は専用処理
    if (kc == action_code.MODS_ONESHOT) {
        processOneShotModsAction(keyp, mods8);
        return;
    }

    if (ev.pressed) {
        if (keyp.tap.count > 0) {
            // Tapped: register the tap keycode
            if (kc != 0) {
                // Caps Word: タップキーにも Shift を適用
                if (caps_word.isActive()) {
                    _ = caps_word.process(kc, true);
                }
                host.registerCode(kc);
                // Repeat Key: タップキーも記録（weak_mods も含める：Caps Word の LSHIFT 等）
                repeat_key.setLastKeycode(kc, host.getMods() | host.getWeakMods());
                host.sendKeyboardReport();
            }
        } else {
            // Held: register modifier
            if (mods8 != 0) {
                host.registerMods(mods8);
                host.sendKeyboardReport();
            }
        }
    } else {
        if (keyp.tap.count > 0) {
            // Release tap
            if (kc != 0) {
                if (caps_word.isActive()) {
                    _ = caps_word.process(kc, false);
                }
                host.unregisterCode(kc);
                host.sendKeyboardReport();
            }
        } else {
            // Release hold
            if (mods8 != 0) {
                host.unregisterMods(mods8);
                host.sendKeyboardReport();
            }
        }
    }
}

/// One-Shot Modifier (OSM) のアクション処理
/// C版 quantum/action.c の ACT_MODS_TAP/MODS_ONESHOT 処理に相当
///
/// タップ時: addOneshotMods(mods) で OSM を設定
///   → 次のキー入力時に sendKeyboardReport() で一時的に適用されクリアされる
/// ホールド時: 通常の修飾キーとして動作（registerMods/unregisterMods）
///
/// 注意: mods5 は modFourBitToFiveBit() の結果（5ビットパック形式）。
/// registerMods/unregisterMods は内部で5ビット→8ビット変換するが、
/// addOneshotMods は8ビットHIDmodsを直接格納するため、明示的に変換が必要。
fn processOneShotModsAction(keyp: *KeyRecord, mods5: u8) void {
    const ev = keyp.event;

    // C版互換: oneshot_enable が false の場合、通常の修飾キーとして動作
    if (!keymap_mod.keymap_config.oneshot_enable) {
        if (ev.pressed) {
            host.registerMods(mods5);
        } else {
            host.unregisterMods(mods5);
        }
        host.sendKeyboardReport();
        return;
    }

    const mods_hid = host.modFiveBitToEightBit(mods5);

    if (ev.pressed) {
        if (keyp.tap.count > 0) {
            if (keyp.tap.count == 1) {
                // タップ: One-Shot Mods を設定（8ビットHIDmod形式で格納）
                // C版互換: OSM設定時はレポートを送信しない（次キー押下時に適用）
                host.addOneshotMods(mods_hid);
            } else {
                // 複数タップ: 通常のmod toggle として扱う（C版互換）
                host.registerMods(mods5);
                host.sendKeyboardReport();
            }
        } else {
            // ホールド: 通常の修飾キーとして登録
            host.registerMods(mods5);
            host.sendKeyboardReport();
        }
    } else {
        if (keyp.tap.count > 0) {
            // タップリリース: OSMは次キーまで保持（レポート送信不要）
            if (keyp.tap.count > 1) {
                host.unregisterMods(mods5);
                host.sendKeyboardReport();
            }
        } else {
            // ホールドリリース: 修飾キーを解除
            host.unregisterMods(mods5);
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
        host.delMods(mods);
        layer.layerOff(l);
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
    if (ev.pressed) {
        if (keyp.tap.count > 0) {
            // Tapped: register the tap keycode
            if (code != 0) {
                // Caps Word: タップキーにも Shift を適用
                if (caps_word.isActive()) {
                    _ = caps_word.process(code, true);
                }
                host.registerCode(code);
                // Repeat Key: タップキーも記録（weak_mods も含める：Caps Word の LSHIFT 等）
                repeat_key.setLastKeycode(code, host.getMods() | host.getWeakMods());
                host.sendKeyboardReport();
            }
        } else {
            // Held: activate layer
            layer.layerOn(l);
        }
    } else {
        if (keyp.tap.count > 0) {
            // Release tap
            if (code != 0) {
                if (caps_word.isActive()) {
                    _ = caps_word.process(code, false);
                }
                host.unregisterCode(code);
                host.sendKeyboardReport();
            }
        } else {
            // Release hold
            // Layer Lock でロック中のレイヤーは layerOff をスキップ
            if (!layer_lock.isLayerLocked(l)) {
                layer.layerOff(l);
            }
        }
    }
}

/// Process special layer tap operations (MO, TG, TO, OSL, etc.)
fn processLayerTapSpecial(keyp: *KeyRecord, l: u5, code: u8) void {
    const ev = keyp.event;
    switch (code) {
        OP_TAP_TOGGLE => {
            // Layer tap toggle (TT)
            if (ev.pressed) {
                layer.layerInvert(l);
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

    // C版互換: tap_count をチェックせず、常に oneshot 挙動
    // （ONESHOT_TAP_TOGGLE 未定義時の C版ロジックと等価）
    if (ev.pressed) {
        host.setOneshotLayer(l, host.OneshotState.START);
    } else {
        host.clearOneshotLayerState(host.OneshotState.PRESSED);
        if (keyp.tap.count > 1) {
            host.clearOneshotLayerState(host.OneshotState.OTHER_KEY_PRESSED);
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
    auto_shift.reset();
    keymap_mod.keymap_config = .{};
    swap_hands.reset();
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

    // OSM(RSFT) のC版互換アクションコード
    // C版: ACTION(ACT_MODS_TAP=2, 0x12<<8 | 0x00) = (2<<12) | 0x1200 = 0x3200
    // → kind=3 (rmods_tap), mods=2, code=0
    // 注: ACTION_MODS_ONESHOT(0x12) は u12 param 制限のためC版と非互換。
    //     直接C版互換値を使用する。
    const act = Action{ .code = 0x3200 };

    // タップ（tap.count=1）→ oneshot_mods に RSHIFT(0x20) が設定される
    var press = KeyRecord{
        .event = KeyEvent.keyPress(0, 0, 100),
        .tap = .{ .count = 1 },
    };
    processAction(&press, act);
    try testing.expectEqual(@as(u8, 0x20), host.getOneshotMods()); // RSHIFT HID bit

    // 次のキーを押す → RSHIFT がレポートに含まれクリアされる
    host.registerCode(0x04); // KC_A
    host.sendKeyboardReport();
    try testing.expectEqual(@as(u8, 0x20), mock.lastKeyboardReport().mods);
    try testing.expectEqual(@as(u8, 0), host.getOneshotMods());
}
