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
 *  Every DSp back-buffer uses
 *  MTLStorageModeShared on all iOS GPU families, allocated through the
 *  bump sub-allocator on kHeapCompositor. Unified memory on
 *  A-series makes VRAM / system-memory a no-op at the performance layer;
 *  Shared gives CPU-writable semantics (the emulated app writes
 *  back-buffer bytes via the CGrafPtr) and GPU readability for the
 *  SwapBuffers blit - without the Private+Shared dual-buffer copy cost
 *  that would have been necessary on discrete-GPU devices.
 *
 *  The back buffer is never an onscreen surface. SwapBuffers copies or
 *  converts it into the video driver's canonical screen_base, which is also
 *  the surface QuickDraw and every accelerated producer observe.
 *
 *  Pixel-format mapping:
 *    8bpp  → MTLPixelFormatR8Uint       (indexed; CLUT unpack)
 *    16bpp → MTLPixelFormatR16Uint      (xRGB1555; shader unpack)
 *    32bpp → MTLPixelFormatBGRA8Unorm   (direct 32-bit)
 *  These formats only describe the offscreen back-buffer texture views.
 *
 *  Threading: all entry points run on the emul thread (PPC dispatch
 *  handler context). No explicit Metal synchronization primitives are
 *  used.
 *  The ThreadingContractTests grep gate enforces this.
 */

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

#include <cstring>
#include <unistd.h>

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "thunks.h"              /* SheepMem::Reserve */
#include "dsp_back_buffer_cgraf_policy.h"
#include "dsp_back_buffer_range.h"
#include "dsp_cgraf_port_policy.h"
#include "dsp_display_mode_policy.h"
#include "dsp_engine.h"
#include "dsp_draw_context.h"
#include "dsp_guest_address.h"
#include "dsp_pixel_staging_lifetime_policy.h"
#include "dsp_metal_renderer.h"
#include "dsp_front_buffer_policy.h"
#include "dsp_vbl_publish_policy.h"
#include "dsp_context_private.h"
#include "gfxaccel_resources.h"       /* per-buffer owner tag */
#include "gfxaccel_resources_heap.h"
#include "dsp_alt_buffer.h"
#include "nqd_accel.h"
#include "video.h"

extern uint32 Mac_sysalloc(uint32 size);
extern void Mac_sysfree(uint32 addr);
/*
 *  Pixel-format mapping.
 *  These are offscreen back-buffer formats; presentation always targets the
 *  video driver's guest-format screen memory.
 */
static inline MTLPixelFormat DSpPixelFormatForDepthBits(uint32_t depth_bits)
{
	switch (depth_bits) {
		/* 1/2/4 bpp use R8Uint + shader-unpack pattern
		 * matching metal_compositor.mm:377-380 and compositor_shaders.metal
		 * compositor_fragment_indexed (bits_per_pixel branch). */
		case 1:  return MTLPixelFormatR8Uint;       /* 1 bpp indexed; 8 px/byte, MSB-first */
		case 2:  return MTLPixelFormatR8Uint;       /* 2 bpp indexed; 4 px/byte */
		case 4:  return MTLPixelFormatR8Uint;       /* 4 bpp indexed; 2 px/byte */
		case 8:  return MTLPixelFormatR8Uint;       /* 8 bpp indexed; 1 px/byte */
		case 16: return MTLPixelFormatR16Uint;      /* xRGB1555; shader unpack */
		case 32: return (MTLPixelFormat)MTLPixelFormatBGRA8Unorm;   /* direct 32-bit */
		default: return MTLPixelFormatInvalid;
	}
}

/*
 *  Row-stride alignment: 256 bytes matches the bump allocator's
 *  alignment floor and the Metal minimum bytes-per-row for buffer-backed
 *  textures on arm64. The emulated app sees rowBytes = alignedRB, so its
 *  write index advances by alignedRB per scanline (may include up to
 *  255 bytes of padding per row - acceptable; DSp apps iterate by
 *  rowBytes, not by tightly-packed width × bpp/8).
 */
