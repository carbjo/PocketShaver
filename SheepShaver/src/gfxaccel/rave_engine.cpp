/*
 *  rave_engine.cpp - RAVE engine registration and callbacks
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Engine registration and the engine-level callbacks: GetMethod, Gestalt,
 *  CheckDevice, and texture/bitmap/color-table resources.
 */

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "macos_util.h"
#include "thunks.h"
#include "rave_engine.h"
#include "rave_device_summary.h"
#include "rave_engine_enable_policy.h"
#include "rave_engine_identity.h"
#include "rave_metal_renderer.h"
#include "dsp_pixmap_offsets.h"
#include "gfxaccel_resources.h"
#include "metal_compositor.h"

#include <cstring>
#include <algorithm>
#include <cmath>
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <cerrno>
#include <cstdarg>
#include <new>

#define DEBUG 0
#include "debug.h"


// Must match TQAError in RAVE.h.
#define kQANoErr                    0
#define kQAError                    1
#define kQAOutOfMemory              2
#define kQANotSupported             3
#define kQAOutOfDate                4
#define kQAParamErr                 5
#define kQAGestaltUnknown           6
#define kQADisplayModeUnsupported   7
#define kQAOutOfVideoMemory         8

// Recycled TQADrawContext Mac addresses. SheepMem::ReserveProc never frees,
// so apps that create and destroy a context every frame (RAVE Bench) would
// exhaust the 512KB SheepMem region.
static std::vector<uint32> rave_ctx_free_list;
// Every address we ever handed out, live or recycled. These must never be
// passed to the guest RAVE manager for disposal.
static std::vector<uint32> rave_ctx_owned_addresses;

static uint8_t rave_last_cl8_color_table_rgb[768];
static bool rave_last_cl8_color_table_valid = false;

static void RaveRememberCL8ColorTableSnapshot(const uint32_t *clut, uint32_t count)
{
	if (clut == nullptr || count != 256)
		return;

	for (uint32_t i = 0; i < 256; i++) {
		const uint32_t bgra = clut[i];
		rave_last_cl8_color_table_rgb[i * 3 + 0] = (uint8_t)((bgra >> 16) & 0xffu);
		rave_last_cl8_color_table_rgb[i * 3 + 1] = (uint8_t)((bgra >> 8) & 0xffu);
		rave_last_cl8_color_table_rgb[i * 3 + 2] = (uint8_t)(bgra & 0xffu);
	}
	rave_last_cl8_color_table_valid = true;
}

bool RaveGetLastCL8ColorTableRGBSnapshot(uint8_t outRGB[768])
{
	if (!rave_last_cl8_color_table_valid || outRGB == nullptr)
		return false;
	memcpy(outRGB, rave_last_cl8_color_table_rgb, sizeof(rave_last_cl8_color_table_rgb));
	return true;
}

// TQAEngineMethodTag, in RAVESystem.h order. GetMethod itself and
// MethodNameToIndex are not in this enum.
enum {
	kQADrawPrivateNew = 0,
	kQADrawPrivateDelete,        // 1
	kQAEngineCheckDevice,        // 2
	kQAEngineGestalt,            // 3
	kQATextureNew,               // 4
	kQATextureDetach,            // 5
	kQATextureDelete,            // 6
	kQABitmapNew,                // 7
	kQABitmapDetach,             // 8
	kQABitmapDelete,             // 9
	kQAColorTableNew,            // 10
	kQAColorTableDelete,         // 11
	kQATextureBindColorTable,    // 12
	kQABitmapBindColorTable,     // 13
	kQAAccessTexture,            // 14
	kQAAccessTextureEnd,         // 15
	kQAAccessBitmap,             // 16
	kQAAccessBitmapEnd,          // 17
	kQAEngineMethodTagCount = 18
};

// TQAGestaltSelector values (0-17)
enum {
	kQAGestalt_OptionalFeatures = 0,
	kQAGestalt_FastFeatures,
	kQAGestalt_VendorID,
	kQAGestalt_EngineID,
	kQAGestalt_Revision,
	kQAGestalt_ASCIINameLength,
	kQAGestalt_ASCIIName,
	kQAGestalt_TextureMemory,
	kQAGestalt_FastTextureMemory,
	kQAGestalt_DrawContextPixelTypesAllowed,
	kQAGestalt_DrawContextPixelTypesPreferred,
	kQAGestalt_TexturePixelTypesAllowed,
	kQAGestalt_TexturePixelTypesPreferred,
	kQAGestalt_BitmapPixelTypesAllowed,
	kQAGestalt_BitmapPixelTypesPreferred,
	kQAGestalt_OptionalFeatures2,
	kQAGestalt_MultiTextureMax,
	kQAGestalt_NumSelectors
};

static void RaveLogDeviceSummary(const char *label, uint32 device)
{
	if (device == 0) {
		RAVE_LOG("%s: device=NULL", label);
		return;
	}

	uint32 deviceType = ReadMacInt32(device + kRaveDeviceOff_Type);
	if (deviceType == kRaveDeviceTypeMemory) {
		uint32 rowBytes  = ReadMacInt32(device + kRaveDeviceOff_MemoryRowBytes);
		uint32 pixelType = ReadMacInt32(device + kRaveDeviceOff_MemoryPixelType);
		uint32 width     = ReadMacInt32(device + kRaveDeviceOff_MemoryWidth);
		uint32 height    = ReadMacInt32(device + kRaveDeviceOff_MemoryHeight);
		uint32 baseAddr  = ReadMacInt32(device + kRaveDeviceOff_MemoryBaseAddr);
		RAVE_LOG("%s: device=0x%08x type=%s rowBytes=%u pixelType=%u "
		         "size=%ux%u baseAddr=0x%08x",
		         label, device, RaveDeviceTypeName(deviceType),
		         rowBytes, pixelType, width, height, baseAddr);
	} else if (deviceType == kRaveDeviceTypeGDevice) {
		uint32 gdevice = ReadMacInt32(device + kRaveDeviceOff_GDeviceHandle);
		RAVE_LOG("%s: device=0x%08x type=%s gDevice=0x%08x",
		         label, device, RaveDeviceTypeName(deviceType), gdevice);
		if (gdevice != 0) {
			uint32 gdevicePtr = ReadMacInt32(gdevice);
			uint32 pixMapH = gdevicePtr != 0
				? ReadMacInt32(gdevicePtr + GDEVICE_OFF_PMAP)
				: 0;
			uint32 pixMapPtr = pixMapH != 0 ? ReadMacInt32(pixMapH) : 0;
			if (pixMapPtr != 0) {
				uint32 baseAddr = ReadMacInt32(
					pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BASEADDR);
				uint16 rbRaw = (uint16)ReadMacInt16(
					pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_ROWBYTES);
				int16 top = (int16)ReadMacInt16(
					pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_TOP);
				int16 left = (int16)ReadMacInt16(
					pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_LEFT);
				int16 bottom = (int16)ReadMacInt16(
					pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_BOT);
				int16 right = (int16)ReadMacInt16(
					pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_RIGHT);
				uint16 pixelType = (uint16)ReadMacInt16(
					pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PIXELTYPE);
				uint16 pixelSize = (uint16)ReadMacInt16(
					pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PIXELSIZE);
				uint16 cmpCount = (uint16)ReadMacInt16(
					pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_CMPCOUNT);
				uint16 cmpSize = (uint16)ReadMacInt16(
					pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_CMPSIZE);
				RAVE_LOG("%s: GDevice ptr=0x%08x pixMapH=0x%08x "
				         "pixMap=0x%08x baseAddr=0x%08x rbRaw=0x%04x "
				         "rb=%u bounds=%d,%d,%d,%d pixelType=0x%04x "
				         "pixelSize=%u cmpCount=%u cmpSize=%u",
				         label, gdevicePtr, pixMapH, pixMapPtr, baseAddr,
				         rbRaw, (unsigned)(rbRaw & 0x3FFFu),
				         (int)top, (int)left, (int)bottom, (int)right,
				         pixelType, pixelSize, cmpCount, cmpSize);
			} else {
				RAVE_LOG("%s: GDevice ptr=0x%08x pixMapH=0x%08x "
				         "pixMap=NULL", label, gdevicePtr, pixMapH);
			}
		}
	} else {
		RAVE_LOG("%s: device=0x%08x type=%s(%u)",
		         label, device, RaveDeviceTypeName(deviceType), deviceType);
	}
}

// kQAOptional_* bits, must match RAVE.h.
enum {
	kQAOptional_DeepZ               = (1 << 0),
	kQAOptional_Texture             = (1 << 1),
	kQAOptional_TextureHQ           = (1 << 2),
	kQAOptional_TextureColor        = (1 << 3),
	kQAOptional_Blend               = (1 << 4),
	kQAOptional_BlendAlpha          = (1 << 5),
	kQAOptional_Antialias           = (1 << 6),
	kQAOptional_ZSorted             = (1 << 7),
	kQAOptional_PerspectiveZ        = (1 << 8),
	kQAOptional_OpenGL              = (1 << 9),   // Extended GL features
	kQAOptional_NoClear             = (1 << 10),  // Engine doesn't clear before draw
	kQAOptional_CSG                 = (1 << 11),  // Constructive solid geometry
	kQAOptional_BoundToDevice       = (1 << 12),  // Tightly bound to GDevice
	kQAOptional_CL4                 = (1 << 13),
	kQAOptional_CL8                 = (1 << 14),
	kQAOptional_BufferComposite     = (1 << 15),  // Composite with initial buffer
	kQAOptional_NoDither            = (1 << 16),  // Can draw with no dithering
	kQAOptional_FogAlpha            = (1 << 17),
	kQAOptional_FogDepth            = (1 << 18),
	kQAOptional_MultiTextures       = (1 << 19),
	kQAOptional_MipmapBias          = (1 << 20),
	kQAOptional_ChannelMask         = (1 << 21),
	kQAOptional_ZBufferMask         = (1 << 22),
	kQAOptional_AlphaTest           = (1 << 23),
	kQAOptional_AccessTexture       = (1 << 24),
	kQAOptional_AccessBitmap        = (1 << 25),
	kQAOptional_AccessDrawBuffer    = (1 << 26),
	kQAOptional_AccessZBuffer       = (1 << 27),
	kQAOptional_ClearDrawBuffer     = (1 << 28),
	kQAOptional_ClearZBuffer        = (1 << 29),
	kQAOptional_OffscreenDrawContexts = (1 << 30)
};

// kQAOptional2_* bits, must match the RAVE 1.6 spec.
enum {
	kQAOptional2_TextureDrawContexts = (1 << 1),
	kQAOptional2_BitmapDrawContexts  = (1 << 2),
	kQAOptional2_Busy                = (1 << 3),
	kQAOptional2_SwapBuffers         = (1 << 4),
	kQAOptional2_Chromakey           = (1 << 5),
	kQAOptional2_NonRelocatable      = (1 << 6),
	kQAOptional2_NoCopy              = (1 << 7),
	kQAOptional2_PriorityBits        = (1 << 8),
	kQAOptional2_FlipOrigin          = (1 << 9),
	kQAOptional2_BitmapScale         = (1 << 10),
	kQAOptional2_DrawContextScale    = (1 << 11),
	kQAOptional2_DrawContextNonRelocatable = (1 << 12)
};

// kQAPixel_* values (bit positions in pixel type masks)
enum {
	kQAPixel_Alpha1 = 0,
	kQAPixel_RGB16 = 1,
	kQAPixel_ARGB16 = 2,
	kQAPixel_RGB32 = 3,
	kQAPixel_ARGB32 = 4,
	kQAPixel_CL4 = 5,
	kQAPixel_CL8 = 6,
	kQAPixel_RGB16_565 = 7,
	kQAPixel_RGB24 = 8,
	kQAPixel_RGB8_332 = 9,
	kQAPixel_ARGB16_4444 = 10,
	kQAPixel_ACL16_88 = 11,
	kQAPixel_I8 = 12,
	kQAPixel_AI16_88 = 13,
	// Both are 4:2:2 (unsigned vs signed UV), per QD3D 1.6 RAVE.h.
	kQAPixel_YUVS = 14,     // YUYV unsigned UV (4:2:2)
	kQAPixel_YUVU = 15,     // YUYV signed UV (4:2:2)
	kQAPixel_YUV422 = 14,   // backward-compat alias for kQAPixel_YUVS
	kQAPixel_YUV411 = 15    // alias for kQAPixel_YUVU (the old name was a misnomer)
};

// Advertised features. Bit positions must match RAVE.h exactly: a wrong bit
// 12 reads as BoundToDevice and makes QADeviceGetFirstEngine skip us.
// Not advertised: NoClear, CSG, BoundToDevice, BufferComposite, NoDither,
// OffscreenDrawContexts, and PerspectiveZ (depth is always submitted as raw
// z; 1/invW depth is not implemented).
static const uint32 kAllOptionalFeatures =
	kQAOptional_DeepZ | kQAOptional_Texture | kQAOptional_TextureHQ |
	kQAOptional_TextureColor | kQAOptional_Blend | kQAOptional_BlendAlpha |
	kQAOptional_Antialias | kQAOptional_ZSorted |
	kQAOptional_CL4 | kQAOptional_CL8 |
	kQAOptional_FogAlpha | kQAOptional_FogDepth | kQAOptional_MultiTextures |
	kQAOptional_MipmapBias | kQAOptional_ChannelMask | kQAOptional_ZBufferMask |
	kQAOptional_AlphaTest | kQAOptional_AccessTexture | kQAOptional_AccessBitmap |
	kQAOptional_AccessDrawBuffer | kQAOptional_AccessZBuffer |
	kQAOptional_ClearDrawBuffer | kQAOptional_ClearZBuffer |
	kQAOptional_OpenGL;  // games set scissor, blend and wrap through GL tags 100-153

// Advertised OptionalFeatures2.
static const uint32 kAllOptionalFeatures2 =
	kQAOptional2_TextureDrawContexts | kQAOptional2_BitmapDrawContexts |
	kQAOptional2_Busy | kQAOptional2_SwapBuffers |
	kQAOptional2_PriorityBits |
	kQAOptional2_BitmapScale;

// kQAFast_* bits, from RAVE.h. A separate bit namespace, not aliases of
// kQAOptional_*.
enum {
	kQAFast_None            = 0,
	kQAFast_Line            = (1 << 0),
	kQAFast_Gouraud         = (1 << 1),
	kQAFast_Texture         = (1 << 2),
	kQAFast_TextureHQ       = (1 << 3),
	kQAFast_Blend           = (1 << 4),
	kQAFast_Antialiasing    = (1 << 5),
	kQAFast_ZSorted         = (1 << 6),
	kQAFast_CL4             = (1 << 7),
	kQAFast_CL8             = (1 << 8),
	kQAFast_FogAlpha        = (1 << 9),
	kQAFast_FogDepth        = (1 << 10),
	kQAFast_MultiTextures   = (1 << 11),
	kQAFast_BitmapScale     = (1 << 12),
	kQAFast_DrawContextScale = (1 << 13)
};

// Metal accelerates everything, so all kQAFast bits are set.
static const uint32 kAllFastFeatures =
	kQAFast_Line | kQAFast_Gouraud | kQAFast_Texture | kQAFast_TextureHQ |
	kQAFast_Blend | kQAFast_Antialiasing | kQAFast_ZSorted |
	kQAFast_CL4 | kQAFast_CL8 |
	kQAFast_FogAlpha | kQAFast_FogDepth | kQAFast_MultiTextures |
	kQAFast_BitmapScale;

// Resource table: 1-based handles, like the draw context table.
RaveResourceEntry rave_resource_table[RAVE_MAX_RESOURCES] = {};
uint32_t rave_resource_addr_base = 0;

// Highest slot ever allocated, plus one. Lookups stop here. Never lowered on
// free, so it can't under-scan a live entry.
static uint32_t g_rave_resource_high_water = 0;
static uint32_t g_rave_resource_next_generation = 1;

// Guest-format bytes held by live textures and bitmaps, charged against the
// advertised texture memory. A full card answers kQAOutOfMemory so games can
// evict (Diablo II's texture cache allocates until it sees that error and
// treats any other error as fatal). Without the cap the 4096-slot table fills
// with ~1 GB of Metal textures first.
static uint64_t g_rave_texture_bytes_live = 0;

static uint32_t RaveTextureBudgetBytes(uint32_t rowBytes, uint32_t h, uint32_t mipLevels)
{
	uint64_t bytes = uint64_t(rowBytes) * h;
	if (mipLevels > 1) bytes += bytes / 3;
	return bytes > UINT32_MAX ? UINT32_MAX : uint32_t(bytes);
}

// An empty card still takes one oversized texture, as long as it is valid.
static bool RaveTextureBudgetAdmits(uint32_t bytes)
{
	return g_rave_texture_bytes_live == 0 ||
	       g_rave_texture_bytes_live + bytes <= kRaveAdvertisedTextureMemoryBytes;
}

static void RaveTextureBudgetCharge(RaveResourceEntry *entry, uint32_t bytes)
{
	entry->budget_bytes = bytes;
	g_rave_texture_bytes_live += bytes;
}

// Saved instructions for unpatch-call-repatch chaining
RaveHookPatchInfo rave_hook_patches[RAVE_NUM_HOOKED_APIS] = {};

