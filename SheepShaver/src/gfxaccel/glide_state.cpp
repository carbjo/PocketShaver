/*
 *  glide_state.cpp - Glide guest-visible state + hardware identity
 *
 *  Holds combinatorial state for Glide 3 and legacy Glide 2 setters.
 *  The GL renderer reads this on draw/swap.
 */

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "glide_engine.h"
#include "gfx_log.h"

#include <cstring>
#include <vector>

struct GlideVertexAttrib {
	int32_t offset;   /* -1 = disabled */
	int32_t mode;
};

struct GlideState {
	bool     inited;
	bool     window_open;
	int      selected_sst;
	int      width;
	int      height;
	int      origin_upper_left;
	int      color_format;
	int      num_buffers;
	int      num_aux;

	uint32_t constant_color;
	uint32_t chroma_value;
	int      chroma_mode;
	int      cull_mode;
	int      depth_mode;
	int      depth_func;
	int      depth_mask;
	int      alpha_blend_src;
	int      alpha_blend_dst;
	int      alpha_blend_src_a;
	int      alpha_blend_dst_a;
	int      render_buffer;

	int      clip_minx, clip_miny, clip_maxx, clip_maxy;

	GlideVertexAttrib vlayout[64];
	int      coord_system;

	uint32_t tex_start_address;
	int      tex_format;
	int      tex_clamp_s, tex_clamp_t;
	int      tex_filter_min, tex_filter_mag;
	int      tex_mipmap_mode;

	bool     lfb_locked;
	uint32_t lfb_guest_ptr;
	uint32_t lfb_stride;
	std::vector<uint8_t> lfb_pixels;
};

static GlideState g_glide;

static const uint32_t kTmuBase = 0x00000000;
static const uint32_t kTmuSize = 4u * 1024u * 1024u;
static const uint32_t kFbMem   = 4u * 1024u * 1024u;

void GlideStateResetDefaults(void)
{
	g_glide.window_open = false;
	g_glide.selected_sst = 0;
	g_glide.width = 640;
	g_glide.height = 480;
	g_glide.origin_upper_left = 1;
	g_glide.color_format = GR_COLORFORMAT_ARGB;
	g_glide.num_buffers = 2;
	g_glide.num_aux = 1;
	g_glide.constant_color = 0xffffffffu;
	g_glide.chroma_value = 0;
	g_glide.chroma_mode = 0;
	g_glide.cull_mode = 0;
	g_glide.depth_mode = 0;
	g_glide.depth_func = 0;
	g_glide.depth_mask = 1;
	g_glide.alpha_blend_src = 1;
	g_glide.alpha_blend_dst = 0;
	g_glide.alpha_blend_src_a = 1;
	g_glide.alpha_blend_dst_a = 0;
	g_glide.render_buffer = 0;
	g_glide.clip_minx = 0;
	g_glide.clip_miny = 0;
	g_glide.clip_maxx = 640;
	g_glide.clip_maxy = 480;
	g_glide.coord_system = 0;
	for (int i = 0; i < 64; i++) {
		g_glide.vlayout[i].offset = -1;
		g_glide.vlayout[i].mode = 0;
	}
	g_glide.tex_start_address = 0;
	g_glide.tex_format = 0;
	g_glide.tex_clamp_s = 0;
	g_glide.tex_clamp_t = 0;
	g_glide.tex_filter_min = 0;
	g_glide.tex_filter_mag = 0;
	g_glide.tex_mipmap_mode = 0;
	g_glide.lfb_locked = false;
	g_glide.lfb_guest_ptr = 0;
	g_glide.lfb_stride = 0;
	g_glide.lfb_pixels.clear();
}

bool GlideStateIsInited(void) { return g_glide.inited; }
bool GlideStateWindowOpen(void) { return g_glide.window_open; }
int  GlideStateWidth(void) { return g_glide.width; }
int  GlideStateHeight(void) { return g_glide.height; }
int  GlideStateOriginUpperLeft(void) { return g_glide.origin_upper_left; }

void GlideStateSetInited(bool v) { g_glide.inited = v; }
void GlideStateSetWindowOpen(bool v) { g_glide.window_open = v; }

