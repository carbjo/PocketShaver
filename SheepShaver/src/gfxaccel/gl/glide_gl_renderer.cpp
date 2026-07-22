/*
 *  glide_gl_renderer.cpp - 3dfx Glide raster path on desktop OpenGL
 *
 *  Renders into a double-buffered overlay texture (same compositor contract
 *  as RAVE) and publishes via MetalCompositorSubmitFrame each buffer swap.
 *
 *  First bring-up targets Diablo II Glide 3.0: win open/clear/swap/triangle.
 *  Texture download and full combinatorial combines arrive as D2 logs demand.
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

static GLuint s_overlay_pair[2] = {0, 0};
static GLuint s_color_tex = 0;
static GLuint s_fbo = 0;
static GLuint s_depth_rb = 0;
static uint32_t s_w = 0, s_h = 0;
static uint32_t s_write = 0;
static bool s_ready = false;
static bool s_in_frame = false;

extern int GlideStateDepthMode(void);
extern int GlideStateDepthMask(void);
extern int GlideStateCullMode(void);
extern int GlideStateAlphaBlendSrc(void);
extern int GlideStateAlphaBlendDst(void);
extern uint32_t GlideStateConstantColor(void);
extern int GlideStateVertexOffset(int param);
extern int GlideStateOriginUpperLeft(void);

static void release_overlay(void)
{
	if (!SharedMetalDevice()) {
		s_overlay_pair[0] = s_overlay_pair[1] = 0;
		s_color_tex = 0;
		s_w = s_h = 0;
		return;
	}
	auto &ext = gfx_gl_ext();
	if (ext.fbo && s_fbo) {
		ext.BindFramebuffer(GL_FRAMEBUFFER, 0);
		ext.DeleteFramebuffers(1, &s_fbo);
		s_fbo = 0;
	}
	if (ext.fbo && s_depth_rb) {
		ext.DeleteRenderbuffers(1, &s_depth_rb);
		s_depth_rb = 0;
	}
	for (int i = 0; i < 2; i++) {
		if (s_overlay_pair[i]) {
			gfxaccel_resources_release_overlay_texture(
				kGfxEngineGlide, (void *)(uintptr_t)s_overlay_pair[i]);
			s_overlay_pair[i] = 0;
		}
	}
	s_color_tex = 0;
	s_w = s_h = 0;
	MetalCompositorSubmitFrame_ClearCachedOverlay();
}

static bool ensure_overlay(uint32_t w, uint32_t h)
{
	if (!SharedMetalDevice()) return false;
	if (s_overlay_pair[0] && s_overlay_pair[1] && s_w == w && s_h == h)
		return true;
	release_overlay();

	void *a = gfxaccel_resources_vend_overlay_texture_indexed(
		kGfxEngineGlide, 0, w, h, MTLPixelFormatBGRA8Unorm);
	void *b = gfxaccel_resources_vend_overlay_texture_indexed(
		kGfxEngineGlide, 1, w, h, MTLPixelFormatBGRA8Unorm);
	if (!a || !b) {
		if (a) gfxaccel_resources_release_overlay_texture(kGfxEngineGlide, a);
		if (b) gfxaccel_resources_release_overlay_texture(kGfxEngineGlide, b);
		QD3D_INIT_LOG("GlideGL: overlay vend failed %ux%u", w, h);
		return false;
	}
	s_overlay_pair[0] = (GLuint)(uintptr_t)a;
	s_overlay_pair[1] = (GLuint)(uintptr_t)b;
	s_write = 0;
	s_color_tex = s_overlay_pair[s_write];
	s_w = w;
	s_h = h;

	auto &ext = gfx_gl_ext();
	if (!ext.fbo) {
		QD3D_INIT_LOG("GlideGL: FBO extension missing");
		release_overlay();
		return false;
	}
	ext.GenFramebuffers(1, &s_fbo);
	ext.GenRenderbuffers(1, &s_depth_rb);
	ext.BindRenderbuffer(GL_RENDERBUFFER, s_depth_rb);
	ext.RenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, (GLsizei)w, (GLsizei)h);
	ext.BindFramebuffer(GL_FRAMEBUFFER, s_fbo);
	ext.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
	                         GL_TEXTURE_2D, s_color_tex, 0);
	ext.FramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
	                            GL_RENDERBUFFER, s_depth_rb);
	GLenum st = ext.CheckFramebufferStatus(GL_FRAMEBUFFER);
	ext.BindFramebuffer(GL_FRAMEBUFFER, 0);
	if (st != GL_FRAMEBUFFER_COMPLETE) {
		QD3D_INIT_LOG("GlideGL: FBO incomplete 0x%x", (unsigned)st);
		release_overlay();
		return false;
	}
	return true;
}

static bool bind_draw_fbo(void)
{
	if (!s_fbo || !s_color_tex || !SharedMetalDevice()) return false;
	auto &ext = gfx_gl_ext();
	ext.BindFramebuffer(GL_FRAMEBUFFER, s_fbo);
	ext.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
	                         GL_TEXTURE_2D, s_color_tex, 0);
	glViewport(0, 0, (GLsizei)s_w, (GLsizei)s_h);
	glMatrixMode(GL_PROJECTION);
	glLoadIdentity();
	/* Glide window coords: x right, y down if origin upper-left. */
	if (GlideStateOriginUpperLeft())
		glOrtho(0.0, (double)s_w, (double)s_h, 0.0, -1.0, 1.0);
	else
		glOrtho(0.0, (double)s_w, 0.0, (double)s_h, -1.0, 1.0);
	glMatrixMode(GL_MODELVIEW);
	glLoadIdentity();
	s_in_frame = true;
	return true;
}

