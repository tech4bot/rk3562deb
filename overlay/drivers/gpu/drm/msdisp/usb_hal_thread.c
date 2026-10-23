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
 * usb_hal_thread.c -- Drm driver for MacroSilicon chip 913x and 912x
 */
 
#include <linux/slab.h>
#include <linux/usb.h>
#include <linux/kfifo.h>
#include <linux/scatterlist.h>

#include "usb_hal_interface.h"
#include "usb_hal_dev.h"
#include "usb_hal_event.h"
#include "usb_hal_thread.h"
#include "hal_adaptor.h"

#define CHAR_RANGE(a) (a<0?0:(a>255?255:a))

static uint usb_hal_idle_refresh_ms = 2500;
module_param_named(idle_refresh_ms, usb_hal_idle_refresh_ms, uint, 0644);
MODULE_PARM_DESC(idle_refresh_ms, "Forced full-frame resend interval in ms when idle (default: 2500)");

struct usb_hal_api_context {
	struct completion	done;
	int			status;
};

static void usb_hal_api_blocking_completion(struct urb *urb)
{
	struct usb_hal_api_context *ctx = urb->context;

	ctx->status = urb->status;
	complete(&ctx->done);
}

static int usb_hal_start_wait_urb(struct urb *urb, int timeout, int *actual_length)
{
	struct usb_hal_api_context ctx;
	unsigned long expire;
	int retval;

	init_completion(&ctx.done);
	urb->context = &ctx;
	urb->actual_length = 0;
	retval = usb_submit_urb(urb, GFP_NOIO);
	if (unlikely(retval))
		goto out;

	expire = timeout ? msecs_to_jiffies(timeout) : MAX_SCHEDULE_TIMEOUT;
	if (!wait_for_completion_timeout(&ctx.done, expire)) {
		usb_kill_urb(urb);
		retval = (ctx.status == -ENOENT ? -ETIMEDOUT : ctx.status);
	} else
		retval = ctx.status;
out:
	if (actual_length)
		*actual_length = urb->actual_length;

	return retval;
}

