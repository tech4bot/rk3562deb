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
 * msdisp_drm_modeset.c -- Drm driver for MacroSilicon chip 913x and 912x
 */


#include <linux/version.h>
#include <linux/vmalloc.h>
#if KERNEL_VERSION(5, 16, 0) <= LINUX_VERSION_CODE
#include <drm/drm_vblank.h>
#include <drm/drm_damage_helper.h>
#elif KERNEL_VERSION(5, 0, 0) <= LINUX_VERSION_CODE || defined(EL8)
#include <drm/drm_damage_helper.h>
#else
#include <drm/drmP.h>
#endif
#include <drm/drm_atomic.h>
#include <drm/drm_crtc.h>
#include <drm/drm_crtc_helper.h>
#include <drm/drm_plane_helper.h>
#include <drm/drm_atomic_helper.h>
#if KERNEL_VERSION(5, 13, 0) <= LINUX_VERSION_CODE
#include <drm/drm_gem_atomic_helper.h>
#else
#include <drm/drm_gem_framebuffer_helper.h>
#endif

#include <linux/dma-buf.h>
#include <linux/moduleparam.h>

#include "msdisp_drm_drv.h"

static bool msdisp_hw_cursor = true;
module_param_named(hw_cursor, msdisp_hw_cursor, bool, 0644);
MODULE_PARM_DESC(hw_cursor, "Enable hardware cursor plane (default: true)");
#include "msdisp_drm_event.h"
#include "msdisp_common_util.h"
#include "msdisp_usb_interface.h"
#include <drm/drm_fourcc.h>
#include <drm/drm_cache.h>


static struct msdisp_drm_pipeline* get_pipeline_by_plane(struct drm_plane* plane)
{
	struct msdisp_drm_device *msdisp_drm = to_msdisp_drm(plane->dev);
	struct msdisp_drm_pipeline* pipeline = NULL;
	int i;

	for (i = 0; i < msdisp_drm->pipeline_cnt; i++) {
		if (!msdisp_drm->pipeline[i].crtc)
			continue;
		if (msdisp_drm->pipeline[i].crtc->primary == plane ||
		    msdisp_drm->pipeline[i].crtc->cursor == plane) {
			pipeline = &msdisp_drm->pipeline[i];
			break;
		}
	}

	return pipeline;
}

static struct msdisp_drm_pipeline* get_pipeline_by_crtc(struct drm_crtc* crtc)
{
	struct msdisp_drm_device *msdisp_drm = to_msdisp_drm(crtc->dev);
	struct msdisp_drm_pipeline* pipeline = NULL;
	int i;

	for (i = 0; i < msdisp_drm->pipeline_cnt; i++) {
		if (msdisp_drm->pipeline[i].crtc == crtc) {
			pipeline = &msdisp_drm->pipeline[i];
			break;
		}
	}

	return pipeline;
}

void msdisp_crtc_update_event(struct drm_crtc *crtc)
{
	struct drm_device* dev = crtc->dev;
	struct msdisp_drm_pipeline* pipeline = get_pipeline_by_crtc(crtc);

	if (crtc->state->event) {
		unsigned long flags;

		crtc->state->event->pipe = drm_crtc_index(crtc);
		spin_lock_irqsave(&dev->event_lock, flags);
		if (pipeline->event) {
			drm_crtc_send_vblank_event(crtc, pipeline->event);
			pipeline->event = NULL;
		}
		drm_crtc_send_vblank_event(crtc, crtc->state->event);
		crtc->state->event = NULL;
		spin_unlock_irqrestore(&dev->event_lock, flags);
	}
}


static void msdisp_drm_crtc_destroy(struct drm_crtc *crtc)
{
	drm_crtc_cleanup(crtc);
	kfree(crtc);
}

void msdisp_drm_crtc_atomic_flush(struct drm_crtc *crtc, 
#if KERNEL_VERSION(5, 11, 0) <= LINUX_VERSION_CODE || defined(RPI) || defined(EL8)
	struct drm_atomic_state *state
#else
	struct drm_crtc_state *old_state
#endif
)
{
	if (crtc->state->active){
		msdisp_crtc_update_event(crtc);
	}
}

