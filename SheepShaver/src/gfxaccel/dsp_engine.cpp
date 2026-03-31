/*
 *  dsp_engine.cpp - DrawSprocket acceleration engine: hook installation and handler functions
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Implements:
 *    - FindLibSymbol-based hook installation for DrawSprocketLib interception
 *    - Real handlers for the 8 key DSp functions (startup, shutdown, version,
 *      display enumeration, context enumeration, context attributes, display ID)
 *    - Remaining 46 functions return noErr as stubs for S02/S03
 *
 *  Hook installation follows the GL two-phase pattern:
 *    Phase 1: All FindLibSymbol lookups first (cache results)
 *    Phase 2: Patch TVECTs (avoids re-entrancy from CFM callbacks)
 */

#include <cstring>
#include <cstdio>
#include <vector>

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "thunks.h"
#include "macos_util.h"
#include "prefs.h"
#include "video.h"
#include "dsp_engine.h"
#include "metal_compositor.h"

#define DEBUG 0
#include "debug.h"

// ---- DrawSprocket Error Codes (from Mac OS headers) ----
enum {
	kDSpNoErr               = 0,
	kDSpNotInitializedErr   = -7000,
	kDSpInvalidContextErr   = -7001,
	kDSpInvalidAttributeErr = -7002,
	kDSpContextBusyErr      = -7003,
	kDSpNotSupportedErr     = -7004
};

// ---- DSp Version: 1.7.3 = 0x01730000 (BCD major.minor.bugfix.stage) ----
// DrawSprocket uses NumVersion encoding: major(8).minor(4).bugfix(4).stage(8).unused(8)
// Version 1.7.3 final = 0x01730080 (stage = 0x80 = final)
static const uint32_t kDSpVersion = 0x01730080;

// ---- Hook Installation State ----
static bool dsp_hooks_installed = false;
static bool dsp_hooks_in_progress = false;
static int dsp_hooks_attempts = 0;
static const int DSP_HOOKS_MAX_ATTEMPTS = 3;

// ---- Engine State ----
static bool dsp_started = false;

// Single context handle — DrawSprocket in the emulator exposes one display.
// This is a non-zero sentinel used to represent the emulator's display context.
// We use a small fixed value since we don't allocate a real Mac-side struct.
static const uint32_t kDSpContextSentinel = 0x44535043;  // 'DSPC'

// ---- Context Lifecycle State ----
static bool dsp_context_reserved = false;
static bool dsp_context_active = false;
static uint32_t dsp_back_buffer_addr = 0;     // Mac address of pixel data (Mac_sysalloc)
static uint32_t dsp_back_buffer_size = 0;
static uint32_t dsp_back_buffer_rowbytes = 0;  // actual row bytes (without 0x8000 flag)
static uint32_t dsp_back_grafport_addr = 0;    // Mac address of CGrafPort struct (SheepMem)
static uint32_t dsp_back_pixmap_addr = 0;      // Mac address of PixMap struct (SheepMem)
static uint32_t dsp_pixmap_handle_addr = 0;    // Mac address of 4-byte PixMapHandle indirection (SheepMem)

// ---- Blanking Color State (RGB16, native-side) ----
static uint16_t dsp_blanking_color[3] = {0, 0, 0};

// ---- Gamma Fade State ----
// Gamma level: 1.0 = fully visible, 0.0 = fully faded to zero-intensity color
static float dsp_gamma_level = 1.0f;
// Zero-intensity color (RGB, normalized 0.0–1.0) — what the display fades toward
static float dsp_gamma_zero_color[3] = {0.0f, 0.0f, 0.0f};

// ---- Alt Buffer State ----
// Currently attached underlay/overlay alt buffer CGrafPort Mac addresses (0 = none)
static uint32_t dsp_underlay_grafport = 0;
static uint32_t dsp_overlay_grafport = 0;
// Cached pixel data addresses for compositing (avoid re-traversing CGrafPort chain each frame)
static uint32_t dsp_underlay_pixel_addr = 0;
static uint32_t dsp_overlay_pixel_addr = 0;
static uint32_t dsp_underlay_pixel_size = 0;
static uint32_t dsp_overlay_pixel_size = 0;

// Tracking struct for allocated alt buffers so they can be freed on dispose/release
struct DSpAltBufferRecord {
	uint32_t grafport_addr;     // CGrafPort Mac address (the "reference" returned to game)
	uint32_t pixmap_addr;       // PixMap Mac address (SheepMem)
	uint32_t pixmap_handle_addr;// PixMapHandle Mac address (SheepMem)
	uint32_t pixel_addr;        // Pixel data Mac address (Mac_sysalloc)
	uint32_t pixel_size;        // Pixel data size in bytes
};
static std::vector<DSpAltBufferRecord> dsp_alt_buffers;

// ---- Default Display Mode (fallback if video globals not yet initialized) ----
static const uint16_t kDefaultDisplayWidth  = 640;
static const uint16_t kDefaultDisplayHeight = 480;
static const uint32_t kDefaultDisplayDepth  = 32;

// ---- Fixed Display ID ----
static const uint32_t kDSpDisplayID = 1;


// ===========================================================================
//  Helpers: current display mode from video.h globals
// ===========================================================================

static uint16_t DSpGetCurrentWidth(void)
{
	if (cur_mode >= 0 && VModes[cur_mode].viXsize > 0)
		return VModes[cur_mode].viXsize;
	return kDefaultDisplayWidth;
}

static uint16_t DSpGetCurrentHeight(void)
{
	if (cur_mode >= 0 && VModes[cur_mode].viYsize > 0)
		return VModes[cur_mode].viYsize;
	return kDefaultDisplayHeight;
}

// Return bit depth from Apple mode code
static uint32_t DSpGetCurrentDepth(void)
{
	if (cur_mode < 0)
		return kDefaultDisplayDepth;

	switch (VModes[cur_mode].viAppleMode) {
		case APPLE_1_BIT:  return 1;
		case APPLE_2_BIT:  return 2;
		case APPLE_4_BIT:  return 4;
		case APPLE_8_BIT:  return 8;
		case APPLE_16_BIT: return 16;
		case APPLE_32_BIT: return 32;
		default:           return kDefaultDisplayDepth;
	}
}

// Depth mask from bit depth (DrawSprocket uses bitmask where bit N = depth N is supported)
static uint32_t DSpDepthMask(uint32_t depth)
{
	return (1u << depth);
}


// ===========================================================================
//  Key Handler Functions (called from DSpDispatch in dsp_dispatch.cpp)
// ===========================================================================

/*
 *  DSpHandleStartup — DSP_SUB_STARTUP (opcode 0)
 *
 *  Initialize DrawSprocket. Sets dsp_started flag.
 *  Returns noErr.
 */
uint32_t DSpHandleStartup(void)
{
	dsp_started = true;
	DSP_LOG("DSpStartup: initialized (display %dx%dx%d)",
	        DSpGetCurrentWidth(), DSpGetCurrentHeight(), DSpGetCurrentDepth());
	return kDSpNoErr;
}

/*
 *  DSpHandleShutdown — DSP_SUB_SHUTDOWN (opcode 1)
 *
 *  Shut down DrawSprocket. Clears dsp_started flag.
 *  Returns noErr.
 */
uint32_t DSpHandleShutdown(void)
{
	dsp_started = false;
	DSP_LOG("DSpShutdown: shut down");
	return kDSpNoErr;
}

/*
 *  DSpHandleGetVersion — DSP_SUB_GET_VERSION (opcode 2)
 *
 *  r3 = pointer to NumVersion output.
 *  Writes DrawSprocket version 1.7.3 to PPC memory.
 *  Returns noErr.
 */
uint32_t DSpHandleGetVersion(uint32_t r3)
{
	if (r3 != 0) {
		WriteMacInt32(r3, kDSpVersion);
	}
	DSP_LOG("DSpGetVersion: 0x%08x -> 0x%08x", r3, kDSpVersion);
	return kDSpNoErr;
}

/*
 *  DSpHandleGetFirstDisplayID — DSP_SUB_GET_FIRST_DISPLAY_ID (opcode 3)
 *
 *  r3 = pointer to DisplayIDType output.
 *  Writes our single display ID.
 *  Returns noErr.
 */
uint32_t DSpHandleGetFirstDisplayID(uint32_t r3)
{
	if (r3 != 0) {
		WriteMacInt32(r3, kDSpDisplayID);
	}
	DSP_LOG("DSpGetFirstDisplayID: displayID=%d -> 0x%08x", kDSpDisplayID, r3);
	return kDSpNoErr;
}

/*
 *  DSpHandleGetNextDisplayID — DSP_SUB_GET_NEXT_DISPLAY_ID (opcode 4)
 *
 *  r3 = current DisplayIDType
 *  r4 = pointer to next DisplayIDType output
 *  Only one display exists, so always writes 0 (end of list).
 *  Returns noErr.
 */
uint32_t DSpHandleGetNextDisplayID(uint32_t r3, uint32_t r4)
{
	if (r4 != 0) {
		WriteMacInt32(r4, 0);  // No more displays
	}
	DSP_LOG("DSpGetNextDisplayID: currentID=%d -> next=0 (end of list)", r3);
	return kDSpNoErr;
}

/*
 *  DSpHandleFindBestContext — DSP_SUB_FIND_BEST_CONTEXT (opcode 18)
 *
 *  r3 = pointer to DSpContextAttributes (desired)
 *  r4 = pointer to DSpContextReference output
 *  Writes our single context handle.
 *  Returns noErr.
 */
uint32_t DSpHandleFindBestContext(uint32_t r3, uint32_t r4)
{
	if (r4 != 0) {
		WriteMacInt32(r4, kDSpContextSentinel);
	}
	DSP_LOG("DSpFindBestContext: desired=0x%08x -> context=0x%08x", r3, kDSpContextSentinel);
	return kDSpNoErr;
}