static int usb_hal_dev_draw_cursor(struct usb_hal_dev* usb_dev)
{
	u8 *pimage;
	u8 *pmouse;
	u8 *pold;  
	int row,col;
	int start_row, end_row, start_col, end_col;
	int img_stride = usb_dev->mode.width * 4;

	//remove old cursor if exist
	struct usb_hal_cursor_buffer* cursor_buf = &usb_dev->old_cursor_buf;
	if (cursor_buf->valid) {
		start_row = cursor_buf->y1;
		start_col = cursor_buf->x1;
		
		end_row = cursor_buf->y2;
		end_col = cursor_buf->x2;

		//copy back the old mouse
		pimage = usb_dev->desktop_buf.buf + start_row * img_stride + start_col * 4;
		pold = cursor_buf->buf;

		for (row = start_row; row < end_row; row++) {
			memcpy(pimage, pold, (end_col - start_col) * 4);
			pimage += img_stride;
			pold += (end_col - start_col) * 4;
		}
	}

	//add new cursor if exist
	cursor_buf = &usb_dev->cursor_buf;
	if (cursor_buf->valid) {
		start_row = cursor_buf->y + cursor_buf->y1;
		if (start_row < 0) start_row = 0;
		start_col = cursor_buf->x + cursor_buf->x1;
		if (start_col < 0) start_col = 0;	
		
		end_row = cursor_buf->y + cursor_buf->y2;
		if (end_row > usb_dev->mode.height) end_row = usb_dev->mode.height;
		end_col = cursor_buf->x + cursor_buf->x2;
		if (end_col > usb_dev->mode.width) end_col = usb_dev->mode.width;

		if (start_row >= end_row || start_col >= end_col) {
			usb_dev->old_cursor_buf.valid = false;
		} else {
			//copy back the old mouse
			pimage = usb_dev->desktop_buf.buf + start_row * img_stride + start_col * 4;
			pmouse = usb_dev->cursor_buf.buf + ((start_row - cursor_buf->y) * USB_HAL_CURSOR_WIDTH
						 + (start_col - cursor_buf->x) ) * 4;
			pold = usb_dev->old_cursor_buf.buf;

			for (row = start_row; row < end_row; row++) {
				u8 *pimage_row = pimage;
				u8 *pmouse_row = pmouse;

				memcpy(pold, pimage_row, (end_col-start_col) * 4);
				for (col = start_col; col < end_col; col++) {
					if (pmouse_row[3] >= 192) {
						pimage_row[0] = pmouse_row[0];
						pimage_row[1] = pmouse_row[1];
						pimage_row[2] = pmouse_row[2];
					} else if (pmouse_row[3] >= 128) {
						pimage_row[0] = ((pmouse_row[0] >> 2) + (pimage_row[0] >> 2) + (pimage_row[0] >> 1));
						pimage_row[1] = ((pmouse_row[1] >> 2) + (pimage_row[1] >> 2) + (pimage_row[1] >> 1));
						pimage_row[2] = ((pmouse_row[2] >> 2) + (pimage_row[2] >> 2) + (pimage_row[2] >> 1));
					} else if (pmouse_row[3] >= 64) {
						pimage_row[0] = ((pmouse_row[0] >> 2) + (pmouse_row[0] >> 1) + (pimage_row[0] >> 2));
						pimage_row[1] = ((pmouse_row[1] >> 2) + (pmouse_row[1] >> 1) + (pimage_row[1] >> 2));
						pimage_row[2] = ((pmouse_row[2] >> 2) + (pmouse_row[2] >> 1) + (pimage_row[2] >> 2));
					}
					pmouse_row += 4;
					pimage_row += 4;
				}

				pimage += img_stride;
				pmouse += USB_HAL_CURSOR_WIDTH * 4;
				pold += (end_col - start_col) * 4;
			}
			
			usb_dev->old_cursor_buf.x1 = start_col;
			usb_dev->old_cursor_buf.y1 = start_row;
			usb_dev->old_cursor_buf.x2 = end_col;
			usb_dev->old_cursor_buf.y2 = end_row;
			usb_dev->old_cursor_buf.valid = true;
		}
	} else {
		usb_dev->old_cursor_buf.valid = false;
	}

	return 0;
}

static void usb_hal_image_to_yuv(struct usb_hal_dev* usb_dev)
{
    int row, i;
	int b1, g1, r1, b2, g2, r2;
	int y0, y1, u0, v0;

	u8* psrc;
	u8* pdst = usb_dev->usb_buf.buf + 8;
	u8* pline = usb_dev->desktop_buf.buf + (usb_dev->rect[usb_dev->frame_index].top * usb_dev->mode.width * 4) 
					+ (usb_dev->rect[usb_dev->frame_index].left * 4);

	int block_width = usb_dev->rect[usb_dev->frame_index].right - usb_dev->rect[usb_dev->frame_index].left;
	int block_height = usb_dev->rect[usb_dev->frame_index].bottom - usb_dev->rect[usb_dev->frame_index].top;

	for (row = 0; row < block_height; row++) {
		psrc = pline;
		for (i = 0; i < block_width; i += 2) {
			b1 = *psrc++;
			g1 = *psrc++;
			r1 = *psrc++;
			psrc += 1;

			b2 = *psrc++;
			g2 = *psrc++;
			r2 = *psrc++;
			psrc += 1;

			y0 = ((263 * r1 + 516 * g1 + 97 * b1) >> 10) + 16;
			u0 = ((-152 * r1 - 298 * g1 + 450 * b1) >> 10) + 128;
			v0 = ((450 * r1 - 377 * g1 - 73 * b1) >> 10) + 128;

			y1 = ((263 * r2 + 516 * g2 + 97 * b2) >> 10) + 16;
			u0 += ((-152 * r2 - 298 * g2 + 450 * b2) >> 10) + 128;
			v0 += ((450 * r2 - 377 * g2 - 73 * b2) >> 10) + 128;

			u0 >>= 1;
			v0 >>= 1;

			u0 = CHAR_RANGE(u0);
			v0 = CHAR_RANGE(v0);
			y0 = CHAR_RANGE(y0);
			y1 = CHAR_RANGE(y1);

			*pdst++ = (u8)u0;
			*pdst++ = (u8)y0;
			*pdst++ = (u8)v0;    
			*pdst++ = (u8)y1;
		}
		pline += usb_dev->mode.width * 4;
	}

    usb_dev->usb_buf.len = (block_width * block_height * 2) + 16;
}

