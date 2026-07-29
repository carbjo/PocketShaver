/*
 *  dsp_gl_renderer.cpp - DSp back-buffer via host memory + compositor present
 * 
 * (C) 2026 RandoOnSteam (battlemageloveryt@gmail.com)
 */

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "dsp_engine.h"
#include "dsp_metal_renderer.h"
#include "dsp_context_private.h"
#include "gfxaccel_resources.h"
#include "gfxaccel_resources_heap.h"
#include "metal_device_shared.h"
#include "metal_compositor.h"
#include "macos_util.h"
#include "video.h"
#include "dsp_back_buffer_range.h"
#include "dsp_back_buffer_cgraf_policy.h"
#include "dsp_cgraf_port_policy.h"
#include "dsp_front_buffer_policy.h"
#include "dsp_front_staging_present_policy.h"
#include "dsp_vbl_publish_policy.h"
#include "dsp_pixmap_offsets.h"
#include "dsp_draw_context.h"
#include "display_mode_controller.h"
#include "dsp_alt_buffer.h"
#include "gfx_log.h"
#include "thunks.h"

#include <SDL_opengl.h>
#include <algorithm>
#include <array>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <limits>
#include <map>
#include <vector>

#ifndef GL_RGBA8
#define GL_RGBA8 0x8058
#endif
#ifndef GL_BGRA
#define GL_BGRA 0x80E1
#endif

extern "C" void gfxaccel_resources_heap_mm_free_buffer(uint32_t heap_id, void *ptr);
extern "C" bool GLCompositorCopyCurrentPaletteRGB(uint8_t out_rgb[768]);

struct DSpGLFrontTexture {
	GLuint texture;
	uint32_t width;
	uint32_t height;
};

/* Front and back are distinct guest surfaces, but each only needs a host GL
 * texture while it is being presented.  Keep the GL-only texture bookkeeping
 * out of the shared Metal/OpenGL DSpContextPrivate ABI. */
static std::map<uint32_t, DSpGLFrontTexture> s_front_textures;

static bool DSpGLIsValidDepth(uint32_t depth)
{
	return depth == 1 || depth == 2 || depth == 4 || depth == 8 ||
		   depth == 16 || depth == 32;
}

static uint32_t DSpGLPackRGBA(uint8_t r, uint8_t g, uint8_t b)
{
	/* The desktop OpenGL backends are little-endian; this integer layout is
	 * byte-for-byte RGBA when uploaded with GL_UNSIGNED_BYTE. */
	return (uint32_t)r | ((uint32_t)g << 8) |
		   ((uint32_t)b << 16) | 0xff000000u;
}

static const uint32_t *DSpGLRGB555GammaLut(const uint8_t *gamma)
{
	static std::array<uint32_t, 32768> lut;
	static std::array<uint8_t, 768> gamma_snapshot;
	static bool valid = false;
	bool changed = !valid;
	if (!changed) {
		for (uint32_t i = 0; i < gamma_snapshot.size(); i++) {
			const uint8_t value = gamma ? gamma[i] : (uint8_t)(i & 255u);
			if (gamma_snapshot[i] != value) {
				changed = true;
				break;
			}
		}
	}
	if (changed) {
		for (uint32_t i = 0; i < gamma_snapshot.size(); i++)
			gamma_snapshot[i] = gamma ? gamma[i] : (uint8_t)(i & 255u);
		for (uint32_t value = 0; value < lut.size(); value++) {
			const uint8_t r = (uint8_t)(((value >> 10) & 31u) * 255u / 31u);
			const uint8_t g = (uint8_t)(((value >> 5) & 31u) * 255u / 31u);
			const uint8_t b = (uint8_t)((value & 31u) * 255u / 31u);
			lut[value] = DSpGLPackRGBA(gamma_snapshot[r],
								   gamma_snapshot[256u + g],
								   gamma_snapshot[512u + b]);
		}
		valid = true;
	}
	return lut.data();
}

static bool DSpGLIsValidBackBufferLayout(uint32_t w, uint32_t h, uint32_t depth,
								   uint32_t *out_row_bytes,
								   uint32_t *out_size)
{
	if (!w || !h || !DSpGLIsValidDepth(depth)) return false;
	const uint32_t row_bytes = DSpBackBufferAlignedRowBytes(w, depth);
	const uint64_t size = (uint64_t)row_bytes * (uint64_t)h;
	if (!row_bytes || size > std::numeric_limits<uint32_t>::max()) return false;
	if (out_row_bytes) *out_row_bytes = row_bytes;
	if (out_size) *out_size = (uint32_t)size;
	return true;
}

static void DSpGLGetPixmapFormat(uint32_t depth, uint16_t *pixel_type,
							  uint16_t *pixel_size, uint16_t *component_count,
							  uint16_t *component_size)
{
	*pixel_type = depth <= 8 ? 0 : 0x10;
	*pixel_size = (uint16_t)depth;
	*component_count = depth <= 8 ? 1 : 3;
	*component_size = depth <= 8 ? (uint16_t)depth :
					  depth == 16 ? 5 : 8;
}

