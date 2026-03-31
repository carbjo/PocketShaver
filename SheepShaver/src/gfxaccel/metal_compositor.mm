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
 *      SDL_GetWindowSize corruption feedback loop — see RAVE comments).
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

#include "sysdeps.h"
#include "video.h"
#include "video_blit.h"
#include "metal_device_shared.h"
#include "metal_compositor.h"
#include "prefs.h"
#include "MiscellaneousSettingsObjCCppHeader.h"

// ---------------------------------------------------------------------------
// Logging macros
// ---------------------------------------------------------------------------

#define COMPOSITOR_LOG(fmt, ...) \
    do { printf("[MetalCompositor] " fmt "\n", ##__VA_ARGS__); } while (0)

#define COMPOSITOR_ERR(fmt, ...) \
    do { printf("[MetalCompositor ERROR] " fmt "\n", ##__VA_ARGS__); } while (0)

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
// GetSDLUIWindow — retrieve UIWindow from SDL (same pattern as RAVE)
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

// Lifecycle flag (added in S04)
static bool                         compositor_initialized = false;

// Depth-aware state (added in S02)
static id<MTLBuffer>                palette_buffer      = nil;
static int                          compositor_depth    = 0;
static int                          compositor_pixel_width   = 0;
static int                          compositor_bits_per_pixel = 0;
static bool                         compositor_use_fallback_texture = false;
static int                          compositor_row_bytes = 0;
static int                          compositor_pitch     = 0;

// 3D overlay compositing state (added in S03)
static id<MTLTexture>               overlay_texture     = nil;
static bool                         overlay_active      = false;
static id<MTLRenderPipelineState>   overlay_pipeline    = nil;
static id<MTLSamplerState>          overlay_sampler     = nil;
static id<MTLLibrary>               compositor_library  = nil;  // cached shader library
static int                          overlay_width       = 0;
static int                          overlay_height      = 0;
static int                          overlay_x           = 0;
static int                          overlay_y           = 0;
static int                          overlay_viewport_w  = 0;
static int                          overlay_viewport_h  = 0;

// ---------------------------------------------------------------------------
// Frame-pacing state — caps 3D rendering to the compositor's VBL cadence
// ---------------------------------------------------------------------------

static uint64_t                     frame_interval_usec = 0;   // microseconds per VBL frame
static uint64_t                     last_3d_frame_usec  = 0;   // timestamp of last 3D frame gate

// ---------------------------------------------------------------------------
// Gamma fade state — set by DSpContext_FadeGamma* via MetalCompositorSetGammaMultiplier
// ---------------------------------------------------------------------------

static float                        compositor_gamma = 1.0f;
static float                        compositor_zero_color[3] = {0.0f, 0.0f, 0.0f};

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
// MetalCompositorInit
// ---------------------------------------------------------------------------

int MetalCompositorInit(int width, int height, int depth, int row_bytes,
                        int pitch, void *buffer, uint32_t buffer_size)
{
    // --- Store depth state ---
    compositor_depth = depth;
    compositor_pixel_width = width;
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
    compositor_layer.drawableSize = CGSizeMake(width, height);  // Mac framebuffer dims
    compositor_layer.contentsGravity = kCAGravityResizeAspect;  // preserve aspect ratio (letterbox)

    // --- CAMetalLayer scaling filter from user preference ---
    bool useNearest = PrefsFindBool("scale_nearest");
    compositor_layer.minificationFilter = useNearest ? kCAFilterNearest : kCAFilterLinear;
    compositor_layer.magnificationFilter = useNearest ? kCAFilterNearest : kCAFilterLinear;

    [uiWindow addSubview:compositor_view];

    COMPOSITOR_LOG("View created: layer=%p view=%p drawableSize=%dx%d windowBounds=%.0fx%.0f",
                   compositor_layer, compositor_view, width, height,
                   uiWindow.bounds.size.width, uiWindow.bounds.size.height);

    // --- Zero-copy shared buffer wrapping the_buffer ---
    compositor_buffer = [compositor_device newBufferWithBytesNoCopy:buffer
                                                            length:buffer_size
                                                           options:MTLResourceStorageModeShared
                                                       deallocator:nil];
    if (!compositor_buffer) {
        COMPOSITOR_ERR("MetalCompositorInit: FAILED — newBufferWithBytesNoCopy (buffer=%p size=%u)",
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
    texDesc.usage = MTLTextureUsageShaderRead;

    // Try zero-copy texture from buffer first (bytesPerRow = row_bytes for indexed,
    // or pitch for direct modes). Metal requires bytesPerRow to be 16-byte aligned
    // for buffer-backed textures — a hard assertion failure, not a nil return.
    int texBytesPerRow = (depth <= VIDEO_DEPTH_8BIT) ? row_bytes : pitch;
    bool bytesPerRowAligned = (texBytesPerRow % 16 == 0);

    if (bytesPerRowAligned) {
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

    // --- Palette buffer for indexed depths ---
    if (depth <= VIDEO_DEPTH_8BIT) {
        palette_buffer = [compositor_device newBufferWithLength:256 * 4
                                                       options:MTLResourceStorageModeShared];
        if (!palette_buffer) {
            COMPOSITOR_ERR("MetalCompositorInit: FAILED — palette_buffer creation");
            return -1;
        }
        // Initialize to zeros (black)
        memset(palette_buffer.contents, 0, 256 * 4);
        COMPOSITOR_LOG("MetalCompositorInit: palette_buffer created (256x4 bytes)");
    }

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

    // Store VBL frame interval for 3D frame-pacing
    int refresh_hz = objc_getFrameRateSetting();
    if (refresh_hz <= 0) refresh_hz = 60;
    frame_interval_usec = 1000000 / (uint64_t)refresh_hz;
    last_3d_frame_usec = 0;  // reset on init

    return 0;
}

// ---------------------------------------------------------------------------
// MetalCompositorUpdatePalette — upload palette for indexed depths
// ---------------------------------------------------------------------------

void MetalCompositorUpdatePalette(const uint8_t *pal, int num_colors)
{
    if (!palette_buffer) {
        COMPOSITOR_ERR("MetalCompositorUpdatePalette: no palette buffer "
                       "(depth=%d is not indexed)", compositor_depth);
        return;
    }

    if (num_colors > 256) num_colors = 256;
    if (num_colors <= 0 || !pal) return;

    // Expand 3-byte RGB to 4-byte RGBA (A=255)
    uint8_t *dst = (uint8_t *)palette_buffer.contents;
    for (int i = 0; i < num_colors; i++) {
        dst[i * 4 + 0] = pal[i * 3 + 0];  // R
        dst[i * 4 + 1] = pal[i * 3 + 1];  // G
        dst[i * 4 + 2] = pal[i * 3 + 2];  // B
        dst[i * 4 + 3] = 255;              // A
    }

    COMPOSITOR_LOG("MetalCompositorUpdatePalette: uploaded %d colors", num_colors);
}

// ---------------------------------------------------------------------------
// MetalCompositorCreateOverlayTexture — create/resize offscreen 3D render target
// ---------------------------------------------------------------------------

int MetalCompositorCreateOverlayTexture(int w, int h)
{
    if (!compositor_device) {
        COMPOSITOR_ERR("MetalCompositorCreateOverlayTexture: FAILED — no device");
        return -1;
    }

    // If texture already exists at the right size, return as-is
    if (overlay_texture && overlay_width == w && overlay_height == h) {
        COMPOSITOR_LOG("MetalCompositorCreateOverlayTexture: reusing existing %dx%d texture=%p",
                       w, h, overlay_texture);
        return 0;
    }

    // Release existing texture if dimensions differ
    if (overlay_texture) {
        COMPOSITOR_LOG("MetalCompositorCreateOverlayTexture: resizing %dx%d → %dx%d",
                       overlay_width, overlay_height, w, h);
        overlay_texture = nil;
    }

    // Create offscreen texture: BGRA8Unorm, Private, RenderTarget|ShaderRead
    MTLTextureDescriptor *texDesc = [[MTLTextureDescriptor alloc] init];
    texDesc.textureType = MTLTextureType2D;
    texDesc.pixelFormat = MTLPixelFormatBGRA8Unorm;
    texDesc.width = (NSUInteger)w;
    texDesc.height = (NSUInteger)h;
    texDesc.storageMode = MTLStorageModePrivate;
    texDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;

    overlay_texture = [compositor_device newTextureWithDescriptor:texDesc];
    if (!overlay_texture) {
        COMPOSITOR_ERR("MetalCompositorCreateOverlayTexture: FAILED — texture creation "
                       "(format=BGRA8Unorm %dx%d)", w, h);
        overlay_width = 0;
        overlay_height = 0;
        return -1;
    }

    overlay_width = w;
    overlay_height = h;

    // Clear the new texture to transparent black. Private storage textures
    // have undefined initial contents — without this, the compositor may
    // sample garbage (e.g. magenta) before the first RAVE/GL frame renders.
    {
        MTLRenderPassDescriptor *clearPass = [MTLRenderPassDescriptor renderPassDescriptor];
        clearPass.colorAttachments[0].texture = overlay_texture;
        clearPass.colorAttachments[0].loadAction = MTLLoadActionClear;
        clearPass.colorAttachments[0].storeAction = MTLStoreActionStore;
        clearPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        id<MTLCommandBuffer> cmdBuf = [compositor_queue commandBuffer];
        if (cmdBuf) {
            id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:clearPass];
            if (enc) {
                [enc endEncoding];
            }
            [cmdBuf commit];
            [cmdBuf waitUntilCompleted];
        }
    }

    // Build overlay compositing pipeline if not already created
    if (!overlay_pipeline) {
        if (!compositor_library) {
            compositor_library = [compositor_device newDefaultLibrary];
        }
        id<MTLLibrary> library = compositor_library;
        if (!library) {
            COMPOSITOR_ERR("MetalCompositorCreateOverlayTexture: FAILED — newDefaultLibrary");
            overlay_texture = nil;
            overlay_width = 0;
            overlay_height = 0;
            return -1;
        }

        id<MTLFunction> vertexFunc = [library newFunctionWithName:@"compositor_vertex"];
        id<MTLFunction> fragmentFunc = [library newFunctionWithName:@"compositor_fragment_composite"];
        if (!vertexFunc || !fragmentFunc) {
            COMPOSITOR_ERR("MetalCompositorCreateOverlayTexture: FAILED — shader function lookup "
                           "(vertex=%p fragment=%p)", vertexFunc, fragmentFunc);
            overlay_texture = nil;
            overlay_width = 0;
            overlay_height = 0;
            return -1;
        }

        MTLRenderPipelineDescriptor *pipeDesc = [[MTLRenderPipelineDescriptor alloc] init];
        pipeDesc.vertexFunction = vertexFunc;
        pipeDesc.fragmentFunction = fragmentFunc;
        pipeDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

        // Opaque overlay: the overlay covers the 2D framebuffer within its
        // viewport rect. RAVE/GL apps don't manage alpha (often output 0),
        // so alpha-based blending doesn't work. Instead, just overwrite
        // the destination. Viewport clipping handles 2D/3D separation.
        pipeDesc.colorAttachments[0].blendingEnabled = NO;
        pipeDesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pipeDesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

        NSError *pipeError = nil;
        overlay_pipeline = [compositor_device newRenderPipelineStateWithDescriptor:pipeDesc
                                                                            error:&pipeError];
        if (!overlay_pipeline) {
            COMPOSITOR_ERR("MetalCompositorCreateOverlayTexture: FAILED — overlay pipeline creation: %s",
                           [[pipeError localizedDescription] UTF8String]);
            overlay_texture = nil;
            overlay_width = 0;
            overlay_height = 0;
            return -1;
        }
    }

    // Create overlay sampler if not already created
    if (!overlay_sampler) {
        MTLSamplerDescriptor *sampDesc = [[MTLSamplerDescriptor alloc] init];
        sampDesc.minFilter = MTLSamplerMinMagFilterLinear;
        sampDesc.magFilter = MTLSamplerMinMagFilterLinear;
        sampDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sampDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
        overlay_sampler = [compositor_device newSamplerStateWithDescriptor:sampDesc];
    }

    COMPOSITOR_LOG("MetalCompositorCreateOverlayTexture: created %dx%d texture=%p",
                   w, h, overlay_texture);
    return 0;
}

// ---------------------------------------------------------------------------
// MetalCompositorGetOverlayTexture — return overlay texture as void* for .cpp
// ---------------------------------------------------------------------------

void *MetalCompositorGetOverlayTexture(void)
{
    return (__bridge void *)overlay_texture;
}

// ---------------------------------------------------------------------------
// MetalCompositorSetOverlayActive — enable/disable 3D overlay compositing
// ---------------------------------------------------------------------------

void MetalCompositorSetOverlayActive(int active)
{
    bool new_active = (active != 0);
    if (overlay_active != new_active) {
        COMPOSITOR_LOG("MetalCompositorSetOverlayActive: %s", new_active ? "ON" : "OFF");
        overlay_active = new_active;
    }
}

// ---------------------------------------------------------------------------
// MetalCompositorSetOverlayRect — set overlay viewport within Mac framebuffer
// ---------------------------------------------------------------------------

void MetalCompositorSetOverlayRect(int x, int y, int w, int h)
{
    overlay_x = x;
    overlay_y = y;
    // If w/h provided, use them for viewport; otherwise fall back to texture size
    if (w > 0 && h > 0) {
        overlay_viewport_w = w;
        overlay_viewport_h = h;
    }
}

// ---------------------------------------------------------------------------
// MetalCompositorSetGammaMultiplier — set gamma fade level for fragment shaders
// ---------------------------------------------------------------------------

void MetalCompositorSetGammaMultiplier(float gamma, const float *zero_color)
{
    compositor_gamma = gamma;
    if (zero_color) {
        compositor_zero_color[0] = zero_color[0];
        compositor_zero_color[1] = zero_color[1];
        compositor_zero_color[2] = zero_color[2];
    }
    COMPOSITOR_LOG("MetalCompositorSetGammaMultiplier: gamma=%.3f zero_color=(%.3f,%.3f,%.3f)",
                   compositor_gamma,
                   compositor_zero_color[0], compositor_zero_color[1], compositor_zero_color[2]);
}

// ---------------------------------------------------------------------------
// MetalCompositorPresent — render one frame
// ---------------------------------------------------------------------------

void MetalCompositorPresent(void)
{
    if (!compositor_layer || !compositor_pipeline) return;

    @autoreleasepool {

    // If using fallback texture, upload framebuffer data via replaceRegion
    if (compositor_use_fallback_texture && compositor_texture && compositor_buffer) {
        MTLRegion region = MTLRegionMake2D(0, 0,
                                           compositor_texture.width,
                                           compositor_texture.height);
        [compositor_texture replaceRegion:region
                              mipmapLevel:0
                                withBytes:compositor_buffer.contents
                              bytesPerRow:(NSUInteger)compositor_pitch];
    }

    // Get next drawable — never cache across frames
    id<CAMetalDrawable> drawable = [compositor_layer nextDrawable];
    if (!drawable) {
        // All drawables in flight — drop this frame
        COMPOSITOR_LOG("MetalCompositorPresent: no drawable (all in flight)");
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

    if (compositor_depth <= VIDEO_DEPTH_8BIT) {
        // Indexed mode: bind palette buffer + uniforms
        [enc setFragmentBuffer:palette_buffer offset:0 atIndex:0];
        uint32_t bpp = (uint32_t)compositor_bits_per_pixel;
        uint32_t pw  = (uint32_t)compositor_pixel_width;
        [enc setFragmentBytes:&bpp length:sizeof(bpp) atIndex:1];
        [enc setFragmentBytes:&pw  length:sizeof(pw)  atIndex:2];
    } else if (compositor_depth == VIDEO_DEPTH_32BIT) {
        // 32-bit mode: bind sampler
        [enc setFragmentSamplerState:compositor_sampler atIndex:0];
    }
    // 16-bit mode: no extra bindings — shader reads directly

    // Gamma fade uniform: pass gamma multiplier + zero-intensity color to all fragment shaders
    // (buffer index 3 — matches GammaParams struct in compositor_shaders.metal)
    // Must match Metal's GammaParams { float gamma; float3 zero_color; }
    // float3 is 16-byte aligned in Metal, so pad to offset 16.
    struct __attribute__((aligned(16))) {
        float gamma;
        float _pad[3];
        float zero_color[4]; // float3 occupies 16 bytes in Metal (3 floats + padding)
    } gamma_params;
    memset(&gamma_params, 0, sizeof(gamma_params));
    gamma_params.gamma = compositor_gamma;
    gamma_params.zero_color[0] = compositor_zero_color[0];
    gamma_params.zero_color[1] = compositor_zero_color[1];
    gamma_params.zero_color[2] = compositor_zero_color[2];
    [enc setFragmentBytes:&gamma_params length:sizeof(gamma_params) atIndex:3];

    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];

    // --- 3D overlay compositing pass ---
    if (overlay_active && overlay_texture && overlay_pipeline) {
        COMPOSITOR_LOG("MetalCompositorPresent: compositing 2D+3D");

        // Set viewport to the overlay's visible rect within the Mac framebuffer.
        // overlay_viewport_w/h may be smaller than the overlay texture (e.g. the
        // RAVE render viewport is 510x361 within a 640x480 texture). This ensures
        // only the rendered portion covers the 2D framebuffer.
        int vp_w = (overlay_viewport_w > 0) ? overlay_viewport_w : overlay_width;
        int vp_h = (overlay_viewport_h > 0) ? overlay_viewport_h : overlay_height;
        MTLViewport overlayVP;
        overlayVP.originX = overlay_x;
        overlayVP.originY = overlay_y;
        overlayVP.width   = vp_w;
        overlayVP.height  = vp_h;
        overlayVP.znear   = 0.0;
        overlayVP.zfar    = 1.0;
        [enc setViewport:overlayVP];

        [enc setRenderPipelineState:overlay_pipeline];
        [enc setFragmentTexture:overlay_texture atIndex:0];
        [enc setFragmentSamplerState:overlay_sampler atIndex:0];

        // Pass UV scale to map the viewport portion of the overlay texture.
        // The overlay texture may be larger than the render viewport.
        float uv_scale[2] = {
            (float)vp_w / (float)overlay_width,
            (float)vp_h / (float)overlay_height
        };
        [enc setFragmentBytes:uv_scale length:sizeof(uv_scale) atIndex:0];

        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
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
// switch. Keeps the view, layer, device, queue, overlay_pipeline, and
// overlay_sampler alive — only rebuilds depth-dependent resources. This
// avoids the visual flash and UIView lifecycle overhead of full
// Shutdown→Init cycles.

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
    int old_height = (int)compositor_layer.drawableSize.height;
    int old_depth = compositor_depth;

    // --- Release old depth-dependent resources ---
    compositor_buffer   = nil;
    compositor_texture  = nil;
    palette_buffer      = nil;
    compositor_pipeline = nil;
    compositor_sampler  = nil;

    // Nil overlay texture so RAVE/GL will recreate via MetalCompositorCreateOverlayTexture().
    // Keep overlay_pipeline and overlay_sampler — they are depth-independent BGRA8Unorm.
    overlay_texture = nil;
    overlay_width   = 0;
    overlay_height  = 0;
    overlay_x       = 0;
    overlay_y       = 0;
    overlay_viewport_w = 0;
    overlay_viewport_h = 0;
    overlay_active  = false;

    // --- Update depth state ---
    compositor_depth = depth;
    compositor_pixel_width = width;
    compositor_bits_per_pixel = bits_per_pixel_for_depth(depth);
    compositor_row_bytes = row_bytes;
    compositor_pitch = pitch;
    compositor_use_fallback_texture = false;

    if (compositor_bits_per_pixel == 0) {
        COMPOSITOR_ERR("MetalCompositorResize: FAILED — unknown depth value %d", depth);
        return -1;
    }

    // --- Update layer drawable size ---
    compositor_layer.drawableSize = CGSizeMake(width, height);
    compositor_layer.contentsGravity = kCAGravityResizeAspect;  // preserve aspect ratio (letterbox)

    // --- Update CAMetalLayer scaling filter from user preference ---
    bool useNearest = PrefsFindBool("scale_nearest");
    compositor_layer.minificationFilter = useNearest ? kCAFilterNearest : kCAFilterLinear;
    compositor_layer.magnificationFilter = useNearest ? kCAFilterNearest : kCAFilterLinear;

    // --- Zero-copy shared buffer wrapping the_buffer ---
    compositor_buffer = [compositor_device newBufferWithBytesNoCopy:buffer
                                                            length:buffer_size
                                                           options:MTLResourceStorageModeShared
                                                       deallocator:nil];
    if (!compositor_buffer) {
        COMPOSITOR_ERR("MetalCompositorResize: FAILED — newBufferWithBytesNoCopy "
                       "(buffer=%p size=%u)", buffer, buffer_size);
        return -1;
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
    texDesc.usage = MTLTextureUsageShaderRead;

    int texBytesPerRow = (depth <= VIDEO_DEPTH_8BIT) ? row_bytes : pitch;
    bool bytesPerRowAligned = (texBytesPerRow % 16 == 0);

    if (bytesPerRowAligned) {
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

    // --- Palette buffer for indexed depths ---
    if (depth <= VIDEO_DEPTH_8BIT) {
        palette_buffer = [compositor_device newBufferWithLength:256 * 4
                                                       options:MTLResourceStorageModeShared];
        if (!palette_buffer) {
            COMPOSITOR_ERR("MetalCompositorResize: FAILED — palette_buffer creation");
            return -1;
        }
        memset(palette_buffer.contents, 0, 256 * 4);
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

    COMPOSITOR_LOG("MetalCompositorResize: %dx%d depth=%d → %dx%d depth=%d (%dbpp) "
                   "format=%s shader=%s filter=%s%s",
                   old_width, old_height, old_depth,
                   width, height, depth, compositor_bits_per_pixel,
                   texture_format_name(texFormat),
                   [fragmentName UTF8String],
                   useNearest ? "nearest" : "linear",
                   compositor_use_fallback_texture ? " (fallback texture)" : "");

    // Re-read frame rate setting (may have changed in preferences before restart)
    int refresh_hz = objc_getFrameRateSetting();
    if (refresh_hz <= 0) refresh_hz = 60;
    frame_interval_usec = 1000000 / (uint64_t)refresh_hz;
    last_3d_frame_usec = 0;

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
// MetalCompositorShutdown — tear down all resources
// ---------------------------------------------------------------------------

void MetalCompositorShutdown(void)
{
    compositor_initialized = false;

    COMPOSITOR_LOG("MetalCompositorShutdown: tearing down (view=%p layer=%p depth=%d)",
                   compositor_view, compositor_layer, compositor_depth);

    if (compositor_view) {
        [compositor_view removeFromSuperview];
        compositor_view = nil;
    }

    compositor_layer    = nil;
    compositor_pipeline = nil;
    compositor_sampler  = nil;
    compositor_texture  = nil;
    compositor_buffer   = nil;
    palette_buffer      = nil;
    compositor_queue    = nil;
    compositor_device   = nil;
    compositor_library  = nil;

    // Overlay cleanup (S03)
    overlay_texture     = nil;
    overlay_pipeline    = nil;
    overlay_sampler     = nil;
    overlay_active      = false;
    overlay_width       = 0;
    overlay_height      = 0;
    overlay_x           = 0;
    overlay_y           = 0;
    overlay_viewport_w  = 0;
    overlay_viewport_h  = 0;

    compositor_depth    = 0;
    compositor_pixel_width   = 0;
    compositor_bits_per_pixel = 0;
    compositor_row_bytes = 0;
    compositor_pitch = 0;
    compositor_use_fallback_texture = false;

    // Frame-pacing cleanup
    frame_interval_usec = 0;
    last_3d_frame_usec  = 0;

    // Gamma fade cleanup
    compositor_gamma = 1.0f;
    compositor_zero_color[0] = 0.0f;
    compositor_zero_color[1] = 0.0f;
    compositor_zero_color[2] = 0.0f;

    COMPOSITOR_LOG("MetalCompositorShutdown: done");
}

// ---------------------------------------------------------------------------
// MetalCompositorSync3DFramePacing — throttle 3D renderers to VBL cadence
// ---------------------------------------------------------------------------
//
// Called from RAVE (NativeRenderEnd) and GL (NativeAGLSwapBuffers) after
// committing a 3D frame to the offscreen overlay texture. Sleeps the
// calling thread (the PPC emulator thread) until the next VBL tick
// boundary so 3D rendering doesn't outrun the compositor's present rate.
//
// Without this, 3D apps can submit many frames between VBL ticks — the
// intermediate frames are never seen (the compositor reads the texture
// once per tick), wasting GPU time and potentially causing visual tearing
// if a write is in progress during a compositor read.
//
// The gate is lightweight: just a timestamp comparison + usleep. No mutex
// or semaphore — the 3D renderers and compositor are on separate threads
// and the offscreen texture is the only shared resource.

void MetalCompositorSync3DFramePacing(void)
{
    if (frame_interval_usec == 0) return;  // not initialized

    uint64_t now = GetTicks_usec();

    if (last_3d_frame_usec > 0) {
        uint64_t elapsed = now - last_3d_frame_usec;
        if (elapsed < frame_interval_usec) {
            uint64_t wait = frame_interval_usec - elapsed;
            Delay_usec(wait);
            now = GetTicks_usec();
        }
    }

    last_3d_frame_usec = now;
}
