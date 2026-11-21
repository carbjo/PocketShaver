/*
 *  dsp_mode_enumerate.cpp - VModes[] -> DSpContextAttributes transform +
 *                            DSpGetFirstContextHandler.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Emul thread only. The mode cache is built at DSpInit and cleared at the
 *  final DSpShutdown.
 */

#include "sysdeps.h"
#include "dsp_mode_enumerate.h"
#include "dsp_engine.h"
#include "dsp_draw_context.h"
#include "dsp_user_select_policy.h"
#include "cpu_emulation.h"
#include "video.h"

#include <vector>
#include <algorithm>
#include <cstring>

namespace {

/* APPLE_*_BIT -> bits per pixel; 0 if unknown. */
uint32_t AppleModeToBitDepth(uint32_t apple)
{
	switch (apple) {
		case APPLE_1_BIT:  return 1;
		case APPLE_2_BIT:  return 2;
		case APPLE_4_BIT:  return 4;
		case APPLE_8_BIT:  return 8;
		case APPLE_16_BIT: return 16;
		case APPLE_32_BIT: return 32;
		default:            return 0;
	}
}

/* Bits per pixel -> kDSpDepthMask_*; 0 if unknown. */
uint32_t DepthMaskForDepth(uint32_t d)
{
	switch (d) {
		case 1:  return kDSpDepthMask_1;
		case 2:  return kDSpDepthMask_2;
		case 4:  return kDSpDepthMask_4;
		case 8:  return kDSpDepthMask_8;
		case 16: return kDSpDepthMask_16;
		case 32: return kDSpDepthMask_32;
		default: return 0;
	}
}

std::vector<DSpContextAttributes> s_dsp_modes;

/* Scan cap in case the DIS_INVALID terminator is missing. VModes has 64
 * entries. */
const int kMaxVModesScan = 128;

bool DSpPublicModeAttributesEqual(const DSpContextAttributes &a,
                                  const DSpContextAttributes &b)
{
	return a.frequency == b.frequency &&
	       a.displayWidth == b.displayWidth &&
	       a.displayHeight == b.displayHeight &&
	       a.colorNeeds == b.colorNeeds &&
	       a.colorTable == b.colorTable &&
	       a.contextOptions == b.contextOptions &&
	       a.backBufferDepthMask == b.backBufferDepthMask &&
	       a.displayDepthMask == b.displayDepthMask &&
	       a.backBufferBestDepth == b.backBufferBestDepth &&
	       a.displayBestDepth == b.displayBestDepth &&
	       a.pageCount == b.pageCount &&
	       a.gameMustConfirmSwitch == b.gameMustConfirmSwitch;
}

}  // anonymous namespace

/*
 *  Rebuild s_dsp_modes from VModes[], skipping unknown depths and zero
 *  sizes. Modes are sorted by depth, width, height, then modes with
 *  identical public attributes are merged, so e.g. window and fullscreen
 *  640x480 do not appear as two DSp contexts.
 */
