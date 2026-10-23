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
 * msdisp_drm_drv.c -- Drm driver for MacroSilicon chip 913x and 912x
 */

#include <linux/version.h>
#include <linux/jiffies.h>
#include <linux/spinlock.h>
#if KERNEL_VERSION(5, 16, 0) <= LINUX_VERSION_CODE
#include <drm/drm_ioctl.h>
#include <drm/drm_file.h>
#include <drm/drm_drv.h>
#include <drm/drm_vblank.h>
#elif KERNEL_VERSION(5, 5, 0) <= LINUX_VERSION_CODE || defined(EL8)
#else
#include <drm/drmP.h>
#endif
#if KERNEL_VERSION(5, 1, 0) <= LINUX_VERSION_CODE || defined(EL8)
#include <drm/drm_probe_helper.h>
#endif
#if KERNEL_VERSION(5, 8, 0) <= LINUX_VERSION_CODE
#include <drm/drm_managed.h>
#endif
#include <drm/drm_atomic_helper.h>
#if KERNEL_VERSION(6, 10, 0) <= LINUX_VERSION_CODE
#if __has_include(<drm/clients/drm_client_setup.h>)
#include <drm/clients/drm_client_setup.h>
#elif __has_include(<drm/drm_client_setup.h>)
#include <drm/drm_client_setup.h>
#endif
#elif __has_include(<drm/drm_fbdev_generic.h>)
#include <drm/drm_fbdev_generic.h>
#else
#include <drm/drm_fb_helper.h>
#endif


#include "msdisp_drm_drv.h"
#include "msdisp_plat_drv.h"

static ushort msdisp_drm_vblank_timer_ms = 16;
module_param_named(vblank_timer_ms, msdisp_drm_vblank_timer_ms, ushort, 0644);
MODULE_PARM_DESC(vblank_timer_ms, "Software vblank/frame-completion timer interval in ms (default: 16)");

static ushort msdisp_drm_initial_pipeline_count = 3;
module_param_named(initial_pipeline_count,
		   msdisp_drm_initial_pipeline_count, ushort, 0644);
MODULE_PARM_DESC(initial_pipeline_count, "Initial DRM device pipeline counts (default: 3)");

int msdisp_drm_get_pipeline_init_count(void)
{
	return msdisp_drm_initial_pipeline_count;
}


void msdisp_drm_sysfs_init(struct msdisp_drm_device * msdisp_drm);
void msdisp_drm_sysfs_exit(struct msdisp_drm_device * msdisp_drm);

#if KERNEL_VERSION(5, 11, 0) <= LINUX_VERSION_CODE || defined(EL8)
#else
static const struct vm_operations_struct msdisp_drm_gem_vm_ops = {
	.fault = msdisp_drm_gem_fault,
	.open = drm_gem_vm_open,
	.close = drm_gem_vm_close,
};
#endif

static const struct file_operations msdisp_drm_driver_fops = {
	.owner = THIS_MODULE,
	.open = drm_open,
	.mmap = msdisp_drm_gem_mmap,
	.poll = drm_poll,
	.read = drm_read,
	.unlocked_ioctl = drm_ioctl,
	.release = drm_release,
	.llseek = noop_llseek,
#if KERNEL_VERSION(6, 12, 0) <= LINUX_VERSION_CODE
	/* drm_open_helper() rechaza con -EINVAL cualquier open() de fops
	 * sin esta bandera desde 6.12; sin ella Mutter no puede abrir el card.
	 */
	.fop_flags = FOP_UNSIGNED_OFFSET,
#endif
};

#if KERNEL_VERSION(5, 11, 0) <= LINUX_VERSION_CODE || defined(EL8)
#else
static int msdisp_drm_enable_vblank(struct drm_device *dev, unsigned int pipe)
{
	return 0;
}

static void msdisp_drm_disable_vblank(struct drm_device *dev, unsigned int pipe)
{

}
#endif

static struct drm_driver driver = {
#if KERNEL_VERSION(5, 4, 0) <= LINUX_VERSION_CODE || defined(EL8)
	.driver_features = DRIVER_MODESET | DRIVER_GEM | DRIVER_ATOMIC,
#else
	.driver_features = DRIVER_MODESET | DRIVER_GEM | DRIVER_PRIME
			 | DRIVER_ATOMIC,
#endif

	/* gem hooks */
#if KERNEL_VERSION(5, 11, 0) <= LINUX_VERSION_CODE || defined(EL8)
#elif KERNEL_VERSION(5, 9, 0) <= LINUX_VERSION_CODE
	.gem_free_object_unlocked = msdisp_drm_gem_free_object,
#else
	.gem_free_object = msdisp_drm_gem_free_object,
#endif

#if KERNEL_VERSION(5, 11, 0) <= LINUX_VERSION_CODE || defined(EL8)
#else
	.gem_vm_ops = &msdisp_drm_gem_vm_ops,
#endif

