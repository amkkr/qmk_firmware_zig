//! Key Lock 機能
//! C版 quantum/process_keycode/process_key_lock.c に相当
//!
//! QK_LOCK キーを押した後に次に押したキーをロック（押しっぱなし）にする。
//! ロック中のキーが再度押されるとロック解除される。
//! 標準キーコード（0x00-0xFF）のみ対応。

const keycode_mod = @import("keycode.zig");
const Keycode = keycode_mod.Keycode;

/// QK_LOCK キーコード（quantum/keycodes.h 互換）
pub const QK_LOCK: Keycode = 0x7C04;

/// ロック状態のビットマップ（256ビット = 4 x u64）
/// 各ビットがキーコード（0x00-0xFF）に対応する
var key_state: [4]u64 = .{ 0, 0, 0, 0 };

/// 次に押したキーをロックするかどうか
var watching: bool = false;

/// 標準キーコード（0x00-0xFF）かどうかを確認する
inline fn isStandardKeycode(kc: Keycode) bool {
    return kc <= 0xFF;
}

/// ビット位置を取得する（64ビット配列インデックスとビット番号）
inline fn getArrayIndex(kc: Keycode) u2 {
    return @truncate(kc >> 6);
}

inline fn getBitIndex(kc: Keycode) u6 {
    return @truncate(kc & 0x3F);
}

/// キーのロック状態を取得する
fn getKeyState(kc: Keycode) bool {
    const arr_idx = getArrayIndex(kc);
    const bit_idx = getBitIndex(kc);
    return (key_state[arr_idx] & (@as(u64, 1) << bit_idx)) != 0;
}

/// キーのロック状態をセットする
fn setKeyState(kc: Keycode) void {
    const arr_idx = getArrayIndex(kc);
    const bit_idx = getBitIndex(kc);
    key_state[arr_idx] |= (@as(u64, 1) << bit_idx);
}

/// キーのロック状態をクリアする
fn clearKeyState(kc: Keycode) void {
    const arr_idx = getArrayIndex(kc);
    const bit_idx = getBitIndex(kc);
    key_state[arr_idx] &= ~(@as(u64, 1) << bit_idx);
}

/// OSM キーコードを元のキーコードに変換する
/// C版の translate_keycode() 相当
fn translateKeycode(kc: Keycode) Keycode {
    if (kc > keycode_mod.QK_ONE_SHOT_MOD and kc <= keycode_mod.QK_ONE_SHOT_MOD_MAX) {
        return kc ^ keycode_mod.QK_ONE_SHOT_MOD;
    }
    return kc;
}

/// Key Lock の処理
///
/// 戻り値:
/// - true: 通常の処理を続ける（上位に処理を渡す）
/// - false: このモジュールで処理済み（上位に渡さない）
///
/// 処理ロジック（C版 process_key_lock() 互換）:
/// Press イベント:
///   1. 非標準キー → watching を false にして通常処理（true）
///   2. QK_LOCK → watching を toggle して false を返す
///   3. 標準キーかつ watching=true → ロック開始、watching=false、通常処理（true）
///   4. 標準キーかつロック中 → ロック解除（状態をクリア）して false を返す
///   5. その他 → 通常処理（true）
/// Release イベント:
///   - ロック中キーなら up イベントをマスク（false）
///   - 非ロックキーなら通常処理（true）
pub fn processKeyLock(kc: *Keycode, pressed: bool) bool {
    const translated = translateKeycode(kc.*);

    if (pressed) {
        // 標準キーでも QK_LOCK でもない → watching をリセットして通常処理
        if (!isStandardKeycode(translated) and translated != QK_LOCK) {
            watching = false;
            return true;
        }

        // QK_LOCK が押された → watching を toggle
        if (translated == QK_LOCK) {
            watching = !watching;
            return false;
        }

        // 標準キーの場合
        if (isStandardKeycode(translated)) {
            // watching=true なら次のキーをロック
            if (watching) {
                watching = false;
                setKeyState(translated);
                // OSM 変換された場合は元のキーコードを使う
                kc.* = translated;
                // key-down イベントは通常通り送信し、key-up をマスク
                return true;
            }

            // すでにロック中なら解除する
            if (getKeyState(translated)) {
                clearKeyState(translated);
                // key-down はブロックし、ユーザーが離した時に key-up を送信
                return false;
            }
        }

        return true;
    } else {
        // up イベント: ロック中のキーなら up をマスク
        return !(isStandardKeycode(translated) and getKeyState(translated));
    }
}

/// Key Lock がアクティブ（次のキーを監視中）かどうかを返す
pub fn isActive() bool {
    return watching;
}

