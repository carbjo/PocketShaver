/*
 *  dsp_clut_gamma.h - DrawSprocket CLUT get/set (sub-ops 300/301).
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  The gamma fade subsystem lives in dsp_draw_context.mm; it and the
 *  Reserve colorTable path reuse the cores declared here.
 */

#ifndef DSP_CLUT_GAMMA_H
#define DSP_CLUT_GAMMA_H

#include <cstdint>

struct DSpContextPrivate;

/* Write (last-first+1)*3 RGB bytes into the context CLUT, pushing to the
 * compositor/DMC when the context is Active. */
int32_t DSpSetCLUTCore(DSpContextPrivate *ctx,
                       uint32_t first, uint32_t last,
                       const uint8_t *entries_host_range);

/* Read (last-first+1)*3 RGB bytes of the context's latched CLUT. */
int32_t DSpGetCLUTCore(DSpContextPrivate *ctx,
                       uint32_t first, uint32_t last,
                       uint8_t *entries_out_host_range);

/* Parse a guest parametric RGBColor at colorAddr into 8-bit R/G/B. */
void DSpReadParametricColorFromGuest(uint32_t colorAddr,
                                     uint8_t *out_r,
                                     uint8_t *out_g,
                                     uint8_t *out_b);

#endif /* DSP_CLUT_GAMMA_H */
