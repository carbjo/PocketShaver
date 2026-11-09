/*
 *  gfxaccel_resources.mm - Metal allocation implementation.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Metal side of gfxaccel_resources: per-engine overlay texture pairs, the
 *  zero-copy framebuffer MTLBuffer over emulated RAM, the buffer owner-tag
 *  map, and the background/foreground handlers.
 *
 *  The framebuffer buffer uses deallocator:nil; the emulator owns that
 *  memory, not Metal.
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <cstdint>
#include <cstdio>
#include <unistd.h>

#include "gfxaccel_resources.h"
#include "metal_device_shared.h"
#include "metal_compositor.h"
#include "display_mode_controller.h"
#include "vbl_source.h"

// ---------------------------------------------------------------------------
// File-scope Metal state
// ---------------------------------------------------------------------------

typedef struct {
	id<MTLTexture> tex[2];
	uint32_t       w;
	uint32_t       h;
	uint32_t       fmt;         // MTLPixelFormat
} GfxResOverlaySlot;

static GfxResOverlaySlot s_overlay_fleet[kGfxEngineCount] = {};

static id<MTLBuffer>  s_framebuffer_buffer    = nil;
static void          *s_framebuffer_host_base = NULL;
static uint32_t       s_framebuffer_length    = 0;

// Placeholder; never allocated yet.
static id<MTLTexture> s_depth_stencil         = nil;

static uintptr_t gfxres_page_size(void)
{
	long ps = sysconf(_SC_PAGESIZE);
	return (ps > 0) ? (uintptr_t)ps : (uintptr_t)4096;
}

static void gfxres_clear_owner_map_on_shutdown(void);

// ---------------------------------------------------------------------------
// Init / shutdown helpers (called from gfxaccel_resources.cpp)
// ---------------------------------------------------------------------------

extern "C" void gfxaccel_resources_mm_init_metal_state(void)
{
	for (uint32_t i = 0; i < (uint32_t)kGfxEngineCount; ++i) {
		s_overlay_fleet[i].tex[0] = nil;
		s_overlay_fleet[i].tex[1] = nil;
		s_overlay_fleet[i].w   = 0;
		s_overlay_fleet[i].h   = 0;
		s_overlay_fleet[i].fmt = 0;
	}

	// The framebuffer buffer is created on first request.
	s_framebuffer_buffer    = nil;
	s_framebuffer_host_base = NULL;
	s_framebuffer_length    = 0;

	s_depth_stencil = nil;
}

extern "C" void gfxaccel_resources_mm_shutdown_metal_state(void)
{
	for (uint32_t i = 0; i < (uint32_t)kGfxEngineCount; ++i) {
		s_overlay_fleet[i].tex[0] = nil;
		s_overlay_fleet[i].tex[1] = nil;
		s_overlay_fleet[i].w   = 0;
		s_overlay_fleet[i].h   = 0;
		s_overlay_fleet[i].fmt = 0;
	}

	s_framebuffer_buffer    = nil;  // does not free the emulated RAM
	s_framebuffer_host_base = NULL;
	s_framebuffer_length    = 0;

	s_depth_stencil = nil;

	// Stale pointers must not survive a restart.
	gfxres_clear_owner_map_on_shutdown();
}

// ---------------------------------------------------------------------------
// Framebuffer MTLBuffer
// ---------------------------------------------------------------------------

extern "C" void *gfxaccel_resources_get_framebuffer_buffer(void *host_base, uint32_t length)
{
	if (host_base == NULL || length == 0) {
		fprintf(stderr, "[gfxaccel_resources] get_framebuffer_buffer: invalid "
		                "host_base=%p length=%u\n", host_base, (unsigned)length);
		return NULL;
	}

	// newBufferWithBytesNoCopy asserts on unaligned pointers (16K pages).
	const uintptr_t page = gfxres_page_size();
	if (((uintptr_t)host_base & (page - 1)) != 0) {
		fprintf(stderr, "[gfxaccel_resources] get_framebuffer_buffer: "
		                "host_base=%p is NOT page-aligned (page=%lu) - "
		                "newBufferWithBytesNoCopy would assert on 16K-page "
		                "devices. Returning NULL.\n",
		        host_base, (unsigned long)page);
		return NULL;
	}

	if (s_framebuffer_buffer != nil &&
	    s_framebuffer_host_base == host_base &&
	    s_framebuffer_length == length) {
		return (__bridge void *)s_framebuffer_buffer;
	}

	s_framebuffer_buffer    = nil;
	s_framebuffer_host_base = NULL;
	s_framebuffer_length    = 0;

	id<MTLDevice> device = (__bridge id<MTLDevice>)SharedMetalDevice();
	if (device == nil) {
		fprintf(stderr, "[gfxaccel_resources] get_framebuffer_buffer: "
		                "SharedMetalDevice() returned nil\n");
		return NULL;
	}

	id<MTLBuffer> buf = [device newBufferWithBytesNoCopy:host_base
	                                              length:length
	                                             options:MTLResourceStorageModeShared
	                                         deallocator:nil];
	if (buf == nil) {
		fprintf(stderr, "[gfxaccel_resources] get_framebuffer_buffer: "
		                "newBufferWithBytesNoCopy returned nil "
		                "(host_base=%p length=%u)\n",
		        host_base, (unsigned)length);
		return NULL;
	}

	s_framebuffer_buffer    = buf;
	s_framebuffer_host_base = host_base;
	s_framebuffer_length    = length;

	return (__bridge void *)s_framebuffer_buffer;
}

// ---------------------------------------------------------------------------
// Per-engine overlay texture fleet
// ---------------------------------------------------------------------------

extern "C" void *gfxaccel_resources_vend_overlay_texture_indexed(uint32_t engine_id,
                                                                 uint32_t texture_index,
                                                                 uint32_t width,
                                                                 uint32_t height,
                                                                 uint32_t pixel_format);

extern "C" void *gfxaccel_resources_vend_overlay_texture(uint32_t engine_id,
                                                         uint32_t width,
                                                         uint32_t height,
                                                         uint32_t pixel_format)
{
	return gfxaccel_resources_vend_overlay_texture_indexed(
	    engine_id, 0, width, height, pixel_format);
}

extern "C" void *gfxaccel_resources_vend_overlay_texture_indexed(uint32_t engine_id,
                                                                 uint32_t texture_index,
                                                                 uint32_t width,
                                                                 uint32_t height,
                                                                 uint32_t pixel_format)
{
	if (engine_id >= (uint32_t)kGfxEngineCount) {
		fprintf(stderr, "[gfxaccel_resources] vend_overlay_texture_indexed: engine_id=%u "
		                "out of range (max=%u)\n",
		        (unsigned)engine_id, (unsigned)kGfxEngineCount);
		return NULL;
	}
	if (texture_index >= 2) {
		fprintf(stderr, "[gfxaccel_resources] vend_overlay_texture_indexed(engine_id=%u): "
		                "texture_index=%u out of range\n",
		        (unsigned)engine_id, (unsigned)texture_index);
		return NULL;
	}
	if (width == 0 || height == 0) {
		fprintf(stderr, "[gfxaccel_resources] vend_overlay_texture_indexed(engine_id=%u): "
		                "invalid dimensions %ux%u\n",
		        (unsigned)engine_id, (unsigned)width, (unsigned)height);
		return NULL;
	}

	GfxResOverlaySlot *slot = &s_overlay_fleet[engine_id];

	if (slot->tex[texture_index] != nil &&
	    slot->w == width &&
	    slot->h == height &&
	    slot->fmt == pixel_format) {
		return (__bridge void *)slot->tex[texture_index];
	}

	// Size/format change invalidates the pair as a unit.
	if ((slot->tex[0] != nil || slot->tex[1] != nil) &&
	    (slot->w != width || slot->h != height || slot->fmt != pixel_format)) {
		slot->tex[0] = nil;
		slot->tex[1] = nil;
		slot->w = 0;
		slot->h = 0;
		slot->fmt = 0;
	}

	id<MTLDevice> device = (__bridge id<MTLDevice>)SharedMetalDevice();
	if (device == nil) {
		fprintf(stderr, "[gfxaccel_resources] vend_overlay_texture_indexed(engine_id=%u): "
		                "SharedMetalDevice() returned nil\n",
		        (unsigned)engine_id);
		return NULL;
	}

	MTLTextureDescriptor *desc = [MTLTextureDescriptor
		texture2DDescriptorWithPixelFormat:(MTLPixelFormat)pixel_format
		                             width:(NSUInteger)width
		                            height:(NSUInteger)height
		                         mipmapped:NO];
	desc.usage       = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	desc.storageMode = MTLStorageModePrivate;

	id<MTLTexture> tex = [device newTextureWithDescriptor:desc];
	if (tex == nil) {
		fprintf(stderr, "[gfxaccel_resources] vend_overlay_texture_indexed(engine_id=%u): "
		                "newTextureWithDescriptor returned nil "
		                "(idx=%u %ux%u fmt=%u)\n",
		        (unsigned)engine_id, (unsigned)texture_index,
		        (unsigned)width, (unsigned)height, (unsigned)pixel_format);
		return NULL;
	}

	slot->tex[texture_index] = tex;
	slot->w   = width;
	slot->h   = height;
	slot->fmt = pixel_format;

	return (__bridge void *)slot->tex[texture_index];
}

extern "C" void gfxaccel_resources_release_overlay_texture(uint32_t engine_id,
                                                           void *texture)
{
	if (texture == NULL) {
		return;
	}
	if (engine_id >= (uint32_t)kGfxEngineCount) {
		fprintf(stderr, "[gfxaccel_resources] release_overlay_texture: "
		                "engine_id=%u out of range\n", (unsigned)engine_id);
		return;
	}

	GfxResOverlaySlot *slot = &s_overlay_fleet[engine_id];

	id<MTLTexture> passed = (__bridge id<MTLTexture>)texture;
	uint32_t matched_index = 2;
	if (slot->tex[0] == passed) matched_index = 0;
	if (slot->tex[1] == passed) matched_index = 1;
	if (matched_index >= 2) {
		// Not ours; leave it alone.
		fprintf(stderr, "[gfxaccel_resources] release_overlay_texture(engine_id=%u): "
		                "texture=%p does not match cached pair (%p, %p); ignoring\n",
		        (unsigned)engine_id, texture,
		        (__bridge void *)slot->tex[0],
		        (__bridge void *)slot->tex[1]);
		return;
	}

	slot->tex[matched_index] = nil;
	if (slot->tex[0] == nil && slot->tex[1] == nil) {
		slot->w   = 0;
		slot->h   = 0;
		slot->fmt = 0;
	}
}

// ---------------------------------------------------------------------------
// Per-buffer owner-tag map
//
// Records which engine owns each tagged buffer. The NQD conflict gate uses
// the DMC active owner instead; the compositor never reads this. Fixed
// 32 entries with linear scans: tagging only happens at mode changes on the
// emul thread.
// ---------------------------------------------------------------------------

#define GFXRES_OWNER_MAP_CAP 32

typedef struct {
	void    *buffer;        // NULL == free
	uint32_t engine_id;     // kGfxEngineNQD/RAVE/GL/DSp
} GfxResOwnerEntry;

static GfxResOwnerEntry s_owner_map[GFXRES_OWNER_MAP_CAP];

extern "C" void gfxaccel_resources_set_buffer_owner(void *buffer,
                                                    uint32_t engine_id)
{
	if (buffer == NULL) return;
	if (engine_id >= (uint32_t)kGfxEngineCount) {
		fprintf(stderr, "[gfxaccel_resources] set_buffer_owner: engine_id=%u "
		                "out of range (max=%u)\n",
		        (unsigned)engine_id, (unsigned)kGfxEngineCount);
		return;
	}
	for (uint32_t i = 0; i < GFXRES_OWNER_MAP_CAP; ++i) {
		if (s_owner_map[i].buffer == buffer) {
			s_owner_map[i].engine_id = engine_id;
			return;
		}
	}
	for (uint32_t i = 0; i < GFXRES_OWNER_MAP_CAP; ++i) {
		if (s_owner_map[i].buffer == NULL) {
			s_owner_map[i].buffer    = buffer;
			s_owner_map[i].engine_id = engine_id;
			return;
		}
	}
	fprintf(stderr, "[gfxaccel_resources] set_buffer_owner: owner-map "
	                "overflow (cap=%u) - increase GFXRES_OWNER_MAP_CAP. "
	                "buffer=%p engine_id=%u dropped.\n",
	        (unsigned)GFXRES_OWNER_MAP_CAP, buffer, (unsigned)engine_id);
}

extern "C" void gfxaccel_resources_clear_buffer_owner(void *buffer)
{
	if (buffer == NULL) return;
	for (uint32_t i = 0; i < GFXRES_OWNER_MAP_CAP; ++i) {
		if (s_owner_map[i].buffer == buffer) {
			s_owner_map[i].buffer    = NULL;
			s_owner_map[i].engine_id = 0;
			return;
		}
	}
}


static void gfxres_clear_owner_map_on_shutdown(void)
{
	for (uint32_t i = 0; i < GFXRES_OWNER_MAP_CAP; ++i) {
		s_owner_map[i].buffer    = NULL;
		s_owner_map[i].engine_id = 0;
	}
}

// ---------------------------------------------------------------------------
// Background/Foreground lifecycle
// ---------------------------------------------------------------------------

// Set by DSpInit.
static GfxAccelLifecycleHookFn s_dsp_background_hook     = NULL;
static void                   *s_dsp_background_hook_ctx = NULL;
static GfxAccelLifecycleHookFn s_dsp_foreground_hook     = NULL;
static void                   *s_dsp_foreground_hook_ctx = NULL;

extern "C" void gfxaccel_handle_background_enter(void)
{
	vbl_source_set_paused(1);

	// Wait for committed GPU work by committing an empty command buffer.
	// The DSp hook below relies on this before it frees back buffers.
	id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)SharedMetalCommandQueue();
	if (queue != nil) {
		id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
		if (cmdBuf != nil) {
			[cmdBuf commit];
			[cmdBuf waitUntilCompleted];
		}
	}

	// A zero drawableSize frees the drawables but keeps the layer.
	void *layerPtr = MetalCompositorGetLayer();
	if (layerPtr != NULL) {
		CAMetalLayer *layer = (__bridge CAMetalLayer *)layerPtr;
		layer.drawableSize = CGSizeZero;
	}

	if (s_dsp_background_hook != NULL) {
		s_dsp_background_hook(s_dsp_background_hook_ctx);
	}
}

extern "C" void gfxaccel_handle_foreground_enter(void)
{
	void *layerPtr = MetalCompositorGetLayer();
	if (layerPtr != NULL) {
		const struct DMCModeSnapshot *snap = dmc_current_snapshot();
		if (snap != NULL && snap->width > 0 && snap->height > 0) {
			CAMetalLayer *layer = (__bridge CAMetalLayer *)layerPtr;
			layer.drawableSize = CGSizeMake((CGFloat)snap->width,
			                                (CGFloat)snap->height);
		}
	}

	vbl_source_set_paused(0);

	if (s_dsp_foreground_hook != NULL) {
		s_dsp_foreground_hook(s_dsp_foreground_hook_ctx);
	}
}

extern "C" void gfxaccel_set_dsp_background_hook(GfxAccelLifecycleHookFn fn, void *ctx)
{
	s_dsp_background_hook     = fn;
	s_dsp_background_hook_ctx = ctx;
}

extern "C" void gfxaccel_set_dsp_foreground_hook(GfxAccelLifecycleHookFn fn, void *ctx)
{
	s_dsp_foreground_hook     = fn;
	s_dsp_foreground_hook_ctx = ctx;
}