static uint32_t DSpGLAllocRectRegion(uint32_t w, uint32_t h)
{
	/* Region handles embedded in a guest-visible CGrafPort must outlive any
	 * Toolbox drawing that retains the port.  Mac_sysalloc storage is movable
	 * and can be reclaimed/poisoned by the guest Memory Manager; SheepMem is
	 * the permanent descriptor arena used by the Metal backend. */
	const uint32_t region = SheepMem::Reserve(DSP_RECT_REGION_SIZE);
	const uint32_t handle = SheepMem::Reserve(4);
	if (!region || !handle) return 0;
	Mac_memset(region, 0, DSP_RECT_REGION_SIZE);
	WriteMacInt16(region + DSP_REGION_OFF_SIZE, DSP_RECT_REGION_SIZE);
	WriteMacInt16(region + DSP_REGION_OFF_BBOX + 0, 0);
	WriteMacInt16(region + DSP_REGION_OFF_BBOX + 2, 0);
	WriteMacInt16(region + DSP_REGION_OFF_BBOX + 4, (uint16_t)h);
	WriteMacInt16(region + DSP_REGION_OFF_BBOX + 6, (uint16_t)w);
	WriteMacInt32(handle, region);
	return handle;
}

static void DSpGLGetFrontStagingGeometry(const DSpContextPrivate *ctx,
	uint32_t visible_w, uint32_t visible_h, uint32_t depth,
	uint32_t *out_row, uint32_t *out_height, uint32_t *out_visible_x = nullptr,
	uint32_t *out_visible_y = nullptr)
{
	(void)ctx;
	/* GetFrontBuffer vends a surface in the active DSp mode.  The saved
	 * MainDevice PixMap describes the desktop being restored on release; it
	 * must not change the staging allocation's pitch or visible origin.  In
	 * particular, Diablo's 640x480 movies run from an 800x600 desktop. */
	if (out_row)
		*out_row = DSpDisplayModePitch(visible_w, depth);
	if (out_height)
		*out_height = visible_h;
	if (out_visible_x)
		*out_visible_x = 0;
	if (out_visible_y)
		*out_visible_y = 0;
}

bool DSpDoAllocateBackBuffer(uint32_t w, uint32_t h, uint32_t bpp,
	void** pbuf, void** ptex)
{
	uint32_t row = 0;
	uint32_t size = 0;
	if (!DSpGLIsValidBackBufferLayout(w, h, bpp, &row, &size)) {
		QD3D_RESOURCE_LOG("DSpAllocateBackBuffer(GL): invalid layout %ux%u@%u",
						  w, h, bpp);
		return false;
	}
	void *buf = gfxaccel_resources_heap_alloc_buffer(kHeapEngineDSp, size, 0);
	if (!buf) return false;
	std::memset(buf, 0, size);

	GLuint tex = 0;
	if (SharedMetalDevice()) {
		glGenTextures(1, &tex);
		glBindTexture(GL_TEXTURE_2D, tex);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, (GLsizei)w, (GLsizei)h, 0,
					 GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
	}
	if (!tex) {
		gfxaccel_resources_heap_mm_free_buffer(kHeapEngineDSp, buf);
		QD3D_RESOURCE_LOG("DSpAllocateBackBuffer(GL): texture allocation "
				"failed for %ux%u@%u",
			w, h, bpp);
		return false;
	}

	*pbuf = buf;
	*ptex = (void *)(uintptr_t)tex;
	gfxaccel_resources_set_buffer_owner(buf, kGfxEngineDSp);
	QD3D_RESOURCE_LOG("DSpAllocateBackBuffer(GL): "
			"back=%ux%u@%u row=%u size=%u texture=%u",
		w, h, bpp, row, size, (unsigned)tex);
	return true;
}
bool DSpAllocateBackBuffer(struct DSpContextPrivate *ctx,
								   uint32_t w, uint32_t h, uint32_t bpp)
{
	if(!DSpDoAllocateBackBuffer(w, h, bpp,
			&ctx->back_buffer, &ctx->back_texture))
		return false;
	ctx->dirty_empty = true;
	ctx->dirty_cold_start = true;
	return true;
}

void DSpReleaseBackBufferNow(DSpContextPrivate *ctx)
{
	if (!ctx) return;
	auto front_it = s_front_textures.find(ctx->handle);
	if (front_it != s_front_textures.end()) {
		if (front_it->second.texture && SharedMetalDevice()) {
			GLuint texture = front_it->second.texture;
			glDeleteTextures(1, &texture);
		}
		s_front_textures.erase(front_it);
	}
	if (ctx->back_texture && SharedMetalDevice()) {
		GLuint tex = (GLuint)(uintptr_t)ctx->back_texture;
		glDeleteTextures(1, &tex);
	}
	if (ctx->back_buffer) {
		gfxaccel_resources_clear_buffer_owner(ctx->back_buffer);
		gfxaccel_resources_heap_mm_free_buffer(kHeapEngineDSp, ctx->back_buffer);
		ctx->back_buffer = nullptr;
	}
	ctx->back_texture = nullptr;
	DSpReleaseBackBufferStaging(ctx);
	ctx->cgrafptr_mac_addr = 0;
	ctx->front_cgrafptr_mac_addr = 0;
	ctx->front_pixmap_mac_addr = 0;
	ctx->front_pixmap_handle_mac_addr = 0;
	ctx->front_staging_mac_addr = 0;
	ctx->front_staging_size = 0;
	ctx->front_staging_owned_sysheap = false;
	ctx->front_staging_row_bytes = 0;
	ctx->front_staging_height = 0;
	ctx->front_staging_present_state = {};
}

