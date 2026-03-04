// Copyright 2024 amkkr
// SPDX-License-Identifier: GPL-2.0-or-later

//! USB プロトコル詳細テスト
//!
//! usb.zig / usb_descriptors.zig / clock.zig の既存テストで
//! カバーされていないエッジケースおよび新機能を検証する。
//!
//! テスト対象:
//! 1. SETUP 受信時の data toggle リセット (DATA1)
//! 2. SIE_CTRL EP0_INT_1BUF 定数
//! 3. SET_CONFIGURATION で EP4-EP5 の data toggle もリセット
//! 4. CDC TX ring buffer 満杯時のデータ破棄
//! 5. handleBusReset で ep0_out_pending がクリアされる
//! 6. disconnect → bus reset → re-enumerate シーケンス
//! 7. USB ディスクリプタのポーリングインターバルとエンドポイントサイズ
//! 8. clock.zig の追加定数検証

const std = @import("std");
const testing = std.testing;

const usb = @import("../hal/usb.zig");
const usb_descriptors = @import("../hal/usb_descriptors.zig");
const clock = @import("../hal/clock.zig");

const UsbDriver = usb.UsbDriver;
const SetupPacket = usb.SetupPacket;
const Request = usb.Request;
const HidRequest = usb.HidRequest;
const DeviceState = usb.DeviceState;
const Ep0OutPending = usb.Ep0OutPending;
const IntBit = usb.IntBit;
const SieCtrl = usb.SieCtrl;

// UsbDriver 内の BUFF_STATUS 定数を参照
const BUFF_STATUS_EP0_IN: u32 = UsbDriver.BUFF_STATUS_EP0_IN;
const BUFF_STATUS_EP0_OUT: u32 = UsbDriver.BUFF_STATUS_EP0_OUT;

// ============================================================
// 1. SETUP 受信時の data toggle リセット
// ============================================================

test "handleSetupFromHw resets EP0 data toggle to DATA1" {
    var drv = UsbDriver{};
    drv.init();

    // data_toggle[0] を false に設定（DATA0）
    drv.data_toggle[0] = false;

    // mock SETUP パケット (SET_ADDRESS) を設定して task() 経由で処理
    drv.mock_ints = IntBit.SETUP_REQ;
    drv.mock_setup_packet = .{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_ADDRESS,
        .wValue = 3,
    };
    drv.task();

    // handleSetupFromHw 内で data_toggle[0] が true (DATA1) にリセットされ、
    // その後 sendStatusStageZlp で反転されるため、最終的に false になる。
    // 重要なのは処理前に DATA1 にリセットされること。
    // SET_ADDRESS は ZLP を1回送信するので toggle は DATA1→DATA0 に戻る。
    // つまり: reset to true → ZLP flips to false
    try testing.expectEqual(false, drv.data_toggle[0]);
}

test "handleSetupFromHw data toggle reset then GET_DESCRIPTOR" {
    var drv = UsbDriver{};
    drv.init();

    // 前のトランザクションで toggle が false (DATA0) のまま
    // リセットなしだと: false → (変化なし) → flip → true
    // リセットありだと: false → reset to true → flip → false
    // 期待値 false はリセットがあることを検証する
    drv.data_toggle[0] = false;

    // SETUP で GET_DESCRIPTOR (DEVICE) を処理
    drv.mock_ints = IntBit.SETUP_REQ;
    drv.mock_setup_packet = .{
        .bmRequestType = 0x80,
        .bRequest = Request.GET_DESCRIPTOR,
        .wValue = @as(u16, usb_descriptors.DescriptorType.DEVICE) << 8,
        .wIndex = 0,
        .wLength = 18,
    };
    drv.task();

    // handleSetupFromHw は data_toggle[0] を true (DATA1) にリセットし、
    // sendEp0InPacket が1回フリップする → false。
    // Device descriptor (18 bytes) は1パケットに収まるため、1回のフリップ。
    // リセットがなければ false → flip → true になるので、false で検証できる。
    try testing.expectEqual(false, drv.data_toggle[0]);
}

