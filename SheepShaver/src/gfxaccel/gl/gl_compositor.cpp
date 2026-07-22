/*
 *  gl_compositor.cpp - OpenGL+SDL compositor (implements metal_compositor.h)
 *
 *  Desktop counterpart of metal_compositor.mm: presents the Mac framebuffer
 *  (all classic depths) plus a cached RAVE/GL overlay into the SDL window.
 */

#include "sysdeps.h"
#include "cpu_emulation.h"   /* ReadMacInt32 (guest tick at 0x016a) */
#include "video.h"
#include "video_blit.h"
#include "metal_device_shared.h"
#include "metal_compositor.h"
#include "display_mode_controller.h"
#include "gfxaccel_resources.h"
#include "vbl_source.h"
#include "gfx_color_policy.h"
#include "gfx_log.h"
/* Windows GL 1.1 has no GLSL compile entry points; present path uses FFP. */

#include <SDL.h>
#include <SDL_opengl.h>
#include "gl_ext.h" /* GL_RGBA8 / GL_BGRA / FBO enums for Windows GL 1.1 */

#include <atomic>
#include <cassert>
#include <chrono>
#include <cstring>
#include <cstdio>
#include <vector>
#include <cmath>

extern SDL_Window *sdl_window;


extern SDL_Window *sdl_window;
SDL_Window *gl_device_sdl_window = nullptr;

static SDL_GLContext s_gl_ctx = nullptr;
static bool s_ready = false;

/* Opaque sentinels so code that null-checks SharedMetalDevice() still works. */
static char s_device_sentinel = 1;
static char s_queue_sentinel = 1;

bool GfxGLDeviceInit(void)
{ /* Should ONLY be called by MetalCompositorInit or otherwise
	the backing variables will not be recreated correctly and it will
	white screen */
	QD3D_INIT_LOG("GfxGLDeviceInit: ready=%d context=%p window=%p",
	              s_ready, s_gl_ctx, (void *)sdl_window);

	if (!sdl_window) {
		QD3D_INIT_LOG("GfxGLDeviceInit: FAILED because SDL window is null");
		fprintf(stderr, "[gfxaccel-gl] GfxGLDeviceInit: sdl_window is NULL\n");
		return false;
	}

	/* Prefer a compatibility profile so Mac GL 1.2 FFP maps cleanly. */
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 1);
	SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
	SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
	SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);
#if defined(SDL_GL_CONTEXT_PROFILE_MASK)
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_COMPATIBILITY);
#endif

	if (s_gl_ctx) {
		SDL_GL_DeleteContext(s_gl_ctx);
		s_gl_ctx = nullptr;
	}

	s_gl_ctx = SDL_GL_CreateContext(sdl_window);
	if (!s_gl_ctx) {
		QD3D_INIT_LOG("GfxGLDeviceInit: SDL_GL_CreateContext FAILED: %s", SDL_GetError());
		fprintf(stderr, "[gfxaccel-gl] SDL_GL_CreateContext failed: %s\n", SDL_GetError());
		s_ready = false;
		return false;
	}

	if (SDL_GL_MakeCurrent(sdl_window, s_gl_ctx) != 0) {
		QD3D_INIT_LOG("GfxGLDeviceInit: SDL_GL_MakeCurrent FAILED: %s", SDL_GetError());
		fprintf(stderr, "[gfxaccel-gl] SDL_GL_MakeCurrent failed: %s\n", SDL_GetError());
		SDL_GL_DeleteContext(s_gl_ctx);
		s_gl_ctx = nullptr;
		s_ready = false;
		return false;
	}

	/* Never block the emulator thread on vsync. Present is invoked from
	 * VideoVBL on the emul thread; SwapInterval(1) + full-frame uploads
	 * at 2560x1440 starves PPC execution and looks like a hard lockup. */
	SDL_GL_SetSwapInterval(0);

	const char *vendor = (const char *)glGetString(GL_VENDOR);
	const char *renderer = (const char *)glGetString(GL_RENDERER);
	const char *version = (const char *)glGetString(GL_VERSION);
	fprintf(stderr, "[gfxaccel-gl] OpenGL ready: %s / %s / %s\n",
	        vendor ? vendor : "?",
	        renderer ? renderer : "?",
	        version ? version : "?");

	gl_device_sdl_window = sdl_window;
	s_ready = true;
	QD3D_INIT_LOG("GfxGLDeviceInit: SUCCESS context=%p vendor='%s' renderer='%s' version='%s'",
	              s_gl_ctx, vendor ? vendor : "?", renderer ? renderer : "?",
	              version ? version : "?");
	return true;
}

void GfxGLDeviceShutdown(void)
{
	if (s_gl_ctx) {
		if (gl_device_sdl_window)
			SDL_GL_MakeCurrent(gl_device_sdl_window, nullptr);
		SDL_GL_DeleteContext(s_gl_ctx);
		s_gl_ctx = nullptr;
	}
	s_ready = false;
}

bool GfxGLDeviceIsReady(void)
{
	return s_ready && s_gl_ctx != nullptr;
}

void GfxGLDeviceSwap(void)
{
	assert(s_ready);
	assert(s_gl_ctx != nullptr);
	assert(gl_device_sdl_window != nullptr);
	SDL_GL_SwapWindow(gl_device_sdl_window);
}

void GfxGLDeviceGetDrawableSize(int *out_w, int *out_h)
{
	assert(s_ready);
	assert(s_gl_ctx != nullptr);
	assert(gl_device_sdl_window != nullptr);
	assert(out_w != nullptr);
	assert(out_h != nullptr);
	SDL_GL_GetDrawableSize(gl_device_sdl_window, out_w, out_h);
}

void *SharedMetalDevice(void)
{
	/* Twin of metal_device_shared: return the shared GPU device, making the
	 * compositor GL context current only when the thread is on a different
	 * context/window. The previous `ctx != s_gl_ctx || MakeCurrent(...)`
	 * short-circuit was inverted: when the context was already wrong the
	 * `||` never called MakeCurrent and every Present/upload returned NULL
	 * (desktop appeared frozen for long stretches between rare successes). */
	if (!s_ready || !s_gl_ctx || !gl_device_sdl_window)
		return NULL;
	if (SDL_GL_GetCurrentContext() != s_gl_ctx ||
	    SDL_GL_GetCurrentWindow() != gl_device_sdl_window) {
		if (SDL_GL_MakeCurrent(gl_device_sdl_window, s_gl_ctx) != 0) {
			QD3D_INIT_LOG("SDL_GL_MakeCurrent failed: %s", SDL_GetError());
			return NULL;
		}
	}
	return (void *)&s_device_sentinel;
}

void *SharedMetalCommandQueue(void)
{
	return SharedMetalDevice();
}

void MetalValidation_InstallErrorHandler(void * /*cmdBufPtr*/)
{
	/* no-op on OpenGL */
}

extern "C" void vbl_source_sdl_tick(double target_ts);
extern "C" int RaveGLRenderPassActive(void);

/* Set when Present is skipped because a RAVE (or nested) pass owns the
 * shared GL context. Cleared when a Present completes or is cancelled. */
static bool s_present_deferred = false;

/* Metal (iOS) reads the "Linear" gamma pref through the ObjC bridge. The
 * desktop/SDL build has no such pref plumbing, so default to the OS-defined
 * (apply_correction = true) policy to stay in lock-step with Metal's default
 * presentation. When the bridge is compiled in, honor it so the two backends
 * apply an identical transform to the guest LUT. */
#if defined(__APPLE__) && defined(TARGET_OS_IPHONE)
extern bool objc_getIsLinearGammaEnabled(void);
static inline bool gl_compositor_is_linear_gamma(void) {
	return objc_getIsLinearGammaEnabled();
}
#else
static inline bool gl_compositor_is_linear_gamma(void) { return false; }
#endif

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------
#include "gfx_log.h"
#define COMPOSITOR_LOG(...) GFX_DEBUG_EMIT("[compositor] ", __VA_ARGS__)
#define COMPOSITOR_ERR(...) GFX_DEBUG_EMIT("[compositor ERROR] ", __VA_ARGS__)

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
static bool s_init = false;
static bool s_present_in_progress = false;
static int compositor_pixel_width = 0, compositor_pixel_height = 0, compositor_depth = 0;
static int compositor_row_bytes = 0, compositor_pitch = 0;
static int compositor_bits_per_pixel = 0;
static void *compositor_buffer = nullptr;
static uint32_t compositor_buffer_size = 0;

