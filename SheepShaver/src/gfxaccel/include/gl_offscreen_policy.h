/*
 *  gl_offscreen_policy.h - OpenGL offscreen drawable analysis helpers.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 */

#ifndef GL_OFFSCREEN_POLICY_H
#define GL_OFFSCREEN_POLICY_H

#include <stdint.h>

typedef struct GLOverlayLayerRect {
	float dst_origin_x;
	float dst_origin_y;
	float dst_size_w;
	float dst_size_h;
	bool framebuffer_space;
} GLOverlayLayerRect;

static inline uint32_t GLOffscreenDrawableBytesPerPixel(uint32_t width,
                                                        uint32_t rowbytes)
{
	if (width == 0) return 0;

	const uint64_t min_32bpp_rowbytes = (uint64_t)width * 4u;
	const uint64_t min_16bpp_rowbytes = (uint64_t)width * 2u;
	if ((uint64_t)rowbytes >= min_32bpp_rowbytes) return 4;
	if ((uint64_t)rowbytes >= min_16bpp_rowbytes) return 2;
	return 0;
}

static inline bool GLShouldAcceptOffscreenDrawable(uint32_t width,
                                                   uint32_t height,
                                                   uint32_t rowbytes,
                                                   uint32_t baseaddr)
{
	// AGL sizes/strides are signed GLsizei values at the guest ABI boundary.
	// Bound them before viewport casts, CPU allocations, or Metal descriptors.
	return width != 0 && width <= 16384 &&
	       height != 0 && height <= 16384 && rowbytes <= INT32_MAX &&
	       GLOffscreenDrawableBytesPerPixel(width, rowbytes) != 0 &&
	       baseaddr != 0;
}

static inline bool GLOffscreenDrawableFitsGuestRAM(uint32_t width,
                                                   uint32_t height,
                                                   uint32_t rowbytes,
                                                   uint32_t baseaddr,
                                                   uint32_t ram_base,
                                                   uint32_t ram_size)
{
	if (!GLShouldAcceptOffscreenDrawable(width, height, rowbytes, baseaddr) ||
	    baseaddr < ram_base) return false;
	// Only the pixels in the last row are accessed; trailing padding need not
	// be mapped. Both import and readback must fit writable guest RAM.
	const uint64_t bytes = uint64_t(height - 1) * rowbytes +
	    uint64_t(width) * GLOffscreenDrawableBytesPerPixel(width, rowbytes);
	const uint64_t end = uint64_t(baseaddr) + bytes;
	return end <= (uint64_t(1) << 32) &&
	       end <= uint64_t(ram_base) + ram_size;
}

static inline bool GLShouldReadbackOffscreenDrawable(bool is_offscreen,
                                                     uint32_t width,
                                                     uint32_t height,
                                                     uint32_t rowbytes,
                                                     uint32_t baseaddr)
{
	return is_offscreen &&
	       GLShouldAcceptOffscreenDrawable(width, height, rowbytes, baseaddr);
}

static inline bool GLShouldPreserveOverlayBindingAfterResourceDetach(
	bool drawable_bound,
	int32_t dst_width,
	int32_t dst_height)
{
	return drawable_bound && dst_width > 0 && dst_height > 0;
}

static inline bool GLShouldReacquireBoundOverlayForPresent(
	bool cached_overlay,
	bool drawable_bound,
	int32_t dst_width,
	int32_t dst_height)
{
	return !cached_overlay &&
	       GLShouldPreserveOverlayBindingAfterResourceDetach(drawable_bound,
	                                                         dst_width,
	                                                         dst_height);
}

static inline bool GLShouldSubmitOverlayFrame(bool cached_overlay,
                                              bool committed_frame)
{
	return cached_overlay && committed_frame;
}

static inline bool GLShouldBeginRenderPassForClear(uint32_t clear_mask)
{
	/* GL_COLOR_BUFFER_BIT. Depth/stencil-only clears are not visible frames. */
	return (clear_mask & 0x00004000u) != 0;
}

static inline bool GLShouldClearColorAttachment(uint32_t clear_mask)
{
	return (clear_mask & 0x00004000u) != 0;
}

static inline bool GLShouldClearDepthAttachment(uint32_t clear_mask)
{
	return (clear_mask & 0x00000100u) != 0;
}

static inline bool GLShouldClearStencilAttachment(uint32_t clear_mask)
{
	return (clear_mask & 0x00000400u) != 0;
}

static inline bool GLShouldApplyAttachmentClear(uint32_t clear_mask)
{
	return GLShouldClearColorAttachment(clear_mask) ||
	       GLShouldClearDepthAttachment(clear_mask) ||
	       GLShouldClearStencilAttachment(clear_mask);
}