/* Expand a guest-format DSp surface into tightly packed RGBA for GL upload. */
static void expand_surface_to_rgba(const DSpContextPrivate *ctx,
									const uint8_t *src,
									uint32_t w, uint32_t h,
									uint32_t bpp, uint32_t row,
									std::vector<uint8_t> &out,
									uint32_t src_x = 0,
									uint32_t src_y = 0)
{
	out.resize((size_t)w * h * 4);
	const uint32_t minimum_row =
		(uint32_t)(((uint64_t)(src_x + w) * bpp + 7u) / 8u);
	if (!ctx || !src || !w || !h || !DSpGLIsValidDepth(bpp) ||
		!row || row < minimum_row) {
		std::memset(out.data(), 0, out.size());
		return;
	}
	const uint8_t *gamma = (const uint8_t *)MetalCompositorGetGammaLUTBuffer();
	auto apply_gamma = [gamma](uint8_t c, uint32_t plane) -> uint8_t {
		return gamma ? gamma[plane * 256u + c] : c;
	};
	const uint32_t *rgb555_lut = bpp == 16 ? DSpGLRGB555GammaLut(gamma) : nullptr;
	std::array<uint32_t, 256> palette_rgba = {};
	if (bpp <= 8) {
		uint8_t display_palette[768];
		const uint8_t *pal = ctx->clut_bytes_latched;
		/* Palette Manager/video-driver SetEntries updates the compositor
		 * directly, not necessarily the DSp context CLUT.  Use the actual
		 * display palette so a valid 256-color mode is not rendered through
		 * the context's old grayscale default. */
		if (GLCompositorCopyCurrentPaletteRGB(display_palette))
			pal = display_palette;
		for (uint32_t i = 0; i < palette_rgba.size(); i++) {
			palette_rgba[i] = DSpGLPackRGBA(
				apply_gamma(pal[i * 3u + 0u], 0),
				apply_gamma(pal[i * 3u + 1u], 1),
				apply_gamma(pal[i * 3u + 2u], 2));
		}
	}
	for (uint32_t y = 0; y < h; y++) {
		const uint8_t *srow = src + (size_t)(src_y + y) * row;
		uint32_t *drow = reinterpret_cast<uint32_t *>(
			out.data() + (size_t)y * w * 4u);
		for (uint32_t x = 0; x < w; x++) {
			const uint32_t sx = src_x + x;
			if (bpp == 32) {
				/* Guest BE ARGB */
				drow[x] = DSpGLPackRGBA(
					apply_gamma(srow[sx * 4u + 1u], 0),
					apply_gamma(srow[sx * 4u + 2u], 1),
					apply_gamma(srow[sx * 4u + 3u], 2));
			} else if (bpp == 16) {
				const uint16_t be = (uint16_t)(
					((uint16_t)srow[sx * 2u] << 8) | srow[sx * 2u + 1u]);
				drow[x] = rgb555_lut[be & 0x7fffu];
			} else {
				uint8_t i = 0;
				if (bpp == 8) {
					i = srow[sx];
				} else if (bpp == 4) {
					const uint8_t packed = srow[sx >> 1];
					i = (sx & 1u) ? (packed & 0x0fu) : (packed >> 4);
				} else if (bpp == 2) {
					const uint8_t packed = srow[sx >> 2];
					i = (packed >> ((3u - (sx & 3u)) * 2u)) & 0x03u;
				} else {
					const uint8_t packed = srow[sx >> 3];
					i = (packed >> (7u - (sx & 7u))) & 0x01u;
				}
				drow[x] = palette_rgba[i];
			}
		}
	}
}

static void expand_back_to_rgba(const DSpContextPrivate *ctx,
								std::vector<uint8_t> &out)
{
	const uint32_t w = DSpContextBackBufferWidth(ctx);
	const uint32_t h = DSpContextBackBufferHeight(ctx);
	const uint32_t bpp = ctx->attr.backBufferBestDepth;
	const uint32_t row = DSpBackBufferAlignedRowBytes(w, bpp);
	expand_surface_to_rgba(ctx, (const uint8_t *)ctx->back_buffer,
						   w, h, bpp, row, out);
}

void DSpEncodeBackBufferBlit(DSpContextPrivate *ctx, void * /*encoder*/, void *framebuffer_texture)
{
	if (!ctx || !ctx->back_buffer) return;

	GLuint fb_tex = (GLuint)(uintptr_t)framebuffer_texture;
	if (fb_tex && SharedMetalDevice()) {
		static std::vector<uint8_t> rgba;
		expand_back_to_rgba(ctx, rgba);
		const uint32_t w = DSpContextBackBufferWidth(ctx);
		const uint32_t h = DSpContextBackBufferHeight(ctx);
		glBindTexture(GL_TEXTURE_2D, fb_tex);
		glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, (GLsizei)w, (GLsizei)h,
						GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());
	}

	ctx->dirty_empty = true;
	ctx->dirty_cold_start = false;
	ctx->dirty_left = ctx->dirty_top = ctx->dirty_right = ctx->dirty_bottom = 0;
}

