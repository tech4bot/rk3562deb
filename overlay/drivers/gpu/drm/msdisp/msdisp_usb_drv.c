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
 * msdisp_usb_drv.c -- Drm driver for MacroSilicon chip 913x and 912x
 */
 
#include <linux/module.h>
#include <linux/kthread.h>
#include <linux/sched.h>
#include <linux/version.h>
#include <linux/device.h>
#include <linux/fs.h>
#include <linux/slab.h>

#include <linux/mm_types.h>
#include <linux/usb.h>
#include <linux/mutex.h>
#include <linux/semaphore.h>
#include <linux/completion.h>
#include <linux/scatterlist.h>
#include <linux/kfifo.h>

#include <drm/drm_device.h>
#include <drm/drm_modeset_helper.h>
#include <drm/drm_probe_helper.h>
#include <drm/drm_file.h>
#include <drm/drm_fourcc.h>

#include "msdisp_usb_interface.h"
#include "msdisp_drm_interface.h"
#include "msdisp_usb_drv.h"
#include "usb_hal_interface.h"

#if KERNEL_VERSION(6, 13, 0) <= LINUX_VERSION_CODE
MODULE_IMPORT_NS("usbdisp_drm");
#elif KERNEL_VERSION(5, 10, 0) <= LINUX_VERSION_CODE
MODULE_IMPORT_NS(usbdisp_drm);
#endif

#define MOD_VER							"3.1.5"
#define MAX_CUSTOM_MODE_CNT				16

struct custom_mode_stru {
	unsigned short width;
	unsigned short height;
	unsigned char rate;
	unsigned char vic;
};


static int option_parserd = 0;
static char* custom_mode = NULL;
static int custom_mode_cnt = 0;
static struct custom_mode_stru mode_arr[MAX_CUSTOM_MODE_CNT];

module_param(custom_mode, charp, S_IRUGO);
MODULE_PARM_DESC(custom_mode, "custom mode: (<vic>_<x>x<y>@<refr>[,<vic>_<x>x<y>@<refr>...]");


void msdisp_usb_sysfs_init(struct usb_interface *interface);
void msdisp_usb_sysfs_exit(struct usb_interface *interface);


void parser_custom_mode(void)
{
	char* start, *cur, *ori;
	int width, height, rate, vic;

	custom_mode_cnt = 0;
	memset(&mode_arr, 0, sizeof(mode_arr));

	if (!custom_mode) {
		return ;
	}

	ori = kstrdup(custom_mode, GFP_KERNEL);
	if (!ori) {
		printk("msdisp:duplicate custom mode failed!\n");
		return ;
	}

	start = ori;
	while (start) {
		cur = strsep(&start, ",");
		if (!cur) {
			break;
		}

		width = 0;
		height = 0;
		rate = 0;
		vic = 0;
		sscanf(cur, "%d_%dx%d@%d", &vic, &width, &height, &rate);
		if ((width != 0) && (height != 0) && (rate != 0) && (vic != 0)) {
			printk("msdisp:parsed custom mode: width:%d height %d rate:%d vic:%d\n", width, height, rate, vic);
			mode_arr[custom_mode_cnt].width = width;
			mode_arr[custom_mode_cnt].height = height;
			mode_arr[custom_mode_cnt].rate = rate;
			mode_arr[custom_mode_cnt].vic = vic;
			custom_mode_cnt++;
		}
	}

	kfree(ori);
}

void msdisp_usb_add_custom_mode(struct msdisp_usb_device* usb_dev)
{
	int i;
	int ret;
	struct usb_hal* hal = usb_dev->hal;

	usb_hal_init_gpio(hal);
	usb_hal_read_custom_timing(hal);
	usb_hal_resume_gpio(hal);

	for (i = 0; i < custom_mode_cnt; i++) {
		ret = usb_hal_add_custom_mode(hal, mode_arr[i].width, mode_arr[i].height, mode_arr[i].rate, mode_arr[i].vic);
		dev_info(&usb_dev->udev->dev,"add custom mode:width:%d height:%d rate:%d vic:%d %s\n", \
			mode_arr[i].width, mode_arr[i].height, mode_arr[i].rate, mode_arr[i].vic, ret ? "failed" : "success");
	}
}

static int msdisp_usb_suspend(struct usb_interface *interface,
			   pm_message_t message)
{
    struct msdisp_usb_device* usb_dev = usb_get_intfdata(interface);
	int ret;

	ret = drm_mode_config_helper_suspend(usb_dev->drm);
	dev_info(&usb_dev->udev->dev, "suspend! ret=%d\n", ret);
    return ret;
}

