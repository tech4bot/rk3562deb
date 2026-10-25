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

#include <linux/version.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/dma-mapping.h>
#include <linux/usb.h>
#include <linux/string.h>

#include "msdisp_plat_drv.h"
#include "msdisp_plat_dev.h"


#define MOD_VER							"3.1.5"

static ushort msdisp_initial_device_count = 1;
module_param_named(initial_device_count,
		   msdisp_initial_device_count, ushort, 0644);
MODULE_PARM_DESC(initial_device_count, "Initial DRM device count (default: 1)");


static struct msdisp_platform_drv_context {
	struct device *root_dev;
	unsigned int dev_count;
	struct platform_device *devices[MSDISP_DEVICE_COUNT_MAX];
	struct notifier_block usb_notifier;
	struct mutex lock;
} g_ctx;

#define msdisp_platform_drv_context_lock(ctx) \
		mutex_lock(&ctx->lock)

#define msdisp_platform_drv_context_unlock(ctx) \
		mutex_unlock(&ctx->lock)


struct platform_device* msdisp_platform_get_device(int id)
{
	if (id >= MSDISP_DEVICE_COUNT_MAX) {
		printk("msdisp: id is invalid\n");
		return NULL;
	}

	return g_ctx.devices[id];
}
EXPORT_SYMBOL(msdisp_platform_get_device);

int msdisp_platform_get_plat_device_index(struct platform_device* plat_dev)
{
	int i = 0; 

	if (!plat_dev) {
		return -1;
	}

	for (i = 0; i < MSDISP_DEVICE_COUNT_MAX; i++) {
		if (g_ctx.devices[i] == plat_dev) {
			return i;
		}
	}

	return -1;
}
EXPORT_SYMBOL(msdisp_platform_get_plat_device_index);

static int msdisp_platform_drv_usb(__always_unused struct notifier_block *nb,
		unsigned long action,
		void *data)
{
#if 0
	struct usb_device *usb_dev = (struct usb_device *)(data);
	struct platform_device *pdev;
	int i = 0;

	if (!usb_dev)
		return 0;
	if (action != BUS_NOTIFY_DEL_DEVICE)
		return 0;

	for (i = 0; i < MSDISP_DEVICE_COUNT_MAX; ++i) {
		pdev = g_ctx.devices[i];
		if (!pdev)
			continue;
		msdisp_platform_device_unlink_if_linked_with(pdev, &usb_dev->dev);
		if (pdev->dev.parent == &usb_dev->dev) {
			msdisp_INFO("Parent USB removed. Removing msdisp.%d\n", i);
			msdisp_platform_dev_destroy(pdev);
			msdisp_platform_drv_context_lock((&g_ctx));
			g_ctx.dev_count--;
			g_ctx.devices[i] = NULL;
			msdisp_platform_drv_context_unlock((&g_ctx));
		}
	}
#endif
	return 0;
}

static int msdisp_platform_drv_get_free_idx(struct msdisp_platform_drv_context *ctx)
{
	int i;

	for (i = 0; i < MSDISP_DEVICE_COUNT_MAX; ++i) {
		if (ctx->devices[i] == NULL)
			return i;
	}
	return -ENOMEM;
}

static struct platform_device *msdisp_platform_drv_create_new_device(struct msdisp_platform_drv_context *ctx)
{
	struct platform_device *pdev = NULL;
	struct platform_device_info pdevinfo = {
		.parent = ctx->root_dev,
		.name = PLAT_DRIVER_NAME,
		.id = msdisp_platform_drv_get_free_idx(ctx),
		.res = NULL,
		.num_res = 0,
		.data = NULL,
		.size_data = 0,
		.dma_mask = DMA_BIT_MASK(32),
	};

	if (pdevinfo.id < 0 || ctx->dev_count >= MSDISP_DEVICE_COUNT_MAX) {
		printk("msdisp device add failed. Too many devices.\n");
		return ERR_PTR(-EINVAL);
	}

	pdev = msdisp_platform_dev_create(&pdevinfo);
	ctx->devices[pdevinfo.id] = pdev;
	ctx->dev_count++;

	return pdev;
}

