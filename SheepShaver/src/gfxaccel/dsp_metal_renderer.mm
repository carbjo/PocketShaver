/*
 *  dsp_metal_renderer.mm - Metal back-buffer allocation + blit encoder
 *                           for DSp.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Back buffers are MTLStorageModeShared buffers from the DSp resource heap:
 *  the guest writes pixels through its CGrafPtr and the GPU reads the same
 *  memory, with no Private copy. Pixel formats match the compositor's
 *  framebuffer formats, so the compositor never needs to know about DSp.
 *
 *  Emul thread only. Ordering on the single shared MTLCommandQueue is the
 *  only Metal synchronization used.
 */

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

#include <cstring>
#include <unistd.h>

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "thunks.h"
#include "dsp_back_buffer_cgraf_policy.h"
#include "dsp_back_buffer_range.h"
#include "dsp_cgraf_port_policy.h"
#include "dsp_display_mode_policy.h"
#include "dsp_engine.h"
#include "dsp_draw_context.h"
#include "dsp_front_staging_color_policy.h"
#include "dsp_guest_address.h"
#include "dsp_pixel_staging_lifetime_policy.h"
#include "dsp_metal_renderer.h"
#include "dsp_context_private.h"
#include "dsp_alt_buffer.h"
#include "gfxaccel_resources.h"
#include "gfxaccel_resources_heap.h"
#include "metal_compositor.h"
#include "metal_device_shared.h"
#include "display_mode_controller.h"

extern uint32 Mac_sysalloc(uint32 size);
extern void Mac_sysfree(uint32 addr);
/* Defined in dsp_draw_context.mm. */
extern "C" void DSpRestoreMainDevicePixMap(DSpContextPrivate *ctx);

/* DSp exposes these blocks as guest PixMap.baseAddr storage. Once exposed,
 * do not DisposePtr them: launch-time CFM/component allocations may reuse
 * the same system-heap range and execute stale frame bytes. */
enum {
	kDSpPixelStagingPoolCapacity = 16
};

/* Minimum staging allocation. Large system-heap allocations mid-game trigger
 * purge/compaction in the guest system zone: purgeable component code is
 * evicted and live blocks move under stale pointers (seen in Diablo II).
 * Allocating at least 2 MiB lets later, larger modes reuse quarantined
 * blocks. 2 MiB covers 800x600x32 with aligned rowBytes (1,996,800 bytes). */
enum : uint32_t {
	kDSpPixelStagingAllocFloor = 0x200000
};

struct DSpPixelStagingPoolBlock {
	uint32_t mac_addr;
	uint32_t size;        /* logical size of the most recent exposure */
	uint32_t alloc_size;  /* real Mac_sysalloc size; never grown. Writes
	                       * must not exceed it. */
	bool     in_use;
	bool     ever_exposed_to_guest;
	bool     allocated_from_mac_system_heap;
};

static DSpPixelStagingPoolBlock
	s_dsp_pixel_staging_pool[kDSpPixelStagingPoolCapacity];

static DSpPixelStagingPoolBlock *DSpFindPixelStagingBlock(uint32_t mac_addr)
{
	for (uint32_t i = 0; i < kDSpPixelStagingPoolCapacity; i++) {
		DSpPixelStagingPoolBlock *block = &s_dsp_pixel_staging_pool[i];
		if (block->mac_addr == mac_addr) return block;
	}
	return nullptr;
}

static DSpPixelStagingPoolBlock *DSpFindEmptyPixelStagingBlock(void)
{
	for (uint32_t i = 0; i < kDSpPixelStagingPoolCapacity; i++) {
		DSpPixelStagingPoolBlock *block = &s_dsp_pixel_staging_pool[i];
		if (block->mac_addr == 0) return block;
	}
	return nullptr;
}

/* Keep one idle floor-sized block in the pool. Fresh allocations come in
 * pairs (back staging at Reserve, front staging at the first
 * GetFrontBuffer), so allocating the spare with the first one moves the
 * second heap hit to mode-set time instead of mid-frame. */
static void DSpPrewarmPixelStagingSpare(void)
{
	for (uint32_t i = 0; i < kDSpPixelStagingPoolCapacity; i++) {
		DSpPixelStagingPoolBlock *block = &s_dsp_pixel_staging_pool[i];
		if (block->mac_addr != 0 && !block->in_use &&
		    block->alloc_size >= kDSpPixelStagingAllocFloor)
			return;
	}
	DSpPixelStagingPoolBlock *slot = DSpFindEmptyPixelStagingBlock();
	if (slot == nullptr)
		return;
	uint32_t mac_addr = Mac_sysalloc(kDSpPixelStagingAllocFloor);
	if (mac_addr == 0)
		return;
	slot->mac_addr = mac_addr;
	slot->size = 0;
	slot->alloc_size = kDSpPixelStagingAllocFloor;
	slot->in_use = false;
	slot->ever_exposed_to_guest = false;
	slot->allocated_from_mac_system_heap = true;
	DSP_LOG("DSpReserveGuestPixelStaging: prewarmed spare 0x%08x alloc=%u",
	        mac_addr, (unsigned)kDSpPixelStagingAllocFloor);
}

extern "C" uint32_t DSpReserveGuestPixelStaging(uint32_t size)
{
	if (size == 0) return 0;

	for (uint32_t i = 0; i < kDSpPixelStagingPoolCapacity; i++) {
		DSpPixelStagingPoolBlock *block = &s_dsp_pixel_staging_pool[i];
		if (block->mac_addr != 0 &&
		    !block->in_use &&
		    DSpPixelStagingCanReuseQuarantinedAllocation(block->alloc_size, size)) {
			block->in_use = true;
			block->size = size;
			DSP_LOG("DSpReserveGuestPixelStaging: reused quarantined "
			        "staging 0x%08x alloc=%u need=%u",
			        block->mac_addr, block->alloc_size, size);
			return block->mac_addr;
		}
	}

	uint32_t alloc_request = size;
	if (alloc_request < kDSpPixelStagingAllocFloor)
		alloc_request = kDSpPixelStagingAllocFloor;
	uint32_t mac_addr = Mac_sysalloc(alloc_request);
	if (mac_addr == 0 && alloc_request != size) {
		/* The floored request did not fit; try the exact size. */
		alloc_request = size;
		mac_addr = Mac_sysalloc(size);
	}
	if (mac_addr == 0) return 0;

	DSpPixelStagingPoolBlock *slot = DSpFindEmptyPixelStagingBlock();
	if (slot != nullptr) {
		slot->mac_addr = mac_addr;
		slot->size = size;
		slot->alloc_size = alloc_request;
		slot->in_use = true;
		slot->ever_exposed_to_guest = false;
		slot->allocated_from_mac_system_heap = true;
		DSP_LOG("DSpReserveGuestPixelStaging: fresh Mac_sysalloc 0x%08x alloc=%u need=%u",
		        mac_addr, alloc_request, size);
		DSpPrewarmPixelStagingSpare();
	} else {
		DSP_LOG("DSpReserveGuestPixelStaging: pool full; 0x%08x "
		        "size=%u will be quarantined untracked on release",
		        mac_addr, size);
	}
	return mac_addr;
}

extern "C" uint32_t DSpGuardStagingWrite(uint32_t mac_addr, uint32_t size,
                                         const char *site)
{
	if (mac_addr == 0 || size == 0) return size;

	DSpPixelStagingPoolBlock *block = DSpFindPixelStagingBlock(mac_addr);
	if (block == nullptr) {
		/* Untracked target; cannot bound it, so just log it. */
		DSP_LOG("DSpGuardStagingWrite: UNTRACKED staging target site=%s "
		        "addr=0x%08x size=%u (no pool entry — cannot bound)",
		        site ? site : "?", mac_addr, size);
		return size;
	}

	if (size > block->alloc_size) {
		DSP_LOG("DSpGuardStagingWrite: *** STAGING OVERRUN PREVENTED *** "
		        "site=%s addr=0x%08x requested=%u alloc=%u overrun=%u "
		        "-> CLAMPED to alloc",
		        site ? site : "?", mac_addr, size, block->alloc_size,
		        size - block->alloc_size);
		return block->alloc_size;
	}
	return size;
}

