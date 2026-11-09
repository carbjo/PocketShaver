/*
 *  rave_draw_context.mm - RAVE draw context lifecycle and state management
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Draw context create/delete and the Set/Get state methods.
 */

#include <memory>
#include <new>
#include "sysdeps.h"
#include "cpu_emulation.h"
#include "rave_engine.h"
#include "rave_guest_buffer.h"
#include "rave_metal_renderer.h"

#include <cstring>

// Declared here rather than via macos_util.h to avoid UIKit header conflicts.
extern uint32 Mac_sysalloc(uint32 size);
extern void Mac_sysfree(uint32 addr);

// Must match TQAError in RAVE.h.
#define kQANoErr                    0
#define kQAError                    1
#define kQANotSupported             3
#define kQAParamErr                 5

// kQAContext flag bits
#define kQAContext_NoZBuffer  (1 << 0)

/*
 *  Context table: 1-based handles to RaveDrawPrivate.
 */
#ifndef RAVE_MAX_CONTEXTS
#define RAVE_MAX_CONTEXTS 8
#endif

static RaveDrawPrivate *context_table[RAVE_MAX_CONTEXTS] = {};
static uint64_t context_generation = 0;

int rave_context_count = 0;
uint32_t rave_current_draw_context_addr = 0;

RaveDrawPrivate *RaveGetContext(uint32 handle)
{
	if (RaveGuestMemoryCallActive() || handle == 0 || handle > RAVE_MAX_CONTEXTS)
		return nullptr;
	return context_table[handle - 1];
}

static uint32_t AllocContextHandle(RaveDrawPrivate *ctx)
{
	for (int i = 0; i < RAVE_MAX_CONTEXTS; i++) {
		if (context_table[i] == nullptr) {
			ctx->generation = ++context_generation;
			if (!ctx->generation) ctx->generation = ++context_generation;
			context_table[i] = ctx;
			return (uint32_t)(i + 1);
		}
	}
	return 0;  // No free slots
}

static void FreeContextHandle(uint32_t handle)
{
	if (handle > 0 && handle <= RAVE_MAX_CONTEXTS) {
		context_table[handle - 1] = nullptr;
	}
}

/*
 *  RAVE spec state defaults. Tag IDs are unique across the float/int/ptr
 *  enums in RAVE.h, so one state[] array holds them all.
 */
