/*
 *  glide_gl_renderer.cpp - 3dfx Glide raster path on desktop OpenGL
 *
 *  Renders into a double-buffered overlay texture (same compositor contract
 *  as RAVE) and publishes via MetalCompositorSubmitFrame each buffer swap.
 * 
 * (C) 2026 RandoOnSteam (battlemageloveryt@gmail.com)
 */

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "glide_engine.h"
#include "metal_compositor.h"
#include "metal_device_shared.h"
#include "display_mode_controller.h"
#include "gfxaccel_resources.h"
#include "gfxaccel_backend.h"
#include "gfx_frame_pacing_policy.h"
#include "gfx_log.h"

#include <SDL_opengl.h>
#include "gl_ext.h"

#include <cstring>
#include <vector>
#include <cmath>

/* Classic GrVertex layout (Glide 2 / common packed layout). Glide 3 may
 * override field offsets via grVertexLayout; we still accept the classic
 * structure when layout offsets match. */
struct GrVertexClassic {
	float x, y, z;           /* 0 */
	float r, g, b;           /* 12 */
	float ooz;               /* 24 */
	float a;                 /* 28 */
	float s, t, w;           /* 32 - simplified */
};

/* Double-buffered overlay. Glide draws directly into glide_color_tex
 * (glide_overlay_pair[0]); the compositor samples the SEPARATE front texture
 * glide_front_tex (glide_overlay_pair[1]). The front is only refreshed from a
 * COMPLETE frame at grBufferSwap / LFB-present, so the free-run VBL present can
 * never composite a half-drawn or freshly-cleared (black) draw buffer - which
 * was the source of the black-screen flashes. The draw buffer persists between
 * frames so incremental (non-full-clear) rendering still accumulates. */
static GLuint glide_overlay_pair[2] = {0, 0};
static GLuint glide_color_tex = 0;   /* draw target (pair[0]) */
static GLuint glide_front_tex = 0;   /* compositor-sampled front (pair[1]) */
static GLuint glide_fbo = 0;
static GLuint glide_depth_rb = 0;
static uint32_t glide_width = 0, glide_height = 0;
static uint32_t glide_write = 0;
static bool glide_is_ready = false;
static bool glide_is_in_frame = false;
static bool glide_has_context = false;
/* Set once a complete frame has been copied into glide_front_tex. Until then
 * there is nothing safe to present, so the overlay submit is suppressed. */
static bool glide_front_valid = false;

static GLuint glide_gl_texture = 0;
static float glide_texture_s_extent = 256.f;
static float glide_texture_t_extent = 256.f;
static bool glide_is_texture_enabled = false;

struct GlideMetalTextureCacheEntry {
	uint32_t address;
	int width;
	int height;
	int format;
	int chroma_mode;
	uint32_t chroma_value;
	int color_format;
	GLuint texture;
	bool dirty;
	GLint wrap_s;
	GLint wrap_t;
	GLint filter;
};

/* Diablo II switches among hundreds of resident TMU addresses per frame.
 * A single host texture forced a CPU decode + glTexSubImage for every
 * grTexSource, even when the guest had not changed that address.
 * FIXME: Awful idea for a global texture cache.
 */
static std::vector<GlideMetalTextureCacheEntry> glide_texture_cache;

static void GlideSubitOverlay(int do_present);

static void GlideReleaseTextureCache(void)
{
	if (SharedMetalDevice()) {
		for (const GlideMetalTextureCacheEntry &entry : glide_texture_cache) {
			if (entry.texture)
				glDeleteTextures(1, &entry.texture);
		}
	}
	glide_texture_cache.clear();
	glide_gl_texture = 0;
	glide_texture_s_extent = glide_texture_t_extent = 256.f;
	glide_is_texture_enabled = false;
}

/* The SDL compositor and Glide use the same compatibility context.  A VBL
 * Present must not bind framebuffer 0 or replace Glide state between two
 * guest draw calls in the same back-buffer frame.
 */
extern "C" int GlideMetalRenderPassActive(void)
{
	return glide_is_in_frame ? 1 : 0;
}

extern int GlideStateDepthMode(void);
extern int GlideStateDepthMask(void);
extern int GlideStateDepthFunc(void);
extern float GlideStateDepthBias(void);
extern int GlideStateCullMode(void);
extern int GlideStateAlphaBlendSrc(void);
extern int GlideStateAlphaBlendDst(void);
extern int GlideStateColorFormat(void);
extern float GlideStateConstantR(void);
extern float GlideStateConstantG(void);
extern float GlideStateConstantB(void);
extern float GlideStateConstantA(void);
extern int GlideStateColorCombineFunction(void);
extern int GlideStateColorCombineFactor(void);
extern int GlideStateColorCombineLocal(void);
extern int GlideStateColorCombineOther(void);
extern int GlideStateColorCombineInvert(void);
extern int GlideStateAlphaCombineFunction(void);
extern int GlideStateAlphaCombineLocal(void);
extern int GlideStateAlphaCombineInvert(void);
extern int GlideStateCoordSystem(void);
extern int GlideStateVertexOffset(int param);
extern int GlideStateVertexStride(void);
extern int GlideStateOriginUpperLeft(void);
extern int GlideStateColorMaskR(void);
extern int GlideStateColorMaskG(void);
extern int GlideStateColorMaskB(void);
extern int GlideStateColorMaskA(void);
extern int GlideStateAlphaTestEnabled(void);
extern int GlideStateAlphaTestFunc(void);
extern float GlideStateAlphaTestRef(void);
extern int GlideStateClipMinX(void);
extern int GlideStateClipMinY(void);
extern int GlideStateClipMaxX(void);
extern int GlideStateClipMaxY(void);
extern int GlideStateChromaMode(void);
extern uint32_t GlideStateChromaValue(void);
extern int GlideStateFogMode(void);
extern uint32_t GlideStateFogColor(void);
extern const uint8_t *GlideStateTmuPtr(uint32_t start, uint32_t *out_avail);
extern bool GlideStateTmuWrite(uint32_t start, const void *src, uint32_t nbytes);
extern void GlideTexLodDims(int lod, int aspect_log2, int *out_w, int *out_h);
extern int GlideTexBpp(int format);
extern uint32_t GlideTexLevelSizeBytes(int lod, int aspect_log2, int format);
extern const uint32_t *GlideStateTexPalette(void);
extern int GlideStateTexClampS(void);
extern int GlideStateTexClampT(void);
extern int GlideStateTexFilterMin(void);
extern int GlideStateTexFilterMag(void);

