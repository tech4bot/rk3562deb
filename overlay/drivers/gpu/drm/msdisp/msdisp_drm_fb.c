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
 * msdisp_drm_fb.c -- Drm driver for MacroSilicon chip 913x and 912x
 */


#include <linux/slab.h>
#include <linux/dma-buf.h>
#include <linux/vmalloc.h>
#include <linux/version.h>
#include <drm/drm_print.h>
#if KERNEL_VERSION(5, 5, 0) <= LINUX_VERSION_CODE || defined(EL8)
#else
#include <drm/drmP.h>
#endif
#include <drm/drm_crtc.h>
#include <drm/drm_crtc_helper.h>
#include <drm/drm_fb_helper.h>
#include <drm/drm_atomic.h>
#if KERNEL_VERSION(5, 0, 0) <= LINUX_VERSION_CODE || defined(EL8)
#include <drm/drm_damage_helper.h>
#endif

#include "msdisp_drm_drv.h"


#if KERNEL_VERSION(5, 0, 0) <= LINUX_VERSION_CODE || defined(EL8)
#else
static int msdisp_drm_user_framebuffer_dirty(
		struct drm_framebuffer *fb,
		__maybe_unused struct drm_file *file_priv,
		__always_unused unsigned int flags,
		__always_unused unsigned int color,
		__always_unused struct drm_clip_rect *clips,
		__always_unused unsigned int num_clips)
{
	struct drm_modeset_acquire_ctx ctx;
	struct drm_atomic_state *state;
	struct drm_plane *plane;
	int ret = 0;

	drm_modeset_acquire_init(&ctx,
		/*
		 * When called from ioctl, we are interruptable,
		 * but not when called internally (ie. defio worker)
		 */
		file_priv ? DRM_MODESET_ACQUIRE_INTERRUPTIBLE :	0);

	state = drm_atomic_state_alloc(fb->dev);
	if (!state) {
		ret = -ENOMEM;
		goto out;
	}
	state->acquire_ctx = &ctx;

retry:

	drm_for_each_plane(plane, fb->dev) {
		struct drm_plane_state *plane_state;

		if (plane->state->fb != fb)
			continue;

		/*
		 * Even if it says 'get state' this function will create and
		 * initialize state if it does not exists. We use this property
		 * to force create state.
		 */
		plane_state = drm_atomic_get_plane_state(state, plane);
		if (IS_ERR(plane_state)) {
			ret = PTR_ERR(plane_state);
			goto out;
		}
	}

	ret = drm_atomic_commit(state);

out:
	if (ret == -EDEADLK) {
		drm_atomic_state_clear(state);
		ret = drm_modeset_backoff(&ctx);
		if (!ret)
			goto retry;
	}

	if (state)
		drm_atomic_state_put(state);

	drm_modeset_drop_locks(&ctx);
	drm_modeset_acquire_fini(&ctx);

	return ret;
}
#endif

static int msdisp_drm_user_framebuffer_create_handle(struct drm_framebuffer *fb,
					       struct drm_file *file_priv,
					       unsigned int *handle)
{
	struct msdisp_drm_framebuffer *efb = to_msdisp_drm_fb(fb);

	return drm_gem_handle_create(file_priv, &efb->obj->base, handle);
}

static void msdisp_drm_user_framebuffer_destroy(struct drm_framebuffer *fb)
{
	struct msdisp_drm_framebuffer *efb = to_msdisp_drm_fb(fb);

	if (efb->obj)
#if KERNEL_VERSION(5, 9, 0) <= LINUX_VERSION_CODE || defined(EL8)
		drm_gem_object_put(&efb->obj->base);
#else
		drm_gem_object_put_unlocked(&efb->obj->base);
#endif
	drm_framebuffer_cleanup(fb);
	kfree(efb);
}

#if KERNEL_VERSION(5, 0, 0) <= LINUX_VERSION_CODE || defined(EL8)
static int msdisp_drm_atomic_helper_dirtyfb(struct drm_framebuffer *fb,
			      struct drm_file *file_priv, unsigned int flags,
			      unsigned int color, struct drm_clip_rect *clips,
			      unsigned int num_clips)
{
	return drm_atomic_helper_dirtyfb(fb, file_priv, flags, color, clips, num_clips);
}
#endif

