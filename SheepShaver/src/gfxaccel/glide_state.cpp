/*
 *  glide_state.cpp - Glide guest-visible state + hardware identity
 *
 *  Holds combinatorial state for Glide 3 and legacy Glide 2 setters.
 *  The GL renderer reads this on draw/swap.
 */

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "macos_util.h"
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
	float    constant_r, constant_g, constant_b, constant_a;
	uint32_t chroma_value;
	int      chroma_mode;
	int      cull_mode;
	int      depth_mode;
	int      depth_func;
	int      depth_mask;
	float    depth_bias;
	int      alpha_blend_src;
	int      alpha_blend_dst;
	int      alpha_blend_src_a;
	int      alpha_blend_dst_a;
	int      alpha_test_func;
	float    alpha_test_ref;
	int      alpha_test_enabled;
	int      color_mask_r, color_mask_g, color_mask_b, color_mask_a;
	int      fog_mode;
	uint32_t fog_color;
	int      dither_mode;
	int      render_buffer;
	int      color_combine_func;
	int      alpha_combine_func;
	int      tex_combine_rgb, tex_combine_alpha;
	float    tex_lod_bias;
	int      tex_detail_n, tex_detail_d, tex_detail_clamp;
	uint32_t lfb_const_alpha;
	uint32_t lfb_const_depth;
	int      lfb_write_color_format;
	int      lfb_write_color_swizzle;

	int      clip_minx, clip_miny, clip_maxx, clip_maxy;

	/* Official GR_PARAM_* are small, but Mac D2 uses 0x30/0x40/0x50 — need 256. */
	GlideVertexAttrib vlayout[256];
	int      coord_system;
	int      vertex_stride; /* inferred max(offset)+size, or set by draw */

	uint32_t tex_start_address;
	int      tex_format;
	int      tex_even_odd;
	int      tex_small_lod;
	int      tex_large_lod;
	int      tex_aspect_log2;
	int      tex_clamp_s, tex_clamp_t;
	int      tex_filter_min, tex_filter_mag;
	int      tex_mipmap_mode;
	/* Simulated TMU framebuffer (guest addresses are offsets into this). */
	std::vector<uint8_t> tmu_mem;
	/* 256-entry ARGB8888 palette for GR_TEXFMT_P_8 / download table. */
	uint32_t tex_palette[256];

	bool     lfb_locked;
	int      lfb_type;       /* GrLock_t: 0=read, 1=write, ... */
	int      lfb_buffer;     /* GrBuffer_t: 0=front, 1=back */
	int      lfb_write_mode; /* GrLfbWriteMode_t: 0=565, ... */
	int      lfb_origin;
	int      lfb_bpp;        /* bytes per pixel for current write mode */
	uint32_t lfb_guest_ptr;  /* Mac system-heap LFB base (guest-writable) */
	uint32_t lfb_alloc_size;
	uint32_t lfb_stride;
	uint32_t lfb_height_rows;
	/* Host-side scratch for 32bpp conversion on unlock (not guest-visible). */
	std::vector<uint8_t> lfb_upload_bgra;
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
	g_glide.constant_r = g_glide.constant_g = g_glide.constant_b = g_glide.constant_a = 1.f;
	g_glide.chroma_value = 0;
	g_glide.chroma_mode = 0;
	g_glide.cull_mode = 0;
	g_glide.depth_mode = 0;
	g_glide.depth_func = 0;
	g_glide.depth_mask = 1;
	g_glide.depth_bias = 0.f;
	/* Glide's GR_BLEND_ONE is 4 (not 1; 1 is SRC_ALPHA). */
	g_glide.alpha_blend_src = 4;
	g_glide.alpha_blend_dst = 0;
	g_glide.alpha_blend_src_a = 1;
	g_glide.alpha_blend_dst_a = 0;
	g_glide.alpha_test_func = 7; /* ALWAYS */
	g_glide.alpha_test_ref = 0.f;
	g_glide.alpha_test_enabled = 0;
	g_glide.color_mask_r = g_glide.color_mask_g = g_glide.color_mask_b = g_glide.color_mask_a = 1;
	g_glide.fog_mode = 0;
	g_glide.fog_color = 0;
	g_glide.dither_mode = 0;
	g_glide.render_buffer = 0;
	g_glide.color_combine_func = 0;
	g_glide.alpha_combine_func = 0;
	g_glide.tex_combine_rgb = 0;
	g_glide.tex_combine_alpha = 0;
	g_glide.tex_lod_bias = 0.f;
	g_glide.tex_detail_n = g_glide.tex_detail_d = g_glide.tex_detail_clamp = 0;
	g_glide.lfb_const_alpha = 0xff;
	g_glide.lfb_const_depth = 0;
	g_glide.lfb_write_color_format = 0;
	g_glide.lfb_write_color_swizzle = 0;
	g_glide.clip_minx = 0;
	g_glide.clip_miny = 0;
	g_glide.clip_maxx = 640;
	g_glide.clip_maxy = 480;
	g_glide.coord_system = 0;
	g_glide.vertex_stride = 0;
	for (int i = 0; i < 256; i++) {
		g_glide.vlayout[i].offset = -1;
		g_glide.vlayout[i].mode = 0;
	}
	g_glide.tex_start_address = 0;
	g_glide.tex_format = 0;
	g_glide.tex_even_odd = 0;
	g_glide.tex_small_lod = 0;
	g_glide.tex_large_lod = 8;
	g_glide.tex_aspect_log2 = 0;
	g_glide.tex_clamp_s = 0;
	g_glide.tex_clamp_t = 0;
	g_glide.tex_filter_min = 0;
	g_glide.tex_filter_mag = 0;
	g_glide.tex_mipmap_mode = 0;
	if (g_glide.tmu_mem.size() != kTmuSize)
		g_glide.tmu_mem.assign(kTmuSize, 0);
	for (int i = 0; i < 256; i++)
		g_glide.tex_palette[i] = 0xff000000u | (uint32_t)(i * 0x010101);
	g_glide.lfb_locked = false;
	g_glide.lfb_type = 0;
	g_glide.lfb_buffer = 0;
	g_glide.lfb_write_mode = 0;
	g_glide.lfb_origin = 0;
	g_glide.lfb_bpp = 2;
	/* Keep any existing guest LFB allocation across soft resets so mid-game
	 * Mac_sysalloc storms stay rare; free only on explicit release. */
	g_glide.lfb_stride = 0;
	g_glide.lfb_height_rows = 0;
	g_glide.lfb_upload_bgra.clear();
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