/*
 *  DSpHandleContextGetAttributes — DSP_SUB_CONTEXT_GET_ATTRIBUTES (opcode 8)
 *
 *  r3 = DSpContextReference (context handle)
 *  r4 = pointer to DSpContextAttributes output struct
 *
 *  Writes a DSpContextAttributes struct to PPC memory matching the emulator's
 *  current display mode.
 *
 *  DSpContextAttributes layout (DrawSprocket 1.7):
 *    Offset  Size  Field
 *    0       4     frequency (Fixed 16.16)
 *    4       4     displayWidth
 *    8       4     displayHeight
 *    12      4     reserved1
 *    16      4     reserved2
 *    20      4     colorNeeds (0=dontCare, 1=request, 2=require)
 *    24      4     colorTable (CTabHandle)
 *    28      4     contextOption (OptionBits)
 *    32      4     backBufferDepthMask
 *    36      4     displayDepthMask
 *    40      4     backBufferBestDepth
 *    44      4     displayBestDepth
 *    48      4     pageCount
 *    52      4     filler[0]
 *    56      4     filler[1]
 *    60      4     filler[2]
 *    64      4     filler[3]
 *    68      4     gammaTableID
 *    72      4     reserved3
 *    Total = 76 bytes
 */
uint32_t DSpHandleContextGetAttributes(uint32_t r3, uint32_t r4)
{
	if (r4 == 0)
		return kDSpInvalidAttributeErr;

	uint16_t width = DSpGetCurrentWidth();
	uint16_t height = DSpGetCurrentHeight();
	uint32_t depth = DSpGetCurrentDepth();
	uint32_t depthMask = DSpDepthMask(depth);

	// Zero the entire struct first
	for (int i = 0; i < 76; i += 4) {
		WriteMacInt32(r4 + i, 0);
	}

	// Fill in fields
	WriteMacInt32(r4 + 0,  0);               // frequency = 0 (from monitor)
	WriteMacInt32(r4 + 4,  width);            // displayWidth
	WriteMacInt32(r4 + 8,  height);           // displayHeight
	WriteMacInt32(r4 + 12, 0);               // reserved1
	WriteMacInt32(r4 + 16, 0);               // reserved2
	WriteMacInt32(r4 + 20, 2);               // colorNeeds = kDSpColorNeeds_Require
	WriteMacInt32(r4 + 24, 0);               // colorTable = NULL
	WriteMacInt32(r4 + 28, 0);               // contextOption = 0
	WriteMacInt32(r4 + 32, depthMask);        // backBufferDepthMask
	WriteMacInt32(r4 + 36, depthMask);        // displayDepthMask
	WriteMacInt32(r4 + 40, depth);            // backBufferBestDepth
	WriteMacInt32(r4 + 44, depth);            // displayBestDepth
	WriteMacInt32(r4 + 48, 1);               // pageCount = 1
	// filler[0..3] already zeroed
	WriteMacInt32(r4 + 68, 0);               // gammaTableID = 0
	WriteMacInt32(r4 + 72, 0);               // reserved3

	DSP_LOG("DSpContext_GetAttributes: context=0x%08x -> %dx%dx%d mask=0x%08x",
	        r3, width, height, depth, depthMask);
	return kDSpNoErr;
}

/*
 *  DSpHandleContextGetDisplayID — DSP_SUB_CONTEXT_GET_DISPLAY_ID (opcode 9)
 *
 *  r3 = DSpContextReference (context handle)
 *  r4 = pointer to DisplayIDType output
 *  Returns our fixed display ID.
 */
uint32_t DSpHandleContextGetDisplayID(uint32_t r3, uint32_t r4)
{
	if (r4 != 0) {
		WriteMacInt32(r4, kDSpDisplayID);
	}
	DSP_LOG("DSpContext_GetDisplayID: context=0x%08x -> displayID=%d", r3, kDSpDisplayID);
	return kDSpNoErr;
}

/*
 *  DSpHandleFindBestContextOnDisplayID — DSP_SUB_FIND_BEST_CONTEXT_ON_DISPLAY_ID (opcode 17)
 *
 *  r3 = DisplayIDType
 *  r4 = pointer to DSpContextAttributes (desired)
 *  r5 = pointer to DSpContextReference output
 *  Writes our single context handle.
 */
uint32_t DSpHandleFindBestContextOnDisplayID(uint32_t r3, uint32_t r4, uint32_t r5)
{
	if (r5 != 0) {
		WriteMacInt32(r5, kDSpContextSentinel);
	}
	DSP_LOG("DSpFindBestContextOnDisplayID: displayID=%d -> context=0x%08x", r3, kDSpContextSentinel);
	return kDSpNoErr;
}

/*
 *  DSpHandleGetCurrentDisplayID — DSP_SUB_GET_CURRENT_DISPLAY_ID (opcode 5)
 *
 *  r3 = DSpContextReference
 *  r4 = pointer to DisplayIDType output
 *  Returns our fixed display ID (same as GetDisplayID for our single-display case).
 */
uint32_t DSpHandleGetCurrentDisplayID(uint32_t r3, uint32_t r4)
{
	if (r4 != 0) {
		WriteMacInt32(r4, kDSpDisplayID);
	}
	DSP_LOG("DSpGetCurrentDisplayID: context=0x%08x -> displayID=%d", r3, kDSpDisplayID);
	return kDSpNoErr;
}

/*
 *  DSpHandleGetDisplayAttributes — DSP_SUB_GET_DISPLAY_ATTRIBUTES (opcode 6)
 *
 *  r3 = DisplayIDType
 *  r4 = pointer to DSpContextAttributes output
 *  Fills in display attributes for the given display ID.
 */
uint32_t DSpHandleGetDisplayAttributes(uint32_t r3, uint32_t r4)
{
	// Reuse the context attributes logic — same data for our single display
	return DSpHandleContextGetAttributes(0, r4);
}


// ===========================================================================
//  Context Lifecycle Handlers (S02)
// ===========================================================================

/*
 *  DSpHandleContextReserve — DSP_SUB_RESERVE (opcode 23)
 *
 *  r3 = DSpContextReference (sentinel)
 *  r4 = DSpContextAttributes* (desired attributes — ignored, we use current display)
 *
 *  Allocates back buffer pixel data via Mac_sysalloc and constructs a valid
 *  CGrafPort + PixMap in SheepMem so games can obtain a CGrafPtr to draw into.
 */
uint32_t DSpHandleContextReserve(uint32_t r3, uint32_t r4)
{
	if (r3 != kDSpContextSentinel)
		return (uint32_t)-7001;  // kDSpInvalidContextErr

	if (dsp_context_reserved)
		return (uint32_t)-7003;  // kDSpContextBusyErr

	uint16_t width  = DSpGetCurrentWidth();
	uint16_t height = DSpGetCurrentHeight();
	uint32_t depth  = DSpGetCurrentDepth();

	// Compute bytes per pixel
	uint32_t bytesPerPixel;
	if (depth <= 8)
		bytesPerPixel = 1;
	else if (depth == 16)
		bytesPerPixel = 2;
	else
		bytesPerPixel = 4;

	// Compute row bytes — prefer screen pitch if it matches
	dsp_back_buffer_rowbytes = (uint32_t)width * bytesPerPixel;
	if (cur_mode >= 0 && VModes[cur_mode].viRowBytes == dsp_back_buffer_rowbytes) {
		// Already matches — use it (no adjustment needed)
	}

	dsp_back_buffer_size = dsp_back_buffer_rowbytes * (uint32_t)height;

	// Allocate pixel data in Mac heap
	dsp_back_buffer_addr = Mac_sysalloc(dsp_back_buffer_size);
	if (dsp_back_buffer_addr == 0) {
		DSP_LOG("DSpContext_Reserve: Mac_sysalloc(%d) failed", dsp_back_buffer_size);
		return (uint32_t)-7004;  // kDSpNotSupportedErr
	}
	Mac_memset(dsp_back_buffer_addr, 0, dsp_back_buffer_size);

	// Allocate PixMap (50 bytes), PixMapHandle (4 bytes), CGrafPort (108 bytes) in SheepMem
	dsp_back_pixmap_addr   = SheepMem::Reserve(50);
	dsp_pixmap_handle_addr = SheepMem::Reserve(4);
	dsp_back_grafport_addr = SheepMem::Reserve(108);

	// PixMapHandle: 4-byte pointer → PixMap address (double indirection)
	WriteMacInt32(dsp_pixmap_handle_addr, dsp_back_pixmap_addr);

	// ---- Write PixMap struct (50 bytes) ----
	// Offset 0: baseAddr (pointer to pixel data)
	WriteMacInt32(dsp_back_pixmap_addr + 0, dsp_back_buffer_addr);
	// Offset 4: rowBytes with 0x8000 high bit (marks as PixMap, not BitMap)
	WriteMacInt16(dsp_back_pixmap_addr + 4, (uint16_t)(dsp_back_buffer_rowbytes | 0x8000));
	// Offset 6: bounds = {top=0, left=0, bottom=height, right=width}
	WriteMacInt16(dsp_back_pixmap_addr + 6,  0);       // top
	WriteMacInt16(dsp_back_pixmap_addr + 8,  0);       // left
	WriteMacInt16(dsp_back_pixmap_addr + 10, height);   // bottom
	WriteMacInt16(dsp_back_pixmap_addr + 12, width);    // right
	// Offset 14: pmVersion = 0
	WriteMacInt16(dsp_back_pixmap_addr + 14, 0);
	// Offset 16: packType = 0
	WriteMacInt16(dsp_back_pixmap_addr + 16, 0);
	// Offset 18: packSize = 0
	WriteMacInt32(dsp_back_pixmap_addr + 18, 0);
	// Offset 22: hRes = 72 dpi (Fixed 0x00480000)
	WriteMacInt32(dsp_back_pixmap_addr + 22, 0x00480000);
	// Offset 26: vRes = 72 dpi (Fixed 0x00480000)
	WriteMacInt32(dsp_back_pixmap_addr + 26, 0x00480000);
	// Offset 30: pixelType (0=indexed, 16=direct)
	WriteMacInt16(dsp_back_pixmap_addr + 30, (depth <= 8) ? 0 : 16);
	// Offset 32: pixelSize
	WriteMacInt16(dsp_back_pixmap_addr + 32, (uint16_t)depth);
	// Offset 34: cmpCount (1 for indexed, 3 for direct)
	WriteMacInt16(dsp_back_pixmap_addr + 34, (depth <= 8) ? 1 : 3);
	// Offset 36: cmpSize
	WriteMacInt16(dsp_back_pixmap_addr + 36, (depth <= 8) ? (uint16_t)depth : (depth == 16 ? 5 : 8));
	// Offset 38: planeByte = 0
	WriteMacInt32(dsp_back_pixmap_addr + 38, 0);
	// Offset 42: pmTable = 0 (color table handle — NULL for now)
	WriteMacInt32(dsp_back_pixmap_addr + 42, 0);
	// Offset 46: pmExt = 0
	WriteMacInt32(dsp_back_pixmap_addr + 46, 0);

	// ---- Write CGrafPort struct (108 bytes) ----
	Mac_memset(dsp_back_grafport_addr, 0, 108);
	// Offset 0: device (int16) = 0
	WriteMacInt16(dsp_back_grafport_addr + 0, 0);
	// Offset 2: portPixMap (Handle = pointer to PixMapHandle)
	WriteMacInt32(dsp_back_grafport_addr + 2, dsp_pixmap_handle_addr);
	// Offset 6: portVersion = 0xC000 (marks as CGrafPort, not GrafPort)
	WriteMacInt16(dsp_back_grafport_addr + 6, 0xC000);
	// Offset 16: portRect = {top=0, left=0, bottom=height, right=width}
	WriteMacInt16(dsp_back_grafport_addr + 16, 0);       // top
	WriteMacInt16(dsp_back_grafport_addr + 18, 0);       // left
	WriteMacInt16(dsp_back_grafport_addr + 20, height);   // bottom
	WriteMacInt16(dsp_back_grafport_addr + 22, width);    // right

	dsp_context_reserved = true;

	DSP_LOG("DSpContext_Reserve: %dx%dx%d rowBytes=%d bufSize=%d buf=0x%08x pixmap=0x%08x grafport=0x%08x",
	        width, height, depth, dsp_back_buffer_rowbytes, dsp_back_buffer_size,
	        dsp_back_buffer_addr, dsp_back_pixmap_addr, dsp_back_grafport_addr);
	return kDSpNoErr;
}