static void InitStateDefaults(RaveDrawPrivate *ctx, uint32 flags)
{
	memset(ctx->state, 0, sizeof(ctx->state));

	// kQATag_ZFunction (0) - int: kQAZFunction_None (0) if NoZBuffer, else kQAZFunction_LT (1)
	ctx->state[0].i = (flags & kQAContext_NoZBuffer) ? 0 : 1;

	// kQATag_ColorBG_a (1) through kQATag_ColorBG_b (4) - float: 0.0
	ctx->state[1].f = 0.0f;
	ctx->state[2].f = 0.0f;
	ctx->state[3].f = 0.0f;
	ctx->state[4].f = 0.0f;

	// kQATag_Width (5) - float: 1.0
	ctx->state[5].f = 1.0f;

	// kQATag_ZMinOffset (6) - float: 0.0
	ctx->state[6].f = 0.0f;

	// kQATag_ZMinScale (7) - float: 1.0/65535.0
	ctx->state[7].f = 1.0f / 65535.0f;

	// kQATag_Antialias (8) - int: kQAAntialias_Fast (1)
	ctx->state[8].i = 1;

	// kQATag_Blend (9) - int: kQABlend_PreMultiply (0)
	ctx->state[9].i = 0;

	// kQATag_PerspectiveZ (10) - int: kQAPerspectiveZ_Off (0)
	ctx->state[10].i = 0;

	// kQATag_TextureFilter (11) - int: kQATextureFilter_Fast (0)
	ctx->state[11].i = 0;

	// kQATag_TextureOp (12) - int: kQATextureOp_None (0)
	ctx->state[12].i = 0;

	// kQATag_Texture (13) - ptr: NULL
	ctx->state[13].i = 0;

	// kQATag_CSGTag (14) - int: 0xFFFFFFFF (kQACSGTag_None)
	ctx->state[14].i = 0xFFFFFFFF;

	// Fog state defaults
	ctx->state[17].i = 0;      // kQATag_FogMode: None
	ctx->state[18].f = 0.0f;   // kQATag_FogColor_a
	ctx->state[19].f = 0.0f;   // kQATag_FogColor_r
	ctx->state[20].f = 0.0f;   // kQATag_FogColor_g
	ctx->state[21].f = 0.0f;   // kQATag_FogColor_b
	ctx->state[22].f = 0.0f;   // kQATag_FogStart
	ctx->state[23].f = 1.0f;   // kQATag_FogEnd
	ctx->state[24].f = 1.0f;   // kQATag_FogDensity
	ctx->state[25].f = 1.0f;   // kQATag_FogMaxDepth

	// Depth write mask default (nonzero = writes enabled)
	ctx->state[28].i = 1;      // kQATag_ZBufferMask: enabled

	// Alpha/Z-sort state defaults
	ctx->state[29].i = 0;      // kQATag_ZSortedHint: off
	ctx->state[31].i = 0;      // kQATag_AlphaTestFunc: None (always pass)

	// Channel mask default (all channels enabled)
	ctx->state[27].i = 0xF;    // kQATag_ChannelMask: RGBA all enabled

	// Multi-texture defaults
	ctx->state[35].i = 0;      // kQATag_MultiTextureOp: Add
	ctx->state[41].f = 0.5f;   // kQATag_MipmapBias: spec default is 0.5
	ctx->state[42].f = 0.5f;   // kQATag_MultiTextureMipmapBias: spec default is 0.5
	ctx->state[46].f = 0.0f;   // kQATag_AlphaTestRef
	ctx->state[51].f = 0.5f;   // kQATag_MultiTextureFactor: 0.5

	// Bitmap scale defaults
	ctx->state[52].f = 1.0f;   // kQATag_BitmapScale_x: default 1.0 (no scaling)
	ctx->state[53].f = 1.0f;   // kQATag_BitmapScale_y: default 1.0 (no scaling)
	ctx->state[54].i = 0;      // kQATag_BitmapFilter: kQAFilter_Fast (nearest)

	// Remaining tags 15-59: zero from memset

	// GL tag defaults (100-153)
	ctx->state[100].i = 0;      // kQATagGL_DrawBuffer: back
	ctx->state[101].i = 0;      // kQATagGL_TextureWrapU: Repeat
	ctx->state[102].i = 0;      // kQATagGL_TextureWrapV: Repeat
	ctx->state[103].i = 0;      // kQATagGL_TextureMagFilter: Nearest
	ctx->state[104].i = 0;      // kQATagGL_TextureMinFilter: Nearest
	ctx->state[105].i = 0;      // kQATagGL_ScissorXMin
	ctx->state[106].i = 0;      // kQATagGL_ScissorYMin
	ctx->state[107].i = ctx->width;   // kQATagGL_ScissorXMax
	ctx->state[108].i = ctx->height;  // kQATagGL_ScissorYMax
	ctx->state[109].i = 1;      // kQATagGL_BlendSrc: GL_ONE (0x0001)
	ctx->state[110].i = 0;      // kQATagGL_BlendDst: GL_ZERO (0x0000)
	ctx->state[111].i = 0xFFFF; // kQATagGL_LinePattern: solid
	ctx->state[112].f = 1.0f;   // kQATagGL_DepthBG
	// Tags 113-116: TextureBorder a/r/g/b (default 0.0 from memset)
	// Tags 117-148: AreaPattern0-31 (default 0xFFFFFFFF = all solid)
	for (int i = 117; i <= 148; i++) ctx->state[i].i = 0xFFFFFFFF;
	ctx->state[149].i = 1;      // kQATagGL_LinePatternFactor
	// Tags 150-153: TextureEnvColor a/r/g/b (default 0.0 from memset)

	// ATI engine-specific defaults
	ctx->ati_fog_active = false;
	memset(ctx->ati_state, 0, sizeof(ctx->ati_state));
	uint32_t atiIntDefaults[RAVE_ATI_TAG_COUNT] = {};
	RaveATIInitializeIntDefaults(atiIntDefaults, RAVE_ATI_TAG_COUNT);
	for (uint32_t i = 0; i < RAVE_ATI_TAG_COUNT; i++) {
		ctx->ati_state[i].i = atiIntDefaults[i];
	}
	RAVE_LOG("InitStateDefaults: ATI UT probe tag %u default=%u (0x%08x)",
	         kRaveATIUnrealTournamentProbeTag,
	         ctx->ati_state[kRaveATIUnrealTournamentProbeIndex].i,
	         ctx->ati_state[kRaveATIUnrealTournamentProbeIndex].i);
}

