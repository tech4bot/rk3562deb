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
 * msdisp_drm_interface.h -- Drm driver for MacroSilicon chip 913x and 912x
 */


#ifndef __MSDISP_DRM_INTERFACE_H__
#define __MSDISP_DRM_INTERFACE_H__

struct platform_device;
struct drm_device;
struct msdisp_usb_hal;
struct kfifo;
struct kobject;

struct platform_device* msdisp_platform_get_device(int id);
int msdisp_platform_get_plat_device_index(struct platform_device* plat_dev);
struct drm_device* msdisp_drm_get_free_device(void);
int msdisp_drm_get_drm_device_index(struct drm_device* drm);
int msdisp_drm_get_free_pipeline_index(struct drm_device* drm);
int msdisp_drm_register_usb_hal(struct drm_device* drm, int pipeline_index, struct msdisp_usb_hal* usb_hal);
int msdisp_drm_unregister_usb_hal(struct drm_device* drm, int pipeline_index);
struct kfifo* msdisp_drm_get_kfifo(struct drm_device* drm, int pipeline_index);
int msdisp_drm_get_pipeline_global_id(struct drm_device* drm, int pipeline_index);
struct kobject* msdisp_drm_get_pipeline_kobject(struct drm_device* drm, int pipeline_index);
#endif