/* DSp OnModeEnter Resize passes buffer=NULL (engine writes s_fb_tex).  Diablo's
 * dual-context scan can leave DMC on QuickDraw without a restore mode switch
 * (handoff suppressed on the parent; child never redirected).  Stash the last
 * classic host surface so we can rebind it when the owner returns to QD. */
static void *s_classic_host_stash = nullptr;
static uint32_t s_classic_host_stash_size = 0;
static int s_classic_host_stash_w = 0;
static int s_classic_host_stash_h = 0;
static int s_classic_host_stash_depth = 0;
static int s_classic_host_stash_rb = 0;
static int s_classic_host_stash_pitch = 0;

static GLuint s_fb_tex = 0;
static int s_fb_tex_width = 0;
static int s_fb_tex_height = 0;
static GLuint s_palette_tex = 0;   /* 256x1 RGB for indexed */
static GLuint s_prog_32 = 0, s_prog_16 = 0, s_prog_idx = 0, s_prog_overlay = 0;
static GLuint s_gamma_tex = 0;

static uint8_t s_palette[256 * 4];
static uint8_t s_gamma_lut[768];
static uint8_t s_gamma_identity[768];
static bool s_palette_dirty = true;
static bool s_gamma_is_identity = true;

/* Overlay mailbox (SubmitFrame caches last overlay). */
static CompositeLayer s_overlay_cache;
static bool s_overlay_valid = false;
static GLuint s_overlay_tex_cache = 0; /* GL name retained as GLuint in void* */
static uint64_t s_overlay_submit_serial = 0;
static uint64_t s_overlay_present_serial = 0;
/*
 * Some RAVE applications keep their draw context allocated when returning to
 * a QuickDraw menu.  Remember the guest framebuffer as it stood when the last
 * RAVE frame was submitted: a later write to it is an implicit ownership
 * handoff even if the application never calls QAEngineDisable.
 */
static std::vector<uint8_t> s_overlay_fb_baseline;
static uint64_t s_last_overlay_submit_usec = 0;
static std::vector<uint8_t> s_classic_fb_upload_baseline;
static bool s_classic_fb_texture_valid = false;
static CompositeLayer s_framebuffer_cache;
static bool s_framebuffer_valid = false;
static GLuint s_framebuffer_tex_cache = 0;
#if QD3D_GRAPHICS_LOGGING_ENABLED
static uint64_t s_overlay_submit_count = 0;
static uint64_t s_present_count = 0;

static bool compositor_trace_sample(uint64_t count)
{
	return count <= 8 || (count != 0 && (count & (count - 1)) == 0) ||
	       (count % 120) == 0;
}
#endif

class ScopedCompositorPresent
{
public:
	ScopedCompositorPresent()
	{
		assert(!s_present_in_progress);
		s_present_in_progress = true;
	}

	~ScopedCompositorPresent()
	{
		assert(s_present_in_progress);
		s_present_in_progress = false;
	}

	ScopedCompositorPresent(const ScopedCompositorPresent &) = delete;
	ScopedCompositorPresent &operator=(const ScopedCompositorPresent &) = delete;
};

/* Present-rect cache (window coords). */
static std::atomic<uint64_t> s_present_origin{0};
static std::atomic<uint64_t> s_present_size{0};

/* Framebuffer texture handle exported to DSp as void*. */
static GLuint s_fb_tex_export = 0;

static size_t visible_framebuffer_bytes(void)
{
	if (!compositor_buffer || compositor_row_bytes <= 0 || compositor_pixel_height <= 0)
		return 0;
	const size_t visible = (size_t)compositor_row_bytes * (size_t)compositor_pixel_height;
	return visible < (size_t)compositor_buffer_size ? visible : (size_t)compositor_buffer_size;
}

static uint64_t compositor_now_usec(void)
{
	return (uint64_t)std::chrono::duration_cast<std::chrono::microseconds>(
		std::chrono::steady_clock::now().time_since_epoch()).count();
}

/* Match metal_compositor.mm MetalCompositorPresent: when DSp owns the
 * display it writes compositor_texture via DSpEncode*ToFramebuffer. A CPU
 * re-upload from compositor_buffer (often NULL after OnModeEnter Resize)
 * would clobber those pixels with black every VBL. RAVE/GL (and later Glide)
 * still need the QuickDraw underlay so they keep the classic upload path. */
static bool classic_cpu_upload_allowed(void)
{
	if (!compositor_buffer)
		return false;
	const DMCModeSnapshot *snap = dmc_current_snapshot();
	if (snap != nullptr) {
		const uint32_t owner = snap->active_owner;
		/* Metal: skip CPU upload only for non-underlay owners (DSp, blanking…).
		 * Overlay engines (RAVE/GL/Glide) keep the classic base. */
		if (owner != (uint32_t)kDMCOwnerQuickDraw &&
		    owner != (uint32_t)kDMCOwnerRAVE &&
		    owner != (uint32_t)kDMCOwnerGL &&
		    owner != (uint32_t)kDMCOwnerGlide) {
			return false;
		}
	}
	return true;
}

static bool classic_framebuffer_needs_upload(void)
{
	if (!classic_cpu_upload_allowed())
		return false;
	const size_t bytes = visible_framebuffer_bytes();
	assert(bytes == 0 || compositor_buffer != nullptr);
	if (!s_classic_fb_texture_valid ||
	    bytes != s_classic_fb_upload_baseline.size()) {
#if DESCENT_HITCH_DEBUG
		static int s_nu_force_log = 0;
		if (s_nu_force_log++ < 40)
			gfx_log_emit("[compositor] ",
				"needsUpload FORCE valid=%d bytes=%zu baseSize=%zu",
				s_classic_fb_texture_valid ? 1 : 0,
				bytes, s_classic_fb_upload_baseline.size());
#endif
		return true;
	}
	const bool diff = bytes != 0 &&
		std::memcmp(compositor_buffer, s_classic_fb_upload_baseline.data(), bytes) != 0;
#if DESCENT_HITCH_DEBUG
	static int s_nu_diff_log = 0;
	if (s_nu_diff_log++ < 40)
		gfx_log_emit("[compositor] ",
			"needsUpload memcmp diff=%d bytes=%zu", diff ? 1 : 0, bytes);
#endif
	return diff;
}

static void remember_classic_framebuffer_upload(void)
{
	const size_t bytes = visible_framebuffer_bytes();
	assert(bytes == 0 || compositor_buffer != nullptr);
	s_classic_fb_upload_baseline.resize(bytes);
	if (bytes != 0)
		std::memcpy(s_classic_fb_upload_baseline.data(), compositor_buffer, bytes);
	s_classic_fb_texture_valid = true;
}

static void remember_overlay_framebuffer_baseline(void)
{
	const size_t bytes = visible_framebuffer_bytes();
	if (bytes == 0) {
		s_overlay_fb_baseline.clear();
		return;
	}
	const uint8_t *src = static_cast<const uint8_t *>(compositor_buffer);
	s_overlay_fb_baseline.assign(src, src + bytes);
}

static void detect_implicit_quickdraw_handoff(void)
{
	if (!s_overlay_valid || s_overlay_fb_baseline.empty())
		return;

	const DMCModeSnapshot *snap = dmc_current_snapshot();
	if (!snap || snap->active_owner != (uint32_t)kDMCOwnerRAVE)
		return;

	const size_t bytes = visible_framebuffer_bytes();
	if (bytes != s_overlay_fb_baseline.size())
		return;
	if (std::memcmp(compositor_buffer, s_overlay_fb_baseline.data(), bytes) == 0)
		return;
	/* At 60 Hz a VideoVBL can land between two RAVE frames. Descent writes
	 * incidental QuickDraw data while its RAVE context remains live; treating
	 * that single write as an immediate owner change clears the cached overlay
	 * until the next RenderEnd and produces severe alternating-frame flicker.
	 * A real menu handoff stops RAVE submissions, so wait for a short quiet
	 * interval before accepting the framebuffer write as authoritative. */
	static constexpr uint64_t kRaveHandoffQuietUsec = 250000u;
	const uint64_t now = compositor_now_usec();
	if (s_last_overlay_submit_usec != 0 &&
	    now - s_last_overlay_submit_usec < kRaveHandoffQuietUsec)
		return;

	QD3D_RENDER_LOG("CompositorQuickDrawHandoff: guest framebuffer changed after the last RAVE frame; restoring QuickDraw owner");
	/* The compositor's DMC exit callback clears both the cached overlay and
	 * this baseline before the next present. */
	(void)dmc_set_active_owner((uint32_t)kDMCOwnerQuickDraw);
}