void GlideStateSetWin(int w, int h, int origin_ul, int cfmt, int nbuf, int naux)
{
	g_glide.width = w;
	g_glide.height = h;
	g_glide.origin_upper_left = origin_ul;
	g_glide.color_format = cfmt;
	g_glide.num_buffers = nbuf;
	g_glide.num_aux = naux;
	g_glide.clip_minx = 0;
	g_glide.clip_miny = 0;
	g_glide.clip_maxx = w;
	g_glide.clip_maxy = h;
	g_glide.window_open = true;
}

void GlideStateSetClip(int minx, int miny, int maxx, int maxy)
{
	g_glide.clip_minx = minx;
	g_glide.clip_miny = miny;
	g_glide.clip_maxx = maxx;
	g_glide.clip_maxy = maxy;
}

void GlideStateSetConstantColor(uint32_t c) { g_glide.constant_color = c; }
uint32_t GlideStateConstantColor(void) { return g_glide.constant_color; }

void GlideStateSetDepth(int mode, int func, int mask)
{
	if (mode >= 0) g_glide.depth_mode = mode;
	if (func >= 0) g_glide.depth_func = func;
	if (mask >= 0) g_glide.depth_mask = mask;
}

int GlideStateDepthMode(void) { return g_glide.depth_mode; }
int GlideStateDepthFunc(void) { return g_glide.depth_func; }
int GlideStateDepthMask(void) { return g_glide.depth_mask; }
int GlideStateCullMode(void) { return g_glide.cull_mode; }

void GlideStateSetCull(int mode) { g_glide.cull_mode = mode; }
void GlideStateSetAlphaBlend(int s, int d, int sa, int da)
{
	g_glide.alpha_blend_src = s;
	g_glide.alpha_blend_dst = d;
	g_glide.alpha_blend_src_a = sa;
	g_glide.alpha_blend_dst_a = da;
}

int GlideStateAlphaBlendSrc(void) { return g_glide.alpha_blend_src; }
int GlideStateAlphaBlendDst(void) { return g_glide.alpha_blend_dst; }

void GlideStateSetVertexLayout(int param, int offset, int mode)
{
	if (param < 0 || param >= 64) return;
	g_glide.vlayout[param].offset = offset;
	g_glide.vlayout[param].mode = mode;
}

int GlideStateVertexOffset(int param)
{
	if (param < 0 || param >= 64) return -1;
	return g_glide.vlayout[param].offset;
}

void GlideStateSetTexSource(uint32_t startAddress, int evenOdd, int format)
{
	(void)evenOdd;
	g_glide.tex_start_address = startAddress;
	g_glide.tex_format = format;
}

uint32_t GlideStateTexStart(void) { return g_glide.tex_start_address; }
int GlideStateTexFormat(void) { return g_glide.tex_format; }

uint32_t GlideStateTexMinAddress(int /*tmu*/) { return kTmuBase; }
uint32_t GlideStateTexMaxAddress(int /*tmu*/) { return kTmuBase + kTmuSize - 1; }

uint32_t GlideStateFbMem(void) { return kFbMem; }
uint32_t GlideStateTmuMem(void) { return kTmuSize; }

void GlideStateResolveResolution(int res_enum, int *out_w, int *out_h)
{
	int w = 640, h = 480;
	switch (res_enum) {
	case GR_RESOLUTION_320x200: w = 320; h = 200; break;
	case GR_RESOLUTION_320x240: w = 320; h = 240; break;
	case GR_RESOLUTION_400x256: w = 400; h = 256; break;
	case GR_RESOLUTION_512x384: w = 512; h = 384; break;
	case GR_RESOLUTION_640x200: w = 640; h = 200; break;
	case GR_RESOLUTION_640x350: w = 640; h = 350; break;
	case GR_RESOLUTION_640x400: w = 640; h = 400; break;
	case GR_RESOLUTION_640x480: w = 640; h = 480; break;
	case GR_RESOLUTION_800x600: w = 800; h = 600; break;
	case GR_RESOLUTION_960x720: w = 960; h = 720; break;
	case GR_RESOLUTION_856x480: w = 856; h = 480; break;
	case GR_RESOLUTION_512x256: w = 512; h = 256; break;
	case GR_RESOLUTION_1024x768: w = 1024; h = 768; break;
	case GR_RESOLUTION_1280x1024: w = 1280; h = 1024; break;
	case GR_RESOLUTION_1600x1200: w = 1600; h = 1200; break;
	case GR_RESOLUTION_400x300: w = 400; h = 300; break;
	default: w = 640; h = 480; break;
	}
	if (out_w) *out_w = w;
	if (out_h) *out_h = h;
}
