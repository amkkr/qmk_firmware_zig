//! madbd5 キーボード定義（Zig版）
//! 5x16 キーボード（テンキー付き、60キーポジション、7レイヤー）
//! プロセッサ: RP2040 (ARM Cortex-M0+)
//! ダイオード方向: COL2ROW
//!
//! 元ファイル:
//!   keyboards/madbd5/keyboard.json
//!   keyboards/madbd5/keymaps/default/keymap.c

const keycode = @import("../core/keycode.zig");
const keymap = @import("../core/keymap.zig");
const matrix = @import("../core/matrix.zig");
const gpio = @import("../hal/gpio.zig");
const Keycode = keycode.Keycode;
const KC = keycode.KC;

// ============================================================
// ハードウェア設定
// ============================================================

pub const name = "madbd5";
pub const manufacturer = "amkkr";

pub const rows: u8 = 5;
pub const cols: u8 = 16;
pub const key_count: usize = 60;

/// ダイオード方向（マトリックススキャン方式）
pub const DiodeDirection = enum { col2row, row2col };
pub const diode_direction: DiodeDirection = .col2row;

/// ブートローダ種別
pub const bootloader = "rp2040";

/// カラムピン: GP28, GP27, GP26, GP22, GP21, GP20, GP19, GP18, GP12, GP11, GP10, GP9, GP8, GP7, GP6, GP5
pub const col_pins = [_]gpio.Pin{ 28, 27, 26, 22, 21, 20, 19, 18, 12, 11, 10, 9, 8, 7, 6, 5 };

/// ロウピン: GP13, GP14, GP15, GP16, GP17
pub const row_pins = [_]gpio.Pin{ 13, 14, 15, 16, 17 };

/// USB設定
pub const usb_vid: u16 = 0xFEED;
pub const usb_pid: u16 = 0x0001;
pub const usb_device_version = "1.0.0";

/// 機能フラグ
pub const features = struct {
    pub const bootmagic = true;
    pub const extrakey = true;
    pub const mousekey = true;
};

/// レイヤー数
pub const num_layers: u8 = 7;

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

/// 物理配列（60キー）からマトリックス座標への変換
///
/// 物理レイアウト:
///   Row 0: 16キー (cols 0-15)   — numpad(4) + left(6) + right(6)
///   Row 1: 16キー (cols 0-15)   — numpad(4) + left(6) + right(6)
///   Row 2: 15キー (cols 0-14)   — numpad(4) + left(6) + right(5)
///   Row 3: 10キー (cols 0-3,4-9) — numpad(4) + thumb(6)
///   Row 4: 3キー  (cols 0-2)    — numpad bottom(3)
///   Total: 60キー
pub fn LAYOUT(comptime keys: [key_count]Keycode) [rows][cols]Keycode {
    @setEvalBranchQuota(4000);
    var result: [rows][cols]Keycode = .{.{KC.NO} ** cols} ** rows;
    var idx: usize = 0;

    // Row 0: cols 0-15 (16 keys)
    for (0..16) |col| {
        result[0][col] = keys[idx];
        idx += 1;
    }

    // Row 1: cols 0-15 (16 keys)
    for (0..16) |col| {
        result[1][col] = keys[idx];
        idx += 1;
    }

    // Row 2: cols 0-14 (15 keys)
    for (0..15) |col| {
        result[2][col] = keys[idx];
        idx += 1;
    }

    // Row 3: cols 0-3, 4-9 (10 keys)
    for (0..10) |col| {
        result[3][col] = keys[idx];
        idx += 1;
    }

    // Row 4: cols 0-2 (3 keys)
    for (0..3) |col| {
        result[4][col] = keys[idx];
        idx += 1;
    }

    return result;
}

// ============================================================
// デフォルトキーマップ
// ============================================================

