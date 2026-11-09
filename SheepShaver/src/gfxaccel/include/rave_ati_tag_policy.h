/*
 *  rave_ati_tag_policy.h - ATI RAVE private tag defaults
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef RAVE_ATI_TAG_POLICY_H
#define RAVE_ATI_TAG_POLICY_H

#include <stdint.h>

#define RAVE_ATI_TAG_COUNT 43  /* kATITriCache(0) through kATIMeshAsStrip(42) */

static constexpr uint32_t kRaveATIPrivateTagBase = 1000u;
static constexpr uint32_t kRaveATIRage128RendererID = 0x00021000u;

/*
 * Unreal Tournament's renderer picker reads ATI private int tag 1011 from a
 * probe context. A boolean 1 leaves RAVE disabled; answer the Rage 128
 * renderer ID advertised elsewhere so it takes its Rage 128 path.
 */
static constexpr uint32_t kRaveATIUnrealTournamentProbeTag = 1011u;
static constexpr uint32_t kRaveATIUnrealTournamentProbeIndex =
	kRaveATIUnrealTournamentProbeTag - kRaveATIPrivateTagBase;

static constexpr uint32_t kRaveATIRaveExtFuncsTag = 1021u;
static constexpr uint32_t kRaveATIRaveExtFuncsIndex =
	kRaveATIRaveExtFuncsTag - kRaveATIPrivateTagBase;
/*
 * The ATI table has at least 5 entries: Myth II calls slot 4 as
 * GetDrawBuffer(ctx, TQADevice*) after sync() and reads rowBytes (+4) and
 * baseAddr (+0x14). Our own table has 8 (slots 5-7 are safe stubs), but only
 * 5 slots are ever written into a caller-provided struct, the largest size a
 * real client is known to use.
 */
static constexpr uint32_t kRaveATIRaveExtFuncsEntryCount = 8u;
static constexpr uint32_t kRaveATIRaveExtFuncsKnownSlotCount = 5u;
static constexpr uint32_t kRaveATIRaveExtFuncsSlotClearDrawBuffer = 0u;
static constexpr uint32_t kRaveATIRaveExtFuncsSlotClearZBuffer = 1u;
static constexpr uint32_t kRaveATIRaveExtFuncsSlotTextureUpdate = 2u;
static constexpr uint32_t kRaveATIRaveExtFuncsSlotBindCodeBook = 3u;
static constexpr uint32_t kRaveATIRaveExtFuncsSlotGetDrawBuffer = 4u;

static constexpr uint32_t kRaveATIDepthWriteEnableTag = 1022u;
static constexpr uint32_t kRaveATIDepthWriteEnableIndex =
	kRaveATIDepthWriteEnableTag - kRaveATIPrivateTagBase;

static inline uint32_t RaveATIDefaultIntTagValue(uint32_t tag)
{
	if (tag == kRaveATIUnrealTournamentProbeTag) return kRaveATIRage128RendererID;
	if (tag == kRaveATIDepthWriteEnableTag) return 1u;
	return 0u;
}

static inline void RaveATIInitializeIntDefaults(uint32_t *intSlots,
                                                uint32_t slotCount)
{
	if (slotCount > kRaveATIUnrealTournamentProbeIndex) {
		intSlots[kRaveATIUnrealTournamentProbeIndex] =
			RaveATIDefaultIntTagValue(kRaveATIUnrealTournamentProbeTag);
	}
	if (slotCount > kRaveATIDepthWriteEnableIndex) {
		intSlots[kRaveATIDepthWriteEnableIndex] =
			RaveATIDefaultIntTagValue(kRaveATIDepthWriteEnableTag);
	}
}

#endif /* RAVE_ATI_TAG_POLICY_H */