test "multiple SETUP packets each reset data toggle" {
    var drv = UsbDriver{};
    drv.init();

    // 第1の SETUP (SET_IDLE)
    drv.mock_ints = IntBit.SETUP_REQ;
    drv.mock_setup_packet = .{
        .bmRequestType = 0x21,
        .bRequest = HidRequest.SET_IDLE,
        .wValue = 0x0400,
    };
    drv.task();
    const toggle_after_first = drv.data_toggle[0];

    // 第2の SETUP (SET_IDLE) — data toggle が再度リセットされる
    drv.mock_ints = IntBit.SETUP_REQ;
    drv.mock_setup_packet = .{
        .bmRequestType = 0x21,
        .bRequest = HidRequest.SET_IDLE,
        .wValue = 0x0800,
    };
    drv.task();

    // 両方とも同じパターン: reset to DATA1 → ZLP → DATA0
    try testing.expectEqual(toggle_after_first, drv.data_toggle[0]);
}

// ============================================================
// 2. SIE_CTRL EP0_INT_1BUF 定数
// ============================================================

test "SIE_CTRL EP0_INT_1BUF is bit 29" {
    try testing.expectEqual(@as(u32, 1 << 29), SieCtrl.EP0_INT_1BUF);
}

test "SIE_CTRL PULLUP_EN is bit 16" {
    try testing.expectEqual(@as(u32, 1 << 16), SieCtrl.PULLUP_EN);
}

test "SIE_CTRL EP0_INT_1BUF and PULLUP_EN do not overlap" {
    try testing.expectEqual(@as(u32, 0), SieCtrl.EP0_INT_1BUF & SieCtrl.PULLUP_EN);
}

// ============================================================
// 3. SET_CONFIGURATION で EP4-EP6 の data toggle もリセット
// ============================================================

test "SET_CONFIGURATION resets EP1-EP6 data toggle to DATA0" {
    var drv = UsbDriver{};
    drv.init();

    // EP4, EP5, EP6 の data toggle を true に設定
    drv.data_toggle[4] = true;
    drv.data_toggle[5] = true;
    drv.data_toggle[6] = true;

    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_CONFIGURATION,
        .wValue = 1,
    });

    try testing.expectEqual(DeviceState.configured, drv.state);
    // USB 2.0 spec §9.4.7: EP1-EP6 全てリセット
    try testing.expectEqual(false, drv.data_toggle[1]);
    try testing.expectEqual(false, drv.data_toggle[2]);
    try testing.expectEqual(false, drv.data_toggle[3]);
    try testing.expectEqual(false, drv.data_toggle[4]);
    try testing.expectEqual(false, drv.data_toggle[5]);
    try testing.expectEqual(false, drv.data_toggle[6]);
}

test "SET_CONFIGURATION deconfigure resets EP4-EP6 data toggle" {
    var drv = UsbDriver{};
    drv.init();

    // まず configure
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_CONFIGURATION,
        .wValue = 1,
    });

    // EP4, EP5, EP6 にアクティビティ
    drv.data_toggle[4] = true;
    drv.data_toggle[5] = true;
    drv.data_toggle[6] = true;

    // deconfigure (configuration = 0)
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_CONFIGURATION,
        .wValue = 0,
    });

    try testing.expectEqual(DeviceState.addressed, drv.state);
    try testing.expectEqual(false, drv.data_toggle[4]);
    try testing.expectEqual(false, drv.data_toggle[5]);
    try testing.expectEqual(false, drv.data_toggle[6]);
}

// ============================================================
// 4. CDC TX ring buffer 満杯時のデータ破棄
// ============================================================

test "CDC TX ring buffer drops data when full" {
    var drv = UsbDriver{};
    drv.init();

    // 255 バイト書き込み（バッファは u8 で管理、満杯は head + 1 == tail）
    var data: [255]u8 = undefined;
    for (&data, 0..) |*b, i| {
        b.* = @intCast(i & 0xFF);
    }
    drv.cdcWrite(&data);

    // head は 255 ラップアラウンドで 255
    try testing.expectEqual(@as(u8, 255), drv.cdc_tx_head);
    try testing.expectEqual(@as(u8, 0), drv.cdc_tx_tail);

    // さらに書き込もうとすると next_head == tail でドロップされる
    drv.cdcWrite("X");
    // head は変わらない（バッファ満杯でドロップ）
    try testing.expectEqual(@as(u8, 255), drv.cdc_tx_head);
}

