/* Copyright (C) 2023 MacroSilicon Technology Co., Ltd.
 *
 * This software is licensed under the terms of the GNU General Public
 * License version 2, as published by the Free Software Foundation, and
 * may be copied, distributed, and modified under those terms.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * usb_device_hid.h -- Drm driver for MacroSilicon chip 913x and 912x
 */


#ifndef __MSDISP_USB_DEVICE_HID_H__
#define __MSDISP_USB_DEVICE_HID_H__

#define MS9132_HID_OP_READ_DATA                         0xB5
#define MS9132_HID_OP_WRITE_ONE_BYTE                    0xB6                        
#define MS9132_HID_OP_WRITE_TWO_BYTES                   0x12
#define MS9132_HID_OP_WRITE_THREE_BYTES                 0x13
#define MS9132_HID_OP_WRITE_FOUR_BYTES                  0x14
#define MS9132_HID_OP_WRITE_FIVE_BYTES                  0x15
#define MS9132_HID_OP_READ_USB3_REG                     0xB7
#define MS9132_HID_OP_WRITE_USB3_REG                    0xB8
#define MS9132_HID_OP_READ_HDMI_PHY_REG                 0xB9
#define MS9132_HID_OP_WRITE_HDMI_PHY_REG                0xBA
#define MS9132_HID_OP_READ_SFR_DATA                     0xC5
#define MS9132_HID_OP_WRITE_SFR_DATA                    0xC6
#define MS9132_HID_OP_READ_SDRAM_DATA                   0xD5
#define MS9132_HID_OP_WRITE_SDRAM_DATA                  0xD6
#define MS9132_HID_OP_READ_EEPROM_DATA                  0xE5
#define MS9132_HID_OP_WRITE_EEPROM_DATA                 0xE6
#define MS9132_HID_OP_READ_FLASH_EIGHT_BYTES            0xF5
#define MS9132_HID_OP_WRITE_FLASH_ONE_BYTE              0xF6
#define MS9132_HID_OP_WRITE_FLASH_FOUR_BYTES            0x34
#define MS9132_HID_OP_READ_FLASH_BURST                  0xF7
#define MS9132_HID_OP_WRITE_FLASH_BURST                 0xF8
#define MS9132_HID_OP_ERASE_FLASH_ONE_SECTION           0xFB
#define MS9132_HID_OP_ERASE_FLASH_ALL                   0xFE

#define MS9132_HID_OP_VIDEO                             0xA6                
#define MS9132_HID_SUBOP_VIDEO_TRIGGER_FRAME            0x00
#define MS9132_HID_SUBOP_VIDEO_UPDATE_IN_INFO           0x01
#define MS9132_HID_SUBOP_VIDEO_UPDATE_OUT_INFO          0x02
#define MS9132_HID_SUBOP_VIDEO_SET_TRANS_MODE           0x03
#define MS9132_HID_SUBOP_VIDEO_TRANSFER                 0x04
#define MS9132_HID_SUBOP_VIDEO_ENABLE                   0x05
#define MS9132_HID_SUBOP_VIDEO_POWER                    0x07


// xdata reg define
#define MS9132_XDATA_REG_EDID                           0xC000
#define MS9132_XDATA_REG_CHIP_ID                        0xFF00
#define MS9120_XDATA_REG_CHIP_ID                        0xF000
#define MS9132_XDATA_REG_SDRAM_TYPE                     0x30
#define MS9132_XDATA_REG_VIDEO_PORT                     0x31
#define MS9132_XDATA_REG_HPD                            0x32
#define MS9132_XDATA_REG_FRAME_SWITCH                   0xD003
#define MS9132_XDATA_HDMITX_MUTE                        0xFB07
#define MS9132_XDATA_HDMITX_MUTE_VIDEO_MUTE_BIT         1



#define MS9132_HID_OP_XDATA_READ_MAX_CNT                4

#define MS9132_TRANS_MODE_FRAME                         0
#define MS9132_TRANS_MODE_FIX_BLOCK_MN                  1
#define MS9132_TRANS_MODE_FIX_BLOCK_WH                  2
#define MS9132_TRANS_MODE_MANUAL_BLOCK                  3
#define MS9132_TRANS_MODE_BYPASS_FRAME                  4
#define MS9132_TRANS_MODE_BYPASS_MANAUAL_BLOCK          5


#define HID_INFO_LEN                                    8

struct ms9132_hid_read_data
{
    u8 op;
    u8 addr_hi;
    u8 addr_lo;
    u8 data[4];
    u8 resv;
};

struct ms9132_hid_write_data_byte
{
    u8 op;
    u8 addr_hi;
    u8 addr_lo;
    u8 data;
    u8 resv[4];
};

struct ms9132_hid_video 
{
    u8 op;
    u8 sub_op;
    union  __attribute__((packed)){
        struct {
            char index;
            char delay;
            char resv[4];
        }frame_index;

        struct {
            char width_hi;
            char width_lo;
            char height_hi;
            char height_lo;
            char color;
            char byte_sel;
        }in;

        struct {
            char index;
            char color;
            char width_hi;
            char width_lo;
            char height_hi;
            char height_lo;
        }out;

        struct {
            char mode;
            char param0;
            char param1;
            char param2;
            char param3;
            char resv;
        }trans_mode;

        struct {
            char trans;
            char resv[5];
        }transfer;

        struct {
            char enable;
            char resv[5];
        }enable;

        struct {
            char on;
            char data;
            char resv[4];
        }power;

        u8 raw[HID_INFO_LEN - 2];
    }info;
};


#endif