void DSpEncodePresentToFramebuffer(DSpContextPrivate *ctx, void *command_buffer, void *framebuffer_texture)
{
	DSpEncodeBackBufferBlit(ctx, command_buffer, framebuffer_texture);
}

bool DSpEncodeFrontBufferStagingToFramebuffer(DSpContextPrivate *ctx, void *, void *framebuffer_texture)
{
	if (!ctx || !ctx->front_staging_mac_addr || !ctx->front_staging_size)
		return false;

	const uint32_t w = ctx->attr.displayWidth;
	const uint32_t h = ctx->attr.displayHeight;
	const uint32_t depth = DSpFrontBufferDepth(
		ctx->attr.backBufferBestDepth, ctx->attr.displayBestDepth);
	const uint32_t row = ctx->front_staging_row_bytes
		? ctx->front_staging_row_bytes
		: DSpFrontBufferRowBytes(w, ctx->attr.backBufferBestDepth,
								 ctx->attr.displayBestDepth);
	const uint32_t storage_h = ctx->front_staging_height
		? ctx->front_staging_height : h;
	const uint64_t required64 = (uint64_t)row * storage_h;
	if (!w || !h || !DSpGLIsValidDepth(depth) || !row ||
		required64 > ctx->front_staging_size || required64 > UINT32_MAX) {
		QD3D_RENDER_LOG("DSpFrontPresent(GL): invalid surface ctx=%u %ux%u@%u row=%u have=%u",
						ctx->handle, w, h, depth, row,
						ctx->front_staging_size);
		return false;
	}

	uint8_t *front = Mac2HostAddr(ctx->front_staging_mac_addr);
	if (!front) return false;
	const uint32_t required = (uint32_t)required64;
	const uint32_t hash = DSpFrontStagingHashBytes(front, required);
	const DMCModeSnapshot *snap = dmc_current_snapshot();
	const uint32_t color_generation = snap
		? (snap->gamma_gen ^ (snap->palette_gen * 0x9e3779b9u)) : 0;
	const uint32_t fade_active = snap ? snap->fade_active : 0;
	DSpFrontStagingPresentState &present =
		ctx->front_staging_present_state;
	if (present.valid && present.encoded && present.last_hash == hash &&
		present.last_size == required &&
		present.last_gamma_gen == color_generation &&
		present.last_fade_active == fade_active) {
		present.unchanged_skips++;
		return true;
	}

	GLuint fb_tex = (GLuint)(uintptr_t)framebuffer_texture;
	if (!fb_tex || !SharedMetalDevice()) return false;

	static std::vector<uint8_t> rgba;
	uint32_t visible_x = 0, visible_y = 0, geometry_row = 0,
			 geometry_height = 0;
	DSpGLGetFrontStagingGeometry(ctx, w, h, depth, &geometry_row,
							   &geometry_height, &visible_x, &visible_y);
	if (geometry_row != row || geometry_height > storage_h ||
		visible_y + h > geometry_height) return false;
	expand_surface_to_rgba(ctx, front, w, h, depth, row, rgba,
						   visible_x, visible_y);
	glBindTexture(GL_TEXTURE_2D, fb_tex);
	glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, (GLsizei)w, (GLsizei)h,
					GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());

	DSpFrontStagingRememberHashForGamma(
		&present, hash, required, color_generation, fade_active);
	return true;
}