int msdisp_drm_crtc_atomic_check(struct drm_crtc *crtc, 
#if KERNEL_VERSION(5, 11, 0) <= LINUX_VERSION_CODE || defined(RPI) || defined(EL8)
	struct drm_atomic_state *state
#else
	struct drm_crtc_state *new_state
#endif
)
{
#if KERNEL_VERSION(5, 11, 0) <= LINUX_VERSION_CODE || defined(RPI) || defined(EL8)
	struct drm_crtc_state *crtc_state = drm_atomic_get_new_crtc_state(state, crtc);
#else
	struct drm_crtc_state *crtc_state = new_state;
#endif

	bool has_primary = (crtc_state->plane_mask & drm_plane_mask(crtc->primary));

	/* We always want to have an active plane with an active CRTC */
	if (has_primary != crtc_state->enable)
		return -EINVAL;

#if KERNEL_VERSION(4, 18, 0) <= LINUX_VERSION_CODE
	/* Tell DRM atomic helpers that this virtual USB display lacks hardware
	 * rasterizer vblank interrupts. This prevents drm_atomic_helper_commit_tail()
	 * from blocking synchronously in drm_atomic_helper_wait_for_vblanks(),
	 * eliminating compositor stalls and multi-monitor freezes in Wayland. */
	crtc_state->no_vblank = true;
#endif

	return drm_atomic_add_affected_planes(crtc_state->state, crtc);
}

void msdisp_drm_crtc_atomic_enable(struct drm_crtc *crtc, 
#if KERNEL_VERSION(5, 11, 0) <= LINUX_VERSION_CODE || defined(RPI) || defined(EL8)
	struct drm_atomic_state *state
#else
	struct drm_crtc_state *old_crtc_state
#endif
)
{
	struct drm_device *dev = crtc->dev;
	struct drm_plane *primary_plane = crtc->primary;
	struct drm_plane_state *plane_state = primary_plane->state;
	struct drm_framebuffer *fb = plane_state->fb;
	struct drm_crtc_state *crtc_state = crtc->state;
	struct drm_display_mode *mode = &crtc_state->mode;
	struct msdisp_drm_pipeline* pipeline;
	struct msdisp_usb_hal* usb_hal;
    int width, height, rate;

	drm_crtc_vblank_on(crtc);
	msdisp_crtc_update_event(crtc);

    dev_info(dev->dev, "enable: pid=%d comm=%s\n", task_pid_nr(current), current->comm);
	dev_info(dev->dev, "fb size:width:%d height:%d mode size:width:%d height:%d\n", fb->width, fb->height, mode->hdisplay, mode->vdisplay);
	pipeline = get_pipeline_by_crtc(crtc);
	mutex_lock(&pipeline->hal_lock);
	usb_hal = pipeline->usb_hal;
	if (!usb_hal) {
		dev_info(dev->dev, "usb hal is null\n");
		goto out;
	}

    width = mode->hdisplay;
    height = mode->vdisplay;
	rate = drm_mode_vrefresh(mode);

	pipeline->drm_width = width;
	pipeline->drm_height = height;
	pipeline->drm_rate = rate;
	pipeline->drm_fb_format = fb->format->format;
	pipeline->drm_status = MSDISP_DRM_STATUS_ENABLE;

    usb_hal->funcs->enable(usb_hal, width, height, rate, fb->format->format);
    dev_info(dev->dev, "enable event:format=0x%x width=%d height=%d rate=%d\n", fb->format->format, width, height, rate);
out:
	mutex_unlock(&pipeline->hal_lock);
}