/// Layer 0: QWERTY ベースレイヤー（テンキー付き）
const layer0 = LAYOUT(.{
    // Row 0: numpad + QWERTY上段
    keycode.TG(4), KC.NUM_LOCK, KC.DEL, KC.KP_SLASH,       KC.TAB,  KC.Q, KC.W, KC.E, KC.R,    KC.T,                                    KC.Y,    KC.U, KC.I,    KC.O,   KC.P,    KC.BSPC,
    // Row 1: numpad + QWERTY中段
    KC.KP_7, KC.KP_8, KC.KP_9, KC.KP_ASTERISK,             KC.LCTL, KC.A, KC.S, KC.D, KC.F,    KC.G,                                    KC.H,    KC.J, KC.K,    KC.L,   KC.SCLN, KC.ENT,
    // Row 2: numpad + QWERTY下段
    KC.KP_4, KC.KP_5, KC.KP_6, KC.KP_MINUS,                KC.LSFT, KC.Z, KC.X, KC.C, KC.V,    KC.B,                                    KC.N,    KC.M, KC.COMM, KC.DOT, KC.SLSH,
    // Row 3: numpad + thumb cluster
    KC.KP_1, KC.KP_2, KC.KP_3, KC.KP_PLUS,                                                      KC.LCTL, KC.LGUI, keycode.LT(1, KC.SPC), keycode.LT(2, KC.ESC), KC.RALT, keycode.MO(1),
    // Row 4: numpad bottom
    KC.KP_0,          KC.KP_DOT, KC.KP_ENTER,
});

/// Layer 1: 数字/記号レイヤー
const layer1 = LAYOUT(.{
    keycode.TG(4), KC.NUM_LOCK, KC.DEL, KC.KP_SLASH,       KC.TAB,  KC.@"1", KC.@"2", KC.@"3", KC.@"4", KC.@"5",                       KC.@"6", KC.@"7", KC.@"8", KC.@"9", KC.@"0", KC.BSPC,
    KC.KP_7, KC.KP_8, KC.KP_9, KC.KP_ASTERISK,             KC.LCTL, KC.NO,   KC.NO,   KC.NO,   KC.NO,   KC.NO,                          KC.MINS, KC.EQL,  KC.LBRC, KC.RBRC, KC.BSLS, KC.ENT,
    KC.KP_4, KC.KP_5, KC.KP_6, KC.KP_MINUS,                KC.LSFT, KC.NO,   KC.NO,   KC.NO,   KC.NO,   KC.SPC,                         KC.GRV,  KC.QUOT, KC.COMM, KC.DOT,  KC.SLSH,
    KC.KP_1, KC.KP_2, KC.KP_3, KC.KP_PLUS,                                                      KC.LCTL, KC.LGUI, KC.TRNS, keycode.LT(3, KC.ESC), KC.RALT, KC.NO,
    KC.KP_0,          KC.KP_DOT, KC.KP_ENTER,
});

/// Layer 2: ナビゲーションレイヤー
const layer2 = LAYOUT(.{
    keycode.TG(4), KC.NUM_LOCK, KC.DEL, KC.KP_SLASH,       KC.TAB,  KC.NO, KC.NO, KC.NO, KC.END,  KC.NO,                                KC.HOME, KC.NO,   KC.NO, KC.NO,   KC.NO, KC.DEL,
    KC.KP_7, KC.KP_8, KC.KP_9, KC.KP_ASTERISK,             KC.LCTL, KC.NO, KC.NO, KC.NO, KC.PGDN, KC.NO,                                KC.LEFT, KC.DOWN, KC.UP, KC.RGHT, KC.NO, KC.ENT,
    KC.KP_4, KC.KP_5, KC.KP_6, KC.KP_MINUS,                KC.LSFT, KC.NO, KC.NO, KC.NO, KC.NO,   KC.PGUP,                              KC.NO,   KC.NO,   KC.NO, KC.NO,   KC.NO,
    KC.KP_1, KC.KP_2, KC.KP_3, KC.KP_PLUS,                                                        KC.LALT, KC.LGUI, keycode.LT(3, KC.SPC), KC.TRNS, KC.RALT, KC.NO,
    KC.KP_0,          KC.KP_DOT, KC.KP_ENTER,
});

/// Layer 3: ファンクション/メディアレイヤー
const layer3 = LAYOUT(.{
    keycode.TG(4), KC.NUM_LOCK, KC.DEL, KC.KP_SLASH,       KC.F1, KC.F2,   KC.F3,   KC.F4,   KC.F5,   KC.F6,                            KC.F7,   KC.F8, KC.F9, KC.F10, KC.F11, KC.F12,
    KC.KP_7, KC.KP_8, KC.KP_9, KC.KP_ASTERISK,             KC.NO, KC.MUTE, KC.VOLD, KC.VOLU, KC.NO,   KC.NO,                            KC.NO,   KC.NO, KC.NO, KC.NO,  KC.NO,  KC.ENT,
    KC.KP_4, KC.KP_5, KC.KP_6, KC.KP_MINUS,                KC.NO, KC.NO,   KC.NO,   KC.NO,   KC.NO,   KC.NO,                            KC.NO,   KC.NO, KC.NO, KC.NO,  KC.NO,
    KC.KP_1, KC.KP_2, KC.KP_3, KC.KP_PLUS,                                                    KC.LCTL, KC.LGUI, KC.TRNS, KC.TRNS, KC.RALT, KC.NO,
    KC.KP_0,          KC.KP_DOT, KC.KP_ENTER,
});