extern "C" uint32_t DSpGetFrontBufferCGrafPtrGL(DSpContextPrivate *ctx)
{
	if (!ctx || !ctx->back_buffer) return 0;

	const uint32_t depth = DSpFrontBufferDepth(
		ctx->attr.backBufferBestDepth, ctx->attr.displayBestDepth);
	const uint32_t w = ctx->attr.displayWidth;
	const uint32_t h = ctx->attr.displayHeight;
	uint32_t row = 0;
	uint32_t storage_h = 0;
	DSpGLGetFrontStagingGeometry(ctx, w, h, depth, &row, &storage_h);
	const uint64_t size64 = (uint64_t)row * storage_h;
	if (!w || !h || !DSpGLIsValidDepth(depth) || !row || size64 > UINT32_MAX)
		return 0;
	const uint32_t size = (uint32_t)size64;

	if (!ctx->front_staging_mac_addr || ctx->front_staging_size < size ||
		ctx->front_staging_row_bytes != row ||
		ctx->front_staging_height != storage_h) {
		const uint32_t pixels = Mac_sysalloc(size);
		uint8_t *dst = pixels ? Mac2HostAddr(pixels) : nullptr;
		if (!pixels || !dst) return 0;
		ctx->front_staging_mac_addr = pixels;
		ctx->front_staging_size = size;
		ctx->front_staging_owned_sysheap = true;
		ctx->front_staging_row_bytes = row;
		ctx->front_staging_height = storage_h;

		const uint32_t back_row = DSpBackBufferAlignedRowBytes(
			DSpContextBackBufferWidth(ctx), ctx->attr.backBufferBestDepth);
		if (DSpShouldSeedFrontBufferStagingFromBackStaging(
				ctx->attr.backBufferBestDepth, depth,
				ctx->staging_mac_addr, ctx->staging_size, back_row,
				size, row)) {
			uint8_t *src = Mac2HostAddr(ctx->staging_mac_addr);
			if (src) std::memcpy(dst, src, size);
			else std::memset(dst, 0, size);
			ctx->front_staging_refresh_swap_generation =
				ctx->swap_generation;
		} else {
			std::memset(dst, 0, size);
		}
		DSpFrontStagingRememberSeedBytes(
			&ctx->front_staging_present_state, dst, size);
	}

	/* A movie may close/reset QuickDraw state and then ask DSp for the front
	 * buffer again.  Do not return the old CGrafPort: Toolbox teardown can
	 * leave its internal handles containing the guest heap poison EFADBEEF.
	 * Re-emit the small descriptor graph in permanent SheepMem while reusing
	 * the actual pixel surface above. */
	const uint32_t pixmap = SheepMem::Reserve(DSpFrontBufferPixMapRecordSize());
	const uint32_t pixmap_handle = SheepMem::Reserve(DSpBackBufferPixMapHandleSize());
	const uint32_t port = SheepMem::Reserve(DSpBackBufferCGrafPortSize());
	const uint32_t vis_region = DSpGLAllocRectRegion(w, h);
	const uint32_t clip_region = DSpGLAllocRectRegion(w, h);
	if (!pixmap || !pixmap_handle || !port || !vis_region || !clip_region)
		return 0;

	uint16_t pixel_type = 0, pixel_size = 0, component_count = 0,
			 component_size = 0;
	DSpGLGetPixmapFormat(depth, &pixel_type, &pixel_size, &component_count,
					  &component_size);
	/* Preserve the real screen PixMap's otherwise-unspecified metadata, as the
	 * Metal emitter does, then replace every surface-dependent field. */
	if (ctx->saved_pixmap_valid && ctx->saved_pixmap_addr)
		Host2Mac_memcpy(pixmap, Mac2HostAddr(ctx->saved_pixmap_addr),
						DSpFrontBufferPixMapRecordSize());
	else
		Mac_memset(pixmap, 0, DSpFrontBufferPixMapRecordSize());
	WriteMacInt32(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_BASEADDR,
				  ctx->front_staging_mac_addr);
	WriteMacInt16(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_ROWBYTES,
				  DSpFrontBufferPixMapRowBytesField(row));
	WriteMacInt16(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_TOP, 0);
	WriteMacInt16(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_LEFT, 0);
	WriteMacInt16(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_BOT, (uint16_t)h);
	WriteMacInt16(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_RIGHT, (uint16_t)w);
	WriteMacInt32(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_HRES, 0x00480000u);
	WriteMacInt32(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_VRES, 0x00480000u);
	WriteMacInt16(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_PIXELTYPE, pixel_type);
	WriteMacInt16(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_PIXELSIZE, pixel_size);
	WriteMacInt16(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_CMPCOUNT, component_count);
	WriteMacInt16(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_CMPSIZE, component_size);
	WriteMacInt32(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_PLANEBYTES, 0);
	/* An indexed front CGrafPort needs the screen's ColorTable handle for
	 * QuickDraw color matching.  Activation cached the original MainDevice
	 * PixMap before redirecting it, so preserve that table on the vended port. */
	if (depth <= 8 && ctx->saved_pixmap_valid && ctx->saved_pixmap_addr) {
		WriteMacInt32(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_PMTABLE,
					  ReadMacInt32(ctx->saved_pixmap_addr +
								   DSP_MAINDEVICE_PIXMAP_OFF_PMTABLE));
	}
	WriteMacInt32(pixmap_handle, pixmap);

	Mac_memset(port, 0, DSpBackBufferCGrafPortSize());
	WriteMacInt32(port + DSP_CGRAFPORT_OFF_PORT_PIXMAP, pixmap_handle);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_PORT_VERSION, 0xC000);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_PORT_RECT + 0, 0);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_PORT_RECT + 2, 0);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_PORT_RECT + 4, (uint16_t)h);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_PORT_RECT + 6, (uint16_t)w);
	WriteMacInt32(port + DSP_CGRAFPORT_OFF_VIS_RGN, vis_region);
	WriteMacInt32(port + DSP_CGRAFPORT_OFF_CLIP_RGN, clip_region);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_RGB_FG_COLOR + 0, 0xffff);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_RGB_FG_COLOR + 2, 0xffff);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_RGB_FG_COLOR + 4, 0xffff);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_RGB_BK_COLOR + 0, 0);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_RGB_BK_COLOR + 2, 0);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_RGB_BK_COLOR + 4, 0);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_PN_SIZE + 0, 1);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_PN_SIZE + 2, 1);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_PN_MODE, 8);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_TX_SIZE, 12);
	WriteMacInt32(port + DSP_CGRAFPORT_OFF_FG_COLOR, 0xffffffffu);
	WriteMacInt32(port + DSP_CGRAFPORT_OFF_BK_COLOR, 0x00000000u);

	ctx->front_cgrafptr_mac_addr = port;
	ctx->front_pixmap_mac_addr = pixmap;
	ctx->front_pixmap_handle_mac_addr = pixmap_handle;
	QD3D_RESOURCE_LOG("DSpGetFrontBuffer(GL): ctx=%u port=0x%08x pixmap=0x%08x base=0x%08x front=%ux%u@%u row=%u storageH=%u size=%u",
					  ctx->handle, port, pixmap,
					  ctx->front_staging_mac_addr, w, h, depth, row,
					  storage_h, size);
	return port;
}

