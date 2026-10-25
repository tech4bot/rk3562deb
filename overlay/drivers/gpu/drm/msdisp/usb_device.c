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
 * usb_device.c -- Drm driver for MacroSilicon chip 913x and 912x
 */


#include <linux/types.h>
#include <linux/usb.h>
#include <linux/hid.h>
#include <linux/printk.h>

//#include <drm/drm_modes.h>
#include <drm/drm_fourcc.h>

#include "usb_hal_chip.h"
#include "usb_device.h"
#include "usb_device_hid.h"
#include "usb_hal_event.h"
#include "usb_hal_interface.h"

#define EDID_LENGTH                             0x80

#define MS9132_TRNAS_BULK_EP                    4

#define MS9132_EDID_BLOCK_LEN                   0x80

#define MS9132_REQUEST_TYPE_SET                 (USB_DIR_OUT | USB_TYPE_CLASS | USB_RECIP_INTERFACE)
#define MS9132_REQUEST_TYPE_GET                 (USB_DIR_IN | USB_TYPE_CLASS | USB_RECIP_INTERFACE)

#define MS9132_REQUEST_REPORT_TYPE              0x3  // Feature
#define MS9132_REQUEST_REPORT_ID                0

#define MS9132_REQUEST_VALUE                    ((MS9132_REQUEST_REPORT_TYPE << 8) | MS9132_REQUEST_REPORT_ID)
#define MS9132_REQUEST_INTERFACE                0

#define VIC_VESA_1920X1080_60                   129
#define VIC_VESA_1680X1050_60                   120
#define VIC_VESA_1440X900_60                    107
#define VIC_VESA_1400X1050_60                   103
#define VIC_VESA_1366X768_60                    102
#define VIC_VESA_1360X768_60                    100
#define VIC_VESA_1280X1024_60                   96
#define VIC_VESA_1280X960_60                    91
#define VIC_VESA_1280X800_60                    87
#define VIC_VESA_1280X768_60                    84
#define VIC_VESA_1280X720_60                    79
#define VIC_VESA_1280X600_60                    78
#define VIC_VESA_1152X864_60                    76
#define VIC_VESA_1024x768_60                    71
#define VIC_VESA_800X600_60                     66
#define VIC_VESA_640X480_60                     64

#define DETAILED_TIMING_OFFSET                  (0x36)
#define LONG_DESCR_LEN                          (18)
#define NUM_OF_DETAILED_DESCRIPTORS             (4)

struct video_mode {
    u8 vic;
    u8 refresh_rate;
    u16 width;
    u16 height;
};

static u8 edidYPBPR[EDID_LENGTH] = {
    0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, // address 0x00
    0x34, 0x23, 0x01, 0x01, 0x01, 0x02, 0x03, 0x04, 
    0x33, 0x1C, 0x01, 0x03, 0x80, 0x33, 0x1D, 0x78, // address 0x10
    0xEF, 0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26,
    0x0F, 0x50, 0x54, 0x00, 0x00, 0x00, 0x01, 0x00, // address 0x20
    0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x01, 0x01,
    0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x01, 0x1D, // address 0x30
    0x00, 0x72, 0x51, 0xD0, 0x1E, 0x20, 0x6E, 0x28,
    0x55, 0x00, 0xC4, 0x8E, 0x21, 0x00, 0x00, 0x1E, // address 0x40
    0x02, 0x3A, 0x80, 0x18, 0x71, 0x38, 0x2D, 0x40, 
    0x58, 0x2C, 0x45, 0x00, 0xC4, 0x8E, 0x21, 0x00, // address 0x50
    0x00, 0x1E, 0x8C, 0x0A, 0xD0, 0x8A, 0x20, 0xE0,
    0x2D, 0x10, 0x10, 0x3E, 0x96, 0x00, 0xC4, 0x8E, // address 0x60
    0x21, 0x00, 0x00, 0x18, 0x8C, 0x0A, 0xD0, 0x90, 
    0x20, 0x40, 0x31, 0x20, 0x0C, 0x40, 0x55, 0x00, // address 0x70
    0xC4, 0x8E, 0x21, 0x00, 0x00, 0x18, 0x00, 0xBC 
};

static u8 edidVGA[EDID_LENGTH] = {
    0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, // address 0x00
    0x34, 0x23, 0x01, 0x01, 0x01, 0x02, 0x03, 0x04,
    0x01, 0x18, 0x01, 0x03, 0x80, 0x33, 0x1D, 0x78, // address 0x10
    0xEF, 0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26,
    0x0F, 0x50, 0x54, 0x21, 0x08, 0x00, 0xD1, 0xC0, // address 0x20
    0x81, 0x40, 0x81, 0x80, 0x81, 0x00, 0x90, 0x40,
    0x95, 0x00, 0x71, 0x40, 0xB3, 0x00, 0x01, 0x1D, // address 0x30
    0x00, 0x72, 0x51, 0xD0, 0x1E, 0x20, 0x6E, 0x28,
    0x55, 0x00, 0xC4, 0x8E, 0x21, 0x00, 0x00, 0x1E, // address 0x40
    0x20, 0x1C, 0x56, 0x86, 0x50, 0x00, 0x20, 0x30,
    0x0E, 0x38, 0x13, 0x00, 0xC4, 0x8E, 0x21, 0x00, // address 0x50
    0x00, 0x1E, 0x00, 0x00, 0x00, 0xFC, 0x00, 0x4D,
    0x53, 0x55, 0x53, 0x42, 0x44, 0x49, 0x53, 0x50, // address 0x60
    0x4C, 0x41, 0x59, 0x0A, 0x00, 0x00, 0x00, 0x10,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // address 0x70
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x92
};