static inline uint32_t DSpAlignedRowBytes(uint32_t w, uint32_t bpp)
{
	return DSpBackBufferAlignedRowBytes(w, bpp);
}

static uint32_t DSpCreateBackBufferRectRegion(uint32_t w, uint32_t h)
{
	uint32_t region_addr = DSpReserveGuestScratch(DSP_RECT_REGION_SIZE);
	uint32_t handle_addr = DSpReserveGuestScratch(4u);
	if (region_addr == 0 || handle_addr == 0) return 0;

	Mac_memset(region_addr, 0, DSP_RECT_REGION_SIZE);
	WriteMacInt16(region_addr + DSP_REGION_OFF_SIZE, DSP_RECT_REGION_SIZE);
	WriteMacInt16(region_addr + DSP_REGION_OFF_BBOX + 0, 0);
	WriteMacInt16(region_addr + DSP_REGION_OFF_BBOX + 2, 0);
	WriteMacInt16(region_addr + DSP_REGION_OFF_BBOX + 4, (uint16_t)h);
	WriteMacInt16(region_addr + DSP_REGION_OFF_BBOX + 6, (uint16_t)w);
	WriteMacInt32(handle_addr, region_addr);
	return handle_addr;
}

/* ---------------------------------------------------------------------- *
 *  DSpAllocateBackBuffer - heap-routed MTLBuffer + MTLTexture view       *
 * ---------------------------------------------------------------------- */

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

	/* Heap-routed alloc - zero direct [device newBufferWith*] in DSp
	 * code, preserving the engine-blindness invariants. The heap
	 * ceiling check is inside the sub-allocator; NULL return here means
	 * either the heap is exhausted (eviction already ran) or allocation
	 * failed outright.
	 *
	 * Migrated from kHeapCompositor to kHeapEngineDSp.
	 * The DSp back buffer now lives in the 5th per-engine heap, which is exempt
	 * from the DMC on_mode_exit reset rule.
	 * This closes the root cause "DSp back buffer reclaimed by kHeapCompositor
	 * reset" with a single-argument change. */
	void *buf_raw = gfxaccel_resources_heap_alloc_buffer(
		kHeapEngineDSp,                                          // DSp back buffer now owns its 5th per-engine heap (kHeapDSp excluded from on_mode_exit reset)
		buffer_size,
		(uint32_t)MTLResourceStorageModeShared);
	if (buf_raw == NULL) {
		DSP_LOG("DSpAllocateBackBuffer: heap alloc failed (size=%u, %ux%u@%ubpp)",
				buffer_size, w, h, bpp);
		return false;
	}
	/* The heap API returns a retained object. Transfer it into ARC so the
	 * DSp release paths can actually drop the Metal resource before resetting
	 * the bump offset. */
	id<MTLBuffer> buf = (__bridge_transfer id<MTLBuffer>)buf_raw;
	

	/* Rule 1 bug fix: at 1/2/4 bpp we use the R8Uint shader-
	 * unpack pattern - the Metal texture is a byte-view over
	 * the packed pixel bytes, so its descriptor.width must be the packed
	 * byte count, not the logical pixel width. `(w * bpp + 7) / 8` yields
	 * 80/160/320/640 bytes-per-row at 1/2/4/8 bpp for w=640 - matches the
	 * compositor's own 2D framebuffer shader path (metal_compositor.mm:
	 * 377-380, s_framebuffer_texture_width is packed-byte width for
	 * indexed depths). At 16/32 bpp the texture is a direct view so
	 * descriptor.width == logical pixel width. The shader unpacks the
	 * byte-view into logical pixels via bit-shifts + CLUT lookup. Without
	 * this fix, newTextureWithDescriptor fails at 1/2/4 bpp because
	 * alignedRB (rounded packed-byte count) < w * bytes-per-texel for
	 * R8Uint (bytesPerRow < descriptor.width * 1). */
	NSUInteger tex_width = (NSUInteger)DSpDisplayModeTextureWidth(w, bpp);

	MTLTextureDescriptor *desc = [MTLTextureDescriptor new];
	desc.textureType = MTLTextureType2D;
	desc.pixelFormat = fmt;
	desc.width       = tex_width;
	desc.height      = h;
	desc.storageMode = MTLStorageModeShared;
	desc.usage       = MTLTextureUsageShaderRead;

	/* Texture is a VIEW over the buffer memory - no separate heap alloc.
	 * Metal requires bytesPerRow to be 16-byte aligned for buffer-backed
	 * textures; 256-byte alignedRB satisfies that trivially. */
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
	ctx->back_buffer = (__bridge_retained void*)buf;
	ctx->back_texture = (__bridge_retained void*)tex;

	/* Tag the back-buffer with the DSp
	 * engine id so ownership is explicit per-buffer (NOT DMC-implicit).
	 * The NQD conflict gate uses the DMC active-owner
	 * snapshot in the hot path; this tag is authoritative per-buffer and
	 * is consumed by test harnesses (coexistence tests) to
	 * cross-check. The compositor NEVER queries this tag -
	 * compositor-blindness is preserved. */
	gfxaccel_resources_set_buffer_owner(
		ctx->back_buffer, (uint32_t)kGfxEngineDSp);

	DSP_LOG("DSpAllocateBackBuffer: %ux%u@%ubpp alignedRB=%u size=%u",
			w, h, bpp, alignedRB, buffer_size);
	return true;
}