static const struct drm_framebuffer_funcs msdisp_drmfb_funcs = {
	.create_handle = msdisp_drm_user_framebuffer_create_handle,
	.destroy = msdisp_drm_user_framebuffer_destroy,
#if KERNEL_VERSION(5, 0, 0) <= LINUX_VERSION_CODE || defined(EL8)
	.dirty = msdisp_drm_atomic_helper_dirtyfb,
#else
	.dirty = msdisp_drm_user_framebuffer_dirty,
#endif
};

static int
msdisp_drm_framebuffer_init(struct drm_device *dev,
		      struct msdisp_drm_framebuffer *efb,
#if KERNEL_VERSION(6, 15, 0) <= LINUX_VERSION_CODE
		      const struct drm_format_info *info,
#endif
		      const struct drm_mode_fb_cmd2 *mode_cmd,
		      struct msdisp_drm_gem_object *obj)
{
	efb->obj = obj;
#if KERNEL_VERSION(6, 15, 0) <= LINUX_VERSION_CODE
	/* fill_fb_struct takes the format info explicitly since 6.15 */
	drm_helper_mode_fill_fb_struct(dev, &efb->base, info, mode_cmd);
#else
	drm_helper_mode_fill_fb_struct(dev, &efb->base, mode_cmd);
#endif
	return drm_framebuffer_init(dev, &efb->base, &msdisp_drmfb_funcs);
}

int msdisp_drm_fb_get_bpp(uint32_t format)
{
	const struct drm_format_info *info = drm_format_info(format);

	if (!info)
		return 0;
	return info->cpp[0] * 8;
}

struct drm_framebuffer *msdisp_drm_fb_user_fb_create(
					struct drm_device *dev,
					struct drm_file *file,
#if KERNEL_VERSION(6, 15, 0) <= LINUX_VERSION_CODE
					const struct drm_format_info *info,
#endif
					const struct drm_mode_fb_cmd2 *mode_cmd)
{
	struct drm_gem_object *obj;
	struct msdisp_drm_framebuffer *efb;
	int ret;
	uint32_t size;
	int bpp = msdisp_drm_fb_get_bpp(mode_cmd->pixel_format);

	if (bpp != 32) {
		dev_err(dev->dev, "Unsupported bpp (%d)\n", bpp);
		return ERR_PTR(-EINVAL);
	}

	dev_dbg(dev->dev, "fb id:0x%x format:0x%x handle:0x%x width:%d height:%d pitch:%d\n",  \
		mode_cmd->fb_id, mode_cmd->pixel_format, mode_cmd->handles[0], mode_cmd->width, mode_cmd->height, mode_cmd->pitches[0]);

	obj = drm_gem_object_lookup(file, mode_cmd->handles[0]);
	if (obj == NULL)
		return ERR_PTR(-ENOENT);

	size = mode_cmd->offsets[0] + mode_cmd->pitches[0] * mode_cmd->height;
	size = ALIGN(size, PAGE_SIZE);

	if (size > obj->size) {
		dev_err(dev->dev, "object size not sufficient for fb %d %zu %u %d %d\n",
			  size, obj->size, mode_cmd->offsets[0],
			  mode_cmd->pitches[0], mode_cmd->height);
		goto err_no_mem;
	}

	efb = kzalloc(sizeof(*efb), GFP_KERNEL);
	if (efb == NULL)
		goto err_no_mem;
	efb->base.obj[0] = obj;

	ret = msdisp_drm_framebuffer_init(dev, efb,
#if KERNEL_VERSION(6, 15, 0) <= LINUX_VERSION_CODE
					  info,
#endif
					  mode_cmd, to_msdisp_drm_bo(obj));
	if (ret) {
		dev_err(dev->dev, "msdisp_drm_framebuffer_init failed: %d\n", ret);
		goto err_inval;
	}
	return &efb->base;

 err_no_mem:
	drm_gem_object_put(obj);
	return ERR_PTR(-ENOMEM);
 err_inval:
	kfree(efb);
	drm_gem_object_put(obj);
	return ERR_PTR(-EINVAL);
}

