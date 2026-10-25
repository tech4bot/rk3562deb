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
 * msdisp_common_util.c -- Drm driver for MacroSilicon chip 913x and 912x
 */

#include <linux/mutex.h>
#include <linux/fs.h>

#include "msdisp_common_util.h"

void msdisp_common_save_buf_to_bmp(u8* buf, u32 width, u32 height, u32 cpp, struct mutex* lock, const char* file_name)
{
	int i;
    struct bmp_file_header fheader;
    struct bmp_info_header iheader;
    struct file* fp;
    loff_t pos;

    fheader.type = 0x4d42;
    fheader.size = width * height * cpp + 0x36;
    fheader.resv1 = fheader.resv2 = 0;
    fheader.offset = 0x36;

    iheader.size = 40;
    iheader.width = width;
    iheader.height = height;
    iheader.planes = 1;
    iheader.bpp = cpp * 8;
    iheader.compression = 0;
    iheader.size_image = width * height * cpp;
    iheader.xpels = iheader.ypels = 0;
    iheader.clr_used = iheader.clr_importent = 0;

    fp = filp_open(file_name, O_RDWR | O_CREAT, 0644);
    if (!fp) {
        printk("create bmp file failed!\n");
        return;
    }

    pos = fp->f_pos;
    __kernel_write(fp, (void*)&fheader, sizeof(fheader), &pos);
    fp->f_pos = pos;

    pos = fp->f_pos;
    __kernel_write(fp, (void*)&iheader, sizeof(iheader), &pos);
    fp->f_pos = pos;

	if (lock) {
		mutex_lock(lock);
	}
	
    for (i = height - 1; i >= 0; i--) {
        pos = fp->f_pos;
        __kernel_write(fp, buf + i * width * cpp, width * cpp, &pos);
        fp->f_pos = pos;
    }

	if (lock) {
		mutex_unlock(lock);
	}

    filp_close(fp, NULL);
}