/*
 *  DSpHandleContextRelease — DSP_SUB_RELEASE (opcode 24)
 *
 *  r3 = DSpContextReference (sentinel)
 *
 *  Frees pixel data and releases SheepMem allocations.
 */
uint32_t DSpHandleContextRelease(uint32_t r3)
{
	if (r3 != kDSpContextSentinel)
		return (uint32_t)-7001;  // kDSpInvalidContextErr

	if (!dsp_context_reserved) {
		DSP_LOG("DSpContext_Release: not reserved, returning noErr (idempotent)");
		return kDSpNoErr;
	}

	// Free pixel data from Mac heap
	if (dsp_back_buffer_addr != 0)
		Mac_sysfree(dsp_back_buffer_addr);

	// Release SheepMem in reverse allocation order (CGrafPort, PixMapHandle, PixMap)
	SheepMem::Release(108);
	SheepMem::Release(4);
	SheepMem::Release(50);

	DSP_LOG("DSpContext_Release: freed buf=0x%08x, released SheepMem", dsp_back_buffer_addr);

	dsp_back_buffer_addr     = 0;
	dsp_back_buffer_size     = 0;
	dsp_back_buffer_rowbytes = 0;
	dsp_back_grafport_addr   = 0;
	dsp_back_pixmap_addr     = 0;
	dsp_pixmap_handle_addr   = 0;
	dsp_context_reserved     = false;
	dsp_context_active       = false;
	dsp_blanking_color[0]    = 0;
	dsp_blanking_color[1]    = 0;
	dsp_blanking_color[2]    = 0;

	// Dispose any attached alt buffers and reset overlay/underlay state
	for (size_t i = 0; i < dsp_alt_buffers.size(); i++) {
		if (dsp_alt_buffers[i].pixel_addr != 0)
			Mac_sysfree(dsp_alt_buffers[i].pixel_addr);
		SheepMem::Release(108);
		SheepMem::Release(4);
		SheepMem::Release(50);
		DSP_LOG("DSpContext_Release: disposed alt buffer grafport=0x%08x", dsp_alt_buffers[i].grafport_addr);
	}
	dsp_alt_buffers.clear();
	dsp_underlay_grafport   = 0;
	dsp_overlay_grafport    = 0;
	dsp_underlay_pixel_addr = 0;
	dsp_overlay_pixel_addr  = 0;
	dsp_underlay_pixel_size = 0;
	dsp_overlay_pixel_size  = 0;

	// Reset gamma fade to full brightness on context release
	dsp_gamma_level = 1.0f;
	dsp_gamma_zero_color[0] = 0.0f;
	dsp_gamma_zero_color[1] = 0.0f;
	dsp_gamma_zero_color[2] = 0.0f;
	MetalCompositorSetGammaMultiplier(1.0f, dsp_gamma_zero_color);

	return kDSpNoErr;
}

/*
 *  DSpHandleContextSetState — DSP_SUB_CONTEXT_SET_STATE (opcode 10)
 *
 *  r3 = DSpContextReference (sentinel)
 *  r4 = DSpContextState: 0=inactive, 1=active, 2=paused
 */
uint32_t DSpHandleContextSetState(uint32_t r3, uint32_t r4)
{
	if (r3 != kDSpContextSentinel)
		return (uint32_t)-7001;  // kDSpInvalidContextErr

	if (!dsp_context_reserved)
		return (uint32_t)-7001;  // kDSpInvalidContextErr

	if (r4 == 1) {
		dsp_context_active = true;
		DSP_LOG("DSpContext_SetState: -> active");
	} else {
		dsp_context_active = false;
		DSP_LOG("DSpContext_SetState: -> inactive/paused (%d)", r4);
	}
	return kDSpNoErr;
}

/*
 *  DSpHandleContextGetState — DSP_SUB_CONTEXT_GET_STATE (opcode 11)
 *
 *  r3 = DSpContextReference (sentinel)
 *  r4 = pointer to DSpContextState output
 */
uint32_t DSpHandleContextGetState(uint32_t r3, uint32_t r4)
{
	if (r3 != kDSpContextSentinel)
		return (uint32_t)-7001;  // kDSpInvalidContextErr

	uint32_t state = 0;  // inactive
	if (dsp_context_reserved && dsp_context_active)
		state = 1;  // active

	if (r4 != 0)
		WriteMacInt32(r4, state);

	DSP_LOG("DSpContext_GetState: state=%d", state);
	return kDSpNoErr;
}

/*
 *  DSpHandleGetBackBuffer — DSP_SUB_GET_BACK_BUFFER (opcode 15)
 *
 *  r3 = DSpContextReference (sentinel)
 *  r4 = DSpBufferKind (ignored — we have a single back buffer)
 *  r5 = pointer to CGrafPtr output
 */
uint32_t DSpHandleGetBackBuffer(uint32_t r3, uint32_t r4, uint32_t r5)
{
	if (r3 != kDSpContextSentinel)
		return (uint32_t)-7001;  // kDSpInvalidContextErr

	if (!dsp_context_reserved)
		return (uint32_t)-7001;  // kDSpInvalidContextErr

	if (r5 != 0)
		WriteMacInt32(r5, dsp_back_grafport_addr);

	DSP_LOG("DSpContext_GetBackBuffer: grafport=0x%08x -> 0x%08x", dsp_back_grafport_addr, r5);
	return kDSpNoErr;
}

/*
 *  DSpHandleGetFrontBuffer — DSP_SUB_GET_FRONT_BUFFER (opcode 14)
 *
 *  r3 = DSpContextReference (sentinel)
 *  r4 = pointer to CGrafPtr output
 *
 *  In our software double-buffering model, front = back before swap.
 */
uint32_t DSpHandleGetFrontBuffer(uint32_t r3, uint32_t r4)
{
	if (r3 != kDSpContextSentinel)
		return (uint32_t)-7001;  // kDSpInvalidContextErr

	if (!dsp_context_reserved)
		return (uint32_t)-7001;  // kDSpInvalidContextErr

	if (r4 != 0)
		WriteMacInt32(r4, dsp_back_grafport_addr);

	DSP_LOG("DSpContext_GetFrontBuffer: grafport=0x%08x -> 0x%08x", dsp_back_grafport_addr, r4);
	return kDSpNoErr;
}


// ===========================================================================
//  SwapBuffers & Blit Handlers (S02-T02)
// ===========================================================================

/*
 *  DSpHandleSwapBuffers — DSP_SUB_SWAP_BUFFERS (opcode 16)
 *
 *  Copies back buffer to the screen framebuffer with layered compositing:
 *    1. Underlay (if attached) — full copy to screen_base
 *    2. Back buffer — overwrites screen_base (or composites over underlay)
 *    3. Overlay (if attached) — non-zero pixel overwrite on top
 *
 *  Handles pitch mismatch between back buffer and screen with row-by-row fallback.
 *
 *  r3 = DSpContextReference (sentinel)
 *  r4 = reserved (unused by most games)
 *  r5 = reserved (unused)
 */