extern "C" void DSpQuarantineGuestPixelStaging(
	uint32_t mac_addr,
	uint32_t size,
	bool allocated_from_mac_system_heap)
{
	if (mac_addr == 0) return;

	DSpPixelStagingPoolBlock *block = DSpFindPixelStagingBlock(mac_addr);
	if (block != nullptr) {
		if (size > block->size) block->size = size;
		block->in_use = false;
		block->ever_exposed_to_guest = true;
		block->allocated_from_mac_system_heap =
			allocated_from_mac_system_heap;
		DSP_LOG("DSpQuarantineGuestPixelStaging: retained exposed "
		        "staging 0x%08x size=%u",
		        mac_addr, block->size);
		return;
	}

	DSpPixelStagingPoolBlock *slot = DSpFindEmptyPixelStagingBlock();
	if (slot != nullptr) {
		slot->mac_addr = mac_addr;
		slot->size = size;
		slot->alloc_size = size;   /* best guess for an untracked block */
		slot->in_use = false;
		slot->ever_exposed_to_guest = true;
		slot->allocated_from_mac_system_heap =
			allocated_from_mac_system_heap;
		DSP_LOG("DSpQuarantineGuestPixelStaging: retained untracked "
		        "exposed staging 0x%08x size=%u",
		        mac_addr, size);
		return;
	}

	if (DSpPixelStagingShouldReturnExposedAllocationToMacHeap(
	        allocated_from_mac_system_heap)) {
		Mac_sysfree(mac_addr);
		return;
	}

	DSP_LOG("DSpQuarantineGuestPixelStaging: pool full; leaving exposed "
	        "staging 0x%08x size=%u allocated",
	        mac_addr, size);
}

extern "C" void DSpDiscardUnusedGuestPixelStaging(
	uint32_t mac_addr,
	bool allocated_from_mac_system_heap)
{
	if (mac_addr == 0) return;

	DSpPixelStagingPoolBlock *block = DSpFindPixelStagingBlock(mac_addr);
	if (block != nullptr) {
		if (block->ever_exposed_to_guest) {
			block->in_use = false;
			DSP_LOG("DSpDiscardUnusedGuestPixelStaging: retained "
			        "previously exposed staging 0x%08x size=%u",
			        mac_addr, block->size);
			return;
		}
		if (block->allocated_from_mac_system_heap) {
			Mac_sysfree(mac_addr);
		}
		*block = {};
		return;
	}

	if (allocated_from_mac_system_heap) {
		Mac_sysfree(mac_addr);
	}
}

extern "C" void DSpReleaseBackBufferStaging(DSpContextPrivate *ctx)
{
	if (ctx == nullptr || ctx->staging_mac_addr == 0) return;
	DSpQuarantineGuestPixelStaging(ctx->staging_mac_addr,
	                               ctx->staging_size,
	                               ctx->staging_owned_sysheap);
	ctx->staging_mac_addr = 0;
	ctx->staging_size = 0;
	ctx->staging_owned_sysheap = false;
}

// Guest staging survives host suspension. Rebuild the Metal copy before the
// context becomes Active, without changing any cached guest port or baseAddr.
extern "C" bool DSpRestoreBackBufferPixels(DSpContextPrivate *ctx)
{
	if (ctx == nullptr || ctx->back_buffer == nil) return false;
	if (ctx->staging_mac_addr == 0) return true; // retained direct backing
	const uint64_t bytes = ctx->back_buffer.length;
	if (bytes > ctx->staging_size || bytes > UINT32_MAX ||
	    !DSpGuestRAMContains(ctx->staging_mac_addr, uint32_t(bytes), RAMBase, RAMSize))
		return false;
	void *destination = ctx->back_buffer.contents;
	if (destination == nullptr) return false;
	memcpy(destination, Mac2HostAddr(ctx->staging_mac_addr), size_t(bytes));
	return true;
}

/* Same formats as the compositor's own framebuffer textures. */
static inline MTLPixelFormat DSpPixelFormatForDepthBits(uint32_t depth_bits)
{
	switch (depth_bits) {
		/* Indexed depths are byte views unpacked in the shader. */
		case 1:  return MTLPixelFormatR8Uint;       /* 1 bpp indexed; 8 px/byte, MSB-first */
		case 2:  return MTLPixelFormatR8Uint;       /* 2 bpp indexed; 4 px/byte */
		case 4:  return MTLPixelFormatR8Uint;       /* 4 bpp indexed; 2 px/byte */
		case 8:  return MTLPixelFormatR8Uint;       /* 8 bpp indexed; 1 px/byte */
		case 16: return MTLPixelFormatR16Uint;      /* xRGB1555; shader unpack */
		case 32: return MTLPixelFormatBGRA8Unorm;   /* direct 32-bit */
		default: return MTLPixelFormatInvalid;
	}
}

/* rowBytes is padded to 256 bytes for buffer-backed textures. The guest
 * sees the padded rowBytes; DSp apps step by rowBytes, not width. */
static inline uint32_t DSpAlignedRowBytes(uint32_t w, uint32_t bpp)
{
	return DSpBackBufferAlignedRowBytes(w, bpp);
}


/* Back buffer: a Shared MTLBuffer with a texture view over it. */

extern "C" bool DSpAllocateBackBuffer(DSpContextPrivate *ctx,
                                       uint32_t w, uint32_t h, uint32_t bpp)
{
	if (ctx == nullptr || w == 0 || h == 0) return false;

	MTLPixelFormat fmt = DSpPixelFormatForDepthBits(bpp);
	if (fmt == MTLPixelFormatInvalid) {
		DSP_LOG("DSpAllocateBackBuffer: invalid pixel format for bpp=%u", bpp);
		return false;
	}

	uint32_t alignedRB   = DSpAlignedRowBytes(w, bpp);
	uint32_t buffer_size = alignedRB * h;

	/* Charged to the DSp budget. Each buffer is a separate device allocation,
	 * so freeing one never aliases in-flight GPU work. */
	void *buf_raw = gfxaccel_resources_heap_alloc_buffer(
	    kHeapEngineDSp,
	    buffer_size,
	    (uint32_t)MTLResourceStorageModeShared);
	if (buf_raw == NULL) {
		DSP_LOG("DSpAllocateBackBuffer: heap alloc failed (size=%u, %ux%u@%ubpp)",
		        buffer_size, w, h, bpp);
		return false;
	}
	/* The allocator returns a retained object. */
	id<MTLBuffer> buf = (__bridge_transfer id<MTLBuffer>)buf_raw;
	ctx->back_buffer = buf;

	/* At 1/2/4 bpp the R8Uint texture is a byte view of packed pixels, so its
	 * width is the packed byte count, (w * bpp + 7) / 8. Using pixel width
	 * would exceed bytesPerRow and fail texture creation. */
	NSUInteger tex_width = (NSUInteger)DSpDisplayModeTextureWidth(w, bpp);

	MTLTextureDescriptor *desc = [MTLTextureDescriptor new];
	desc.textureType = MTLTextureType2D;
	desc.pixelFormat = fmt;
	desc.width       = tex_width;
	desc.height      = h;
	desc.storageMode = MTLStorageModeShared;
	desc.usage       = MTLTextureUsageShaderRead;

	/* View over the buffer memory; no separate allocation. */
	id<MTLTexture> tex = [buf newTextureWithDescriptor:desc
	                                            offset:0
	                                       bytesPerRow:alignedRB];
	if (tex == nil) {
		DSP_LOG("DSpAllocateBackBuffer: newTextureWithDescriptor returned nil "
		        "(bpp=%u, alignedRB=%u)", bpp, alignedRB);
		gfxaccel_resources_heap_note_allocation_released(kHeapEngineDSp);
		ctx->back_buffer = nil;
		return false;
	}
	ctx->back_texture = tex;

	/* Per-buffer owner tag. The compositor never reads it. */
	gfxaccel_resources_set_buffer_owner(
	    (__bridge void *)ctx->back_buffer, (uint32_t)kGfxEngineDSp);

	DSP_LOG("DSpAllocateBackBuffer: %ux%u@%ubpp alignedRB=%u size=%u",
	        w, h, bpp, alignedRB, buffer_size);
	return true;
}