// ---------------------------------------------------------------------------
// Shaders (GLSL 1.20 compatibility)
// ---------------------------------------------------------------------------
static const char *kVS = R"GLSL(
#version 120
varying vec2 v_uv;
void main() {
  // Fullscreen triangle from gl_VertexID is not in 1.20; use fixed attributes.
  vec2 pos = gl_Vertex.xy;
  gl_Position = vec4(pos, 0.0, 1.0);
  v_uv = pos * 0.5 + 0.5;
  v_uv.y = 1.0 - v_uv.y;
}
)GLSL";

static const char *kFS32 = R"GLSL(
#version 120
uniform sampler2D u_tex;
uniform sampler2D u_gamma; // 256x3 R/G/B strips packed as 256x1 RGB via 3 rows in 1D? use 256x1 with .rgb channels per sample via 3 textures - we pack as 256x3
varying vec2 v_uv;
void main() {
  // Guest stores big-endian ARGB bytes; uploaded as BGRA so recovered as:
  // sample = (B,G,R,A) from GL_BGRA or we upload as RGBA after swizzle.
  vec4 s = texture2D(u_tex, v_uv);
  // We upload guest 32bpp as GL_BGRA with GL_UNSIGNED_BYTE after host-endian
  // consideration: guest memory is [A][R][G][B] in address order.
  // We convert to RGBA float in CPU upload path for simplicity.
  vec3 c = s.rgb;
  float r = texture2D(u_gamma, vec2(c.r, 0.0)).r;
  float g = texture2D(u_gamma, vec2(c.g, 0.0)).g;
  float b = texture2D(u_gamma, vec2(c.b, 0.0)).b;
  gl_FragColor = vec4(r, g, b, 1.0);
}
)GLSL";

static const char *kFS16 = R"GLSL(
#version 120
uniform sampler2D u_tex;
uniform sampler2D u_gamma;
varying vec2 v_uv;
void main() {
  // 16bpp uploaded as RGBA8 after CPU unpack of xRGB1555 BE
  vec4 s = texture2D(u_tex, v_uv);
  float r = texture2D(u_gamma, vec2(s.r, 0.0)).r;
  float g = texture2D(u_gamma, vec2(s.g, 0.0)).g;
  float b = texture2D(u_gamma, vec2(s.b, 0.0)).b;
  gl_FragColor = vec4(r, g, b, 1.0);
}
)GLSL";

static const char *kFSIdx = R"GLSL(
#version 120
uniform sampler2D u_tex;     // R channel = index / 255
uniform sampler2D u_palette; // 256x1 RGBA
uniform sampler2D u_gamma;
uniform float u_bits;
uniform float u_pixel_width;
varying vec2 v_uv;
void main() {
  float px = floor(v_uv.x * u_pixel_width);
  float py = floor(v_uv.y * float(textureSize2D_fake)); // not available - use tex size via uniform
  // Simpler path: CPU already expands indexed into RGBA8 each frame when needed.
  // For 8bpp we sample index texture.
  float idx = texture2D(u_tex, v_uv).r * 255.0;
  vec4 color = texture2D(u_palette, vec2((idx + 0.5) / 256.0, 0.5));
  float r = texture2D(u_gamma, vec2(color.r, 0.0)).r;
  float g = texture2D(u_gamma, vec2(color.g, 0.0)).g;
  float b = texture2D(u_gamma, vec2(color.b, 0.0)).b;
  gl_FragColor = vec4(r, g, b, 1.0);
}
)GLSL";

/* Fixed-function fallback path is used if GLSL compile fails. */
static bool s_use_shaders = false;

static const char *kFSOverlay = R"GLSL(
#version 120
uniform sampler2D u_tex;
uniform float u_alpha;
varying vec2 v_uv;
void main() {
  vec4 c = texture2D(u_tex, v_uv);
  c.a *= u_alpha;
  gl_FragColor = c;
}
)GLSL";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static int depth_to_bpp_bits(int depth_mode)
{
	switch (depth_mode) {
	case VIDEO_DEPTH_1BIT: return 1;
	case VIDEO_DEPTH_2BIT: return 2;
	case VIDEO_DEPTH_4BIT: return 4;
	case VIDEO_DEPTH_8BIT: return 8;
	case VIDEO_DEPTH_16BIT: return 16;
	case VIDEO_DEPTH_32BIT: return 32;
	default: return 32;
	}
}

static void ensure_identity_gamma(void)
{
	for (int i = 0; i < 256; i++) {
		s_gamma_identity[i] = (uint8_t)i;
		s_gamma_identity[256 + i] = (uint8_t)i;
		s_gamma_identity[512 + i] = (uint8_t)i;
		s_gamma_lut[i] = (uint8_t)i;
		s_gamma_lut[256 + i] = (uint8_t)i;
		s_gamma_lut[512 + i] = (uint8_t)i;
	}
}

static void upload_gamma_texture(void)
{
	if (!s_gamma_tex) {
		glGenTextures(1, &s_gamma_tex);
		glBindTexture(GL_TEXTURE_2D, s_gamma_tex);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	} else {
		glBindTexture(GL_TEXTURE_2D, s_gamma_tex);
	}
	/* Pack as 256x1 RGB: each texel is (R_lut[i], G_lut[i], B_lut[i]) */
	uint8_t packed[256 * 3];
	for (int i = 0; i < 256; i++) {
		packed[i * 3 + 0] = s_gamma_lut[i];
		packed[i * 3 + 1] = s_gamma_lut[256 + i];
		packed[i * 3 + 2] = s_gamma_lut[512 + i];
	}
	glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, 256, 1, 0, GL_RGB, GL_UNSIGNED_BYTE, packed);
}

static void destroy_programs(void)
{
	s_prog_32 = s_prog_16 = s_prog_idx = s_prog_overlay = 0;
}

static bool build_programs(void)
{
	destroy_programs();
	/* Prefer fixed-function for maximum desktop GL compatibility;
	 * shaders optional. For now always use FFP + CPU color expand. */
	s_use_shaders = false;
	(void)kVS; (void)kFS32; (void)kFS16; (void)kFSIdx; (void)kFSOverlay;
	return true;
}

static void destroy_textures(void)
{
	if (s_fb_tex) { glDeleteTextures(1, &s_fb_tex); s_fb_tex = 0; }
	s_fb_tex_width = 0;
	s_fb_tex_height = 0;
	s_classic_fb_texture_valid = false;
	s_classic_fb_upload_baseline.clear();
	if (s_palette_tex) { glDeleteTextures(1, &s_palette_tex); s_palette_tex = 0; }
	if (s_gamma_tex) { glDeleteTextures(1, &s_gamma_tex); s_gamma_tex = 0; }
	s_fb_tex_export = 0;
}

static void ensure_fb_texture(void)
{
	if (!s_fb_tex) {
		glGenTextures(1, &s_fb_tex);
		glBindTexture(GL_TEXTURE_2D, s_fb_tex);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
		s_fb_tex_export = s_fb_tex;
	}
	if (s_fb_tex_width != compositor_pixel_width || s_fb_tex_height != compositor_pixel_height) {
		glBindTexture(GL_TEXTURE_2D, s_fb_tex);
		glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, compositor_pixel_width, compositor_pixel_height, 0,
		             GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
		s_fb_tex_width = compositor_pixel_width;
		s_fb_tex_height = compositor_pixel_height;
		s_classic_fb_texture_valid = false;
		s_classic_fb_upload_baseline.clear();
	}
}

