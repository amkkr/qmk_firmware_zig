//! madbd34 キーボード定義（Zig版）
//! 4x12 スプリットキーボード（41キーポジション、4レイヤー）
//! プロセッサ: RP2040 (ARM Cortex-M0+)
//! ダイオード方向: COL2ROW
//!
//! 元ファイル:
//!   keyboards/madbd34/keyboard.json
//!   keyboards/madbd34/keymaps/default/keymap.c

const keycode = @import("../core/keycode.zig");
const keymap = @import("../core/keymap.zig");
const matrix = @import("../core/matrix.zig");
const gpio = @import("../hal/gpio.zig");
const Keycode = keycode.Keycode;
const KC = keycode.KC;

// ============================================================
// ハードウェア設定
// ============================================================

pub const name = "madbd34";
pub const manufacturer = "amkkr";

pub const rows: u8 = 4;
pub const cols: u8 = 12;
pub const key_count: usize = 41;

/// ダイオード方向（マトリックススキャン方式）
pub const DiodeDirection = enum { col2row, row2col };
pub const diode_direction: DiodeDirection = .col2row;

/// ブートローダ種別
pub const bootloader = "rp2040";

/// カラムピン: GP8, GP9, GP10, GP11, GP12, GP13, GP18, GP19, GP20, GP21, GP22, GP26
pub const col_pins = [_]gpio.Pin{ 8, 9, 10, 11, 12, 13, 18, 19, 20, 21, 22, 26 };

/// ロウピン: GP14, GP15, GP16, GP17
pub const row_pins = [_]gpio.Pin{ 14, 15, 16, 17 };

/// USB設定
pub const usb_vid: u16 = 0xFEED;
pub const usb_pid: u16 = 0x0000;
pub const usb_device_version = "1.0.0";

/// 機能フラグ
pub const features = struct {
    pub const bootmagic = true;
    pub const extrakey = true;
    pub const mousekey = true;
};

/// マトリックス設定を返す
pub fn matrixConfig() matrix.Config {
    return .{
        .col_pins = &col_pins,
        .row_pins = &row_pins,
    };
}

// ============================================================
// LAYOUT関数
// ============================================================

/// 物理配列（41キー）からマトリックス座標への変換
///
/// 物理レイアウト:
///   Row 0: k00 k01 k02 k03 k04 k05 | k06 k07 k08 k09 k0a k0b   (12キー)
///   Row 1: k10 k11 k12 k13 k14 k15 | k16 k17 k18 k19 k1a k1b   (12キー)
///   Row 2: k20 k21 k22 k23 k24 k25 | k26 k27 k28 k29 k2a        (11キー)
///   Row 3:             k33 k34 k35 | k36 k37 k38                  (6キー)
pub fn LAYOUT(comptime keys: [key_count]Keycode) [rows][cols]Keycode {
    @setEvalBranchQuota(2000);
    var result: [rows][cols]Keycode = .{.{KC.NO} ** cols} ** rows;
    var idx: usize = 0;

    // Row 0: cols 0-11 (12 keys)
    for (0..12) |col| {
        result[0][col] = keys[idx];
        idx += 1;
    }

    // Row 1: cols 0-11 (12 keys)
    for (0..12) |col| {
        result[1][col] = keys[idx];
        idx += 1;
    }

    // Row 2: cols 0-10 (11 keys)
    for (0..11) |col| {
        result[2][col] = keys[idx];
        idx += 1;
    }

    // Row 3: cols 3-8 (6 keys)
    for (3..9) |col| {
        result[3][col] = keys[idx];
        idx += 1;
    }

    return result;
}

// ============================================================
// デフォルトキーマップ
// ============================================================

/// このキーボードで定義されているレイヤー数。
/// keymap.Keymap 型は常に MAX_LAYERS（16）スロット分確保するが、
/// この値は実際に使用するレイヤー数のメタデータとして使用する。
pub const num_layers: u8 = 4;