/* Synchronous back-buffer release. */

extern "C" void DSpReleaseBackBufferNow(DSpContextPrivate *ctx)
{
	if (ctx == nullptr) return;
	DSpRestoreMainDevicePixMap(ctx);  /* must drop the PixMap redirect before the buffer goes away */
	/* Clear the owner tag before the buffer goes away. */
	if (ctx->back_buffer != nil) {
		gfxaccel_resources_clear_buffer_owner(
		    (__bridge void *)ctx->back_buffer);
		gfxaccel_resources_heap_note_allocation_released(kHeapEngineDSp);
	}
	/* Release the texture view before its buffer; some iOS Metal drivers
	 * assert otherwise. The release paths in dsp_draw_context.mm follow the
	 * same order and must also clear the owner tag first. */
	ctx->back_texture = nil;
	ctx->back_buffer  = nil;
	DSpReleaseBackBufferStaging(ctx);
	ctx->cgrafptr_mac_addr = 0;
	if (gfxaccel_resources_heap_live_allocation_count(kHeapEngineDSp) == 0) {
		uint64_t reclaimed = gfxaccel_resources_heap_reset(kHeapEngineDSp);
		if (reclaimed > 0) {
			DSP_LOG("DSp heap reset after DSpReleaseBackBufferNow reclaimed %llu bytes",
			        (unsigned long long)reclaimed);
		}
	}
}

/*
 *  Blit the back buffer to the framebuffer. The whole buffer is copied on
 *  cold start (Reserve or foreground restore), when nothing was invalidated
 *  (DSp 1.7 p.38: no Inval means all dirty), or when the dirty rect covers
 *  over 90% of it. Otherwise only the dirty rect is copied. Dirty state is
 *  reset afterwards.
 */
static void DSpEncodeBackBufferBlit(DSpContextPrivate *ctx,
                                         id<MTLTexture> source_texture,
                                         void *encoder_raw,
                                         void *framebuffer_texture_raw)
{
	id<MTLBlitCommandEncoder> encoder =
	    (__bridge id<MTLBlitCommandEncoder>)encoder_raw;
	id<MTLTexture> framebuffer_texture =
	    (__bridge id<MTLTexture>)framebuffer_texture_raw;
	if (ctx == nullptr || encoder == nil || framebuffer_texture == nil) return;
	if (source_texture == nil) return;

	uint32_t full_w = DSpContextBackBufferWidth(ctx);
	uint32_t full_h = DSpContextBackBufferHeight(ctx);

	/* The back buffer can differ in size from the display mode (DSp 1.7
	 * p.25). Clamp to both extents; Metal validation asserts otherwise. */
	NSUInteger dst_w = framebuffer_texture.width;
	NSUInteger dst_h = framebuffer_texture.height;
	NSUInteger back_w = source_texture.width;
	NSUInteger back_h = source_texture.height;
	NSUInteger clamp_w = ((NSUInteger)full_w < dst_w) ? (NSUInteger)full_w : dst_w;
	NSUInteger clamp_h = ((NSUInteger)full_h < dst_h) ? (NSUInteger)full_h : dst_h;
	if (clamp_w > back_w) clamp_w = back_w;
	if (clamp_h > back_h) clamp_h = back_h;

	bool full_upload;
	uint32_t dw = 0, dh = 0;
	if (ctx->dirty_cold_start) {
		full_upload = true;
	} else if (ctx->dirty_empty) {
		full_upload = true;
	} else {
		dw = (uint32_t)(ctx->dirty_right  - ctx->dirty_left);
		dh = (uint32_t)(ctx->dirty_bottom - ctx->dirty_top);
		/* dirty/full > 0.9, in integer math. */
		uint64_t dirty_area = (uint64_t)dw * (uint64_t)dh;
		uint64_t full_area  = (uint64_t)full_w * (uint64_t)full_h;
		full_upload = (dirty_area * 10ULL > full_area * 9ULL);
	}

	if (full_upload) {
		[encoder copyFromTexture:source_texture
		             sourceSlice:0
		             sourceLevel:0
		            sourceOrigin:MTLOriginMake(0, 0, 0)
		              sourceSize:MTLSizeMake(clamp_w, clamp_h, 1)
		               toTexture:framebuffer_texture
		        destinationSlice:0
		        destinationLevel:0
		       destinationOrigin:MTLOriginMake(0, 0, 0)];
		DSP_VLOG("EncodeBackBufferBlit: FULL %lux%lu (cold_start=%d empty=%d)",
		         (unsigned long)clamp_w, (unsigned long)clamp_h,
		         ctx->dirty_cold_start, ctx->dirty_empty);
	} else {
		/* Clamp the sub-rect to both textures. */
		NSUInteger origin_x = (NSUInteger)ctx->dirty_left;
		NSUInteger origin_y = (NSUInteger)ctx->dirty_top;
		NSUInteger sub_w    = (NSUInteger)dw;
		NSUInteger sub_h    = (NSUInteger)dh;
		if (origin_x + sub_w > clamp_w) sub_w = (origin_x < clamp_w) ? (clamp_w - origin_x) : 0;
		if (origin_y + sub_h > clamp_h) sub_h = (origin_y < clamp_h) ? (clamp_h - origin_y) : 0;
		if (sub_w > 0 && sub_h > 0) {
			[encoder copyFromTexture:source_texture
			             sourceSlice:0
			             sourceLevel:0
			            sourceOrigin:MTLOriginMake((NSUInteger)ctx->dirty_left,
			                                        (NSUInteger)ctx->dirty_top, 0)
			              sourceSize:MTLSizeMake(sub_w, sub_h, 1)
			               toTexture:framebuffer_texture
			        destinationSlice:0
			        destinationLevel:0
			       destinationOrigin:MTLOriginMake((NSUInteger)ctx->dirty_left,
			                                        (NSUInteger)ctx->dirty_top, 0)];
		}
		DSP_VLOG("EncodeBackBufferBlit: SUB %lux%lu at (%d,%d)",
		         (unsigned long)sub_w, (unsigned long)sub_h,
		         (int)ctx->dirty_left, (int)ctx->dirty_top);
	}

	ctx->dirty_empty       = true;
	ctx->dirty_cold_start  = false;
	ctx->dirty_left = ctx->dirty_top = ctx->dirty_right = ctx->dirty_bottom = 0;
}

/* Back-buffer CGrafPort in guest RAM. */

