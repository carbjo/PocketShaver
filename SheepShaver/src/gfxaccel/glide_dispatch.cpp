/*
 *  glide_dispatch.cpp - NATIVE_GLIDE_DISPATCH multiplex
 *
 *  Reads sub-opcode from glide_scratch_addr and implements Glide 2/3
 *  entry points used by Diablo II and shared core titles.
 */

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "thunks.h"        /* SheepMem */
#include "glide_engine.h"
#include "display_mode_controller.h"
#include "gfx_frame_pacing_policy.h"
#include "metal_compositor.h"
#include "gfx_log.h"
#include "gfxaccel_backend.h"

#include <cstring>
#include <cstdarg>
#include <cstdio>

#if !defined(GFXACCEL_USE_OPENGL)
/* Metal Glide raster path is not implemented yet; keep dispatch linkable. */
int  GlideGLInit(void) { return -1; }
void GlideGLShutdown(void) {}
int  GlideGLWinOpen(int, int, int) { return -1; }
void GlideGLWinClose(void) {}
void GlideGLBufferClear(uint32_t, uint32_t, uint32_t) {}
void GlideGLBufferSwap(int) {}
void GlideGLDrawTriangle(const void *, const void *, const void *) {}
void GlideGLApplyState(void) {}
#endif

/* State accessors (glide_state.cpp) */
extern void GlideStateResetDefaults(void);
extern bool GlideStateIsInited(void);
extern bool GlideStateWindowOpen(void);
extern int  GlideStateWidth(void);
extern int  GlideStateHeight(void);
extern int  GlideStateOriginUpperLeft(void);
extern void GlideStateSetInited(bool v);
extern void GlideStateSetWindowOpen(bool v);
extern void GlideStateSetWin(int w, int h, int origin_ul, int cfmt, int nbuf, int naux);
extern void GlideStateSetClip(int minx, int miny, int maxx, int maxy);
extern void GlideStateSetConstantColor(uint32_t c);
extern uint32_t GlideStateConstantColor(void);
extern void GlideStateSetDepth(int mode, int func, int mask);
extern void GlideStateSetCull(int mode);
extern void GlideStateSetAlphaBlend(int s, int d, int sa, int da);
extern void GlideStateSetVertexLayout(int param, int offset, int mode);
extern void GlideStateSetTexSource(uint32_t startAddress, int evenOdd, int format);
extern uint32_t GlideStateTexMinAddress(int tmu);
extern uint32_t GlideStateTexMaxAddress(int tmu);
extern uint32_t GlideStateFbMem(void);
extern uint32_t GlideStateTmuMem(void);
extern void GlideStateResolveResolution(int res_enum, int *out_w, int *out_h);

static void glide_log(const char *fmt, ...)
{
#if ACCEL_LOGGING_ENABLED
	char buf[512];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	QD3D_INIT_LOG("%s", buf);
#else
	(void)fmt;
#endif
}

/* Guest GrHwConfiguration-ish: report one SST-1 class board. */
static void write_query_hardware(uint32_t hwConfigPtr)
{
	if (!hwConfigPtr) return;
	/* Minimal structure many ports accept:
	 *   num_sst (FxI32)
	 *   SSTs[0].type
	 *   SSTs[0].sstBoard.VoodooConfig.{fbRam, tmuConfig...}
	 * We zero a generous block and set num_sst=1, fb/tmu sizes. */
	for (int i = 0; i < 256; i += 4)
		WriteMacInt32(hwConfigPtr + i, 0);
	WriteMacInt32(hwConfigPtr + 0, 1); /* num_sst */
	/* Leave board type 0 = VOODOO; memory fields at common offsets. */
	WriteMacInt32(hwConfigPtr + 8, (int32_t)(GlideStateFbMem() / (1024 * 1024)));
	WriteMacInt32(hwConfigPtr + 12, 1); /* nTmus */
	WriteMacInt32(hwConfigPtr + 16, (int32_t)(GlideStateTmuMem() / (1024 * 1024)));
}