/// Layer 4: ゲーミングベースレイヤー
const layer4 = LAYOUT(.{
    KC.TRNS, KC.END,  KC.END,        KC.END,                KC.TAB,  KC.Q, KC.W, KC.E, KC.R,   KC.T,                                     KC.Y,    KC.U,  KC.I,    KC.O,   KC.P,    KC.BSPC,
    KC.F9,   KC.F10,  KC.F11,        KC.F12,                KC.LCTL, KC.A, KC.S, KC.D, KC.F,   KC.G,                                     KC.H,    KC.J,  KC.K,    KC.L,   KC.SCLN, KC.ENT,
    KC.F5,   KC.F6,   KC.F7,         KC.F8,                 KC.LSFT, KC.Z, KC.X, KC.C, KC.V,   KC.B,                                     KC.N,    KC.M,  KC.COMM, KC.DOT, KC.SLSH,
    KC.F1,   KC.F2,   KC.F3,         KC.F4,                                                     keycode.MO(5), KC.LGUI, KC.SPC, KC.ESC, KC.RALT, keycode.MO(6),
    KC.KP_0,          KC.LEFT_SHIFT, KC.RIGHT_SHIFT,
});

/// Layer 5: ゲーミング数字/記号レイヤー
const layer5 = LAYOUT(.{
    KC.TRNS, KC.END,  KC.END,        KC.END,                KC.TAB,  KC.@"1", KC.@"2", KC.@"3", KC.@"4", KC.@"5",                       KC.@"6", KC.@"7", KC.@"8", KC.@"9", KC.@"0", KC.BSPC,
    KC.F9,   KC.F10,  KC.F11,        KC.F12,                KC.LCTL, KC.A,    KC.S,    KC.D,    KC.F,    KC.G,                            KC.MINS, KC.EQL,  KC.LBRC, KC.RBRC, KC.BSLS, KC.ENT,
    KC.F5,   KC.F6,   KC.F7,         KC.F8,                 KC.LSFT, KC.Z,    KC.X,    KC.C,    KC.V,    KC.B,                            KC.GRV,  KC.QUOT, KC.COMM, KC.DOT,  KC.SLSH,
    KC.F1,   KC.F2,   KC.F3,         KC.F4,                                                     KC.LCTL, KC.LGUI, KC.SPC, KC.ESC, KC.RALT, KC.NO,
    KC.KP_0,          KC.LEFT_SHIFT, KC.RIGHT_SHIFT,
});

/// Layer 6: ゲーミングファンクション/ナビゲーションレイヤー
const layer6 = LAYOUT(.{
    KC.TRNS, KC.END,  KC.END,        KC.END,                KC.F1, KC.F2,   KC.F3,   KC.F4,   KC.F5, KC.F6,                              KC.F7,       KC.F8,       KC.F9,      KC.F10,       KC.F11, KC.F12,
    KC.F9,   KC.F10,  KC.F11,        KC.F12,                KC.NO, KC.MUTE, KC.VOLD, KC.VOLU, KC.NO, KC.NO,                              KC.LEFT,     KC.DOWN,     KC.UP,      KC.RGHT,      KC.NO,  KC.NO,
    KC.F5,   KC.F6,   KC.F7,         KC.F8,                 KC.NO, KC.NO,   KC.NO,   KC.NO,   KC.NO, KC.NO,                              KC.MS_WH_LEFT, KC.MS_WH_DOWN, KC.MS_WH_UP, KC.MS_WH_RIGHT, KC.NO,
    KC.F1,   KC.F2,   KC.F3,         KC.F4,                                                   KC.LCTL, KC.LGUI, KC.SPC, KC.ESC, KC.RALT, KC.NO,
    KC.KP_0,          KC.LEFT_SHIFT, KC.RIGHT_SHIFT,
});

/// デフォルトキーマップ（7レイヤー分）
pub const default_keymap: keymap.Keymap = buildKeymap();

fn buildKeymap() keymap.Keymap {
    var km: keymap.Keymap = keymap.emptyKeymap();
    km[0] = layer0;
    km[1] = layer1;
    km[2] = layer2;
    km[3] = layer3;
    km[4] = layer4;
    km[5] = layer5;
    km[6] = layer6;
    return km;
}

// ============================================================
// テスト
// ============================================================

const testing = @import("std").testing;