static int msdisp_usb_resume(struct usb_interface *interface)
{
    struct msdisp_usb_device* usb_dev = usb_get_intfdata(interface);
	int ret;

	ret = drm_mode_config_helper_resume(usb_dev->drm);

	dev_info(&usb_dev->udev->dev, "resume! ret=%d\n", ret);
	return ret;
}

static int msdisp_usb_reset_resume(struct usb_interface *interface)
{
    struct msdisp_usb_device* usb_dev = usb_get_intfdata(interface);
	int ret;
	
	if (usb_dev && usb_dev->hal) {
		usb_hal_resume_gpio(usb_dev->hal);
	}
	ret = drm_mode_config_helper_resume(usb_dev->drm);
	if (usb_dev && usb_dev->drm) {
		drm_kms_helper_hotplug_event(usb_dev->drm);
	}
	dev_info(&usb_dev->udev->dev, "reset resume!ret =%d\n", ret);
	return ret;
}

struct usb_hal* usb_intf_device_to_hal_func(struct device* dev)
{
	struct msdisp_usb_device* usb_dev = dev_get_drvdata(dev);
	return usb_dev->hal;
}

static int msdisp_usb_probe(struct usb_interface *interface,
			const struct usb_device_id *id)
{
    struct usb_device *udev = interface_to_usbdev(interface);
    struct msdisp_usb_device* usb_dev;
    struct msdisp_usb_hal* usb_hal;
	struct kfifo* fifo;
    int ret = 0;
	int global_id;
	struct kobject* obj;

	dev_info(&udev->dev, "module version:%s\n", MOD_VER);
	if (!option_parserd) {
		parser_custom_mode();
		option_parserd = 1;
	}

    usb_dev = devm_kzalloc(&udev->dev, sizeof(struct msdisp_usb_device), GFP_KERNEL);
    if (!usb_dev) {
        dev_err(&udev->dev, "devm_kzalloc alloc usb_dev failed!\n");
        return -ENOMEM;
    }

    usb_hal = devm_kzalloc(&udev->dev, sizeof(*usb_hal), GFP_KERNEL);
    if (!usb_hal) {
        dev_err(&udev->dev, "devm_kzalloc alloc usb_hal failed!\n");
        return -ENOMEM;
    } 

    usb_dev->udev = udev;
	
    usb_hal->funcs = msdisp_usb_find_usb_hal(id);
    if (!usb_hal->funcs) {
        dev_err(&udev->dev, "Can't find usb hal funcs! vid=0x%x pid=0x%x\n", id->idVendor, id->idProduct);
        return -ENOENT;
    }

    usb_dev->drm = msdisp_drm_get_free_device();
    if (!usb_dev->drm) {
		dev_err(&udev->dev, "get free drm device failed!\n");
        ret = -ENODEV;
        goto fail;
    }

	usb_dev->pipeline_index = msdisp_drm_get_free_pipeline_index(usb_dev->drm);
	if (usb_dev->pipeline_index < 0) {
		dev_err(&udev->dev, "get free pipeline failed!\n");
        ret = -ENODEV;
        goto fail;
	}

	fifo = msdisp_drm_get_kfifo(usb_dev->drm, usb_dev->pipeline_index);
	if (!fifo) {
		dev_err(&udev->dev, "drm get fifo failed!\n");
        ret = -ENODEV;
        goto fail;
    }

	usb_set_intfdata(interface, usb_dev);
	global_id = msdisp_drm_get_pipeline_global_id(usb_dev->drm, usb_dev->pipeline_index);
	usb_dev->hal = usb_hal_init(interface, id, fifo, global_id);
	if (!usb_dev->hal) {
		dev_err(&udev->dev, "usb hal init failed!!\n");
		ret = -ENODEV;
        goto fail;
	}
	msdisp_usb_add_custom_mode(usb_dev);

    usb_hal->private = usb_dev;
    usb_dev->usb_hal = usb_hal;
    ret = msdisp_drm_register_usb_hal(usb_dev->drm, usb_dev->pipeline_index, usb_hal);
    if (ret) {
        dev_err(&udev->dev, "register usb hal failed!");
        ret = -EINVAL;
        goto fail;
    }

	obj = msdisp_drm_get_pipeline_kobject(usb_dev->drm, usb_dev->pipeline_index);
	if (obj) {
		ret = sysfs_create_link(obj, &interface->dev.kobj, "usb_dev");
		if (ret) {
			dev_err(&udev->dev, "create syslink failed!ret=%d\n", ret);
		}
	}

	drm_kms_helper_hotplug_event(usb_dev->drm);
	
    return 0;

fail:
	if (usb_dev->hal) {
		usb_hal_destroy(usb_dev->hal);
	}

    return ret;
}

