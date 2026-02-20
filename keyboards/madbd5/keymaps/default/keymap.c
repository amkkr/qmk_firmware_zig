// Copyright 2023 QMK
// SPDX-License-Identifier: GPL-2.0-or-later

#include QMK_KEYBOARD_H

const uint16_t PROGMEM keymaps[][MATRIX_ROWS][MATRIX_COLS] = {
    [0] = LAYOUT(
        TG(4),   KC_NUM,  KC_DEL,    KC_KP_SLASH,           KC_TAB,  KC_Q, KC_W, KC_E, KC_R,    KC_T,                                 KC_Y,    KC_U, KC_I,    KC_O,   KC_P,    KC_BSPC,
        KC_KP_7, KC_KP_8, KC_KP_9,   KC_KP_ASTERISK,        KC_LCTL, KC_A, KC_S, KC_D, KC_F,    KC_G,                                 KC_H,    KC_J, KC_K,    KC_L,   KC_SCLN, KC_ENT,
        KC_KP_4, KC_KP_5, KC_KP_6,   KC_KP_MINUS,           KC_LSFT, KC_Z, KC_X, KC_C, KC_V,    KC_B,                                 KC_N,    KC_M, KC_COMM, KC_DOT, KC_SLSH,
        KC_KP_1, KC_KP_2, KC_KP_3,   KC_KP_PLUS,                                       KC_LCTL, KC_LGUI, LT(1,KC_SPC), LT(2, KC_ESC), KC_RALT, MO(1),
        KC_KP_0,          KC_KP_DOT, KC_KP_ENTER
    ),

    [1] = LAYOUT(
        TG(4),   KC_NUM,  KC_DEL,    KC_KP_SLASH,           KC_TAB,  KC_1,  KC_2,  KC_3,  KC_4,    KC_5,                            KC_6,    KC_7,    KC_8,    KC_9,    KC_0,    KC_BSPC,
        KC_KP_7, KC_KP_8, KC_KP_9,   KC_KP_ASTERISK,        KC_LCTL, KC_NO, KC_NO, KC_NO, KC_NO,   KC_NO,                           KC_MINS, KC_EQL,  KC_LBRC, KC_RBRC, KC_BSLS, KC_ENT,
        KC_KP_4, KC_KP_5, KC_KP_6,   KC_KP_MINUS,           KC_LSFT, KC_NO, KC_NO, KC_NO, KC_NO,   KC_SPC,                          KC_GRV,  KC_QUOT, KC_COMM, KC_DOT,  KC_SLSH,
        KC_KP_1, KC_KP_2, KC_KP_3,   KC_KP_PLUS,                                          KC_LCTL, KC_LGUI, KC_TRNS, LT(3, KC_ESC), KC_RALT, KC_NO,
        KC_KP_0,          KC_KP_DOT, KC_KP_ENTER
    ),

    [2] = LAYOUT(
        TG(4),   KC_NUM,  KC_DEL,    KC_KP_SLASH,           KC_TAB,  KC_NO, KC_NO, KC_NO, KC_END,  KC_NO,                          KC_HOME, KC_NO,   KC_NO, KC_NO,   KC_NO, KC_DEL,
        KC_KP_7, KC_KP_8, KC_KP_9,   KC_KP_ASTERISK,        KC_LCTL, KC_NO, KC_NO, KC_NO, KC_PGDN, KC_NO,                          KC_LEFT, KC_DOWN, KC_UP, KC_RGHT, KC_NO, KC_ENT,
        KC_KP_4, KC_KP_5, KC_KP_6,   KC_KP_MINUS,           KC_LSFT, KC_NO, KC_NO, KC_NO, KC_NO,   KC_PGUP,                        KC_NO,   KC_NO,   KC_NO, KC_NO,   KC_NO,
        KC_KP_1, KC_KP_2, KC_KP_3,   KC_KP_PLUS,                                          KC_LALT, KC_LGUI, LT(3,KC_SPC), KC_TRNS, KC_RALT, KC_NO,
        KC_KP_0,          KC_KP_DOT, KC_KP_ENTER
    ),

    [3] = LAYOUT(
        TG(4),   KC_NUM,  KC_DEL,    KC_KP_SLASH,           KC_F1, KC_F2,   KC_F3,   KC_F4,   KC_F5,   KC_F6,                    KC_F7,   KC_F8, KC_F9, KC_F10, KC_F11, KC_F12,
        KC_KP_7, KC_KP_8, KC_KP_9,   KC_KP_ASTERISK,        KC_NO, KC_MUTE, KC_VOLD, KC_VOLU, KC_NO,   KC_NO,                    KC_NO,   KC_NO, KC_NO, KC_NO,  KC_NO,  KC_ENT,
        KC_KP_4, KC_KP_5, KC_KP_6,   KC_KP_MINUS,           KC_NO, KC_NO,   KC_NO,   KC_NO,   KC_NO,   KC_NO,                    KC_NO,   KC_NO, KC_NO, KC_NO,  KC_NO,
        KC_KP_1, KC_KP_2, KC_KP_3,   KC_KP_PLUS,                                              KC_LCTL, KC_LGUI, KC_TRNS,KC_TRNS, KC_RALT, KC_NO,
        KC_KP_0,          KC_KP_DOT, KC_KP_ENTER
    ),

    [4] = LAYOUT(
        KC_TRNS, KC_END,  KC_END,        KC_END,            KC_TAB,  KC_Q, KC_W, KC_E, KC_R,   KC_T,                    KC_Y,    KC_U,  KC_I,    KC_O,   KC_P,    KC_BSPC,
        KC_F9,   KC_F10,  KC_F11,        KC_F12,            KC_LCTL, KC_A, KC_S, KC_D, KC_F,   KC_G,                    KC_H,    KC_J,  KC_K,    KC_L,   KC_SCLN, KC_ENT,
        KC_F5,   KC_F6,   KC_F7,         KC_F8,             KC_LSFT, KC_Z, KC_X, KC_C, KC_V,   KC_B,                    KC_N,    KC_M,  KC_COMM, KC_DOT, KC_SLSH,
        KC_F1,   KC_F2,   KC_F3,         KC_F4,                                        MO(5),  KC_LGUI, KC_SPC, KC_ESC, KC_RALT, MO(6),
        KC_KP_0,          KC_LEFT_SHIFT, KC_RIGHT_SHIFT
    ),

    [5] = LAYOUT(
        KC_TRNS, KC_END,  KC_END,        KC_END,            KC_TAB,  KC_1, KC_2, KC_3, KC_4,    KC_5,                    KC_6,    KC_7,    KC_8,    KC_9,    KC_0,    KC_BSPC,
        KC_F9,   KC_F10,  KC_F11,        KC_F12,            KC_LCTL, KC_A, KC_S, KC_D, KC_F,    KC_G,                    KC_MINS, KC_EQL,  KC_LBRC, KC_RBRC, KC_BSLS, KC_ENT,
        KC_F5,   KC_F6,   KC_F7,         KC_F8,             KC_LSFT, KC_Z, KC_X, KC_C, KC_V,    KC_B,                    KC_GRV,  KC_QUOT, KC_COMM, KC_DOT,  KC_SLSH,
        KC_F1,   KC_F2,   KC_F3,         KC_F4,                                        KC_LCTL, KC_LGUI, KC_SPC, KC_ESC, KC_RALT, KC_NO,
        KC_KP_0,          KC_LEFT_SHIFT, KC_RIGHT_SHIFT
    ),

    [6] = LAYOUT(
        KC_TRNS, KC_END,  KC_END,        KC_END,            KC_F1, KC_F2,   KC_F3,   KC_F4,   KC_F5, KC_F6,                     KC_F7,   KC_F8,   KC_F9,   KC_F10,  KC_F11, KC_F12,
        KC_F9,   KC_F10,  KC_F11,        KC_F12,            KC_NO, KC_MUTE, KC_VOLD, KC_VOLU, KC_NO, KC_NO,                     KC_LEFT, KC_DOWN, KC_UP,   KC_RGHT, KC_NO,  KC_NO,
        KC_F5,   KC_F6,   KC_F7,         KC_F8,             KC_NO, KC_NO,   KC_NO,   KC_NO,   KC_NO, KC_NO,                     MS_WHLL, MS_WHLD, MS_WHLU, MS_WHLR, KC_NO,
        KC_F1,   KC_F2,   KC_F3,         KC_F4,                                               KC_LCTL, KC_LGUI, KC_SPC, KC_ESC, KC_RALT, KC_NO,
        KC_KP_0,          KC_LEFT_SHIFT, KC_RIGHT_SHIFT
    )
};