extern "C" uint32_t DSpPrepareBackBufferGuestStorage(DSpContextPrivate *ctx)
{
	if (ctx == nullptr || ctx->back_buffer == nil) return 0;

	uint32_t bpp       = ctx->attr.backBufferBestDepth;
	uint32_t w         = DSpContextBackBufferWidth(ctx);
	uint32_t h         = DSpContextBackBufferHeight(ctx);
	uint32_t alignedRB = DSpAlignedRowBytes(w, bpp);

	/* Use the MTLBuffer contents directly if they map into guest RAM. They
	 * usually do not, since Metal memory is outside the emulated RAM. Then
	 * the guest draws into Mac system-heap staging, and SwapBuffers copies
	 * it into the buffer before the blit. Never cast the host pointer to a
	 * 32-bit Mac address. */
	uint32_t buffer_size = alignedRB * h;
	uint8_t *back_contents = (uint8_t *)ctx->back_buffer.contents;
	uint32_t mapped_addr = Host2MacAddr(back_contents);
	uint8_t *round_trip_host = mapped_addr != 0 ? Mac2HostAddr(mapped_addr) : NULL;
	uint32_t baseAddr_mac = DSpUsableDirectGuestBaseOrZero(
		mapped_addr,
		buffer_size,
		(uint32_t)RAMBase,
		(uint32_t)RAMSize,
		(uintptr_t)round_trip_host,
		(uintptr_t)back_contents);
	if (baseAddr_mac == 0) {
		DSP_LOG("DSpGetBackBufferCGrafPtr: direct base rejected "
		        "(mapped=0x%08x roundTrip=%p contents=%p size=%u)",
		        mapped_addr, round_trip_host, back_contents, buffer_size);
		if (ctx->staging_mac_addr != 0) {
			baseAddr_mac = DSpUsableGuestBaseOrZero(
				ctx->staging_mac_addr,
				buffer_size,
				(uint32_t)RAMBase,
				(uint32_t)RAMSize);
			if (baseAddr_mac == 0) {
				DSP_LOG("DSpGetBackBufferCGrafPtr: discarding unusable cached "
				        "staging baseAddr=0x%08x (size=%u)",
				        ctx->staging_mac_addr, buffer_size);
				DSpReleaseBackBufferStaging(ctx);
			}
		}
		if (baseAddr_mac == 0) {
			uint32_t staging_mac = DSpReserveGuestPixelStaging(buffer_size);
			baseAddr_mac = DSpUsableGuestBaseOrZero(
				staging_mac,
				buffer_size,
				(uint32_t)RAMBase,
				(uint32_t)RAMSize);
			if (baseAddr_mac == 0) {
				DSpDiscardUnusedGuestPixelStaging(staging_mac, true);
				DSP_LOG("DSpGetBackBufferCGrafPtr: neither Host2MacAddr nor "
				        "pixel staging allocation (%u) could vend a usable "
				        "guest-RAM baseAddr "
				        "(last=0x%08x)",
				        buffer_size, staging_mac);
				return 0;
			}
			ctx->staging_mac_addr = baseAddr_mac;
			ctx->staging_size = buffer_size;
			ctx->staging_owned_sysheap = true;
			uint32_t seed_n = DSpGuardStagingWrite(baseAddr_mac, buffer_size,
			                                       "GetBackBufferCGrafPtr.seed");
			if (back_contents != NULL) {
				Host2Mac_memcpy(baseAddr_mac, back_contents, seed_n);
			} else {
				Mac_memset(baseAddr_mac, 0, seed_n);
			}
			DSP_LOG("DSpGetBackBufferCGrafPtr: using guest-RAM staging at 0x%08x "
			        "(size=%u); initialized from back_buffer; SwapBuffers will "
			        "memcpy staging→back_buffer",
			        baseAddr_mac, buffer_size);
		}
	}

	return baseAddr_mac;
}

/* Makes no guest calls, so a caller that prepared storage off-table can
 * recheck table identity before this rewrites a retained port. */
extern "C" uint32_t DSpEmitBackBufferCGrafPtr(DSpContextPrivate *ctx,
                                              uint32_t baseAddr_mac)
{
	if (ctx == nullptr || ctx->back_buffer == nil || baseAddr_mac == 0) return 0;
	const uint32_t w = DSpContextBackBufferWidth(ctx);
	const uint32_t h = DSpContextBackBufferHeight(ctx);
	const uint32_t bpp = ctx->attr.backBufferBestDepth;
	const uint32_t alignedRB = DSpAlignedRowBytes(w, bpp);

	const uint32_t storage = DSpGuestPortStorageSlot(dsp_guest_port_storage_addr,
	    ctx->handle - 1, 2 * DSP_MAX_CONTEXTS + DSP_MAX_ALT_BUFFERS);
	ctx->cgrafptr_mac_addr = DSpEmitSurfaceCGrafPort(baseAddr_mac, w, h, bpp,
	    alignedRB, 0, nullptr, nullptr, storage);
	return ctx->cgrafptr_mac_addr;
}

extern "C" uint32_t DSpGetBackBufferCGrafPtr(DSpContextPrivate *ctx)
{
	if (ctx == nullptr || ctx->back_buffer == nil) return 0;
	if (ctx->cgrafptr_mac_addr != 0) return ctx->cgrafptr_mac_addr;
	const uint32_t base = DSpPrepareBackBufferGuestStorage(ctx);
	return DSpEmitBackBufferCGrafPtr(ctx, base);
}

/*
 *  Pixel-format-aware present. A blit cannot copy between textures of
 *  different pixel sizes (e.g. an R16Uint back buffer to a BGRA8Unorm
 *  framebuffer), so non-32bpp depths go through a render pass with an
 *  unpack shader, compiled from the inline source below on first use.
 */