static GLenum map_blend_factor(int gr)
{
	/* Glide GR_BLEND_* common values */
	switch (gr) {
	case 0x0: return GL_ZERO;
	case 0x1: return GL_ONE;
	case 0x2: return GL_DST_COLOR;
	case 0x3: return GL_ONE_MINUS_DST_COLOR;
	case 0x4: return GL_SRC_ALPHA;
	case 0x5: return GL_ONE_MINUS_SRC_ALPHA;
	case 0x6: return GL_DST_ALPHA;
	case 0x7: return GL_ONE_MINUS_DST_ALPHA;
	case 0x8: return GL_SRC_ALPHA_SATURATE;
	default:  return GL_ONE;
	}
}

void GlideGLApplyState(void)
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
		glDepthFunc(GL_LEQUAL);
		glDepthMask(GlideStateDepthMask() ? GL_TRUE : GL_FALSE);
	} else {
		glDisable(GL_DEPTH_TEST);
	}
	glEnable(GL_BLEND);
	glBlendFunc(map_blend_factor(GlideStateAlphaBlendSrc()),
	            map_blend_factor(GlideStateAlphaBlendDst()));
	glDisable(GL_TEXTURE_2D);
	glDisable(GL_LIGHTING);
	glDisable(GL_ALPHA_TEST);
	glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
}

int GlideGLInit(void)
{
	s_ready = SharedMetalDevice() != nullptr;
	QD3D_INIT_LOG("GlideGLInit: ready=%d", s_ready ? 1 : 0);
	return s_ready ? 0 : -1;
}

void GlideGLShutdown(void)
{
	if (SharedMetalDevice())
		release_overlay();
	s_ready = false;
	s_in_frame = false;
}

int GlideGLWinOpen(int width, int height, int origin_upper_left)
{
	(void)origin_upper_left;
	if (width <= 0 || height <= 0) return -1;
	if (!SharedMetalDevice()) {
		if (GlideGLInit() != 0) return -1;
	}
	if (!ensure_overlay((uint32_t)width, (uint32_t)height))
		return -1;
	if (!bind_draw_fbo())
		return -1;
	glClearColor(0.f, 0.f, 0.f, 1.f);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	auto &ext = gfx_gl_ext();
	ext.BindFramebuffer(GL_FRAMEBUFFER, 0);
	s_in_frame = false;
	QD3D_INIT_LOG("GlideGLWinOpen: %dx%d overlay=%u", width, height,
	              (unsigned)s_color_tex);
	return 0;
}

void GlideGLWinClose(void)
{
	if (SharedMetalDevice())
		release_overlay();
	s_in_frame = false;
	(void)dmc_set_active_owner(kDMCOwnerQuickDraw);
}

