/*
 *  dsp_metal_renderer.h - Metal back-buffer allocation + blit encoder
 *                          for DSp.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  C-callable interface. ObjC types are passed via void*; the
 *  implementation lives in dsp_metal_renderer.mm. Pattern analog:
 *  rave_metal_renderer.h. Every DSp back-buffer uses MTLStorageModeShared,
 *  allocated through the bump sub-allocator on kHeapCompositor.
 *
 *  Compositor-blindness preserved: DSp emits a CompositeLayer POD with
 *  slot=kLayerSlotFramebuffer — compositor sees the slot + source handle
 *  only, never the engine identity.
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
 *  Allocate the back-buffer MTLBuffer + MTLTexture view through the
 *  bump sub-allocator on kHeapCompositor. Both are MTLStorageModeShared.
 *  Texture is a VIEW over the buffer memory — no separate heap allocation.
 *
 *  Returns true on success (ctx->back_buffer / back_texture populated
 *  and retained). On failure, ctx state is NOT modified — caller is
 *  responsible for error return to emulated PPC.
 *
 *  bpp must be one of {8, 16, 32}. 1/2/4 bpp is out of scope here.
 */
extern bool DSpAllocateBackBuffer(struct DSpContextPrivate *ctx,
                                   uint32_t w, uint32_t h, uint32_t bpp);

/*
 *  Synchronous release — texture FIRST, buffer SECOND (iOS ARC
 *  view-before-backing invariant). Caller must ensure no frame is in
 *  flight; the normal Release path uses the VBL-bounded queue via
 *  DSpQueueReleaseAtVBL in dsp_draw_context.mm.
 */
extern void DSpReleaseBackBufferNow(struct DSpContextPrivate *ctx);
extern void DSpReleaseBackBufferStaging(struct DSpContextPrivate *ctx);

/*
 *  Full present-to-framebuffer helper that picks the right Metal encoder
 *  based on whether ctx->back_texture and framebuffer_texture share a
 *  pixel format.
 *
 *    - Same format (e.g. both BGRA8Unorm at 32 bpp): opens a single blit
 *      command encoder on `command_buffer` and delegates to
 *      DSpEncodeBackBufferBlit. This is the 32 bpp Sims fast path.
 *
 *    - Different format (e.g. back_texture R8Uint at indexed depths or
 *      R16Uint at 16 bpp into the
 *      compositor's BGRA8Unorm framebuffer): runs a DSp-owned full-screen
 *      render pass that samples back_texture in its native pixel format
 *      and writes BGRA8Unorm to framebuffer_texture. The fragment shader
 *      source is compiled in dsp_metal_renderer.mm (DSp engine side — no
 *      new symbols in metal_compositor.{h,mm} or compositor_shaders.metal).
 *
 *  This replaces the bare `[blit copyFromTexture: ... toTexture: ...]`
 *  path that Sims's 1024x768@16bpp mode tripped on Catalyst (Metal debug
 *  blit validation rejects pixel-format-incompatible copies).
 *
 *  command_buffer is id<MTLCommandBuffer> as void*; framebuffer_texture
 *  is id<MTLTexture> as void*. The function opens/closes its own encoder
 *  on `command_buffer`; the caller is responsible for [cb commit].
 *
 *  Copies the guest-writable back buffer into an immutable upload before
 *  encoding; the command buffer retains the upload through completion.
 *  Returns false if allocation or encoding fails.
 *
 *  Dirty-state reset semantics match the back-buffer blit
 *  (ctx->dirty_empty = true, ctx->dirty_cold_start = false, dirty bounds
 *  zeroed) on every successful encode.
 *
 *  Currently supports indexed 1/2/4/8 bpp
 *  (R8Uint + per-context CLUT -> BGRA8Unorm), 16 bpp
 *  (R16Uint xRGB1555 -> BGRA8Unorm), and 32 bpp
 *  (BGRA8Unorm matched-format blit). Unsupported mismatched format pairs
 *  are logged and skipped rather than routed through a Metal-incompatible
 *  blit.
 */
extern bool DSpEncodePresentToFramebuffer(struct DSpContextPrivate *ctx,
                                            void *command_buffer,
                                            void *framebuffer_texture);

extern bool DSpEncodeFrontBufferStagingToFramebuffer(struct DSpContextPrivate *ctx,
                                                      void *command_buffer,
                                                      void *framebuffer_texture);

/*
 *  Emit a CGrafPort-shaped struct into emulated Mac RAM for
 *  GetBackBuffer vending (stable-pointer-within-mode contract).
 *  Allocates once per context via SheepMem::Reserve; subsequent calls
 *  return the cached Mac address. Populates baseAddr, rowBytes, bounds,
 *  pixelType, pixelSize, cmpCount, cmpSize per the emulated app's
 *  expectations for its depth.
 *
 *  baseAddr uses Host2MacAddr((uint8 *)ctx->back_buffer.contents) when
 *  the contents pointer falls inside the vm_alloc emulated-RAM region;
	 *  otherwise (the heap lives outside that region on arm64 iOS) the
	 *  function reserves a separate Mac system-heap staging region the same
	 *  size as the back-buffer, validates the full guest-RAM span, and
	 *  SwapBuffers memcpys staging → back_buffer before encoding the GPU
	 *  blit. The fallback path preserves
 *  guest-writable CGrafPtr semantics.
 *
 *  Returns the CGrafPort's Mac address, or 0 on failure (caller returns
 *  kDSpInternalErr).
 */
extern uint32_t DSpGetBackBufferCGrafPtr(struct DSpContextPrivate *ctx);
extern bool DSpRestoreBackBufferPixels(struct DSpContextPrivate *ctx);

/*
 *  Always-on overrun guard for guest-RAM pixel-staging writes. Looks up the
 *  staging block backing `mac_addr` and clamps `size` to the block's TRUE
 *  Mac_sysalloc allocation (never the grown logical size), logging loudly if
 *  the caller requested more than was allocated. Returns the safe byte count
 *  to pass to memcpy/memset. `site` is a short tag identifying the call site
 *  in the diagnostic log. A return < `size` means an overrun was prevented —
 *  the smoking gun for guest-heap corruption from a mis-sized staging write.
 */
extern uint32_t DSpGuardStagingWrite(uint32_t mac_addr, uint32_t size,
                                      const char *site);

#ifdef __cplusplus
}
#endif

#endif /* DSP_METAL_RENDERER_H */
