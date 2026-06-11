/*
 *  dsp_draw_context.h - DSp per-context private-data table + Reserve/Release
 *                        lifecycle + VBL-bounded release queue. Also covers
 *                        the GetBackBuffer / SwapBuffers / SetState / GetState /
 *                        InvalBackBufferRect handlers.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  C-callable interface. ObjC types (id<MTLBuffer>, id<MTLTexture>)
 *  live inside the opaque DSpContextPrivate struct defined in
 *  dsp_draw_context.mm; this header exposes only C-friendly decls so
 *  dsp_dispatch.cpp can call handlers without dragging in Metal headers.
 *
 *  Pattern analog: rave_metal_renderer.h (style) +
 *  rave_draw_context.mm (per-context table shape).
 */

#ifndef DSP_DRAW_CONTEXT_H
#define DSP_DRAW_CONTEXT_H

#include <stdint.h>

struct DSpContextPrivate;  /* opaque; full def in dsp_draw_context.mm */

#ifdef __cplusplus
extern "C" {
#endif

/*
 *  Context-table accessors. 1-based handles; handle 0 is the NULL sentinel
 *  DrawSprocketLib emits. Max 8 simultaneous DSp contexts (more than any
 *  classic-Mac game used).
 *
 *  DSP_MAX_CONTEXTS was previously a `#define` local to
 *  dsp_draw_context.mm. dsp_host_bridge.mm (OnBackground/OnForeground
 *  bodies) walks `DSpGetContext(i + 1)` for i in 0..DSP_MAX_CONTEXTS-1
 *  and needs the bound visible cross-TU. Hoisting the constant into the
 *  public header preserves all existing uses (the original `#define` in
 *  dsp_draw_context.mm still compiles because it's compatible with the
 *  header-visible value). Keep this name — DSp tests and other cross-TU
 *  walks (DSpVBLServiceCallback, DSpHandleBackgroundFromEmulThread, etc.)
 *  can reference this same header bound without re-defining.
 */
#ifndef DSP_MAX_CONTEXTS
#define DSP_MAX_CONTEXTS 8
#endif
extern struct DSpContextPrivate *DSpGetContext(uint32_t handle);

/*
 *  Debug session `dsp-sims-enumeration-stall` fix (2026-04-19) — sentinel
 *  value for DSpContextPrivate::enumeration_mode_index indicating "not
 *  part of the GetFirstContext/GetNextContext enumeration chain". Applies
 *  to contexts created via DSpContext_Reserve and to contexts vended by
 *  DSpFindBestContext (they represent best-match results, not cursor
 *  positions). Calling DSpGetNextContext with such a handle returns
 *  kDSpContextNotFoundErr per DSp 1.7 PDF p.17 ("last context in the
 *  list" terminator).
 *
 *  Value == UINT32_MAX; kept as a macro (not inline constant) so C-only
 *  callers and the enumerator in dsp_mode_enumerate.cpp can reference it
 *  without any C++-specific idioms.
 */
#define DSP_ENUMERATION_INDEX_NONE 0xFFFFFFFFu

/*
 *  Allocate a metadata-only DSp context handle for
 *  DSpGetFirstContext / DSpFindBestContext.
 *
 *  Unlike DSpContext_ReserveHandler this helper does NOT
 *  allocate a Metal back-buffer or texture. The emulated app gets a
 *  handle whose `attr` is the vended-mode metadata; resources are
 *  allocated lazily when the app calls DSpContext_Reserve with the
 *  inspected attributes, per the DSp 1.7 enumeration-then-reserve
 *  contract.
 *
 *  Takes a forward-declared `struct DSpContextAttributes *` (full def in
 *  dsp_engine.h — included by callers) to populate ctx->attr.
 *
 *  Debug session `dsp-sims-enumeration-stall` fix (2026-04-19) — adds the
 *  `enumeration_mode_index` arg. Callers on the GetFirstContext /
 *  GetNextContext path pass the 0-based index into s_dsp_modes[] that this
 *  metadata-only context was vended from; the value is stored on the
 *  context so DSpGetNextContextHandler can advance the cursor. Callers NOT
 *  on the enumeration path (DSpFindBestContext) pass
 *  DSP_ENUMERATION_INDEX_NONE (== 0xFFFFFFFFu) so the GetNextContext
 *  terminator-arm fires correctly.
 *
 *  On success returns a 1-based handle (>= 1); on table-full returns 0.
 *  The caller is responsible for checking for 0 and mapping to
 *  kDSpInternalErr (matches the Reserve_Core pattern).
 */
struct DSpContextAttributes;
extern uint32_t DSpAllocFirstContextHandle(
    const struct DSpContextAttributes *attr,
    uint32_t enumeration_mode_index);

/*
 *  Allocate a transient metadata-only DSp context handle.
 *
 *  This wraps DSpAllocFirstContextHandle with one compatibility fallback:
 *  if the small context table is full, it may recycle an inactive
 *  non-enumeration metadata-only handle left behind by probing code that
 *  called DSpFindBestContext but never reserved or released the result.
 *  Reserved contexts and live enumeration cursors are never reclaimed.
 */
extern uint32_t DSpAllocMetadataContextHandle(
    const struct DSpContextAttributes *attr,
    uint32_t enumeration_mode_index);

/*
 *  Debug session `dsp-sims-enumeration-stall` fix (2026-04-19) — read the
 *  enumeration_mode_index stored on a metadata-only context handle. Used
 *  by dsp_mode_enumerate.cpp's DSpGetNextContext_Core to advance the
 *  enumeration cursor without needing the full DSpContextPrivate struct
 *  definition (which imports <Metal/Metal.h> and is unusable in .cpp).
 *
 *  Returns the index (0..s_dsp_modes.size()-1) for a context on the
 *  enumeration chain, DSP_ENUMERATION_INDEX_NONE for non-enumeration
 *  contexts (Reserve / FindBest), and DSP_ENUMERATION_INDEX_NONE for
 *  invalid ctxRef (caller validates ctxRef->existence separately via
 *  DSpGetContext).
 */
extern uint32_t DSpGetContextEnumerationIndex(uint32_t ctxRef);

/*
 *  Debug session `dsp-enum-context-table-exhaustion` fix (2026-04-21) —
 *  advance an existing enumeration-cursor context to the next mode IN
 *  PLACE, reusing the same handle / slot / heap allocation. Mutates
 *  ctx->attr = *new_attr and ctx->enumeration_mode_index = new_idx.
 *
 *  Why: DSp 1.7 PDF p.17 treats the iterator reference as a *cursor* —
 *  the handle is the same across the walk; the context it refers-to
 *  advances. Pre-fix DSpGetNextContext_Core called
 *  DSpAllocFirstContextHandle on every step, heap-allocating a fresh
 *  DSpContextPrivate slot per iteration. With DSP_MAX_CONTEXTS = 8 and
 *  a 36-mode cache (loggo.txt:483 Catalyst capture), the table saturated
 *  at step 9 — well before The Sims' required 16bpp modes were visible.
 *
 *  In-place mutation consumes exactly one context slot for the lifetime
 *  of a walk, regardless of mode-cache size. Apps that want to "remember"
 *  a specific mode during the walk still work: they call
 *  DSpContext_Reserve with a copy of the attrs, which allocates a
 *  separate full context (with MTLBuffer + back-texture).
 *
 *  Returns:
 *    - kDSpNoErr on success (attr + index updated).
 *    - kDSpInvalidContextErr if ctxRef does not resolve.
 *    - kDSpInvalidAttributesErr if new_attr is NULL.
 *
 *  Threading: emul-thread single-writer, same contract as
 *  DSpAllocFirstContextHandle. No mutex. No MTLFence. No _Atomic.
 */
extern int32_t DSpAdvanceEnumerationContext(
    uint32_t ctxRef,
    const struct DSpContextAttributes *new_attr,
    uint32_t new_idx);

/*
 *  Release an inactive metadata-only DSp context handle.
 *
 *  Used by DSpGetNextContext when an enumeration cursor reaches the
 *  end-of-list terminator. The cursor has no Metal back-buffer and no
 *  game-owned resources; keeping it allocated after returning a NULL next
 *  context leaks one of the small DSp context-table slots during mode
 *  probing. Reserved/full contexts are rejected.
 */
extern int32_t DSpReleaseMetadataContextHandle(uint32_t ctxRef);

/*
 *  Public sub-opcode handlers.
 *
 *  Debug session `dsp-sims-post-reserve-black-screen` (2026-04-19) fix:
 *  DSpContext_ReserveHandler signature corrected to DSp 1.7 PDF p.25:
 *      OSStatus DSpContext_Reserve(DSpContextReference inContext,
 *                                  const DSpContextAttributesPtr inDesiredAttributes);
 *  First arg is the EXISTING ctxRef returned by FindBestContext /
 *  GetFirstContext; second arg is a Mac pointer to the desired attributes.
 *  Reserve allocates a back-buffer + back-texture ON the existing context,
 *  overriding its attributes with the desired-attributes struct. No new
 *  handle is allocated; no out-write is performed (the app already knows
 *  its own ctxRef).
 */
extern int32_t  DSpContext_ReserveHandler(uint32_t ctxRef,
                                          uint32_t attrAddr);
extern int32_t  DSpContext_ReleaseHandler(uint32_t ctxRef);
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

/*
 *  Cheap-family query handlers (sub-ops 730-738 + 745). Each reads/writes
 *  context state, a new bookkeeping field, a constant, or walks the context
 *  table; copies of the DSpContext_GetStateHandler skeleton (DSpGetContext
 *  null-guard + outAddr==0 guard + WriteMacInt* + kDSpNoErr). See
 *  dsp_draw_context.mm.
 */
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
 *  Coordinate / mouse handlers (sub-ops
 *  720-723). GetMouse has NO context param (r3 is the out-Point address);
 *  GlobalToLocal / LocalToGlobal are identity at the iOS single fullscreen
 *  origin (0,0); FindContextFromPoint takes the Point by VALUE (the v,h are
 *  unpacked in the dispatch case, NOT read from a pointer). See
 *  dsp_draw_context.mm.
 */
extern int32_t  DSpGetMouseHandler(uint32_t outGlobalPointAddr);
extern int32_t  DSpContext_GlobalToLocalHandler(uint32_t ctxRef,
                                                uint32_t ioPointAddr);
extern int32_t  DSpContext_LocalToGlobalHandler(uint32_t ctxRef,
                                                uint32_t ioPointAddr);
extern int32_t  DSpFindContextFromPointHandler(int16_t v, int16_t h,
                                               uint32_t outCtxRefAddr);

/*
 *  Discovery / multi-display handlers (sub-ops
 *  744, 746, 747, 760, 761). FindBestContextOnDisplayID validates inDisplayID
 *  then delegates to the existing FindBest matcher (3-arg ABI: attrs first,
 *  outContext second, displayID third). CanUserSelectContext writes false on
 *  the single iOS display. UserSelectContext presents no dialog and auto-picks
 *  via FindBest. SetBlankingColor / SetDebugMode have NO ctxRef. Each handler
 *  decl lands WITH its body per-export. See dsp_draw_context.mm.
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

/*
 *  AltBuffer handlers (sub-ops 700-705).
 *  Real Metal-backed implementations reusing the engine-blind
 *  gfxaccel infra with zero new concurrency primitives.
 *
 *  New (700)        : r3=ctxRef, r4=inVRAMBuffer, r5=inAttributes,
 *                     r6=outAltBuffer. NULL inAttributes => underlay-capable;
 *                     heap-backed via gfxaccel_resources_heap_alloc_buffer
 *                     (kHeapEngineDSp). Writes the new handle to outAltBuffer.
 *  Dispose (701)    : r3=altBuffer. Releases the heap backing + clears record.
 *  GetCGrafPtr (702): r3=altBuffer, r4=bufferKind, r5=outCGrafPtr. Only
 *                     kDSpBufferKind_Normal valid; else kDSpInvalidAttributesErr.
 *  InvalRect (703)  : r3=altBuffer, r4=inInvalidRect. Clamps + unions the
 *                     dirty rect (ASVS V5).
 *  GetUnderlay (704): r3=ctxRef, r4=outUnderlay. Writes ctx->underlay_alt_buffer.
 *  SetUnderlay (705): r3=ctxRef, r4=inNewUnderlay. Designates the underlay.
 *
 *  See dsp_draw_context.mm. Each handler decl lands WITH its body per-export.
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
 *  Blit handlers (sub-ops 710-711).
 *
 *  DSpBlit_Faster (710)  : r3=inBlitInfo, r4=inAsyncFlag. Scales srcRect ->
 *                          dstRect via the NEW nqd_bitblt_scaled kernel
 *                          (nearest default, bilinear when Interpolation set;
 *                          color-key per SrcKey/DstKey).
 *  DSpBlit_Fastest (711) : r3=inBlitInfo, r4=inAsyncFlag. Strict 1:1 copy via
 *                          the proven nqd_bitblt kernel.
 *
 *  Both read DSpBlitInfo via DSP_BLITINFO_OFF_*, resolve src/dst CGrafPtr +
 *  Rect, reject OOB baseAddr / unsupported depth -> kDSpInternalErr, NULL
 *  inBlitInfo -> kDSpInvalidAttributesErr. Async = synchronous-then-complete:
 *  set completionFlag + invoke completionProc via call_macos1 (PPC-trampoline,
 *  NEVER a raw C cast). ZERO new concurrency primitive. Decl lands WITH
 *  the body per-export.
 */
extern int32_t  DSpBlit_FasterHandler(uint32_t inBlitInfo, uint32_t inAsyncFlag);
extern int32_t  DSpBlit_FastestHandler(uint32_t inBlitInfo, uint32_t inAsyncFlag);

/*
 *  Save/Restore/Flatten handlers (sub-ops 739-741, PDF pp.21-23).
 *
 *  DSpContext_GetFlattenedSize (740) : r3=ctxRef, r4=outSize. Writes the
 *                          DSP_FLAT_SIZE byte count of the flattened format.
 *                          NULL outSize -> kDSpInvalidAttributesErr;
 *                          bad ctxRef -> kDSpInvalidContextErr.
 *  DSpContext_Flatten (739) : r3=ctxRef, r4=outFlatContext. Serializes the
 *                          {magic 'DSpF', version, size, DSpContextAttributes
 *                          attr, max_frame_rate, dirty_grid_w/h} subset to the
 *                          guest out-buffer via WriteMacInt*. Runtime-only
 *                          fields are NEVER serialized (Flatten is
 *                          pre-Active per PDF p.22). NULL outFlatContext ->
 *                          kDSpInvalidAttributesErr (validated BEFORE ctx
 *                          lookup); bad ctxRef -> kDSpInvalidContextErr.
 *  DSpContext_Restore (741) : r3=inFlatContext, r4=outRestoredContext. Reads +
 *                          validates magic+version, allocates a fresh metadata
 *                          context, writes its ctxRef. magic/version mismatch
 *                          or no-display-match -> kDSpContextNotFoundErr
 *                          (documented valid per PDF p.22, NOT masked). NULL
 *                          either ptr -> kDSpInvalidAttributesErr.
 *
 *  Self-consistent round-trip: Flatten then Restore reproduces
 *  the attr + max_frame_rate + dirty_grid_w/h subset. Pure RAM serialization —
 *  ZERO new concurrency primitive. Decl lands WITH the body per-export.
 */
extern int32_t  DSpContext_FlattenHandler(uint32_t ctxRef, uint32_t outFlatContext);
extern int32_t  DSpContext_GetFlattenedSizeHandler(uint32_t ctxRef, uint32_t outSize);
extern int32_t  DSpContext_RestoreHandler(uint32_t inFlatContext, uint32_t outRestoredContext);

/*
 *  Queue/Switch deferred-context-switch handlers
 *  (sub-ops 742-743, DSp 1.7 PDF pp.26-27; DSp-1.7-only exports).
 *
 *  DSpContext_Queue (742)  : r3=parentCtx, r4=childCtx, r5=inDesiredAttributes.
 *                          Resolves both ctxRefs (unresolved ->
 *                          kDSpInvalidContextErr); passes the same-display check
 *                          (trivially true on the single iOS fullscreen
 *                          display); optionally applies inDesiredAttributes to
 *                          the child when non-zero; records
 *                          parent->queued_child = childRef. Returns kDSpNoErr.
 *  DSpContext_Switch (743) : r3=oldCtx, r4=newCtx. Requires a prior Queue
 *                          (old->queued_child == newRef, else kDSpInternalErr
 *                          per PDF p.27 "returns an error"); kills the OLD
 *                          context's piggyback VBL proc (old->vbl_proc_ptr = 0 —
 *                          the VBL service walk early-outs on ==0); deactivates
 *                          OLD through SetState(Inactive); activates NEW through
 *                          SetState(Active); clears old->queued_child.
 *
 *  queued_child is a RAM-only single-writer emul-thread field — ZERO new
 *  concurrency primitive. Decl lands WITH the body per-export.
 */
extern int32_t  DSpContext_QueueHandler(uint32_t parentCtx, uint32_t childCtx,
                                        uint32_t inDesiredAttributes);
extern int32_t  DSpContext_SwitchHandler(uint32_t oldCtx, uint32_t newCtx);
extern void     DSpContext_SetStateSwitchHandoff(uint32_t oldCtxRef);

/*
 *  CLUT handlers.
 *
 *  The DSp 1.7 pp.56-57 wire-format —
 *  8-byte ColorSpec / 16-bit big-endian channels, pointer-before-index arg
 *  order (entriesAddr, inStartingEntry, inEntryCount); inEntryCount is a
 *  COUNT, not an inclusive last index. The 16<->8 conversion is confined
 *  to the guest-RAM boundary; internal clut_bytes storage stays 8-bit.
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
 *  Gamma + Fade handlers.
 *
 *  Argument layout per dsp_dispatch.cpp r4..r7 marshalling:
 *    SetGamma     (ctxRef, tableAddr)                    — sub-opcode 400
 *    GetGamma     (ctxRef, tableOutAddr)                 — sub-opcode 401
 *    FadeGammaIn  (ctxRef, durationVbls)                 — sub-opcode 402
 *    FadeGammaOut (ctxRef, durationVbls)                 — sub-opcode 403
 *    FadeGamma    (ctxRef, percent, durationVbls, colorAddr) — sub-opcode 404
 *
 *  Debug session `dsp-sims-post-reserve-black-screen` (2026-04-19) fix:
 *  FadeGammaIn / FadeGammaOut / FadeGamma now accept ctxRef == 0 as the
 *  DSp 1.7 PDF p.32 "ambient display gamma" no-op, returning kDSpNoErr
 *  without mutating any per-context state. Real Mac apps (including The
 *  Sims) use `DSpContext_FadeGammaOut(NULL, NULL)` during Startup +
 *  Shutdown to fade the system-wide gamma before/after their own Reserved
 *  context is active. Rejecting NULL ctxRef produced kDSpInvalidContextErr
 *  and poisoned The Sims's internal "DSp healthy" flag.
 */
extern int32_t  DSpContext_SetGammaHandler(uint32_t ctxRef,
                                           uint32_t tableAddr);
extern int32_t  DSpContext_GetGammaHandler(uint32_t ctxRef,
                                           uint32_t tableOutAddr);
/*
 *  FadeGamma trio per the
 *  DSp 1.7 ABI (pp.32-35). The parametric FadeGamma takes a SIGNED
 *  inPercent + an RGBColor* zero-intensity tint (NO durationVbls); the
 *  In/Out variants take an RGBColor* tint and fade over a fixed 1 second
 *  derived from the device-native VBL cadence.
 */
extern int32_t  DSpContext_FadeGammaInHandler(uint32_t ctxRef,
                                              uint32_t colorAddr);
extern int32_t  DSpContext_FadeGammaOutHandler(uint32_t ctxRef,
                                               uint32_t colorAddr);
extern int32_t  DSpContext_FadeGammaHandler(uint32_t ctxRef,
                                            int32_t  inPercent,
                                            uint32_t colorAddr);

/*
 *  VBL Service + Blanking + Screensaver handlers.
 *
 *  Argument layout per dsp_dispatch.cpp r4..r6 marshalling:
 *    SetVBLProc   (ctxRef, procPtr, refCon)               — sub-opcode 500
 *    GetVBLCount  (ctxRef, countOutAddr)                  — sub-opcode 501
 *    BlankFill    (ctxRef, rectAddr, colorAddr)           — sub-opcode 502
 *    GetVBLProc   (ctxRef, procOutAddr, refConOutAddr)    — sub-opcode 503
 */
extern int32_t  DSpContext_SetVBLProcHandler(uint32_t ctxRef,
                                             uint32_t procPtr,
                                             uint32_t refCon);
extern int32_t  DSpContext_GetVBLCountHandler(uint32_t ctxRef,
                                              uint32_t countOutAddr);
extern int32_t  DSpContext_BlankFillHandler(uint32_t ctxRef,
                                            uint32_t rectAddr,
                                            uint32_t colorAddr);
extern int32_t  DSpContext_GetVBLProcHandler(uint32_t ctxRef,
                                             uint32_t procOutAddr,
                                             uint32_t refConOutAddr);

/*
 *  Canonical DSpProcessEvent
 *  (sub-opcode 750). DSp 1.7 PDF p.58:
 *    OSStatus DSpProcessEvent(EventRecord *inEvent, Boolean *outEventWasProcessed)
 *  NO ctxRef — the app passes its OWN event in; DSp inspects it for the
 *  suspend/resume osEvt it must handle, drives context state, and reports via
 *  the Boolean out-param whether it consumed the event (honest false for
 *  unhandled events). The dispatch case routes r3 = inEventAddr
 *  (EventRecord*), r4 = outProcessedAddr (Boolean*).
 *
 *  This is the OPPOSITE direction to the retired sub-op-600 dequeue
 *  handler (the old DSpContext_* ProcessEvent reader export), which was
 *  retired (retire, NOT repurpose). The SPSC input-fanout ring
 *  it observed is KEPT;
 *  the DSpEventTests ring-observation methods migrate to the TESTING_BUILD
 *  DSpTesting_DequeueContextEvent helper.
 */
extern int32_t  DSpProcessEventHandler(uint32_t inEventAddr,
                                       uint32_t outProcessedAddr);

/*
 *  VBL-bounded release — registered as a vbl_source secondary callback in
 *  DSpInit (dsp_engine.cpp). Drains the release FIFO; releases each
 *  entry's back-texture before its back-buffer. Safe to call at
 *  vbl_source_testing_simulate_vbl_tick() time during unit tests.
 */
extern void     DSpVBLReleaseCallback(void *ctx, void *drawable, double ts);

/*
 *  VBL-latched CLUT snapshot callback. Registered
 *  from DSpInit via vbl_source_register_secondary_callback; unregistered
 *  from DSpShutdown. Drains clut_bytes -> clut_bytes_latched per-context.
 */
extern void     DSpVBLClutLatchCallback(void *ctx, void *drawable, double ts);

/*
 *  VBL-driven gamma-fade interpolation callback.
 *  Registered from DSpInit via vbl_source_register_secondary_callback
 *  AFTER DSpVBLClutLatchCallback; unregistered from DSpShutdown FIRST
 *  (reverse registration order). The body walks the context table and
 *  applies the per-frame linear-interpolation +
 *  dmc_record_gamma_change_with_lut push.
 */
extern void     DSpVBLGammaFadeCallback(void *ctx, void *drawable, double ts);

/*
 *  VBL service callback. Registered from DSpInit
 *  via vbl_source_register_secondary_callback AFTER DSpVBLGammaFadeCallback.
 *  Unregistered from DSpShutdown FIRST (reverse registration order). The
 *  body atomic-increments s_dsp_vbl_count (the monotonic tick counter) and
 *  runs the per-context walk + user VBLProc invocation via call_macos3.
 *  Runs on the emul thread per the VBL secondary-callback contract.
 */
extern void     DSpVBLServiceCallback(void *ctx, void *drawable, double ts);

/*
 *  Background/foreground emul-thread drain. Declared here so it can be
 *  registered in the same VBL secondary-callback chain without touching
 *  headers again.
 */
extern void     DSpVBLBackgroundForegroundDrain(void);

/*
 *  Pending-lifecycle bitmask bits carried in the dsp_engine.cpp atomic and
 *  returned by DSpExchangeBgFgPending. Accumulated with fetch_or so a
 *  foreground event cannot erase an undrained background event.
 */
enum {
	kDSpPendingBackground = 1u << 0,
	kDSpPendingForeground = 1u << 1
};

/*
 *  Synchronous lifecycle drain. Runs the background/foreground drain plus
 *  the VBL release-FIFO drain immediately on the calling (main==emul)
 *  thread. Called from the UIKit lifecycle hooks (dsp_engine.cpp) because
 *  gfxaccel_handle_background_enter pauses the VBL source before invoking
 *  them — the VBL drain chain cannot run while backgrounded. No-ops
 *  (leaving the pending bits set for the in-flight tick's own drain) when
 *  called from inside the VBL callback chain.
 */
extern void     DSpDrainLifecycleSync(void);

/*
 *  Emul-thread handler bodies invoked from the VBL
 *  drain. Exported so test-harness code (and the draw-context drain
 *  dispatcher) can invoke them directly. Both iterate the DSp context
 *  table on the emul thread — callers MUST NOT invoke from the main
 *  thread; use the NotificationCenter / gfxaccel_set_dsp_*_hook path for
 *  external triggers.
 */
extern void     DSpHandleBackgroundFromEmulThread(void);
extern void     DSpHandleForegroundFromEmulThread(void);

/*
 *  Atomic bridge. Implementation lives in
 *  dsp_engine.cpp so the _Atomic uint32_t flag is owned by the engine
 *  lifecycle module; dsp_draw_context.mm calls this from the drain paths
 *  to read + clear the pending state in one acquire-ordered exchange.
 *  Returns a kDSpPending* bitmask (0 = none pending).
 */
extern uint32_t DSpExchangeBgFgPending(void);

/*
 *  Map DSp play state -> Display-Mode-Controller owner value. This helper
 *  is the single point where the DSp-to-controller owner mapping lives;
 *  the SetState handler, the bg/fg hooks, and the multi-engine canary
 *  all call through here.
 *
 *  The public export is uint32_t (not the controller's typed
 *  enum) so this public DSp header stays free of the controller's own
 *  header. The returned value is binary-compatible with the controller
 *  owner enum — consumers that have already pulled in that header can
 *  cast directly, or use the typed inline wrapper
 *  DSpMapStateToDMCOwnerTyped() exported by the private helper header
 *  dsp_engine_internal.h (gfxaccel-tree-internal only).
 *
 *  Valid inputs: kDSpContextState_{Active,Paused,Inactive} from
 *  dsp_engine.h. Any other value returns the controller's Quiescent
 *  sentinel; call sites must reject invalid state values BEFORE calling
 *  this helper (SetState bounds-checks first).
 */
extern uint32_t DSpMapStateToDMCOwner(uint32_t dsp_state);

#ifdef TESTING_BUILD
/*
 *  TESTING_BUILD-only helpers. Called from setUp/tearDown in
 *  DSpContextTests.swift to drain the release FIFO, clear the context
 *  table, and reset atomic counters between tests.
 */
extern int      dsp_testing_context_count(void);
extern void     dsp_testing_reset_contexts(void);

/*
 *  Test hooks — expose the NQD
 *  conflict-gate drop counter. Implementation in gfxaccel_resources.mm.
 *  The coexistence tests assert that after configuring a DSp
 *  Active context and issuing one NQD dispatch into the framebuffer
 *  slot, dsp_testing_get_nqd_fb_drop_count() returns 1.
 */
extern int      dsp_testing_get_nqd_fb_drop_count(void);
extern void     dsp_testing_reset_nqd_fb_drop_count(void);

/*
 *  NQD-side alias — same
 *  storage as dsp_testing_get_nqd_fb_drop_count. Tests may query by
 *  either name.
 */
extern int      NQDTesting_GetFramebufferDropCount(void);

/*
 *  One-call scripted Reserve + SetState(Active) for the coexistence tests.
 *  Returns the new ctxRef (>= 1) on
 *  success, or a negative DSp error code (-30440..-30450) on failure.
 *
 *  Routes DMC active_owner to kDMCOwnerDSp so the NQD conflict gate
 *  becomes active on the next NQD dispatch.
 */
extern int32_t  DSpTesting_SimulateActiveContext(uint32_t width,
                                                  uint32_t height,
                                                  uint32_t depth);

/*
 *  Guest-RAM scratch allocator for test-harness use.
 *
 *  Production DSp handlers consume attr-struct + out-param addresses as
 *  uint32_t Mac-addresses, read/written via ReadMacInt32/WriteMacInt32.
 *  The test target does NOT link main_unix.cpp (which owns SheepMem
 *  globals) so SheepMem::Reserve is non-functional under PocketShaverTests.
 *
 *  dsp_testing_alloc_guest_scratch() returns a 4-byte-aligned uint32
 *  address that ReadMacInt32/WriteMacInt32 (EMULATED_PPC=0 static inlines,
 *  which dereference *(uint32*)addr) can dereference safely. Backed by a
 *  page-aligned mmap() region in the low 4 GiB of host VA so the uint32
 *  cast round-trips to a valid host pointer (matches PSFakeMacRAM allocator
 *  pattern).
 *
 *  Bump allocator: calls advance a file-static `s_scratch_pos` pointer;
 *  dsp_testing_free_guest_scratch is a no-op marker (real reset via
 *  dsp_testing_reset_guest_scratch, called from test tearDown).
 *
 *  Returns 0 on allocation failure; tests should XCTFail on 0.
 */
extern uint32_t dsp_testing_alloc_guest_scratch(uint32_t size);
extern void     dsp_testing_free_guest_scratch(uint32_t addr);
extern void     dsp_testing_reset_guest_scratch(void);
/*
 *  Returns 1 iff the scratch backing store sits entirely below 4 GiB
 *  of host VA so ReadMacInt32 / WriteMacInt32 (EMULATED_PPC=0 raw
 *  pointer deref) can safely access every scratch-vended address.
 *  Returns 0 on arm64 iOS simulator when mmap ignored the low-4GiB
 *  hints. Callers whose code path depends on production Mac-memory
 *  reads (DSpGetBackBufferCGrafPtr, DSpContext_SwapBuffers' staging
 *  memcpy) use this probe to XCTSkip when the constraint is unmet.
 */
extern int      dsp_testing_scratch_in_low_4gib(void);

/*
 *  Swift-callable shims around the static-inline
 *  ReadMacInt32 / WriteMacInt32 / ReadMacInt16 / WriteMacInt16 helpers
 *  from cpu_emulation.h. Static inlines cannot be imported into Swift via
 *  the bridging header; these thin extern "C" wrappers give Swift test
 *  code a way to populate the guest-RAM structs (DSpContextAttributes,
 *  Mac Rect, out-param uint32_t cells) that DSp handlers consume.
 */
extern void     dsp_testing_write_mac_int32(uint32_t addr, uint32_t value);
extern uint32_t dsp_testing_read_mac_int32(uint32_t addr);
extern void     dsp_testing_write_mac_int16(uint32_t addr, uint32_t value);
extern uint32_t dsp_testing_read_mac_int16(uint32_t addr);
/* Byte-accurate 1-byte read/write — use for Pascal Boolean / SInt8
 * out-params (e.g. DSpProcessEvent's outEventWasProcessed) the handler
 * stores with WriteMacInt8, instead of (read_mac_int16 & 0xff). */
extern void     dsp_testing_write_mac_int8(uint32_t addr, uint32_t value);
extern uint32_t dsp_testing_read_mac_int8(uint32_t addr);

/*
 *  Host-struct-based wrappers around the DSp
 *  context-lifecycle handlers for tests. EMULATED_PPC=0 + arm64 iOS
 *  simulator's RAM-above-4GiB combo means ReadMacInt32/WriteMacInt32
 *  deref a truncated uint32 host pointer and SEGV. These wrappers
 *  bypass the Mac-memory indirection by taking struct / out-ptr /
 *  int16 arguments directly. Behavior is byte-identical to the
 *  Mac-address variants at the Reserve_Core / state-table level;
 *  wrappers are compiled only under TESTING_BUILD so production
 *  binaries exclude them.
 */
struct DSpContextAttributes;  /* full def in dsp_engine.h */
extern int32_t DSpTesting_ReserveByStruct(const struct DSpContextAttributes *attr,
                                           uint32_t *outCtxRef);
extern int32_t DSpTesting_GetBackBufferByStruct(uint32_t ctxRef,
                                                 uint32_t options,
                                                 uint32_t *outBuf);

/*
 *  TESTING_BUILD helper: return the back-buffer's host-visible
 *  contents pointer + byte length for a context. Used by
 *  DSpIndexedDepthCompositeTests to write packed index bit patterns
 *  directly into the MTLBuffer-backed back-buffer (MTLStorageModeShared).
 *  Bypasses the guest-scratch staging indirection that
 *  DSpGetBackBufferCGrafPtr uses. Returns kDSpNoErr + populates out-params
 *  on success; kDSpInvalidContextErr + zeros on invalid ctx.
 */
extern int32_t DSpTesting_GetBackBufferHostPointer(uint32_t ctxRef,
                                                    void **outContents,
                                                    uint32_t *outLength);

/*
 *  TESTING_BUILD helper: return the back-buffer MTLTexture
 *  view handle (id<MTLTexture> as void*) for a context. Used by
 *  DSpIndexedDepthCompositeTests to blit a packed-index pattern into
 *  the back-buffer via a Shared staging MTLBuffer when the underlying
 *  back_buffer is StorageModePrivate (iOS simulator heap constraint).
 *  Returned handle is UNRETAINED (owned by the context); caller must
 *  NOT release it. Returns NULL on invalid ctxRef.
 */
extern void *DSpTesting_GetBackTextureHandle(uint32_t ctxRef);
extern int32_t DSpTesting_GetStateByStruct(uint32_t ctxRef,
                                            uint32_t *outState);
extern int32_t DSpTesting_InvalBackBufferRectByValue(uint32_t ctxRef,
                                                      int16_t top, int16_t left,
                                                      int16_t bottom, int16_t right);

/*
 *  Cheap-family query host-helper contract spine. Each By{Value,Values}
 *  wrapper takes host pointers/values so DSpContextTests can assert the
 *  handler's behavior without driving EMULATED_PPC (above-4GiB guest-RAM
 *  SEGV avoidance, same rationale as the ByStruct/ByValue family).
 */
extern int32_t DSpTesting_IsBusyByValue(uint32_t ctxRef, uint8_t *outBusy);
extern int32_t DSpTesting_GetDisplayIDByValue(uint32_t ctxRef, uint32_t *outID);
extern int32_t DSpTesting_GetDirtyRectGridUnitsByValues(uint32_t ctxRef,
                                                        uint32_t *outW,
                                                        uint32_t *outH);
extern int32_t DSpTesting_GetMaxFrameRateByValue(uint32_t ctxRef,
                                                 uint32_t *outMaxFPS);
extern int32_t DSpTesting_SetMaxFrameRateByValue(uint32_t ctxRef,
                                                  uint32_t inMaxFPS);
extern uint32_t DSpTesting_MaxFrameRatePacingVBLs(uint32_t maxFrameRate,
                                                   uint64_t cadenceUsec);
extern int32_t DSpTesting_GetMonitorFrequencyByValue(uint32_t ctxRef,
                                                      uint32_t *outFixed);
extern int32_t DSpTesting_SetDirtyRectGridSizeByValues(uint32_t ctxRef,
                                                       uint32_t w,
                                                       uint32_t h);
extern int32_t DSpTesting_GetDirtyRectGridSizeByValues(uint32_t ctxRef,
                                                       uint32_t *outW,
                                                       uint32_t *outH);
extern int32_t DSpTesting_GetFrontBufferByValue(uint32_t ctxRef,
                                                uint32_t *outCGrafPtr);
extern int32_t DSpTesting_GetCurrentContextByValue(uint32_t displayID,
                                                   uint32_t *outCtxRef);
/* Forces ctx->state = Active (RAM-only) bypassing the DMC/MainDevice-PixMap
 * SetState path that SEGVs in the no-ROM simulator; seeds the
 * GetCurrentContext active-walk contract test. */
extern int32_t DSpTesting_ForceContextStateActive(uint32_t ctxRef);

/*
 *  Coordinate / mouse host-helper contract spine. The By{Value,Values}
 *  wrappers take host pointers/values so DSpContextTests can assert
 *  behavior without driving EMULATED_PPC.
 *  DSpTesting_SetHostMouseLocation seeds the MouseLocation lowmem global so
 *  the GetMouse contract proves the handler reads the real host source.
 */
extern int32_t DSpTesting_GetMouseByValues(int16_t *v, int16_t *h);
extern void    DSpTesting_SetHostMouseLocation(int16_t v, int16_t h);
extern int32_t DSpTesting_GlobalToLocalByValues(uint32_t ctxRef,
                                                int16_t *v, int16_t *h);
extern int32_t DSpTesting_LocalToGlobalByValues(uint32_t ctxRef,
                                                int16_t *v, int16_t *h);
extern int32_t DSpTesting_FindContextFromPointByValues(int16_t v, int16_t h,
                                                       uint32_t *outCtxRef);

/*
 *  Discovery / multi-display host-helper contract spine. The
 *  By{Struct,Value} wrappers take host pointers/values so DSpContextTests
 *  can assert single-display-faithful behavior without driving
 *  EMULATED_PPC. The discovery wrappers delegate to the existing
 *  DSpTesting_FindBestContextByStruct (no new matcher). Each helper decl
 *  lands WITH its body per-export.
 *
 *  DSpTesting_FindBestContextOnDisplayIDByStruct uses the single-screen
 *  policy: ANY displayID maps to the single screen and delegates to the
 *  matcher; null out -> kDSpInvalidAttributesErr; only a genuinely unmatchable
 *  attribute request -> kDSpContextNotFoundErr (from the matcher, NOT a
 *  displayID mismatch). inDisplayID is the SECOND arg here to match the test
 *  call shape (req, displayID, outCtxRef).
 */
extern int32_t DSpTesting_SetDebugModeByValue(uint8_t on);
extern int32_t DSpTesting_GetDebugMode(uint8_t *out);
extern int32_t DSpTesting_CanUserSelectContextByStruct(
    const struct DSpContextAttributes *req, uint8_t *outCan);
extern int32_t DSpTesting_FindBestContextOnDisplayIDByStruct(
    const struct DSpContextAttributes *req, uint32_t displayID,
    uint32_t *outCtxRef);
extern int32_t DSpTesting_UserSelectContextByStruct(
    const struct DSpContextAttributes *req, uint32_t *outCtxRef);
extern int32_t DSpTesting_SetBlankingColorByValues(uint16_t r, uint16_t g,
                                                   uint16_t b);

/*
 *  AltBuffer host-helper contract spine. The By{Struct,Value} wrappers
 *  take host pointers/values so DSpAltBufferTests can assert behavior
 *  without driving EMULATED_PPC (above-4GiB guest-RAM SEGV avoidance,
 *  same rationale as the cheap-family By{Value,Struct} family). GPU-effect
 *  assertions in the test gate behind dsp_testing_scratch_in_low_4gib().
 */
extern int32_t DSpTesting_AltBuffer_NewByStruct(
    uint32_t ctxRef,
    uint8_t inVRAMBuffer,
    const struct DSpAltBufferAttributes *inAttributes /* NULL => underlay-capable */,
    uint32_t *outAltBuffer);
extern int32_t DSpTesting_AltBuffer_DisposeByValue(uint32_t altBuffer);
extern int32_t DSpTesting_AltBuffer_GetCGrafPtrByValue(uint32_t altBuffer,
                                                       uint32_t bufferKind,
                                                       uint32_t *outCGrafPtr);
extern int32_t DSpTesting_AltBuffer_InvalRectByValue(uint32_t altBuffer,
                                                     int16_t top, int16_t left,
                                                     int16_t bottom, int16_t right);
extern int32_t DSpTesting_GetUnderlayAltBufferByValue(uint32_t ctxRef,
                                                      uint32_t *outUnderlay);
extern int32_t DSpTesting_SetUnderlayAltBufferByValue(uint32_t ctxRef,
                                                      uint32_t inNewUnderlay);
/* Reads back an alt-buffer's accumulated dirty rect (designate/inval
 * contract assertion). Returns kDSpInvalidAttributesErr on bad handle. */
extern int32_t DSpTesting_AltBuffer_GetDirtyRectByValues(uint32_t altBuffer,
                                                         int16_t *outTop,
                                                         int16_t *outLeft,
                                                         int16_t *outBottom,
                                                         int16_t *outRight,
                                                         uint8_t *outEmpty);
/* Writes a solid BGRA color into the alt-buffer backing (host pointer; no
 * guest-RAM indirection) so the golden underlay-restore test can seed a
 * known underlay pattern. Returns kDSpInvalidAttributesErr on bad handle. */
extern int32_t DSpTesting_AltBuffer_FillBacking(uint32_t altBuffer,
                                                uint8_t b, uint8_t g,
                                                uint8_t r, uint8_t a);

/*
 *  Blit TESTING_BUILD host helpers (sub-ops 710-711). The two By-Addr twins
 *  take a guest-RAM DSpBlitInfo Mac address the test populated into the
 *  scratch region (via dsp_testing_write_mac_int*) and call the production
 *  handler directly — exercising the read-path + NQD dispatch + synchronous
 *  completionFlag write without an EMULATED_PPC frame.
 *  DSpTesting_ResolveBlitSide asserts the CGrafPtr+Rect -> clamped geometry
 *  contract (overscan mitigation) without dispatching the GPU.
 *  GPU-effect assertions in the test gate behind dsp_testing_scratch_in_low_4gib();
 *  the NULL / depth-mismatch / OOB guards assert unconditionally.
 */
extern int32_t DSpTesting_BlitFastestByAddr(uint32_t inBlitInfo, uint32_t inAsyncFlag);
extern int32_t DSpTesting_BlitFasterByAddr(uint32_t inBlitInfo, uint32_t inAsyncFlag);
extern int DSpTesting_ResolveBlitSide(uint32_t cgrafptr_mac, uint32_t rect_mac,
                                      uint32_t *out_base_origin, int32_t *out_row_bytes,
                                      uint32_t *out_pixel_bytes,
                                      int32_t *out_w, int32_t *out_h);

/*
 *  Flatten/Restore TESTING_BUILD host helpers
 *  (sub-ops 739-741). These operate on HOST byte buffers (uint8_t*) instead of
 *  guest Mac addresses, so the round-trip contract + golden fidelity tests need
 *  no EMULATED_PPC frame, no ROM, no render — pure microsecond serialization
 *  (protects the 30s test budget). DSpTesting_FlattenToHost serializes
 *  ctx into a host blob; DSpTesting_RestoreFromHost reads a host blob, validates
 *  magic+version, allocates a fresh metadata context + returns its ctxRef.
 *  DSpTesting_GetFlattenedSizeByValue returns the format byte count. The
 *  `blob_cap` argument lets the test pass a too-small buffer to assert the size
 *  guard. Bad ctxRef / NULL blob / undersized blob -> the same kDSp* codes as
 *  the guest-RAM path so the helpers are observationally identical to the
 *  production handlers.
 */
extern int32_t DSpTesting_GetFlattenedSizeByValue(uint32_t ctxRef, uint32_t *outSize);
extern int32_t DSpTesting_FlattenToHost(uint32_t ctxRef, uint8_t *blob, uint32_t blob_cap);
extern int32_t DSpTesting_RestoreFromHost(const uint8_t *blob, uint32_t blob_len,
                                          uint32_t *outRestoredCtxRef);

/*
 *  Queue/Switch TESTING_BUILD host helpers
 *  (sub-ops 742-743). Queue remains RAM-only for the no-attribute contract
 *  path. Switch calls the production SetState-backed path so DMC owner/mode,
 *  MainDevice PixMap redirect, and active-fullscreen side effects match the
 *  real handler. inDesiredAttributes is passed as 0 (no attribute override) in
 *  the contract path — the production guest-RAM apply-on-non-zero branch is
 *  exercised on device/Catalyst. DSpTesting_GetQueuedChildByValue reads
 *  parent->queued_child so tests can assert the staged handle is recorded by
 *  Queue and cleared only after Switch applies.
 */
extern int32_t DSpTesting_QueueByValue(uint32_t parentCtx, uint32_t childCtx,
                                       uint32_t inDesiredAttributes);
extern int32_t DSpTesting_SwitchByValue(uint32_t oldCtx, uint32_t newCtx);
extern int32_t DSpTesting_GetQueuedChildByValue(uint32_t ctxRef, uint32_t *outChild);

/*
 *  TESTING_BUILD helper: host-struct wrapper around
 *  DSpContext_SetCLUTEntriesHandler. See implementation in
 *  dsp_draw_context.mm. `entries_host` points to (last-first+1)*3 bytes
 *  of R/G/B data in host memory — bypasses the ReadMacInt8 loop so
 *  DSpIndexedDepthCompositeTests can issue SetCLUT at simulator speed
 *  without guest-RAM plumbing (above-4GiB simulator SEGV
 *  avoidance). The 8-byte ColorSpec wire-path is the *ByColorSpec helper.
 */
extern int32_t DSpTesting_SetCLUTEntriesByStruct(uint32_t ctxRef,
                                                 uint32_t first,
                                                 uint32_t last,
                                                 const uint8_t *entries_host);

/*
 *  TESTING_BUILD helper: host-struct wrapper around
 *  DSpContext_GetCLUTEntriesHandler. See implementation in
 *  dsp_draw_context.mm. `entries_out_host` points to (last-first+1)*3
 *  bytes of output storage in host memory — bypasses the WriteMacInt8
 *  loop. Reads from the VBL-latched snapshot.
 */
extern int32_t DSpTesting_GetCLUTEntriesByStruct(uint32_t ctxRef,
                                                 uint32_t first,
                                                 uint32_t last,
                                                 uint8_t *entries_out_host);

/*
 *  TESTING_BUILD helpers: 8-byte ColorSpec
 *  wire-path wrappers around DSpContext_{Set,Get}CLUTEntriesHandler.
 *  `entries_host` / `entries_out_host` point to `inEntryCount` 8-byte
 *  ColorSpec structs (value@+0 SInt16, 16-bit big-endian r@+2/g@+4/b@+6),
 *  exercising the real 16<->8 conversion the production handlers do.
 *  Pointer-before-index arg order: (ctxRef, entries, inStartingEntry,
 *  inEntryCount). Used by DSpPaletteTests + DSpCLUTAnimationTests.
 */
extern int32_t DSpTesting_SetCLUTEntriesByColorSpec(uint32_t ctxRef,
                                                    const uint8_t *entries_host,
                                                    uint32_t inStartingEntry,
                                                    uint32_t inEntryCount);
extern int32_t DSpTesting_GetCLUTEntriesByColorSpec(uint32_t ctxRef,
                                                    uint8_t *entries_out_host,
                                                    uint32_t inStartingEntry,
                                                    uint32_t inEntryCount);

/*
 *  TESTING_BUILD helper: host-LUT wrapper around
 *  DSpContext_SetGammaHandler. See implementation in dsp_draw_context.mm.
 *  `lut_host_768` points to a 768-byte planar R/G/B LUT in host memory —
 *  bypasses the ReadMacInt8 loop so DSpGammaTests can issue SetGamma at
 *  simulator speed without guest-RAM plumbing.
 */
extern int32_t DSpTesting_SetGammaByLUT(uint32_t ctxRef,
                                         const uint8_t *lut_host_768);

/*
 *  TESTING_BUILD helper: host-LUT wrapper around
 *  DSpContext_GetGammaHandler. See implementation in dsp_draw_context.mm.
 *  `lut_out_host_768` is a 768-byte caller-allocated buffer that
 *  receives the planar R/G/B gamma LUT — bypasses the WriteMacInt8 loop.
 */
extern int32_t DSpTesting_GetGammaByLUT(uint32_t ctxRef,
                                         uint8_t *lut_out_host_768);

/*
 *  TESTING_BUILD helpers: wrappers
 *  around the FadeGammaIn/Out (no duration; fixed 1-second
 *  cadence-derived) taking a host-side zero-intensity tint.
 *  DSpTesting_FadeOneSecondVbls returns the device-native VBL count so
 *  tests advance exactly enough VBLs to reach the terminal state.
 *  DSpTesting_AdvanceFadeOneVBL calls DSpVBLGammaFadeCallback directly so
 *  tests step through fades deterministically without real VBL ticks.
 */
extern uint32_t DSpTesting_FadeOneSecondVbls(void);
extern int32_t DSpTesting_FadeGammaInByColor(uint32_t ctxRef,
                                              uint8_t r,
                                              uint8_t g,
                                              uint8_t b);
extern int32_t DSpTesting_FadeGammaOutByColor(uint32_t ctxRef,
                                               uint8_t r,
                                               uint8_t g,
                                               uint8_t b);
extern void    DSpTesting_AdvanceFadeOneVBL(void);

/*
 *  TESTING_BUILD helper: directly invoke
 *  DSpVBLServiceCallback (VBL service callback + per-context walk)
 *  without needing a real display-link fire. Used by DSpVBLTests
 *  to advance s_dsp_vbl_count deterministically and
 *  exercise the per-context walk + user VBLProc invocation.
 *
 *  Unlike vbl_source_testing_simulate_vbl_tick (which drains ALL four
 *  secondary callbacks), this shim fires ONLY DSpVBLServiceCallback —
 *  useful for narrow unit tests that don't want release/clut-latch/
 *  gamma-fade side-effects.
 */
extern void    DSpTesting_SimulateVBLTick(void);

/*
 *  TESTING_BUILD helper: host-uint8
 *  tint wrapper around the DSpContext_FadeGammaHandler.
 *  Bypasses the guest-RAM 16-bit color read so DSpGammaTests can issue
 *  parametric fades at simulator speed. Takes a SIGNED percent and NO
 *  duration (parametric FadeGamma applies its target LUT immediately).
 */
extern int32_t DSpTesting_FadeGammaByValues(uint32_t ctxRef,
                                             int32_t percent,
                                             uint8_t r,
                                             uint8_t g,
                                             uint8_t b);

/*
 *  TESTING_BUILD helper: direct host-value wrapper around
 *  DSpContext_BlankFillHandler. Takes 4 int16 rect coords + 3 uint8 RGB
 *  channels directly, bypassing the ReadMacInt16 loops. Used by
 *  DSpVBLTests for golden-image BlankFill assertions at
 *  1/2/4/8/16/32 bpp without guest-RAM plumbing (above-4GiB
 *  simulator SEGV avoidance). Mirrors the
 *  DSpTesting_FadeGammaByValues +
 *  DSpTesting_InvalBackBufferRectByValue pattern.
 */
extern int32_t DSpTesting_BlankFillByValues(uint32_t ctxRef,
                                             int16_t top,
                                             int16_t left,
                                             int16_t bottom,
                                             int16_t right,
                                             uint8_t r,
                                             uint8_t g,
                                             uint8_t b);

/*
 *  TESTING_BUILD helpers: host-value wrappers that bypass the
 *  WriteMacInt32 guest-RAM writes of the production Get* handlers, so
 *  DSpVBLTests.swift can round-trip SetVBLProc / observe s_dsp_vbl_count
 *  on the simulator (above-4GiB scratch-addr SEGV avoidance).
 *
 *  DSpTesting_ReadVBLCount           — host read of s_dsp_vbl_count low-32
 *  DSpTesting_ReadVBLProcFields      — host read of ctx->vbl_proc_ptr/refcon
 *  DSpTesting_BlankFillHandlerWithAddresses
 *                                     — production-path BlankFill with
 *                                       guest-RAM rectAddr/colorAddr so arg-
 *                                       validation (NULL-rejection) tests
 *                                       can drive the 0 -> kDSpInvalid-
 *                                       AttributesErr branch.
 */
extern int32_t DSpTesting_ReadVBLCount(uint32_t ctxRef, uint32_t *outCount);
extern int32_t DSpTesting_ReadVBLProcFields(uint32_t ctxRef,
                                             uint32_t *outProc,
                                             uint32_t *outRefCon);
extern int32_t DSpTesting_BlankFillHandlerWithAddresses(uint32_t ctxRef,
                                                         uint32_t rectAddr,
                                                         uint32_t colorAddr);

/*
 *  TESTING_BUILD helper — applies the production BlankFill
 *  depth-dispatch kernel (DSpBlankFillDepthDispatch) to a caller-provided
 *  host buffer. Works around the iOS simulator's MTLStorageModePrivate
 *  heap coercion (gfxaccel_resources_heap.mm:190) that makes
 *  ctx->back_buffer.contents NULL on the simulator. Byte-identical
 *  behavior to the production path — same clipping, same depth-switch,
 *  same pixel-pack formulas. No dirty-region notification (the host
 *  buffer is not a back-buffer).
 */
extern int32_t DSpTesting_BlankFillOnHostBuffer(uint8_t *host_buffer,
                                                 uint16_t bb_w,
                                                 uint16_t bb_h,
                                                 uint32_t depth,
                                                 uint32_t pitch,
                                                 int16_t top,
                                                 int16_t left,
                                                 int16_t bottom,
                                                 int16_t right,
                                                 uint8_t r,
                                                 uint8_t g,
                                                 uint8_t b);

/*
 *  Event-integration test wrappers.
 *
 *  DSpTesting_EnqueueEventToCtx         — thin wrapper around dsp_enqueue_into_ring
 *                                         (file-static helper, exposed
 *                                         cross-TU as extern "C").
 *                                         Lets Swift tests pre-populate per-ctx
 *                                         SPSC event queues for dequeue-path tests.
 *  DSpTesting_ReadContextPausedByBackground
 *                                       — read ctx->paused_by_background for
 *                                         bg/fg sequence test assertions.
 *  DSpTesting_ReadContextEventsQueueDepth
 *                                       — read (events_head - events_tail) for
 *                                         overflow-path testing.
 *  DSpTesting_DequeueContextEvent       — dequeue one event from the SPSC ring
 *                                         WITHOUT guest-RAM marshalling.
 *                                         Lifts the retired sub-op-600 dequeue
 *                                         body so the DSpEventTests
 *                                         ring-observation methods survive the
 *                                         guest-export retirement; the ring +
 *                                         its producers are KEPT. Reuses the
 *                                         existing ring atomics behind
 *                                         TESTING_BUILD — ZERO new production
 *                                         concurrency primitive.
 *  DSpTesting_WriteContextPausedByBackground
 *                                       — write ctx->paused_by_background so
 *                                         fg-sequence tests can simulate a
 *                                         prior bg transition's flag state
 *                                         without going through OnBackground
 *                                         (which would enqueue events).
 */
extern int32_t DSpTesting_EnqueueEventToCtx(uint32_t ctxRef,
                                             uint16_t what, uint32_t message,
                                             uint32_t when,
                                             int16_t where_v, int16_t where_h,
                                             uint16_t modifiers);
extern int32_t DSpTesting_ReadContextPausedByBackground(uint32_t ctxRef,
                                                         uint8_t *outFlag);
extern int32_t DSpTesting_ReadContextEventsQueueDepth(uint32_t ctxRef,
                                                       uint32_t *outDepth);
extern int32_t DSpTesting_DequeueContextEvent(uint32_t ctxRef,
                                              uint16_t *outWhat,
                                              uint32_t *outMessage,
                                              uint32_t *outWhen,
                                              int16_t *outWhereV,
                                              int16_t *outWhereH,
                                              uint16_t *outModifiers,
                                              uint8_t *outProcessed);
extern int32_t DSpTesting_WriteContextPausedByBackground(uint32_t ctxRef,
                                                          uint8_t flag);

/*
 *  Debug session `dsp-sims-enumeration-stall` fix (2026-04-19) — host
 *  read of ctx->enumeration_mode_index for the new GetFirst/GetNext
 *  iteration regression test. Returns kDSpNoErr + populates *outIndex on
 *  success; kDSpInvalidContextErr + leaves *outIndex untouched on invalid
 *  ctxRef; kDSpInvalidAttributesErr + leaves *outIndex untouched if
 *  outIndex is NULL. outIndex may be DSP_ENUMERATION_INDEX_NONE
 *  (0xFFFFFFFFu) for contexts not on the enumeration chain.
 */
extern int32_t DSpTesting_ReadEnumerationModeIndex(uint32_t ctxRef,
                                                    uint32_t *outIndex);

/*
 *  Debug session `dsp-sims-post-reserve-black-screen` fix (2026-04-19) —
 *  host-side wrapper around DSpContext_ReserveHandler's new signature for
 *  regression testing the Sims-style flow: FindBest / GetFirstContext
 *  vends a metadata-only ctxRef; the app calls Reserve(ctxRef, attrs) to
 *  attach a back-buffer to that existing handle. This wrapper lets Swift
 *  tests execute the exact same code path the production dispatcher calls
 *  without going through guest-RAM. Returns the DSp 1.7 error code
 *  unchanged.
 */
extern int32_t DSpTesting_ReserveOnHandleByStruct(
    uint32_t ctxRef,
    const struct DSpContextAttributes *attr);

/*
 *  TESTING_BUILD helpers for the MainDevice-PixMap fix verification:
 *    - DSpTesting_GetMainDevicePixMapBaseAddr
 *    - DSpTesting_TickVBL
 *    - DSpTesting_GetSubmitFrameCount
 *    - DSpTesting_ResetSubmitFrameCount
 *    - DSpTesting_BootstrapMinimalContext
 *    - DSpTesting_SetStateActiveDirect
 *    - DSpTesting_CaptureCompositorOutput
 *
 *  Bodies live in dsp_draw_context.mm (MainDevice walk, Reserve_Core
 *  twin, SetStateHandler twin, VBLSource tick) and metal_compositor.mm
 *  (SubmitFrame counter + compositor framebuffer texture readback).
 */
extern uint32_t DSpTesting_GetMainDevicePixMapBaseAddr(void);
extern void     DSpTesting_TickVBL(void);
extern uint64_t DSpTesting_GetSubmitFrameCount(void);
extern void     DSpTesting_ResetSubmitFrameCount(void);
extern uint32_t DSpTesting_BootstrapMinimalContext(uint32_t width,
                                                    uint32_t height,
                                                    uint32_t bpp);
extern int32_t  DSpTesting_SetStateActiveDirect(uint32_t ctxRef);
extern void     DSpTesting_CaptureCompositorOutput(uint8_t **out_bytes,
                                                    uint32_t *out_width,
                                                    uint32_t *out_height);
#endif

#ifdef __cplusplus
}
#endif

#endif /* DSP_DRAW_CONTEXT_H */