void msdisp_drm_crtc_atomic_disable(struct drm_crtc *crtc, 
#if KERNEL_VERSION(5, 11, 0) <= LINUX_VERSION_CODE || defined(RPI) || defined(EL8)
	struct drm_atomic_state *state
#else
	struct drm_crtc_state *old_crtc_state
#endif
)
{
	struct drm_device *dev = crtc->dev;
	struct msdisp_drm_pipeline* pipeline;
	struct msdisp_usb_hal* usb_hal;

	
	drm_crtc_vblank_off(crtc);
	if (crtc->state->event) {
		unsigned long flags;

		spin_lock_irqsave(&dev->event_lock, flags);
		drm_crtc_send_vblank_event(crtc, crtc->state->event);
		crtc->state->event = NULL;
		spin_unlock_irqrestore(&dev->event_lock, flags);
	}
	pipeline = get_pipeline_by_crtc(crtc);
	pipeline->drm_status = MSDISP_DRM_STATUS_DISABLE;
    dev_info(dev->dev, "disable: pid=%d! comm=%s\n", task_pid_nr(current), current->comm);
	mutex_lock(&pipeline->hal_lock);
	usb_hal = pipeline->usb_hal;

	if (!usb_hal) {
		dev_info(dev->dev, "usb hal is null\n");
		goto out;
	}

    usb_hal->funcs->disable(usb_hal);
out:
	mutex_unlock(&pipeline->hal_lock);
}

static struct drm_crtc_helper_funcs msdisp_drm_helper_funcs = {
	.atomic_check = msdisp_drm_crtc_atomic_check,
	.atomic_enable = msdisp_drm_crtc_atomic_enable,
	.atomic_disable = msdisp_drm_crtc_atomic_disable,
	.atomic_flush = msdisp_drm_crtc_atomic_flush,
};

#if KERNEL_VERSION(5, 11, 0) <= LINUX_VERSION_CODE || defined(RPI) || defined(EL8)
static int msdisp_drm_enable_vblank(struct drm_crtc *crtc)
{
	return 0;
}

static void msdisp_drm_disable_vblank(struct drm_crtc *crtc)
{

}
#endif


static const struct drm_crtc_funcs msdisp_drm_crtc_funcs = {
	.reset                  = drm_atomic_helper_crtc_reset,
	.destroy                = msdisp_drm_crtc_destroy,
	.set_config             = drm_atomic_helper_set_config,
	.atomic_duplicate_state = drm_atomic_helper_crtc_duplicate_state,
	.atomic_destroy_state   = drm_atomic_helper_crtc_destroy_state,
#if KERNEL_VERSION(5, 11, 0) <= LINUX_VERSION_CODE || defined(RPI) || defined(EL8)
	.enable_vblank          = msdisp_drm_enable_vblank,
	.disable_vblank         = msdisp_drm_disable_vblank,
#endif
};

static int msdisp_drm_handle_damage(struct msdisp_drm_framebuffer *efb, struct msdisp_drm_pipeline *pipeline)
{
	struct drm_framebuffer* fb = &efb->base;
	struct msdisp_usb_hal* usb_hal = pipeline->usb_hal;
	u8* src;
	int len;

	src = (u8*)(efb->obj->vmapping);
	len = fb->pitches[0] * fb->height;

	return usb_hal->funcs->update_frame(usb_hal, src, fb->pitches[0], len, fb->format->format, 0);
}