void DSpBuildModesFromVModes(void)
{
	s_dsp_modes.clear();

	int scanned = 0;
	int filtered_depth = 0;
	int filtered_zero = 0;

	for (int i = 0; i < kMaxVModesScan; i++) {
		const VideoInfo &v = VModes[i];
		if (v.viType == DIS_INVALID) break;

		scanned++;

		uint32_t depth = AppleModeToBitDepth(v.viAppleMode);
		if (depth != 1 && depth != 2 && depth != 4 && depth != 8 &&
		    depth != 16 && depth != 32) {
			filtered_depth++;
			continue;
		}
		if (v.viXsize == 0 || v.viYsize == 0) {
			filtered_zero++;
			continue;
		}

		DSpContextAttributes a;
		std::memset(&a, 0, sizeof(a));
		/* 0 means refresh rate unknown (p.66); avoids reporting ProMotion
		 * rates. */
		a.frequency            = 0;
		a.displayWidth         = (uint32_t)v.viXsize;
		a.displayHeight        = (uint32_t)v.viYsize;
		a.backBufferWidth      = (uint32_t)v.viXsize;
		a.backBufferHeight     = (uint32_t)v.viYsize;
		a.backBufferBestDepth  = depth;
		a.displayBestDepth     = depth;
		a.backBufferDepthMask  = DepthMaskForDepth(depth);
		a.displayDepthMask     = DepthMaskForDepth(depth);
		a.pageCount            = 2;
		a.colorNeeds           = (depth == 8) ? 1u /* Request */
		                                       : 2u /* Require */;
		a.contextOptions       = kDSpContextOption_PageFlip;
		s_dsp_modes.push_back(a);
	}

	/* DSp 1.7 does not define an order; keep it stable. */
	std::stable_sort(s_dsp_modes.begin(), s_dsp_modes.end(),
		[](const DSpContextAttributes &a, const DSpContextAttributes &b) {
			if (a.backBufferBestDepth != b.backBufferBestDepth)
				return a.backBufferBestDepth < b.backBufferBestDepth;
			if (a.displayWidth != b.displayWidth)
				return a.displayWidth < b.displayWidth;
			return a.displayHeight < b.displayHeight;
		});

	const size_t before_coalesce = s_dsp_modes.size();
	s_dsp_modes.erase(
	    std::unique(s_dsp_modes.begin(), s_dsp_modes.end(),
	                DSpPublicModeAttributesEqual),
	    s_dsp_modes.end());

	DSP_LOG("BuildModesFromVModes: %zu modes cached (scanned=%d, "
	        "filtered_depth=%d, filtered_zero=%d, coalesced=%zu)",
	        s_dsp_modes.size(), scanned, filtered_depth, filtered_zero,
	        before_coalesce - s_dsp_modes.size());
}

void DSpClearModes(void)
{
	s_dsp_modes.clear();
}

size_t DSpUserSelectableModeCount(const DSpContextAttributes *req)
{
	if (req == nullptr) return 0;
	return DSpCountUserSelectableContexts(s_dsp_modes.data(),
	                                      s_dsp_modes.size(), *req);
}

/* Vends a metadata-only context for s_dsp_modes[0]. */
static int32_t DSpGetFirstContext_Core(uint32_t *outHandle)
{
	if (outHandle == nullptr) return kDSpInvalidAttributesErr;

	if (s_dsp_modes.empty()) {
		DSP_LOG("GetFirstContext: mode cache empty — kDSpContextNotFoundErr");
		return kDSpContextNotFoundErr;
	}

	/* Index 0 lets DSpGetNextContext walk the rest of the modes (p.17). */
	const DSpContextAttributes *head = &s_dsp_modes[0];
	uint32_t handle = DSpAllocMetadataContextHandle(
	    head, /*enumeration_mode_index=*/0);
	if (handle == 0) {
		DSP_LOG("GetFirstContext: table full — kDSpInternalErr");
		return kDSpInternalErr;
	}

	*outHandle = handle;
	DSP_LOG("GetFirstContext: vended handle=%u %ux%u@%ubpp (enum_idx=0 of %zu)",
	        handle, head->displayWidth, head->displayHeight,
	        head->backBufferBestDepth, s_dsp_modes.size());
	return kDSpNoErr;
}

/*
 *  Sub-opcode 200. Any displayID maps to the one screen. Apps pass
 *  Display Manager IDs such as 256 and quit if no context comes back.
 */
extern "C" int32_t DSpGetFirstContextHandler(uint32_t displayID,
                                              uint32_t outContextRefAddr)
{
	if (displayID != 0) {
		DSP_LOG("GetFirstContext: displayID=%u accepted "
		        "(single-screen iOS — mapped to backing screen)",
		        displayID);
	}
	if (outContextRefAddr == 0) {
		DSP_LOG("GetFirstContext: NULL outContextRefAddr — "
		        "kDSpInvalidAttributesErr");
		return kDSpInvalidAttributesErr;
	}

	uint32_t handle = 0;
	int32_t rc = DSpGetFirstContext_Core(&handle);
	if (rc != kDSpNoErr) return rc;

	WriteMacInt32(outContextRefAddr, handle);
	return kDSpNoErr;
}


/*
 *  DSpGetNextContext (sub-opcode 203, p.17). Returns a new metadata context
 *  for the mode after prevCtxRef's. Past the last mode, or for a context not
 *  on the enumeration chain (FindBest result or Reserved), it sets
 *  *outHandle to 0 and returns kDSpContextNotFoundErr.
 */