static u8 edidVGA_USB3[EDID_LENGTH] = {
    0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, // address 0x00
    0x34, 0x23, 0x01, 0x01, 0x01, 0x02, 0x03, 0x04,
    0x01, 0x18, 0x01, 0x03, 0x80, 0x33, 0x1D, 0x78, // address 0x10
    0xEF, 0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26,
    0x0F, 0x50, 0x54, 0x21, 0x08, 0x00, 0xD1, 0xC0, // address 0x20
    0x81, 0x40, 0x81, 0x80, 0x81, 0x00, 0x90, 0x40,
    0x95, 0x00, 0x71, 0x40, 0xB3, 0x00, 0x02, 0x3A, // address 0x30
    0x80, 0x18, 0x71, 0x38, 0x2D, 0x40, 0x58, 0x2C,
    0x45, 0x00, 0xC4, 0x8E, 0x21, 0x00, 0x00, 0x1E, // address 0x40
    0x20, 0x1C, 0x56, 0x86, 0x50, 0x00, 0x20, 0x30,
    0x0E, 0x38, 0x13, 0x00, 0xC4, 0x8E, 0x21, 0x00, // address 0x50
    0x00, 0x1E, 0x00, 0x00, 0x00, 0xFC, 0x00, 0x4D,
    0x53, 0x55, 0x53, 0x42, 0x44, 0x49, 0x53, 0x50, // address 0x60
    0x4C, 0x41, 0x59, 0x0A, 0x00, 0x00, 0x00, 0x10,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // address 0x70
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xB9
};

#if 0
static u8 edidVGA_4M[EDID_LENGTH] = {
    0x34, 0x23, 0x01, 0x01, 0x01, 0x02, 0x03, 0x04, // address 0x00
    0x01, 0x18, 0x01, 0x03, 0x80, 0x33, 0x1D, 0x78,
    0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, // address 0x10
    0xEF, 0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26,
    0x0F, 0x50, 0x54, 0x21, 0x08, 0x00, 0x01, 0x01, // address 0x20
    0x81, 0x40, 0x01, 0x01, 0x81, 0x00, 0x01, 0x01,
    0x01, 0x01, 0x71, 0x40, 0x01, 0x01, 0x01, 0x1D, // address 0x30
    0x00, 0x72, 0x51, 0xD0, 0x1E, 0x20, 0x6E, 0x28, 
    0x55, 0x00, 0xC4, 0x8E, 0x21, 0x00, 0x00, 0x1E, // address 0x40
    0x66, 0x21, 0x50, 0xB0, 0x51, 0x00, 0x1B, 0x30,
    0x40, 0x70, 0x36, 0x00, 0xC4, 0x8E, 0x21, 0x00, // address 0x50
    0x00, 0x1E, 0x00, 0x00, 0x00, 0xFC, 0x00, 0x4D,
    0x53, 0x55, 0x53, 0x42, 0x44, 0x49, 0x53, 0x50, // address 0x60
    0x4C, 0x41, 0x59, 0x0A, 0x00, 0x00, 0x00, 0x10,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // address 0x70
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3A
};
#endif

static u8 edidVGA_CVBS[EDID_LENGTH] = {
    0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, // address 0x00
    0x34, 0x23, 0x01, 0x01, 0x01, 0x02, 0x03, 0x04,
    0x33, 0x1C, 0x01, 0x03, 0x80, 0x33, 0x1D, 0x78, // address 0x10
    0xEF, 0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26,
    0x0F, 0x50, 0x54, 0x01, 0x00, 0x00, 0x45, 0x40, // address 0x20
    0x45, 0x40, 0x45, 0x40, 0x45, 0x40, 0x45, 0x40,
    0x45, 0x40, 0x45, 0x40, 0x45, 0x40, 0xA0, 0x0F, // address 0x30
    0x20, 0x00, 0x31, 0x58, 0x1C, 0x20, 0x28, 0x80,
    0x14, 0x00, 0x13, 0x8E, 0x21, 0x00, 0x00, 0x1E, // address 0x40
    0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // address 0x50
    0x00, 0x00, 0x00, 0x00, 0x00, 0xFD, 0x00, 0x32,
    0x55, 0x1E, 0x51, 0x11, 0x00, 0x0A, 0x20, 0x20, // address 0x60
    0x20, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00, 0xFC,
    0x00, 0x4D, 0x53, 0x55, 0x53, 0x42, 0x44, 0x49, // address 0x70
    0x53, 0x50, 0x4C, 0x41, 0x59, 0x0A, 0x00, 0x08
};

#if 0
static u8 edid2blocks_temp[EDID_LENGTH * 2] = {
    0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, // address 0x00
    0x21, 0x57, 0x30, 0x21, 0x1D, 0x8D, 0x34, 0x01,
    0x33, 0x20, 0x01, 0x03, 0x80, 0x3C, 0x22, 0x78, // address 0x10
    0x02, 0x28, 0x95, 0xA7, 0x55, 0x4E, 0xA3, 0x26,
    0x0F, 0x50, 0x54, 0x21, 0x03, 0x00, 0x81, 0x80, // address 0x20
    0x81, 0x40, 0x61, 0x40, 0x01, 0x00, 0x01, 0x00,
    0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x02, 0x3A, // address 0x30
    0x80, 0x18, 0x71, 0x38, 0x2D, 0x40, 0x58, 0x2C,
    0x45, 0x00, 0xC4, 0x8E, 0x21, 0x00, 0x00, 0x1E, // address 0x40
    0x01, 0x1D, 0x00, 0x72, 0x51, 0xD0, 0x1E, 0x20,
    0x6E, 0x28, 0x55, 0x00, 0x55, 0x50, 0x21, 0x00, // address 0x50
    0x00, 0x1E, 0x00, 0x00, 0x00, 0xFD, 0x00, 0x18,
    0x55, 0x1E, 0x64, 0x1E, 0x00, 0x0A, 0x20, 0x20, // address 0x60
    0x20, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00, 0xFC,
    0x00, 0x48, 0x44, 0x4D, 0x49, 0x20, 0x54, 0x4F, // address 0x70
    0x20, 0x55, 0x53, 0x42, 0x0A, 0x20, 0x01, 0xAF,
    0x02, 0x03, 0x2E, 0x71, 0x4C, 0x1F, 0x22, 0x21, // address 0x80
    0x20, 0x13, 0x3E, 0x3D, 0x3C, 0x05, 0x14, 0x5F,
    0x64, 0x23, 0x09, 0x07, 0x07, 0x83, 0x01, 0x00, // address 0x90
    0x00, 0x6E, 0x03, 0x0C, 0x00, 0x10, 0x00, 0x00,
    0x3C, 0x20, 0x00, 0x80, 0x01, 0x02, 0x03, 0x04, // address 0xA0
    0xE5, 0x0E, 0x61, 0x60, 0x66, 0x65, 0x6A, 0x5E,
    0x00, 0xA0, 0xA0, 0xA0, 0x29, 0x50, 0x30, 0x20, // address 0xB0
    0x25, 0x00, 0xB0, 0x13, 0x32, 0x00, 0x00, 0x18,
    0x19, 0x64, 0x00, 0x80, 0xA3, 0xA0, 0x2C, 0x50, // address 0xC0
    0xB0, 0x10, 0x35, 0x10, 0xB0, 0x13, 0x32, 0x00,
    0x00, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // address 0xD0
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // address 0xE0
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // address 0xF0
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC7
};
#endif

