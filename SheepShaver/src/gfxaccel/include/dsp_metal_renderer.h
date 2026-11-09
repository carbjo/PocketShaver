/*
 *  dsp_metal_renderer.h - Metal back-buffer allocation and present for DSp.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  C interface; ObjC objects are passed as void*. DSp hands the compositor a
 *  kLayerSlotFramebuffer layer, so the compositor never sees the engine.
 */

#ifndef DSP_METAL_RENDERER_H
#define DSP_METAL_RENDERER_H

#include <stdint.h>
#include <stdbool.h>

struct DSpContextPrivate;

#ifdef __cplusplus
extern "C" {
#endif

/*
 *  Allocate the shared back-buffer MTLBuffer and a texture view over it from
 *  the kHeapCompositor bump allocator. On success ctx->back_buffer and
 *  back_texture are set and retained; on failure ctx is untouched.
 *  bpp must be 8, 16 or 32.
 */
extern bool DSpAllocateBackBuffer(struct DSpContextPrivate *ctx,
                                   uint32_t w, uint32_t h, uint32_t bpp);

/*
 *  Synchronous release: texture view first, then the buffer. Caller must
 *  ensure no frame is in flight; normal release goes through
 *  DSpQueueReleaseAtVBL.
 */
extern void DSpReleaseBackBufferNow(struct DSpContextPrivate *ctx);
extern void DSpReleaseBackBufferStaging(struct DSpContextPrivate *ctx);

/*
 *  Encode the back buffer into the framebuffer. Matching formats (32 bpp
 *  BGRA8) use a blit. Otherwise a DSp-owned render pass converts indexed
 *  1/2/4/8 bpp (R8Uint + CLUT) or 16 bpp (R16Uint xRGB1555) to BGRA8, since
 *  Metal validation rejects cross-format blits. Other pairs are logged and
 *  skipped.
 *
 *  Copies the guest-writable buffer into an immutable upload that the
 *  command buffer retains. Opens and closes its own encoder; the caller
 *  commits. On success resets dirty state (dirty_empty = true,
 *  dirty_cold_start = false, bounds zeroed). Returns false on failure.
 *
 *  command_buffer is id<MTLCommandBuffer>, framebuffer_texture is
 *  id<MTLTexture>.
 */
extern bool DSpEncodePresentToFramebuffer(struct DSpContextPrivate *ctx,
                                            void *command_buffer,
                                            void *framebuffer_texture);

extern bool DSpEncodeFrontBufferStagingToFramebuffer(struct DSpContextPrivate *ctx,
                                                      void *command_buffer,
                                                      void *framebuffer_texture);

/*
 *  Vend the back buffer's guest CGrafPort; the pointer is stable within a
 *  mode. Reserved once per context, then cached.
 *
 *  baseAddr is the back buffer itself when its contents lie inside guest
 *  RAM. Otherwise (the usual case on arm64 iOS) a same-size Mac system-heap
 *  staging region is vended, and SwapBuffers copies staging into the back
 *  buffer before the GPU blit, so the port stays guest-writable.
 *
 *  Returns 0 on failure (caller returns kDSpInternalErr).
 */
extern uint32_t DSpGetBackBufferCGrafPtr(struct DSpContextPrivate *ctx);
/* Preparation may execute guest NewPtrSys callbacks. Emission only writes
 * existing arena storage, so Queue can revalidate between the two phases. */
extern uint32_t DSpPrepareBackBufferGuestStorage(struct DSpContextPrivate *ctx);
extern uint32_t DSpEmitBackBufferCGrafPtr(struct DSpContextPrivate *ctx,
                                       uint32_t baseAddr_mac);
extern bool DSpRestoreBackBufferPixels(struct DSpContextPrivate *ctx);

/*
 *  Overrun guard for guest-RAM staging writes. Clamps `size` to the true
 *  Mac_sysalloc size of the staging block holding `mac_addr` (not its grown
 *  logical size) and logs if it had to. Returns the byte count to copy;
 *  `site` tags the log line. A short return means a heap smash was averted.
 */
extern uint32_t DSpGuardStagingWrite(uint32_t mac_addr, uint32_t size,
                                      const char *site);

#ifdef __cplusplus
}
#endif

#endif /* DSP_METAL_RENDERER_H */