test "ハードウェア設定が正しい" {
    try testing.expectEqual(@as(u8, 5), rows);
    try testing.expectEqual(@as(u8, 16), cols);
    try testing.expectEqual(@as(usize, 16), col_pins.len);
    try testing.expectEqual(@as(usize, 5), row_pins.len);
}

test "ピン番号が keyboard.json と一致する" {
    // Cols: GP28, GP27, GP26, GP22, GP21, GP20, GP19, GP18, GP12, GP11, GP10, GP9, GP8, GP7, GP6, GP5
    try testing.expectEqual(@as(gpio.Pin, 28), col_pins[0]);
    try testing.expectEqual(@as(gpio.Pin, 27), col_pins[1]);
    try testing.expectEqual(@as(gpio.Pin, 26), col_pins[2]);
    try testing.expectEqual(@as(gpio.Pin, 22), col_pins[3]);
    try testing.expectEqual(@as(gpio.Pin, 5), col_pins[15]);

    // Rows: GP13, GP14, GP15, GP16, GP17
    try testing.expectEqual(@as(gpio.Pin, 13), row_pins[0]);
    try testing.expectEqual(@as(gpio.Pin, 17), row_pins[4]);
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

    // Row 0: 16キー (index 0-15)
    try testing.expectEqual(@as(Keycode, 1), m[0][0]);
    try testing.expectEqual(@as(Keycode, 16), m[0][15]);

    // Row 1: 16キー (index 16-31)
    try testing.expectEqual(@as(Keycode, 17), m[1][0]);
    try testing.expectEqual(@as(Keycode, 32), m[1][15]);

    // Row 2: 15キー (index 32-46), col 15 は空
    try testing.expectEqual(@as(Keycode, 33), m[2][0]);
    try testing.expectEqual(@as(Keycode, 47), m[2][14]);
    try testing.expectEqual(KC.NO, m[2][15]);

    // Row 3: 10キー (index 47-56), cols 10-15 は空
    try testing.expectEqual(@as(Keycode, 48), m[3][0]);
    try testing.expectEqual(@as(Keycode, 57), m[3][9]);
    try testing.expectEqual(KC.NO, m[3][10]);
    try testing.expectEqual(KC.NO, m[3][15]);

    // Row 4: 3キー (index 57-59), cols 3-15 は空
    try testing.expectEqual(@as(Keycode, 58), m[4][0]);
    try testing.expectEqual(@as(Keycode, 60), m[4][2]);
    try testing.expectEqual(KC.NO, m[4][3]);
    try testing.expectEqual(KC.NO, m[4][15]);
}

test "デフォルトキーマップ: Layer 0 (QWERTY+テンキー) の検証" {
    const km = default_keymap;

    // テンキー部分 (Row 0)
    try testing.expectEqual(keycode.TG(4), km[0][0][0]);
    try testing.expectEqual(KC.NUM_LOCK, km[0][0][1]);
    try testing.expectEqual(KC.DEL, km[0][0][2]);
    try testing.expectEqual(KC.KP_SLASH, km[0][0][3]);

    // QWERTY部分 (Row 0)
    try testing.expectEqual(KC.TAB, km[0][0][4]);
    try testing.expectEqual(KC.Q, km[0][0][5]);
    try testing.expectEqual(KC.BSPC, km[0][0][15]);

    // Row 1
    try testing.expectEqual(KC.KP_7, km[0][1][0]);
    try testing.expectEqual(KC.LCTL, km[0][1][4]);
    try testing.expectEqual(KC.ENT, km[0][1][15]);

    // Row 2
    try testing.expectEqual(KC.KP_4, km[0][2][0]);
    try testing.expectEqual(KC.LSFT, km[0][2][4]);
    try testing.expectEqual(KC.SLSH, km[0][2][14]);

    // Row 3 (thumb cluster)
    try testing.expectEqual(KC.KP_1, km[0][3][0]);
    try testing.expectEqual(KC.KP_PLUS, km[0][3][3]);
    try testing.expectEqual(KC.LCTL, km[0][3][4]);
    try testing.expectEqual(keycode.LT(1, KC.SPC), km[0][3][6]);
    try testing.expectEqual(keycode.LT(2, KC.ESC), km[0][3][7]);
    try testing.expectEqual(keycode.MO(1), km[0][3][9]);

    // Row 4 (numpad bottom)
    try testing.expectEqual(KC.KP_0, km[0][4][0]);
    try testing.expectEqual(KC.KP_DOT, km[0][4][1]);
    try testing.expectEqual(KC.KP_ENTER, km[0][4][2]);
}