static void GlideReleaseOverlay(void)
{
	if (!SharedMetalDevice()) {
		glide_overlay_pair[0] = glide_overlay_pair[1] = 0;
		glide_color_tex = 0;
		glide_front_tex = 0;
		glide_front_valid = false;
		glide_width = glide_height = 0;
		return;
	}
	auto &ext = gfx_gl_ext();
	if (ext.fbo && glide_fbo) {
		ext.BindFramebuffer(GL_FRAMEBUFFER, 0);
		ext.DeleteFramebuffers(1, &glide_fbo);
		glide_fbo = 0;
	}
	if (ext.fbo && glide_depth_rb) {
		ext.DeleteRenderbuffers(1, &glide_depth_rb);
		glide_depth_rb = 0;
	}
	for (int i = 0; i < 2; i++) {
		if (glide_overlay_pair[i]) {
			gfxaccel_resources_release_overlay_texture(
				kGfxEngineGlide, (void *)(uintptr_t)glide_overlay_pair[i]);
			glide_overlay_pair[i] = 0;
		}
	}
	glide_color_tex = 0;
	glide_front_tex = 0;
	glide_front_valid = false;
	glide_width = glide_height = 0;
	glide_has_context = false;
	MetalCompositorSubmitFrame_ClearCachedOverlay();
}

/* Publish the completed draw buffer to the front (compositor-sampled) texture.
 * Copies the whole draw color texture via the draw FBO so the front always
 * holds a COMPLETE frame - never a half-drawn or freshly-cleared draw buffer.
 * Must be called with a valid overlay + FBO; leaves GL bound to framebuffer 0. */
static void GlidePublishFrontFromDraw(void)
{
	if (!glide_fbo || !glide_color_tex || !glide_front_tex ||
		!SharedMetalDevice())
		return;
	auto &ext = gfx_gl_ext();
	if (!ext.fbo)
		return;
	/* Read from the draw color texture via the FBO; copy into the front tex. */
	ext.BindFramebuffer(GL_FRAMEBUFFER, glide_fbo);
	ext.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
							 GL_TEXTURE_2D, glide_color_tex, 0);
	glBindTexture(GL_TEXTURE_2D, glide_front_tex);
	/* glCopyTexSubImage2D is core GL 1.1 - copies the bound read framebuffer's
	 * color into the bound texture. Front and draw are the same size. */
	glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0,
						(GLsizei)glide_width, (GLsizei)glide_height);
	glBindTexture(GL_TEXTURE_2D, 0);
	ext.BindFramebuffer(GL_FRAMEBUFFER, 0);
	glide_front_valid = true;
}

static bool GlideEnsureOverlay(uint32_t w, uint32_t h)
{
	if (!SharedMetalDevice()) return false;
	if (glide_overlay_pair[0] && glide_overlay_pair[1] && glide_width == w && glide_height == h)
		return true;
	GlideReleaseOverlay();

	void *a = gfxaccel_resources_vend_overlay_texture_indexed(
		kGfxEngineGlide, 0, w, h, MTLPixelFormatBGRA8Unorm);
	void *b = gfxaccel_resources_vend_overlay_texture_indexed(
		kGfxEngineGlide, 1, w, h, MTLPixelFormatBGRA8Unorm);
	if (!a || !b) {
		if (a) gfxaccel_resources_release_overlay_texture(kGfxEngineGlide, a);
		if (b) gfxaccel_resources_release_overlay_texture(kGfxEngineGlide, b);
		QD3D_INIT_LOG("GlideMetal: overlay vend failed %ux%u", w, h);
		return false;
	}
	glide_overlay_pair[0] = (GLuint)(uintptr_t)a;
	glide_overlay_pair[1] = (GLuint)(uintptr_t)b;
	glide_write = 0;
	glide_color_tex = glide_overlay_pair[0];   /* draw target */
	glide_front_tex = glide_overlay_pair[1];   /* compositor-sampled front */
	glide_front_valid = false;
	glide_width = w;
	glide_height = h;

	auto &ext = gfx_gl_ext();
	if (!ext.fbo) {
		QD3D_INIT_LOG("GlideMetal: FBO extension missing");
		GlideReleaseOverlay();
		return false;
	}
	ext.GenFramebuffers(1, &glide_fbo);
	ext.GenRenderbuffers(1, &glide_depth_rb);
	ext.BindRenderbuffer(GL_RENDERBUFFER, glide_depth_rb);
	ext.RenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, (GLsizei)w, (GLsizei)h);
	ext.BindFramebuffer(GL_FRAMEBUFFER, glide_fbo);
	ext.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
							 GL_TEXTURE_2D, glide_color_tex, 0);
	ext.FramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
								GL_RENDERBUFFER, glide_depth_rb);
	GLenum st = ext.CheckFramebufferStatus(GL_FRAMEBUFFER);
	ext.BindFramebuffer(GL_FRAMEBUFFER, 0);
	if (st != GL_FRAMEBUFFER_COMPLETE) {
		QD3D_INIT_LOG("GlideMetal: FBO incomplete 0x%x", (unsigned)st);
		GlideReleaseOverlay();
		return false;
	}
	return true;
}

static bool GlideBindDrawFBO(void)
{
	if (!glide_fbo || !glide_color_tex || !SharedMetalDevice()) return false;
	auto &ext = gfx_gl_ext();
	ext.BindFramebuffer(GL_FRAMEBUFFER, glide_fbo);
	ext.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
							 GL_TEXTURE_2D, glide_color_tex, 0);
	glViewport(0, 0, (GLsizei)glide_width, (GLsizei)glide_height);
	glMatrixMode(GL_PROJECTION);
	glLoadIdentity();
	/* Glide window coords: x right, y down if origin upper-left. */
	if (GlideStateOriginUpperLeft())
		glOrtho(0.0, (double)glide_width, (double)glide_height, 0.0, -1.0, 1.0);
	else
		glOrtho(0.0, (double)glide_width, 0.0, (double)glide_height, -1.0, 1.0);
	glMatrixMode(GL_MODELVIEW);
	glLoadIdentity();
	glide_is_in_frame = true;
	return true;
}

static GLenum GlideMapBlendFactor(int gr, bool source_factor)
{
	/* Glide 3 GrAlphaBlendFnc_t values.  Color factors are relative to the
	 * opposite input: SRC_COLOR means destination color when used as the
	 * source factor, and source color when used as the destination factor. */
	switch (gr) {
	case 0x0: return GL_ZERO;
	case 0x1: return GL_SRC_ALPHA;
	case 0x2: return source_factor ? GL_DST_COLOR : GL_SRC_COLOR;
	case 0x3: return GL_DST_ALPHA;
	case 0x4: return GL_ONE;
	case 0x5: return GL_ONE_MINUS_SRC_ALPHA;
	case 0x6: return source_factor ? GL_ONE_MINUS_DST_COLOR
								   : GL_ONE_MINUS_SRC_COLOR;
	case 0x7: return GL_ONE_MINUS_DST_ALPHA;
	case 0xf: return source_factor ? GL_SRC_ALPHA_SATURATE : GL_ONE;
	default:  return GL_ONE;
	}
}

static GLenum GlideMapGLCmpFunc(int gr)
{
	/* GR_CMP_* */
	switch (gr) {
	case 0: return GL_NEVER;
	case 1: return GL_LESS;
	case 2: return GL_EQUAL;
	case 3: return GL_LEQUAL;
	case 4: return GL_GREATER;
	case 5: return GL_NOTEQUAL;
	case 6: return GL_GEQUAL;
	case 7: return GL_ALWAYS;
	default: return GL_LEQUAL;
	}
}