uint32_t DSpHandleSwapBuffers(uint32_t r3, uint32_t r4, uint32_t r5)
{
	if (r3 != kDSpContextSentinel)
		return (uint32_t)-7001;  // kDSpInvalidContextErr

	if (!dsp_context_reserved || !dsp_context_active)
		return (uint32_t)-7001;  // kDSpInvalidContextErr

	if (dsp_back_buffer_addr == 0)
		return (uint32_t)-7004;  // kDSpNotSupportedErr

	uint16_t width  = DSpGetCurrentWidth();
	uint16_t height = DSpGetCurrentHeight();
	uint32_t screen_rowbytes = (cur_mode >= 0) ? VModes[cur_mode].viRowBytes : dsp_back_buffer_rowbytes;

	// Layer 1: Underlay (if attached) — copy underlay pixel data to screen_base
	if (dsp_underlay_grafport != 0 && dsp_underlay_pixel_addr != 0) {
		// Read underlay PixMap rowBytes through cached grafport
		uint32_t ul_pmh = ReadMacInt32(dsp_underlay_grafport + 2);
		uint32_t ul_pm  = ReadMacInt32(ul_pmh);
		uint16_t ul_rb  = ReadMacInt16(ul_pm + 4) & 0x7FFF;

		if (ul_rb == screen_rowbytes) {
			memcpy(Mac2HostAddr(screen_base),
			       Mac2HostAddr(dsp_underlay_pixel_addr),
			       ul_rb * (uint32_t)height);
		} else {
			uint32_t copy_rb = (ul_rb < screen_rowbytes) ? ul_rb : screen_rowbytes;
			uint8_t *dst = Mac2HostAddr(screen_base);
			uint8_t *src = Mac2HostAddr(dsp_underlay_pixel_addr);
			for (uint16_t row = 0; row < height; row++) {
				memcpy(dst + (uint32_t)row * screen_rowbytes,
				       src + (uint32_t)row * ul_rb,
				       copy_rb);
			}
		}
		DSP_LOG("DSpSwapBuffers: composited underlay 0x%08x (%d bytes)", dsp_underlay_pixel_addr, ul_rb * height);
	}

	// Layer 2: Back buffer → screen_base (overwrites underlay)
	if (screen_rowbytes == dsp_back_buffer_rowbytes) {
		// Fast path: single memcpy for entire buffer
		memcpy(Mac2HostAddr(screen_base),
		       Mac2HostAddr(dsp_back_buffer_addr),
		       dsp_back_buffer_rowbytes * (uint32_t)height);
	} else {
		// Row-by-row copy when pitches differ
		uint32_t copy_bytes = (screen_rowbytes < dsp_back_buffer_rowbytes)
		                    ? screen_rowbytes : dsp_back_buffer_rowbytes;
		uint8_t *dst = Mac2HostAddr(screen_base);
		uint8_t *src = Mac2HostAddr(dsp_back_buffer_addr);
		for (uint16_t row = 0; row < height; row++) {
			memcpy(dst + (uint32_t)row * screen_rowbytes,
			       src + (uint32_t)row * dsp_back_buffer_rowbytes,
			       copy_bytes);
		}
	}

	// Layer 3: Overlay (if attached) — non-zero pixel overwrite compositing
	if (dsp_overlay_grafport != 0 && dsp_overlay_pixel_addr != 0) {
		uint32_t ol_pmh = ReadMacInt32(dsp_overlay_grafport + 2);
		uint32_t ol_pm  = ReadMacInt32(ol_pmh);
		uint16_t ol_rb  = ReadMacInt16(ol_pm + 4) & 0x7FFF;
		uint16_t ol_depth = ReadMacInt16(ol_pm + 32);  // pixelSize

		uint32_t bytesPerPixel;
		if (ol_depth <= 8)
			bytesPerPixel = 1;
		else if (ol_depth == 16)
			bytesPerPixel = 2;
		else
			bytesPerPixel = 4;

		uint8_t *dst = Mac2HostAddr(screen_base);
		uint8_t *src = Mac2HostAddr(dsp_overlay_pixel_addr);
		uint32_t pixels_per_row = (uint32_t)width;

		for (uint16_t row = 0; row < height; row++) {
			uint8_t *src_row = src + (uint32_t)row * ol_rb;
			uint8_t *dst_row = dst + (uint32_t)row * screen_rowbytes;

			for (uint32_t px = 0; px < pixels_per_row; px++) {
				uint32_t offset = px * bytesPerPixel;
				// Check if pixel is non-zero
				bool non_zero = false;
				for (uint32_t b = 0; b < bytesPerPixel; b++) {
					if (src_row[offset + b] != 0) {
						non_zero = true;
						break;
					}
				}
				if (non_zero) {
					memcpy(dst_row + offset, src_row + offset, bytesPerPixel);
				}
			}
		}
		DSP_LOG("DSpSwapBuffers: composited overlay 0x%08x (non-zero overwrite)", dsp_overlay_pixel_addr);
	}

	DSP_LOG("DSpSwapBuffers: %dx%d screenRB=%d backRB=%d screen_base=0x%08x underlay=%s overlay=%s",
	        width, height, screen_rowbytes, dsp_back_buffer_rowbytes, screen_base,
	        (dsp_underlay_grafport != 0) ? "yes" : "no",
	        (dsp_overlay_grafport != 0) ? "yes" : "no");
	return kDSpNoErr;
}

/*
 *  DSpBlitBetweenBuffers — static helper for all blit variants
 *
 *  Reads PixMap baseAddr from each CGrafPort's portPixMap chain:
 *    CGrafPort offset 2 → PixMapHandle → PixMap → offset 0 baseAddr
 *  Reads rowBytes from each PixMap (offset 4, mask off 0x8000).
 *  Copies pixels row-by-row from source rect to dest rect.
 */
static uint32_t DSpBlitBetweenBuffers(uint32_t src_grafport, uint32_t src_rect_addr,
                                      uint32_t dst_grafport, uint32_t dst_rect_addr)
{
	// Read source PixMap through CGrafPort → Handle → PixMap chain
	uint32_t src_pmh   = ReadMacInt32(src_grafport + 2);   // portPixMap (PixMapHandle)
	uint32_t src_pm    = ReadMacInt32(src_pmh);              // dereference handle → PixMap*
	uint32_t src_base  = ReadMacInt32(src_pm + 0);           // baseAddr
	uint16_t src_rb    = ReadMacInt16(src_pm + 4) & 0x7FFF;  // rowBytes (mask off 0x8000)
	uint16_t src_depth = ReadMacInt16(src_pm + 32);           // pixelSize

	// Read dest PixMap through same chain
	uint32_t dst_pmh   = ReadMacInt32(dst_grafport + 2);
	uint32_t dst_pm    = ReadMacInt32(dst_pmh);
	uint32_t dst_base  = ReadMacInt32(dst_pm + 0);
	uint16_t dst_rb    = ReadMacInt16(dst_pm + 4) & 0x7FFF;

	// Compute bytes per pixel from source depth
	uint32_t bytesPerPixel;
	if (src_depth <= 8)
		bytesPerPixel = 1;
	else if (src_depth == 16)
		bytesPerPixel = 2;
	else
		bytesPerPixel = 4;

	// Read source rect (int16: top, left, bottom, right)
	int16_t src_top    = (int16_t)ReadMacInt16(src_rect_addr + 0);
	int16_t src_left   = (int16_t)ReadMacInt16(src_rect_addr + 2);
	int16_t src_bottom = (int16_t)ReadMacInt16(src_rect_addr + 4);
	int16_t src_right  = (int16_t)ReadMacInt16(src_rect_addr + 6);

	// Read dest rect
	int16_t dst_top    = (int16_t)ReadMacInt16(dst_rect_addr + 0);
	int16_t dst_left   = (int16_t)ReadMacInt16(dst_rect_addr + 2);
	int16_t dst_bottom = (int16_t)ReadMacInt16(dst_rect_addr + 4);
	int16_t dst_right  = (int16_t)ReadMacInt16(dst_rect_addr + 6);

	// Compute copy dimensions
	int src_w = src_right - src_left;
	int dst_w = dst_right - dst_left;
	int src_h = src_bottom - src_top;
	int dst_h = dst_bottom - dst_top;

	int copy_w = (src_w < dst_w) ? src_w : dst_w;
	int copy_h = (src_h < dst_h) ? src_h : dst_h;
	if (copy_w <= 0 || copy_h <= 0)
		return kDSpNoErr;

	uint32_t copy_bytes = (uint32_t)copy_w * bytesPerPixel;

	uint8_t *src_host = Mac2HostAddr(src_base) + (uint32_t)src_top * src_rb + (uint32_t)src_left * bytesPerPixel;
	uint8_t *dst_host = Mac2HostAddr(dst_base) + (uint32_t)dst_top * dst_rb + (uint32_t)dst_left * bytesPerPixel;

	for (int row = 0; row < copy_h; row++) {
		memcpy(dst_host + (uint32_t)row * dst_rb,
		       src_host + (uint32_t)row * src_rb,
		       copy_bytes);
	}

	DSP_LOG("DSpBlitBetweenBuffers: %dx%d depth=%d src=0x%08x dst=0x%08x",
	        copy_w, copy_h, src_depth, src_base, dst_base);
	return kDSpNoErr;
}

/*
 *  DSpHandleBlit — DSP_SUB_BLIT (opcode 49)
 *
 *  r3 = pointer to DSpBlitInfo struct
 *
 *  DSpBlitInfo layout:
 *    offset 0  = completionFlag (bool32)
 *    offset 4  = filler
 *    offset 8  = src CGrafPtr
 *    offset 12 = srcRect (8 bytes: top, left, bottom, right)
 *    offset 20 = dst CGrafPtr
 *    offset 24 = dstRect (8 bytes)
 */
uint32_t DSpHandleBlit(uint32_t r3)
{
	if (r3 == 0)
		return (uint32_t)-7002;  // kDSpInvalidAttributeErr

	uint32_t src_gp = ReadMacInt32(r3 + 8);
	uint32_t dst_gp = ReadMacInt32(r3 + 20);

	DSP_LOG("DSpBlit: info=0x%08x src=0x%08x dst=0x%08x", r3, src_gp, dst_gp);
	return DSpBlitBetweenBuffers(src_gp, r3 + 12, dst_gp, r3 + 24);
}

/*
 *  DSpHandleBlitRect — DSP_SUB_BLIT_RECT (opcode 50)
 *
 *  r3 = src CGrafPtr, r4 = src Rect ptr, r5 = dst CGrafPtr, r6 = dst Rect ptr
 */
uint32_t DSpHandleBlitRect(uint32_t r3, uint32_t r4, uint32_t r5, uint32_t r6)
{
	DSP_LOG("DSpBlitRect: src=0x%08x dst=0x%08x", r3, r5);
	return DSpBlitBetweenBuffers(r3, r4, r5, r6);
}

/*
 *  DSpHandleBlitFastest — DSP_SUB_BLIT_FASTEST (opcode 53)
 *
 *  r3 = src CGrafPtr, r4 = dst CGrafPtr, r5 = reserved
 *  Copies entire buffer (full PixMap bounds) using the fastest method.
 */