test "デフォルトキーマップ: Layer 1 (数字/記号) の検証" {
    const km = default_keymap;

    try testing.expectEqual(KC.@"1", km[1][0][5]);
    try testing.expectEqual(KC.@"0", km[1][0][14]);
    try testing.expectEqual(KC.MINS, km[1][1][10]);
    try testing.expectEqual(KC.EQL, km[1][1][11]);
    try testing.expectEqual(KC.LBRC, km[1][1][12]);
    try testing.expectEqual(KC.RBRC, km[1][1][13]);
    try testing.expectEqual(KC.BSLS, km[1][1][14]);
    try testing.expectEqual(KC.GRV, km[1][2][10]);
    try testing.expectEqual(KC.QUOT, km[1][2][11]);
}

test "デフォルトキーマップ: Layer 2 (ナビゲーション) の検証" {
    const km = default_keymap;

    try testing.expectEqual(KC.END, km[2][0][8]);
    try testing.expectEqual(KC.HOME, km[2][0][10]);
    try testing.expectEqual(KC.DEL, km[2][0][15]);
    try testing.expectEqual(KC.PGDN, km[2][1][8]);
    try testing.expectEqual(KC.LEFT, km[2][1][10]);
    try testing.expectEqual(KC.DOWN, km[2][1][11]);
    try testing.expectEqual(KC.UP, km[2][1][12]);
    try testing.expectEqual(KC.RGHT, km[2][1][13]);
    try testing.expectEqual(KC.PGUP, km[2][2][9]);
}

test "デフォルトキーマップ: Layer 3 (ファンクション/メディア) の検証" {
    const km = default_keymap;

    // ファンクションキー
    try testing.expectEqual(KC.F1, km[3][0][4]);
    try testing.expectEqual(KC.F12, km[3][0][15]);

    // メディアキー
    try testing.expectEqual(KC.MUTE, km[3][1][5]);
    try testing.expectEqual(KC.VOLD, km[3][1][6]);
    try testing.expectEqual(KC.VOLU, km[3][1][7]);
}

test "デフォルトキーマップ: Layer 4 (ゲーミング) の検証" {
    const km = default_keymap;

    // TG(4) でトグル
    try testing.expectEqual(KC.TRNS, km[4][0][0]);

    // QWERTY部分
    try testing.expectEqual(KC.TAB, km[4][0][4]);
    try testing.expectEqual(KC.Q, km[4][0][5]);
    try testing.expectEqual(KC.BSPC, km[4][0][15]);

    // MO(5), MO(6)
    try testing.expectEqual(keycode.MO(5), km[4][3][4]);
    try testing.expectEqual(keycode.MO(6), km[4][3][9]);
}

test "デフォルトキーマップ: 未使用レイヤーが空である" {
    const km = default_keymap;

    // Layer 7以降は全て KC.NO
    for (7..keymap.MAX_LAYERS) |l| {
        for (0..rows) |r| {
            for (0..cols) |c| {
                try testing.expectEqual(KC.NO, km[l][r][c]);
            }
        }
    }
}

test "matrixConfig: 設定値が正しい" {
    const cfg = matrixConfig();
    try testing.expectEqual(@as(usize, 16), cfg.col_pins.len);
    try testing.expectEqual(@as(usize, 5), cfg.row_pins.len);
}

test "LAYOUT関数: C版キーマップと等価な値を生成する" {
    // C版の LT(1,KC_SPC) = QK_LAYER_TAP | (1 << 8) | KC_SPC
    // = 0x4000 | 0x0100 | 0x2C = 0x412C
    try testing.expectEqual(@as(Keycode, 0x412C), keycode.LT(1, KC.SPC));

    // C版の LT(2,KC_ESC) = 0x4000 | 0x0200 | 0x29 = 0x4229
    try testing.expectEqual(@as(Keycode, 0x4229), keycode.LT(2, KC.ESC));

    // C版の MO(1) = QK_MOMENTARY | 1 = 0x5221
    try testing.expectEqual(@as(Keycode, 0x5221), keycode.MO(1));

    // Layer 0 の thumb キーが正しいことを確認
    const km = default_keymap;
    try testing.expectEqual(@as(Keycode, 0x412C), km[0][3][6]); // LT(1, KC_SPC)
    try testing.expectEqual(@as(Keycode, 0x4229), km[0][3][7]); // LT(2, KC_ESC)
    try testing.expectEqual(@as(Keycode, 0x5221), km[0][3][9]); // MO(1)
}