enum {
	kGlideCombineFunctionZero = 0,
	kGlideCombineFunctionLocal = 1,
	kGlideCombineFunctionLocalAlpha = 2,
	kGlideCombineFunctionScaleOther = 3,
	kGlideCombineFunctionScaleOtherAddLocal = 4,
	kGlideCombineFunctionScaleOtherAddLocalAlpha = 5,
	kGlideCombineFunctionScaleOtherMinusLocal = 6,
	kGlideCombineFunctionScaleOtherMinusLocalAddLocal = 7,
	kGlideCombineFunctionScaleOtherMinusLocalAddLocalAlpha = 8,
	kGlideCombineFactorLocal = 1,
	kGlideCombineFactorOne = 8,
	kGlideCombineLocalIterated = 0,
	kGlideCombineLocalConstant = 1,
	kGlideCombineOtherTexture = 1,
	kGlideWindowCoords = 0
};

static bool GlideColorCombineUsesTexture(void)
{
	if (GlideStateColorCombineOther() != kGlideCombineOtherTexture)
		return false;
	switch (GlideStateColorCombineFunction()) {
	case kGlideCombineFunctionScaleOther:
	case kGlideCombineFunctionScaleOtherAddLocal:
	case kGlideCombineFunctionScaleOtherAddLocalAlpha:
	case kGlideCombineFunctionScaleOtherMinusLocal:
	case kGlideCombineFunctionScaleOtherMinusLocalAddLocal:
	case kGlideCombineFunctionScaleOtherMinusLocalAddLocalAlpha:
		return true;
	default:
		return false;
	}
}

void GlideMetalApplyState(void)
{
	if (!SharedMetalDevice()) return;
	const int cull = GlideStateCullMode();
	if (cull == 0) {
		glDisable(GL_CULL_FACE);
	} else {
		glEnable(GL_CULL_FACE);
		glCullFace(cull == 1 ? GL_FRONT : GL_BACK);
	}
	if (GlideStateDepthMode() != 0) {
		glEnable(GL_DEPTH_TEST);
		glDepthFunc(GlideMapGLCmpFunc(GlideStateDepthFunc() ? GlideStateDepthFunc() : 3));
		glDepthMask(GlideStateDepthMask() ? GL_TRUE : GL_FALSE);
		const float bias = GlideStateDepthBias();
		if (bias != 0.f) {
			glEnable(GL_POLYGON_OFFSET_FILL);
			glPolygonOffset(bias, bias);
		} else {
			glDisable(GL_POLYGON_OFFSET_FILL);
		}
	} else {
		glDisable(GL_DEPTH_TEST);
		glDisable(GL_POLYGON_OFFSET_FILL);
	}
	glEnable(GL_BLEND);
	glBlendFunc(GlideMapBlendFactor(GlideStateAlphaBlendSrc(), true),
				GlideMapBlendFactor(GlideStateAlphaBlendDst(), false));
	if (glide_is_texture_enabled && glide_gl_texture &&
		GlideColorCombineUsesTexture()) {
		glEnable(GL_TEXTURE_2D);
		glBindTexture(GL_TEXTURE_2D, glide_gl_texture);
		glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);
	} else {
		glDisable(GL_TEXTURE_2D);
	}
	if (GlideStateChromaMode()) {
		/* Chroma-keyed texels are decoded with alpha zero; reject them before
		 * blending/depth writes, matching the Glide chroma test. */
		glEnable(GL_ALPHA_TEST);
		glAlphaFunc(GL_GREATER, 0.f);
	} else if (GlideStateAlphaTestEnabled()) {
		glEnable(GL_ALPHA_TEST);
		glAlphaFunc(GlideMapGLCmpFunc(GlideStateAlphaTestFunc()),
					GlideStateAlphaTestRef());
	} else {
		glDisable(GL_ALPHA_TEST);
	}
	glColorMask(GlideStateColorMaskR() ? GL_TRUE : GL_FALSE,
				GlideStateColorMaskG() ? GL_TRUE : GL_FALSE,
				GlideStateColorMaskB() ? GL_TRUE : GL_FALSE,
				GlideStateColorMaskA() ? GL_TRUE : GL_FALSE);
	/* Clip window -> scissor in window coords (origin upper-left). */
	{
		const int minx = GlideStateClipMinX();
		const int miny = GlideStateClipMinY();
		const int maxx = GlideStateClipMaxX();
		const int maxy = GlideStateClipMaxY();
		const int w = maxx - minx;
		const int h = maxy - miny;
		if (w > 0 && h > 0 && (minx > 0 || miny > 0 ||
			maxx < (int)glide_width || maxy < (int)glide_height)) {
			glEnable(GL_SCISSOR_TEST);
			/* GL scissor origin is lower-left if we use raw GL without flip;
			 * our FBO ortho is upper-left y-down, but scissor is still bottom-left
			 * in window coordinates of the FBO. Convert. */
			const int gl_y = (int)glide_height - miny - h;
			glScissor(minx, gl_y > 0 ? gl_y : 0, w, h);
		} else {
			glDisable(GL_SCISSOR_TEST);
		}
	}
	if (GlideStateFogMode() != 0) {
		glEnable(GL_FOG);
		glFogi(GL_FOG_MODE, GL_LINEAR);
		const uint32_t fc = GlideStateFogColor();
		const float col[4] = {
			((fc >> 16) & 0xff) / 255.f,
			((fc >> 8) & 0xff) / 255.f,
			(fc & 0xff) / 255.f,
			1.f
		};
		glFogfv(GL_FOG_COLOR, col);
	} else {
		glDisable(GL_FOG);
	}
	glDisable(GL_LIGHTING);
}

void GlideMetalSetClipWindow(int minx, int miny, int maxx, int maxy)
{
	/* State already stored; re-apply if in frame. */
	(void)minx; (void)miny; (void)maxx; (void)maxy;
	if (glide_is_in_frame) GlideMetalApplyState();
}

void GlideMetalSetColorMask(int r, int g, int b, int a)
{
	if (!SharedMetalDevice()) return;
	glColorMask(r ? GL_TRUE : GL_FALSE, g ? GL_TRUE : GL_FALSE,
				b ? GL_TRUE : GL_FALSE, a ? GL_TRUE : GL_FALSE);
}

void GlideMetalSetAlphaTest(int enabled, int func, float ref)
{
	if (!SharedMetalDevice()) return;
	if (GlideStateChromaMode()) {
		glEnable(GL_ALPHA_TEST);
		glAlphaFunc(GL_GREATER, 0.f);
	} else if (enabled) {
		glEnable(GL_ALPHA_TEST);
		glAlphaFunc(GlideMapGLCmpFunc(func), ref);
	} else {
		glDisable(GL_ALPHA_TEST);
	}
}

void GlideMetalSetFog(int mode, uint32_t color)
{
	(void)mode; (void)color;
	if (glide_is_in_frame) GlideMetalApplyState();
}

void GlideMetalSetDepthBias(float bias)
{
	(void)bias;
	if (glide_is_in_frame) GlideMetalApplyState();
}