uint32_t DSpHandleBlitFastest(uint32_t r3, uint32_t r4, uint32_t r5)
{
	// Read source PixMap
	uint32_t src_pmh  = ReadMacInt32(r3 + 2);
	uint32_t src_pm   = ReadMacInt32(src_pmh);
	uint32_t src_base = ReadMacInt32(src_pm + 0);
	uint16_t src_rb   = ReadMacInt16(src_pm + 4) & 0x7FFF;
	// bounds: top(6), left(8), bottom(10), right(12)
	uint16_t src_h    = ReadMacInt16(src_pm + 10) - ReadMacInt16(src_pm + 6);

	// Read dest PixMap
	uint32_t dst_pmh  = ReadMacInt32(r4 + 2);
	uint32_t dst_pm   = ReadMacInt32(dst_pmh);
	uint32_t dst_base = ReadMacInt32(dst_pm + 0);
	uint16_t dst_rb   = ReadMacInt16(dst_pm + 4) & 0x7FFF;
	uint16_t dst_h    = ReadMacInt16(dst_pm + 10) - ReadMacInt16(dst_pm + 6);

	uint16_t copy_h = (src_h < dst_h) ? src_h : dst_h;
	uint32_t copy_rb = (src_rb < dst_rb) ? src_rb : dst_rb;

	if (src_rb == dst_rb) {
		// Whole-buffer copy in one shot
		memcpy(Mac2HostAddr(dst_base), Mac2HostAddr(src_base), (uint32_t)copy_rb * copy_h);
	} else {
		// Row-by-row fallback
		uint8_t *src_host = Mac2HostAddr(src_base);
		uint8_t *dst_host = Mac2HostAddr(dst_base);
		for (uint16_t row = 0; row < copy_h; row++) {
			memcpy(dst_host + (uint32_t)row * dst_rb,
			       src_host + (uint32_t)row * src_rb,
			       copy_rb);
		}
	}

	DSP_LOG("DSpBlitFastest: %dx rb src=0x%08x dst=0x%08x", copy_h, src_base, dst_base);
	return kDSpNoErr;
}

/*
 *  DSpHandleBlitPixel — DSP_SUB_BLIT_PIXEL (opcode 51)
 *
 *  r3 = src CGrafPtr, r4 = src Rect ptr, r5 = dst CGrafPtr, r6 = dst Rect ptr
 *  Identical to BlitRect — per-pixel transfer mode not meaningful in our case.
 */
uint32_t DSpHandleBlitPixel(uint32_t r3, uint32_t r4, uint32_t r5, uint32_t r6)
{
	DSP_LOG("DSpBlitPixel: src=0x%08x dst=0x%08x", r3, r5);
	return DSpBlitBetweenBuffers(r3, r4, r5, r6);
}

/*
 *  DSpHandleBlitRegion — DSP_SUB_BLIT_REGION (opcode 52)
 *
 *  r3 = src CGrafPtr, r4 = src Rect ptr, r5 = dst CGrafPtr, r6 = dst Rect/Region ptr
 *  Treats region as rect — we don't parse RgnHandle structures.
 */
uint32_t DSpHandleBlitRegion(uint32_t r3, uint32_t r4, uint32_t r5, uint32_t r6)
{
	DSP_LOG("DSpBlitRegion: src=0x%08x dst=0x%08x (region as rect)", r3, r5);
	return DSpBlitBetweenBuffers(r3, r4, r5, r6);
}


// ===========================================================================
//  CLUT, Blanking Color, Coordinate Translation Handlers (S02-T03)
// ===========================================================================

/*
 *  DSpHandleSetCLUTEntries — DSP_SUB_SET_CLUT_ENTRIES (opcode 38)
 *
 *  r3 = DSpContextReference (sentinel)
 *  r4 = pointer to ColorSpec array in Mac memory
 *  r5 = startIndex (uint16, or -1 for indexed mode)
 *  r6 = count (uint16, number of entries)
 *
 *  Each ColorSpec is 8 bytes: { value: int16, rgb: { red: uint16, green: uint16, blue: uint16 } }
 *  If startIndex != -1, the actual palette index is startIndex + i.
 *  Otherwise, the value field in each ColorSpec is the palette index.
 */
uint32_t DSpHandleSetCLUTEntries(uint32_t r3, uint32_t r4, uint32_t r5, uint32_t r6)
{
	if (r3 != kDSpContextSentinel)
		return (uint32_t)-7001;  // kDSpInvalidContextErr

	if (!dsp_context_reserved)
		return (uint32_t)-7001;  // kDSpInvalidContextErr

	int16_t startIndex = (int16_t)r5;
	uint16_t count = (uint16_t)r6;

	for (uint16_t i = 0; i < count; i++) {
		uint32_t entry_addr = r4 + (uint32_t)i * 8;

		int16_t idx;
		if (startIndex != -1) {
			idx = startIndex + (int16_t)i;
		} else {
			idx = (int16_t)ReadMacInt16(entry_addr);
		}

		if (idx < 0 || idx > 255)
			continue;

		uint16_t red   = ReadMacInt16(entry_addr + 2);
		uint16_t green = ReadMacInt16(entry_addr + 4);
		uint16_t blue  = ReadMacInt16(entry_addr + 6);

		mac_pal[idx].red   = red >> 8;
		mac_pal[idx].green = green >> 8;
		mac_pal[idx].blue  = blue >> 8;
	}

	// Push updated palette to Metal compositor
	MetalCompositorUpdatePalette((const uint8_t *)mac_pal, 256);

	DSP_LOG("DSpContext_SetCLUTEntries: updated %d entries (startIndex=%d)", count, startIndex);
	return kDSpNoErr;
}

/*
 *  DSpHandleSetBlankingColor — DSP_SUB_SET_BLANKING_COLOR (opcode 27)
 *
 *  r3 = DSpContextReference (sentinel)
 *  r4 = pointer to RGBColor (6 bytes: red uint16, green uint16, blue uint16)
 */
uint32_t DSpHandleSetBlankingColor(uint32_t r3, uint32_t r4)
{
	if (r3 != kDSpContextSentinel)
		return (uint32_t)-7001;  // kDSpInvalidContextErr

	dsp_blanking_color[0] = ReadMacInt16(r4 + 0);  // red
	dsp_blanking_color[1] = ReadMacInt16(r4 + 2);  // green
	dsp_blanking_color[2] = ReadMacInt16(r4 + 4);  // blue

	DSP_LOG("DSpContext_SetBlankingColor: r=%d g=%d b=%d",
	        dsp_blanking_color[0], dsp_blanking_color[1], dsp_blanking_color[2]);
	return kDSpNoErr;
}

/*
 *  DSpHandleGetBlankingColor — DSP_SUB_GET_BLANKING_COLOR (opcode 28)
 *
 *  r3 = DSpContextReference (sentinel)
 *  r4 = pointer to RGBColor output (6 bytes)
 */
uint32_t DSpHandleGetBlankingColor(uint32_t r3, uint32_t r4)
{
	if (r3 != kDSpContextSentinel)
		return (uint32_t)-7001;  // kDSpInvalidContextErr

	WriteMacInt16(r4 + 0, dsp_blanking_color[0]);  // red
	WriteMacInt16(r4 + 2, dsp_blanking_color[1]);  // green
	WriteMacInt16(r4 + 4, dsp_blanking_color[2]);  // blue

	DSP_LOG("DSpContext_GetBlankingColor: r=%d g=%d b=%d",
	        dsp_blanking_color[0], dsp_blanking_color[1], dsp_blanking_color[2]);
	return kDSpNoErr;
}

/*
 *  DSpHandleGlobalToLocal — DSP_SUB_CONTEXT_GLOBAL_TO_LOCAL (opcode 12)
 *
 *  r3 = DSpContextReference (sentinel)
 *  r4 = pointer to Point (4 bytes: v int16, h int16)
 *
 *  Identity transform — single display at origin (0,0).
 */
uint32_t DSpHandleGlobalToLocal(uint32_t r3, uint32_t r4)
{
	if (r3 != kDSpContextSentinel)
		return (uint32_t)-7001;  // kDSpInvalidContextErr

	// Identity: read and write back unchanged
	int16_t v = (int16_t)ReadMacInt16(r4 + 0);
	int16_t h = (int16_t)ReadMacInt16(r4 + 2);
	WriteMacInt16(r4 + 0, (uint16_t)v);
	WriteMacInt16(r4 + 2, (uint16_t)h);

	DSP_LOG("DSpContext_GlobalToLocal: (%d,%d) -> (%d,%d)", v, h, v, h);
	return kDSpNoErr;
}

/*
 *  DSpHandleLocalToGlobal — DSP_SUB_CONTEXT_LOCAL_TO_GLOBAL (opcode 13)
 *
 *  r3 = DSpContextReference (sentinel)
 *  r4 = pointer to Point (4 bytes: v int16, h int16)
 *
 *  Identity transform — single display at origin (0,0).
 */
uint32_t DSpHandleLocalToGlobal(uint32_t r3, uint32_t r4)
{
	if (r3 != kDSpContextSentinel)
		return (uint32_t)-7001;  // kDSpInvalidContextErr

	// Identity: read and write back unchanged
	int16_t v = (int16_t)ReadMacInt16(r4 + 0);
	int16_t h = (int16_t)ReadMacInt16(r4 + 2);
	WriteMacInt16(r4 + 0, (uint16_t)v);
	WriteMacInt16(r4 + 2, (uint16_t)h);

	DSP_LOG("DSpContext_LocalToGlobal: (%d,%d) -> (%d,%d)", v, h, v, h);
	return kDSpNoErr;
}


// ===========================================================================
//  Gamma Fade Handlers (S03)
// ===========================================================================

/*
 *  DSpHandleFadeGamma — DSP_SUB_FADE_GAMMA (opcode 25)
 *
 *  r3 = DSpContextReference (sentinel, NULL, or 0 for kDSpEveryContext)
 *  r4 = fade percent (0=fully faded, 100=fully visible)
 *  r5 = pointer to RGBColor (3x uint16 big-endian) — zero-intensity color
 *
 *  Sets the gamma level and optional zero-intensity color, then pushes
 *  the multiplier to the Metal compositor for real-time display fading.
 */
uint32_t DSpHandleFadeGamma(uint32_t r3, uint32_t r4, uint32_t r5)
{
	// Accept NULL/0 and sentinel (kDSpEveryContext) — single-display emulator
	dsp_gamma_level = (float)r4 / 100.0f;
	if (dsp_gamma_level < 0.0f) dsp_gamma_level = 0.0f;
	if (dsp_gamma_level > 1.0f) dsp_gamma_level = 1.0f;

	// Read zero-intensity color if pointer is non-null
	if (r5 != 0) {
		dsp_gamma_zero_color[0] = (float)ReadMacInt16(r5 + 0) / 65535.0f;  // red
		dsp_gamma_zero_color[1] = (float)ReadMacInt16(r5 + 2) / 65535.0f;  // green
		dsp_gamma_zero_color[2] = (float)ReadMacInt16(r5 + 4) / 65535.0f;  // blue
	}

	MetalCompositorSetGammaMultiplier(dsp_gamma_level, dsp_gamma_zero_color);

	DSP_LOG("DSpContext_FadeGamma: context=0x%08x percent=%d gamma=%.3f zero_color=(%.3f,%.3f,%.3f)",
	        r3, r4, dsp_gamma_level,
	        dsp_gamma_zero_color[0], dsp_gamma_zero_color[1], dsp_gamma_zero_color[2]);
	return kDSpNoErr;
}