static bool framebuffer_layer_occludes_classic_framebuffer(void)
{
	return s_framebuffer_valid && s_framebuffer_cache.source &&
	       s_framebuffer_cache.blend == kBlendOpaque &&
	       s_framebuffer_cache.alpha >= 1.f &&
	       s_framebuffer_cache.dst_origin_x <= 0.f &&
	       s_framebuffer_cache.dst_origin_y <= 0.f &&
	       s_framebuffer_cache.dst_size_w >= (float)compositor_pixel_width &&
	       s_framebuffer_cache.dst_size_h >= (float)compositor_pixel_height;
}

/* Expand guest framebuffer into tightly packed RGBA8 for upload. */
static void expand_framebuffer_rgba(std::vector<uint8_t> &out)
{
	out.resize((size_t)compositor_pixel_width * (size_t)compositor_pixel_height * 4);
	const uint8_t *src = (const uint8_t *)compositor_buffer;
	if (!src) {
		std::memset(out.data(), 0, out.size());
		return;
	}

	const int rb = compositor_row_bytes;
	const int bpp = compositor_bits_per_pixel;

	if (bpp == 32) {
		/* Upload raw guest BE ARGB -> RGBA8. Gamma is applied ONCE in the
		 * fragment shader (u_gamma), matching Metal, which uploads the
		 * framebuffer raw and lets the shader apply the display LUT. Pre-
		 * applying s_gamma_lut here double-corrects (washed-out / too bright,
		 * white-on-light invisible) - do NOT apply it on upload. */
		for (int y = 0; y < compositor_pixel_height; y++) {
			const uint8_t *row = src + (size_t)y * (size_t)rb;
			uint8_t *dst = out.data() + (size_t)y * (size_t)compositor_pixel_width * 4;
			for (int x = 0; x < compositor_pixel_width; x++) {
				dst[x * 4 + 0] = row[x * 4 + 1]; /* R */
				dst[x * 4 + 1] = row[x * 4 + 2]; /* G */
				dst[x * 4 + 2] = row[x * 4 + 3]; /* B */
				dst[x * 4 + 3] = 255;
			}
		}
		return;
	}

	if (bpp == 16) {
		for (int y = 0; y < compositor_pixel_height; y++) {
			const uint8_t *row = src + (size_t)y * (size_t)rb;
			uint8_t *dst = out.data() + (size_t)y * (size_t)compositor_pixel_width * 4;
			for (int x = 0; x < compositor_pixel_width; x++) {
				uint16_t be = (uint16_t)((row[x * 2] << 8) | row[x * 2 + 1]);
				uint8_t R = (uint8_t)(((be >> 10) & 0x1f) * 255 / 31);
				uint8_t G = (uint8_t)(((be >> 5) & 0x1f) * 255 / 31);
				uint8_t B = (uint8_t)((be & 0x1f) * 255 / 31);
				/* Raw unpack; gamma applied once in the fragment shader. */
				dst[x * 4 + 0] = R;
				dst[x * 4 + 1] = G;
				dst[x * 4 + 2] = B;
				dst[x * 4 + 3] = 255;
			}
		}
		return;
	}

	/* Indexed 1/2/4/8 */
	for (int y = 0; y < compositor_pixel_height; y++) {
		const uint8_t *row = src + (size_t)y * (size_t)rb;
		uint8_t *dst = out.data() + (size_t)y * (size_t)compositor_pixel_width * 4;
		for (int x = 0; x < compositor_pixel_width; x++) {
			uint8_t index = 0;
			if (bpp == 8) {
				index = row[x];
			} else if (bpp == 4) {
				uint8_t b = row[x / 2];
				index = (x & 1) ? (b & 0x0f) : (b >> 4);
			} else if (bpp == 2) {
				uint8_t b = row[x / 4];
				int shift = (3 - (x % 4)) * 2;
				index = (b >> shift) & 0x3;
			} else { /* 1 */
				uint8_t b = row[x / 8];
				index = (b >> (7 - (x % 8))) & 0x1;
			}
			uint8_t R = s_palette[index * 4 + 0];
			uint8_t G = s_palette[index * 4 + 1];
			uint8_t B = s_palette[index * 4 + 2];
			/* Raw palette lookup; gamma applied once in the fragment shader. */
			dst[x * 4 + 0] = R;
			dst[x * 4 + 1] = G;
			dst[x * 4 + 2] = B;
			dst[x * 4 + 3] = 255;
		}
	}
}

static void draw_textured_quad(void)
{
	glBegin(GL_QUADS);
	glTexCoord2f(0.f, 1.f); glVertex2f(-1.f, -1.f);
	glTexCoord2f(1.f, 1.f); glVertex2f( 1.f, -1.f);
	glTexCoord2f(1.f, 0.f); glVertex2f( 1.f,  1.f);
	glTexCoord2f(0.f, 0.f); glVertex2f(-1.f,  1.f);
	glEnd();
}

/*
 * RAVE and the compositor intentionally share one compatibility-profile GL
 * context.  State set while an overlay FBO is bound therefore survives after
 * the FBO is unbound.  In particular, a 960x720 RAVE scissor clips a
 * 1920x1440 window to its lower-left quarter, and a channel write mask such as
 * red-only also applies to the window back buffer.  Establish a complete
 * presentation boundary before clearing or drawing the classic framebuffer.
 */
static void prepare_present_state(void)
{
	auto &ext = gfx_gl_ext();
	if (ext.fbo)
		ext.BindFramebuffer(GL_FRAMEBUFFER, 0);

	/* A multi-textured RAVE draw may leave texture unit 1 active/enabled. */
	if (ext.multitex && ext.ActiveTexture) {
		ext.ActiveTexture(GL_TEXTURE1);
		glDisable(GL_TEXTURE_2D);
		ext.ActiveTexture(GL_TEXTURE0);
	}

	glDrawBuffer(GL_BACK);
	glDisable(GL_SCISSOR_TEST);
	glDisable(GL_DEPTH_TEST);
	glDisable(GL_STENCIL_TEST);
	glDisable(GL_ALPHA_TEST);
	glDisable(GL_FOG);
	glDisable(GL_CULL_FACE);
	glDisable(GL_LIGHTING);
	glDisable(GL_COLOR_SUM);
	glDisable(GL_BLEND);
	glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
	glDepthMask(GL_TRUE);
	glStencilMask(~0u);
	glPolygonMode(GL_FRONT_AND_BACK, GL_FILL);
}

static void draw_overlay_layer(const CompositeLayer *layer)
{
	if (!layer || !layer->source) return;
	GLuint tex = (GLuint)(uintptr_t)layer->source;
	if (!tex) return;

	glEnable(GL_TEXTURE_2D);
	glBindTexture(GL_TEXTURE_2D, tex);
	glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_MODULATE);

	if (layer->blend == kBlendOpaque) {
		glDisable(GL_BLEND);
	} else {
		glEnable(GL_BLEND);
		if (layer->blend == kBlendPremultiplied)
			glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
		else
			glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
	}

	float a = layer->alpha;
	if (a < 0.f) a = 0.f;
	if (a > 1.f) a = 1.f;
	glColor4f(1.f, 1.f, 1.f, a);

	/* Layer dst is in guest/framebuffer pixel space (Metal twin). Map to NDC
	 * of the full drawable viewport. Prefer the live DMC mode size when the
	 * compositor texture was force-resized to a DSp BGRA surface so RAVE/GL
	 * overlays that still publish guest-mode rectangles land correctly. */
	int space_w = compositor_pixel_width;
	int space_h = compositor_pixel_height;
	const DMCModeSnapshot *snap = dmc_current_snapshot();
	if (snap && snap->width > 0 && snap->height > 0) {
		space_w = (int)snap->width;
		space_h = (int)snap->height;
	}
	if (space_w <= 0) space_w = 1;
	if (space_h <= 0) space_h = 1;

	float dw = (layer->dst_size_w > 0.f) ? layer->dst_size_w : (float)space_w;
	float dh = (layer->dst_size_h > 0.f) ? layer->dst_size_h : (float)space_h;
	float x0 = layer->dst_origin_x;
	float y0 = layer->dst_origin_y;
	float x1 = x0 + dw;
	float y1 = y0 + dh;
	float nx0 = (x0 / (float)space_w) * 2.f - 1.f;
	float nx1 = (x1 / (float)space_w) * 2.f - 1.f;
	/* Guest Y top-down -> NDC Y up */
	float ny0 = 1.f - (y1 / (float)space_h) * 2.f;
	float ny1 = 1.f - (y0 / (float)space_h) * 2.f;

	glBegin(GL_QUADS);
	if (layer->slot == kLayerSlotFramebuffer) {
		/* CPU-expanded DSp pixels are uploaded top row first, like the classic
		 * framebuffer upload. */
		glTexCoord2f(0.f, 0.f); glVertex2f(nx0, ny1);
		glTexCoord2f(1.f, 0.f); glVertex2f(nx1, ny1);
		glTexCoord2f(1.f, 1.f); glVertex2f(nx1, ny0);
		glTexCoord2f(0.f, 1.f); glVertex2f(nx0, ny0);
	} else {
		/* RAVE renders y=0 at the top of an OpenGL render target, which lands
		 * at texture t=1. */
		glTexCoord2f(0.f, 1.f); glVertex2f(nx0, ny1);
		glTexCoord2f(1.f, 1.f); glVertex2f(nx1, ny1);
		glTexCoord2f(1.f, 0.f); glVertex2f(nx1, ny0);
		glTexCoord2f(0.f, 0.f); glVertex2f(nx0, ny0);
	}
	glEnd();

	glColor4f(1.f, 1.f, 1.f, 1.f);
	glDisable(GL_BLEND);
}