/*
 *  TQADrawContext has 35 method pointers starting at offset 8. This maps
 *  each field to its rave_method_tvects sub-opcode.
 */
static const int kDrawContextMethodFields = 35;
static const int struct_field_to_subopcode[35] = {
	0,  1,  2,  3,  4,  5,       // setFloat..getPtr
	6,  7,  8,  9,  10, 11, 12,  // drawPoint..drawBitmap
	13, 14, 15, 16, 17,          // renderStart..sync
	18, 19, 20, 21,              // submitVerticesGouraud..drawTriMeshTexture
	22, 23,                      // setNoticeMethod, getNoticeMethod
	24,                          // submitMultiTextureParams
	25,                          // accessDrawBuffer
	26, 27, 28, 29, 30,          // accessDrawBufferEnd, accessZBuffer, accessZBufferEnd, clearDrawBuffer, clearZBuffer
	31, 32, 33,                  // textureFromContext, bitmapFromContext, busy
	34                           // swapBuffers
};


/*
 *  NativeDrawPrivateNew
 *  PPC args: r3=drawContext, r4=device, r5=rect, r6=clip, r7=flags
 *  Returns TQAError.
 */
int32 NativeDrawPrivateNew(uint32 drawContextAddr, uint32 deviceAddr,
                           uint32 rectAddr, uint32 clipAddr, uint32 flags)
{
	if (RaveGuestMemoryCallActive()) return kQAError;
	if (rave_logging_enabled) {
		printf("RAVE DrawPrivateNew ENTER: ctx=0x%08x dev=0x%08x rect=0x%08x clip=0x%08x flags=0x%x\n",
		       drawContextAddr, deviceAddr, rectAddr, clipAddr, flags);

		printf("RAVE DrawPrivateNew: context_table state on entry (count=%d):\n", rave_context_count);
		for (int i = 0; i < RAVE_MAX_CONTEXTS; i++) {
			if (context_table[i] != nullptr) {
				printf("  slot[%d] = %p (occupied)\n", i, context_table[i]);
			}
		}
	}

	// TQARect field order is left, right, top, bottom.
	int32 left   = (int32)ReadMacInt32(rectAddr + 0);
	int32 right  = (int32)ReadMacInt32(rectAddr + 4);
	int32 top    = (int32)ReadMacInt32(rectAddr + 8);
	int32 bottom = (int32)ReadMacInt32(rectAddr + 12);

	if (rave_logging_enabled)
		printf("RAVE DrawPrivateNew: rect raw=(%d,%d,%d,%d) size=%dx%d\n",
		       left, top, right, bottom, right - left, bottom - top);

	std::unique_ptr<RaveDrawPrivate> owner(new (std::nothrow) RaveDrawPrivate());
	RaveDrawPrivate *ctx = owner.get();
	if (!ctx) {
		if (rave_logging_enabled)
			printf("RAVE DrawPrivateNew: FAIL - native allocation returned null\n");
		return kQAError;
	}
	if (rave_logging_enabled)
		printf("RAVE DrawPrivateNew: native alloc OK at %p\n", ctx);
	memset(ctx, 0, sizeof(RaveDrawPrivate));

	ctx->left   = left;
	ctx->top    = top;
	ctx->width  = right - left;
	ctx->height = bottom - top;
	ctx->flags  = flags;
	ctx->drawContextAddr = drawContextAddr;

	InitStateDefaults(ctx, flags);

	ctx->vertexStagingCapacity = 65536;
	ctx->vertexStagingCount = 0;
	std::unique_ptr<uint8_t[]> vertices(new (std::nothrow) uint8_t[ctx->vertexStagingCapacity * RAVE_VERTEX_BYTES]);
	ctx->vertexStagingBuffer = vertices.get();

	// Multi-texture UVs, parallel to vertexStagingBuffer. 16 bytes per
	// vertex: uOverW2, vOverW2, invW2, pad.
	std::unique_ptr<uint8_t[]> multiTex(new (std::nothrow) uint8_t[ctx->vertexStagingCapacity * 16]);
	ctx->multiTexStagingBuffer = multiTex.get();
	ctx->multiTexStagingCount = 0;
	ctx->multiTextureActive = false;
	ctx->multiTextureHandle = 0;
	ctx->multiTextureOp = 0;
	ctx->multiTextureFactor = 0.0f;

	std::unique_ptr<ZSortTriangle[]> zsort(new (std::nothrow) ZSortTriangle[RAVE_ZSORT_MAX_TRIANGLES]);
	ctx->zsortBuffer = zsort.get();
	if (!vertices || !multiTex || !zsort) return kQAError;
	ctx->zsortCount = 0;

	ctx->frameCount = 0;

	uint32_t handle = AllocContextHandle(ctx);
	if (handle == 0) {
		if (rave_logging_enabled)
			printf("RAVE DrawPrivateNew: FAIL - no free context slots (all %d occupied)\n", RAVE_MAX_CONTEXTS);
		return kQAError;
	}
	// Ownership transfers only after all staging allocations and registration succeed.
	vertices.release();
	multiTex.release();
	zsort.release();
	owner.release();
	if (rave_logging_enabled)
		printf("RAVE DrawPrivateNew: got handle=%d\n", handle);

	// TQADrawContext: +0 drawPrivate handle, +4 version, +8 method TVECTs.
	WriteMacInt32(drawContextAddr + 0, handle);

	// TQAVersion: kQAVersion_1_6 = 4, not 0x01060000.
	WriteMacInt32(drawContextAddr + 4, 4);
	for (int i = 0; i < kDrawContextMethodFields; i++) {
		int subopcode = struct_field_to_subopcode[i];
		uint32 tvect_addr = 0;
		if (subopcode >= 0) {
			tvect_addr = rave_method_tvects[subopcode];
		}
		WriteMacInt32(drawContextAddr + 8 + i * 4, tvect_addr);
	}

	rave_context_count++;

	RaveCreateMetalOverlay(ctx->left, ctx->top, ctx->width, ctx->height);
	RaveInitMetalResources(ctx);

	RAVE_LOG("DrawPrivateNew: handle=%d size=%dx%d contexts=%d",
	         handle, ctx->width, ctx->height, rave_context_count);

	if (rave_logging_enabled) {
		printf("RAVE DrawContext at 0x%08x:\n", drawContextAddr);
		printf("  [+0] drawPrivate = %d\n", ReadMacInt32(drawContextAddr + 0));
		printf("  [+4] version     = %d\n", ReadMacInt32(drawContextAddr + 4));
		for (int i = 0; i < kDrawContextMethodFields; i++) {
			uint32 tvect = ReadMacInt32(drawContextAddr + 8 + i * 4);
			if (tvect != 0) {
				uint32 code_ptr = ReadMacInt32(tvect);
				printf("  [+%d] method[%d] = TVECT 0x%08x -> code 0x%08x\n",
				       8 + i * 4, i, tvect, code_ptr);
			} else {
				printf("  [+%d] method[%d] = NULL\n", 8 + i * 4, i);
			}
		}
	}

	// For EngineGestalt(kQATIGestalt_CurrentContext).
	rave_current_draw_context_addr = drawContextAddr;

	return kQANoErr;
}


