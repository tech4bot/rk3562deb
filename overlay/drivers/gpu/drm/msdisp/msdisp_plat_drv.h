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
 * msdisp_plat_drv.h -- Drm driver for MacroSilicon chip 913x and 912x
 */

#ifndef __MSDISP_PLATFORM_DRV_H__
#define __MSDISP_PLATFORM_DRV_H__

struct device;
struct platform_device_info;


#define DRIVER_NAME   "msdisp"
#define DRIVER_DESC   "MacroSilicon Extensible Display Interface"
#define DRIVER_DATE   "20230710"

#define DRIVER_MAJOR 1
#define DRIVER_MINOR 0
#define DRIVER_PATCH 0
#define PLAT_DRIVER_NAME "msdisp_plat"

#define MSDISP_DEVICE_COUNT_MAX                 3

void msdisp_platform_remove_all_devices(struct device *device);
unsigned int msdisp_platform_device_count(struct device *device);
int msdisp_platform_add_devices(struct device *device, unsigned int val);
int msdisp_platform_device_add(struct device *device);

#endif