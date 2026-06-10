/*
 *  metal_compositor.mm - Metal compositor for 2D framebuffer presentation
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Replaces SDL's rendering pipeline on iOS with a Metal compositor.
 *  Creates a UIView + CAMetalLayer covering the full iOS window, wraps
 *  the emulator's framebuffer as a zero-copy shared MTLBuffer, and
 *  renders a fullscreen triangle every frame to present the 2D desktop.
 *
 *  Supports all six Mac color depths:
 *    - 1/2/4/8-bit indexed: R8Uint texture + palette buffer lookup in shader
 *    - 16-bit direct: R16Uint texture + big-endian xRGB1555 unpack in shader
 *    - 32-bit direct: BGRA8Unorm texture + sampler (unchanged from S01)
 *
 *  Key design choices:
 *    - UIView created manually, NOT via SDL_Metal_CreateView (avoids
 *      SDL_GetWindowSize corruption feedback loop — see engine overlay
 *      comments for historical detail).
 *    - newBufferWithBytesNoCopy for zero-copy GPU access to the_buffer.
 *    - Fullscreen triangle (3 vertices via vertex_id, no vertex buffer).
 *    - Drawables are never cached across frames.
 *    - CAMetalLayer.drawableSize = Mac framebuffer dimensions, not UIView frame.
 *    - Integer textures (R8Uint, R16Uint) use tex.read() in shaders — not
 *      tex.sample(). CAMetalLayer min/magnificationFilter provides scaling.
 */

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>

#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>

#include <stdatomic.h>

#include "sysdeps.h"
#include "video.h"
#include "video_blit.h"
#include "metal_device_shared.h"
#include "metal_compositor.h"
#include "display_mode_controller.h"
#include "gfxaccel_resources.h"
#include "gfxaccel_resources_heap.h"
#include "metal_compositor_drawable_policy.h"
#include "vbl_source.h"
#include "prefs.h"
#include "MiscellaneousSettingsObjCCppHeader.h"

// ---------------------------------------------------------------------------
// Logging macros
// ---------------------------------------------------------------------------

#include "accel_logging.h"
#import <os/log.h>
#if ACCEL_LOGGING_ENABLED
bool compositor_logging_enabled = accel_log_detail::subsystem_on("comp");
os_log_t compositor_log = OS_LOG_DEFAULT;
static struct CompositorLogInit {
    CompositorLogInit() { compositor_log = os_log_create("com.pocketshaver.compositor", "engine"); }
} compositor_log_init;
#define COMPOSITOR_LOG(fmt, ...)  do { if (compositor_logging_enabled) os_log(compositor_log, fmt, ##__VA_ARGS__); } while (0)
#define COMPOSITOR_VLOG(fmt, ...) do { if (compositor_logging_enabled && ACCEL_LOG_VERBOSE) os_log(compositor_log, fmt, ##__VA_ARGS__); } while (0)
#else
static constexpr bool compositor_logging_enabled = false;
#define COMPOSITOR_LOG(fmt, ...)  do {} while (0)
#define COMPOSITOR_VLOG(fmt, ...) do {} while (0)
#endif

// Always-on error logging (NOT gated by ACCEL_LOGGING_ENABLED).
#if ACCEL_LOGGING_ENABLED
#define COMPOSITOR_ERR(fmt, ...) do { os_log_error(compositor_log, fmt, ##__VA_ARGS__); } while (0)
#else
#define COMPOSITOR_ERR(fmt, ...) do { os_log_error(OS_LOG_DEFAULT, fmt, ##__VA_ARGS__); } while (0)
#endif

// ---------------------------------------------------------------------------
// SDL window — declared in video_sdl2.cpp
// ---------------------------------------------------------------------------

extern SDL_Window *sdl_window;

// ---------------------------------------------------------------------------
// CompositorMetalView — UIView backed by CAMetalLayer
// ---------------------------------------------------------------------------

@interface CompositorMetalView : UIView
@end

@implementation CompositorMetalView
+ (Class)layerClass {
    return [CAMetalLayer class];
}
@end

// ---------------------------------------------------------------------------
// GetSDLUIWindow — retrieve UIWindow from SDL (shared pattern across engines)
// ---------------------------------------------------------------------------

static UIWindow *GetSDLUIWindow(void)
{
    if (!sdl_window) return nil;

    SDL_SysWMinfo wmInfo;
    SDL_VERSION(&wmInfo.version);
    if (!SDL_GetWindowWMInfo(sdl_window, &wmInfo)) {
        COMPOSITOR_ERR("GetSDLUIWindow: SDL_GetWindowWMInfo failed: %s", SDL_GetError());
        return nil;
    }
    if (wmInfo.subsystem != SDL_SYSWM_UIKIT) {
        COMPOSITOR_ERR("GetSDLUIWindow: not UIKit subsystem (%d)", wmInfo.subsystem);
        return nil;
    }
    return wmInfo.info.uikit.window;
}

// ---------------------------------------------------------------------------
// Static compositor state
// ---------------------------------------------------------------------------

static CompositorMetalView         *compositor_view     = nil;
static CAMetalLayer                *compositor_layer    = nil;
static id<MTLDevice>                compositor_device   = nil;
static id<MTLCommandQueue>          compositor_queue    = nil;
static id<MTLBuffer>                compositor_buffer   = nil;
static id<MTLTexture>               compositor_texture  = nil;
static id<MTLRenderPipelineState>   compositor_pipeline = nil;
static id<MTLSamplerState>          compositor_sampler  = nil;

// Lifecycle flag for Metal compositor state.
static bool                         compositor_initialized = false;

// Double-buffered palette. Two 256x4-byte MTLBuffers allocated from
// kHeapCompositor. Writer (emul thread) writes to back buffer. VBL callback
// swaps front/back atomically. Reader (compositor encode) binds front buffer
// to fragment shader. C11 _Atomic for index swap -- minimal threading
// primitive.
static id<MTLBuffer>                s_palette_buffers[2] = { nil, nil };
static _Atomic uint8_t              s_palette_front_idx  = 0;

// VBL-delivered drawable (iOS 17+ CAMetalDisplayLink path).
// The display link callback stores the drawable here; present paths consume it
// instead of calling [layer nextDrawable] (which throws when a display link is attached).
static id<CAMetalDrawable>          s_vbl_drawable       = nil;

// Gamma LUT buffer. 768 bytes planar: 256 R + 256 G + 256 B.
// Allocated from kHeapCompositor. Bound at fragment buffer index 2 for the
// indexed-mode shader. Updated from DMCModeSnapshot gamma_lut on each
// DMC gamma generation bump.
static id<MTLBuffer>                gamma_lut_buffer    = nil;

// Identity-LUT fallback buffer. A permanently-allocated
// 768-byte planar identity ramp bound whenever gamma_lut_buffer is nil so the
// gamma-sampling fragment shaders NEVER read an unbound buffer index (UB).
// Allocated at init alongside gamma_lut_buffer for ALL depths (16/32bpp present
// paths sample the LUT too, not just indexed). Read-only after init.
static id<MTLBuffer>                gamma_identity_buffer = nil;

// Compositor-side latched fade_active. Latched in
// compositor_vbl_callback FROM THE SAME gen-gated DMCModeSnapshot that drives
// the gamma LUT copy, so the (gamma_lut_buffer contents, fade_active) pair the
// present shaders see always traces back to ONE coherent snapshot. The present
// encode binds THIS value — it must NOT re-fetch a fresh dmc_current_snapshot()
// (which could pair a mid-fade LUT with a stale end-of-fade flag → one warped
// frame; the exact torn read this code exists to fix). The flag
// rides the EXISTING VBL-callback latch path; ZERO new concurrency primitives
// — the VBL callback and MetalCompositorPresent both run on the main
// thread, so a plain file-static is the correct same-thread carrier (matching
// the s_last_gamma_gen / frame_interval_usec main-thread statics).
static uint32_t                     s_latched_fade_active = 0;

// Depth-aware state (added in S02)
static int                          compositor_depth    = 0;
static int                          compositor_pixel_width   = 0;
static int                          compositor_pixel_height  = 0;
static int                          compositor_bits_per_pixel = 0;
static bool                         compositor_use_fallback_texture = false;
static int                          compositor_row_bytes = 0;
static int                          compositor_pitch     = 0;

// Shader library cache (retained across Init/Resize cycles for reuse).
static id<MTLLibrary>               compositor_library  = nil;

static NSUInteger                   s_last_overlay_scale_target_w = 0;
static NSUInteger                   s_last_overlay_scale_target_h = 0;
static int                          s_last_overlay_scale_fb_w = 0;
static int                          s_last_overlay_scale_fb_h = 0;

