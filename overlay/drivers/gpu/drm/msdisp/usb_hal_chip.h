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
 * usb_hal_chip.h -- Drm driver for MacroSilicon chip 913x and 912x
 */
 
#ifndef __USB_HAL_CHIP_H__
#define __USB_HAL_CHIP_H__

#define CHIP_ID_9132                            0
#define CHIP_ID_9120                            1
#define CHIP_ID_912A                            2
#define CHIP_ID_912C                            3

#define VIDEO_PORT_CVBS                         0
#define VIDEO_PORT_SVIDEO                       1
#define VIDEO_PORT_VGA                          2
#define VIDEO_PORT_YPBPR                        3
#define VIDEO_PORT_CVBS_SVIDEO                  4
#define VIDEO_PORT_HDMI                         5
#define VIDEO_PORT_DIGITAL                      6
#define VIDEO_PORT_MAX                          7

#define SDRAM_2M                                0
#define SDRAM_4M                                1
#define SDRAM_8M                                2
#define SDRAM_16M                               3
#define SDRAM_NONE                              4


#endif