/* ---------------------------------------------------------------------- *
 *  DSpReleaseBackBufferNow - synchronous release, texture-first          *
 * ---------------------------------------------------------------------- */
void DSpContextPrivateReleaseBackBufferVariables(void** texture, void** buffer)
{
	id<MTLTexture> mtltexture  = (__bridge_transfer id<MTLTexture>)*texture;
	id<MTLBuffer> mtlbuffer  = (__bridge_transfer id<MTLBuffer>)*buffer;
	*texture = nil;
	*buffer  = nil;
	mtltexture = nil;
	mtlbuffer = nil;
}
void DSpContextPrivateReleaseBackBuffer(DSpContextPrivate* ctx)
{
	DSpContextPrivateReleaseBackBufferVariables(&ctx->back_texture,
												&ctx->back_buffer);
}
extern "C" void DSpReleaseBackBufferNow(DSpContextPrivate *ctx)
{
	if (ctx == nullptr) return;
	/* Clear the owner-tag BEFORE the buffer
	 * goes away so the owner map does not hold a dangling pointer. */
	if (ctx->back_buffer != nil) {
		gfxaccel_resources_clear_buffer_owner(
			ctx->back_buffer);
		gfxaccel_resources_heap_note_allocation_released(kHeapEngineDSp);
	}
	/* Texture FIRST (drops the view
	 * reference into the buffer memory), buffer SECOND. Some iOS Metal
	 * drivers assert on "Texture references buffer memory that has been
	 * deallocated" when the backing is released before a view. Matches
	 * DSpReleaseNow in dsp_draw_context.mm + the release-FIFO
	 * drain.
	 *
	 * NOTE: dsp_draw_context.mm also has its own release paths
	 * (DSpReleaseNow synchronous, DSpQueueReleaseAtVBL deferred,
	 * DSpQueueReleaseAtVBLPartial for bg survival, and the VBL drain
	 * callback). All must clear the owner tag before nil'ing the buffer. */
	DSpContextPrivateReleaseBackBuffer(ctx);
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

/* ---------------------------------------------------------------------- *
 *  DSpGetBackBufferCGrafPtr - CGrafPort emission into guest RAM          *
 * ---------------------------------------------------------------------- */

extern "C" uint32_t DSpGetBackBufferCGrafPtr(DSpContextPrivate *ctx)
{
	if (ctx == nullptr || ctx->back_buffer == nil) return 0;
	/* Stable-pointer contract: subsequent GetBackBuffer calls
	 * for the same context return the same Mac address for the lifetime
	 * of the mode. Cached on first call. */
	if (ctx->cgrafptr_mac_addr != 0) return ctx->cgrafptr_mac_addr;

	uint32_t bpp       = ctx->attr.backBufferBestDepth;
	uint32_t w         = DSpContextBackBufferWidth(ctx);
	uint32_t h         = DSpContextBackBufferHeight(ctx);
	uint32_t alignedRB = DSpAlignedRowBytes(w, bpp);

	/* baseAddr: Mac-address view of the MTLBuffer's CPU-side contents
	 * pointer. The buffer is MTLStorageModeShared so ctx->back_buffer
	 * .contents is a host VA pointer; Host2MacAddr (from
	 * include/cpu_emulation.h) wraps vm_do_get_virtual_address on real-
	 * addressing platforms and an identity cast on direct-addressing.
		 *
		 * On arm64 iOS the bump allocator lives in its own heap -
		 * NOT mapped into the emulated RAM region - so Host2MacAddr may
		 * return 0 or a nonzero address outside guest RAM for the MTLBuffer
		 * contents pointer. Fallback: reserve a Mac system-heap staging region
		 * the same size as the back-buffer and
		 * memcpy staging → back_buffer.contents in SwapBuffers before
		 * encoding the GPU blit. This preserves guest-writable CGrafPtr
		 * semantics.
	 *
	 * Raw (uint32)(uintptr_t) cast of the contents pointer is FORBIDDEN
	 * - it's undefined behaviour on arm64 iOS (64-bit host VA truncated
	 * to 32-bit Mac address). */
	uint32_t buffer_size = alignedRB * h;
	uint8_t *back_contents = (uint8_t *)((__bridge id<MTLBuffer>)ctx->back_buffer).contents;
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

	int16_t bounds_top    = 0;
	int16_t bounds_left   = 0;
	int16_t bounds_bottom = (int16_t)h;
	int16_t bounds_right  = (int16_t)w;

	/* PixMap field values per Classic Mac PixMap conventions.
	 * The behavior-preserving defaults are used; fixtures will
	 * validate against DrawSprocketLib captures.
	 *
	 * The 1/2/4 bpp indexed cases follow DSp 1.7 PDF
	 * p.36 + Inside Macintosh: Imaging With QuickDraw ch.4 PixMap layout.
	 * pixelType=0 (chunky indexed); pixelSize = bpp; cmpCount = 1
	 * (single index channel); cmpSize = bpp. */
	uint16_t pixelType, pixelSize, cmpCount, cmpSize;
	if (bpp == 1) {
		pixelType = 0;       /* chunky indexed */
		pixelSize = 1;  cmpCount = 1;  cmpSize = 1;
	} else if (bpp == 2) {
		pixelType = 0;
		pixelSize = 2;  cmpCount = 1;  cmpSize = 2;
	} else if (bpp == 4) {
		pixelType = 0;
		pixelSize = 4;  cmpCount = 1;  cmpSize = 4;
	} else if (bpp == 8) {
		pixelType = 0;
		pixelSize = 8;  cmpCount = 1;  cmpSize = 8;
	} else if (bpp == 16) {
		pixelType = 0x10;    /* RGBDirect */
		pixelSize = 16; cmpCount = 3;  cmpSize = 5;   /* xRGB1555 */
	} else { /* bpp == 32 */
		pixelType = 0x10;    /* RGBDirect */
		pixelSize = 32; cmpCount = 3;  cmpSize = 8;   /* ARGB8888 */
	}

	uint32_t pixmap_addr =
		DSpReserveGuestScratch(DSpBackBufferPixMapRecordSize());
	uint32_t pixmap_handle_addr =
		DSpReserveGuestScratch(DSpBackBufferPixMapHandleSize());
	uint32_t cgrafptr_addr =
		DSpReserveGuestScratch(DSpBackBufferCGrafPortSize());
	uint32_t vis_rgn_handle = DSpCreateBackBufferRectRegion(w, h);
	uint32_t clip_rgn_handle = DSpCreateBackBufferRectRegion(w, h);
	if (pixmap_addr == 0 || pixmap_handle_addr == 0 ||
		cgrafptr_addr == 0 || vis_rgn_handle == 0 ||
		clip_rgn_handle == 0) {
		DSP_LOG("DSpGetBackBufferCGrafPtr: guest-scratch reserve failed "
				"(pixmap=0x%08x handle=0x%08x cgraf=0x%08x "
				"vis=0x%08x clip=0x%08x)",
				pixmap_addr, pixmap_handle_addr, cgrafptr_addr,
				vis_rgn_handle, clip_rgn_handle);
		return 0;
	}

	const uint16_t row_bytes_field =
		DSpBackBufferPixMapRowBytesField(alignedRB);

	Mac_memset(pixmap_addr, 0, DSpBackBufferPixMapRecordSize());
	WriteMacInt32(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_BASEADDR,     baseAddr_mac);
	WriteMacInt16(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_ROWBYTES,     row_bytes_field);
	WriteMacInt16(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_TOP,   (uint16_t)bounds_top);
	WriteMacInt16(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_LEFT,  (uint16_t)bounds_left);
	WriteMacInt16(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_BOT,   (uint16_t)bounds_bottom);
	WriteMacInt16(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_RIGHT, (uint16_t)bounds_right);
	WriteMacInt32(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_HRES,         0x00480000u);
	WriteMacInt32(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_VRES,         0x00480000u);
	WriteMacInt16(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_PIXELTYPE,    pixelType);
	WriteMacInt16(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_PIXELSIZE,    pixelSize);
	WriteMacInt16(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_CMPCOUNT,     cmpCount);
	WriteMacInt16(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_CMPSIZE,      cmpSize);
	WriteMacInt32(pixmap_addr + DSP_MAINDEVICE_PIXMAP_OFF_PLANEBYTES,   0);

	WriteMacInt32(pixmap_handle_addr, pixmap_addr);

	Mac_memset(cgrafptr_addr, 0, DSpBackBufferCGrafPortSize());
	WriteMacInt32(cgrafptr_addr + DSP_CGRAFPORT_OFF_PORT_PIXMAP,
				  pixmap_handle_addr);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_PORT_VERSION, 0xC000);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_PORT_RECT + 0,
				  (uint16_t)bounds_top);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_PORT_RECT + 2,
				  (uint16_t)bounds_left);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_PORT_RECT + 4,
				  (uint16_t)bounds_bottom);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_PORT_RECT + 6,
				  (uint16_t)bounds_right);
	WriteMacInt32(cgrafptr_addr + DSP_CGRAFPORT_OFF_VIS_RGN,
				  vis_rgn_handle);
	WriteMacInt32(cgrafptr_addr + DSP_CGRAFPORT_OFF_CLIP_RGN,
				  clip_rgn_handle);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_RGB_FG_COLOR + 0,
				  0xffff);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_RGB_FG_COLOR + 2,
				  0xffff);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_RGB_FG_COLOR + 4,
				  0xffff);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_RGB_BK_COLOR + 0, 0);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_RGB_BK_COLOR + 2, 0);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_RGB_BK_COLOR + 4, 0);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_PN_SIZE + 0, 1);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_PN_SIZE + 2, 1);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_PN_MODE, 8);
	WriteMacInt16(cgrafptr_addr + DSP_CGRAFPORT_OFF_TX_SIZE, 12);
	WriteMacInt32(cgrafptr_addr + DSP_CGRAFPORT_OFF_FG_COLOR, 0xffffffffu);
	WriteMacInt32(cgrafptr_addr + DSP_CGRAFPORT_OFF_BK_COLOR, 0x00000000u);

	ctx->cgrafptr_mac_addr = cgrafptr_addr;
	DSP_LOG("DSpGetBackBufferCGrafPtr: ctx=%u cgrafptr=0x%08x pixmapH=0x%08x "
			"pixmap=0x%08x visRgn=0x%08x clipRgn=0x%08x baseAddr=0x%08x "
			"rbRaw=0x%04x rb=%u bpp=%u",
			ctx->handle, cgrafptr_addr, pixmap_handle_addr, pixmap_addr,
			vis_rgn_handle, clip_rgn_handle, baseAddr_mac, row_bytes_field,
			alignedRB, bpp);
	return cgrafptr_addr;
}