/*
 *  RaveChainToOriginal - call the original function behind a hook.
 *
 *  Temporarily restores the original entry instructions, calls through the
 *  original TVECT, then re-applies the patch. A relocated-prologue
 *  trampoline would need a scratch register (r11) for the jump back, which
 *  the saved instructions may themselves use. Safe because PPC emulation is
 *  single-threaded.
 */
uint32_t RaveChainToOriginal(int hook_index, int nargs, uint32_t const *args)
{
	RaveHookPatchInfo &info = rave_hook_patches[hook_index];
	if (!info.active) {
		RAVE_LOG("CHAIN: hook %d not active, returning kQANoErr", hook_index);
		return kQANoErr;
	}

	// Restore the original entry instructions
	for (int j = 0; j < 4; j++) {
		WriteMacInt32(info.orig_code + j * 4, info.saved_instr[j]);
	}

#if EMULATED_PPC
	FlushCodeCache(info.orig_code, info.orig_code + 16);
#endif

	// Original TVECT now runs the unpatched code
	uint32_t result;
	switch (nargs) {
	case 1:
		result = call_macos1(info.orig_tvect, args[0]);
		break;
	case 2:
		result = call_macos2(info.orig_tvect, args[0], args[1]);
		break;
	case 3:
		result = call_macos3(info.orig_tvect, args[0], args[1], args[2]);
		break;
	case 4:
		result = call_macos4(info.orig_tvect, args[0], args[1], args[2], args[3]);
		break;
	case 5:
		result = call_macos5(info.orig_tvect, args[0], args[1], args[2], args[3], args[4]);
		break;
	case 6:
		result = call_macos6(info.orig_tvect, args[0], args[1], args[2], args[3], args[4], args[5]);
		break;
	default:
		RAVE_LOG("CHAIN: unsupported nargs=%d", nargs);
		result = kQANoErr;
		break;
	}

	// Re-apply the hook
	for (int j = 0; j < 4; j++) {
		WriteMacInt32(info.orig_code + j * 4, info.hook_instr[j]);
	}

#if EMULATED_PPC
	FlushCodeCache(info.orig_code, info.orig_code + 16);
#endif

	return result;
}

uint32_t RaveResourceAlloc(RaveResourceType type) {
	if (rave_resource_addr_base == 0) return 0;  // RaveThunksInit not run yet
	for (int i = 0; i < RAVE_MAX_RESOURCES; i++) {
		if (rave_resource_table[i].type == kRaveResourceFree) {
			memset(&rave_resource_table[i], 0, sizeof(RaveResourceEntry));
			rave_resource_table[i].type = type;
			rave_resource_table[i].transparent_index = -1;
			rave_resource_table[i].generation = g_rave_resource_next_generation++;
			if (g_rave_resource_next_generation == 0)
				g_rave_resource_next_generation = 1;
			// Each slot owns a fixed 4-byte Mac-visible word. SheepMem is a
			// LIFO stack shared with SheepVar, so per-resource reservations
			// could never be given back.
			uint32_t mac_addr = rave_resource_addr_base + (uint32_t)i * 4;
			rave_resource_table[i].mac_addr = mac_addr;
			// Magic value lets the delete hooks recognize our resources
			uint32_t magic = 0;
			switch (type) {
				case kRaveResourceTexture:    magic = 0x54455854; break; // 'TEXT'
				case kRaveResourceBitmap:     magic = 0x424D5050; break; // 'BMPP'
				case kRaveResourceColorTable: magic = 0x434F4C52; break; // 'COLR'
				default: break;
			}
			WriteMacInt32(mac_addr, magic);
			if ((uint32_t)(i + 1) > g_rave_resource_high_water)
				g_rave_resource_high_water = (uint32_t)(i + 1);
			return (uint32_t)(i + 1);  // 1-based handle
		}
	}
	RAVE_LOG("resource table full (%d slots)", RAVE_MAX_RESOURCES);
	return 0;
}

bool RaveResourceFree(uint32_t handle) {
	RaveFlushPendingDraws();
	if (handle == 0 || handle > RAVE_MAX_RESOURCES) return false;
	RaveResourceEntry *entry = &rave_resource_table[handle - 1];
	if (entry->type == kRaveResourceFree) return false;

	if (entry->metal_texture != nullptr) {
		RaveReleaseTexture(entry->metal_texture);
		entry->metal_texture = nullptr;
	}
	if (entry->cpu_pixel_mac_addr != 0) {
		Mac_sysfree(entry->cpu_pixel_mac_addr);
		entry->cpu_pixel_data = nullptr;
		entry->cpu_pixel_mac_addr = 0;
		entry->cpu_pixel_data_size = 0;
	}
	if (entry->original_pixels != nullptr) {
		delete[] entry->original_pixels;
		entry->original_pixels = nullptr;
	}
	if (entry->clut_data != nullptr) {
		delete[] entry->clut_data;
		entry->clut_data = nullptr;
	}
	g_rave_texture_bytes_live -= entry->budget_bytes < g_rave_texture_bytes_live
		? entry->budget_bytes : g_rave_texture_bytes_live;

	memset(entry, 0, sizeof(RaveResourceEntry));
	return true;
}

RaveResourceEntry *RaveResourceGet(uint32_t handle) {
	if (handle == 0 || handle > RAVE_MAX_RESOURCES) return nullptr;
	RaveResourceEntry *entry = &rave_resource_table[handle - 1];
	if (entry->type == kRaveResourceFree) return nullptr;
	return entry;
}

static bool RaveForgetRTTAndFreeResource(uint32_t handle)
{
	RaveResourceEntry *entry = RaveResourceGet(handle);
	if (!entry) return false;
	if (entry->type == kRaveResourceTexture || entry->type == kRaveResourceBitmap)
		RaveForgetRTTResourceHandle(handle, entry->generation);
	return RaveResourceFree(handle);
}

uint32_t RaveResourceFindByAddr(uint32_t mac_addr) {
	if (mac_addr < rave_resource_addr_base || rave_resource_addr_base == 0) return 0;
	const uint32_t offset = mac_addr - rave_resource_addr_base;
	if ((offset & 3u) != 0 || offset / 4 >= RAVE_MAX_RESOURCES) return 0;
	const uint32_t i = offset / 4;
	if (rave_resource_table[i].type == kRaveResourceFree ||
	    rave_resource_table[i].mac_addr != mac_addr) {
		return 0;
	}
	return i + 1;
}

/*
 *  First texture entry whose pixmap_mac_addr matches. Only the deferred
 *  direct-format path uses pixmap_mac_addr (Bugdom's ARGB16 sprites);
 *  bitmaps are copied eagerly.
 */
RaveResourceEntry *RaveFindTextureByPixmapAddr(uint32_t pixmapAddr)
{
	if (pixmapAddr == 0) return nullptr;
	for (int i = 0; i < RAVE_MAX_RESOURCES; i++) {
		RaveResourceEntry *e = &rave_resource_table[i];
		if (e->type == kRaveResourceTexture &&
		    e->pixmap_mac_addr == pixmapAddr) {
			return e;
		}
	}
	return nullptr;
}

/*
 *  Q3Pixmap_Set_Image intercept.
 *
 *  Copies the new pixels into the cpu_pixel_data of the RAVE texture that
 *  tracks pixmapAddr and marks it authoritative, so later realize/refresh
 *  reads from it instead of the pixmap. Most calls are unrelated to RAVE
 *  (2D PICT pixmaps) and return silently. Emul thread.
 */
void NativeHookQ3PixmapSetImage(uint32_t pixmapAddr,
                                 uint32_t srcHostAddr,
                                 uint32_t byteCount)
{
	RaveResourceEntry *entry = RaveFindTextureByPixmapAddr(pixmapAddr);
	if (!entry) {
		return;
	}
	if (!entry->cpu_pixel_data || entry->cpu_pixel_data_size == 0) {
		// TextureNew's Mac_sysalloc failed. Leave the flag unset so the
		// pixmap_mac_addr path is used.
		RAVE_LOG("Q3Pixmap_Set_Image: entry has no cpu_pixel_data buffer; "
		         "pixmap=0x%08x", pixmapAddr);
		return;
	}

	uint32_t copyBytes = byteCount;
	if (copyBytes > entry->cpu_pixel_data_size) {
		copyBytes = entry->cpu_pixel_data_size;
	}

	// srcHostAddr is actually a Mac address.
	memcpy(entry->cpu_pixel_data, Mac2HostAddr(srcHostAddr), copyBytes);

	entry->cpu_pixel_data_is_authoritative = true;

	RAVE_LOG("Q3Pixmap_Set_Image intercept: pixmap=0x%08x src=0x%08x "
	         "bytes=%u (bounded=%u) -> cpu_pixel_data_is_authoritative=true",
	         pixmapAddr, srcHostAddr, byteCount, copyBytes);
}

/*
 *  Pixel converters: big-endian Mac pixels (read via ReadMacInt*) to BGRA8.
 */

// A(31:24) R(23:16) G(15:8) B(7:0)
static void ConvertARGB32(uint32 srcAddr, uint8_t *dst, uint32_t width, uint32_t height, uint32_t rowBytes)
{
	for (uint32_t y = 0; y < height; y++) {
		uint32 rowAddr = srcAddr + y * rowBytes;
		for (uint32_t x = 0; x < width; x++) {
			uint32_t argb = ReadMacInt32(rowAddr + x * 4);
			uint8_t a = (argb >> 24) & 0xFF;
			uint8_t r = (argb >> 16) & 0xFF;
			uint8_t g = (argb >> 8) & 0xFF;
			uint8_t b = argb & 0xFF;
			uint32_t idx = (y * width + x) * 4;
			dst[idx + 0] = b;
			dst[idx + 1] = g;
			dst[idx + 2] = r;
			dst[idx + 3] = a;
		}
	}
}

// As ARGB32, top byte ignored, alpha 0xFF.
static void ConvertRGB32(uint32 srcAddr, uint8_t *dst, uint32_t width, uint32_t height, uint32_t rowBytes)
{
	for (uint32_t y = 0; y < height; y++) {
		uint32 rowAddr = srcAddr + y * rowBytes;
		for (uint32_t x = 0; x < width; x++) {
			uint32_t xrgb = ReadMacInt32(rowAddr + x * 4);
			uint8_t r = (xrgb >> 16) & 0xFF;
			uint8_t g = (xrgb >> 8) & 0xFF;
			uint8_t b = xrgb & 0xFF;
			uint32_t idx = (y * width + x) * 4;
			dst[idx + 0] = b;
			dst[idx + 1] = g;
			dst[idx + 2] = r;
			dst[idx + 3] = 0xFF;
		}
	}
}

// A(15) R(14:10) G(9:5) B(4:0). 5->8 bits via (x<<3)|(x>>2).
static void ConvertARGB16(uint32 srcAddr, uint8_t *dst, uint32_t width, uint32_t height, uint32_t rowBytes)
{
	for (uint32_t y = 0; y < height; y++) {
		uint32 rowAddr = srcAddr + y * rowBytes;
		for (uint32_t x = 0; x < width; x++) {
			uint16_t val = (uint16_t)ReadMacInt16(rowAddr + x * 2);
			uint8_t a = (val >> 15) & 1;
			uint8_t r = (val >> 10) & 0x1F;
			uint8_t g = (val >> 5) & 0x1F;
			uint8_t b = val & 0x1F;
			uint8_t r8 = (r << 3) | (r >> 2);
			uint8_t g8 = (g << 3) | (g >> 2);
			uint8_t b8 = (b << 3) | (b >> 2);
			uint8_t a8 = a ? 0xFF : 0x00;
			uint32_t idx = (y * width + x) * 4;
			dst[idx + 0] = b8;
			dst[idx + 1] = g8;
			dst[idx + 2] = r8;
			dst[idx + 3] = a8;
		}
	}
}

// As ARGB16, top bit ignored, alpha 0xFF.
static void ConvertRGB16(uint32 srcAddr, uint8_t *dst, uint32_t width, uint32_t height, uint32_t rowBytes)
{
	for (uint32_t y = 0; y < height; y++) {
		uint32 rowAddr = srcAddr + y * rowBytes;
		for (uint32_t x = 0; x < width; x++) {
			uint16_t val = (uint16_t)ReadMacInt16(rowAddr + x * 2);
			uint8_t r = (val >> 10) & 0x1F;
			uint8_t g = (val >> 5) & 0x1F;
			uint8_t b = val & 0x1F;
			uint8_t r8 = (r << 3) | (r >> 2);
			uint8_t g8 = (g << 3) | (g >> 2);
			uint8_t b8 = (b << 3) | (b >> 2);
			uint32_t idx = (y * width + x) * 4;
			dst[idx + 0] = b8;
			dst[idx + 1] = g8;
			dst[idx + 2] = r8;
			dst[idx + 3] = 0xFF;
		}
	}
}

// R(7:5) G(4:2) B(1:0), alpha 0xFF.
static void ConvertRGB8_332(uint32 srcAddr, uint8_t *dst, uint32_t width, uint32_t height, uint32_t rowBytes)
{
	for (uint32_t y = 0; y < height; y++) {
		uint32 rowAddr = srcAddr + y * rowBytes;
		for (uint32_t x = 0; x < width; x++) {
			uint8_t val = ReadMacInt8(rowAddr + x);
			uint8_t r3 = (val >> 5) & 0x07;
			uint8_t g3 = (val >> 2) & 0x07;
			uint8_t b2 = val & 0x03;
			uint8_t r8 = (r3 << 5) | (r3 << 2) | (r3 >> 1);
			uint8_t g8 = (g3 << 5) | (g3 << 2) | (g3 >> 1);
			uint8_t b8 = (b2 << 6) | (b2 << 4) | (b2 << 2) | b2;
			uint32_t idx = (y * width + x) * 4;
			dst[idx + 0] = b8;
			dst[idx + 1] = g8;
			dst[idx + 2] = r8;
			dst[idx + 3] = 0xFF;
		}
	}
}

// A(15:12) R(11:8) G(7:4) B(3:0). 4->8 bits via (n<<4)|n.
static void ConvertARGB16_4444(uint32 srcAddr, uint8_t *dst, uint32_t width, uint32_t height, uint32_t rowBytes)
{
	for (uint32_t y = 0; y < height; y++) {
		uint32 rowAddr = srcAddr + y * rowBytes;
		for (uint32_t x = 0; x < width; x++) {
			uint16_t val = (uint16_t)ReadMacInt16(rowAddr + x * 2);
			uint8_t a4 = (val >> 12) & 0x0F;
			uint8_t r4 = (val >> 8) & 0x0F;
			uint8_t g4 = (val >> 4) & 0x0F;
			uint8_t b4 = val & 0x0F;
			uint32_t idx = (y * width + x) * 4;
			dst[idx + 0] = (b4 << 4) | b4;
			dst[idx + 1] = (g4 << 4) | g4;
			dst[idx + 2] = (r4 << 4) | r4;
			dst[idx + 3] = (a4 << 4) | a4;
		}
	}
}

// 8-bit intensity: B=G=R=I, alpha 0xFF.
static void ConvertI8(uint32 srcAddr, uint8_t *dst, uint32_t width, uint32_t height, uint32_t rowBytes)
{
	for (uint32_t y = 0; y < height; y++) {
		uint32 rowAddr = srcAddr + y * rowBytes;
		for (uint32_t x = 0; x < width; x++) {
			uint8_t i = ReadMacInt8(rowAddr + x);
			uint32_t idx = (y * width + x) * 4;
			dst[idx + 0] = i;
			dst[idx + 1] = i;
			dst[idx + 2] = i;
			dst[idx + 3] = 0xFF;
		}
	}
}

// A(15:8) I(7:0).
static void ConvertAI16_88(uint32 srcAddr, uint8_t *dst, uint32_t width, uint32_t height, uint32_t rowBytes)
{
	for (uint32_t y = 0; y < height; y++) {
		uint32 rowAddr = srcAddr + y * rowBytes;
		for (uint32_t x = 0; x < width; x++) {
			uint16_t val = (uint16_t)ReadMacInt16(rowAddr + x * 2);
			uint8_t a = (val >> 8) & 0xFF;
			uint8_t i = val & 0xFF;
			uint32_t idx = (y * width + x) * 4;
			dst[idx + 0] = i;
			dst[idx + 1] = i;
			dst[idx + 2] = i;
			dst[idx + 3] = a;
		}
	}
}

