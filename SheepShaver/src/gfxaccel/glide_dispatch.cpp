/*
 *  glide_dispatch.cpp - NATIVE_GLIDE_DISPATCH multiplex
 *
 */

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "thunks.h"        /* SheepMem */
#include "macos_util.h"
#include "glide_engine.h"
#include "display_mode_controller.h"
#include "gfx_log.h"
#include "gfxaccel_backend.h"

#include <cstring>
#include <cstdarg>
#include <cstdio>
#include <vector>
#include <chrono>

#if !defined(GFXACCEL_USE_OPENGL)
/* Metal Glide raster path is not implemented yet; keep dispatch linkable. */
int  GlideGLInit(void) { return -1; }
void GlideGLShutdown(void) {}
int  GlideGLWinOpen(int, int, int) { return -1; }
void GlideGLWinClose(void) {}
void GlideGLBufferClear(uint32_t, uint32_t, uint32_t) {}
void GlideGLBufferSwap(int) {}
void GlideGLDrawPoint(const void *) {}
void GlideGLDrawLine(const void *, const void *) {}
void GlideGLDrawTriangle(const void *, const void *, const void *) {}
void GlideGLDrawPolygon(int, const void *const *) {}
void GlideGLDrawPolygonContiguous(int, const void *, uint32_t) {}
void GlideGLDrawVertexArray(uint32_t, uint32_t, const void *const *) {}
void GlideGLDrawVertexArrayContiguous(uint32_t, uint32_t, const void *, uint32_t) {}
void GlideGLApplyState(void) {}
void GlideGLSetClipWindow(int, int, int, int) {}
void GlideGLSetColorMask(int, int, int, int) {}
void GlideGLSetAlphaTest(int, int, float) {}
void GlideGLSetChromakey(void) {}
void GlideGLSetFog(int, uint32_t) {}
void GlideGLSetDepthBias(float) {}
void GlideGLMarkContent(void) {}
void GlideGLPublishOverlay(int) {}
void GlideGLSplash(void) {}
void GlideGLFinish(void) {}
void GlideGLUploadLfbAndPresent(const uint8_t *, int, int, int, int) {}
void GlideGLTexDownloadLevel(uint32_t, int, int, int, int, const void *, uint32_t) {}
void GlideGLTexSource(uint32_t, int, int, int, int, int) {}
void GlideGLTexDownloadTable(int, const void *) {}
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
extern void GlideStateSetConstantColor4(float r, float g, float b, float a);
extern uint32_t GlideStateConstantColor(void);
extern void GlideStateSetDepth(int mode, int func, int mask);
extern void GlideStateSetDepthBias(float b);
extern void GlideStateSetCull(int mode);
extern void GlideStateSetAlphaBlend(int s, int d, int sa, int da);
extern void GlideStateSetAlphaTest(int func, float ref);
extern int GlideStateAlphaTestEnabled(void);
extern int GlideStateAlphaTestFunc(void);
extern float GlideStateAlphaTestRef(void);
extern void GlideStateSetColorMask(int r, int g, int b, int a);
extern void GlideStateSetChromakey(int mode, uint32_t value);
extern int GlideStateChromaMode(void);
extern uint32_t GlideStateChromaValue(void);
extern void GlideStateSetFog(int mode, uint32_t color);
extern int GlideStateFogMode(void);
extern uint32_t GlideStateFogColor(void);
extern void GlideStateSetDither(int mode);
extern void GlideStateSetRenderBuffer(int buf);
extern void GlideStateSetColorCombine(int func);
extern void GlideStateSetAlphaCombine(int func);
extern void GlideStateSetTexCombine(int rgb, int a);
extern void GlideStateSetTexLodBias(float b);
extern void GlideStateSetTexDetail(int n, int d, int clamp);
extern void GlideStateSetTexMipMapMode(int mode);
extern void GlideStateSetLfbConstAlpha(uint32_t a);
extern void GlideStateSetLfbConstDepth(uint32_t d);
extern void GlideStateSetLfbWriteColorFormat(int f);
extern void GlideStateSetLfbWriteColorSwizzle(int s);
extern void GlideStateSetCoordSystem(int c);
extern void GlideStateDisableAllEffects(void);
extern void GlideStateSetVertexLayout(int param, int offset, int mode);
extern void GlideStateSetTexSource(uint32_t startAddress, int evenOdd, int format);
extern void GlideStateSetTexSourceEx(uint32_t startAddress, int evenOdd,
                                     int small_lod, int large_lod, int aspect_log2, int format);
extern void GlideStateSetTexClamp(int s, int t);
extern void GlideStateSetTexFilter(int minf, int magf);
extern bool GlideStateLfbWriteRegion(int dst_buffer, int dst_x, int dst_y,
                                     int src_format, int src_w, int src_h,
                                     int src_stride, const void *src_data);
extern bool GlideStateLfbReadRegion(int src_buffer, int src_x, int src_y,
                                    int src_w, int src_h, int dst_stride, void *dst_data);
extern uint32_t GlideStateTexMinAddress(int tmu);
extern uint32_t GlideStateTexMaxAddress(int tmu);
extern uint32_t GlideStateFbMem(void);
extern uint32_t GlideStateTmuMem(void);
extern uint32_t GlideTexCalcMemRequired(int small_lod, int large_lod, int aspect_log2, int format);
extern uint32_t GlideTexLevelSizeBytes(int lod, int aspect_log2, int format);
extern void GlideStateResolveResolution(int res_enum, int *out_w, int *out_h);
extern void GlideStateLfbRelease(void);
extern bool GlideStateLfbLock(int type, int buffer, int write_mode, int origin,
                              uint32_t *out_ptr, uint32_t *out_stride, int *out_write_mode);