void GlideMetalSplash(void)
{
	/* Classic Glide splash - solid color flash so titles that call it
	 * get a visible frame rather than a silent no-op. */
	if (!GlideBindDrawFBO()) return;
	glClearColor(0.1f, 0.15f, 0.35f, 1.f);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	glide_has_context = true;
	/* Splash is a one-shot visible frame - Present is intentional. */
	GlideSubitOverlay(/*do_present=*/1);
}

void GlideMetalFinish(void)
{
	if (SharedMetalDevice())
		glFlush();
}

int GlideMetalInit(void)
{
	glide_is_ready = SharedMetalDevice() != nullptr;
	QD3D_INIT_LOG("GlideMetalInit: ready=%d", glide_is_ready ? 1 : 0);
	return glide_is_ready ? 0 : -1;
}

void GlideMetalShutdown(void)
{
	if (SharedMetalDevice()) {
		GlideReleaseTextureCache();
		GlideReleaseOverlay();
	} else {
		glide_texture_cache.clear();
	}
	glide_is_ready = false;
	glide_is_in_frame = false;
}

/* Drive DMC to whatever resolution this WinOpen requested. Glide titles
 * (D2 included) legitimately switch 640x480 <-> 800x600 (and others) for
 * movies vs menus vs gameplay - never assume a fixed "intro" size. */
static void GlideSyncDMCToWindow(int width, int height)
{
	if (width <= 0 || height <= 0)
		return;

	/* Claim Glide first so dmc_request_mode_switch preserves us as owner
	 * (otherwise a prior DSp owner sticks across the mode change). */
	(void)dmc_set_active_owner(kDMCOwnerGlide);

	const DMCModeSnapshot *snap = dmc_current_snapshot();
	if (snap && (int)snap->width == width && (int)snap->height == height) {
		return;
	}

	DMCModeDesc mode = {};
	mode.width = (uint32_t)width;
	mode.height = (uint32_t)height;
	/* bpp for DMC validation is {1,2,4,8,16,32}. 16 matches native LFB. */
	mode.depth = 16;
	mode.row_bytes = (uint32_t)width * 2u;
	mode.pitch = mode.row_bytes;
	mode.vbl_usec = 0;
	mode.screen_base_mac = 0;
	mode.screen_base_host = nullptr;

	int32_t rc = dmc_request_mode_switch(&mode);
	if (rc != kDMCNoErr) {
		mode.depth = 32;
		mode.row_bytes = (uint32_t)width * 4u;
		mode.pitch = mode.row_bytes;
		rc = dmc_request_mode_switch(&mode);
	}
	if (rc != kDMCNoErr) {
		QD3D_INIT_LOG("GlideMetalWinOpen: DMC mode switch %dx%d failed rc=%d",
					  width, height, (int)rc);
	} else {
		QD3D_INIT_LOG("GlideMetalWinOpen: DMC mode -> %dx%d (from grSstWinOpen)",
					  width, height);
	}
	/* Mode switch can leave owner sticky; reassert. */
	(void)dmc_set_active_owner(kDMCOwnerGlide);
}

int GlideMetalWinOpen(int width, int height, int origin_upper_left)
{
	(void)origin_upper_left;
	if (width <= 0 || height <= 0) return -1;
	if (!SharedMetalDevice()) {
		if (GlideMetalInit() != 0) return -1;
	}
	if (!GlideEnsureOverlay((uint32_t)width, (uint32_t)height))
		return -1;
	if (!GlideBindDrawFBO())
		return -1;
	glClearColor(0.f, 0.f, 0.f, 1.f);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	auto &ext = gfx_gl_ext();
	ext.BindFramebuffer(GL_FRAMEBUFFER, 0);
	glide_is_in_frame = false;
	glide_has_context = false;

	/* Match host display mode to THIS open (movies 640, menu 800, &). */
	GlideSyncDMCToWindow(width, height);
	/* Show the cleared Glide buffer immediately (black), owned by Glide -
	 * leaving DSp underlay with a missing CLUT produced a solid WHITE
	 * screen. Movies then overwrite via LFB; menu draws via LFB/GL.
	 * One Present on open is intentional (mode switch); later swaps/clears
	 * only SubmitFrame and let free-run VideoVBL Present. */
	glide_has_context = true;
	GlideSubitOverlay(/*do_present=*/1);

	QD3D_INIT_LOG("GlideMetalWinOpen: %dx%d overlay=%u (clear present; free-run VBL)",
				  width, height, (unsigned)glide_color_tex);
	return 0;
}

void GlideMetalWinClose(void)
{
	if (SharedMetalDevice())
		GlideReleaseOverlay();
	glide_is_in_frame = false;
	glide_has_context = false;
}

/* Host-endian float load from guest big-endian PPC memory. */
static float GlideLoadF32(const uint8_t *p)
{
	union { uint32_t u; float f; } v;
	v.u = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
		  ((uint32_t)p[2] << 8) | (uint32_t)p[3];
	return v.f;
}