void GlideStateSetConstantColor(uint32_t c)
{
	g_glide.constant_color = c;
	g_glide.constant_a = ((c >> 24) & 0xff) / 255.f;
	g_glide.constant_r = ((c >> 16) & 0xff) / 255.f;
	g_glide.constant_g = ((c >> 8) & 0xff) / 255.f;
	g_glide.constant_b = (c & 0xff) / 255.f;
}
void GlideStateSetConstantColor4(float r, float g, float b, float a)
{
	g_glide.constant_r = r; g_glide.constant_g = g;
	g_glide.constant_b = b; g_glide.constant_a = a;
	auto q = [](float x) -> uint32_t {
		if (x < 0.f) x = 0.f; if (x > 1.f) x = 1.f;
		return (uint32_t)(x * 255.f + 0.5f);
	};
	g_glide.constant_color = (q(a) << 24) | (q(r) << 16) | (q(g) << 8) | q(b);
}
uint32_t GlideStateConstantColor(void) { return g_glide.constant_color; }

void GlideStateSetDepth(int mode, int func, int mask)
{
	if (mode >= 0) g_glide.depth_mode = mode;
	if (func >= 0) g_glide.depth_func = func;
	if (mask >= 0) g_glide.depth_mask = mask;
}
void GlideStateSetDepthBias(float b) { g_glide.depth_bias = b; }
float GlideStateDepthBias(void) { return g_glide.depth_bias; }

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
void GlideStateSetAlphaTest(int func, float ref)
{
	g_glide.alpha_test_func = func;
	g_glide.alpha_test_ref = ref;
	/* GR_CMP_ALWAYS = 7 typically disables effective test */
	g_glide.alpha_test_enabled = (func != 7 && func != 0) ? 1 : 0;
}
void GlideStateSetColorMask(int r, int g, int b, int a)
{
	g_glide.color_mask_r = r ? 1 : 0;
	g_glide.color_mask_g = g ? 1 : 0;
	g_glide.color_mask_b = b ? 1 : 0;
	g_glide.color_mask_a = a ? 1 : 0;
}
void GlideStateSetChromakey(int mode, uint32_t value)
{
	if (mode >= 0) g_glide.chroma_mode = mode;
	g_glide.chroma_value = value;
}
void GlideStateSetFog(int mode, uint32_t color)
{
	if (mode >= 0) g_glide.fog_mode = mode;
	g_glide.fog_color = color;
}
void GlideStateSetDither(int mode) { g_glide.dither_mode = mode; }
void GlideStateSetRenderBuffer(int buf) { g_glide.render_buffer = buf; }
void GlideStateSetColorCombine(int func) { g_glide.color_combine_func = func; }
void GlideStateSetAlphaCombine(int func) { g_glide.alpha_combine_func = func; }
void GlideStateSetTexCombine(int rgb, int a)
{
	g_glide.tex_combine_rgb = rgb;
	g_glide.tex_combine_alpha = a;
}
void GlideStateSetTexLodBias(float b) { g_glide.tex_lod_bias = b; }
void GlideStateSetTexDetail(int n, int d, int clamp)
{
	g_glide.tex_detail_n = n;
	g_glide.tex_detail_d = d;
	g_glide.tex_detail_clamp = clamp;
}
void GlideStateSetTexMipMapMode(int mode) { g_glide.tex_mipmap_mode = mode; }
void GlideStateSetLfbConstAlpha(uint32_t a) { g_glide.lfb_const_alpha = a; }
void GlideStateSetLfbConstDepth(uint32_t d) { g_glide.lfb_const_depth = d; }
void GlideStateSetLfbWriteColorFormat(int f) { g_glide.lfb_write_color_format = f; }
void GlideStateSetLfbWriteColorSwizzle(int s) { g_glide.lfb_write_color_swizzle = s; }
void GlideStateSetCoordSystem(int c) { g_glide.coord_system = c; }
void GlideStateDisableAllEffects(void)
{
	g_glide.fog_mode = 0;
	g_glide.chroma_mode = 0;
	g_glide.alpha_test_enabled = 0;
	g_glide.depth_mode = 0;
	g_glide.alpha_blend_src = 4;
	g_glide.alpha_blend_dst = 0;
}