uint32_t DSpGetBackBufferCGrafPtr(DSpContextPrivate *ctx)
{
	if (!ctx || !ctx->back_buffer) return 0;
	if (ctx->cgrafptr_mac_addr) return ctx->cgrafptr_mac_addr;

	const uint32_t bpp = ctx->attr.backBufferBestDepth;
	const uint32_t w = DSpContextBackBufferWidth(ctx);
	const uint32_t h = DSpContextBackBufferHeight(ctx);
	uint32_t row_bytes = 0;
	uint32_t buffer_size = 0;
	if (!DSpGLIsValidBackBufferLayout(w, h, bpp, &row_bytes, &buffer_size)) return 0;

	if (!ctx->staging_mac_addr || ctx->staging_size < buffer_size) {
		const uint32_t pixels = Mac_sysalloc(buffer_size);
		if (!pixels || !Mac2HostAddr(pixels)) return 0;
		ctx->staging_mac_addr = pixels;
		ctx->staging_size = buffer_size;
		ctx->staging_owned_sysheap = true;
		std::memcpy(Mac2HostAddr(pixels), ctx->back_buffer, buffer_size);
	}

	const uint32_t pixmap = SheepMem::Reserve(DSpBackBufferPixMapRecordSize());
	const uint32_t pixmap_handle = SheepMem::Reserve(DSpBackBufferPixMapHandleSize());
	const uint32_t port = SheepMem::Reserve(DSpBackBufferCGrafPortSize());
	const uint32_t vis_region = DSpGLAllocRectRegion(w, h);
	const uint32_t clip_region = DSpGLAllocRectRegion(w, h);
	if (!pixmap || !pixmap_handle || !port || !vis_region || !clip_region)
		return 0;

	uint16_t pixel_type = 0, pixel_size = 0, component_count = 0,
			 component_size = 0;
	DSpGLGetPixmapFormat(bpp, &pixel_type, &pixel_size, &component_count,
					  &component_size);
	Mac_memset(pixmap, 0, DSpBackBufferPixMapRecordSize());
	WriteMacInt32(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_BASEADDR, ctx->staging_mac_addr);
	WriteMacInt16(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_ROWBYTES,
				  DSpBackBufferPixMapRowBytesField(row_bytes));
	WriteMacInt16(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_TOP, 0);
	WriteMacInt16(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_LEFT, 0);
	WriteMacInt16(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_BOT, (uint16_t)h);
	WriteMacInt16(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_BOUNDS_RIGHT, (uint16_t)w);
	WriteMacInt32(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_HRES, 0x00480000u);
	WriteMacInt32(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_VRES, 0x00480000u);
	WriteMacInt16(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_PIXELTYPE, pixel_type);
	WriteMacInt16(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_PIXELSIZE, pixel_size);
	WriteMacInt16(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_CMPCOUNT, component_count);
	WriteMacInt16(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_CMPSIZE, component_size);
	WriteMacInt32(pixmap + DSP_MAINDEVICE_PIXMAP_OFF_PLANEBYTES, 0);
	WriteMacInt32(pixmap_handle, pixmap);

	Mac_memset(port, 0, DSpBackBufferCGrafPortSize());
	WriteMacInt32(port + DSP_CGRAFPORT_OFF_PORT_PIXMAP, pixmap_handle);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_PORT_VERSION, 0xC000);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_PORT_RECT + 0, 0);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_PORT_RECT + 2, 0);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_PORT_RECT + 4, (uint16_t)h);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_PORT_RECT + 6, (uint16_t)w);
	WriteMacInt32(port + DSP_CGRAFPORT_OFF_VIS_RGN, vis_region);
	WriteMacInt32(port + DSP_CGRAFPORT_OFF_CLIP_RGN, clip_region);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_RGB_FG_COLOR + 0, 0xffff);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_RGB_FG_COLOR + 2, 0xffff);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_RGB_FG_COLOR + 4, 0xffff);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_RGB_BK_COLOR + 0, 0);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_RGB_BK_COLOR + 2, 0);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_RGB_BK_COLOR + 4, 0);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_PN_SIZE + 0, 1);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_PN_SIZE + 2, 1);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_PN_MODE, 8);
	WriteMacInt16(port + DSP_CGRAFPORT_OFF_TX_SIZE, 12);
	WriteMacInt32(port + DSP_CGRAFPORT_OFF_FG_COLOR, 0xffffffffu);
	WriteMacInt32(port + DSP_CGRAFPORT_OFF_BK_COLOR, 0x00000000u);

	ctx->cgrafptr_mac_addr = port;
	QD3D_RESOURCE_LOG("DSpGetBackBuffer(GL): ctx=%u port=0x%08x pixmap=0x%08x base=0x%08x back=%ux%u@%u row=%u size=%u",
					  ctx->handle, port, pixmap, ctx->staging_mac_addr, w, h,
					  bpp, row_bytes, buffer_size);
	return port;
}