static uint32_t GlideLoadU32(const uint8_t *p)
{
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
		   ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static int GlideLayoutOff(int standard_param, int d2_alias)
{
	int o = GlideStateVertexOffset(standard_param);
	if (o >= 0) return o;
	if (d2_alias >= 0)
		return GlideStateVertexOffset(d2_alias);
	return -1;
}

static void GlideEmitVertex(const uint8_t *base)
{
	/* Defaults: classic GrVertex. */
	float x = GlideLoadF32(base + 0);
	float y = GlideLoadF32(base + 4);
	float r = 1.f, g = 1.f, b = 1.f, a = 1.f;

	/* Official GR_PARAM_XY=1. */
	int xy_off = GlideLayoutOff(0x01, -1);
	if (xy_off >= 0) {
		x = GlideLoadF32(base + xy_off);
		y = GlideLoadF32(base + xy_off + 4);
	}

	/* Glide 3 layout tokens are grouped by attribute: RGB=0x20,
	 * PARGB=0x30.  Keep the small Glide-2-compatible IDs as fallbacks.
	 * In particular, 0x50 is Q0 -- treating it as PARGB converts the bits of
	 * reciprocal-W into an almost-black vertex color. */
	int rgb_off = GlideLayoutOff(0x20, 0x07);
	int pargb_off = GlideLayoutOff(0x30, 0x08);
	if (rgb_off >= 0) {
		r = GlideLoadF32(base + rgb_off);
		g = GlideLoadF32(base + rgb_off + 4);
		b = GlideLoadF32(base + rgb_off + 8);
	} else if (pargb_off >= 0) {
		const uint32_t c = GlideLoadU32(base + pargb_off);
		a = ((c >> 24) & 0xff) / 255.f;
		r = ((c >> 16) & 0xff) / 255.f;
		g = ((c >> 8) & 0xff) / 255.f;
		b = (c & 0xff) / 255.f;
	}

	int a_off = GlideLayoutOff(0x10, 0x06);
	if (a_off >= 0 && pargb_off < 0)
		a = GlideLoadF32(base + a_off);

	if (r > 1.f || g > 1.f || b > 1.f) {
		r /= 255.f; g /= 255.f; b /= 255.f;
	}
	if (a > 1.f) a /= 255.f;

	const float iterated_r = r;
	const float iterated_g = g;
	const float iterated_b = b;
	const float iterated_a = a;
	auto select_local_rgb = [&](int local) {
		if (local == kGlideCombineLocalConstant) {
			r = GlideStateConstantR();
			g = GlideStateConstantG();
			b = GlideStateConstantB();
		} else if (local == kGlideCombineLocalIterated) {
			r = iterated_r;
			g = iterated_g;
			b = iterated_b;
		} else {
			r = g = b = 0.f;
		}
	};

	/* Implement the two color-combine paths used by Diablo II:
	 *   LOCAL                         -> solid iterated/constant color
	 *   SCALE_OTHER(texture, LOCAL)  -> texture modulated by local color
	 * SCALE_OTHER(texture, ONE) uses a white modulation color. */
	const int color_func = GlideStateColorCombineFunction();
	if (color_func == kGlideCombineFunctionZero) {
		r = g = b = 0.f;
	} else if (color_func == kGlideCombineFunctionLocal) {
		select_local_rgb(GlideStateColorCombineLocal());
	} else if (color_func == kGlideCombineFunctionLocalAlpha) {
		const float local_a = GlideStateColorCombineLocal() ==
			kGlideCombineLocalConstant ? GlideStateConstantA() : iterated_a;
		r = g = b = local_a;
	} else if (GlideColorCombineUsesTexture()) {
		if (GlideStateColorCombineFactor() == kGlideCombineFactorOne) {
			r = g = b = 1.f;
		} else {
			select_local_rgb(GlideStateColorCombineLocal());
		}
	}

	if (GlideStateColorCombineInvert() && !GlideColorCombineUsesTexture()) {
		r = 1.f - r;
		g = 1.f - g;
		b = 1.f - b;
	}

	/* Preserve texture alpha as a chroma discard mask. Chroma-keying happens
	 * before Glide's alpha combine stage, so a ZERO alpha combine must not
	 * erase that mask in the fixed-function emulation. */
	const int alpha_func = GlideStateAlphaCombineFunction();
	if (alpha_func == kGlideCombineFunctionZero) {
		a = GlideStateChromaMode() && GlideColorCombineUsesTexture() ? 1.f : 0.f;
	} else if (alpha_func == kGlideCombineFunctionLocal) {
		a = GlideStateAlphaCombineLocal() == kGlideCombineLocalConstant
			? GlideStateConstantA() : iterated_a;
	} else {
		a = iterated_a;
	}
	if (GlideStateAlphaCombineInvert() &&
		!(GlideStateChromaMode() && GlideColorCombineUsesTexture()))
		a = 1.f - a;

	/* ST0 contains s/q,t/q in Glide texel units and Q0 contains q.  OpenGL's
	 * projective coordinate division happens after interpolation. Window
	 * coordinates use a virtual 256-unit long axis regardless of mip size;
	 * clip coordinates are already normalized to [0,1]. */
	int st_off = GlideLayoutOff(0x40, 0x09);
	if (st_off >= 0) {
		const float s = GlideLoadF32(base + st_off);
		const float t = GlideLoadF32(base + st_off + 4);
		const int q_off = GlideLayoutOff(0x50, 0x04);
		float q = q_off >= 0 ? GlideLoadF32(base + q_off) : 1.f;
		if (!std::isfinite(q) || std::fabs(q) < 1.0e-20f)
			q = 1.f;
		if (GlideStateCoordSystem() == kGlideWindowCoords) {
			glTexCoord4f(s / glide_texture_s_extent,
						 t / glide_texture_t_extent, 0.f, q);
		} else {
			glTexCoord4f(s, t, 0.f, q);
		}
	}

	glColor4f(r, g, b, a);
	glVertex3f(x, y, 0.f);
}

static GLenum GlideMapGlideToGLPrim(uint32_t mode)
{
	/* GrPrimitive_t */
	switch (mode) {
	case 0: return GL_POINTS;
	case 1: return GL_LINE_STRIP;
	case 2: return GL_LINES;
	case 3: return GL_POLYGON;
	case 4: return GL_TRIANGLE_STRIP;
	case 5: return GL_TRIANGLE_FAN;
	case 6: return GL_TRIANGLES;
	case 7: return GL_TRIANGLE_STRIP; /* CONTINUE */
	case 8: return GL_TRIANGLE_FAN;
	default: return GL_TRIANGLES;
	}
}

void GlideMetalDrawPoint(const void *a)
{
	if (!a) return;
	if (!GlideBindDrawFBO()) return;
	GlideMetalApplyState();
	glBegin(GL_POINTS);
	GlideEmitVertex((const uint8_t *)a);
	glEnd();
	glide_has_context = true;
}

void GlideMetalDrawLine(const void *a, const void *b)
{
	if (!a || !b) return;
	if (!GlideBindDrawFBO()) return;
	GlideMetalApplyState();
	glBegin(GL_LINES);
	GlideEmitVertex((const uint8_t *)a);
	GlideEmitVertex((const uint8_t *)b);
	glEnd();
	glide_has_context = true;
}

void GlideMetalDrawTriangle(const void *a, const void *b, const void *c)
{
	if (!a || !b || !c) return;
	if (!GlideBindDrawFBO()) return;
	GlideMetalApplyState();
	glBegin(GL_TRIANGLES);
	GlideEmitVertex((const uint8_t *)a);
	GlideEmitVertex((const uint8_t *)b);
	GlideEmitVertex((const uint8_t *)c);
	glEnd();
	glide_has_context = true;
}

void GlideMetalDrawPolygon(int nverts, const void *const *ptrs)
{
	if (!ptrs || nverts < 3) return;
	if (!GlideBindDrawFBO()) return;
	GlideMetalApplyState();
	glBegin(GL_TRIANGLE_FAN);
	for (int i = 0; i < nverts; i++) {
		if (ptrs[i])
			GlideEmitVertex((const uint8_t *)ptrs[i]);
	}
	glEnd();
	glide_has_context = true;
}

void GlideMetalDrawPolygonContiguous(int nverts, const void *verts, uint32_t stride)
{
	if (!verts || nverts < 3) return;
	if (!GlideBindDrawFBO()) return;
	if (stride == 0) stride = (uint32_t)GlideStateVertexStride();
	if (stride < 8) stride = 8;
	GlideMetalApplyState();
	const uint8_t *base = (const uint8_t *)verts;
	glBegin(GL_TRIANGLE_FAN);
	for (int i = 0; i < nverts; i++)
		GlideEmitVertex(base + (size_t)i * stride);
	glEnd();
	glide_has_context = true;
}

void GlideMetalDrawVertexArray(uint32_t mode, uint32_t count, const void *const *ptrs)
{
	if (!ptrs || count == 0) return;
	if (!GlideBindDrawFBO()) return;
	GlideMetalApplyState();
	glBegin(GlideMapGlideToGLPrim(mode));
	for (uint32_t i = 0; i < count; i++) {
		if (ptrs[i])
			GlideEmitVertex((const uint8_t *)ptrs[i]);
	}
	glEnd();
	glide_has_context = true;
}

void GlideMetalDrawVertexArrayContiguous(uint32_t mode, uint32_t count,
									  const void *vertices, uint32_t stride)
{
	if (!vertices || count == 0) return;
	if (!GlideBindDrawFBO()) return;
	if (stride == 0)
		stride = (uint32_t)GlideStateVertexStride();
	if (stride < 8) stride = 8;
	GlideMetalApplyState();
	const uint8_t *base = (const uint8_t *)vertices;
	glBegin(GlideMapGlideToGLPrim(mode));
	for (uint32_t i = 0; i < count; i++)
		GlideEmitVertex(base + (size_t)i * stride);
	glEnd();
	glide_has_context = true;
}

/*
 * Publish the Glide color buffer into the compositor overlay mailbox.
 * do_present=0: SubmitFrame only - VideoVBL/free-run owns Present so we
 * never nest guest VBL (call_macos) inside NATIVE_GLIDE_DISPATCH.
 * do_present=1: also Present (WinOpen first black frame, LFB unlock).
 */
static void GlideSubitOverlay(int do_present)
{
	if (!glide_color_tex || !SharedMetalDevice()) return;
	/* Never push an empty/clear-only frame as opaque overlay. */
	if (!glide_has_context) {
		MetalCompositorSubmitFrame_ClearCachedOverlay();
		if (do_present)
			MetalCompositorPresent(); /* VBL chain only */
		return;
	}

	/* Every GlideSubitOverlay call sits at a frame boundary (WinOpen clear,
	 * grBufferSwap, LFB unlock/present, splash), so the draw buffer now holds
	 * a COMPLETE frame. Copy it to the front texture and present from THAT, so
	 * the free-run VBL present never samples a half-drawn or freshly-cleared
	 * (black) draw buffer between the clear and the draw calls. */
	GlidePublishFrontFromDraw();
	if (!glide_front_valid) {
		/* Copy could not run (missing FBO); fall back to the draw texture. */
		glide_front_tex = glide_color_tex;
		glide_front_valid = true;
	}

	const DMCModeSnapshot *snap = dmc_current_snapshot();
	float dst_w = (float)glide_width;
	float dst_h = (float)glide_height;
	if (snap && snap->width > 0 && snap->height > 0 &&
		(snap->width != glide_width || snap->height != glide_height)) {
		dst_w = (float)snap->width;
		dst_h = (float)snap->height;
		static uint32_t s_mismatch_log = 0;
		if (s_mismatch_log++ < 8)
			QD3D_INIT_LOG("Glide submit: DMC %ux%u != glide %ux%u - fill-scale fallback",
						  snap->width, snap->height, glide_width, glide_height);
	}

	CompositeLayer layer = {};
	layer.source = (void *)(uintptr_t)glide_front_tex;
	layer.src_origin_x = 0;
	layer.src_origin_y = 0;
	layer.src_size_w = glide_width;
	layer.src_size_h = glide_height;
	layer.dst_origin_x = 0.f;
	layer.dst_origin_y = 0.f;
	layer.dst_size_w = dst_w;
	layer.dst_size_h = dst_h;
	layer.slot = kLayerSlotOverlay;
	layer.blend = kBlendOpaque;
	layer.alpha = 1.f;

	(void)dmc_set_active_owner(kDMCOwnerGlide);
	FrameDescriptor desc = {};
	desc.layers = &layer;
	desc.layer_count = 1;
	desc.generation = snap ? snap->generation : 0;
	desc.vbl_tick_target_usec = 0;
	(void)MetalCompositorSubmitFrame(&desc);
	if (do_present)
		MetalCompositorPresent();
}

void GlideMetalPublishOverlay(int do_present)
{
	GlideSubitOverlay(do_present ? 1 : 0);
}

void GlideMetalBufferSwap(int swap_interval)
{
	if (!glide_color_tex || !SharedMetalDevice()) return;

	auto &ext = gfx_gl_ext();
	glFlush();
	if (ext.fbo)
		ext.BindFramebuffer(GL_FRAMEBUFFER, 0);
	glide_is_in_frame = false;

	/* grBufferSwap(1) blocks for the next retrace on real Glide hardware.
	 * Pending-count emulation cannot provide that contract on a single-threaded
	 * guest; pace the completed frame on the host deadline lane, then report the
	 * synchronous swap complete. Diablo II uses interval 1. */
	int intervals = swap_interval > 0 ? swap_interval : 0;
	if (intervals > 4) intervals = 4;
	for (int i = 0; i < intervals; i++) {
		(void)MetalCompositorSync3DFramePacingForEngine(
			kGfxFramePacingEngineGlide);
	}

	/*
	 * Real grBufferSwap makes the back buffer visible. Match the proven
	 * movie LFB path: SubmitFrame + Present here. free-run VIA still keeps
	 * Mac VBL timebase alive between swaps; it is not a substitute for the
	 * swap Present itself.
	 */
	GlideSubitOverlay(/*do_present=*/1);
}

void GlideMetalBufferClear(uint32_t color, uint32_t alpha, uint32_t depth)
{
	(void)depth;
	if (!GlideBindDrawFBO()) return;
	/* GrColor packing depends on color format; treat as ARGB8888 common case. */
	const float r = ((color >> 16) & 0xff) / 255.f;
	const float g = ((color >> 8) & 0xff) / 255.f;
	const float b = ((color >> 0) & 0xff) / 255.f;
	const float a = (alpha & 0xffu) / 255.f;
	glClearColor(r, g, b, a);
	glClearDepth(1.0);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	/*
	 * Real Glide only clears the back buffer. Display is grBufferSwap /
	 * LFB unlock. Mark content so the next swap is allowed to present.
	 */
	glide_has_context = true;
	{
		auto &ext = gfx_gl_ext();
		if (ext.fbo)
			ext.BindFramebuffer(GL_FRAMEBUFFER, 0);
		glide_is_in_frame = false;
	}
}

void GlideMetalMarkContent(void)
{
	glide_has_context = true;
}

void GlideMetalUploadLfbAndPresent(const uint8_t *bgra, int w, int h, int pitch,
								int present)
{
	if (!bgra || w <= 0 || h <= 0 || !glide_color_tex || !SharedMetalDevice())
		return;
	if ((uint32_t)w > glide_width) w = (int)glide_width;
	if ((uint32_t)h > glide_height) h = (int)glide_height;

	/* Upload into the current write color texture (BGRA8). Unbind FBO so
	 * the texture is not both attachment and upload target. */
	auto &ext = gfx_gl_ext();
	if (ext.fbo)
		ext.BindFramebuffer(GL_FRAMEBUFFER, 0);
	glide_is_in_frame = false;

	glBindTexture(GL_TEXTURE_2D, glide_color_tex);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
	if (pitch == w * 4) {
		glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, w, h,
						GL_BGRA, GL_UNSIGNED_BYTE, bgra);
	} else {
		/* Row-by-row if pitch differs (should not for our converter). */
		for (int y = 0; y < h; y++) {
			glTexSubImage2D(GL_TEXTURE_2D, 0, 0, y, w, 1,
							GL_BGRA, GL_UNSIGNED_BYTE,
							bgra + (size_t)y * (size_t)pitch);
		}
	}
	glBindTexture(GL_TEXTURE_2D, 0);
	glFlush();

	glide_has_context = true;
	/* LFB unlock path: Present so movies keep working without waiting VBL. */
	if (present)
		GlideSubitOverlay(/*do_present=*/1);
	else
		GlideSubitOverlay(/*do_present=*/0);
}

