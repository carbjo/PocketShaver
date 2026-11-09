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
 *  Presents the guest framebuffer through a UIView + CAMetalLayer that
 *  replaces SDL's renderer.
 *
 *    - 1/2/4/8-bit: R8Uint texture + palette lookup in the shader.
 *    - 16-bit: R16Uint texture, big-endian xRGB1555 unpacked in the shader.
 *    - 32-bit: BGRA8Unorm texture.
 *
 *  The view is created by hand rather than with SDL_Metal_CreateView, which
 *  feeds back into SDL_GetWindowSize. Drawables are never cached across
 *  frames. Integer textures use tex.read(); the layer's min/mag filter does
 *  the scaling.
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
#include "gfx_color_policy.h"
#include "gfxaccel_threading_policy.h"
#include "gfxaccel_resources.h"
#include "gfxaccel_resources_heap.h"
#include "metal_compositor_drawable_policy.h"
#include "vbl_source.h"
#include "prefs.h"
#include "MiscellaneousSettingsObjCCppHeader.h"
#include "PerformanceCounterObjCCppHeader.h"

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

// Error logging is always on.
#if ACCEL_LOGGING_ENABLED
#define COMPOSITOR_ERR(fmt, ...) do { os_log_error(compositor_log, fmt, ##__VA_ARGS__); } while (0)
#else
#define COMPOSITOR_ERR(fmt, ...) do { os_log_error(OS_LOG_DEFAULT, fmt, ##__VA_ARGS__); } while (0)
#endif

// video_sdl2.cpp
extern SDL_Window *sdl_window;

@interface CompositorMetalView : UIView
@end

@implementation CompositorMetalView
+ (Class)layerClass {
    return [CAMetalLayer class];
}
@end

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

static CompositorMetalView         *compositor_view     = nil;
static CAMetalLayer                *compositor_layer    = nil;
static id<MTLDevice>                compositor_device   = nil;
static id<MTLCommandQueue>          compositor_queue    = nil;
static id<MTLBuffer>                compositor_buffer   = nil;
static id<MTLTexture>               compositor_texture  = nil;
static id<MTLRenderPipelineState>   compositor_pipeline = nil;
static id<MTLSamplerState>          compositor_sampler  = nil;

static bool                         compositor_initialized = false;

// Present rect: compositor_view's bounds in window coordinates, the source of
// truth for the absolute-cursor map in video_sdl2.cpp. The cursor map must use
// the same rect the image is drawn into. uiWindow.bounds and SDL_GetWindowSize
// (transposed/stale off-main on Catalyst) can disagree with it. video_sdl2
// aspect-fits the guest within this rect to match kCAGravityResizeAspect.
// Written on the main thread, read on the redraw thread; x:y and w:h are each
// packed into one atomic so a pair never tears.

static _Atomic uint64_t s_present_rect_origin = 0;   // (x << 32) | y, window points
static _Atomic uint64_t s_present_rect_size   = 0;   // (w << 32) | h, window points

extern "C" void MetalCompositorRefreshPresentRect(void)
{
    // UIKit reads are main-thread only; off-thread calls keep the cached value.
    if (![NSThread isMainThread]) return;
    CompositorMetalView *view = compositor_view;
    if (!view || !view.superview) return;
    CGRect vb = view.bounds;
    if (vb.size.width <= 0.0 || vb.size.height <= 0.0) return;
    // Window coordinates fold any Catalyst safe-area inset into the origin.
    CGRect inWindow = [view convertRect:vb toView:nil];
    int x = (int)(inWindow.origin.x + 0.5);
    int y = (int)(inWindow.origin.y + 0.5);
    int w = (int)(inWindow.size.width  + 0.5);
    int h = (int)(inWindow.size.height + 0.5);
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    atomic_store_explicit(&s_present_rect_origin,
        ((uint64_t)(uint32_t)x << 32) | (uint32_t)y, memory_order_relaxed);
    atomic_store_explicit(&s_present_rect_size,
        ((uint64_t)(uint32_t)w << 32) | (uint32_t)h, memory_order_relaxed);
}

extern "C" void MetalCompositorGetPresentRect(int *out_x, int *out_y,
                                              int *out_w, int *out_h)
{
    uint64_t o = atomic_load_explicit(&s_present_rect_origin, memory_order_relaxed);
    uint64_t s = atomic_load_explicit(&s_present_rect_size,   memory_order_relaxed);
    if (out_x) *out_x = (int)(uint32_t)(o >> 32);
    if (out_y) *out_y = (int)(uint32_t)(o & 0xffffffffu);
    if (out_w) *out_w = (int)(uint32_t)(s >> 32);
    if (out_h) *out_h = (int)(uint32_t)(s & 0xffffffffu);
}

// VBL-latched palette: two 256x4-byte buffers. Writers update the back
// buffer; the VBL callback promotes it to front only when dirty; the encoder
// binds the front. Writers and VBL both run on the main/emul thread today;
// the atomics guard a future thread split.
static id<MTLBuffer>                s_palette_buffers[2] = { nil, nil };
static _Atomic uint8_t              s_palette_front_idx  = 0;
static _Atomic uint8_t              s_palette_dirty      = 0;
static _Atomic uint8_t              s_palette_back_in_sync = 1;

static void reset_palette_latch_state(void)
{
    atomic_store_explicit(&s_palette_front_idx, 0, memory_order_relaxed);
    atomic_store_explicit(&s_palette_dirty, 0, memory_order_relaxed);
    atomic_store_explicit(&s_palette_back_in_sync, 1, memory_order_relaxed);
}

// Display gamma LUT, 768 bytes planar (256 R, 256 G, 256 B). Recomposed from
// the DMC snapshot whenever its gamma generation changes.
static id<MTLBuffer>                gamma_lut_buffer    = nil;

