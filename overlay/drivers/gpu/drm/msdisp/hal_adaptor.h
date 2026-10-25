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
 * hal_adaptor.h -- Drm driver for MacroSilicon chip 913x and 912x
 */


#ifndef __MSDISP_HAL_ADAPTOR_H__
#define __MSDISP_HAL_ADAPTOR_H__

#include <linux/types.h>
#include "usb_hal_interface.h"

#define SDRAM_TYPE_TO_SIZE(a)        ((2 * 1024 * 1024) << (a))

struct usb_device;
struct usb_device_id;
struct msdisp_usb_hal_funcs;
struct usb_hal_event;

// use usb device id
struct msdisp_hal_id
{
    u16 idVendor;
    u16 idProduct;
};

struct msdisp_hal_funcs
{
    s32 (*get_edid)(struct usb_device* udev, misctiming_t* misc_timing, u8 detail_count, u8 chip_id, u8 port_type, u8 sdram_type, u8 block, u8* buf, u32 len);
    s32 (*get_hpd_status)(struct usb_device* udev, u32* status);
    s32 (*set_video_in_info)(struct usb_device* udev, u16 width, u16 height, u8 color, u8 byte_sel);
    s32 (*set_video_out_info)(struct usb_device* udev, u8 index, u8 color, u16 width, u16 height);
    s32 (*trigger_frame)(struct usb_device* udev, u8 index, u8 delay);
    s32 (*set_trans_mode)(struct usb_device* udev, u8 mode, u8* param, u8 param_cnt);
    s32 (*set_trans_enable)(struct usb_device* udev, u8 enable);
    s32 (*set_video_enable)(struct usb_device* udev, u8 enable);
    s32 (*set_power_enable)(struct usb_device* udev, u8 enable);
    s32 (*get_mode_vic)(u16 width, u16 height, u8 rate, u8* vic);
    u8  (*get_transfer_bulk_ep)(void);
    s32 (*xdata_write_byte)(struct usb_device* udev, u16 addr, u8 data);
    s32 (*xdata_read_byte)(struct usb_device* udev, u16 addr, u8* data);
    s32 (*current_frame_index)(struct usb_device* udev, u8* index);
    s32 (*set_screen_enable)(struct usb_device* udev, u8 enable, u8 chip_id, u8 port_type, u8 sdram_type);
    s32 (*event_proc)(struct usb_device* udev, struct usb_hal_event* event, u8 chip_id, u8 port_type, u8 sdram_type);
    s32 (*get_chip_id)(struct usb_device* udev, u8* chip_id);
    s32 (*get_port_type)(struct usb_device* udev, u8* port_type);
    s32 (*get_sdram_type)(struct usb_device* udev, u8* sdram_type);
    s32 (*read_flash)(struct usb_device* udev, u16 addr, u8* buf, u8 len);
    s32 (*sfr_read_byte)(struct usb_device* udev, u16 addr, u8* data);
    s32 (*sfr_write_byte)(struct usb_device* udev, u16 addr, u8 value);
    s32 (*init_dev)(struct usb_device* udev, u8 chip_id, u8 port_type, u8 sdram_type);
};

struct msdisp_hal_dev 
{
    const struct msdisp_hal_id* id;
    const struct msdisp_hal_funcs* funcs;
};


struct msdisp_usb_hal_wrapper {
    const struct msdisp_hal_id* id;
    struct msdisp_usb_hal_funcs* funcs;
};

const struct msdisp_hal_dev* msdisp_hal_find_dev(const struct usb_device_id *id, struct usb_device* udev);

#endif
