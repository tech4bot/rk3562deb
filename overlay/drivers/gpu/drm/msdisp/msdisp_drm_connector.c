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
 * msdisp_drm_connector.c -- Drm driver for MacroSilicon chip 913x and 912x
 */


#include <linux/version.h>
#include <drm/drm_crtc.h>
#include <drm/drm_edid.h>
#include <drm/drm_modes.h>
#include <drm/drm_crtc_helper.h>
#include <drm/drm_atomic_helper.h>

#if KERNEL_VERSION(5, 1, 0) <= LINUX_VERSION_CODE || defined(EL8)
#include <drm/drm_probe_helper.h>
#endif

#include <drm/drm_print.h>

#include "msdisp_drm_drv.h"
#include "msdisp_drm_connector.h"
#include "msdisp_usb_interface.h"
#include "msdisp_drm_mode.h"



static struct msdisp_drm_pipeline* get_pipeline_by_connector(struct drm_connector* connector) 
{
	struct msdisp_drm_device *msdisp_drm = to_msdisp_drm(connector->dev);
	struct msdisp_drm_connector *msdisp_connector =
					container_of(connector,
					struct msdisp_drm_connector,
					connector);
	struct msdisp_drm_pipeline* pipeline;

	pipeline = &msdisp_drm->pipeline[msdisp_connector->pipeline_index];

	return pipeline;
}


/*
 * dummy connector to just get EDID,
 * all MSDISP_DRM appear to have a DVI-D
 */

static int msdisp_drm_get_edid_block(void *data, u8 *buf, unsigned int block,
			       size_t len)
{
	struct msdisp_drm_pipeline* pipeline = (struct msdisp_drm_pipeline*)data;
	struct msdisp_usb_hal* usb_hal;
	int ret;

	mutex_lock(&pipeline->hal_lock);
	usb_hal = pipeline->usb_hal;
	if (!usb_hal) {
		ret = -EINVAL;
		goto out;
	}

	ret = usb_hal->funcs->get_edid(usb_hal, block, buf, len);

out:
	mutex_unlock(&pipeline->hal_lock);
    return ret;
}

static int msdisp_drm_add_modes_by_cea_vic(struct drm_connector* connector)
{
	struct msdisp_drm_pipeline* pipeline;
	struct msdisp_usb_hal* usb_hal;
	int cnt = 0, get_cnt = 0, ret, i;
	unsigned char vics[8];
	struct drm_display_mode* mode = NULL;

	pipeline = get_pipeline_by_connector(connector);
	mutex_lock(&pipeline->hal_lock);
	usb_hal = pipeline->usb_hal;
	if (!usb_hal) {
		goto out;
	}

	ret = usb_hal->funcs->get_custom_cea_vic(usb_hal, vics, 8, &get_cnt);
	if (ret) {
		goto out;
	}

	for (i = 0; i < get_cnt; i++) {
		mode = msdisp_mode_from_cea_vic(connector->dev, vics[i]);
		if (!mode) {
			continue;
		}
		/* This dongle drives a DDC-less VGA display: any EDID we do
		 * manage to read (see msdisp_drm_get_modes) is unreliable --
		 * observed to succeed on some boots and fail on others,
		 * apparently a chip-internal generic/canned EDID rather than
		 * anything from the actual monitor. When it "succeeds" its
		 * declared established-timings (e.g. 800x600@60) get added as
		 * the preferred mode ahead of these, and the chip's own
		 * mode-mapper then maps that unconfigured request to an
		 * unrelated internal VIC, producing an invalid signal (no
		 * image). Force the first configured custom mode preferred so
		 * fbdev always deterministically picks a mode we know this
		 * chip can actually output, regardless of whether the flaky
		 * EDID read happens to succeed this boot. */
		if (i == 0) {
			mode->type |= DRM_MODE_TYPE_PREFERRED;
		}
		drm_mode_probed_add(connector, mode);
		cnt++;
	}

out:
	mutex_unlock(&pipeline->hal_lock);
	return cnt;
}