// Identity LUT for paths that bypass display gamma (e.g. DSp staging into
// the 32-bit framebuffer). Read-only after init.
static id<MTLBuffer>                gamma_identity_buffer = nil;

// fade_active latched from the same snapshot that built gamma_lut_buffer,
// so diagnostics and DSp staging see the fade state the LUT reflects.
static uint32_t                     s_latched_fade_active = 0;
// Last gamma generation composed into gamma_lut_buffer; UINT32_MAX = never.
// Init/Resize reseed the buffer with the display default, so they must reset
// this, or a ramp whose gamma_gen survived a mode switch is never recomposed.
static uint32_t                     s_last_gamma_gen = UINT32_MAX;

static int                          compositor_depth    = 0;
static int                          compositor_pixel_width   = 0;
static int                          compositor_pixel_height  = 0;
static int                          compositor_bits_per_pixel = 0;
static bool                         compositor_use_fallback_texture = false;
static int                          compositor_row_bytes = 0;
static int                          compositor_pitch     = 0;

// Kept across Init/Resize.
static id<MTLLibrary>               compositor_library  = nil;

static NSUInteger                   s_last_overlay_scale_target_w = 0;
static NSUInteger                   s_last_overlay_scale_target_h = 0;
static int                          s_last_overlay_scale_fb_w = 0;
static int                          s_last_overlay_scale_fb_h = 0;

// Refreshed from DMC snapshots.
static uint64_t                     frame_interval_usec = 0;   // microseconds per VBL frame

// metal_compositor_submitframe.mm. Init binds device/queue/layer; Shutdown
// unbinds them.

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

// DMC subscriber callbacks. The compositor subscribes first, so reverse-order
// on_mode_enter dispatch reaches it last, after every engine has bound its
// new overlay.
// TODO: move teardown from MetalCompositorResize into OnModeExit and the
// rebuild into OnModeEnter.
static int32_t MetalCompositor_OnModeExit(const struct DMCModeSnapshot *outgoing, void *ctx)
{
    (void)ctx;
    if (outgoing) {
        COMPOSITOR_LOG("DMC on_mode_exit: outgoing gen=%u %ux%u depth=%u",
                       outgoing->generation, outgoing->width, outgoing->height, outgoing->depth);
    }
    // The cached overlay texture belongs to the outgoing mode and may be freed
    // or the wrong size. Engines repopulate it on their next SubmitFrame.
    MetalCompositorSubmitFrame_ClearCachedOverlay();
    return 0;
}

