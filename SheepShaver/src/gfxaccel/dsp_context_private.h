/*
 *  dsp_context_private.h - Full DSpContextPrivate struct definition.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Private to gfxaccel/ because it holds ObjC Metal types; .cpp callers use
 *  the opaque forward declaration in dsp_engine.h / dsp_draw_context.h.
 */

#ifndef DSP_CONTEXT_PRIVATE_H
#define DSP_CONTEXT_PRIVATE_H

#import <Metal/Metal.h>

#include <stdint.h>
#include <stdatomic.h>

#include "dsp_front_staging_present_policy.h"

#include "dsp_engine.h"

/* All fields are emul-thread only. new DSpContextPrivate() value-initializes
 * every non-ObjC field to zero. */
struct DSpContextPrivate {
	DSpContextAttributes  attr;
	uint32_t              state;          /* DSpContextState enum value */
	uint32_t              handle;

	/* Index into s_dsp_modes[] for GetFirst/GetNextContext iteration (DSp
	 * p.17). DSP_ENUMERATION_INDEX_NONE for Reserved and FindBest contexts,
	 * which have no successor. 0 is a valid index, so every construction
	 * path must set this explicitly. */
	uint32_t              enumeration_mode_index;

	/* Shared-storage resources from DSpAllocateBackBuffer. Release the
	 * texture before the buffer. */
	id<MTLBuffer>         back_buffer;
	id<MTLTexture>        back_texture;

	/* Guest CGrafPort addresses, cached so GetBackBuffer / GetFrontBuffer
	 * return a stable pointer. */
	uint32_t              cgrafptr_mac_addr;
	uint32_t              front_cgrafptr_mac_addr;
	uint32_t              front_pixmap_mac_addr;
	uint32_t              front_pixmap_handle_mac_addr;
	uint32_t              front_staging_mac_addr;
	uint32_t              front_staging_size;
	bool                  front_staging_owned_sysheap;
	DSpFrontStagingPresentState front_staging_present_state;

	/* Union of InvalBackBufferRect calls. */
	int16_t               dirty_left, dirty_top, dirty_right, dirty_bottom;
	bool                  dirty_empty;
	bool                  dirty_cold_start;

	/* Presented damage survives encoder dirty resets until GetBackBuffer
	 * restores the underlay into the guest's actual drawing surface. */
	int32_t               underlay_restore_left, underlay_restore_top;
	int32_t               underlay_restore_right, underlay_restore_bottom;
	bool                  underlay_restore_pending;

	/* Set on the first SwapBuffers. VBL auto-publish is only for clients
	 * that never swap; left on, it can show half-drawn QuickDraw menu
	 * frames between app presents. */
	bool                  explicit_swap_observed;

	/* Bumped on every SwapBuffers. The back -> front staging refresh only
	 * runs after a new swap; otherwise it would overwrite clients that draw
	 * straight into the front buffer (The Sims 2D UI). */
	uint32_t              swap_generation;
	uint32_t              front_staging_refresh_swap_generation;
	/* Geometry of the last vended front staging. A mismatch means a mode
	 * switch changed the pitch, so refresh regardless of swap generation. */
	uint32_t              front_staging_row_bytes;
	uint32_t              front_staging_height;

	/* Guest-RAM pixel staging, used when Host2MacAddr cannot map the
	 * MTLBuffer contents (the buffer lives outside guest RAM). SwapBuffers
	 * copies staging into back_buffer before the GPU blit. 0 means the
	 * buffer is directly guest-addressable. */
	uint32_t              staging_mac_addr;
	uint32_t              staging_size;
	/* True when staging came from the Mac system heap. Such buffers are
	 * quarantined on release rather than freed, because CFM could reuse the
	 * old frame bytes as executable memory during launch transitions. */
	bool                  staging_owned_sysheap;

	/* MainDevice PixMap originals. Captured on SetState(Active); restored on
	 * Release, Paused, Inactive and DSpOnBackground. */
	uint32_t  saved_pixmap_addr;        /* PixMap struct pointer captured at SetState(Active) */
	uint32_t  saved_pixmap_baseAddr;
	uint16_t  saved_pixmap_rowBytes;
	int16_t   saved_pixmap_bounds[4];   /* top, left, bottom, right (matches QD Rect layout) */
	uint16_t  saved_pixmap_pixelType;
	uint16_t  saved_pixmap_pixelSize;
	uint16_t  saved_pixmap_cmpCount;
	uint16_t  saved_pixmap_cmpSize;
	uint16_t  saved_pixmap_pmVersion;
	uint16_t  saved_pixmap_packType;
	uint32_t  saved_pixmap_packSize;
	uint32_t  saved_pixmap_hRes;
	uint32_t  saved_pixmap_vRes;
	uint32_t  saved_pixmap_planeBytes;
	uint8_t   saved_pixmap_valid;       /* 0 = no redirect installed; 1 = redirect installed */
	uint8_t   saved_pixmap_reserved[3]; /* alignment padding */
	/* Original MainDevice gdRect, saved with the PixMap and restored by
	 * DSpRestoreMainDevicePixMap. Apps read gdRect for the display bounds. */
	uint32_t  saved_gdevice_ptr;        /* GDevice struct pointer the gdRect save came from */
	int16_t   saved_gdrect[4];          /* original gdRect: top, left, bottom, right */
	uint8_t   saved_gdrect_valid;       /* 0 = not cached; 1 = cached (restore pending) */
	uint8_t   saved_gdrect_reserved[3]; /* alignment padding */