static void msdisp_usb_disconnect(struct usb_interface *interface)
{
	struct msdisp_usb_device* usb_dev = usb_get_intfdata(interface);
	struct kobject* obj;
    
    (void)msdisp_drm_unregister_usb_hal(usb_dev->drm, usb_dev->pipeline_index);
	usb_hal_destroy(usb_dev->hal);
	obj = msdisp_drm_get_pipeline_kobject(usb_dev->drm, usb_dev->pipeline_index);
	if (obj) {
		sysfs_remove_link(obj, "usb_dev");
	}
	if (usb_dev && usb_dev->drm) {
		drm_kms_helper_hotplug_event(usb_dev->drm);
	}
}

static const struct usb_device_id id_table[] = {
	{.idVendor = 0x345f, .idProduct = 0x9132, .bInterfaceClass = 0xff,
	 .bInterfaceSubClass = 0x00,
	 .bInterfaceProtocol = 0x00,
	 .match_flags = USB_DEVICE_ID_MATCH_VENDOR |
            USB_DEVICE_ID_MATCH_PRODUCT |
			USB_DEVICE_ID_MATCH_INT_CLASS |
			USB_DEVICE_ID_MATCH_INT_SUBCLASS |
			USB_DEVICE_ID_MATCH_INT_PROTOCOL,},

	{.idVendor = 0x345f, .idProduct = 0x9133, .bInterfaceClass = 0xff,
	 .bInterfaceSubClass = 0x00,
	 .bInterfaceProtocol = 0x00,
	 .match_flags = USB_DEVICE_ID_MATCH_VENDOR |
            USB_DEVICE_ID_MATCH_PRODUCT |
			USB_DEVICE_ID_MATCH_INT_CLASS |
			USB_DEVICE_ID_MATCH_INT_SUBCLASS |
			USB_DEVICE_ID_MATCH_INT_PROTOCOL,},

	{.idVendor = 0x345f, .idProduct = 0x9135, .bInterfaceClass = 0xff,
	 .bInterfaceSubClass = 0x00,
	 .bInterfaceProtocol = 0x00,
	 .match_flags = USB_DEVICE_ID_MATCH_VENDOR |
            USB_DEVICE_ID_MATCH_PRODUCT |
			USB_DEVICE_ID_MATCH_INT_CLASS |
			USB_DEVICE_ID_MATCH_INT_SUBCLASS |
			USB_DEVICE_ID_MATCH_INT_PROTOCOL,},

	/* Post-modeswitch functional ID: this dongle enumerates as 345f:9132
	 * (fake driver-CD mode) only until something claims it, then it
	 * re-enumerates as 534d:6021 "MacroSilicon VGA Display Adapter" for
	 * its actual HID+Audio+vendor-display composite function. Interface
	 * 3 (bInterfaceClass 0xff/0x00/0x00, iInterface "msusb video") is the
	 * display control interface, same shape as the 345f entries above. */
	{.idVendor = 0x534d, .idProduct = 0x6021, .bInterfaceClass = 0xff,
	 .bInterfaceSubClass = 0x00,
	 .bInterfaceProtocol = 0x00,
	 .match_flags = USB_DEVICE_ID_MATCH_VENDOR |
            USB_DEVICE_ID_MATCH_PRODUCT |
			USB_DEVICE_ID_MATCH_INT_CLASS |
			USB_DEVICE_ID_MATCH_INT_SUBCLASS |
			USB_DEVICE_ID_MATCH_INT_PROTOCOL,},
	{},
};
MODULE_DEVICE_TABLE(usb, id_table);

static struct usb_driver msdisp_usb_drv = {
	.name = "msdisp_usb",
	.probe = msdisp_usb_probe,
	.disconnect = msdisp_usb_disconnect,
	.suspend = msdisp_usb_suspend,
	.resume = msdisp_usb_resume,
	.reset_resume = msdisp_usb_reset_resume,
	.id_table = id_table,
};
module_usb_driver(msdisp_usb_drv);

MODULE_VERSION(MOD_VER);
MODULE_DESCRIPTION("MacroSilicon USB Display USB Driver");
MODULE_LICENSE("GPL");