static void usb_hal_package_block(struct usb_hal_dev* usb_dev)
{
	int size = usb_dev->usb_buf.len;
    u8* src = usb_dev->usb_buf.buf;
	u8* pdata = src;

	u16 coladdr = usb_dev->rect[usb_dev->frame_index].left;
	u16 rowaddr = usb_dev->rect[usb_dev->frame_index].top;
	u16 width = usb_dev->rect[usb_dev->frame_index].right - usb_dev->rect[usb_dev->frame_index].left;
	u16 height = usb_dev->rect[usb_dev->frame_index].bottom - usb_dev->rect[usb_dev->frame_index].top;

    *pdata++ = 0xFF;
    *pdata++ = 0x00;
    *pdata++ = (u8)((coladdr & 0xFF0) >> 4);
    *pdata++ = (u8)((coladdr & 0xF) << 4) | ((rowaddr & 0xF00) >> 8);
    *pdata++ = (u8)((rowaddr & 0xFF));
    *pdata++ = (u8)((width & 0xFF0) >> 4);
    *pdata++ = (u8)((width & 0xF) << 4) | ((height & 0xF00) >> 8);
    *pdata++ = (u8)((height & 0xFF));

    pdata = src + size - 8;

    *pdata++ = 0xFF;
    *pdata++ = 0xC0;
    *pdata++ = 0x00;
    *pdata++ = 0x00;
    *pdata++ = 0x00;
    *pdata++ = 0x00;
    *pdata++ = 0x00;
    *pdata++ = 0x00;
}

static bool usb_hal_compare_line(u8* buffer_a, u8* buffer_b, int step, int len)
{
	u32 *p_a = (u32*)buffer_a;
	u32 *p_b = (u32*)buffer_b;

	while (len--) {
		if (*p_a != *p_b) {
			return true;
		}
		p_a += step;
		p_b += step;
	}

	return false;
}

static void usb_hal_combine_rects(struct usb_hal_dev* usb_dev, int left, int top, int right, int bottom)
{
	int i;
	for (i = 0; i < 2; i++) {
		usb_dev->rect[i].left = min(usb_dev->rect[i].left, left);
		usb_dev->rect[i].top = min(usb_dev->rect[i].top, top);
		usb_dev->rect[i].right = max(usb_dev->rect[i].right, right);
		usb_dev->rect[i].bottom =  max(usb_dev->rect[i].bottom, bottom);

		usb_dev->rect[i].left &= 0xFFC;
		/* Alignment must not extend the update past the packed image rows.
		 * For example, a 1366-pixel row must never become a 1368-pixel
		 * transfer: the YUV converter advances by mode.width per row. */
		usb_dev->rect[i].right = min((usb_dev->rect[i].right + 3) & 0xFFC,
					    usb_dev->mode.width);
		usb_dev->rect[i].top &= 0xFFE;
		usb_dev->rect[i].bottom = min((usb_dev->rect[i].bottom + 1) & 0xFFE,
					     usb_dev->mode.height);
	}
}