static int32_t DSpGetNextContext_Core(uint32_t prevCtxRef, uint32_t *outHandle)
{
	/* 0 is not a valid prev ref (p.17); treat it as end of list. */
	if (prevCtxRef == 0) {
		*outHandle = 0;
		DSP_LOG("GetNextContext: prevCtxRef=0 — terminator "
		        "(kDSpContextNotFoundErr)");
		return kDSpContextNotFoundErr;
	}

	DSpContextPrivate *prev_ctx = DSpGetContext(prevCtxRef);
	if (prev_ctx == nullptr) {
		DSP_LOG("GetNextContext: invalid prevCtxRef=0x%08x — "
		        "kDSpInvalidContextErr", prevCtxRef);
		return kDSpInvalidContextErr;
	}

	/* DSpContextPrivate needs Metal headers, so read the field through the
	 * C accessor. */
	uint32_t prev_idx = DSpGetContextEnumerationIndex(prevCtxRef);

	if (prev_idx == DSP_ENUMERATION_INDEX_NONE) {
		*outHandle = 0;
		DSP_LOG("GetNextContext: prevCtxRef=%u has no enumeration cursor "
		        "(FindBest/Reserved) — terminator (kDSpContextNotFoundErr)",
		        prevCtxRef);
		return kDSpContextNotFoundErr;
	}

	/* Also covers a handle that outlived a smaller rebuilt cache. */
	size_t next_idx = (size_t)prev_idx + 1;
	if (next_idx >= s_dsp_modes.size()) {
		*outHandle = 0;
		/* Do not release prevCtxRef. Enumerated refs stay valid for
		 * GetAttributes, GetDisplayID and Flatten (p.16), and apps such as
		 * Myth II read every ref only after the walk ends. Stale enumeration
		 * contexts are recycled by DSpAllocMetadataContextHandle when the
		 * table fills. */
		DSP_LOG("GetNextContext: prevCtxRef=%u at last mode (idx=%u of %zu) "
		        "— terminator, ref stays valid; kDSpContextNotFoundErr",
		        prevCtxRef, (unsigned)prev_idx, s_dsp_modes.size());
		return kDSpContextNotFoundErr;
	}

	/* Each step vends a distinct context. Advancing one handle in place
	 * would make every earlier ref alias the last mode. Long walks fit
	 * because of DSP_MAX_CONTEXTS plus recycling. */
	const DSpContextAttributes *next_mode = &s_dsp_modes[next_idx];
	uint32_t next_handle = DSpAllocMetadataContextHandle(next_mode,
	                                                     (uint32_t)next_idx);
	if (next_handle == 0) {
		DSP_LOG("GetNextContext: metadata context alloc failed at idx=%zu "
		        "(table full, nothing recyclable) — kDSpInternalErr",
		        next_idx);
		return kDSpInternalErr;
	}

	*outHandle = next_handle;
	DSP_LOG("GetNextContext: handle=%u %ux%u@%ubpp "
	        "(enum_idx=%zu of %zu; distinct handle, prev=%u untouched)",
	        next_handle, next_mode->displayWidth, next_mode->displayHeight,
	        next_mode->backBufferBestDepth,
	        next_idx, s_dsp_modes.size(), prevCtxRef);
	return kDSpNoErr;
}

extern "C" int32_t DSpGetNextContextHandler(uint32_t prevCtxRef,
                                             uint32_t outContextRefAddr)
{
	if (outContextRefAddr == 0) {
		DSP_LOG("GetNextContext: NULL outContextRefAddr — "
		        "kDSpInvalidAttributesErr");
		return kDSpInvalidAttributesErr;
	}

	uint32_t out_handle = 0;
	int32_t rc = DSpGetNextContext_Core(prevCtxRef, &out_handle);

	/* Write 0 at end of list so the p.17 loop terminates. Validation errors
	 * leave the out-pointer untouched. */
	if (rc == kDSpNoErr || rc == kDSpContextNotFoundErr) {
		WriteMacInt32(outContextRefAddr, out_handle);
	}
	return rc;
}