/* ---- Textures ---------------------------------------------------------- */

static void GlideUnpackChromaRGB(uint32_t color, int color_format,
									uint8_t *out_r, uint8_t *out_g,
									uint8_t *out_b)
{
	uint8_t r = 0, g = 0, b = 0;
	switch (color_format) {
	case GR_COLORFORMAT_ABGR:
		r = (uint8_t)(color & 0xffu);
		g = (uint8_t)((color >> 8) & 0xffu);
		b = (uint8_t)((color >> 16) & 0xffu);
		break;
	case GR_COLORFORMAT_RGBA:
		r = (uint8_t)((color >> 24) & 0xffu);
		g = (uint8_t)((color >> 16) & 0xffu);
		b = (uint8_t)((color >> 8) & 0xffu);
		break;
	case GR_COLORFORMAT_BGRA:
		b = (uint8_t)((color >> 24) & 0xffu);
		g = (uint8_t)((color >> 16) & 0xffu);
		r = (uint8_t)((color >> 8) & 0xffu);
		break;
	case GR_COLORFORMAT_ARGB:
	default:
		r = (uint8_t)((color >> 16) & 0xffu);
		g = (uint8_t)((color >> 8) & 0xffu);
		b = (uint8_t)(color & 0xffu);
		break;
	}
	*out_r = r;
	*out_g = g;
	*out_b = b;
}