static const char *kDSpUnpackShaderSource =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "\n"
    "struct DSpUnpackVertexOut {\n"
    "    float4 position [[position]];\n"
    "    float2 texCoord;\n"
    "};\n"
    "\n"
    "/* Fullscreen-triangle vertex shader (3 vertices). UV mapped with Y\n"
    " * unflipped because back_texture pixel (0,0) is top-left in Mac\n"
    " * raster order and the framebuffer texture is also top-left origin.\n"
    " * Matches the unflipped sense of [blit copyFromTexture: ... ] which\n"
    " * preserves Mac raster orientation. */\n"
    "vertex DSpUnpackVertexOut dsp_unpack_vertex(uint vid [[vertex_id]])\n"
    "{\n"
    "    DSpUnpackVertexOut out;\n"
    "    float2 pos;\n"
    "    pos.x = (vid == 1) ? 3.0 : -1.0;\n"
    "    pos.y = (vid == 2) ? 3.0 : -1.0;\n"
    "    out.position = float4(pos, 0.0, 1.0);\n"
    "    /* Mac raster: top-left origin. Metal clip-space Y points up, so\n"
    "     * Y=+1 in clip maps to V=0 (top). Unflipped Y mapping: */\n"
    "    out.texCoord.x = (pos.x + 1.0) * 0.5;\n"
    "    out.texCoord.y = 1.0 - (pos.y + 1.0) * 0.5;\n"
    "    return out;\n"
    "}\n"
    "\n"
    "/* R8Uint indexed -> BGRA8Unorm. Mirrors compositor_fragment_indexed\n"
    " * while reading DSp's per-context planar RGB CLUT directly. */\n"
    "fragment float4 dsp_unpack_fragment_indexed(\n"
    "    DSpUnpackVertexOut in [[stage_in]],\n"
    "    texture2d<uint, access::read> tex [[texture(0)]],\n"
    "    constant uchar *gamma_lut [[buffer(0)]],\n"
    "    constant uint &fade_active [[buffer(1)]],\n"
    "    constant uchar *clut_rgb [[buffer(2)]],\n"
    "    constant uint &bits_per_pixel [[buffer(3)]],\n"
    "    constant uint &pixel_width [[buffer(4)]])\n"
    "{\n"
    "    (void)fade_active;\n"
    "    uint px = uint(in.texCoord.x * float(pixel_width));\n"
    "    uint py = uint(in.texCoord.y * float(tex.get_height()));\n"
    "    px = min(px, pixel_width - 1);\n"
    "    py = min(py, tex.get_height() - 1);\n"
    "\n"
    "    uint index = 0;\n"
    "    if (bits_per_pixel == 8u) {\n"
    "        index = tex.read(uint2(px, py)).r;\n"
    "    } else if (bits_per_pixel == 4u) {\n"
    "        uint byte_val = tex.read(uint2(px / 2u, py)).r;\n"
    "        index = ((px & 1u) == 0u) ? (byte_val >> 4u) : (byte_val & 0xFu);\n"
    "    } else if (bits_per_pixel == 2u) {\n"
    "        uint byte_val = tex.read(uint2(px / 4u, py)).r;\n"
    "        uint shift = (3u - (px & 3u)) * 2u;\n"
    "        index = (byte_val >> shift) & 0x3u;\n"
    "    } else if (bits_per_pixel == 1u) {\n"
    "        uint byte_val = tex.read(uint2(px / 8u, py)).r;\n"
    "        index = (byte_val >> (7u - (px & 7u))) & 0x1u;\n"
    "    }\n"
    "\n"
    "    uint clut_offset = index * 3u;\n"
    "    float r = float(gamma_lut[clut_rgb[clut_offset + 0u]])        / 255.0;\n"
    "    float g = float(gamma_lut[256u + clut_rgb[clut_offset + 1u]]) / 255.0;\n"
    "    float b = float(gamma_lut[512u + clut_rgb[clut_offset + 2u]]) / 255.0;\n"
    "    return float4(r, g, b, 1.0);\n"
    "}\n"
    "\n"
    "fragment float4 dsp_unpack_fragment_indexed_compositor32(\n"
    "    DSpUnpackVertexOut in [[stage_in]],\n"
    "    texture2d<uint, access::read> tex [[texture(0)]],\n"
    "    constant uchar *gamma_lut [[buffer(0)]],\n"
    "    constant uint &fade_active [[buffer(1)]],\n"
    "    constant uchar *clut_rgb [[buffer(2)]],\n"
    "    constant uint &bits_per_pixel [[buffer(3)]],\n"
    "    constant uint &pixel_width [[buffer(4)]])\n"
    "{\n"
    "    (void)fade_active;\n"
    "    uint px = uint(in.texCoord.x * float(pixel_width));\n"
    "    uint py = uint(in.texCoord.y * float(tex.get_height()));\n"
    "    px = min(px, pixel_width - 1);\n"
    "    py = min(py, tex.get_height() - 1);\n"
    "\n"
    "    uint index = 0;\n"
    "    if (bits_per_pixel == 8u) {\n"
    "        index = tex.read(uint2(px, py)).r;\n"
    "    } else if (bits_per_pixel == 4u) {\n"
    "        uint byte_val = tex.read(uint2(px / 2u, py)).r;\n"
    "        index = ((px & 1u) == 0u) ? (byte_val >> 4u) : (byte_val & 0xFu);\n"
    "    } else if (bits_per_pixel == 2u) {\n"
    "        uint byte_val = tex.read(uint2(px / 4u, py)).r;\n"
    "        uint shift = (3u - (px & 3u)) * 2u;\n"
    "        index = (byte_val >> shift) & 0x3u;\n"
    "    } else if (bits_per_pixel == 1u) {\n"
    "        uint byte_val = tex.read(uint2(px / 8u, py)).r;\n"
    "        index = (byte_val >> (7u - (px & 7u))) & 0x1u;\n"
    "    }\n"
    "\n"
    "    uint clut_offset = index * 3u;\n"
    "    float r = float(gamma_lut[clut_rgb[clut_offset + 0u]])        / 255.0;\n"
    "    float g = float(gamma_lut[256u + clut_rgb[clut_offset + 1u]]) / 255.0;\n"
    "    float b = float(gamma_lut[512u + clut_rgb[clut_offset + 2u]]) / 255.0;\n"
    "    return float4(g, r, 1.0, b);\n"
    "}\n"
    "\n"
    "static inline float4 dsp_unpack_rgb555_to_rgba(\n"
    "    uint packed,\n"
    "    constant uchar *gamma_lut,\n"
    "    uint fade_active)\n"
    "{\n"
    "    (void)fade_active;\n"
    "    uint R = (packed >> 10) & 0x1F;\n"
    "    uint G = (packed >>  5) & 0x1F;\n"
    "    uint B =  packed        & 0x1F;\n"
    "    uint idx_r = (R * 255u) / 31u;\n"
    "    uint idx_g = (G * 255u) / 31u;\n"
    "    uint idx_b = (B * 255u) / 31u;\n"
    "    float r = float(gamma_lut[idx_r])        / 255.0;\n"
    "    float g = float(gamma_lut[256u + idx_g]) / 255.0;\n"
    "    float b = float(gamma_lut[512u + idx_b]) / 255.0;\n"
    "    return float4(r, g, b, 1.0);\n"
    "}\n"
    "\n"
    "static inline float4 dsp_store_for_compositor_32bpp(float4 rgba)\n"
    "{\n"
    "    /* MetalCompositorPresent's 32-bit shader treats the compositor\n"
    "     * texture as classic big-endian ARGB memory and reconstructs RGB\n"
    "     * as (s.g, s.r, s.a). Store front-staging pixels in that layout. */\n"
    "    return float4(rgba.g, rgba.r, 1.0, rgba.b);\n"
    "}\n"
    "\n"
    "/* R16Uint xRGB1555 -> BGRA8Unorm. Mirrors compositor_fragment_16bpp\n"
    " * (compositor_shaders.metal:143). The Mac stores 16-bit pixels as\n"
    " * big-endian xRGB1555, but ARM64 reads them as little-endian. */\n"
    "/* Non-visible-path twin: DSp force-resize to 32bpp routes the\n"
    " * visible pixels through compositor_fragment_32bpp via the blit fast-path;\n"
    " * this unpack pass is hit only for the rare R16Uint-back / non-BGRA\n"
    " * framebuffer case. We sample the same display-ready planar gamma_lut the\n"
    " * compositor present shaders use, for four-shader consistency. */\n"
    "fragment float4 dsp_unpack_fragment_16bpp(\n"
    "    DSpUnpackVertexOut in [[stage_in]],\n"
    "    texture2d<uint, access::read> tex [[texture(0)]],\n"
    "    constant uchar *gamma_lut [[buffer(0)]],\n"
    "    constant uint &fade_active [[buffer(1)]])\n"
    "{\n"
    "    uint w = tex.get_width();\n"
    "    uint h = tex.get_height();\n"
    "    uint px = uint(in.texCoord.x * float(w));\n"
    "    uint py = uint(in.texCoord.y * float(h));\n"
    "    px = min(px, w - 1);\n"
    "    py = min(py, h - 1);\n"
    "    uint packed = tex.read(uint2(px, py)).r;\n"
    "    /* Byte-swap big-endian -> little-endian (matches compositor\n"
    "     * shader; Mac authored xRGB1555 big-endian). */\n"
    "    packed = ((packed & 0xFF) << 8) | ((packed >> 8) & 0xFF);\n"
    "    return dsp_unpack_rgb555_to_rgba(packed, gamma_lut, fade_active);\n"
    "}\n"
    "\n"
    "/* R16Uint xRGB1555 -> BGRA8Unorm for native-order staging inputs.\n"
    " * Most Mac-authored 16-bit DSp pixels use dsp_unpack_fragment_16bpp,\n"
    " * which swaps big-endian xRGB1555 before decoding. */\n"
    "fragment float4 dsp_unpack_fragment_16bpp_native(\n"
    "    DSpUnpackVertexOut in [[stage_in]],\n"
    "    texture2d<uint, access::read> tex [[texture(0)]],\n"
    "    constant uchar *gamma_lut [[buffer(0)]],\n"
    "    constant uint &fade_active [[buffer(1)]])\n"
    "{\n"
    "    uint w = tex.get_width();\n"
    "    uint h = tex.get_height();\n"
    "    uint px = uint(in.texCoord.x * float(w));\n"
    "    uint py = uint(in.texCoord.y * float(h));\n"
    "    px = min(px, w - 1);\n"
    "    py = min(py, h - 1);\n"
    "    uint packed = tex.read(uint2(px, py)).r;\n"
    "    return dsp_unpack_rgb555_to_rgba(packed, gamma_lut, fade_active);\n"
    "}\n"
    "\n"
    "fragment float4 dsp_unpack_fragment_16bpp_compositor32(\n"
    "    DSpUnpackVertexOut in [[stage_in]],\n"
    "    texture2d<uint, access::read> tex [[texture(0)]],\n"
    "    constant uchar *gamma_lut [[buffer(0)]],\n"
    "    constant uint &fade_active [[buffer(1)]])\n"
    "{\n"
    "    uint w = tex.get_width();\n"
    "    uint h = tex.get_height();\n"
    "    uint px = uint(in.texCoord.x * float(w));\n"
    "    uint py = uint(in.texCoord.y * float(h));\n"
    "    px = min(px, w - 1);\n"
    "    py = min(py, h - 1);\n"
    "    uint packed = tex.read(uint2(px, py)).r;\n"
    "    packed = ((packed & 0xFF) << 8) | ((packed >> 8) & 0xFF);\n"
    "    return dsp_store_for_compositor_32bpp(\n"
    "        dsp_unpack_rgb555_to_rgba(packed, gamma_lut, fade_active));\n"
    "}\n"
    "\n"
    "fragment float4 dsp_unpack_fragment_16bpp_native_compositor32(\n"
    "    DSpUnpackVertexOut in [[stage_in]],\n"
    "    texture2d<uint, access::read> tex [[texture(0)]],\n"
    "    constant uchar *gamma_lut [[buffer(0)]],\n"
    "    constant uint &fade_active [[buffer(1)]])\n"
    "{\n"
    "    uint w = tex.get_width();\n"
    "    uint h = tex.get_height();\n"
    "    uint px = uint(in.texCoord.x * float(w));\n"
    "    uint py = uint(in.texCoord.y * float(h));\n"
    "    px = min(px, w - 1);\n"
    "    py = min(py, h - 1);\n"
    "    uint packed = tex.read(uint2(px, py)).r;\n"
    "    return dsp_store_for_compositor_32bpp(\n"
    "        dsp_unpack_rgb555_to_rgba(packed, gamma_lut, fade_active));\n"
    "}\n";