int GlideStateAlphaBlendSrc(void) { return g_glide.alpha_blend_src; }
int GlideStateAlphaBlendDst(void) { return g_glide.alpha_blend_dst; }
int GlideStateColorFormat(void) { return g_glide.color_format; }
int GlideStateChromaMode(void) { return g_glide.chroma_mode; }
uint32_t GlideStateChromaValue(void) { return g_glide.chroma_value; }
int GlideStateFogMode(void) { return g_glide.fog_mode; }
uint32_t GlideStateFogColor(void) { return g_glide.fog_color; }
int GlideStateColorMaskR(void) { return g_glide.color_mask_r; }
int GlideStateColorMaskG(void) { return g_glide.color_mask_g; }
int GlideStateColorMaskB(void) { return g_glide.color_mask_b; }
int GlideStateColorMaskA(void) { return g_glide.color_mask_a; }
int GlideStateAlphaTestEnabled(void) { return g_glide.alpha_test_enabled; }
int GlideStateAlphaTestFunc(void) { return g_glide.alpha_test_func; }
float GlideStateAlphaTestRef(void) { return g_glide.alpha_test_ref; }
int GlideStateClipMinX(void) { return g_glide.clip_minx; }
int GlideStateClipMinY(void) { return g_glide.clip_miny; }
int GlideStateClipMaxX(void) { return g_glide.clip_maxx; }
int GlideStateClipMaxY(void) { return g_glide.clip_maxy; }
int GlideStateRenderBuffer(void) { return g_glide.render_buffer; }