static struct video_mode  g_support_mode[] = {
    {VIC_VESA_1920X1080_60, 60, 1920, 1080},
    {VIC_VESA_1680X1050_60, 60, 1680, 1050},
    {VIC_VESA_1440X900_60, 60, 1440, 900},
    {VIC_VESA_1400X1050_60, 60, 1400, 1050},
    {VIC_VESA_1366X768_60, 60, 1366, 768},
    {VIC_VESA_1360X768_60, 60, 1360, 768},
    {VIC_VESA_1280X1024_60, 60, 1280, 1024},
    {VIC_VESA_1280X960_60, 60, 1280, 960},
    {VIC_VESA_1280X800_60, 60, 1280, 800},
    {VIC_VESA_1280X768_60, 60, 1280, 768},
    {VIC_VESA_1280X720_60, 60, 1280, 720},
    {VIC_VESA_1280X600_60, 60, 1280, 600},
    {VIC_VESA_1152X864_60, 60, 1152, 864},
    {VIC_VESA_1024x768_60, 60, 1024, 768},
    {150, 60, 1024, 600},
    {VIC_VESA_800X600_60, 60, 800, 600},
    {VIC_VESA_640X480_60, 60, 640, 480}
};

s32 ms9132_xdata_write_byte(struct usb_device* udev, u16 addr, u8 data);

int msdisp_usb_dev_port_has_i2c(int port_type)
{
    int ret = 0;
    if ((VIDEO_PORT_HDMI == port_type) || (VIDEO_PORT_DIGITAL == port_type)) {
        ret = 1;
    }

    return ret;
}

static int ms9132_hid_report(struct usb_device*udev, int is_set, void* report, int len)
{
    u8 req_type;
    u8 req;
    u16 index;
    u16 value;
    unsigned int pipe;
    int timeout;
    int rtn;
    u8* buf = NULL;

    buf = kmalloc(len, GFP_KERNEL);
    if (!buf) {
        return -ENOMEM; 
    }
    memcpy(buf, report, len);
#ifdef MSDISP_DEBUG    
    if (is_set && (buf[0] == 0xa6)) {
        dev_info(&udev->dev,"buf:0x%02x 0x%02x 0x%02x 0x%02x 0x%02x 0x%02x 0x%02x 0x%02x\n",
            buf[0], buf[1], buf[2], buf[3], buf[4], buf[5], buf[6], buf[7]);
    }
#endif

    pipe = (is_set ?  usb_sndctrlpipe(udev, 0) : usb_rcvctrlpipe(udev, 0));
    req_type = (is_set ? MS9132_REQUEST_TYPE_SET : MS9132_REQUEST_TYPE_GET);
    req = (is_set ?  HID_REQ_SET_REPORT: HID_REQ_GET_REPORT);
    timeout = (is_set ? USB_CTRL_SET_TIMEOUT : USB_CTRL_GET_TIMEOUT);

    value = MS9132_REQUEST_VALUE;
    index = MS9132_REQUEST_INTERFACE;

    rtn = usb_control_msg(udev, pipe, req, req_type,
        value, index, buf, len, timeout);

    if (rtn < 0) {
        u8* tmp = (u8*)report;
        dev_err(&udev->dev, "ms9132 %s report failed! rtn =%d\n", is_set ? "set" : "get", rtn);
        dev_err(&udev->dev, "report: %02x %02x %02x %02x %02x %02x %02x %02x\n", tmp[0], tmp[1], tmp[2], tmp[3], tmp[4], tmp[5], tmp[6], tmp[7]);
        goto out;
    }

    if (!is_set) {
        memcpy(report, buf, len);
    }
out:
    if (buf) {
        kfree(buf);
    }
    return (rtn < 0 ? 1 : 0);
}

static int ms9132_read_xdata_once(struct usb_device* udev, u16 addr, u8* buf, u8 read_cnt)
{
    int i, rtn;
    struct ms9132_hid_read_data rdata;

    if (MS9132_HID_OP_XDATA_READ_MAX_CNT < read_cnt)
    {
        return -1;
    }

    rdata.op = MS9132_HID_OP_READ_DATA;
    rdata.addr_hi = ((addr & 0xff00) >> 8);
    rdata.addr_lo = (addr & 0xff);
    rdata.data[0] = rdata.data[1] = rdata.data[2] = rdata.data[3] = 0;
    rdata.resv = 0;

    rtn = ms9132_hid_report(udev, 1, &rdata, sizeof(rdata));
    if (rtn) {
        goto out;
    }

    rtn = ms9132_hid_report(udev, 0, &rdata, sizeof(rdata));
    if (rtn) {
        goto out;
    }

    for (i = 0; i < read_cnt; i++) {
        buf[i] = rdata.data[i];
    }

out:
    return rtn;
}