// ---------------------------------------------------------------------------
// DMC subscriber callbacks (Metal copies)
// ---------------------------------------------------------------------------
static int32_t MetalCompositor_OnModeExit(const struct DMCModeSnapshot *outgoing, void *ctx)
{
    (void)ctx;
    if (outgoing) {
        COMPOSITOR_LOG("DMC on_mode_exit: outgoing gen=%u %ux%u depth=%u",
                       outgoing->generation, outgoing->width, outgoing->height, outgoing->depth);
    }
    /* Metal clears the overlay cache on every real mode exit so a stale
     * engine texture cannot composite into the next mode. GL also drops the
     * framebuffer-slot cache (DSp) for the same lifetime reason. */
    MetalCompositorSubmitFrame_ClearCachedOverlay();
    MetalCompositorSubmitFrame_ClearCachedFramebuffer();
    s_present_deferred = false;
    return 0;
}

static int32_t MetalCompositor_OnModeEnter(const struct DMCModeSnapshot *incoming, void *ctx)
{
    (void)ctx;
    if (incoming) {
        COMPOSITOR_LOG("DMC on_mode_enter: incoming gen=%u %ux%u depth=%u vbl_usec=%llu",
                       incoming->generation, incoming->width, incoming->height, incoming->depth,
                       (unsigned long long)incoming->vbl_usec);
    } else {
        return 0;
    }

    if (incoming->active_owner == (uint32_t)kDMCOwnerDSp) {
        int new_w = (int)incoming->width;
        int new_h = (int)incoming->height;
        int cur_w = compositor_pixel_width;
        int cur_h = compositor_pixel_height;
        if (new_w != cur_w || new_h != cur_h || compositor_depth != VIDEO_DEPTH_32BIT) {
            uint32_t bgra_row_bytes = (uint32_t)new_w * 4;
            uint32_t bgra_size      = bgra_row_bytes * (uint32_t)new_h;
            int rc = MetalCompositorResize(
                new_w, new_h,
                VIDEO_DEPTH_32BIT,
                (int)bgra_row_bytes,
                (int)bgra_row_bytes,
                NULL,
                bgra_size);
            if (rc != 0) {
                COMPOSITOR_ERR("DMC on_mode_enter: MetalCompositorResize failed (rc=%d) for "
                               "DSp owner %dx%d - drawable will appear small in window",
                               rc, new_w, new_h);
            }
        }
    } else if (incoming->active_owner == (uint32_t)kDMCOwnerQuickDraw &&
               incoming->screen_base_host != NULL) {
        int new_w = (int)incoming->width;
        int new_h = (int)incoming->height;
        int new_pixel_depth = (int)incoming->depth;
        int new_depth = DepthModeForPixelDepth(new_pixel_depth);
        int new_row_bytes = (int)incoming->row_bytes;
        int new_pitch = (int)incoming->pitch;
        int cur_w = compositor_pixel_width;
        int cur_h = compositor_pixel_height;
        if (new_w != cur_w ||
            new_h != cur_h ||
            compositor_depth != new_depth ||
            compositor_row_bytes != new_row_bytes ||
            compositor_pitch != new_pitch) {
            uint64_t buffer_size64 = (uint64_t)incoming->pitch *
                                     (uint64_t)incoming->height;
            uint32_t buffer_size =
                buffer_size64 > UINT32_MAX ? UINT32_MAX : (uint32_t)buffer_size64;
            int rc = MetalCompositorResize(
                new_w, new_h,
                new_depth,
                new_row_bytes,
                new_pitch,
                incoming->screen_base_host,
                buffer_size);
            if (rc != 0) {
                COMPOSITOR_ERR("DMC on_mode_enter: MetalCompositorResize failed "
                               "(rc=%d) for QuickDraw restore %dx%d@%d rb=%d host=%p",
                               rc, new_w, new_h, new_pixel_depth, new_row_bytes,
                               incoming->screen_base_host);
            }
        }
    }

    return 0;
}
// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
int MetalCompositorInit(int width, int height, int depth, int row_bytes,
                        int pitch, void *buffer, uint32_t buffer_size)
{
	if (!GfxGLDeviceInit()) {
		COMPOSITOR_ERR("GfxGLDeviceInit failed");
		return -1;
	}

	compositor_pixel_width = width;
	compositor_pixel_height = height;
	compositor_depth = depth;
	compositor_row_bytes = row_bytes;
	compositor_pitch = pitch;
	compositor_buffer = buffer;
	compositor_buffer_size = buffer_size;
	compositor_bits_per_pixel = depth_to_bpp_bits(depth);

	ensure_identity_gamma();
	std::memset(s_palette, 0, sizeof(s_palette));
	s_palette[0 * 4 + 0] = 255; s_palette[0 * 4 + 1] = 255; s_palette[0 * 4 + 2] = 255; s_palette[0 * 4 + 3] = 255;
	/* index 1 black already zero */

	if (buffer != nullptr) {
		s_classic_host_stash = buffer;
		s_classic_host_stash_size = buffer_size;
		s_classic_host_stash_w = width;
		s_classic_host_stash_h = height;
		s_classic_host_stash_depth = depth;
		s_classic_host_stash_rb = row_bytes;
		s_classic_host_stash_pitch = pitch;
	}

	destroy_textures();
	ensure_fb_texture();
	upload_gamma_texture();
	build_programs();

	/* Subscribe to DMC first (compositor is presentation layer). */
	struct DMCSubscriber sub = {};
	sub.name = "compositor";
	sub.on_mode_exit = MetalCompositor_OnModeExit;
	sub.on_mode_enter = MetalCompositor_OnModeEnter;
	sub.ctx = nullptr;
	dmc_subscribe(&sub);

	/* VBL source - SDL-driven from Present. */
	vbl_source_init(nullptr, nullptr, nullptr);

	s_init = true;
	COMPOSITOR_LOG("Init tick=%u %dx%d depth=%d rb=%d pitch=%d bpp=%d",
	               ReadMacInt32(0x016a),
	               width, height, depth, row_bytes, pitch, compositor_bits_per_pixel);
	return 0;
}