void GlideStateSetVertexLayout(int param, int offset, int mode)
{
	if (param < 0 || param >= 256) return;
	if (mode == 0) {
		/* GR_PARAM_DISABLE */
		g_glide.vlayout[param].offset = -1;
		g_glide.vlayout[param].mode = 0;
		return;
	}
	g_glide.vlayout[param].offset = offset;
	g_glide.vlayout[param].mode = mode;
	/* Grow inferred stride so contiguous draws have a floor. */
	int need = offset + 16; /* generous for ST pair / RGB */
	if (need > g_glide.vertex_stride)
		g_glide.vertex_stride = need;
}

int GlideStateVertexOffset(int param)
{
	if (param < 0 || param >= 256) return -1;
	return g_glide.vlayout[param].offset;
}

int GlideStateVertexStride(void)
{
	return g_glide.vertex_stride > 0 ? g_glide.vertex_stride : 32;
}

void GlideStateSetTexSource(uint32_t startAddress, int evenOdd, int format)
{
	g_glide.tex_start_address = startAddress;
	g_glide.tex_even_odd = evenOdd;
	if (format >= 0)
		g_glide.tex_format = format;
}

void GlideStateSetTexSourceEx(uint32_t startAddress, int evenOdd,
                              int small_lod, int large_lod, int aspect_log2, int format)
{
	g_glide.tex_start_address = startAddress;
	g_glide.tex_even_odd = evenOdd;
	g_glide.tex_small_lod = small_lod;
	g_glide.tex_large_lod = large_lod;
	g_glide.tex_aspect_log2 = aspect_log2;
	g_glide.tex_format = format;
}

uint32_t GlideStateTexStart(void) { return g_glide.tex_start_address; }
int GlideStateTexFormat(void) { return g_glide.tex_format; }
int GlideStateTexEvenOdd(void) { return g_glide.tex_even_odd; }
int GlideStateTexSmallLod(void) { return g_glide.tex_small_lod; }
int GlideStateTexLargeLod(void) { return g_glide.tex_large_lod; }
int GlideStateTexAspectLog2(void) { return g_glide.tex_aspect_log2; }

uint32_t GlideStateTexMinAddress(int /*tmu*/) { return kTmuBase; }
uint32_t GlideStateTexMaxAddress(int /*tmu*/) { return kTmuBase + kTmuSize - 1; }

uint32_t GlideStateFbMem(void) { return kFbMem; }
uint32_t GlideStateTmuMem(void) { return kTmuSize; }

/* ---- Texture geometry helpers (Glide LOD / aspect) -------------------- */

int GlideTexBpp(int format)
{
	/* Common GrTextureFormat_t values (Glide 2/3). */
	switch (format) {
	case 0x00: /* 8-bit */
	case 0x01: /* YIQ_422 */
	case 0x02: /* ALPHA_8 */
	case 0x03: /* INTENSITY_8 */
	case 0x04: /* ALPHA_INTENSITY_44 */
	case 0x05: /* P_8 */
	case 0x06: /* RSVD0 */
	case 0x07: /* RSVD1 */
	case 0x08: /* 16-bit base? some headers */
		return 1;
	case 0x0a: /* RGB_565 */
	case 0x0b: /* ARGB_1555 */
	case 0x0c: /* ARGB_4444 */
	case 0x0d: /* ALPHA_INTENSITY_88 */
	case 0x0e: /* AP_88 */
	case 0x0f: /* RSVD2 */
		return 2;
	case 0x12: /* ARGB_8888 */
	case 0x13:
		return 4;
	default:
		/* Many Mac builds use small enums; treat unknown as 16bpp. */
		if (format < 0x0a) return 1;
		if (format >= 0x12) return 4;
		return 2;
	}
}

void GlideTexLodDims(int lod, int aspect_log2, int *out_w, int *out_h)
{
	/* largeLodLog2=8 → 256, aspect 0 = 1:1. aspect_log2 >0 wider, <0 taller. */
	int base = 1 << (lod < 0 ? 0 : (lod > 11 ? 11 : lod));
	int w = base, h = base;
	if (aspect_log2 > 0) {
		int s = aspect_log2 > 3 ? 3 : aspect_log2;
		h = base >> s;
		if (h < 1) h = 1;
	} else if (aspect_log2 < 0) {
		int s = (-aspect_log2) > 3 ? 3 : -aspect_log2;
		w = base >> s;
		if (w < 1) w = 1;
	}
	if (out_w) *out_w = w;
	if (out_h) *out_h = h;
}