void GlideGLBufferClear(uint32_t color, uint32_t alpha, uint32_t depth)
{
	(void)depth;
	if (!bind_draw_fbo()) return;
	/* GrColor packing depends on color format; treat as ARGB8888 common case. */
	const float a = ((color >> 24) & 0xff) / 255.f;
	const float r = ((color >> 16) & 0xff) / 255.f;
	const float g = ((color >> 8) & 0xff) / 255.f;
	const float b = ((color >> 0) & 0xff) / 255.f;
	(void)alpha;
	glClearColor(r, g, b, a > 0.f ? a : 1.f);
	glClearDepth(1.0);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
}

static void emit_vertex(const uint8_t *base)
{
	/* Prefer classic layout: x,y at 0; r,g,b at 12; a at 28. */
	const float *f = (const float *)base;
	float x = f[0], y = f[1];
	float r = f[3], g = f[4], b = f[5];
	float a = f[7];
	/* If vertex layout set GR_PARAM_XY offset, honor it. */
	int xy_off = GlideStateVertexOffset(1); /* GR_PARAM_XY often 0x01 */
	if (xy_off >= 0) {
		const float *p = (const float *)(base + xy_off);
		x = p[0]; y = p[1];
	}
	int rgb_off = GlideStateVertexOffset(2); /* GR_PARAM_RGB */
	if (rgb_off >= 0) {
		const float *p = (const float *)(base + rgb_off);
		r = p[0]; g = p[1]; b = p[2];
	}
	int a_off = GlideStateVertexOffset(3); /* GR_PARAM_A */
	if (a_off >= 0) {
		const float *p = (const float *)(base + a_off);
		a = p[0];
	}
	/* Scale if colors look like 0..255 */
	if (r > 1.f || g > 1.f || b > 1.f) {
		r /= 255.f; g /= 255.f; b /= 255.f;
	}
	if (a > 1.f) a /= 255.f;
	glColor4f(r, g, b, a);
	glVertex3f(x, y, 0.f);
}

void GlideGLDrawTriangle(const void *a, const void *b, const void *c)
{
	if (!a || !b || !c) return;
	if (!bind_draw_fbo()) return;
	GlideGLApplyState();
	glBegin(GL_TRIANGLES);
	emit_vertex((const uint8_t *)a);
	emit_vertex((const uint8_t *)b);
	emit_vertex((const uint8_t *)c);
	glEnd();
}

void GlideGLBufferSwap(int swap_interval)
{
	(void)swap_interval;
	if (!s_color_tex || !SharedMetalDevice()) return;

	auto &ext = gfx_gl_ext();
	glFlush();
	if (ext.fbo)
		ext.BindFramebuffer(GL_FRAMEBUFFER, 0);
	s_in_frame = false;

	CompositeLayer layer = {};
	layer.source = (void *)(uintptr_t)s_color_tex;
	layer.src_origin_x = 0;
	layer.src_origin_y = 0;
	layer.src_size_w = s_w;
	layer.src_size_h = s_h;
	layer.dst_origin_x = 0.f;
	layer.dst_origin_y = 0.f;
	layer.dst_size_w = (float)s_w;
	layer.dst_size_h = (float)s_h;
	layer.slot = kLayerSlotOverlay;
	layer.blend = kBlendOpaque;
	layer.alpha = 1.f;

	(void)dmc_set_active_owner(kDMCOwnerGlide);
	const DMCModeSnapshot *snap = dmc_current_snapshot();
	FrameDescriptor desc = {};
	desc.layers = &layer;
	desc.layer_count = 1;
	desc.generation = snap ? snap->generation : 0;
	desc.vbl_tick_target_usec = 0;
	(void)MetalCompositorSubmitFrame(&desc);

	/* Present immediately so Glide titles are not VBL-only (Metal RAVE
	 * also relies on Present; GL deferred path needs a kick). */
	MetalCompositorPresent();

	/* Flip write buffer for next frame. */
	s_write ^= 1;
	s_color_tex = s_overlay_pair[s_write] ? s_overlay_pair[s_write]
	                                      : s_overlay_pair[0];
}