// Box-filter the level-0 BGRA8 image down the mip chain and upload each level.
// Apps' own mip TQAImages can't be trusted: UT doesn't supply a valid chain at
// the level count we compute, which gave black distant surfaces and dropped
// the 1-bit alpha of its ARGB16 mips.
static void RaveUploadGeneratedMips(void *metalTexture, const uint8_t *level0,
                                    uint32_t w, uint32_t h, uint32_t mipLevels)
{
	if (!metalTexture || mipLevels <= 1 || !level0)
		return;

	uint32_t sw = w, sh = h;
	const uint8_t *src = level0;       // caller-owned
	uint8_t *prevOwned = nullptr;      // our buffer for the previous level

	// One pass break for the whole chain, not one per level.
	RaveTextureUploadBatchBegin();

	for (uint32_t level = 1; level < mipLevels; level++) {
		uint32_t dw = (sw > 1) ? sw / 2 : 1;
		uint32_t dh = (sh > 1) ? sh / 2 : 1;
		uint8_t *dst = new uint8_t[(size_t)dw * dh * 4];

		for (uint32_t y = 0; y < dh; y++) {
			uint32_t y0 = y * 2;
			uint32_t y1 = (y0 + 1 < sh) ? y0 + 1 : y0;
			for (uint32_t x = 0; x < dw; x++) {
				uint32_t x0 = x * 2;
				uint32_t x1 = (x0 + 1 < sw) ? x0 + 1 : x0;
				const uint8_t *p00 = &src[(y0 * sw + x0) * 4];
				const uint8_t *p01 = &src[(y0 * sw + x1) * 4];
				const uint8_t *p10 = &src[(y1 * sw + x0) * 4];
				const uint8_t *p11 = &src[(y1 * sw + x1) * 4];
				uint8_t *d = &dst[(y * dw + x) * 4];
				for (int c = 0; c < 4; c++)
					d[c] = (uint8_t)(((uint32_t)p00[c] + p01[c] + p10[c] + p11[c]) >> 2);
			}
		}

		RaveUploadMipLevel(metalTexture, level, dw, dh, dst, dw * 4);

		if (prevOwned) delete[] prevOwned;
		prevOwned = dst;
		src = dst;
		sw = dw;
		sh = dh;
	}

	RaveTextureUploadBatchEnd();

	if (prevOwned) delete[] prevOwned;
}


// A(15:8) CLUT index(7:0), alpha from the pixel. Reads the native copy in
// original_pixels, which holds the big-endian bytes.
static void ExpandACL16_88(const uint8_t *srcBuf, uint8_t *dst, uint32_t width, uint32_t height,
                           uint32_t rowBytes, const uint32_t *clut, uint32_t clutCount)
{
	for (uint32_t y = 0; y < height; y++) {
		for (uint32_t x = 0; x < width; x++) {
			uint32_t off = y * rowBytes + x * 2;
			uint8_t a = srcBuf[off];
			uint8_t idx = srcBuf[off + 1];
			if (idx >= clutCount) idx = 0;
			uint32_t bgra = clut[idx];
			uint32_t dstIdx = (y * width + x) * 4;
			dst[dstIdx + 0] = bgra & 0xFF;
			dst[dstIdx + 1] = (bgra >> 8) & 0xFF;
			dst[dstIdx + 2] = (bgra >> 16) & 0xFF;
			dst[dstIdx + 3] = a;
		}
	}
}