static void usb_hal_update_change_rects(struct usb_hal_dev* usb_dev)
{
	int row, col;
	int bytesperline;
	int top, left, bottom, right;
	int width = usb_dev->mode.width;
	int height = usb_dev->mode.height;
	int line_stride = usb_dev->mode.width * 4; 
	u8 *p_old = usb_dev->image_buf.buf;
	u8 *p_new = usb_dev->desktop_buf.buf;

	left = usb_dev->mode.width;
	top = usb_dev->mode.height;
	right = 0;
	bottom = 0;

	//check the top
	for (row = 0; row < height; row++) {
		if (usb_hal_compare_line(p_old, p_new, 1, width)) {
			top = row;
			bottom = row + 1;
			break;
		}
		p_old += line_stride;
		p_new += line_stride;
	}

	if (top == height) {
		return;
	}

	//check the bottom
	p_old = usb_dev->image_buf.buf + width * (height - 1) * 4; 
	p_new = usb_dev->desktop_buf.buf + width * (height - 1) * 4;
	for (row = height - 1; row >= bottom; row--) {
		if (usb_hal_compare_line(p_old, p_new, 1, width)) {
			bottom = row + 1;
			break;
		}
		p_old -= line_stride;
		p_new -= line_stride;
	}

	//check the left
	p_old = usb_dev->image_buf.buf + top * line_stride;
	p_new = usb_dev->desktop_buf.buf + top * line_stride;
	for (col = 0; col < width; col++) {
		if (usb_hal_compare_line(p_old, p_new, width, bottom - top)) {
			left = col;
			right = col + 1;
			break;
		}
		p_old += 4;
		p_new += 4;
	}

	//check the right 
	p_old = usb_dev->image_buf.buf + (width - 1) * 4 + top * line_stride;
	p_new = usb_dev->desktop_buf.buf + (width - 1) * 4 + top * line_stride;
	for (col = width - 1; col >= right; col--) {
		if (usb_hal_compare_line(p_old, p_new, width, bottom - top)) {
			right = col + 1;
			break;
		}
		p_old -= 4;
		p_new -= 4;
	}

	//update buffer
	if (left == 0 && right == width) {
		p_old = usb_dev->image_buf.buf + top * line_stride;
		p_new = usb_dev->desktop_buf.buf + top * line_stride;
		memcpy(p_old, p_new, (bottom - top) * line_stride);
	} else {
		bytesperline = (right - left) * 4;
		p_old = usb_dev->image_buf.buf + top * line_stride + left * 4;
		p_new = usb_dev->desktop_buf.buf + top * line_stride + left * 4;
		for (row = top; row < bottom; row++) {
			memcpy(p_old, p_new, bytesperline);
			p_old += line_stride;
			p_new += line_stride;
		}
	}

	usb_hal_combine_rects(usb_dev, left, top, right, bottom);
}

static void usb_hal_full_rects(struct usb_hal_dev* usb_dev)
{
	int i;
	for (i = 0; i < 2; i++) {
		usb_dev->rect[i].left = 0;
		usb_dev->rect[i].top = 0;
		usb_dev->rect[i].right = usb_dev->mode.width;
		usb_dev->rect[i].bottom =  usb_dev->mode.height;
	}
}

static void usb_hal_clear_rect(struct usb_hal_dev* usb_dev, int index)
{
	usb_dev->rect[index].left = usb_dev->mode.width;
	usb_dev->rect[index].top = usb_dev->mode.height;
	usb_dev->rect[index].right = 0;
	usb_dev->rect[index].bottom = 0;
}

