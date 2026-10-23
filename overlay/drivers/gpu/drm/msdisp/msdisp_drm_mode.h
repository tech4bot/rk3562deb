#ifndef __MSDISP_DRM_MODE_H__
#define __MSDISP_DRM_MODE_H__

struct drm_display_mode;
struct drm_device;

struct drm_display_mode * msdisp_mode_from_cea_vic(struct drm_device *dev, unsigned char video_code);

#endif