test "CDC TX ring buffer wraps correctly after flush" {
    var drv = UsbDriver{};
    drv.init();
    drv.state = .configured;

    // 初回書き込み
    drv.cdcWrite("ABCDE");
    try testing.expectEqual(@as(u8, 5), drv.cdc_tx_head);

    // フラッシュ
    drv.cdcFlush();
    try testing.expectEqual(@as(u8, 5), drv.cdc_tx_tail);

    // 再度書き込み（ラップアラウンド前）
    drv.cdcWrite("FGH");
    try testing.expectEqual(@as(u8, 8), drv.cdc_tx_head);

    // フラッシュ
    drv.cdcFlush();
    try testing.expectEqual(@as(u8, 8), drv.cdc_tx_tail);
}

// ============================================================
// 5. handleBusReset で ep0_out_pending がクリアされる
// ============================================================

test "handleBusReset clears ep0_out_pending set_report" {
    var drv = UsbDriver{};
    drv.init();

    // SET_REPORT を送信して pending にする
    drv.handleSetup(&.{
        .bmRequestType = 0x21,
        .bRequest = HidRequest.SET_REPORT,
        .wValue = 0x0200,
        .wIndex = usb_descriptors.KEYBOARD_INTERFACE,
        .wLength = 1,
    });
    try testing.expectEqual(Ep0OutPending.set_report, drv.ep0_out_pending);

    // bus reset
    drv.handleBusReset();

    // ep0_out_pending がクリアされている
    try testing.expectEqual(Ep0OutPending.none, drv.ep0_out_pending);
}

test "handleBusReset clears ep0_out_pending set_line_coding" {
    var drv = UsbDriver{};
    drv.init();

    // SET_LINE_CODING を送信して pending にする
    drv.handleSetup(&.{
        .bmRequestType = 0x21,
        .bRequest = usb_descriptors.CdcRequest.SET_LINE_CODING,
        .wValue = 0,
        .wIndex = usb_descriptors.CDC_COMM_INTERFACE,
        .wLength = 7,
    });
    try testing.expectEqual(Ep0OutPending.set_line_coding, drv.ep0_out_pending);

    // bus reset
    drv.handleBusReset();

    try testing.expectEqual(Ep0OutPending.none, drv.ep0_out_pending);
}

// ============================================================
// 6. disconnect → bus reset → re-enumerate シーケンス
// ============================================================

test "full enumeration sequence: init → SET_ADDRESS → SET_CONFIGURATION → BUS_RESET → re-enumerate" {
    var drv = UsbDriver{};
    drv.init();

    // Step 1: SET_ADDRESS
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_ADDRESS,
        .wValue = 7,
    });
    try testing.expectEqual(@as(u8, 7), drv.address);
    try testing.expectEqual(DeviceState.addressed, drv.state);

    // Step 2: SET_CONFIGURATION
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_CONFIGURATION,
        .wValue = 1,
    });
    try testing.expectEqual(DeviceState.configured, drv.state);
    try testing.expect(drv.isConfigured());

    // Step 3: いくつかのデータを転送
    drv.data_toggle[1] = true;
    drv.data_toggle[2] = true;
    drv.cdcWrite("Hello");
    drv.keyboard_leds = 0x03;

    // Step 4: BUS_RESET
    drv.handleBusReset();
    try testing.expectEqual(DeviceState.default_state, drv.state);
    try testing.expectEqual(@as(u8, 0), drv.address);
    try testing.expectEqual(@as(u8, 0), drv.configuration);
    try testing.expect(!drv.isConfigured());
    // data toggle リセット
    for (drv.data_toggle) |t| {
        try testing.expectEqual(false, t);
    }
    // CDC TX バッファクリア
    try testing.expectEqual(@as(u8, 0), drv.cdc_tx_head);
    try testing.expectEqual(@as(u8, 0), drv.cdc_tx_tail);

    // Step 5: 再列挙
    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_ADDRESS,
        .wValue = 12,
    });
    try testing.expectEqual(@as(u8, 12), drv.address);

    drv.handleSetup(&.{
        .bmRequestType = 0x00,
        .bRequest = Request.SET_CONFIGURATION,
        .wValue = 1,
    });
    try testing.expectEqual(DeviceState.configured, drv.state);
    try testing.expect(drv.isConfigured());
}