	.dumb_create = msdisp_drm_dumb_create,
	.dumb_map_offset = msdisp_drm_gem_mmap_offset,
#if KERNEL_VERSION(5, 12, 0) <= LINUX_VERSION_CODE || defined(EL8)
#else
	.dumb_destroy = drm_gem_dumb_destroy,
#endif

	.fops = &msdisp_drm_driver_fops,

#if KERNEL_VERSION(6, 6, 0) > LINUX_VERSION_CODE
	/* removed from drm_driver in 6.6; the core uses these as defaults */
	.prime_fd_to_handle = drm_gem_prime_fd_to_handle,
	.prime_handle_to_fd = drm_gem_prime_handle_to_fd,
#endif
	.gem_prime_import = drm_gem_prime_import,
#if KERNEL_VERSION(5, 11, 0) <= LINUX_VERSION_CODE || defined(EL8)
#else
	.gem_prime_export = drm_gem_prime_export,
	.gem_prime_get_sg_table = msdisp_drm_prime_get_sg_table,
	.enable_vblank = msdisp_drm_enable_vblank,
	.disable_vblank = msdisp_drm_disable_vblank,
#endif
	.gem_prime_import_sg_table = msdisp_drm_prime_import_sg_table,

#if KERNEL_VERSION(6, 10, 0) <= LINUX_VERSION_CODE
	.fbdev_probe = msdisp_drm_fbdev_probe,
#endif

	.name = DRIVER_NAME,
	.desc = DRIVER_DESC,
#if KERNEL_VERSION(6, 14, 0) > LINUX_VERSION_CODE
	.date = DRIVER_DATE,
#endif
	.major = DRIVER_MAJOR,
	.minor = DRIVER_MINOR,
	.patchlevel = DRIVER_PATCH,
};

static void msdisp_drm_handle_page_flip(struct msdisp_drm_pipeline* pipeline)
{
	struct drm_crtc* crtc = pipeline->crtc;
	struct drm_device* dev = crtc->dev;
	unsigned long flags;

	spin_lock_irqsave(&dev->event_lock, flags);
	if (pipeline->event) {
		drm_crtc_send_vblank_event(crtc, pipeline->event);
		pipeline->event = NULL;
	}
	spin_unlock_irqrestore(&dev->event_lock, flags);
}

static void msidsip_drm_timer_func(struct timer_list* t)
{
#if KERNEL_VERSION(6, 16, 0) <= LINUX_VERSION_CODE
	struct msdisp_drm_device *msdisp = timer_container_of(msdisp, t, vblank_timer);
#else
	struct msdisp_drm_device *msdisp = from_timer(msdisp, t, vblank_timer);
#endif
	struct drm_crtc* crtc;
	int i;

	for (i = 0; i < msdisp->pipeline_cnt; i++) {
		crtc = msdisp->pipeline[i].crtc;
		drm_crtc_handle_vblank(crtc);
		msdisp_drm_handle_page_flip(&msdisp->pipeline[i]);
	}

	mod_timer(&msdisp->vblank_timer, jiffies + msecs_to_jiffies(msdisp_drm_vblank_timer_ms));
}

static int msdisp_drm_init(struct msdisp_drm_device *msdisp)
{
	struct drm_device *dev = &msdisp->drm;
	int i;
	int ret = -ENOMEM;

	for (i = 0; i < msdisp->pipeline_cnt; i++) {
		msdisp->pipeline[i].drm_status = MSDISP_DRM_STATUS_DISABLE;
		mutex_init(&msdisp->pipeline[i].hal_lock);
	}

	timer_setup(&msdisp->vblank_timer, msidsip_drm_timer_func, 0);
	msdisp->vblank_timer.expires = (jiffies + msecs_to_jiffies(msdisp_drm_vblank_timer_ms));
	add_timer(&msdisp->vblank_timer);
 
	ret = msdisp_drm_modeset_init(dev);
	if (ret) {
		goto err;
	}

#if KERNEL_VERSION(6, 0, 0) <= LINUX_VERSION_CODE
	dev->vblank_disable_immediate = true;
#else
#if KERNEL_VERSION(5, 15, 0) <= LINUX_VERSION_CODE
#if IS_ENABLED(CONFIG_DRM_LEGACY)
	dev->irq_enabled = true;
#endif
#else
	dev->irq_enabled = true;
#endif
#endif
    ret = drm_vblank_init(dev, msdisp->pipeline_cnt);
	if (ret)
		goto err;

	drm_kms_helper_poll_init(dev);

err:
	return ret;
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5,8,0)
#else
/* added by Fuzhao Jin */
static void devm_drm_dev_init_release(void *data)
{
	drm_dev_put(data);
}