static int ms9132_read_xdata(struct usb_device* udev, u16 addr, u8* buf, u16 cnt)
{
    u16 offset = 0;
    u8 read_cnt;
    int rtn;

    if (((u32)addr + cnt) > 0x10000)
    {
        return -ERANGE;
    }

    while (cnt) {
        read_cnt = ((cnt > MS9132_HID_OP_XDATA_READ_MAX_CNT) ? MS9132_HID_OP_XDATA_READ_MAX_CNT : cnt);
        rtn = ms9132_read_xdata_once(udev, addr + offset, buf + offset, read_cnt);
        if (rtn) {
            goto out;
        }
        offset += read_cnt;
        cnt -= read_cnt;
    }

out:
    return rtn;
}

static int ms9132_read_flash(struct usb_device* udev, u16 addr, u8* buf, u8 len)
{
    int rtn;
    int pos = 0;
    int index = 0;
    u8 ctrl_data[8];

    while(pos < len)
    {
        index = 0;

        ctrl_data[index++] = MS9132_HID_OP_READ_FLASH_EIGHT_BYTES;
        ctrl_data[index++] = (u8)(((addr + pos) >> 16) & 0x00ff);
        ctrl_data[index++] = (u8)(((addr + pos) >> 8) & 0x00ff);
        ctrl_data[index++] = (u8)((addr + pos) & 0x00ff);
        ctrl_data[index++] = 0;
        ctrl_data[index++] = 0;
        ctrl_data[index++] = 0;
        ctrl_data[index++] = 0;

        rtn = ms9132_hid_report(udev, 1, ctrl_data, index);
        if (rtn) {
            goto out;
        }

        rtn = ms9132_hid_report(udev, 0, ctrl_data, index);
        if (rtn) {
            goto out;
        }
        memcpy(buf + pos, &ctrl_data[index - 8], len - pos > 8 ? 8 : len - pos);
        pos += 8;
    }

out:
    return rtn;
}

static int ms9132_read_sfr_data(struct usb_device* udev, u16 addr, u8* data)
{
    int rtn;
    u8 ctrl_data[8] = {0};

    ctrl_data[0] = MS9132_HID_OP_READ_SFR_DATA;
    ctrl_data[1] = (u8)addr;
    ctrl_data[2] = 0;
    ctrl_data[3] = 0;    
    ctrl_data[4] = 0; 
    ctrl_data[5] = 0; 
    ctrl_data[6] = 0; 
    ctrl_data[7] = 0; 

    rtn = ms9132_hid_report(udev, 1, ctrl_data, 8);
    if (rtn) {
        goto out;
    }

    rtn = ms9132_hid_report(udev, 0, ctrl_data, 8);
    if (rtn) {
        goto out;
    }

    *data = ctrl_data[2];

out:
    return rtn;
}

static int ms9132_write_sfr_data(struct usb_device* udev, u16 addr, u8 value)
{
    int rtn;
    u8 ctrl_data[8] = {0};

    ctrl_data[0] = MS9132_HID_OP_WRITE_SFR_DATA;
    ctrl_data[1] = (u8)addr;
    ctrl_data[2] = (u8)value;
    ctrl_data[3] = 0;    
    ctrl_data[4] = 0; 
    ctrl_data[5] = 0; 
    ctrl_data[6] = 0; 
    ctrl_data[7] = 0; 

    rtn = ms9132_hid_report(udev, 1, ctrl_data, 8);
    if (rtn) {
        goto out;
    }

out:
    return rtn;
}

static void edid_std_timing_convert(const misctiming_t *pt_std_timing, detailed_timing_t *pt_detailed_timing)
{
  pt_detailed_timing->pixclk = pt_std_timing->pixclk;
  pt_detailed_timing->hactive = pt_std_timing->hactive;
  pt_detailed_timing->hblank = pt_std_timing->htotal - pt_std_timing->hactive;
  pt_detailed_timing->vactive = pt_std_timing->vactive;
  pt_detailed_timing->vblank = pt_std_timing->vtotal - pt_std_timing->vactive;
  pt_detailed_timing->hoffset = pt_detailed_timing->hblank - pt_std_timing->hoffset;
  pt_detailed_timing->hsyncwidth = pt_std_timing->hsyncwidth;
  pt_detailed_timing->voffset = pt_detailed_timing->vblank - pt_std_timing->voffset;
  pt_detailed_timing->vsyncwidth = pt_std_timing->vsyncwidth;
  pt_detailed_timing->h_image_size = 0;
  pt_detailed_timing->v_image_size = 0;
  pt_detailed_timing->hborder = 0;
  pt_detailed_timing->vborder = 0;
  pt_detailed_timing->polarity = pt_std_timing->polarity;
}

