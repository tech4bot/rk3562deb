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
 * msdisp_drm_connector.h -- Drm driver for MacroSilicon chip 913x and 912x
 */


#ifndef __MSDISP_DRM_CONNECTOR_H__
#define __MSDISP_DRM_CONNECTOR_H__

#include <drm/drm_crtc.h>
#include <drm/drm_connector.h>

struct edid;

struct msdisp_drm_connector {
	struct drm_connector connector;
    enum drm_connector_status status;
	int pipeline_index;
	/* last udl_detect edid */
	struct edid *edid;
};


#endif //__MSDISP_CONNECTOR_H__
