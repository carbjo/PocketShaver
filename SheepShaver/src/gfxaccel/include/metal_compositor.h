/*
 *  metal_compositor.h - Metal compositor for 2D framebuffer presentation
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  C++ callable interface for the Metal compositor that replaces SDL's
 *  rendering pipeline on iOS. Returns void/int so this header can be
 *  included from plain .cpp files without pulling in ObjC types.
 */

#ifndef METAL_COMPOSITOR_H
#define METAL_COMPOSITOR_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Depth values correspond to VIDEO_DEPTH_* constants from video_blit.h:
 *   VIDEO_DEPTH_1BIT  — 1-bit indexed (2 colors)
 *   VIDEO_DEPTH_2BIT  — 2-bit indexed (4 colors)
 *   VIDEO_DEPTH_4BIT  — 4-bit indexed (16 colors)
 *   VIDEO_DEPTH_8BIT  — 8-bit indexed (256 colors)
 *   VIDEO_DEPTH_16BIT — 16-bit direct (xRGB1555 big-endian)
 *   VIDEO_DEPTH_32BIT — 32-bit direct (BGRA8)
 */

/*
 * Initialize the Metal compositor for 2D framebuffer presentation.
 *
 * Creates a CompositorMetalView (UIView + CAMetalLayer) covering the full
 * iOS window, wraps the framebuffer as a zero-copy shared MTLBuffer with
 * a MTLTexture view, and builds the render pipeline for the specified depth.
 *
 * Parameters:
 *   width       - framebuffer width in pixels
 *   height      - framebuffer height in pixels
 *   depth       - VIDEO_DEPTH_* constant (selects texture format + shader)
 *   row_bytes   - actual data row stride in bytes (VIDEO_MODE_ROW_BYTES)
 *   pitch       - allocation row stride in bytes (>= row_bytes, page-aligned)
 *   buffer      - pointer to the_buffer (page-aligned framebuffer memory)
 *   buffer_size - total allocation size (page-aligned, >= height * pitch)
 *
 * Returns 0 on success, -1 on failure (with diagnostic log messages).
 */
int MetalCompositorInit(int width, int height, int depth, int row_bytes,
                        int pitch, void *buffer, uint32_t buffer_size);

/*
 * Update the 256-entry palette for indexed color depths (1/2/4/8-bit).
 *
 * Expands 3-byte-per-entry RGB input to 4-byte RGBA (A=255) and copies
 * to the shared palette MTLBuffer. No-op with a warning if called when
 * the compositor is not in an indexed color mode.
 *
 * Parameters:
 *   pal        - pointer to palette data (3 bytes per color: R, G, B)
 *   num_colors - number of palette entries to update (max 256)
 */
void MetalCompositorUpdatePalette(const uint8_t *pal, int num_colors);

/*
 * Render one frame of the 2D framebuffer to the CAMetalLayer.
 *
 * Gets the next drawable, encodes a fullscreen triangle draw sampling
 * the shared framebuffer texture, and presents+commits immediately.
 * Safe to call when not initialized (returns silently).
 */
void MetalCompositorPresent(void);

/*
 * Tear down all Metal compositor resources.
 *
 * Removes the CompositorMetalView from the UIWindow and releases
 * all Metal objects. Safe to call when not initialized.
 */
void MetalCompositorShutdown(void);

/*
 * Resize the Metal compositor for a resolution/depth mode switch.
 *
 * Rebuilds only the depth-dependent resources — buffer, texture, pipeline,
 * palette, and sampler — while keeping the view, layer, device, queue,
 * overlay_pipeline, and overlay_sampler alive. This avoids the visual flash
 * and UIView lifecycle overhead from a full Shutdown→Init cycle.
 *
 * The overlay_texture is nilled so RAVE/GL will recreate it on the next
 * frame via MetalCompositorCreateOverlayTexture().
 *
 * Threading: called from the PPC emulation thread with interrupts disabled —
 * no MetalCompositorPresent() calls can fire during resize. UIView operations
 * must NOT happen here (which is why the view stays alive).
 *
 * Precondition: compositor must already be initialized (via MetalCompositorInit).
 * If not, returns -1 and logs an error — caller should use Init instead.
 *
 * Parameters: same as MetalCompositorInit.
 *
 * Returns 0 on success, -1 on failure (with diagnostic log messages).
 */
