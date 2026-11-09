/*
 *  dsp_engine_internal.h - Private DSp helpers shared by dsp_engine.cpp and
 *                          dsp_draw_context.mm. Not exported via include/.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef DSP_ENGINE_INTERNAL_H
#define DSP_ENGINE_INTERNAL_H

#include <stdint.h>
#include "display_mode_controller.h"

#ifdef __cplusplus
extern "C" {
#endif

struct DSpContextPrivate;
struct DSpContextAttributes;
/* Prepares a changed inactive surface before the queued child is published.
 * On failure the existing surface is kept. */
int32_t DSpPrepareContextForQueue(struct DSpContextPrivate *ctx,
                                const struct DSpContextAttributes *desired);

/* DMCOwner-typed DSpMapStateToDMCOwner(). The public one returns uint32_t
 * so include/dsp_draw_context.h need not pull in the DMC header. */
static inline DMCOwner DSpMapStateToDMCOwnerTyped(uint32_t dsp_state)
{
	extern uint32_t DSpMapStateToDMCOwner(uint32_t);
	return (DMCOwner)DSpMapStateToDMCOwner(dsp_state);
}

#ifdef __cplusplus
}
#endif

#endif /* DSP_ENGINE_INTERNAL_H */
