//! Layer Lock 機能
//! C版 quantum/layer_lock.c に相当
//!
//! Layer Lock は MO（モメンタリレイヤー）で一時的に有効化したレイヤーを
//! ロック（指を離してもアクティブなまま）する機能。
//! Layer Lock キーを再度押すとロック解除される。

const layer = @import("layer.zig");

/// ロック中のレイヤーをビットマスクで管理
var locked_layers: layer.LayerState = 0;

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
        // ロック: レイヤーをオンにして記録
        locked_layers |= @as(layer.LayerState, 1) << top_layer;
        layer.layerOn(top_layer);
    }
}

/// Layer Lock 状態のリセット
pub fn reset() void {
    locked_layers = 0;
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

    // レイヤー1をアクティブにする
    layer.layerOn(1);
    try testing.expect(layer.layerStateIs(1));

    // Layer Lock を押す -> レイヤー1がロックされる
    processLayerLock(true);
    try testing.expect(isLayerLocked(1));
    try testing.expect(layer.layerStateIs(1));

    // MO(1) を離してもロックされているのでレイヤーは維持される（外部でlayerOffは呼ばれない想定）
    // ここではロック状態の確認のみ

    // 再度 Layer Lock を押す -> レイヤー1がアンロックされる
    processLayerLock(true);
    try testing.expect(!isLayerLocked(1));
    try testing.expect(!layer.layerStateIs(1));
}

test "layer lock: release does nothing" {
    reset();
    layer.resetState();

    layer.layerOn(1);
    processLayerLock(false); // リリースは無視
    try testing.expect(!isLayerLocked(1));
}

test "layer lock: layer 0 is not lockable" {
    reset();
    layer.resetState();

    // layer_state=0 のとき最上位レイヤーは0
    processLayerLock(true);
    try testing.expect(!isLayerLocked(0));
}

test "layer lock: locks highest active layer" {
    reset();
    layer.resetState();

    layer.layerOn(1);
    layer.layerOn(3);

    // 最上位のレイヤー3がロックされる
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