static int usb_hal_dev_send_frame(struct usb_hal_dev* usb_dev, struct urb* data_urb, unsigned char* zero_msg, int ep)
{
	int real_ret, ret, snd_len;
	s64 elapsed_ms;
	ktime_t start_time, end_time;
	struct usb_device* udev = usb_dev->udev;

	real_ret = 0;
	usb_dev->stat.send_total++;
	start_time = ktime_get();

	mutex_lock(&usb_dev->usb_buf.mutex);
	mutex_lock(&usb_dev->cursor_buf.mutex);
	usb_hal_dev_draw_cursor(usb_dev);
	mutex_unlock(&usb_dev->cursor_buf.mutex);

	usb_hal_update_change_rects(usb_dev);
	if (usb_dev->rect[usb_dev->frame_index].left >= usb_dev->rect[usb_dev->frame_index].right) {
			usb_dev->stat.empty_rect_skip++;
			mutex_unlock(&usb_dev->usb_buf.mutex);
			return -1;
	}

	usb_hal_image_to_yuv(usb_dev);
	usb_hal_package_block(usb_dev);
	usb_hal_clear_rect(usb_dev, usb_dev->frame_index);
	mutex_unlock(&usb_dev->usb_buf.mutex);

	start_time = ktime_get();
	if ((USB_HAL_BUF_TYPE_USB == usb_dev->usb_buf.type) || (USB_HAL_BUF_TYPE_DMA == usb_dev->usb_buf.type)) {
		/* The chip stalls (-110/ETIMEDOUT) when handed a whole ~1.2MB frame as a
		 * single bulk URB. A USB capture of the vendor Windows driver shows it
		 * splitting each frame into 64KB chunks submitted back-to-back, which is
		 * almost certainly the chip's real internal transfer limit. usb_buf is a
		 * single physically-contiguous allocation for these buffer types, so this
		 * is a plain offset walk with no scatter-gather needed. */
		const unsigned int chunk_size = 64 * 1024;
		unsigned int remaining = usb_dev->usb_buf.len;
		unsigned int offset = 0;

		while (remaining > 0) {
			unsigned int len = remaining > chunk_size ? chunk_size : remaining;

			usb_fill_bulk_urb(data_urb, udev, usb_sndbulkpipe(udev, ep), usb_dev->usb_buf.buf + offset, len,
					usb_hal_api_blocking_completion, NULL);
			data_urb->transfer_dma = usb_dev->usb_buf.dma_addr + offset;
			data_urb->transfer_flags |= URB_NO_TRANSFER_DMA_MAP;

			ret = usb_hal_start_wait_urb(data_urb, 2000, &snd_len);
			if (ret) {
				dev_err(&udev->dev, "wait urb failed!\n ret = %d (offset=%u len=%u)\n", ret, offset, len);
				real_ret = ret;
				break;
			}
			if (snd_len != len) {
				/* Advancing by the requested length after a short transfer
				 * shifts every subsequent chunk of this frame. */
				usb_dev->stat.short_send++;
				dev_err_ratelimited(&udev->dev,
					"short bulk transfer! offset=%u requested=%u actual=%d\n",
					offset, len, snd_len);
				real_ret = -EIO;
				break;
			}
			offset += len;
			remaining -= len;
		}
	} else {
		usb_fill_bulk_urb(data_urb, udev, usb_sndbulkpipe(udev, ep), usb_dev->usb_buf.buf, usb_dev->usb_buf.len,
				usb_hal_api_blocking_completion, NULL);
		if (USB_HAL_BUF_TYPE_VMALLOC == usb_dev->usb_buf.type) {
			data_urb->num_sgs = usb_dev->usb_buf.sgt->orig_nents;
			data_urb->sg = usb_dev->usb_buf.sgt->sgl;
		}

		ret = usb_hal_start_wait_urb(data_urb, 2000, &snd_len);
		if (ret) {
			dev_err(&udev->dev, "wait urb failed!\n ret = %d\n", ret);
			real_ret = ret;
		}
	}

	if (!real_ret) {
		usb_dev->stat.send_success++;
	}

    ret = usb_bulk_msg(udev, usb_sndbulkpipe(udev, ep), zero_msg, 0, &snd_len, 2000);
    if (ret) {
        dev_err(&udev->dev, "send zero msg failed! ret=%d\n", ret);
    }
	end_time = ktime_get();

	elapsed_ms = ktime_to_ms(ktime_sub(end_time, start_time));
	if(elapsed_ms > 150) {
		dev_warn(&udev->dev, "send frame Elapsed time: %lld ms\n", elapsed_ms);
	}

	if (!real_ret) {
		/* The chip's real double-buffer index only advances when it actually
		 * receives a frame. Toggling unconditionally (including after a failed
		 * or timed-out send) permanently desyncs our tracking from the chip
		 * until the next disable/enable cycle, so subsequent partial updates
		 * land in the wrong physical buffer. */
		usb_dev->frame_index = ((0 == usb_dev->frame_index) ? 1 : 0);
	}
   	//usb_dev->hal_dev->funcs->trigger_frame(usb_dev->udev, usb_dev->frame_index, 100);

	usb_dev->update_time = ktime_get();

	return real_ret;
}