extern "C" int32_t DSpContext_SwapBuffersHandler(uint32_t ctxRef,
												  uint32_t busyProcAddr,
												  uint32_t userRefCon)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (ctx == nullptr) {
		DSP_LOG("SwapBuffers: invalid ctxRef=%u", ctxRef);
		return kDSpInvalidContextErr;
	}
	if (ctx->back_texture == NULL || ctx->back_buffer == NULL) {
		DSP_LOG("SwapBuffers: ctxRef=%u has no back-buffer", ctxRef);
		return kDSpInternalErr;
	}

	/* State captured at entry - revalidation rejects on CHANGE during the
	 * busyProc / frame-pacing re-entry windows, not on non-Active per se. */
	const uint32_t entry_state = ctx->state;

	/* Pre-swap busyProc gate (PDF p.39 - constraints-before-swap, NOT
	 * post-swap completion). */
	if (!DSpPollBusyProc(ctxRef, busyProcAddr, userRefCon)) {
		DSP_LOG("SwapBuffers: busyProc gate timed out (2 VBL cap); "
				"proceeding with swap");
	}
	int32_t revalidate_rc =
		DSpRevalidateSwapContext(ctxRef, ctx, entry_state, &ctx, "busyProc");
	if (revalidate_rc != kDSpNoErr) return revalidate_rc;

	/* VBL sync unless kDSpContextOption_DontSyncVBL is set. max_frame_rate
	 * multiplies the same DSp pacing lane, so a 60-fps cap on a 120-Hz
	 * display waits for two VBL periods instead of one. */
	if ((ctx->attr.contextOptions & kDSpContextOption_DontSyncVBL) == 0) {
		DSpSyncSwapFramePacing(ctxRef, ctx->max_frame_rate);
		revalidate_rc =
			DSpRevalidateSwapContext(ctxRef, ctx, entry_state, &ctx,
									 "frame pacing");
		if (revalidate_rc != kDSpNoErr) return revalidate_rc;
	}

	/* Complete any QuickDraw/NQD writes before reading the shared back
	 * buffer. A guest-RAM staging port, when present, is the app-visible copy
	 * and is folded into the same backing before the page copy. */
	NQDMetalFlush();
	if (ctx->staging_mac_addr != 0) {
		const uint32_t w = ctx->attr.displayWidth;
		const uint32_t h = ctx->attr.displayHeight;
		const uint32_t bpp = ctx->attr.backBufferBestDepth;
		const uint32_t row_bytes = (w * bpp + 7u) / 8u;
		const uint32_t aligned_row_bytes =
			(row_bytes + 255u) & ~255u;
		const uint32_t buffer_size = aligned_row_bytes * h;
		uint8_t *staging_host = Mac2HostAddr(ctx->staging_mac_addr);
		void *back_contents = ctx->back_buffer.contents;
		if (staging_host != NULL && back_contents != NULL) {
			memcpy(back_contents, staging_host, buffer_size);
		}
	}

	if (!DSpCopyBackBufferToCanonicalScreen(ctx)) {
		DSP_LOG("SwapBuffers: canonical screen publish failed "
				"(ctx=%u back=%ux%u@%u cur_mode=%d)",
				ctxRef,
				DSpContextBackBufferWidth(ctx),
				DSpContextBackBufferHeight(ctx),
				ctx->attr.backBufferBestDepth,
				cur_mode);
		return kDSpInternalErr;
	}
	ctx->dirty_empty = true;
	ctx->dirty_cold_start = false;
	ctx->dirty_left = ctx->dirty_top =
		ctx->dirty_right = ctx->dirty_bottom = 0;

	/* PDF p.39: "This function returns immediately, even if the buffer
	 * swap has not yet occurred." */
	return kDSpNoErr;
}