static int msdisp_drm_get_modes(struct drm_connector *connector)
{
    int cnt = 0, vic_cnt = 0;
	struct msdisp_drm_connector *msdisp_connector =
					container_of(connector,
					struct msdisp_drm_connector,
					connector);

	drm_connector_update_edid_property(connector, msdisp_connector->edid);
	vic_cnt = msdisp_drm_add_modes_by_cea_vic(connector);
	/* When custom_mode is configured (vic_cnt > 0), trust only the custom
	 * CEA VIC list to prevent flaky/canned EDIDs on DDC-less displays
	 * from overriding it. When custom_mode is not set, add standard EDID
	 * modes so standard MS9132/9133 HDMI panels work properly. */
	if (vic_cnt == 0 && msdisp_connector->edid) {
		cnt = drm_add_edid_modes(connector, msdisp_connector->edid);
	}
	return cnt + vic_cnt;
}

static enum drm_mode_status msdisp_drm_mode_valid(struct drm_connector *connector,
#if KERNEL_VERSION(6, 15, 0) <= LINUX_VERSION_CODE
					    const struct drm_display_mode *mode)
#else
					    struct drm_display_mode *mode)
#endif
{
	struct msdisp_drm_pipeline* pipeline;
	struct msdisp_usb_hal* usb_hal;
	int ret;

	pipeline = get_pipeline_by_connector(connector);
	mutex_lock(&pipeline->hal_lock);
	usb_hal = pipeline->usb_hal;
	if (!usb_hal) {
		ret = 1;
		goto out;
	}

	ret = usb_hal->funcs->mode_valid(usb_hal, mode->hdisplay, mode->vdisplay, drm_mode_vrefresh(mode));

out:
	mutex_unlock(&pipeline->hal_lock);
	return (0 == ret) ? MODE_OK : MODE_BAD;
}

static enum drm_connector_status
msdisp_drm_detect(struct drm_connector *connector, __always_unused bool force)
{
	s32 rtn;
    u32 stat;
	enum drm_connector_status status;
	struct msdisp_drm_device* msdisp_drm = to_msdisp_drm(connector->dev);
	struct msdisp_usb_hal* usb_hal;
	struct msdisp_drm_pipeline* pipeline;
	struct msdisp_drm_connector* msdisp_connector =
				container_of(connector,
				struct msdisp_drm_connector,
				connector);

	pipeline = &msdisp_drm->pipeline[msdisp_connector->pipeline_index];
	mutex_lock(&pipeline->hal_lock);
	usb_hal = pipeline->usb_hal;
	
	if (!usb_hal) {
		status = connector_status_disconnected;
	} else {
		rtn = usb_hal->funcs->get_hpd_status(usb_hal, &stat);
		if (rtn) {
			status = connector_status_disconnected;
		} else {
			status = stat ? connector_status_connected : connector_status_disconnected;
		}
	}
	mutex_unlock(&pipeline->hal_lock);

    if (msdisp_connector->status != status) {
        dev_info(connector->dev->dev, "status changed! old:%d new:%d\n", msdisp_connector->status, status);
    }
    
    /* get edid when first checked */
    if ((connector_status_connected != msdisp_connector->status) && (connector_status_connected == status)) {
        if (msdisp_connector->edid) {
            kfree(msdisp_connector->edid);
        }

#if KERNEL_VERSION(6, 12, 0) <= LINUX_VERSION_CODE
        /* drm_do_get_edid() was removed in 6.13; read via drm_edid and
         * keep a raw copy so the rest of the driver (kfree/add_modes)
         * works unchanged.
         *
         * Debian's 6.12.101+deb13 backports the 6.13 EDID API (drm_edid_read_custom
         * exists, drm_do_get_edid does not) while still reporting LINUX_VERSION_CODE
         * as 6.12, so the upstream >=6.13 guard misses it. Lowered to 6.12 here.
         */
        {
            const struct drm_edid *drm_edid;
            const struct edid *raw;

            msdisp_connector->edid = NULL;
            drm_edid = drm_edid_read_custom(connector, msdisp_drm_get_edid_block, pipeline);
            if (drm_edid) {
                raw = drm_edid_raw(drm_edid);
                if (raw)
                    msdisp_connector->edid = kmemdup(raw,
                        (raw->extensions + 1) * EDID_LENGTH, GFP_KERNEL);
                drm_edid_free(drm_edid);
            }
        }
#else
        msdisp_connector->edid = drm_do_get_edid(connector, msdisp_drm_get_edid_block, pipeline);
#endif
	    if (!msdisp_connector->edid) {
            /* VGA monitors/cables without DDC never return EDID; the chip's
             * own HPD sense already told us something is physically plugged
             * in (status==connected above), so don't force disconnected here
             * -- fall through and let custom_mode-derived CEA VIC modes
             * (added unconditionally in msdisp_drm_get_modes) drive it. */
            DRM_ERROR("get edid failed! (continuing without EDID, using custom_mode if set)\n");
        }
    }

    msdisp_connector->status = status;

	return status;

}