/*
 *  DSpHandleFadeGammaOut — DSP_SUB_FADE_GAMMA_OUT (opcode 26)
 *
 *  r3 = DSpContextReference (sentinel, NULL, or 0 for kDSpEveryContext)
 *  r4 = reserved (unused)
 *
 *  Fades the display to full blackout (gamma = 0.0).
 */
uint32_t DSpHandleFadeGammaOut(uint32_t r3, uint32_t r4)
{
	dsp_gamma_level = 0.0f;
	MetalCompositorSetGammaMultiplier(0.0f, dsp_gamma_zero_color);

	DSP_LOG("DSpContext_FadeGammaOut: context=0x%08x -> gamma=0.0 (blackout)", r3);
	return kDSpNoErr;
}

/*
 *  DSpHandleFadeGammaIn — DSP_SUB_FADE_GAMMA_IN (opcode 54)
 *
 *  r3 = DSpContextReference (sentinel, NULL, or 0 for kDSpEveryContext)
 *  r4 = reserved (unused)
 *
 *  Restores the display to full brightness (gamma = 1.0).
 */
uint32_t DSpHandleFadeGammaIn(uint32_t r3, uint32_t r4)
{
	dsp_gamma_level = 1.0f;
	MetalCompositorSetGammaMultiplier(1.0f, dsp_gamma_zero_color);

	DSP_LOG("DSpContext_FadeGammaIn: context=0x%08x -> gamma=1.0 (restored)", r3);
	return kDSpNoErr;
}


// ===========================================================================
//  Alt Buffer Handlers (S03-T02)
// ===========================================================================

/*
 *  DSpHandleAltBufferNew — DSP_SUB_ALT_BUFFER_NEW (opcode 57)
 *
 *  r3 = pointer to DSpAltBufferReference output (receives CGrafPtr Mac addr)
 *  r4 = pointer to DSpAltBufferAttributes (desired — ignored, we match current display)
 *  r5 = reserved
 *
 *  Allocates a CGrafPtr buffer identical to the back buffer (pixel data via
 *  Mac_sysalloc, CGrafPort/PixMap/PixMapHandle via SheepMem). Pixel data is
 *  cleared to zero. The CGrafPort Mac address is written to the output at r3.
 */
uint32_t DSpHandleAltBufferNew(uint32_t r3, uint32_t r4, uint32_t r5)
{
	if (r3 == 0)
		return (uint32_t)-7002;  // kDSpInvalidAttributeErr

	uint16_t width  = DSpGetCurrentWidth();
	uint16_t height = DSpGetCurrentHeight();
	uint32_t depth  = DSpGetCurrentDepth();

	// Compute bytes per pixel (same logic as ContextReserve)
	uint32_t bytesPerPixel;
	if (depth <= 8)
		bytesPerPixel = 1;
	else if (depth == 16)
		bytesPerPixel = 2;
	else
		bytesPerPixel = 4;

	uint32_t rowbytes = (uint32_t)width * bytesPerPixel;
	uint32_t buf_size = rowbytes * (uint32_t)height;

	// Allocate pixel data in Mac heap
	uint32_t pixel_addr = Mac_sysalloc(buf_size);
	if (pixel_addr == 0) {
		DSP_LOG("DSpAltBuffer_New: Mac_sysalloc(%d) failed", buf_size);
		return (uint32_t)-7004;  // kDSpNotSupportedErr
	}
	Mac_memset(pixel_addr, 0, buf_size);

	// Allocate PixMap (50 bytes), PixMapHandle (4 bytes), CGrafPort (108 bytes) in SheepMem
	uint32_t pixmap_addr   = SheepMem::Reserve(50);
	uint32_t pmh_addr      = SheepMem::Reserve(4);
	uint32_t grafport_addr = SheepMem::Reserve(108);

	// PixMapHandle: 4-byte pointer → PixMap address (double indirection)
	WriteMacInt32(pmh_addr, pixmap_addr);

	// ---- Write PixMap struct (50 bytes) ----
	WriteMacInt32(pixmap_addr + 0, pixel_addr);                              // baseAddr
	WriteMacInt16(pixmap_addr + 4, (uint16_t)(rowbytes | 0x8000));           // rowBytes + 0x8000 flag
	WriteMacInt16(pixmap_addr + 6,  0);                                      // bounds.top
	WriteMacInt16(pixmap_addr + 8,  0);                                      // bounds.left
	WriteMacInt16(pixmap_addr + 10, height);                                 // bounds.bottom
	WriteMacInt16(pixmap_addr + 12, width);                                  // bounds.right
	WriteMacInt16(pixmap_addr + 14, 0);                                      // pmVersion
	WriteMacInt16(pixmap_addr + 16, 0);                                      // packType
	WriteMacInt32(pixmap_addr + 18, 0);                                      // packSize
	WriteMacInt32(pixmap_addr + 22, 0x00480000);                             // hRes = 72 dpi
	WriteMacInt32(pixmap_addr + 26, 0x00480000);                             // vRes = 72 dpi
	WriteMacInt16(pixmap_addr + 30, (depth <= 8) ? 0 : 16);                 // pixelType
	WriteMacInt16(pixmap_addr + 32, (uint16_t)depth);                        // pixelSize
	WriteMacInt16(pixmap_addr + 34, (depth <= 8) ? 1 : 3);                  // cmpCount
	WriteMacInt16(pixmap_addr + 36, (depth <= 8) ? (uint16_t)depth : (depth == 16 ? 5 : 8)); // cmpSize
	WriteMacInt32(pixmap_addr + 38, 0);                                      // planeByte
	WriteMacInt32(pixmap_addr + 42, 0);                                      // pmTable = NULL
	WriteMacInt32(pixmap_addr + 46, 0);                                      // pmExt

	// ---- Write CGrafPort struct (108 bytes) ----
	Mac_memset(grafport_addr, 0, 108);
	WriteMacInt16(grafport_addr + 0, 0);                                     // device
	WriteMacInt32(grafport_addr + 2, pmh_addr);                              // portPixMap = handle addr
	WriteMacInt16(grafport_addr + 6, 0xC000);                                // portVersion = CGrafPort
	WriteMacInt16(grafport_addr + 16, 0);                                    // portRect.top
	WriteMacInt16(grafport_addr + 18, 0);                                    // portRect.left
	WriteMacInt16(grafport_addr + 20, height);                               // portRect.bottom
	WriteMacInt16(grafport_addr + 22, width);                                // portRect.right

	// Write the CGrafPort Mac address to the output pointer
	WriteMacInt32(r3, grafport_addr);

	// Track for disposal
	DSpAltBufferRecord rec;
	rec.grafport_addr     = grafport_addr;
	rec.pixmap_addr       = pixmap_addr;
	rec.pixmap_handle_addr = pmh_addr;
	rec.pixel_addr        = pixel_addr;
	rec.pixel_size        = buf_size;
	dsp_alt_buffers.push_back(rec);

	DSP_LOG("DSpAltBuffer_New: %dx%dx%d rowBytes=%d bufSize=%d pixel=0x%08x grafport=0x%08x -> output=0x%08x",
	        width, height, depth, rowbytes, buf_size, pixel_addr, grafport_addr, r3);
	return kDSpNoErr;
}

/*
 *  DSpHandleAltBufferDispose — DSP_SUB_ALT_BUFFER_DISPOSE (opcode 58)
 *
 *  r3 = DSpAltBufferReference (CGrafPort Mac address)
 *
 *  Frees pixel data and SheepMem allocations. If the buffer is currently
 *  attached as underlay or overlay, detaches it first.
 */
uint32_t DSpHandleAltBufferDispose(uint32_t r3)
{
	if (r3 == 0)
		return (uint32_t)-7002;  // kDSpInvalidAttributeErr

	// Detach if currently attached
	if (r3 == dsp_underlay_grafport) {
		dsp_underlay_grafport = 0;
		dsp_underlay_pixel_addr = 0;
		dsp_underlay_pixel_size = 0;
		DSP_LOG("DSpAltBuffer_Dispose: detached underlay 0x%08x", r3);
	}
	if (r3 == dsp_overlay_grafport) {
		dsp_overlay_grafport = 0;
		dsp_overlay_pixel_addr = 0;
		dsp_overlay_pixel_size = 0;
		DSP_LOG("DSpAltBuffer_Dispose: detached overlay 0x%08x", r3);
	}

	// Find the tracking record and free allocations
	for (size_t i = 0; i < dsp_alt_buffers.size(); i++) {
		if (dsp_alt_buffers[i].grafport_addr == r3) {
			// Free pixel data from Mac heap
			if (dsp_alt_buffers[i].pixel_addr != 0)
				Mac_sysfree(dsp_alt_buffers[i].pixel_addr);

			// Release SheepMem in reverse allocation order (CGrafPort, PixMapHandle, PixMap)
			SheepMem::Release(108);
			SheepMem::Release(4);
			SheepMem::Release(50);

			DSP_LOG("DSpAltBuffer_Dispose: freed grafport=0x%08x pixel=0x%08x",
			        r3, dsp_alt_buffers[i].pixel_addr);

			dsp_alt_buffers.erase(dsp_alt_buffers.begin() + i);
			return kDSpNoErr;
		}
	}

	DSP_LOG("DSpAltBuffer_Dispose: unknown buffer 0x%08x (not tracked)", r3);
	return kDSpNoErr;  // Gracefully handle unknown buffers
}

/*
 *  DSpHandleAltBufferInvalRect — DSP_SUB_ALT_BUFFER_INVAL_RECT (opcode 59)
 *
 *  r3 = DSpAltBufferReference
 *  r4 = pointer to Rect (invalidation rect — no-op for our implementation)
 *
 *  No-op stub. We re-read the full alt buffer from pixel data each SwapBuffers,
 *  so invalidation tracking is unnecessary.
 */