static void msdisp_drm_plane_atomic_update(struct drm_plane *plane,
#if KERNEL_VERSION(5, 13, 0) <= LINUX_VERSION_CODE
				     struct drm_atomic_state *atom_state
#else
				     struct drm_plane_state *old_state
#endif
		)
{
#if KERNEL_VERSION(5, 13, 0) <= LINUX_VERSION_CODE
	struct drm_plane_state *old_state = drm_atomic_get_old_plane_state(atom_state, plane);
#else
#endif
	struct drm_device* dev;
	struct msdisp_usb_hal* usb_hal;
	struct drm_framebuffer *fb;
	struct msdisp_drm_framebuffer *efb;
	struct dma_buf_attachment *import_attach;
	struct msdisp_drm_frame_stat* stat;
	struct msdisp_drm_pipeline* pipeline;
	int ret, lock_flag = 0;

	if (!plane || !plane->state || !plane->dev) {
		return;
	}

	dev = plane->dev;

	pipeline = get_pipeline_by_plane(plane);
	stat = &pipeline->frame_stat;
	stat->total++;

	if (!old_state) {
		stat->no_old_state++;
		return;
	}

	/* Use the newly committed framebuffer from plane->state->fb, NOT
	 * old_state->fb. Using old_state caused every screen update to be
	 * 1 frame behind (input lag / delayed typing) and broke initial frame
	 * display on resume/modeset when old_state->fb was NULL. */
	fb = plane->state->fb;
	if (!fb) {
		stat->no_fb++;
		return;
	}

	efb = to_msdisp_drm_fb(fb);

	drm_framebuffer_get(&efb->base);

	if (!efb->obj->vmapping) {
		if (msdisp_drm_gem_vmap(efb->obj) == -ENOMEM) {
			dev_err(dev->dev, "Failed to map scanout buffer\n");
			stat->vmap_fail++;
			goto err_fb;
		}
		if (!efb->obj->vmapping) {
			dev_err(dev->dev, "Vmapping does not exists!\n");
			stat->vmap_null++;
			goto err_fb;
		}
	}

	import_attach = efb->obj->base.import_attach;
	if (import_attach) {
		ret = dma_buf_begin_cpu_access(import_attach->dmabuf,
					       DMA_FROM_DEVICE);
		if (ret) {
			dev_err(dev->dev, "dma_buf begin cpu access failed! ret=%d!\n", ret);
			stat->cpu_access_fail++;
			goto err_fb;
		}
	}

	/* When the buffer is mapped through our own page array rather than the
	 * exporter's .vmap, the exporter's begin_cpu_access() cannot invalidate a
	 * mapping it does not know about, so nothing invalidates our cache lines
	 * before we read the GPU's writes. Without this the image is stale but
	 * self-consistent: correct while static, torn during motion. */
	if (import_attach && efb->obj->pages) {
		drm_clflush_pages(efb->obj->pages,
				  DIV_ROUND_UP(efb->obj->base.size, PAGE_SIZE));
	}

	if (pipeline->dump_fb_flag) {
        msdisp_common_save_buf_to_bmp(efb->obj->vmapping, fb->width, fb->height, fb->format->cpp[0], NULL, pipeline->dump_fb_filename);
        pipeline->dump_fb_flag = 0;
        dev_info(dev->dev, "msdisp finished save raw fb data to file:%s\n", pipeline->dump_fb_filename);
    }

	mutex_lock(&pipeline->hal_lock);
	lock_flag = 1;
	usb_hal = pipeline->usb_hal;
	if (!pipeline->usb_hal) {
		stat->no_usb_hal++;
		goto end_cpu_access;
	}

	if (msdisp_drm_handle_damage(efb, pipeline)) {
		stat->handle_fail++;
	}

end_cpu_access:
	if (import_attach)
		dma_buf_end_cpu_access(import_attach->dmabuf,
				       DMA_FROM_DEVICE);

err_fb:
	drm_framebuffer_put(&efb->base);

	if (lock_flag) {
		mutex_unlock(&pipeline->hal_lock);
	}
}

static const struct drm_plane_helper_funcs msdisp_drm_plane_helper_funcs = {
	.atomic_update = msdisp_drm_plane_atomic_update,
#if KERNEL_VERSION(5, 13, 0) <= LINUX_VERSION_CODE
	.prepare_fb = drm_gem_plane_helper_prepare_fb
#else
	.prepare_fb = drm_gem_fb_prepare_fb
#endif
};