uint32_t GlideTexLevelSizeBytes(int lod, int aspect_log2, int format)
{
	int w = 1, h = 1;
	GlideTexLodDims(lod, aspect_log2, &w, &h);
	const int bpp = GlideTexBpp(format);
	return (uint32_t)w * (uint32_t)h * (uint32_t)bpp;
}

uint32_t GlideTexCalcMemRequired(int small_lod, int large_lod, int aspect_log2, int format)
{
	if (large_lod < small_lod) {
		int t = large_lod; large_lod = small_lod; small_lod = t;
	}
	uint32_t total = 0;
	for (int lod = large_lod; lod >= small_lod; --lod)
		total += GlideTexLevelSizeBytes(lod, aspect_log2, format);
	/* Align up to 8 like hardware. */
	return (total + 7u) & ~7u;
}

bool GlideStateTmuWrite(uint32_t start, const void *src, uint32_t nbytes)
{
	if (!src || nbytes == 0) return false;
	if (g_glide.tmu_mem.size() != kTmuSize)
		g_glide.tmu_mem.assign(kTmuSize, 0);
	if (start >= kTmuSize) return false;
	uint32_t n = nbytes;
	if (start + n > kTmuSize)
		n = kTmuSize - start;
	memcpy(g_glide.tmu_mem.data() + start, src, n);
	return true;
}

const uint8_t *GlideStateTmuPtr(uint32_t start, uint32_t *out_avail)
{
	if (g_glide.tmu_mem.size() != kTmuSize)
		g_glide.tmu_mem.assign(kTmuSize, 0);
	if (start >= kTmuSize) {
		if (out_avail) *out_avail = 0;
		return nullptr;
	}
	if (out_avail) *out_avail = kTmuSize - start;
	return g_glide.tmu_mem.data() + start;
}

void GlideStateTexSetPalette(const uint32_t *argb256)
{
	if (!argb256) return;
	memcpy(g_glide.tex_palette, argb256, sizeof(g_glide.tex_palette));
}

const uint32_t *GlideStateTexPalette(void) { return g_glide.tex_palette; }

void GlideStateSetTexClamp(int s, int t)
{
	g_glide.tex_clamp_s = s;
	g_glide.tex_clamp_t = t;
}
void GlideStateSetTexFilter(int minf, int magf)
{
	g_glide.tex_filter_min = minf;
	g_glide.tex_filter_mag = magf;
}
int GlideStateTexClampS(void) { return g_glide.tex_clamp_s; }
int GlideStateTexClampT(void) { return g_glide.tex_clamp_t; }
int GlideStateTexFilterMin(void) { return g_glide.tex_filter_min; }
int GlideStateTexFilterMag(void) { return g_glide.tex_filter_mag; }

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

/* ---- Linear frame buffer (grLfbLock) ---------------------------------- */

/* Glide writeMode → bytes/pixel. 0 = 565 is the D2 path (log r5=0). */
static int glide_lfb_bpp_for_mode(int write_mode)
{
	switch (write_mode) {
	case 0:  /* GR_LFBWRITEMODE_565 */
	case 1:  /* 555 */
	case 2:  /* 1555 */
	case 5:  /* 565_DEPTH */
	case 6:  /* 555_DEPTH */
	case 7:  /* 1555_DEPTH */
	case 0xf: /* ZA16 */
		return 2;
	case 3:  /* 888 */
	case 4:  /* 8888 */
	case 8:  /* 888_DEPTH? rare */
		return 4;
	case 0xff: /* ANY — pick 565 for Voodoo-class */
		return 2;
	default:
		return 2;
	}
}

void GlideStateLfbRelease(void)
{
	g_glide.lfb_locked = false;
	if (g_glide.lfb_guest_ptr) {
		Mac_sysfree(g_glide.lfb_guest_ptr);
		g_glide.lfb_guest_ptr = 0;
	}
	g_glide.lfb_alloc_size = 0;
	g_glide.lfb_stride = 0;
	g_glide.lfb_height_rows = 0;
	g_glide.lfb_upload_bgra.clear();
}

