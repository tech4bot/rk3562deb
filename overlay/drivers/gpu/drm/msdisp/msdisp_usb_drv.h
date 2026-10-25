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
 * msdisp_usb_drv.h -- Drm driver for MacroSilicon chip 913x and 912x
 */

#ifndef __MSDISP_USB_DRV_H__
#define __MSDISP_USB_DRV_H__

#include <linux/module.h>
#include <linux/version.h>
#include <linux/device.h>
#include <linux/kthread.h>
#include <linux/semaphore.h>


struct usb_device;
struct drm_device;
struct usb_hal;
struct msdisp_usb_hal;



struct msdisp_usb_device {
    struct usb_device* udev;
    struct drm_device* drm;
    int pipeline_index;
    struct msdisp_usb_hal* usb_hal;
    struct usb_hal* hal;
};

#endif