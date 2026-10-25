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
 * msdisp_drm_sysfs.c -- Drm driver for MacroSilicon chip 913x and 912x
 */

#include <linux/version.h>
#include <linux/device.h>
#include <linux/fs.h>

#include <drm/drm_drv.h>
#include <drm/drm_file.h>

#include "msdisp_drm_drv.h"

#define to_pipeline(d) container_of(d, struct msdisp_drm_pipeline, dev)

static ssize_t msdisp_drm_frame_show(struct device* dev, struct device_attribute* attr, char* buf)
{
	struct msdisp_drm_pipeline* pipeline = to_pipeline(dev);
    struct msdisp_drm_frame_stat* stat = &pipeline->frame_stat;
	char tmp[256];

	*buf = 0;

	sprintf(tmp, "total:%lld\n", stat->total);
	strcat(buf, tmp);
	sprintf(tmp, "no usb hal:%lld\n", stat->no_usb_hal);
	strcat(buf, tmp);
	sprintf(tmp, "no old state:%lld\n", stat->no_old_state);
	strcat(buf, tmp);
	sprintf(tmp, "no fb:%lld\n", stat->no_fb);
	strcat(buf, tmp);
	sprintf(tmp, "vmap fail:%lld\n", stat->vmap_fail);
	strcat(buf, tmp);
	sprintf(tmp, "vmap null:%lld\n", stat->vmap_null);
	strcat(buf, tmp);
	sprintf(tmp, "cpu access fail:%lld\n", stat->cpu_access_fail);
	strcat(buf, tmp);
    sprintf(tmp, "aquire buffer fail:%lld\n", stat->acquire_buf_fail);
	strcat(buf, tmp);
	sprintf(tmp, "handle fail:%lld\n", stat->handle_fail);
	strcat(buf, tmp);

	return strlen(buf);
}

static ssize_t msdisp_drm_pipeline_info_show(struct device* dev, struct device_attribute* attr, char* buf)
{
	struct msdisp_drm_pipeline* pipeline = to_pipeline(dev);
	char tmp[256];

	*buf = 0;

	sprintf(tmp, "reg hal:%d\n", pipeline->reg_flag);
	strcat(buf, tmp);
	sprintf(tmp, "status :%d\n", pipeline->drm_status);
	strcat(buf, tmp);
	sprintf(tmp, "width:%d\n", pipeline->drm_width);
	strcat(buf, tmp);
	sprintf(tmp, "height:%d\n", pipeline->drm_height);
	strcat(buf, tmp);
	sprintf(tmp, "rate:%d\n", pipeline->drm_rate);
	strcat(buf, tmp);
	sprintf(tmp, "fb format:%x\n", pipeline->drm_fb_format);
	strcat(buf, tmp);
    
	return strlen(buf);
}

static ssize_t msdisp_drm_dump_fb_store(struct device* dev, struct device_attribute* attr, const char* buf, size_t count)
{
	struct msdisp_drm_pipeline* pipeline = to_pipeline(dev);

	if (count > 255) {
		printk("file path is too long\n");
		goto out;
	}
	memcpy(pipeline->dump_fb_filename, buf, count);
	// remove the "\n" in the tail
	if ('\n' == pipeline->dump_fb_filename[count - 1]) {
		pipeline->dump_fb_filename[count - 1] = '\0';
	}
	
	pipeline->dump_fb_flag = 1;

out:
	printk("the dump fb filename:%s len:%zu count:%zu\n", pipeline->dump_fb_filename, strlen(pipeline->dump_fb_filename), count);
	return count;
}

static DEVICE_ATTR(dump_fb, 0220, NULL, msdisp_drm_dump_fb_store);
static DEVICE_ATTR(frame, 0444, msdisp_drm_frame_show, NULL);
static DEVICE_ATTR(info, 0444, msdisp_drm_pipeline_info_show, NULL);

static struct attribute* msdisp_drm_attribute[] = {
	&dev_attr_dump_fb.attr,
    &dev_attr_frame.attr,
	&dev_attr_info.attr,
	NULL
};

static const struct attribute_group msdisp_drm_attr_group = {
	.attrs = msdisp_drm_attribute,
};

static const struct attribute_group* attr_groups [] = {
	&msdisp_drm_attr_group,
	NULL
};

static int do_init_device(struct device* dev, struct device* parent, int index)
{
	int ret;

	dev->driver = NULL;
	dev->bus = NULL;
	dev->type = NULL;
	dev->groups = attr_groups;
	dev->parent = parent;
	device_initialize(dev);
	dev_set_name(dev, "pipeline%d", index);

	ret = device_add(dev);
	if (ret) {
		dev_err(parent, "add pipeline%d's device failed! ret=%d\n", index, ret);
	}

	return ret;
}

void msdisp_drm_sysfs_init(struct msdisp_drm_device * msdisp_drm)
{
	int i, ret;
	struct device* dev;

	for (i = 0; i < msdisp_drm->pipeline_cnt; i++) {
		dev = &msdisp_drm->pipeline[i].dev;
		ret = do_init_device(dev, msdisp_drm->drm.dev, i);
		msdisp_drm->pipeline[i].dev_init = ((0 == ret) ? 1 : 0);
	}
}

void msdisp_drm_sysfs_exit(struct msdisp_drm_device * msdisp_drm)
{
	int i;
	struct device* dev;

	for (i = 0; i < msdisp_drm->pipeline_cnt; i++) {
		dev = &msdisp_drm->pipeline[i].dev;
		if (msdisp_drm->pipeline[i].dev_init) {
			device_del(dev);
		} else {
			put_device(dev);
		}
	}
}