static void dsp_refresh_front_staging_after_swap(DSpContextPrivate *ctx)
{
	if (!ctx || !ctx->front_staging_mac_addr || !ctx->staging_mac_addr)
		return;
	const uint32_t front_depth = DSpFrontBufferDepth(
		ctx->attr.backBufferBestDepth, ctx->attr.displayBestDepth);
	const uint32_t back_row = DSpBackBufferAlignedRowBytes(
		DSpContextBackBufferWidth(ctx), ctx->attr.backBufferBestDepth);
	const uint32_t front_row = ctx->front_staging_row_bytes;
	if (!DSpShouldRefreshFrontBufferStagingFromBackStaging(
			ctx->attr.backBufferBestDepth, front_depth,
			ctx->staging_mac_addr, ctx->front_staging_mac_addr,
			ctx->staging_size, ctx->front_staging_size,
			back_row, front_row, ctx->swap_generation,
			ctx->front_staging_refresh_swap_generation, false))
		return;

	uint8_t *src = Mac2HostAddr(ctx->staging_mac_addr);
	uint8_t *dst = Mac2HostAddr(ctx->front_staging_mac_addr);
	if (!src || !dst) return;
	std::memcpy(dst, src, ctx->front_staging_size);
	ctx->front_staging_refresh_swap_generation = ctx->swap_generation;
	DSpFrontStagingRememberSeedBytes(
		&ctx->front_staging_present_state, dst, ctx->front_staging_size);
}
int32_t DSpContext_SwapBuffersHandler(uint32_t ctxRef,
	uint32_t /*doneProc*/, uint32_t /*refCon*/)
{
	DSpContextPrivate *ctx = DSpGetContext(ctxRef);
	if (!ctx || !ctx->back_buffer) return kDSpInternalErr;
	/* Copy guest staging -> host back buffer */
	if (ctx->staging_mac_addr && ctx->staging_size) {
		const uint32_t w = DSpContextBackBufferWidth(ctx);
		const uint32_t h = DSpContextBackBufferHeight(ctx);
		const uint32_t row = DSpBackBufferAlignedRowBytes(
			w, ctx->attr.backBufferBestDepth);
		const uint64_t expected64 = (uint64_t)row * h;
		const uint32_t expected = expected64 <= UINT32_MAX
			? (uint32_t)expected64 : 0;
		uint8 *src = Mac2HostAddr(ctx->staging_mac_addr);
		const uint32_t copy_size = expected
			? std::min(expected, ctx->staging_size) : 0;
		if (src && copy_size) std::memcpy(ctx->back_buffer, src, copy_size);
		if (copy_size != expected) {
			QD3D_RENDER_LOG("DSpSwap(GL): bounded staging copy ctx=%u have=%u expected=%u copied=%u",
							ctxRef, ctx->staging_size, expected, copy_size);
		}
	}
	ctx->swap_generation++;
	/* A swap replaces the visible page.  Keep a separately vended front
	 * surface in sync once per swap; otherwise its stale initial pixels would
	 * be republished by the VBL path over the newly swapped frame. */
	dsp_refresh_front_staging_after_swap(ctx);
	ctx->explicit_swap_observed = true;
	ctx->dirty_cold_start = false;
	ctx->dirty_empty = true;

	/* Present into compositor-owned framebuffer texture (same contract as
	 * Metal): DSp expands guest pixels into s_fb_tex; Present samples that
	 * texture without a host-buffer re-upload while DSp owns the display. */
	void *fb = MetalCompositorGetFramebufferTexture();
	if (!fb) return kDSpInternalErr;
	DSpEncodePresentToFramebuffer(ctx, nullptr, fb);

	/* Engine-blind SubmitFrame (descriptor validation + stale-gen reject).
	 * Production Present composites s_fb_tex as the classic layer; the
	 * framebuffer slot is recorded for occlusion/diagnostics parity. */
	struct CompositeLayer layer;
	std::memset(&layer, 0, sizeof(layer));
	layer.source       = fb;
	layer.src_origin_x = 0;
	layer.src_origin_y = 0;
	layer.src_size_w   = ctx->attr.displayWidth;
	layer.src_size_h   = ctx->attr.displayHeight;
	layer.dst_origin_x = 0.0f;
	layer.dst_origin_y = 0.0f;
	layer.dst_size_w   = (float)ctx->attr.displayWidth;
	layer.dst_size_h   = (float)ctx->attr.displayHeight;
	layer.slot         = kLayerSlotFramebuffer;
	layer.blend        = kBlendOpaque;
	layer.alpha        = 1.0f;

	const struct DMCModeSnapshot *snap = dmc_current_snapshot();
	struct FrameDescriptor desc;
	desc.layers               = &layer;
	desc.layer_count          = 1;
	desc.generation           = snap ? snap->generation : 0;
	desc.vbl_tick_target_usec = 0;
	(void)MetalCompositorSubmitFrame(&desc);
	return kDSpNoErr;
}

