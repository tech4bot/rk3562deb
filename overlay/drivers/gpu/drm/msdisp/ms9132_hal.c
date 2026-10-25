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
 * ms9132_hal.c -- Drm driver for MacroSilicon chip 913x and 912x
 */


#include <linux/types.h>
#include <linux/usb.h>
#include <linux/hid.h>
#include <linux/printk.h>

#include <drm/drm_modes.h>

#include "usb_hal_chip.h"
#include "usb_hal_edid.h"
#include "usb_device.h"
#include "usb_device_hid.h"
#include "msdisp_usb_interface.h"
#include "msdisp_usb_drv.h"
#include "usb_hal_interface.h"
#include "usb_hal_dev.h"

int ms9132_hal_get_hpd_status(struct msdisp_usb_hal* usb_hal, unsigned int* status)
{
    struct msdisp_usb_device* msdisp_usb = (struct msdisp_usb_device *)usb_hal->private;
    struct usb_hal* hal = msdisp_usb->hal;

    return usb_hal_get_hpd_status(hal, status);
}

int ms9132_hal_get_edid(struct msdisp_usb_hal* usb_hal, int block, unsigned char* buf, unsigned int len)
{
    struct msdisp_usb_device* msdisp_usb = (struct msdisp_usb_device *)usb_hal->private;
    struct usb_hal* hal = msdisp_usb->hal;

    return usb_hal_get_edid(hal, block, buf, len);
}

int ms9132_hal_mode_valid(struct msdisp_usb_hal* usb_hal, int width, int height, int rate)
{
    struct msdisp_usb_device* msdisp_usb = (struct msdisp_usb_device *)usb_hal->private;
    struct usb_hal* hal = msdisp_usb->hal;
    struct usb_hal_video_mode hal_mode;
    int rtn;

    hal_mode.width = width;
    hal_mode.height = height;
    hal_mode.rate = rate;
    hal_mode.vic = 0;
    rtn = usb_hal_video_mode_valid(hal, &hal_mode);

	return (0 == rtn) ? MODE_OK : MODE_BAD;
}

int ms9132_hal_enable(struct msdisp_usb_hal* usb_hal, int width, int height, int rate, unsigned int fourcc)
{
    struct msdisp_usb_device* msdisp_usb = (struct msdisp_usb_device *)usb_hal->private;
    struct usb_hal* hal = msdisp_usb->hal;
    struct usb_hal_video_mode hal_mode;
    int rtn;

    hal_mode.width = width;
    hal_mode.height = height;
    hal_mode.rate = rate;
    hal_mode.vic = 0;

    rtn = usb_hal_video_mode_valid(hal, &hal_mode);
    if (rtn) {
        dev_err(&msdisp_usb->udev->dev, "invalid mode:wdith:%d height:%d rate:%d!\n", width, height, rate);
        return rtn;
    }

    if (!usb_hal_is_support_fourcc(fourcc)) {
        dev_err(&msdisp_usb->udev->dev, "invalid fourcc:0x%x!\n", fourcc);
        return -EINVAL;
    }

    rtn = usb_hal_get_vic(hal, width, height, rate, &hal_mode.vic);
    if (rtn) {
        dev_err(&msdisp_usb->udev->dev, "get vic failed!ret=%d!\n", rtn);
        return rtn;
    }

    return usb_hal_enable(hal, &hal_mode, fourcc);
}

int ms9132_hal_disable(struct msdisp_usb_hal* usb_hal)
{
    struct msdisp_usb_device* msdisp_usb = (struct msdisp_usb_device *)usb_hal->private;
    struct usb_hal* hal = msdisp_usb->hal;

    return usb_hal_disable(hal);
}

int ms9132_hal_update_frame(struct msdisp_usb_hal* usb_hal, u8* buf, int pitch, u32 len, unsigned int fourcc, int try_lock)
{
    struct msdisp_usb_device* msdisp_usb = (struct msdisp_usb_device *)usb_hal->private;
    struct usb_hal* hal = msdisp_usb->hal;

    return usb_hal_update_frame(hal, buf, pitch, len, fourcc, try_lock);
}

int ms9132_hal_get_custom_cea_vic(struct msdisp_usb_hal* usb_hal, u8* buf, int size, int* cnt)
{
    struct msdisp_usb_device* msdisp_usb = (struct msdisp_usb_device *)usb_hal->private;
    struct usb_hal* hal = msdisp_usb->hal;
    /* usb_hal_dev is where usb_hal_add_custom_mode() (called from
     * msdisp_usb_add_custom_mode() at probe, parsing the custom_mode=
     * module param) actually stores the parsed modes -- the fixed
     * VIDEO_PORT_CVBS_SVIDEO-only fallback below never consulted them. */
    struct usb_hal_dev* usb_dev = (struct usb_hal_dev*)hal->private;
    int i;

    *cnt = 0;

    for (i = 0; i < usb_dev->custom_mode_cnt && *cnt < size; i++) {
        buf[*cnt] = usb_dev->custom_mode[i].vic;
        (*cnt)++;
    }

    if (*cnt > 0) {
        return 0;
    }

    if (VIDEO_PORT_CVBS_SVIDEO == hal->port_type) {
        if (size < 1) {
            return -ERANGE;
        }

        buf[0] = _VFMT_CEA_02_720x480P_60HZ;
        *cnt = 1;

        buf[1] = _VFMT_CEA_17_720x576P_50HZ;
        *cnt = 2;
    }

    return 0;
}

int ms9132_hal_cursor_set(struct msdisp_usb_hal* usb_hal, u8* buf)
{
    struct msdisp_usb_device* msdisp_usb = (struct msdisp_usb_device *)usb_hal->private;
    struct usb_hal* hal = msdisp_usb->hal;

    return usb_hal_cursor_set(hal, buf);   
}

int ms9132_hal_cursor_move(struct msdisp_usb_hal* usb_hal, int x, int y)
{
    struct msdisp_usb_device* msdisp_usb = (struct msdisp_usb_device *)usb_hal->private;
    struct usb_hal* hal = msdisp_usb->hal;

    return usb_hal_cursor_move(hal, x, y);
}

struct msdisp_usb_hal_funcs ms9132_hal_funcs = {
    .get_hpd_status = ms9132_hal_get_hpd_status,
    .get_edid = ms9132_hal_get_edid,
    .mode_valid = ms9132_hal_mode_valid,
    .enable = ms9132_hal_enable,
    .disable = ms9132_hal_disable,
    .update_frame = ms9132_hal_update_frame,
    .cursor_set = ms9132_hal_cursor_set,
    .cursor_move = ms9132_hal_cursor_move,
    .get_custom_cea_vic = ms9132_hal_get_custom_cea_vic
};

struct msdisp_usb_hal_funcs* msdisp_usb_find_usb_hal(const struct usb_device_id *id)
{
    if (((id->idVendor == ms9132_id.idVendor) && (id->idProduct == ms9132_id.idProduct))
            || ((id->idVendor == ms9133_id.idVendor) && (id->idProduct == ms9133_id.idProduct))
            || ((id->idVendor == ms9135_id.idVendor) && (id->idProduct == ms9135_id.idProduct))
            || ((id->idVendor == ms6021_id.idVendor) && (id->idProduct == ms6021_id.idProduct))) {

        return &ms9132_hal_funcs;
    }

    return NULL;
}
