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
 * usb_hal_dev.h -- Drm driver for MacroSilicon chip 913x and 912x
 */


#ifndef __USB_HAL_DEV_H__
#define __USB_HAL_DEV_H__

#include <linux/types.h>
#include <linux/mutex.h>
#include <linux/kthread.h>
#include <linux/semaphore.h>
#include <linux/wait.h>

#include "usb_hal_interface.h"

#define USB_HAL_TRANS_MODE_FRAME                      0
#define USB_HAL_TRANS_MODE_MANUAL_BLOCK               3

#define USB_HAL_COLOR_FORMAT_RGB565                   0    
#define USB_HAL_COLOR_FORMAT_RGB888                   1
#define USB_HAL_COLOR_FORMAT_YUV422                   2
#define USB_HAL_COLOR_FORMAT_YUV444                   3

#define USB_HAL_DEV_STATE_UNKNOWN                   0
#define USB_HAL_DEV_STATE_ENABLED                   1
#define USB_HAL_DEV_STATE_DISABLED                  2

#define MS9132_USB_BUS_STATUS_NORMAL                0
#define MS9132_USB_BUS_STATUS_SUSPEND               1

#define USB_HAL_BUF_TYPE_USB		                0
#define USB_HAL_BUF_TYPE_DMA		                1
#define USB_HAL_BUF_TYPE_KMALLOC	                2
#define USB_HAL_BUF_TYPE_VMALLOC                    3

#define USB_HAL_BUF_SIZE			            (8 * 1024 * 1024)
#define USB_HAL_BUF_DEF_LEN			            (4 * 1920 * 1080)

#define USB_HAL_CURSOR_WIDTH                    64
#define USB_HAL_CURSOR_HEIGHT                   64
#define USB_HAL_CURSOR_BUF_SIZE                 (USB_HAL_CURSOR_WIDTH * USB_HAL_CURSOR_HEIGHT * 4)

#define USB_HAL_MAX_CUSTOM_MODE                 16

struct sg_table;
struct usb_device;
struct kfifo;

struct msdisp_hal_dev;

struct usb_hal_buffer
{
    u8* buf;
    u32 size;
    u32 len; 
    dma_addr_t dma_addr;
	u32 type;
    struct mutex mutex;
	struct sg_table* sgt;
};

struct usb_hal_cursor_buffer
{
    bool valid;
    u8* buf;
    int x;
    int y;
    int x1;
    int y1;
    int x2;
    int y2;
    struct mutex mutex;
};

struct usb_hal_dev_frame_stat {
    u64 send_total;
    u64 send_success;
    u64 update_event;
    u64 period_send;
    u64 state_error;
    u64 try_lock_fail;
    u64 empty_rect_skip;
    u64 short_send;
};
 
struct usb_hal_change_rect {
    int left;
	int right;
	int top;
    int bottom;
};

struct usb_hal_dev {
    struct usb_hal* hal;
    const struct msdisp_hal_dev *hal_dev;
    struct usb_device* udev;
    struct kfifo* fifo;
    struct usb_hal_video_mode mode;
    struct device* dma_dev;

    volatile int thread_run_flag;
    struct semaphore sema;
    wait_queue_head_t wait_queue;
    struct task_struct* thread;
    int index;
    u8 vpack_in;
    u8 vpack_out;
    u8 color_out;
    u8 vic;
    u8 trans_mode;
    struct usb_hal_buffer usb_buf;
    struct usb_hal_buffer desktop_buf;
    struct usb_hal_cursor_buffer cursor_buf;
    struct usb_hal_cursor_buffer old_cursor_buf;
    struct usb_hal_dev_frame_stat stat;
    atomic_t mouse_moving;
    ktime_t update_time; 
    ktime_t mouse_updatetime;  

    int state;
    int bus_status;
    int first_buf_send;
    int wait_send_cnt;
    unsigned char frame_index;

    struct usb_hal_video_mode custom_mode[USB_HAL_MAX_CUSTOM_MODE];
    int custom_mode_cnt;

    int image_width;
    int image_height;

    struct usb_hal_buffer image_buf;
    struct usb_hal_change_rect rect[2];
};

#endif