extern "C" void DSpVBLCompositorPublishCallback(void *cb_ctx,
												void *drawable,
												double ts)
{
	(void)cb_ctx; (void)drawable; (void)ts;

	const DMCModeSnapshot *snap = dmc_current_snapshot();
	if (snap == nullptr || snap->transitioning != 0)
		return;

	DSpContextPrivate *active = nullptr;
	for (uint32_t i = 0; i < DSP_MAX_CONTEXTS; i++) {
		DSpContextPrivate *ctx = DSpGetContext(i + 1);
		if (ctx == nullptr) continue;
		if (ctx->state != (uint32_t)kDSpContextState_Active) continue;
		if (ctx->back_buffer == nullptr) continue;
		active = ctx;
		break;
	}
	if (active == nullptr) return;

	const bool present_front_staging =
		DSpShouldPresentFrontBufferStagingForState(
			active->attr.backBufferBestDepth,
			active->attr.displayBestDepth,
			active->front_staging_mac_addr,
			active->front_staging_size,
			active->state,
			(uint32_t)kDSpContextState_Active);
	if (!DSpShouldPublishActiveContextOnVBL(snap->active_owner,
											(uint32_t)kDMCOwnerDSp,
											active != nullptr,
											present_front_staging,
											active->explicit_swap_observed)) {
		return;
	}

	/* Drain guest staging -> host back_buffer before expand/upload. */
	if (active->staging_mac_addr != 0 && active->staging_size != 0) {
		const uint32_t w = DSpContextBackBufferWidth(active);
		const uint32_t h = DSpContextBackBufferHeight(active);
		const uint32_t row = DSpBackBufferAlignedRowBytes(
			w, active->attr.backBufferBestDepth);
		const uint64_t expected64 = (uint64_t)row * h;
		const uint32_t expected = expected64 <= UINT32_MAX
			? (uint32_t)expected64 : 0;
		uint8_t *src = Mac2HostAddr(active->staging_mac_addr);
		const uint32_t copy_size = expected
			? std::min(expected, active->staging_size) : 0;
		if (src && copy_size && active->back_buffer)
			std::memcpy(active->back_buffer, src, copy_size);
	}

	void *fb = MetalCompositorGetFramebufferTexture();
	if (!fb || !SharedMetalDevice()) return;

	bool front_presented = false;
	if (present_front_staging) {
		front_presented =
			DSpEncodeFrontBufferStagingToFramebuffer(active, nullptr, fb);
	}
	if (!front_presented)
		DSpEncodePresentToFramebuffer(active, nullptr, fb);

	struct CompositeLayer layer;
	std::memset(&layer, 0, sizeof(layer));
	layer.source       = fb;
	layer.src_origin_x = 0;
	layer.src_origin_y = 0;
	layer.src_size_w   = active->attr.displayWidth;
	layer.src_size_h   = active->attr.displayHeight;
	layer.dst_origin_x = 0.0f;
	layer.dst_origin_y = 0.0f;
	layer.dst_size_w   = (float)active->attr.displayWidth;
	layer.dst_size_h   = (float)active->attr.displayHeight;
	layer.slot         = kLayerSlotFramebuffer;
	layer.blend        = kBlendOpaque;
	layer.alpha        = 1.0f;

	struct FrameDescriptor desc;
	desc.layers               = &layer;
	desc.layer_count          = 1;
	desc.generation           = snap->generation;
	desc.vbl_tick_target_usec = 0;
	(void)MetalCompositorSubmitFrame(&desc);
}

void* DSpGetBackingContents(void* backing)
{
	return backing;
}

/* Host bridge - desktop: track Active fullscreen without iOS idle-timer */
static bool s_dsp_active_fullscreen = false;
extern "C" void DSpHostBridge_SetActiveFullscreen(bool active)
{
	s_dsp_active_fullscreen = active;
}
extern "C" bool DSpHostBridge_GetActiveFullscreen(void)
{
	return s_dsp_active_fullscreen;
}
extern "C" void DSpHostBridgeInit(void)
{
	s_dsp_active_fullscreen = false;
}
extern "C" void DSpHostBridgeShutdown(void)
{
	s_dsp_active_fullscreen = false;
}

bool DSpAllocAltBufferBacking(DSpAltBufferRecord *rec,
	uint32_t w, uint32_t h) {
	bool res;
	if (rec == nullptr || w == 0 || h == 0) return false;
	if (w > DSP_ALT_MAX_DIM || h > DSP_ALT_MAX_DIM) {
		fprintf(stderr, "DSpAllocAltBufferBacking: "
			"dims %ux%u exceed DSP_ALT_MAX_DIM\n", w, h);
		return false;
	}

	res = DSpDoAllocateBackBuffer(w, h, rec->depth,
		&rec->backing, &rec->texture);
	if (res == false) {
		DSP_LOG("DSpAllocAltBufferBacking: DSpAllocateBackBuffer failed "
				"(%ux%u@%u)", w, h, rec->depth);
		gfxaccel_resources_heap_note_allocation_released(kHeapEngineDSp);
		return false;
	}
	rec->width = w;
	rec->height = h;
	return true;
}
void DSpContextPrivateReleaseBackBufferVariables(void** texture,void** buffer)
{
}
void DSpContextPrivateReleaseBackBuffer(DSpContextPrivate* ctx)
{
}