uint32_t DSpHandleAltBufferInvalRect(uint32_t r3, uint32_t r4)
{
	DSP_LOG("DSpAltBuffer_InvalRect: buffer=0x%08x rect=0x%08x (no-op)", r3, r4);
	return kDSpNoErr;
}

/*
 *  DSpHandleSetUnderlayAltBuffer — DSP_SUB_SET_UNDERLAY_ALT_BUFFER (opcode 55)
 *
 *  r3 = DSpContextReference (sentinel)
 *  r4 = DSpAltBufferReference (CGrafPtr, or 0/NULL to detach)
 *
 *  Attaches (or detaches) an alt buffer as the context's underlay.
 *  Caches the pixel data address for efficient compositing in SwapBuffers.
 */
uint32_t DSpHandleSetUnderlayAltBuffer(uint32_t r3, uint32_t r4)
{
	dsp_underlay_grafport = r4;

	if (r4 != 0) {
		// Cache pixel data address by traversing CGrafPort → PixMapHandle → PixMap → baseAddr
		uint32_t pmh   = ReadMacInt32(r4 + 2);    // portPixMap (PixMapHandle)
		uint32_t pm    = ReadMacInt32(pmh);         // dereference → PixMap*
		dsp_underlay_pixel_addr = ReadMacInt32(pm + 0);  // baseAddr
		uint16_t rb    = ReadMacInt16(pm + 4) & 0x7FFF;
		uint16_t h     = ReadMacInt16(pm + 10) - ReadMacInt16(pm + 6);
		dsp_underlay_pixel_size = (uint32_t)rb * h;
	} else {
		dsp_underlay_pixel_addr = 0;
		dsp_underlay_pixel_size = 0;
	}

	DSP_LOG("DSpContext_SetUnderlayAltBuffer: context=0x%08x buffer=0x%08x pixel=0x%08x size=%d",
	        r3, r4, dsp_underlay_pixel_addr, dsp_underlay_pixel_size);
	return kDSpNoErr;
}

/*
 *  DSpHandleGetUnderlayAltBuffer — DSP_SUB_GET_UNDERLAY_ALT_BUFFER (opcode 43)
 *
 *  r3 = DSpContextReference (sentinel)
 *  r4 = pointer to DSpAltBufferReference output
 *
 *  Writes the currently attached underlay alt buffer CGrafPtr to the output.
 */
uint32_t DSpHandleGetUnderlayAltBuffer(uint32_t r3, uint32_t r4)
{
	if (r4 != 0)
		WriteMacInt32(r4, dsp_underlay_grafport);

	DSP_LOG("DSpContext_GetUnderlayAltBuffer: context=0x%08x -> buffer=0x%08x", r3, dsp_underlay_grafport);
	return kDSpNoErr;
}

/*
 *  DSpHandleSetOverlayAltBuffer — DSP_SUB_SET_OVERLAY_ALT_BUFFER (opcode 56)
 *
 *  r3 = DSpContextReference (sentinel)
 *  r4 = DSpAltBufferReference (CGrafPtr, or 0/NULL to detach)
 */
uint32_t DSpHandleSetOverlayAltBuffer(uint32_t r3, uint32_t r4)
{
	dsp_overlay_grafport = r4;

	if (r4 != 0) {
		uint32_t pmh   = ReadMacInt32(r4 + 2);
		uint32_t pm    = ReadMacInt32(pmh);
		dsp_overlay_pixel_addr = ReadMacInt32(pm + 0);
		uint16_t rb    = ReadMacInt16(pm + 4) & 0x7FFF;
		uint16_t h     = ReadMacInt16(pm + 10) - ReadMacInt16(pm + 6);
		dsp_overlay_pixel_size = (uint32_t)rb * h;
	} else {
		dsp_overlay_pixel_addr = 0;
		dsp_overlay_pixel_size = 0;
	}

	DSP_LOG("DSpContext_SetOverlayAltBuffer: context=0x%08x buffer=0x%08x pixel=0x%08x size=%d",
	        r3, r4, dsp_overlay_pixel_addr, dsp_overlay_pixel_size);
	return kDSpNoErr;
}

/*
 *  DSpHandleGetOverlayAltBuffer — DSP_SUB_GET_OVERLAY_ALT_BUFFER (opcode 44)
 *
 *  r3 = DSpContextReference (sentinel)
 *  r4 = pointer to DSpAltBufferReference output
 */
uint32_t DSpHandleGetOverlayAltBuffer(uint32_t r3, uint32_t r4)
{
	if (r4 != 0)
		WriteMacInt32(r4, dsp_overlay_grafport);

	DSP_LOG("DSpContext_GetOverlayAltBuffer: context=0x%08x -> buffer=0x%08x", r3, dsp_overlay_grafport);
	return kDSpNoErr;
}


// ===========================================================================
//  FindLibSymbol Hook Installation
// ===========================================================================

/*
 *  DSpInstallHooks — Hook DrawSprocketLib function lookups via FindLibSymbol
 *
 *  Locates DrawSprocketLib exports via FindLibSymbol and patches each
 *  function's TVECT to redirect to our allocated dsp_method_tvects[].
 *
 *  Follows the GL two-phase pattern:
 *   Phase 1: All FindLibSymbol lookups (cache results)
 *   Phase 2: Patch TVECTs (avoids re-entrancy)
 *
 *  Library names for Classic Mac OS DrawSprocket:
 *   - "DrawSprocketLib" (primary)
 *   - "DrawSprktLib" (alternate short name used by some versions)
 *   - "DrawSprocket Lib" (alternate with space, seen in some installers)
 */