/*
 *  DSpFindBestContext (sub-opcode 201). Filter by display depth mask, then
 *  pick depth (exact, else deepest >= requested, else deepest), then
 *  resolution (exact, else smallest that fits, else closest area). All
 *  modes report frequency 0, so there is no refresh-rate tiebreak.
 */

namespace {

/* Returns a pointer into s_dsp_modes, or nullptr if nothing matches the
 * depth mask. req must be non-null. */
const DSpContextAttributes *DSpFindBestContext_Core(
    const DSpContextAttributes *req)
{
	/* Depth mask filter. This picks the display mode; the requested
	 * back-buffer depth is applied later by Reserve. */
	std::vector<const DSpContextAttributes *> pool;
	pool.reserve(s_dsp_modes.size());
	const uint32_t display_depth_mask =
	    DSpUserSelectRequestedDisplayDepthMask(*req);
	for (const auto &m : s_dsp_modes) {
		uint32_t mode_depth_mask = DepthMaskForDepth(m.displayBestDepth);
		if ((display_depth_mask & mode_depth_mask) != 0) {
			pool.push_back(&m);
		}
	}
	if (pool.empty()) {
		DSP_LOG("FindBest: Tier 0 empty — req displayDepthMask=0x%08x yields "
		        "no candidates; kDSpContextNotFoundErr",
		        display_depth_mask);
		return nullptr;
	}

	/* Depth. Prefers going deeper, as in the p.25 example (320x240x16
	 * requested, 640x480x32 chosen). */
	std::vector<const DSpContextAttributes *> depth_filtered;
	depth_filtered.reserve(pool.size());
	uint32_t exact_depth = DSpUserSelectRequestedDisplayBestDepth(*req);
	for (auto *c : pool) {
		if (c->displayBestDepth == exact_depth) {
			depth_filtered.push_back(c);
		}
	}
	if (depth_filtered.empty()) {
		uint32_t best_depth = 0;
		for (auto *c : pool) {
			if (c->displayBestDepth >= exact_depth &&
			    c->displayBestDepth > best_depth) {
				best_depth = c->displayBestDepth;
			}
		}
		if (best_depth == 0) {
			/* Requested depth exceeds every mode. */
			for (auto *c : pool) {
				if (c->displayBestDepth > best_depth) {
					best_depth = c->displayBestDepth;
				}
			}
		}
		for (auto *c : pool) {
			if (c->displayBestDepth == best_depth) {
				depth_filtered.push_back(c);
			}
		}
	}
	if (depth_filtered.empty()) {
		/* Unreachable with a non-empty pool. */
		DSP_LOG("FindBest: Tier 1 unexpectedly empty — "
		        "kDSpContextNotFoundErr");
		return nullptr;
	}

	/* Resolution: exact, else smallest-area mode that fits, else closest
	 * area. */
	std::vector<const DSpContextAttributes *> resolution_filtered;
	resolution_filtered.reserve(depth_filtered.size());
	for (auto *c : depth_filtered) {
		if (c->displayWidth == req->displayWidth &&
		    c->displayHeight == req->displayHeight) {
			resolution_filtered.push_back(c);
		}
	}
	if (resolution_filtered.empty()) {
		uint64_t best_area = UINT64_MAX;
		for (auto *c : depth_filtered) {
			if (c->displayWidth >= req->displayWidth &&
			    c->displayHeight >= req->displayHeight) {
				uint64_t a = (uint64_t)c->displayWidth *
				             (uint64_t)c->displayHeight;
				if (a < best_area) best_area = a;
			}
		}
		if (best_area != UINT64_MAX) {
			for (auto *c : depth_filtered) {
				uint64_t a = (uint64_t)c->displayWidth *
				             (uint64_t)c->displayHeight;
				if (a == best_area) resolution_filtered.push_back(c);
			}
		} else {
			uint64_t req_area = (uint64_t)req->displayWidth *
			                    (uint64_t)req->displayHeight;
			uint64_t best_delta = UINT64_MAX;
			for (auto *c : depth_filtered) {
				uint64_t a = (uint64_t)c->displayWidth *
				             (uint64_t)c->displayHeight;
				uint64_t delta = a > req_area ? a - req_area
				                                : req_area - a;
				if (delta < best_delta) best_delta = delta;
			}
			for (auto *c : depth_filtered) {
				uint64_t a = (uint64_t)c->displayWidth *
				             (uint64_t)c->displayHeight;
				uint64_t delta = a > req_area ? a - req_area
				                                : req_area - a;
				if (delta == best_delta) {
					resolution_filtered.push_back(c);
				}
			}
		}
	}
	/* Non-empty by construction. */
	const DSpContextAttributes *best = resolution_filtered.front();
	DSP_LOG("FindBest: req=%ux%u back@%ubpp/bmask=0x%08x "
	        "display@%ubpp/dmask=0x%08x pc=%u => best display=%ux%u@%ubpp "
	        "(pool=%zu depth=%zu res=%zu)",
	        req->displayWidth, req->displayHeight,
	        req->backBufferBestDepth, req->backBufferDepthMask,
	        req->displayBestDepth, req->displayDepthMask, req->pageCount,
	        best->displayWidth, best->displayHeight,
	        best->displayBestDepth,
	        pool.size(), depth_filtered.size(),
	        resolution_filtered.size());
	return best;
}

/* Allocates an Inactive metadata context for *best. False if the table is
 * full. */
bool DSpFindBestContext_AllocAndWriteBack(const DSpContextAttributes *best,
                                          uint32_t *outHandle)
{
	/* Not an enumeration cursor; GetNextContext treats it as the end. */
	uint32_t handle = DSpAllocMetadataContextHandle(
	    best, DSP_ENUMERATION_INDEX_NONE);
	if (handle == 0) {
		DSP_LOG("FindBest: AllocMetadataContextHandle failed — "
		        "table full (kDSpInternalErr upstream)");
		return false;
	}
	*outHandle = handle;
	return true;
}

}  // anonymous namespace

