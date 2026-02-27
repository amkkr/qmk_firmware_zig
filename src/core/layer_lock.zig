//! Layer Lock 機能
//! C版 quantum/layer_lock.c に相当
//!
//! Layer Lock は MO（モメンタリレイヤー）で一時的に有効化したレイヤーを
//! ロック（指を離してもアクティブなまま）する機能。
//! Layer Lock キーを再度押すとロック解除される。

const layer = @import("layer.zig");
const host = @import("host.zig");
const timer = @import("../hal/timer.zig");

/// ロック中のレイヤーをビットマスクで管理
var locked_layers: layer.LayerState = 0;

/// アイドルタイムアウト（ミリ秒、0 = 無効）
pub var idle_timeout: u32 = 0;

/// タイムアウト計測用タイマー
var lock_timer: u32 = 0;

/// 指定レイヤーがロックされているか確認
pub fn isLayerLocked(l: u5) bool {
    return (locked_layers & (@as(layer.LayerState, 1) << l)) != 0;
}

/// Layer Lock キーが押されたときの処理
/// 現在の最上位アクティブレイヤーをロック/アンロックする。
/// pressed が true のときのみ動作する（キーリリース時は何もしない）。
pub fn processLayerLock(pressed: bool) void {
    if (!pressed) return;

    const current_state = layer.getLayerState() | layer.getDefaultLayerState();
    const top_layer = layer.getHighestLayer(current_state);

    // レイヤー0のロックは意味がないので無視
    if (top_layer == 0) return;

    if (isLayerLocked(top_layer)) {
        // ロック解除: レイヤーをオフにする
        locked_layers &= ~(@as(layer.LayerState, 1) << top_layer);
        layer.layerOff(top_layer);
    } else {
        // ロック: OSL で有効化されていた場合、oneshot を解除して
        // レイヤーが自動解除されないようにする
        if (top_layer == host.getOneshotLayer()) {
            host.resetOneshotLayer();
        }
        locked_layers |= @as(layer.LayerState, 1) << top_layer;
        layer.layerOn(top_layer);
        activityTrigger();
    }
}

/// 指定レイヤーのロック状態をトグルする
/// C版 layer_lock_invert() に相当
pub fn layerLockInvert(l: u5) void {
    const mask = @as(layer.LayerState, 1) << l;
    if ((locked_layers & mask) == 0) {
        if (l == host.getOneshotLayer()) {
            host.resetOneshotLayer();
        }
        layer.layerOn(l);
        activityTrigger();
    } else {
        layer.layerOff(l);
    }
    locked_layers ^= mask;
}

/// 指定レイヤーをロックする（既にロック済みなら何もしない）
pub fn layerLockOn(l: u5) void {
    if (!isLayerLocked(l)) {
        layerLockInvert(l);
    }
}

/// 指定レイヤーのロックを解除する（ロックされていなければ何もしない）
pub fn layerLockOff(l: u5) void {
    if (isLayerLocked(l)) {
        layerLockInvert(l);
    }
}

/// 全レイヤーのロックを解除する
pub fn layerLockAllOff() void {
    layer.layerAnd(~locked_layers);
    locked_layers = 0;
}

/// アイドルタイムアウト処理（keyboard.task() から呼ばれる）
pub fn task() void {
    if (idle_timeout > 0 and locked_layers != 0) {
        if (timer.elapsed32(lock_timer) > idle_timeout) {
            layerLockAllOff();
            lock_timer = timer.read32();
        }
    }
}

/// アクティビティトリガー（ロック操作時にタイマーリセット）
pub fn activityTrigger() void {
    lock_timer = timer.read32();
}

/// レイヤー状態との同期
pub fn syncWithLayerState() void {
    const current = layer.getLayerState();
    locked_layers &= current;
}

/// Layer Lock 状態のリセット
pub fn reset() void {
    locked_layers = 0;
    idle_timeout = 0;
    lock_timer = 0;
}

/// ロック中のレイヤー状態を取得（テスト用）
pub fn getLockedLayers() layer.LayerState {
    return locked_layers;
}

// ============================================================
// Tests
// ============================================================

const testing = @import("std").testing;

test "layer lock: initial state has no locked layers" {
    reset();
    layer.resetState();
    try testing.expectEqual(@as(layer.LayerState, 0), locked_layers);
    try testing.expect(!isLayerLocked(1));
}

test "layer lock: lock and unlock a layer" {
    reset();
    layer.resetState();
    layer.layerOn(1);
    try testing.expect(layer.layerStateIs(1));
    processLayerLock(true);
    try testing.expect(isLayerLocked(1));
    try testing.expect(layer.layerStateIs(1));
    processLayerLock(true);
    try testing.expect(!isLayerLocked(1));
    try testing.expect(!layer.layerStateIs(1));
}

test "layer lock: release does nothing" {
    reset();
    layer.resetState();
    layer.layerOn(1);
    processLayerLock(false);
    try testing.expect(!isLayerLocked(1));
}

test "layer lock: layer 0 is not lockable" {
    reset();
    layer.resetState();
    processLayerLock(true);
    try testing.expect(!isLayerLocked(0));
}

test "layer lock: locks highest active layer" {
    reset();
    layer.resetState();
    layer.layerOn(1);
    layer.layerOn(3);
    processLayerLock(true);
    try testing.expect(isLayerLocked(3));
    try testing.expect(!isLayerLocked(1));
}

test "layer lock: reset clears all locks" {
    reset();
    layer.resetState();
    layer.layerOn(1);
    processLayerLock(true);
    try testing.expect(isLayerLocked(1));
    reset();
    try testing.expect(!isLayerLocked(1));
    try testing.expectEqual(@as(layer.LayerState, 0), locked_layers);
}

test "layer lock: layerLockInvert toggles lock state" {
    reset();
    layer.resetState();
    layerLockInvert(2);
    try testing.expect(isLayerLocked(2));
    try testing.expect(layer.layerStateIs(2));
    layerLockInvert(2);
    try testing.expect(!isLayerLocked(2));
    try testing.expect(!layer.layerStateIs(2));
}

test "layer lock: layerLockOn and layerLockOff" {
    reset();
    layer.resetState();
    layerLockOn(3);
    try testing.expect(isLayerLocked(3));
    layerLockOn(3);
    try testing.expect(isLayerLocked(3));
    layerLockOff(3);
    try testing.expect(!isLayerLocked(3));
    layerLockOff(3);
    try testing.expect(!isLayerLocked(3));
}

test "layer lock: layerLockAllOff clears all locks" {
    reset();
    layer.resetState();
    layerLockOn(1);
    layerLockOn(3);
    try testing.expect(isLayerLocked(1));
    try testing.expect(isLayerLocked(3));
    layerLockAllOff();
    try testing.expect(!isLayerLocked(1));
    try testing.expect(!isLayerLocked(3));
    try testing.expect(!layer.layerStateIs(1));
    try testing.expect(!layer.layerStateIs(3));
}

test "layer lock: syncWithLayerState removes stale locks" {
    reset();
    layer.resetState();
    layerLockOn(1);
    try testing.expect(isLayerLocked(1));
    layer.layerOff(1);
    syncWithLayerState();
    try testing.expect(!isLayerLocked(1));
}