static void edid_detailed_timing_convert(detailed_timing_t *p_detailed_timing, u8 *detailed_timing_buf)
{
  detailed_timing_buf[0]  = (u8)(p_detailed_timing->pixclk & 0xff);
  detailed_timing_buf[1]  = p_detailed_timing->pixclk >> 8;
  detailed_timing_buf[2]  = (u8)(p_detailed_timing->hactive & 0xff);
  detailed_timing_buf[3]  = (u8)(p_detailed_timing->hblank & 0xff);
  detailed_timing_buf[4]  = ((p_detailed_timing->hactive >> 4) & 0xF0) + ((p_detailed_timing->hblank >> 8) & 0x0F);
  detailed_timing_buf[5]  = (u8)(p_detailed_timing->vactive & 0xff);
  detailed_timing_buf[6]  = (u8)(p_detailed_timing->vblank & 0xff);
  detailed_timing_buf[7]  = ((p_detailed_timing->vactive >> 4) & 0xF0) + ((p_detailed_timing->vblank >> 8) & 0x0F);
  detailed_timing_buf[8]  = (u8)(p_detailed_timing->hoffset & 0xff);
  detailed_timing_buf[9]  = (u8)(p_detailed_timing->hsyncwidth & 0xff);
  detailed_timing_buf[10] = ((p_detailed_timing->voffset << 4) & 0xF0) + ((p_detailed_timing->vsyncwidth >> 0) & 0x0F);
  detailed_timing_buf[11] = ((p_detailed_timing->hoffset >> 2) & 0xC0) + ((p_detailed_timing->hsyncwidth >> 4) & 0x30) \
                              + ((p_detailed_timing->voffset >> 6) & 0x0C) + ((p_detailed_timing->vsyncwidth >> 8) & 0x03);
  detailed_timing_buf[12] = (u8)(p_detailed_timing->h_image_size & 0xff);
  detailed_timing_buf[13] = (u8)(p_detailed_timing->v_image_size & 0xff);
  detailed_timing_buf[14] = ((p_detailed_timing->h_image_size >> 4) & 0xF0) + ((p_detailed_timing->v_image_size >> 8) & 0x0F);
  detailed_timing_buf[15] = (u8)(p_detailed_timing->hborder & 0xff);
  detailed_timing_buf[16] = (u8)(p_detailed_timing->vborder & 0xff);
  detailed_timing_buf[17] = (~(p_detailed_timing->polarity << 7) & 0x80) + (0x00 & 0x61) + (0x18 & 0x18)
                              + ((p_detailed_timing->polarity << 0) & 0x06);
}

static void edid_checksum_calc(u8* buf)
{
    u8 i;
    u8 checksum = 0;

    for (i = 0x0; i < 0x7f; i++) {
        checksum -= buf[i];
    }
    buf[0x7f] = checksum;
}

static void edid_update_detailed_timing(u8* data, misctiming_t* timing_append, u8 detail_count, u8 block)
{
  int i;
  char details[2 * LONG_DESCR_LEN];
  u8 *porg = data + DETAILED_TIMING_OFFSET;
  u8 backup[LONG_DESCR_LEN * NUM_OF_DETAILED_DESCRIPTORS];
  u8 *ptgt;

  memset(backup, 0, LONG_DESCR_LEN * NUM_OF_DETAILED_DESCRIPTORS);

  if (detail_count > 0 && block < 1)
  {
    detailed_timing_t detail_timing;
    if (detail_count > 2)
    {
      detail_count = 2;
    }

    ptgt = (u8*)details;
    for (i = 0; i < detail_count; i++)
    {
      misctiming_t *v_timing = &timing_append[i];
      edid_std_timing_convert(v_timing, &detail_timing);
      edid_detailed_timing_convert(&detail_timing, ptgt);
      ptgt += LONG_DESCR_LEN;
    }

    memcpy(backup, details, LONG_DESCR_LEN * detail_count);
    memcpy(porg, backup, LONG_DESCR_LEN * NUM_OF_DETAILED_DESCRIPTORS);

    edid_checksum_calc(data);
  } 
}

s32 ms91xx_read_flash(struct usb_device* udev, u16 addr, u8* buf, u8 len)
{
    return ms9132_read_flash(udev, addr, buf, len);
}

s32 ms91xx_read_sfr(struct usb_device* udev, u16 addr, u8* data)
{
    return ms9132_read_sfr_data(udev, addr, data);
}

s32 ms91xx_write_sfr(struct usb_device* udev, u16 addr, u8 value)
{
    return ms9132_write_sfr_data(udev, addr, value);
}

s32 ms9132_mod_bits(struct usb_device* udev, u16 addr, u8 value, u8 mask)
{
    u8 reg;
    s32 ret;

    ret = ms9132_read_xdata_once(udev, addr, &reg, 1);
    if (ret) {
        return ret;
    }

    reg &= (u8)(~mask);
    reg |= (u8)(value & mask);

    return ms9132_xdata_write_byte(udev, addr, reg);
}

s32 ms9132_get_edid(struct usb_device* udev, misctiming_t* timing, u8 detail_count, 
    u8 chip_id, u8 port_type, u8 sdram_type, u8 block, u8* buf, u32 len)
{
    s32 ret = 0;

    if ((VIDEO_PORT_YPBPR == port_type) || (VIDEO_PORT_CVBS == port_type) || (VIDEO_PORT_CVBS_SVIDEO == port_type) || (VIDEO_PORT_SVIDEO == port_type)) {
        if (block > 0 ) {
            dev_err(&udev->dev, "video output type %d has only one block!\n", port_type);
            return -EINVAL;
        }
    }

    if ((SDRAM_2M == sdram_type) || (SDRAM_NONE == sdram_type)) {
        if (block > 0 ) {
            dev_err(&udev->dev, "sdram type %d has only one block!\n", sdram_type);
            return -EINVAL;
        }
    }

    if (VIDEO_PORT_YPBPR == port_type) {
        memcpy(buf, edidYPBPR, len);
    } else if ((VIDEO_PORT_CVBS == port_type) || (VIDEO_PORT_CVBS_SVIDEO == port_type) || (VIDEO_PORT_SVIDEO == port_type) || (SDRAM_2M == sdram_type)) {
        memcpy(buf, edidVGA_CVBS, len);
    } else if (SDRAM_NONE == sdram_type) {
        if (USB_SPEED_SUPER == udev->speed) {
            memcpy(buf, edidVGA_USB3, len);
        } else {
            memcpy(buf, edidVGA, len);
        }
    } else {
        u16 addr = MS9132_XDATA_REG_EDID + block * MS9132_EDID_BLOCK_LEN;

        ret = ms9132_read_xdata(udev, addr, buf, (u16)len);
    }

    edid_update_detailed_timing(buf, timing, detail_count, block);

    return ret;
}


s32 ms9132_get_hpd_status(struct usb_device* udev, u32* status)
{
    int rtn;
    u8  stat;

    *status = 0;

    rtn = ms9132_read_xdata_once(udev, MS9132_XDATA_REG_HPD, &stat, 1);
    if (rtn) {
        goto out;
    }

    *status = stat;

out:
    return rtn;
}