/*
 *  NativeDrawPrivateDelete
 *  PPC args: r3 = drawPrivate handle. Returns 0 in gpr(3).
 */
int32 NativeDrawPrivateDelete(uint32 drawPrivateHandle)
{
	RAVE_LOG("DrawPrivateDelete: handle=%d", drawPrivateHandle);

	RaveDrawPrivate *ctx = RaveGetContext(drawPrivateHandle);
	if (!ctx) {
		RAVE_LOG("DrawPrivateDelete: invalid handle %d", drawPrivateHandle);
		return kQANoErr;
	}

	// Hide the dying context before guest DisposePtr can invoke callbacks.
	FreeContextHandle(drawPrivateHandle);
	{
		RaveGuestMemoryScope guard;
		const uint32_t owned = ctx->ati_ext_funcs_owned;
		ctx->ati_ext_funcs_owned = 0;
		if (owned) Mac_sysfree(owned);
	}

	delete[] ctx->vertexStagingBuffer;
	ctx->vertexStagingBuffer = nullptr;

	delete[] ctx->multiTexStagingBuffer;
	ctx->multiTexStagingBuffer = nullptr;

	delete[] ctx->drawScratchA;
	ctx->drawScratchA = nullptr;
	ctx->drawScratchACap = 0;
	delete[] ctx->drawScratchB;
	ctx->drawScratchB = nullptr;
	ctx->drawScratchBCap = 0;
	delete[] ctx->drawScratchF;
	ctx->drawScratchF = nullptr;
	ctx->drawScratchFCap = 0;

	delete[] ctx->zsortBuffer;
	ctx->zsortBuffer = nullptr;

	RaveReleaseMetalResources(ctx);

	delete ctx;
	rave_context_count--;

	// Leave the cached overlay alive when the last context goes away. Its
	// lifetime is the display mode: RaveOnDetach releases it on a real mode
	// change. Freeing it here caused a black flash on every Nanosaur scene
	// transition, because VBL presented between the delete and the next
	// DrawPrivateNew.
	if (rave_context_count <= 0) {
		rave_context_count = 0;
		rave_current_draw_context_addr = 0;
	}

	RAVE_LOG("DrawPrivateDelete: done, contexts=%d", rave_context_count);
	return kQANoErr;
}