int devm_drm_dev_init(struct device *parent,
		      struct drm_device *dev,
		      struct drm_driver *driver)
{
	int ret;

	ret = drm_dev_init(dev, driver, parent);
	if (ret)
		return ret;

	ret = devm_add_action(parent, devm_drm_dev_init_release, dev);
	if (ret)
		devm_drm_dev_init_release(dev);

	return ret;
}

void *__devm_drm_dev_alloc(struct device *parent, struct drm_driver *driver,
			   size_t size, size_t offset)
{
	void *container;
	struct drm_device *drm;
	int ret;

	container = kzalloc(size, GFP_KERNEL);
	if (!container)
		return ERR_PTR(-ENOMEM);

	drm = container + offset;
	ret = devm_drm_dev_init(parent, drm, driver);
	if (ret) {
		kfree(container);
		return ERR_PTR(ret);
	}

	return container;
}

#define devm_drm_dev_alloc(parent, driver, type, member) \
	((type *) __devm_drm_dev_alloc(parent, driver, sizeof(type), \
				       offsetof(type, member)))
#endif

struct drm_device *msdisp_drm_device_create(struct device *parent)
{
    struct msdisp_drm_device *msdisp_drm = NULL;
	struct drm_device *drm = NULL;
	int ret, i, alloc_fifo_cnt = 0;

	if (msdisp_drm_initial_pipeline_count > MSDISP_DRM_MAX_PIPELINE_CNT) {
		printk("%s: Max pipeline is :%d module param is:%d\n", __func__, MSDISP_DRM_MAX_PIPELINE_CNT, msdisp_drm_initial_pipeline_count);
		return NULL;
	}

	msdisp_drm = devm_drm_dev_alloc(parent, &driver, struct msdisp_drm_device, drm);

    if(NULL == msdisp_drm) {
        dev_err(parent, "alloc msdisp drm device failed!\n");
        return NULL;
    }

    drm = &msdisp_drm->drm;
	msdisp_drm->pipeline_cnt = msdisp_drm_initial_pipeline_count;


	for (i = 0; i < msdisp_drm->pipeline_cnt; i++) {
		ret = kfifo_alloc(&msdisp_drm->pipeline[i].fifo, 1024, GFP_KERNEL);
		if (ret) {
			dev_err(drm->dev, "alloc kfifo%d failed!\n ret = %d\n", i, ret);
			ret = -ENOMEM;
			goto err_free;
		}
		alloc_fifo_cnt = i;
	}
	
	ret = msdisp_drm_init(msdisp_drm);
	if (ret)
		goto err_free;


	ret = drm_dev_register(drm, 0);
	if (ret)
		goto err_free;

	/* Vendor driver never registered a generic fbdev/fbcon client, so
	 * nothing ever created /dev/fb0 or bound the text console to this
	 * device -- connector correctly reported "connected" but no video
	 * signal was ever actually output. drm_client_setup() (6.10+) /
	 * drm_fbdev_generic_setup() (older) is the standard call other
	 * simple KMS drivers make here; NULL/32 lets it pick a format
	 * automatically. */
#if KERNEL_VERSION(6, 10, 0) <= LINUX_VERSION_CODE
	drm_client_setup(drm, NULL);
#else
	drm_fbdev_generic_setup(drm, 32);
#endif

	msdisp_drm_sysfs_init(msdisp_drm);
	return drm;

err_free:
	for (i = 0; i < alloc_fifo_cnt; i++) {
		(void)kfifo_free(&msdisp_drm->pipeline[i].fifo);
	}
	return ERR_PTR(ret);
}

int msdisp_drm_device_remove(struct drm_device *drm)
{
	int i;
	struct msdisp_drm_device* msdisp_drm = to_msdisp_drm(drm);

	for (i = 0; i < msdisp_drm->pipeline_cnt; i++) {
		(void)kfifo_free(&msdisp_drm->pipeline[i].fifo);
	}

#if KERNEL_VERSION(6, 2, 0) <= LINUX_VERSION_CODE
	timer_delete(&msdisp_drm->vblank_timer);
#else
	del_timer(&msdisp_drm->vblank_timer);
#endif
	msdisp_drm_sysfs_exit(msdisp_drm);
	drm_dev_unplug(drm);

	return 0;
}