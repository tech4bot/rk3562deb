# SPDX-License-Identifier: GPL-2.0
ccflags-y := -I$(src) -isystem include/drm

obj-$(CONFIG_DRM_MSDISP) += usbdisp_drm.o usbdisp_usb.o

usbdisp_drm-y := msdisp_plat_drv.o msdisp_plat_dev.o msdisp_drm_drv.o \
                 msdisp_drm_modeset.o msdisp_drm_gem.o msdisp_drm_fb.o \
                 msdisp_drm_encoder.o msdisp_drm_connector.o \
                 msdisp_drm_interface.o msdisp_drm_sysfs.o \
                 msdisp_common_util.o msdisp_drm_mode.o

usbdisp_usb-y := msdisp_usb_drv.o ms9132_hal.o \
                 hal_adaptor.o usb_device.o usb_hal_interface.o \
                 usb_hal_sysfs.o usb_hal_thread.o