/*
 *  State methods get the TQADrawContext address and read the drawPrivate
 *  handle from offset 0.
 */
static RaveDrawPrivate *GetContextFromDrawAddr(uint32 drawContextAddr)
{
	uint32 handle = ReadMacInt32(drawContextAddr + 0);
	return RaveGetContext(handle);
}


/*
 *  NativeSetFloat
 *  PPC args: r3=drawContextAddr, r4=tag, r5=float bits
 */
int32 NativeSetFloat(uint32 drawContextAddr, uint32 tag, uint32 valueBits)
{
	RaveDrawPrivate *ctx = GetContextFromDrawAddr(drawContextAddr);
	if (!ctx) {
		RAVE_LOG("SetFloat: invalid context 0x%08x", drawContextAddr);
		return kQAError;
	}

	// ATI engine-specific tags (1000+)
	if (tag >= 1000) {
		uint32_t ati_idx = tag - 1000;
		if (ati_idx < RAVE_ATI_TAG_COUNT) {
			float value;
			memcpy(&value, &valueBits, sizeof(float));
			ctx->ati_state[ati_idx].f = value;
			if (ati_idx == kRaveATIDepthWriteEnableIndex) {
				ctx->dirty_flags |= 1;
			}
				// ATI fog tags (indices 2-9) override standard fog.
			if (ati_idx >= 2 && ati_idx <= 9) {
				ctx->ati_fog_active = true;
			}
		}
		return kQANoErr;
	}
	// Standard and GL tags (0-153).
	if (tag >= RAVE_MAX_TAG) return kQANoErr;

	// Tags 6 and 7 are read-only per spec; accept and ignore writes.
	if (tag == 6 || tag == 7) return kQANoErr;

	float value;
	memcpy(&value, &valueBits, sizeof(float));
	ctx->state[tag].f = value;
	ctx->dirty_flags |= (1 << (tag & 31));

	return kQANoErr;
}


/*
 *  NativeSetInt
 *  PPC args: r3=drawContextAddr, r4=tag, r5=value
 */