/* Unpack PSOs, built once. Output is BGRA8Unorm to match the compositor
 * framebuffer. */
static id<MTLRenderPipelineState> s_dsp_unpack_pso_indexed = nil;
static id<MTLRenderPipelineState> s_dsp_unpack_pso_indexed_compositor32 = nil;
static id<MTLRenderPipelineState> s_dsp_unpack_pso_16bpp = nil;
static id<MTLRenderPipelineState> s_dsp_unpack_pso_16bpp_native = nil;
static id<MTLRenderPipelineState> s_dsp_unpack_pso_16bpp_compositor32 = nil;
static id<MTLRenderPipelineState> s_dsp_unpack_pso_16bpp_native_compositor32 = nil;
static dispatch_once_t            s_dsp_unpack_pso_once = 0;
static bool                       s_dsp_unpack_pso_build_failed = false;

static id<MTLRenderPipelineState> DSpBuildUnpackPSO(id<MTLDevice> device,
                                                     id<MTLFunction> vfn,
                                                     id<MTLFunction> ffn,
                                                     const char *name)
{
	if (vfn == nil || ffn == nil) {
		DSP_LOG("DSpBuildUnpackPSOs: missing function for %s", name);
		return nil;
	}

	MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
	desc.vertexFunction   = vfn;
	desc.fragmentFunction = ffn;
	desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

	NSError *psoErr = nil;
	id<MTLRenderPipelineState> pso = [device newRenderPipelineStateWithDescriptor:desc
	                                                                        error:&psoErr];
	if (pso == nil) {
		DSP_LOG("DSpBuildUnpackPSOs: %s PSO creation failed: %s",
		        name, psoErr ? [[psoErr localizedDescription] UTF8String] : "(no error)");
	}
	return pso;
}

static void DSpBuildUnpackPSOs(void)
{
	id<MTLDevice> device = (__bridge id<MTLDevice>)SharedMetalDevice();
	if (device == nil) {
		s_dsp_unpack_pso_build_failed = true;
		DSP_LOG("DSpBuildUnpackPSOs: SharedMetalDevice returned nil");
		return;
	}

	NSError *libErr = nil;
	NSString *src = [NSString stringWithUTF8String:kDSpUnpackShaderSource];
	id<MTLLibrary> lib = [device newLibraryWithSource:src
	                                          options:nil
	                                            error:&libErr];
	if (lib == nil) {
		s_dsp_unpack_pso_build_failed = true;
		DSP_LOG("DSpBuildUnpackPSOs: newLibraryWithSource failed: %s",
		        libErr ? [[libErr localizedDescription] UTF8String] : "(no error)");
		return;
	}

	id<MTLFunction> vfn = [lib newFunctionWithName:@"dsp_unpack_vertex"];
	id<MTLFunction> indexed_ffn = [lib newFunctionWithName:@"dsp_unpack_fragment_indexed"];
	id<MTLFunction> indexed_compositor32_ffn =
	    [lib newFunctionWithName:@"dsp_unpack_fragment_indexed_compositor32"];
	id<MTLFunction> ffn_16bpp = [lib newFunctionWithName:@"dsp_unpack_fragment_16bpp"];
	id<MTLFunction> ffn_16bpp_native = [lib newFunctionWithName:@"dsp_unpack_fragment_16bpp_native"];
	id<MTLFunction> ffn_16bpp_compositor32 =
	    [lib newFunctionWithName:@"dsp_unpack_fragment_16bpp_compositor32"];
	id<MTLFunction> ffn_16bpp_native_compositor32 =
	    [lib newFunctionWithName:@"dsp_unpack_fragment_16bpp_native_compositor32"];
	if (vfn == nil) {
		s_dsp_unpack_pso_build_failed = true;
		DSP_LOG("DSpBuildUnpackPSOs: missing dsp_unpack_vertex");
		return;
	}

	s_dsp_unpack_pso_indexed = DSpBuildUnpackPSO(device, vfn, indexed_ffn, "indexed");
	s_dsp_unpack_pso_indexed_compositor32 =
	    DSpBuildUnpackPSO(device, vfn, indexed_compositor32_ffn,
	                      "indexed-compositor32");
	s_dsp_unpack_pso_16bpp   = DSpBuildUnpackPSO(device, vfn, ffn_16bpp, "16bpp");
	s_dsp_unpack_pso_16bpp_native =
	    DSpBuildUnpackPSO(device, vfn, ffn_16bpp_native, "16bpp-native");
	s_dsp_unpack_pso_16bpp_compositor32 =
	    DSpBuildUnpackPSO(device, vfn, ffn_16bpp_compositor32,
	                      "16bpp-compositor32");
	s_dsp_unpack_pso_16bpp_native_compositor32 =
	    DSpBuildUnpackPSO(device, vfn, ffn_16bpp_native_compositor32,
	                      "16bpp-native-compositor32");

	if (s_dsp_unpack_pso_indexed != nil)
		DSP_LOG("DSpBuildUnpackPSOs: indexed R8Uint->BGRA8Unorm PSO ready");
	if (s_dsp_unpack_pso_indexed_compositor32 != nil)
		DSP_LOG("DSpBuildUnpackPSOs: indexed compositor32 R8Uint->BGRA8Unorm PSO ready");
	if (s_dsp_unpack_pso_16bpp != nil)
		DSP_LOG("DSpBuildUnpackPSOs: 16bpp R16Uint->BGRA8Unorm PSO ready");
	if (s_dsp_unpack_pso_16bpp_native != nil)
		DSP_LOG("DSpBuildUnpackPSOs: 16bpp native R16Uint->BGRA8Unorm PSO ready");
	if (s_dsp_unpack_pso_16bpp_compositor32 != nil)
		DSP_LOG("DSpBuildUnpackPSOs: 16bpp compositor32 R16Uint->BGRA8Unorm PSO ready");
	if (s_dsp_unpack_pso_16bpp_native_compositor32 != nil)
		DSP_LOG("DSpBuildUnpackPSOs: 16bpp native compositor32 R16Uint->BGRA8Unorm PSO ready");
}

/*
 *  Full-screen pass that unpacks an R8Uint or R16Uint source into the
 *  BGRA8Unorm framebuffer. Used only when the formats differ. Returns false
 *  if the format pair is unsupported or no PSO is available.
 */
