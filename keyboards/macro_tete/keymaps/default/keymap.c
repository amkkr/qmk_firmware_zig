// Copyright 2023 QMK
// SPDX-License-Identifier: GPL-2.0-or-later

#include QMK_KEYBOARD_H

const uint16_t PROGMEM keymaps[][MATRIX_ROWS][MATRIX_COLS] = {
    [0] = LAYOUT(
        LGUI(KC_Z),LGUI(LSFT(KC_Z)),LGUI(KC_A),
        LGUI(KC_X),LGUI(KC_C),LGUI(KC_V)
    )
    // [0] = LAYOUT(
        // LCTL(KC_Z),LCTL(KC_Y),LCTL(KC_A),
        // LCTL(KC_X),LCTL(KC_C),LCTL(KC_V)
    // )
};