int32 NativeSetInt(uint32 drawContextAddr, uint32 tag, uint32 value)
{
	RaveDrawPrivate *ctx = GetContextFromDrawAddr(drawContextAddr);
	if (!ctx) {
		RAVE_LOG("SetInt: invalid context 0x%08x", drawContextAddr);
		return kQAError;
	}

	// ATI engine-specific tags (1000+)
	if (tag >= 1000) {
		uint32_t ati_idx = tag - 1000;
		if (ati_idx < RAVE_ATI_TAG_COUNT) {
			ctx->ati_state[ati_idx].i = value;
			if (ati_idx == kRaveATIDepthWriteEnableIndex) {
				ctx->dirty_flags |= 1;
			}
				// ATI fog tags (indices 2-9) override standard fog.
			if (ati_idx >= 2 && ati_idx <= 9) {
				ctx->ati_fog_active = true;
			}
		}
		return kQANoErr;
	}
	// Standard and GL tags (0-153).
	if (tag >= RAVE_MAX_TAG) return kQANoErr;

	// MultiTextureEnable counts secondary layers; only secondary index 0 exists.
	if ((tag == 33 && value > 1) || (tag == 34 && value != 0)) return kQAParamErr;

	ctx->state[tag].i = value;
	ctx->dirty_flags |= (1 << (tag & 31));

	// Setting a standard fog mode cancels the ATI fog override.
	if (tag == 17 && value != 0) {
		ctx->ati_fog_active = false;
	}

	return kQANoErr;
}

// Writes only the 5 known slots: a caller-provided table's real size is
// unknown beyond the 5 entries Myth II uses.
static void WriteATIRaveExtFuncsTable(uint32 ptr)
{
	WriteMacInt32(ptr + kRaveATIRaveExtFuncsSlotClearDrawBuffer * 4,
	              rave_method_tvects[kRaveATIClearDrawBuffer]);
	WriteMacInt32(ptr + kRaveATIRaveExtFuncsSlotClearZBuffer * 4,
	              rave_method_tvects[kRaveATIClearZBuffer]);
	WriteMacInt32(ptr + kRaveATIRaveExtFuncsSlotTextureUpdate * 4,
	              rave_method_tvects[kRaveATITextureUpdate]);
	WriteMacInt32(ptr + kRaveATIRaveExtFuncsSlotBindCodeBook * 4,
	              rave_method_tvects[kRaveATIBindCodeBook]);
	WriteMacInt32(ptr + kRaveATIRaveExtFuncsSlotGetDrawBuffer * 4,
	              rave_method_tvects[kRaveATIGetDrawBuffer]);
}

static uint32 EnsureATIRaveExtFuncsTable(RaveDrawPrivate *ctx)
{
	// SetPtr writes into a caller's five-entry buffer. GetPtr vends this
	// separately owned table, which also has defensive tail stubs.
	uint32 ptr = ctx->ati_ext_funcs_owned;
	if (ptr == 0) {
		RaveGuestMemoryScope guard;
		ptr = Mac_sysalloc(kRaveATIRaveExtFuncsEntryCount * 4);
		if (ptr == 0) {
			RAVE_LOG("GetPtr: kATIRaveExtFuncs allocation failed");
			return 0;
		}
		ctx->ati_ext_funcs_owned = ptr;
	}

	WriteATIRaveExtFuncsTable(ptr);
	// Fill the unidentified tail slots with a callable stub so an
	// out-of-range index never jumps through heap garbage (Myth II crash).
	for (uint32 slot = kRaveATIRaveExtFuncsKnownSlotCount;
	     slot < kRaveATIRaveExtFuncsEntryCount; slot++) {
		WriteMacInt32(ptr + slot * 4, rave_method_tvects[kRaveATIStub]);
	}
	return ptr;
}


/*
 *  NativeSetPtr
 *  PPC args: r3=drawContextAddr, r4=tag, r5=Mac address
 */
