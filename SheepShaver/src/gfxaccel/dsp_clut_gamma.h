/*
 *  dsp_clut_gamma.h - DrawSprocket CLUT + gamma get/set (sub-ops 300/301, 4xx).
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  CLUT + gamma get/set handlers (+ cores + DSpTesting_* wrappers) were
 *  extracted from dsp_draw_context.mm into dsp_clut_gamma.mm (de-bloat).
 *  The gamma FADE subsystem stays in dsp_draw_context.mm (it is coupled to the
 *  VBL machinery + context-table walk). The fade handlers reuse exactly two of
 *  the extracted cores; those are the only cross-module surface declared here.
 */

#ifndef DSP_CLUT_GAMMA_H
#define DSP_CLUT_GAMMA_H

#include <cstdint>

struct DSpContextPrivate;  /* pointer-only use; full def in dsp_context_private.h */

/* Read (last-first+1)*3 RGB bytes of the context's latched CLUT into
 * entries_out_host_range. Shared with the fade handlers (dsp_draw_context.mm). */
int32_t DSpGetCLUTCore(DSpContextPrivate *ctx,
                       uint32_t first, uint32_t last,
                       uint8_t *entries_out_host_range);

/* Parse a guest parametric RGBColor at colorAddr into 8-bit R/G/B. Shared with
 * the fade handlers (which read the fade target colour). */
void DSpReadParametricColorFromGuest(uint32_t colorAddr,
                                     uint8_t *out_r,
                                     uint8_t *out_g,
                                     uint8_t *out_b);

#endif /* DSP_CLUT_GAMMA_H */