// ---------------------------------------------------------------------------
// Frame-pacing state — local cadence cache refreshed from DMC snapshots.
// ---------------------------------------------------------------------------

static uint64_t                     frame_interval_usec = 0;   // microseconds per VBL frame

/* TESTING_BUILD-only SubmitFrame counter (storage,
 * increment, and read/reset helpers) moved to metal_compositor_submitframe.mm
 * because the PocketShaverTests target
 * compiles metal_compositor_submitframe.mm but NOT metal_compositor.mm.
 * Keeping the symbols co-located in the test-built TU avoids the
 * undefined-symbol link failure that the counter-instrumented tests
 * would otherwise hit. The counter declaration that lived here
 * has been deleted; the active definition + helpers live in
 * metal_compositor_submitframe.mm under the same #ifdef TESTING_BUILD
 * gate. */

// ---------------------------------------------------------------------------
// SubmitFrame cross-module bindings
//
// The SubmitFrame implementation + blend-mode PSO cache + inflight
// semaphore + TESTING_BUILD seams all live in metal_compositor_submitframe.mm
// (no SDL2 dependency there - the test target can compile it in isolation).
// This file binds the production presentation context (device + queue +
// layer) into the submitframe module from MetalCompositorInit and clears
// it from MetalCompositorShutdown.
// ---------------------------------------------------------------------------

extern "C" int  MetalCompositorSubmitFrame_BindPresentationContext(
    void *device, void *queue, void *cametal_layer);
extern "C" void MetalCompositorSubmitFrame_UnbindPresentationContext(void);
extern "C" void MetalCompositorSubmitFrame_SetFramebufferTexture(void *texture);

static MetalCompositorDrawableSize MetalCompositorCurrentDrawableSize(int framebuffer_width,
                                                                      int framebuffer_height)
{
    UIWindow *uiWindow = GetSDLUIWindow();
    int view_width = 0;
    int view_height = 0;
    if (uiWindow) {
        view_width = (int)(uiWindow.bounds.size.width + 0.5);
        view_height = (int)(uiWindow.bounds.size.height + 0.5);
    }
    return MetalCompositorTargetDrawableSize(framebuffer_width,
                                             framebuffer_height,
                                             view_width,
                                             view_height);
}

static void MetalCompositorScaleLayerToDrawable(struct CompositeLayer *layer,
                                                NSUInteger drawable_width,
                                                NSUInteger drawable_height)
{
    if (!layer || drawable_width == 0 || drawable_height == 0) return;

    int fb_width = compositor_pixel_width;
    int fb_height = compositor_texture ? (int)[compositor_texture height] : 0;
    if (fb_height <= 0 && compositor_layer) {
        fb_height = (int)compositor_layer.drawableSize.height;
    }
    if (fb_width <= 0 || fb_height <= 0) return;

    if ((NSUInteger)fb_width == drawable_width &&
        (NSUInteger)fb_height == drawable_height) {
        return;
    }

    const float sx = (float)drawable_width / (float)fb_width;
    const float sy = (float)drawable_height / (float)fb_height;
    layer->dst_origin_x *= sx;
    layer->dst_origin_y *= sy;
    layer->dst_size_w *= sx;
    layer->dst_size_h *= sy;

    if (s_last_overlay_scale_target_w != drawable_width ||
        s_last_overlay_scale_target_h != drawable_height ||
        s_last_overlay_scale_fb_w != fb_width ||
        s_last_overlay_scale_fb_h != fb_height) {
        s_last_overlay_scale_target_w = drawable_width;
        s_last_overlay_scale_target_h = drawable_height;
        s_last_overlay_scale_fb_w = fb_width;
        s_last_overlay_scale_fb_h = fb_height;
        COMPOSITOR_LOG("MetalCompositorPresent: scaled cached overlay from framebuffer %dx%d to drawable %lux%lu (scale %.3fx%.3f)",
                       fb_width, fb_height,
                       (unsigned long)drawable_width,
                       (unsigned long)drawable_height,
                       sx, sy);
    }
}

// ---------------------------------------------------------------------------
// DMC subscriber callbacks
//
// Compositor registers as DMC subscriber FIRST (in MetalCompositorInit) so
// that reverse-order on_mode_enter dispatch makes the compositor the LAST
// subscriber to re-enter each mode — correct for a presentation layer that
// needs every engine to have bound its new overlay before the frame is drawn.
//
// Callbacks are observational / refresh local cadence cache.
// A future change will move overlay-nilling + palette-buffer teardown from
// MetalCompositorResize into OnModeExit, and the Resize-rebuild into
// OnModeEnter, eliminating the separate MetalCompositorInit/Resize call path.
// ---------------------------------------------------------------------------
static int32_t MetalCompositor_OnModeExit(const struct DMCModeSnapshot *outgoing, void *ctx)
{
    (void)ctx;
    if (outgoing) {
        COMPOSITOR_LOG("DMC on_mode_exit: outgoing gen=%u %ux%u depth=%u",
                       outgoing->generation, outgoing->width, outgoing->height, outgoing->depth);
    }
    // rave-overlay-flicker-black fix (2026-04-16): drop the cached overlay
    // on every real mode exit.  The cache retains an MTLTexture vended at
    // the outgoing mode's resolution; the incoming mode may reallocate a
    // per-engine overlay at a different size, so the cache would otherwise
    // point at a stale (possibly-freed) texture or an oversized one that
    // composes incorrectly.  Engines re-populate the cache on their next
    // SubmitFrame after attaching to the new mode.
    MetalCompositorSubmitFrame_ClearCachedOverlay();
    // No resource teardown moved here yet.
    return 0;
}