// ============================================================
// 7. USB ディスクリプタ定数の検証
// ============================================================

test "HID endpoint polling intervals are 1ms" {
    try testing.expectEqual(@as(u8, 1), usb_descriptors.KEYBOARD_INTERVAL);
    try testing.expectEqual(@as(u8, 1), usb_descriptors.MOUSE_INTERVAL);
    try testing.expectEqual(@as(u8, 1), usb_descriptors.EXTRA_INTERVAL);
}

test "CDC notification interval is 255ms" {
    try testing.expectEqual(@as(u8, 255), usb_descriptors.CDC_NOTIFICATION_INTERVAL);
}

test "HID endpoint sizes are 8 bytes" {
    try testing.expectEqual(@as(u8, 8), usb_descriptors.KEYBOARD_ENDPOINT_SIZE);
    try testing.expectEqual(@as(u8, 8), usb_descriptors.MOUSE_ENDPOINT_SIZE);
    try testing.expectEqual(@as(u8, 8), usb_descriptors.EXTRA_ENDPOINT_SIZE);
}

test "CDC notification endpoint size is 8 bytes" {
    try testing.expectEqual(@as(u8, 8), usb_descriptors.CDC_NOTIFICATION_ENDPOINT_SIZE);
}

test "CDC data endpoint size is 64 bytes" {
    try testing.expectEqual(@as(u8, 64), usb_descriptors.CDC_DATA_ENDPOINT_SIZE);
}

test "endpoint numbers are sequential 1-6" {
    try testing.expectEqual(@as(u8, 1), usb_descriptors.KEYBOARD_ENDPOINT);
    try testing.expectEqual(@as(u8, 2), usb_descriptors.MOUSE_ENDPOINT);
    try testing.expectEqual(@as(u8, 3), usb_descriptors.EXTRA_ENDPOINT);
    try testing.expectEqual(@as(u8, 4), usb_descriptors.NKRO_ENDPOINT);
    try testing.expectEqual(@as(u8, 5), usb_descriptors.CDC_NOTIFICATION_ENDPOINT);
    try testing.expectEqual(@as(u8, 6), usb_descriptors.CDC_DATA_ENDPOINT);
}

test "interface numbers are sequential 0-5" {
    try testing.expectEqual(@as(u8, 0), usb_descriptors.KEYBOARD_INTERFACE);
    try testing.expectEqual(@as(u8, 1), usb_descriptors.MOUSE_INTERFACE);
    try testing.expectEqual(@as(u8, 2), usb_descriptors.EXTRA_INTERFACE);
    try testing.expectEqual(@as(u8, 3), usb_descriptors.NKRO_INTERFACE);
    try testing.expectEqual(@as(u8, 4), usb_descriptors.CDC_COMM_INTERFACE);
    try testing.expectEqual(@as(u8, 5), usb_descriptors.CDC_DATA_INTERFACE);
    try testing.expectEqual(@as(u8, 6), usb_descriptors.NUM_INTERFACES);
}

test "configuration descriptor endpoint intervals match constants" {
    // エンドポイントディスクリプタ内の bInterval を検証
    var i: usize = 0;
    var found_keyboard_ep = false;
    var found_cdc_notification_ep = false;
    while (i < usb_descriptors.configuration_descriptor.len) {
        const len = usb_descriptors.configuration_descriptor[i];
        if (len == 0) break;
        if (i + 1 < usb_descriptors.configuration_descriptor.len and
            usb_descriptors.configuration_descriptor[i + 1] == usb_descriptors.DescriptorType.ENDPOINT and
            len == 7)
        {
            const addr = usb_descriptors.configuration_descriptor[i + 2];
            const interval = usb_descriptors.configuration_descriptor[i + 6];

            // Keyboard EP (EP1 IN, 0x81)
            if (addr == (usb_descriptors.KEYBOARD_ENDPOINT | usb_descriptors.EndpointDirection.IN)) {
                try testing.expectEqual(@as(u8, 1), interval);
                found_keyboard_ep = true;
            }
            // CDC Notification EP (EP4 IN, 0x84)
            if (addr == (usb_descriptors.CDC_NOTIFICATION_ENDPOINT | usb_descriptors.EndpointDirection.IN)) {
                try testing.expectEqual(@as(u8, 255), interval);
                found_cdc_notification_ep = true;
            }
        }
        i += len;
    }
    try testing.expect(found_keyboard_ep);
    try testing.expect(found_cdc_notification_ep);
}