s32 ms9132_set_video_in_info(struct usb_device* udev, u16 width, u16 height, u8 color, u8 byte_sel)
{
    struct ms9132_hid_video hid;

    hid.op = MS9132_HID_OP_VIDEO;
    hid.sub_op = MS9132_HID_SUBOP_VIDEO_UPDATE_IN_INFO;
    hid.info.in.width_hi = ((width & 0xff00) >> 8);
    hid.info.in.width_lo = (width & 0xff);
    hid.info.in.height_hi = ((height & 0xff00) >> 8);
    hid.info.in.height_lo = (height & 0xff);
    hid.info.in.color = color;
    hid.info.in.byte_sel = byte_sel;

    return ms9132_hid_report(udev, 1, &hid, sizeof(hid));
}

s32 ms9132_set_video_out_info(struct usb_device* udev, u8 index, u8 color, u16 width, u16 height)
{
    struct ms9132_hid_video hid;
    
    hid.op = MS9132_HID_OP_VIDEO;
    hid.sub_op = MS9132_HID_SUBOP_VIDEO_UPDATE_OUT_INFO;
    hid.info.out.index = index;
    hid.info.out.color = color;
    hid.info.out.width_hi = ((width & 0xff00) >> 8);
    hid.info.out.width_lo = (width & 0xff);
    hid.info.out.height_hi = ((height & 0xff00) >> 8);
    hid.info.out.height_lo = (height & 0xff);

    return ms9132_hid_report(udev, 1, &hid, sizeof(hid));
}

s32 ms9132_trigger_frame(struct usb_device* udev, u8 index, u8 delay)
{
    struct ms9132_hid_video hid;
  
    hid.op = MS9132_HID_OP_VIDEO;
    hid.sub_op = MS9132_HID_SUBOP_VIDEO_TRIGGER_FRAME;
    hid.info.frame_index.index = index;
    hid.info.frame_index.delay = delay;
    memset(&hid.info.frame_index.resv, 0, 4);

    return ms9132_hid_report(udev, 1, &hid, sizeof(hid));
}

s32 ms9132_set_trans_mode(struct usb_device* udev, u8 mode, u8* param, u8 param_cnt)
{
    struct ms9132_hid_video hid;
    
    memset(&hid, 0, sizeof(hid));
    hid.op = MS9132_HID_OP_VIDEO;
    hid.sub_op = MS9132_HID_SUBOP_VIDEO_SET_TRANS_MODE;

    hid.info.trans_mode.mode = mode;
    switch (mode) {
        case MS9132_TRANS_MODE_FRAME:
        case MS9132_TRANS_MODE_MANUAL_BLOCK:
        case MS9132_TRANS_MODE_BYPASS_FRAME:
        case MS9132_TRANS_MODE_BYPASS_MANAUAL_BLOCK:
            break;
        case MS9132_TRANS_MODE_FIX_BLOCK_MN:
        {
            hid.info.trans_mode.param0 = param[0];
            hid.info.trans_mode.param1 = param[1];
            break;
        }
        case MS9132_TRANS_MODE_FIX_BLOCK_WH:
        {
            hid.info.trans_mode.param0 = param[0];
            hid.info.trans_mode.param1 = param[1];
            hid.info.trans_mode.param2 = param[2];
            hid.info.trans_mode.param3 = param[3];
            break;
        }
        default:
            return -1;
    }

    return ms9132_hid_report(udev, 1, &hid, sizeof(hid));
}

s32 ms9132_set_trans_enable(struct usb_device* udev, u8 enable)
{
    struct ms9132_hid_video hid;
    
    hid.op = MS9132_HID_OP_VIDEO;
    hid.sub_op = MS9132_HID_SUBOP_VIDEO_TRANSFER;
    hid.info.transfer.trans = enable;
    memset(&hid.info.transfer.resv, 0, 5);

    return ms9132_hid_report(udev, 1, &hid, sizeof(hid));
}

s32 ms9132_set_screen_enable(struct usb_device* udev, u8 enable, u8 chip_id, u8 port_type, u8 sdram_type)
{
    int ret;
    u8 data;
    u8 mask;
    u16 addr;
    bool is_clear = false;

    if (CHIP_ID_9132 == chip_id) {
        if (VIDEO_PORT_HDMI == port_type) {
            addr = MS9132_XDATA_HDMITX_MUTE;
            mask = (u8)(1 << MS9132_XDATA_HDMITX_MUTE_VIDEO_MUTE_BIT);
            is_clear = true;
        } else {
            addr = 0xf037;
            mask = 0x1;
        }
    } else {
        switch (port_type) {
            case VIDEO_PORT_HDMI:
                addr = 0xf507;
                mask = 0x2;
                is_clear = true;
                break;
            case VIDEO_PORT_VGA:
                addr = 0xf004;
                mask = 0x80;
                break;
            case VIDEO_PORT_YPBPR:
                addr = 0xf030;
                mask = 0x1;
                break;
            case VIDEO_PORT_DIGITAL:
                addr = 0xf005;
                mask = 0x10;
                break;
            default:
                addr = 0xf004;
                mask = 0x2;
                break;
        }
    }

    ret = ms9132_read_xdata_once(udev, addr, &data, 1);
    if (ret) {
        return ret;
    }

    if ((enable != 0) ^ is_clear) {
        data |= mask;
    } else {
        data &= ~mask;
    }

    return ms9132_xdata_write_byte(udev, addr, data);
}

s32 ms9132_set_video_enable(struct usb_device* udev, u8 enable)
{
    struct ms9132_hid_video hid;
    
    hid.op = MS9132_HID_OP_VIDEO;
    hid.sub_op = MS9132_HID_SUBOP_VIDEO_ENABLE;
    hid.info.enable.enable = enable;
    memset(&hid.info.enable.resv, 0, 5);

    return ms9132_hid_report(udev, 1, &hid, sizeof(hid));
}