static int32_t MetalCompositor_OnModeEnter(const struct DMCModeSnapshot *incoming, void *ctx)
{
    (void)ctx;
    if (incoming && incoming->vbl_usec > 0) {
        // vbl_usec 0 = not filled in yet; keep the Init/Resize value.
        frame_interval_usec = incoming->vbl_usec;
    }
    if (incoming) {
        COMPOSITOR_LOG("DMC on_mode_enter: incoming gen=%u %ux%u depth=%u vbl_usec=%llu",
                       incoming->generation, incoming->width, incoming->height, incoming->depth,
                       (unsigned long long)incoming->vbl_usec);
    } else {
        return 0;
    }

    /* When DSp owns the framebuffer, resize the compositor texture to the Mac
     * mode; otherwise DSp writes only its top-left region. The texture is always
     * BGRA8Unorm because DSp decodes its back buffer to BGRA in its own pass.
     *
     * RAVE/GL are overlays and rely on the QuickDraw framebuffer underlay for 2D
     * UI, so they must not trigger a rebuild with a NULL host buffer here.
     * QuickDraw mode switches rebuild only when the snapshot carries
     * screen_base_host, as on DSp release restoring the desktop surface.
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
                /* Non-fatal: output lands in a corner of the old texture. */
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

static void fill_identity_gamma_lut(uint8_t *lut)
{
    GfxColorFillIdentityGammaLUT(lut);
}

// 768-byte gamma LUT seeded with the display default or identity. Gamma
// buffers outlive ownership handoffs, so they stay off resettable heaps.

static id<MTLBuffer> alloc_gamma_buffer(id<MTLDevice> device,
                                        const char *label,
                                        bool display_default)
{
    id<MTLBuffer> buf = [device newBufferWithLength:768
                                            options:MTLResourceStorageModeShared];
    if (!buf) {
        COMPOSITOR_ERR("alloc_gamma_buffer(%s): device alloc failed", label);
    }
    if (buf) {
        if (display_default) {
            GfxColorFillDefaultDisplayGammaLUT((uint8_t *)buf.contents,
                                               !objc_getIsLinearGammaEnabled());
        } else {
            fill_identity_gamma_lut((uint8_t *)buf.contents);
        }
    }
    return buf;
}

static const char *texture_format_name(MTLPixelFormat fmt)
{
    switch (fmt) {
        case MTLPixelFormatR8Uint:      return "R8Uint";
        case MTLPixelFormatR16Uint:     return "R16Uint";
        case MTLPixelFormatBGRA8Unorm:  return "BGRA8Unorm";
        default:                        return "Unknown";
    }
}

struct CompositorDepthResources {
    id<MTLBuffer>              buffer;
    id<MTLTexture>             texture;
    id<MTLBuffer>              palette_buffers[2];
    id<MTLBuffer>              gamma_lut;
    id<MTLBuffer>              gamma_identity;
    id<MTLLibrary>             library;
    id<MTLRenderPipelineState> pipeline;
    id<MTLSamplerState>        sampler;
    NSString                  *fragment_name;
    MTLPixelFormat             tex_format;
    NSUInteger                 tex_width;
    bool                       use_fallback_texture;
};

static int MetalCompositorBuildDepthResources(const char *op,
                                              id<MTLDevice> device,
                                              int width, int height,
                                              int depth, int row_bytes,
                                              int pitch, void *buffer,
                                              uint32_t buffer_size,
                                              bool use_nearest,
                                              bool allow_null_buffer,
                                              CompositorDepthResources *out)
{
    if (!device || !out) {
        COMPOSITOR_ERR("%s: FAILED — missing Metal device or output record", op);
        return -1;
    }

    int bits_per_pixel = bits_per_pixel_for_depth(depth);
    if (bits_per_pixel == 0) {
        COMPOSITOR_ERR("%s: FAILED — unknown depth value %d", op, depth);
        return -1;
    }

    if (buffer != NULL) {
        out->buffer = (__bridge id<MTLBuffer>)gfxaccel_resources_get_framebuffer_buffer(
            buffer, buffer_size);
        if (!out->buffer) {
            COMPOSITOR_ERR("%s: FAILED — gfxaccel_resources_get_framebuffer_buffer "
                           "returned NULL (buffer=%p size=%u)",
                           op, buffer, buffer_size);
            return -1;
        }
    } else if (!allow_null_buffer) {
        COMPOSITOR_ERR("%s: FAILED — NULL framebuffer buffer for initial compositor setup",
                       op);
        return -1;
    }

    if (depth <= VIDEO_DEPTH_8BIT) {
        out->tex_format = MTLPixelFormatR8Uint;
        out->tex_width = (NSUInteger)row_bytes;
    } else if (depth == VIDEO_DEPTH_16BIT) {
        out->tex_format = MTLPixelFormatR16Uint;
        out->tex_width = (NSUInteger)width;
    } else {
        out->tex_format = MTLPixelFormatBGRA8Unorm;
        out->tex_width = (NSUInteger)width;
    }

    MTLTextureDescriptor *texDesc = [[MTLTextureDescriptor alloc] init];
    texDesc.textureType = MTLTextureType2D;
    texDesc.pixelFormat = out->tex_format;
    texDesc.width = out->tex_width;
    texDesc.height = (NSUInteger)height;
    texDesc.storageMode = MTLStorageModeShared;
    texDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;

    int texBytesPerRow = (depth <= VIDEO_DEPTH_8BIT) ? row_bytes : pitch;
    bool bytesPerRowAligned = (texBytesPerRow % 16 == 0);

    if (bytesPerRowAligned && out->buffer != nil) {
        out->texture = [out->buffer newTextureWithDescriptor:texDesc
                                                      offset:0
                                                 bytesPerRow:(NSUInteger)texBytesPerRow];
    }

    if (!out->texture) {
        COMPOSITOR_LOG("%s: buffer texture skipped/failed for %s "
                       "(bytesPerRow=%d aligned=%d), using standalone texture with replaceRegion",
                       op, texture_format_name(out->tex_format),
                       texBytesPerRow, bytesPerRowAligned);
        texDesc.storageMode = MTLStorageModeShared;
        out->texture = [device newTextureWithDescriptor:texDesc];
        if (!out->texture) {
            COMPOSITOR_ERR("%s: FAILED — newTextureWithDescriptor fallback "
                           "(format=%s width=%lu height=%d)",
                           op, texture_format_name(out->tex_format),
                           (unsigned long)out->tex_width, height);
            return -1;
        }
        out->use_fallback_texture = true;
    }

    if (depth <= VIDEO_DEPTH_8BIT) {
        for (int i = 0; i < 2; i++) {
            out->palette_buffers[i] = [device newBufferWithLength:256 * 4
                                                          options:MTLResourceStorageModeShared];
            if (!out->palette_buffers[i]) {
                COMPOSITOR_ERR("%s: FAILED — palette_buffer[%d] creation", op, i);
                return -1;
            }
            memset(out->palette_buffers[i].contents, 0, 256 * 4);
        }
    }

    out->gamma_lut      = alloc_gamma_buffer(device, "gamma_lut_buffer", true);
    out->gamma_identity = alloc_gamma_buffer(device, "gamma_identity_buffer", false);
    if (!out->gamma_lut || !out->gamma_identity) {
        COMPOSITOR_ERR("%s: FAILED — gamma buffer creation (lut=%p identity=%p)",
                       op, out->gamma_lut, out->gamma_identity);
        return -1;
    }

    id<MTLLibrary> library = compositor_library;
    if (!library) {
        library = [device newDefaultLibrary];
    }
    if (!library) {
        COMPOSITOR_ERR("%s: FAILED — newDefaultLibrary returned nil", op);
        return -1;
    }
    out->library = library;

    id<MTLFunction> vertexFunc = [library newFunctionWithName:@"compositor_vertex"];
    if (!vertexFunc) {
        COMPOSITOR_ERR("%s: FAILED — vertex function 'compositor_vertex' not found", op);
        return -1;
    }

    if (depth <= VIDEO_DEPTH_8BIT) {
        out->fragment_name = @"compositor_fragment_indexed";
    } else if (depth == VIDEO_DEPTH_16BIT) {
        out->fragment_name = @"compositor_fragment_16bpp";
    } else {
        out->fragment_name = @"compositor_fragment_32bpp";
    }

    id<MTLFunction> fragmentFunc = [library newFunctionWithName:out->fragment_name];
    if (!fragmentFunc) {
        COMPOSITOR_ERR("%s: FAILED — fragment function '%s' not found",
                       op, [out->fragment_name UTF8String]);
        return -1;
    }

    MTLRenderPipelineDescriptor *pipeDesc = [[MTLRenderPipelineDescriptor alloc] init];
    pipeDesc.vertexFunction = vertexFunc;
    pipeDesc.fragmentFunction = fragmentFunc;
    pipeDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    NSError *pipeError = nil;
    out->pipeline = [device newRenderPipelineStateWithDescriptor:pipeDesc
                                                           error:&pipeError];
    if (!out->pipeline) {
        COMPOSITOR_ERR("%s: FAILED — pipeline creation for '%s': %s",
                       op, [out->fragment_name UTF8String],
                       [[pipeError localizedDescription] UTF8String]);
        return -1;
    }

    if (depth == VIDEO_DEPTH_32BIT) {
        MTLSamplerDescriptor *sampDesc = [[MTLSamplerDescriptor alloc] init];
        sampDesc.minFilter = use_nearest ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
        sampDesc.magFilter = use_nearest ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
        sampDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sampDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;

        out->sampler = [device newSamplerStateWithDescriptor:sampDesc];
        if (!out->sampler) {
            COMPOSITOR_ERR("%s: FAILED — sampler creation", op);
            return -1;
        }
    }

    return 0;
}

// Display-link tick.
static void compositor_vbl_callback(void *ctx, void *drawable, double target_ts)
{
	(void)ctx;
	(void)drawable;

	MetalCompositorPaletteLatch();

	MetalCompositorSubmitFrame_SetTargetTimestamp(target_ts);

	// Recompose the gamma LUT when gamma_gen changes and latch fade_active from
	// the same snapshot. The producer bumps gamma_gen on every fade_active
	// change, so the LUT and the flag always come from one snapshot.
	const DMCModeSnapshot *snap = dmc_current_snapshot();
	if (snap != NULL && gamma_lut_buffer != nil) {
		if (snap->gamma_gen != s_last_gamma_gen) {
			id<MTLBuffer> revision = [compositor_device newBufferWithLength:768
			                                        options:MTLResourceStorageModeShared];
			if (!revision) return; // preserve the coherent (LUT, fade) pair; retry next VBL
			GfxColorBuildDisplayGammaLUT(snap->gamma_lut,
			                             snap->fade_active != 0,
			                             !objc_getIsLinearGammaEnabled(),
			                             (uint8_t *)revision.contents);
			gamma_lut_buffer = revision;
			s_latched_fade_active = snap->fade_active ? 1u : 0u;
			s_last_gamma_gen = snap->gamma_gen;
			COMPOSITOR_LOG("VBL callback: updated gamma LUT (gen=%u fade_active=%u)",
			               snap->gamma_gen, s_latched_fade_active);
		}
	}
}

// Catalyst pins the compositor view with Auto Layout (iOS uses the autoresizing
// mask). Without a pin the view has no size. Re-homing the view into a new SDL
// rootViewController.view on a mode switch drops the old pin and collapses it
// to 0x0, so re-pin on every re-home. The stored constraints are deactivated
// first so re-pinning cannot stack duplicates.
#if TARGET_OS_MACCATALYST
static NSArray<NSLayoutConstraint *> *s_compositor_pin_constraints = nil;

// PreferencesViewControllerObjC.mm
extern "C" bool catalyst_is_window_fullscreen(void);

static void MetalCompositorPinViewToWindow(void)
{
    if (!compositor_view || !compositor_view.superview) return;
    if (s_compositor_pin_constraints) {
        [NSLayoutConstraint deactivateConstraints:s_compositor_pin_constraints];
        s_compositor_pin_constraints = nil;
    }
    compositor_view.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *superview = compositor_view.superview;
    // Full screen pins to the window edges. Windowed pins the top to the safe
    // area, whose top inset is the title bar; the other edges have no inset.
    BOOL fullscreen = catalyst_is_window_fullscreen();
    NSLayoutYAxisAnchor *topAnchor = fullscreen ? superview.topAnchor
                                                 : superview.safeAreaLayoutGuide.topAnchor;
    NSArray<NSLayoutConstraint *> *pins = @[
        [compositor_view.topAnchor      constraintEqualToAnchor:topAnchor],
        [compositor_view.leadingAnchor  constraintEqualToAnchor:superview.leadingAnchor],
        [compositor_view.trailingAnchor constraintEqualToAnchor:superview.trailingAnchor],
        [compositor_view.bottomAnchor   constraintEqualToAnchor:superview.bottomAnchor],
    ];
    [NSLayoutConstraint activateConstraints:pins];
    s_compositor_pin_constraints = pins;
}

// Letterbox bars: black in full screen, light/dark-adaptive grey when windowed.
static void MetalCompositorApplyLetterboxColor(void)
{
    if (!compositor_view) return;
    if (catalyst_is_window_fullscreen()) {
        compositor_view.backgroundColor = [UIColor blackColor];
    } else {
        compositor_view.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            return traits.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:0.16 alpha:1.0]
                : [UIColor colorWithWhite:0.93 alpha:1.0];
        }];
    }
}