test "CDC data endpoint bInterval is 0 (bulk)" {
    var i: usize = 0;
    var found_bulk_ep = false;
    while (i < usb_descriptors.configuration_descriptor.len) {
        const len = usb_descriptors.configuration_descriptor[i];
        if (len == 0) break;
        if (i + 1 < usb_descriptors.configuration_descriptor.len and
            usb_descriptors.configuration_descriptor[i + 1] == usb_descriptors.DescriptorType.ENDPOINT and
            len == 7)
        {
            const addr = usb_descriptors.configuration_descriptor[i + 2];
            const attr = usb_descriptors.configuration_descriptor[i + 3];
            const interval = usb_descriptors.configuration_descriptor[i + 6];

            // CDC Data IN EP (EP5 IN, 0x85, Bulk)
            if (addr == (usb_descriptors.CDC_DATA_ENDPOINT | usb_descriptors.EndpointDirection.IN) and
                attr == usb_descriptors.EndpointTransfer.BULK)
            {
                try testing.expectEqual(@as(u8, 0), interval);
                found_bulk_ep = true;
            }
        }
        i += len;
    }
    try testing.expect(found_bulk_ep);
}

// ============================================================
// 8. clock.zig の追加定数検証
// ============================================================

test "clock DIV_1 is integer 1 shifted by 8" {
    // DIV_1 = 1 << 8 = 256 (1:1 分周、整数部1、小数部0)
    try testing.expectEqual(@as(u32, 256), clock.ClockRegs.DIV_1);
    try testing.expectEqual(@as(u32, 1 << 8), clock.ClockRegs.DIV_1);
}

test "clk_ref source constants are distinct" {
    try testing.expect(clock.ClockRegs.CLK_REF_SRC_ROSC != clock.ClockRegs.CLK_REF_SRC_AUX);
    try testing.expect(clock.ClockRegs.CLK_REF_SRC_ROSC != clock.ClockRegs.CLK_REF_SRC_XOSC);
    try testing.expect(clock.ClockRegs.CLK_REF_SRC_AUX != clock.ClockRegs.CLK_REF_SRC_XOSC);
}

test "clk_sys source constants" {
    try testing.expectEqual(@as(u32, 0), clock.ClockRegs.CLK_SYS_SRC_REF);
    try testing.expectEqual(@as(u32, 1), clock.ClockRegs.CLK_SYS_SRC_AUX);
    try testing.expectEqual(@as(u32, 0), clock.ClockRegs.CLK_SYS_AUXSRC_PLL_SYS);
}

// ============================================================
// 9. USB レジスタ定数のクロスチェック
// ============================================================

test "USB register base addresses" {
    try testing.expectEqual(@as(u32, 0x50110000), usb.USBCTRL_REGS_BASE);
    try testing.expectEqual(@as(u32, 0x50100000), usb.USBCTRL_DPRAM_BASE);
}

test "USB register offsets" {
    try testing.expectEqual(@as(u32, 0x00), usb.Reg.ADDR_ENDP);
    try testing.expectEqual(@as(u32, 0x40), usb.Reg.MAIN_CTRL);
    try testing.expectEqual(@as(u32, 0x4C), usb.Reg.SIE_CTRL);
    try testing.expectEqual(@as(u32, 0x50), usb.Reg.SIE_STATUS);
    try testing.expectEqual(@as(u32, 0x58), usb.Reg.BUFF_STATUS);
    try testing.expectEqual(@as(u32, 0x90), usb.Reg.INTE);
}