void MetalCompositorUpdatePalette(const uint8_t *pal, int num_colors)
{
	/* Match metal_compositor.mm: palette buffers only exist for indexed
	 * depths. DSpContext_SetStateHandler always replays a 256-entry CLUT on
	 * Active; for 16/32 bpp contexts that CLUT is zero-filled (or a 1/2-entry
	 * B/W seed). Applying it while the compositor is in VIDEO_DEPTH_32BIT
	 * (DSp OnModeEnter normalises the FB to BGRA) permanently wipes the
	 * classic 8-bit desktop palette → black screen after Rescan Monitors /
	 * title-mode switches. Metal no-ops those updates; GL must too. */
	if (compositor_bits_per_pixel > 8 ||
	    compositor_depth > VIDEO_DEPTH_8BIT) {
		COMPOSITOR_LOG("MetalCompositorUpdatePalette: ignored %d colors "
		               "(depth=%d bpp=%d is not indexed)",
		               num_colors, compositor_depth, compositor_bits_per_pixel);
		return;
	}
	if (!pal || num_colors <= 0) return;
	if (num_colors > 256) num_colors = 256;
	for (int i = 0; i < num_colors; i++) {
		s_palette[i * 4 + 0] = pal[i * 3 + 0];
		s_palette[i * 4 + 1] = pal[i * 3 + 1];
		s_palette[i * 4 + 2] = pal[i * 3 + 2];
		s_palette[i * 4 + 3] = 255;
	}
	s_palette_dirty = true;
	s_classic_fb_texture_valid = false;
}

extern "C" bool GLCompositorCopyCurrentPaletteRGB(uint8_t out_rgb[768])
{
	if (!s_init || !out_rgb) return false;
	for (int i = 0; i < 256; i++) {
		out_rgb[i * 3 + 0] = s_palette[i * 4 + 0];
		out_rgb[i * 3 + 1] = s_palette[i * 4 + 1];
		out_rgb[i * 3 + 2] = s_palette[i * 4 + 2];
	}
	return true;
}

void MetalCompositorPresent(void)
{
	if (!s_init) return;
	/* Guest callbacks may pump a nested VideoVBL on the same emulation thread.
	 * A second clear/swap while the outer present is incomplete can replay the
	 * first movie frames and expose a partially composed back buffer. */
	if (s_present_in_progress) {
		s_present_deferred = true;
#if QD3D_GRAPHICS_LOGGING_ENABLED
		static uint64_t s_nested_present_count = 0;
		++s_nested_present_count;
		if (compositor_trace_sample(s_nested_present_count)) {
			QD3D_RENDER_LOG("CompositorPresent deferred: nested present count=%llu",
			                (unsigned long long)s_nested_present_count);
		}
#endif
		return;
	}

	/* Guest notice callbacks can run VideoVBL before NativeRenderEnd returns.
	 * Do not let presentation rebind framebuffer 0 or overwrite compatibility
	 * state while RAVE is still building the current overlay frame. Metal can
	 * encode independently; GL shares one context with RAVE, so defer and
	 * flush from NativeRenderEnd via MetalCompositorFlushDeferredPresent. */
	if (RaveGLRenderPassActive()) {
		s_present_deferred = true;
#if QD3D_GRAPHICS_LOGGING_ENABLED
		static uint64_t s_deferred_present_count = 0;
		++s_deferred_present_count;
		if (compositor_trace_sample(s_deferred_present_count)) {
			QD3D_RENDER_LOG("CompositorPresent deferred: RAVE render pass active count=%llu",
			                (unsigned long long)s_deferred_present_count);
		}
#endif
		return;
	}
	ScopedCompositorPresent present_scope;

	/* Drive VBL secondary callbacks (DSp drains etc.) every call. */
	vbl_source_sdl_tick(0.0);
	MetalCompositorPaletteLatch();
	detect_implicit_quickdraw_handoff();

	/* Recover classic host mapping after a DSp NULL-buffer Resize when DMC
	 * has already returned ownership to QuickDraw without OnModeEnter restore
	 * (see dual-context handoff in DSpContext_SetStateHandler). Must run
	 * before the cadence gate so the first recovered frame is drawn.
	 * Only the stashed *classic* desktop surface is restored — never a freed
	 * DSp heap (Metal: QD snapshot screen_base_host only). */
	{
		const DMCModeSnapshot *snap = dmc_current_snapshot();
		if (compositor_buffer == nullptr &&
		    s_classic_host_stash != nullptr &&
		    snap != nullptr &&
		    snap->active_owner == (uint32_t)kDMCOwnerQuickDraw &&
		    snap->transitioning == 0) {
			(void)MetalCompositorResize(
				s_classic_host_stash_w, s_classic_host_stash_h,
				s_classic_host_stash_depth,
				s_classic_host_stash_rb, s_classic_host_stash_pitch,
				s_classic_host_stash, s_classic_host_stash_size);
		}
	}

	/* Metal Present always samples the live FB when upload is allowed.
	 * GL skips the full expand when the baseline matches, but must still
	 * redraw when content changed, an overlay was submitted, a deferred
	 * present is owed, or the host cadence interval has elapsed. */
	static uint64_t s_last_present_usec = 0;
	const uint64_t now_usec = compositor_now_usec();
	const uint64_t cadence_usec = GfxFramePacingClampCadenceUsec(
		vbl_source_get_cadence_usec());
	const bool classic_dirty = classic_framebuffer_needs_upload();
	const bool do_draw = classic_dirty ||
	                     !s_classic_fb_texture_valid ||
	                     s_last_present_usec == 0 ||
	                     s_present_deferred ||
	                     now_usec - s_last_present_usec >= cadence_usec ||
	                     s_overlay_present_serial != s_overlay_submit_serial ||
	                     s_framebuffer_valid;

	if (!do_draw)
		return;
	if (!SharedMetalDevice()) {
		/* Keep the deferral: a transient make-current failure must not
		 * permanently drop a dirty desktop frame. */
		s_present_deferred = true;
		return;
	}
	s_last_present_usec = now_usec;
	s_present_deferred = false;

#if QD3D_GRAPHICS_LOGGING_ENABLED
	GLboolean inherited_color_mask[4] = {};
	GLint inherited_scissor_box[4] = {};
	const GLboolean inherited_scissor = glIsEnabled(GL_SCISSOR_TEST);
	glGetBooleanv(GL_COLOR_WRITEMASK, inherited_color_mask);
	glGetIntegerv(GL_SCISSOR_BOX, inherited_scissor_box);
#endif
	prepare_present_state();

	int dw = 0, dh = 0;
	GfxGLDeviceGetDrawableSize(&dw, &dh);
	if (dw <= 0 || dh <= 0) {
		if (sdl_window)
			SDL_GetWindowSize(sdl_window, &dw, &dh);
	}
	if (dw <= 0) dw = compositor_pixel_width;
	if (dh <= 0) dh = compositor_pixel_height;

	glViewport(0, 0, dw, dh);
	glClearColor(0.f, 0.f, 0.f, 1.f);
	glClear(GL_COLOR_BUFFER_BIT);

	glMatrixMode(GL_PROJECTION);
	glLoadIdentity();
	glMatrixMode(GL_MODELVIEW);
	glLoadIdentity();

	/* A full-screen opaque DSp page completely hides the classic framebuffer.
	 * Avoid expanding and uploading that second full-screen surface during
	 * movies; otherwise update the already-allocated texture in place.
	 *
	 * When DSp owns the FB, s_fb_tex is written by DSpEncode*ToFramebuffer
	 * (and VBL publish). Keep sampling it without a host-buffer re-upload —
	 * OnModeEnter Resize passes buffer=NULL for DSp, and expand-from-null
	 * would paint solid black over the DSp pixels every present. */
	const bool classic_occluded =
		framebuffer_layer_occludes_classic_framebuffer();
	bool classic_uploaded = false;
	if (!classic_occluded) {
		ensure_fb_texture();
		glEnable(GL_TEXTURE_2D);
		glBindTexture(GL_TEXTURE_2D, s_fb_tex);
		if (classic_framebuffer_needs_upload()) {
			static std::vector<uint8_t> rgba;
			expand_framebuffer_rgba(rgba);
			glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, compositor_pixel_width, compositor_pixel_height,
			                GL_RGBA, GL_UNSIGNED_BYTE, rgba.data());
			remember_classic_framebuffer_upload();
			classic_uploaded = true;
		}
		glTexEnvi(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
		glDisable(GL_BLEND);
		glColor4f(1.f, 1.f, 1.f, 1.f);
		draw_textured_quad();
	}

	/* DSp page-flipped framebuffer, then the independent RAVE overlay. */
	if (s_framebuffer_valid)
		draw_overlay_layer(&s_framebuffer_cache);
	if (s_overlay_valid)
		draw_overlay_layer(&s_overlay_cache);
#if QD3D_GRAPHICS_LOGGING_ENABLED && 0
	s_present_count++;
	if (compositor_trace_sample(s_present_count)) {
		QD3D_RENDER_LOG("CompositorPresent count=%llu drawable=%dx%d guest=%dx%d classicOccluded=%d classicUploaded=%d framebufferValid=%d framebuffer=%u overlayValid=%d overlay=%u dst=%.1f,%.1f %.1fx%.1f inheritedScissor=%d[%d,%d %dx%d] inheritedMask=%d%d%d%d glError=0x%x",
		                (unsigned long long)s_present_count, dw, dh, compositor_pixel_width,
		                compositor_pixel_height, classic_occluded ? 1 : 0,
		                classic_uploaded ? 1 : 0,
		                s_framebuffer_valid ? 1 : 0,
		                (unsigned)s_framebuffer_tex_cache,
		                s_overlay_valid ? 1 : 0,
		                (unsigned)s_overlay_tex_cache,
		                s_overlay_cache.dst_origin_x, s_overlay_cache.dst_origin_y,
		                s_overlay_cache.dst_size_w, s_overlay_cache.dst_size_h,
		                inherited_scissor ? 1 : 0, inherited_scissor_box[0],
		                inherited_scissor_box[1], inherited_scissor_box[2],
		                inherited_scissor_box[3], inherited_color_mask[0] ? 1 : 0,
		                inherited_color_mask[1] ? 1 : 0,
		                inherited_color_mask[2] ? 1 : 0,
		                inherited_color_mask[3] ? 1 : 0,
		                (unsigned)glGetError());
	}
#endif

	GfxGLDeviceSwap();
	s_overlay_present_serial = s_overlay_submit_serial;

#if defined(DESCENT_HITCH_DEBUG) && 0
	/* Present heartbeat (throttled). Confirms the emul-thread present path is
	 * actually swapping frames during a suspected freeze. The two hashes both
	 * sample compositor_buffer: fbHash over the full frame, sBufRegion over just the
	 * movie sub-rect (rows 60..372) that Cinepak writes, so we can tell a
	 * content freeze from a GPU-upload freeze. */
	{
		static uint64_t s_hb_last_usec = 0;
		static uint64_t s_hb_frames = 0;
		++s_hb_frames;
		const uint64_t hb_now = compositor_now_usec();
		if (s_hb_last_usec == 0)
			s_hb_last_usec = hb_now;
		if (hb_now - s_hb_last_usec >= 250000) {
			uint32_t fbhash = 2166136261u;
			uint32_t regionhash = 2166136261u;
			uint32_t macRegion = 2166136261u;   /* same region via live VM map */
			const size_t vb = visible_framebuffer_bytes();
			if (compositor_buffer && vb) {
				const uint8_t *b = (const uint8_t *)compositor_buffer;
				for (size_t i = 0; i < vb; i += 257)
					fbhash = (fbhash ^ b[i]) * 16777619u;
				const size_t rb = (size_t)compositor_row_bytes;
				if (rb != 0 && vb >= (size_t)372 * rb) {
					const uint8_t *rbp = b + (size_t)60 * rb;
					for (size_t i = 0; i < (size_t)312 * rb; i += 257)
						regionhash = (regionhash ^ rbp[i]) * 16777619u;
				}
			}
			/* Cinepak writes through Mac2HostAddr(guest screen base). If this
			 * differs from sBufRegion during the freeze, compositor_buffer is stale
			 * relative to the live framebuffer mapping (dual mapping). */
			const uint8_t *mb = Mac2HostAddr(0x20000000);
			const size_t mrb = (size_t)compositor_row_bytes;
			if (mb && mrb != 0 && vb >= (size_t)372 * mrb) {
				const uint8_t *mrbp = mb + (size_t)60 * mrb;
				for (size_t i = 0; i < (size_t)312 * mrb; i += 257)
					macRegion = (macRegion ^ mrbp[i]) * 16777619u;
			}
			gfx_log_emit("[compositor] ",
				"presentHB frames=%llu dtUsec=%llu tick=%u classicOccluded=%d classicUploaded=%d sBuf=%p macBuf=%p vbBytes=%zu fbHash=%08x sBufRegion=%08x macRegion=%08x",
				(unsigned long long)s_hb_frames,
				(unsigned long long)(hb_now - s_hb_last_usec),
				ReadMacInt32(0x016a),
				classic_occluded ? 1 : 0, classic_uploaded ? 1 : 0,
				compositor_buffer, (void *)mb, vb, fbhash, regionhash, macRegion);
			s_hb_last_usec = hb_now;
			s_hb_frames = 0;
		}
	}
#endif

	/* Update present rect to full window for cursor mapping. */
	atomic_store_explicit(&s_present_origin, 0, std::memory_order_relaxed);
	atomic_store_explicit(&s_present_size,
		((uint64_t)(uint32_t)dw << 32) | (uint32_t)dh, std::memory_order_relaxed);
}