#if KERNEL_VERSION(6, 10, 0) <= LINUX_VERSION_CODE
/* drm_client_setup()/drm_fbdev_client_setup() (called from
 * msdisp_drm_device_create() in msdisp_drm_drv.c on 6.10+ kernels) requires
 * dev->driver->fbdev_probe to be set -- the vendor driver never implemented
 * this, so drm_fb_helper_single_fb_probe() fell through with an
 * uninitialized `ret`, leaving fb_helper->fb NULL, and then unconditionally
 * did strcpy(fb_helper->fb->comm, "[fbcon]"), a NULL deref. This is a
 * from-scratch implementation modeled on the upstream drm_fbdev_dma.c /
 * drm_fbdev_shmem.c "shadowed" fbdev_probe (those aren't usable directly:
 * msdisp's GEM objects aren't drm_gem_dma/shmem_helper objects, they're a
 * custom type -- see struct msdisp_drm_gem_object). Since our fb always has
 * ->funcs->dirty set (msdisp_drm_fb.c's msdisp_drmfb_funcs), we always take
 * the deferred/shadowed path: fbcon draws into a plain vzalloc'd shadow
 * buffer, and on damage we blit that into the real scanout buffer (vmapped
 * via the new gem_obj_funcs.vmap/.vunmap in msdisp_drm_gem.c) and invoke
 * fb->funcs->dirty() to push it out over USB. */

static int msdisp_fbdev_fb_open(struct fb_info *info, int user)
{
	struct drm_fb_helper *fb_helper = info->par;

	if (user && !try_module_get(fb_helper->dev->driver->fops->owner))
		return -ENODEV;

	return 0;
}

static int msdisp_fbdev_fb_release(struct fb_info *info, int user)
{
	struct drm_fb_helper *fb_helper = info->par;

	if (user)
		module_put(fb_helper->dev->driver->fops->owner);

	return 0;
}

static void msdisp_fbdev_fb_destroy(struct fb_info *info)
{
	struct drm_fb_helper *fb_helper = info->par;
	void *shadow = info->screen_buffer;

	if (!fb_helper->dev)
		return;

	if (info->fbdefio)
		fb_deferred_io_cleanup(info);
	drm_fb_helper_fini(fb_helper);
	vfree(shadow);

	drm_client_buffer_vunmap(fb_helper->buffer);
#if KERNEL_VERSION(6, 18, 0) <= LINUX_VERSION_CODE
	drm_client_buffer_delete(fb_helper->buffer);
	drm_client_release(&fb_helper->client);
#else
	drm_client_framebuffer_delete(fb_helper->buffer);
	drm_client_release(&fb_helper->client);
	drm_fb_helper_unprepare(fb_helper);
	kfree(fb_helper);
#endif
}

FB_GEN_DEFAULT_DEFERRED_SYSMEM_OPS(msdisp_fbdev,
				   drm_fb_helper_damage_range,
				   drm_fb_helper_damage_area);

static const struct fb_ops msdisp_fbdev_fb_ops = {
	.owner = THIS_MODULE,
	.fb_open = msdisp_fbdev_fb_open,
	.fb_release = msdisp_fbdev_fb_release,
	FB_DEFAULT_DEFERRED_OPS(msdisp_fbdev),
	DRM_FB_HELPER_DEFAULT_OPS,
	.fb_destroy = msdisp_fbdev_fb_destroy,
};

static int msdisp_fbdev_helper_fb_dirty(struct drm_fb_helper *fb_helper,
					struct drm_clip_rect *clip)
{
	struct drm_device *dev = fb_helper->dev;
	struct drm_framebuffer *fb = fb_helper->fb;
	struct iosys_map dst = fb_helper->buffer->map;
	size_t offset;
	size_t len;
	unsigned int y;
	void *src;
	int ret;

	if (!(clip->x1 < clip->x2 && clip->y1 < clip->y2))
		return 0;

	offset = clip->y1 * fb->pitches[0] + clip->x1 * fb->format->cpp[0];
	len = (clip->x2 - clip->x1) * fb->format->cpp[0];
	src = fb_helper->info->screen_buffer + offset;
	iosys_map_incr(&dst, offset);

	for (y = clip->y1; y < clip->y2; y++) {
		iosys_map_memcpy_to(&dst, 0, src, len);
		iosys_map_incr(&dst, fb->pitches[0]);
		src += fb->pitches[0];
	}