int MetalCompositorResize(int width, int height, int depth, int row_bytes,
                          int pitch, void *buffer, uint32_t buffer_size);

/*
 * Query whether the compositor has been successfully initialized.
 *
 * Returns 1 if MetalCompositorInit completed successfully and
 * MetalCompositorShutdown has not been called since. Returns 0 otherwise.
 *
 * Used by video_sdl2.cpp to decide between Init (first time) and Resize
 * (subsequent mode switches).
 */
int MetalCompositorIsInitialized(void);

/*
 * Create (or resize) the offscreen overlay texture for 3D compositing.
 *
 * The texture is BGRA8Unorm, GPU-private, with RenderTarget|ShaderRead
 * usage — suitable as a render target for RAVE/GL and as a shader-read
 * source for the compositor's alpha-blending pass.
 *
 * If the texture already exists at the requested size, returns immediately.
 * If dimensions differ, releases the old texture and creates a new one.
 * Also creates the overlay compositing pipeline (with alpha blending) if
 * it doesn't exist yet.
 *
 * Parameters:
 *   w - overlay texture width in pixels
 *   h - overlay texture height in pixels
 *
 * Returns 0 on success, -1 on failure (with diagnostic log messages).
 */
int MetalCompositorCreateOverlayTexture(int w, int h);

/*
 * Get the offscreen overlay texture as a void* for use from .cpp files.
 *
 * Returns the id<MTLTexture> cast to void*, or NULL if no overlay texture
 * has been created. The caller must bridge-cast back to id<MTLTexture>
 * in ObjC++ code that needs to use it as a render target.
 */
void *MetalCompositorGetOverlayTexture(void);

/*
 * Enable or disable 3D overlay compositing in the present pass.
 *
 * When active=1 (and an overlay texture exists), MetalCompositorPresent
 * draws the 2D framebuffer first, then alpha-blends the 3D overlay on
 * top. When active=0, only the 2D framebuffer is rendered (default).
 *
 * Parameters:
 *   active - 1 to enable overlay compositing, 0 to disable
 */
void MetalCompositorSetOverlayActive(int active);

/*
 * Throttle 3D rendering to match the compositor's VBL cadence.
 *
 * Call after committing a 3D frame (RAVE RenderEnd, GL SwapBuffers).
 * Sleeps the calling thread until the next VBL tick boundary so the
 * 3D renderer doesn't outrun the compositor's present rate. This
 * prevents wasted GPU frames and potential visual tearing on the
 * shared offscreen texture.
 *
 * Safe to call when the compositor is not initialized (returns immediately).
 */
void MetalCompositorSync3DFramePacing(void);

/*
 * Set the overlay's position and visible size within the Mac framebuffer.
 *
 * RAVE/GL 3D contexts have a specific rect within the Mac screen.
 * The overlay texture may be larger than the actual render viewport
 * (e.g. texture=640x480 but render=510x361). The compositor uses
 * (x, y, w, h) to draw only the rendered portion, so 2D content
 * outside the 3D viewport remains visible.
 *
 * Parameters:
 *   x - left edge in Mac framebuffer pixels
 *   y - top edge in Mac framebuffer pixels
 *   w - visible width (render viewport width, may be < texture width)
 *   h - visible height (render viewport height, may be < texture height)
 */
void MetalCompositorSetOverlayRect(int x, int y, int w, int h);

#ifdef __cplusplus
}
#endif

#endif /* METAL_COMPOSITOR_H */