int msdisp_platform_device_add(struct device *device)
{
	struct msdisp_platform_drv_context *ctx =
		(struct msdisp_platform_drv_context *)dev_get_drvdata(device);
	struct platform_device *pdev = NULL;

	msdisp_platform_drv_context_lock(ctx);

	if (IS_ERR_OR_NULL(pdev))
		pdev = msdisp_platform_drv_create_new_device(ctx);
	msdisp_platform_drv_context_unlock(ctx);

	if (IS_ERR_OR_NULL(pdev))
		return -EINVAL;

	return 0;
}

int msdisp_platform_add_devices(struct device *device, unsigned int val)
{
	unsigned int dev_count = msdisp_platform_device_count(device);

	if (val == 0) {
		dev_warn(device, "Adding 0 devices has no effect\n");
		return 0;
	}
	if (val > MSDISP_DEVICE_COUNT_MAX - dev_count) {
		dev_err(device, "msdisp device add failed. Too many devices.\n");
		return -EINVAL;
	}

	dev_info(device, "Increasing device count to %u\n", dev_count + val);
	while (val-- && msdisp_platform_device_add(device) == 0)
		;
	return 0;
}

void msdisp_platform_remove_all_devices(struct device *device)
{
	int i;
	struct msdisp_platform_drv_context *ctx =
		(struct msdisp_platform_drv_context *)dev_get_drvdata(device);

	msdisp_platform_drv_context_lock(ctx);
	for (i = 0; i < MSDISP_DEVICE_COUNT_MAX; ++i) {
		if (ctx->devices[i]) {
			dev_info(device, "Removing msdisp %d\n", i);
			msdisp_platform_dev_destroy(ctx->devices[i]);
			g_ctx.dev_count--;
			g_ctx.devices[i] = NULL;
		}
	}
	ctx->dev_count = 0;
	msdisp_platform_drv_context_unlock(ctx);
}

unsigned int msdisp_platform_device_count(struct device *device)
{
	unsigned int count = 0;
	struct msdisp_platform_drv_context *ctx = NULL;

	ctx = (struct msdisp_platform_drv_context *)dev_get_drvdata(device);
	msdisp_platform_drv_context_lock(ctx);
	count = ctx->dev_count;
	msdisp_platform_drv_context_unlock(ctx);

	return count;

}

static struct platform_driver msdisp_platform_driver = {
	.probe = msdisp_platform_device_probe,
	.remove = msdisp_platform_device_remove,
	.driver = {
		   .name = PLAT_DRIVER_NAME,
		   .mod_name = KBUILD_MODNAME,
		   .owner = THIS_MODULE,
	}
};

static int __init msdisp_init(void)
{
	int ret;

	memset(&g_ctx, 0, sizeof(g_ctx));
	g_ctx.root_dev = root_device_register("usbevdi");
	dev_info(g_ctx.root_dev, "module version:%s\n", MOD_VER);
	g_ctx.usb_notifier.notifier_call = msdisp_platform_drv_usb;
	mutex_init(&g_ctx.lock);
	dev_set_drvdata(g_ctx.root_dev, &g_ctx);

	usb_register_notify(&g_ctx.usb_notifier);
	ret = platform_driver_register(&msdisp_platform_driver);
	if (ret)
		return ret;

	if (msdisp_initial_device_count)
		return msdisp_platform_add_devices(
			g_ctx.root_dev, msdisp_initial_device_count);

	return 0;
}

static void __exit msdisp_exit(void)
{
	msdisp_platform_remove_all_devices(g_ctx.root_dev);
	platform_driver_unregister(&msdisp_platform_driver);

	if (!PTR_ERR_OR_ZERO(g_ctx.root_dev)) {
		usb_unregister_notify(&g_ctx.usb_notifier);
		dev_set_drvdata(g_ctx.root_dev, NULL);
		root_device_unregister(g_ctx.root_dev);
	}
	printk("Exit %s driver\n", DRIVER_NAME);
}

module_init(msdisp_init);
module_exit(msdisp_exit);

MODULE_VERSION(MOD_VER);
MODULE_DESCRIPTION("MacroSilicon USB Display DRM Driver");
MODULE_LICENSE("GPL");