static bool glide_lfb_ensure_guest(int bpp)
{
	const int w = g_glide.width > 0 ? g_glide.width : 640;
	const int h = g_glide.height > 0 ? g_glide.height : 480;
	/* Align stride to 16 bytes (hardware-like pitch). */
	uint32_t stride = (uint32_t)((w * bpp + 15) & ~15);
	uint32_t need = stride * (uint32_t)h;
	if (need < 4096)
		need = 4096;

	if (g_glide.lfb_guest_ptr && g_glide.lfb_alloc_size >= need &&
	    g_glide.lfb_bpp == bpp) {
		g_glide.lfb_stride = stride;
		g_glide.lfb_height_rows = (uint32_t)h;
		return true;
	}

	if (g_glide.lfb_guest_ptr) {
		Mac_sysfree(g_glide.lfb_guest_ptr);
		g_glide.lfb_guest_ptr = 0;
		g_glide.lfb_alloc_size = 0;
	}

	uint32_t mac = Mac_sysalloc(need);
	if (!mac) {
		QD3D_INIT_LOG("Glide LFB: Mac_sysalloc(%u) failed", need);
		return false;
	}

	/* Zero so unread edges are black. */
	uint8_t *host = Mac2HostAddr(mac);
	if (host)
		memset(host, 0, need);

	g_glide.lfb_guest_ptr = mac;
	g_glide.lfb_alloc_size = need;
	g_glide.lfb_stride = stride;
	g_glide.lfb_height_rows = (uint32_t)h;
	g_glide.lfb_bpp = bpp;
	return true;
}

bool GlideStateLfbLock(int type, int buffer, int write_mode, int origin,
                       uint32_t *out_ptr, uint32_t *out_stride, int *out_write_mode)
{
	if (g_glide.lfb_locked)
		return false;
	if (!g_glide.window_open)
		return false;

	/* type: 0=READ_ONLY, 1=WRITE_ONLY, 2=IDLE, 3=WRITE_ONLY_EXPLICIT? */
	int bpp = glide_lfb_bpp_for_mode(write_mode);
	/* Idle lock with ANY often still wants 565. */
	if (write_mode == 0xff)
		write_mode = 0;

	if (!glide_lfb_ensure_guest(bpp))
		return false;

	g_glide.lfb_locked = true;
	g_glide.lfb_type = type;
	g_glide.lfb_buffer = buffer;
	g_glide.lfb_write_mode = write_mode;
	g_glide.lfb_origin = origin;
	g_glide.lfb_bpp = bpp;

	if (out_ptr)
		*out_ptr = g_glide.lfb_guest_ptr;
	if (out_stride)
		*out_stride = g_glide.lfb_stride;
	if (out_write_mode)
		*out_write_mode = write_mode;
	return true;
}

bool GlideStateLfbUnlock(int buffer)
{
	(void)buffer;
	if (!g_glide.lfb_locked)
		return false;
	g_glide.lfb_locked = false;
	return true;
}

bool GlideStateLfbIsLocked(void) { return g_glide.lfb_locked; }
uint32_t GlideStateLfbGuestPtr(void) { return g_glide.lfb_guest_ptr; }
uint32_t GlideStateLfbStride(void) { return g_glide.lfb_stride; }
int GlideStateLfbWriteMode(void) { return g_glide.lfb_write_mode; }
int GlideStateLfbType(void) { return g_glide.lfb_type; }
int GlideStateLfbBuffer(void) { return g_glide.lfb_buffer; }
int GlideStateLfbBpp(void) { return g_glide.lfb_bpp; }

/* Convert guest LFB (big-endian memory image) to host BGRA8 for GL upload.
 * Returns pointer + pitch into lfb_upload_bgra, or nullptr on failure. */
