/*
 *  dsp_mode_enumerate.h - DSp mode cache + enumeration handler public API.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Builds a cache of DSpContextAttributes from VModes[] and implements the
 *  GetFirst/GetNext/FindBest enumeration handlers on it. The cache is
 *  emul-thread only (built at DSpInit, cleared at DSpShutdown), no locking.
 */

#ifndef DSP_MODE_ENUMERATE_H
#define DSP_MODE_ENUMERATE_H

#include <stdint.h>
#include <stddef.h>
#include "dsp_engine.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Called by DSpInit / DSpShutdown. Both are idempotent; build rebuilds. */
extern void    DSpBuildModesFromVModes(void);
extern void    DSpClearModes(void);

/*
 *  DSpGetFirstContext handler (sub-opcode 200), DSp 1.7 p.20.
 *
 *  Any displayID is accepted and routed to the single screen; apps pass
 *  Display Manager ids such as 256 and die if refused.
 *  outContextRefAddr == 0 -> kDSpInvalidAttributesErr; empty cache ->
 *  kDSpContextNotFoundErr. Otherwise writes a new handle for mode 0.
 */
extern int32_t DSpGetFirstContextHandler(uint32_t displayID,
                                          uint32_t outContextRefAddr);

/*
 *  DSpGetNextContext handler (sub-opcode 203). Each step vends a distinct
 *  metadata context, since apps may read every ref after the walk (p.16);
 *  stale ones are recycled when the table fills. At the end writes 0 and
 *  returns kDSpContextNotFoundErr. outContextRefAddr == 0 ->
 *  kDSpInvalidAttributesErr; unknown nonzero prevCtxRef ->
 *  kDSpInvalidContextErr.
 */
extern int32_t DSpGetNextContextHandler(uint32_t prevCtxRef,
                                         uint32_t outContextRefAddr);

/*
 *  DSpFindBestContext handler (sub-opcode 201), DSp 1.7 pp.25, 65-67.
 *
 *  attrAddr or outContextRefAddr == 0 -> kDSpInvalidAttributesErr. Reads
 *  the request at the p.65 offsets (frequency@0, displayWidth@4,
 *  displayHeight@8, colorNeeds@20, colorTable@24, contextOptions@28,
 *  backBufferDepthMask@32, displayDepthMask@36, backBufferBestDepth@40,
 *  displayBestDepth@44, pageCount@48) and matches in order: depth-mask
 *  overlap, bit-depth preference, resolution; refresh is ignored since
 *  frequency is 0. No match -> kDSpContextNotFoundErr; full handle table
 *  -> kDSpInternalErr.
 */
extern int32_t DSpFindBestContextHandler(uint32_t attrAddr,
                                          uint32_t outContextRefAddr);

/* Number of cached modes meeting the requested minimums. The caller maps
 * count > 1 to DSpCanUserSelectContext == true. */
extern size_t DSpUserSelectableModeCount(
    const DSpContextAttributes *req);

/*
 *  DSpContext_GetAttributes handler (sub-opcode 202). Defined in
 *  dsp_draw_context.mm, which owns the context table; declared here with the
 *  other enumeration handlers.
 *
 *  outAttrAddr == 0 -> kDSpInvalidAttributesErr; bad ctxRef ->
 *  kDSpInvalidContextErr. Otherwise writes ctx->attr at the DSp 1.7 p.65
 *  offsets. While Active, the back-buffer depth fields are reported as the
 *  display depth when they differ (see DSpNormalizeGetAttributesForState).
 */
extern int32_t DSpContext_GetAttributesHandler(uint32_t ctxRef,
                                                uint32_t outAttrAddr);


#ifdef __cplusplus
}
#endif

#endif /* DSP_MODE_ENUMERATE_H */