/// 状態をリセットする
pub fn reset() void {
    key_state = .{ 0, 0, 0, 0 };
    watching = false;
}

/// Key Lock 監視状態をキャンセルする（ロック済みキーは保持）
pub fn cancelKeyLock() void {
    watching = false;
}

// ============================================================
// Tests
// ============================================================

const testing = @import("std").testing;

test "QK_LOCK キー押下で watching が true になる" {
    reset();
    var kc: Keycode = QK_LOCK;
    const result = processKeyLock(&kc, true);
    try testing.expect(!result); // QK_LOCK は上位に渡さない
    try testing.expect(isActive()); // watching = true
}

test "QK_LOCK を2回押すと watching が false に戻る" {
    reset();
    var kc: Keycode = QK_LOCK;
    _ = processKeyLock(&kc, true); // watching = true
    kc = QK_LOCK;
    _ = processKeyLock(&kc, true); // watching = false
    try testing.expect(!isActive());
}

test "watching=true の時に次のキーをロックする" {
    reset();
    // QK_LOCK を押して watching=true にする
    var kc: Keycode = QK_LOCK;
    _ = processKeyLock(&kc, true);
    try testing.expect(isActive());

    // 次のキー（KC_A = 0x04）を押す → ロックされる
    kc = 0x04;
    const result = processKeyLock(&kc, true);
    try testing.expect(result); // key-down は通常処理
    try testing.expect(!isActive()); // watching = false
    try testing.expect(getKeyState(0x04)); // KC_A がロック中
}

test "ロック中キーの release イベントはマスクされる" {
    reset();
    // QK_LOCK → KC_A でロック
    var kc: Keycode = QK_LOCK;
    _ = processKeyLock(&kc, true);
    kc = 0x04;
    _ = processKeyLock(&kc, true);

    // KC_A のリリース → マスクされる
    kc = 0x04;
    const result = processKeyLock(&kc, false);
    try testing.expect(!result); // up イベントはブロック
    try testing.expect(getKeyState(0x04)); // まだロック中
}

test "ロック中キーを再度押すとロック解除される" {
    reset();
    // KC_A をロック
    var kc: Keycode = QK_LOCK;
    _ = processKeyLock(&kc, true);
    kc = 0x04;
    _ = processKeyLock(&kc, true);

    // KC_A を再度押す → ロック解除（key-down はブロック）
    kc = 0x04;
    const result = processKeyLock(&kc, true);
    try testing.expect(!result); // key-down はブロック
    try testing.expect(!getKeyState(0x04)); // ロック解除

    // その後の release は通常処理
    kc = 0x04;
    const release = processKeyLock(&kc, false);
    try testing.expect(release); // up イベントは通常処理
}

test "非標準キーコードは watching をリセットして通常処理" {
    reset();
    // QK_LOCK → watching=true
    var kc: Keycode = QK_LOCK;
    _ = processKeyLock(&kc, true);
    try testing.expect(isActive());

    // 非標準キー（例: LT(1, KC_A) = 0x4104）
    kc = 0x4104;
    const result = processKeyLock(&kc, true);
    try testing.expect(result); // 通常処理
    try testing.expect(!isActive()); // watching = false
}

test "ロックなしキーの release は通常処理" {
    reset();
    var kc: Keycode = 0x04; // KC_A（ロックされていない）
    const result = processKeyLock(&kc, false);
    try testing.expect(result); // 通常処理
}

test "reset() で全状態がクリアされる" {
    reset();
    // KC_A をロック
    var kc: Keycode = QK_LOCK;
    _ = processKeyLock(&kc, true);
    kc = 0x04;
    _ = processKeyLock(&kc, true);

    reset();
    try testing.expect(!isActive());
    try testing.expect(!getKeyState(0x04));
}

test "OSM キーコードが標準キーに変換されてロックされる" {
    reset();
    // OSM(LSFT) = QK_ONE_SHOT_MOD | 0x02 = 0x52A2
    const osm_lsft = keycode_mod.QK_ONE_SHOT_MOD | 0x02;
    // translate すると 0x02 になる（= LSFT in modifier range... ただし 0xFF 以下）

    var kc: Keycode = QK_LOCK;
    _ = processKeyLock(&kc, true);

    kc = osm_lsft;
    const result = processKeyLock(&kc, true);
    try testing.expect(result);
    // 変換後 0x02 がロックされているか確認
    try testing.expect(getKeyState(0x02));
    try testing.expectEqual(@as(Keycode, 0x02), kc); // kc が変換されているか
}