	/* 256 x RGB. SetCLUTEntries writes clut_bytes; DSpVBLClutLatchCallback
	 * copies it to clut_bytes_latched each VBL; GetCLUTEntries reads the
	 * latched copy. */
	uint8_t               clut_bytes[768];
	uint8_t               clut_bytes_latched[768];

	/* Current gamma, re-pushed to the DMC on Paused -> Active. Updated by
	 * SetGamma, fade completion and instant FadeGamma. Planar 256 R, 256 G,
	 * 256 B, matching the DMC snapshot's gamma_lut. */
	uint8_t               gamma_lut_persisted[768];

	/* Gamma fade in progress. DSpVBLGammaFadeCallback interpolates and
	 * pushes the LUT each VBL while active != 0. The FadeGamma calls start a
	 * fade; SetGamma cancels one. */
	struct DSpFadeState {
		uint8_t           start_lut[768];
		uint8_t           end_lut[768];
		uint16_t          duration_vbls;
		uint16_t          elapsed_vbls;
		uint8_t           active;
		uint8_t           reserved[3];
	}                     fade_state;

	/* Guest TVECT from SetVBLProc (sub-op 500); 0 = none (DSp p.81).
	 * DSpVBLServiceCallback calls it as
	 * void (DSpContextReference, void *refCon, UInt32 vblCount). */
	uint32_t              vbl_proc_ptr;
	uint32_t              vbl_proc_refcon;

	/* Set when app backgrounding auto-pauses an Active context; cleared on
	 * foreground resume. An app-initiated Pause leaves it 0, so that context
	 * stays paused after foreground. */
	uint8_t               paused_by_background;

	/* DMC values snapshotted for background/foreground persistence. */
	struct {
		DSpContextAttributes attr;
		uint32_t             persisted_palette_generation;
		uint32_t             persisted_gamma_generation;
		uint32_t             invalidated_full;
	} persisted;

	/* max_frame_rate (sub-ops 734/735): app-suggested cap, 0 = none (DSp
	 * p.44). SwapBuffers uses it to stretch VBL pacing.
	 * dirty_grid_w/h (sub-ops 736/737): dirty-rect cell size, rounded up to
	 * a multiple of 32; 0 = the 32x32 default. */
	uint32_t              max_frame_rate;
	uint32_t              dirty_grid_w;
	uint32_t              dirty_grid_h;

	/* Alt-buffer handles (sub-ops 704/705), 0 = none. GetBackBuffer restores
	 * the underlay into the back buffer (DSp p.51). The overlay slot is
	 * reserved and not yet used (p.49). */
	uint32_t              underlay_alt_buffer;
	uint32_t              overlay_alt_buffer;

	/* Child context staged by DSpContext_Queue (sub-ops 742/743, DSp
	 * pp.26-27); 0 = none. Switch requires queued_child == newRef, else it
	 * fails (p.27), and clears it after switching. */
	uint32_t              queued_child;
};

/* Back-buffer size, falling back to the display size when the app did not
 * request one. */
static inline uint32_t DSpContextBackBufferWidth(const DSpContextPrivate *ctx)
{
	return ctx->attr.backBufferWidth != 0
	       ? ctx->attr.backBufferWidth
	       : ctx->attr.displayWidth;
}

static inline uint32_t DSpContextBackBufferHeight(const DSpContextPrivate *ctx)
{
	return ctx->attr.backBufferHeight != 0
	       ? ctx->attr.backBufferHeight
	       : ctx->attr.displayHeight;
}

extern "C" uint32_t DSpReserveGuestPixelStaging(uint32_t size);
extern "C" void DSpQuarantineGuestPixelStaging(uint32_t mac_addr,
                                               uint32_t size,
                                               bool allocated_from_mac_system_heap);
extern "C" void DSpDiscardUnusedGuestPixelStaging(uint32_t mac_addr,
                                                  bool allocated_from_mac_system_heap);

#endif /* DSP_CONTEXT_PRIVATE_H */
