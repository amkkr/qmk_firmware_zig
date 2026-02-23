//! Swap Hands 機能
//! C版 quantum/action.c の ACT_SWAP_HANDS 処理および
//! quantum/process_keycode/process_swap_hands.c に相当
//!
//! Swap Hands は左右の手を入れ替えたかのような動作をするモード。
//! 有効時、キーマップの左右対称な位置にマッピングされたキーが使用される。
//! 実際のキー位置変換は hand_swap_config テーブル（キーボード定義側）に委ねる。
//!
//! サポートする操作:
//! - SH_ON: Swap Hands を有効化（リリース時）
//! - SH_OFF: Swap Hands を無効化（リリース時）
//! - SH_TG / SH_TOGG: Swap Hands をトグル（プレス時）
//! - SH_MON: モメンタリー ON（プレス中のみ有効）
//! - SH_MOFF: モメンタリー OFF（プレス中のみ無効）
//! - SH_T(kc): タップでキーコード送信、ホールドで Swap Hands

const event_mod = @import("event.zig");
const action_code = @import("action_code.zig");
const host = @import("host.zig");

const KeyRecord = event_mod.KeyRecord;
const KeyEvent = event_mod.KeyEvent;
const Action = action_code.Action;

// ============================================================
// Swap Hands 操作コード（C版 OP_SH_* に相当）
// C版 quantum/action_code.h の OP_SH_* と一致させる
// ============================================================

/// Swap Hands 操作コード
pub const OP_SH_TOGGLE: u8 = 0xF0; // トグル（プレス時）
pub const OP_SH_TAP_TOGGLE: u8 = 0xF1; // タップトグル
pub const OP_SH_ON_OFF: u8 = 0xF2; // モメンタリー ON（pressed中有効）
pub const OP_SH_OFF_ON: u8 = 0xF3; // モメンタリー OFF（pressed中無効）
pub const OP_SH_OFF: u8 = 0xF4; // OFF（リリース時）
pub const OP_SH_ON: u8 = 0xF5; // ON（リリース時）
pub const OP_SH_ONESHOT: u8 = 0xF6; // One-shot Swap Hands

// ============================================================
// グローバル状態
// ============================================================

/// Swap Hands が現在有効かどうか
var swap_hands: bool = false;

// ============================================================
// 公開 API
// ============================================================

/// Swap Hands を有効化する
pub fn swapHandsOn() void {
    swap_hands = true;
}

/// Swap Hands を無効化する
pub fn swapHandsOff() void {
    swap_hands = false;
}

/// Swap Hands をトグルする
pub fn swapHandsToggle() void {
    swap_hands = !swap_hands;
}

/// Swap Hands の現在の状態を取得する
pub fn isSwapHandsOn() bool {
    return swap_hands;
}

/// 状態をリセットする（テスト用）
pub fn reset() void {
    swap_hands = false;
}

// ============================================================
// アクション処理
// ============================================================

/// ACT_SWAP_HANDS アクションを処理する
/// C版 quantum/action.c の ACT_SWAP_HANDS ケースに相当
pub fn processSwapHandsAction(keyp: *KeyRecord, act: Action) void {
    const ev = keyp.event;
    // swap アクションのコードは key.code フィールドに格納
    const code = act.key.code;

    switch (code) {
        OP_SH_TOGGLE => {
            // トグル: プレス時のみ
            if (ev.pressed) {
                swap_hands = !swap_hands;
            }
        },
        OP_SH_ON_OFF => {
            // モメンタリー ON: 押している間だけ有効
            swap_hands = ev.pressed;
        },
        OP_SH_OFF_ON => {
            // モメンタリー OFF: 押している間だけ無効
            swap_hands = !ev.pressed;
        },
        OP_SH_ON => {
            // ON: リリース時に有効化
            if (!ev.pressed) {
                swap_hands = true;
            }
        },
        OP_SH_OFF => {
            // OFF: リリース時に無効化
            if (!ev.pressed) {
                swap_hands = false;
            }
        },
        OP_SH_ONESHOT => {
            // TODO: One-shot Swap Hands は未実装（C版 set_oneshot_swaphands() 相当）
            // C版では「次のキー入力まで swap_hands を維持し、そのキー後に自動 OFF」
            // というセマンティクスだが、action_tapping との連携が必要なため簡易実装。
            // 現状は SH_MON と同等の動作（モメンタリー ON/OFF）。
            if (ev.pressed) {
                swap_hands = true;
            } else {
                swap_hands = false;
            }
        },
        OP_SH_TAP_TOGGLE => {
            // タップトグル（SH_TT）: タップ回数に応じてトグル
            // タッピングサブシステムが解決済みの場合の処理
            if (ev.pressed) {
                if (keyp.tap.count > 0) {
                    // タップ中: トグルは行わない（タップキーコード処理）
                } else {
                    // ホールド: Swap Hands を有効化
                    swap_hands = true;
                }
            } else {
                if (keyp.tap.count > 0) {
                    // タップリリース: トグル
                    swap_hands = !swap_hands;
                } else {
                    // ホールドリリース: 無効化
                    swap_hands = false;
                }
            }
        },
        else => {
            // SH_T(kc): タップでキーコード送信、ホールドで Swap Hands
            processSwapHandsTapKey(keyp, code);
        },
    }
}