static int msdisp_drm_cursor_plane_atomic_check(struct drm_plane *plane,
#if KERNEL_VERSION(5, 13, 0) <= LINUX_VERSION_CODE
						struct drm_atomic_state *state
#else
						struct drm_plane_state *new_plane_state
#endif
)
{
#if KERNEL_VERSION(5, 13, 0) <= LINUX_VERSION_CODE
	struct drm_plane_state *new_plane_state = drm_atomic_get_new_plane_state(state, plane);
#else
	struct drm_atomic_state *state = new_plane_state->state;
#endif
	struct drm_crtc_state *crtc_state;

	if (!new_plane_state->fb)
		return 0;

	if (!new_plane_state->crtc)
		return 0;

	if (new_plane_state->fb->width > 64 || new_plane_state->fb->height > 64)
		return -EINVAL;

	crtc_state = drm_atomic_get_crtc_state(state, new_plane_state->crtc);
	if (IS_ERR(crtc_state))
		return PTR_ERR(crtc_state);

	return drm_atomic_helper_check_plane_state(new_plane_state, crtc_state,
						   DRM_PLANE_NO_SCALING,
						   DRM_PLANE_NO_SCALING,
						   true, true);
}

static void msdisp_drm_cursor_plane_atomic_update(struct drm_plane *plane,
#if KERNEL_VERSION(5, 13, 0) <= LINUX_VERSION_CODE
				     struct drm_atomic_state *state
#else
				     struct drm_plane_state *old_state
#endif
)
{
	struct drm_plane_state *new_state = plane->state;
	struct msdisp_drm_pipeline *pipeline;
	struct msdisp_usb_hal *usb_hal;
	struct drm_framebuffer *fb;
	struct msdisp_drm_framebuffer *efb;
	struct dma_buf_attachment *import_attach;
	void *vmapping;
	u8 *cursor_buf = NULL;
	int y, width, height;

	if (!plane || !new_state)
		return;

	if (new_state->crtc)
		pipeline = get_pipeline_by_crtc(new_state->crtc);
	else
		pipeline = get_pipeline_by_plane(plane);
	if (!pipeline)
		return;

	usb_hal = pipeline->usb_hal;
	if (!usb_hal)
		return;

	fb = new_state->fb;
	if (!fb || !new_state->visible) {
		usb_hal->funcs->cursor_set(usb_hal, NULL);
		return;
	}

	/* Always refresh the 64x64 cursor bitmap when the cursor plane is
	 * updated. Some compositors render cursor icon changes in-place into
	 * an existing BO without changing the drm_framebuffer pointer, and
	 * refreshing the 16 KB buffer ensures the cursor image is never stale
	 * or lost after modeset. */
	efb = to_msdisp_drm_fb(fb);
	if (efb && efb->obj) {
		drm_framebuffer_get(&efb->base);

		if (!efb->obj->vmapping) {
			if (msdisp_drm_gem_vmap(efb->obj)) {
				drm_framebuffer_put(&efb->base);
				goto move_cursor;
			}
		}

		vmapping = efb->obj->vmapping;
		if (!vmapping) {
			drm_framebuffer_put(&efb->base);
			goto move_cursor;
		}

		import_attach = efb->obj->base.import_attach;
		if (import_attach)
			dma_buf_begin_cpu_access(import_attach->dmabuf, DMA_FROM_DEVICE);

		if (import_attach && efb->obj->pages)
			drm_clflush_pages(efb->obj->pages, DIV_ROUND_UP(efb->obj->base.size, PAGE_SIZE));

		width = fb->width;
		height = fb->height;

		if (width <= 64 && height <= 64) {
			if (width == 64 && height == 64 && fb->pitches[0] == 64 * 4) {
				usb_hal->funcs->cursor_set(usb_hal, (u8 *)vmapping);
			} else {
				cursor_buf = kzalloc(64 * 64 * 4, GFP_KERNEL);
				if (cursor_buf) {
					for (y = 0; y < height; y++) {
						memcpy(cursor_buf + y * 64 * 4,
						       (u8 *)vmapping + y * fb->pitches[0],
						       width * 4);
					}
					usb_hal->funcs->cursor_set(usb_hal, cursor_buf);
					kfree(cursor_buf);
				}
			}
		}

		if (import_attach)
			dma_buf_end_cpu_access(import_attach->dmabuf, DMA_FROM_DEVICE);

		drm_framebuffer_put(&efb->base);
	}

move_cursor:
	usb_hal->funcs->cursor_move(usb_hal, new_state->crtc_x, new_state->crtc_y);
}