void MetalCompositorShutdown(void)
{
	if (s_init) {
		if (SharedMetalDevice()) {
			MetalCompositorSubmitFrame_ClearCachedOverlay();
			MetalCompositorSubmitFrame_ClearCachedFramebuffer();
			destroy_textures();
			destroy_programs();
		}
		vbl_source_shutdown();
		dmc_unsubscribe("compositor");
		s_init = false;
		compositor_buffer = nullptr;
		s_classic_host_stash = nullptr;
		s_classic_host_stash_size = 0;
		COMPOSITOR_LOG("Shutdown tick=%u", ReadMacInt32(0x016a));
	}

	/* The shared SDL_GLContext is tied to the current SDL window.  It must be
	 * deleted while that window is still alive, including partial-init paths. */
	GfxGLDeviceShutdown();
}

int MetalCompositorResize(int width, int height, int depth, int row_bytes,
                          int pitch, void *buffer, uint32_t buffer_size)
{ /* gl_device_sdl_window change == w/h/flags changed; recreate everything */
	if (!s_init || gl_device_sdl_window != sdl_window)
		return MetalCompositorInit(width, height, depth,
			row_bytes, pitch, buffer, buffer_size);
	if (!SharedMetalDevice())
	{
		COMPOSITOR_LOG("couldn't SharedMetalDevice()!");
		return -1;
	}

	/* Stash / refresh classic host mapping. DSp OnModeEnter passes NULL so
	 * the previous desktop surface is remembered for a QD rebind. */
	if (buffer != nullptr) {
		s_classic_host_stash = buffer;
		s_classic_host_stash_size = buffer_size;
		s_classic_host_stash_w = width;
		s_classic_host_stash_h = height;
		s_classic_host_stash_depth = depth;
		s_classic_host_stash_rb = row_bytes;
		s_classic_host_stash_pitch = pitch;
	} else if (compositor_buffer != nullptr) {
		s_classic_host_stash = compositor_buffer;
		s_classic_host_stash_size = compositor_buffer_size;
		s_classic_host_stash_w = compositor_pixel_width;
		s_classic_host_stash_h = compositor_pixel_height;
		s_classic_host_stash_depth = compositor_depth;
		s_classic_host_stash_rb = compositor_row_bytes;
		s_classic_host_stash_pitch = compositor_pitch;
	}

	MetalCompositorSubmitFrame_ClearCachedOverlay();
	MetalCompositorSubmitFrame_ClearCachedFramebuffer();
	compositor_pixel_width = width;
	compositor_pixel_height = height;
	compositor_depth = depth;
	compositor_row_bytes = row_bytes;
	compositor_pitch = pitch;
	compositor_buffer = buffer;
	compositor_buffer_size = buffer_size;
	compositor_bits_per_pixel = depth_to_bpp_bits(depth);
	s_classic_fb_texture_valid = false;
	s_classic_fb_upload_baseline.clear();
	ensure_fb_texture();
	COMPOSITOR_LOG("Resize %dx%d depth=%d", width, height, depth);
	return 0;
}

int MetalCompositorIsInitialized(void)
{
	return s_init ? 1 : 0;
}

/* Guest address and size of the current visible screen surface. Consumed by
 * the NQD CPU blit path (nqd_gl_renderer.cpp) to validate screen-destined
 * surface ranges; the screen lives outside guest RAM. Emul-thread only, like
 * the NQD hooks and mode switches that update compositor_buffer. */