/// Layer 0: QWERTY ベースレイヤー
const layer0 = LAYOUT(.{
    KC.TAB,  KC.Q,  KC.W,  KC.E,  KC.R,  KC.T,               KC.Y,  KC.U,  KC.I,    KC.O,    KC.P,    KC.BSPC,
    KC.LCTL, KC.A,  KC.S,  KC.D,  KC.F,  KC.G,               KC.H,  KC.J,  KC.K,    KC.L,    KC.SCLN, KC.ENT,
    KC.LSFT, KC.Z,  KC.X,  KC.C,  KC.V,  KC.B,               KC.N,  KC.M,  KC.COMM, KC.DOT,  KC.SLSH,
                  KC.LCTL, KC.LGUI, keycode.LT(1, KC.SPC),  keycode.LT(2, KC.ESC), KC.RALT, keycode.MO(1),
});

/// Layer 1: 数字/記号レイヤー
const layer1 = LAYOUT(.{
    KC.TAB,  KC.@"1", KC.@"2", KC.@"3", KC.@"4", KC.@"5",    KC.@"6", KC.@"7", KC.@"8", KC.@"9", KC.@"0", KC.BSPC,
    KC.LCTL, KC.NO,   KC.NO,   KC.NO,   KC.NO,   KC.NO,       KC.MINS, KC.EQL,  KC.LBRC, KC.RBRC, KC.BSLS, KC.ENT,
    KC.LSFT, KC.NO,   KC.NO,   KC.NO,   KC.NO,   KC.SPC,      KC.GRV,  KC.QUOT, KC.COMM, KC.DOT,  KC.SLSH,
                  KC.LCTL, KC.LGUI, keycode.LT(1, KC.SPC),  keycode.LT(3, KC.ESC), KC.RALT, KC.NO,
});

/// Layer 2: ナビゲーションレイヤー
const layer2 = LAYOUT(.{
    KC.TAB,  KC.NO, KC.NO, KC.NO, KC.END,  KC.NO,             KC.HOME, KC.NO,   KC.NO, KC.NO,   KC.NO, KC.DEL,
    KC.LCTL, KC.NO, KC.NO, KC.NO, KC.PGDN, KC.NO,             KC.LEFT, KC.DOWN, KC.UP, KC.RGHT, KC.NO, KC.ENT,
    KC.LSFT, KC.NO, KC.NO, KC.NO, KC.NO,   KC.PGUP,           KC.NO,   KC.NO,   KC.NO, KC.NO,   KC.NO,
                  KC.LALT, KC.LGUI, keycode.LT(3, KC.SPC),  keycode.LT(2, KC.ESC), KC.RALT, KC.NO,
});

/// Layer 3: ファンクション/メディア/マウスレイヤー
const layer3 = LAYOUT(.{
    KC.F1, KC.F2,   KC.F3,   KC.F4,   KC.F5, KC.F6,           KC.F7,     KC.F8,      KC.F9,      KC.F10,      KC.F11, KC.F12,
    KC.NO, KC.MUTE, KC.VOLD, KC.VOLU, KC.NO, KC.NO,           KC.MS_LEFT, KC.MS_DOWN, KC.MS_UP,   KC.MS_RIGHT, KC.NO,  KC.NO,
    KC.NO, KC.NO,   KC.NO,   KC.NO,   KC.NO, KC.NO,           KC.MS_WH_LEFT, KC.MS_WH_DOWN, KC.MS_WH_UP, KC.MS_WH_RIGHT, KC.NO,
                  KC.LCTL, KC.LGUI, keycode.LT(2, KC.SPC),  keycode.LT(1, KC.ESC), KC.RALT, KC.NO,
});

/// デフォルトキーマップ（4レイヤー分）
pub const default_keymap: keymap.Keymap = buildKeymap();

fn buildKeymap() keymap.Keymap {
    var km: keymap.Keymap = keymap.emptyKeymap();
    km[0] = layer0;
    km[1] = layer1;
    km[2] = layer2;
    km[3] = layer3;
    return km;
}

// ============================================================
// テスト
// ============================================================

const testing = @import("std").testing;

test "ハードウェア設定が正しい" {
    try testing.expectEqual(@as(u8, 4), rows);
    try testing.expectEqual(@as(u8, 12), cols);
    try testing.expectEqual(@as(usize, 12), col_pins.len);
    try testing.expectEqual(@as(usize, 4), row_pins.len);
}