static int32_t MetalCompositor_OnModeEnter(const struct DMCModeSnapshot *incoming, void *ctx)
{
    (void)ctx;
    if (incoming && incoming->vbl_usec > 0) {
        // Refresh local cadence cache from the snapshot. If vbl_usec is 0
        // (snapshot built before controller filled it) we keep the existing
        // frame_interval_usec that MetalCompositorInit/Resize already computed.
        frame_interval_usec = incoming->vbl_usec;
    }
    if (incoming) {
        COMPOSITOR_LOG("DMC on_mode_enter: incoming gen=%u %ux%u depth=%u vbl_usec=%llu",
                       incoming->generation, incoming->width, incoming->height, incoming->depth,
                       (unsigned long long)incoming->vbl_usec);
    } else {
        return 0;
    }

    /* CF-22.3-06 + CF-22.3-07: when DSp owns the framebuffer, resize the
     * compositor texture to match the Mac mode. Presentation still renders into
     * the host window-sized drawable; the compositor shader scales the Mac-mode
     * framebuffer texture across that drawable. Without this, the framebuffer
     * texture stays at the init-time window dimensions while DSp only writes a
     * top-left region = the "small corner" UX symptom.
     *
     * The compositor texture is forced to BGRA8Unorm (VIDEO_DEPTH_32BIT)
     * because DSp decodes its source-format back buffer (e.g. R16Uint
     * xRGB1555 at 16bpp) into BGRA8Unorm during its own render pass before
     * the compositor sees it. The Mac-side mode depth is preserved in the
     * snapshot; only the compositor's internal pixel format is normalised.
     *
     * RAVE/GL are overlay contributors, not compositor-framebuffer writers.
     * They still rely on the QuickDraw host framebuffer underlay for classic
     * 2D UI, so rebuilding compositor_texture with a NULL host buffer here
     * hides those CPU-side UI writes.
     *
     * QuickDraw mode switches normally retain their existing behaviour (no
     * auto-resize here; the QD-side path manages compositor refresh through
     * its own mechanism). DSp release is the exception: it publishes a
     * QuickDraw snapshot with screen_base_host set to the restored MainDevice
     * framebuffer, so the compositor can rebuild away from the DSp-owned
     * BGRA render target and present the real desktop surface again.
     */
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
                NULL,                    /* engine writes via render pass; no host buffer */
                bgra_size);
            if (rc != 0) {
                COMPOSITOR_ERR("DMC on_mode_enter: MetalCompositorResize failed (rc=%d) for "
                               "DSp owner %dx%d — drawable will appear small in window",
                               rc, new_w, new_h);
                /* Non-fatal: engine writes still land in the existing (mismatched)
                 * framebuffer texture, which appears in a corner of the window
                 * (pre-CF-22.3-06 behaviour). */
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
// bits_per_pixel_for_depth — convert VIDEO_DEPTH_* to actual bit count
// ---------------------------------------------------------------------------

static int bits_per_pixel_for_depth(int depth)
{
    if (depth == VIDEO_DEPTH_1BIT)  return 1;
    if (depth == VIDEO_DEPTH_2BIT)  return 2;
    if (depth == VIDEO_DEPTH_4BIT)  return 4;
    if (depth == VIDEO_DEPTH_8BIT)  return 8;
    if (depth == VIDEO_DEPTH_16BIT) return 16;
    if (depth == VIDEO_DEPTH_32BIT) return 32;
    return 0;
}

// ---------------------------------------------------------------------------
// fill_identity_gamma_lut — write a 768-byte planar identity ramp (256 R +
// 256 G + 256 B) into a buffer's contents. Shared by the live gamma_lut_buffer
// init and the gamma_identity_buffer fallback.
// ---------------------------------------------------------------------------

static void fill_identity_gamma_lut(uint8_t *lut)
{
    for (int i = 0; i < 256; i++) {
        lut[i]       = (uint8_t)i;
        lut[256 + i] = (uint8_t)i;
        lut[512 + i] = (uint8_t)i;
    }
}

// ---------------------------------------------------------------------------
// alloc_gamma_buffer — allocate a 768-byte shared MTLBuffer from kHeapCompositor
// (with a device fallback if the heap is exhausted) and seed it with an
// identity ramp. Returns nil only if BOTH allocation paths fail. Shared by the
// live gamma_lut_buffer and the gamma_identity_buffer.
// ---------------------------------------------------------------------------

static id<MTLBuffer> alloc_gamma_buffer(const char *label)
{
    id<MTLBuffer> buf = (__bridge_transfer id<MTLBuffer>)
        gfxaccel_resources_heap_alloc_buffer(kHeapCompositor, 768,
                                             MTLResourceStorageModeShared);
    if (!buf) {
        COMPOSITOR_ERR("alloc_gamma_buffer(%s): heap alloc failed; falling back", label);
        // heap-exempt: gamma LUT fallback (only if heap is exhausted)
        buf = [compositor_device newBufferWithLength:768
                                             options:MTLResourceStorageModeShared];
    }
    if (buf) {
        fill_identity_gamma_lut((uint8_t *)buf.contents);
    }
    return buf;
}

// ---------------------------------------------------------------------------
// texture_format_name — human-readable format name for logging
// ---------------------------------------------------------------------------

static const char *texture_format_name(MTLPixelFormat fmt)
{
    switch (fmt) {
        case MTLPixelFormatR8Uint:      return "R8Uint";
        case MTLPixelFormatR16Uint:     return "R16Uint";
        case MTLPixelFormatBGRA8Unorm:  return "BGRA8Unorm";
        default:                        return "Unknown";
    }
}

// ---------------------------------------------------------------------------
// VBL callback — fired on every display-link tick
// ---------------------------------------------------------------------------
static void compositor_vbl_callback(void *ctx, void *drawable, double target_ts)
{
	(void)ctx;

	// Store the display-link-delivered drawable for the next present call.
	// On iOS 17+ (CAMetalDisplayLink), calling [layer nextDrawable] throws;
	// the drawable MUST come from the display link callback instead.
	if (drawable) {
		s_vbl_drawable = (__bridge id<CAMetalDrawable>)drawable;
	}

	// 1. Latch palette double-buffer
	MetalCompositorPaletteLatch();

	// 2. Propagate target timestamp for present(at:)
	MetalCompositorSubmitFrame_SetTargetTimestamp(target_ts);

	// 3. Copy gamma LUT from DMC snapshot to compositor buffer if gamma_gen
	//    changed, AND latch fade_active FROM THE SAME snapshot.
	//    The producer publishes (gamma_lut, fade_active) atomically in
	//    one snapshot bump and bumps gamma_gen on EVERY fade_active change
	//    (dmc_record_gamma_change_with_lut_fade), so latching fade_active at the
	//    gen-gate keeps the latched flag coherent with the LUT bytes now in
	//    gamma_lut_buffer. MetalCompositorPresent binds s_latched_fade_active —
	//    it does NOT re-fetch a fresh dmc_current_snapshot() (that fresh read was
	//    the torn-snapshot bug: a mid-fade LUT could pair with an end-of-fade
	//    flag → one warped frame). One snapshot, one (LUT, flag) pair.
	const DMCModeSnapshot *snap = dmc_current_snapshot();
	if (snap != NULL && gamma_lut_buffer != nil) {
		static uint32_t s_last_gamma_gen = 0;
		if (snap->gamma_gen != s_last_gamma_gen) {
			memcpy(gamma_lut_buffer.contents, snap->gamma_lut, 768);
			s_latched_fade_active = snap->fade_active ? 1u : 0u;
			s_last_gamma_gen = snap->gamma_gen;
			COMPOSITOR_LOG("VBL callback: updated gamma LUT (gen=%u fade_active=%u)",
			               snap->gamma_gen, s_latched_fade_active);
		}
	}
}

// ---------------------------------------------------------------------------
// MetalCompositorInit
// ---------------------------------------------------------------------------

int MetalCompositorInit(int width, int height, int depth, int row_bytes,
                        int pitch, void *buffer, uint32_t buffer_size)
{
    // --- Store depth state ---
    compositor_depth = depth;
    compositor_pixel_width = width;
    compositor_pixel_height = height;
    compositor_bits_per_pixel = bits_per_pixel_for_depth(depth);
    compositor_row_bytes = row_bytes;
    compositor_pitch = pitch;
    compositor_use_fallback_texture = false;

    if (compositor_bits_per_pixel == 0) {
        COMPOSITOR_ERR("MetalCompositorInit: FAILED — unknown depth value %d", depth);
        return -1;
    }

    // --- Device & queue from shared singleton ---
    compositor_device = (__bridge id<MTLDevice>)SharedMetalDevice();
    if (!compositor_device) {
        COMPOSITOR_ERR("MetalCompositorInit: FAILED — SharedMetalDevice returned nil");
        return -1;
    }

    compositor_queue = (__bridge id<MTLCommandQueue>)SharedMetalCommandQueue();
    if (!compositor_queue) {
        COMPOSITOR_ERR("MetalCompositorInit: FAILED — SharedMetalCommandQueue returned nil");
        return -1;
    }

    // --- UIWindow ---
    UIWindow *uiWindow = GetSDLUIWindow();
    if (!uiWindow) {
        COMPOSITOR_ERR("MetalCompositorInit: FAILED — cannot get UIWindow");
        return -1;
    }

    // --- CompositorMetalView covering full window ---
    compositor_view = [[CompositorMetalView alloc] initWithFrame:uiWindow.bounds];
    compositor_view.opaque = YES;
    compositor_view.backgroundColor = [UIColor blackColor];
    compositor_view.userInteractionEnabled = NO;  // let touches pass to SDL

    compositor_layer = (CAMetalLayer *)compositor_view.layer;
    compositor_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    compositor_layer.device = compositor_device;
    compositor_layer.maximumDrawableCount = 3;         // triple buffering
    compositor_layer.framebufferOnly = YES;
    MetalCompositorDrawableSize target_size =
        MetalCompositorCurrentDrawableSize(width, height);
    compositor_layer.drawableSize = CGSizeMake(target_size.width, target_size.height);
    compositor_layer.contentsGravity = kCAGravityResizeAspect;  // preserve aspect ratio (letterbox)

    // --- CAMetalLayer scaling filter from user preference ---
    bool useNearest = PrefsFindBool("scale_nearest");
    compositor_layer.minificationFilter = useNearest ? kCAFilterNearest : kCAFilterLinear;
    compositor_layer.magnificationFilter = useNearest ? kCAFilterNearest : kCAFilterLinear;

    // Explicitly declare sRGB color space
    {
        // CGColorSpaceCreateWithName returns a +1 retained CGColorSpaceRef;
        // CAMetalLayer.colorspace is a Core Foundation property whose setter
        // retains.  Without CGColorSpaceRelease we leak one CGColorSpaceRef
        // per Resize (Nanosaur mode-switch path hits this every scene
        // transition).
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        compositor_layer.colorspace = cs;
        if (cs) CGColorSpaceRelease(cs);
    }

    [uiWindow addSubview:compositor_view];

    COMPOSITOR_LOG("View created: layer=%p view=%p framebuffer=%dx%d drawableSize=%dx%d windowBounds=%.0fx%.0f",
                   compositor_layer, compositor_view,
                   width, height,
                   target_size.width, target_size.height,
                   uiWindow.bounds.size.width, uiWindow.bounds.size.height);

    // --- Zero-copy shared buffer wrapping the_buffer ---
    // gfxaccel_resources is the sole owner of the
    // framebuffer MTLBuffer. The newBufferWithBytesNoCopy fallback
    // has been removed — any nil return from the resource manager is a hard
    // Init failure.
    compositor_buffer = (__bridge id<MTLBuffer>)gfxaccel_resources_get_framebuffer_buffer(
        buffer, buffer_size);
    if (!compositor_buffer) {
        COMPOSITOR_ERR("MetalCompositorInit: FAILED — gfxaccel_resources_get_framebuffer_buffer "
                       "returned NULL (buffer=%p size=%u)",
                       buffer, buffer_size);
        return -1;
    }

    // --- Select texture format and dimensions per depth ---
    MTLPixelFormat texFormat;
    NSUInteger texWidth;

    if (depth <= VIDEO_DEPTH_8BIT) {
        // Indexed depths: R8Uint, texture width = row_bytes (bytes, not pixels)
        texFormat = MTLPixelFormatR8Uint;
        texWidth = (NSUInteger)row_bytes;
    } else if (depth == VIDEO_DEPTH_16BIT) {
        // 16-bit direct: R16Uint, texture width = pixel width
        texFormat = MTLPixelFormatR16Uint;
        texWidth = (NSUInteger)width;
    } else {
        // 32-bit direct: BGRA8Unorm, texture width = pixel width
        texFormat = MTLPixelFormatBGRA8Unorm;
        texWidth = (NSUInteger)width;
    }

    // --- Texture view over the shared buffer ---
    MTLTextureDescriptor *texDesc = [[MTLTextureDescriptor alloc] init];
    texDesc.textureType = MTLTextureType2D;
    texDesc.pixelFormat = texFormat;
    texDesc.width = texWidth;
    texDesc.height = (NSUInteger)height;
    texDesc.storageMode = MTLStorageModeShared;
    // Include RenderTarget usage so the DSp
    // engine's mismatched-format present pass (R16Uint xRGB1555 ->
    // BGRA8Unorm at 16 bpp) can use this texture as a color attachment.
    // ShaderRead is still primary (the compositor's own present pass
    // samples it). Engine-blindness invariant preserved: this is just a
    // usage-flag extension; no engine identifiers introduced.
    texDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;

    // Try zero-copy texture from buffer first (bytesPerRow = row_bytes for indexed,
    // or pitch for direct modes). Metal requires bytesPerRow to be 16-byte aligned
    // for buffer-backed textures — a hard assertion failure, not a nil return.
    int texBytesPerRow = (depth <= VIDEO_DEPTH_8BIT) ? row_bytes : pitch;
    bool bytesPerRowAligned = (texBytesPerRow % 16 == 0);

    if (bytesPerRowAligned && compositor_buffer != nil) {
        compositor_texture = [compositor_buffer newTextureWithDescriptor:texDesc
                                                                 offset:0
                                                            bytesPerRow:(NSUInteger)texBytesPerRow];
    }

    if (!compositor_texture) {
        // Fallback: standalone texture with replaceRegion per frame.
        // Triggered when bytesPerRow is not 16-byte aligned (e.g. 1366×4=5464)
        // or when Metal rejects the buffer texture for other reasons.
        COMPOSITOR_LOG("MetalCompositorInit: buffer texture skipped/failed for %s "
                       "(bytesPerRow=%d aligned=%d), using standalone texture with replaceRegion",
                       texture_format_name(texFormat), texBytesPerRow, bytesPerRowAligned);
        texDesc.storageMode = MTLStorageModeShared;
        compositor_texture = [compositor_device newTextureWithDescriptor:texDesc];
        if (!compositor_texture) {
            COMPOSITOR_ERR("MetalCompositorInit: FAILED — newTextureWithDescriptor fallback "
                           "(format=%s width=%lu height=%d)",
                           texture_format_name(texFormat), (unsigned long)texWidth, height);
            return -1;
        }
        compositor_use_fallback_texture = true;
    }

    // --- Publish framebuffer texture to SubmitFrame module ---
    // Exposes compositor_texture so DSpContext_SwapBuffersHandler can blit
    // the DSp back-buffer into it via MTLBlitCommandEncoder. The setter
    // lives in metal_compositor_submitframe.mm (test-target-compatible);
    // DSp calls MetalCompositorGetFramebufferTexture() to retrieve it.
    MetalCompositorSubmitFrame_SetFramebufferTexture(
        (__bridge void *)compositor_texture);

    // --- Double-buffered palette for indexed depths ---
    if (depth <= VIDEO_DEPTH_8BIT) {
        for (int i = 0; i < 2; i++) {
            s_palette_buffers[i] = (__bridge_transfer id<MTLBuffer>)
                gfxaccel_resources_heap_alloc_buffer(kHeapCompositor, 256 * 4,
                                                     MTLResourceStorageModeShared);
            if (!s_palette_buffers[i]) {
                COMPOSITOR_ERR("MetalCompositorInit: palette_buffer[%d] heap alloc failed; falling back", i);
                // heap-exempt: palette fallback (only if heap is exhausted)
                s_palette_buffers[i] = [compositor_device newBufferWithLength:256 * 4
                                                                     options:MTLResourceStorageModeShared];
            }
            if (!s_palette_buffers[i]) {
                COMPOSITOR_ERR("MetalCompositorInit: FAILED — palette_buffer[%d] creation", i);
                return -1;
            }
            memset(s_palette_buffers[i].contents, 0, 256 * 4);
        }
        atomic_store_explicit(&s_palette_front_idx, 0, memory_order_relaxed);
        COMPOSITOR_LOG("MetalCompositorInit: s_palette_buffers[2] created (256x4 bytes each)");
    }

    // --- Gamma LUT buffers for ALL depths (LUT sampling extends to the
    //     16bpp + 32bpp present shaders, so the live buffer is
    //     no longer indexed-only). gamma_identity_buffer is the fallback
    //     bound whenever gamma_lut_buffer is nil so the gamma-sampling shaders
    //     never read an unbound buffer index. Both seed with an identity ramp;
    //     the VBL callback overwrites gamma_lut_buffer with the DMC fade LUT. ---
    gamma_lut_buffer      = alloc_gamma_buffer("gamma_lut_buffer");
    gamma_identity_buffer = alloc_gamma_buffer("gamma_identity_buffer");
    if (!gamma_lut_buffer || !gamma_identity_buffer) {
        // A nil gamma buffer is a hard init failure — proceeding would
        // encode a present whose shaders dereference an unbound argument (UB).
        COMPOSITOR_ERR("MetalCompositorInit: FAILED — gamma buffer creation "
                       "(lut=%p identity=%p)", gamma_lut_buffer, gamma_identity_buffer);
        return -1;
    }
    s_latched_fade_active = 0;  // no fade in progress at init
    COMPOSITOR_LOG("MetalCompositorInit: gamma_lut_buffer + gamma_identity_buffer "
                   "created (768 bytes each)");

    // --- Shader library (cached for reuse across Resize calls) ---
    if (!compositor_library) {
        compositor_library = [compositor_device newDefaultLibrary];
    }
    id<MTLLibrary> library = compositor_library;
    if (!library) {
        COMPOSITOR_ERR("MetalCompositorInit: FAILED — newDefaultLibrary returned nil");
        return -1;
    }

    id<MTLFunction> vertexFunc = [library newFunctionWithName:@"compositor_vertex"];
    if (!vertexFunc) {
        COMPOSITOR_ERR("MetalCompositorInit: FAILED — vertex function 'compositor_vertex' not found");
        return -1;
    }

    // --- Select fragment function by depth ---
    NSString *fragmentName;
    if (depth <= VIDEO_DEPTH_8BIT) {
        fragmentName = @"compositor_fragment_indexed";
    } else if (depth == VIDEO_DEPTH_16BIT) {
        fragmentName = @"compositor_fragment_16bpp";
    } else {
        fragmentName = @"compositor_fragment_32bpp";
    }

    id<MTLFunction> fragmentFunc = [library newFunctionWithName:fragmentName];
    if (!fragmentFunc) {
        COMPOSITOR_ERR("MetalCompositorInit: FAILED — fragment function '%s' not found",
                       [fragmentName UTF8String]);
        return -1;
    }

    // --- Render pipeline ---
    MTLRenderPipelineDescriptor *pipeDesc = [[MTLRenderPipelineDescriptor alloc] init];
    pipeDesc.vertexFunction = vertexFunc;
    pipeDesc.fragmentFunction = fragmentFunc;
    pipeDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    NSError *pipeError = nil;
    compositor_pipeline = [compositor_device newRenderPipelineStateWithDescriptor:pipeDesc
                                                                           error:&pipeError];
    if (!compositor_pipeline) {
        COMPOSITOR_ERR("MetalCompositorInit: FAILED — pipeline creation for '%s': %s",
                       [fragmentName UTF8String],
                       [[pipeError localizedDescription] UTF8String]);
        return -1;
    }

    // --- Sampler state for 32-bit mode (nearest or linear from user pref) ---
    if (depth == VIDEO_DEPTH_32BIT) {
        MTLSamplerDescriptor *sampDesc = [[MTLSamplerDescriptor alloc] init];
        sampDesc.minFilter = useNearest ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
        sampDesc.magFilter = useNearest ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
        sampDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sampDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;

        compositor_sampler = [compositor_device newSamplerStateWithDescriptor:sampDesc];
        if (!compositor_sampler) {
            COMPOSITOR_ERR("MetalCompositorInit: FAILED — sampler creation");
            return -1;
        }
    } else {
        compositor_sampler = nil;
    }

    COMPOSITOR_LOG("MetalCompositorInit: success — depth=%d (%dbpp) format=%s "
                   "pixel_width=%d tex_width=%lu shader=%s filter=%s%s",
                   depth, compositor_bits_per_pixel,
                   texture_format_name(texFormat),
                   width, (unsigned long)texWidth,
                   [fragmentName UTF8String],
                   useNearest ? "nearest" : "linear",
                   compositor_use_fallback_texture ? " (fallback texture)" : "");
    compositor_initialized = true;

    // Subscribe to DMC FIRST:
    // compositor registered first → reverse-order enter makes compositor LAST
    // to re-enter, after every engine has bound its new overlay. Subsequent
    // Init calls (after Shutdown/Init cycles) are idempotent on the subscriber
    // front: if the name is already registered, dmc_subscribe returns
    // kDMCErrSubscriberAlreadyRegistered — which we tolerate silently.
    {
        static DMCSubscriber compositor_sub = {
            /* .name          = */ "compositor",
            /* .on_mode_exit  = */ MetalCompositor_OnModeExit,
            /* .on_mode_enter = */ MetalCompositor_OnModeEnter,
            /* .ctx           = */ NULL,
        };
        int32_t sub_err = dmc_subscribe(&compositor_sub);
        if (sub_err != kDMCNoErr && sub_err != kDMCErrSubscriberAlreadyRegistered) {
            COMPOSITOR_ERR("dmc_subscribe('compositor') FAILED err=%d — "
                           "falling back to local cadence", (int)sub_err);
        }
    }

    // Read VBL cadence from the controller snapshot if available; fall back to
    // direct objc_getFrameRateSetting() query. (A just-subscribed subscriber
    // receives a catchup synthetic on_mode_enter, which will
    // populate frame_interval_usec via MetalCompositor_OnModeEnter — but only
    // if the controller already had a published snapshot with vbl_usec > 0.
    // The initial dmc_create at VideoInit sets vbl_usec = 0, so the fallback
    // path is the normal first-boot behavior.)
    const DMCModeSnapshot *snap = dmc_current_snapshot();
    if (snap != NULL && snap->vbl_usec > 0) {
        frame_interval_usec = snap->vbl_usec;
    } else {
        int refresh_hz = objc_getFrameRateSetting();
        if (refresh_hz <= 0) refresh_hz = 60;
        frame_interval_usec = 1000000 / (uint64_t)refresh_hz;
    }

    // --- Bind the presentation context into the SubmitFrame
    //     module. This creates the inflight semaphore (depth 3, matching
    //     CAMetalLayer.maximumDrawableCount) and builds the blend-mode PSO
    //     cache the first time through; subsequent Shutdown->Init cycles
    //     rebuild the PSOs against the current device. ---
    int sf_err = MetalCompositorSubmitFrame_BindPresentationContext(
        (__bridge void *)compositor_device,
        (__bridge void *)compositor_queue,
        (__bridge void *)compositor_layer);
    if (sf_err != 0) {
        COMPOSITOR_ERR("MetalCompositorInit: FAILED — SubmitFrame bind err=%d", sf_err);
        return -1;
    }

    // Initialize VBL source with display-link-driven callbacks
    int32_t vbl_err = vbl_source_init((__bridge void *)compositor_layer,
                                       compositor_vbl_callback,
                                       NULL);
    if (vbl_err != 0) {
        COMPOSITOR_ERR("MetalCompositorInit: vbl_source_init failed (%d)", vbl_err);
        // Non-fatal: compositor can still work without VBL source (immediate present fallback)
    }

    return 0;
}

// ---------------------------------------------------------------------------
// MetalCompositorUpdatePalette — upload palette for indexed depths
// ---------------------------------------------------------------------------

void MetalCompositorUpdatePalette(const uint8_t *pal, int num_colors)
{
    if (!s_palette_buffers[0] || !s_palette_buffers[1]) {
        COMPOSITOR_ERR("MetalCompositorUpdatePalette: no palette buffers "
                       "(depth=%d is not indexed)", compositor_depth);
        return;
    }

    if (num_colors > 256) num_colors = 256;
    if (num_colors <= 0 || !pal) return;

    // Write to back buffer. The VBL-latched swap ensures
    // palette-animating apps can hammer the palette at any rate without
    // stalling the render queue -- each VBL picks up the latest back state.
    uint8_t back = 1 - atomic_load_explicit(&s_palette_front_idx, memory_order_relaxed);
    uint8_t *dst = (uint8_t *)s_palette_buffers[back].contents;
    for (int i = 0; i < num_colors; i++) {
        dst[i * 4 + 0] = pal[i * 3 + 0];  // R
        dst[i * 4 + 1] = pal[i * 3 + 1];  // G
        dst[i * 4 + 2] = pal[i * 3 + 2];  // B
        dst[i * 4 + 3] = 255;              // A
    }

    COMPOSITOR_LOG("MetalCompositorUpdatePalette: wrote %d colors to back buffer", num_colors);
}

// ---------------------------------------------------------------------------
// MetalCompositorPaletteLatch — VBL-latched swap
// ---------------------------------------------------------------------------
// Called from the VBL callback BEFORE any command encoding for the frame
// begins. Promotes back->front atomically so the compositor always reads
// a complete, consistent palette.

void MetalCompositorPaletteLatch(void)
{
    uint8_t old = atomic_load_explicit(&s_palette_front_idx, memory_order_relaxed);
    atomic_store_explicit(&s_palette_front_idx, 1 - old, memory_order_release);
}

// ---------------------------------------------------------------------------
// MetalCompositorUpdateGammaLUT — copy gamma LUT from DMC snapshot
// ---------------------------------------------------------------------------
// Called when the DMC gamma generation counter changes. Copies 768 bytes (planar: 256 R + 256 G +
// 256 B) from the snapshot's gamma_lut into the gamma_lut_buffer MTLBuffer
// so the compositor fragment shader can apply per-channel gamma correction.

void MetalCompositorUpdateGammaLUT(const uint8_t *lut)
{
    if (!gamma_lut_buffer || !lut) return;
    memcpy(gamma_lut_buffer.contents, lut, 768);
    COMPOSITOR_LOG("MetalCompositorUpdateGammaLUT: updated 768 bytes");
}

// Production accessor for the gamma_lut_buffer so the DSp
// 16bpp unpack render pass can bind the same LUT the present shaders sample
// (the non-visible-path twin — see dsp_metal_renderer.mm).
void *MetalCompositorGetGammaLUTBuffer(void)
{
    return (__bridge void *)gamma_lut_buffer;
}

// The permanently-allocated identity-LUT fallback buffer.
// The DSp 16bpp unpack twin binds this when MetalCompositorGetGammaLUTBuffer()
// is nil (compositor mid-init) so its gamma-sampling shader never reads an
// unbound buffer index (UB). Returns NULL only if the compositor is fully
// uninitialized — the twin then aborts the pass rather than encoding an
// unbound read.
void *MetalCompositorGetGammaIdentityBuffer(void)
{
    return (__bridge void *)gamma_identity_buffer;
}

// ---------------------------------------------------------------------------
// Historical: the legacy engine-specific overlay API was deleted
// (CreateOverlayTexture / GetOverlayTexture / SetOverlayActive /
// SetOverlayRect / Sync3DFramePacing) and the supporting file-static state
// (overlay_texture, overlay_active, overlay_pipeline, overlay_sampler,
// overlay_x/y/width/height/viewport_w/h, last_3d_frame_usec). The 3D engines
// now own their overlays via gfxaccel_resources_vend_overlay_texture and
// submit frames via MetalCompositorSubmitFrame — the compositor is blind to
// which engine produced any given CompositeLayer (RES-04 / Success #5).
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// MetalCompositorPresent — render one frame (2D framebuffer only)
// ---------------------------------------------------------------------------

void *MetalCompositorConsumeVBLDrawable(void)
{
    id<CAMetalDrawable> d = s_vbl_drawable;
    s_vbl_drawable = nil;
    return (__bridge_retained void *)d;
}

void MetalCompositorPresent(void)
{
    if (!compositor_layer || !compositor_pipeline) return;

    @autoreleasepool {

    // If using fallback texture, upload framebuffer data via replaceRegion.
    //
    // Skip this CPU upload when the active owner is driving the framebuffer
    // texture. In that case the owner has already encoded its own render pass
    // into compositor_texture (e.g. DSp's DSpEncodePresentToFramebuffer), and:
    //   (a) replaceRegion: here would clobber the owner's render output, and
    //   (b) Metal validation rejects replaceRegion: on a texture that is
    //       currently attached as a writeable render target by an in-flight
    //       command buffer ("_validateReplaceRegion" assertion). The DSp
    //       publish callback commits its render pass asynchronously, so the
    //       GPU may still hold compositor_texture as a render-target
    //       attachment when MetalCompositorPresent runs the next VBL tick.
    //
    // RAVE/GL are overlay owners. They submit cached overlay layers, but the
    // base compositor_texture is still the QuickDraw/NQD CPU framebuffer.
    // Keep uploading it so post-RAVE classic 2D UI/text remains visible under
    // or outside the overlay.
    bool skip_cpu_upload = false;
    {
        const DMCModeSnapshot *snap = dmc_current_snapshot();
        if (snap != NULL) {
            uint32_t owner = snap->active_owner;
            if (owner != (uint32_t)kDMCOwnerQuickDraw &&
                owner != (uint32_t)kDMCOwnerRAVE &&
                owner != (uint32_t)kDMCOwnerGL) {
                skip_cpu_upload = true;
            }
        }
    }
    if (!skip_cpu_upload && compositor_use_fallback_texture && compositor_texture && compositor_buffer) {
        MTLRegion region = MTLRegionMake2D(0, 0,
                                           compositor_texture.width,
                                           compositor_texture.height);
        [compositor_texture replaceRegion:region
                              mipmapLevel:0
                                withBytes:compositor_buffer.contents
                              bytesPerRow:(NSUInteger)compositor_pitch];
    }

    id<CAMetalDrawable> drawable = [compositor_layer nextDrawable];
    if (!drawable) {
        return;
    }

    // Render pass: clear to black, draw fullscreen triangle sampling framebuffer
    MTLRenderPassDescriptor *passDesc = [MTLRenderPassDescriptor renderPassDescriptor];
    passDesc.colorAttachments[0].texture = drawable.texture;
    passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandBuffer> cmdBuf = [compositor_queue commandBuffer];
    if (!cmdBuf) return;

    id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:passDesc];
    if (!enc) return;

    [enc setRenderPipelineState:compositor_pipeline];
    [enc setFragmentTexture:compositor_texture atIndex:0];

    // Bind the fade flag that was LATCHED in
    // compositor_vbl_callback from the SAME gen-gated snapshot as the gamma LUT
    // now sitting in gamma_lut_buffer. We do NOT re-fetch dmc_current_snapshot()
    // here — a fresh present-time read could observe a newer fade_active than
    // the LUT bytes the VBL callback latched, pairing a mid-fade LUT with an
    // end-of-fade flag on the final fade frame (torn read: one
    // warped frame). The (LUT, fade_active) pair the shader sees must come from
    // one coherent snapshot/gen.
    uint32_t fade_active = s_latched_fade_active;

    // The gamma-sampling shaders read the LUT buffer index
    // unconditionally, so it MUST always be bound. Prefer the live
    // gamma_lut_buffer; fall back to the permanently-allocated identity buffer
    // if the live buffer is nil (pre-init / alloc-failure window). NEVER leave
    // the buffer index unbound — that is undefined behavior in the shader.
    id<MTLBuffer> gamma_to_bind = gamma_lut_buffer ? gamma_lut_buffer
                                                   : gamma_identity_buffer;

    if (compositor_depth <= VIDEO_DEPTH_8BIT) {
        // Indexed mode: bind VBL-latched front palette buffer + uniforms
        uint8_t front = atomic_load_explicit(&s_palette_front_idx, memory_order_acquire);
        [enc setFragmentBuffer:s_palette_buffers[front] offset:0 atIndex:0];
        uint32_t bpp = (uint32_t)compositor_bits_per_pixel;
        [enc setFragmentBytes:&bpp length:sizeof(bpp) atIndex:1];

        // Bind gamma LUT buffer at index 2 - always bound.
        [enc setFragmentBuffer:gamma_to_bind offset:0 atIndex:2];

        // pixel_width shifts to index 3 (gamma_lut takes index 2)
        uint32_t pw  = (uint32_t)compositor_pixel_width;
        [enc setFragmentBytes:&pw  length:sizeof(pw)  atIndex:3];

        // fade_active lands at the next free buffer index 4.
        [enc setFragmentBytes:&fade_active length:sizeof(fade_active) atIndex:4];
    } else if (compositor_depth == VIDEO_DEPTH_16BIT) {
        // 16bpp now samples the gamma LUT. The 16bpp shader's buffer
        // namespace is empty (it previously bound nothing), so gamma_lut=0,
        // fade_active=1 (separate per-branch index namespaces).
        // Always bound.
        [enc setFragmentBuffer:gamma_to_bind offset:0 atIndex:0];
        [enc setFragmentBytes:&fade_active length:sizeof(fade_active) atIndex:1];
    } else if (compositor_depth == VIDEO_DEPTH_32BIT) {
        // 32-bit mode: bind sampler (sampler-state index, NOT a buffer index — no
        // collision with the gamma_lut buffer at index 0).
        [enc setFragmentSamplerState:compositor_sampler atIndex:0];
        // Bind the gamma LUT + fade flag so a DSp FadeGamma is visible
        // at the DSp force-resized 32bpp depth (the VISIBLE present path).
        // Always bound.
        [enc setFragmentBuffer:gamma_to_bind offset:0 atIndex:0];
        [enc setFragmentBytes:&fade_active length:sizeof(fade_active) atIndex:1];
    }

    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];

    // rave-overlay-flicker-black fix (2026-04-16): composite the last-known
    // overlay atop the 2D framebuffer.  The SubmitFrame module caches the
    // most recent kLayerSlotOverlay CompositeLayer (retaining its source
    // MTLTexture).  During active 3D submission SubmitFrame also calls
    // presentDrawable with its own overlay-only pass and the two present
    // calls race for the CAMetalLayer drawable pool -- in steady state the
    // user sees whichever landed last.  During engine-paused intervals (the
    // QADrawContextDelete -> QADrawContextNew window, ~20 log lines of
    // host gestalt probing) SubmitFrame stops firing and only this present
    // path runs; before this fix, the interval produced a visible black flash
    // because the 2D framebuffer is blank/black for full-3D apps.  The
    // cache + this composite step keeps the last overlay visible until a
    // fresh SubmitFrame arrives or the cache is invalidated on mode-exit.
    //
    // Note: this reintroduces an "overlay-in-Present" branch
    // that was previously deleted, but the mechanism is different: Present reads
    // a texture cached by SubmitFrame rather than querying per-engine
    // overlay state directly; the compositor remains engine-blind.
    {
        struct CompositeLayer cached;
        void *cached_tex_retained = NULL;
        if (MetalCompositorSubmitFrame_AcquireCachedOverlay(&cached,
                                                            &cached_tex_retained)) {
            MetalCompositorScaleLayerToDrawable(&cached,
                                                (NSUInteger)drawable.texture.width,
                                                (NSUInteger)drawable.texture.height);
            MetalCompositorSubmitFrame_EncodeCachedOverlay(
                (__bridge void *)enc, &cached);
            MetalCompositorSubmitFrame_ReleaseCachedOverlay(cached_tex_retained);
        }
    }

    [enc endEncoding];

    [cmdBuf presentDrawable:drawable];
    [cmdBuf commit];

    } // @autoreleasepool
}