/*
 * Glide 3: FxBool grGet(FxU32 pname, FxU32 plength, void *params);
 * PPC: r3=pname, r4=plength, r5=params. (We used to treat r4 as params —
 * that wrote into low memory when D2 passed plength=4 and broke detection.)
 */
static uint32_t handle_grGet(uint32_t pname, uint32_t plength, uint32_t paramsPtr)
{
	if (!paramsPtr) {
		glide_log("grGet(pname=%u plength=%u params=NULL) -> FALSE", pname, plength);
		return FXFALSE;
	}
	/* Zero the buffer the app provided (up to a sane cap). */
	uint32_t nbytes = plength ? plength : 4;
	if (nbytes > 64) nbytes = 64;
	for (uint32_t i = 0; i + 4 <= nbytes; i += 4)
		WriteMacInt32(paramsPtr + i, 0);
	for (uint32_t i = (nbytes & ~3u); i < nbytes; i++)
		WriteMacInt8(paramsPtr + i, 0);

	uint32_t v0 = 0, v1 = 0, v2 = 0, v3 = 0;
	int nvals = 1;
	switch (pname) {
	case GR_BITS_DEPTH:                v0 = 16; break;
	case GR_BITS_RGBA:                 v0 = 0x05060500; /* 5/6/5/0-ish pack; app may only need nonzero */ break;
	case GR_FIFO_FULLNESS:             v0 = 0; break;
	case GR_FOG_TABLE_ENTRIES:         v0 = 64; break;
	case GR_GAMMA_TABLE_ENTRIES:       v0 = 256; break;
	case GR_IS_BUSY:                   v0 = 0; break;
	case GR_LFB_PIXEL_PIPE:            v0 = 0; break;
	case GR_MAX_TEXTURE_SIZE:          v0 = 256; break;
	case GR_MAX_TEXTURE_ASPECT_RATIO:  v0 = 8; break;
	case GR_MEMORY_FB:                 v0 = GlideStateFbMem(); break;
	case GR_MEMORY_TMU:                v0 = GlideStateTmuMem(); break;
	case GR_MEMORY_UMA:                v0 = 0; break;
	case GR_NUM_BOARDS:                v0 = 1; break;
	case GR_NUM_POWER_OF_TWO_TEXTURES: v0 = 1; break; /* power-of-two only */
	case GR_NUM_FB:                    v0 = 1; break;
	case GR_NUM_TMU:                   v0 = 1; break;
	case GR_PENDING_BUFFERSWAPS:       v0 = 0; break;
	case GR_REVISION_FB:               v0 = 2; break;
	case GR_REVISION_TMU:              v0 = 1; break;
	case GR_TEXTURE_ALIGN:             v0 = 8; break;
	case GR_VIDEO_POSITION:
		v0 = 0; v1 = 0; nvals = 2; break;
	case GR_VIEWPORT:
		v0 = 0; v1 = 0;
		v2 = (uint32_t)GlideStateWidth();
		v3 = (uint32_t)GlideStateHeight();
		nvals = 4;
		break;
	case GR_WDEPTH_MIN_MAX:
		v0 = 0; v1 = 65535; nvals = 2; break;
	case GR_ZDEPTH_MIN_MAX:
		v0 = 0; v1 = 65535; nvals = 2; break;
	case GR_GLIDE_STATE_SIZE:          v0 = 4096; break;
	case GR_GLIDE_VERTEXLAYOUT_SIZE:   v0 = 256; break;
	default:
		glide_log("grGet(pname=0x%x plength=%u) unknown -> 0 TRUE", pname, plength);
		WriteMacInt32(paramsPtr, 0);
		return FXTRUE;
	}
	if (nbytes >= 4) WriteMacInt32(paramsPtr + 0, (int32_t)v0);
	if (nvals >= 2 && nbytes >= 8) WriteMacInt32(paramsPtr + 4, (int32_t)v1);
	if (nvals >= 3 && nbytes >= 12) WriteMacInt32(paramsPtr + 8, (int32_t)v2);
	if (nvals >= 4 && nbytes >= 16) WriteMacInt32(paramsPtr + 12, (int32_t)v3);
	glide_log("grGet(pname=0x%x plength=%u) -> v0=%u v1=%u TRUE",
	          pname, plength, v0, v1);
	return FXTRUE;
}