extern bool GlideStateLfbUnlock(int buffer);
extern bool GlideStateLfbIsLocked(void);
extern uint32_t GlideStateLfbGuestPtr(void);
extern uint32_t GlideStateLfbStride(void);
extern int GlideStateLfbWriteMode(void);
extern int GlideStateLfbType(void);
extern int GlideStateLfbBuffer(void);
extern int GlideStateLfbBpp(void);
extern const uint8_t *GlideStateLfbConvertToBGRA(int *out_w, int *out_h, int *out_pitch);
extern void GlideStateLfbClear(uint16_t color565);

static void glide_log(const char *fmt, ...)
{
#if ACCEL_LOGGING_ENABLED
	char buf[512];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof(buf), fmt, ap);
	va_end(ap);
	QD3D_INIT_LOG("%s", buf);
	/* Hang diagnosis: force line out immediately so the last line is real. */
	fflush(stderr);
	fflush(stdout);
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
 * Glide 3: FxU32 grGet(FxU32 pname, FxU32 plength, void *params).
 * The result is the number of bytes written, not an FxBool.  Bad tokens and
 * short buffers return zero without modifying the caller's buffer.
 */
static uint32_t handle_grGet(uint32_t pname, uint32_t plength, uint32_t paramsPtr)
{
	if (!paramsPtr) {
		glide_log("grGet(pname=%u plength=%u params=NULL) -> 0 bytes", pname, plength);
		return 0;
	}

	uint32_t v0 = 0, v1 = 0, v2 = 0, v3 = 0;
	uint32_t required = 4;
	switch (pname) {
	case GR_BITS_DEPTH:                v0 = 16; break;
	case GR_BITS_RGBA:
		v0 = 5; v1 = 6; v2 = 5; v3 = 0; required = 16; break;
	case GR_FIFO_FULLNESS:
		/* Minimum and maximum FIFO fullness are a two-value Glide 3 query. */
		v0 = 0; v1 = 0; required = 8; break;
	case GR_FOG_TABLE_ENTRIES:         v0 = 64; break;
	case GR_GAMMA_TABLE_ENTRIES:       v0 = 256; break;
	case GR_GLIDE_STATE_SIZE:          v0 = 4096; break;
	case GR_GLIDE_VERTEXLAYOUT_SIZE:   v0 = 256; break;
	case GR_IS_BUSY:                   v0 = 0; break;
	case GR_LFB_PIXEL_PIPE:            v0 = 0; break;
	case GR_MAX_TEXTURE_SIZE:          v0 = 256; break;
	case GR_MAX_TEXTURE_ASPECT_RATIO:  v0 = 8; break;
	case GR_MEMORY_FB:                 v0 = GlideStateFbMem(); break;
	case GR_MEMORY_TMU:                v0 = GlideStateTmuMem(); break;
	case GR_MEMORY_UMA:                v0 = 0; break;
	case GR_NUM_BOARDS:                v0 = 1; break;
	case GR_NON_POWER_OF_TWO_TEXTURES: v0 = 0; break;
	case GR_NUM_FB:                    v0 = 1; break;
	case GR_NUM_SWAP_HISTORY_BUFFER:   v0 = 8; break;
	case GR_NUM_TMU:                   v0 = 1; break;
	case GR_PENDING_BUFFERSWAPS:
		v0 = 0; break; /* swaps complete synchronously */
	case GR_REVISION_FB:               v0 = 2; break;
	case GR_REVISION_TMU:              v0 = 1; break;
	case GR_STATS_LINES:
	case GR_STATS_PIXELS_AFUNC_FAIL:
	case GR_STATS_PIXELS_CHROMA_FAIL:
	case GR_STATS_PIXELS_DEPTHFUNC_FAIL:
	case GR_STATS_PIXELS_IN:
	case GR_STATS_PIXELS_OUT:
	case GR_STATS_PIXELS:
	case GR_STATS_POINTS:
	case GR_STATS_TRIANGLES_IN:
	case GR_STATS_TRIANGLES_OUT:
	case GR_STATS_TRIANGLES:
	case GR_SWAP_HISTORY:              v0 = 0; break;
	case GR_SUPPORTS_PASSTHRU:         v0 = 0; break;
	case GR_TEXTURE_ALIGN:             v0 = 8; break;
	case GR_VIDEO_POSITION:
		v0 = 0; v1 = 0; required = 8; break;
	case GR_VIEWPORT:
		v0 = 0; v1 = 0;
		v2 = (uint32_t)GlideStateWidth();
		v3 = (uint32_t)GlideStateHeight();
		required = 16;
		break;
	case GR_WDEPTH_MIN_MAX:
	case GR_ZDEPTH_MIN_MAX:
		v0 = 0; v1 = 65535; required = 8; break;
	case GR_VERTEX_PARAMETER:          v0 = 0; break;
	case GR_BITS_GAMMA:                v0 = 8; break;
	default:
		glide_log("grGet(pname=0x%x plength=%u) unknown -> 0 bytes", pname, plength);
		return 0;
	}

	if (plength < required) {
		glide_log("grGet(pname=0x%x plength=%u) needs %u -> 0 bytes",
		          pname, plength, required);
		return 0;
	}
	WriteMacInt32(paramsPtr + 0, (int32_t)v0);
	if (required >= 8)  WriteMacInt32(paramsPtr + 4, (int32_t)v1);
	if (required >= 12) WriteMacInt32(paramsPtr + 8, (int32_t)v2);
	if (required >= 16) WriteMacInt32(paramsPtr + 12, (int32_t)v3);
	glide_log("grGet(pname=0x%x plength=%u) -> v0=%u v1=%u bytes=%u",
	          pname, plength, v0, v1, required);
	return required;
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
	/* Official grGetString tokens are 0xa0-0xa4. */
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

/* Ring of recent Glide calls for hang dumps (host-side, no guest pointers kept live). */
struct GlideCallRec {
	uint64_t n;
	uint32_t sub;
	uint32_t r3, r4, r5, r6, r7, r8, r9, r10, stack9;
};
static const int kGlideHist = 48;
static GlideCallRec s_glide_hist[kGlideHist];
static int s_glide_hist_i = 0;
static uint64_t s_glide_hist_total = 0;
static uint32_t s_last_sub = 0;
static uint64_t s_call_n_global = 0;


void GlideHangDumpState(void)
{
	glide_log("======== GLIDE HANG STATE ========");
	glide_log("glide: call_n=%llu last_sub=%u hist_total=%llu",
	          (unsigned long long)s_call_n_global, s_last_sub,
	          (unsigned long long)s_glide_hist_total);
	glide_log("glide: inited=%d win_open=%d size=%dx%d originUL=%d chroma_mode=%d chroma_val=%08x",
	          GlideStateIsInited() ? 1 : 0,
	          GlideStateWindowOpen() ? 1 : 0,
	          GlideStateWidth(), GlideStateHeight(),
	          GlideStateOriginUpperLeft(),
	          GlideStateChromaMode(),
	          (unsigned)GlideStateChromaValue());
	glide_log("glide: swap=sync lfb_locked=%d lfb_ptr=%08x stride=%u type=%d buf=%d mode=%d",
	          GlideStateLfbIsLocked() ? 1 : 0,
	          (unsigned)GlideStateLfbGuestPtr(),
	          (unsigned)GlideStateLfbStride(),
	          GlideStateLfbType(), GlideStateLfbBuffer(), GlideStateLfbWriteMode());
	glide_log("glide: scratch=%08x (sub slot)", (unsigned)glide_scratch_addr);
	if (glide_scratch_addr)
		glide_log("glide: scratch_sub_now=%u", (unsigned)ReadMacInt32(glide_scratch_addr));
	/* Dump hist oldest..newest */
	const int n = (s_glide_hist_total < (uint64_t)kGlideHist)
	              ? (int)s_glide_hist_total : kGlideHist;
	glide_log("glide: last %d calls (oldest first):", n);
	for (int k = 0; k < n; k++) {
		const int idx = (s_glide_hist_i - n + k + kGlideHist * 2) % kGlideHist;
		const GlideCallRec &c = s_glide_hist[idx];
		glide_log("  hist[%d] #%llu sub=%u r3=%08x r4=%08x r5=%08x r6=%08x r7=%08x r8=%08x r9=%08x r10=%08x sp9=%08x",
		          k, (unsigned long long)c.n, c.sub,
		          c.r3, c.r4, c.r5, c.r6, c.r7, c.r8, c.r9, c.r10, c.stack9);
	}
	glide_log("======== GLIDE HANG STATE END ========");
}

uint32_t GlideDispatch(uint32_t r3, uint32_t r4, uint32_t r5,
                       uint32_t r6, uint32_t r7, uint32_t r8,
                       uint32_t r9, uint32_t r10, uint32_t sp)
{
	if (!glide_scratch_addr)
		return 0;
	const uint32_t sub = ReadMacInt32(glide_scratch_addr);
	/* 9th stack arg (PPC Mac): home area + 8 register slots = SP+56. */
	const uint32_t stack9 = sp ? ReadMacInt32(sp + 56) : 0;

	static uint64_t s_call_n = 0;
	static uint32_t s_post_open_n = 0;
	static uint32_t s_hot_n = 0; /* VRetrace / VideoLine / IsBusy spam */
	++s_call_n;
	s_call_n_global = s_call_n;
	s_last_sub = sub;
	/* Record history (including hot paths - hang diagnosis needs them). */
	{
		GlideCallRec &c = s_glide_hist[s_glide_hist_i];
		c.n = s_call_n; c.sub = sub;
		c.r3 = r3; c.r4 = r4; c.r5 = r5; c.r6 = r6;
		c.r7 = r7; c.r8 = r8; c.r9 = r9; c.r10 = r10; c.stack9 = stack9;
		s_glide_hist_i = (s_glide_hist_i + 1) % kGlideHist;
		s_glide_hist_total++;
	}
	if (sub == kGlide_grSstWinOpen)
		s_post_open_n = 0;
	else if (GlideStateWindowOpen() && sub < kGlide_HookGetSharedLibrary)
		++s_post_open_n;

	const bool hot =
		sub == kGlide_grSstVRetraceOn || sub == kGlide_grSstVideoLine ||
		sub == kGlide_grSstIsBusy || sub == kGlide_grSstIdle ||
		sub == kGlide_grSstStatus || sub == kGlide_grBufferNumPending;
	const bool always_log =
		sub < kGlide_HookGetSharedLibrary && !hot &&
		(s_post_open_n <= 400 || s_call_n <= 120 ||
		 sub == kGlide_grBufferClear || sub == kGlide_grBufferSwap ||
		 sub == kGlide_grLfbLock || sub == kGlide_grLfbUnlock ||
		 sub == kGlide_grTexDownloadMipMap ||
		 sub == kGlide_grTexDownloadMipMapLevel ||
		 sub == kGlide_grTexSource || sub == kGlide_grTexDownloadTable ||
		 sub == kGlide_grDrawTriangle || sub == kGlide_grDrawVertexArray ||
		 sub == kGlide_grDrawVertexArrayContiguous ||
		 sub == kGlide_grSstWinOpen || sub == kGlide_grSstWinClose ||
		 (sub >= 200 && sub < 230));

	const bool log_this = true;/*hot ? (++s_hot_n <= 16 || (s_hot_n % 10000u) == 0)
	                          : always_log;*/
	if (hot && log_this)
		glide_log("GlideENTER #%llu sub=%u HOT#%u r3=%08x (win=%d)",
		          (unsigned long long)s_call_n, sub, s_hot_n, r3,
		          GlideStateWindowOpen() ? 1 : 0);
	else if (!hot && log_this)
		glide_log("GlideENTER #%llu sub=%u r3=%08x r4=%08x r5=%08x r6=%08x r7=%08x r8=%08x r9=%08x r10=%08x",
		          (unsigned long long)s_call_n, sub, r3, r4, r5, r6, r7, r8, r9, r10);

	/* RAII exit log - if the log freezes mid-call, ENTER was last without EXIT. */
	struct GlideExitLog {
		uint64_t n;
		uint32_t sub;
		bool on;
		~GlideExitLog()
		{
			if (on)
				glide_log("GlideEXIT  #%llu sub=%u",
				          (unsigned long long)n, sub);
		}
	} exit_log{s_call_n, sub, log_this && !hot};

	switch (sub) {
	case kGlide_grGlideInit:
		GlideStateResetDefaults();
		GlideStateSetInited(true);
		GlideGLInit();
		/* Re-smash exports - grGlideInit / library reload can restore stock
		 * TVECTs and leave wait paths spinning in PEF hardware stubs. */
		extern void GlideForceReinstallHooks(void);
		GlideForceReinstallHooks();
		glide_log("grGlideInit (+hooks re-patch)");
		return 0;

	case kGlide_grGlideShutdown:
		if (GlideStateWindowOpen()) {
			GlideGLWinClose();
			GlideStateSetWindowOpen(false);
			(void)dmc_set_active_owner(kDMCOwnerQuickDraw);
		}
		GlideStateLfbRelease();
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
		/* nAux is stack arg on PPC when > 8 words - default 1 if missing. */
		int nAux = 1;
		int w = 640, h = 480;
		GlideStateResolveResolution(res, &w, &h);
		const int origin_ul = (org == GR_ORIGIN_UPPER_LEFT) ? 1 : 0;
		/* Drop any stale lock from a prior mode (movies -> menu). */
		if (GlideStateLfbIsLocked())
			(void)GlideStateLfbUnlock(0);
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

	case kGlide_grSstWinClose: {
		/* D2 spams WinClose on teardown - ignore when already closed. */
		static uint32_t s_close_n = 0;
		if (!GlideStateWindowOpen())
			return 0;
		++s_close_n;
		if (GlideStateLfbIsLocked())
			(void)GlideStateLfbUnlock(0);
		GlideGLWinClose();
		GlideStateSetWindowOpen(false);
		/* Keep LFB alloc across close/reopen (mode switch 640->800); free on shutdown.
		 * Leave DMC owner alone - next DSp SetState / WinOpen owns the handoff. */
		if (s_close_n <= 4 || (s_close_n & (s_close_n - 1)) == 0)
			glide_log("grSstWinClose (#%u)", (unsigned)s_close_n);
		return 0;
	}

	case kGlide_grSstControl:
	case kGlide_grSstIdle:
		/* Stock PEF may spin on hardware; our hook is pure no-op. */
		return 0;
	case kGlide_grSstIsBusy:
		/* Never sticky-busy (that freezes while(grSstIsBusy()). */
		return FXFALSE;
	case kGlide_grSstOrigin:
		return 0;
	case kGlide_grSstScreenWidth:
		return (uint32_t)GlideStateWidth();
	case kGlide_grSstScreenHeight:
		return (uint32_t)GlideStateHeight();
	case kGlide_grSstStatus:
		/* SST status: 0 = idle / not busy / FIFO empty. */
		return 0;
	case kGlide_grSstVRetraceOn: {
		/*
		 * D2 PEF may not even export this (FindLibSymbol=0) - still implement
		 * for GetProcAddress / future PEFs. Toggle every call AND time-based
		 * so while(grSstVRetraceOn()) / while(!...) cannot stick forever.
		 */
		static uint32_t s_vr_calls = 0;
		static uint64_t s_vr_epoch_ms = 0;
		++s_vr_calls;
		const uint64_t now_ms = (uint64_t)std::chrono::duration_cast<std::chrono::milliseconds>(
			std::chrono::steady_clock::now().time_since_epoch()).count();
		if (s_vr_epoch_ms == 0)
			s_vr_epoch_ms = now_ms;
		const uint64_t phase = (now_ms - s_vr_epoch_ms) % 16ull;
		/* Report the host-time retrace phase. The prior call-count toggle and
		 * deferred-Present kick fabricated hardware progress and could disturb
		 * a frame already being rendered. */
		uint32_t in_retrace = (phase < 3ull) ? FXTRUE : FXFALSE;
		if (s_vr_calls <= 12 || (s_vr_calls % 50000u) == 0) {
			glide_log("grSstVRetraceOn #%u -> %u phase=%llu",
			          s_vr_calls, in_retrace, (unsigned long long)phase);
		}
		return in_retrace;
	}
	case kGlide_grSstVideoLine: {
		static uint32_t s_vl_calls = 0;
		static uint64_t s_vl_epoch_ms = 0;
		++s_vl_calls;
		const uint64_t now_ms = (uint64_t)std::chrono::duration_cast<std::chrono::milliseconds>(
			std::chrono::steady_clock::now().time_since_epoch()).count();
		if (s_vl_epoch_ms == 0)
			s_vl_epoch_ms = now_ms;
		const int h = GlideStateHeight() > 0 ? GlideStateHeight() : 480;
		const uint64_t phase = (now_ms - s_vl_epoch_ms) % 16ull;
		/* Also advance by call count so zero-time polls move. */
		const uint32_t line = (uint32_t)(((phase * (uint64_t)h) / 16ull + s_vl_calls) % (uint32_t)h);
		return line;
	}

	case kGlide_grBufferClear: {
		/* void grBufferClear(GrColor_t color, GrAlpha_t alpha, FxU32 depth) */
		glide_log("grBufferClear begin color=%08x", r3);
		/* Clear back buffer only - real Glide does not display on clear. */
		GlideGLBufferClear(r3, r4, r5);
		(void)dmc_set_active_owner(kDMCOwnerGlide);
		glide_log("grBufferClear done");
		return 0;
	}
	case kGlide_grBufferSwap: {
		/* void grBufferSwap(int swap_interval) */
		const int interval = (int)r3;
		glide_log("grBufferSwap begin interval=%d", interval);
		/*
		 * Make the back buffer visible (SubmitFrame + Present), same contract
		 * as LFB unlock which already works for D2 movies. Instant software
		 * completion: pending=0 after Present. free-run keeps Mac VBL alive
		 * between swaps; see docs/d2-glide-menu-hang.md.
		 */
		GlideGLBufferSwap(interval);
		(void)dmc_set_active_owner(kDMCOwnerGlide);
		(void)interval; /* hardware would wait ~interval VBLs; we present now */
		glide_log("grBufferSwap done (pending=0, presented)");
		return 0;
	}
	case kGlide_grBufferNumPending: {
		/* Read-only count; the software swap above completes synchronously. */
		return 0;
	}
	case kGlide_grRenderBuffer:
		GlideStateSetRenderBuffer((int)r3);
		return 0;

	case kGlide_grDrawPoint: {
		const void *a = r3 ? Mac2HostAddr(r3) : nullptr;
		if (a) { GlideGLDrawPoint(a); GlideGLMarkContent(); }
		return 0;
	}
	case kGlide_grDrawLine: {
		const void *a = r3 ? Mac2HostAddr(r3) : nullptr;
		const void *b = r4 ? Mac2HostAddr(r4) : nullptr;
		if (a && b) { GlideGLDrawLine(a, b); GlideGLMarkContent(); }
		return 0;
	}
	case kGlide_grDrawTriangle: {
		const void *a = r3 ? Mac2HostAddr(r3) : nullptr;
		const void *b = r4 ? Mac2HostAddr(r4) : nullptr;
		const void *c = r5 ? Mac2HostAddr(r5) : nullptr;
		if (a && b && c) {
			GlideGLDrawTriangle(a, b, c);
			GlideGLMarkContent();
		}
		return 0;
	}
	case kGlide_grAADrawTriangle: {
		const void *a = r3 ? Mac2HostAddr(r3) : nullptr;
		const void *b = r4 ? Mac2HostAddr(r4) : nullptr;
		const void *c = r5 ? Mac2HostAddr(r5) : nullptr;
		if (a && b && c) {
			GlideGLDrawTriangle(a, b, c);
			GlideGLMarkContent();
		}
		return 0;
	}
	case kGlide_grDrawPlanarPolygon:
	case kGlide_grDrawPolygon: {
		/* void grDrawPolygon(int nverts, const int ilist[], const GrVertex vlist[]);
		 * Common alternate: grDrawPlanarPolygon(nverts, *ilist, **verts)
		 * r3=nverts, r4=ilist or verts, r5=verts */
		const int n = (int)r3;
		if (n < 3 || n > 256) return 0;
		/* Prefer pointer list at r5, else contiguous at r4. */
		if (r5) {
			static std::vector<const void *> ptrs;
			ptrs.resize((size_t)n);
			for (int i = 0; i < n; i++) {
				const uint32_t mac = ReadMacInt32(r5 + (uint32_t)i * 4);
				ptrs[(size_t)i] = mac ? Mac2HostAddr(mac) : nullptr;
			}
			GlideGLDrawPolygon(n, ptrs.data());
		} else if (r4) {
			GlideGLDrawPolygonContiguous(n, Mac2HostAddr(r4), 0);
		}
		GlideGLMarkContent();
		return 0;
	}
	case kGlide_grDrawPlanarPolygonVertexList:
	case kGlide_grDrawPolygonVertexList: {
		/* void grDrawPolygonVertexList(int nverts, const GrVertex vlist[]); */
		const int n = (int)r3;
		const void *v = r4 ? Mac2HostAddr(r4) : nullptr;
		if (v && n >= 3)
			GlideGLDrawPolygonContiguous(n, v, 0);
		GlideGLMarkContent();
		return 0;
	}

	case kGlide_grAlphaBlendFunction:
		GlideStateSetAlphaBlend((int)r3, (int)r4, (int)r5, (int)r6);
		return 0;
	case kGlide_grAlphaCombine:
		GlideStateSetAlphaCombine((int)r3);
		return 0;
	case kGlide_grAlphaControlsITRGBLighting:
		return 0;
	case kGlide_grAlphaTestFunction:
		GlideStateSetAlphaTest((int)r3, GlideStateAlphaTestRef());
		GlideGLSetAlphaTest(1, (int)r3, GlideStateAlphaTestRef());
		return 0;
	case kGlide_grAlphaTestReferenceValue: {
		/* GrAlpha_t often 0..255 */
		const float ref = (r3 > 255) ? 1.f : (r3 / 255.f);
		GlideStateSetAlphaTest(GlideStateAlphaTestFunc(), ref);
		GlideGLSetAlphaTest(GlideStateAlphaTestEnabled(),
		                    GlideStateAlphaTestFunc(), ref);
		return 0;
	}
	case kGlide_grChromakeyMode:
		GlideStateSetChromakey((int)r3, GlideStateChromaValue());
		GlideGLSetChromakey();
		return 0;
	case kGlide_grChromakeyValue:
		GlideStateSetChromakey(GlideStateChromaMode(), r3);
		GlideGLSetChromakey();
		return 0;
	case kGlide_grClipWindow:
		GlideStateSetClip((int)r3, (int)r4, (int)r5, (int)r6);
		GlideGLSetClipWindow((int)r3, (int)r4, (int)r5, (int)r6);
		return 0;
	case kGlide_grColorCombine:
		GlideStateSetColorCombine((int)r3);
		return 0;
	case kGlide_grColorMask:
		/* void grColorMask(FxBool rgb, FxBool a) */
		GlideStateSetColorMask(r3 ? 1 : 0, r3 ? 1 : 0, r3 ? 1 : 0, r4 ? 1 : 0);
		GlideGLSetColorMask(r3 ? 1 : 0, r3 ? 1 : 0, r3 ? 1 : 0, r4 ? 1 : 0);
		return 0;
	case kGlide_grConstantColorValue:
		GlideStateSetConstantColor(r3);
		return 0;
	case kGlide_grConstantColorValue4: {
		/* void grConstantColorValue4(float a, float r, float g, float b)
		 * Floats may be in r3-r6 as raw bits on some ABIs. */
		union { uint32_t u; float f; } a, rr, g, b;
		a.u = r3; rr.u = r4; g.u = r5; b.u = r6;
		GlideStateSetConstantColor4(rr.f, g.f, b.f, a.f);
		return 0;
	}
	case kGlide_grCullMode:
		GlideStateSetCull((int)r3);
		return 0;
	case kGlide_grDepthBiasLevel: {
		/* FxI32 or float bias */
		union { uint32_t u; float f; int32_t i; } v;
		v.u = r3;
		/* Prefer small int as integer bias, else float bits */
		const float bias = (v.i > -10000 && v.i < 10000) ? (float)v.i : v.f;
		GlideStateSetDepthBias(bias);
		GlideGLSetDepthBias(bias);
		return 0;
	}
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
		GlideStateDisableAllEffects();
		return 0;
	case kGlide_grDitherMode:
		GlideStateSetDither((int)r3);
		return 0;
	case kGlide_grFogColorValue:
		GlideStateSetFog(GlideStateFogMode(), r3);
		GlideGLSetFog(GlideStateFogMode(), r3);
		return 0;
	case kGlide_grFogMode:
		GlideStateSetFog((int)r3, GlideStateFogColor());
		GlideGLSetFog((int)r3, GlideStateFogColor());
		return 0;
	case kGlide_grFogTable:
		/* void grFogTable(const GrFog_t table[GR_FOG_TABLE_SIZE]) - accept. */
		return 0;
	case kGlide_grGammaCorrectionValue: {
		/* float gamma - accept. */
		return 0;
	}
	case kGlide_grHints:
		return 0;
	case kGlide_grSplash:
		GlideGLSplash();
		return 0;

	case kGlide_grTexCalcMemRequired: {
		/* FxU32 grTexCalcMemRequired(GrLOD_t small, GrLOD_t large,
		 *   GrAspectRatio_t aspect, GrTextureFormat_t format) */
		return GlideTexCalcMemRequired((int)r3, (int)r4, (int)r5, (int)r6);
	}
	case kGlide_grTexTextureMemRequired: {
		/* FxU32 grTexTextureMemRequired(FxU32 evenOdd, GrTexInfo *info) */
		const uint32_t info = r4;
		if (!info)
			return 256 * 256 * 2;
		const int small_lod = (int)ReadMacInt32(info + 0);
		const int large_lod = (int)ReadMacInt32(info + 4);
		const int aspect = (int)ReadMacInt32(info + 8);
		const int format = (int)ReadMacInt32(info + 12);
		return GlideTexCalcMemRequired(small_lod, large_lod, aspect, format);
	}
	case kGlide_grTexMinAddress:
		return GlideStateTexMinAddress((int)r3);
	case kGlide_grTexMaxAddress:
		return GlideStateTexMaxAddress((int)r3);
	case kGlide_grTexSource: {
		/* void grTexSource(GrChipID_t tmu, FxU32 startAddress, FxU32 evenOdd,
		 *                  GrTexInfo *info) */
		const uint32_t start = r4;
		const int evenOdd = (int)r5;
		const uint32_t info = r6;
		int small_lod = 0, large_lod = 8, aspect = 0, format = 0x0a;
		if (info) {
			small_lod = (int)ReadMacInt32(info + 0);
			large_lod = (int)ReadMacInt32(info + 4);
			aspect = (int)ReadMacInt32(info + 8);
			format = (int)ReadMacInt32(info + 12);
		}
		GlideStateSetTexSourceEx(start, evenOdd, small_lod, large_lod, aspect, format);
		GlideGLTexSource(start, evenOdd, small_lod, large_lod, aspect, format);
		return 0;
	}
	case kGlide_grTexClampMode:
		GlideStateSetTexClamp((int)r4, (int)r5); /* tmu=r3, s=r4, t=r5 */
		return 0;
	case kGlide_grTexFilterMode:
		GlideStateSetTexFilter((int)r4, (int)r5);
		return 0;
	case kGlide_grTexCombine:
		/* void grTexCombine(tmu, rgb_func, rgb_factor, alpha_func, alpha_factor,
		 *                   rgb_invert, alpha_invert) - store rgb/alpha funcs. */
		GlideStateSetTexCombine((int)r4, (int)r6);
		return 0;
	case kGlide_grTexDetailControl:
		GlideStateSetTexDetail((int)r4, (int)r5, (int)r6);
		return 0;
	case kGlide_grTexLodBiasValue: {
		union { uint32_t u; float f; } v; v.u = r4;
		GlideStateSetTexLodBias(v.f);
		return 0;
	}
	case kGlide_grTexLodTable:
		return 0;
	case kGlide_grTexMipMapMode:
		GlideStateSetTexMipMapMode((int)r4);
		return 0;
	case kGlide_grTexDownloadMipMap: {
		/* void grTexDownloadMipMap(GrChipID_t tmu, FxU32 startAddress,
		 *   FxU32 evenOdd, GrTexInfo *info) */
		const uint32_t start = r4;
		const uint32_t info = r6;
		if (!info) return 0;
		const int small_lod = (int)ReadMacInt32(info + 0);
		const int large_lod = (int)ReadMacInt32(info + 4);
		const int aspect = (int)ReadMacInt32(info + 8);
		const int format = (int)ReadMacInt32(info + 12);
		const uint32_t data_mac = ReadMacInt32(info + 16);
		const uint8_t *data = data_mac ? Mac2HostAddr(data_mac) : nullptr;
		if (!data) return 0;
		/* Download each LOD from large->small; data packs levels sequentially. */
		uint32_t addr = start;
		const uint8_t *p = data;
		const int lo = small_lod < large_lod ? small_lod : large_lod;
		const int hi = small_lod < large_lod ? large_lod : small_lod;
		for (int lod = hi; lod >= lo; --lod) {
			const uint32_t n = GlideTexLevelSizeBytes(lod, aspect, format);
			GlideGLTexDownloadLevel(addr, lod, hi, aspect, format, p, n);
			addr += n;
			p += n;
		}
		return 0;
	}
	case kGlide_grTexDownloadMipMapLevel:
	case kGlide_grTexDownloadMipMapLevelPartial: {
		/* void grTexDownloadMipMapLevel(GrChipID_t tmu, FxU32 startAddress,
		 *   GrLOD_t thisLod, GrLOD_t largeLod, GrAspectRatio_t aspect,
		 *   GrTextureFormat_t format, FxU32 evenOdd, void *data)
		 * PPC: r3..r10 - evenOdd=r9, data=r10. Partial has more stack args;
		 * we treat as full level download. */
		const uint32_t start = r4;
		const int this_lod = (int)r5;
		const int large_lod = (int)r6;
		const int aspect = (int)r7;
		const int format = (int)r8;
		const uint32_t data_mac = r10 ? r10 : r9; /* tolerate swapped */
		const uint8_t *data = data_mac ? Mac2HostAddr(data_mac) : nullptr;
		if (!data) {
			glide_log("grTexDownloadMipMapLevel NO DATA start=%08x r9=%08x r10=%08x",
			          start, r9, r10);
			return 0;
		}
		const uint32_t n = GlideTexLevelSizeBytes(this_lod, aspect, format);
		/* For partial, still use full level size from start of guest buffer. */
		GlideGLTexDownloadLevel(start, this_lod, large_lod, aspect, format, data, n);
		return 0;
	}
	case kGlide_grTexDownloadTable:
	case kGlide_grTexDownloadTablePartial: {
		/* Glide2: grTexDownloadTable(type, data)
		 * Glide3: grTexDownloadTable(tmu, type, data)
		 * Log shows r3=2 (palette type) with data in r4 - Glide2 style. */
		int type = (int)r3;
		uint32_t data_mac = r4;
		if (r3 <= 1 && r4 <= 0x10) {
			/* Likely Glide3: tmu=r3 type=r4 data=r5 */
			type = (int)r4;
			data_mac = r5;
		}
		const void *data = data_mac ? Mac2HostAddr(data_mac) : nullptr;
		GlideGLTexDownloadTable(type, data);
		return 0;
	}
	case kGlide_grTexMultibase:
	case kGlide_grTexMultibaseAddress:
	case kGlide_grTexNCCTable:
		return 0;

	case kGlide_grGet:
		/* FxU32 grGet(FxU32 pname, FxU32 plength, FxI32 *params) */
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
			/* Wait/sync - often missing as PEF exports; offer via GetProcAddress. */
			{ "grSstVRetraceOn", kGlide_grSstVRetraceOn },
			{ "grSstVideoLine", kGlide_grSstVideoLine },
			{ "grSstIsBusy", kGlide_grSstIsBusy },
			{ "grSstIdle", kGlide_grSstIdle },
			{ "grSstStatus", kGlide_grSstStatus },
			{ "grBufferNumPending", kGlide_grBufferNumPending },
			{ "grFinish", kGlide_grFinish },
			{ "grFlush", kGlide_grFlush },
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
				 * illegal opcodes - execute_illegal now recovers via LR.
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
		/* void guGammaCorrectionRGB(float r, float g, float b);
		 * PPC Mac: floats in f1-f3 (we don't read FPRs here). No-op is fine -
		 * D2 calls this after the first menu BufferSwap; we must not hang. */
		glide_log("guGammaCorrectionRGB (no-op)");
		return 0;
	case kGlide_grReset:
		return 0;
	case kGlide_grEnable:
	case kGlide_grDisable:
		/* Combinatorial enable bits - state recorded via specific setters. */
		return 0;
	case kGlide_grCoordinateSystem:
		GlideStateSetCoordSystem((int)r3);
		return 0;
	case kGlide_grVertexLayout:
		/* void grVertexLayout(FxU32 param, FxI32 offset, FxU32 mode) */
		GlideStateSetVertexLayout((int)r3, (int)r4, (int)r5);
		glide_log("grVertexLayout param=0x%x off=%d mode=%u",
		          (unsigned)r3, (int)r4, r5);
		return 0;
	case kGlide_grDrawVertexArray: {
		/* void grDrawVertexArray(FxU32 mode, FxU32 count, void *pointers) */
		const uint32_t mode = r3;
		const uint32_t count = r4;
		const uint32_t ptrs_mac = r5;
		if (!count || !ptrs_mac || count > 65536u)
			return 0;
		static std::vector<const void *> host_ptrs;
		host_ptrs.resize(count);
		for (uint32_t i = 0; i < count; i++) {
			const uint32_t mac = ReadMacInt32(ptrs_mac + i * 4);
			host_ptrs[i] = mac ? Mac2HostAddr(mac) : nullptr;
		}
		GlideGLDrawVertexArray(mode, count, host_ptrs.data());
		GlideGLMarkContent();
		return 0;
	}
	case kGlide_grDrawVertexArrayContiguous: {
		/* void grDrawVertexArrayContiguous(FxU32 mode, FxU32 count,
		 *                                  void *vertices, FxU32 stride) */
		const uint32_t mode = r3;
		const uint32_t count = r4;
		const void *verts = r5 ? Mac2HostAddr(r5) : nullptr;
		const uint32_t stride = r6;
		if (verts && count && count <= 65536u) {
			GlideGLDrawVertexArrayContiguous(mode, count, verts, stride);
			GlideGLMarkContent();
		}
		return 0;
	}
	case kGlide_grGlideGetState:
	case kGlide_grGlideSetState:
	case kGlide_grGlideGetVertexLayout:
	case kGlide_grGlideSetVertexLayout:
		/* Opaque state blobs - accept without faulting. */
		return 0;
	case kGlide_grFinish:
	case kGlide_grFlush:
		GlideGLFinish();
		/* GPU idle: no outstanding swaps. */
		return 0;

	case kGlide_grLfbLock: {
		/* FxBool grLfbLock(GrLock_t type, GrBuffer_t buffer,
		 *   GrLfbWriteMode_t writeMode, GrOriginLocation_t origin,
		 *   FxBool pixelPipeline, GrLfbInfo_t *info);
		 * PPC: r3..r8. D2 log: type=1 (WRITE), buffer=0 (FRONT), writeMode=0 (565). */
		const int type = (int)r3;
		const int buffer = (int)r4;
		const int writeMode = (int)r5;
		const int origin = (int)r6;
		const uint32_t info = r8; /* 6th arg */
		(void)r7; /* pixelPipeline - ignore for software LFB */

		uint32_t lfbPtr = 0, stride = 0;
		int resolvedMode = writeMode;
		if (!info) {
			glide_log("grLfbLock FAIL info=NULL type=%d buf=%d mode=%d",
			          type, buffer, writeMode);
			return FXFALSE;
		}
		if (!GlideStateLfbLock(type, buffer, writeMode, origin,
		                       &lfbPtr, &stride, &resolvedMode)) {
			static uint32_t s_lfb_fail = 0;
			if (++s_lfb_fail <= 8)
				glide_log("grLfbLock FAIL type=%d buf=%d mode=%d locked=%d win=%d",
				          type, buffer, writeMode,
				          GlideStateLfbIsLocked() ? 1 : 0,
				          GlideStateWindowOpen() ? 1 : 0);
			return FXFALSE;
		}

		/* GrLfbInfo_t { int size; void *lfbPtr; FxU32 stride; mode; origin } */
		WriteMacInt32(info + 4, lfbPtr);
		WriteMacInt32(info + 8, stride);
		WriteMacInt32(info + 12, (uint32_t)resolvedMode);
		WriteMacInt32(info + 16, (uint32_t)origin);
		/* Leave size (info+0) as caller set it. */

		(void)dmc_set_active_owner(kDMCOwnerGlide);

		static uint32_t s_lfb_ok = 0;
		if (++s_lfb_ok <= 8 || (s_lfb_ok & (s_lfb_ok - 1)) == 0)
			glide_log("grLfbLock OK #%u type=%d buf=%d mode=%d ptr=%08x stride=%u",
			          (unsigned)s_lfb_ok, type, buffer, resolvedMode,
			          lfbPtr, stride);
		return FXTRUE;
	}
	case kGlide_grLfbUnlock: {
		/* FxBool grLfbUnlock(GrLock_t type, GrBuffer_t buffer) */
		const int type = (int)r3;
		const int buffer = (int)r4;
		const int was_write = (GlideStateLfbType() != 0) || (type != 0);
		if (!GlideStateLfbUnlock(buffer))
			return FXFALSE;

		/* On write unlock: convert 565/etc -> BGRA, upload overlay, present.
		 * Front-buffer locks present immediately; back-buffer also present
		 * so D2 soft-blit paths that skip BufferSwap still show pixels. */
		if (was_write) {
			int uw = 0, uh = 0, upitch = 0;
			const uint8_t *bgra = GlideStateLfbConvertToBGRA(&uw, &uh, &upitch);
			if (bgra)
				GlideGLUploadLfbAndPresent(bgra, uw, uh, upitch, /*present=*/1);
			(void)dmc_set_active_owner(kDMCOwnerGlide);
		}
		return FXTRUE;
	}
	case kGlide_grLfbReadRegion: {
		/* FxBool grLfbReadRegion(GrBuffer_t src_buffer, FxU32 src_x, src_y,
		 *   FxU32 src_width, src_height, FxU32 dst_stride, void *dst_data)
		 * r3=buf r4=x r5=y r6=w r7=h r8=stride r9=data (or stack9). */
		const int buf = (int)r3;
		const int x = (int)r4, y = (int)r5;
		const int w = (int)r6, h = (int)r7;
		const int stride = (int)r8;
		const uint32_t data_mac = r9 ? r9 : stack9;
		void *dst = data_mac ? Mac2HostAddr(data_mac) : nullptr;
		const bool ok = GlideStateLfbReadRegion(buf, x, y, w, h, stride, dst);
		glide_log("grLfbReadRegion %dx%d @%d,%d -> %s", w, h, x, y, ok ? "OK" : "FAIL");
		return ok ? FXTRUE : FXFALSE;
	}
	case kGlide_grLfbWriteRegion: {
		/* FxBool grLfbWriteRegion(dst_buffer, dst_x, dst_y, src_format,
		 *   src_width, src_height, pixelPipeline, src_stride, src_data)
		 * r3..r10 + stack9 = src_data when 9 args. */
		const int buf = (int)r3;
		const int x = (int)r4, y = (int)r5;
		const int fmt = (int)r6;
		const int w = (int)r7, h = (int)r8;
		/* r9 = pixelPipeline or stride; r10 = stride or data */
		int stride = (int)r10;
		uint32_t data_mac = stack9;
		if (!data_mac && r10 > 0x1000) {
			/* 8-arg form: r9=stride r10=data */
			stride = (int)r9;
			data_mac = r10;
		}
		const void *src = data_mac ? Mac2HostAddr(data_mac) : nullptr;
		const bool ok = GlideStateLfbWriteRegion(buf, x, y, fmt, w, h, stride, src);
		if (ok) {
			int uw = 0, uh = 0, upitch = 0;
			const uint8_t *bgra = GlideStateLfbConvertToBGRA(&uw, &uh, &upitch);
			if (bgra)
				GlideGLUploadLfbAndPresent(bgra, uw, uh, upitch, 1);
			GlideGLMarkContent();
		}
		glide_log("grLfbWriteRegion %dx%d @%d,%d fmt=%d -> %s",
		          w, h, x, y, fmt, ok ? "OK" : "FAIL");
		return ok ? FXTRUE : FXFALSE;
	}
	case kGlide_grLfbConstantAlpha:
		GlideStateSetLfbConstAlpha(r3);
		return FXTRUE;
	case kGlide_grLfbConstantDepth:
		GlideStateSetLfbConstDepth(r3);
		return FXTRUE;
	case kGlide_grLfbWriteColorFormat:
		GlideStateSetLfbWriteColorFormat((int)r3);
		return FXTRUE;
	case kGlide_grLfbWriteColorSwizzle:
		GlideStateSetLfbWriteColorSwizzle((int)r3);
		return FXTRUE;

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
