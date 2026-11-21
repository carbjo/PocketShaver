/*
 *  rave_engine_identity.h - Advertised RAVE hardware identity
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef RAVE_ENGINE_IDENTITY_H
#define RAVE_ENGINE_IDENTITY_H

#include <stdint.h>

/*
 * Hardware IDs returned during engine enumeration, distinct from the internal
 * RAVE_ENGINE_MAGIC handle marker. Unreal Tournament's renderer picker checks
 * them, so advertise the ATI Rage 128 ID that AGL also reports.
 */
static const uint32_t kRaveAdvertisedVendorID = 1u;          // kQAVendor_ATI
static const uint32_t kRaveAdvertisedEngineID = 0x00021000u; // ATI Rage 128
static const uint32_t kRaveAdvertisedRevision = 0x00010000u; // 1.0
static const uint32_t kRaveAdvertisedTextureMemoryBytes = 64u * 1024u * 1024u;

/*
 * ATI gestalt selector 1001 (kQAGestalt_EngineSpecific_Minimum + 1): VRAM in
 * bytes. Myth II gates each resolution on width*height*4 <= VRAM, and if the
 * selector is unsupported it registers a garbage resolution record. Report
 * 32 MB so every mode we offer fits.
 */
static const uint32_t kRaveAdvertisedVRAMBytes = 32u * 1024u * 1024u;

#endif