static void GlideDecodeTextureLevel(const uint8_t *src, int w, int h, int format,
								   int chroma_mode, uint32_t chroma_value,
								   int color_format,
								   std::vector<uint8_t> &rgba)
{
	rgba.resize((size_t)w * (size_t)h * 4u);
	const uint32_t *pal = GlideStateTexPalette();
	const int bpp = GlideTexBpp(format);
	uint8_t chroma_r = 0, chroma_g = 0, chroma_b = 0;
	GlideUnpackChromaRGB(chroma_value, color_format,
							&chroma_r, &chroma_g, &chroma_b);
	uint8_t *d = rgba.data();
	const uint8_t *s = src;
	for (int i = 0; i < w * h; i++) {
		uint8_t R = 255, G = 255, B = 255, A = 255;
		if (bpp == 1) {
			const uint8_t p = *s++;
			if (format == 0x05 || format == 0x08) {
				/* P_8 expands a palette RGB value with opaque alpha. The
				 * standard palette word's high byte is not texture alpha. */
				const uint32_t c = pal ? pal[p] : 0xffffffffu;
				A = 255;
				R = (uint8_t)((c >> 16) & 0xff);
				G = (uint8_t)((c >> 8) & 0xff);
				B = (uint8_t)(c & 0xff);
			} else {
				/* intensity / alpha-ish */
				R = G = B = p;
				A = 255;
			}
		} else if (bpp == 2) {
			/* Guest big-endian 16-bit */
			const uint16_t p = (uint16_t)((s[0] << 8) | s[1]);
			s += 2;
			if (format == 0x0a) {
				/* RGB_565 */
				const int r = (p >> 11) & 0x1f;
				const int g = (p >> 5) & 0x3f;
				const int b = p & 0x1f;
				R = (uint8_t)((r << 3) | (r >> 2));
				G = (uint8_t)((g << 2) | (g >> 4));
				B = (uint8_t)((b << 3) | (b >> 2));
			} else if (format == 0x0c) {
				/* ARGB_4444 */
				A = (uint8_t)(((p >> 12) & 0xf) * 17);
				R = (uint8_t)(((p >> 8) & 0xf) * 17);
				G = (uint8_t)(((p >> 4) & 0xf) * 17);
				B = (uint8_t)((p & 0xf) * 17);
			} else {
				/* ARGB_1555 default for 16bpp */
				A = (p & 0x8000) ? 255 : 0;
				const int r = (p >> 10) & 0x1f;
				const int g = (p >> 5) & 0x1f;
				const int b = p & 0x1f;
				R = (uint8_t)((r << 3) | (r >> 2));
				G = (uint8_t)((g << 3) | (g >> 2));
				B = (uint8_t)((b << 3) | (b >> 2));
			}
		} else {
			/* ARGB_8888 guest BE */
			A = s[0]; R = s[1]; G = s[2]; B = s[3];
			s += 4;
		}
		/* Glide chromakey rejects the fragment before blending/depth writes.
		 * D2 uses RGBA color format with key 0x000000ff (opaque black). */
		if (chroma_mode && R == chroma_r && G == chroma_g && B == chroma_b)
			A = 0;
		d[0] = R; d[1] = G; d[2] = B; d[3] = A;
		d += 4;
	}
}

static void GlideUploadCachedTexture(GlideMetalTextureCacheEntry &entry,
										const uint8_t *src,
										int chroma_mode,
										uint32_t chroma_value,
										int color_format)
{
	std::vector<uint8_t> rgba;
	GlideDecodeTextureLevel(src, entry.width, entry.height, entry.format,
						   chroma_mode, chroma_value, color_format, rgba);
	glBindTexture(GL_TEXTURE_2D, entry.texture);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, entry.width, entry.height, 0,
				 GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());
	entry.chroma_mode = chroma_mode;
	entry.chroma_value = chroma_value;
	entry.color_format = color_format;
	entry.dirty = false;
}

void GlideMetalSetChromakey(void)
{
	const int chroma_mode = GlideStateChromaMode();
	const uint32_t chroma_value = GlideStateChromaValue();
	const int color_format = GlideStateColorFormat();
	GlideMetalTextureCacheEntry *bound = nullptr;
	for (GlideMetalTextureCacheEntry &entry : glide_texture_cache) {
		if (entry.chroma_mode != chroma_mode ||
			entry.chroma_value != chroma_value ||
			entry.color_format != color_format)
			entry.dirty = true;
		if (glide_gl_texture != 0 && entry.texture == glide_gl_texture)
			bound = &entry;
	}

	/* A key can change after grTexSource. Re-decode the resident texture now
	 * so the very next draw sees the new key even without another source call. */
	if (bound && bound->dirty && SharedMetalDevice()) {
		uint32_t avail = 0;
		const uint8_t *src = GlideStateTmuPtr(bound->address, &avail);
		const uint32_t need = (uint32_t)bound->width *
							  (uint32_t)bound->height *
							  (uint32_t)GlideTexBpp(bound->format);
		if (src && avail >= need)
			GlideUploadCachedTexture(*bound, src, chroma_mode,
										chroma_value, color_format);
	}
	if (glide_is_in_frame)
		GlideMetalApplyState();
	else if (SharedMetalDevice())
		glBindTexture(GL_TEXTURE_2D, 0);
}