test "USB interrupt bits are non-overlapping" {
    try testing.expectEqual(@as(u32, 0), IntBit.BUFF_STATUS & IntBit.BUS_RESET);
    try testing.expectEqual(@as(u32, 0), IntBit.BUFF_STATUS & IntBit.SETUP_REQ);
    try testing.expectEqual(@as(u32, 0), IntBit.BUS_RESET & IntBit.SETUP_REQ);
}

test "SieStatus bits are correct" {
    try testing.expectEqual(@as(u32, 1 << 17), usb.SieStatus.SETUP_REC);
    try testing.expectEqual(@as(u32, 1 << 19), usb.SieStatus.BUS_RESET);
}

// ============================================================
// 10. CDC class request の追加テスト
// ============================================================

test "CDC unknown class request stalls" {
    var drv = UsbDriver{};
    drv.init();

    // 不明な CDC class request
    drv.handleSetup(&.{
        .bmRequestType = 0x21,
        .bRequest = 0xFF, // 不明
        .wValue = 0,
        .wIndex = usb_descriptors.CDC_COMM_INTERFACE,
        .wLength = 0,
    });

    // stall endpoint (ep0_in_data は null のまま)
    try testing.expect(drv.ep0_in_data == null);
    try testing.expectEqual(@as(u16, 0), drv.ep0_in_total_len);
}

test "SET_PROTOCOL for mouse interface updates mouse_protocol" {
    var drv = UsbDriver{};
    drv.init();

    // Mouse を boot protocol に設定
    drv.handleSetup(&.{
        .bmRequestType = 0x21,
        .bRequest = HidRequest.SET_PROTOCOL,
        .wValue = 0, // boot protocol
        .wIndex = usb_descriptors.MOUSE_INTERFACE,
    });

    try testing.expectEqual(usb.HidProtocol.boot, drv.mouse_protocol);
    // Keyboard は変わらない
    try testing.expectEqual(usb.HidProtocol.report, drv.keyboard_protocol);

    // Mouse を report protocol に戻す
    drv.handleSetup(&.{
        .bmRequestType = 0x21,
        .bRequest = HidRequest.SET_PROTOCOL,
        .wValue = 1, // report protocol
        .wIndex = usb_descriptors.MOUSE_INTERFACE,
    });

    try testing.expectEqual(usb.HidProtocol.report, drv.mouse_protocol);
}

test "GET_LINE_CODING after SET_LINE_CODING reflects updated values" {
    var drv = UsbDriver{};
    drv.init();

    // SET_LINE_CODING で 9600 baud に変更
    drv.handleSetup(&.{
        .bmRequestType = 0x21,
        .bRequest = usb_descriptors.CdcRequest.SET_LINE_CODING,
        .wValue = 0,
        .wIndex = usb_descriptors.CDC_COMM_INTERFACE,
        .wLength = 7,
    });

    const lc = usb_descriptors.LineCoding{
        .dwDTERate = 9600,
        .bCharFormat = 0,
        .bParityType = 0,
        .bDataBits = 8,
    };
    drv.mock_ep0_out_buf = @bitCast(lc);
    drv.mock_buff_status = BUFF_STATUS_EP0_OUT;
    drv.mock_ints = IntBit.BUFF_STATUS;
    drv.task();

    try testing.expectEqual(@as(u32, 9600), drv.cdc_line_coding.dwDTERate);

    // GET_LINE_CODING で更新された値が返る
    drv.data_toggle[0] = false;
    drv.handleSetup(&.{
        .bmRequestType = 0xA1,
        .bRequest = usb_descriptors.CdcRequest.GET_LINE_CODING,
        .wValue = 0,
        .wIndex = usb_descriptors.CDC_COMM_INTERFACE,
        .wLength = 7,
    });

    try testing.expectEqual(@as(u16, 7), drv.ep0_in_total_len);
    const reply_lc: usb_descriptors.LineCoding = @bitCast(drv.ep0_reply_buf[0..7].*);
    try testing.expectEqual(@as(u32, 9600), reply_lc.dwDTERate);
}