static inline GLOverlayLayerRect GLMakeOverlayLayerRect(
	int32_t dst_left,
	int32_t dst_top,
	int32_t dst_width,
	int32_t dst_height,
	uint32_t overlay_width,
	uint32_t overlay_height,
	uint32_t framebuffer_width,
	uint32_t framebuffer_height)
{
	GLOverlayLayerRect rect;
	rect.dst_origin_x = (float)dst_left;
	rect.dst_origin_y = (float)dst_top;
	rect.dst_size_w = (float)dst_width;
	rect.dst_size_h = (float)dst_height;
	rect.framebuffer_space = false;

	if (overlay_width != 0 &&
	    overlay_height != 0 &&
	    framebuffer_width != 0 &&
	    framebuffer_height != 0 &&
	    dst_width > 0 &&
	    dst_height > 0 &&
	    overlay_width == framebuffer_width &&
	    overlay_height == framebuffer_height &&
	    ((uint32_t)dst_width != framebuffer_width ||
	     (uint32_t)dst_height != framebuffer_height)) {
		rect.dst_origin_x = 0.0f;
		rect.dst_origin_y = 0.0f;
		rect.dst_size_w = (float)framebuffer_width;
		rect.dst_size_h = (float)framebuffer_height;
		rect.framebuffer_space = true;
	}

	return rect;
}

static inline uint16_t GLOffscreenPackRGB555BigEndian(uint8_t r,
                                                      uint8_t g,
                                                      uint8_t b)
{
	return (uint16_t)((((uint16_t)r >> 3) << 10) |
	                  (((uint16_t)g >> 3) <<  5) |
	                   ((uint16_t)b >> 3));
}

static inline uint16_t GLOffscreenPackARGB1555BigEndian(uint8_t r,
                                                        uint8_t g,
                                                        uint8_t b,
                                                        uint8_t a)
{
	const uint16_t alpha = (a >= 128) ? 0x8000u : 0u;
	return (uint16_t)(alpha | GLOffscreenPackRGB555BigEndian(r, g, b));
}

static inline void GLOffscreenStoreRGB555Bytes(uint16_t pixel,
                                               uint8_t out_bytes[2])
{
	out_bytes[0] = (uint8_t)(pixel >> 8);
	out_bytes[1] = (uint8_t)(pixel & 0xffu);
}

static inline void GLOffscreenStoreARGB8888Bytes(uint8_t r,
                                                 uint8_t g,
                                                 uint8_t b,
                                                 uint8_t a,
                                                 uint8_t out_bytes[4])
{
	out_bytes[0] = a;
	out_bytes[1] = r;
	out_bytes[2] = g;
	out_bytes[3] = b;
}

/* Import caller-owned offscreen memory before resuming GPU rendering. A
 * flush exposes this memory to the guest CPU; preserving the private Metal
 * texture alone would undo CPU erases and edits on the next readback. */
static inline bool GLOffscreenLoadGuestPixelsToBGRA8(
	const uint8_t *guest, uint32_t width, uint32_t height,
	uint32_t rowbytes, uint32_t bytes_per_pixel, uint8_t *bgra)
{
	if (!guest || !bgra || width == 0 || height == 0 ||
	    (bytes_per_pixel != 2 && bytes_per_pixel != 4) ||
	    (uint64_t)rowbytes < (uint64_t)width * bytes_per_pixel)
		return false;

	for (uint32_t y = 0; y < height; ++y) {
		const uint8_t *src = guest + (uint64_t)y * rowbytes;
		uint8_t *dst = bgra + (uint64_t)y * width * 4u;
		for (uint32_t x = 0; x < width; ++x) {
			if (bytes_per_pixel == 2) {
				const uint16_t pixel = (uint16_t)((src[0] << 8) | src[1]);
				const uint8_t b = pixel & 31u;
				const uint8_t g = (pixel >> 5) & 31u;
				const uint8_t r = (pixel >> 10) & 31u;
				dst[0] = (uint8_t)((b << 3) | (b >> 2));
				dst[1] = (uint8_t)((g << 3) | (g >> 2));
				dst[2] = (uint8_t)((r << 3) | (r >> 2));
				dst[3] = (pixel & 0x8000u) ? 255 : 0;
			} else {
				dst[0] = src[3];
				dst[1] = src[2];
				dst[2] = src[1];
				dst[3] = src[0];
			}
			src += bytes_per_pixel;
			dst += 4;
		}
	}
	return true;
}

#endif /* GL_OFFSCREEN_POLICY_H */
