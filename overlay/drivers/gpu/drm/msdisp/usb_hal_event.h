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
 * usb_hal_event.h -- Drm driver for MacroSilicon chip 913x and 912x
 */

#ifndef __USB_HAL_EVENT_H__
#define __USB_HAL_EVENT_H__

// drm request custom event type starts from 0x80000000
#define USB_HAL_EVENT_TYPE_BASE                  0x90000000
#define USB_HAL_EVENT_TYPE_ENABLE				(USB_HAL_EVENT_TYPE_BASE + 1)
#define USB_HAL_EVENT_TYPE_DISABLE				(USB_HAL_EVENT_TYPE_BASE + 2)
#define USB_HAL_EVENT_TYPE_UPDATE				(USB_HAL_EVENT_TYPE_BASE + 3)

struct usb_hal_base_event {
	unsigned int type;
	unsigned int length;
};


struct usb_hal_event {
    struct usb_hal_base_event base;
    union {
		struct {
			unsigned char color_in;
			unsigned char color_out;
			unsigned char vic;
			unsigned char trans_mode;
			unsigned short width;
			unsigned short height;
			unsigned char resv[4];
		}enable;

		struct {
            unsigned int len;
			unsigned int resv[2];
		}update;

		struct {
			unsigned int resv[3];
		}disable;
	} para;
};

#endif