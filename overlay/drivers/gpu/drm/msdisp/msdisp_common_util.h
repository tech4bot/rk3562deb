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
 * msdisp_common_util.h -- Drm driver for MacroSilicon chip 913x and 912x
 */
 
#ifndef __MSDISP_COMMON_UTIL_H__
#define __MSDISP_COMMON_UTIL_H__
#include <linux/types.h>

struct mutex;

struct bmp_file_header
{
    u16 type;
    u32 size;
    u16 resv1;
    u16 resv2;
    u32 offset;
}__attribute__((packed));

struct bmp_info_header
{
    u32 size;
    u32 width;
    u32 height;
    u16 planes;
    u16 bpp;
    u32 compression;
    u32 size_image;
    u32 xpels;
    u32 ypels;
    u32 clr_used;
    u32 clr_importent;
}__attribute__((packed));

void msdisp_common_save_buf_to_bmp(u8* buf, u32 width, u32 height, u32 cpp, struct mutex* lock, const char* file_name);

#endif