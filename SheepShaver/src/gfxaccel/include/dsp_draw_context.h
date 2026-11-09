/*
 *  dsp_draw_context.h - DSp context table, Reserve/Release, VBL-bounded
 *                        release queue and the per-context handlers.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  C interface. Metal objects live in the opaque DSpContextPrivate defined
 *  in dsp_draw_context.mm, so .cpp callers need no Metal headers.
 */

#ifndef DSP_DRAW_CONTEXT_H
#define DSP_DRAW_CONTEXT_H

#include <stdint.h>
#include "dsp_guest_port_storage.h"

struct DSpContextPrivate;  /* opaque; full def in dsp_draw_context.mm */

#ifdef __cplusplus
extern "C" {
#endif

/*
 *  Context table. Handles are 1-based; 0 is the NULL ref DrawSprocketLib
 *  uses. DSP_MAX_CONTEXTS is public so other TUs can walk
 *  DSpGetContext(1..DSP_MAX_CONTEXTS).
 */
#ifndef DSP_MAX_CONTEXTS
/* GetNextContext vends a distinct metadata context per step (apps such as
 * Myth II keep every ref, p.16), so a full mode walk takes modes+1 slots.
 * Stale enumeration contexts are recycled under pressure by
 * DSpAllocMetadataContextHandle. */
#define DSP_MAX_CONTEXTS 64
#endif
extern struct DSpContextPrivate *DSpGetContext(uint32_t handle);

/*
 *  enumeration_mode_index for contexts outside the GetFirst/GetNext chain
 *  (from Reserve or FindBest). GetNextContext on one returns
 *  kDSpContextNotFoundErr (DSp 1.7 p.17).
 */
#define DSP_ENUMERATION_INDEX_NONE 0xFFFFFFFFu

/*
 *  Allocate a metadata-only context for GetFirstContext/FindBestContext:
 *  ctx->attr is set from attr, but no Metal resources are created until the
 *  app calls DSpContext_Reserve.
 *
 *  enumeration_mode_index is the s_dsp_modes[] index on the GetFirst/GetNext
 *  path, so GetNextContext can advance; other callers pass
 *  DSP_ENUMERATION_INDEX_NONE.
 *
 *  Returns a 1-based handle, or 0 if the table is full (caller maps that to
 *  kDSpInternalErr).
 */
struct DSpContextAttributes;
extern uint32_t DSpAllocFirstContextHandle(
    const struct DSpContextAttributes *attr,
    uint32_t enumeration_mode_index);

/*
 *  Like DSpAllocFirstContextHandle, but when the table is full it may
 *  recycle an inactive, non-enumeration metadata context left by code that
 *  called FindBestContext and never reserved or released it. Reserved
 *  contexts and live enumeration cursors are never reclaimed.
 */
extern uint32_t DSpAllocMetadataContextHandle(
    const struct DSpContextAttributes *attr,
    uint32_t enumeration_mode_index);

/*
 *  enumeration_mode_index of a context, for dsp_mode_enumerate.cpp, which
 *  can't see DSpContextPrivate. Returns DSP_ENUMERATION_INDEX_NONE for
 *  non-enumeration contexts and for invalid refs; callers check validity
 *  with DSpGetContext.
 */
extern uint32_t DSpGetContextEnumerationIndex(uint32_t ctxRef);

/*
 *  Sub-opcode handlers.
 *
 *  Reserve (DSp 1.7 p.25) takes the existing ctxRef from FindBest or
 *  GetFirst plus a guest pointer to the desired attributes. It allocates
 *  the back buffer on that context and adopts the attributes; no new handle
 *  is created or written back.
 */
extern int32_t  DSpContext_ReserveHandler(uint32_t ctxRef,
                                          uint32_t attrAddr);
extern int32_t  DSpContext_ReleaseHandler(uint32_t ctxRef);
/* Emul-thread final shutdown; deactivates/releases live contexts and alt buffers. */
extern int32_t  DSpReleaseAllContexts(void);
extern int32_t  DSpContext_GetBackBufferHandler(uint32_t ctxRef,
                                                uint32_t options,
                                                uint32_t outBufAddr);
extern int32_t  DSpContext_SwapBuffersHandler(uint32_t ctxRef,
                                              uint32_t busyProcAddr,
                                              uint32_t userRefCon);
extern int32_t  DSpContext_SetStateHandler(uint32_t ctxRef, uint32_t state);
extern int32_t  DSpContext_GetStateHandler(uint32_t ctxRef,
                                           uint32_t outStateAddr);
extern int32_t  DSpContext_InvalBackBufferRectHandler(uint32_t ctxRef,
                                                      uint32_t rectAddr);

/* Query handlers (sub-ops 730-738, 745). */
extern int32_t  DSpContext_IsBusyHandler(uint32_t ctxRef,
                                         uint32_t outBusyAddr);
extern int32_t  DSpContext_GetDisplayIDHandler(uint32_t ctxRef,
                                               uint32_t outIDAddr);
extern int32_t  DSpContext_GetDirtyRectGridUnitsHandler(uint32_t ctxRef,
                                                        uint32_t wAddr,
                                                        uint32_t hAddr);
extern int32_t  DSpContext_GetMaxFrameRateHandler(uint32_t ctxRef,
                                                  uint32_t outAddr);
extern int32_t  DSpContext_SetMaxFrameRateHandler(uint32_t ctxRef,
                                                  uint32_t inMaxFPS);
extern int32_t  DSpContext_GetMonitorFrequencyHandler(uint32_t ctxRef,
                                                      uint32_t outFixedAddr);
extern int32_t  DSpContext_SetDirtyRectGridSizeHandler(uint32_t ctxRef,
                                                       uint32_t w,
                                                       uint32_t h);
extern int32_t  DSpContext_GetDirtyRectGridSizeHandler(uint32_t ctxRef,
                                                       uint32_t wAddr,
                                                       uint32_t hAddr);
extern int32_t  DSpContext_GetFrontBufferHandler(uint32_t ctxRef,
                                                 uint32_t outCGrafPtrAddr);
extern int32_t  DSpGetCurrentContextHandler(uint32_t displayID,
                                            uint32_t outCtxRefAddr);

/*
 *  Coordinate and mouse handlers (sub-ops 720-723). GetMouse has no
 *  context; r3 is the out Point. GlobalToLocal/LocalToGlobal are identity
 *  since the single screen sits at (0,0). FindContextFromPoint gets the
 *  Point by value, unpacked into v,h by the dispatcher.
 */
extern int32_t  DSpGetMouseHandler(uint32_t outGlobalPointAddr);
extern int32_t  DSpContext_GlobalToLocalHandler(uint32_t ctxRef,
                                                uint32_t ioPointAddr);
extern int32_t  DSpContext_LocalToGlobalHandler(uint32_t ctxRef,
                                                uint32_t ioPointAddr);
extern int32_t  DSpFindContextFromPointHandler(int16_t v, int16_t h,
                                               uint32_t outCtxRefAddr);

/*
 *  Discovery handlers (sub-ops 744, 746, 747, 760, 761).
 *  FindBestContextOnDisplayID validates the display, then runs FindBest;
 *  note the argument order (attrs, outContext, displayID).
 *  CanUserSelectContext reports whether more than one cached mode meets the
 *  request. UserSelectContext shows no dialog and picks via FindBest.
 *  SetBlankingColor and SetDebugMode take no ctxRef.
 */
extern int32_t  DSpSetDebugModeHandler(uint32_t inDebugMode);
extern int32_t  DSpCanUserSelectContextHandler(uint32_t attrAddr,
                                               uint32_t outCanAddr);
extern int32_t  DSpFindBestContextOnDisplayIDHandler(uint32_t attrAddr,
                                                     uint32_t outCtxRefAddr,
                                                     uint32_t inDisplayID);
extern int32_t  DSpUserSelectContextHandler(uint32_t attrAddr,
                                            uint32_t inDialogDisplayLocation,
                                            uint32_t inEventProc,
                                            uint32_t outCtxRefAddr);
extern int32_t  DSpSetBlankingColorHandler(uint32_t inRGBColorAddr);

/* Emit a real guest CGrafPort (PixMap and handle, portVersion 0xC000 port,
 * rect vis/clip regions) for a DSp surface. Every guest-facing DSp CGrafPtr
 * (front, back and alt buffers) must come from here, because guest code
 * uses them as real ports. seed_pixmap_mac (0 = zero-fill) seeds the PixMap
 * before the standard fields are written. Returns the port address, or 0
 * without a valid storage slot; the optional outs get the PixMap and handle
 * addresses. */
extern uint32_t DSpEmitSurfaceCGrafPort(uint32_t baseAddr_mac,
                                        uint32_t w,
                                        uint32_t h,
                                        uint32_t depth,
                                        uint32_t row_bytes,
                                        uint32_t seed_pixmap_mac,
                                        uint32_t *out_pixmap_mac,
                                        uint32_t *out_pixmap_handle_mac,
                                        uint32_t port_storage);

extern uint32_t dsp_guest_port_storage_addr;

/*
 *  AltBuffer handlers (sub-ops 700-705).
 *
 *  New (700)        : r3=ctxRef, r4=inVRAMBuffer, r5=inAttributes,
 *                     r6=outAltBuffer. NULL inAttributes makes it
 *                     underlay-capable. Backed by kHeapEngineDSp.
 *  Dispose (701)    : r3=altBuffer. Frees the backing and the record.
 *  GetCGrafPtr (702): r3=altBuffer, r4=bufferKind, r5=outCGrafPtr. Only
 *                     kDSpBufferKind_Normal; else kDSpInvalidAttributesErr.
 *  InvalRect (703)  : r3=altBuffer, r4=inInvalidRect. Clamps and unions
 *                     into the dirty rect.
 *  GetUnderlay (704): r3=ctxRef, r4=outUnderlay.
 *  SetUnderlay (705): r3=ctxRef, r4=inNewUnderlay.
 */
extern int32_t  DSpAltBuffer_NewHandler(uint32_t ctxRef,
                                        uint32_t inVRAMBuffer,
                                        uint32_t inAttributesAddr,
                                        uint32_t outAltBufferAddr);
extern int32_t  DSpAltBuffer_DisposeHandler(uint32_t altBuffer);
extern int32_t  DSpAltBuffer_GetCGrafPtrHandler(uint32_t altBuffer,
                                                uint32_t bufferKind,
                                                uint32_t outCGrafPtrAddr);
extern int32_t  DSpAltBuffer_InvalRectHandler(uint32_t altBuffer,
                                              uint32_t inInvalidRectAddr);
extern int32_t  DSpContext_GetUnderlayAltBufferHandler(uint32_t ctxRef,
                                                       uint32_t outUnderlayAddr);
extern int32_t  DSpContext_SetUnderlayAltBufferHandler(uint32_t ctxRef,
                                                       uint32_t inNewUnderlay);

/*
 *  Blit handlers (sub-ops 710-711), r3=inBlitInfo, r4=inAsyncFlag.
 *  Faster scales srcRect to dstRect with nqd_bitblt_scaled (nearest, or
 *  bilinear with Interpolation; SrcKey/DstKey color keys). Fastest is a 1:1
 *  nqd_bitblt copy.
 *
 *  NULL inBlitInfo -> kDSpInvalidAttributesErr; out-of-range baseAddr or
 *  unsupported depth -> kDSpInternalErr. Async blits run synchronously,
 *  then set completionFlag and call completionProc through call_macos1
 *  (never a raw C call).
 */
extern int32_t  DSpBlit_FasterHandler(uint32_t inBlitInfo, uint32_t inAsyncFlag);
extern int32_t  DSpBlit_FastestHandler(uint32_t inBlitInfo, uint32_t inAsyncFlag);

/*
 *  Flatten/Restore handlers (sub-ops 739-741, DSp 1.7 pp.21-23); format in
 *  dsp_engine.h.
 *
 *  GetFlattenedSize (740): r3=ctxRef, r4=outSize. Writes DSP_FLAT_SIZE.
 *  Flatten (739): r3=ctxRef, r4=outFlatContext. outFlatContext is checked
 *                 before ctxRef.
 *  Restore (741): r3=inFlatContext, r4=outRestoredContext. Creates a new
 *                 metadata context. Bad magic or version, or no matching
 *                 display, returns kDSpContextNotFoundErr (valid per p.22).
 *
 *  NULL pointers -> kDSpInvalidAttributesErr; bad ctxRef ->
 *  kDSpInvalidContextErr.
 */
extern int32_t  DSpContext_FlattenHandler(uint32_t ctxRef, uint32_t outFlatContext);
extern int32_t  DSpContext_GetFlattenedSizeHandler(uint32_t ctxRef, uint32_t outSize);
extern int32_t  DSpContext_RestoreHandler(uint32_t inFlatContext, uint32_t outRestoredContext);

/*
 *  Deferred context switch (sub-ops 742-743, DSp 1.7 pp.26-27).
 *
 *  Queue (742) : r3=parentCtx, r4=childCtx, r5=inDesiredAttributes. Both refs
 *                must resolve (else kDSpInvalidContextErr); the same-display
 *                check always passes. Applies inDesiredAttributes to the child
 *                if nonzero and records parent->queued_child.
 *  Switch (743): r3=oldCtx, r4=newCtx. Requires old->queued_child == newCtx
 *                (else kDSpInternalErr, p.27). Clears old's VBL proc,
 *                sets old Inactive and new Active, clears queued_child.
 *
 *  Emul thread only.
 */
extern int32_t  DSpContext_QueueHandler(uint32_t parentCtx, uint32_t childCtx,
                                        uint32_t inDesiredAttributes);
extern int32_t  DSpContext_SwitchHandler(uint32_t oldCtx, uint32_t newCtx);
extern void     DSpContext_SetStateSwitchHandoff(uint32_t oldCtxRef);

/*
 *  CLUT handlers (DSp 1.7 pp.56-57). Guest entries are 8-byte ColorSpecs
 *  with 16-bit big-endian channels. Pointer comes before index;
 *  inEntryCount is a count, not a last index. Conversion to the 8-bit
 *  clut_bytes happens only at the guest boundary.
 */
extern int32_t  DSpContext_SetCLUTEntriesHandler(uint32_t ctxRef,
                                                 uint32_t entriesAddr,
                                                 uint32_t inStartingEntry,
                                                 uint32_t inEntryCount);
extern int32_t  DSpContext_GetCLUTEntriesHandler(uint32_t ctxRef,
                                                 uint32_t entriesOutAddr,
                                                 uint32_t inStartingEntry,
                                                 uint32_t inEntryCount);
extern int32_t  DSpGetActiveCLUTSnapshot(uint8_t out_clut_bytes[768]);

/*
 *  Gamma fades (DSp 1.7 pp.32-35), sub-ops 402-404. FadeGamma takes a
 *  signed inPercent and an RGBColor* tint, with no duration. In/Out take a
 *  tint and fade over one second of device VBLs.
 *
 *  ctxRef == 0 fades the ambient display gamma (p.32) and returns kDSpNoErr
 *  without touching any context. The Sims calls FadeGammaOut(NULL, NULL)
 *  around Startup/Shutdown and treats an error as DSp being broken.
 */
extern int32_t  DSpContext_FadeGammaInHandler(uint32_t ctxRef,
                                              uint32_t colorAddr);
extern int32_t  DSpContext_FadeGammaOutHandler(uint32_t ctxRef,
                                               uint32_t colorAddr);
extern int32_t  DSpContext_FadeGammaHandler(uint32_t ctxRef,
                                            int32_t  inPercent,
                                            uint32_t colorAddr);

/*
 *  VBL handlers, sub-ops 500 and 503:
 *    SetVBLProc (ctxRef, procPtr, refCon)
 *    GetVBLProc (ctxRef, procOutAddr, refConOutAddr)
 */
extern int32_t  DSpContext_SetVBLProcHandler(uint32_t ctxRef,
                                             uint32_t procPtr,
                                             uint32_t refCon);
extern int32_t  DSpContext_GetVBLProcHandler(uint32_t ctxRef,
                                             uint32_t procOutAddr,
                                             uint32_t refConOutAddr);

/*
 *  DSpProcessEvent (sub-op 750, DSp 1.7 p.58). No ctxRef: r3 = EventRecord*,
 *  r4 = Boolean* out. The app passes its own event in; DSp acts on
 *  suspend/resume osEvts and reports whether it consumed the event.
 */
extern int32_t  DSpProcessEventHandler(uint32_t inEventAddr,
                                       uint32_t outProcessedAddr);

/* VBL secondary callback registered by DSpInit. Drains the release FIFO,
 * releasing each back texture before its back buffer. */
extern void     DSpVBLReleaseCallback(void *ctx, void *drawable, double ts);

/* VBL secondary callback (DSpInit/DSpShutdown): latches clut_bytes into
 * clut_bytes_latched for each context. */
extern void     DSpVBLClutLatchCallback(void *ctx, void *drawable, double ts);

/* VBL secondary callback for gamma fades: steps each fade and pushes the
 * LUT via dmc_record_gamma_change_with_lut. Registered after the CLUT latch
 * and unregistered before it. */
extern void     DSpVBLGammaFadeCallback(void *ctx, void *drawable, double ts);

/* VBL secondary callback, registered after the gamma fade and unregistered
 * before it. Increments s_dsp_vbl_count and calls each context's VBLProc
 * through call_macos3. Emul thread. */
extern void     DSpVBLServiceCallback(void *ctx, void *drawable, double ts);

/* Emul-thread background/foreground drain, run from the VBL chain. */
extern void     DSpVBLBackgroundForegroundDrain(void);

/* Pending lifecycle bits returned by DSpExchangeBgFgPending. Set with
 * fetch_or so a foreground event can't erase an undrained background one. */
enum {
	kDSpPendingBackground = 1u << 0,
	kDSpPendingForeground = 1u << 1
};

/*
 *  Run the background/foreground drain and the release-FIFO drain now, on
 *  the (main == emul) thread. Called from the UIKit lifecycle hooks because
 *  gfxaccel_handle_background_enter pauses the VBL source first. Inside the
 *  VBL chain it does nothing and leaves the bits for that tick's drain.
 */
extern void     DSpDrainLifecycleSync(void);

/* Walk the context table; emul thread only. External triggers go through
 * gfxaccel_set_dsp_*_hook. */
extern void     DSpHandleBackgroundFromEmulThread(void);
extern void     DSpHandleForegroundFromEmulThread(void);

/* Read and clear the pending kDSpPending* bits in one acquire exchange
 * (0 = none). The flag lives in dsp_engine.cpp. */
extern uint32_t DSpExchangeBgFgPending(void);

/*
 *  The single DSp play state -> DMC owner mapping, used by SetState, the
 *  background/foreground hooks and others. Returns uint32_t to keep the DMC
 *  header out of here; the value is a DMC owner enum
 *  (DSpMapStateToDMCOwnerTyped in dsp_engine_internal.h is the typed form).
 *  Invalid states return the Quiescent owner, so callers must validate
 *  first.
 */
extern uint32_t DSpMapStateToDMCOwner(uint32_t dsp_state);


#ifdef __cplusplus
}
#endif

#endif /* DSP_DRAW_CONTEXT_H */