test "SET_CONTROL_LINE_STATE DTR only" {
    var drv = UsbDriver{};
    drv.init();

    // DTR のみ (bit 0)
    drv.handleSetup(&.{
        .bmRequestType = 0x21,
        .bRequest = usb_descriptors.CdcRequest.SET_CONTROL_LINE_STATE,
        .wValue = 0x01,
        .wIndex = usb_descriptors.CDC_COMM_INTERFACE,
        .wLength = 0,
    });

    try testing.expect(drv.cdcDtrActive());
    try testing.expectEqual(@as(u16, 0x01), drv.cdc_control_line_state);

    // DTR クリア
    drv.handleSetup(&.{
        .bmRequestType = 0x21,
        .bRequest = usb_descriptors.CdcRequest.SET_CONTROL_LINE_STATE,
        .wValue = 0x00,
        .wIndex = usb_descriptors.CDC_COMM_INTERFACE,
        .wLength = 0,
    });

    try testing.expect(!drv.cdcDtrActive());
}

// ============================================================
// 11. BufCtrl 定数の検証
// ============================================================

test "BufCtrl bit constants" {
    try testing.expectEqual(@as(u32, 1 << 15), usb.BufCtrl.FULL);
    try testing.expectEqual(@as(u32, 1 << 14), usb.BufCtrl.LAST);
    try testing.expectEqual(@as(u32, 1 << 13), usb.BufCtrl.DATA_PID);
    try testing.expectEqual(@as(u32, 1 << 10), usb.BufCtrl.AVAILABLE);
    try testing.expectEqual(@as(u32, 0x3FF), usb.BufCtrl.LEN_MASK);
}

test "BufCtrl EP0_OUT_ADDR is correct" {
    // EP0 OUT buf ctrl = DPRAM + 0x80 + 4 = DPRAM + 0x84
    const expected = usb.USBCTRL_DPRAM_BASE + usb.DPRAM.EP_BUF_CTRL_BASE + 4;
    try testing.expectEqual(expected, usb.BufCtrl.EP0_OUT_ADDR);
}

// ============================================================
// 12. EP0 OUT data phase 直後の挙動
// ============================================================

test "EP0 OUT BUFF_STATUS without pending is no-op" {
    var drv = UsbDriver{};
    drv.init();

    // ep0_out_pending が none のとき EP0 OUT BUFF_STATUS が来ても何もしない
    drv.ep0_out_pending = .none;
    drv.mock_buff_status = BUFF_STATUS_EP0_OUT;
    drv.mock_ints = IntBit.BUFF_STATUS;
    drv.task();

    // 状態は変わらない
    try testing.expectEqual(Ep0OutPending.none, drv.ep0_out_pending);
    try testing.expectEqual(@as(u8, 0), drv.keyboard_leds);
}

// ============================================================
// 13. LineCoding の comptime サイズ検証
// ============================================================

test "LineCoding default values" {
    const lc = usb_descriptors.LineCoding{};
    try testing.expectEqual(@as(u32, 115200), lc.dwDTERate);
    try testing.expectEqual(@as(u8, 0), lc.bCharFormat);
    try testing.expectEqual(@as(u8, 0), lc.bParityType);
    try testing.expectEqual(@as(u8, 8), lc.bDataBits);
}

test "LineCoding bitcast roundtrip" {
    const lc = usb_descriptors.LineCoding{
        .dwDTERate = 230400,
        .bCharFormat = 2, // 2 stop bits
        .bParityType = 1, // odd parity
        .bDataBits = 7,
    };
    const bytes: [7]u8 = @bitCast(lc);
    const lc2: usb_descriptors.LineCoding = @bitCast(bytes);
    try testing.expectEqual(lc.dwDTERate, lc2.dwDTERate);
    try testing.expectEqual(lc.bCharFormat, lc2.bCharFormat);
    try testing.expectEqual(lc.bParityType, lc2.bParityType);
    try testing.expectEqual(lc.bDataBits, lc2.bDataBits);
}

// ============================================================
// 14. USB request 定数の整合性
// ============================================================