static uint32_t handle_grGetString(uint32_t pname)
{
	/* Return a Mac pointer to a static C string in SheepMem once allocated. */
	static uint32_t s_vendor = 0, s_renderer = 0, s_version = 0, s_ext = 0;
	auto ensure = [](uint32_t &slot, const char *text) -> uint32_t {
		if (slot) return slot;
		size_t n = strlen(text) + 1;
		slot = SheepMem::Reserve((uint32)((n + 3) & ~3u));
		uint8 *p = Mac2HostAddr(slot);
		if (p) memcpy(p, text, n);
		return slot;
	};
	/* Official grGetString tokens are 0xa0–0xa4. */
	switch (pname) {
	case GR_EXTENSION:
		return ensure(s_ext, "DEVICE ");
	case GR_HARDWARE:
		return ensure(s_renderer, "Voodoo 3");
	case GR_RENDERER:
		return ensure(s_renderer, "Glide");
	case GR_VENDOR:
		return ensure(s_vendor, "3Dfx Interactive");
	case GR_VERSION:
		return ensure(s_version, "3.10");
	default:
		glide_log("grGetString(pname=0x%x) unknown", pname);
		return ensure(s_version, "3.10");
	}
}

uint32_t GlideDispatch(uint32_t r3, uint32_t r4, uint32_t r5,
                       uint32_t r6, uint32_t r7, uint32_t r8)
{
	if (!glide_scratch_addr)
		return 0;
	const uint32_t sub = ReadMacInt32(glide_scratch_addr);

	/* Always log non-CFM-gate calls so we can see whether D2 actually
	 * invokes Glide after symbol bind (config crash path). */
	if (sub < kGlide_HookGetSharedLibrary) {
		static uint64_t s_call_n = 0;
		++s_call_n;
		if (s_call_n <= 64 || (s_call_n & (s_call_n - 1)) == 0)
			glide_log("GlideDispatch #%llu sub=%u r3=%08x r4=%08x r5=%08x",
			          (unsigned long long)s_call_n, sub, r3, r4, r5);
	}

	switch (sub) {
	case kGlide_grGlideInit:
		GlideStateResetDefaults();
		GlideStateSetInited(true);
		GlideGLInit();
		glide_log("grGlideInit");
		return 0;

	case kGlide_grGlideShutdown:
		if (GlideStateWindowOpen()) {
			GlideGLWinClose();
			GlideStateSetWindowOpen(false);
			(void)dmc_set_active_owner(kDMCOwnerQuickDraw);
		}
		GlideGLShutdown();
		GlideStateSetInited(false);
		glide_log("grGlideShutdown");
		return 0;

	case kGlide_grGlideGetVersion: {
		/* void grGlideGetVersion(char version[80]); */
		if (r3) {
			const char *v = "3.10";
			uint8 *p = Mac2HostAddr(r3);
			if (p) {
				size_t n = strlen(v);
				if (n > 79) n = 79;
				memcpy(p, v, n);
				p[n] = 0;
			}
		}
		return 0;
	}

	case kGlide_grSstQueryBoards: {
		/* FxBool grSstQueryBoards(GrHwConfiguration *hw); */
		if (r3) {
			WriteMacInt32(r3, 1);
			write_query_hardware(r3);
		}
		return FXTRUE;
	}

	case kGlide_grSstQueryHardware: {
		if (r3) write_query_hardware(r3);
		return FXTRUE;
	}

	case kGlide_grSstSelect:
		/* void grSstSelect(int which_sst); */
		return 0;

	case kGlide_grSstWinOpen: {
		/* FxBool grSstWinOpen(FxU32 hWnd, GrScreenResolution_t res,
		 *   GrScreenRefresh_t ref, GrColorFormat_t cformat,
		 *   GrOriginLocation_t org, int nColBuffers, int nAuxBuffers) */
		const int res = (int)r4;
		const int cfmt = (int)r6;
		const int org = (int)r7;
		const int nCol = (int)r8;
		/* nAux is stack arg on PPC when > 8 words — default 1 if missing. */
		int nAux = 1;
		int w = 640, h = 480;
		GlideStateResolveResolution(res, &w, &h);
		const int origin_ul = (org == GR_ORIGIN_UPPER_LEFT) ? 1 : 0;
		if (GlideGLWinOpen(w, h, origin_ul) != 0) {
			glide_log("grSstWinOpen FAILED %dx%d", w, h);
			return FXFALSE;
		}
		GlideStateSetWin(w, h, origin_ul, cfmt, nCol ? nCol : 2, nAux);
		(void)dmc_set_active_owner(kDMCOwnerGlide);
		glide_log("grSstWinOpen %dx%d orgUL=%d cfmt=%d nCol=%d",
		          w, h, origin_ul, cfmt, nCol);
		return FXTRUE;
	}

	case kGlide_grSstWinClose:
		GlideGLWinClose();
		GlideStateSetWindowOpen(false);
		(void)dmc_set_active_owner(kDMCOwnerQuickDraw);
		glide_log("grSstWinClose");
		return 0;

	case kGlide_grSstControl:
	case kGlide_grSstIdle:
		return 0;
	case kGlide_grSstIsBusy:
		return FXFALSE;
	case kGlide_grSstOrigin:
		return 0;
	case kGlide_grSstScreenWidth:
		return (uint32_t)GlideStateWidth();
	case kGlide_grSstScreenHeight:
		return (uint32_t)GlideStateHeight();
	case kGlide_grSstStatus:
		return 0;
	case kGlide_grSstVRetraceOn:
		return FXTRUE;
	case kGlide_grSstVideoLine:
		return 0;

	case kGlide_grBufferClear: {
		/* void grBufferClear(GrColor_t color, GrAlpha_t alpha, FxU32 depth) */
		GlideGLBufferClear(r3, r4, r5);
		return 0;
	}
	case kGlide_grBufferSwap: {
		/* void grBufferSwap(int swap_interval) */
		GlideGLBufferSwap((int)r3);
		MetalCompositorSync3DFramePacingForEngine(kGfxFramePacingEngineGlide);
		return 0;
	}
	case kGlide_grBufferNumPending:
		return 0;
	case kGlide_grRenderBuffer:
		return 0;

	case kGlide_grDrawTriangle: {
		/* void grDrawTriangle(const GrVertex *a, *b, *c) */
		const void *a = r3 ? Mac2HostAddr(r3) : nullptr;
		const void *b = r4 ? Mac2HostAddr(r4) : nullptr;
		const void *c = r5 ? Mac2HostAddr(r5) : nullptr;
		if (a && b && c)
			GlideGLDrawTriangle(a, b, c);
		return 0;
	}
	case kGlide_grAADrawTriangle: {
		const void *a = r3 ? Mac2HostAddr(r3) : nullptr;
		const void *b = r4 ? Mac2HostAddr(r4) : nullptr;
		const void *c = r5 ? Mac2HostAddr(r5) : nullptr;
		if (a && b && c)
			GlideGLDrawTriangle(a, b, c);
		return 0;
	}
	case kGlide_grDrawPoint:
	case kGlide_grDrawLine:
	case kGlide_grDrawPlanarPolygon:
	case kGlide_grDrawPlanarPolygonVertexList:
	case kGlide_grDrawPolygon:
	case kGlide_grDrawPolygonVertexList:
		/* Stubs until D2 logs show hits. */
		return 0;

	case kGlide_grAlphaBlendFunction:
		GlideStateSetAlphaBlend((int)r3, (int)r4, (int)r5, (int)r6);
		return 0;
	case kGlide_grAlphaCombine:
	case kGlide_grAlphaControlsITRGBLighting:
	case kGlide_grAlphaTestFunction:
	case kGlide_grAlphaTestReferenceValue:
		return 0;
	case kGlide_grChromakeyMode:
	case kGlide_grChromakeyValue:
		return 0;
	case kGlide_grClipWindow:
		GlideStateSetClip((int)r3, (int)r4, (int)r5, (int)r6);
		return 0;
	case kGlide_grColorCombine:
		return 0;
	case kGlide_grColorMask:
		return 0;
	case kGlide_grConstantColorValue:
		GlideStateSetConstantColor(r3);
		return 0;
	case kGlide_grConstantColorValue4:
		return 0;
	case kGlide_grCullMode:
		GlideStateSetCull((int)r3);
		return 0;
	case kGlide_grDepthBiasLevel:
		return 0;
	case kGlide_grDepthBufferFunction:
		GlideStateSetDepth(-1, (int)r3, -1);
		return 0;
	case kGlide_grDepthBufferMode:
		GlideStateSetDepth((int)r3, -1, -1);
		return 0;
	case kGlide_grDepthMask:
		GlideStateSetDepth(-1, -1, r3 ? 1 : 0);
		return 0;
	case kGlide_grDisableAllEffects:
	case kGlide_grDitherMode:
	case kGlide_grFogColorValue:
	case kGlide_grFogMode:
	case kGlide_grFogTable:
	case kGlide_grGammaCorrectionValue:
	case kGlide_grHints:
	case kGlide_grSplash:
		return 0;

	case kGlide_grTexCalcMemRequired:
	case kGlide_grTexTextureMemRequired:
		/* Return a conservative byte size. */
		return 256 * 256 * 2;
	case kGlide_grTexMinAddress:
		return GlideStateTexMinAddress((int)r3);
	case kGlide_grTexMaxAddress:
		return GlideStateTexMaxAddress((int)r3);
	case kGlide_grTexSource:
		/* void grTexSource(GrChipID_t tmu, FxU32 startAddress, FxU32 evenOdd, GrTexInfo *info) */
		GlideStateSetTexSource(r4, (int)r5, 0);
		return 0;
	case kGlide_grTexClampMode:
	case kGlide_grTexCombine:
	case kGlide_grTexDetailControl:
	case kGlide_grTexFilterMode:
	case kGlide_grTexLodBiasValue:
	case kGlide_grTexLodTable:
	case kGlide_grTexMipMapMode:
	case kGlide_grTexDownloadMipMap:
	case kGlide_grTexDownloadMipMapLevel:
	case kGlide_grTexDownloadMipMapLevelPartial:
	case kGlide_grTexDownloadTable:
	case kGlide_grTexDownloadTablePartial:
	case kGlide_grTexMultibase:
	case kGlide_grTexMultibaseAddress:
	case kGlide_grTexNCCTable:
		return 0;

	case kGlide_grGet:
		/* FxBool grGet(FxU32 pname, FxU32 plength, void *params) */
		return handle_grGet(r3, r4, r5);
	case kGlide_grGetString:
		return handle_grGetString(r3);
	case kGlide_grGetProcAddress: {
		/* void *grGetProcAddress(char *procName); return TVECT or NULL */
		char name[128] = "";
		if (r3) {
			const uint8_t *p = Mac2HostAddr(r3);
			if (p) {
				size_t i = 0;
				while (i + 1 < sizeof(name) && p[i]) {
					name[i] = (char)p[i];
					i++;
				}
				name[i] = 0;
			}
		}
		struct Pair { const char *n; int sub; };
		static const Pair kExt[] = {
			{ "grGet", kGlide_grGet },
			{ "grGetString", kGlide_grGetString },
			{ "grCoordinateSpace", kGlide_grCoordinateSystem },
			{ "grCoordinateSystem", kGlide_grCoordinateSystem },
			{ "guGammaCorrectionRGB", kGlide_guGammaCorrectionRGB },
			{ "grTexDownloadTable", kGlide_grTexDownloadTable },
			{ "grChromakeyMode", kGlide_grChromakeyMode },
			{ "grChromakeyValue", kGlide_grChromakeyValue },
			{ "grDitherMode", kGlide_grDitherMode },
			/* D2 board-detect extension (must not return NULL). */
			{ "grDeviceQueryExt", kGlide_grDeviceQueryExt },
			{ "grDeviceQuery", kGlide_grDeviceQueryExt },
		};
		for (size_t i = 0; i < sizeof(kExt) / sizeof(kExt[0]); i++) {
			if (std::strcmp(name, kExt[i].n) == 0) {
				/*
				 * Return the TVECT (CFM ProcPtr), not raw code. Mac callers
				 * do lwz r0,0(r3); mtctr; bctrl. Returning code would break
				 * that. Raw-code callers that bctr to the TVECT itself hit
				 * illegal opcodes — execute_illegal now recovers via LR.
				 */
				uint32_t tv = glide_method_tvects[kExt[i].sub];
				glide_log("grGetProcAddress('%s') -> tvect=0x%08x code=0x%08x",
				          name, tv, tv ? ReadMacInt32(tv) : 0);
				return tv;
			}
		}
		glide_log("grGetProcAddress('%s') -> NULL", name);
		return 0;
	}
	case kGlide_grDeviceQueryExt: {
		/*
		 * D2: grGetProcAddress("grDeviceQueryExt") then call with
		 * (void *buf, FxU32 size). Log shows r4=0x10 (16-byte query block).
		 * Fill a Voodoo-like summary so detection does not reject zeros.
		 */
		uint32_t buf = r3;
		uint32_t size = r4 ? r4 : 16;
		if (buf && size >= 4) {
			/* Word0: board type GR_SSTTYPE_VOODOO=0 or Voodoo2=3 */
			WriteMacInt32(buf + 0, 3); /* Voodoo2-class */
			if (size >= 8)
				WriteMacInt32(buf + 4, (int32_t)(GlideStateFbMem() / (1024 * 1024)));
			if (size >= 12)
				WriteMacInt32(buf + 8, 1); /* nTMU */
			if (size >= 16)
				WriteMacInt32(buf + 12, (int32_t)(GlideStateTmuMem() / (1024 * 1024)));
		}
		glide_log("grDeviceQueryExt buf=%08x size=%u -> TRUE", buf, size);
		return FXTRUE;
	}
	case kGlide_guGammaCorrectionRGB:
		/* void guGammaCorrectionRGB(float r, float g, float b); no-op OK */
		return 0;
	case kGlide_grReset:
	case kGlide_grEnable:
	case kGlide_grDisable:
	case kGlide_grCoordinateSystem:
		return 0;
	case kGlide_grVertexLayout:
		/* void grVertexLayout(FxU32 param, FxI32 offset, FxU32 mode) */
		GlideStateSetVertexLayout((int)r3, (int)r4, (int)r5);
		return 0;
	case kGlide_grDrawVertexArray:
	case kGlide_grDrawVertexArrayContiguous:
		/* Implement when D2 path is confirmed from logs. */
		return 0;
	case kGlide_grGlideGetState:
	case kGlide_grGlideSetState:
	case kGlide_grGlideGetVertexLayout:
	case kGlide_grGlideSetVertexLayout:
	case kGlide_grFinish:
	case kGlide_grFlush:
		return 0;

	case kGlide_grLfbLock:
		/* Report failure for now (soft fallback); D2 often tolerates this. */
		return FXFALSE;
	case kGlide_grLfbUnlock:
		return FXTRUE;
	case kGlide_grLfbReadRegion:
	case kGlide_grLfbWriteRegion:
	case kGlide_grLfbConstantAlpha:
	case kGlide_grLfbConstantDepth:
	case kGlide_grLfbWriteColorFormat:
	case kGlide_grLfbWriteColorSwizzle:
		return FXFALSE;

	case kGlide_HookGetSharedLibrary:
		return NativeGlideHookGetSharedLibrary(r3, r4, r5, r6, r7, r8);
	case kGlide_HookFindSymbol:
		return NativeGlideHookFindSymbol(r3, r4, r5, r6);
	case kGlide_HookCloseConnection:
		return NativeGlideHookCloseConnection(r3);
	case kGlide_HookCountSymbols:
		return NativeGlideHookCountSymbols(r3, r4);
	case kGlide_HookGetIndSymbol:
		return NativeGlideHookGetIndSymbol(r3, r4, r5, r6, r7);

	default:
		glide_log("GlideDispatch: unhandled sub=%u", sub);
		return 0;
	}
}