s32 ms9132_set_power_enable(struct usb_device* udev, u8 enable)
{
    struct ms9132_hid_video hid;
    
    hid.op = MS9132_HID_OP_VIDEO;
    hid.sub_op = MS9132_HID_SUBOP_VIDEO_POWER;
    hid.info.power.on = enable;
    hid.info.power.data = 2;
    memset(&hid.info.power.resv, 0, 4);

    return ms9132_hid_report(udev, 1, &hid, sizeof(hid));
}

s32 ms9132_get_mode_vic(u16 width, u16 height, u8 rate, u8* vic)
{
    int i;
    s32 rtn = -1;
    
    for (i = 0; i < sizeof(g_support_mode) / sizeof(struct video_mode); i++) {
        if ((width == g_support_mode[i].width) && (height == g_support_mode[i].height) \
            && (rate == g_support_mode[i].refresh_rate)) {
            *vic = g_support_mode[i].vic;
            rtn = 0;
            break;
        } 
    }

    return rtn;
}

u8 ms9132_get_trans_bulk_ep(void)
{
    return (u8)MS9132_TRNAS_BULK_EP;
}

s32 ms9132_xdata_write_byte(struct usb_device* udev, u16 addr, u8 data)
{
    struct ms9132_hid_write_data_byte wdata;

    wdata.op = MS9132_HID_OP_WRITE_ONE_BYTE;
    wdata.addr_hi = ((addr & 0xff00) >> 8);
    wdata.addr_lo = (addr & 0xff);
    wdata.data = data;
    wdata.resv[0] = wdata.resv[1] = wdata.resv[2] = wdata.resv[3] = 0;

    return ms9132_hid_report(udev, 1, &wdata, sizeof(wdata));
}

s32 ms9132_xdata_read_byte(struct usb_device* udev, u16 addr, u8* data)
{
    return ms9132_read_xdata_once(udev, addr, data, 1);
}

s32 ms9132_current_frame_index(struct usb_device* udev, u8* index)
{
    s32 ret;
    u8 reg = 0;

   
    ret = ms9132_read_xdata_once(udev, MS9132_XDATA_REG_FRAME_SWITCH, &reg, 1);
    if (!ret) {
        *index = (reg ? 1 : 0);
    }

    return ret;
}

static s32 ms9132_event_enable(struct usb_device* udev, struct usb_hal_event* event, u8 chip_id, u8 port_type, u8 sdram_type)
{
    int width, height;
    int rtn;
    u8 color_in = event->para.enable.color_in;
    u8 color_out = event->para.enable.color_out;
    u8 vic = event->para.enable.vic;
    u8 trans_mode = event->para.enable.trans_mode;

    width = event->para.enable.width;
    height = event->para.enable.height;

    rtn = ms9132_set_trans_enable(udev, 0);
    if (rtn) {
        dev_err(&udev->dev, "stop trans failed! rtn = %d\n", rtn);
        return -1;
    }

	rtn = ms9132_set_video_enable(udev, 0);
    if (rtn) {
        dev_err(&udev->dev, "stop video failed! rtn = %d\n", rtn);
        return -1;
    }

	rtn = ms9132_set_screen_enable(udev, 0, chip_id, port_type, sdram_type);
    if (rtn) {
        dev_err(&udev->dev, "stop screen failed! rtn = %d\n", rtn);
        return -1;
    }

	msleep(50);

    ms9132_set_power_enable(udev, 1);
    if (rtn) {
        dev_err(&udev->dev, "set power failed! rtn = %d\n", rtn);
        return -1;
    }
    msleep(50);

    rtn = ms9132_set_trans_mode(udev, trans_mode, NULL, 0);
    if (rtn) {
        dev_err(&udev->dev, "set trans mode failed! rtn = %d\n", rtn);
        return -1;
    }

    dev_info(&udev->dev, "color in:0x%02x width:%d height:%d\n", color_in, width, height);
    rtn = ms9132_set_video_in_info(udev, width, height, color_in, 0);
    if (rtn) {
        dev_err(&udev->dev, "set video in info failed! rtn = %d\n", rtn);
        return -1;
    }

    dev_info(&udev->dev, "color out:0x%02x width:%d height:%d vic:%d\n", color_out, width, height, vic);
    rtn = ms9132_set_video_out_info(udev, vic, color_out, width, height); 
    if (rtn) {
        dev_err(&udev->dev, "set video out info failed! rtn = %d\n", rtn);
        return -1;
    }

    rtn = ms9132_set_trans_enable(udev, 1);
    if (rtn) {
        dev_err(&udev->dev, "start trans failed! rtn = %d\n", rtn);
        return -1;
    }
    msleep(50);

	// disable video, until first frame sends successfully
    rtn = ms9132_set_video_enable(udev, 0);
    if (rtn) {
        dev_err(&udev->dev, "stop video failed! rtn = %d\n", rtn);
        return -1;
    }

	rtn = ms9132_set_screen_enable(udev, 0, chip_id, port_type, sdram_type);
    if (rtn) {
        dev_err(&udev->dev, "stop screen failed! rtn = %d\n", rtn);
        return -1;
    }

    dev_info(&udev->dev, "pipe enable finished!\n");
    return 0;
}

static s32 ms9132_event_disable(struct usb_device* udev, struct usb_hal_event* event, u8 chip_id, u8 port_type, u8 sdram_type)
{
    int ret;

    dev_info(&udev->dev, "disable hw begin\n");
    ret = ms9132_set_trans_enable(udev, 0);
    if (ret) {
    	dev_err(&udev->dev, "stop trans failed! rtn = %d\n", ret);
    }

    ret = ms9132_set_video_enable(udev, 0);
    if (ret) {
    	dev_err(&udev->dev, "stopt video failed! rtn = %d\n", ret);
    }

	ret = ms9132_set_screen_enable(udev, 0, chip_id, port_type, sdram_type);
    if (ret) {
    	dev_err(&udev->dev, "stopt screen failed! rtn = %d\n", ret);
    }

    ret = ms9132_set_power_enable(udev, 0);
    if (ret) {
       	dev_err(&udev->dev, "power disable failed! rtn = %d\n", ret);
    }

    dev_info(&udev->dev, "disable hw end\n");
    return 0;
}