int32 NativeSetPtr(uint32 drawContextAddr, uint32 tag, uint32 ptr)
{
	RaveDrawPrivate *ctx = GetContextFromDrawAddr(drawContextAddr);
	if (!ctx) {
		RAVE_LOG("SetPtr: invalid context 0x%08x", drawContextAddr);
		return kQAError;
	}

	// ATI engine-specific tags (1000+)
	if (tag >= 1000) {
		uint32_t ati_idx = tag - 1000;
		if (ati_idx == kRaveATIRaveExtFuncsIndex) {
			if (ptr == 0) {
				RAVE_LOG("SetPtr: kATIRaveExtFuncs ignored null pointer");
				return kQAParamErr;
			}
			WriteATIRaveExtFuncsTable(ptr);
			ctx->ati_state[kRaveATIRaveExtFuncsIndex].i = ptr;
			RAVE_LOG("SetPtr: kATIRaveExtFuncs -> delivered %u TVECT addresses to 0x%08x",
			         kRaveATIRaveExtFuncsKnownSlotCount, ptr);
			return kQANoErr;
		}
		if (ati_idx < RAVE_ATI_TAG_COUNT) {
			ctx->ati_state[ati_idx].i = ptr;
		}
		return kQANoErr;
	}
	if (tag >= RAVE_MAX_TAG) return kQANoErr;

	ctx->state[tag].i = ptr;
	ctx->dirty_flags |= (1 << (tag & 31));

	return kQANoErr;
}


/*
 *  NativeGetFloat
 *  PPC args: r3=drawContextAddr, r4=tag. Returns float bits in gpr(3).
 */
uint32 NativeGetFloat(uint32 drawContextAddr, uint32 tag)
{
	RaveDrawPrivate *ctx = GetContextFromDrawAddr(drawContextAddr);
	if (!ctx) {
		RAVE_LOG("GetFloat: invalid context 0x%08x", drawContextAddr);
		return 0;
	}

	// ATI engine-specific tags (1000+)
	if (tag >= 1000) {
		uint32_t ati_idx = tag - 1000;
		if (ati_idx < RAVE_ATI_TAG_COUNT) {
			uint32 bits;
			memcpy(&bits, &ctx->ati_state[ati_idx].f, sizeof(uint32));
			return bits;
		}
		return 0;
	}
	if (tag >= RAVE_MAX_TAG) return 0;

	uint32 bits;
	memcpy(&bits, &ctx->state[tag].f, sizeof(uint32));
	return bits;
}


/*
 *  NativeGetInt
 *  PPC args: r3=drawContextAddr, r4=tag
 */
uint32 NativeGetInt(uint32 drawContextAddr, uint32 tag)
{
	RaveDrawPrivate *ctx = GetContextFromDrawAddr(drawContextAddr);
	if (!ctx) {
		RAVE_LOG("GetInt: invalid context 0x%08x", drawContextAddr);
		return 0;
	}

	// ATI engine-specific tags (1000+)
	if (tag >= 1000) {
		uint32_t ati_idx = tag - 1000;
		if (ati_idx < RAVE_ATI_TAG_COUNT) {
			uint32_t value = ctx->ati_state[ati_idx].i;
			if (tag == kRaveATIUnrealTournamentProbeTag) {
				RAVE_VLOG("GetInt: ATI UT probe tag %u -> %u (0x%08x)", tag, value, value);
			}
			return value;
		}
		return 0;
	}
	if (tag >= RAVE_MAX_TAG) return 0;

	return ctx->state[tag].i;
}


/*
 *  NativeGetPtr
 *  PPC args: r3=drawContextAddr, r4=tag. Returns a Mac address.
 */
uint32 NativeGetPtr(uint32 drawContextAddr, uint32 tag)
{
	RaveDrawPrivate *ctx = GetContextFromDrawAddr(drawContextAddr);
	if (!ctx) {
		RAVE_LOG("GetPtr: invalid context 0x%08x", drawContextAddr);
		return 0;
	}

	// ATI engine-specific tags (1000+)
	if (tag >= 1000) {
		uint32_t ati_idx = tag - 1000;
		if (ati_idx == kRaveATIRaveExtFuncsIndex) {
			uint32 ptr = EnsureATIRaveExtFuncsTable(ctx);
			RAVE_LOG("GetPtr: kATIRaveExtFuncs -> 0x%08x", ptr);
			return ptr;
		}
		if (ati_idx < RAVE_ATI_TAG_COUNT) {
			return ctx->ati_state[ati_idx].i;
		}
		return 0;
	}
	if (tag >= RAVE_MAX_TAG) return 0;

	return ctx->state[tag].i;
}
