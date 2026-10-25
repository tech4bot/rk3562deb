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
 * msdisp_drm_encoder.c -- Drm driver for MacroSilicon chip 913x and 912x
 */


#include <linux/version.h>
#if KERNEL_VERSION(5, 5, 0) <= LINUX_VERSION_CODE || defined(EL8)
#else
#include <drm/drmP.h>
#endif
#include <drm/drm_crtc.h>
#include <drm/drm_crtc_helper.h>
#include <drm/drm_modeset_helper_vtables.h>


#include "msdisp_drm_drv.h"

/* dummy encoder */
static void msdisp_drm_enc_destroy(struct drm_encoder *encoder)
{
	drm_encoder_cleanup(encoder);
	kfree(encoder);
}

static void msdisp_drm_encoder_enable(__always_unused struct drm_encoder *encoder)
{
}

static void msdisp_drm_encoder_disable(__always_unused struct drm_encoder *encoder)
{
}

static const struct drm_encoder_helper_funcs msdisp_drm_enc_helper_funcs = {
	.enable = msdisp_drm_encoder_enable,
	.disable = msdisp_drm_encoder_disable
};

static const struct drm_encoder_funcs msdisp_drm_enc_funcs = {
	.destroy = msdisp_drm_enc_destroy,
};

struct drm_encoder *msdisp_drm_encoder_init(struct drm_device *dev)
{
	int ret = 0;
	struct drm_encoder *encoder;

	encoder = kzalloc(sizeof(struct drm_encoder), GFP_KERNEL);
	if (!encoder) {
		return NULL;
	}

	ret = drm_encoder_init(dev, encoder, &msdisp_drm_enc_funcs,
			       DRM_MODE_ENCODER_TMDS, dev_name(dev->dev));
	if (ret) {
		dev_err(dev->dev, "Failed to initialize encoder: %d\n", ret);
		goto err_init;
	}

	drm_encoder_helper_add(encoder, &msdisp_drm_enc_helper_funcs);

	return encoder;

err_init:
	kfree(encoder);
	return NULL;
}