void GlideMetalTexDownloadLevel(uint32_t start_addr, int lod, int large_lod,
							 int aspect_log2, int format, const void *data,
							 uint32_t nbytes)
{
	(void)large_lod;
	if (!data) return;
	int w = 1, h = 1;
	GlideTexLodDims(lod, aspect_log2, &w, &h);
	uint32_t need = GlideTexLevelSizeBytes(lod, aspect_log2, format);
	if (nbytes && nbytes < need)
		need = nbytes;
	uint32_t old_avail = 0;
	const uint8_t *old_data = GlideStateTmuPtr(start_addr, &old_avail);
	const bool changed = old_data == nullptr || old_avail < need ||
		std::memcmp(old_data, data, need) != 0;
	if (changed && !GlideStateTmuWrite(start_addr, data, need)) {
		QD3D_INIT_LOG("GlideMetalTexDownloadLevel FAIL addr=%08x need=%u",
					  start_addr, need);
		return;
	}
	/* Invalidate every resident base whose sampled level overlaps a real write. */
	const uint64_t write_begin = start_addr;
	const uint64_t write_end = write_begin + need;
	if (changed) {
		for (GlideMetalTextureCacheEntry &entry : glide_texture_cache) {
			const uint64_t entry_begin = entry.address;
			const uint64_t entry_end = entry_begin +
				(uint64_t)entry.width * (uint64_t)entry.height *
				(uint64_t)GlideTexBpp(entry.format);
			if (write_begin < entry_end && write_end > entry_begin)
				entry.dirty = true;
		}
	}
	static uint32_t s_dl_n = 0;
	if (++s_dl_n <= 12 || (s_dl_n & (s_dl_n - 1)) == 0)
		QD3D_INIT_LOG("GlideMetalTexDownloadLevel #%u addr=%08x lod=%d %dx%d fmt=%d n=%u",
					  (unsigned)s_dl_n, start_addr, lod, w, h, format, need);
}

void GlideMetalTexSource(uint32_t start_addr, int even_odd, int small_lod,
					  int large_lod, int aspect_log2, int format)
{
	(void)even_odd;
	(void)small_lod;
	if (!SharedMetalDevice()) return;
	/* Use large LOD as base resolution for sampling. */
	int w = 1, h = 1;
	GlideTexLodDims(large_lod, aspect_log2, &w, &h);
	uint32_t avail = 0;
	const uint8_t *src = GlideStateTmuPtr(start_addr, &avail);
	const uint32_t need = GlideTexLevelSizeBytes(large_lod, aspect_log2, format);
	if (!src || avail < need || need == 0) {
		glide_is_texture_enabled = false;
		QD3D_INIT_LOG("GlideMetalTexSource FAIL addr=%08x need=%u avail=%u",
					  start_addr, need, avail);
		return;
	}

	const int chroma_mode = GlideStateChromaMode();
	const uint32_t chroma_value = GlideStateChromaValue();
	const int color_format = GlideStateColorFormat();
	GlideMetalTextureCacheEntry *cached = nullptr;
	for (GlideMetalTextureCacheEntry &entry : glide_texture_cache) {
		if (entry.address == start_addr && entry.width == w &&
			entry.height == h && entry.format == format) {
			cached = &entry;
			break;
		}
	}
	if (!cached) {
		GlideMetalTextureCacheEntry entry = {};
		entry.address = start_addr;
		entry.width = w;
		entry.height = h;
		entry.format = format;
		entry.chroma_mode = chroma_mode;
		entry.chroma_value = chroma_value;
		entry.color_format = color_format;
		entry.dirty = true;
		entry.wrap_s = -1;
		entry.wrap_t = -1;
		entry.filter = -1;
		glGenTextures(1, &entry.texture);
		glide_texture_cache.push_back(entry);
		cached = &glide_texture_cache.back();
	}

	const bool upload = cached->dirty ||
		cached->chroma_mode != chroma_mode ||
		cached->chroma_value != chroma_value ||
		cached->color_format != color_format;
	glide_gl_texture = cached->texture;
	glBindTexture(GL_TEXTURE_2D, cached->texture);
	glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
	const GLint wrap_s = GlideStateTexClampS() ? GL_CLAMP_TO_EDGE : GL_REPEAT;
	const GLint wrap_t = GlideStateTexClampT() ? GL_CLAMP_TO_EDGE : GL_REPEAT;
	const GLint filt = (GlideStateTexFilterMin() || GlideStateTexFilterMag())
						   ? GL_LINEAR : GL_NEAREST;
	if (cached->wrap_s != wrap_s) {
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, wrap_s);
		cached->wrap_s = wrap_s;
	}
	if (cached->wrap_t != wrap_t) {
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, wrap_t);
		cached->wrap_t = wrap_t;
	}
	if (cached->filter != filt) {
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, filt);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, filt);
		cached->filter = filt;
	}
	if (upload) {
		GlideUploadCachedTexture(*cached, src, chroma_mode,
									chroma_value, color_format);
	}
	glBindTexture(GL_TEXTURE_2D, 0);

	/* Window-coordinate texture coordinates describe one repeat with a
	 * 256-unit long axis. The shorter axis is reduced only by aspect ratio,
	 * never by the selected LOD's physical pixel dimensions. */
	glide_texture_s_extent = 256.f;
	glide_texture_t_extent = 256.f;
	if (aspect_log2 > 0) {
		const int shift = aspect_log2 > 3 ? 3 : aspect_log2;
		glide_texture_t_extent /= (float)(1 << shift);
	} else if (aspect_log2 < 0) {
		const int shift = -aspect_log2 > 3 ? 3 : -aspect_log2;
		glide_texture_s_extent /= (float)(1 << shift);
	}
	glide_is_texture_enabled = true;

	static uint32_t s_src_n = 0;
	if (++s_src_n <= 12 || (s_src_n & (s_src_n - 1)) == 0)
		QD3D_INIT_LOG("GlideMetalTexSource #%u addr=%08x %dx%d fmt=%d",
					  (unsigned)s_src_n, start_addr, w, h, format);
}

void GlideMetalTexDownloadTable(int type, const void *data)
{
	/* type 2 = palette (Glide2 GR_TEXTABLE_PALETTE). 256 RGB words. */
	if (!data) return;
	if (type == 2 || type == 0x2) {
		const uint8_t *p = (const uint8_t *)data;
		uint32_t pal[256];
		for (int i = 0; i < 256; i++) {
			/* Guest big-endian palette words; P_8 ignores the high byte. */
			pal[i] = ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
					 ((uint32_t)p[2] << 8) | (uint32_t)p[3];
			p += 4;
		}
		/* Store on state via re-export - write through palette setter. */
		const uint32_t *old_palette = GlideStateTexPalette();
		const bool changed = old_palette == nullptr ||
			std::memcmp(old_palette, pal, sizeof(pal)) != 0;
		extern void GlideStateTexSetPalette(const uint32_t *argb256);
		GlideStateTexSetPalette(pal);
		if (changed) {
			/* Palette changes affect every resident paletted texture. */
			for (GlideMetalTextureCacheEntry &entry : glide_texture_cache) {
				if (entry.format == 0x05 || entry.format == 0x08)
					entry.dirty = true;
			}
		}
		static uint32_t s_pal_n = 0;
		if (++s_pal_n <= 8)
			QD3D_INIT_LOG("GlideMetalTexDownloadTable palette #%u", (unsigned)s_pal_n);
	}
}