static void usb_hal_dev_do_enable(struct usb_hal_dev* usb_dev, struct usb_hal_event* event)
{
    unsigned char frame_index = 0;
    int ret;
    const struct msdisp_hal_dev* hal_dev = usb_dev->hal_dev;
    struct usb_device* udev = usb_dev->udev;
	struct usb_hal* hal = usb_dev->hal;

    ret = hal_dev->funcs->event_proc(usb_dev->udev, event, hal->chip_id, hal->port_type, hal->sdram_type);
    if (ret) {
        dev_err(&udev->dev, "hal dev enable event proc failed! ret=%d\n", ret);
    }

    ret = hal_dev->funcs->current_frame_index(udev, &frame_index);
	if (!ret) {
		usb_dev->frame_index = frame_index;
		dev_info(&udev->dev, "current index:%d\n", frame_index);
	} else {
		dev_info(&udev->dev, "get frame index failed! rtn = %d\n", ret);
		usb_dev->frame_index = 0;
	}

	usb_dev->state = USB_HAL_DEV_STATE_ENABLED;
	usb_dev->first_buf_send = 0;
}

static void usb_hal_dev_do_disable(struct usb_hal_dev* usb_dev, struct usb_hal_event* event)
{
    int ret;
    const struct msdisp_hal_dev* hal_dev = usb_dev->hal_dev;
    struct usb_device* udev = usb_dev->udev;
	struct usb_hal* hal = usb_dev->hal;

    ret = hal_dev->funcs->event_proc(usb_dev->udev, event, hal->chip_id, hal->port_type, hal->sdram_type);
    if (ret) {
        dev_err(&udev->dev, "hal dev disable event proc failed! ret=%d\n", ret);
    }

    usb_dev->state = USB_HAL_DEV_STATE_DISABLED;
}

static void usb_hal_dev_do_update(struct usb_hal_dev* usb_dev, struct urb* data_urb, unsigned char* zero_msg, int ep)
{
    int ret;
	const struct msdisp_hal_dev* hal_dev = usb_dev->hal_dev;
	struct usb_device *udev = usb_dev->udev;

	usb_dev->stat.update_event++;
	usb_dev->wait_send_cnt = 0;

	ret = usb_hal_dev_send_frame(usb_dev, data_urb, zero_msg, ep);
	if (ret) {
		goto out;
	}

	if (0 == usb_dev->first_buf_send) {
		struct usb_hal* hal = usb_dev->hal;
		ret = hal_dev->funcs->set_video_enable(udev, 1);
    	if (ret) {
        	dev_err(&udev->dev, "start video failed! rtn = %d\n", ret);
		}

		ret = hal_dev->funcs->set_screen_enable(udev, 1, hal->chip_id, hal->port_type, hal->sdram_type);
    	if (ret) {
        	dev_err(&udev->dev, "stop screen failed! rtn = %d\n", ret);
    	}

		usb_dev->first_buf_send = 1;
		usb_hal_full_rects(usb_dev);
		
		dev_info(&udev->dev, "start video success!\n");
	}
out:
	return;
}

void usb_hal_dev_state_unknown(struct usb_hal_dev* usb_dev, struct usb_hal_event* event)
{
	if (USB_HAL_EVENT_TYPE_ENABLE == event->base.type ) {
		dev_info(&usb_dev->udev->dev, "event:%x width:%d height:%d\n", event->base.type, event->para.enable.width, \
        event->para.enable.height);
	}
    
	/* in unknown state, only process enable event*/
	if (event->base.type != USB_HAL_EVENT_TYPE_ENABLE) {
		return;
	}

    usb_hal_dev_do_enable(usb_dev, event);
}

#if 0
void usb_hal_dev_state_enable(struct usb_hal_dev* usb_dev, struct urb* data_urb, unsigned char* zero_msg, int ep, struct usb_hal_event* event)
{
    if (USB_HAL_EVENT_TYPE_DISABLE == event->base.type) {
        usb_hal_dev_do_disable(usb_dev, event);
        return ;
    }

    if (USB_HAL_EVENT_TYPE_UPDATE == event->base.type) {
        usb_hal_dev_do_update(usb_dev, data_urb, zero_msg, ep, event);
    }
}
#endif

