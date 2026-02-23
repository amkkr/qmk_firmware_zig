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
const keymap_mod = @import("keymap.zig");
const report_mod = @import("report.zig");

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
            // Regular layer-tap key (not special operation)
            return code != 0 and code < OP_TAP_TOGGLE;
        },
        else => return false,
    }
}

/// Execute an action based on its kind
pub fn processAction(keyp: *KeyRecord, act: Action) void {
    if (act.code == action_code.ACTION_NO or act.code == action_code.ACTION_TRANSPARENT) return;

    const ev = keyp.event;
    const kind = act.kind.id;

    switch (kind) {
        .mods, .rmods => processModsAction(ev, act),
        .mods_tap, .rmods_tap => processModsTapAction(keyp, act),
        .usage => extrakey.processUsageAction(ev, act.code),
        .layer => processLayerAction(ev, act),
        .layer_mods => processLayerModsAction(ev, act),
        .layer_tap, .layer_tap_ext => processLayerTapAction(keyp, act),
        else => {
            if (@import("builtin").is_test) {
                @import("std").log.warn("unhandled action kind: {}", .{@intFromEnum(kind)});
            }
        },
    }
}

/// Process basic modifier actions (hold for mod, with optional key)
fn processModsAction(ev: KeyEvent, act: Action) void {
    const mods = act.key.mods;
    const kc = act.key.code;
    const mods8 = modFourBitToFiveBit(mods, act.kind.id == .rmods);

    if (ev.pressed) {
        if (mods8 != 0) host.registerMods(mods8);
        if (kc != 0) host.registerCode(kc);
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
                host.registerCode(kc);
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
    const mods_hid = host.modFiveBitToEightBit(mods5);

    if (ev.pressed) {
        if (keyp.tap.count > 0) {
            // タップ: One-Shot Mods を設定（8ビットHIDmod形式で格納）
            if (keyp.tap.count == 1) {
                host.addOneshotMods(mods_hid);
            } else {
                // 複数タップ: 通常のmod toggle として扱う（C版互換）
                host.registerMods(mods5);
            }
        } else {
            // ホールド: 通常の修飾キーとして登録
            host.registerMods(mods5);
        }
        host.sendKeyboardReport();
    } else {
        if (keyp.tap.count > 0) {
            // タップリリース: 何もしない（OSMは次キーまで保持）
            if (keyp.tap.count > 1) {
                host.unregisterMods(mods5);
            }
            host.sendKeyboardReport();
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
        processLayerTapSpecial(ev, l, code);
        return;
    }

    // Regular layer-tap: hold=layer, tap=keycode
    if (ev.pressed) {
        if (keyp.tap.count > 0) {
            // Tapped: register the tap keycode
            if (code != 0) {
                host.registerCode(code);
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
                host.unregisterCode(code);
                host.sendKeyboardReport();
            }
        } else {
            // Release hold
            layer.layerOff(l);
        }
    }
}

/// Process special layer tap operations (MO, TG, TO, etc.)
fn processLayerTapSpecial(ev: KeyEvent, l: u5, code: u8) void {
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
                layer.layerOff(l);
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
        else => {},
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

test "OSM right modifier tap sets correct HID bits" {
    reset();
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