// Title-bar height above the windowed view, in points (0 before layout).
// Window auto-resize adds it back.
extern "C" double MetalCompositorWindowedContentInsetTop(void)
{
    if (!compositor_view || !compositor_view.superview) return 0.0;
    return (double)compositor_view.superview.safeAreaInsets.top;
}

// Re-pin and recolor after a windowed/full-screen change. Runs on main.
extern "C" void MetalCompositorReapplyWindowPinning(void)
{
    if ([NSThread isMainThread]) {
        MetalCompositorPinViewToWindow();
        MetalCompositorApplyLetterboxColor();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            MetalCompositorPinViewToWindow();
            MetalCompositorApplyLetterboxColor();
        });
    }
}
#endif

int MetalCompositorInit(int width, int height, int depth, int row_bytes,
                        int pitch, void *buffer, uint32_t buffer_size)
{
    if (compositor_initialized) {
        COMPOSITOR_LOG("MetalCompositorInit: already initialized; resizing existing compositor");
        return MetalCompositorResize(width, height, depth, row_bytes,
                                     pitch, buffer, buffer_size);
    }

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

    UIWindow *uiWindow = GetSDLUIWindow();
    if (!uiWindow) {
        COMPOSITOR_ERR("MetalCompositorInit: FAILED — cannot get UIWindow");
        return -1;
    }

    compositor_view = [[CompositorMetalView alloc] initWithFrame:uiWindow.bounds];
    compositor_view.opaque = YES;
#if TARGET_OS_MACCATALYST
    MetalCompositorApplyLetterboxColor();
#else
    compositor_view.backgroundColor = [UIColor blackColor];
#endif
    compositor_view.userInteractionEnabled = NO;  // let touches pass to SDL
    // On Mac the window resizes to the true screen size after this init frame;
    // track it so the layer doesn't composite into the stale launch rect.
    compositor_view.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    compositor_layer = (CAMetalLayer *)compositor_view.layer;
#if TARGET_OS_MACCATALYST
    // Catalyst views come up at scale 1.0 even on a 2x screen, and the window
    // server's linear upscale blurs. Use the live backing scale so the layer's
    // own filter does the HiDPI upscale.
    {
        CGFloat backingScale = uiWindow.screen.scale;
        if (backingScale > 0.0) {
            compositor_view.contentScaleFactor = backingScale;
            compositor_layer.contentsScale = backingScale;
        }
    }
#endif
    compositor_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    compositor_layer.device = compositor_device;
    compositor_layer.maximumDrawableCount = 3;         // triple buffering
    compositor_layer.framebufferOnly = YES;
    MetalCompositorDrawableSize target_size =
        MetalCompositorCurrentDrawableSize(width, height);
    compositor_layer.drawableSize = CGSizeMake(target_size.width, target_size.height);
    // Always aspect-fit (letterbox), never crop.
    compositor_layer.contentsGravity = kCAGravityResizeAspect;

    bool useNearest = PrefsFindBool("scale_nearest");
    compositor_layer.minificationFilter = useNearest ? kCAFilterNearest : kCAFilterLinear;
    compositor_layer.magnificationFilter = useNearest ? kCAFilterNearest : kCAFilterLinear;

    {
        // The setter retains; release our +1 or it leaks per Resize.
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        compositor_layer.colorspace = cs;
        if (cs) CGColorSpaceRelease(cs);
    }

    COMPOSITOR_LOG("View created: layer=%p view=%p framebuffer=%dx%d drawableSize=%dx%d windowBounds=%.0fx%.0f",
                   compositor_layer, compositor_view,
                   width, height,
                   target_size.width, target_size.height,
                   uiWindow.bounds.size.width, uiWindow.bounds.size.height);

    // gfxaccel_resources owns the framebuffer MTLBuffer; nil is a hard failure.
    compositor_buffer = (__bridge id<MTLBuffer>)gfxaccel_resources_get_framebuffer_buffer(
        buffer, buffer_size);
    if (!compositor_buffer) {
        COMPOSITOR_ERR("MetalCompositorInit: FAILED — gfxaccel_resources_get_framebuffer_buffer "
                       "returned NULL (buffer=%p size=%u)",
                       buffer, buffer_size);
        return -1;
    }

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

    MTLTextureDescriptor *texDesc = [[MTLTextureDescriptor alloc] init];
    texDesc.textureType = MTLTextureType2D;
    texDesc.pixelFormat = texFormat;
    texDesc.width = texWidth;
    texDesc.height = (NSUInteger)height;
    texDesc.storageMode = MTLStorageModeShared;
    // RenderTarget: DSp's 16bpp present pass renders into this texture.
    texDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;

    // Buffer-backed textures need 16-byte-aligned bytesPerRow; Metal asserts
    // rather than returning nil, so check first.
    int texBytesPerRow = (depth <= VIDEO_DEPTH_8BIT) ? row_bytes : pitch;
    bool bytesPerRowAligned = (texBytesPerRow % 16 == 0);

    if (bytesPerRowAligned && compositor_buffer != nil) {
        compositor_texture = [compositor_buffer newTextureWithDescriptor:texDesc
                                                                 offset:0
                                                            bytesPerRow:(NSUInteger)texBytesPerRow];
    }

    if (!compositor_texture) {
        // Standalone texture updated with replaceRegion (e.g. 1366*4 = 5464).
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

    // DSp blits its back buffer into this via MetalCompositorGetFramebufferTexture().
    MetalCompositorSubmitFrame_SetFramebufferTexture(
        (__bridge void *)compositor_texture);

    if (depth <= VIDEO_DEPTH_8BIT) {
        for (int i = 0; i < 2; i++) {
            s_palette_buffers[i] = [compositor_device newBufferWithLength:256 * 4
                                                                   options:MTLResourceStorageModeShared];
            if (!s_palette_buffers[i]) {
                COMPOSITOR_ERR("MetalCompositorInit: FAILED — palette_buffer[%d] creation", i);
                return -1;
            }
            memset(s_palette_buffers[i].contents, 0, 256 * 4);
        }
        reset_palette_latch_state();
        COMPOSITOR_LOG("MetalCompositorInit: s_palette_buffers[2] created (256x4 bytes each)");
    }

    gamma_lut_buffer      = alloc_gamma_buffer(compositor_device, "gamma_lut_buffer", true);
    gamma_identity_buffer = alloc_gamma_buffer(compositor_device, "gamma_identity_buffer", false);
    if (!gamma_lut_buffer || !gamma_identity_buffer) {
        // Shaders would read an unbound argument.
        COMPOSITOR_ERR("MetalCompositorInit: FAILED — gamma buffer creation "
                       "(lut=%p identity=%p)", gamma_lut_buffer, gamma_identity_buffer);
        return -1;
    }
    s_latched_fade_active = 0;
    s_last_gamma_gen = UINT32_MAX;  // recompose on first VBL
    COMPOSITOR_LOG("MetalCompositorInit: gamma_lut_buffer + gamma_identity_buffer "
                   "created (768 bytes each)");

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

    COMPOSITOR_LOG("MetalCompositorInit: resources ready — depth=%d (%dbpp) format=%s "
                   "pixel_width=%d tex_width=%lu shader=%s filter=%s%s",
                   depth, compositor_bits_per_pixel,
                   texture_format_name(texFormat),
                   width, (unsigned long)texWidth,
                   [fragmentName UTF8String],
                   useNearest ? "nearest" : "linear",
                   compositor_use_fallback_texture ? " (fallback texture)" : "");

    // Prefer the snapshot's VBL cadence; the subscribe below may refresh it.
    const DMCModeSnapshot *snap = dmc_current_snapshot();
    if (snap != NULL && snap->vbl_usec > 0) {
        frame_interval_usec = snap->vbl_usec;
    } else {
        int refresh_hz = objc_getFrameRateSetting();
        if (refresh_hz <= 0) refresh_hz = 60;
        frame_interval_usec = 1000000 / (uint64_t)refresh_hz;
    }

    // Creates the inflight semaphore (depth 3, matching maximumDrawableCount)
    // and the blend PSO cache.
    int sf_err = MetalCompositorSubmitFrame_BindPresentationContext(
        (__bridge void *)compositor_device,
        (__bridge void *)compositor_queue,
        (__bridge void *)compositor_layer);
    if (sf_err != 0) {
        COMPOSITOR_ERR("MetalCompositorInit: FAILED — SubmitFrame bind err=%d", sf_err);
        return -1;
    }

    compositor_initialized = true;
    // Insert at index 0 of the SDL container view so the gamepad/input overlay
    // (a later sibling) stays on top, and the compositor inherits the container's
    // keyboard/drag offset transform. MetalCompositorResize re-homes it the same way.
    {
        UIView *sdlContainer = uiWindow.rootViewController.view;
        if (sdlContainer) {
            [sdlContainer insertSubview:compositor_view atIndex:0];
        } else {
            // No rootViewController yet; still insert at the bottom.
            [uiWindow insertSubview:compositor_view atIndex:0];
        }
#if TARGET_OS_MACCATALYST
        // Must run after insertion: the constraints need a shared hierarchy.
        MetalCompositorPinViewToWindow();
#endif
    }

    // Subscribe first so reverse-order enter reaches the compositor last.
    // Re-subscribing after Shutdown/Init returns AlreadyRegistered, which is fine.
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

    COMPOSITOR_LOG("MetalCompositorInit: success");

    int32_t vbl_err = vbl_source_init((__bridge void *)compositor_layer,
                                       compositor_vbl_callback,
                                       NULL);
    if (vbl_err != 0) {
        COMPOSITOR_ERR("MetalCompositorInit: vbl_source_init failed (%d)", vbl_err);
        // Non-fatal: presents immediately without a VBL source.
    }

    return 0;
}

void MetalCompositorUpdatePalette(const uint8_t *pal, int num_colors)
{
    if (!s_palette_buffers[0] || !s_palette_buffers[1]) {
        COMPOSITOR_ERR("MetalCompositorUpdatePalette: no palette buffers "
                       "(depth=%d is not indexed)", compositor_depth);
        return;
    }

    if (num_colors > 256) num_colors = 256;
    if (num_colors <= 0 || !pal) return;

    // Queued frames may still read the latched palette, so publish a new
    // immutable revision that carries earlier partial updates forward.
    uint8_t back = 1 - atomic_load_explicit(&s_palette_front_idx, memory_order_relaxed);
    uint8_t source = atomic_load_explicit(&s_palette_back_in_sync, memory_order_acquire)
        ? back : 1 - back;
    id<MTLBuffer> revision = [compositor_device newBufferWithLength:256 * 4
                                            options:MTLResourceStorageModeShared];
    if (!revision) return;
    memcpy(revision.contents, s_palette_buffers[source].contents, 256 * 4);
    uint8_t *dst = (uint8_t *)revision.contents;
    for (int i = 0; i < num_colors; i++) {
        dst[i * 4 + 0] = pal[i * 3 + 0];  // R
        dst[i * 4 + 1] = pal[i * 3 + 1];  // G
        dst[i * 4 + 2] = pal[i * 3 + 2];  // B
        dst[i * 4 + 3] = 255;              // A
    }
    s_palette_buffers[back] = revision;
    atomic_store_explicit(&s_palette_back_in_sync, 1, memory_order_release);
    atomic_store_explicit(&s_palette_dirty, 1, memory_order_release);

    COMPOSITOR_LOG("MetalCompositorUpdatePalette: wrote %d colors to back buffer", num_colors);
}

// Called from the VBL callback before the frame is encoded. Swaps only when
// dirty, so clean VBLs don't alternate between fresh and stale palettes.

void MetalCompositorPaletteLatch(void)
{
    if (!atomic_load_explicit(&s_palette_dirty, memory_order_acquire)) return;
    uint8_t old = atomic_load_explicit(&s_palette_front_idx, memory_order_relaxed);
    atomic_store_explicit(&s_palette_front_idx, 1 - old, memory_order_release);
    atomic_store_explicit(&s_palette_dirty, 0, memory_order_release);
    atomic_store_explicit(&s_palette_back_in_sync, 0, memory_order_release);
}

// Gamma change outside the VBL snapshot latch; composed with the non-fade
// display policy.

void MetalCompositorUpdateGammaLUT(const uint8_t *lut)
{
    if (!gamma_lut_buffer || !lut) return;
    id<MTLBuffer> revision = [compositor_device newBufferWithLength:768
                                            options:MTLResourceStorageModeShared];
    if (!revision) return;
    GfxColorBuildDisplayGammaLUT(lut, false, !objc_getIsLinearGammaEnabled(),
                                 (uint8_t *)revision.contents);
    gamma_lut_buffer = revision;
    COMPOSITOR_LOG("MetalCompositorUpdateGammaLUT: updated 768 bytes");
}

// For DSp's 16bpp unpack pass (dsp_metal_renderer.mm), which must use the same LUT.
void *MetalCompositorGetGammaLUTBuffer(void)
{
    return (__bridge void *)gamma_lut_buffer;
}

// Bound by the DSp unpack pass when the gamma LUT is nil (mid-init) so it
// never reads an unbound buffer. NULL only before init; the pass then aborts.
void *MetalCompositorGetGammaIdentityBuffer(void)
{
    return (__bridge void *)gamma_identity_buffer;
}

// 3D engines vend their own overlays from gfxaccel_resources and submit them
// through MetalCompositorSubmitFrame; the compositor never knows which engine
// produced a CompositeLayer.

// Present the 2D framebuffer plus the cached overlay.

void MetalCompositorPresent(void)
{
    if (!compositor_layer || !compositor_pipeline) return;

    // Drain pending memory-warning eviction here too: pure 2D sessions never
    // call SubmitFrame, but Present runs every VBL.
    (void)gfxaccel_heap_wait_for_eviction(0);

    @autoreleasepool {

    // Skip the fallback-texture upload when another owner (e.g. DSp) renders
    // into compositor_texture: replaceRegion would clobber its output, and Metal
    // validation rejects replaceRegion on a texture an in-flight command buffer
    // still holds as a render target. RAVE/GL are overlays over the QuickDraw
    // framebuffer, so keep uploading for them.
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
                              bytesPerRow:(NSUInteger)(compositor_depth <= VIDEO_DEPTH_8BIT
                                                       ? compositor_row_bytes
                                                       : compositor_pitch)];
    }

    id<CAMetalDrawable> drawable = [compositor_layer nextDrawable];
    if (!drawable) {
        return;
    }

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

    // Shaders always read a LUT; identity covers pre-init / alloc failure.
    id<MTLBuffer> gamma_to_bind = gamma_lut_buffer ? gamma_lut_buffer
                                                   : gamma_identity_buffer;

    if (compositor_depth <= VIDEO_DEPTH_8BIT) {
        uint8_t front = atomic_load_explicit(&s_palette_front_idx, memory_order_acquire);
        [enc setFragmentBuffer:s_palette_buffers[front] offset:0 atIndex:0];
        uint32_t bpp = (uint32_t)compositor_bits_per_pixel;
        [enc setFragmentBytes:&bpp length:sizeof(bpp) atIndex:1];

        [enc setFragmentBuffer:gamma_to_bind offset:0 atIndex:2];

        uint32_t pw  = (uint32_t)compositor_pixel_width;
        [enc setFragmentBytes:&pw  length:sizeof(pw)  atIndex:3];

    } else if (compositor_depth == VIDEO_DEPTH_16BIT) {
        [enc setFragmentBuffer:gamma_to_bind offset:0 atIndex:0];
    } else if (compositor_depth == VIDEO_DEPTH_32BIT) {
        // Sampler index 0 is a separate namespace from buffer index 0.
        [enc setFragmentSamplerState:compositor_sampler atIndex:0];
        [enc setFragmentBuffer:gamma_to_bind offset:0 atIndex:0];
    }

    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];

    // Composite the overlay SubmitFrame last cached. Keeping it while an engine
    // pauses (e.g. between QADrawContextDelete and QADrawContextNew) avoids a
    // black flash in full-3D apps, whose 2D framebuffer is black.
    {
        struct CompositeLayer cached;
        void *cached_tex_retained = NULL;
        if (MetalCompositorSubmitFrame_AcquireCachedOverlay(&cached,
                                                            &cached_tex_retained)) {
            MetalCompositorScaleLayerToDrawable(&cached,
                                                (NSUInteger)drawable.texture.width,
                                                (NSUInteger)drawable.texture.height);
            MetalCompositorSubmitFrame_EncodeCachedOverlay(
                (__bridge void *)enc, &cached, (__bridge void *)gamma_to_bind);
            MetalCompositorSubmitFrame_ReleaseCachedOverlay(cached_tex_retained);
        }
    }

    [enc endEncoding];

    [cmdBuf presentDrawable:drawable];
    [cmdBuf commit];

    // Do not add per-present work here (e.g. FPS counting). This runs on the emul
    // thread inside the VBL handler right before DrainPendingResourceLocks
    // (emul_op.cpp). Added latency re-phases the Sound Manager 'nift' dispose/reuse
    // race and can push Diablo II into a CFM-REPAIR storm. Count presents in the
    // display-link callback instead.

    } // @autoreleasepool
}