// ---------------------------------------------------------------------------
// MetalCompositorResize — rebuild buffer/texture/pipeline for new mode
// ---------------------------------------------------------------------------
// Called from PPC emulation thread with interrupts disabled during a mode
// switch. Keeps the view, layer, device, and queue alive — only rebuilds
// depth-dependent resources. This avoids the visual flash and UIView
// lifecycle overhead of full Shutdown→Init cycles. Per-engine overlay
// textures are managed by gfxaccel_resources; each engine re-vends its own
// overlay from its DMC on_mode_enter handler.

int MetalCompositorResize(int width, int height, int depth, int row_bytes,
                          int pitch, void *buffer, uint32_t buffer_size)
{
    if (!compositor_initialized) {
        COMPOSITOR_ERR("MetalCompositorResize: FAILED — compositor not initialized "
                       "(use MetalCompositorInit for first init)");
        return -1;
    }

    // Capture old dimensions/depth for diagnostic log
    int old_width = compositor_pixel_width;
    int old_height = compositor_pixel_height;
    int old_depth = compositor_depth;

    // --- Release old depth-dependent resources ---
    compositor_buffer   = nil;
    compositor_texture  = nil;
    s_palette_buffers[0] = nil;
    s_palette_buffers[1] = nil;
    atomic_store_explicit(&s_palette_front_idx, 0, memory_order_relaxed);
    gamma_lut_buffer      = nil;
    gamma_identity_buffer = nil;  // rebuilt below (always-bound fallback)
    compositor_pipeline = nil;
    compositor_sampler  = nil;

    // --- Update depth state ---
    compositor_depth = depth;
    compositor_pixel_width = width;
    compositor_pixel_height = height;
    compositor_bits_per_pixel = bits_per_pixel_for_depth(depth);
    compositor_row_bytes = row_bytes;
    compositor_pitch = pitch;
    compositor_use_fallback_texture = false;

    if (compositor_bits_per_pixel == 0) {
        COMPOSITOR_ERR("MetalCompositorResize: FAILED — unknown depth value %d", depth);
        return -1;
    }

    // --- Update layer drawable size ---
    MetalCompositorDrawableSize target_size =
        MetalCompositorCurrentDrawableSize(width, height);
    compositor_layer.drawableSize = CGSizeMake(target_size.width, target_size.height);
    compositor_layer.contentsGravity = kCAGravityResizeAspect;  // preserve aspect ratio (letterbox)

    // --- Update CAMetalLayer scaling filter from user preference ---
    bool useNearest = PrefsFindBool("scale_nearest");
    compositor_layer.minificationFilter = useNearest ? kCAFilterNearest : kCAFilterLinear;
    compositor_layer.magnificationFilter = useNearest ? kCAFilterNearest : kCAFilterLinear;

    // Re-declare sRGB color space on resize
    {
        // CGColorSpaceCreateWithName returns a +1 retained CGColorSpaceRef;
        // CAMetalLayer.colorspace is a Core Foundation property whose setter
        // retains.  Without CGColorSpaceRelease we leak one CGColorSpaceRef
        // per Resize (Nanosaur mode-switch path hits this every scene
        // transition).
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        compositor_layer.colorspace = cs;
        if (cs) CGColorSpaceRelease(cs);
    }

    // --- Zero-copy shared buffer wrapping the_buffer ---
    // gfxaccel_resources is the sole framebuffer MTLBuffer provider; a nil
    // return is a hard Resize failure (no newBufferWithBytesNoCopy fallback).
    //
    // A NULL `buffer` argument indicates a non-QuickDraw owner
    // (DSp etc.) where the engine writes pixels via render pass directly to
    // compositor_texture; no CPU-side host buffer is needed. Skip the
    // buffer-backed texture path; the standalone-texture fallback below
    // allocates a fresh MTLTexture sized from texDesc.
    if (buffer != NULL) {
        compositor_buffer = (__bridge id<MTLBuffer>)gfxaccel_resources_get_framebuffer_buffer(
            buffer, buffer_size);
        if (!compositor_buffer) {
            COMPOSITOR_ERR("MetalCompositorResize: FAILED — gfxaccel_resources_get_framebuffer_buffer "
                           "returned NULL (buffer=%p size=%u)", buffer, buffer_size);
            return -1;
        }
    } else {
        compositor_buffer = nil;
    }

    // --- Select texture format and dimensions per depth ---
    MTLPixelFormat texFormat;
    NSUInteger texWidth;

    if (depth <= VIDEO_DEPTH_8BIT) {
        texFormat = MTLPixelFormatR8Uint;
        texWidth = (NSUInteger)row_bytes;
    } else if (depth == VIDEO_DEPTH_16BIT) {
        texFormat = MTLPixelFormatR16Uint;
        texWidth = (NSUInteger)width;
    } else {
        texFormat = MTLPixelFormatBGRA8Unorm;
        texWidth = (NSUInteger)width;
    }

    // --- Texture view over the shared buffer ---
    MTLTextureDescriptor *texDesc = [[MTLTextureDescriptor alloc] init];
    texDesc.textureType = MTLTextureType2D;
    texDesc.pixelFormat = texFormat;
    texDesc.width = texWidth;
    texDesc.height = (NSUInteger)height;
    texDesc.storageMode = MTLStorageModeShared;
    // Include RenderTarget usage so the DSp
    // engine's mismatched-format present pass (R16Uint xRGB1555 ->
    // BGRA8Unorm at 16 bpp) can use this texture as a color attachment.
    // ShaderRead is still primary (the compositor's own present pass
    // samples it). Engine-blindness invariant preserved: this is just a
    // usage-flag extension; no engine identifiers introduced.
    texDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;

    int texBytesPerRow = (depth <= VIDEO_DEPTH_8BIT) ? row_bytes : pitch;
    bool bytesPerRowAligned = (texBytesPerRow % 16 == 0);

    if (bytesPerRowAligned && compositor_buffer != nil) {
        compositor_texture = [compositor_buffer newTextureWithDescriptor:texDesc
                                                                 offset:0
                                                            bytesPerRow:(NSUInteger)texBytesPerRow];
    }

    if (!compositor_texture) {
        COMPOSITOR_LOG("MetalCompositorResize: buffer texture skipped/failed for %s "
                       "(bytesPerRow=%d aligned=%d), using standalone texture with replaceRegion",
                       texture_format_name(texFormat), texBytesPerRow, bytesPerRowAligned);
        texDesc.storageMode = MTLStorageModeShared;
        compositor_texture = [compositor_device newTextureWithDescriptor:texDesc];
        if (!compositor_texture) {
            COMPOSITOR_ERR("MetalCompositorResize: FAILED — newTextureWithDescriptor fallback "
                           "(format=%s width=%lu height=%d)",
                           texture_format_name(texFormat), (unsigned long)texWidth, height);
            return -1;
        }
        compositor_use_fallback_texture = true;
    }

    // --- Re-publish framebuffer texture to SubmitFrame module ---
    // compositor_texture was just rebuilt; keep the DSp-facing accessor in sync.
    MetalCompositorSubmitFrame_SetFramebufferTexture(
        (__bridge void *)compositor_texture);

    // --- Double-buffered palette for indexed depths ---
    if (depth <= VIDEO_DEPTH_8BIT) {
        for (int i = 0; i < 2; i++) {
            s_palette_buffers[i] = (__bridge_transfer id<MTLBuffer>)
                gfxaccel_resources_heap_alloc_buffer(kHeapCompositor, 256 * 4,
                                                     MTLResourceStorageModeShared);
            if (!s_palette_buffers[i]) {
                COMPOSITOR_ERR("MetalCompositorResize: palette_buffer[%d] heap alloc failed; falling back", i);
                // heap-exempt: palette fallback (only if heap is exhausted)
                s_palette_buffers[i] = [compositor_device newBufferWithLength:256 * 4
                                                                     options:MTLResourceStorageModeShared];
            }
            if (!s_palette_buffers[i]) {
                COMPOSITOR_ERR("MetalCompositorResize: FAILED — palette_buffer[%d] creation", i);
                return -1;
            }
            memset(s_palette_buffers[i].contents, 0, 256 * 4);
        }
        atomic_store_explicit(&s_palette_front_idx, 0, memory_order_relaxed);
    }

    // --- Gamma LUT buffers for ALL depths (16/32bpp LUT
    //     sampling). gamma_identity_buffer is the always-bound fallback.
    //     A mode switch to 32bpp mid-fade must keep a bound gamma buffer so the
    //     DSp fade stays visible. The next DMC gamma-gen bump (mid-fade push or
    //     final-frame push) re-copies the live LUT in compositor_vbl_callback. ---
    gamma_lut_buffer      = alloc_gamma_buffer("gamma_lut_buffer");
    gamma_identity_buffer = alloc_gamma_buffer("gamma_identity_buffer");
    if (!gamma_lut_buffer || !gamma_identity_buffer) {
        COMPOSITOR_ERR("MetalCompositorResize: FAILED — gamma buffer creation "
                       "(lut=%p identity=%p)", gamma_lut_buffer, gamma_identity_buffer);
        return -1;
    }

    // --- Shader library (reuse cached instance) ---
    if (!compositor_library) {
        compositor_library = [compositor_device newDefaultLibrary];
    }
    id<MTLLibrary> library = compositor_library;
    if (!library) {
        COMPOSITOR_ERR("MetalCompositorResize: FAILED — newDefaultLibrary returned nil");
        return -1;
    }

    id<MTLFunction> vertexFunc = [library newFunctionWithName:@"compositor_vertex"];
    if (!vertexFunc) {
        COMPOSITOR_ERR("MetalCompositorResize: FAILED — vertex function 'compositor_vertex' not found");
        return -1;
    }

    // --- Select fragment function by depth ---
    NSString *fragmentName;
    if (depth <= VIDEO_DEPTH_8BIT) {
        fragmentName = @"compositor_fragment_indexed";
    } else if (depth == VIDEO_DEPTH_16BIT) {
        fragmentName = @"compositor_fragment_16bpp";
    } else {
        fragmentName = @"compositor_fragment_32bpp";
    }

    id<MTLFunction> fragmentFunc = [library newFunctionWithName:fragmentName];
    if (!fragmentFunc) {
        COMPOSITOR_ERR("MetalCompositorResize: FAILED — fragment function '%s' not found",
                       [fragmentName UTF8String]);
        return -1;
    }

    // --- Render pipeline ---
    MTLRenderPipelineDescriptor *pipeDesc = [[MTLRenderPipelineDescriptor alloc] init];
    pipeDesc.vertexFunction = vertexFunc;
    pipeDesc.fragmentFunction = fragmentFunc;
    pipeDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    NSError *pipeError = nil;
    compositor_pipeline = [compositor_device newRenderPipelineStateWithDescriptor:pipeDesc
                                                                           error:&pipeError];
    if (!compositor_pipeline) {
        COMPOSITOR_ERR("MetalCompositorResize: FAILED — pipeline creation for '%s': %s",
                       [fragmentName UTF8String],
                       [[pipeError localizedDescription] UTF8String]);
        return -1;
    }

    // --- Sampler state for 32-bit mode ---
    if (depth == VIDEO_DEPTH_32BIT) {
        MTLSamplerDescriptor *sampDesc = [[MTLSamplerDescriptor alloc] init];
        sampDesc.minFilter = useNearest ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
        sampDesc.magFilter = useNearest ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
        sampDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sampDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;

        compositor_sampler = [compositor_device newSamplerStateWithDescriptor:sampDesc];
        if (!compositor_sampler) {
            COMPOSITOR_ERR("MetalCompositorResize: FAILED — sampler creation");
            return -1;
        }
    } else {
        compositor_sampler = nil;
    }

    COMPOSITOR_LOG("MetalCompositorResize: %dx%d depth=%d → framebuffer=%dx%d drawable=%dx%d depth=%d (%dbpp) "
                   "format=%s shader=%s filter=%s%s",
                   old_width, old_height, old_depth,
                   width, height,
                   target_size.width, target_size.height,
                   depth, compositor_bits_per_pixel,
                   texture_format_name(texFormat),
                   [fragmentName UTF8String],
                   useNearest ? "nearest" : "linear",
                   compositor_use_fallback_texture ? " (fallback texture)" : "");

    // Re-read frame rate setting (may have changed in preferences before restart)
    int refresh_hz = objc_getFrameRateSetting();
    if (refresh_hz <= 0) refresh_hz = 60;
    frame_interval_usec = 1000000 / (uint64_t)refresh_hz;

    // Re-initialize VBL source after layer resize. The layer object
    // itself survives Resize, but the display-link may need to re-sync with
    // the updated drawableSize and cadence.
    vbl_source_shutdown();
    int32_t vbl_err = vbl_source_init((__bridge void *)compositor_layer,
                                       compositor_vbl_callback,
                                       NULL);
    if (vbl_err != 0) {
        COMPOSITOR_ERR("MetalCompositorResize: vbl_source_init failed (%d)", vbl_err);
        // Non-fatal: continues without VBL source
    }

    return 0;
}