/* Sub-opcode 201. */
extern "C" int32_t DSpFindBestContextHandler(uint32_t attrAddr,
                                              uint32_t outContextRefAddr)
{
	if (attrAddr == 0) {
		DSP_LOG("FindBest: NULL attrAddr — kDSpInvalidAttributesErr");
		return kDSpInvalidAttributesErr;
	}
	if (outContextRefAddr == 0) {
		DSP_LOG("FindBest: NULL outContextRefAddr — "
		        "kDSpInvalidAttributesErr");
		return kDSpInvalidAttributesErr;
	}

	/* Guest DSpContextAttributes, p.65 layout (same offsets as Reserve).
	 * Everything past pageCount (+48) is unused here. */
	DSpContextAttributes req = {};
	req.frequency             = ReadMacInt32(attrAddr +  0);  /* input ignored per PDF */
	req.displayWidth          = ReadMacInt32(attrAddr +  4);
	req.displayHeight         = ReadMacInt32(attrAddr +  8);
	req.reserved1             = ReadMacInt32(attrAddr + 12);
	req.reserved2             = ReadMacInt32(attrAddr + 16);
	req.colorNeeds            = ReadMacInt32(attrAddr + 20);
	req.colorTable            = ReadMacInt32(attrAddr + 24);
	req.contextOptions        = ReadMacInt32(attrAddr + 28);
	req.backBufferDepthMask   = ReadMacInt32(attrAddr + 32);
	req.displayDepthMask      = ReadMacInt32(attrAddr + 36);
	req.backBufferBestDepth   = ReadMacInt32(attrAddr + 40);
	req.displayBestDepth      = ReadMacInt32(attrAddr + 44);
	req.pageCount             = ReadMacInt32(attrAddr + 48);
	/* gameMustConfirmSwitch (+55) is ignored on input (p.67). */
	req.gameMustConfirmSwitch = 0;
	/* backBufferWidth/Height are host-only fields, not in the guest struct. */
	req.backBufferWidth       = req.displayWidth;
	req.backBufferHeight      = req.displayHeight;
	const DSpContextAttributes *best = DSpFindBestContext_Core(&req);
	if (best == nullptr) {
		return kDSpContextNotFoundErr;
	}

	uint32_t handle = 0;
	if (!DSpFindBestContext_AllocAndWriteBack(best, &handle)) {
		return kDSpInternalErr;
	}

	WriteMacInt32(outContextRefAddr, handle);
	return kDSpNoErr;
}