test "standard USB request codes" {
    try testing.expectEqual(@as(u8, 0), Request.GET_STATUS);
    try testing.expectEqual(@as(u8, 1), Request.CLEAR_FEATURE);
    try testing.expectEqual(@as(u8, 3), Request.SET_FEATURE);
    try testing.expectEqual(@as(u8, 5), Request.SET_ADDRESS);
    try testing.expectEqual(@as(u8, 6), Request.GET_DESCRIPTOR);
    try testing.expectEqual(@as(u8, 8), Request.GET_CONFIGURATION);
    try testing.expectEqual(@as(u8, 9), Request.SET_CONFIGURATION);
    try testing.expectEqual(@as(u8, 10), Request.GET_INTERFACE);
    try testing.expectEqual(@as(u8, 11), Request.SET_INTERFACE);
}

test "HID request codes" {
    try testing.expectEqual(@as(u8, 0x01), HidRequest.GET_REPORT);
    try testing.expectEqual(@as(u8, 0x02), HidRequest.GET_IDLE);
    try testing.expectEqual(@as(u8, 0x03), HidRequest.GET_PROTOCOL);
    try testing.expectEqual(@as(u8, 0x09), HidRequest.SET_REPORT);
    try testing.expectEqual(@as(u8, 0x0A), HidRequest.SET_IDLE);
    try testing.expectEqual(@as(u8, 0x0B), HidRequest.SET_PROTOCOL);
}

test "CDC request codes" {
    try testing.expectEqual(@as(u8, 0x20), usb_descriptors.CdcRequest.SET_LINE_CODING);
    try testing.expectEqual(@as(u8, 0x21), usb_descriptors.CdcRequest.GET_LINE_CODING);
    try testing.expectEqual(@as(u8, 0x22), usb_descriptors.CdcRequest.SET_CONTROL_LINE_STATE);
}

test "descriptor type constants" {
    try testing.expectEqual(@as(u8, 0x01), usb_descriptors.DescriptorType.DEVICE);
    try testing.expectEqual(@as(u8, 0x02), usb_descriptors.DescriptorType.CONFIGURATION);
    try testing.expectEqual(@as(u8, 0x03), usb_descriptors.DescriptorType.STRING);
    try testing.expectEqual(@as(u8, 0x04), usb_descriptors.DescriptorType.INTERFACE);
    try testing.expectEqual(@as(u8, 0x05), usb_descriptors.DescriptorType.ENDPOINT);
    try testing.expectEqual(@as(u8, 0x0B), usb_descriptors.DescriptorType.INTERFACE_ASSOCIATION);
    try testing.expectEqual(@as(u8, 0x21), usb_descriptors.DescriptorType.HID);
    try testing.expectEqual(@as(u8, 0x22), usb_descriptors.DescriptorType.HID_REPORT);
}

// ============================================================
// 15. device descriptor USB version と max packet size
// ============================================================

test "device descriptor bcdUSB is 2.0" {
    const bcd_low = usb_descriptors.device_descriptor[2];
    const bcd_high = usb_descriptors.device_descriptor[3];
    try testing.expectEqual(@as(u8, 0x00), bcd_low);
    try testing.expectEqual(@as(u8, 0x02), bcd_high);
}

test "device descriptor bMaxPacketSize0 is 64" {
    try testing.expectEqual(@as(u8, 64), usb_descriptors.device_descriptor[7]);
}

test "device descriptor bNumConfigurations is 1" {
    try testing.expectEqual(@as(u8, 1), usb_descriptors.device_descriptor[17]);
}

test "device descriptor string indices" {
    try testing.expectEqual(@as(u8, 1), usb_descriptors.device_descriptor[14]); // iManufacturer
    try testing.expectEqual(@as(u8, 2), usb_descriptors.device_descriptor[15]); // iProduct
    try testing.expectEqual(@as(u8, 3), usb_descriptors.device_descriptor[16]); // iSerialNumber
}

// ============================================================
// 16. configuration descriptor bMaxPower
// ============================================================

test "configuration descriptor bMaxPower is 500mA (250 units)" {
    try testing.expectEqual(@as(u8, 250), usb_descriptors.configuration_descriptor[8]);
}

test "configuration descriptor bConfigurationValue is 1" {
    try testing.expectEqual(@as(u8, 1), usb_descriptors.configuration_descriptor[5]);
}
