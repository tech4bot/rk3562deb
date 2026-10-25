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
 * hal_adaptor.c -- Drm driver for MacroSilicon chip 913x and 912x
 */


#include <linux/usb.h>

#include "hal_adaptor.h"
#include "usb_device.h"

const struct msdisp_hal_dev* hal_dev[] =
{
    &ms9132_dev,
    &ms9133_dev,
    &ms9135_dev,
    &ms6021_dev
};

const struct msdisp_hal_dev* msdisp_hal_find_dev(const struct usb_device_id *id, struct usb_device* udev)
{
    int i, cnt;
    const struct msdisp_hal_dev* dev = NULL;

    cnt  = sizeof(hal_dev) / sizeof(struct msdisp_hal_dev*);

    for (i = 0; i < cnt; i++) {
        if ((id->idVendor == hal_dev[i]->id->idVendor) && (id->idProduct == hal_dev[i]->id->idProduct)) {
            dev = hal_dev[i];
            break;
        }
    }

    return dev;
}