int MetalCompositorGetGuestSurface(uint32_t *out_mac_base, uint32_t *out_byte_size)
{
	if (!s_init || compositor_buffer == nullptr || compositor_buffer_size == 0)
		return -1;
	*out_mac_base = Host2MacAddr((uint8 *)compositor_buffer);
	*out_byte_size = compositor_buffer_size;
	return 0;
}

int MetalCompositorCurrentMode(int *out_width, int *out_height, int *out_depth)
{
	if (!s_init)
		return 0;
	if (out_width)  *out_width  = compositor_pixel_width;
	if (out_height) *out_height = compositor_pixel_height;
	if (out_depth)  *out_depth  = compositor_depth;
	return 1;
}

int32_t MetalCompositorSubmitFrame(const struct FrameDescriptor *desc)
{
	if (!desc || !desc->layers || desc->layer_count == 0)
		return kGfxAccelErrInvalidDescriptor;

	const DMCModeSnapshot *snap = dmc_current_snapshot();
	if (snap && desc->generation != 0 && desc->generation != snap->generation)
		return kGfxAccelErrStaleGeneration;

	bool submitted_overlay = false;
	/* Keep DSp's framebuffer separate from the single RAVE overlay mailbox. */
	for (uint32_t i = 0; i < desc->layer_count; i++) {
		const CompositeLayer *L = &desc->layers[i];
		if (L->slot == kLayerSlotOverlay && L->source) {
			s_overlay_cache = *L;
			s_overlay_valid = true;
			s_overlay_tex_cache = (GLuint)(uintptr_t)L->source;
			submitted_overlay = true;
		} else if (L->slot == kLayerSlotFramebuffer && L->source) {
			s_framebuffer_cache = *L;
			s_framebuffer_valid = true;
			s_framebuffer_tex_cache = (GLuint)(uintptr_t)L->source;
		}
	}
	if (submitted_overlay) {
		s_overlay_submit_serial++;
		remember_overlay_framebuffer_baseline();
		s_last_overlay_submit_usec = compositor_now_usec();
	}
#if QD3D_GRAPHICS_LOGGING_ENABLED
	s_overlay_submit_count++;
	if (compositor_trace_sample(s_overlay_submit_count)) {
		QD3D_RENDER_LOG("CompositorSubmit count=%llu layers=%u generation=%llu overlayValid=%d overlay=%u",
		                (unsigned long long)s_overlay_submit_count,
		                desc->layer_count, (unsigned long long)desc->generation,
		                s_overlay_valid ? 1 : 0, (unsigned)s_overlay_tex_cache);
	}
#endif
	return kGfxAccelNoErr;
}

int32_t MetalCompositorSync3DFramePacingForEngine(int32_t engine_id)
{
	return vbl_source_sync_3d_pacing_for_engine(engine_id);
}

void MetalCompositorSubmitFrame_SetTargetTimestamp(double /*ts*/)
{
}

int MetalCompositorSubmitFrame_AcquireCachedOverlay(struct CompositeLayer *out_layer,
                                                    void **out_tex_retained)
{
	if (!s_overlay_valid) return 0;
	if (out_layer) *out_layer = s_overlay_cache;
	if (out_tex_retained) *out_tex_retained = s_overlay_cache.source;
	return 1;
}

void MetalCompositorSubmitFrame_ReleaseCachedOverlay(void * /*tex_retained*/)
{
	/* OpenGL textures are not refcounted here. */
}

void MetalCompositorSubmitFrame_EncodeCachedOverlay(void * /*render_encoder*/,
                                                    const struct CompositeLayer *layer,
                                                    void * /*display_gamma_lut*/)
{
	if (layer) draw_overlay_layer(layer);
}

void MetalCompositorSubmitFrame_ClearCachedOverlay(void)
{
	s_overlay_valid = false;
	std::memset(&s_overlay_cache, 0, sizeof(s_overlay_cache));
	s_overlay_tex_cache = 0;
	s_overlay_fb_baseline.clear();
	s_last_overlay_submit_usec = 0;
}

void MetalCompositorSubmitFrame_ClearCachedFramebuffer(void)
{
	s_framebuffer_valid = false;
	std::memset(&s_framebuffer_cache, 0, sizeof(s_framebuffer_cache));
	s_framebuffer_tex_cache = 0;
}

/* GL-only: flush a Present that was deferred while the shared context was
 * owned by a RAVE render pass (or a nested present). Metal has no equivalent
 * because it encodes without borrowing the 3D engine's command stream. */
extern "C" void MetalCompositorFlushDeferredPresent(void)
{
	if (!s_init || !s_present_deferred)
		return;
	if (s_present_in_progress || RaveGLRenderPassActive())
		return;
	MetalCompositorPresent();
}

void *MetalCompositorGetLayer(void)
{
	return s_init ? (void *)(uintptr_t)1 : nullptr;
}

void *MetalCompositorGetFramebufferTexture(void)
{
	return s_init ? (void *)(uintptr_t)s_fb_tex_export : nullptr;
}

void MetalCompositorPaletteLatch(void)
{
	/* Immediate palette path; dirty flag cleared. */
	s_palette_dirty = false;
}

void MetalCompositorUpdateGammaLUT(const uint8_t *lut)
{
	if (!lut) return;
	/* Mirror metal_compositor.mm: the caller passes the raw guest LUT; the
	 * display policy (OS-defined => verbatim, Linear => inverse Mac Standard
	 * curve) is composed here so the GL and Metal backends present the
	 * identical ramp. A raw memcpy here (the old GL behaviour) diverged from
	 * Metal whenever the policy was non-identity, which is what produced the
	 * over-bright / washed-out / white-invisible presentation in D2. */
	GfxColorBuildDisplayGammaLUT(lut, false,
	                             !gl_compositor_is_linear_gamma(),
	                             s_gamma_lut);
	s_gamma_is_identity = true;
	for (int i = 0; i < 256; i++) {
		if (s_gamma_lut[i] != (uint8_t)i ||
		    s_gamma_lut[256 + i] != (uint8_t)i ||
		    s_gamma_lut[512 + i] != (uint8_t)i) {
			s_gamma_is_identity = false;
			break;
		}
	}
	s_classic_fb_texture_valid = false;
	if (s_init && SharedMetalDevice())
		upload_gamma_texture();
}

void *MetalCompositorGetGammaLUTBuffer(void)
{
	return s_init ? (void *)s_gamma_lut : nullptr;
}

void *MetalCompositorGetGammaIdentityBuffer(void)
{
	return s_init ? (void *)s_gamma_identity : nullptr;
}

void MetalCompositorRefreshPresentRect(void)
{
	int w = 0, h = 0;
	if (sdl_window)
		SDL_GetWindowSize(sdl_window, &w, &h);
	atomic_store_explicit(&s_present_origin, 0, std::memory_order_relaxed);
	atomic_store_explicit(&s_present_size,
		((uint64_t)(uint32_t)w << 32) | (uint32_t)h, std::memory_order_relaxed);
}

void MetalCompositorGetPresentRect(int *out_x, int *out_y, int *out_w, int *out_h)
{
	uint64_t o = atomic_load_explicit(&s_present_origin, std::memory_order_relaxed);
	uint64_t s = atomic_load_explicit(&s_present_size, std::memory_order_relaxed);
	if (out_x) *out_x = (int)(uint32_t)(o >> 32);
	if (out_y) *out_y = (int)(uint32_t)(o & 0xffffffffu);
	if (out_w) *out_w = (int)(uint32_t)(s >> 32);
	if (out_h) *out_h = (int)(uint32_t)(s & 0xffffffffu);
}

/* Internal helpers used by Metal submitframe module - provide stubs. */
extern "C" int MetalCompositorSubmitFrame_BindPresentationContext(
    void *, void *, void *) { return 0; }
extern "C" void MetalCompositorSubmitFrame_UnbindPresentationContext(void) {}
extern "C" void MetalCompositorSubmitFrame_SetFramebufferTexture(void *texture)
{
	if (texture)
		s_fb_tex_export = (GLuint)(uintptr_t)texture;
}