// Mode switch, on the emul thread with interrupts disabled. Rebuilds only the
// depth-dependent resources; view, layer, device and queue survive, which
// avoids the flash of a full Shutdown/Init. Engines re-vend their overlays
// from on_mode_enter.

int MetalCompositorResize(int width, int height, int depth, int row_bytes,
                          int pitch, void *buffer, uint32_t buffer_size)
{
    if (!compositor_initialized) {
        COMPOSITOR_ERR("MetalCompositorResize: FAILED — compositor not initialized "
                       "(use MetalCompositorInit for first init)");
        return -1;
    }
    if (!compositor_device || !compositor_layer) {
        COMPOSITOR_ERR("MetalCompositorResize: FAILED — initialized flag set without "
                       "device/layer (device=%p layer=%p)",
                       compositor_device, compositor_layer);
        return -1;
    }

    // Re-home the view if SDL swapped its rootViewController.view; an orphaned
    // view shows black. No-op when already parented.
    if (compositor_view) {
        UIWindow *resizeWindow = GetSDLUIWindow();
        UIView *sdlContainer = resizeWindow.rootViewController.view;
        if (sdlContainer && compositor_view.superview != sdlContainer) {
            [sdlContainer insertSubview:compositor_view atIndex:0];
        }
#if TARGET_OS_MACCATALYST
        // Re-homing drops the pin; without it the view collapses to 0x0.
        MetalCompositorPinViewToWindow();
#endif
    }

    int old_width = compositor_pixel_width;
    int old_height = compositor_pixel_height;
    int old_depth = compositor_depth;
    (void)old_width;
    (void)old_height;
    (void)old_depth;

    int new_bits_per_pixel = bits_per_pixel_for_depth(depth);
    if (new_bits_per_pixel == 0) {
        COMPOSITOR_ERR("MetalCompositorResize: FAILED — unknown depth value %d", depth);
        return -1;
    }

    MetalCompositorDrawableSize target_size =
        MetalCompositorCurrentDrawableSize(width, height);
    bool useNearest = PrefsFindBool("scale_nearest");

    CompositorDepthResources new_resources = {};
    if (MetalCompositorBuildDepthResources("MetalCompositorResize",
                                           compositor_device,
                                           width, height,
                                           depth, row_bytes,
                                           pitch, buffer,
                                           buffer_size,
                                           useNearest,
                                           true,
                                           &new_resources) != 0) {
        return -1;
    }

    // Swap in only after the whole replacement set built successfully.
    compositor_depth = depth;
    compositor_pixel_width = width;
    compositor_pixel_height = height;
    compositor_bits_per_pixel = new_bits_per_pixel;
    compositor_row_bytes = row_bytes;
    compositor_pitch = pitch;
    compositor_use_fallback_texture = new_resources.use_fallback_texture;

    compositor_texture = new_resources.texture;
    compositor_buffer = new_resources.buffer;
    s_palette_buffers[0] = new_resources.palette_buffers[0];
    s_palette_buffers[1] = new_resources.palette_buffers[1];
    reset_palette_latch_state();
    gamma_lut_buffer      = new_resources.gamma_lut;
    gamma_identity_buffer = new_resources.gamma_identity;
    // The fresh LUT holds only the display default; force the VBL latch to
    // recompose the ramp DMC carried across the switch.
    s_last_gamma_gen = UINT32_MAX;
    compositor_library = new_resources.library;
    compositor_pipeline = new_resources.pipeline;
    compositor_sampler = new_resources.sampler;

    compositor_layer.drawableSize = CGSizeMake(target_size.width, target_size.height);
    compositor_layer.contentsGravity = kCAGravityResizeAspect;
    compositor_layer.minificationFilter = useNearest ? kCAFilterNearest : kCAFilterLinear;
    compositor_layer.magnificationFilter = useNearest ? kCAFilterNearest : kCAFilterLinear;

    {
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        compositor_layer.colorspace = cs;
        if (cs) CGColorSpaceRelease(cs);
    }

    MetalCompositorSubmitFrame_SetFramebufferTexture(
        (__bridge void *)compositor_texture);

    COMPOSITOR_LOG("MetalCompositorResize: %dx%d depth=%d → framebuffer=%dx%d drawable=%dx%d depth=%d (%dbpp) "
                   "format=%s shader=%s filter=%s%s",
                   old_width, old_height, old_depth,
                   width, height,
                   target_size.width, target_size.height,
                   depth, compositor_bits_per_pixel,
                   texture_format_name(new_resources.tex_format),
                   [new_resources.fragment_name UTF8String],
                   useNearest ? "nearest" : "linear",
                   compositor_use_fallback_texture ? " (fallback texture)" : "");

    // The frame rate pref may have changed.
    int refresh_hz = objc_getFrameRateSetting();
    if (refresh_hz <= 0) refresh_hz = 60;
    frame_interval_usec = 1000000 / (uint64_t)refresh_hz;

    // Restart the display link for the new drawableSize and cadence.
    vbl_source_shutdown();
    int32_t vbl_err = vbl_source_init((__bridge void *)compositor_layer,
                                       compositor_vbl_callback,
                                       NULL);
    if (vbl_err != 0) {
        COMPOSITOR_ERR("MetalCompositorResize: vbl_source_init failed (%d)", vbl_err);
        // Non-fatal.
    }

    return 0;
}