	if (fb->funcs->dirty) {
		ret = fb->funcs->dirty(fb, NULL, 0, 0, clip, 1);
		if (drm_WARN_ONCE(dev, ret, "msdisp fbdev: dirty helper failed: ret=%d\n", ret))
			return ret;
	}

	return 0;
}

static const struct drm_fb_helper_funcs msdisp_fbdev_helper_funcs = {
	.fb_dirty = msdisp_fbdev_helper_fb_dirty,
};

int msdisp_drm_fbdev_probe(struct drm_fb_helper *fb_helper,
			   struct drm_fb_helper_surface_size *sizes)
{
	struct drm_client_dev *client = &fb_helper->client;
	struct drm_device *dev = fb_helper->dev;
	struct drm_client_buffer *buffer;
	struct drm_framebuffer *fb;
	struct fb_info *info;
	struct iosys_map map;
	void *shadow;
	size_t screen_size;
	u32 format;
	int ret;

	drm_dbg_kms(dev, "surface width(%d), height(%d) and bpp(%d)\n",
		    sizes->surface_width, sizes->surface_height,
		    sizes->surface_bpp);

	format = drm_driver_legacy_fb_format(dev, sizes->surface_bpp, sizes->surface_depth);
#if KERNEL_VERSION(6, 18, 0) <= LINUX_VERSION_CODE
	buffer = drm_client_buffer_create_dumb(client, sizes->surface_width,
					       sizes->surface_height, format);
#else
	buffer = drm_client_framebuffer_create(client, sizes->surface_width,
					       sizes->surface_height, format);
#endif
	if (IS_ERR(buffer))
		return PTR_ERR(buffer);

	fb = buffer->fb;

	ret = drm_client_buffer_vmap(buffer, &map);
	if (ret)
		goto err_drm_client_buffer_delete;
	if (drm_WARN_ON(dev, map.is_iomem)) {
		ret = -ENODEV;
		goto err_drm_client_buffer_vunmap;
	}

	fb_helper->funcs = &msdisp_fbdev_helper_funcs;
	fb_helper->buffer = buffer;
	fb_helper->fb = fb;

#if KERNEL_VERSION(6, 12, 0) <= LINUX_VERSION_CODE
	/* Upstream commit 63c971af4036 ("drm/fb-helper: Allocate and release
	 * fb_info in single place", merged in 6.13 and backported to 6.12.y /
	 * Debian 13) moved drm_fb_helper_alloc_info() and release_info() into
	 * drm_fb_helper_single_fb_probe(), pre-populating fb_helper->info. */
	info = fb_helper->info;
#else
	info = drm_fb_helper_alloc_info(fb_helper);
	if (IS_ERR(info)) {
		ret = PTR_ERR(info);
		goto err_drm_client_buffer_vunmap;
	}
#endif

	drm_fb_helper_fill_info(info, fb_helper, sizes);

	screen_size = buffer->gem->size;
	shadow = vzalloc(screen_size);
	if (!shadow) {
		ret = -ENOMEM;
		goto err_drm_fb_helper_release_info;
	}

	info->fbops = &msdisp_fbdev_fb_ops;
	info->flags |= FBINFO_VIRTFB | FBINFO_READS_FAST;
	info->screen_buffer = shadow;
	info->fix.smem_len = screen_size;

	fb_helper->fbdefio.delay = HZ / 20;
	fb_helper->fbdefio.deferred_io = drm_fb_helper_deferred_io;
	info->fbdefio = &fb_helper->fbdefio;

	ret = fb_deferred_io_init(info);
	if (ret)
		goto err_vfree;

	return 0;

err_vfree:
	vfree(shadow);
err_drm_fb_helper_release_info:
#if KERNEL_VERSION(6, 12, 0) > LINUX_VERSION_CODE
	drm_fb_helper_release_info(fb_helper);
#endif
err_drm_client_buffer_vunmap:
	fb_helper->fb = NULL;
	fb_helper->buffer = NULL;
	drm_client_buffer_vunmap(buffer);
err_drm_client_buffer_delete:
#if KERNEL_VERSION(6, 18, 0) <= LINUX_VERSION_CODE
	drm_client_buffer_delete(buffer);
#else
	drm_client_framebuffer_delete(buffer);
#endif
	return ret;
}
#endif
