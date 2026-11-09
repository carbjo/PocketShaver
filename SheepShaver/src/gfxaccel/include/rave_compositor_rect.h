/*
 *  rave_compositor_rect.h - RAVE draw rect to compositor destination mapping
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef RAVE_COMPOSITOR_RECT_H
#define RAVE_COMPOSITOR_RECT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct RaveCompositorRect {
	int32_t left;
	int32_t top;
	int32_t width;
	int32_t height;
};

/*
 * Some DrawSprocket-era games make a fullscreen context whose rect is offset
 * from the framebuffer, e.g. (-683,-512)-(683,512) on 1366x1024, or
 * (192,144)-(832,624) after a centered 1024x768 context drops to 640x480. That
 * rect is the 3D coordinate system, not the on-screen destination.
 */
static inline struct RaveCompositorRect RaveCompositorRectFromDrawRect(
    int32_t left,
    int32_t top,
    int32_t width,
    int32_t height,
    uint32_t mode_width,
    uint32_t mode_height)
{
	struct RaveCompositorRect out = { left, top, width, height };

	if (width <= 0 || height <= 0 || mode_width == 0 || mode_height == 0) {
		return out;
	}

	if ((uint32_t)width == mode_width &&
	    (uint32_t)height == mode_height) {
		out.left = 0;
		out.top = 0;
	}

	return out;
}

#ifdef __cplusplus
}
#endif

#endif /* RAVE_COMPOSITOR_RECT_H */
