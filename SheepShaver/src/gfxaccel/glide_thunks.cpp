/*
 *  glide_thunks.cpp - Glide PPC-to-native TVECT allocation
 *
 *  Same layout as rave_thunks / dsp_thunks: 32-byte TVECT writes a
 *  sub-opcode into glide_scratch_addr then executes NATIVE_GLIDE_DISPATCH.
 *
 * (C) 2026 RandoOnSteam (battlemageloveryt@gmail.com)
 */

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "thunks.h"
#include "glide_engine.h"
#include "gfx_log.h"

uint32_t glide_method_tvects[GLIDE_MAX_SUBOPCODE];
uint32_t glide_scratch_addr = 0;

static uint32 AllocateGlideTVECT(int method_id, uint32 glide_opcode)
{
	uint32 scratch_hi = (glide_scratch_addr >> 16) & 0xFFFF;
	uint32 scratch_lo = glide_scratch_addr & 0xFFFF;

	uint32 base = SheepMem::ReserveProc(32);
	uint32 code = base + 8;

	WriteMacInt32(base + 0, code);
	WriteMacInt32(base + 4, 0);

	const uint32 r11 = 11;
	const uint32 r12 = 12;

	/* lis r11, scratch_hi */
	WriteMacInt32(code + 0, 0x3C000000 | (r11 << 21) | (scratch_hi & 0xFFFF));
	/* ori r11, r11, scratch_lo */
	WriteMacInt32(code + 4, 0x60000000 | (r11 << 21) | (r11 << 16) | (scratch_lo & 0xFFFF));
	/* li r12, method_id */
	WriteMacInt32(code + 8, 0x38000000 | (r12 << 21) | (method_id & 0xFFFF));
	/* stw r12, 0(r11) */
	WriteMacInt32(code + 12, 0x90000000 | (r12 << 21) | (r11 << 16));
	/* NATIVE_GLIDE_DISPATCH */
	WriteMacInt32(code + 16, glide_opcode);
	/* blr */
	WriteMacInt32(code + 20, 0x4E800020);

	return base;
}

void GlideThunksInit(void)
{
	QD3D_INIT_LOG("GlideThunksInit: begin");
	glide_scratch_addr = SheepMem::Reserve(32);
	WriteMacInt32(glide_scratch_addr, 0);

	uint32 glide_opcode = NativeOpcode(NATIVE_GLIDE_DISPATCH);
	memset(glide_method_tvects, 0, sizeof(glide_method_tvects));

	/* Allocate a TVECT for every defined sub-opcode slot we care about.
	 * Unused indices stay 0; InstallHooks only patches symbols that map
	 * to a non-zero TVECT. */
	static const int kCoreOps[] = {
		kGlide_grGlideInit, kGlide_grGlideShutdown, kGlide_grGlideGetVersion,
		kGlide_grSstQueryBoards, kGlide_grSstQueryHardware, kGlide_grSstSelect,
		kGlide_grSstWinOpen, kGlide_grSstWinClose, kGlide_grSstControl,
		kGlide_grSstIdle, kGlide_grSstIsBusy, kGlide_grSstOrigin,
		kGlide_grSstScreenWidth, kGlide_grSstScreenHeight, kGlide_grSstStatus,
		kGlide_grSstVRetraceOn, kGlide_grSstVideoLine,
		kGlide_grBufferClear, kGlide_grBufferSwap, kGlide_grBufferNumPending,
		kGlide_grRenderBuffer,
		kGlide_grDrawPoint, kGlide_grDrawLine, kGlide_grDrawTriangle,
		kGlide_grDrawPlanarPolygon, kGlide_grDrawPlanarPolygonVertexList,
		kGlide_grDrawPolygon, kGlide_grDrawPolygonVertexList,
		kGlide_grAADrawTriangle,
		kGlide_grAlphaBlendFunction, kGlide_grAlphaCombine,
		kGlide_grAlphaControlsITRGBLighting, kGlide_grAlphaTestFunction,
		kGlide_grAlphaTestReferenceValue, kGlide_grChromakeyMode,
		kGlide_grChromakeyValue, kGlide_grClipWindow, kGlide_grColorCombine,
		kGlide_grColorMask, kGlide_grConstantColorValue,
		kGlide_grConstantColorValue4, kGlide_grCullMode,
		kGlide_grDepthBiasLevel, kGlide_grDepthBufferFunction,
		kGlide_grDepthBufferMode, kGlide_grDepthMask,
		kGlide_grDisableAllEffects, kGlide_grDitherMode,
		kGlide_grFogColorValue, kGlide_grFogMode, kGlide_grFogTable,
		kGlide_grGammaCorrectionValue, kGlide_grHints, kGlide_grSplash,
		kGlide_grTexCalcMemRequired, kGlide_grTexTextureMemRequired,
		kGlide_grTexMinAddress, kGlide_grTexMaxAddress, kGlide_grTexNCCTable,
		kGlide_grTexSource, kGlide_grTexClampMode, kGlide_grTexCombine,
		kGlide_grTexDetailControl, kGlide_grTexFilterMode,
		kGlide_grTexLodBiasValue, kGlide_grTexLodTable, kGlide_grTexMipMapMode,
		kGlide_grTexDownloadMipMap, kGlide_grTexDownloadMipMapLevel,
		kGlide_grTexDownloadMipMapLevelPartial, kGlide_grTexDownloadTable,
		kGlide_grTexDownloadTablePartial, kGlide_grTexMultibase,
		kGlide_grTexMultibaseAddress,
		kGlide_grGet, kGlide_grGetString, kGlide_grReset,
		kGlide_grEnable, kGlide_grDisable, kGlide_grCoordinateSystem,
		kGlide_grGetProcAddress, kGlide_guGammaCorrectionRGB,
		kGlide_grDeviceQueryExt,
		kGlide_grVertexLayout, kGlide_grDrawVertexArray,
		kGlide_grDrawVertexArrayContiguous, kGlide_grGlideGetState,
		kGlide_grGlideSetState, kGlide_grGlideGetVertexLayout,
		kGlide_grGlideSetVertexLayout, kGlide_grFinish, kGlide_grFlush,
		kGlide_grLfbLock, kGlide_grLfbUnlock, kGlide_grLfbReadRegion,
		kGlide_grLfbWriteRegion, kGlide_grLfbConstantAlpha,
		kGlide_grLfbConstantDepth, kGlide_grLfbWriteColorFormat,
		kGlide_grLfbWriteColorSwizzle,
		kGlide_HookGetSharedLibrary, kGlide_HookFindSymbol,
		kGlide_HookCloseConnection, kGlide_HookCountSymbols,
		kGlide_HookGetIndSymbol,
	};

	int n = 0;
	for (size_t i = 0; i < sizeof(kCoreOps) / sizeof(kCoreOps[0]); i++) {
		int id = kCoreOps[i];
		if (id < 0 || id >= GLIDE_MAX_SUBOPCODE)
			continue;
		glide_method_tvects[id] = AllocateGlideTVECT(id, glide_opcode);
		n++;
	}
	QD3D_INIT_LOG("GlideThunksInit: allocated %d TVECTs scratch=0x%08x",
	              n, glide_scratch_addr);
}