// BT.601 YUYV to BGRA8. Two pixels per 4 bytes, Mac byte order Y0 U Y1 V.
static inline uint8_t clamp_u8(int v)
{
	return (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
}

static void ConvertYUVS(uint32 srcAddr, uint8_t *dst,
                        uint32_t width, uint32_t height, uint32_t rowBytes)
{
	// Need 2 bytes per pixel per row
	if (width > 0 && rowBytes < width * 2) {
		memset(dst, 0, (size_t)width * height * 4);
		return;
	}
	for (uint32_t y = 0; y < height; y++) {
		uint32 rowAddr = srcAddr + y * rowBytes;
		for (uint32_t x = 0; x < width; x += 2) {
			uint8_t Y0 = ReadMacInt8(rowAddr + x * 2 + 0);
			uint8_t U  = ReadMacInt8(rowAddr + x * 2 + 1);
			uint8_t Y1 = ReadMacInt8(rowAddr + x * 2 + 2);
			uint8_t V  = ReadMacInt8(rowAddr + x * 2 + 3);

			int cr = V - 128;
			int cb = U - 128;
			for (int p = 0; p < 2; p++) {
				if (x + p >= width) break;  // handle odd widths
				int Yp = (p == 0) ? Y0 : Y1;
				int r = Yp + (int)(1.402f * cr);
				int g = Yp - (int)(0.344f * cb) - (int)(0.714f * cr);
				int b = Yp + (int)(1.772f * cb);
				uint32_t idx = (y * width + x + p) * 4;
				dst[idx + 0] = clamp_u8(b);
				dst[idx + 1] = clamp_u8(g);
				dst[idx + 2] = clamp_u8(r);
				dst[idx + 3] = 0xFF;
			}
		}
	}
}

// As YUVS, but U and V are signed bytes, so no -128 bias.
static void ConvertYUVU(uint32 srcAddr, uint8_t *dst,
                        uint32_t width, uint32_t height, uint32_t rowBytes)
{
	// Need 2 bytes per pixel per row
	if (width > 0 && rowBytes < width * 2) {
		memset(dst, 0, (size_t)width * height * 4);
		return;
	}
	for (uint32_t y = 0; y < height; y++) {
		uint32 rowAddr = srcAddr + y * rowBytes;
		for (uint32_t x = 0; x < width; x += 2) {
			uint8_t Y0 = ReadMacInt8(rowAddr + x * 2 + 0);
			uint8_t U  = ReadMacInt8(rowAddr + x * 2 + 1);
			uint8_t Y1 = ReadMacInt8(rowAddr + x * 2 + 2);
			uint8_t V  = ReadMacInt8(rowAddr + x * 2 + 3);

			int cr = (int8_t)V;
			int cb = (int8_t)U;
			for (int p = 0; p < 2; p++) {
				if (x + p >= width) break;  // handle odd widths
				int Yp = (p == 0) ? Y0 : Y1;
				int r = Yp + (int)(1.402f * cr);
				int g = Yp - (int)(0.344f * cb) - (int)(0.714f * cr);
				int b = Yp + (int)(1.772f * cb);
				uint32_t idx = (y * width + x + p) * 4;
				dst[idx + 0] = clamp_u8(b);
				dst[idx + 1] = clamp_u8(g);
				dst[idx + 2] = clamp_u8(r);
				dst[idx + 3] = 0xFF;
			}
		}
	}
}


/*
 *  ConvertPixels - returns false for indexed formats (they need a CLUT) and
 *  unsupported ones.
 */
bool ConvertPixels(uint32_t pixelType, uint32 srcAddr, uint8_t *dst,
                          uint32_t width, uint32_t height, uint32_t rowBytes)
{
	bool converted = true;
	switch (pixelType) {
		case kQAPixel_ARGB32:
			ConvertARGB32(srcAddr, dst, width, height, rowBytes);
			break;
		case kQAPixel_RGB32:
			ConvertRGB32(srcAddr, dst, width, height, rowBytes);
			break;
		case kQAPixel_ARGB16:
			ConvertARGB16(srcAddr, dst, width, height, rowBytes);
			break;
		case kQAPixel_RGB16:
			ConvertRGB16(srcAddr, dst, width, height, rowBytes);
			break;
		case kQAPixel_RGB8_332:
			ConvertRGB8_332(srcAddr, dst, width, height, rowBytes);
			break;
		case kQAPixel_ARGB16_4444:
			ConvertARGB16_4444(srcAddr, dst, width, height, rowBytes);
			break;
		case kQAPixel_I8:
			ConvertI8(srcAddr, dst, width, height, rowBytes);
			break;
		case kQAPixel_AI16_88:
			ConvertAI16_88(srcAddr, dst, width, height, rowBytes);
			break;
		case kQAPixel_YUVS:
			ConvertYUVS(srcAddr, dst, width, height, rowBytes);
			break;
		case kQAPixel_YUVU:
			ConvertYUVU(srcAddr, dst, width, height, rowBytes);
			break;
		// Not converted: Alpha1 is unused by Mac OS 9 apps; RGB16_565 and
		// RGB24 are Win32-only per RAVE.h.
		case kQAPixel_Alpha1:
		case kQAPixel_RGB16_565:
		case kQAPixel_RGB24:
			converted = false;
			break;
		default:
			converted = false;  // indexed
			break;
	}

	return converted;
}



/*
 *  Texture creation, shared by the hook path (NativeHookTextureNew) and the
 *  engine path (NativeEngineTextureNew).
 */
static bool RaveImageLayoutIsValid(uint32_t pixelType, uint32_t width, uint32_t height,
                                   uint32_t rowBytes, uint32_t pixels)
{
	if (!width || !height || width > 16384 || height > 16384 || !pixels) return false;
	uint64_t minimumRow;
	switch (pixelType) {
		case kQAPixel_Alpha1: minimumRow = (uint64_t(width) + 7) / 8; break;
		case kQAPixel_CL4: minimumRow = (uint64_t(width) + 1) / 2; break;
		case kQAPixel_CL8: case kQAPixel_RGB8_332: case kQAPixel_I8:
			minimumRow = width; break;
		case kQAPixel_RGB16: case kQAPixel_ARGB16: case kQAPixel_RGB16_565:
		case kQAPixel_ARGB16_4444: case kQAPixel_ACL16_88: case kQAPixel_AI16_88:
			minimumRow = uint64_t(width) * 2; break;
		case kQAPixel_RGB24: minimumRow = uint64_t(width) * 3; break;
		case kQAPixel_RGB32: case kQAPixel_ARGB32:
			minimumRow = uint64_t(width) * 4; break;
		case kQAPixel_YUVS: case kQAPixel_YUVU:
			// The converter reads a complete YUYV pair, even for an odd width.
			minimumRow = ((uint64_t(width) + 1) / 2) * 4; break;
		default: return false;
	}
	const uint64_t size = uint64_t(rowBytes) * height;
	return rowBytes >= minimumRow && size <= UINT32_MAX &&
	       uint64_t(pixels) + size <= uint64_t(UINT32_MAX) + 1;
}

static int32_t RaveCreateTextureFromImages(uint32_t flags, uint32_t pixelType,
                                         uint32 imagesAddr, RaveResourceEntry *entry)
{
	if (!imagesAddr || uint64_t(imagesAddr) + 16 > uint64_t(UINT32_MAX) + 1) return kQAParamErr;
	// Level-0 TQAImage: width, height, rowBytes, pixmap
	uint32_t w        = ReadMacInt32(imagesAddr + 0);
	uint32_t h        = ReadMacInt32(imagesAddr + 4);
	uint32_t rowBytes = ReadMacInt32(imagesAddr + 8);
	uint32_t pixmap   = ReadMacInt32(imagesAddr + 12);
	if (!RaveImageLayoutIsValid(pixelType, w, h, rowBytes, pixmap)) return kQAParamErr;

	// 4-bit priority in bits 31:28 (QACalculatePriorityBits)
	entry->priority = (uint8_t)((flags >> 28) & 0xF);

	bool hasMipmaps = (flags & 2);  // kQATexture_Mipmap
	uint32_t mipLevels = 1;
	if (hasMipmaps) {
		uint32_t maxDim = (w > h) ? w : h;
		mipLevels = (uint32_t)floor(log2((double)maxDim)) + 1;
	}

	const uint32_t budgetBytes = RaveTextureBudgetBytes(rowBytes, h, mipLevels);
	if (!RaveTextureBudgetAdmits(budgetBytes)) {
		RAVE_LOG("TextureNew %ux%u (%u bytes) -> kQAOutOfMemory, %llu bytes live",
		         w, h, budgetBytes, (unsigned long long)g_rave_texture_bytes_live);
		return kQAOutOfMemory;
	}

	entry->pixel_type = pixelType;
	entry->width      = w;
	entry->height     = h;
	entry->mip_levels = mipLevels;
	entry->row_bytes  = rowBytes;

	// Set by NativeHookQ3PixmapSetImage when an intercept fills this texture.
	entry->cpu_pixel_data_is_authoritative = false;

	bool isIndexed = (pixelType == kQAPixel_CL8 || pixelType == kQAPixel_CL4 || pixelType == kQAPixel_ACL16_88);

	if (isIndexed) {
		// Copy now. The spec allows waiting until TextureDetach, but games
		// such as Tomb Raider reuse the buffer right after TextureNew. Only
		// level 0 is read; mips are generated after CLUT expansion.
		const uint32_t totalSize = uint32_t(uint64_t(rowBytes) * h);
		entry->original_pixels = new (std::nothrow) uint8_t[totalSize];
		if (!entry->original_pixels) return kQAOutOfMemory;
		entry->original_size = totalSize;
		entry->pixels_copied = true;

		Mac2Host_memcpy(entry->original_pixels, pixmap, totalSize);

		// Metal texture is created at BindColorTable
		entry->metal_texture = nullptr;
		RAVE_LOG("TextureNew indexed (pixelType=%d) %dx%d mips=%d rowBytes=%d pixmap=0x%08x",
		       pixelType, w, h, mipLevels, rowBytes, pixmap);
	} else {
		// Direct format. Snapshot now when level 0 converts; otherwise defer
		// for clients that fill the buffer after TextureNew.
		entry->pixmap_mac_addr = pixmap;
		entry->metal_texture = nullptr;
		entry->pixels_copied = false;

		uint8_t *expanded = new (std::nothrow) uint8_t[size_t(w) * h * 4]();
		if (!expanded) return kQAOutOfMemory;
		const bool converted = ConvertPixels(pixelType, pixmap, expanded, w, h, rowBytes);
		const bool whitenedAlphaMask =
			(pixelType == kQAPixel_ARGB32) && RaveBGRAWhitenAlphaOnlyMask(expanded, w * h);
		RaveBGRAImageStats sourceStats = converted
			? RaveBGRAImageAnalyze(expanded, w * h)
			: RaveBGRAImageStats{0, 0, 0, 0, w * h, w * h, w * h};
		entry->diag_alpha_zero = (w * h) - sourceStats.alpha;
		entry->diag_index_zero = 0;
		entry->diag_rgb_nonzero = sourceStats.rgb;
		// TextureNew has copy semantics: snapshot level 0 now so later reuse
		// of the guest's staging buffer can't corrupt it. Fill-after-create
		// clients go through the texture-update path.
		const bool snapshotNow = converted;

		if (snapshotNow) {
			entry->metal_texture = RaveCreateMetalTexture(w, h, mipLevels, expanded, w * 4);
			if (mipLevels > 1 && entry->metal_texture) {
				// Generate mips from level 0, not the app's mip images.
				RaveUploadGeneratedMips(entry->metal_texture, expanded, w, h, mipLevels);
			}
			entry->pixels_copied = (entry->metal_texture != nullptr);
			RAVE_LOG("TextureNew direct snapshot (pixelType=%d) %dx%d mips=%d pixmap=0x%08x -> metal=%p nz=%u a=%u rgb=%u white=%u first[nz/a/rgb]=%u/%u/%u alphaMaskWhite=%d",
			         pixelType, w, h, mipLevels, pixmap, entry->metal_texture,
			         sourceStats.nonzero, sourceStats.alpha, sourceStats.rgb, sourceStats.white,
			         sourceStats.first_nonzero, sourceStats.first_alpha, sourceStats.first_rgb,
			         whitenedAlphaMask);
		} else {
			// Deferred realization also generates mips from level zero.
			RAVE_LOG("TextureNew unconverted (pixelType=%d) %dx%d mips=%d pixmap=0x%08x converted=%d",
			         pixelType, w, h, mipLevels, pixmap, converted ? 1 : 0);
		}
		delete[] expanded;
	}

	// Mac-side level-0 copy for AccessTexture.
	uint32_t cpuBufSize = rowBytes * h;
	uint32_t cpuMacAddr = Mac_sysalloc(cpuBufSize);
	if (cpuMacAddr != 0) {
		entry->cpu_pixel_mac_addr = cpuMacAddr;
		entry->cpu_pixel_data = Mac2HostAddr(cpuMacAddr);
		entry->cpu_pixel_data_size = cpuBufSize;
		Host2Mac_memcpy(cpuMacAddr, Mac2HostAddr(pixmap), cpuBufSize);
		RAVE_LOG("TextureNew cpu_pixel_data at Mac 0x%08x (%d bytes)",
		       cpuMacAddr, cpuBufSize);
	} else {
		RAVE_LOG("TextureNew WARN: Mac_sysalloc(%d) failed for cpu_pixel_data", cpuBufSize);
	}
	RaveTextureBudgetCharge(entry, budgetBytes);
	return kQANoErr;
}


/*
 *  RaveRealizeDeferredTexture - create the Metal texture for a deferred
 *  direct-format texture at its first draw (from ApplyDirtyState). By then
 *  QD3D has written the real pixels.
 */
void RaveRealizeDeferredTexture(RaveResourceEntry *entry)
{
	if (!entry || entry->metal_texture || entry->pixmap_mac_addr == 0) return;

	uint32_t w = entry->width;
	uint32_t h = entry->height;
	uint32_t pixelType = entry->pixel_type;
	uint32_t rowBytes = entry->row_bytes;
	uint32_t mipLevels = entry->mip_levels;

	// Prefer cpu_pixel_data when a Q3Pixmap_Set_Image intercept filled it:
	// Bugdom's sprite buffers are transient and pixmap_mac_addr may already
	// hold recycled heap data. Titles with persistent buffers use the pixmap.
	uint32_t pixmap = entry->pixmap_mac_addr;
	if (entry->cpu_pixel_data_is_authoritative &&
	    entry->cpu_pixel_mac_addr != 0 &&
	    entry->cpu_pixel_data_size > 0) {
		pixmap = entry->cpu_pixel_mac_addr;
	}

	uint8_t *expanded = new uint8_t[w * h * 4];
	ConvertPixels(pixelType, pixmap, expanded, w, h, rowBytes);
	const bool whitenedAlphaMask =
		(pixelType == kQAPixel_ARGB32) && RaveBGRAWhitenAlphaOnlyMask(expanded, w * h);

	// Check the whole image. Bugdom's ARGB16 sprites often have transparent
	// top-left borders, so sampling a prefix would misjudge them as empty.
	RaveBGRAImageStats sourceStats = RaveBGRAImageAnalyze(expanded, w * h);
	bool sourceWasEmpty = (sourceStats.nonzero == 0);
	entry->diag_alpha_zero = (w * h) - sourceStats.alpha;
	entry->diag_index_zero = 0;
	entry->diag_rgb_nonzero = sourceStats.rgb;

	entry->metal_texture = RaveCreateMetalTexture(w, h, mipLevels, expanded, w * 4);

	if (mipLevels > 1 && entry->metal_texture) {
		// Generate mips from level 0; the cached mip TQAImages are stale here.
		RaveUploadGeneratedMips(entry->metal_texture, expanded, w, h, mipLevels);
	}

	delete[] expanded;

	if (entry->cpu_pixel_data && entry->cpu_pixel_mac_addr) {
		Host2Mac_memcpy(entry->cpu_pixel_mac_addr, Mac2HostAddr(pixmap), entry->cpu_pixel_data_size);
	}

	// Once non-empty data has been seen, the Metal copy is authoritative.
	// If the first realization was empty, RaveTextureNeedsLivePixmapRefresh
	// keeps polling until the late-filled pixels appear.
	entry->pixels_copied = !sourceWasEmpty;

	RAVE_LOG("TextureRealize: pixelType=%d %dx%d mips=%d pixmap=0x%08x -> metal=%p empty=%d nz=%u a=%u rgb=%u white=%u first[nz/a/rgb]=%u/%u/%u alphaMaskWhite=%d",
	         pixelType, w, h, mipLevels, pixmap, entry->metal_texture, sourceWasEmpty,
	         sourceStats.nonzero, sourceStats.alpha, sourceStats.rgb, sourceStats.white,
	         sourceStats.first_nonzero, sourceStats.first_alpha, sourceStats.first_rgb,
	         whitenedAlphaMask);
}


/*
 *  Bitmap creation: like a texture, single level.
 */
static int32_t RaveCreateBitmapFromImage(uint32_t pixelType, uint32 imageAddr,
                                       RaveResourceEntry *entry)
{
	if (!imageAddr || uint64_t(imageAddr) + 16 > uint64_t(UINT32_MAX) + 1) return kQAParamErr;
	uint32_t w        = ReadMacInt32(imageAddr + 0);
	uint32_t h        = ReadMacInt32(imageAddr + 4);
	uint32_t rowBytes = ReadMacInt32(imageAddr + 8);
	uint32_t pixmap   = ReadMacInt32(imageAddr + 12);
	if (!RaveImageLayoutIsValid(pixelType, w, h, rowBytes, pixmap)) return kQAParamErr;

	const uint32_t budgetBytes = RaveTextureBudgetBytes(rowBytes, h, 1);
	if (!RaveTextureBudgetAdmits(budgetBytes)) {
		RAVE_LOG("BitmapNew %ux%u (%u bytes) -> kQAOutOfMemory, %llu bytes live",
		         w, h, budgetBytes, (unsigned long long)g_rave_texture_bytes_live);
		return kQAOutOfMemory;
	}

	entry->pixel_type = pixelType;
	entry->width      = w;
	entry->height     = h;
	entry->mip_levels = 1;
	entry->row_bytes  = rowBytes;

	bool isIndexed = (pixelType == kQAPixel_CL8 || pixelType == kQAPixel_CL4 || pixelType == kQAPixel_ACL16_88);

	if (isIndexed) {
		uint32_t totalSize = rowBytes * h;
		entry->original_pixels = new (std::nothrow) uint8_t[totalSize];
		if (!entry->original_pixels) return kQAOutOfMemory;
		entry->original_size = totalSize;
		entry->pixels_copied = true;
		for (uint32_t b = 0; b < totalSize; b++) {
			entry->original_pixels[b] = ReadMacInt8(pixmap + b);
		}
		entry->metal_texture = nullptr;
		RAVE_LOG("BitmapNew indexed (pixelType=%d) %dx%d rowBytes=%d pixmap=0x%08x",
		       pixelType, w, h, rowBytes, pixmap);
	} else {
		uint8_t *expanded = new (std::nothrow) uint8_t[size_t(w) * h * 4]();
		if (!expanded) return kQAOutOfMemory;
		ConvertPixels(pixelType, pixmap, expanded, w, h, rowBytes);
		entry->metal_texture = RaveCreateMetalTexture(w, h, 1, expanded, w * 4);
		delete[] expanded;
		RAVE_LOG("BitmapNew direct (pixelType=%d) %dx%d -> metal=%p",
		       pixelType, w, h, entry->metal_texture);
	}

	// Mac-side copy for AccessBitmap
	uint32_t cpuBufSize = rowBytes * h;
	uint32_t cpuMacAddr = Mac_sysalloc(cpuBufSize);
	if (cpuMacAddr != 0) {
		entry->cpu_pixel_mac_addr = cpuMacAddr;
		entry->cpu_pixel_data = Mac2HostAddr(cpuMacAddr);
		entry->cpu_pixel_data_size = cpuBufSize;
		Host2Mac_memcpy(cpuMacAddr, Mac2HostAddr(pixmap), cpuBufSize);
		RAVE_LOG("BitmapNew cpu_pixel_data at Mac 0x%08x (%d bytes)",
		       cpuMacAddr, cpuBufSize);
	} else {
		RAVE_LOG("BitmapNew WARN: Mac_sysalloc(%d) failed for cpu_pixel_data", cpuBufSize);
	}
	RaveTextureBudgetCharge(entry, budgetBytes);
	return kQANoErr;
}


static void RaveCreateColorTableData(uint32_t tableType, uint32 pixelDataAddr,
                                      int32_t transparentIndex, RaveResourceEntry *entry)
{
	uint32_t count = (tableType == 0) ? 256 : 16;  // CL8_RGB32 vs CL4_RGB32
	uint32_t *clut = new uint32_t[count];

	for (uint32_t i = 0; i < count; i++) {
		uint32_t rgb = ReadMacInt32(pixelDataAddr + i * 4);
		uint8_t r = (rgb >> 16) & 0xFF;
		uint8_t g = (rgb >> 8) & 0xFF;
		uint8_t b = rgb & 0xFF;
		uint8_t a = 0xFF;
		// BGRA in host (little-endian) order
		clut[i] = b | (g << 8) | (r << 16) | (a << 24);
	}

	// transparentIndexFlag is a Boolean (QD3D manual p.1587): when set,
	// index 0 becomes fully transparent.
	if (transparentIndex != 0) {
		clut[0] &= 0x00FFFFFF;
	}

	entry->clut_data = clut;
	entry->clut_count = count;
	entry->transparent_index = (transparentIndex != 0) ? 0 : -1;
	RaveRememberCL8ColorTableSnapshot(clut, count);

	RAVE_LOG("ColorTableNew tableType=%d count=%d transparentFlag=%d (idx0 %s)",
	       tableType, count, transparentIndex,
	       (transparentIndex != 0) ? "transparent" : "opaque");
}


/*
 *  Expand an indexed texture or bitmap through its bound CLUT and
 *  (re)create the Metal texture. Reads the native original_pixels copy.
 */
static void RaveReExpandWithCLUT(RaveResourceEntry *texEntry, RaveResourceEntry *clutEntry)
{
	RaveFlushPendingDraws();
	if (!texEntry->original_pixels || !clutEntry->clut_data) return;

	uint32_t w = texEntry->width;
	uint32_t h = texEntry->height;

	if (texEntry->metal_texture != nullptr) {
		RaveReleaseTexture(texEntry->metal_texture);
		texEntry->metal_texture = nullptr;
	}

	uint8_t *expanded = new uint8_t[w * h * 4];

	if (texEntry->pixel_type == kQAPixel_CL8) {
		for (uint32_t y = 0; y < h; y++) {
			for (uint32_t x = 0; x < w; x++) {
				uint8_t idx = texEntry->original_pixels[y * texEntry->row_bytes + x];
				if (idx >= clutEntry->clut_count) idx = 0;
				uint32_t bgra = clutEntry->clut_data[idx];
				uint32_t dstIdx = (y * w + x) * 4;
				memcpy(&expanded[dstIdx], &bgra, 4);
			}
		}
	} else if (texEntry->pixel_type == kQAPixel_CL4) {
		for (uint32_t y = 0; y < h; y++) {
			for (uint32_t x = 0; x < w; x++) {
				uint8_t byte = texEntry->original_pixels[y * texEntry->row_bytes + x / 2];
				uint8_t idx;
				if (x & 1)
					idx = byte & 0x0F;
				else
					idx = (byte >> 4) & 0x0F;
				if (idx >= clutEntry->clut_count) idx = 0;
				uint32_t bgra = clutEntry->clut_data[idx];
				uint32_t dstIdx = (y * w + x) * 4;
				memcpy(&expanded[dstIdx], &bgra, 4);
			}
		}
	} else if (texEntry->pixel_type == kQAPixel_ACL16_88) {
		ExpandACL16_88(texEntry->original_pixels, expanded, w, h,
		               texEntry->row_bytes, clutEntry->clut_data, clutEntry->clut_count);
	}

	uint32_t numPx = w * h;
	uint32_t indexZero = 0;
	RaveBGRAImageStats stats = RaveBGRAImageAnalyze(expanded, numPx);
	if (numPx > 0) {
		if (texEntry->pixel_type == kQAPixel_CL8) {
			for (uint32_t y = 0; y < h; y++) {
				for (uint32_t x = 0; x < w; x++) {
					if (texEntry->original_pixels[y * texEntry->row_bytes + x] == 0) indexZero++;
				}
			}
		} else if (texEntry->pixel_type == kQAPixel_CL4) {
			for (uint32_t y = 0; y < h; y++) {
				for (uint32_t x = 0; x < w; x++) {
					uint8_t byte = texEntry->original_pixels[y * texEntry->row_bytes + x / 2];
					uint8_t idx = (x & 1) ? (byte & 0x0F) : ((byte >> 4) & 0x0F);
					if (idx == 0) indexZero++;
				}
			}
		}
		texEntry->diag_alpha_zero = numPx - stats.alpha;
		texEntry->diag_index_zero = indexZero;
		texEntry->diag_rgb_nonzero = stats.rgb;
	}

	texEntry->metal_texture = RaveCreateMetalTexture(w, h, texEntry->mip_levels, expanded, w * 4);

	// Mips are CPU-generated from the expanded level 0.
	if (texEntry->mip_levels > 1 && texEntry->metal_texture) {
		RaveUploadGeneratedMips(texEntry->metal_texture, expanded, w, h, texEntry->mip_levels);
	}

	delete[] expanded;

	RAVE_LOG("Re-expanded %s %dx%d with CLUT (%d entries) -> metal=%p",
	       (texEntry->type == kRaveResourceTexture) ? "texture" : "bitmap",
	       w, h, clutEntry->clut_count, texEntry->metal_texture);
}


/*
 *  Engine methods called by the RAVE manager for our engine (as opposed to
 *  the hooks on the public API).
 */

int32_t NativeEngineTextureNew(uint32_t flags, uint32_t pixelType,
                                uint32_t imagesAddr, uint32_t newTexturePtr)
{
	fprintf(stderr, "RAVE: TextureNew flags=0x%x pixelType=%d images=0x%x\n",
	        flags, pixelType, imagesAddr);
	uint32_t handle = RaveResourceAlloc(kRaveResourceTexture);
	if (handle == 0) {
		WriteMacInt32(newTexturePtr, 0);
		return kQAOutOfMemory;
	}
	RaveResourceEntry *entry = RaveResourceGet(handle);
	const int32_t error = RaveCreateTextureFromImages(flags, pixelType, imagesAddr, entry);
	if (error != kQANoErr) {
		RaveResourceFree(handle);
		WriteMacInt32(newTexturePtr, 0);
		return error;
	}
	WriteMacInt32(newTexturePtr, entry->mac_addr);
	return kQANoErr;
}

int32_t NativeEngineTextureDetach(uint32_t textureAddr)
{
	// Pixels are copied at TextureNew.
	return kQANoErr;
}

void NativeEngineTextureDelete(uint32_t textureAddr)
{
	uint32_t handle = RaveResourceFindByAddr(textureAddr);
	if (handle != 0) {
		RaveForgetRTTAndFreeResource(handle);
	}
}

int32_t NativeEngineBitmapNew(uint32_t flags, uint32_t pixelType,
                               uint32_t imageAddr, uint32_t newBitmapPtr)
{
	uint32_t handle = RaveResourceAlloc(kRaveResourceBitmap);
	if (handle == 0) {
		WriteMacInt32(newBitmapPtr, 0);
		return kQAOutOfMemory;
	}
	RaveResourceEntry *entry = RaveResourceGet(handle);
	const int32_t error = RaveCreateBitmapFromImage(pixelType, imageAddr, entry);
	if (error != kQANoErr) {
		RaveResourceFree(handle);
		WriteMacInt32(newBitmapPtr, 0);
		return error;
	}
	// 4-bit priority in bits 31:28 (QACalculatePriorityBits)
	entry->priority = (uint8_t)((flags >> 28) & 0xF);
	WriteMacInt32(newBitmapPtr, entry->mac_addr);
	return kQANoErr;
}

int32_t NativeEngineBitmapDetach(uint32_t bitmapAddr)
{
	// Pixels are copied at BitmapNew.
	return kQANoErr;
}

void NativeEngineBitmapDelete(uint32_t bitmapAddr)
{
	uint32_t handle = RaveResourceFindByAddr(bitmapAddr);
	if (handle != 0) {
		RaveForgetRTTAndFreeResource(handle);
	}
}

int32_t NativeEngineColorTableNew(uint32_t tableType, uint32_t pixelDataAddr,
                                   uint32_t transparentIndexOrFlag, uint32_t newTablePtr)
{
	uint32_t handle = RaveResourceAlloc(kRaveResourceColorTable);
	if (handle == 0) {
		WriteMacInt32(newTablePtr, 0);
		return kQAOutOfMemory;
	}
	RaveResourceEntry *entry = RaveResourceGet(handle);
	RaveCreateColorTableData(tableType, pixelDataAddr, (int32_t)transparentIndexOrFlag, entry);
	WriteMacInt32(newTablePtr, entry->mac_addr);
	return kQANoErr;
}

void NativeEngineColorTableDelete(uint32_t colorTableAddr)
{
	uint32_t handle = RaveResourceFindByAddr(colorTableAddr);
	if (handle != 0) {
		RaveResourceFree(handle);
	}
}

int32_t NativeEngineTextureBindColorTable(uint32_t textureAddr, uint32_t colorTableAddr)
{
	uint32_t texHandle = RaveResourceFindByAddr(textureAddr);
	uint32_t clutHandle = RaveResourceFindByAddr(colorTableAddr);
	if (texHandle == 0 || clutHandle == 0) return kQANotSupported;

	RaveResourceEntry *texEntry = RaveResourceGet(texHandle);
	RaveResourceEntry *clutEntry = RaveResourceGet(clutHandle);
	if (!texEntry || !clutEntry) return kQANotSupported;

	texEntry->bound_clut = clutHandle;

	if (texEntry->original_pixels) {
		RaveReExpandWithCLUT(texEntry, clutEntry);
	}

	return kQANoErr;
}

int32_t NativeEngineBitmapBindColorTable(uint32_t bitmapAddr, uint32_t colorTableAddr)
{
	uint32_t bmpHandle = RaveResourceFindByAddr(bitmapAddr);
	uint32_t clutHandle = RaveResourceFindByAddr(colorTableAddr);
	if (bmpHandle == 0 || clutHandle == 0) return kQANotSupported;

	RaveResourceEntry *bmpEntry = RaveResourceGet(bmpHandle);
	RaveResourceEntry *clutEntry = RaveResourceGet(clutHandle);
	if (!bmpEntry || !clutEntry) return kQANotSupported;

	bmpEntry->bound_clut = clutHandle;

	if (bmpEntry->original_pixels) {
		RaveReExpandWithCLUT(bmpEntry, clutEntry);
	}

	return kQANoErr;
}


/*
 *  AccessTexture/End and AccessBitmap/End: guest CPU access to pixels.
 *  Access returns the Mac-side copy; End re-converts and re-uploads it.
 *
 *  TQAAccessTexture(TQATexture *, long mipmapLevel, long flags, TQAPixelBuffer *)
 *  TQAPixelBuffer: rowBytes +0, pixelType +4, width +8, height +12,
 *  baseAddr +16. Only level 0 is returned; no known game asks for others.
 */
int32_t NativeEngineAccessTexture(uint32_t textureAddr, uint32_t mipmapLevel,
                                   uint32_t flags, uint32_t bufferStructAddr)
{
	RaveFlushPendingDraws();
	uint32_t handle = RaveResourceFindByAddr(textureAddr);
	if (handle == 0) return kQANotSupported;
	RaveResourceEntry *entry = RaveResourceGet(handle);
	if (!entry || entry->type != kRaveResourceTexture) return kQANotSupported;
	if (!entry->cpu_pixel_data || entry->cpu_pixel_mac_addr == 0) return kQANotSupported;

	WriteMacInt32(bufferStructAddr + 0,  entry->row_bytes);
	WriteMacInt32(bufferStructAddr + 4,  entry->pixel_type);
	WriteMacInt32(bufferStructAddr + 8,  entry->width);
	WriteMacInt32(bufferStructAddr + 12, entry->height);
	WriteMacInt32(bufferStructAddr + 16, entry->cpu_pixel_mac_addr);
	RAVE_LOG("AccessTexture: tex=0x%08x mip=%d flags=0x%x -> buf=0x%08x %dx%d rowBytes=%d",
	         textureAddr, mipmapLevel, flags, entry->cpu_pixel_mac_addr,
	         entry->width, entry->height, entry->row_bytes);
	return kQANoErr;
}

int32_t NativeEngineAccessTextureEnd(uint32_t textureAddr, uint32_t dirtyRectAddr)
{
	RaveFlushPendingDraws();
	uint32_t handle = RaveResourceFindByAddr(textureAddr);
	if (handle == 0) return kQANotSupported;
	RaveResourceEntry *entry = RaveResourceGet(handle);
	if (!entry || entry->type != kRaveResourceTexture) return kQANotSupported;
	if (!entry->cpu_pixel_data) return kQANotSupported;

	uint32_t w = entry->width;
	uint32_t h = entry->height;
	bool isIndexed = (entry->pixel_type == kQAPixel_CL8 || entry->pixel_type == kQAPixel_CL4 || entry->pixel_type == kQAPixel_ACL16_88);
	if (isIndexed) {
		const uint64_t bytes = uint64_t(entry->row_bytes) * h;
		if (!entry->original_pixels || bytes > entry->original_size || bytes > entry->cpu_pixel_data_size)
			return kQAParamErr;
			// Palette binds rebuild from original_pixels, so commit the edited
			// indices there even before a palette is bound.
		memcpy(entry->original_pixels, entry->cpu_pixel_data, size_t(bytes));
		RaveResourceEntry *clut = RaveResourceGet(entry->bound_clut);
		if (!clut || clut->type != kRaveResourceColorTable || !clut->clut_data)
			return kQANoErr;
	}
	uint8_t *expanded = new uint8_t[size_t(w) * h * 4]();

	if (isIndexed && entry->bound_clut != 0) {
		RaveResourceEntry *clutEntry = RaveResourceGet(entry->bound_clut);
		if (clutEntry && clutEntry->clut_data) {
			if (entry->pixel_type == kQAPixel_CL8) {
				for (uint32_t y = 0; y < h; y++) {
					for (uint32_t x = 0; x < w; x++) {
						uint8_t idx = entry->cpu_pixel_data[y * entry->row_bytes + x];
						if (idx >= clutEntry->clut_count) idx = 0;
						uint32_t bgra = clutEntry->clut_data[idx];
						memcpy(&expanded[(y * w + x) * 4], &bgra, 4);
					}
				}
			} else if (entry->pixel_type == kQAPixel_ACL16_88) {
				for (uint32_t y = 0; y < h; y++) {
					for (uint32_t x = 0; x < w; x++) {
						uint32_t off = y * entry->row_bytes + x * 2;
						uint8_t a = entry->cpu_pixel_data[off];
						uint8_t idx = entry->cpu_pixel_data[off + 1];
						if (idx >= clutEntry->clut_count) idx = 0;
						uint32_t bgra = clutEntry->clut_data[idx];
						memcpy(&expanded[(y * w + x) * 4], &bgra, 4);
						expanded[(y * w + x) * 4 + 3] = a;
					}
				}
			} else { // CL4
				for (uint32_t y = 0; y < h; y++) {
					for (uint32_t x = 0; x < w; x++) {
						uint8_t byte = entry->cpu_pixel_data[y * entry->row_bytes + x / 2];
						uint8_t idx = (x & 1) ? (byte & 0x0F) : ((byte >> 4) & 0x0F);
						if (idx >= clutEntry->clut_count) idx = 0;
						uint32_t bgra = clutEntry->clut_data[idx];
						memcpy(&expanded[(y * w + x) * 4], &bgra, 4);
					}
				}
			}
		}
	} else if (!isIndexed) {
		// cpu_pixel_data lives in Mac memory, so convert via its Mac address
		uint32_t macAddr = entry->cpu_pixel_mac_addr;
		ConvertPixels(entry->pixel_type, macAddr, expanded, w, h, entry->row_bytes);
		if (entry->type == kRaveResourceTexture && entry->pixel_type == kQAPixel_ARGB32) {
			RaveBGRAWhitenAlphaOnlyMask(expanded, w * h);
		}
	}

	if (entry->type == kRaveResourceTexture) {
		RaveBGRAImageStats stats = RaveBGRAImageAnalyze(expanded, w * h);
		entry->diag_alpha_zero = (w * h) - stats.alpha;
		entry->diag_index_zero = 0;
		entry->diag_rgb_nonzero = stats.rgb;
	}

	if (entry->metal_texture) {
		// One pass break for level 0 and the regenerated chain.
		RaveTextureUploadBatchBegin();
		RaveUploadMipLevel(entry->metal_texture, 0, w, h, expanded, w * 4);
		if (entry->mip_levels > 1) {
			RaveUploadGeneratedMips(entry->metal_texture, expanded, w, h, entry->mip_levels);
		}
		RaveTextureUploadBatchEnd();
	}

	delete[] expanded;
	RAVE_LOG("AccessTextureEnd: tex=0x%08x re-uploaded %dx%d", textureAddr, w, h);
	return kQANoErr;
}

// TQAAccessBitmap(TQABitmap *, long flags, TQAPixelBuffer *); same buffer
// layout as AccessTexture.
int32_t NativeEngineAccessBitmap(uint32_t bitmapAddr, uint32_t flags,
                                  uint32_t bufferStructAddr)
{
	RaveFlushPendingDraws();
	uint32_t handle = RaveResourceFindByAddr(bitmapAddr);
	if (handle == 0) return kQANotSupported;
	RaveResourceEntry *entry = RaveResourceGet(handle);
	if (!entry || entry->type != kRaveResourceBitmap) return kQANotSupported;
	if (!entry->cpu_pixel_data || entry->cpu_pixel_mac_addr == 0) return kQANotSupported;

	WriteMacInt32(bufferStructAddr + 0,  entry->row_bytes);
	WriteMacInt32(bufferStructAddr + 4,  entry->pixel_type);
	WriteMacInt32(bufferStructAddr + 8,  entry->width);
	WriteMacInt32(bufferStructAddr + 12, entry->height);
	WriteMacInt32(bufferStructAddr + 16, entry->cpu_pixel_mac_addr);
	RAVE_LOG("AccessBitmap: bmp=0x%08x flags=0x%x -> buf=0x%08x %dx%d rowBytes=%d",
	         bitmapAddr, flags, entry->cpu_pixel_mac_addr,
	         entry->width, entry->height, entry->row_bytes);
	return kQANoErr;
}

int32_t NativeEngineAccessBitmapEnd(uint32_t bitmapAddr, uint32_t dirtyRectAddr)
{
	RaveFlushPendingDraws();
	uint32_t handle = RaveResourceFindByAddr(bitmapAddr);
	if (handle == 0) return kQANotSupported;
	RaveResourceEntry *entry = RaveResourceGet(handle);
	if (!entry || entry->type != kRaveResourceBitmap) return kQANotSupported;
	if (!entry->cpu_pixel_data) return kQANotSupported;

	uint32_t w = entry->width;
	uint32_t h = entry->height;
	bool isIndexed = (entry->pixel_type == kQAPixel_CL8 || entry->pixel_type == kQAPixel_CL4 || entry->pixel_type == kQAPixel_ACL16_88);
	if (isIndexed) {
		const uint64_t bytes = uint64_t(entry->row_bytes) * h;
		if (!entry->original_pixels || bytes > entry->original_size || bytes > entry->cpu_pixel_data_size)
			return kQAParamErr;
		memcpy(entry->original_pixels, entry->cpu_pixel_data, size_t(bytes));
		RaveResourceEntry *clut = RaveResourceGet(entry->bound_clut);
		if (!clut || clut->type != kRaveResourceColorTable || !clut->clut_data)
			return kQANoErr;
	}
	uint8_t *expanded = new uint8_t[size_t(w) * h * 4]();

	if (isIndexed && entry->bound_clut != 0) {
		RaveResourceEntry *clutEntry = RaveResourceGet(entry->bound_clut);
		if (clutEntry && clutEntry->clut_data) {
			if (entry->pixel_type == kQAPixel_CL8) {
				for (uint32_t y = 0; y < h; y++) {
					for (uint32_t x = 0; x < w; x++) {
						uint8_t idx = entry->cpu_pixel_data[y * entry->row_bytes + x];
						if (idx >= clutEntry->clut_count) idx = 0;
						uint32_t bgra = clutEntry->clut_data[idx];
						memcpy(&expanded[(y * w + x) * 4], &bgra, 4);
					}
				}
			} else if (entry->pixel_type == kQAPixel_ACL16_88) {
				for (uint32_t y = 0; y < h; y++) {
					for (uint32_t x = 0; x < w; x++) {
						uint32_t off = y * entry->row_bytes + x * 2;
						uint8_t a = entry->cpu_pixel_data[off];
						uint8_t idx = entry->cpu_pixel_data[off + 1];
						if (idx >= clutEntry->clut_count) idx = 0;
						uint32_t bgra = clutEntry->clut_data[idx];
						memcpy(&expanded[(y * w + x) * 4], &bgra, 4);
						expanded[(y * w + x) * 4 + 3] = a;
					}
				}
			} else { // CL4
				for (uint32_t y = 0; y < h; y++) {
					for (uint32_t x = 0; x < w; x++) {
						uint8_t byte = entry->cpu_pixel_data[y * entry->row_bytes + x / 2];
						uint8_t idx = (x & 1) ? (byte & 0x0F) : ((byte >> 4) & 0x0F);
						if (idx >= clutEntry->clut_count) idx = 0;
						uint32_t bgra = clutEntry->clut_data[idx];
						memcpy(&expanded[(y * w + x) * 4], &bgra, 4);
					}
				}
			}
		}
	} else if (!isIndexed) {
		uint32_t macAddr = entry->cpu_pixel_mac_addr;
		ConvertPixels(entry->pixel_type, macAddr, expanded, w, h, entry->row_bytes);
	}

	if (entry->metal_texture) {
		RaveUploadMipLevel(entry->metal_texture, 0, w, h, expanded, w * 4);
	}

	delete[] expanded;
	RAVE_LOG("AccessBitmapEnd: bmp=0x%08x re-uploaded %dx%d", bitmapAddr, w, h);
	return kQANoErr;
}


static const char kEngineASCIIName[] = "PocketShaver RAVE";
static const uint32 kEngineASCIINameLength = 17;

// Indexed by TQAGestaltSelector, for logging
static const char *gestalt_selector_names[] = {
	"OptionalFeatures",                    // 0
	"FastFeatures",                        // 1
	"VendorID",                            // 2
	"EngineID",                            // 3
	"Revision",                            // 4
	"ASCIINameLength",                     // 5
	"ASCIIName",                           // 6
	"TextureMemory",                       // 7
	"FastTextureMemory",                   // 8
	"DrawContextPixelTypesAllowed",        // 9
	"DrawContextPixelTypesPreferred",      // 10
	"TexturePixelTypesAllowed",            // 11
	"TexturePixelTypesPreferred",          // 12
	"BitmapPixelTypesAllowed",             // 13
	"BitmapPixelTypesPreferred",           // 14
	"OptionalFeatures2",                   // 15
	"MultiTextureMax",                     // 16
	"NumSelectors"                         // 17
};


/*
 *  NativeEngineGetMethod - TQAEngineGetMethod, via the sub-opcode 100 TVECT.
 *  Writes the TVECT for methodTag (0-17) into the TQAEngineMethod union at
 *  methodPtr.
 */
int32 NativeEngineGetMethod(uint32 methodTag, uint32 methodPtr)
{
	if (methodTag >= kQAEngineMethodTagCount) {
		RAVE_LOG("EngineGetMethod: unknown tag %d -> kQANotSupported", methodTag);
		return kQANotSupported;
	}

	// Engine method N is sub-opcode 100 + N.
	uint32 tvect_addr = rave_method_tvects[kRaveEngineDrawPrivateNew + methodTag];

	if (tvect_addr == 0) {
		RAVE_LOG("EngineGetMethod: tag %d has no TVECT -> kQANotSupported", methodTag);
		return kQANotSupported;
	}

	// The union is a single function pointer.
	WriteMacInt32(methodPtr, tvect_addr);

	RAVE_LOG("EngineGetMethod: tag %d -> TVECT 0x%08x", methodTag, tvect_addr);
	return kQANoErr;
}


/*
 *  NativeEngineGestalt - TQAEngineGestalt, via the sub-opcode 103 TVECT.
 *  Writes the answer for selector to responsePtr.
 */
int32 NativeEngineGestalt(uint32 selector, uint32 responsePtr)
{
	switch (selector) {
	case kQAGestalt_OptionalFeatures:
		WriteMacInt32(responsePtr, kAllOptionalFeatures);
		RAVE_LOG("EngineGestalt: %s -> 0x%08x", gestalt_selector_names[selector], kAllOptionalFeatures);
		break;

	case kQAGestalt_FastFeatures:
		// kQAFast_* is its own bit namespace, distinct from kQAOptional_*.
		WriteMacInt32(responsePtr, kAllFastFeatures);
		RAVE_LOG("EngineGestalt: %s -> 0x%08x", gestalt_selector_names[selector], kAllFastFeatures);
		break;

	case kQAGestalt_VendorID:
		WriteMacInt32(responsePtr, kRaveAdvertisedVendorID);
		RAVE_LOG("EngineGestalt: %s -> %u (kQAVendor_ATI)", gestalt_selector_names[selector],
		         kRaveAdvertisedVendorID);
		break;

	case kQAGestalt_EngineID:
		WriteMacInt32(responsePtr, kRaveAdvertisedEngineID);
		RAVE_LOG("EngineGestalt: %s -> 0x%08x (ATI Rage 128)", gestalt_selector_names[selector],
		         kRaveAdvertisedEngineID);
		break;

	case kQAGestalt_Revision:
		WriteMacInt32(responsePtr, kRaveAdvertisedRevision);
		RAVE_LOG("EngineGestalt: %s -> 0x%08x (1.0)", gestalt_selector_names[selector],
		         kRaveAdvertisedRevision);
		break;

	case kQAGestalt_ASCIINameLength:
		WriteMacInt32(responsePtr, kEngineASCIINameLength);
		RAVE_LOG("EngineGestalt: %s -> %d", gestalt_selector_names[selector], kEngineASCIINameLength);
		break;

	case kQAGestalt_ASCIIName:
		// strcpy semantics: NUL-terminate
		Host2Mac_memcpy(responsePtr, (uint8 *)kEngineASCIIName, kEngineASCIINameLength);
		WriteMacInt8(responsePtr + kEngineASCIINameLength, 0);
		RAVE_LOG("EngineGestalt: %s -> \"%s\"", gestalt_selector_names[selector], kEngineASCIIName);
		break;

	case kQAGestalt_TextureMemory:
	case kQAGestalt_FastTextureMemory:
		WriteMacInt32(responsePtr, kRaveAdvertisedTextureMemoryBytes);
		RAVE_LOG("EngineGestalt: %s -> 64MB", gestalt_selector_names[selector]);
		break;

	case kQAGestalt_DrawContextPixelTypesAllowed:
		// RGB32 is required: "Millions of colors" is xRGB8888
		WriteMacInt32(responsePtr, (1 << kQAPixel_ARGB32) | (1 << kQAPixel_RGB32) |
					  (1 << kQAPixel_RGB16));
		RAVE_LOG("EngineGestalt: %s -> ARGB32|RGB32|RGB16", gestalt_selector_names[selector]);
		break;

	case kQAGestalt_DrawContextPixelTypesPreferred:
		WriteMacInt32(responsePtr, (1 << kQAPixel_RGB32));
		RAVE_LOG("EngineGestalt: %s -> RGB32", gestalt_selector_names[selector]);
		break;

	case kQAGestalt_TexturePixelTypesAllowed:
		WriteMacInt32(responsePtr, (1 << kQAPixel_ARGB32) | (1 << kQAPixel_RGB32) |
					  (1 << kQAPixel_ARGB16) | (1 << kQAPixel_RGB16) |
					  (1 << kQAPixel_CL8) | (1 << kQAPixel_CL4) |
					  (1 << kQAPixel_RGB8_332) | (1 << kQAPixel_ARGB16_4444) |
					  (1 << kQAPixel_ACL16_88) | (1 << kQAPixel_I8) | (1 << kQAPixel_AI16_88));
		RAVE_LOG("EngineGestalt: %s -> ARGB32|RGB32|ARGB16|RGB16|CL8|CL4|RGB8_332|ARGB16_4444|ACL16_88|I8|AI16_88", gestalt_selector_names[selector]);
		break;

	case kQAGestalt_TexturePixelTypesPreferred:
		WriteMacInt32(responsePtr, (1 << kQAPixel_ARGB32));
		RAVE_LOG("EngineGestalt: %s -> ARGB32", gestalt_selector_names[selector]);
		break;

	case kQAGestalt_BitmapPixelTypesAllowed:
		WriteMacInt32(responsePtr, (1 << kQAPixel_ARGB32) | (1 << kQAPixel_RGB32) |
					  (1 << kQAPixel_ARGB16) | (1 << kQAPixel_RGB16) |
					  (1 << kQAPixel_CL8) | (1 << kQAPixel_CL4) |
					  (1 << kQAPixel_RGB8_332) | (1 << kQAPixel_ARGB16_4444) |
					  (1 << kQAPixel_ACL16_88) | (1 << kQAPixel_I8) | (1 << kQAPixel_AI16_88));
		RAVE_LOG("EngineGestalt: %s -> ARGB32|RGB32|ARGB16|RGB16|CL8|CL4|...", gestalt_selector_names[selector]);
		break;

	case kQAGestalt_BitmapPixelTypesPreferred:
		WriteMacInt32(responsePtr, (1 << kQAPixel_ARGB32));
		RAVE_LOG("EngineGestalt: %s -> ARGB32", gestalt_selector_names[selector]);
		break;

	case kQAGestalt_OptionalFeatures2:
		WriteMacInt32(responsePtr, kAllOptionalFeatures2);
		RAVE_LOG("EngineGestalt: %s -> 0x%08x", gestalt_selector_names[selector], kAllOptionalFeatures2);
		break;

	case kQAGestalt_MultiTextureMax:
		// One secondary layer in addition to the primary texture.
		WriteMacInt32(responsePtr, 1);
		RAVE_LOG("EngineGestalt: %s -> 1", gestalt_selector_names[selector]);
		break;

	case kQAGestalt_NumSelectors:
		// Selectors 0-16 are valid, so the count is 17.
		WriteMacInt32(responsePtr, 17);
		RAVE_LOG("EngineGestalt: %s -> 17", gestalt_selector_names[selector]);
		break;

	default:
		// Engine-specific selectors. Unknown ones get kQANotSupported.
		if (selector == 1000) {  // kQATIGestalt_CurrentContext
			WriteMacInt32(responsePtr, rave_current_draw_context_addr);
			RAVE_LOG("EngineGestalt: kQATIGestalt_CurrentContext -> 0x%08x",
			         rave_current_draw_context_addr);
			break;
		}
		if (selector == 1001) {  // kQATIGestalt_VRAMBytes
			WriteMacInt32(responsePtr, kRaveAdvertisedVRAMBytes);
			RAVE_LOG("EngineGestalt: kQATIGestalt_VRAMBytes -> %u",
			         kRaveAdvertisedVRAMBytes);
			break;
		}
		RAVE_LOG("EngineGestalt: unknown selector %d -> kQANotSupported", selector);
		return kQANotSupported;
	}

	return kQANoErr;
}


/*
 *  NativeEngineCheckDevice - TQAEngineCheckDevice, via the sub-opcode 102
 *  TVECT. Accepts both kQADeviceMemory (0) and kQADeviceGDevice (1).
 */
int32 NativeEngineCheckDevice(uint32 devicePtr)
{
	uint32 deviceType = ReadMacInt32(devicePtr);

	RaveLogDeviceSummary("EngineCheckDevice", devicePtr);
	RAVE_LOG("EngineCheckDevice: %s(%u) -> kQANoErr",
	         RaveDeviceTypeName(deviceType), deviceType);

	return kQANoErr;
}


/*
 *  Hook: QADeviceGetFirstEngine(device). Always returns our sentinel engine.
 *  r3 = device (may be NULL to enumerate all)
 */
uint32 NativeHookGetFirstEngine(uint32 device)
{
	RaveLogDeviceSummary("HOOK: QADeviceGetFirstEngine", device);
	RAVE_LOG("HOOK: QADeviceGetFirstEngine(device=0x%08x) -> sentinel 0x%08x",
		   device, rave_sentinel_engine);
	return rave_sentinel_engine;
}


/*
 *  Hook: QADeviceGetNextEngine(device, prevEngine). After the sentinel the
 *  list ends; otherwise chain to the original.
 *  r3 = device, r4 = prevEngine
 */
uint32 NativeHookGetNextEngine(uint32 device, uint32 prevEngine)
{
	if (prevEngine == rave_sentinel_engine) {
		// End of list after the sentinel. QARegisterEngine did not put us
		// in the manager's list, so there are no real engines to chain to.
		// Chaining to the original GetFirstEngine is not an option either:
		// its prologue has a PC-relative bl, which breaks when relocated
		// and loops forever on the sentinel.
		RAVE_LOG("HOOK: QADeviceGetNextEngine(prev=sentinel) -> NULL (end of list)");
		return 0;
	} else {
		RAVE_LOG("HOOK: QADeviceGetNextEngine(prev=0x%08x) -> chaining to original", prevEngine);
		if (rave_orig_get_next_engine == 0) return 0;
		const uint32 args[] = { device, prevEngine };
		return RaveChainToOriginal(kRaveHookIdx_GetNextEngine, 2, args);
	}
}


/*
 *  Hook: QAEngineGestalt(engine, selector, response). Ours goes to
 *  NativeEngineGestalt; others chain.
 *  r3 = engine, r4 = selector, r5 = response
 */
uint32 NativeHookEngineGestalt(uint32 engine, uint32 selector, uint32 responsePtr)
{
	if (engine == rave_sentinel_engine) {
		RAVE_LOG("HOOK: QAEngineGestalt(sentinel, sel=%d) -> native", selector);
		return (uint32)NativeEngineGestalt(selector, responsePtr);
	} else {
		if (rave_orig_engine_gestalt == 0) return (uint32)(int32)kQANotSupported;
		const uint32 args[] = { engine, selector, responsePtr };
		return RaveChainToOriginal(kRaveHookIdx_EngineGestalt, 3, args);
	}
}


/*
 *  Hook: QAEngineCheckDevice(engine, device). Ours accepts every device;
 *  others chain.
 *  r3 = engine, r4 = device
 */
uint32 NativeHookEngineCheckDevice(uint32 engine, uint32 device)
{
	if (engine == rave_sentinel_engine) {
		RAVE_LOG("HOOK: QAEngineCheckDevice(sentinel, device=0x%08x) -> kQANoErr", device);
		return kQANoErr;
	} else {
		if (rave_orig_engine_check_device == 0) return (uint32)(int32)kQANotSupported;
		const uint32 args[] = { engine, device };
		return RaveChainToOriginal(kRaveHookIdx_EngineCheckDevice, 2, args);
	}
}

/*
 *  Hook: QAEngineEnable(vendorID, engineID). Some games call this to select
 *  an engine before creating a context. The manager's list doesn't reliably
 *  contain our sentinel, so BestChoice and ATI are answered here.
 */
uint32 NativeHookEngineEnable(uint32 vendorID, uint32 engineID)
{
	RAVE_LOG("HOOK: QAEngineEnable(vendor=0x%08x engine=0x%08x)", vendorID, engineID);
	if (RaveEngineEnableHandledByNative(vendorID, engineID)) {
		RAVE_LOG("HOOK: QAEngineEnable -> kQANoErr (native accepted)");
		return kQANoErr;
	}

	if (rave_orig_engine_enable == 0) return (uint32)(int32)kQANotSupported;
	const uint32 args[] = { vendorID, engineID };
	const uint32 result = RaveChainToOriginal(kRaveHookIdx_EngineEnable, 2, args);
	RAVE_LOG("HOOK: QAEngineEnable -> chained result %d", (int32)result);
	return result;
}


/*
 *  Hook: QAEngineDisable(vendorID, engineID)
 */
uint32 NativeHookEngineDisable(uint32 vendorID, uint32 engineID)
{
	RAVE_LOG("HOOK: QAEngineDisable(vendor=0x%08x engine=0x%08x)", vendorID, engineID);
	if (RaveEngineEnableHandledByNative(vendorID, engineID)) {
		RAVE_LOG("HOOK: QAEngineDisable -> kQANoErr (native accepted)");
		return kQANoErr;
	}

	if (rave_orig_engine_disable == 0) return (uint32)(int32)kQANotSupported;
	const uint32 args[] = { vendorID, engineID };
	const uint32 result = RaveChainToOriginal(kRaveHookIdx_EngineDisable, 2, args);
	RAVE_LOG("HOOK: QAEngineDisable -> chained result %d", (int32)result);
	return result;
}


/*
 *  Hook: QADrawContextNew(device, rect, clip, engine, flags, &drawContext)
 *
 *  The manager normally allocates the TQADrawContext and calls the
 *  engine's DrawPrivateNew. It doesn't know our sentinel engine, so for
 *  ours we build the TQADrawContext ourselves; its method TVECTs point at
 *  our PPC thunks. Other engines chain.
 *
 *  r3 = device, r4 = rect, r5 = clip, r6 = engine, r7 = flags,
 *  r8 = drawContextPtr (out)
 */
uint32 NativeHookDrawContextNew(uint32 device, uint32 rect, uint32 clip,
                                 uint32 engine, uint32 flags, uint32 drawContextPtr)
{
	RAVE_LOG("HOOK: QADrawContextNew engine=0x%08x sentinel=0x%08x device=0x%08x rect=0x%08x clip=0x%08x flags=0x%08x ctxPtr=0x%08x",
	       engine, rave_sentinel_engine, device, rect, clip, flags, drawContextPtr);
	if (engine == rave_sentinel_engine) {
		RAVE_LOG("HOOK: QADrawContextNew(sentinel) -> creating context");

		// TQADrawContext: +0 drawPrivate handle, +4 version, +8 method TVECTs.
		uint32 ctx_size = 4 + 4 + kRaveDrawMethodCount * 4;  // 148 bytes
		uint32 ctx;
		if (!rave_ctx_free_list.empty()) {
			ctx = rave_ctx_free_list.back();
			rave_ctx_free_list.pop_back();
			RAVE_LOG("HOOK: reusing ctx=0x%08x from free list (%zu remain)",
			       ctx, rave_ctx_free_list.size());
		} else {
			ctx = SheepMem::ReserveProc(ctx_size);
			rave_ctx_owned_addresses.push_back(ctx);
			RAVE_LOG("HOOK: allocated ctx=0x%08x from SheepMem proc", ctx);
		}
		// Not zeroed: NativeDrawPrivateNew writes every field. A memset
		// would briefly expose NULL TVECTs to stale guest references, which
		// then jump to address 0.
		RAVE_LOG("HOOK: calling NativeDrawPrivateNew(ctx=0x%08x, dev=0x%08x, rect=0x%08x, clip=0x%08x, flags=0x%08x)",
		       ctx, device, rect, clip, flags);
		int32 err = NativeDrawPrivateNew(ctx, device, rect, clip, flags);
		RAVE_LOG("HOOK: NativeDrawPrivateNew returned %d", err);
		if (err != kQANoErr) {
			RAVE_LOG("HOOK: DrawPrivateNew failed with %d", err);
			// The address was never published, so recycle it.
			rave_ctx_free_list.push_back(ctx);
			return (uint32)err;
		}

		WriteMacInt32(drawContextPtr, ctx);

		uint32 drawPrivate = ReadMacInt32(ctx);
		RAVE_LOG("HOOK: QADrawContextNew -> ctx=0x%08x, drawPrivate=%d",
			   ctx, drawPrivate);
		return kQANoErr;
	} else {
		if (rave_orig_draw_context_new == 0) return (uint32)(int32)kQANotSupported;
		const uint32 args[] = { device, rect, clip, engine, flags, drawContextPtr };
		return RaveChainToOriginal(kRaveHookIdx_DrawContextNew, 6, args);
	}
}


/*
 *  Hook: QATextureNew(engine, flags, pixelType, images[], &newTexture)
 *  r3 = engine, r4 = flags, r5 = pixelType, r6 = images, r7 = &newTexture
 */
uint32 NativeHookTextureNew(uint32 engine, uint32 flags, uint32 pixelType,
                            uint32 images, uint32 newTexturePtr)
{
	if (engine == rave_sentinel_engine) {
		uint32_t handle = RaveResourceAlloc(kRaveResourceTexture);
		if (handle == 0) {
			RAVE_LOG("HOOK: QATextureNew(sentinel) FAILED - resource table full");
			WriteMacInt32(newTexturePtr, 0);
			return (uint32)(int32)kQAOutOfMemory;
		}
		RaveResourceEntry *entry = RaveResourceGet(handle);
		const int32_t error = RaveCreateTextureFromImages(flags, pixelType, images, entry);
		if (error != kQANoErr) {
			RaveResourceFree(handle);
			WriteMacInt32(newTexturePtr, 0);
			return error;
		}
		RAVE_LOG("HOOK: QATextureNew(sentinel) flags=0x%x pixelType=%d %dx%d -> handle %d addr=0x%08x metal=%p",
		       flags, pixelType, entry->width, entry->height, handle, entry->mac_addr, entry->metal_texture);
		WriteMacInt32(newTexturePtr, entry->mac_addr);
		return kQANoErr;
	} else {
		if (rave_orig_texture_new == 0) return (uint32)(int32)kQANotSupported;
		const uint32 args[] = { engine, flags, pixelType, images, newTexturePtr };
		return RaveChainToOriginal(kRaveHookIdx_TextureNew, 5, args);
	}
}


/*
 *  Hook: QABitmapNew(engine, flags, pixelType, &image, &newBitmap)
 *  r3 = engine, r4 = flags, r5 = pixelType, r6 = &image, r7 = &newBitmap
 */
uint32 NativeHookBitmapNew(uint32 engine, uint32 flags, uint32 pixelType,
                           uint32 image, uint32 newBitmapPtr)
{
	if (engine == rave_sentinel_engine) {
		uint32_t handle = RaveResourceAlloc(kRaveResourceBitmap);
		if (handle == 0) {
			RAVE_LOG("HOOK: QABitmapNew(sentinel) FAILED - resource table full");
			WriteMacInt32(newBitmapPtr, 0);
			return (uint32)(int32)kQAOutOfMemory;
		}
		RaveResourceEntry *entry = RaveResourceGet(handle);
		const int32_t error = RaveCreateBitmapFromImage(pixelType, image, entry);
		if (error != kQANoErr) {
			RaveResourceFree(handle);
			WriteMacInt32(newBitmapPtr, 0);
			return error;
		}
		// 4-bit priority in bits 31:28 (QACalculatePriorityBits)
		entry->priority = (uint8_t)((flags >> 28) & 0xF);
		RAVE_LOG("HOOK: QABitmapNew(sentinel) flags=0x%x pixelType=%d %dx%d -> handle %d addr=0x%08x metal=%p",
		       flags, pixelType, entry->width, entry->height, handle, entry->mac_addr, entry->metal_texture);
		WriteMacInt32(newBitmapPtr, entry->mac_addr);
		return kQANoErr;
	} else {
		if (rave_orig_bitmap_new == 0) return (uint32)(int32)kQANotSupported;
		const uint32 args[] = { engine, flags, pixelType, image, newBitmapPtr };
		return RaveChainToOriginal(kRaveHookIdx_BitmapNew, 5, args);
	}
}


/*
 *  Hook: QAColorTableNew(engine, tableType, pixelData, transparentFlag, &newTable)
 *  r3 = engine, r4 = tableType, r5 = pixelData, r6 = transparentFlag,
 *  r7 = &newTable
 */
uint32 NativeHookColorTableNew(uint32 engine, uint32 tableType, uint32 pixelData,
                               uint32 transparentFlag, uint32 newTablePtr)
{
	if (engine == rave_sentinel_engine) {
		uint32_t handle = RaveResourceAlloc(kRaveResourceColorTable);
		if (handle == 0) {
			RAVE_LOG("HOOK: QAColorTableNew(sentinel) FAILED - resource table full");
			WriteMacInt32(newTablePtr, 0);
			return (uint32)(int32)kQAOutOfMemory;
		}
		RaveResourceEntry *entry = RaveResourceGet(handle);
		RaveCreateColorTableData(tableType, pixelData, (int32_t)transparentFlag, entry);
		RAVE_LOG("HOOK: QAColorTableNew(sentinel) tableType=%d count=%d -> handle %d addr=0x%08x",
		       tableType, entry->clut_count, handle, entry->mac_addr);
		WriteMacInt32(newTablePtr, entry->mac_addr);
		return kQANoErr;
	} else {
		if (rave_orig_color_table_new == 0) return (uint32)(int32)kQANotSupported;
		const uint32 args[] = { engine, tableType, pixelData, transparentFlag, newTablePtr };
		return RaveChainToOriginal(kRaveHookIdx_ColorTableNew, 5, args);
	}
}


/*
 *  Hook: QADrawContextDelete(drawContext). Contexts we created are deleted
 *  natively; others chain.
 *  r3 = TQADrawContext *
 */
uint32 NativeHookDrawContextDelete(uint32 drawContextPtr) {
	if (drawContextPtr == 0) return kQANoErr;
	const bool owned = std::find(rave_ctx_owned_addresses.begin(),
	                             rave_ctx_owned_addresses.end(), drawContextPtr)
	                   != rave_ctx_owned_addresses.end();
	uint32 handle = ReadMacInt32(drawContextPtr + 0);
	RaveDrawPrivate *ctx = RaveGetContext(handle);
	if (owned && ctx && ctx->drawContextAddr == drawContextPtr) {
		RAVE_LOG("HOOK: QADrawContextDelete(0x%08x) handle=%d -> native delete",
		       drawContextPtr, handle);
		// Invalidate while the context still owns its source texture, so a
		// newer GL/RAVE frame survives cleanup of this inactive context.
		RaveInvalidateContextOverlay(ctx);
		// Clear the handle before DisposePtr can re-enter the guest. The
		// owned-address check below still recognizes this context.
		WriteMacInt32(drawContextPtr + 0, 0);
		NativeDrawPrivateDelete(handle);

		// Recycle the address for the next QADrawContextNew.
		rave_ctx_free_list.push_back(drawContextPtr);

		return kQANoErr;
	}
	// A duplicate delete, or a callback during teardown, finds no live
	// handle. The context is still ours, not the guest's.
	if (owned) {
		RAVE_LOG("HOOK: QADrawContextDelete(0x%08x) -> inactive native context", drawContextPtr);
		return kQANoErr;
	}
	if (rave_orig_draw_context_delete == 0) return kQANoErr;
	RAVE_LOG("HOOK: QADrawContextDelete(0x%08x) -> chaining to original", drawContextPtr);
	const uint32 args[] = { drawContextPtr };
	return RaveChainToOriginal(kRaveHookIdx_DrawContextDelete, 1, args);
}


/*
 *  Hook: QATextureDelete(engine, texture). Frees ours; others chain.
 *  r3 = engine, r4 = texture
 */
uint32 NativeHookTextureDelete(uint32 enginePtr, uint32 texturePtr) {
	uint32_t resHandle = RaveResourceFindByAddr(texturePtr);
	if (resHandle != 0) {
		RAVE_LOG("HOOK: QATextureDelete(engine=0x%08x, tex=0x%08x) -> resource handle %d freed",
		       enginePtr, texturePtr, resHandle);
		RaveForgetRTTAndFreeResource(resHandle);
		return kQANoErr;
	}
	if (rave_orig_texture_delete == 0) return kQANoErr;
	RAVE_LOG("HOOK: QATextureDelete(engine=0x%08x, tex=0x%08x) -> chaining to original",
	       enginePtr, texturePtr);
	const uint32 args[] = { enginePtr, texturePtr };
	return RaveChainToOriginal(kRaveHookIdx_TextureDelete, 2, args);
}


/*
 *  Hook: QABitmapDelete(engine, bitmap)
 *  r3 = engine, r4 = bitmap
 */
uint32 NativeHookBitmapDelete(uint32 enginePtr, uint32 bitmapPtr) {
	uint32_t resHandle = RaveResourceFindByAddr(bitmapPtr);
	if (resHandle != 0) {
		RAVE_LOG("HOOK: QABitmapDelete(engine=0x%08x, bmp=0x%08x) -> resource handle %d freed",
		       enginePtr, bitmapPtr, resHandle);
		RaveForgetRTTAndFreeResource(resHandle);
		return kQANoErr;
	}
	if (rave_orig_bitmap_delete == 0) return kQANoErr;
	RAVE_LOG("HOOK: QABitmapDelete(engine=0x%08x, bmp=0x%08x) -> chaining to original",
	       enginePtr, bitmapPtr);
	const uint32 args[] = { enginePtr, bitmapPtr };
	return RaveChainToOriginal(kRaveHookIdx_BitmapDelete, 2, args);
}


/*
 *  Hook: QAColorTableDelete(engine, colorTable)
 *  r3 = engine, r4 = colorTable
 */
uint32 NativeHookColorTableDelete(uint32 enginePtr, uint32 colorTablePtr) {
	uint32_t resHandle = RaveResourceFindByAddr(colorTablePtr);
	if (resHandle != 0) {
		RAVE_LOG("HOOK: QAColorTableDelete(engine=0x%08x, ct=0x%08x) -> resource handle %d freed",
		       enginePtr, colorTablePtr, resHandle);
		RaveResourceFree(resHandle);
		return kQANoErr;
	}
	if (rave_orig_color_table_delete == 0) return kQANoErr;
	RAVE_LOG("HOOK: QAColorTableDelete(engine=0x%08x, ct=0x%08x) -> chaining to original",
	       enginePtr, colorTablePtr);
	const uint32 args[] = { enginePtr, colorTablePtr };
	return RaveChainToOriginal(kRaveHookIdx_ColorTableDelete, 2, args);
}


/*
 *  Hook: QATextureBindColorTable(engine, texture, colorTable)
 *  r3 = engine, r4 = texture, r5 = colorTable
 */
uint32 NativeHookTextureBindColorTable(uint32 engine, uint32 texture, uint32 colorTable)
{
	if (engine == rave_sentinel_engine) {
		RAVE_LOG("HOOK: QATextureBindColorTable(sentinel, tex=0x%08x, ct=0x%08x)", texture, colorTable);
		return (uint32)NativeEngineTextureBindColorTable(texture, colorTable);
	} else {
		if (rave_orig_texture_bind_color_table == 0) return (uint32)(int32)kQANotSupported;
		const uint32 args[] = { engine, texture, colorTable };
		return RaveChainToOriginal(kRaveHookIdx_TextureBindColorTable, 3, args);
	}
}


/*
 *  Hook: QABitmapBindColorTable(engine, bitmap, colorTable)
 *  r3 = engine, r4 = bitmap, r5 = colorTable
 */
uint32 NativeHookBitmapBindColorTable(uint32 engine, uint32 bitmap, uint32 colorTable)
{
	if (engine == rave_sentinel_engine) {
		RAVE_LOG("HOOK: QABitmapBindColorTable(sentinel, bmp=0x%08x, ct=0x%08x)", bitmap, colorTable);
		return (uint32)NativeEngineBitmapBindColorTable(bitmap, colorTable);
	} else {
		if (rave_orig_bitmap_bind_color_table == 0) return (uint32)(int32)kQANotSupported;
		const uint32 args[] = { engine, bitmap, colorTable };
		return RaveChainToOriginal(kRaveHookIdx_BitmapBindColorTable, 3, args);
	}
}


/*
 *  Hook: QATextureDetach(engine, texture). Per the spec this is when the
 *  engine may copy the app's pixels; ours already copied at TextureNew.
 *  r3 = engine, r4 = texture
 */
uint32 NativeHookTextureDetach(uint32 engine, uint32 texture)
{
	if (engine == rave_sentinel_engine) {
		RAVE_LOG("HOOK: QATextureDetach(sentinel, tex=0x%08x)", texture);
		return (uint32)NativeEngineTextureDetach(texture);
	} else {
		if (rave_orig_texture_detach == 0) return (uint32)(int32)kQANotSupported;
		const uint32 args[] = { engine, texture };
		return RaveChainToOriginal(kRaveHookIdx_TextureDetach, 2, args);
	}
}


/*
 *  Hook: QABitmapDetach(engine, bitmap)
 *  r3 = engine, r4 = bitmap
 */
uint32 NativeHookBitmapDetach(uint32 engine, uint32 bitmap)
{
	if (engine == rave_sentinel_engine) {
		RAVE_LOG("HOOK: QABitmapDetach(sentinel, bmp=0x%08x)", bitmap);
		return (uint32)NativeEngineBitmapDetach(bitmap);
	} else {
		if (rave_orig_bitmap_detach == 0) return (uint32)(int32)kQANotSupported;
		const uint32 args[] = { engine, bitmap };
		return RaveChainToOriginal(kRaveHookIdx_BitmapDetach, 2, args);
	}
}


/*
 *  Hook: QAAccessTexture(engine, texture, mipmapLevel, flags, buffer)
 *  r3 = engine, r4 = texture, r5 = mipmapLevel, r6 = flags, r7 = buffer
 */
uint32 NativeHookAccessTexture(uint32 engine, uint32 texture, uint32 mipmapLevel,
                                uint32 flags, uint32 buffer)
{
	if (engine == rave_sentinel_engine) {
		RAVE_LOG("HOOK: QAAccessTexture(sentinel, tex=0x%08x, mip=%d, flags=0x%x)",
		       texture, mipmapLevel, flags);
		return (uint32)NativeEngineAccessTexture(texture, mipmapLevel, flags, buffer);
	} else {
		if (rave_orig_access_texture == 0) return (uint32)(int32)kQANotSupported;
		const uint32 args[] = { engine, texture, mipmapLevel, flags, buffer };
		return RaveChainToOriginal(kRaveHookIdx_AccessTexture, 5, args);
	}
}


/*
 *  Hook: QAAccessTextureEnd(engine, texture, dirtyRect)
 *  r3 = engine, r4 = texture, r5 = dirtyRect
 */
uint32 NativeHookAccessTextureEnd(uint32 engine, uint32 texture, uint32 dirtyRect)
{
	if (engine == rave_sentinel_engine) {
		RAVE_LOG("HOOK: QAAccessTextureEnd(sentinel, tex=0x%08x)", texture);
		return (uint32)NativeEngineAccessTextureEnd(texture, dirtyRect);
	} else {
		if (rave_orig_access_texture_end == 0) return (uint32)(int32)kQANotSupported;
		const uint32 args[] = { engine, texture, dirtyRect };
		return RaveChainToOriginal(kRaveHookIdx_AccessTextureEnd, 3, args);
	}
}


/*
 *  Hook: QAAccessBitmap(engine, bitmap, flags, buffer)
 *  r3 = engine, r4 = bitmap, r5 = flags, r6 = buffer
 */
uint32 NativeHookAccessBitmap(uint32 engine, uint32 bitmap, uint32 flags, uint32 buffer)
{
	if (engine == rave_sentinel_engine) {
		RAVE_LOG("HOOK: QAAccessBitmap(sentinel, bmp=0x%08x, flags=0x%x)", bitmap, flags);
		return (uint32)NativeEngineAccessBitmap(bitmap, flags, buffer);
	} else {
		if (rave_orig_access_bitmap == 0) return (uint32)(int32)kQANotSupported;
		const uint32 args[] = { engine, bitmap, flags, buffer };
		return RaveChainToOriginal(kRaveHookIdx_AccessBitmap, 4, args);
	}
}


/*
 *  Hook: QAAccessBitmapEnd(engine, bitmap, dirtyRect)
 *  r3 = engine, r4 = bitmap, r5 = dirtyRect
 */
uint32 NativeHookAccessBitmapEnd(uint32 engine, uint32 bitmap, uint32 dirtyRect)
{
	if (engine == rave_sentinel_engine) {
		RAVE_LOG("HOOK: QAAccessBitmapEnd(sentinel, bmp=0x%08x)", bitmap);
		return (uint32)NativeEngineAccessBitmapEnd(bitmap, dirtyRect);
	} else {
		if (rave_orig_access_bitmap_end == 0) return (uint32)(int32)kQANotSupported;
		const uint32 args[] = { engine, bitmap, dirtyRect };
		return RaveChainToOriginal(kRaveHookIdx_AccessBitmapEnd, 3, args);
	}
}


/*
 *  Build a PPC Gestalt selector function in SheepMem,
 *    pascal OSErr SelectorFunction(OSType selector, long *response)
 *  that stores value in *response and returns noErr.
 */
static uint32 AllocateGestaltCallback(uint32 value)
{
	// 8-byte TVECT + 5 instructions
	uint32 base = SheepMem::ReserveProc(28);
	uint32 code = base + 8;

	WriteMacInt32(base, code);      // code_ptr
	WriteMacInt32(base + 4, 0);     // TOC, unused

	// r3 = selector, r4 = response pointer
	const uint32 r3 = 3, r4 = 4, r5 = 5;

	// lis r5, value_hi
	WriteMacInt32(code + 0, 0x3C000000 | (r5 << 21) | ((value >> 16) & 0xFFFF));
	// ori r5, r5, value_lo
	WriteMacInt32(code + 4, 0x60000000 | (r5 << 21) | (r5 << 16) | (value & 0xFFFF));
	// stw r5, 0(r4) -- *response = value
	WriteMacInt32(code + 8, 0x90000000 | (r5 << 21) | (r4 << 16));
	// li r3, 0 -- return noErr
	WriteMacInt32(code + 12, 0x38000000 | (r3 << 21));
	// blr
	WriteMacInt32(code + 16, 0x4E800020);

	return base;
}


/*
 *  Registration with the RAVE manager. RaveRegisterEngine is called from
 *  VideoInstallAccel and finds QARegisterEngine with FindLibSymbol; if the
 *  library isn't loaded yet it fails quietly and is retried later.
 */
static bool rave_registered = false;
static bool rave_reg_in_progress = false;
static int rave_reg_attempts = 0;
static const int RAVE_REG_MAX_ATTEMPTS = 3;

bool RaveIsRegistered(void)
{
	return rave_registered;
}

/*
 *  gfxaccel_resources mode-change handlers, registered from
 *  RaveRegisterEngine.
 *    RaveOnAttach (mode enter): pre-vend the overlay pair at the new size if
 *      RAVE has a live or preserved overlay; otherwise it is vended lazily.
 *    RaveOnDetach (mode exit): release the cached overlay.
 *  These run on the DMC writer thread under its mutex, so they must not call
 *  back into DMC (deadlock).
 */
static int32_t RaveOnAttach(uint32_t /* engine_id */,
                            const struct DMCModeSnapshot *incoming,
                            void * /* ctx */)
{
	/* No overlay to carry over (e.g. a 2D-only app): vend lazily later. */
	if (!rave_has_active_overlay()) {
		return 0;  /* kGfxAccelResNoErr */
	}
	if (incoming == NULL) {
		return 0;
	}

	/* Pre-vend so the first present after the switch has an overlay. */
	void *tex0 = gfxaccel_resources_vend_overlay_texture_indexed(
	                kGfxEngineRAVE,
	                0,
	                incoming->width,
	                incoming->height,
	                80 /* MTLPixelFormatBGRA8Unorm */);
	void *tex1 = gfxaccel_resources_vend_overlay_texture_indexed(
	                kGfxEngineRAVE,
	                1,
	                incoming->width,
	                incoming->height,
	                80 /* MTLPixelFormatBGRA8Unorm */);
	if (tex0 == NULL || tex1 == NULL) {
		if (tex0 != NULL) gfxaccel_resources_release_overlay_texture(kGfxEngineRAVE, tex0);
		if (tex1 != NULL) gfxaccel_resources_release_overlay_texture(kGfxEngineRAVE, tex1);
		/* Reject the transition; DMC rolls back. */
		return kDMCErrSubscriberRejected;
	}
	return 0;
}

static int32_t RaveOnDetach(uint32_t /* engine_id */,
                            const struct DMCModeSnapshot * /* outgoing */,
                            void * /* ctx */)
{
	/* Idempotent; the next RaveCreateMetalOverlay re-vends. */
	rave_release_overlay_for_detach();
	return 0;
}

static bool rave_resource_handlers_registered = false;

static void RaveRegisterResourceHandlers(void)
{
	if (rave_resource_handlers_registered) return;
	struct GfxResEngineHandlers rave_handlers;
	rave_handlers.attach = RaveOnAttach;
	rave_handlers.detach = RaveOnDetach;
	rave_handlers.ctx    = NULL;
	gfxaccel_resources_register_engine(kGfxEngineRAVE, &rave_handlers);
	rave_resource_handlers_registered = true;
}

void RaveRegisterEngine(void)
{
	// rave_registered is set on success; rave_reg_in_progress blocks
	// re-entry via FindLibSymbol -> CFM load -> VideoInstallAccel. A failed
	// FindLibSymbol (library not loaded yet, e.g. during Disk First Aid) is
	// retried: sony.cpp accRun keeps calling PatchAfterStartup until
	// registration succeeds.
	if (rave_registered) {
		return;
	}
	if (rave_reg_attempts >= RAVE_REG_MAX_ATTEMPTS) {
		return;
	}
	if (rave_reg_in_progress) {
		RAVE_LOG("RaveRegisterEngine() skipped (re-entrant call)");
		return;
	}
	rave_reg_in_progress = true;

	RAVE_LOG("RaveRegisterEngine() called");

	// gfxaccel_resources_init has already run (main_unix.cpp init order), so
	// the handlers can be registered first. Idempotent.
	RaveRegisterResourceHandlers();

	// Do every FindLibSymbol lookup before the first CallMacOS. FindLibSymbol
	// can load CFM fragments, which re-enters VideoInstallAccel ->
	// RaveRegisterEngine; the guard catches that, but the CFM path corrupts
	// a CallMacOS frame that is already in progress.

	// The CFM fragment is "QuickDraw™ 3D Accelerator" (from the PEF imports of
	// the DDK Empty Engine sample); the file on disk is "QuickDraw™ 3D RAVE".
	// Pascal strings; ™ is MacRoman 0xAA.
	static const char *rave_lib_names[] = {
		"\031QuickDraw\xAA 3D Accelerator",  // CFM fragment name
		"\022QuickDraw\xAA 3D RAVE",          // file name
		"\022QuickDraw3DRAVELib",              // stub library
		NULL
	};

	uint32 qa_register = 0;
	const char *found_rave_lib = NULL;
	for (int i = 0; rave_lib_names[i] != NULL; i++) {
		RAVE_LOG("  trying library '%s' (len %d)",
			   rave_lib_names[i] + 1, (unsigned char)rave_lib_names[i][0]);
		qa_register = FindLibSymbol(rave_lib_names[i], "\020QARegisterEngine");
		if (qa_register != 0) {
			found_rave_lib = rave_lib_names[i];
			RAVE_LOG("QARegisterEngine found via '%s' at TVECT 0x%08x",
					 rave_lib_names[i] + 1, qa_register);
			break;
		}
		RAVE_LOG("  -> not found");
	}

	if (qa_register == 0) {
		rave_reg_in_progress = false;
		rave_reg_attempts++;
		if (rave_reg_attempts >= RAVE_REG_MAX_ATTEMPTS)
			RAVE_LOG("QARegisterEngine not found after %d attempts, giving up", rave_reg_attempts);
		else
			RAVE_LOG("QARegisterEngine not found, skipping 3D acceleration (attempt %d/%d, will retry)",
			         rave_reg_attempts, RAVE_REG_MAX_ATTEMPTS);
		return;
	}

	// InterfaceLib NewGestalt, for the Gestalt selectors registered below
	uint32 new_gestalt_tvect = FindLibSymbol("\014InterfaceLib", "\012NewGestalt");
	RAVE_LOG("cached InterfaceLib: NewGestalt=0x%08x", new_gestalt_tvect);

	// From here on only CallMacOS, no FindLibSymbol.

	// Sub-opcode 100 (kRaveEngineDrawPrivateNew) is the EngineGetMethod TVECT.
	uint32 engine_get_method_tvect = rave_method_tvects[kRaveEngineDrawPrivateNew];

	if (engine_get_method_tvect == 0) {
		RAVE_LOG("EngineGetMethod TVECT not allocated, skipping registration");
		rave_reg_in_progress = false;
		return;
	}

	RAVE_LOG("Registering engine with EngineGetMethod TVECT 0x%08x", engine_get_method_tvect);

	// TQAError QARegisterEngine(TQAEngineGetMethod)
	typedef int32 (*qa_register_t)(uint32);
	int32 err = (int32)CallMacOS1(qa_register_t, qa_register, engine_get_method_tvect);

	if (err != kQANoErr) {
		RAVE_LOG("engine registration failed with error %d", err);
		rave_reg_in_progress = false;
		return;
	}

	RAVE_LOG("engine registered successfully");


	if (new_gestalt_tvect) {
		typedef int16 (*new_gestalt_t)(uint32, uint32);

		// 'rave' (gestaltRaveVersion) = RAVE 1.6
		{
			uint32 callback = AllocateGestaltCallback(0x00010600);
			int16 gerr = (int16)CallMacOS2(new_gestalt_t, new_gestalt_tvect,
				0x72617665, callback);
			RAVE_LOG("NewGestalt('rave', 0x00010600) -> %d", gerr);
		}

		// 'qd3x' (QD3D hardware extensions) = 1
		{
			uint32 callback = AllocateGestaltCallback(0x00000001);
			int16 gerr = (int16)CallMacOS2(new_gestalt_t, new_gestalt_tvect,
				0x71643378, callback);
			RAVE_LOG("NewGestalt('qd3x', 0x00000001) -> %d", gerr);
		}

		// 'gls ' (OpenGL version) = 1.2
		{
			uint32 callback = AllocateGestaltCallback(0x0120);
			int16 gerr = (int16)CallMacOS2(new_gestalt_t, new_gestalt_tvect,
				0x676c7320, callback);
			RAVE_LOG("NewGestalt('gls ', 0x0120) -> %d", gerr);
		}
	} else {
		RAVE_LOG("NewGestalt not found, skipping Gestalt registration");
	}

	// QARegisterEngine "succeeds" but never adds us to the manager's engine
	// list: it needs a ZgLoadingSharedLibrary context we can't provide from
	// VideoInstallAccel. So hook the manager APIs; the hooks handle our
	// sentinel engine and chain for every other engine.
	RaveInstallHooks();

	rave_registered = true;
	rave_reg_in_progress = false;

	RAVE_LOG("init complete -- waiting for QD3D IR calls");
}


/*
 *  RaveInstallHooks - patch the RAVE manager APIs listed below so our
 *  sentinel engine is handled natively. Each entry is redirected to a hook
 *  thunk that dispatches through NATIVE_RAVE_DISPATCH.
 */
void RaveInstallHooks(void)
{
	RAVE_LOG("installing enumeration hooks");

	// Same candidate names as RaveRegisterEngine.
	static const char *rave_lib_names[] = {
		"\031QuickDraw\xAA 3D Accelerator",  // 25 chars: CFM fragment name
		"\022QuickDraw\xAA 3D RAVE",          // 18 chars: file name
		"\022QuickDraw3DRAVELib",              // 18 chars: stub library name
		NULL
	};

	// All APIs must resolve from one library. Besides enumeration, resource
	// creation and deletion are hooked too, because the manager doesn't know
	// our engine.
	struct {
		const char *sym;   // Pascal string
		uint32 *orig;      // original TVECT
		int hook_id;       // hook sub-opcode
		const char *name;
	} apis[] = {
		{ "\026QADeviceGetFirstEngine", &rave_orig_get_first_engine,  kRaveHookGetFirstEngine,    "QADeviceGetFirstEngine" },
		{ "\025QADeviceGetNextEngine",  &rave_orig_get_next_engine,   kRaveHookGetNextEngine,     "QADeviceGetNextEngine" },
		{ "\017QAEngineGestalt",        &rave_orig_engine_gestalt,    kRaveHookEngineGestalt,     "QAEngineGestalt" },
		{ "\023QAEngineCheckDevice",    &rave_orig_engine_check_device, kRaveHookEngineCheckDevice, "QAEngineCheckDevice" },
		{ "\020QADrawContextNew",       &rave_orig_draw_context_new,  kRaveHookDrawContextNew,    "QADrawContextNew" },
		{ "\014QATextureNew",           &rave_orig_texture_new,       kRaveHookTextureNew,        "QATextureNew" },
		{ "\013QABitmapNew",            &rave_orig_bitmap_new,        kRaveHookBitmapNew,         "QABitmapNew" },
		{ "\017QAColorTableNew",        &rave_orig_color_table_new,   kRaveHookColorTableNew,     "QAColorTableNew" },
		{ "\023QADrawContextDelete",  &rave_orig_draw_context_delete, kRaveHookDrawContextDelete, "QADrawContextDelete" },
		{ "\017QATextureDelete",      &rave_orig_texture_delete,      kRaveHookTextureDelete,     "QATextureDelete" },
		{ "\016QABitmapDelete",       &rave_orig_bitmap_delete,       kRaveHookBitmapDelete,      "QABitmapDelete" },
		{ "\022QAColorTableDelete",   &rave_orig_color_table_delete,  kRaveHookColorTableDelete,  "QAColorTableDelete" },
		{ "\027QATextureBindColorTable", &rave_orig_texture_bind_color_table, kRaveHookTextureBindColorTable, "QATextureBindColorTable" },
		{ "\026QABitmapBindColorTable",  &rave_orig_bitmap_bind_color_table,  kRaveHookBitmapBindColorTable,  "QABitmapBindColorTable" },
		{ "\017QATextureDetach",        &rave_orig_texture_detach,           kRaveHookTextureDetach,         "QATextureDetach" },
		{ "\016QABitmapDetach",         &rave_orig_bitmap_detach,            kRaveHookBitmapDetach,          "QABitmapDetach" },
		{ "\017QAAccessTexture",        &rave_orig_access_texture,           kRaveHookAccessTexture,         "QAAccessTexture" },
		{ "\022QAAccessTextureEnd",     &rave_orig_access_texture_end,       kRaveHookAccessTextureEnd,      "QAAccessTextureEnd" },
		{ "\016QAAccessBitmap",         &rave_orig_access_bitmap,            kRaveHookAccessBitmap,          "QAAccessBitmap" },
		{ "\021QAAccessBitmapEnd",      &rave_orig_access_bitmap_end,        kRaveHookAccessBitmapEnd,       "QAAccessBitmapEnd" },
		{ "\016QAEngineEnable",         &rave_orig_engine_enable,            kRaveHookEngineEnable,          "QAEngineEnable" },
		{ "\017QAEngineDisable",        &rave_orig_engine_disable,           kRaveHookEngineDisable,         "QAEngineDisable" },
	};
	const int num_apis = 22;

	bool all_found = false;
	for (int lib = 0; rave_lib_names[lib] != NULL; lib++) {
		RAVE_LOG("  trying library '%s' for hooks", rave_lib_names[lib] + 1);

		bool found_all = true;
		for (int i = 0; i < num_apis; i++) {
			uint32 tvect = FindLibSymbol(rave_lib_names[lib], apis[i].sym);
			if (tvect == 0) {
				RAVE_LOG("    %s not found", apis[i].name);
				found_all = false;
				break;
			}
			*apis[i].orig = tvect;
			RAVE_LOG("    %s TVECT at 0x%08x", apis[i].name, tvect);
		}

		if (found_all) {
			all_found = true;
			break;
		}
	}

	if (!all_found) {
		RAVE_LOG("FAILED to find all enumeration APIs, hooks NOT installed");
		return;
	}

	// Patch the first 4 instructions of each function with
	//   lis r11,hi; ori r11,r11,lo; mtctr r11; bctr
	// to the hook thunk. Patching code instead of TVECTs catches every
	// caller, including per-importer TVECT copies. r11 is volatile, and
	// mtctr/bctr leaves LR alone, so the caller's return address survives.
	// RaveChainToOriginal restores the saved instructions to call through.

	const uint32 r11 = 11;

	for (int i = 0; i < num_apis; i++) {
		uint32 orig_tvect = *apis[i].orig;
		uint32 hook_tvect = rave_method_tvects[apis[i].hook_id];

		if (hook_tvect == 0) {
			RAVE_LOG("  hook TVECT for %s not allocated!", apis[i].name);
			continue;
		}

		uint32 orig_code = ReadMacInt32(orig_tvect);

		uint32 hook_code = ReadMacInt32(hook_tvect);

		uint32 saved_instr[4];
		for (int j = 0; j < 4; j++) {
			saved_instr[j] = ReadMacInt32(orig_code + j * 4);
		}

		RAVE_LOG("  %s: orig_code=0x%08x, first 4 instrs: %08x %08x %08x %08x",
			   apis[i].name, orig_code,
			   saved_instr[0], saved_instr[1], saved_instr[2], saved_instr[3]);

		uint32 hook_hi = (hook_code >> 16) & 0xFFFF;
		uint32 hook_lo = hook_code & 0xFFFF;

		uint32 hook_instr[4];
		// lis r11, hook_code_hi
		hook_instr[0] = 0x3C000000 | (r11 << 21) | hook_hi;
		// ori r11, r11, hook_code_lo
		hook_instr[1] = 0x60000000 | (r11 << 21) | (r11 << 16) | hook_lo;
		// mtctr r11
		hook_instr[2] = 0x7C0903A6 | (r11 << 21);
		// bctr
		hook_instr[3] = 0x4E800420;

		rave_hook_patches[i].orig_tvect = orig_tvect;
		rave_hook_patches[i].orig_code  = orig_code;
		for (int j = 0; j < 4; j++) {
			rave_hook_patches[i].saved_instr[j] = saved_instr[j];
			rave_hook_patches[i].hook_instr[j]  = hook_instr[j];
		}
		rave_hook_patches[i].active = true;

		for (int j = 0; j < 4; j++) {
			WriteMacInt32(orig_code + j * 4, hook_instr[j]);
		}

#if EMULATED_PPC
		FlushCodeCache(orig_code, orig_code + 16);
#endif

		uint32 verify = ReadMacInt32(orig_code);
		RAVE_LOG("  patched %s: orig_code 0x%08x now starts with 0x%08x (expect 0x%08x)",
			   apis[i].name, orig_code, verify, hook_instr[0]);
		RAVE_LOG("  patch info stored at hook_patches[%d], orig_tvect=0x%08x",
			   i, orig_tvect);

		// rave_orig_* still hold the original TVECTs.
	}

	RAVE_LOG("enumeration hooks installed, sentinel engine at 0x%08x",
		   rave_sentinel_engine);
}


/*
 *  ATI RaveExtFuncs textureUpdate: re-upload an existing texture. ATI pixel
 *  types 1000-1003 map to standard types.
 */

enum {
	kQATIPixel_RGB4444  = 1000,
	kQATIPixel_ARGB4444 = 1001,
	kQATIPixel_YUV422   = 1002,
	kQATIPixel_ARGB8    = 1003
};

int32_t NativeATITextureUpdate(uint32_t flags, uint32_t pixelType, uint32_t imagesAddr, uint32_t textureAddr)
{
	uint32_t handle = RaveResourceFindByAddr(textureAddr);
	RaveResourceEntry *entry = RaveResourceGet(handle);
	if (!entry || entry->type != kRaveResourceTexture) {
		RAVE_LOG("ATITextureUpdate: texture not found at 0x%08x", textureAddr);
		return kQAError;
	}
	if (!imagesAddr || uint64_t(imagesAddr) + 16 > uint64_t(UINT32_MAX) + 1)
		return kQAParamErr;

	// TQAImage: width, height, rowBytes, pixels
	uint32_t width      = ReadMacInt32(imagesAddr + 0);
	uint32_t height     = ReadMacInt32(imagesAddr + 4);
	uint32_t rowBytes   = ReadMacInt32(imagesAddr + 8);
	uint32_t pixelBuffer = ReadMacInt32(imagesAddr + 12);

	if (width == 0 || height == 0 || pixelBuffer == 0) {
		RAVE_LOG("ATITextureUpdate: invalid image params %dx%d buf=0x%08x", width, height, pixelBuffer);
		return kQAError;
	}

	uint32_t effectivePixelType = pixelType;
	switch (pixelType) {
		case kQATIPixel_ARGB8:
			effectivePixelType = kQAPixel_ARGB32;
			break;
		case kQATIPixel_RGB4444:
		case kQATIPixel_ARGB4444:
			effectivePixelType = kQAPixel_ARGB16_4444;
			break;
		case kQATIPixel_YUV422:
			RAVE_LOG("ATITextureUpdate: YUV422 pixel type not supported");
			return kQANotSupported;
		default:
			break;
	}

	// Must match the existing texture; validate before reading pixels.
	if (!RaveImageLayoutIsValid(effectivePixelType, width, height, rowBytes, pixelBuffer) ||
	    width != entry->width || height != entry->height)
		return kQAParamErr;
	const uint32_t bgra_row_bytes = width * 4;
	uint8_t *bgra_data = new (std::nothrow) uint8_t[size_t(bgra_row_bytes) * height];
	if (!bgra_data) return kQAOutOfMemory;

	bool converted = ConvertPixels(effectivePixelType, pixelBuffer, bgra_data, width, height, rowBytes);
	if (!converted) {
		RAVE_LOG("ATITextureUpdate: unsupported pixel type %d (effective %d)", pixelType, effectivePixelType);
		delete[] bgra_data;
		return kQAError;
	}
	bool whitenedAlphaMask = false;
	if (effectivePixelType == kQAPixel_ARGB32) {
		whitenedAlphaMask = RaveBGRAWhitenAlphaOnlyMask(bgra_data, width * height);
	}
	RaveBGRAImageStats stats = RaveBGRAImageAnalyze(bgra_data, width * height);
	entry->diag_alpha_zero = (width * height) - stats.alpha;
	entry->diag_index_zero = 0;
	entry->diag_rgb_nonzero = stats.rgb;

	if (entry->metal_texture) {
		// One pass break for level 0 and the regenerated chain.
		RaveTextureUploadBatchBegin();
		RaveUploadMipLevel(entry->metal_texture, 0, width, height, bgra_data, bgra_row_bytes);

		if (entry->mip_levels > 1) {
			RaveUploadGeneratedMips(entry->metal_texture, bgra_data, width, height, entry->mip_levels);
		}
		RaveTextureUploadBatchEnd();
	} else {
		// Not realized yet, so this update is lost and the texture later
		// realizes from its pixmap, which may be stale.
		RAVE_LOG("ATITextureUpdate: DROPPED update on unrealized texture 0x%08x (%dx%d rgb=%u/%u pixmap=0x%08x) — metal_texture==NULL",
		         textureAddr, width, height, stats.rgb, width * height, entry->pixmap_mac_addr);
	}

	delete[] bgra_data;

	RAVE_LOG("ATITextureUpdate: updated texture 0x%08x (%dx%d, pixelType=%d->%d, alphaMaskWhite=%d)",
	         textureAddr, width, height, pixelType, effectivePixelType, whitenedAlphaMask);
	return kQANoErr;
}


/*
 *  ATI RaveExtFuncs bindCodeBook: VQ textures (8-bit indices into 256 2x2
 *  ARGB blocks). Not implemented; returns kQANotSupported.
 */
int32_t NativeATIBindCodeBook(uint32_t textureAddr, uint32_t codebookPtr)
{
	RAVE_LOG("ATIBindCodeBook: texture 0x%08x codebook 0x%08x -> kQANotSupported (VQ not implemented)",
	         textureAddr, codebookPtr);
	return kQANotSupported;
}