static void msdisp_drm_cursor_plane_atomic_disable(struct drm_plane *plane,
#if KERNEL_VERSION(5, 13, 0) <= LINUX_VERSION_CODE
				      struct drm_atomic_state *state
#else
				      struct drm_plane_state *old_state
#endif
)
{
	struct msdisp_drm_pipeline *pipeline;
	struct msdisp_usb_hal *usb_hal;

	if (!plane)
		return;

	pipeline = get_pipeline_by_plane(plane);
	if (!pipeline)
		return;

	usb_hal = pipeline->usb_hal;
	if (!usb_hal)
		return;

	usb_hal->funcs->cursor_set(usb_hal, NULL);
}

static const struct drm_plane_helper_funcs msdisp_drm_cursor_plane_helper_funcs = {
	.atomic_check = msdisp_drm_cursor_plane_atomic_check,
	.atomic_update = msdisp_drm_cursor_plane_atomic_update,
	.atomic_disable = msdisp_drm_cursor_plane_atomic_disable,
#if KERNEL_VERSION(5, 13, 0) <= LINUX_VERSION_CODE
	.prepare_fb = drm_gem_plane_helper_prepare_fb,
#else
	.prepare_fb = drm_gem_fb_prepare_fb,
#endif
};

static const struct drm_plane_funcs msdisp_drm_plane_funcs = {
	.update_plane = drm_atomic_helper_update_plane,
	.disable_plane = drm_atomic_helper_disable_plane,
	.destroy = drm_plane_cleanup,
	.reset = drm_atomic_helper_plane_reset,
	.atomic_duplicate_state = drm_atomic_helper_plane_duplicate_state,
	.atomic_destroy_state = drm_atomic_helper_plane_destroy_state,
};

static const uint32_t formats[] = {
	DRM_FORMAT_XRGB8888,
	DRM_FORMAT_ARGB8888,
};

static const uint64_t format_modifiers[] = {
	DRM_FORMAT_MOD_LINEAR,
	DRM_FORMAT_MOD_INVALID
};

static struct drm_plane *msdisp_drm_create_plane(
		struct drm_device *dev,
		uint32_t possible_crtcs,
		enum drm_plane_type type,
		const struct drm_plane_helper_funcs *helper_funcs)
{
	struct drm_plane *plane;
	int ret;
	char *plane_type = (type == DRM_PLANE_TYPE_CURSOR) ? "cursor" : "primary";

	plane = kzalloc(sizeof(*plane), GFP_KERNEL);
	if (plane == NULL) {
		dev_err(dev->dev, "Failed to allocate %s plane\n", plane_type);
		return NULL;
	}
	plane->format_default = true;

	ret = drm_universal_plane_init(dev,
				       plane,
				       possible_crtcs,
				       &msdisp_drm_plane_funcs,
				       formats,
				       ARRAY_SIZE(formats),
				       format_modifiers,
				       type,
				       plane_type
				       );

	if (ret) {
		dev_err(dev->dev, "Failed to initialize %s plane\n", plane_type);
		kfree(plane);
		return NULL;
	}

	drm_plane_helper_add(plane, helper_funcs);

	return plane;
}

static struct drm_crtc* msdisp_drm_crtc_init(struct drm_device *dev, int pipe_idx)
{
	struct drm_crtc* crtc = NULL;
	struct drm_plane *primary_plane = NULL;
	struct drm_plane *cursor_plane = NULL;
	int status = 0;
	uint32_t possible_crtcs = (1 << pipe_idx);

	crtc = kzalloc(sizeof(struct drm_crtc), GFP_KERNEL);
	if (!crtc) {
		return NULL;
	}

