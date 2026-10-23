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
 * msdisp_usb_interface.h -- Drm driver for MacroSilicon chip 913x and 912x
 */


#ifndef __MSDISP_USB_INTERFACE_H__
#define __MSDISP_USB_INTERFACE_H__

struct usb_device;
struct usb_device_id;
struct msdisp_usb_hal;
struct drm_display_mode;


struct msdisp_usb_hal_funcs
{
    int (*get_hpd_status)(struct msdisp_usb_hal* usb_hal, unsigned int* status);
    int (*get_edid)(struct msdisp_usb_hal* usb_hal, int block, unsigned char* buf, unsigned int len);
    int (*mode_valid)(struct msdisp_usb_hal* usb_hal, int width, int height, int rate);
    int (*enable)(struct msdisp_usb_hal* usb_hal, int width, int height, int rate, unsigned int fourcc);
    int (*disable)(struct msdisp_usb_hal* usb_hal);
    int (*update_frame)(struct msdisp_usb_hal* usb_hal, u8* buf, int pitch, u32 len, unsigned int fourcc, int try_lock);
    int (*get_custom_cea_vic)(struct msdisp_usb_hal* usb_hal, u8* buf, int size, int* cnt);
    int (*cursor_set)(struct msdisp_usb_hal* usb_hal, u8* buf);
    int (*cursor_move)(struct msdisp_usb_hal* usb_hal, int x, int y);
};

struct msdisp_usb_hal {
    void* private; 
    struct msdisp_usb_hal_funcs* funcs;
};
struct msdisp_usb_hal_funcs* msdisp_usb_find_usb_hal(const struct usb_device_id *id);

#endif