// ---------------------------------------------------------------------------
// MetalCompositorIsInitialized — query compositor lifecycle state
// ---------------------------------------------------------------------------

int MetalCompositorIsInitialized(void)
{
    return (int)compositor_initialized;
}

// ---------------------------------------------------------------------------
// MetalCompositorGetLayer — layer accessor
// ---------------------------------------------------------------------------

void *MetalCompositorGetLayer(void)
{
    return (__bridge void *)compositor_layer;
}

// ---------------------------------------------------------------------------
// MetalCompositorGetFramebufferTexture implementation lives in
// metal_compositor_submitframe.mm so the test target (which does not
// compile this file due to SDL2 deps) can also resolve the symbol. The
// production path below publishes compositor_texture via
// MetalCompositorSubmitFrame_SetFramebufferTexture whenever Init/Resize
// rebuilds the framebuffer texture view.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// MetalCompositorShutdown — tear down all resources
// ---------------------------------------------------------------------------

void MetalCompositorShutdown(void)
{
    // Unsubscribe from DMC FIRST so an in-flight transition broadcast cannot
    // land on a half-torn-down compositor. Return value is
    // ignored: kDMCErrSubscriberNotFound is legitimate if Init failed before
    // the subscribe call landed.
    dmc_unsubscribe("compositor");

    // Shut down VBL source before tearing down the layer it references
    vbl_source_shutdown();

    compositor_initialized = false;

    // Unbind from the SubmitFrame module. This drains the
    // inflight semaphore (3 waits) + releases the blend-mode PSOs +
    // clears test seam state. This prevents
    // __block over-release on the completion-handler capture.
    MetalCompositorSubmitFrame_UnbindPresentationContext();

    COMPOSITOR_LOG("MetalCompositorShutdown: tearing down (view=%p layer=%p depth=%d)",
                   compositor_view, compositor_layer, compositor_depth);

    if (compositor_view) {
        [compositor_view removeFromSuperview];
        compositor_view = nil;
    }

    // Clear the SubmitFrame module's framebuffer-texture publication
    // before the compositor_texture is released.
    MetalCompositorSubmitFrame_SetFramebufferTexture(NULL);

    compositor_layer    = nil;
    compositor_pipeline = nil;
    compositor_sampler  = nil;
    compositor_texture  = nil;
    compositor_buffer   = nil;
    s_palette_buffers[0] = nil;
    s_palette_buffers[1] = nil;
    atomic_store_explicit(&s_palette_front_idx, 0, memory_order_relaxed);
    gamma_lut_buffer      = nil;
    gamma_identity_buffer = nil;
    s_latched_fade_active = 0;  // clear latched fade on teardown
    compositor_queue    = nil;
    compositor_device   = nil;
    compositor_library  = nil;

    compositor_depth    = 0;
    compositor_pixel_width   = 0;
    compositor_pixel_height  = 0;
    compositor_bits_per_pixel = 0;
    compositor_row_bytes = 0;
    compositor_pitch = 0;
    compositor_use_fallback_texture = false;

    // Frame-pacing cleanup
    frame_interval_usec = 0;

    COMPOSITOR_LOG("MetalCompositorShutdown: done");
}