const uint8_t *GlideStateLfbConvertToBGRA(int *out_w, int *out_h, int *out_pitch)
{
	if (!g_glide.lfb_guest_ptr || !g_glide.lfb_stride || !g_glide.lfb_height_rows)
		return nullptr;
	const int w = g_glide.width;
	const int h = (int)g_glide.lfb_height_rows;
	const int bpp = g_glide.lfb_bpp > 0 ? g_glide.lfb_bpp : 2;
	const uint32_t stride = g_glide.lfb_stride;
	const uint8_t *src = Mac2HostAddr(g_glide.lfb_guest_ptr);
	if (!src || w <= 0 || h <= 0)
		return nullptr;

	const int pitch = w * 4;
	g_glide.lfb_upload_bgra.resize((size_t)pitch * (size_t)h);
	uint8_t *dst = g_glide.lfb_upload_bgra.data();
	const int mode = g_glide.lfb_write_mode;

	/* Guest LFB is top-down. Overlay slot samples t=1 at screen top (RAVE
	 * FBO convention), while glTexSubImage row0 is t≈0 — flip so movies
	 * are right-side up. */
	for (int y = 0; y < h; y++) {
		const uint8_t *row = src + (size_t)y * stride;
		uint8_t *drow = dst + (size_t)(h - 1 - y) * pitch;
		if (bpp == 2) {
			for (int x = 0; x < w; x++) {
				/* Mac RAM is big-endian halfwords. */
				const uint16_t p = (uint16_t)((row[0] << 8) | row[1]);
				row += 2;
				uint8_t R, G, B, A = 0xff;
				if (mode == 1 || mode == 2 || mode == 6 || mode == 7) {
					/* 1555 / 555 */
					const int r = (p >> 10) & 0x1f;
					const int g = (p >> 5) & 0x1f;
					const int b = p & 0x1f;
					R = (uint8_t)((r << 3) | (r >> 2));
					G = (uint8_t)((g << 3) | (g >> 2));
					B = (uint8_t)((b << 3) | (b >> 2));
					if (mode == 2 || mode == 7)
						A = (p & 0x8000) ? 0xff : 0x00;
				} else {
					/* 565 (default) */
					const int r = (p >> 11) & 0x1f;
					const int g = (p >> 5) & 0x3f;
					const int b = p & 0x1f;
					R = (uint8_t)((r << 3) | (r >> 2));
					G = (uint8_t)((g << 2) | (g >> 4));
					B = (uint8_t)((b << 3) | (b >> 2));
				}
				drow[0] = B; drow[1] = G; drow[2] = R; drow[3] = A;
				drow += 4;
			}
		} else {
			/* 8888 packed: treat guest big-endian ARGB words → BGRA. */
			for (int x = 0; x < w; x++) {
				const uint32_t p = ((uint32_t)row[0] << 24) | ((uint32_t)row[1] << 16) |
				                   ((uint32_t)row[2] << 8) | (uint32_t)row[3];
				row += 4;
				const uint8_t A = (uint8_t)((p >> 24) & 0xff);
				const uint8_t R = (uint8_t)((p >> 16) & 0xff);
				const uint8_t G = (uint8_t)((p >> 8) & 0xff);
				const uint8_t B = (uint8_t)(p & 0xff);
				drow[0] = B; drow[1] = G; drow[2] = R;
				drow[3] = A ? A : 0xff;
				drow += 4;
			}
		}
	}
	if (out_w) *out_w = w;
	if (out_h) *out_h = h;
	if (out_pitch) *out_pitch = pitch;
	return dst;
}

void GlideStateLfbClear(uint16_t color565)
{
	if (!g_glide.lfb_guest_ptr || !g_glide.lfb_stride || !g_glide.lfb_alloc_size)
		return;
	uint8_t *host = Mac2HostAddr(g_glide.lfb_guest_ptr);
	if (!host) return;
	const int bpp = g_glide.lfb_bpp > 0 ? g_glide.lfb_bpp : 2;
	/* Never use window width alone — after 640→800 reswitch, stride/rows
	 * may still describe the old buffer; overflowing corrupts guest heap. */
	const int max_w = (int)(g_glide.lfb_stride / (uint32_t)bpp);
	const int w = (g_glide.width > 0 && g_glide.width < max_w) ? g_glide.width : max_w;
	const int h = (int)g_glide.lfb_height_rows;
	if (w <= 0 || h <= 0) return;
	const uint32_t need = g_glide.lfb_stride * (uint32_t)h;
	if (need > g_glide.lfb_alloc_size) return;
	if (bpp == 2) {
		const uint8_t hi = (uint8_t)((color565 >> 8) & 0xff);
		const uint8_t lo = (uint8_t)(color565 & 0xff);
		for (int y = 0; y < h; y++) {
			uint8_t *row = host + (size_t)y * g_glide.lfb_stride;
			for (int x = 0; x < w; x++) {
				row[0] = hi; row[1] = lo;
				row += 2;
			}
		}
	} else {
		memset(host, 0, need);
	}
}