static inline MTLPixelFormat DSpAltPixelFormatForDepth(uint32_t depth)
{
	switch (depth) {
		case 8:  return MTLPixelFormatR8Uint;
		case 16: return MTLPixelFormatR16Uint;
		default: return (MTLPixelFormat)MTLPixelFormatBGRA8Unorm;
	}
}

/* Allocate the heap-routed depth-matched backing (MTLBuffer + texture view)
 * for an alt-buffer record. Mirrors DSpAllocateBackBuffer's heap-alloc +
 * texture-view idiom at rec->depth (set by New from the owning context;
 * persists across the background/foreground release-restore cycle). Returns
 * true on success; on failure leaves rec->backing/texture nil. */
bool DSpAllocAltBufferBacking(DSpAltBufferRecord *rec,
									 uint32_t w, uint32_t h)
{
	if (rec == nullptr || w == 0 || h == 0) return false;
	const uint32_t bpp_bytes = DSpAltBytesPerPixel(rec->depth);

	/* Bound the dimensions and compute the backing size in 64-bit so the
	 * uint32 row-bytes / buffer-size products cannot overflow (which would
	 * under-allocate for a record whose width/height are huge). The dim cap
	 * also keeps alignedRB <= 0x3FFF so the 16-bit GetCGrafPtr rowBytes write
	 * is always exact. Reject anything past the caps. */
	if (w > DSP_ALT_MAX_DIM || h > DSP_ALT_MAX_DIM) {
		DSP_LOG("DSpAllocAltBufferBacking: dims %ux%u exceed DSP_ALT_MAX_DIM=%u",
				w, h, (uint32_t)DSP_ALT_MAX_DIM);
		return false;
	}
	uint64_t row_bytes64 = (uint64_t)w * (uint64_t)bpp_bytes;
	uint64_t aligned64   = (row_bytes64 + 255u) & ~(uint64_t)255u;
	uint64_t size64      = aligned64 * (uint64_t)h;
	if (aligned64 > 0xFFFFFFFFu || size64 > DSP_ALT_MAX_BACKING_BYTES) {
		DSP_LOG("DSpAllocAltBufferBacking: backing too large (alignedRB=%llu "
				"size=%llu, %ux%u) -> reject",
				(unsigned long long)aligned64, (unsigned long long)size64, w, h);
		return false;
	}
	uint32_t alignedRB   = (uint32_t)aligned64;
	uint32_t buffer_size = (uint32_t)size64;

	void *buf_raw = gfxaccel_resources_heap_alloc_buffer(
		kHeapEngineDSp,                            /* per-engine DSp heap */
		buffer_size,
		(uint32_t)MTLResourceStorageModeShared);
	if (buf_raw == NULL) {
		DSP_LOG("DSpAllocAltBufferBacking: heap alloc failed (size=%u, %ux%u)",
				buffer_size, w, h);
		return false;
	}
	id<MTLBuffer> buf = (__bridge_transfer id<MTLBuffer>)buf_raw;

	MTLTextureDescriptor *desc = [MTLTextureDescriptor new];
	desc.textureType = MTLTextureType2D;
	desc.pixelFormat = DSpAltPixelFormatForDepth(rec->depth);
	desc.width       = (NSUInteger)w;
	desc.height      = (NSUInteger)h;
	desc.storageMode = MTLStorageModeShared;
	desc.usage       = MTLTextureUsageShaderRead;

	id<MTLTexture> tex = [buf newTextureWithDescriptor:desc
												offset:0
										   bytesPerRow:alignedRB];
	if (tex == nil) {
		DSP_LOG("DSpAllocAltBufferBacking: newTextureWithDescriptor returned nil "
				"(%ux%u alignedRB=%u)", w, h, alignedRB);
		gfxaccel_resources_heap_note_allocation_released(kHeapEngineDSp);
		return false;
	}

	rec->backing = buf;
	rec->texture = tex;
	rec->width   = w;
	rec->height  = h;

	/* Tag the backing with the DSp engine id for per-buffer ownership.
	 * The compositor never queries this tag. */
	gfxaccel_resources_set_buffer_owner((__bridge void *)buf,
										(uint32_t)kGfxEngineDSp);
	return true;
}

void* DSpGetBackingContents(void* backing)
{
	return [((__bridge id<MTLBuffer>)backing) contents];
}