// ---------------------------------------------------------------------------
// TESTING_BUILD palette introspection hooks
// ---------------------------------------------------------------------------

#ifdef TESTING_BUILD
uint8_t MetalCompositorTesting_GetPaletteFrontIdx(void)
{
    return atomic_load_explicit(&s_palette_front_idx, memory_order_acquire);
}

void *MetalCompositorTesting_GetPaletteBuffer(int idx)
{
    if (idx < 0 || idx > 1) return NULL;
    return (__bridge void *)s_palette_buffers[idx];
}

int MetalCompositorTesting_InitPaletteBuffers(void *device)
{
    if (device == NULL) return -1;
    id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
    for (int i = 0; i < 2; i++) {
        // heap-exempt: test-only helper for PaletteDoubleBufferTests; bypasses the heap sub-allocator intentionally because the test device is a fresh MTLDevice with no gfxaccel_resources_heap bound
        s_palette_buffers[i] = [dev newBufferWithLength:256 * 4
                                                options:MTLResourceStorageModeShared];
        if (!s_palette_buffers[i]) return -1;
        memset(s_palette_buffers[i].contents, 0, 256 * 4);
    }
    atomic_store_explicit(&s_palette_front_idx, 0, memory_order_relaxed);
    return 0;
}

void MetalCompositorTesting_ShutdownPaletteBuffers(void)
{
    s_palette_buffers[0] = nil;
    s_palette_buffers[1] = nil;
    atomic_store_explicit(&s_palette_front_idx, 0, memory_order_relaxed);
}

// Gamma LUT buffer introspection hook.
void *MetalCompositorTesting_GetGammaLUTBuffer(void)
{
    return (__bridge void *)gamma_lut_buffer;
}
#endif /* TESTING_BUILD */



/* All TESTING_BUILD helpers (g_testing_submitframe_count + the read/reset
 * helpers + DSpTesting_CaptureCompositorOutput) moved into
 * metal_compositor_submitframe.mm because the PocketShaverTests target
 * does NOT compile metal_compositor.mm. See the explanatory block earlier
 * in this file (the "MOVED to metal_compositor_submitframe.mm" comment
 * that replaced the counter declaration). */