static void msdisp_drm_connector_destroy(struct drm_connector *connector)
{
	struct msdisp_drm_connector *msdisp_conn =
					container_of(connector,
					struct msdisp_drm_connector,
					connector);

	drm_connector_cleanup(connector);
	kfree(msdisp_conn->edid);
	kfree(msdisp_conn);
}

static struct drm_encoder *msdisp_drm_best_encoder(struct drm_connector *connector)
{
#if KERNEL_VERSION(5, 5, 0) <= LINUX_VERSION_CODE || defined(EL8)
	struct drm_encoder *encoder;

	drm_connector_for_each_possible_encoder(connector, encoder) {
		return encoder;
	}

	return NULL;
#else
	return drm_encoder_find(connector->dev,
				NULL,
				connector->encoder_ids[0]);
#endif
}

static struct drm_connector_helper_funcs msdisp_drm_connector_helper_funcs = {
	.get_modes = msdisp_drm_get_modes,
	.mode_valid = msdisp_drm_mode_valid,
	.best_encoder = msdisp_drm_best_encoder,
};

static const struct drm_connector_funcs msdisp_drm_connector_funcs = {
	.detect = msdisp_drm_detect,
	.fill_modes = drm_helper_probe_single_connector_modes,
	.destroy = msdisp_drm_connector_destroy,
	.reset = drm_atomic_helper_connector_reset,
	.atomic_duplicate_state = drm_atomic_helper_connector_duplicate_state,
	.atomic_destroy_state = drm_atomic_helper_connector_destroy_state
};

struct msdisp_drm_connector* msdisp_drm_connector_init(struct drm_device *dev, struct drm_encoder *encoder, int index)
{
	struct drm_connector *connector;
	struct msdisp_drm_connector* msdisp_conn;

	msdisp_conn = kzalloc(sizeof(struct msdisp_drm_connector), GFP_KERNEL);
	if (!msdisp_conn) {
		return NULL;
	}
		
	connector = &msdisp_conn->connector; 

	/* TODO: Initialize connector with actual connector type */
	drm_connector_init(dev, connector, &msdisp_drm_connector_funcs,
			   DRM_MODE_CONNECTOR_HDMIA);
	drm_connector_helper_add(connector, &msdisp_drm_connector_helper_funcs);
	connector->polled =  DRM_CONNECTOR_POLL_HPD |
		DRM_CONNECTOR_POLL_CONNECT | DRM_CONNECTOR_POLL_DISCONNECT;

#if KERNEL_VERSION(4, 19, 0) <= LINUX_VERSION_CODE  || defined(EL8)
	drm_connector_attach_encoder(connector, encoder);
#else
	drm_mode_connector_attach_encoder(connector, encoder);
#endif

	msdisp_conn->status = connector_status_unknown;
	msdisp_conn->pipeline_index = index;
	return msdisp_conn;
}