/// SH_T(kc) の処理: タップでキーコード、ホールドで Swap Hands
fn processSwapHandsTapKey(keyp: *KeyRecord, kc: u8) void {
    const ev = keyp.event;

    if (ev.pressed) {
        if (keyp.tap.count > 0) {
            // タップ: キーコードを送信
            if (kc != 0) {
                host.registerCode(kc);
                host.sendKeyboardReport();
            }
        } else {
            // ホールド: Swap Hands を有効化
            swap_hands = true;
        }
    } else {
        if (keyp.tap.count > 0) {
            // タップリリース: キーコードを解除
            if (kc != 0) {
                host.unregisterCode(kc);
                host.sendKeyboardReport();
            }
        } else {
            // ホールドリリース: Swap Hands を無効化
            swap_hands = false;
        }
    }
}

// ============================================================
// Tests
// ============================================================

const testing = @import("std").testing;
const MockDriver = @import("test_driver.zig").FixedTestDriver(32, 4);

test "swap hands on/off/toggle" {
    reset();
    try testing.expect(!isSwapHandsOn());

    swapHandsOn();
    try testing.expect(isSwapHandsOn());

    swapHandsOff();
    try testing.expect(!isSwapHandsOn());

    swapHandsToggle();
    try testing.expect(isSwapHandsOn());

    swapHandsToggle();
    try testing.expect(!isSwapHandsOn());
}

test "SH_ON_OFF (momentary on)" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    const act = Action{ .code = action_code.ACTION_SWAP_HANDS_ON_OFF() };

    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processSwapHandsAction(&press, act);
    try testing.expect(isSwapHandsOn());

    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 200) };
    processSwapHandsAction(&release, act);
    try testing.expect(!isSwapHandsOn());
}

test "SH_OFF_ON (momentary off)" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    swapHandsOn();

    const act = Action{ .code = action_code.ACTION_SWAP_HANDS_OFF_ON() };

    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processSwapHandsAction(&press, act);
    try testing.expect(!isSwapHandsOn());

    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 200) };
    processSwapHandsAction(&release, act);
    try testing.expect(isSwapHandsOn());
}

test "SH_TOGGLE (toggle on press)" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    const act = Action{ .code = action_code.ACTION_SWAP_HANDS_TOGGLE() };

    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processSwapHandsAction(&press, act);
    try testing.expect(isSwapHandsOn());

    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 200) };
    processSwapHandsAction(&release, act);
    try testing.expect(isSwapHandsOn()); // リリースでは変わらない

    var press2 = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 300) };
    processSwapHandsAction(&press2, act);
    try testing.expect(!isSwapHandsOn());
}

test "SH_ON (enable on release)" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    const act = Action{ .code = action_code.ACTION_SWAP_HANDS_ON() };

    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processSwapHandsAction(&press, act);
    try testing.expect(!isSwapHandsOn()); // プレスでは変わらない

    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 200) };
    processSwapHandsAction(&release, act);
    try testing.expect(isSwapHandsOn()); // リリースで有効化
}

test "SH_OFF (disable on release)" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    swapHandsOn();

    const act = Action{ .code = action_code.ACTION_SWAP_HANDS_OFF() };

    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processSwapHandsAction(&press, act);
    try testing.expect(isSwapHandsOn()); // プレスでは変わらない

    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 200) };
    processSwapHandsAction(&release, act);
    try testing.expect(!isSwapHandsOn()); // リリースで無効化
}

test "SH_T(kc) tap sends keycode" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // SH_T(KC_A): タップでKC_A、ホールドでSwap Hands
    const act = Action{ .code = action_code.ACTION_SWAP_HANDS_TAP_KEY(0x04) };

    // タップ（tap.count=1）→ KC_A を送信
    var press = KeyRecord{
        .event = KeyEvent.keyPress(0, 0, 100),
        .tap = .{ .count = 1 },
    };
    processSwapHandsAction(&press, act);
    try testing.expect(mock.lastKeyboardReport().hasKey(0x04));
    try testing.expect(!isSwapHandsOn());

    var release = KeyRecord{
        .event = KeyEvent.keyRelease(0, 0, 150),
        .tap = .{ .count = 1 },
    };
    processSwapHandsAction(&release, act);
    try testing.expect(!mock.lastKeyboardReport().hasKey(0x04));
}

test "SH_T(kc) hold enables swap hands" {
    reset();
    var mock = MockDriver{};
    host.setDriver(host.HostDriver.from(&mock));
    defer host.clearDriver();

    // SH_T(KC_A): タップでKC_A、ホールドでSwap Hands
    const act = Action{ .code = action_code.ACTION_SWAP_HANDS_TAP_KEY(0x04) };

    // ホールド（tap.count=0）→ Swap Hands 有効化
    var press = KeyRecord{ .event = KeyEvent.keyPress(0, 0, 100) };
    processSwapHandsAction(&press, act);
    try testing.expect(isSwapHandsOn());
    try testing.expect(!mock.lastKeyboardReport().hasKey(0x04));

    var release = KeyRecord{ .event = KeyEvent.keyRelease(0, 0, 400) };
    processSwapHandsAction(&release, act);
    try testing.expect(!isSwapHandsOn());
}