static bool DSpEncodeUnpackTextureRenderPass(DSpContextPrivate *ctx,
                                             id<MTLTexture> source_texture,
                                             uint32_t source_bpp,
                                             uint32_t source_pixel_width,
                                             const char *source_label,
                                             bool native_r16_order,
                                             bool use_display_gamma,
                                             bool write_compositor32_layout,
                                             id<MTLCommandBuffer> cb,
                                             id<MTLTexture> framebuffer_texture)
{
	if (ctx == nullptr || cb == nil || framebuffer_texture == nil) return false;
	if (source_texture == nil) return false;

	dispatch_once(&s_dsp_unpack_pso_once, ^{ DSpBuildUnpackPSOs(); });
	if (s_dsp_unpack_pso_build_failed) return false;

	MTLPixelFormat src_fmt = source_texture.pixelFormat;
	MTLPixelFormat dst_fmt = framebuffer_texture.pixelFormat;
	const uint32_t bpp = source_bpp;
	const bool indexed =
	    (src_fmt == MTLPixelFormatR8Uint && dst_fmt == MTLPixelFormatBGRA8Unorm &&
	     (bpp == 1 || bpp == 2 || bpp == 4 || bpp == 8));

	id<MTLRenderPipelineState> pso = nil;
	if (indexed) {
		pso = write_compositor32_layout ? s_dsp_unpack_pso_indexed_compositor32
		                                 : s_dsp_unpack_pso_indexed;
	} else if (src_fmt == MTLPixelFormatR16Uint && dst_fmt == MTLPixelFormatBGRA8Unorm) {
		if (write_compositor32_layout) {
			pso = native_r16_order ? s_dsp_unpack_pso_16bpp_native_compositor32
			                       : s_dsp_unpack_pso_16bpp_compositor32;
		} else {
			pso = native_r16_order ? s_dsp_unpack_pso_16bpp_native
			                       : s_dsp_unpack_pso_16bpp;
		}
	}
	if (pso == nil) {
		DSP_LOG("DSpEncodeUnpackRenderPass: unsupported format pair "
		        "(%s src=%lu dst=%lu bpp=%u) — present skipped to avoid "
		        "Metal-incompatible blit",
		        source_label ? source_label : "source",
		        (unsigned long)src_fmt, (unsigned long)dst_fmt, bpp);
		return false;
	}

	/* DontCare load: the fullscreen triangle writes every pixel. */
	MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
	rpd.colorAttachments[0].texture     = framebuffer_texture;
	rpd.colorAttachments[0].loadAction  = MTLLoadActionDontCare;
	rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

	id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rpd];
	if (re == nil) {
		DSP_LOG("DSpEncodeUnpackRenderPass: renderCommandEncoder returned nil");
		return false;
	}

	/* Clamp like DSpEncodeBackBufferBlit; the framebuffer can lag behind a
	 * mode switch. */
	NSUInteger back_w = indexed ? (NSUInteger)source_pixel_width
	                            : source_texture.width;
	NSUInteger back_h = source_texture.height;
	NSUInteger fb_w   = framebuffer_texture.width;
	NSUInteger fb_h   = framebuffer_texture.height;
	NSUInteger vp_w   = (back_w < fb_w) ? back_w : fb_w;
	NSUInteger vp_h   = (back_h < fb_h) ? back_h : fb_h;

	MTLViewport vp = (MTLViewport){
		.originX = 0.0, .originY = 0.0,
		.width   = (double)vp_w, .height = (double)vp_h,
		.znear   = 0.0, .zfar   = 1.0,
	};
	[re setViewport:vp];

	[re setRenderPipelineState:pso];
	[re setFragmentTexture:source_texture atIndex:0];

	/* Buffer 0 is the gamma LUT and must always be bound; the shaders read
	 * it unconditionally. Back-buffer presents use the display LUT.
	 * Front-staging overlays use identity so they match the RAVE layer in
	 * the same frame. Buffer 1 (fade_active) only keeps the binding layout
	 * stable; fades are already composed into the LUT. */
	id<MTLBuffer> gamma_buf = nil;
	if (use_display_gamma) {
		gamma_buf = (__bridge id<MTLBuffer>)MetalCompositorGetGammaLUTBuffer();
	}
	if (gamma_buf == nil) {
		gamma_buf = (__bridge id<MTLBuffer>)MetalCompositorGetGammaIdentityBuffer();
	}
	if (gamma_buf == nil) {
		DSP_LOG("DSpEncodeUnpackRenderPass: no gamma LUT buffer (compositor "
		        "uninitialized) — aborting unpack pass to avoid unbound-buffer "
		        "read; caller skips present");
		[re endEncoding];
		return false;
	}
	[re setFragmentBuffer:gamma_buf offset:0 atIndex:0];
	uint32_t fade_active = 0u;
	if (use_display_gamma) {
		const DMCModeSnapshot *snap = dmc_current_snapshot();
		fade_active = (snap && snap->fade_active) ? 1u : 0u;
	}
	fade_active = DSpUnpackShaderFadeActiveForGammaPolicy(
	    use_display_gamma,
	    fade_active != 0u);
	[re setFragmentBytes:&fade_active length:sizeof(fade_active) atIndex:1];
	if (indexed) {
		[re setFragmentBytes:ctx->clut_bytes length:768 atIndex:2];
		[re setFragmentBytes:&bpp length:sizeof(bpp) atIndex:3];
		uint32_t pixel_width = source_pixel_width;
		[re setFragmentBytes:&pixel_width length:sizeof(pixel_width) atIndex:4];
	}

	[re drawPrimitives:MTLPrimitiveTypeTriangle
	       vertexStart:0
	       vertexCount:3];
	[re endEncoding];

	if (indexed) {
		DSP_VLOG("DSpEncodeUnpackRenderPass: %s %lux%lu R8Uint indexed -> "
		         "BGRA8Unorm (bpp=%u output=%s gamma=%s shaderFade=%u "
		         "cold_start=%d empty=%d "
		         "clut0=%u,%u,%u clut1=%u,%u,%u)",
		         source_label ? source_label : "source",
		         (unsigned long)vp_w, (unsigned long)vp_h,
		         bpp, write_compositor32_layout ? "compositor32" : "normalized",
		         use_display_gamma ? "display" : "identity",
		         fade_active, ctx->dirty_cold_start, ctx->dirty_empty,
		         ctx->clut_bytes[0], ctx->clut_bytes[1], ctx->clut_bytes[2],
		         ctx->clut_bytes[3], ctx->clut_bytes[4], ctx->clut_bytes[5]);
	} else {
		DSP_VLOG("DSpEncodeUnpackRenderPass: %s %lux%lu R16Uint -> BGRA8Unorm "
		         "(bpp=%u order=%s output=%s gamma=%s shaderFade=%u "
		         "cold_start=%d empty=%d)",
		         source_label ? source_label : "source",
		         (unsigned long)vp_w, (unsigned long)vp_h,
		         bpp, native_r16_order ? "native" : "mac-be",
		         write_compositor32_layout ? "compositor32" : "normalized",
		         use_display_gamma ? "display" : "identity", fade_active,
		         ctx->dirty_cold_start, ctx->dirty_empty);
	}
	return true;
}

static bool DSpEncodeUnpackRenderPass(DSpContextPrivate *ctx,
                                       id<MTLTexture> source_texture,
                                       id<MTLCommandBuffer> cb,
                                       id<MTLTexture> framebuffer_texture)
{
	if (ctx == nullptr) return false;
	const bool write_compositor32_layout =
	    DSpBackBufferWritesCompositor32Layout();
	return DSpEncodeUnpackTextureRenderPass(ctx,
	                                        source_texture,
	                                        ctx->attr.backBufferBestDepth,
	                                        DSpContextBackBufferWidth(ctx),
	                                        "backBuffer",
	                                        false,
	                                        DSpBackBufferUnpackUsesDisplayGamma(
	                                            write_compositor32_layout),
	                                        write_compositor32_layout,
	                                        cb,
	                                        framebuffer_texture);
}

extern "C" bool DSpEncodePresentToFramebuffer(DSpContextPrivate *ctx,
                                                void *command_buffer_raw,
                                                void *framebuffer_texture_raw)
{
	id<MTLCommandBuffer> cb =
	    (__bridge id<MTLCommandBuffer>)command_buffer_raw;
	id<MTLTexture> framebuffer_texture =
	    (__bridge id<MTLTexture>)framebuffer_texture_raw;
	if (ctx == nullptr || cb == nil || framebuffer_texture == nil) return false;
	if (ctx->back_texture == nil || ctx->back_buffer == nil) return false;

	// The guest may draw again as soon as this returns, so queued Metal work
	// must sample a snapshot, not the guest-writable buffer.
	id<MTLBuffer> snapshot = [ctx->back_buffer.device
	    newBufferWithBytes:ctx->back_buffer.contents
	    length:ctx->back_buffer.length options:MTLResourceStorageModeShared];
	if (snapshot == nil) return false;
	MTLTextureDescriptor *td = [MTLTextureDescriptor
	    texture2DDescriptorWithPixelFormat:ctx->back_texture.pixelFormat
	    width:ctx->back_texture.width height:ctx->back_texture.height mipmapped:NO];
	td.storageMode = MTLStorageModeShared;
	td.usage = MTLTextureUsageShaderRead;
	id<MTLTexture> source_texture = [snapshot newTextureWithDescriptor:td offset:0
	    bytesPerRow:DSpBackBufferAlignedRowBytes(DSpContextBackBufferWidth(ctx),
	                                            ctx->attr.backBufferBestDepth)];
	if (source_texture == nil) return false;

	MTLPixelFormat src_fmt = source_texture.pixelFormat;
	MTLPixelFormat dst_fmt = framebuffer_texture.pixelFormat;

	if (src_fmt == dst_fmt) {
		/* Matching formats (32 bpp): plain dirty-rect blit. */
		id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
		if (blit == nil) {
			DSP_LOG("DSpEncodePresentToFramebuffer: blitCommandEncoder "
			        "returned nil (fast path)");
			return false;
		}
		DSpEncodeBackBufferBlit(ctx, source_texture, (__bridge void *)blit,
		                         (__bridge void *)framebuffer_texture);
		[blit endEncoding];
		return true;
	}

	bool ok = DSpEncodeUnpackRenderPass(ctx, source_texture, cb, framebuffer_texture);
	if (!ok) {
		DSP_LOG("DSpEncodePresentToFramebuffer: no compatible present path "
		        "(src=%lu dst=%lu bpp=%u)",
		        (unsigned long)src_fmt, (unsigned long)dst_fmt,
		        ctx->attr.backBufferBestDepth);
		return false;
	}

	/* Same dirty-state reset as DSpEncodeBackBufferBlit. */
	ctx->dirty_empty       = true;
	ctx->dirty_cold_start  = false;
	ctx->dirty_left = ctx->dirty_top = ctx->dirty_right = ctx->dirty_bottom = 0;
	return true;
}