	primary_plane = msdisp_drm_create_plane(dev, possible_crtcs, DRM_PLANE_TYPE_PRIMARY,
					  &msdisp_drm_plane_helper_funcs);

	if (!primary_plane) {
		kfree(crtc);
		return NULL;
	}

#if KERNEL_VERSION(5, 0, 0) <= LINUX_VERSION_CODE || defined(EL8)
	drm_plane_enable_fb_damage_clips(primary_plane);
#endif

	if (msdisp_hw_cursor) {
		cursor_plane = msdisp_drm_create_plane(dev, possible_crtcs, DRM_PLANE_TYPE_CURSOR,
						 &msdisp_drm_cursor_plane_helper_funcs);
		if (!cursor_plane) {
			dev_warn(dev->dev, "Failed to create cursor plane\n");
		}
	}

	status = drm_crtc_init_with_planes(dev, crtc,
				primary_plane, cursor_plane,
				&msdisp_drm_crtc_funcs,
				NULL
				);

	if (status) {
		dev_err(dev->dev, "Failed to init crtc with planes: %d\n", status);
		drm_plane_cleanup(primary_plane);
		kfree(primary_plane);
		if (cursor_plane) {
			drm_plane_cleanup(cursor_plane);
			kfree(cursor_plane);
		}
		kfree(crtc);
		return NULL;
	}

	drm_crtc_helper_add(crtc, &msdisp_drm_helper_funcs);

	return crtc;
}

static const struct drm_mode_config_funcs msdisp_drm_mode_funcs = {
	.fb_create = msdisp_drm_fb_user_fb_create,
	.atomic_commit = drm_atomic_helper_commit,
	.atomic_check = drm_atomic_helper_check
};

int msdisp_drm_modeset_init(struct drm_device *dev)
{
	struct msdisp_drm_device *msdisp_drm = to_msdisp_drm(dev);
	struct drm_crtc* crtc;
	struct msdisp_drm_connector *connector;
    struct drm_encoder *encoder;
	int i, pipeline_cnt;

	drm_mode_config_init(dev);

	dev->mode_config.min_width = 0;
	dev->mode_config.min_height = 0;
	dev->mode_config.max_width = 1920;
	dev->mode_config.max_height = 1600;
	if (msdisp_hw_cursor) {
		dev->mode_config.cursor_width = 64;
		dev->mode_config.cursor_height = 64;
	} else {
		dev->mode_config.cursor_width = 0;
		dev->mode_config.cursor_height = 0;
	}
	dev->mode_config.prefer_shadow = 0;
	dev->mode_config.preferred_depth = 32;
	//dev->mode_config.preferred_depth = 16;

	dev->mode_config.funcs = &msdisp_drm_mode_funcs;

	pipeline_cnt = msdisp_drm_get_pipeline_init_count();
	for (i = 0; i < pipeline_cnt; i++) {
		crtc = msdisp_drm_crtc_init(dev, i);
		if (!crtc) {
			dev_err(dev->dev, "Failed to init crtc%d\n", i);
			goto err;
		}

		encoder = msdisp_drm_encoder_init(dev);
		if (!encoder) {
			dev_err(dev->dev, "Failed to init encoder%d\n", i);
			goto err;
		}
		encoder->possible_crtcs = (1 << i);

		connector = msdisp_drm_connector_init(dev, encoder, i);
		if (!connector) {
			dev_err(dev->dev, "Failed to init connector%d\n", i);
			goto err;
		}
		

		msdisp_drm->pipeline[i].crtc = crtc;
		msdisp_drm->pipeline[i].encoder = encoder;
		msdisp_drm->pipeline[i].connector = connector;

		continue;
err:
		if (crtc) {
			kfree(crtc);
		}

		if (encoder) {
			kfree(encoder);
		}

		if (connector) {
			kfree(connector);
		}

		return -ENOMEM;
	}
	drm_mode_config_reset(dev);

	return 0;
}