test "ピン番号が keyboard.json と一致する" {
    // Cols: GP8, GP9, GP10, GP11, GP12, GP13, GP18, GP19, GP20, GP21, GP22, GP26
    try testing.expectEqual(@as(gpio.Pin, 8), col_pins[0]);
    try testing.expectEqual(@as(gpio.Pin, 13), col_pins[5]);
    try testing.expectEqual(@as(gpio.Pin, 18), col_pins[6]);
    try testing.expectEqual(@as(gpio.Pin, 26), col_pins[11]);

    // Rows: GP14, GP15, GP16, GP17
    try testing.expectEqual(@as(gpio.Pin, 14), row_pins[0]);
    try testing.expectEqual(@as(gpio.Pin, 17), row_pins[3]);
}

test "LAYOUT関数: キー数と配置が正しい" {
    const keys = comptime blk: {
        var k: [key_count]Keycode = undefined;
        for (0..key_count) |i| {
            k[i] = @intCast(i + 1);
        }
        break :blk k;
    };

    const m = LAYOUT(keys);

    // Row 0: 12キー (index 0-11)
    try testing.expectEqual(@as(Keycode, 1), m[0][0]);
    try testing.expectEqual(@as(Keycode, 12), m[0][11]);

    // Row 1: 12キー (index 12-23)
    try testing.expectEqual(@as(Keycode, 13), m[1][0]);
    try testing.expectEqual(@as(Keycode, 24), m[1][11]);

    // Row 2: 11キー (index 24-34), col 11 は空
    try testing.expectEqual(@as(Keycode, 25), m[2][0]);
    try testing.expectEqual(@as(Keycode, 35), m[2][10]);
    try testing.expectEqual(KC.NO, m[2][11]);

    // Row 3: 6キー (index 35-40), cols 3-8, 他は空
    try testing.expectEqual(KC.NO, m[3][0]);
    try testing.expectEqual(KC.NO, m[3][1]);
    try testing.expectEqual(KC.NO, m[3][2]);
    try testing.expectEqual(@as(Keycode, 36), m[3][3]);
    try testing.expectEqual(@as(Keycode, 41), m[3][8]);
    try testing.expectEqual(KC.NO, m[3][9]);
}

test "デフォルトキーマップ: Layer 0 (QWERTY) の検証" {
    const km = default_keymap;

    // 先頭キー
    try testing.expectEqual(KC.TAB, km[0][0][0]);
    try testing.expectEqual(KC.Q, km[0][0][1]);
    try testing.expectEqual(KC.W, km[0][0][2]);

    // 最後のキー（Row 0）
    try testing.expectEqual(KC.BSPC, km[0][0][11]);

    // Row 1
    try testing.expectEqual(KC.LCTL, km[0][1][0]);
    try testing.expectEqual(KC.ENT, km[0][1][11]);

    // Row 2
    try testing.expectEqual(KC.LSFT, km[0][2][0]);
    try testing.expectEqual(KC.SLSH, km[0][2][10]);
    try testing.expectEqual(KC.NO, km[0][2][11]); // 未使用

    // Row 3 (サムクラスタ)
    try testing.expectEqual(KC.LCTL, km[0][3][3]);
    try testing.expectEqual(KC.LGUI, km[0][3][4]);
    try testing.expectEqual(keycode.LT(1, KC.SPC), km[0][3][5]);
    try testing.expectEqual(keycode.LT(2, KC.ESC), km[0][3][6]);
    try testing.expectEqual(KC.RALT, km[0][3][7]);
    try testing.expectEqual(keycode.MO(1), km[0][3][8]);
}

test "デフォルトキーマップ: Layer 1 (数字/記号) の検証" {
    const km = default_keymap;

    try testing.expectEqual(KC.@"1", km[1][0][1]);
    try testing.expectEqual(KC.@"0", km[1][0][10]);
    try testing.expectEqual(KC.MINS, km[1][1][6]);
    try testing.expectEqual(KC.EQL, km[1][1][7]);
    try testing.expectEqual(KC.LBRC, km[1][1][8]);
    try testing.expectEqual(KC.RBRC, km[1][1][9]);
    try testing.expectEqual(KC.BSLS, km[1][1][10]);
    try testing.expectEqual(KC.GRV, km[1][2][6]);
    try testing.expectEqual(KC.QUOT, km[1][2][7]);
}