int MetalCompositorIsInitialized(void)
{
    return (int)compositor_initialized;
}

void *MetalCompositorGetLayer(void)
{
    return (__bridge void *)compositor_layer;
}

// MetalCompositorGetFramebufferTexture is in metal_compositor_submitframe.mm;
// Init/Resize publish compositor_texture to it.

void MetalCompositorShutdown(void)
{
    // Unsubscribe first so a transition broadcast can't reach a half-torn-down
    // compositor. NotFound is fine if Init failed before subscribing.
    dmc_unsubscribe("compositor");

    // Before the layer it references goes away.
    vbl_source_shutdown();

    compositor_initialized = false;

    // Drains the inflight semaphore and releases the blend PSOs.
    MetalCompositorSubmitFrame_UnbindPresentationContext();

    COMPOSITOR_LOG("MetalCompositorShutdown: tearing down (view=%p layer=%p depth=%d)",
                   compositor_view, compositor_layer, compositor_depth);

    if (compositor_view) {
        [compositor_view removeFromSuperview];
        compositor_view = nil;
    }

    // Unpublish before compositor_texture is released.
    MetalCompositorSubmitFrame_SetFramebufferTexture(NULL);

    compositor_layer    = nil;
    compositor_pipeline = nil;
    compositor_sampler  = nil;
    compositor_texture  = nil;
    compositor_buffer   = nil;
    s_palette_buffers[0] = nil;
    s_palette_buffers[1] = nil;
    reset_palette_latch_state();
    gamma_lut_buffer      = nil;
    gamma_identity_buffer = nil;
    s_latched_fade_active = 0;
    s_last_gamma_gen = UINT32_MAX;
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

    frame_interval_usec = 0;

    COMPOSITOR_LOG("MetalCompositorShutdown: done");
}