extern "C" bool DSpEncodeFrontBufferStagingToFramebuffer(DSpContextPrivate *ctx,
                                                          void *command_buffer_raw,
                                                          void *framebuffer_texture_raw)
{
	id<MTLCommandBuffer> cb =
	    (__bridge id<MTLCommandBuffer>)command_buffer_raw;
	id<MTLTexture> framebuffer_texture =
	    (__bridge id<MTLTexture>)framebuffer_texture_raw;
	if (ctx == nullptr || cb == nil || framebuffer_texture == nil) return false;
	if (ctx->front_staging_mac_addr == 0 || ctx->front_staging_size == 0) return false;

	const uint32_t front_depth =
	    DSpDisplayModeDepth(ctx->attr.backBufferBestDepth,
	                        ctx->attr.displayBestDepth);
	MTLPixelFormat fmt = DSpPixelFormatForDepthBits(front_depth);
	if (fmt == MTLPixelFormatInvalid) {
		DSP_LOG("DSpEncodeFrontBufferStagingToFramebuffer: unsupported "
		        "front depth %u", front_depth);
		return false;
	}

	const uint32_t w = ctx->attr.displayWidth;
	const uint32_t h = ctx->attr.displayHeight;
	const uint32_t row_bytes =
	    DSpDisplayModePitch(w, front_depth);
	const uint32_t buffer_size = row_bytes * h;
	uint32_t baseAddr_mac = DSpUsableGuestBaseOrZero(
		ctx->front_staging_mac_addr,
		buffer_size,
		(uint32_t)RAMBase,
		(uint32_t)RAMSize);
	if (baseAddr_mac == 0 || buffer_size > ctx->front_staging_size) {
		DSP_LOG("DSpEncodeFrontBufferStagingToFramebuffer: unusable front "
		        "staging addr=0x%08x size=%u need=%u depth=%u",
		        ctx->front_staging_mac_addr, ctx->front_staging_size,
		        buffer_size, front_depth);
		return false;
	}

	uint8_t *front_host = Mac2HostAddr(baseAddr_mac);
	if (front_host == NULL) {
		DSP_LOG("DSpEncodeFrontBufferStagingToFramebuffer: Mac2HostAddr "
		        "failed for 0x%08x", baseAddr_mac);
		return false;
	}

	/* Re-encode only when the content hash changes, never on gamma changes.
	 * The front path does not apply gamma, and gamma_gen bumps every VBL
	 * during a fade, which would re-blit stale front staging over newly
	 * swapped frames. */
	const uint32_t current_hash =
	    DSpFrontStagingHashBytes(front_host, buffer_size);
	if (!DSpFrontStagingShouldEncodeHash(
	        &ctx->front_staging_present_state,
	        current_hash,
	        buffer_size)) {
		const uint32_t skips =
		    ctx->front_staging_present_state.unchanged_skips;
		if (skips <= 3 || (skips % 120u) == 0) {
			DSP_VLOG("DSpEncodeFrontBufferStagingToFramebuffer: skipped "
			         "unchanged front staging addr=0x%08x rowBytes=%u "
			         "%ux%u@%u hash=0x%08x skips=%u",
			         baseAddr_mac, row_bytes, w, h, front_depth,
			         current_hash, skips);
		}
		return true;
	}

	id<MTLDevice> device = (__bridge id<MTLDevice>)SharedMetalDevice();
	if (device == nil) {
		DSP_LOG("DSpEncodeFrontBufferStagingToFramebuffer: shared Metal "
		        "device is nil");
		return false;
	}

	id<MTLBuffer> staging_copy =
	    [device newBufferWithBytes:front_host
	                        length:buffer_size
	                       options:MTLResourceStorageModeShared];
	if (staging_copy == nil) {
		DSP_LOG("DSpEncodeFrontBufferStagingToFramebuffer: newBufferWithBytes "
		        "failed (size=%u depth=%u)", buffer_size, front_depth);
		return false;
	}

	MTLTextureDescriptor *td =
	    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
	                                                       width:DSpDisplayModeTextureWidth(w, front_depth)
	                                                      height:h
	                                                   mipmapped:NO];
	td.usage       = MTLTextureUsageShaderRead;
	td.storageMode = MTLStorageModeShared;

	id<MTLTexture> front_texture =
	    [staging_copy newTextureWithDescriptor:td
	                                    offset:0
	                               bytesPerRow:row_bytes];
	if (front_texture == nil) {
		DSP_LOG("DSpEncodeFrontBufferStagingToFramebuffer: front texture "
		        "creation failed (rowBytes=%u depth=%u)",
		        row_bytes, front_depth);
		return false;
	}

	bool ok = false;
	if (front_texture.pixelFormat == framebuffer_texture.pixelFormat) {
		NSUInteger copy_w = (NSUInteger)w;
		NSUInteger copy_h = (NSUInteger)h;
		if (copy_w > front_texture.width) copy_w = front_texture.width;
		if (copy_h > front_texture.height) copy_h = front_texture.height;
		if (copy_w > framebuffer_texture.width) copy_w = framebuffer_texture.width;
		if (copy_h > framebuffer_texture.height) copy_h = framebuffer_texture.height;

		if (copy_w > 0 && copy_h > 0) {
			id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
			if (blit != nil) {
				[blit copyFromTexture:front_texture
				           sourceSlice:0
				           sourceLevel:0
				          sourceOrigin:MTLOriginMake(0, 0, 0)
				            sourceSize:MTLSizeMake(copy_w, copy_h, 1)
				             toTexture:framebuffer_texture
				      destinationSlice:0
				      destinationLevel:0
				     destinationOrigin:MTLOriginMake(0, 0, 0)];
				[blit endEncoding];
				ok = true;
				DSP_VLOG("DSpEncodeFrontBufferStagingToFramebuffer: direct "
				         "front staging blit %lux%lu",
				         (unsigned long)copy_w, (unsigned long)copy_h);
			} else {
				DSP_VLOG("DSpEncodeFrontBufferStagingToFramebuffer: "
				         "blitCommandEncoder returned nil for direct front "
				         "staging path");
			}
		}
	} else {
		ok = DSpEncodeUnpackTextureRenderPass(ctx,
		                                      front_texture,
		                                      front_depth,
		                                      w,
		                                      "frontStaging",
		                                      DSpFrontStagingUsesNativeR16OrderInMetal(),
		                                      DSpFrontStagingUsesDisplayGamma(),
		                                      DSpFrontStagingWritesCompositor32Layout(),
		                                      cb,
		                                      framebuffer_texture);
	}
	if (ok) {
		DSpFrontStagingRememberHash(
		    &ctx->front_staging_present_state,
		    current_hash,
		    buffer_size);
		DSP_VLOG("DSpEncodeFrontBufferStagingToFramebuffer: presented "
		         "front staging addr=0x%08x rowBytes=%u %ux%u@%u "
		         "hash=0x%08x",
		         baseAddr_mac, row_bytes, w, h, front_depth, current_hash);
	}
	return ok;
}