void DSpInstallHooks(void)
{
	if (dsp_hooks_installed) {
		DSP_LOG("DSpInstallHooks: already installed");
		return;
	}
	if (dsp_hooks_attempts >= DSP_HOOKS_MAX_ATTEMPTS) {
		return;
	}
	if (dsp_hooks_in_progress) {
		DSP_LOG("DSpInstallHooks: skipped (re-entrant call)");
		return;
	}
	dsp_hooks_in_progress = true;

	DSP_LOG("DSpInstallHooks: installing FindLibSymbol hooks for DrawSprocketLib");

	// ---- Phase 1: FindLibSymbol lookups (cache all TVECTs) ----
	//
	// Library name format: Pascal string (first byte = length).
	// "DrawSprocketLib"  = 15 chars -> \017
	// "DrawSprktLib"     = 12 chars -> \014
	// "DrawSprocket Lib" = 16 chars -> \020
	static const char *lib_names[] = {
		"\017DrawSprocketLib",
		"\014DrawSprktLib",
		"\020DrawSprocket Lib"
	};
	static const int num_libs = sizeof(lib_names) / sizeof(lib_names[0]);

	// DrawSprocket function symbol table — maps each exported function
	// to its sub-opcode. Pascal string format (first byte = length).
	struct DSpSymbolEntry {
		const char *pascal_sym;
		int sub_opcode;
		const char *name;  // For logging
	};

	DSpSymbolEntry dsp_symbols[] = {
		/* Startup / shutdown / version */
		{ "\012DSpStartup",                      DSP_SUB_STARTUP,                       "DSpStartup" },
		{ "\013DSpShutdown",                     DSP_SUB_SHUTDOWN,                      "DSpShutdown" },
		{ "\015DSpGetVersion",                   DSP_SUB_GET_VERSION,                   "DSpGetVersion" },
		/* Display management */
		{ "\024DSpGetFirstDisplayID",            DSP_SUB_GET_FIRST_DISPLAY_ID,          "DSpGetFirstDisplayID" },
		{ "\023DSpGetNextDisplayID",             DSP_SUB_GET_NEXT_DISPLAY_ID,           "DSpGetNextDisplayID" },
		{ "\026DSpGetCurrentDisplayID",          DSP_SUB_GET_CURRENT_DISPLAY_ID,        "DSpGetCurrentDisplayID" },
		{ "\027DSpGetDisplayAttributes",         DSP_SUB_GET_DISPLAY_ATTRIBUTES,        "DSpGetDisplayAttributes" },
		{ "\027DSpSetDisplayAttributes",         DSP_SUB_SET_DISPLAY_ATTRIBUTES,        "DSpSetDisplayAttributes" },
		/* Context lifecycle */
		{ "\030DSpContext_GetAttributes",        DSP_SUB_CONTEXT_GET_ATTRIBUTES,        "DSpContext_GetAttributes" },
		{ "\027DSpContext_GetDisplayID",         DSP_SUB_CONTEXT_GET_DISPLAY_ID,        "DSpContext_GetDisplayID" },
		{ "\023DSpContext_SetState",             DSP_SUB_CONTEXT_SET_STATE,             "DSpContext_SetState" },
		{ "\023DSpContext_GetState",             DSP_SUB_CONTEXT_GET_STATE,             "DSpContext_GetState" },
		{ "\030DSpContext_GlobalToLocal",        DSP_SUB_CONTEXT_GLOBAL_TO_LOCAL,       "DSpContext_GlobalToLocal" },
		{ "\030DSpContext_LocalToGlobal",        DSP_SUB_CONTEXT_LOCAL_TO_GLOBAL,       "DSpContext_LocalToGlobal" },
		/* Alternate buffers */
		{ "\031DSpContext_GetFrontBuffer",       DSP_SUB_GET_FRONT_BUFFER,              "DSpContext_GetFrontBuffer" },
		{ "\030DSpContext_GetBackBuffer",        DSP_SUB_GET_BACK_BUFFER,               "DSpContext_GetBackBuffer" },
		{ "\026DSpContext_SwapBuffers",          DSP_SUB_SWAP_BUFFERS,                  "DSpContext_SwapBuffers" },
		{ "\035DSpFindBestContextOnDisplayID",   DSP_SUB_FIND_BEST_CONTEXT_ON_DISPLAY_ID, "DSpFindBestContextOnDisplayID" },
		/* Context enumeration */
		{ "\022DSpFindBestContext",              DSP_SUB_FIND_BEST_CONTEXT,             "DSpFindBestContext" },
		{ "\032DSpContext_CountAttributes",      DSP_SUB_CONTEXT_COUNT_ATTRIBUTES,      "DSpContext_CountAttributes" },
		{ "\032DSpContext_GetNthAttribute",      DSP_SUB_CONTEXT_GET_NTH_ATTRIBUTE,     "DSpContext_GetNthAttribute" },
		/* New context API */
		{ "\016DSpContext_New",                  DSP_SUB_NEW_CONTEXT,                   "DSpContext_New" },
		{ "\022DSpContext_Dispose",              DSP_SUB_DISPOSE_CONTEXT,               "DSpContext_Dispose" },
		{ "\022DSpContext_Reserve",              DSP_SUB_RESERVE,                       "DSpContext_Reserve" },
		{ "\022DSpContext_Release",              DSP_SUB_RELEASE,                       "DSpContext_Release" },
		/* Fading / gamma fade */
		{ "\024DSpContext_FadeGamma",            DSP_SUB_FADE_GAMMA,                    "DSpContext_FadeGamma" },
		{ "\027DSpContext_FadeGammaOut",         DSP_SUB_FADE_GAMMA_OUT,                "DSpContext_FadeGammaOut" },
		{ "\026DSpContext_FadeGammaIn",          DSP_SUB_FADE_GAMMA_IN,                 "DSpContext_FadeGammaIn" },
		{ "\033DSpContext_SetBlankingColor",     DSP_SUB_SET_BLANKING_COLOR,            "DSpContext_SetBlankingColor" },
		{ "\033DSpContext_GetBlankingColor",     DSP_SUB_GET_BLANKING_COLOR,            "DSpContext_GetBlankingColor" },
		/* Gamma */
		{ "\023DSpContext_SetGamma",             DSP_SUB_SET_GAMMA,                     "DSpContext_SetGamma" },
		{ "\023DSpContext_GetGamma",             DSP_SUB_GET_GAMMA,                     "DSpContext_GetGamma" },
		{ "\033DSpContext_GetGammaByDevice",     DSP_SUB_GET_GAMMA_BY_DEVICE,           "DSpContext_GetGammaByDevice" },
		{ "\025DSpContext_ResetGamma",           DSP_SUB_RESET_GAMMA,                   "DSpContext_ResetGamma" },
		/* Palette */
		{ "\025DSpContext_SetPalette",           DSP_SUB_SET_PALETTE,                   "DSpContext_SetPalette" },
		{ "\025DSpContext_GetPalette",           DSP_SUB_GET_PALETTE,                   "DSpContext_GetPalette" },
		{ "\034DSpContext_SetPaletteEntries",    DSP_SUB_SET_PALETTE_ENTRIES,           "DSpContext_SetPaletteEntries" },
		{ "\034DSpContext_GetPaletteEntries",    DSP_SUB_GET_PALETTE_ENTRIES,           "DSpContext_GetPaletteEntries" },
		{ "\035DSpContext_GetPaletteByDevice",   DSP_SUB_GET_PALETTE_BY_DEVICE,         "DSpContext_GetPaletteByDevice" },
		/* Cursor / CLUT operations */
		{ "\031DSpContext_SetCLUTEntries",       DSP_SUB_SET_CLUT_ENTRIES,              "DSpContext_SetCLUTEntries" },
		{ "\031DSpContext_GetCLUTEntries",       DSP_SUB_GET_CLUT_ENTRIES,              "DSpContext_GetCLUTEntries" },
		{ "\025DSpContext_ShowCursor",           DSP_SUB_SHOW_CURSOR,                   "DSpContext_ShowCursor" },
		{ "\030DSpContext_ObscureCursor",        DSP_SUB_OBSCURE_CURSOR,                "DSpContext_ObscureCursor" },
		{ "\024DSpContext_SetCursor",            DSP_SUB_SET_CURSOR,                    "DSpContext_SetCursor" },
		/* Underlay / overlay alt buffers */
		{ "\037DSpContext_GetUnderlayAltBuffer", DSP_SUB_GET_UNDERLAY_ALT_BUFFER,       "DSpContext_GetUnderlayAltBuffer" },
		{ "\036DSpContext_GetOverlayAltBuffer",  DSP_SUB_GET_OVERLAY_ALT_BUFFER,        "DSpContext_GetOverlayAltBuffer" },
		{ "\037DSpContext_SetUnderlayAltBuffer", DSP_SUB_SET_UNDERLAY_ALT_BUFFER,       "DSpContext_SetUnderlayAltBuffer" },
		{ "\036DSpContext_SetOverlayAltBuffer",  DSP_SUB_SET_OVERLAY_ALT_BUFFER,        "DSpContext_SetOverlayAltBuffer" },
		{ "\020DSpAltBuffer_New",                DSP_SUB_ALT_BUFFER_NEW,                "DSpAltBuffer_New" },
		{ "\024DSpAltBuffer_Dispose",            DSP_SUB_ALT_BUFFER_DISPOSE,            "DSpAltBuffer_Dispose" },
		{ "\026DSpAltBuffer_InvalRect",          DSP_SUB_ALT_BUFFER_INVAL_RECT,         "DSpAltBuffer_InvalRect" },
		/* Context queue */
		{ "\023DSpContextQueue_Add",            DSP_SUB_CONTEXT_QUEUE_ADD,             "DSpContextQueue_Add" },
		{ "\026DSpContextQueue_Remove",         DSP_SUB_CONTEXT_QUEUE_REMOVE,          "DSpContextQueue_Remove" },
		/* User notification callback */
		{ "\034DSpInstallUserSelectCallback",    DSP_SUB_INSTALL_USER_SELECT_CALLBACK,  "DSpInstallUserSelectCallback" },
		{ "\033DSpRemoveUserSelectCallback",     DSP_SUB_REMOVE_USER_SELECT_CALLBACK,   "DSpRemoveUserSelectCallback" },
		/* Blit operations */
		{ "\007DSpBlit",                         DSP_SUB_BLIT,                          "DSpBlit" },
		{ "\013DSpBlitRect",                     DSP_SUB_BLIT_RECT,                    "DSpBlitRect" },
		{ "\014DSpBlitPixel",                    DSP_SUB_BLIT_PIXEL,                   "DSpBlitPixel" },
		{ "\015DSpBlitRegion",                   DSP_SUB_BLIT_REGION,                  "DSpBlitRegion" },
		{ "\016DSpBlitFastest",                  DSP_SUB_BLIT_FASTEST,                 "DSpBlitFastest" },
	};
	const int num_dsp = sizeof(dsp_symbols) / sizeof(dsp_symbols[0]);

	// Cache found TVECTs
	struct CachedTVECT {
		uint32_t tvect;
		int sub_opcode;
		const char *name;
	};

	std::vector<CachedTVECT> cached_tvects;
	int found_count = 0;

	// Try each library name variant
	for (int lib = 0; lib < num_libs; lib++) {
		int lib_found = 0;
		for (int i = 0; i < num_dsp; i++) {
			uint32_t tvect = FindLibSymbol(lib_names[lib], dsp_symbols[i].pascal_sym);
			if (tvect != 0) {
				// Check we haven't already found this sub-opcode from a previous lib
				bool already_found = false;
				for (size_t j = 0; j < cached_tvects.size(); j++) {
					if (cached_tvects[j].sub_opcode == dsp_symbols[i].sub_opcode) {
						already_found = true;
						break;
					}
				}
				if (!already_found) {
					cached_tvects.push_back({ tvect, dsp_symbols[i].sub_opcode, dsp_symbols[i].name });
					found_count++;
					lib_found++;
					DSP_LOG("  found %s at TVECT 0x%08x (lib %d)", dsp_symbols[i].name, tvect, lib);
				}
			}
		}
		DSP_LOG("DSpInstallHooks: lib '%s' yielded %d new symbols", lib_names[lib] + 1, lib_found);

		// If we found all functions in this library, no need to try alternates
		if (found_count >= num_dsp) break;
	}

	DSP_LOG("DSpInstallHooks: found %d/%d DrawSprocket functions", found_count, num_dsp);

	// ---- Phase 2: Patch found TVECTs ----
	//
	// For each found TVECT, overwrite the first 4 PPC instructions at orig_code
	// with a branch to our hook thunk (identical to GL pattern).

	const uint32_t r11 = 11;
	int patched_count = 0;

	for (size_t i = 0; i < cached_tvects.size(); i++) {
		uint32_t orig_tvect = cached_tvects[i].tvect;
		int sub = cached_tvects[i].sub_opcode;
		uint32_t hook_tvect = dsp_method_tvects[sub];

		if (hook_tvect == 0) {
			DSP_LOG("  hook TVECT for %s (sub %d) not allocated!", cached_tvects[i].name, sub);
			continue;
		}

		// Read the original code pointer from the TVECT
		uint32_t orig_code = ReadMacInt32(orig_tvect);

		// Read our hook thunk's code pointer
		uint32_t hook_code = ReadMacInt32(hook_tvect);

		// Build patch: lis r11,hi; ori r11,r11,lo; mtctr r11; bctr
		uint32_t hook_hi = (hook_code >> 16) & 0xFFFF;
		uint32_t hook_lo = hook_code & 0xFFFF;

		// Overwrite first 4 instructions at orig_code
		// lis r11, hook_code_hi
		WriteMacInt32(orig_code + 0, 0x3C000000 | (r11 << 21) | hook_hi);
		// ori r11, r11, hook_code_lo
		WriteMacInt32(orig_code + 4, 0x60000000 | (r11 << 21) | (r11 << 16) | hook_lo);
		// mtctr r11
		WriteMacInt32(orig_code + 8, 0x7C0903A6 | (r11 << 21));
		// bctr
		WriteMacInt32(orig_code + 12, 0x4E800420);

		// Flush instruction cache
#if EMULATED_PPC
		FlushCodeCache(orig_code, orig_code + 16);
#endif

		patched_count++;
		DSP_LOG("  patched %s: orig_code=0x%08x -> hook_code=0x%08x",
		        cached_tvects[i].name, orig_code, hook_code);
	}

	DSP_LOG("DSpInstallHooks: patched %d functions total", patched_count);

	if (patched_count > 0) {
		dsp_hooks_installed = true;
		dsp_hooks_in_progress = false;
	} else {
		dsp_hooks_in_progress = false;
		dsp_hooks_attempts++;
		if (dsp_hooks_attempts >= DSP_HOOKS_MAX_ATTEMPTS)
			DSP_LOG("DSpInstallHooks: DrawSprocketLib not available after %d attempts, giving up",
			        dsp_hooks_attempts);
		else
			DSP_LOG("DSpInstallHooks: patched 0 functions, will retry on next VideoInstallAccel (attempt %d/%d)",
			        dsp_hooks_attempts, DSP_HOOKS_MAX_ATTEMPTS);
		return;
	}
}