test "デフォルトキーマップ: Layer 2 (ナビゲーション) の検証" {
    const km = default_keymap;

    try testing.expectEqual(KC.END, km[2][0][4]);
    try testing.expectEqual(KC.HOME, km[2][0][6]);
    try testing.expectEqual(KC.DEL, km[2][0][11]);
    try testing.expectEqual(KC.PGDN, km[2][1][4]);
    try testing.expectEqual(KC.LEFT, km[2][1][6]);
    try testing.expectEqual(KC.DOWN, km[2][1][7]);
    try testing.expectEqual(KC.UP, km[2][1][8]);
    try testing.expectEqual(KC.RGHT, km[2][1][9]);
    try testing.expectEqual(KC.PGUP, km[2][2][5]);
}

test "デフォルトキーマップ: Layer 3 (ファンクション/メディア/マウス) の検証" {
    const km = default_keymap;

    // ファンクションキー
    try testing.expectEqual(KC.F1, km[3][0][0]);
    try testing.expectEqual(KC.F12, km[3][0][11]);

    // メディアキー
    try testing.expectEqual(KC.MUTE, km[3][1][1]);
    try testing.expectEqual(KC.VOLD, km[3][1][2]);
    try testing.expectEqual(KC.VOLU, km[3][1][3]);

    // マウスキー
    try testing.expectEqual(KC.MS_LEFT, km[3][1][6]);
    try testing.expectEqual(KC.MS_DOWN, km[3][1][7]);
    try testing.expectEqual(KC.MS_UP, km[3][1][8]);
    try testing.expectEqual(KC.MS_RIGHT, km[3][1][9]);

    // マウスホイール
    try testing.expectEqual(KC.MS_WH_LEFT, km[3][2][6]);
    try testing.expectEqual(KC.MS_WH_DOWN, km[3][2][7]);
    try testing.expectEqual(KC.MS_WH_UP, km[3][2][8]);
    try testing.expectEqual(KC.MS_WH_RIGHT, km[3][2][9]);
}

test "デフォルトキーマップ: 未使用レイヤーが空である" {
    const km = default_keymap;

    // Layer 4以降は全て KC.NO
    for (4..keymap.MAX_LAYERS) |l| {
        for (0..rows) |r| {
            for (0..cols) |c| {
                try testing.expectEqual(KC.NO, km[l][r][c]);
            }
        }
    }
}

test "matrixConfig: 設定値が正しい" {
    const cfg = matrixConfig();
    try testing.expectEqual(@as(usize, 12), cfg.col_pins.len);
    try testing.expectEqual(@as(usize, 4), cfg.row_pins.len);
}

test "LAYOUT関数: C版キーマップと等価な値を生成する" {
    // C版の LT(1,KC_SPC) = QK_LAYER_TAP | (1 << 8) | KC_SPC
    // = 0x4000 | 0x0100 | 0x2C = 0x412C
    try testing.expectEqual(@as(Keycode, 0x412C), keycode.LT(1, KC.SPC));

    // C版の LT(2,KC_ESC) = 0x4000 | 0x0200 | 0x29 = 0x4229
    try testing.expectEqual(@as(Keycode, 0x4229), keycode.LT(2, KC.ESC));

    // C版の MO(1) = QK_MOMENTARY | 1 = 0x5221
    try testing.expectEqual(@as(Keycode, 0x5221), keycode.MO(1));

    // Layer 0 のサムキーが正しいことを確認
    const km = default_keymap;
    try testing.expectEqual(@as(Keycode, 0x412C), km[0][3][5]); // LT(1, KC_SPC)
    try testing.expectEqual(@as(Keycode, 0x4229), km[0][3][6]); // LT(2, KC_ESC)
    try testing.expectEqual(@as(Keycode, 0x5221), km[0][3][8]); // MO(1)
}