bool GlideStateLfbWriteRegion(int /*dst_buffer*/, int dst_x, int dst_y,
                              int /*src_format*/, int src_w, int src_h,
                              int src_stride, const void *src_data)
{
	if (!src_data || src_w <= 0 || src_h <= 0) return false;
	if (!g_glide.lfb_guest_ptr && !glide_lfb_ensure_guest(g_glide.lfb_bpp > 0 ? g_glide.lfb_bpp : 2))
		return false;
	uint8_t *dst = Mac2HostAddr(g_glide.lfb_guest_ptr);
	if (!dst) return false;
	const int bpp = g_glide.lfb_bpp > 0 ? g_glide.lfb_bpp : 2;
	const int dst_stride = (int)g_glide.lfb_stride;
	const int max_w = g_glide.width > 0 ? g_glide.width : (dst_stride / bpp);
	const int max_h = (int)g_glide.lfb_height_rows;
	if (dst_x < 0) { src_w += dst_x; src_data = (const uint8_t *)src_data - dst_x * bpp; dst_x = 0; }
	if (dst_y < 0) { src_h += dst_y; src_data = (const uint8_t *)src_data - dst_y * src_stride; dst_y = 0; }
	if (src_w <= 0 || src_h <= 0) return true;
	if (dst_x + src_w > max_w) src_w = max_w - dst_x;
	if (dst_y + src_h > max_h) src_h = max_h - dst_y;
	if (src_w <= 0 || src_h <= 0) return true;
	if (src_stride <= 0) src_stride = src_w * bpp;
	const uint8_t *s = (const uint8_t *)src_data;
	const int row_bytes = src_w * bpp;
	for (int y = 0; y < src_h; y++) {
		uint8_t *drow = dst + (size_t)(dst_y + y) * (size_t)dst_stride + (size_t)dst_x * bpp;
		memcpy(drow, s + (size_t)y * (size_t)src_stride, (size_t)row_bytes);
	}
	return true;
}

bool GlideStateLfbReadRegion(int /*src_buffer*/, int src_x, int src_y,
                             int src_w, int src_h, int dst_stride, void *dst_data)
{
	if (!dst_data || src_w <= 0 || src_h <= 0) return false;
	if (!g_glide.lfb_guest_ptr) return false;
	const uint8_t *src = Mac2HostAddr(g_glide.lfb_guest_ptr);
	if (!src) return false;
	const int bpp = g_glide.lfb_bpp > 0 ? g_glide.lfb_bpp : 2;
	const int src_stride = (int)g_glide.lfb_stride;
	const int max_w = g_glide.width > 0 ? g_glide.width : (src_stride / bpp);
	const int max_h = (int)g_glide.lfb_height_rows;
	if (src_x < 0) { src_w += src_x; src_x = 0; }
	if (src_y < 0) { src_h += src_y; src_y = 0; }
	if (src_w <= 0 || src_h <= 0) return true;
	if (src_x + src_w > max_w) src_w = max_w - src_x;
	if (src_y + src_h > max_h) src_h = max_h - src_y;
	if (dst_stride <= 0) dst_stride = src_w * bpp;
	uint8_t *d = (uint8_t *)dst_data;
	const int row_bytes = src_w * bpp;
	for (int y = 0; y < src_h; y++) {
		const uint8_t *srow = src + (size_t)(src_y + y) * (size_t)src_stride + (size_t)src_x * bpp;
		memcpy(d + (size_t)y * (size_t)dst_stride, srow, (size_t)row_bytes);
	}
	return true;
}