static s32 ms9132_event_proc(struct usb_device* udev, struct usb_hal_event* event, u8 chip_id, u8 port_type, u8 sdram_type)
{
    if (USB_HAL_EVENT_TYPE_ENABLE == event->base.type) {
        return ms9132_event_enable(udev, event, chip_id, port_type, sdram_type);
    } else if (USB_HAL_EVENT_TYPE_DISABLE == event->base.type) {
        return ms9132_event_disable(udev, event, chip_id, port_type, sdram_type);
    }
    return -1;
}

static s32 ms91xx_get_port_type(struct usb_device* udev, u8* port_type)
{
    s32 ret;
    u8 reg = 0;

    ret = ms9132_read_xdata_once(udev, MS9132_XDATA_REG_VIDEO_PORT, &reg, 1);
    if (!ret) {
        if (reg >= VIDEO_PORT_MAX) {
            return -EINVAL;
        }
        *port_type = reg;
    }

    return ret;
}

static s32 ms91xx_get_sdram_type(struct usb_device* udev, u8* sdram_type)
{
    s32 ret;
    u8 reg = 0;

    ret = ms9132_read_xdata_once(udev, MS9132_XDATA_REG_SDRAM_TYPE, &reg, 1);
    if (!ret) {
        if (reg > SDRAM_NONE) {
            return -EINVAL;
        }
        *sdram_type = reg;
    }

    return ret;
}

static int ms91xx_get_chip_id(struct usb_device* udev, u8* chip_id)
{
    u8 buf[3] = {0, 0, 0};
    s32 ret;

    ret = ms9132_read_xdata(udev, MS9132_XDATA_REG_CHIP_ID, buf, 3);
    if (ret) {
        return ret;
    }

    if ((0x13 == buf[1]) && (0x0a == buf[2])) {
        *chip_id = CHIP_ID_9132;
        return 0;
    }

    buf[0] = buf[1] = buf[2] = 0;
    ret = ms9132_read_xdata(udev, MS9120_XDATA_REG_CHIP_ID, buf, 3);
    if (ret) {
        return ret;
    }

    if ((0x16 == buf[1]) && (0x0a == buf[2])) {
        if (0xb7 == buf[0]) {
            *chip_id = CHIP_ID_912C;
        } else if (0xa7 == buf[0]) {
            *chip_id = CHIP_ID_912A;
        } else {
            *chip_id = CHIP_ID_9120;
        }
    }

    return 0;
}

static s32 ms91xx_init_dev(struct usb_device* udev, u8 chip_id, u8 port_type, u8 sdram_type) 
{
    s32 ret = 0;
    if (VIDEO_PORT_CVBS_SVIDEO == port_type) {
        ret = ms9132_mod_bits(udev, 0xF160, 0x0, 0x20);
        if (ret) {
            return ret;
        }

        ret = ms9132_xdata_write_byte(udev, 0xF031, 0x34);
        if (ret) {
            return ret;
        }
    }

    return ret;
}

const struct msdisp_hal_id ms9132_id = 
{
    .idVendor = MSDISP_913X_VENDOR,
    .idProduct = MSDISP_9132_PRODUCT
};

const struct msdisp_hal_id ms9133_id = 
{
    .idVendor = MSDISP_913X_VENDOR,
    .idProduct = MSDISP_9133_PRODUCT
};

const struct msdisp_hal_id ms9135_id =
{
    .idVendor = MSDISP_913X_VENDOR,
    .idProduct = MSDISP_9135_PRODUCT
};

const struct msdisp_hal_id ms6021_id =
{
    .idVendor = MSDISP_6021_VENDOR,
    .idProduct = MSDISP_6021_PRODUCT
};

const struct msdisp_hal_funcs ms91xx_funcs = {
    .get_edid = ms9132_get_edid,
    .get_hpd_status = ms9132_get_hpd_status,
    .set_video_in_info = ms9132_set_video_in_info,
    .set_video_out_info = ms9132_set_video_out_info,
    .trigger_frame = ms9132_trigger_frame,
    .set_trans_mode = ms9132_set_trans_mode,
    .set_trans_enable = ms9132_set_trans_enable,
    .set_video_enable = ms9132_set_video_enable,
    .set_power_enable = ms9132_set_power_enable,
    .get_mode_vic = ms9132_get_mode_vic,
    .get_transfer_bulk_ep = ms9132_get_trans_bulk_ep,
    .xdata_write_byte = ms9132_xdata_write_byte,
    .xdata_read_byte = ms9132_xdata_read_byte,
    .current_frame_index = ms9132_current_frame_index,
    .set_screen_enable = ms9132_set_screen_enable,
    .event_proc = ms9132_event_proc,
    .get_chip_id= ms91xx_get_chip_id,
    .get_port_type = ms91xx_get_port_type,
    .get_sdram_type = ms91xx_get_sdram_type,
    .read_flash = ms91xx_read_flash,
    .sfr_read_byte = ms91xx_read_sfr,
    .sfr_write_byte = ms91xx_write_sfr,
    .init_dev = ms91xx_init_dev
};

struct msdisp_hal_dev ms9132_dev = {
    .id = &ms9132_id,
    .funcs = &ms91xx_funcs
};

struct msdisp_hal_dev ms9133_dev = {
    .id = &ms9133_id,
    .funcs = &ms91xx_funcs
};

struct msdisp_hal_dev ms9135_dev = {
    .id = &ms9135_id,
    .funcs = &ms91xx_funcs
};

struct msdisp_hal_dev ms6021_dev = {
    .id = &ms6021_id,
    .funcs = &ms91xx_funcs
};
