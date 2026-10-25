#ifndef __MSDISP_MS9132_H__
#define __MSDISP_MS9132_H__

#include "hal_adaptor.h"

#define MSDISP_913X_VENDOR 0x345f
#define MSDISP_9132_PRODUCT 0x9132
#define MSDISP_9133_PRODUCT 0x9133
#define MSDISP_9135_PRODUCT 0x9135

/* Post-modeswitch functional VID:PID for the same 913x chip: the dongle
 * enumerates as MSDISP_913X_VENDOR:MSDISP_9132_PRODUCT (fake driver-CD
 * mode) only until claimed, then re-enumerates as this composite
 * HID+Audio+vendor-display ID for its real function. */
#define MSDISP_6021_VENDOR 0x534d
#define MSDISP_6021_PRODUCT 0x6021

extern const struct msdisp_hal_id ms9132_id;
extern const struct msdisp_hal_id ms9133_id;
extern const struct msdisp_hal_id ms9135_id;
extern const struct msdisp_hal_id ms6021_id;
extern struct msdisp_hal_dev ms9132_dev;
extern struct msdisp_hal_dev ms9133_dev;
extern struct msdisp_hal_dev ms9135_dev;
extern struct msdisp_hal_dev ms6021_dev;


#endif