void usb_hal_state_machine(struct usb_hal_dev* usb_dev, struct urb* data_urb, unsigned char* zero_msg, int ep, struct kfifo* fifo)
{
    int len;
	struct usb_hal_event event;
	bool bupdate = false;
	ktime_t current_time;
	long timeout;
	s64 elapsed_ms;
	long remaining_ms;

	/* Calculate remaining time until the next periodic idle refresh.
	 * When idle, sleep in TASK_INTERRUPTIBLE (State S) instead of
	 * busy-polling with 1ms uninterruptible sleeps (State D). */
	current_time = ktime_get();
	elapsed_ms = ktime_to_ms(ktime_sub(current_time, usb_dev->update_time));
	remaining_ms = (long)usb_hal_idle_refresh_ms - (long)elapsed_ms;
	if (remaining_ms <= 0)
		remaining_ms = 10;
	else if (remaining_ms > usb_hal_idle_refresh_ms)
		remaining_ms = usb_hal_idle_refresh_ms;

	timeout = msecs_to_jiffies(remaining_ms);

	wait_event_interruptible_timeout(usb_dev->wait_queue,
		!kfifo_is_empty(fifo) ||
		(1 == atomic_read(&usb_dev->mouse_moving)) ||
		!usb_dev->thread_run_flag ||
		MS9132_USB_BUS_STATUS_SUSPEND == usb_dev->bus_status,
		timeout);

    // if usb will be suspend, not process, until usb resume
	if ( MS9132_USB_BUS_STATUS_SUSPEND == usb_dev->bus_status) {
		return;
	}

	// event received, proc event
	while ((len = kfifo_out(fifo, &event, sizeof(event)) != 0)) {
		switch (usb_dev->state) {
			case USB_HAL_DEV_STATE_UNKNOWN:
			case USB_HAL_DEV_STATE_DISABLED:
				usb_hal_dev_state_unknown(usb_dev, &event);
				break;

			case USB_HAL_DEV_STATE_ENABLED:
				if (USB_HAL_EVENT_TYPE_DISABLE == event.base.type) {
					usb_hal_dev_do_disable(usb_dev, &event);
				}

				if (USB_HAL_EVENT_TYPE_UPDATE == event.base.type) {
					bupdate = true;
				}
				break;
		}
	}

	if (USB_HAL_DEV_STATE_ENABLED != usb_dev->state) return;
	if (!bupdate) {
		current_time = ktime_get();	
		if (1 == atomic_cmpxchg(&usb_dev->mouse_moving, 1, 0)) {
				bupdate = true;
		} 

		if (!bupdate) {
			if ((ktime_to_ms(ktime_sub(current_time, usb_dev->update_time))) >= usb_hal_idle_refresh_ms) {
				bupdate = true;
				usb_hal_full_rects(usb_dev);
			} 
		}
	}

	if (bupdate) {
		usb_hal_dev_do_update(usb_dev, data_urb, zero_msg, ep);
		return;
	}
}

int usb_hal_state_machine_entry(void* data)
{
    struct usb_hal* usb_hal = (struct usb_hal *)data;
    struct usb_hal_dev* usb_dev = (struct usb_hal_dev*)usb_hal->private;
	struct urb* data_urb;
    int ep;
	int counter = 0;
	unsigned char* zero_msg;
    struct kfifo* fifo;

	dev_info(&usb_dev->udev->dev, "state machine proc enter!\n");

    fifo = usb_dev->fifo;

	zero_msg = kmalloc(8, GFP_KERNEL);
	if (!zero_msg){
		return -ENOMEM;
	}

	data_urb = usb_alloc_urb(0, GFP_KERNEL);
	if (!data_urb) {
		kfree(zero_msg);
		return -ENOMEM;
	}

    ep = usb_dev->hal_dev->funcs->get_transfer_bulk_ep();
	/* wait for drm enable */
    while(usb_dev->thread_run_flag) {
        usb_hal_state_machine(usb_dev, data_urb, zero_msg, ep, fifo);		
		counter++;
    }

	usb_free_urb(data_urb);
	kfree(zero_msg);

    return 0;
}

void usb_hal_stop_thread(struct usb_hal_dev *usb_dev)
{
    usb_dev->thread_run_flag = 0;
    wake_up_interruptible(&usb_dev->wait_queue);
}