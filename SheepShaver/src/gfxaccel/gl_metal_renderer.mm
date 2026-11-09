/*
 *  gl_metal_renderer.mm - Metal rendering backend for OpenGL 1.2 FFP
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Pipeline/depth-stencil caches, a triple-buffered vertex ring, immediate
 *  mode and vertex-array draws, uniform upload, texture upload/readback, and
 *  frame begin/end into the compositor's overlay.
 */

#import <Metal/Metal.h>

#include <algorithm>
#include <cstring>
#include <cstdio>
#include <cstddef>
#include <cmath>
#include <dispatch/dispatch.h>
#include <unordered_map>
#include <vector>

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "gl_engine.h"
#include "gl_input_validation.h"
#include <new>
#include "gl_buffer_policy.h"
#include "metal_compositor.h"
#include "display_mode_controller.h"
#include "accel_logging.h"
#include "metal_device_shared.h"
#include "gl_metal_coordinates.h"
#include "gl_metal_draw_state.h"
#include "gl_vertex_pipeline.h"
#include "gl_render_contract.h"
#include "gl_texture_environment.h"
#include "gl_texture_format_policy.h"
#include "gl_offscreen_policy.h"
#include "gl_pixel_unpack_policy.h"
#include "gl_pixel_pack_policy.h"
#include "gl_pixel_readback.h"
#include "gl_pixel_upload.h"
#include "nqd_accel.h"


// From macos_util.h, which conflicts with UIKit headers
extern uint32 Mac_sysalloc(uint32 size);

/* Each drawable owns logical front/back color buffers, plus two immutable
 * publication snapshots. A snapshot is reused only after another snapshot
 * replaces it in the compositor mailbox; all GPU work shares the same queue. */
struct GLOverlayState {
    id<MTLTexture> pair[2] = { nil, nil };
    id<MTLTexture> presentation[2] = { nil, nil };
    id<MTLTexture> published[2] = { nil, nil };
    uint32_t publication_index = 0;
    bool needs_clear = true;
    int32_t left = 0, top = 0, width = 0, height = 0;
    bool committed = false;
};
static std::unordered_map<GLContext *, GLOverlayState> s_gl_overlays;

static void gl_end_render_target_for_detach(GLContext *ctx);

static void gl_release_overlay_texture(GLOverlayState &overlay)
{
    for (int i = 0; i < 2; ++i) {
        MetalCompositorSubmitFrame_ClearCachedOverlayForSource(
            (__bridge void *)overlay.published[i]);
        overlay.published[i] = nil;
        overlay.pair[i] = nil;
        overlay.presentation[i] = nil;
    }
    overlay.publication_index = 0;
    overlay.needs_clear = true;
    overlay.committed = false;
}

static bool gl_claim_display_for_overlay(void)
{
    const int32_t err = dmc_set_active_owner(kDMCOwnerGL);
    if (err != kDMCNoErr) {
        GL_METAL_LOG("GL display ownership request failed (%d)", err);
        return false;
    }
    return true;
}

static id<MTLTexture> gl_new_render_target(uint32_t width, uint32_t height)
{
    if (width == 0 || height == 0) return nil;
    id<MTLDevice> device = (__bridge id<MTLDevice>)SharedMetalDevice();
    MTLTextureDescriptor *desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                    width:width height:height mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModePrivate;
    return [device newTextureWithDescriptor:desc];
}

static id<MTLTexture> gl_acquire_overlay_texture(GLOverlayState &overlay)
{
    if (!overlay.pair[0] || !overlay.pair[1] || !overlay.presentation[0] || !overlay.presentation[1]) {
        id<MTLTexture> first = gl_new_render_target(overlay.width, overlay.height);
        id<MTLTexture> second = gl_new_render_target(overlay.width, overlay.height);
        id<MTLTexture> presentFront = gl_new_render_target(overlay.width, overlay.height);
        id<MTLTexture> presentBack = gl_new_render_target(overlay.width, overlay.height);
        if (!first || !second || !presentFront || !presentBack) return nil;
        overlay.presentation[0] = presentFront;
        overlay.presentation[1] = presentBack;
        overlay.pair[0] = first;
        overlay.pair[1] = second;
        overlay.committed = false;
        overlay.needs_clear = true;
    }
    return overlay.pair[0];
}

extern "C" void gl_overlay_bind(GLContext *ctx, int32_t left, int32_t top,
                                 int32_t width, int32_t height)
{
    if (!ctx || width <= 0 || height <= 0) return;
    auto existing = s_gl_overlays.find(ctx);
    if (existing == s_gl_overlays.end() ||
        existing->second.width != width || existing->second.height != height)
        gl_end_render_target_for_detach(ctx);
    // A claim can detach every overlay. Acquire only after that handoff.
    if (!gl_claim_display_for_overlay()) return;
    GLOverlayState &overlay = s_gl_overlays[ctx];
    if (overlay.width != width || overlay.height != height)
        gl_release_overlay_texture(overlay);
    overlay.left = left; overlay.top = top;
    overlay.width = width; overlay.height = height;
    (void)gl_acquire_overlay_texture(overlay);
}

extern "C" void gl_overlay_unbind(GLContext *ctx)
{
    auto it = s_gl_overlays.find(ctx);
    if (it == s_gl_overlays.end()) return;
    gl_end_render_target_for_detach(ctx);
    gl_release_overlay_texture(it->second);
    s_gl_overlays.erase(it);
}

static void gl_note_front_modified(GLContext *ctx, id<MTLTexture> texture)
{
    auto it = s_gl_overlays.find(ctx);
    if (it != s_gl_overlays.end() && texture != nil &&
        texture == it->second.pair[0] &&
        (GLDrawBufferTargets(ctx->draw_buffer, ctx->double_buffered) & 1))
        it->second.committed = true;
}

// Publish a copy, never a logical buffer that a later GL_FRONT draw can edit.
static void gl_publish_front(GLContext *ctx)
{
    auto it = s_gl_overlays.find(ctx);
    if (it == s_gl_overlays.end()) return;
    GLOverlayState &overlay = it->second;
    id<MTLTexture> front = overlay.presentation[0];
    if (!overlay.committed || !front) return;
    id<MTLTexture> __strong &texture = overlay.published[overlay.publication_index];
    if (!texture) texture = gl_new_render_target(overlay.width, overlay.height);
    if (!texture) return;
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)SharedMetalCommandQueue();
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    if (!blit) return;
    [blit copyFromTexture:front sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(front.width,front.height,1)
        toTexture:texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [blit endEncoding];
    [command commit];

    const DMCModeSnapshot *snap = dmc_current_snapshot();
    CompositeLayer layer = {};
    layer.source = (__bridge void *)texture;
    layer.src_size_w = (uint32_t)texture.width;
    layer.src_size_h = (uint32_t)texture.height;
    layer.dst_origin_x = (float)overlay.left;
    layer.dst_origin_y = (float)overlay.top;
    layer.dst_size_w = (float)overlay.width;
    layer.dst_size_h = (float)overlay.height;
    layer.slot = kLayerSlotOverlay;
    layer.blend = kBlendPremultiplied;
    layer.alpha = 1.0f;
    FrameDescriptor desc = { &layer, 1, snap ? snap->generation : 0, 0 };
    if (MetalCompositorSubmitFrame(&desc) == kGfxAccelNoErr) {
        overlay.publication_index ^= 1u;
        overlay.committed = false;
    }
}

extern "C" void gl_overlay_present(GLContext *ctx)
{
    auto it = s_gl_overlays.find(ctx);
    if (it == s_gl_overlays.end()) return;
    if (ctx->double_buffered) {
        std::swap(it->second.pair[0], it->second.pair[1]);
        std::swap(it->second.presentation[0], it->second.presentation[1]);
        it->second.committed = true;
    }
    gl_publish_front(ctx);
    // A swap changes both logical roles; the next operation reloads the pair.
    // AGL has already called EndFrame.
    gl_end_render_target_for_detach(ctx);
}

extern "C" int gl_prepare_overlays_for_attach(void)
{
    for (auto &entry : s_gl_overlays) {
        if (!gl_acquire_overlay_texture(entry.second)) return -1;
    }
    return 0;
}

extern "C" void gl_release_overlay_for_detach(void)
{
    for (auto &entry : s_gl_overlays) {
        gl_end_render_target_for_detach(entry.first);
        gl_release_overlay_texture(entry.second);
    }
}

// Blend factors
#define GL_ZERO                    0x0000
#define GL_ONE                     0x0001
#define GL_SRC_COLOR               0x0300
#define GL_ONE_MINUS_SRC_COLOR     0x0301
#define GL_SRC_ALPHA               0x0302
#define GL_ONE_MINUS_SRC_ALPHA     0x0303
#define GL_DST_ALPHA               0x0304
#define GL_ONE_MINUS_DST_ALPHA     0x0305
#define GL_DST_COLOR               0x0306
#define GL_ONE_MINUS_DST_COLOR     0x0307
#define GL_SRC_ALPHA_SATURATE      0x0308

// EXT_blend_color factors (values from glext.h)
#define GL_CONSTANT_COLOR              0x8001
#define GL_ONE_MINUS_CONSTANT_COLOR    0x8002
#define GL_CONSTANT_ALPHA              0x8003
#define GL_ONE_MINUS_CONSTANT_ALPHA    0x8004

// Blend equations (EXT_blend_equation / _minmax / _subtract; values from glext.h)
#define GL_FUNC_ADD                    0x8006
#define GL_MIN                         0x8007
#define GL_MAX                         0x8008
#define GL_FUNC_SUBTRACT               0x800A
#define GL_FUNC_REVERSE_SUBTRACT       0x800B

// GL primitive modes
#define GL_POINTS                  0x0000
#define GL_LINES                   0x0001
#define GL_LINE_LOOP               0x0002
#define GL_LINE_STRIP              0x0003
#define GL_TRIANGLES               0x0004
#define GL_TRIANGLE_STRIP          0x0005
#define GL_TRIANGLE_FAN            0x0006
#define GL_QUADS                   0x0007
#define GL_QUAD_STRIP              0x0008
#define GL_POLYGON                 0x0009

// GL depth functions
#define GL_NEVER                   0x0200
#define GL_LESS                    0x0201
#define GL_EQUAL                   0x0202
#define GL_LEQUAL                  0x0203
#define GL_GREATER                 0x0204
#define GL_NOTEQUAL                0x0205
#define GL_GEQUAL                  0x0206
#define GL_ALWAYS                  0x0207

// GL stencil operations
#define GL_KEEP                    0x1E00
#define GL_REPLACE_STENCIL         0x1E01
#define GL_INCR                    0x1E02
#define GL_DECR                    0x1E03
#define GL_INVERT_STENCIL          0x150A
#define GL_INCR_WRAP               0x8507
#define GL_DECR_WRAP               0x8508

// GL fog modes
#define GL_LINEAR                  0x2601
#define GL_EXP                     0x0800
#define GL_EXP2                    0x0801

// GL shade model
#define GL_FLAT                    0x1D00
#define GL_SMOOTH                  0x1D01

// GL data types (for vertex arrays)
#define GL_BYTE                    0x1400
#define GL_UNSIGNED_BYTE           0x1401
#define GL_SHORT                   0x1402
#define GL_UNSIGNED_SHORT          0x1403
#define GL_INT                     0x1404
#define GL_UNSIGNED_INT            0x1405
#define GL_FLOAT                   0x1406
#define GL_2_BYTES                 0x1407
#define GL_3_BYTES                 0x1408
#define GL_4_BYTES                 0x1409
#define GL_DOUBLE                  0x140A

// GL client state arrays
#define GL_VERTEX_ARRAY            0x8074
#define GL_NORMAL_ARRAY            0x8075
#define GL_COLOR_ARRAY             0x8076
#define GL_TEXTURE_COORD_ARRAY     0x8078

// GL interleaved array formats
#define GL_V2F                     0x2A20
#define GL_V3F                     0x2A21
#define GL_C4UB_V2F                0x2A22
#define GL_C4UB_V3F                0x2A23
#define GL_C3F_V3F                 0x2A24
#define GL_N3F_V3F                 0x2A25
#define GL_C4F_N3F_V3F             0x2A26
#define GL_T2F_V3F                 0x2A27
#define GL_T4F_V4F                 0x2A28
#define GL_T2F_C4UB_V3F            0x2A29
#define GL_T2F_C3F_V3F             0x2A2A
#define GL_T2F_N3F_V3F             0x2A2B
#define GL_T2F_C4F_N3F_V3F         0x2A2C
#define GL_T4F_C4F_N3F_V4F         0x2A2D


// Must match GLVertexUniforms in gl_shaders.metal
struct GLMetalVertexUniforms {
    float mvp_matrix[16];       // float4x4
    float modelview_matrix[16]; // float4x4
    float normal_matrix[12];    // float3x3, each column padded to float4
    int32_t lighting_enabled;
    int32_t normalize_enabled;
    int32_t num_active_lights;
    int32_t fog_enabled;
    int32_t fog_mode;
    float   fog_start;
    float   fog_end;
    float   fog_density;
    float   point_size;
    int32_t two_side_lighting;  // GL_LIGHT_MODEL_TWO_SIDE
    int32_t num_clip_planes;    // offset 216
    float   _clip_pad[1];       // aligns clip_planes to 224 for float4
    float   clip_planes[6][4];  // offset 224
};

// Must match GLLight in gl_shaders.metal. Metal float3 occupies 16 bytes.
struct GLMetalLight {
    float ambient[4];                // offset 0
    float diffuse[4];                // offset 16
    float specular[4];               // offset 32
    float position[4];               // offset 48
    float spot_direction[4];         // offset 64 (Metal float3 = 16 bytes; [3] unused)
    float spot_exponent;             // offset 80
    float spot_cutoff;               // offset 84
    float constant_atten;            // offset 88
    float linear_atten;              // offset 92
    float quadratic_atten;           // offset 96
    int32_t enabled;                 // offset 100
    float _pad0, _pad1, _pad2;      // pad to 128 bytes
    float _pad3, _pad4, _pad5;
};

// Must match GLMaterialData in gl_shaders.metal
struct GLMetalMaterial {
    float ambient[4];
    float diffuse[4];
    float specular[4];
    float emission[4];
    float shininess;
    int32_t color_material;          // see GLColorMaterialToShader
    float _pad1, _pad2;
};

// Must match GLLightingData in gl_shaders.metal
struct GLMetalLightingData {
    GLMetalLight lights[8];
    GLMetalMaterial material;
    float global_ambient[4];
    GLMetalMaterial back_material;
    int32_t local_viewer;
    int32_t _pad[3];
};

// Layouts must match gl_shaders.metal.
static_assert(sizeof(GLMetalVertexUniforms) == 320, "GLMetalVertexUniforms size must match Metal GLVertexUniforms (320 bytes)");
static_assert(offsetof(GLMetalVertexUniforms, clip_planes) % 16 == 0,
              "GLMetalVertexUniforms.clip_planes must be 16-byte aligned to match Metal float4[6]");
static_assert(sizeof(GLMetalFragmentUniforms) == 288, "GLMetalFragmentUniforms size must match Metal GLFragmentUniforms (288 bytes)");
static_assert(sizeof(GLMetalLight) == 128, "GLMetalLight size must match Metal GLLight (128 bytes)");
static_assert(sizeof(GLMetalMaterial) == 80, "GLMetalMaterial size must match Metal GLMaterialData (80 bytes)");
static_assert(sizeof(GLMetalLightingData) == 1216, "GLMetalLightingData size must match Metal GLLightingData (1216 bytes)");
static_assert(offsetof(GLMetalLightingData, back_material) == 1120, "Metal back material offset");
static_assert(offsetof(GLMetalLightingData, local_viewer) == 1200, "Metal local viewer offset");


#define GL_RING_BUFFER_SIZE (4 * 1024 * 1024)
#define GL_RING_BUFFER_COUNT 3


// Per-context Metal resources (opaque to the C++ side)
struct GLMetalState {
    id<MTLTexture> destinationSnapshots[4] = {nil,nil,nil,nil};
    id<MTLDevice>               device;
    id<MTLCommandQueue>         commandQueue;
    id<MTLLibrary>              shaderLibrary;
    MTLVertexDescriptor        *vertexDescriptor;
    id<MTLComputePipelineState> textureCopyPipeline;
    bool framebufferFetch;
    bool textureCopyPending; // includes copies already committed but not CPU-synchronized

    // Keyed by MakePipelineKey
    std::unordered_map<uint64_t, id<MTLRenderPipelineState>> pipelineCache;

    std::unordered_map<uint64_t, id<MTLDepthStencilState>> depthStencilCache;
    std::unordered_map<unsigned, id<MTLRenderPipelineState>> clearPipelineCache;
    std::unordered_map<unsigned, id<MTLDepthStencilState>> clearDepthStencilCache;

    // Immediate-mode flush scratch, kept so capacity survives across flushes.
    // Cleared at the start of each flush.
    std::vector<GLMetalVertex> imExpandScratch;
    std::vector<GLMetalVertex> imConvertScratch;

    id<MTLBuffer>               vertexBuffers[GL_RING_BUFFER_COUNT];
    int                         currentBufferIndex;
    int                         bufferOffset;
    dispatch_semaphore_t        ringSemaphore;
    bool                        ringSlotAcquired;
    uint32_t                    ringSlotsInCommandBuffer;

    id<MTLBuffer>               vertexUniformBuffer;
    id<MTLBuffer>               fragmentUniformBuffer;
    id<MTLBuffer>               lightUniformBuffer;

    id<MTLCommandBuffer>        currentCommandBuffer;
    id<MTLRenderCommandEncoder> currentEncoder;
    id<MTLTexture>              overlayTexture;  // logical front color target
    id<MTLTexture>              backTexture;     // logical back (unused sink for offscreen)
    id<MTLTexture>              presentationTexture;
    id<MTLTexture>              presentationBackTexture;
    id<MTLTexture>              offscreenTexture; // private to this context, never published
    id<MTLTexture>              offscreenUploadTexture;
    std::vector<uint8_t>        offscreenUploadPixels;
    id<MTLTexture>              depthBuffer;
    id<MTLBuffer>               depthReadbackBuffer;
    id<MTLTexture>              fallbackWhiteTexture;  // 1x1, bound for missing textures
	id<MTLCommandBuffer>        lastCommittedBuffer;
	bool                        renderPassActive;
	bool                        initialized;
	bool                        viewportScissorCacheValid;
	uint32_t                    viewportScissorTargetWidth;
	uint32_t                    viewportScissorTargetHeight;
	int32_t                     cachedViewport[4];
	float                       cachedDepthRangeNear;
	float                       cachedDepthRangeFar;
	bool                        cachedScissorTest;
	int32_t                     cachedScissorBox[4];

	id<MTLSamplerState>         linearSampler;
    id<MTLSamplerState>         nearestSampler;
};

static unsigned GLMetalDrawTargets(GLContext *ctx)
{
    const unsigned targets = GLDrawBufferTargets(ctx->draw_buffer, ctx->double_buffered);
    // An AGL offscreen drawable has one caller-owned pixel array. Retain its
    // existing FRONT/BACK aliasing while keeping GL_NONE authoritative.
    return GLContextGetOffscreenDrawable(ctx, NULL, NULL, NULL, NULL) ? (targets ? 1 : 0) : targets;
}

static id<MTLTexture> GLMetalReadColorTexture(GLContext *ctx, GLMetalState *ms)
{
    if (GLContextGetOffscreenDrawable(ctx, NULL, NULL, NULL, NULL)) return ms->overlayTexture;
    return ctx->read_buffer == 0x0402 || ctx->read_buffer == 0x0405
        ? ms->backTexture : ms->overlayTexture;
}

static void GLMetalSetColorAttachments(MTLRenderPassDescriptor *pass, GLMetalState *ms)
{
    pass.colorAttachments[0].texture = ms->overlayTexture;
    pass.colorAttachments[1].texture = ms->backTexture;
    pass.colorAttachments[2].texture = ms->presentationTexture;
    pass.colorAttachments[3].texture = ms->presentationBackTexture;
    for (int i = 0; i < (ms->presentationTexture ? 4 : 2); ++i) {
        pass.colorAttachments[i].loadAction = MTLLoadActionLoad;
        pass.colorAttachments[i].storeAction = MTLStoreActionStore;
    }
}

static void GLMetalRingSignalSlots(dispatch_semaphore_t sem,
                                   uint32_t slotCount)
{
    for (uint32_t i = 0; i < slotCount; i++) {
        dispatch_semaphore_signal(sem);
    }
}

static void GLMetalAdvanceRingSlot(GLMetalState *ms)
{
    ms->currentBufferIndex = (ms->currentBufferIndex + 1) % GL_RING_BUFFER_COUNT;
    ms->bufferOffset = 0;
    ms->ringSlotAcquired = false;
}

static bool GLMetalAcquireRingSlot(GLMetalState *ms)
{
    if (!ms || !ms->ringSemaphore) {
        return false;
    }

    dispatch_semaphore_wait(ms->ringSemaphore, DISPATCH_TIME_FOREVER);
    ms->ringSlotAcquired = true;
    ms->ringSlotsInCommandBuffer++;
    return true;
}

static bool GLMetalEnsureRingSlot(GLMetalState *ms)
{
    if (!ms) {
        return false;
    }
    return ms->ringSlotAcquired || GLMetalAcquireRingSlot(ms);
}

static void GLMetalRegisterRingCompletion(GLMetalState *ms,
                                          id<MTLCommandBuffer> commandBuffer)
{
    if (!ms) {
        return;
    }

    uint32_t slotsConsumed = ms->ringSlotsInCommandBuffer;
    if (slotsConsumed == 0) {
        return;
    }

    dispatch_semaphore_t sem = ms->ringSemaphore;
    ms->ringSlotsInCommandBuffer = 0;
    GLMetalAdvanceRingSlot(ms);

    if (commandBuffer != nil) {
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completedCommandBuffer) {
            (void)completedCommandBuffer;
            GLMetalRingSignalSlots(sem, slotsConsumed);
        }];
    } else {
        GLMetalRingSignalSlots(sem, slotsConsumed);
    }
}

static void GLMetalCommitCommandBuffer(GLMetalState *ms,
                                       id<MTLCommandBuffer> commandBuffer)
{
    if (!commandBuffer) {
        return;
    }

    GLMetalRegisterRingCompletion(ms, commandBuffer);
    [commandBuffer commit];
}


// Mode handoffs must not leave an encoder writing an outgoing target.
// Avoid readback/guest work inside the DMC subscriber fan-out.
static void gl_end_render_target_for_detach(GLContext *ctx)
{
    GLMetalState *ms = ctx ? (GLMetalState *)ctx->metal : nullptr;
    if (!ms) return;
    if (ms->currentEncoder) {
        [ms->currentEncoder endEncoding];
        ms->currentEncoder = nil;
    }
    if (ms->currentCommandBuffer) {
        GLMetalCommitCommandBuffer(ms, ms->currentCommandBuffer);
        ms->lastCommittedBuffer = ms->currentCommandBuffer;
        ms->currentCommandBuffer = nil;
    }
    ms->renderPassActive = false;
    ms->overlayTexture = nil;
    ms->presentationTexture = nil;
    ms->presentationBackTexture = nil;
}

static id<MTLSamplerState> GLMetalGetSampler(GLMetalState *ms, GLTextureObject *texObj);

static bool GLMetalTexCoordArrayAvailableForDraw(const GLContext *ctx, int unit)
{
    if (!ctx || unit < 0 || unit >= 4) return false;
    return GLMetalTexCoordArrayAvailableForArrayDraw(
        ctx->texcoord_array[unit].enabled,
        ctx->prepared_texcoord_array_for_draw[unit],
        ctx->latched_texture_2d_for_array_draw[unit],
        ctx->prepared_texcoord_array[unit].pointer != 0);
}

static bool GLMetalTexture2DEnabledForDraw(const GLContext *ctx, int unit)
{
    if (!ctx || unit < 0 || unit >= 4) return false;
    return GLMetalTexture2DEnabledForArrayDraw(
        ctx->tex_units[unit].enabled_2d,
        ctx->prepared_texture_2d_for_draw[unit],
        ctx->latched_texture_2d_for_array_draw[unit],
        ctx->tex_units[unit].bound_texture_2d != 0,
        GLMetalTexCoordArrayAvailableForDraw(ctx, unit));
}

static const GLVertexArrayPointer *GLMetalTexCoordArrayForDraw(const GLContext *ctx,
                                                               int unit)
{
    if (!ctx || unit < 0 || unit >= 4) return nullptr;
    if (ctx->texcoord_array[unit].enabled && ctx->texcoord_array[unit].pointer)
        return &ctx->texcoord_array[unit];
    return nullptr;
}

static void GLMetalClearPreparedDrawState(GLContext *ctx)
{
    if (!ctx) return;
    for (int unit = 0; unit < 4; unit++) {
        ctx->prepared_texture_2d_for_draw[unit] = false;
        ctx->prepared_texcoord_array_for_draw[unit] = false;
    }
}

static void GLMetalMarkDrawCompleted(GLContext *ctx)
{
    if (!ctx) return;
    ctx->completed_draw_serial++;
    GLMetalClearPreparedDrawState(ctx);
}

// Offscreen rendering owns only the buffer supplied to aglSetOffScreen.
// QuickDraw and DrawSprocket must present guest pixels without injecting a
// cached GL frame into unrelated surfaces. The guest controls the ordering
// of 2D backgrounds, offscreen 3D copies, and foreground sprites.
static void GLMetalStoreBGRA8PixelsToGuestOffscreen(const uint8_t *bgra,
                                                    uint32_t width,
                                                    uint32_t height,
                                                    uint32_t dstRowbytes,
                                                    uint32_t dstBaseaddr,
                                                    uint32_t dstBytesPerPixel)
{
    uint8_t *dstBase = Mac2HostAddr(dstBaseaddr);

    for (uint32_t y = 0; y < height; y++) {
        const uint8_t *srcRow = bgra + (size_t)y * (size_t)width * 4u;

        if (dstBase != NULL) {
            uint8_t *dstRow = dstBase + (size_t)y * (size_t)dstRowbytes;
            for (uint32_t x = 0; x < width; x++) {
                const uint8_t *src = srcRow + (size_t)x * 4u;
                const uint8_t b = src[0];
                const uint8_t g = src[1];
                const uint8_t r = src[2];
                const uint8_t a = src[3];

                if (dstBytesPerPixel == 2) {
                    uint8_t bytes[2];
                    GLOffscreenStoreRGB555Bytes(
                        GLOffscreenPackARGB1555BigEndian(r, g, b, a), bytes);
                    dstRow[(size_t)x * 2u + 0] = bytes[0];
                    dstRow[(size_t)x * 2u + 1] = bytes[1];
                } else {
                    uint8_t bytes[4];
                    GLOffscreenStoreARGB8888Bytes(r, g, b, a, bytes);
                    dstRow[(size_t)x * 4u + 0] = bytes[0];
                    dstRow[(size_t)x * 4u + 1] = bytes[1];
                    dstRow[(size_t)x * 4u + 2] = bytes[2];
                    dstRow[(size_t)x * 4u + 3] = bytes[3];
                }
            }
            continue;
        }

        const uint32_t dstRowAddr =
            dstBaseaddr + (uint32_t)((uint64_t)y * (uint64_t)dstRowbytes);
        for (uint32_t x = 0; x < width; x++) {
            const uint8_t *src = srcRow + (size_t)x * 4u;
            const uint8_t b = src[0];
            const uint8_t g = src[1];
            const uint8_t r = src[2];
            const uint8_t a = src[3];

            if (dstBytesPerPixel == 2) {
                uint8_t bytes[2];
                GLOffscreenStoreRGB555Bytes(
                    GLOffscreenPackARGB1555BigEndian(r, g, b, a), bytes);
                const uint32_t dstAddr = dstRowAddr + x * 2u;
                WriteMacInt8(dstAddr + 0, bytes[0]);
                WriteMacInt8(dstAddr + 1, bytes[1]);
            } else {
                uint8_t bytes[4];
                GLOffscreenStoreARGB8888Bytes(r, g, b, a, bytes);
                const uint32_t dstAddr = dstRowAddr + x * 4u;
                WriteMacInt8(dstAddr + 0, bytes[0]);
                WriteMacInt8(dstAddr + 1, bytes[1]);
                WriteMacInt8(dstAddr + 2, bytes[2]);
                WriteMacInt8(dstAddr + 3, bytes[3]);
            }
        }
    }
}

static bool GLMetalReadbackOffscreenDrawable(GLContext *ctx,
                                             GLMetalState *ms,
                                             id<MTLCommandBuffer> committedBuffer)
{
    uint32_t dstW = 0;
    uint32_t dstH = 0;
    uint32_t dstRowbytes = 0;
    uint32_t dstBaseaddr = 0;
    uint32_t dstBytesPerPixel = 0;
    if (!GLContextGetOffscreenDrawable(ctx, &dstW, &dstH,
                                       &dstRowbytes, &dstBaseaddr, &dstBytesPerPixel)) {
        return false;
    }

    if (!ms || !ms->initialized || ms->overlayTexture == nil ||
        ms->device == nil || ms->commandQueue == nil) {
        return false;
    }

    if (committedBuffer != nil) {
        [committedBuffer waitUntilCompleted];
    }

    const uint32_t texW = (uint32_t)[ms->overlayTexture width];
    const uint32_t texH = (uint32_t)[ms->overlayTexture height];
    const uint32_t readW = std::min(dstW, texW);
    const uint32_t readH = std::min(dstH, texH);
    if (readW == 0 || readH == 0) return false;

    if (readW != dstW || readH != dstH) {
        GL_METAL_LOG("GLMetalReadbackOffscreen: texture size %ux%u smaller than offscreen %ux%u",
                     texW, texH, dstW, dstH);
    }

    MTLTextureDescriptor *stagingDesc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                          width:readW
                                                         height:readH
                                                      mipmapped:NO];
    stagingDesc.usage = MTLTextureUsageShaderRead;
    stagingDesc.storageMode = MTLStorageModeShared;
    id<MTLTexture> staging = [ms->device newTextureWithDescriptor:stagingDesc];
    if (staging == nil) {
        GL_METAL_LOG("GLMetalReadbackOffscreen: failed to allocate staging texture %ux%u",
                     readW, readH);
        return false;
    }

    id<MTLCommandBuffer> blitCmdBuf = [ms->commandQueue commandBuffer];
    if (blitCmdBuf == nil) return false;
    id<MTLBlitCommandEncoder> blit = [blitCmdBuf blitCommandEncoder];
    if (blit == nil) return false;
    [blit copyFromTexture:ms->overlayTexture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(readW, readH, 1)
                toTexture:staging
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [blitCmdBuf commit];
    [blitCmdBuf waitUntilCompleted];

    std::vector<uint8_t> bgra((size_t)readW * (size_t)readH * 4u);
    MTLRegion region = MTLRegionMake2D(0, 0, readW, readH);
    [staging getBytes:bgra.data()
          bytesPerRow:(NSUInteger)readW * 4u
           fromRegion:region
          mipmapLevel:0];

    GLMetalStoreBGRA8PixelsToGuestOffscreen(
        bgra.data(), readW, readH, dstRowbytes, dstBaseaddr,
        dstBytesPerPixel);

    GL_METAL_VLOG("GLMetalReadbackOffscreen: copied %ux%u to 0x%08x rowbytes=%u bpp=%u",
                 readW, readH, dstBaseaddr, dstRowbytes, dstBytesPerPixel * 8u);
    return true;
}

#if ACCEL_LOGGING_ENABLED
struct GLMetalTextureBGRAStats {
    uint8_t minB, minG, minR, minA;
    uint8_t maxB, maxG, maxR, maxA;
    double avgB, avgG, avgR, avgA;
    uint32_t hash;
    uint8_t first[4];
    uint8_t mid[4];
    uint8_t last[4];
};

static bool GLMetalTextureDiagnosticsShouldTrace(uint32_t texName, int level)
{
    (void)texName;
    (void)level;
    return true;
}

static bool GLMetalTextureBGRAStatsAnalyze(const uint8_t *data, int width, int height,
                                           int dataLen, GLMetalTextureBGRAStats *out)
{
    if (!data || !out || width <= 0 || height <= 0)
        return false;
    const int pixelCount = width * height;
    if (pixelCount <= 0 || dataLen < pixelCount * 4)
        return false;

    out->minB = out->minG = out->minR = out->minA = 255;
    out->maxB = out->maxG = out->maxR = out->maxA = 0;
    unsigned long long sumB = 0, sumG = 0, sumR = 0, sumA = 0;
    uint32_t hash = 2166136261u;
    const int midIndex = pixelCount / 2;

    for (int i = 0; i < pixelCount; i++) {
        const uint8_t *px = data + i * 4;
        if (i == 0) memcpy(out->first, px, 4);
        if (i == midIndex) memcpy(out->mid, px, 4);
        if (i == pixelCount - 1) memcpy(out->last, px, 4);

        if (px[0] < out->minB) out->minB = px[0]; if (px[0] > out->maxB) out->maxB = px[0]; sumB += px[0];
        if (px[1] < out->minG) out->minG = px[1]; if (px[1] > out->maxG) out->maxG = px[1]; sumG += px[1];
        if (px[2] < out->minR) out->minR = px[2]; if (px[2] > out->maxR) out->maxR = px[2]; sumR += px[2];
        if (px[3] < out->minA) out->minA = px[3]; if (px[3] > out->maxA) out->maxA = px[3]; sumA += px[3];

        for (int c = 0; c < 4; c++) {
            hash ^= px[c];
            hash *= 16777619u;
        }
    }

    out->avgB = (double)sumB / (double)pixelCount;
    out->avgG = (double)sumG / (double)pixelCount;
    out->avgR = (double)sumR / (double)pixelCount;
    out->avgA = (double)sumA / (double)pixelCount;
    out->hash = hash;
    return true;
}

static void GLMetalLogTextureBGRAStats(const char *label, uint32_t texName, int level,
                                       int width, int height, const uint8_t *data,
                                       int dataLen)
{
    GLMetalTextureBGRAStats stats;
    if (!GLMetalTextureBGRAStatsAnalyze(data, width, height, dataLen, &stats))
        return;

    GL_METAL_VLOG("%s: tex=%u level=%d %dx%d bgra min=(%u,%u,%u,%u) "
                 "max=(%u,%u,%u,%u) avg=(%.1f,%.1f,%.1f,%.1f) "
                 "first=(%u,%u,%u,%u) mid=(%u,%u,%u,%u) last=(%u,%u,%u,%u) hash=0x%08x",
                 label, texName, level, width, height,
                 stats.minB, stats.minG, stats.minR, stats.minA,
                 stats.maxB, stats.maxG, stats.maxR, stats.maxA,
                 stats.avgB, stats.avgG, stats.avgR, stats.avgA,
                 stats.first[0], stats.first[1], stats.first[2], stats.first[3],
                 stats.mid[0], stats.mid[1], stats.mid[2], stats.mid[3],
                 stats.last[0], stats.last[1], stats.last[2], stats.last[3],
                 stats.hash);
}

static void GLMetalLogDrawState(GLContext *ctx, const GLMetalVertex *verts,
                                size_t vertCount, int mtlPrim,
                                const GLMetalVertexUniforms &vu,
                                const GLMetalFragmentUniforms &fu,
                                int texUnit, int nextOffset)
{
    if (!gl_logging_enabled)
        return;

    float min_color[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    float max_color[4] = {0.0f, 0.0f, 0.0f, 0.0f};
    float min_sec[3] = {0.0f, 0.0f, 0.0f};
    float max_sec[3] = {0.0f, 0.0f, 0.0f};
    float min_pos[3] = {0.0f, 0.0f, 0.0f};
    float max_pos[3] = {0.0f, 0.0f, 0.0f};
    float min_tex0[3] = {0.0f, 0.0f, 0.0f};
    float max_tex0[3] = {0.0f, 0.0f, 0.0f};
    float min_tex1[3] = {0.0f, 0.0f, 0.0f};
    float max_tex1[3] = {0.0f, 0.0f, 0.0f};
    float min_uv0[2] = {0.0f, 0.0f};
    float max_uv0[2] = {0.0f, 0.0f};
    float min_uv1[2] = {0.0f, 0.0f};
    float max_uv1[2] = {0.0f, 0.0f};
    auto texUV = [](const float texcoord[4], int c) -> float {
        const float q = texcoord[3];
        return (q != 0.0f) ? texcoord[c] / q : texcoord[c];
    };

    if (vertCount > 0) {
        for (int c = 0; c < 4; c++) {
            min_color[c] = max_color[c] = verts[0].color[c];
        }
        for (int c = 0; c < 3; c++) {
            min_sec[c] = max_sec[c] = verts[0].secondary_color[c];
            min_pos[c] = max_pos[c] = verts[0].position[c];
            min_tex0[c] = max_tex0[c] = verts[0].texcoord[c];
            min_tex1[c] = max_tex1[c] = verts[0].texcoord1[c];
        }
        for (int c = 0; c < 2; c++) {
            min_uv0[c] = max_uv0[c] = texUV(verts[0].texcoord, c);
            min_uv1[c] = max_uv1[c] = texUV(verts[0].texcoord1, c);
        }

        for (size_t i = 1; i < vertCount; i++) {
            for (int c = 0; c < 4; c++) {
                float v = verts[i].color[c];
                if (v < min_color[c]) min_color[c] = v;
                if (v > max_color[c]) max_color[c] = v;
            }
            for (int c = 0; c < 3; c++) {
                float s = verts[i].secondary_color[c];
                if (s < min_sec[c]) min_sec[c] = s;
                if (s > max_sec[c]) max_sec[c] = s;
                float p = verts[i].position[c];
                if (p < min_pos[c]) min_pos[c] = p;
                if (p > max_pos[c]) max_pos[c] = p;
                float t0 = verts[i].texcoord[c];
                if (t0 < min_tex0[c]) min_tex0[c] = t0;
                if (t0 > max_tex0[c]) max_tex0[c] = t0;
                float t1 = verts[i].texcoord1[c];
                if (t1 < min_tex1[c]) min_tex1[c] = t1;
                if (t1 > max_tex1[c]) max_tex1[c] = t1;
            }
            for (int c = 0; c < 2; c++) {
                float uv0 = texUV(verts[i].texcoord, c);
                if (uv0 < min_uv0[c]) min_uv0[c] = uv0;
                if (uv0 > max_uv0[c]) max_uv0[c] = uv0;
                float uv1 = texUV(verts[i].texcoord1, c);
                if (uv1 < min_uv1[c]) min_uv1[c] = uv1;
                if (uv1 > max_uv1[c]) max_uv1[c] = uv1;
            }
        }
    }

	uint32_t tex0Name = fu.has_texture_3d
	    ? ctx->tex_units[texUnit].bound_texture_3d
	    : ctx->tex_units[texUnit].bound_texture_2d;
	int tex0W = 0;
	int tex0H = 0;
	uint32_t tex0MinFilter = 0;
	uint32_t tex0MagFilter = 0;
	uint32_t tex0WrapS = 0;
	uint32_t tex0WrapT = 0;
	int tex0HasMipmaps = 0;
	unsigned long tex0MetalMips = 0;
	unsigned long tex0MetalW = 0;
	unsigned long tex0MetalH = 0;
	auto tex0It = ctx->texture_objects.find(tex0Name);
	if (tex0It != ctx->texture_objects.end()) {
	    const GLTextureObject &tex0 = tex0It->second;
	    tex0W = tex0.width;
	    tex0H = tex0.height;
	    tex0MinFilter = tex0.min_filter;
	    tex0MagFilter = tex0.mag_filter;
	    tex0WrapS = tex0.wrap_s;
	    tex0WrapT = tex0.wrap_t;
	    tex0HasMipmaps = tex0.has_mipmaps ? 1 : 0;
	    if (tex0.metal_texture) {
	        id<MTLTexture> mtlTex0 = (__bridge id<MTLTexture>)(tex0.metal_texture);
	        tex0MetalMips = (unsigned long)[mtlTex0 mipmapLevelCount];
	        tex0MetalW = (unsigned long)[mtlTex0 width];
	        tex0MetalH = (unsigned long)[mtlTex0 height];
	    }
	}

	uint32_t tex1Name = ctx->tex_units[1].bound_texture_2d;
	int tex1W = 0;
	int tex1H = 0;
	uint32_t tex1MinFilter = 0;
	uint32_t tex1MagFilter = 0;
	uint32_t tex1WrapS = 0;
	uint32_t tex1WrapT = 0;
	int tex1HasMipmaps = 0;
	unsigned long tex1MetalMips = 0;
	unsigned long tex1MetalW = 0;
	unsigned long tex1MetalH = 0;
	auto tex1It = ctx->texture_objects.find(tex1Name);
	if (tex1It != ctx->texture_objects.end()) {
	    const GLTextureObject &tex1 = tex1It->second;
	    tex1W = tex1.width;
	    tex1H = tex1.height;
	    tex1MinFilter = tex1.min_filter;
	    tex1MagFilter = tex1.mag_filter;
	    tex1WrapS = tex1.wrap_s;
	    tex1WrapT = tex1.wrap_t;
	    tex1HasMipmaps = tex1.has_mipmaps ? 1 : 0;
	    if (tex1.metal_texture) {
	        id<MTLTexture> mtlTex1 = (__bridge id<MTLTexture>)(tex1.metal_texture);
	        tex1MetalMips = (unsigned long)[mtlTex1 mipmapLevelCount];
	        tex1MetalW = (unsigned long)[mtlTex1 width];
	        tex1MetalH = (unsigned long)[mtlTex1 height];
	    }
	}

    const bool isOffscreen = GLContextGetOffscreenDrawable(ctx, NULL, NULL, NULL, NULL);
    const uint32_t drawableMask =
        GLMetalDrawableColorWriteMask(isOffscreen,
                                      ctx->color_mask[0], ctx->color_mask[1],
                                      ctx->color_mask[2], ctx->color_mask[3]);

    uint32_t projectedFinite = 0;
    uint32_t projectedInside = 0;
    float min_ndc[3] = {0.0f, 0.0f, 0.0f};
    float max_ndc[3] = {0.0f, 0.0f, 0.0f};
    auto projectVertex = [&](const GLMetalVertex &v, float ndc[3],
                             bool countInside) -> bool {
        const float x = v.position[0];
        const float y = v.position[1];
        const float z = v.position[2];
        const float w = v.position[3];
        const float cx = vu.mvp_matrix[0] * x + vu.mvp_matrix[4] * y +
                         vu.mvp_matrix[8] * z + vu.mvp_matrix[12] * w;
        const float cy = vu.mvp_matrix[1] * x + vu.mvp_matrix[5] * y +
                         vu.mvp_matrix[9] * z + vu.mvp_matrix[13] * w;
        const float cz = vu.mvp_matrix[2] * x + vu.mvp_matrix[6] * y +
                         vu.mvp_matrix[10] * z + vu.mvp_matrix[14] * w;
        const float cw = vu.mvp_matrix[3] * x + vu.mvp_matrix[7] * y +
                         vu.mvp_matrix[11] * z + vu.mvp_matrix[15] * w;
        if (!std::isfinite(cx) || !std::isfinite(cy) ||
            !std::isfinite(cz) || !std::isfinite(cw) || fabsf(cw) < 1.0e-20f) {
            return false;
        }

        ndc[0] = cx / cw;
        ndc[1] = cy / cw;
        ndc[2] = cz / cw;
        const float aw = fabsf(cw);
        if (countInside &&
            fabsf(cx) <= aw && fabsf(cy) <= aw && fabsf(cz) <= aw) {
            projectedInside++;
        }
        return std::isfinite(ndc[0]) && std::isfinite(ndc[1]) && std::isfinite(ndc[2]);
    };

    for (size_t i = 0; i < vertCount; i++) {
        float ndc[3];
        if (!projectVertex(verts[i], ndc, true)) continue;
        if (projectedFinite == 0) {
            memcpy(min_ndc, ndc, sizeof(min_ndc));
            memcpy(max_ndc, ndc, sizeof(max_ndc));
        } else {
            for (int c = 0; c < 3; c++) {
                if (ndc[c] < min_ndc[c]) min_ndc[c] = ndc[c];
                if (ndc[c] > max_ndc[c]) max_ndc[c] = ndc[c];
            }
        }
        projectedFinite++;
    }

    const bool suspectQuakeForegroundModel =
        tex0Name == 1342u && (vertCount == 513 || vertCount == 216);
    if (suspectQuakeForegroundModel) {
        static uint32_t s_suspectQuakeForegroundModelLogCount = 0;
        if (s_suspectQuakeForegroundModelLogCount < 64) {
            float min_eye[4] = {0.0f, 0.0f, 0.0f, 0.0f};
            float max_eye[4] = {0.0f, 0.0f, 0.0f, 0.0f};
            float min_clip[4] = {0.0f, 0.0f, 0.0f, 0.0f};
            float max_clip[4] = {0.0f, 0.0f, 0.0f, 0.0f};
            uint32_t transformedFinite = 0;
            for (size_t i = 0; i < vertCount; i++) {
                const float x = verts[i].position[0];
                const float y = verts[i].position[1];
                const float z = verts[i].position[2];
                const float w = verts[i].position[3];
                const float eye[4] = {
                    vu.modelview_matrix[0] * x + vu.modelview_matrix[4] * y +
                        vu.modelview_matrix[8] * z + vu.modelview_matrix[12] * w,
                    vu.modelview_matrix[1] * x + vu.modelview_matrix[5] * y +
                        vu.modelview_matrix[9] * z + vu.modelview_matrix[13] * w,
                    vu.modelview_matrix[2] * x + vu.modelview_matrix[6] * y +
                        vu.modelview_matrix[10] * z + vu.modelview_matrix[14] * w,
                    vu.modelview_matrix[3] * x + vu.modelview_matrix[7] * y +
                        vu.modelview_matrix[11] * z + vu.modelview_matrix[15] * w
                };
                const float clip[4] = {
                    vu.mvp_matrix[0] * x + vu.mvp_matrix[4] * y +
                        vu.mvp_matrix[8] * z + vu.mvp_matrix[12] * w,
                    vu.mvp_matrix[1] * x + vu.mvp_matrix[5] * y +
                        vu.mvp_matrix[9] * z + vu.mvp_matrix[13] * w,
                    vu.mvp_matrix[2] * x + vu.mvp_matrix[6] * y +
                        vu.mvp_matrix[10] * z + vu.mvp_matrix[14] * w,
                    vu.mvp_matrix[3] * x + vu.mvp_matrix[7] * y +
                        vu.mvp_matrix[11] * z + vu.mvp_matrix[15] * w
                };
                bool finite = true;
                for (int c = 0; c < 4; c++) {
                    finite = finite && std::isfinite(eye[c]) && std::isfinite(clip[c]);
                }
                if (!finite) continue;
                if (transformedFinite == 0) {
                    memcpy(min_eye, eye, sizeof(min_eye));
                    memcpy(max_eye, eye, sizeof(max_eye));
                    memcpy(min_clip, clip, sizeof(min_clip));
                    memcpy(max_clip, clip, sizeof(max_clip));
                } else {
                    for (int c = 0; c < 4; c++) {
                        if (eye[c] < min_eye[c]) min_eye[c] = eye[c];
                        if (eye[c] > max_eye[c]) max_eye[c] = eye[c];
                        if (clip[c] < min_clip[c]) min_clip[c] = clip[c];
                        if (clip[c] > max_clip[c]) max_clip[c] = clip[c];
                    }
                }
                transformedFinite++;
            }

            GL_METAL_VLOG("GLMetalDrawSuspect: verts=%zu tex=%u matrixMode=0x%x mvDepth=%d projDepth=%d "
                         "activeClipPlanes=%d transformedFinite=%u eyeX %.6g..%.6g eyeY %.6g..%.6g "
                         "eyeZ %.6g..%.6g eyeW %.6g..%.6g clipX %.6g..%.6g clipY %.6g..%.6g "
                         "clipZ %.6g..%.6g clipW %.6g..%.6g",
                         vertCount, tex0Name, ctx->matrix_mode, ctx->modelview_depth,
                         ctx->projection_depth, vu.num_clip_planes, transformedFinite,
                         min_eye[0], max_eye[0], min_eye[1], max_eye[1],
                         min_eye[2], max_eye[2], min_eye[3], max_eye[3],
                         min_clip[0], max_clip[0], min_clip[1], max_clip[1],
                         min_clip[2], max_clip[2], min_clip[3], max_clip[3]);
            GL_METAL_VLOG("GLMetalDrawSuspectMatrix: verts=%zu tex=%u "
                         "mv=[%.6g %.6g %.6g %.6g | %.6g %.6g %.6g %.6g | %.6g %.6g %.6g %.6g | %.6g %.6g %.6g %.6g] "
                         "proj=[%.6g %.6g %.6g %.6g | %.6g %.6g %.6g %.6g | %.6g %.6g %.6g %.6g | %.6g %.6g %.6g %.6g] "
                         "mvp=[%.6g %.6g %.6g %.6g | %.6g %.6g %.6g %.6g | %.6g %.6g %.6g %.6g | %.6g %.6g %.6g %.6g]",
                         vertCount, tex0Name,
                         vu.modelview_matrix[0], vu.modelview_matrix[4], vu.modelview_matrix[8], vu.modelview_matrix[12],
                         vu.modelview_matrix[1], vu.modelview_matrix[5], vu.modelview_matrix[9], vu.modelview_matrix[13],
                         vu.modelview_matrix[2], vu.modelview_matrix[6], vu.modelview_matrix[10], vu.modelview_matrix[14],
                         vu.modelview_matrix[3], vu.modelview_matrix[7], vu.modelview_matrix[11], vu.modelview_matrix[15],
                         ctx->projection_stack[ctx->projection_depth][0], ctx->projection_stack[ctx->projection_depth][4], ctx->projection_stack[ctx->projection_depth][8], ctx->projection_stack[ctx->projection_depth][12],
                         ctx->projection_stack[ctx->projection_depth][1], ctx->projection_stack[ctx->projection_depth][5], ctx->projection_stack[ctx->projection_depth][9], ctx->projection_stack[ctx->projection_depth][13],
                         ctx->projection_stack[ctx->projection_depth][2], ctx->projection_stack[ctx->projection_depth][6], ctx->projection_stack[ctx->projection_depth][10], ctx->projection_stack[ctx->projection_depth][14],
                         ctx->projection_stack[ctx->projection_depth][3], ctx->projection_stack[ctx->projection_depth][7], ctx->projection_stack[ctx->projection_depth][11], ctx->projection_stack[ctx->projection_depth][15],
                         vu.mvp_matrix[0], vu.mvp_matrix[4], vu.mvp_matrix[8], vu.mvp_matrix[12],
                         vu.mvp_matrix[1], vu.mvp_matrix[5], vu.mvp_matrix[9], vu.mvp_matrix[13],
                         vu.mvp_matrix[2], vu.mvp_matrix[6], vu.mvp_matrix[10], vu.mvp_matrix[14],
                         vu.mvp_matrix[3], vu.mvp_matrix[7], vu.mvp_matrix[11], vu.mvp_matrix[15]);
            s_suspectQuakeForegroundModelLogCount++;
        }
    }

    uint32_t trisCW = 0;
    uint32_t trisCCW = 0;
    uint32_t trisDegenerate = 0;
    if (mtlPrim == (int)MTLPrimitiveTypeTriangle) {
        for (size_t i = 0; i + 2 < vertCount; i += 3) {
            float a[3], b[3], c[3];
            if (!projectVertex(verts[i], a, false) ||
                !projectVertex(verts[i + 1], b, false) ||
                !projectVertex(verts[i + 2], c, false)) {
                trisDegenerate++;
                continue;
            }
            const float area = (b[0] - a[0]) * (c[1] - a[1]) -
                               (b[1] - a[1]) * (c[0] - a[0]);
            if (fabsf(area) < 1.0e-8f) {
                trisDegenerate++;
            } else if (area > 0.0f) {
                trisCCW++;
            } else {
                trisCW++;
            }
        }
    }

    GL_METAL_VLOG("GLMetalDrawState: verts=%zu prim=%d nextOffset=%d activeTex=%d "
	             "tex0(unit=%d has=%d has3=%d en2=%d en3=%d name=%u %dx%d env=0x%x shader=%d "
	             "filter=0x%x/0x%x wrap=0x%x/0x%x mips=%d metal=%lux%lu/%lu) "
	             "tex1(has=%d en2=%d name=%u %dx%d env=0x%x shader=%d "
	             "filter=0x%x/0x%x wrap=0x%x/0x%x mips=%d metal=%lux%lu/%lu) "
                 "blend=%d src=0x%x dst=0x%x eq=0x%x alpha=%d func=0x%x ref=%.3f "
                 "depth=%d func=0x%x mask=%d lighting=%d lights=%d localViewer=%d twoSide=%d "
                 "colorSum=%d fog=%d fogMode=0x%x/%d fogRGBA=(%.3f,%.3f,%.3f,%.3f) "
                 "fogRange=(%.3f,%.3f) fogDensity=%.6f cull=%d cullMode=0x%x front=0x%x shade=0x%x "
                 "viewport=(%d,%d %dx%d) scissor=%d(%d,%d %dx%d) "
                 "colorMask=%d%d%d%d drawableMask=0x%x "
                 "arrays(v=%d c=%d ct=0x%x n=%d t0=%d t1=%d) "
                 "color(r %.3f..%.3f g %.3f..%.3f b %.3f..%.3f a %.3f..%.3f) "
                 "sec(r %.3f..%.3f g %.3f..%.3f b %.3f..%.3f) "
                 "pos(x %.3f..%.3f y %.3f..%.3f z %.3f..%.3f) "
                 "tc0(s %.3f..%.3f t %.3f..%.3f q %.3f..%.3f uv %.3f..%.3f %.3f..%.3f) "
                 "tc1(s %.3f..%.3f t %.3f..%.3f q %.3f..%.3f uv %.3f..%.3f %.3f..%.3f) "
                 "proj(finite=%u inside=%u ndcX %.3f..%.3f ndcY %.3f..%.3f ndcZ %.3f..%.3f trisCW=%u trisCCW=%u trisDeg=%u)",
                 vertCount, mtlPrim, nextOffset, ctx->active_texture,
                 texUnit, fu.has_texture, fu.has_texture_3d,
                 GLMetalTexture2DEnabledForDraw(ctx, texUnit) ? 1 : 0,
                 ctx->tex_units[texUnit].enabled_3d ? 1 : 0,
	             tex0Name, tex0W, tex0H, ctx->tex_units[texUnit].env_mode, fu.texenv_mode,
	             tex0MinFilter, tex0MagFilter, tex0WrapS, tex0WrapT,
	             tex0HasMipmaps, tex0MetalW, tex0MetalH, tex0MetalMips,
	             fu.has_texture_unit1, GLMetalTexture2DEnabledForDraw(ctx, 1) ? 1 : 0,
	             tex1Name, tex1W, tex1H, ctx->tex_units[1].env_mode, fu.texenv1_mode,
	             tex1MinFilter, tex1MagFilter, tex1WrapS, tex1WrapT,
	             tex1HasMipmaps, tex1MetalW, tex1MetalH, tex1MetalMips,
                 ctx->blend ? 1 : 0, ctx->blend_src, ctx->blend_dst, ctx->blend_equation,
                 ctx->alpha_test ? 1 : 0, ctx->alpha_func, ctx->alpha_ref,
                 ctx->depth_test ? 1 : 0, ctx->depth_func, ctx->depth_mask ? 1 : 0,
                 ctx->lighting_enabled ? 1 : 0, vu.num_active_lights,
                 ctx->light_model_local_viewer ? 1 : 0, ctx->light_model_two_side ? 1 : 0,
                 ctx->color_sum ? 1 : 0, ctx->fog_enabled ? 1 : 0,
                 ctx->fog_mode, vu.fog_mode,
                 fu.fog_color[0], fu.fog_color[1], fu.fog_color[2], fu.fog_color[3],
                 vu.fog_start, vu.fog_end, vu.fog_density,
                 ctx->cull_face_enabled ? 1 : 0, ctx->cull_face_mode,
                 ctx->front_face, ctx->shade_model,
                 ctx->viewport[0], ctx->viewport[1], ctx->viewport[2], ctx->viewport[3],
                 ctx->scissor_test ? 1 : 0,
                 ctx->scissor_box[0], ctx->scissor_box[1],
                 ctx->scissor_box[2], ctx->scissor_box[3],
                 ctx->color_mask[0] ? 1 : 0, ctx->color_mask[1] ? 1 : 0,
                 ctx->color_mask[2] ? 1 : 0, ctx->color_mask[3] ? 1 : 0,
                 drawableMask,
                 ctx->vertex_array.enabled ? 1 : 0,
                 ctx->color_array.enabled ? 1 : 0, ctx->color_array.type,
                 ctx->normal_array.enabled ? 1 : 0,
                 GLMetalTexCoordArrayAvailableForDraw(ctx, 0) ? 1 : 0,
                 GLMetalTexCoordArrayAvailableForDraw(ctx, 1) ? 1 : 0,
                 min_color[0], max_color[0], min_color[1], max_color[1],
                 min_color[2], max_color[2], min_color[3], max_color[3],
                 min_sec[0], max_sec[0], min_sec[1], max_sec[1], min_sec[2], max_sec[2],
                 min_pos[0], max_pos[0], min_pos[1], max_pos[1], min_pos[2], max_pos[2],
                 min_tex0[0], max_tex0[0], min_tex0[1], max_tex0[1],
                 min_tex0[2], max_tex0[2], min_uv0[0], max_uv0[0],
                 min_uv0[1], max_uv0[1],
                 min_tex1[0], max_tex1[0], min_tex1[1], max_tex1[1],
                 min_tex1[2], max_tex1[2], min_uv1[0], max_uv1[0],
                 min_uv1[1], max_uv1[1],
                 projectedFinite, projectedInside,
                 min_ndc[0], max_ndc[0], min_ndc[1], max_ndc[1], min_ndc[2], max_ndc[2],
                 trisCW, trisCCW, trisDegenerate);
}
#endif

static void GLMetalApplyViewportAndScissor(GLMetalState *ms, GLContext *ctx,
                                           uint32_t target_w, uint32_t target_h)
{
    if (ms->viewportScissorCacheValid &&
        ms->viewportScissorTargetWidth == target_w &&
        ms->viewportScissorTargetHeight == target_h &&
        memcmp(ms->cachedViewport, ctx->viewport, sizeof(ms->cachedViewport)) == 0 &&
        ms->cachedDepthRangeNear == ctx->depth_range_near &&
        ms->cachedDepthRangeFar == ctx->depth_range_far &&
        ms->cachedScissorTest == ctx->scissor_test &&
        memcmp(ms->cachedScissorBox, ctx->scissor_box, sizeof(ms->cachedScissorBox)) == 0) {
        return;
    }

    GLMetalViewportRect rect = GLMetalMakeViewportRect(
        ctx->viewport[0], ctx->viewport[1], ctx->viewport[2], ctx->viewport[3],
        target_h, ctx->depth_range_near, ctx->depth_range_far);

    MTLViewport vp;
    vp.originX = rect.origin_x;
    vp.originY = rect.origin_y;
    vp.width   = rect.width;
    vp.height  = rect.height;
    vp.znear   = rect.znear;
    vp.zfar    = rect.zfar;
    [ms->currentEncoder setViewport:vp];

	if (ctx->scissor_test) {
		GLMetalScissorRect converted = GLMetalMakeScissorRect(
			ctx->scissor_box[0], ctx->scissor_box[1],
			ctx->scissor_box[2], ctx->scissor_box[3],
			target_w, target_h);
        MTLScissorRect sr;
        sr.x = converted.x;
        sr.y = converted.y;
        sr.width = converted.width;
		sr.height = converted.height;
		[ms->currentEncoder setScissorRect:sr];
	} else {
		MTLScissorRect sr;
		sr.x = 0;
		sr.y = 0;
		sr.width = target_w;
		sr.height = target_h;
		[ms->currentEncoder setScissorRect:sr];
	}

    ms->viewportScissorCacheValid = true;
    ms->viewportScissorTargetWidth = target_w;
    ms->viewportScissorTargetHeight = target_h;
    memcpy(ms->cachedViewport, ctx->viewport, sizeof(ms->cachedViewport));
    ms->cachedDepthRangeNear = ctx->depth_range_near;
    ms->cachedDepthRangeFar = ctx->depth_range_far;
    ms->cachedScissorTest = ctx->scissor_test;
    memcpy(ms->cachedScissorBox, ctx->scissor_box, sizeof(ms->cachedScissorBox));
}

static void GLMetalFillPixelQuadVertices(GLMetalVertex verts[4],
                                         float ndc_x0, float ndc_y0,
                                         float ndc_x1, float ndc_y1)
{
    GLMetalPixelQuadVertex quad[4];
    GLMetalBuildPixelQuadVertices(quad, ndc_x0, ndc_y0, ndc_x1, ndc_y1);

    memset(verts, 0, sizeof(GLMetalVertex) * 4);
    for (int i = 0; i < 4; i++) {
        verts[i].position[0] = quad[i].x;
        verts[i].position[1] = quad[i].y;
        verts[i].position[2] = 0.0f;
        verts[i].position[3] = 1.0f;
        verts[i].color[0] = 1.0f;
        verts[i].color[1] = 1.0f;
        verts[i].color[2] = 1.0f;
        verts[i].color[3] = 1.0f;
        verts[i].texcoord[0] = quad[i].u;
        verts[i].texcoord[1] = quad[i].v;
        verts[i].texcoord[3] = 1.0f;
    }
}

// Keyed by (minFilter, magFilter, wrapS, wrapT); shared by all contexts.
static std::unordered_map<uint64_t, id<MTLSamplerState>> gl_sampler_cache;

// ---- Blend factor mapping ----
static MTLBlendFactor GLBlendToMetal(uint32_t gl_blend) {
    switch (gl_blend) {
        case GL_ZERO:                return MTLBlendFactorZero;
        case GL_ONE:                 return MTLBlendFactorOne;
        case GL_SRC_COLOR:           return MTLBlendFactorSourceColor;
        case GL_ONE_MINUS_SRC_COLOR: return MTLBlendFactorOneMinusSourceColor;
        case GL_SRC_ALPHA:           return MTLBlendFactorSourceAlpha;
        case GL_ONE_MINUS_SRC_ALPHA: return MTLBlendFactorOneMinusSourceAlpha;
        case GL_DST_ALPHA:           return MTLBlendFactorDestinationAlpha;
        case GL_ONE_MINUS_DST_ALPHA: return MTLBlendFactorOneMinusDestinationAlpha;
        case GL_DST_COLOR:           return MTLBlendFactorDestinationColor;
        case GL_ONE_MINUS_DST_COLOR: return MTLBlendFactorOneMinusDestinationColor;
        case GL_SRC_ALPHA_SATURATE:  return MTLBlendFactorSourceAlphaSaturated;
        // EXT_blend_color
        case GL_CONSTANT_COLOR:           return MTLBlendFactorBlendColor;
        case GL_ONE_MINUS_CONSTANT_COLOR: return MTLBlendFactorOneMinusBlendColor;
        case GL_CONSTANT_ALPHA:           return MTLBlendFactorBlendAlpha;
        case GL_ONE_MINUS_CONSTANT_ALPHA: return MTLBlendFactorOneMinusBlendAlpha;
        default:                     return MTLBlendFactorOne;
    }
}


// ---- Blend equation mapping ----
// Metal Min/Max ignore the blend factors, which matches GL_MIN/GL_MAX.
static MTLBlendOperation GLBlendEquationToMetal(uint32_t eq) {
    switch (eq) {
        case GL_FUNC_ADD:              return MTLBlendOperationAdd;
        case GL_FUNC_SUBTRACT:         return MTLBlendOperationSubtract;
        case GL_FUNC_REVERSE_SUBTRACT: return MTLBlendOperationReverseSubtract;
        case GL_MIN:                   return MTLBlendOperationMin;
        case GL_MAX:                   return MTLBlendOperationMax;
        default:                       return MTLBlendOperationAdd;
    }
}


// ---- Depth compare function mapping ----
static MTLCompareFunction GLDepthFuncToMetal(uint32_t gl_func) {
    switch (gl_func) {
        case GL_NEVER:    return MTLCompareFunctionNever;
        case GL_LESS:     return MTLCompareFunctionLess;
        case GL_EQUAL:    return MTLCompareFunctionEqual;
        case GL_LEQUAL:   return MTLCompareFunctionLessEqual;
        case GL_GREATER:  return MTLCompareFunctionGreater;
        case GL_NOTEQUAL: return MTLCompareFunctionNotEqual;
        case GL_GEQUAL:   return MTLCompareFunctionGreaterEqual;
        case GL_ALWAYS:   return MTLCompareFunctionAlways;
        default:          return MTLCompareFunctionLess;
    }
}


// ---- Stencil operation mapping ----
static MTLStencilOperation GLStencilOpToMetal(uint32_t gl_op) {
    switch (gl_op) {
        case GL_KEEP:            return MTLStencilOperationKeep;
        case 0x0000:             return MTLStencilOperationZero;  // GL_ZERO
        case GL_REPLACE_STENCIL: return MTLStencilOperationReplace;
        case GL_INCR:            return MTLStencilOperationIncrementClamp;
        case GL_DECR:            return MTLStencilOperationDecrementClamp;
        case GL_INVERT_STENCIL:  return MTLStencilOperationInvert;
        case GL_INCR_WRAP:       return MTLStencilOperationIncrementWrap;
        case GL_DECR_WRAP:       return MTLStencilOperationDecrementWrap;
        default:                 return MTLStencilOperationKeep;
    }
}


// ---- Pipeline state key ----
// Must cover everything baked into the pipeline descriptor, including the blend
// equation. Depth, stencil and cull are encoder state and keyed separately.
static uint64_t MakePipelineKey(bool blend_enabled, uint32_t blend_src, uint32_t blend_dst,
                                 bool depth_write, uint32_t color_mask_bits, bool has_texture,
                                 uint32_t blend_equation, bool is_offscreen) {
    uint64_t key = 0;
    key |= (blend_enabled ? 1ULL : 0);
    // Preserve the full GL tokens: CONSTANT_COLOR (0x8001) and ONE (1)
    // must never share a pipeline, for either source or destination.
    key |= ((uint64_t)(blend_src & 0xFFFF)) << 1;
    key |= ((uint64_t)(blend_dst & 0xFFFF)) << 17;
    key |= (depth_write ? 1ULL : 0) << 33;
    key |= ((uint64_t)(color_mask_bits & 0xF)) << 34;
    key |= (has_texture ? 1ULL : 0) << 38;
    key |= ((uint64_t)(blend_equation & 0xFFFF)) << 39;
    key |= (is_offscreen ? 1ULL : 0) << 55;
    return key;
}


// ---- Depth stencil state key ----
static uint64_t MakeDepthStencilKey(GLContext *ctx) {
    uint64_t key = 0;
    key |= (ctx->depth_test ? 1ULL : 0);
    key |= ((ctx->depth_mask ? 1ULL : 0) << 1);
    key |= ((uint64_t)(ctx->depth_func & 0xFF) << 2);
    key |= ((ctx->stencil_test ? 1ULL : 0) << 10);
    key |= ((uint64_t)(ctx->stencil.func & 0xFF) << 11);
    key |= ((uint64_t)(ctx->stencil.ref & 0xFF) << 19);
    key |= ((uint64_t)(ctx->stencil.value_mask & 0xFF) << 27);
    key |= ((uint64_t)(ctx->stencil.write_mask & 0xFF) << 35);
    // Raw GL tokens share low bits (GL_KEEP=0x1e00, GL_ZERO=0).
    // Metal's compact operation values uniquely identify all eight operations.
    key |= ((uint64_t)GLStencilOpToMetal(ctx->stencil.sfail) << 43);
    key |= ((uint64_t)GLStencilOpToMetal(ctx->stencil.dpfail) << 47);
    key |= ((uint64_t)GLStencilOpToMetal(ctx->stencil.dppass) << 51);
    return key;
}


void GLMetalInit(GLContext *ctx)
{
    if (ctx->metal) return;

    // Do not memset: GLMetalState holds C++ containers and ARC ids. Value
    // initialization already zeroes the POD fields.
    GLMetalState *ms = new GLMetalState();
    ms->initialized = false;
    ms->currentBufferIndex = 0;
    ms->bufferOffset = 0;
    ms->ringSemaphore = NULL;
    ms->ringSlotAcquired = false;
    ms->ringSlotsInCommandBuffer = 0;
    ms->renderPassActive = false;

    // Shared device from the compositor
    ms->device = (__bridge id<MTLDevice>)SharedMetalDevice();
    if (!ms->device) {
        GL_METAL_LOG("GLMetalInit: SharedMetalDevice failed");
        delete ms;
        return;
    }

    ms->framebufferFetch = [ms->device supportsFamily:MTLGPUFamilyApple1];

    if (ms->device == (__bridge id<MTLDevice>)SharedMetalDevice()) {
        ms->commandQueue = (__bridge id<MTLCommandQueue>)SharedMetalCommandQueue();
    } else {
        ms->commandQueue = [ms->device newCommandQueue];
    }

    NSError *err = nil;
    NSString *libPath = [[NSBundle mainBundle] pathForResource:@"gl_shaders" ofType:@"metallib"];
    if (libPath) {
        ms->shaderLibrary = [ms->device newLibraryWithFile:libPath error:&err];
    }
    if (!ms->shaderLibrary) {
        ms->shaderLibrary = [ms->device newDefaultLibrary];
    }
    if (!ms->shaderLibrary) {
        GL_METAL_LOG("GLMetalInit: failed to load shader library: %s",
                     err ? [[err localizedDescription] UTF8String] : "unknown");
        delete ms;
        return;
    }

    // Matches GLMetalVertex
    ms->vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
    ms->vertexDescriptor.attributes[0].format = MTLVertexFormatFloat4;
    ms->vertexDescriptor.attributes[0].offset = offsetof(GLMetalVertex, position);
    ms->vertexDescriptor.attributes[0].bufferIndex = 0;
    ms->vertexDescriptor.attributes[1].format = MTLVertexFormatFloat4;
    ms->vertexDescriptor.attributes[1].offset = offsetof(GLMetalVertex, color);
    ms->vertexDescriptor.attributes[1].bufferIndex = 0;
    ms->vertexDescriptor.attributes[2].format = MTLVertexFormatFloat3;
    ms->vertexDescriptor.attributes[2].offset = offsetof(GLMetalVertex, normal);
    ms->vertexDescriptor.attributes[2].bufferIndex = 0;
    ms->vertexDescriptor.attributes[3].format = MTLVertexFormatFloat4;
    ms->vertexDescriptor.attributes[3].offset = offsetof(GLMetalVertex, texcoord);
    ms->vertexDescriptor.attributes[3].bufferIndex = 0;

    ms->vertexDescriptor.attributes[4].format = MTLVertexFormatFloat4;  // texcoord unit 1
    ms->vertexDescriptor.attributes[4].offset = offsetof(GLMetalVertex, texcoord1);
    ms->vertexDescriptor.attributes[4].bufferIndex = 0;

    ms->vertexDescriptor.attributes[5].format = MTLVertexFormatFloat3;  // secondary color
    ms->vertexDescriptor.attributes[5].offset = offsetof(GLMetalVertex, secondary_color);
    ms->vertexDescriptor.attributes[5].bufferIndex = 0;

    ms->vertexDescriptor.attributes[6].format = MTLVertexFormatFloat4;
    ms->vertexDescriptor.attributes[6].offset = offsetof(GLMetalVertex, lighting_position);
    ms->vertexDescriptor.attributes[6].bufferIndex = 0;

    // Materials are per-vertex attributes, so material changes inside
    // Begin/End and the flat-shading provoking material survive batching.
    for (int face=0;face<2;++face) for(int term=0;term<5;++term) {
        const int attribute=7+face*5+term;
        ms->vertexDescriptor.attributes[attribute].format = term==4 ? MTLVertexFormatFloat : MTLVertexFormatFloat4;
        ms->vertexDescriptor.attributes[attribute].offset = offsetof(GLMetalVertex,material)+face*sizeof(GLMaterial)+term*16;
        ms->vertexDescriptor.attributes[attribute].bufferIndex = 0;
    }
    ms->vertexDescriptor.attributes[17].format=MTLVertexFormatFloat;
    ms->vertexDescriptor.attributes[17].offset=offsetof(GLMetalVertex,stipple_distance);
    ms->vertexDescriptor.attributes[17].bufferIndex=0;
    ms->vertexDescriptor.layouts[0].stride = sizeof(GLMetalVertex);

    // Long-lived buffers come from the device, not the placement heap: they
    // outlive mode-exit resets.
    for (int i = 0; i < GL_RING_BUFFER_COUNT; i++) {
        ms->vertexBuffers[i] = [ms->device newBufferWithLength:GL_RING_BUFFER_SIZE
                                                        options:MTLResourceStorageModeShared];
        if (!ms->vertexBuffers[i]) {
            GL_METAL_LOG("device alloc failed for GL ring buffer %d", i);
        }
    }
    ms->currentBufferIndex = 0;
    ms->bufferOffset = 0;
    ms->ringSemaphore = dispatch_semaphore_create(GL_RING_BUFFER_COUNT);
    ms->ringSlotAcquired = false;
    ms->ringSlotsInCommandBuffer = 0;

    ms->vertexUniformBuffer = [ms->device newBufferWithLength:sizeof(GLMetalVertexUniforms)
                                                      options:MTLResourceStorageModeShared];
    if (!ms->vertexUniformBuffer) {
        GL_METAL_LOG("device alloc failed for GL vertex uniform buffer");
    }
    ms->fragmentUniformBuffer = [ms->device newBufferWithLength:sizeof(GLMetalFragmentUniforms)
                                                        options:MTLResourceStorageModeShared];
    if (!ms->fragmentUniformBuffer) {
        GL_METAL_LOG("device alloc failed for GL fragment uniform buffer");
    }
    ms->lightUniformBuffer = [ms->device newBufferWithLength:sizeof(GLMetalLightingData)
                                                     options:MTLResourceStorageModeShared];
    if (!ms->lightUniformBuffer) {
        GL_METAL_LOG("device alloc failed for GL light uniform buffer");
    }

    MTLSamplerDescriptor *sampDesc = [[MTLSamplerDescriptor alloc] init];
    sampDesc.minFilter = MTLSamplerMinMagFilterLinear;
    sampDesc.magFilter = MTLSamplerMinMagFilterLinear;
    sampDesc.sAddressMode = MTLSamplerAddressModeRepeat;
    sampDesc.tAddressMode = MTLSamplerAddressModeRepeat;
    ms->linearSampler = [ms->device newSamplerStateWithDescriptor:sampDesc];

    sampDesc.minFilter = MTLSamplerMinMagFilterNearest;
    sampDesc.magFilter = MTLSamplerMinMagFilterNearest;
    ms->nearestSampler = [ms->device newSamplerStateWithDescriptor:sampDesc];

    // Some games (Madden 2000) keep binding deleted texture names, which ATI's
    // driver tolerated. Binding white lets vertex colors show through.
    {
        MTLTextureDescriptor *fbDesc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:1 height:1 mipmapped:NO];
        fbDesc.usage = MTLTextureUsageShaderRead;
        ms->fallbackWhiteTexture = [ms->device newTextureWithDescriptor:fbDesc];
        if (ms->fallbackWhiteTexture) {
            uint32_t white = 0xFFFFFFFF;
            MTLRegion rgn = MTLRegionMake2D(0, 0, 1, 1);
            [ms->fallbackWhiteTexture replaceRegion:rgn mipmapLevel:0 withBytes:&white bytesPerRow:4];
        }
    }

    ms->initialized = true;
    ctx->shared_objects->destroy_texture = GLMetalDestroyTexture;
    ctx->metal = (void *)ms;

    GL_METAL_LOG("GLMetalInit: success (device=%p queue=%p lib=%p)",
                 ms->device, ms->commandQueue, ms->shaderLibrary);
}


static void GLMetalConfigurePresentationDraw(GLMetalState *ms, GLContext *ctx)
{
    struct { uint32_t values[8]; float blendColor[4]; } state = {
        {ctx->blend ? 1u : 0u, ctx->blend_src, ctx->blend_dst, ctx->blend_equation,
         ctx->color_logic_op ? 1u : 0u, ctx->logic_op_mode, 0, 0}, {0,0,0,0}};
    memcpy(state.blendColor, ctx->blend_color, sizeof(state.blendColor));
    [ms->currentEncoder setFragmentBytes:&state length:sizeof(state) atIndex:4];
}

// Native color attachments retain GL RGBA. Presentation attachments have their
// own coverage alpha and are manually blended against retained snapshots.
static void GLMetalConfigureColorPipelineAttachments(MTLRenderPipelineDescriptor *desc,
    GLContext *ctx, bool offscreen, unsigned colorMask, unsigned targets)
{
    MTLColorWriteMask mask =
        ((colorMask & 1u) ? MTLColorWriteMaskRed : MTLColorWriteMaskNone) |
        ((colorMask & 2u) ? MTLColorWriteMaskGreen : MTLColorWriteMaskNone) |
        ((colorMask & 4u) ? MTLColorWriteMaskBlue : MTLColorWriteMaskNone) |
        ((colorMask & 8u) ? MTLColorWriteMaskAlpha : MTLColorWriteMaskNone);
    for (int i = 0; i < 2; ++i) {
        auto attachment = desc.colorAttachments[i];
        attachment.pixelFormat = MTLPixelFormatBGRA8Unorm;
        attachment.writeMask = targets & (1u << i) ? mask : MTLColorWriteMaskNone;
        attachment.blendingEnabled = ctx->blend && !ctx->color_logic_op;
        if (attachment.blendingEnabled) {
            attachment.rgbBlendOperation = GLBlendEquationToMetal(ctx->blend_equation);
            attachment.alphaBlendOperation = attachment.rgbBlendOperation;
            attachment.sourceRGBBlendFactor = GLBlendToMetal(ctx->blend_src);
            attachment.destinationRGBBlendFactor = GLBlendToMetal(ctx->blend_dst);
            attachment.sourceAlphaBlendFactor = GLBlendToMetal(ctx->blend_src);
            attachment.destinationAlphaBlendFactor = GLBlendToMetal(ctx->blend_dst);
        }
        if (!offscreen) {
            auto presentation = desc.colorAttachments[i + 2];
            presentation.pixelFormat = MTLPixelFormatBGRA8Unorm;
            // Alpha-only GL writes cannot change visible coverage.
            presentation.writeMask = targets & (1u << i)
                ? (MTLColorWriteMask)((mask & ~MTLColorWriteMaskAlpha) | ((colorMask & 7u) ? MTLColorWriteMaskAlpha : MTLColorWriteMaskNone))
                : MTLColorWriteMaskNone;
            presentation.blendingEnabled = NO;
        }
    }
}

static id<MTLRenderPipelineState> GLMetalGetPipeline(GLMetalState *ms, GLContext *ctx) {
    bool blend_enabled = ctx->blend;
    uint32_t blend_src = ctx->blend_src;
    uint32_t blend_dst = ctx->blend_dst;
    bool depth_write = ctx->depth_mask;
    const bool isOffscreen = GLContextGetOffscreenDrawable(ctx, NULL, NULL, NULL, NULL);
    uint32_t color_mask_bits = GLMetalDrawableColorWriteMask(isOffscreen,
                                                             ctx->color_mask[0],
                                                             ctx->color_mask[1],
                                                             ctx->color_mask[2],
                                                             ctx->color_mask[3]);
    int texUnit = GLMetalPrimaryTextureUnitForDraw(ctx->active_texture);
    const uint32_t target = GLTextureUnitTarget(ctx->tex_units[texUnit],
        GLMetalTexture2DEnabledForDraw(ctx, texUnit));
    bool has_texture = target != 0 && GLBoundTextureObject(ctx, texUnit, target) != nullptr;

    uint64_t key = MakePipelineKey(blend_enabled, blend_src, blend_dst,
                                    depth_write, color_mask_bits, has_texture,
                                    ctx->blend_equation, isOffscreen) | (uint64_t(GLMetalDrawTargets(ctx)) << 56) | (uint64_t(ctx->color_logic_op) << 58);

    auto it = ms->pipelineCache.find(key);
    if (it != ms->pipelineCache.end()) return it->second;

    NSError *err = nil;
    id<MTLFunction> vertexFunc = [ms->shaderLibrary newFunctionWithName:@"gl_vertex_main"];
    NSString *fragmentName = isOffscreen
        ? (ms->framebufferFetch ? @"gl_fragment_main_fetch" : @"gl_fragment_main")
        : (ms->framebufferFetch ? @"gl_fragment_present_fetch" : @"gl_fragment_present");
    id<MTLFunction> fragmentFunc = [ms->shaderLibrary newFunctionWithName:fragmentName];
    if (!vertexFunc || !fragmentFunc) {
        GL_METAL_LOG("GLMetalGetPipeline: shader function lookup failed");
        return nil;
    }

    MTLRenderPipelineDescriptor *pipeDesc = [[MTLRenderPipelineDescriptor alloc] init];
    pipeDesc.vertexFunction = vertexFunc;
    pipeDesc.fragmentFunction = fragmentFunc;
    pipeDesc.vertexDescriptor = ms->vertexDescriptor;
    pipeDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pipeDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    pipeDesc.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;

    GLMetalConfigureColorPipelineAttachments(pipeDesc, ctx, isOffscreen,
        color_mask_bits, GLMetalDrawTargets(ctx));

    id<MTLRenderPipelineState> pipeline = [ms->device newRenderPipelineStateWithDescriptor:pipeDesc error:&err];
    if (!pipeline) {
        GL_METAL_LOG("GLMetalGetPipeline: creation failed: %s",
                     [[err localizedDescription] UTF8String]);
        return nil;
    }

    ms->pipelineCache[key] = pipeline;
    GL_METAL_LOG("GLMetalGetPipeline: created pipeline key=0x%llx (cache size=%zu)",
                 key, ms->pipelineCache.size());
    return pipeline;
}


static id<MTLDepthStencilState> GLMetalCreateDepthStencilState(GLMetalState *ms, GLContext *ctx) {
    uint64_t key = MakeDepthStencilKey(ctx);

    auto it = ms->depthStencilCache.find(key);
    if (it != ms->depthStencilCache.end()) return it->second;

    MTLDepthStencilDescriptor *desc = [[MTLDepthStencilDescriptor alloc] init];
    // Orthographic projections also render depth-tested 3D scenes. Projection
    // and blending cannot override the guest's depth function or write mask;
    // offscreen clients can consume that depth to composite into their 2D world.
    if (ctx->depth_test) {
        desc.depthCompareFunction = GLDepthFuncToMetal(ctx->depth_func);
        desc.depthWriteEnabled = ctx->depth_mask ? YES : NO;
    } else {
        desc.depthCompareFunction = MTLCompareFunctionAlways;
        desc.depthWriteEnabled = NO;
    }

    if (ctx->stencil_test) {
        MTLStencilDescriptor *stencilDesc = [[MTLStencilDescriptor alloc] init];
        stencilDesc.stencilCompareFunction = GLDepthFuncToMetal(ctx->stencil.func);
        stencilDesc.readMask = ctx->stencil.value_mask & 0xFF;
        stencilDesc.writeMask = ctx->stencil.write_mask & 0xFF;
        stencilDesc.stencilFailureOperation = GLStencilOpToMetal(ctx->stencil.sfail);
        stencilDesc.depthFailureOperation = GLStencilOpToMetal(ctx->stencil.dpfail);
        stencilDesc.depthStencilPassOperation = GLStencilOpToMetal(ctx->stencil.dppass);
        desc.frontFaceStencil = stencilDesc;
        desc.backFaceStencil = stencilDesc;
        GL_METAL_LOG("GLMetalCreateDepthStencilState: stencil enabled func=0x%x ref=%d vmask=0x%x wmask=0x%x sfail=0x%x dpfail=0x%x dppass=0x%x",
                     ctx->stencil.func, ctx->stencil.ref, ctx->stencil.value_mask,
                     ctx->stencil.write_mask, ctx->stencil.sfail, ctx->stencil.dpfail, ctx->stencil.dppass);
    }

    id<MTLDepthStencilState> state = [ms->device newDepthStencilStateWithDescriptor:desc];
    ms->depthStencilCache[key] = state;
    return state;
}


static void mat4_multiply(float *out, const float *a, const float *b) {
    float tmp[16];
    for (int r = 0; r < 4; r++) {
        for (int c = 0; c < 4; c++) {
            tmp[c * 4 + r] = a[0 * 4 + r] * b[c * 4 + 0] +
                              a[1 * 4 + r] * b[c * 4 + 1] +
                              a[2 * 4 + r] * b[c * 4 + 2] +
                              a[3 * 4 + r] * b[c * 4 + 3];
        }
    }
    memcpy(out, tmp, sizeof(float) * 16);
}

/*
 *  Normal matrix: inverse transpose of the modelview's upper-left 3x3, written
 *  as Metal float3x3 (3 columns padded to float4, 12 floats).
 */
static void compute_normal_matrix(float *out12, const float *mv) {
    float a = mv[0], b = mv[4], c = mv[8];
    float d = mv[1], e = mv[5], f = mv[9];
    float g = mv[2], h = mv[6], k = mv[10];

    float det = a * (e * k - f * h) - b * (d * k - f * g) + c * (d * h - e * g);
    if (fabsf(det) < 1e-12f) det = 1.0f;
    float inv_det = 1.0f / det;

    // inverse = adjugate / det
    float inv[9];
    inv[0] = (e * k - f * h) * inv_det;
    inv[1] = (c * h - b * k) * inv_det;
    inv[2] = (b * f - c * e) * inv_det;
    inv[3] = (f * g - d * k) * inv_det;
    inv[4] = (a * k - c * g) * inv_det;
    inv[5] = (c * d - a * f) * inv_det;
    inv[6] = (d * h - e * g) * inv_det;
    inv[7] = (b * g - a * h) * inv_det;
    inv[8] = (a * e - b * d) * inv_det;

    // inv is row-major. Each row becomes a column of inverse-transpose;
    // Metal pads each float3 column to four floats.
    out12[0] = inv[0]; out12[1] = inv[1]; out12[2] = inv[2]; out12[3] = 0.0f;
    out12[4] = inv[3]; out12[5] = inv[4]; out12[6] = inv[5]; out12[7] = 0.0f;
    out12[8] = inv[6]; out12[9] = inv[7]; out12[10] = inv[8]; out12[11] = 0.0f;
}


static void EnsureDepthBuffer(GLMetalState *ms, int width, int height) {
    if (ms->depthBuffer &&
        (int)[ms->depthBuffer width] == width &&
        (int)[ms->depthBuffer height] == height) {
        return;
    }

    MTLTextureDescriptor *depthDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                     width:width
                                    height:height
                                 mipmapped:NO];
    depthDesc.storageMode = MTLStorageModePrivate;
    depthDesc.usage = MTLTextureUsageRenderTarget;
    ms->depthBuffer = [ms->device newTextureWithDescriptor:depthDesc];

    GL_METAL_LOG("EnsureDepthBuffer: created %dx%d depth+stencil buffer (Depth32Float_Stencil8)", width, height);
}


// AGL offscreen drawables are caller-owned memory, not persistent GPU pbuffers.
// Import their current pixels at each CPU/GPU handoff, including same-size
// rebindings. Flush/Finish read them back before returning to the guest.
static bool GLMetalUploadGuestOffscreenDrawable(GLMetalState *ms,
                                                uint32_t width, uint32_t height,
                                                uint32_t rowbytes, uint32_t baseaddr,
                                                uint32_t bytesPerPixel)
{
    NQDMetalFlush(); // finish QuickDraw writes to guest memory first
    if (ms->lastCommittedBuffer) [ms->lastCommittedBuffer waitUntilCompleted];

    ms->offscreenUploadPixels.resize((size_t)width * height * 4u);
    if (!GLOffscreenLoadGuestPixelsToBGRA8(Mac2HostAddr(baseaddr), width, height,
                                          rowbytes, bytesPerPixel,
                                          ms->offscreenUploadPixels.data()))
        return false;

    if (!ms->offscreenUploadTexture || ms->offscreenUploadTexture.width != width ||
        ms->offscreenUploadTexture.height != height) {
        MTLTextureDescriptor *desc = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                         width:width height:height mipmapped:NO];
        desc.storageMode = MTLStorageModeShared;
        desc.usage = MTLTextureUsageShaderRead;
        ms->offscreenUploadTexture = [ms->device newTextureWithDescriptor:desc];
    }
    if (!ms->offscreenUploadTexture) return false;
    [ms->offscreenUploadTexture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                                  mipmapLevel:0
                                    withBytes:ms->offscreenUploadPixels.data()
                                  bytesPerRow:(NSUInteger)width * 4u];
    id<MTLBlitCommandEncoder> blit = [ms->currentCommandBuffer blitCommandEncoder];
    if (!blit) return false;
    [blit copyFromTexture:ms->offscreenUploadTexture sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(width, height, 1)
                toTexture:ms->overlayTexture destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    return true;
}

void GLMetalBeginFrame(GLContext *ctx)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->initialized) return;

    if (ms->renderPassActive) return;

    // Render over the full drawable. The GL viewport/scissor restrict draws
    // inside that surface; they never resize the presentation layer. Offscreen
    // targets are context-private and cannot replace an onscreen cached frame.
    uint32_t offscreenW = 0;
    uint32_t offscreenH = 0;
    uint32_t offscreenRowbytes = 0;
    uint32_t offscreenBaseaddr = 0;
    uint32_t offscreenBytesPerPixel = 0;
    const bool isOffscreen =
        GLContextGetOffscreenDrawable(ctx, &offscreenW, &offscreenH,
                                     &offscreenRowbytes, &offscreenBaseaddr, &offscreenBytesPerPixel);
    auto binding = s_gl_overlays.find(ctx);
    if (!isOffscreen && binding == s_gl_overlays.end()) return;
    uint32_t drawableW = isOffscreen ? offscreenW : (uint32_t)binding->second.width;
    uint32_t drawableH = isOffscreen ? offscreenH : (uint32_t)binding->second.height;
    const GLMetalRenderTargetSize targetSize = GLMetalChooseRenderTargetSize(
        isOffscreen, drawableW, drawableH,
        (uint32_t)ctx->viewport[2], (uint32_t)ctx->viewport[3]);
    const int w = (int)targetSize.width;
    const int h = (int)targetSize.height;
    id<MTLTexture> nextOverlay = nil;
    if (isOffscreen) {
        if (!ms->offscreenTexture || ms->offscreenTexture.width != drawableW ||
            ms->offscreenTexture.height != drawableH)
            ms->offscreenTexture = gl_new_render_target(drawableW, drawableH);
        nextOverlay = ms->offscreenTexture;
        ms->presentationTexture = nil;
        ms->presentationBackTexture = nil;
        if (!ms->backTexture || ms->backTexture.width != drawableW || ms->backTexture.height != drawableH)
            ms->backTexture = gl_new_render_target(drawableW, drawableH);
    } else {
        if (!gl_claim_display_for_overlay()) return;
        nextOverlay = gl_acquire_overlay_texture(binding->second);
        ms->backTexture = binding->second.pair[1];
        ms->presentationTexture = binding->second.presentation[0];
        ms->presentationBackTexture = binding->second.presentation[1];
    }
    if (!nextOverlay) return;

    const bool loadColor = isOffscreen || !binding->second.needs_clear;
    if (!isOffscreen) binding->second.needs_clear = false;
    ms->overlayTexture = nextOverlay;
    const bool loadDepthStencil = ms->depthBuffer &&
        (int)ms->depthBuffer.width == w && (int)ms->depthBuffer.height == h;
    EnsureDepthBuffer(ms, w, h);

    ms->currentCommandBuffer = [ms->commandQueue commandBuffer];
    if (!ms->currentCommandBuffer ||
        (isOffscreen && !GLMetalUploadGuestOffscreenDrawable(
            ms, offscreenW, offscreenH, offscreenRowbytes, offscreenBaseaddr,
            offscreenBytesPerPixel))) {
        ms->currentCommandBuffer = nil;
        if (!ctx->last_error) ctx->last_error = 0x0505; // GL_OUT_OF_MEMORY
        return;
    }

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    GLMetalSetColorAttachments(rpd, ms);
    const float clearAlpha = GLMetalOverlayClearAlpha(isOffscreen, ctx->clear_color[3]);
    const float coverageAlpha = OverlayClearEffectiveAlpha(isOffscreen, ctx->clear_color[3]);
    const MTLClearColor clearColor = MTLClearColorMake(
        GLMetalOverlayClearColorComponent(isOffscreen, ctx->clear_color[0], clearAlpha),
        GLMetalOverlayClearColorComponent(isOffscreen, ctx->clear_color[1], clearAlpha),
        GLMetalOverlayClearColorComponent(isOffscreen, ctx->clear_color[2], clearAlpha), clearAlpha);
    for (int i = 0; i < 2; ++i) {
        rpd.colorAttachments[i].loadAction = loadColor ? MTLLoadActionLoad : MTLLoadActionClear;
        rpd.colorAttachments[i].clearColor = clearColor;
    }

    if (ms->presentationTexture) {
        for (int i = 2; i < 4; ++i) {
            rpd.colorAttachments[i].loadAction = loadColor ? MTLLoadActionLoad : MTLLoadActionClear;
            rpd.colorAttachments[i].clearColor = MTLClearColorMake(
                ctx->clear_color[0] * coverageAlpha, ctx->clear_color[1] * coverageAlpha,
                ctx->clear_color[2] * coverageAlpha, coverageAlpha);
        }
    }
    rpd.depthAttachment.texture = ms->depthBuffer;
    rpd.depthAttachment.loadAction = loadDepthStencil ? MTLLoadActionLoad : MTLLoadActionClear;
    rpd.depthAttachment.storeAction =
        GLMetalDepthAttachmentShouldStoreForReadback()
            ? MTLStoreActionStore
            : MTLStoreActionDontCare;
    rpd.depthAttachment.clearDepth = ctx->clear_depth;

    rpd.stencilAttachment.texture = ms->depthBuffer;
    rpd.stencilAttachment.loadAction = loadDepthStencil ? MTLLoadActionLoad : MTLLoadActionClear;
    rpd.stencilAttachment.storeAction = MTLStoreActionStore;
    rpd.stencilAttachment.clearStencil = ctx->clear_stencil;

	ms->currentEncoder = [ms->currentCommandBuffer renderCommandEncoderWithDescriptor:rpd];
	ms->viewportScissorCacheValid = false;

	GLMetalApplyViewportAndScissor(ms, ctx, (uint32_t)w, (uint32_t)h);

    ms->renderPassActive = true;
    ms->bufferOffset = 0;

    GL_METAL_VLOG("GLMetalBeginFrame: encoder=%p overlayTexture=%p target=%dx%d viewport=(%d,%d %dx%d) offscreen=%d drawable=%ux%u",
                 ms->currentEncoder, ms->overlayTexture, w, h,
                 ctx->viewport[0], ctx->viewport[1],
                 ctx->viewport[2], ctx->viewport[3],
	                 isOffscreen ? 1 : 0, offscreenW, offscreenH);
}

static id<MTLRenderPipelineState> GLMetalGetClearPipeline(GLMetalState *ms,
                                                        unsigned colorMask, unsigned targets, bool presentation)
{
    const unsigned key = colorMask | (targets << 4) | (presentation ? 64u : 0u);
    auto found = ms->clearPipelineCache.find(key);
    if (found != ms->clearPipelineCache.end()) return found->second;

    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = [ms->shaderLibrary newFunctionWithName:@"gl_clear_vertex"];
    desc.fragmentFunction = [ms->shaderLibrary newFunctionWithName:presentation ? @"gl_clear_present_fragment" : @"gl_clear_fragment"];
    if (!desc.vertexFunction || !desc.fragmentFunction) return nil;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    desc.colorAttachments[0].writeMask =
        ((colorMask & 1) ? MTLColorWriteMaskRed : MTLColorWriteMaskNone) |
        ((colorMask & 2) ? MTLColorWriteMaskGreen : MTLColorWriteMaskNone) |
        ((colorMask & 4) ? MTLColorWriteMaskBlue : MTLColorWriteMaskNone) |
        ((colorMask & 8) ? MTLColorWriteMaskAlpha : MTLColorWriteMaskNone);
    desc.colorAttachments[1] = [desc.colorAttachments[0] copy];
    if (!(targets & 1)) desc.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
    if (!(targets & 2)) desc.colorAttachments[1].writeMask = MTLColorWriteMaskNone;
    if (presentation) {
        for (int i = 0; i < 2; ++i) {
            desc.colorAttachments[i + 2] = [desc.colorAttachments[i] copy];
            if (targets & (1u << i)) {
                auto attachment = desc.colorAttachments[i + 2];
                attachment.writeMask &= ~MTLColorWriteMaskAlpha;
                if (colorMask & 7u) attachment.writeMask |= MTLColorWriteMaskAlpha;
            }
        }
    }
    desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    desc.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline =
        [ms->device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!pipeline) {
        GL_METAL_LOG("GL clear pipeline failed: %s", error.localizedDescription.UTF8String);
        return nil;
    }
    ms->clearPipelineCache[key] = pipeline;
    return pipeline;
}

// Attachment load-action clears ignore the scissor and all write masks.
// A fullscreen triangle supplies those semantics without disturbing pixels
// or stencil bits outside the requested clear.
static bool GLMetalDrawMaskedClear(GLContext *ctx, uint32_t mask)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    const uint32_t width = (uint32_t)ms->overlayTexture.width;
    const uint32_t height = (uint32_t)ms->overlayTexture.height;
    GLMetalScissorRect rect = {0, 0, width, height, true};
    if (ctx->scissor_test) {
        rect = GLMetalMakeScissorRect(ctx->scissor_box[0], ctx->scissor_box[1],
                                     ctx->scissor_box[2], ctx->scissor_box[3],
                                     width, height);
    }
    if (!rect.valid) return true;

    const unsigned colorMask = GLShouldClearColorAttachment(mask)
        ? GLMetalGuestColorWriteMask(ctx->color_mask[0], ctx->color_mask[1],
                                    ctx->color_mask[2], ctx->color_mask[3]) : 0;
    const bool depthWrite = GLShouldClearDepthAttachment(mask);
    const unsigned stencilMask = GLShouldClearStencilAttachment(mask)
        ? (ctx->stencil.write_mask & 0xffu) : 0;
    id<MTLRenderPipelineState> pipeline = GLMetalGetClearPipeline(ms, colorMask, GLMetalDrawTargets(ctx), ms->presentationTexture != nil);
    if (!pipeline) return false;

    const unsigned key = (depthWrite ? 1u : 0u) | (stencilMask << 1);
    id<MTLDepthStencilState> depthState;
    auto found = ms->clearDepthStencilCache.find(key);
    if (found != ms->clearDepthStencilCache.end()) {
        depthState = found->second;
    } else {
        MTLDepthStencilDescriptor *desc = [[MTLDepthStencilDescriptor alloc] init];
        desc.depthCompareFunction = MTLCompareFunctionAlways;
        desc.depthWriteEnabled = depthWrite;
        if (stencilMask) {
            MTLStencilDescriptor *stencil = [[MTLStencilDescriptor alloc] init];
            stencil.stencilCompareFunction = MTLCompareFunctionAlways;
            stencil.depthStencilPassOperation = MTLStencilOperationReplace;
            stencil.readMask = 0xff;
            stencil.writeMask = stencilMask;
            desc.frontFaceStencil = stencil;
            desc.backFaceStencil = stencil;
        }
        depthState = [ms->device newDepthStencilStateWithDescriptor:desc];
        if (!depthState) return false;
        ms->clearDepthStencilCache[key] = depthState;
    }

    const bool offscreen = GLContextGetOffscreenDrawable(ctx, NULL, NULL, NULL, NULL);
    const float alpha = GLMetalOverlayClearAlpha(offscreen, ctx->clear_color[3]);
    const float coverageAlpha = OverlayClearEffectiveAlpha(offscreen, ctx->clear_color[3]);
    const float values[12] = {
        GLMetalOverlayClearColorComponent(offscreen, ctx->clear_color[0], alpha),
        GLMetalOverlayClearColorComponent(offscreen, ctx->clear_color[1], alpha),
        GLMetalOverlayClearColorComponent(offscreen, ctx->clear_color[2], alpha), alpha,
        std::max(0.0f, std::min(1.0f, ctx->clear_depth)), 0, 0, 0,
        ctx->clear_color[0] * coverageAlpha, ctx->clear_color[1] * coverageAlpha,
        ctx->clear_color[2] * coverageAlpha, coverageAlpha
    };
    const MTLViewport viewport = {0, 0, (double)width, (double)height, 0, 1};
    const MTLScissorRect scissor = {rect.x, rect.y, rect.width, rect.height};
    [ms->currentEncoder setRenderPipelineState:pipeline];
    [ms->currentEncoder setDepthStencilState:depthState];
    [ms->currentEncoder setStencilReferenceValue:(uint32_t)ctx->clear_stencil & 0xffu];
    [ms->currentEncoder setViewport:viewport];
    [ms->currentEncoder setScissorRect:scissor];
    [ms->currentEncoder setCullMode:MTLCullModeNone];
    [ms->currentEncoder setDepthBias:0 slopeScale:0 clamp:0];
    [ms->currentEncoder setVertexBytes:values length:sizeof(values) atIndex:0];
    [ms->currentEncoder setFragmentBytes:values length:sizeof(values) atIndex:0];
    [ms->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    if (colorMask) gl_note_front_modified(ctx, ms->overlayTexture);
    // The next ordinary draw must restore the guest viewport and scissor.
    ms->viewportScissorCacheValid = false;
    return true;
}

void GLMetalClear(GLContext *ctx, uint32_t mask)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->initialized) return;
    if (!ctx->depth_mask) mask &= ~0x00000100u;
    if (!(ctx->stencil.write_mask & 0xffu)) mask &= ~0x00000400u;
    const unsigned colorMask = GLMetalGuestColorWriteMask(
        ctx->color_mask[0], ctx->color_mask[1], ctx->color_mask[2], ctx->color_mask[3]);
    if (!colorMask || !GLMetalDrawTargets(ctx)) mask &= ~0x00004000u;
    if (!GLShouldApplyAttachmentClear(mask)) return;
    if (ctx->scissor_test && (ctx->scissor_box[2] <= 0 || ctx->scissor_box[3] <= 0)) return;

    if (!ms->renderPassActive) {
        GLMetalBeginFrame(ctx);
        if (!ms->renderPassActive) return;
    }

    if (!ms->overlayTexture || !ms->currentCommandBuffer) {
        GL_METAL_LOG("GLMetalClear: missing active target for mask=0x%x", mask);
        return;
    }

    const bool clearColor = GLShouldClearColorAttachment(mask);
    const bool clearDepth = GLShouldClearDepthAttachment(mask);
    const bool clearStencil = GLShouldClearStencilAttachment(mask);
    if (ctx->scissor_test || (clearColor && colorMask != 0xfu) ||
        (clearStencil && (ctx->stencil.write_mask & 0xffu) != 0xffu)) {
        if (!GLMetalDrawMaskedClear(ctx, mask) && !ctx->last_error)
            ctx->last_error = 0x0505; // GL_OUT_OF_MEMORY
        return;
    }
    const uint32_t targetW = (uint32_t)[ms->overlayTexture width];
    const uint32_t targetH = (uint32_t)[ms->overlayTexture height];

    if ((clearDepth || clearStencil) && !ms->depthBuffer) {
        EnsureDepthBuffer(ms, (int)targetW, (int)targetH);
    }

    if (ms->currentEncoder) {
        [ms->currentEncoder endEncoding];
        ms->currentEncoder = nil;
    }

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    GLMetalSetColorAttachments(rpd, ms);
    const unsigned targets = GLMetalDrawTargets(ctx);
    for (int i = 0; i < 2; ++i)
        rpd.colorAttachments[i].loadAction = clearColor && (targets & (1u << i))
            ? MTLLoadActionClear : MTLLoadActionLoad;

    uint32_t offscreenW = 0;
    uint32_t offscreenH = 0;
    const bool isOffscreen =
        GLContextGetOffscreenDrawable(ctx, &offscreenW, &offscreenH, NULL, NULL);
    const float clearAlpha =
        GLMetalOverlayClearAlpha(isOffscreen, ctx->clear_color[3]);
    const float coverageAlpha = OverlayClearEffectiveAlpha(isOffscreen, ctx->clear_color[3]);
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(
        GLMetalOverlayClearColorComponent(isOffscreen,
                                          ctx->clear_color[0], clearAlpha),
        GLMetalOverlayClearColorComponent(isOffscreen,
                                          ctx->clear_color[1], clearAlpha),
        GLMetalOverlayClearColorComponent(isOffscreen,
                                          ctx->clear_color[2], clearAlpha),
        clearAlpha
    );

    rpd.colorAttachments[1].clearColor = rpd.colorAttachments[0].clearColor;
    if (ms->presentationTexture) {
        for (int i = 0; i < 2; ++i) {
            rpd.colorAttachments[i + 2].loadAction = clearColor && (targets & (1u << i))
                ? MTLLoadActionClear : MTLLoadActionLoad;
            rpd.colorAttachments[i + 2].clearColor = MTLClearColorMake(
                ctx->clear_color[0] * coverageAlpha, ctx->clear_color[1] * coverageAlpha,
                ctx->clear_color[2] * coverageAlpha, coverageAlpha);
        }
    }

    if (ms->depthBuffer) {
        rpd.depthAttachment.texture = ms->depthBuffer;
        rpd.depthAttachment.loadAction = clearDepth ? MTLLoadActionClear : MTLLoadActionLoad;
        rpd.depthAttachment.storeAction = MTLStoreActionStore;
        rpd.depthAttachment.clearDepth = ctx->clear_depth;

        rpd.stencilAttachment.texture = ms->depthBuffer;
        rpd.stencilAttachment.loadAction = clearStencil ? MTLLoadActionClear : MTLLoadActionLoad;
        rpd.stencilAttachment.storeAction = MTLStoreActionStore;
        rpd.stencilAttachment.clearStencil = ctx->clear_stencil;
    }

	ms->currentEncoder = [ms->currentCommandBuffer renderCommandEncoderWithDescriptor:rpd];
	ms->viewportScissorCacheValid = false;
	if (!ms->currentEncoder) {
		GL_METAL_LOG("GLMetalClear: failed to restart encoder for mask=0x%x", mask);
        ms->renderPassActive = false;
        return;
    }

    GLMetalApplyViewportAndScissor(ms, ctx, targetW, targetH);

    if (clearColor) gl_note_front_modified(ctx, ms->overlayTexture);
    GL_METAL_VLOG("GLMetalClear: mask=0x%x color=%d depth=%d stencil=%d viewport=(%d,%d %dx%d)",
                 mask, clearColor ? 1 : 0, clearDepth ? 1 : 0, clearStencil ? 1 : 0,
                 ctx->viewport[0], ctx->viewport[1], ctx->viewport[2], ctx->viewport[3]);
}


static int32_t GLFogModeToShader(uint32_t gl_mode) {
    switch (gl_mode) {
        case GL_LINEAR: return 1;
        case GL_EXP:    return 2;
        case GL_EXP2:   return 3;
        default:        return 0;
    }
}


/*
 *  Material term that tracks the vertex color under GL_COLOR_MATERIAL, as the
 *  shader's 0..5 code. The face selector applies to front and back separately.
 */
static int32_t GLColorMaterialToShader(const GLContext *ctx, int face) {
    if (!ctx->lighting_enabled || !ctx->color_material_enabled) return 0;
    const uint32_t materialFace = face == 0 ? 0x0404 : 0x0405;
    if (ctx->color_material_face != 0x0408 && ctx->color_material_face != materialFace) return 0;
    switch (ctx->color_material_mode) {
        case 0x1200: return 1;  // GL_AMBIENT
        case 0x1201: return 2;  // GL_DIFFUSE
        case 0x1202: return 3;  // GL_SPECULAR
        case 0x1600: return 4;  // GL_EMISSION
        case 0x1602: return 5;  // GL_AMBIENT_AND_DIFFUSE
        default:     return 0;
    }
}

static bool GLMetalTwoSideLightingForDraw(const GLContext *ctx)
{
    // GL uses front lighting for points and lines, regardless of TWO_SIDE.
    return ctx->lighting_enabled && ctx->light_model_two_side &&
           ctx->im_mode >= 0x0004 && ctx->im_mode <= 0x0009;
}

static void GLMetalFillLightingData(GLMetalLightingData &data, const GLContext *ctx)
{
    data = {};
    for (int i = 0; i < 8; ++i) {
        auto &out = data.lights[i];
        const auto &in = ctx->lights[i];
        memcpy(out.ambient, in.ambient, sizeof(out.ambient));
        memcpy(out.diffuse, in.diffuse, sizeof(out.diffuse));
        memcpy(out.specular, in.specular, sizeof(out.specular));
        memcpy(out.position, in.position, sizeof(out.position));
        memcpy(out.spot_direction, in.spot_direction, sizeof(in.spot_direction));
        out.spot_exponent = in.spot_exponent;
        out.spot_cutoff = in.spot_cutoff >= 180.0f ? -1.0f :
            cosf(in.spot_cutoff * float(M_PI / 180.0));
        out.constant_atten = in.constant_attenuation;
        out.linear_atten = in.linear_attenuation;
        out.quadratic_atten = in.quadratic_attenuation;
        out.enabled = in.enabled ? 1 : 0;
    }
    for (int face = 0; face < 2; ++face) {
        auto &out = face == 0 ? data.material : data.back_material;
        const auto &in = ctx->materials[face];
        memcpy(out.ambient, in.ambient, sizeof(out.ambient));
        memcpy(out.diffuse, in.diffuse, sizeof(out.diffuse));
        memcpy(out.specular, in.specular, sizeof(out.specular));
        memcpy(out.emission, in.emission, sizeof(out.emission));
        out.shininess = in.shininess;
        out.color_material = GLColorMaterialToShader(ctx, face);
    }
    memcpy(data.global_ambient, ctx->light_model_ambient, sizeof(data.global_ambient));
    data.local_viewer = ctx->light_model_local_viewer ? 1 : 0;
}


// GL_NEVER..GL_ALWAYS (0x0200-0x0207) -> shader 0-7
static int32_t GLAlphaFuncToShader(uint32_t gl_func) {
    if (gl_func >= GL_NEVER && gl_func <= GL_ALWAYS) {
        return (int32_t)(gl_func - GL_NEVER);
    }
    return 7;  // GL_ALWAYS
}


/*
 *  Mid-frame flush when the ring is full: commit, rotate to the next ring
 *  slot, and reopen the pass with load actions. Only viewport and scissor are
 *  restored; the caller sets all other per-draw state afterwards. Returns
 *  false if the caller should skip the draw.
 */
static bool GLMetalFlushAndResetRingBuffer(GLContext *ctx)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;

    GL_METAL_LOG("GLMetalFlushAndResetRingBuffer: ring buffer full (offset=%d/%d), flushing mid-frame",
                 ms->bufferOffset, GL_RING_BUFFER_SIZE);

    if (ms->currentEncoder) {
        [ms->currentEncoder endEncoding];
        ms->currentEncoder = nil;
    }

    // Ring slot reuse is gated by the completion handler; no CPU wait.
    if (ms->currentCommandBuffer) {
        GLMetalCommitCommandBuffer(ms, ms->currentCommandBuffer);
        ms->lastCommittedBuffer = ms->currentCommandBuffer;
        ms->currentCommandBuffer = nil;
    }

    // The commit rotated the ring slot; reset the offset regardless.
    ms->bufferOffset = 0;

    ms->currentCommandBuffer = [ms->commandQueue commandBuffer];
    if (!ms->currentCommandBuffer) {
        GL_METAL_LOG("GLMetalFlushAndResetRingBuffer: failed to create new command buffer");
        return false;
    }

    // Load all attachments to keep the frame so far
    if (!ms->overlayTexture) {
        GL_METAL_LOG("GLMetalFlushAndResetRingBuffer: no overlay texture, cannot restart encoder");
        return false;
    }

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    GLMetalSetColorAttachments(rpd, ms);

    if (ms->depthBuffer) {
        rpd.depthAttachment.texture = ms->depthBuffer;
        rpd.depthAttachment.loadAction = MTLLoadActionLoad;
        rpd.depthAttachment.storeAction = MTLStoreActionStore;
        rpd.stencilAttachment.texture = ms->depthBuffer;
        rpd.stencilAttachment.loadAction = MTLLoadActionLoad;
        rpd.stencilAttachment.storeAction = MTLStoreActionStore;
    }

	ms->currentEncoder = [ms->currentCommandBuffer renderCommandEncoderWithDescriptor:rpd];
	ms->viewportScissorCacheValid = false;
	if (!ms->currentEncoder) {
		GL_METAL_LOG("GLMetalFlushAndResetRingBuffer: failed to create new encoder");
        return false;
    }

    GLMetalApplyViewportAndScissor(ms, ctx,
                                   (uint32_t)[ms->overlayTexture width],
                                   (uint32_t)[ms->overlayTexture height]);

    GL_METAL_LOG("GLMetalFlushAndResetRingBuffer: mid-frame flush complete, encoder restarted");
    return true;
}


// Destination-dependent operations read a snapshot from immediately before
// this primitive. Separate encoders impose GPU ordering without a CPU wait.
struct GLMetalDestinationSnapshot { id<MTLTexture> texture[4] = {nil,nil,nil,nil}; };
static bool GLMetalSnapshotLogicDestinations(GLMetalState *ms,GLContext *ctx,GLMetalDestinationSnapshot &snapshot)
{
    id<MTLTexture> sources[4]={ms->overlayTexture,ms->backTexture,ms->presentationTexture,ms->presentationBackTexture};
    for(int i=0;i<4;++i)if(sources[i]) {
        MTLTextureDescriptor *descriptor=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:sources[i].pixelFormat width:sources[i].width height:sources[i].height mipmapped:NO];
        descriptor.storageMode=MTLStorageModePrivate;descriptor.usage=MTLTextureUsageShaderRead;
        if(!ms->destinationSnapshots[i] || ms->destinationSnapshots[i].width!=sources[i].width ||
           ms->destinationSnapshots[i].height!=sources[i].height || ms->destinationSnapshots[i].pixelFormat!=sources[i].pixelFormat)
            ms->destinationSnapshots[i]=[ms->device newTextureWithDescriptor:descriptor];
        snapshot.texture[i]=ms->destinationSnapshots[i];
        if(!snapshot.texture[i]) {if(!ctx->last_error)ctx->last_error=0x0505;return false;}
    }
    [ms->currentEncoder endEncoding];ms->currentEncoder=nil;
    id<MTLBlitCommandEncoder> blit=[ms->currentCommandBuffer blitCommandEncoder];
    for(int i=0;i<4;++i)if(sources[i]) [blit copyFromTexture:sources[i] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(sources[i].width,sources[i].height,1) toTexture:snapshot.texture[i] destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [blit endEncoding];
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];GLMetalSetColorAttachments(pass,ms);
    pass.depthAttachment.texture=ms->depthBuffer;pass.depthAttachment.loadAction=MTLLoadActionLoad;pass.depthAttachment.storeAction=MTLStoreActionStore;
    pass.stencilAttachment.texture=ms->depthBuffer;pass.stencilAttachment.loadAction=MTLLoadActionLoad;pass.stencilAttachment.storeAction=MTLStoreActionStore;
    ms->currentEncoder=[ms->currentCommandBuffer renderCommandEncoderWithDescriptor:pass];ms->viewportScissorCacheValid=false;
    GLMetalApplyViewportAndScissor(ms,ctx,(uint32_t)ms->overlayTexture.width,(uint32_t)ms->overlayTexture.height);
    return ms->currentEncoder!=nil;
}

static void GLMetalSubmitVertices(GLContext *ctx,
    const std::vector<uint32_t> *indices = nullptr,
    MTLPrimitiveType indexedPrimitive = MTLPrimitiveTypeTriangle,
    bool primitiveBoundary = false, float stippleBase = 0, uint32_t polygonRasterMode = 0)
{
    if (GLProcessRenderMode(ctx)) return;
    if (ctx->im_mode>=4 && ctx->cull_face_enabled && ctx->cull_face_mode==0x0408) return;
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->initialized) return;
    if (ctx->im_vertices.empty()) return;

	if (!ms->renderPassActive) {
		GLMetalBeginFrame(ctx);
		if (!ms->renderPassActive) return;
	}
	if (ms->overlayTexture) {
		GLMetalApplyViewportAndScissor(ms, ctx,
		                               (uint32_t)[ms->overlayTexture width],
		                               (uint32_t)[ms->overlayTexture height]);
	}

    if(ctx->im_mode>=4 && (ctx->polygon_mode_front!=0x1b02 || ctx->polygon_mode_back!=0x1b02)) {
        auto original=std::move(ctx->im_vertices);const auto originalMode=ctx->im_mode;
        std::vector<GLMetalVertex> converted;GLConvertDrawVertices(*ctx,original,converted);
        const bool lighting=ctx->lighting_enabled,culling=ctx->cull_face_enabled;
        const auto shade=ctx->shade_model;
        GLTextureUnit units[2]={ctx->tex_units[0],ctx->tex_units[1]};
        float textureMatrices[2][16];
        for(int u=0;u<2;++u)memcpy(textureMatrices[u],ctx->texture_stack[u][ctx->texture_depth[u]],64);
        GLVisitPrimitiveIndices(originalMode,original.size(),[&](const std::vector<size_t> &order,bool,bool) {
            std::vector<GLContractVertex> polygon;for(size_t index:order){auto v=GLContractTransform(*ctx,converted[index]);v.edge=original[index].edge_flag;polygon.push_back(v);}
            GLContractClip(*ctx,polygon,true);if(polygon.size()<3)return;
            bool front=GLContractFrontFacing(*ctx,polygon);if(GLContractCulled(*ctx,front))return;
            uint32_t mode=front?ctx->polygon_mode_front:ctx->polygon_mode_back;
            if(mode==0x1b02) {
                auto fillOrder=order;
                if(originalMode==8)std::rotate(fillOrder.begin(),fillOrder.begin()+3,fillOrder.end());
                ctx->im_vertices.clear();for(size_t index:fillOrder)ctx->im_vertices.push_back(original[index]);
                auto frontMode=ctx->polygon_mode_front,backMode=ctx->polygon_mode_back;
                ctx->polygon_mode_front=ctx->polygon_mode_back=0x1b02;ctx->im_mode=originalMode==9?9:order.size()==3?4:7;
                GLMetalSubmitVertices(ctx,nullptr,MTLPrimitiveTypeTriangle,true);
                ctx->polygon_mode_front=frontMode;ctx->polygon_mode_back=backMode;return;
            }
            // Light original vertices before clipping; generated boundary
            // vertices interpolate those colors, as fixed-function GL does.
            polygon.clear();size_t provoking=originalMode==9?order.front():originalMode==8?order[order.size()-2]:order.back();
            for(size_t index:order) {
                auto raster=converted[index];
                if(shade==GL_FLAT){memcpy(raster.color,converted[provoking].color,16);memcpy(raster.material,converted[provoking].material,sizeof(raster.material));memcpy(raster.normal,converted[provoking].normal,sizeof(raster.normal));memcpy(raster.lighting_position,converted[provoking].lighting_position,16);}
                GLContractLight(*ctx,raster,(!front && ctx->light_model_two_side)?1:0,raster.color);
                auto v=GLContractTransform(*ctx,raster);v.edge=original[index].edge_flag;polygon.push_back(v);
            }
            GLContractClip(*ctx,polygon,true);if(polygon.empty())return;
            ctx->lighting_enabled=false;ctx->cull_face_enabled=false;ctx->shade_model=GL_SMOOTH;
            for(int u=0;u<2;++u){auto &unit=ctx->tex_units[u];unit.texgen_s_enabled=unit.texgen_t_enabled=unit.texgen_r_enabled=unit.texgen_q_enabled=false;
                auto matrix=ctx->texture_stack[u][ctx->texture_depth[u]];for(int k=0;k<16;++k)matrix[k]=(k%5==0)?1:0;}
            auto vertex=[](const GLContractVertex &v){GLVertex out{};memcpy(out.position,v.raster.position,16);memcpy(out.color,v.raster.color,16);memcpy(out.normal,v.raster.normal,12);memcpy(out.texcoord[0],v.raster.texcoord,16);memcpy(out.texcoord[1],v.raster.texcoord1,16);memcpy(out.secondary_color,v.raster.secondary_color,12);return out;};
            ctx->im_mode=mode==0x1b00?0:1;
            float polygonPhase=0;
            for(size_t i=0;i<polygon.size();++i)if(polygon[i].edge) {
                ctx->im_vertices={vertex(polygon[i])};if(mode==0x1b01)ctx->im_vertices.push_back(vertex(polygon[(i+1)%polygon.size()]));
                GLMetalSubmitVertices(ctx,nullptr,MTLPrimitiveTypeTriangle,true,polygonPhase,mode);
                if(mode==0x1b01)polygonPhase+=GLLineRasterLength(*ctx,polygon[i].raster,polygon[(i+1)%polygon.size()].raster);
            }
            ctx->lighting_enabled=lighting;ctx->cull_face_enabled=culling;ctx->shade_model=shade;
            for(int u=0;u<2;++u){ctx->tex_units[u]=units[u];memcpy(ctx->texture_stack[u][ctx->texture_depth[u]],textureMatrices[u],64);}
        });
        ctx->im_vertices=std::move(original);ctx->im_mode=originalMode;return;
    }

    const bool snapshotRequired=!ms->framebufferFetch && (ctx->color_logic_op || (ms->presentationTexture && ctx->blend));
    if(snapshotRequired && !primitiveBoundary) {
        // Keep original primitive order: overlapping primitives must observe
        // previous writes, including when they arrived in a single Begin/End.
        auto saved=std::move(ctx->im_vertices);const auto mode=ctx->im_mode;
        std::vector<GLMetalVertex> lineVertices;GLConvertDrawVertices(*ctx,saved,lineVertices);float linePhase=stippleBase;
        GLVisitPrimitiveIndices(mode,saved.size(),[&](const std::vector<size_t> &original,bool polygon,bool reset) {
            if(reset)linePhase=stippleBase;
            auto order=original;
            if(polygon && mode!=9) {size_t provoking=mode==8?order[order.size()-2]:order.back();auto at=std::find(order.begin(),order.end(),provoking);std::rotate(order.begin(),at,order.end());}
            ctx->im_vertices.clear();for(size_t index:order)ctx->im_vertices.push_back(saved[index]);
            ctx->im_mode=polygon?9:order.size()==1?0:1;
            GLMetalSubmitVertices(ctx,nullptr,MTLPrimitiveTypeTriangle,true,linePhase);
            if(!polygon && original.size()==2)linePhase+=GLLineRasterLength(*ctx,lineVertices[original[0]],lineVertices[original[1]]);
        });
        ctx->im_mode=mode;ctx->im_vertices=std::move(saved);return;
    }

    // Convert texture generation/matrices once per draw, before topology
    // expansion. Indexed smooth draws retain their shared vertex storage.
    auto &converted = ms->imConvertScratch;
    auto &expandedVerts = ms->imExpandScratch;
    GLConvertDrawVertices(*ctx, ctx->im_vertices, converted);
    GLPrepareLineStipple(*ctx,converted,stippleBase);
    GLDrawPrimitive primitive;
    const bool expanded = !indices && GLExpandDrawPrimitives(ctx->im_mode,
        ctx->shade_model == GL_FLAT, converted, expandedVerts, primitive);
    MTLPrimitiveType mtlPrim = indexedPrimitive;
    if (!indices) {
        switch (primitive) {
        case GLDrawPrimitive::Point: mtlPrim=MTLPrimitiveTypePoint; break;
        case GLDrawPrimitive::Line: mtlPrim=MTLPrimitiveTypeLine; break;
        case GLDrawPrimitive::LineStrip: mtlPrim=MTLPrimitiveTypeLineStrip; break;
        case GLDrawPrimitive::Triangle: mtlPrim=MTLPrimitiveTypeTriangle; break;
        case GLDrawPrimitive::TriangleStrip: mtlPrim=MTLPrimitiveTypeTriangleStrip; break;
        }
    }
    if(expanded && ctx->im_mode==2 && expandedVerts.size()>=2)
        expandedVerts.back().stipple_distance=converted.back().stipple_distance+GLLineRasterLength(*ctx,converted.back(),converted.front());
    auto &drawVertices = expanded ? expandedVerts : converted;
    const GLMetalVertex *vertData = drawVertices.data();
    const size_t vertCount = drawVertices.size();
    if (vertCount == 0) return;

    const float *mv = ctx->modelview_stack[ctx->modelview_depth];
    const float *proj = ctx->projection_stack[ctx->projection_depth];
    float mvp[16];
    mat4_multiply(mvp, proj, mv);
    const int texUnit = GLMetalPrimaryTextureUnitForDraw(ctx->active_texture);
    const uint32_t primaryTarget = GLTextureUnitTarget(ctx->tex_units[texUnit],
        GLMetalTexture2DEnabledForDraw(ctx, texUnit));
    GLTextureObject *primaryTexture = GLBoundTextureObject(ctx, texUnit, primaryTarget);
    const bool hasPrimaryTexture = primaryTarget != 0 && primaryTexture != nullptr;
    const uint32_t secondaryTarget = GLTextureUnitTarget(ctx->tex_units[1],
        GLMetalTexture2DEnabledForDraw(ctx, 1));
    GLTextureObject *secondaryTexture = GLBoundTextureObject(ctx, 1, secondaryTarget);
    const size_t vertBytes = vertCount * sizeof(GLMetalVertex);
    const size_t indexRelativeOffset = (vertBytes + 255u) & ~size_t(255u);
    const size_t indexBytes = indices ? indices->size() * sizeof(uint32_t) : 0;
    const size_t stagingBytes = indices ? indexRelativeOffset + indexBytes : vertBytes;
    const bool overflow = stagingBytes > GL_RING_BUFFER_SIZE;
    id<MTLBuffer> vb;
    NSUInteger vertexOffset = 0;
    if (overflow) {
        // Command buffers retain their resources. An oversized draw therefore
        // owns this allocation until completion, without changing strip/fan
        // boundaries or silently discarding geometry at the ring-size limit.
        if (stagingBytes > ms->device.maxBufferLength) {
            if (!ctx->last_error) ctx->last_error = 0x0505; // OUT_OF_MEMORY
            return;
        }
        vb = [ms->device newBufferWithLength:stagingBytes options:MTLResourceStorageModeShared];
    } else {
        if (!GLMetalEnsureRingSlot(ms)) return;
        if (size_t(ms->bufferOffset) + stagingBytes > GL_RING_BUFFER_SIZE) {
            if (!GLMetalFlushAndResetRingBuffer(ctx) || !GLMetalEnsureRingSlot(ms)) return;
        }
        vb = ms->vertexBuffers[ms->currentBufferIndex];
        vertexOffset = (NSUInteger)ms->bufferOffset;
    }
    if (!vb) {
        if (!ctx->last_error) ctx->last_error = 0x0505;
        return;
    }
    memcpy((uint8_t *)vb.contents + vertexOffset, vertData, vertBytes);
    const NSUInteger indexOffset = vertexOffset + indexRelativeOffset;
    if (indices) memcpy((uint8_t *)vb.contents + indexOffset, indices->data(), indexBytes);

    // ---- Upload vertex uniforms ----
    const bool fogActiveForDraw = ctx->fog_enabled;
    GLMetalVertexUniforms vu;
    memcpy(vu.mvp_matrix, mvp, sizeof(float) * 16);
    memcpy(vu.modelview_matrix, mv, sizeof(float) * 16);
    compute_normal_matrix(vu.normal_matrix, mv);
    vu.lighting_enabled = ctx->lighting_enabled ? 1 : 0;
    vu.normalize_enabled = ctx->normalize ? 1 : 0;
    vu.num_active_lights = 0;
    for (int i = 0; i < 8; i++) {
        if (ctx->lights[i].enabled) vu.num_active_lights++;
    }
    vu.fog_enabled = fogActiveForDraw ? 1 : 0;
    vu.fog_mode = fogActiveForDraw ? GLFogModeToShader(ctx->fog_mode) : 0;
    vu.fog_start = ctx->fog_start;
    vu.fog_end = ctx->fog_end;
    vu.fog_density = ctx->fog_density;
    vu.point_size = ctx->point_size;
    vu.two_side_lighting = GLMetalTwoSideLightingForDraw(ctx) ? 1 : 0;

    // ---- User clip planes ----
    int nClipPlanes = 0;
    memset(vu.clip_planes, 0, sizeof(vu.clip_planes));
    memset(vu._clip_pad, 0, sizeof(vu._clip_pad));
    for (int i = 0; i < 6; i++) {
        if (ctx->clip_plane_enabled[i]) {
            GLMetalCopyClipPlaneToUniform(vu.clip_planes[nClipPlanes], ctx->clip_planes[i]);
            nClipPlanes++;
        }
    }
    vu.num_clip_planes = nClipPlanes;

    // ---- Upload fragment uniforms ----
    GLMetalFragmentUniforms fu;
    GLMetalSetTextureEnvironments(fu, *ctx);
    if (fogActiveForDraw) {
        memcpy(fu.fog_color, ctx->fog_color, sizeof(float) * 4);
    } else {
        fu.fog_color[0] = fu.fog_color[1] = fu.fog_color[2] = 0.0f;
        fu.fog_color[3] = -1.0f;  // fog off
    }
    fu.alpha_test_enabled = ctx->alpha_test ? 1 : 0;
    fu.alpha_func = GLAlphaFuncToShader(ctx->alpha_func);
    fu.alpha_ref = ctx->alpha_ref;
    fu.has_texture = hasPrimaryTexture ? 1 : 0;
    fu.has_texture_3d = primaryTarget == 0x806f ? 1 : 0;
    fu.has_texture_1d = primaryTarget == 0x0de0 ? 1 : 0;
    fu.tex_format = primaryTexture ? GLTextureLevelBaseFormat(*primaryTexture, 0) : 0x1908;
    fu.tex1_format = secondaryTexture ? GLTextureLevelBaseFormat(*secondaryTexture, 0) : 0x1908;
    fu.shade_model = (ctx->shade_model == GL_SMOOTH) ? 1 : 0;
    fu.framebuffer_height=(int32_t)ms->overlayTexture.height;
    fu.polygon_stipple_enabled=ctx->polygon_stipple_enabled && ctx->im_mode>=4;
    fu.line_stipple_enabled=ctx->line_stipple_enabled && ctx->im_mode>=1 && ctx->im_mode<=3;
    fu.color_sum_enabled = ctx->color_sum ? 1 : 0;
    // Each unit chooses its enabled target independently. 1D images use a
    // height-one Metal texture, with T ignored in the fragment shader.
    fu.has_texture_unit1 = (secondaryTarget == 0x0de0 || secondaryTarget == 0x0de1 || secondaryTarget == 0x806f) &&
        secondaryTexture != nullptr;
    fu.has_texture_unit1_1d = secondaryTarget == 0x0de0;
    fu.has_texture_unit1_3d = secondaryTarget == 0x806f;
    {
        const bool isOffscreen =
            GLContextGetOffscreenDrawable(ctx, NULL, NULL, NULL, NULL);
        fu.force_opaque_output =
            GLMetalForceOpaqueOverlayOutput(isOffscreen, ctx->blend) ? 1 : 0;
    }

    // ---- Upload lighting data ----
    GLMetalLightingData ld_val;
    GLMetalFillLightingData(ld_val, ctx);
    GLMetalLightingData *ld = &ld_val;

    id<MTLRenderPipelineState> pipeline = GLMetalGetPipeline(ms, ctx);
    if (!pipeline) return;

    id<MTLDepthStencilState> dsState = GLMetalCreateDepthStencilState(ms, ctx);

    GLMetalDestinationSnapshot snapshot;
    if(snapshotRequired && !GLMetalSnapshotLogicDestinations(ms,ctx,snapshot))return;
    for(int i=0;i<4;++i)[ms->currentEncoder setFragmentTexture:snapshot.texture[i] ?: ms->fallbackWhiteTexture atIndex:3+i];
    GLMetalConfigurePresentationDraw(ms,ctx);

    // ---- Encode draw call ----
    [ms->currentEncoder setRenderPipelineState:pipeline];
    [ms->currentEncoder setDepthStencilState:dsState];

    if (ctx->stencil_test) {
        [ms->currentEncoder setStencilReferenceValue:(uint32_t)(ctx->stencil.ref & 0xFF)];
    }

    // Constant blend factors read the encoder's blend color.
    if (ctx->blend) {
        [ms->currentEncoder setBlendColorRed:ctx->blend_color[0]
                                      green:ctx->blend_color[1]
                                       blue:ctx->blend_color[2]
                                      alpha:ctx->blend_color[3]];
    }

    // Facing also selects two-sided lighting when culling is disabled.
    const MTLWinding winding =
        GLMetalFrontFacingWindingIsCounterClockwise(ctx->front_face)
            ? MTLWindingCounterClockwise : MTLWindingClockwise;
    [ms->currentEncoder setFrontFacingWinding:winding];
    if (ctx->cull_face_enabled) {
        const MTLCullMode mode = ctx->cull_face_mode == 0x0405
            ? MTLCullModeBack : MTLCullModeFront;
        [ms->currentEncoder setCullMode:mode];
    } else {
        [ms->currentEncoder setCullMode:MTLCullModeNone];
    }

    if ((ctx->im_mode>=4 && ctx->polygon_offset_fill) ||
        (polygonRasterMode==0x1b01 && ctx->polygon_offset_line) ||
        (polygonRasterMode==0x1b00 && ctx->polygon_offset_point)) {
        [ms->currentEncoder setDepthBias:ctx->polygon_offset_units
                              slopeScale:ctx->polygon_offset_factor
                                   clamp:0.0f];
    } else {
        [ms->currentEncoder setDepthBias:0.0f slopeScale:0.0f clamp:0.0f];
    }

    // Buffers: 0 vertices, 1 uniforms, 2 lighting. Uniforms are copied inline
    // with set*Bytes so each draw gets its own snapshot.
    [ms->currentEncoder setVertexBuffer:vb offset:vertexOffset atIndex:0];
    [ms->currentEncoder setVertexBytes:&vu length:sizeof(GLMetalVertexUniforms) atIndex:1];
    [ms->currentEncoder setVertexBytes:ld length:sizeof(GLMetalLightingData) atIndex:2];

    [ms->currentEncoder setFragmentBytes:&fu length:sizeof(GLMetalFragmentUniforms) atIndex:1];

    // The shader always declares texture(0)/sampler(0); bind them even when
    // untextured to satisfy validation.
    if (fu.has_texture) {
        const uint32_t texName = GLTextureUnitBoundName(ctx->tex_units[texUnit], primaryTarget);
        if (primaryTexture && primaryTexture->metal_texture) {
            id<MTLTexture> mtlTex = (__bridge id<MTLTexture>)(primaryTexture->metal_texture);
            int texIdx = fu.has_texture_3d ? 1 : 0;  // 3D textures bind at index 1
            [ms->currentEncoder setFragmentTexture:mtlTex atIndex:texIdx];
            id<MTLSamplerState> sampler = GLMetalGetSampler(ms, primaryTexture);
            [ms->currentEncoder setFragmentSamplerState:sampler atIndex:0];
        } else if (ms->fallbackWhiteTexture) {
            // Deleted or never uploaded: bind white (see fallbackWhiteTexture)
            [ms->currentEncoder setFragmentTexture:ms->fallbackWhiteTexture atIndex:0];
            [ms->currentEncoder setFragmentSamplerState:ms->nearestSampler atIndex:0];
            GL_METAL_VLOG("WARNING: has_texture=1 but tex %u has no Metal backing (found=%d) -- using white fallback",
                         texName, primaryTexture ? 1 : 0);
        } else {
            [ms->currentEncoder setFragmentSamplerState:ms->nearestSampler atIndex:0];
        }
    } else {
        // Untextured: bind the fallback for validation; it is not sampled.
        if (ms->fallbackWhiteTexture) {
            [ms->currentEncoder setFragmentTexture:ms->fallbackWhiteTexture atIndex:0];
        }
        [ms->currentEncoder setFragmentSamplerState:ms->nearestSampler atIndex:0];
    }

    // Texture unit 1 binds at texture(2)/sampler(1); texture(1) is unit 0's 3D
    // slot. Always bound for validation, with white when inactive or deleted.
    if (fu.has_texture_unit1) {
        if (secondaryTexture && secondaryTexture->metal_texture) {
            id<MTLTexture> mtlTex1 = (__bridge id<MTLTexture>)(secondaryTexture->metal_texture);
            [ms->currentEncoder setFragmentTexture:mtlTex1 atIndex:fu.has_texture_unit1_3d ? 7 : 2];
            id<MTLSamplerState> sampler1 = GLMetalGetSampler(ms, secondaryTexture);
            [ms->currentEncoder setFragmentSamplerState:sampler1 atIndex:1];
        } else {
            if (ms->fallbackWhiteTexture) {
                [ms->currentEncoder setFragmentTexture:ms->fallbackWhiteTexture atIndex:2];
            }
            [ms->currentEncoder setFragmentSamplerState:ms->nearestSampler atIndex:1];
        }
    } else {
        if (ms->fallbackWhiteTexture) {
            [ms->currentEncoder setFragmentTexture:ms->fallbackWhiteTexture atIndex:2];
        }
        [ms->currentEncoder setFragmentSamplerState:ms->nearestSampler atIndex:1];
    }

    if (indices) {
        [ms->currentEncoder drawIndexedPrimitives:mtlPrim indexCount:indices->size()
            indexType:MTLIndexTypeUInt32 indexBuffer:vb indexBufferOffset:indexOffset];
    } else {
        [ms->currentEncoder drawPrimitives:mtlPrim vertexStart:0 vertexCount:vertCount];
    }

    gl_note_front_modified(ctx, ms->overlayTexture);
    if (!overflow) {
        ms->bufferOffset += (int)stagingBytes;
        ms->bufferOffset = (ms->bufferOffset + 255) & ~255;
    }

#if ACCEL_LOGGING_ENABLED
    GLMetalLogDrawState(ctx, vertData, vertCount, (int)mtlPrim, vu, fu, texUnit, ms->bufferOffset);
#endif

	    GL_METAL_VLOG("GLMetalFlushImmediateMode: drew %zu verts as prim %d, offset now %d",
	                 vertCount, (int)mtlPrim, ms->bufferOffset);
	    GLMetalMarkDrawCompleted(ctx);
	}


// Called at glEnd(): converts im_vertices and encodes the draw.
void GLMetalFlushImmediateMode(GLContext *ctx)
{
    GLMetalSubmitVertices(ctx);
}


/*
 *  Draw BGRA8 pixels as a textured quad at the raster position, honoring the
 *  guest's fragment tests, write masks and blending.
 */
static void GLMetalDrawPixelQuad(GLContext *ctx, int width, int height,
                                 const uint8_t *bgra_data, int data_len, bool bitmap,
                                 float xorig = 0, float yorig = 0)
{
    if (!ctx) return;
    int requiredBytes = 0;
    if (!GLPixelBGRA8Size(ctx, width, height, requiredBytes) || !requiredBytes) return;
    if (!bgra_data || data_len < requiredBytes) { GLPixelUploadInvalid(ctx); return; }
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->initialized) return;

    // Supported GPUs allow 16384 texels per axis; reject before Metal asserts.
    if (width > 16384 || height > 16384) {
        if (!ctx->last_error) ctx->last_error = 0x0505; // OUT_OF_MEMORY
        return;
    }

	if (!ms->renderPassActive) {
		GLMetalBeginFrame(ctx);
		if (!ms->renderPassActive) return;
	}
	if (ms->overlayTexture) {
		GLMetalApplyViewportAndScissor(ms, ctx,
		                               (uint32_t)[ms->overlayTexture width],
		                               (uint32_t)[ms->overlayTexture height]);
	}

    MTLTextureDescriptor *texDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                     width:width
                                    height:height
                                 mipmapped:NO];
    texDesc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [ms->device newTextureWithDescriptor:texDesc];
    if (!tex) return;

    MTLRegion region = MTLRegionMake2D(0, 0, width, height);
    [tex replaceRegion:region mipmapLevel:0 withBytes:bgra_data bytesPerRow:width * 4];

    float vp_x = (float)ctx->viewport[0];
    float vp_y = (float)ctx->viewport[1];
    float vp_w = (float)ctx->viewport[2];
    float vp_h = (float)ctx->viewport[3];
    if (vp_w <= 0 || vp_h <= 0) return;

    // Bitmap origins offset only this draw. Keep the stored raster position
    // intact so its subsequent xmove/ymove advance and attributes are unchanged.
    float win_x = ctx->raster_pos[0] - xorig;
    float win_y = ctx->raster_pos[1] - yorig;

    float quad_w = (float)width * (bitmap ? 1.0f : ctx->pixel_zoom_x);
    float quad_h = (float)height * (bitmap ? 1.0f : ctx->pixel_zoom_y);

    float ndc_x0 = (win_x - vp_x) / vp_w * 2.0f - 1.0f;
    float ndc_y0 = (win_y - vp_y) / vp_h * 2.0f - 1.0f;
    float ndc_x1 = ndc_x0 + quad_w / vp_w * 2.0f;
    float ndc_y1 = ndc_y0 + quad_h / vp_h * 2.0f;

    GLMetalVertex verts[4];
    GLMetalFillPixelQuadVertices(verts, ndc_x0, ndc_y0, ndc_x1, ndc_y1);
    for (auto &v : verts) {
        v.position[2] = ctx->raster_pos[2] * 2.0f - 1.0f;
        if (bitmap) memcpy(v.color, ctx->raster_color, sizeof(v.color));
    }
    GLMetalVertexUniforms vu_local;
    memset(&vu_local, 0, sizeof(vu_local));
    static const float identity[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
    memcpy(vu_local.mvp_matrix, identity, sizeof(float) * 16);
    memcpy(vu_local.modelview_matrix, identity, sizeof(float) * 16);
    memset(vu_local.normal_matrix, 0, sizeof(float) * 12);
    vu_local.normal_matrix[0] = 1; vu_local.normal_matrix[4] = 1; vu_local.normal_matrix[8] = 1;
    vu_local.lighting_enabled = 0;
    vu_local.normalize_enabled = 0;
    vu_local.num_active_lights = 0;
    vu_local.fog_enabled = 0;
    vu_local.fog_mode = 0;
    vu_local.fog_start = 0; vu_local.fog_end = 1; vu_local.fog_density = 0;

    // The transient texture supplies pixel colors or bitmap coverage. Guest
    // alpha testing follows either path before depth/stencil/blending.
    GLMetalFragmentUniforms fu_local;
    memset(&fu_local, 0, sizeof(fu_local));
    fu_local.texenv_mode = 3;  // replace
    fu_local.texenv_color[0] = fu_local.texenv_color[1] = fu_local.texenv_color[2] = fu_local.texenv_color[3] = 1.0f;
    fu_local.fog_color[0] = fu_local.fog_color[1] = fu_local.fog_color[2] = 0.0f;
    fu_local.fog_color[3] = -1.0f;  // fog off
    fu_local.alpha_test_enabled = ctx->alpha_test;
    fu_local.alpha_func = GLAlphaFuncToShader(ctx->alpha_func);
    fu_local.alpha_ref = ctx->alpha_ref;
    fu_local.bitmap_mask = bitmap;
    fu_local.has_texture = 1;
    fu_local.shade_model = 1;  // smooth
    {
        const bool isOffscreen =
            GLContextGetOffscreenDrawable(ctx, NULL, NULL, NULL, NULL);
        fu_local.force_opaque_output =
            GLMetalForceOpaqueOverlayOutput(isOffscreen, ctx->blend) ? 1 : 0;
    }

    id<MTLRenderPipelineState> pipeline = GLMetalGetPipeline(ms, ctx);
    if (!pipeline) return;

    id<MTLDepthStencilState> dsState = GLMetalCreateDepthStencilState(ms, ctx);

    GLMetalDestinationSnapshot pixelSnapshot;
    if(!ms->framebufferFetch && (ctx->color_logic_op || (ms->presentationTexture && ctx->blend)) &&
       !GLMetalSnapshotLogicDestinations(ms,ctx,pixelSnapshot))return;
    // RasterPos has already applied the depth range. Use window depth directly,
    // including when DepthRange changed after RasterPos was established.
    GLMetalViewportRect rect = GLMetalMakeViewportRect(vp_x, vp_y, vp_w, vp_h,
                                                       ms->overlayTexture.height, 0, 1);
    MTLViewport viewport = {rect.origin_x, rect.origin_y, rect.width, rect.height, 0, 1};
    [ms->currentEncoder setViewport:viewport];
    ms->viewportScissorCacheValid = false;

    for(int i=0;i<4;++i)[ms->currentEncoder setFragmentTexture:pixelSnapshot.texture[i] ?: ms->fallbackWhiteTexture atIndex:3+i];
    GLMetalConfigurePresentationDraw(ms,ctx);
    [ms->currentEncoder setRenderPipelineState:pipeline];
    [ms->currentEncoder setDepthStencilState:dsState];
    [ms->currentEncoder setStencilReferenceValue:(uint32_t)(ctx->stencil.ref & 0xff)];
    [ms->currentEncoder setBlendColorRed:ctx->blend_color[0] green:ctx->blend_color[1]
                                   blue:ctx->blend_color[2] alpha:ctx->blend_color[3]];
    [ms->currentEncoder setDepthBias:0 slopeScale:0 clamp:0];
    [ms->currentEncoder setCullMode:MTLCullModeNone];
    [ms->currentEncoder setVertexBytes:verts length:sizeof(verts) atIndex:0];
    {
        GLMetalLightingData ld_empty;
        memset(&ld_empty, 0, sizeof(ld_empty));
        [ms->currentEncoder setVertexBytes:&vu_local length:sizeof(GLMetalVertexUniforms) atIndex:1];
        [ms->currentEncoder setVertexBytes:&ld_empty length:sizeof(GLMetalLightingData) atIndex:2];
    }
    [ms->currentEncoder setFragmentBytes:&fu_local length:sizeof(GLMetalFragmentUniforms) atIndex:1];
    [ms->currentEncoder setFragmentTexture:tex atIndex:0];
    [ms->currentEncoder setFragmentSamplerState:ms->nearestSampler atIndex:0];
    // Unit 1 slot must be bound for validation; it is not sampled here.
    [ms->currentEncoder setFragmentTexture:ms->fallbackWhiteTexture atIndex:2];
    [ms->currentEncoder setFragmentSamplerState:ms->nearestSampler atIndex:1];
    [ms->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    gl_note_front_modified(ctx, ms->overlayTexture);
    GLMetalMarkDrawCompleted(ctx);

    GL_METAL_VLOG("GLMetalDrawPixels: %dx%d at raster (%.1f, %.1f) zoom (%.1f, %.1f)",
                 width, height, ctx->raster_pos[0], ctx->raster_pos[1],
                 ctx->pixel_zoom_x, ctx->pixel_zoom_y);
}


// Both entry points share the same fragment-state application. Bitmap coverage
// is tested separately from the raster color's alpha in the fragment shader.
void GLMetalDrawPixels(GLContext *ctx, int width, int height, const uint8_t *data, int size)
{
    GLMetalDrawPixelQuad(ctx, width, height, data, size, false);
}

void GLMetalBitmap(GLContext *ctx, int width, int height, const uint8_t *data, int size,
                   float xorig, float yorig)
{
    GLMetalDrawPixelQuad(ctx, width, height, data, size, true, xorig, yorig);
}


void GLMetalEndFrame(GLContext *ctx)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->renderPassActive) return;

    [ms->currentEncoder endEncoding];
    ms->currentEncoder = nil;

    id<MTLCommandBuffer> committedBuffer = ms->currentCommandBuffer;
    GLMetalCommitCommandBuffer(ms, committedBuffer);
    ms->lastCommittedBuffer = committedBuffer;
    ms->currentCommandBuffer = nil;

    ms->renderPassActive = false;
    GLMetalReadbackOffscreenDrawable(ctx, ms, committedBuffer);

    GL_METAL_VLOG("GLMetalEndFrame: frame committed, buffer index now %d", ms->currentBufferIndex);
}


void NativeGLFinish(GLContext *ctx)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms) return;

    if (ms->renderPassActive && ms->currentEncoder) {
        [ms->currentEncoder endEncoding];
        ms->currentEncoder = nil;
    }
    if (ms->currentCommandBuffer) {
        id<MTLCommandBuffer> committedBuffer = ms->currentCommandBuffer;
        GLMetalCommitCommandBuffer(ms, committedBuffer);
        [committedBuffer waitUntilCompleted];
        ms->lastCommittedBuffer = committedBuffer;
        ms->currentCommandBuffer = nil;
        ms->renderPassActive = false;
        GLMetalReadbackOffscreenDrawable(ctx, ms, committedBuffer);
    }

    if (ms->lastCommittedBuffer) [ms->lastCommittedBuffer waitUntilCompleted];
    gl_publish_front(ctx);

    GL_METAL_VLOG("NativeGLFinish: completed");
}

void GLMetalPrepareDrawableChange(GLContext *ctx)
{
    if (!ctx || !ctx->metal) return;
    NativeGLFinish(ctx);
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (ms->lastCommittedBuffer) [ms->lastCommittedBuffer waitUntilCompleted];
    ms->overlayTexture = nil;
    ms->viewportScissorCacheValid = false;
}


void NativeGLFlush(GLContext *ctx)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms) return;

    if (ms->renderPassActive && ms->currentEncoder) {
        [ms->currentEncoder endEncoding];
        ms->currentEncoder = nil;
    }
    if (ms->currentCommandBuffer) {
        id<MTLCommandBuffer> committedBuffer = ms->currentCommandBuffer;
        GLMetalCommitCommandBuffer(ms, committedBuffer);
        ms->lastCommittedBuffer = committedBuffer;
        ms->currentCommandBuffer = nil;
        ms->renderPassActive = false;
        GLMetalReadbackOffscreenDrawable(ctx, ms, committedBuffer);
    }

    gl_publish_front(ctx);

    GL_METAL_VLOG("NativeGLFlush: committed");
}


/*
 *  Waits for GPU work, then frees this context's Metal state. Textures and
 *  display lists belong to the share group; the accum buffer is freed in
 *  gl_engine.cpp.
 */
void GLMetalRelease(GLContext *ctx)
{
    gl_overlay_unbind(ctx);
    if (!ctx->metal) return;

    GLMetalState *ms = (GLMetalState *)ctx->metal;

    if (ms->renderPassActive && ms->currentEncoder) {
        [ms->currentEncoder endEncoding];
        ms->currentEncoder = nil;
    }
    if (ms->currentCommandBuffer) {
        GLMetalCommitCommandBuffer(ms, ms->currentCommandBuffer);
        [ms->currentCommandBuffer waitUntilCompleted];
        ms->currentCommandBuffer = nil;
    }
    if (ms->lastCommittedBuffer) {
        [ms->lastCommittedBuffer waitUntilCompleted];
        ms->lastCommittedBuffer = nil;
    }

    // Textures are left to the share group, which outlives this context.
    size_t tex_count = ctx->texture_objects.size();

    size_t pipe_count = ms->pipelineCache.size();
    ms->pipelineCache.clear();
    size_t ds_count = ms->depthStencilCache.size();
    ms->depthStencilCache.clear();
    ms->clearPipelineCache.clear();
    ms->clearDepthStencilCache.clear();

    // Shared sampler cache; rebuilt on demand
    size_t sampler_count = gl_sampler_cache.size();
    gl_sampler_cache.clear();

    GL_METAL_LOG("GLMetalRelease: retained %zu shared textures; released %zu pipelines, %zu depth-stencil states, %zu samplers",
                 tex_count, pipe_count, ds_count, sampler_count);

    delete ms;
    ctx->metal = nullptr;

    GL_METAL_LOG("GLMetalRelease: all Metal resources released");
}


// ==========================================================================
//  Texture upload and sampler management
// ==========================================================================

// Must match gl_state.cpp
#define GL_NEAREST                        0x2600
#define GL_LINEAR_FILTER                  0x2601
#define GL_NEAREST_MIPMAP_NEAREST         0x2700
#define GL_LINEAR_MIPMAP_NEAREST          0x2701
#define GL_NEAREST_MIPMAP_LINEAR          0x2702
#define GL_LINEAR_MIPMAP_LINEAR           0x2703

#define GL_REPEAT                         0x2901
#define GL_CLAMP                          0x2900
#define GL_CLAMP_TO_EDGE                  0x812F
#define GL_MIRRORED_REPEAT                0x8370

#define GL_RGBA                           0x1908
#define GL_DEPTH_COMPONENT                0x1902


static void GLMetalEndAndCommitForReadback(GLMetalState *ms);
static bool GLMetalRestartRenderPassForReadback(GLContext *ctx);

// replaceRegion writes shared storage immediately. Submit and finish earlier
// draws as well as copies before changing pixels they may still be reading.
// GPU-only copy -> draw sequences remain asynchronous.
static void GLMetalSynchronizeTextureAccess(GLContext *ctx)
{
    if (!ctx) return;
    GLContext *contexts[4] = {};
    bool resume[4] = {};
    unsigned count = GLContextGetSharedContexts(ctx, contexts, 4);
    if (!count) { contexts[0] = ctx; count = 1; }
    for (unsigned i = 0; i < count; ++i) {
        GLContext *owner = contexts[i];
        GLMetalState *ms = (GLMetalState *)owner->metal;
        if (!ms || (!ms->currentCommandBuffer && !ms->lastCommittedBuffer)) continue;
        resume[i] = ms->renderPassActive;
        GLMetalEndAndCommitForReadback(ms);
        ms->textureCopyPending = false;
    }
    // Preserve every logical pass, including inactive peers. A lazy BeginFrame
    // on an offscreen peer would reimport stale guest RAM over its GPU pixels.
    // Commit all producers first, then resume attachment loads so pending
    // shared-resource work cannot be held behind a newly opened encoder.
    for (unsigned i = 0; i < count; ++i) {
        if (resume[i]) GLMetalRestartRenderPassForReadback(contexts[i]);
    }
}

void GLMetalSynchronizeSharedContexts(GLContext *ctx)
{
    GLMetalSynchronizeTextureAccess(ctx);
}

void GLMetalUploadTexture(GLContext *ctx, GLTextureObject *texObj, int level,
                           int width, int height, const uint8_t *data, int dataLen)
{
    if (!ctx || !texObj) return;
    if (!GLTextureImageSizeIsValid(level, width, height) ||
        dataLen < 0 || uint64_t(width) * uint64_t(height) * 4 > uint64_t(dataLen)) {
        if (!ctx->last_error) ctx->last_error = 0x0501;
        return;
    }
    if (!width || !height) return;
    if (!data) { if (!ctx->last_error) ctx->last_error = 0x0501; return; }
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->device) return;

    id<MTLTexture> existing = texObj->metal_texture ?
        (__bridge id<MTLTexture>)(texObj->metal_texture) : nil;
    if (level > 0 && existing && !GLTextureRegionFits(level, 0, 0, 0, width, height, 1,
        existing.width, existing.height, 1, GLTextureMipLevelCount(existing.width, existing.height))) {
        if (!ctx->last_error) ctx->last_error = 0x0501;
        return;
    }
    if (existing) GLMetalSynchronizeTextureAccess(ctx);

    // Recreate if missing or the base size changed. Compare against the Metal
    // texture: the caller may already have updated texObj's dimensions.
    const bool dropLegacyFallbackMips =
        level == 0 &&
        texObj->has_mipmaps &&
        GLPixelLegacyUnsignedShortHasLevelZeroOnlyFallback(
            texObj->legacy_ushort_bgr332_chain,
            texObj->legacy_ushort_scalar_no_palette_chain,
            texObj->source_format,
            texObj->source_type);
    if (dropLegacyFallbackMips) {
        texObj->has_mipmaps = false;
    }

    bool needNew = !existing ||
                   (level == 0 && ((int)[existing width] != width || (int)[existing height] != height)) ||
                   (dropLegacyFallbackMips && existing && [existing mipmapLevelCount] > 1);

#if ACCEL_LOGGING_ENABLED
    if (gl_logging_enabled && dropLegacyFallbackMips) {
        const char *fallbackName =
            texObj->legacy_ushort_scalar_no_palette_chain ?
            "scalar no-palette" : "BGR332";
        GL_METAL_LOG("GLMetalUploadTexture: tex=%u level=0 dropping legacy %s client mips",
                     texObj->name, fallbackName);
    }
#endif

    // A level > 0 upload needs mip storage; a non-mipmapped texture has only
    // one level and would crash.
    if (level > 0 && existing && [existing mipmapLevelCount] <= (NSUInteger)level) {
        texObj->has_mipmaps = true;
        // Recreate with mips, keeping existing levels. Use the old texture's
        // base size; texObj may hold this level's size.
        NSUInteger baseW = [existing width];
        NSUInteger baseH = [existing height];
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                        width:baseW
                                                                                       height:baseH
                                                                                    mipmapped:YES];
        desc.usage = MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;

        id<MTLTexture> newTex = [ms->device newTextureWithDescriptor:desc];
        if (newTex) {
            NSUInteger baseBytesPerRow = baseW * 4;
            NSUInteger baseSize = baseBytesPerRow * baseH;
            uint8_t *baseData = (uint8_t *)malloc(baseSize);
            if (baseData) {
                MTLRegion baseRegion = MTLRegionMake2D(0, 0, baseW, baseH);
                [existing getBytes:baseData bytesPerRow:baseBytesPerRow fromRegion:baseRegion mipmapLevel:0];
                [newTex replaceRegion:baseRegion mipmapLevel:0 withBytes:baseData bytesPerRow:baseBytesPerRow];
                free(baseData);
            }

            NSUInteger oldMipCount = [existing mipmapLevelCount];
            for (int m = 1; m < level && (NSUInteger)m < oldMipCount; m++) {
                NSUInteger mw = MAX(baseW >> m, 1u);
                NSUInteger mh = MAX(baseH >> m, 1u);
                NSUInteger mBytesPerRow = mw * 4;
                NSUInteger mSize = mBytesPerRow * mh;
                uint8_t *mData = (uint8_t *)malloc(mSize);
                if (mData) {
                    MTLRegion mRegion = MTLRegionMake2D(0, 0, mw, mh);
                    [existing getBytes:mData bytesPerRow:mBytesPerRow fromRegion:mRegion mipmapLevel:m];
                    [newTex replaceRegion:mRegion mipmapLevel:m withBytes:mData bytesPerRow:mBytesPerRow];
                    free(mData);
                }
            }

            CFRelease(texObj->metal_texture);
            texObj->metal_texture = (void *)CFBridgingRetain(newTex);
            texObj->width = (int)baseW;
            texObj->height = (int)baseH;
            existing = newTex;
        }
    } else if (level > 0 && existing) {
        texObj->has_mipmaps = true;
    }

    if (needNew && level == 0) {
        if (texObj->metal_texture) {
            CFRelease(texObj->metal_texture);
            texObj->metal_texture = nullptr;
        }

        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                        width:width
                                                                                       height:height
                                                                                    mipmapped:texObj->has_mipmaps];
        desc.usage = MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;

        id<MTLTexture> newTex = [ms->device newTextureWithDescriptor:desc];
        if (!newTex) {
            GL_METAL_LOG("GLMetalUploadTexture: failed to create %dx%d texture", width, height);
            return;
        }

        texObj->metal_texture = (void *)CFBridgingRetain(newTex);
        texObj->width = width;
        texObj->height = height;
        existing = newTex;
    }

    if (!existing) return;

    // Mip promotion can fail; check the levels the texture actually has.
    if (!GLTextureRegionFits(level, 0, 0, 0, width, height, 1,
        existing.width, existing.height, 1, unsigned(existing.mipmapLevelCount))) {
        if (!ctx->last_error) ctx->last_error = 0x0501;
        return;
    }

    int mipWidth = width;
    int mipHeight = height;

	MTLRegion region = MTLRegionMake2D(0, 0, mipWidth, mipHeight);
	[existing replaceRegion:region
	            mipmapLevel:level
	              withBytes:data
	            bytesPerRow:mipWidth * 4];

#if ACCEL_LOGGING_ENABLED
	if (gl_logging_enabled &&
	    GLMetalTextureDiagnosticsShouldTrace(texObj->name, level)) {
	    GLMetalLogTextureBGRAStats("GLMetalUploadTexture source",
	                               texObj->name, level,
	                               mipWidth, mipHeight, data, dataLen);
	    std::vector<uint8_t> readback((size_t)mipWidth * (size_t)mipHeight * 4u);
	    if (!readback.empty()) {
	        [existing getBytes:readback.data()
	               bytesPerRow:mipWidth * 4
	                fromRegion:region
	               mipmapLevel:level];
	        GLMetalLogTextureBGRAStats("GLMetalUploadTexture readback",
	                                   texObj->name, level,
	                                   mipWidth, mipHeight,
	                                   readback.data(), (int)readback.size());
	    }
	}
#endif

	GL_METAL_VLOG("GLMetalUploadTexture: tex=%u level=%d %dx%d (%d bytes) "
	             "metal=%lux%lu mips=%lu hasMipmaps=%d",
	             texObj->name, level, mipWidth, mipHeight, dataLen,
	             (unsigned long)[existing width],
	             (unsigned long)[existing height],
	             (unsigned long)[existing mipmapLevelCount],
	             texObj->has_mipmaps ? 1 : 0);
}


void GLMetalUploadSubTexture(GLContext *ctx, GLTextureObject *texObj, int level,
                              int xoff, int yoff, int w, int h,
                              const uint8_t *data, int bytesPerRow)
{
    if (!ctx || !texObj) return;
    if (!texObj->metal_texture) { if (!ctx->last_error) ctx->last_error = 0x0502; return; }
    id<MTLTexture> mtlTex = (__bridge id<MTLTexture>)(texObj->metal_texture);
    if (!GLTextureRegionFits(level, xoff, yoff, 0, w, h, 1,
        mtlTex.width, mtlTex.height, 1, unsigned(mtlTex.mipmapLevelCount)) ||
        bytesPerRow < 0 || uint64_t(bytesPerRow) < uint64_t(w) * 4) {
        if (!ctx->last_error) ctx->last_error = 0x0501;
        return;
    }
    if (!w || !h) return;
    if (!data) { if (!ctx->last_error) ctx->last_error = 0x0501; return; }
    GLMetalSynchronizeTextureAccess(ctx);
    MTLRegion region = MTLRegionMake2D(xoff, yoff, w, h);
    [mtlTex replaceRegion:region
              mipmapLevel:level
                withBytes:data
              bytesPerRow:bytesPerRow];

    GL_METAL_VLOG("GLMetalUploadSubTexture: tex=%u level=%d region=(%d,%d,%d,%d)",
                 texObj->name, level, xoff, yoff, w, h);
}


void GLMetalDestroyTexture(GLTextureObject *texObj)
{
    if (texObj->metal_texture) {
        CFRelease(texObj->metal_texture);
        texObj->metal_texture = nullptr;
    }
    texObj->width = 0;
    texObj->height = 0;
    texObj->depth = 0;
}


// data is depth consecutive BGRA8 slices.
void GLMetalUpload3DTexture(GLContext *ctx, GLTextureObject *texObj, int level,
                            int width, int height, int depth,
                            const uint8_t *data, int dataLen)
{
    if (!ctx || !texObj) return;
    if (!GLTextureImageSizeIsValid(level, width, height, depth) ||
        dataLen < 0 || uint64_t(width) * uint64_t(height) * uint64_t(depth) * 4 > uint64_t(dataLen)) {
        if (!ctx->last_error) ctx->last_error = 0x0501;
        return;
    }
    if (!width || !height || !depth) return;
    if (!data) { if (!ctx->last_error) ctx->last_error = 0x0501; return; }
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->device) return;

    id<MTLTexture> existing = texObj->metal_texture ?
        (__bridge id<MTLTexture>)(texObj->metal_texture) : nil;
    if (level > 0 && existing && !GLTextureRegionFits(level, 0, 0, 0, width, height, depth,
        existing.width, existing.height, existing.depth,
        GLTextureMipLevelCount(existing.width, existing.height, existing.depth))) {
        if (!ctx->last_error) ctx->last_error = 0x0501;
        return;
    }
    if (existing) GLMetalSynchronizeTextureAccess(ctx);

    // TexImage3D has already updated the guest metadata. Inspect the backing
    // texture itself, just as the 2D upload path does.
    bool needNew = !existing ||
                   (level == 0 && (existing.textureType != MTLTextureType3D ||
                    (int)existing.width != width || (int)existing.height != height ||
                    (int)existing.depth != depth));

    const bool addMipStorage = existing && level > 0 &&
        (NSUInteger)level >= existing.mipmapLevelCount;
    if ((needNew && level == 0) || addMipStorage) {
        const NSUInteger baseW = level == 0 ? width : existing.width;
        const NSUInteger baseH = level == 0 ? height : existing.height;
        const NSUInteger baseD = level == 0 ? depth : existing.depth;
        MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
        desc.textureType = MTLTextureType3D;
        desc.pixelFormat = MTLPixelFormatBGRA8Unorm;
        desc.width = baseW;
        desc.height = baseH;
        desc.depth = baseD;
        NSUInteger mipCount = 1;
        for (NSUInteger size = std::max(baseW, std::max(baseH, baseD)); size > 1; size >>= 1)
            ++mipCount;
        if (level < 0 || (NSUInteger)level >= mipCount) {
            if (!ctx->last_error) ctx->last_error = 0x0501;
            return;
        }
        desc.mipmapLevelCount = (texObj->has_mipmaps || level > 0) ? mipCount : 1;
        desc.usage = MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;

        id<MTLTexture> newTex = [ms->device newTextureWithDescriptor:desc];
        if (!newTex) {
            GL_METAL_LOG("GLMetalUpload3DTexture: failed to create %dx%dx%d texture", width, height, depth);
            return;
        }

        // Promoting a base-only texture must retain every previously uploaded
        // level. Shared storage is CPU-safe after the synchronization above.
        if (addMipStorage) {
            for (NSUInteger mip = 0; mip < existing.mipmapLevelCount; ++mip) {
                const NSUInteger mw = std::max(baseW >> mip, (NSUInteger)1);
                const NSUInteger mh = std::max(baseH >> mip, (NSUInteger)1);
                const NSUInteger md = std::max(baseD >> mip, (NSUInteger)1);
                uint8_t *pixels = (uint8_t *)malloc(mw * mh * md * 4);
                if (!pixels) {
                    if (!ctx->last_error) ctx->last_error = 0x0505;
                    return;
                }
                const MTLRegion region = MTLRegionMake3D(0, 0, 0, mw, mh, md);
                [existing getBytes:pixels bytesPerRow:mw * 4 bytesPerImage:mw * mh * 4
                        fromRegion:region mipmapLevel:mip slice:0];
                [newTex replaceRegion:region mipmapLevel:mip slice:0 withBytes:pixels
                          bytesPerRow:mw * 4 bytesPerImage:mw * mh * 4];
                free(pixels);
            }
        }
        if (texObj->metal_texture) CFRelease(texObj->metal_texture);
        texObj->metal_texture = (void *)CFBridgingRetain(newTex);
        existing = newTex;
    }

    if (!existing) return;

    if (level < 0 || (NSUInteger)level >= existing.mipmapLevelCount ||
        width <= 0 || height <= 0 || depth <= 0 ||
        (NSUInteger)width > std::max(existing.width >> level, (NSUInteger)1) ||
        (NSUInteger)height > std::max(existing.height >> level, (NSUInteger)1) ||
        (NSUInteger)depth > std::max(existing.depth >> level, (NSUInteger)1)) {
        if (!ctx->last_error) ctx->last_error = 0x0501; // GL_INVALID_VALUE
        return;
    }
    // Higher-level uploads must not replace base-level metadata with mip sizes.
    texObj->width = (int)existing.width;
    texObj->height = (int)existing.height;
    texObj->depth = (int)existing.depth;
    if (level > 0) texObj->has_mipmaps = true;

    MTLRegion region = MTLRegionMake3D(0, 0, 0, width, height, depth);
    [existing replaceRegion:region
                mipmapLevel:level
                      slice:0
                  withBytes:data
                bytesPerRow:width * 4
              bytesPerImage:width * height * 4];

    GL_METAL_VLOG("GLMetalUpload3DTexture: tex=%u level=%d %dx%dx%d (%d bytes)",
                 texObj->name, level, width, height, depth, dataLen);
}


void GLMetalUploadSubTexture3D(GLContext *ctx, GLTextureObject *texObj, int level,
                               int xoff, int yoff, int zoff,
                               int w, int h, int d,
                               const uint8_t *data, int bytesPerRow, int bytesPerImage)
{
    if (!ctx || !texObj) return;
    if (!texObj->metal_texture) { if (!ctx->last_error) ctx->last_error = 0x0502; return; }
    id<MTLTexture> mtlTex = (__bridge id<MTLTexture>)(texObj->metal_texture);
    if (!GLTextureRegionFits(level, xoff, yoff, zoff, w, h, d,
        mtlTex.width, mtlTex.height, mtlTex.depth, unsigned(mtlTex.mipmapLevelCount)) ||
        bytesPerRow < 0 || bytesPerImage < 0 || uint64_t(bytesPerRow) < uint64_t(w) * 4 ||
        uint64_t(bytesPerImage) < uint64_t(bytesPerRow) * uint64_t(h)) {
        if (!ctx->last_error) ctx->last_error = 0x0501;
        return;
    }
    if (!w || !h || !d) return;
    if (!data) { if (!ctx->last_error) ctx->last_error = 0x0501; return; }
    GLMetalSynchronizeTextureAccess(ctx);
    MTLRegion region = MTLRegionMake3D(xoff, yoff, zoff, w, h, d);
    [mtlTex replaceRegion:region
              mipmapLevel:level
                    slice:0
                withBytes:data
              bytesPerRow:bytesPerRow
            bytesPerImage:bytesPerImage];

    GL_METAL_VLOG("GLMetalUploadSubTexture3D: tex=%u level=%d region=(%d,%d,%d,%d,%d,%d)",
                 texObj->name, level, xoff, yoff, zoff, w, h, d);
}



static MTLSamplerMinMagFilter GLFilterToMetalMinMag(uint32_t gl_filter) {
    switch (gl_filter) {
        case GL_NEAREST:
        case GL_NEAREST_MIPMAP_NEAREST:
        case GL_NEAREST_MIPMAP_LINEAR:
            return MTLSamplerMinMagFilterNearest;
        case GL_LINEAR_FILTER:
        case GL_LINEAR_MIPMAP_NEAREST:
        case GL_LINEAR_MIPMAP_LINEAR:
        default:
            return MTLSamplerMinMagFilterLinear;
    }
}

static MTLSamplerMipFilter GLFilterToMetalMip(uint32_t gl_filter) {
    switch (gl_filter) {
        case GL_NEAREST_MIPMAP_NEAREST:
        case GL_LINEAR_MIPMAP_NEAREST:
            return MTLSamplerMipFilterNearest;
        case GL_NEAREST_MIPMAP_LINEAR:
        case GL_LINEAR_MIPMAP_LINEAR:
            return MTLSamplerMipFilterLinear;
        default:
            return MTLSamplerMipFilterNotMipmapped;
    }
}

static MTLSamplerAddressMode GLWrapToMetal(uint32_t gl_wrap) {
    switch (gl_wrap) {
        case GL_REPEAT:           return MTLSamplerAddressModeRepeat;
        case GL_CLAMP:
        case GL_CLAMP_TO_EDGE:    return MTLSamplerAddressModeClampToEdge;
        case GL_MIRRORED_REPEAT:  return MTLSamplerAddressModeMirrorRepeat;
        default:                  return MTLSamplerAddressModeRepeat;
    }
}

static id<MTLSamplerState> GLMetalGetSampler(GLMetalState *ms, GLTextureObject *texObj) {
    uint64_t key = (uint64_t)(texObj->min_filter & 0xFFFF)
                 | ((uint64_t)(texObj->mag_filter & 0xFFFF) << 16)
                 | ((uint64_t)(texObj->wrap_s & 0xFFFF) << 32)
                 | ((uint64_t)(texObj->wrap_t & 0xFFFF) << 48);

    auto it = gl_sampler_cache.find(key);
    if (it != gl_sampler_cache.end()) return it->second;

    MTLSamplerDescriptor *desc = [[MTLSamplerDescriptor alloc] init];
    desc.minFilter = GLFilterToMetalMinMag(texObj->min_filter);
    desc.magFilter = GLFilterToMetalMinMag(texObj->mag_filter);
    desc.mipFilter = GLFilterToMetalMip(texObj->min_filter);
    desc.sAddressMode = GLWrapToMetal(texObj->wrap_s);
    desc.tAddressMode = GLWrapToMetal(texObj->wrap_t);

    id<MTLSamplerState> sampler = [ms->device newSamplerStateWithDescriptor:desc];
    gl_sampler_cache[key] = sampler;

    GL_METAL_LOG("GLMetalGetSampler: created sampler key=0x%llx (min=0x%x mag=0x%x wrapS=0x%x wrapT=0x%x)",
                 (unsigned long long)key, texObj->min_filter, texObj->mag_filter,
                 texObj->wrap_s, texObj->wrap_t);

    return sampler;
}


/*
 *  Returns a malloc'd BGRA8 copy of a framebuffer rect (caller frees), or NULL.
 *  Ends the current encoder and resumes with load actions.
 */
static void GLMetalWaitForCommittedReadbackWork(GLMetalState *ms)
{
    if (!ms) return;
    if (ms->lastCommittedBuffer) {
        [ms->lastCommittedBuffer waitUntilCompleted];
        ms->lastCommittedBuffer = nil;
    }
}

static void GLMetalEndAndCommitForReadback(GLMetalState *ms)
{
    if (!ms) return;

    if (ms->currentEncoder) {
        [ms->currentEncoder endEncoding];
        ms->currentEncoder = nil;
    }

    if (ms->currentCommandBuffer) {
        id<MTLCommandBuffer> committedBuffer = ms->currentCommandBuffer;
        GLMetalCommitCommandBuffer(ms, committedBuffer);
        [committedBuffer waitUntilCompleted];
        ms->lastCommittedBuffer = committedBuffer;
        ms->currentCommandBuffer = nil;
    }

    GLMetalWaitForCommittedReadbackWork(ms);
    ms->renderPassActive = false;
}

static bool GLMetalRestartRenderPassForReadback(GLContext *ctx)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->overlayTexture) return false;

    if (!ms->currentCommandBuffer)
        ms->currentCommandBuffer = [ms->commandQueue commandBuffer];
    if (!ms->currentCommandBuffer) {
        GL_METAL_LOG("GLMetalRestartRenderPassForReadback: failed to create command buffer");
        return false;
    }

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    GLMetalSetColorAttachments(rpd, ms);

    if (ms->depthBuffer) {
        rpd.depthAttachment.texture = ms->depthBuffer;
        rpd.depthAttachment.loadAction = MTLLoadActionLoad;
        rpd.depthAttachment.storeAction = MTLStoreActionStore;
        rpd.stencilAttachment.texture = ms->depthBuffer;
        rpd.stencilAttachment.loadAction = MTLLoadActionLoad;
        rpd.stencilAttachment.storeAction = MTLStoreActionStore;
    }

	ms->currentEncoder = [ms->currentCommandBuffer renderCommandEncoderWithDescriptor:rpd];
	ms->viewportScissorCacheValid = false;
	if (!ms->currentEncoder) {
		GL_METAL_LOG("GLMetalRestartRenderPassForReadback: failed to create encoder");
        ms->currentCommandBuffer = nil;
        ms->renderPassActive = false;
        return false;
    }

    GLMetalApplyViewportAndScissor(ms, ctx,
                                   (uint32_t)[ms->overlayTexture width],
                                   (uint32_t)[ms->overlayTexture height]);
    ms->renderPassActive = true;
    return true;
}

static bool GLMetalReadRectIsInTexture(id<MTLTexture> tex,
                                       int32_t x, int32_t y,
                                       int32_t width, int32_t height)
{
    if (!tex || x < 0 || y < 0 || width <= 0 || height <= 0) return false;
    const uint64_t x1 = (uint64_t)(uint32_t)x + (uint32_t)width;
    const uint64_t y1 = (uint64_t)(uint32_t)y + (uint32_t)height;
    return x1 <= [tex width] && y1 <= [tex height];
}

static id<MTLBuffer> GLMetalGetDepthReadbackBuffer(GLMetalState *ms,
                                                   int32_t width, int32_t height,
                                                   NSUInteger *bytesPerRow)
{
    // A combined depth/stencil texture cannot be blitted to R32Float. Extract
    // the depth aspect into shared buffer memory, with a Metal-aligned pitch.
    const NSUInteger rowBytes = ((NSUInteger)width * sizeof(float) + 255u) & ~NSUInteger(255u);
    const NSUInteger bufferBytes = rowBytes * (NSUInteger)height;
    *bytesPerRow = rowBytes;
    if (!ms->depthReadbackBuffer || ms->depthReadbackBuffer.length < bufferBytes) {
        ms->depthReadbackBuffer = [ms->device newBufferWithLength:bufferBytes
                                                       options:MTLResourceStorageModeShared];
    }
    return ms->depthReadbackBuffer;
}

// Copy through a private scratch texture so destination textures need no
// shader-write usage and even source/destination aliasing remains ordered.
// Texture row zero is GL's bottom row; render-target row zero is Metal's top.
bool GLMetalCopyFramebufferToTexture(GLContext *ctx, GLTextureObject *texObj,
    int level, int xoffset, int yoffset, int x, int y, int width, int height, bool redefine)
{
    if (!ctx || !texObj) return false;
    auto fail = [&](uint32_t error) {
        if (!ctx->last_error) ctx->last_error = error;
        return false;
    };
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    id<MTLTexture> dst = (__bridge id<MTLTexture>)texObj->metal_texture;
    id<MTLTexture> preserveSource = nil;
    if (!ms || !ms->initialized) return fail(0x0502); // INVALID_OPERATION
    // Other contexts in the share group can still have unsubmitted draws
    // referencing this texture. Order them before this context replaces it.
    GLMetalSynchronizeTextureAccess(ctx);
    if (redefine) {
        // 1024 matches GL_MAX_TEXTURE_SIZE. Redefining level 0 makes a fresh
        // texture, so queued draws keep the old one.
        if (level < 0 || level > 10 || width < 0 || height < 0 ||
            width > (1024 >> level) || height > (1024 >> level)) return fail(0x0501);
        if (width == 0 || height == 0) return true;
        const NSUInteger baseW = level > 0 && dst ? dst.width : NSUInteger(width) << level;
        const NSUInteger baseH = level > 0 && dst ? dst.height : NSUInteger(height) << level;
        if (std::max(NSUInteger(1), baseW >> level) != (NSUInteger)width ||
            std::max(NSUInteger(1), baseH >> level) != (NSUInteger)height) return fail(0x0501);
        if (level == 0 || !dst || (NSUInteger)level >= dst.mipmapLevelCount) {
            auto d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                width:baseW height:baseH mipmapped:(level > 0 || texObj->has_mipmaps)];
            d.storageMode = MTLStorageModeShared;
            d.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> replacement = [ms->device newTextureWithDescriptor:d];
            if (!replacement) return fail(0x0505);
            if (dst && dst.width == baseW && dst.height == baseH)
                preserveSource = dst;
            if (texObj->metal_texture) CFRelease(texObj->metal_texture);
            texObj->metal_texture = (void *)CFBridgingRetain(replacement);
            texObj->width = (int)baseW; texObj->height = (int)baseH;
            texObj->has_mipmaps = replacement.mipmapLevelCount > 1;
            dst = replacement;
        }
    }
    if (!dst) return fail(0x0502);
    if (level < 0 || (NSUInteger)level >= dst.mipmapLevelCount ||
        xoffset < 0 || yoffset < 0 || width < 0 || height < 0)
        return fail(0x0501); // INVALID_VALUE
    const NSUInteger mipW = std::max(NSUInteger(1), dst.width >> level);
    const NSUInteger mipH = std::max(NSUInteger(1), dst.height >> level);
    if (uint64_t(xoffset) + uint64_t(width) > mipW ||
        uint64_t(yoffset) + uint64_t(height) > mipH) return fail(0x0501);
    if (width == 0 || height == 0) return true;
    if (!ms->overlayTexture) GLMetalBeginFrame(ctx);
    id<MTLTexture> src = GLMetalReadColorTexture(ctx, ms);
    if (!src) return fail(0x0502);

    // Source pixels outside the framebuffer are undefined in GL. Preserve the
    // corresponding destination texels and copy only the in-bounds intersection.
    const int64_t left = std::max<int64_t>(0, -int64_t(x));
    const int64_t bottom = std::max<int64_t>(0, -int64_t(y));
    const int64_t w = std::min<int64_t>(width, int64_t(src.width) - x) - left;
    const int64_t h = std::min<int64_t>(height, int64_t(src.height) - y) - bottom;
    const bool hasPixels = w > 0 && h > 0;
    if (!hasPixels && !preserveSource) return true;

    if (hasPixels && !ms->textureCopyPipeline) {
        NSError *error = nil;
        id<MTLFunction> fn = [ms->shaderLibrary newFunctionWithName:@"gl_copy_texture_region"];
        if (fn) ms->textureCopyPipeline = [ms->device newComputePipelineStateWithFunction:fn error:&error];
        if (!ms->textureCopyPipeline) return fail(0x0505); // OUT_OF_MEMORY
    }
    id<MTLTexture> scratch = nil;
    if (hasPixels) {
        auto desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:(NSUInteger)w height:(NSUInteger)h mipmapped:NO];
        desc.storageMode = MTLStorageModePrivate;
        desc.usage = MTLTextureUsageShaderWrite;
        scratch = [ms->device newTextureWithDescriptor:desc];
        if (!scratch) return fail(0x0505);
    }

    struct CopyUniforms {
        uint32_t sourceX, sourceBottom, width, height;
        float scale[4], bias[4];
        uint32_t base_internal_format, _pad[3];
    } u = {uint32_t(int64_t(x) + left), uint32_t(int64_t(src.height) - 1 - (int64_t(y) + bottom)),
        uint32_t(w), uint32_t(h),
        {ctx->pixel_transfer_red_scale, ctx->pixel_transfer_green_scale,
         ctx->pixel_transfer_blue_scale, ctx->pixel_transfer_alpha_scale},
        {ctx->pixel_transfer_red_bias, ctx->pixel_transfer_green_bias,
         ctx->pixel_transfer_blue_bias, ctx->pixel_transfer_alpha_bias},
        GLTextureLevelBaseFormat(*texObj, level), {0, 0, 0}};
    const bool resume = ms->renderPassActive;
    if (ms->currentEncoder) {
        [ms->currentEncoder endEncoding];
        ms->currentEncoder = nil;
    }
    ms->renderPassActive = false;
    if (!ms->currentCommandBuffer) ms->currentCommandBuffer = [ms->commandQueue commandBuffer];
    ms->textureCopyPending = true;
    if (preserveSource) {
        id<MTLBlitCommandEncoder> preserve = [ms->currentCommandBuffer blitCommandEncoder];
        if (!preserve) {
            if (resume) GLMetalRestartRenderPassForReadback(ctx);
            return fail(0x0505);
        }
        for (NSUInteger mip = 0; mip < preserveSource.mipmapLevelCount; ++mip) {
            [preserve copyFromTexture:preserveSource sourceSlice:0 sourceLevel:mip sourceOrigin:MTLOriginMake(0,0,0)
                sourceSize:MTLSizeMake(std::max(NSUInteger(1),dst.width >> mip),std::max(NSUInteger(1),dst.height >> mip),1)
                toTexture:dst destinationSlice:0 destinationLevel:mip destinationOrigin:MTLOriginMake(0,0,0)];
        }
        [preserve endEncoding];
    }
    id<MTLBlitCommandEncoder> blit = nil;
    if (hasPixels) {
        id<MTLComputeCommandEncoder> compute = [ms->currentCommandBuffer computeCommandEncoder];
        if (!compute) {
            if (resume) GLMetalRestartRenderPassForReadback(ctx);
            return fail(0x0505);
        }
        [compute setComputePipelineState:ms->textureCopyPipeline];
        [compute setTexture:src atIndex:0];
        [compute setTexture:scratch atIndex:1];
        [compute setBytes:&u length:sizeof(u) atIndex:0];
        const NSUInteger tw = ms->textureCopyPipeline.threadExecutionWidth;
        [compute dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(tw, 1, 1)];
        [compute endEncoding];
        blit = [ms->currentCommandBuffer blitCommandEncoder];
        if (blit) {
            [blit copyFromTexture:scratch sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                sourceSize:MTLSizeMake(w,h,1) toTexture:dst destinationSlice:0 destinationLevel:level
                destinationOrigin:MTLOriginMake(xoffset + left,yoffset + bottom,0)];
            [blit endEncoding];
        }
    }
    // Resuming on the same command buffer keeps draw/copy/draw order and keeps
    // ring slots and scratch alive until completion.
    if (resume) {
        if (!GLMetalRestartRenderPassForReadback(ctx)) return fail(0x0505);
    } else {
        GLMetalCommitCommandBuffer(ms, ms->currentCommandBuffer);
        ms->lastCommittedBuffer = ms->currentCommandBuffer;
        ms->currentCommandBuffer = nil;
    }
    return !hasPixels || blit ? true : fail(0x0505);
}

static uint8_t *GLMetalReadFramebufferRectFromTexture(GLContext *ctx, int x, int y,
    int width, int height, int *out_len, id<MTLTexture> source)
{
    if (out_len) *out_len = 0;
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->initialized || width <= 0 || height <= 0) return NULL;

    if (!ms->overlayTexture) GLMetalBeginFrame(ctx);
    id<MTLTexture> srcTex = source ? source : GLMetalReadColorTexture(ctx, ms);
    if (!srcTex || !GLMetalReadRectIsInTexture(srcTex, x, y, width, height)) return NULL;

    const bool restartRenderPass = ms->renderPassActive;
    if (restartRenderPass) {
        GLMetalEndAndCommitForReadback(ms);
    } else {
        GLMetalWaitForCommittedReadbackWork(ms);
    }

    MTLTextureDescriptor *stagingDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:width
                                                                                         height:height
                                                                                      mipmapped:NO];
    stagingDesc.usage = MTLTextureUsageShaderRead;
    stagingDesc.storageMode = MTLStorageModeShared;
    id<MTLTexture> staging = [ms->device newTextureWithDescriptor:stagingDesc];
    if (!staging) {
        if (restartRenderPass) GLMetalRestartRenderPassForReadback(ctx);
        return NULL;
    }

    id<MTLCommandBuffer> blitCmdBuf = [ms->commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [blitCmdBuf blitCommandEncoder];
    const uint32_t sourceY =
        GLMetalTextureYForGLRead(y, height, (uint32_t)[srcTex height]);
    [blit copyFromTexture:srcTex sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake((NSUInteger)x, sourceY, 0)
               sourceSize:MTLSizeMake((NSUInteger)width, (NSUInteger)height, 1)
                toTexture:staging destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [blitCmdBuf commit];
    [blitCmdBuf waitUntilCompleted];

    int bufLen = width * height * 4;
    uint8_t *pixels = (uint8_t *)malloc(bufLen);
    if (!pixels) {
        if (restartRenderPass) GLMetalRestartRenderPassForReadback(ctx);
        return NULL;
    }

    [staging getBytes:pixels bytesPerRow:width * 4 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];

    if (restartRenderPass) GLMetalRestartRenderPassForReadback(ctx);

    if (out_len) *out_len = bufLen;
    return pixels;
}


uint8_t *GLMetalReadFramebufferRect(GLContext *ctx, int x, int y, int width, int height, int *out_len)
{
    return GLMetalReadFramebufferRectFromTexture(ctx, x, y, width, height, out_len, nil);
}

static bool GLMetalStoreReadPixelsToGuest(GLContext *ctx, const uint8_t *pixels,
    int32_t width, int32_t height, uint32_t format, uint32_t type, uint32_t address)
{
    return GLStoreReadbackPixels(ctx,pixels,width,height,format,type,address,true,
        [](uint32_t p,uint8_t v){WriteMacInt8(p,v);});
}

// Texture uploads store GL row zero as Metal row zero, unlike the framebuffer.
bool GLMetalReadTexture(GLContext *ctx, GLTextureObject *obj, int32_t level,
    int32_t width, int32_t height, std::vector<uint8_t> &pixels)
{
    GLMetalSynchronizeTextureAccess(ctx);
    GLMetalState *ms=(GLMetalState *)ctx->metal;
    id<MTLTexture> src=(__bridge id<MTLTexture>)obj->metal_texture;
    if (!ms || !ms->initialized || !src || level >= (int32_t)src.mipmapLevelCount ||
        src.textureType != MTLTextureType2D || src.pixelFormat != MTLPixelFormatBGRA8Unorm ||
        std::max(NSUInteger(1),src.width >> level) != NSUInteger(width) ||
        std::max(NSUInteger(1),src.height >> level) != NSUInteger(height)) {
        if (!ctx->last_error) ctx->last_error=0x0502;
        return false;
    }
    const bool restart=ms->renderPassActive;
    if (restart) GLMetalEndAndCommitForReadback(ms);
    else GLMetalWaitForCommittedReadbackWork(ms);
    const NSUInteger pitch=(NSUInteger(width)*4+255)&~NSUInteger(255);
    id<MTLBuffer> staging=[ms->device newBufferWithLength:pitch*height options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb=[ms->commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit=staging ? [cb blitCommandEncoder] : nil;
    if (blit) {
        [blit copyFromTexture:src sourceSlice:0 sourceLevel:level sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(width,height,1) toBuffer:staging destinationOffset:0
            destinationBytesPerRow:pitch destinationBytesPerImage:pitch*height];
        [blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
    }
    const bool ok=blit && cb.status==MTLCommandBufferStatusCompleted;
    if (ok) {
        pixels.resize(size_t(width)*height*4);
        for(int32_t row=0;row<height;++row)
            memcpy(pixels.data()+size_t(row)*width*4,(const uint8_t *)staging.contents+row*pitch,size_t(width)*4);
        GLTexturePrepareReadbackBGRA(pixels.data(), pixels.size(), GLTextureLevelBaseFormat(*obj, level));
    } else if (!ctx->last_error) ctx->last_error=0x0505;
    if (restart) GLMetalRestartRenderPassForReadback(ctx);
    return ok;
}

void NativeGLReadPixels(GLContext *ctx, int32_t x, int32_t y, int32_t width, int32_t height,
                         uint32_t format, uint32_t type, uint32_t mac_pixels)
{
    GL_METAL_VLOG("ReadPixels request: rect=(%d,%d %dx%d) format=0x%x type=0x%x dst=0x%08x pack=(align=%d row=%d skip=%d,%d)",
                 x, y, width, height, format, type, mac_pixels,
                 ctx->pixel_store.pack_alignment, ctx->pixel_store.pack_row_length,
                 ctx->pixel_store.pack_skip_pixels, ctx->pixel_store.pack_skip_rows);
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->initialized || mac_pixels == 0 || width <= 0 || height <= 0) return;

    if (!ms->overlayTexture) GLMetalBeginFrame(ctx);
    if (format != GL_DEPTH_COMPONENT) {
        const uint32_t error = GLPixelPackError(format, type);
        if (error) {
            if (!ctx->last_error) ctx->last_error = error;
            return;
        }
    }

    const bool restartRenderPass = ms->renderPassActive;
    if (restartRenderPass) {
        GLMetalEndAndCommitForReadback(ms);
    } else {
        GLMetalWaitForCommittedReadbackWork(ms);
    }

    auto restartIfNeeded = [&]() {
        if (restartRenderPass) GLMetalRestartRenderPassForReadback(ctx);
    };

    if (format == GL_DEPTH_COMPONENT && type == GL_UNSIGNED_SHORT) {
        GLMetalPackLayout layout;
        if (!GLMetalGetPackLayout(ctx, width, height, 2, mac_pixels, layout)) {
            restartIfNeeded();
            return;
        }
        id<MTLTexture> depthTex = ms->depthBuffer;
        if (!depthTex || !GLMetalReadRectIsInTexture(depthTex, x, y, width, height)) {
            restartIfNeeded();
            return;
        }

        NSUInteger depthRowBytes = 0;
        id<MTLBuffer> staging = GLMetalGetDepthReadbackBuffer(ms, width, height, &depthRowBytes);
        if (!staging) {
            if (!ctx->last_error) ctx->last_error = 0x0505; // GL_OUT_OF_MEMORY
            restartIfNeeded();
            return;
        }

        id<MTLCommandBuffer> blitCmdBuf = [ms->commandQueue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [blitCmdBuf blitCommandEncoder];
        if (!blit) {
            if (!ctx->last_error) ctx->last_error = 0x0505;
            restartIfNeeded();
            return;
        }
        const uint32_t sourceY =
            GLMetalTextureYForGLRead(y, height, (uint32_t)[depthTex height]);
        [blit copyFromTexture:depthTex
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake((NSUInteger)x, sourceY, 0)
                   sourceSize:MTLSizeMake((NSUInteger)width, (NSUInteger)height, 1)
                     toBuffer:staging
            destinationOffset:0
       destinationBytesPerRow:depthRowBytes
     destinationBytesPerImage:depthRowBytes * (NSUInteger)height
                      options:MTLBlitOptionDepthFromDepthStencil];
        [blit endEncoding];
        [blitCmdBuf commit];
        [blitCmdBuf waitUntilCompleted];
        if (blitCmdBuf.status != MTLCommandBufferStatusCompleted) {
            if (!ctx->last_error) ctx->last_error = 0x0502; // GL_INVALID_OPERATION
            restartIfNeeded();
            return;
        }
        const uint8_t *depthBytes = (const uint8_t *)[staging contents];

        const int32_t bytesPerPixel = 2;
        float sampleDepth = 0.0f;
        uint16_t samplePacked = 0;
        bool haveSampleDepth = false;
        for (int32_t row = 0; row < height; row++) {
            const int32_t srcRow = height - 1 - row;
            for (int32_t col = 0; col < width; col++) {
                const float *depthRow = (const float *)(depthBytes + (NSUInteger)srcRow * depthRowBytes);
                const float depth = depthRow[col];
                const uint16_t packed =
                    GLMetalDepthFloatToUnsignedShort(depth);
                if (!haveSampleDepth) {
                    sampleDepth = depth;
                    samplePacked = packed;
                    haveSampleDepth = true;
                }
                const uint32_t dstAddr = (uint32_t)(mac_pixels + layout.start +
                    (uint64_t)row * layout.rowStride + (uint64_t)col * bytesPerPixel);
                uint8_t output[2]={uint8_t(packed>>8),uint8_t(packed)};
                GLReadbackApplyByteOrder(ctx->pixel_store.pack_swap_bytes,GL_UNSIGNED_SHORT,2,output);
                WriteMacInt8(dstAddr,output[0]);WriteMacInt8(dstAddr+1,output[1]);
            }
        }

        restartIfNeeded();
        GL_METAL_VLOG("NativeGLReadPixels: depth read %dx%d at (%d,%d) sample=%.6f packed=0x%04x -> mac addr 0x%08x",
                     width, height, x, y, sampleDepth, samplePacked, mac_pixels);
        return;
    }

    if (format == GL_DEPTH_COMPONENT) {
        GL_METAL_LOG("NativeGLReadPixels: unsupported depth format/type fmt=0x%x type=0x%x",
                     format, type);
        restartIfNeeded();
        return;
    }

    id<MTLTexture> srcTex = nil;
    if (ms->overlayTexture) {
        srcTex = GLMetalReadColorTexture(ctx, ms);
    }
    if (!srcTex || !GLMetalReadRectIsInTexture(srcTex, x, y, width, height)) {
        GL_METAL_LOG("NativeGLReadPixels: no overlay texture available");
        restartIfNeeded();
        return;
    }

    // Shared staging texture for CPU readback
    MTLTextureDescriptor *stagingDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:width
                                                                                         height:height
                                                                                      mipmapped:NO];
    stagingDesc.usage = MTLTextureUsageShaderRead;
    stagingDesc.storageMode = MTLStorageModeShared;

    id<MTLTexture> staging = [ms->device newTextureWithDescriptor:stagingDesc];
    if (!staging) {
        restartIfNeeded();
        return;
    }

    id<MTLCommandBuffer> blitCmdBuf = [ms->commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [blitCmdBuf blitCommandEncoder];
    const uint32_t sourceY =
        GLMetalTextureYForGLRead(y, height, (uint32_t)[srcTex height]);

    [blit copyFromTexture:srcTex
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake((NSUInteger)x, sourceY, 0)
               sourceSize:MTLSizeMake((NSUInteger)width, (NSUInteger)height, 1)
                toTexture:staging
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];

    [blit endEncoding];
    [blitCmdBuf commit];
    [blitCmdBuf waitUntilCompleted];

    uint8_t *stagingBytes = (uint8_t *)malloc((size_t)width * height * 4u);
    if (!stagingBytes) {
        restartIfNeeded();
        return;
    }

    MTLRegion region = MTLRegionMake2D(0, 0, width, height);
    [staging getBytes:stagingBytes bytesPerRow:width * 4 fromRegion:region mipmapLevel:0];

    GLMetalStoreReadPixelsToGuest(ctx, stagingBytes, width, height, format, type, mac_pixels);

    free(stagingBytes);

    restartIfNeeded();

    GL_METAL_VLOG("NativeGLReadPixels: read %dx%d at (%d,%d) -> mac addr 0x%08x",
                 width, height, x, y, mac_pixels);
}


// ==========================================================================
//  Accumulation buffer -- CPU-side float buffer with Metal readback/writeback
// ==========================================================================

#define GL_ACCUM_OP    0x0100
#define GL_LOAD_OP     0x0101
#define GL_RETURN_OP   0x0102
#define GL_MULT_OP     0x0103
#define GL_ADD_OP      0x0104

static void gl_accum_ensure_allocated(GLContext *ctx, int width, int height)
{
    if (ctx->accum_allocated && ctx->accum_width == width && ctx->accum_height == height)
        return;

    if (ctx->accum_buffer) {
        free(ctx->accum_buffer);
        ctx->accum_buffer = nullptr;
    }

    ctx->accum_buffer = (float *)calloc(width * height * 4, sizeof(float));
    if (ctx->accum_buffer) {
        ctx->accum_width = width;
        ctx->accum_height = height;
        ctx->accum_allocated = true;
        GL_METAL_LOG("Accum buffer allocated: %dx%d (%zu bytes)",
                     width, height, (size_t)(width * height * 4 * sizeof(float)));
    } else {
        ctx->accum_allocated = false;
        GL_METAL_LOG("WARNING: Accum buffer allocation failed for %dx%d", width, height);
    }
}

// Accumulator rows use the same top-to-bottom order as Metal readback.
static GLMetalScissorRect gl_accum_rect(GLContext *ctx, uint32_t width, uint32_t height)
{
    if (ctx->scissor_test)
        return GLMetalMakeScissorRect(ctx->scissor_box[0], ctx->scissor_box[1],
                                      ctx->scissor_box[2], ctx->scissor_box[3],
                                      width, height);
    return {0, 0, width, height, width != 0 && height != 0};
}

// ReadFramebufferRect submits pending rendering and waits for the GPU before
// reading shared staging storage. It also preserves depth and stencil on resume.
static float *gl_accum_read_framebuffer(GLContext *ctx, int *out_w, int *out_h)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->initialized || !ms->overlayTexture) return nullptr;
    const int width = (int)ms->overlayTexture.width;
    const int height = (int)ms->overlayTexture.height;
    int byteCount = 0;
    uint8_t *raw = GLMetalReadFramebufferRect(ctx, 0, 0, width, height, &byteCount);
    if (!raw) return nullptr;

    float *result = (float *)malloc((size_t)byteCount * sizeof(float));
    if (!result) { free(raw); return nullptr; }
    for (int i = 0; i < width * height; i++) {
        result[i * 4 + 0] = raw[i * 4 + 2] / 255.0f;
        result[i * 4 + 1] = raw[i * 4 + 1] / 255.0f;
        result[i * 4 + 2] = raw[i * 4 + 0] / 255.0f;
        result[i * 4 + 3] = raw[i * 4 + 3] / 255.0f;
    }
    free(raw);
    *out_w = width;
    *out_h = height;
    return result;
}

static void gl_accum_restart_encoder(GLContext *ctx)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (ms && ms->initialized && ms->overlayTexture && !ms->currentEncoder)
        GLMetalRestartRenderPassForReadback(ctx);
}

// GL_RETURN bypasses blending, depth and stencil, but honors the scissor and
// color write masks. Read/merge masked channels in shared staging storage and
// blit the result into the private overlay, preserving the other attachments.
static void gl_accum_write_color_target(GLContext *ctx, float scale, id<MTLTexture> target,
    id<MTLTexture> presentationTarget)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->initialized || !ctx->accum_allocated || !ms->overlayTexture) return;
    if (!ctx->color_mask[0] && !ctx->color_mask[1] &&
        !ctx->color_mask[2] && !ctx->color_mask[3]) return;

    const uint32_t dstW = (uint32_t)ms->overlayTexture.width;
    const uint32_t dstH = (uint32_t)ms->overlayTexture.height;
    GLMetalScissorRect rect = gl_accum_rect(ctx, dstW, dstH);
    if (!rect.valid) return;
    const uint32_t width = std::min(dstW, (uint32_t)ctx->accum_width);
    const uint32_t height = std::min(dstH, (uint32_t)ctx->accum_height);
    if (rect.x >= width || rect.y >= height) return;
    rect.width = std::min(rect.width, width - rect.x);
    rect.height = std::min(rect.height, height - rect.y);

    int byteCount = 0;
    uint8_t *pixels = GLMetalReadFramebufferRectFromTexture(ctx, 0, 0, dstW, dstH, &byteCount, target);
    if (!pixels) return;
    uint8_t *visible = presentationTarget
        ? GLMetalReadFramebufferRectFromTexture(ctx, 0, 0, dstW, dstH, &byteCount, presentationTarget)
        : nullptr;
    if (presentationTarget && !visible) { free(pixels); return; }
    for (uint32_t y = rect.y; y < rect.y + rect.height; ++y) {
        for (uint32_t x = rect.x; x < rect.x + rect.width; ++x) {
            const size_t source = ((size_t)y * ctx->accum_width + x) * 4;
            const size_t dest = ((size_t)y * dstW + x) * 4;
            for (unsigned channel = 0; channel < 4; ++channel) {
                if (!ctx->color_mask[channel]) continue;
                const float value = std::max(0.0f, std::min(1.0f,
                    ctx->accum_buffer[source + channel] * scale));
                const unsigned bgraChannel = channel == 0 ? 2 : channel == 2 ? 0 : channel;
                pixels[dest + bgraChannel] = (uint8_t)(value * 255.0f + 0.5f);
                if (visible && channel < 3) {
                    visible[dest + bgraChannel] = pixels[dest + bgraChannel];
                    visible[dest + 3] = 255;
                }
            }
        }
    }

    auto desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                 width:dstW height:dstH mipmapped:NO];
    desc.storageMode = MTLStorageModeShared;
    id<MTLTexture> staging = [ms->device newTextureWithDescriptor:desc];
    id<MTLTexture> visibleStaging = visible ? [ms->device newTextureWithDescriptor:desc] : nil;
    if (!staging || (visible && !visibleStaging)) {
        free(visible);
        free(pixels);
        if (!ctx->last_error) ctx->last_error = 0x0505;
        return;
    }
    [staging replaceRegion:MTLRegionMake2D(0, 0, dstW, dstH) mipmapLevel:0
                withBytes:pixels bytesPerRow:dstW * 4];
    free(pixels);
    if (visible) {
        [visibleStaging replaceRegion:MTLRegionMake2D(0, 0, dstW, dstH) mipmapLevel:0
                            withBytes:visible bytesPerRow:dstW * 4];
        free(visible);
    }

    if (ms->currentEncoder) {
        [ms->currentEncoder endEncoding];
        ms->currentEncoder = nil;
    }
    if (!ms->currentCommandBuffer)
        ms->currentCommandBuffer = [ms->commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [ms->currentCommandBuffer blitCommandEncoder];
    [blit copyFromTexture:staging sourceSlice:0 sourceLevel:0
            sourceOrigin:MTLOriginMake(rect.x, rect.y, 0)
              sourceSize:MTLSizeMake(rect.width, rect.height, 1)
               toTexture:target destinationSlice:0 destinationLevel:0
       destinationOrigin:MTLOriginMake(rect.x, rect.y, 0)];
    if (visibleStaging) {
        [blit copyFromTexture:visibleStaging sourceSlice:0 sourceLevel:0
                sourceOrigin:MTLOriginMake(rect.x, rect.y, 0)
                  sourceSize:MTLSizeMake(rect.width, rect.height, 1)
                   toTexture:presentationTarget destinationSlice:0 destinationLevel:0
           destinationOrigin:MTLOriginMake(rect.x, rect.y, 0)];
    }
    [blit endEncoding];
    gl_accum_restart_encoder(ctx);
}

static void gl_accum_write_framebuffer(GLContext *ctx, float scale)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    const unsigned targets = GLMetalDrawTargets(ctx);
    if (targets & 1) {
        gl_accum_write_color_target(ctx, scale, ms->overlayTexture, ms->presentationTexture);
        gl_note_front_modified(ctx, ms->overlayTexture);
    }
    if (targets & 2) gl_accum_write_color_target(ctx, scale, ms->backTexture, ms->presentationBackTexture);
}

void NativeGLAccum(GLContext *ctx, uint32_t op, float value)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->initialized) return;

    // LOAD/ACCUM use the selected read buffer; RETURN uses draw buffers.
    // Reacquire logical roles after swaps before reading or writing them.
    if ((op == GL_ACCUM_OP || op == GL_LOAD_OP ||
         (op == GL_RETURN_OP && ctx->accum_allocated)) && !ms->renderPassActive) {
        GLMetalBeginFrame(ctx);
        if (!ms->renderPassActive) return;
    }

    switch (op) {
    case GL_ACCUM_OP:
    case GL_LOAD_OP: {
        int width = 0, height = 0;
        float *fb = gl_accum_read_framebuffer(ctx, &width, &height);
        if (!fb) { gl_accum_restart_encoder(ctx); return; }
        gl_accum_ensure_allocated(ctx, width, height);
        if (ctx->accum_allocated) {
            const GLMetalScissorRect rect = gl_accum_rect(ctx, width, height);
            for (uint32_t y = rect.y; y < rect.y + rect.height; ++y) {
                for (uint32_t x = rect.x; x < rect.x + rect.width; ++x) {
                    const size_t pixel = ((size_t)y * width + x) * 4;
                    for (unsigned c = 0; c < 4; ++c) {
                        const float scaled = fb[pixel + c] * value;
                        if (op == GL_LOAD_OP) ctx->accum_buffer[pixel + c] = scaled;
                        else ctx->accum_buffer[pixel + c] += scaled;
                    }
                }
            }
        }
        free(fb);
        gl_accum_restart_encoder(ctx);
        break;
    }
    case GL_MULT_OP:
    case GL_ADD_OP: {
        if (!ctx->accum_allocated) return;
        const GLMetalScissorRect rect = gl_accum_rect(ctx, ctx->accum_width, ctx->accum_height);
        for (uint32_t y = rect.y; y < rect.y + rect.height; ++y) {
            for (uint32_t x = rect.x; x < rect.x + rect.width; ++x) {
                const size_t pixel = ((size_t)y * ctx->accum_width + x) * 4;
                for (unsigned c = 0; c < 4; ++c) {
                    if (op == GL_MULT_OP) ctx->accum_buffer[pixel + c] *= value;
                    else ctx->accum_buffer[pixel + c] += value;
                }
            }
        }
        break;
    }
    case GL_RETURN_OP:
        gl_accum_write_framebuffer(ctx, value);
        break;
    default:
        GL_METAL_LOG("WARNING: glAccum unknown op 0x%04x", op);
        break;
    }
}


// ==========================================================================
//  Immediate mode handlers - called from gl_dispatch.cpp
// ==========================================================================

void NativeGLBegin(GLContext *ctx, uint32_t mode)
{
	ctx->in_begin = true;
	ctx->im_mode = mode;
	ctx->im_vertices.clear();
	GL_METAL_VLOG("glBegin(0x%04x)", mode);
}

// In gl_state.cpp


void NativeGLEnd(GLContext *ctx)
{
    ctx->in_begin = false;
    GLMetalFlushImmediateMode(ctx);
	GL_METAL_VLOG("glEnd: %s %zu vertices",
	             ctx->render_mode == 0x1C02 ? "selection" : "flushed",
	             ctx->im_vertices.size());
}


// ---- Vertex submission ----

static inline void PushVertex(GLContext *ctx, float x, float y, float z, float w)
{
    GLVertex v;
    v.position[0] = x; v.position[1] = y; v.position[2] = z; v.position[3] = w;
    memcpy(v.color, ctx->current_color, sizeof(float) * 4);
    memcpy(v.normal, ctx->current_normal, sizeof(float) * 3);
    for (int u = 0; u < 4; u++) {
        memcpy(v.texcoord[u], ctx->current_texcoord[u], sizeof(float) * 4);
    }
    memcpy(v.secondary_color, ctx->current_secondary_color, sizeof(float) * 3);
    v.fog_coord = ctx->current_fog_coord;
    GLSnapshotVertexMaterial(*ctx, v);
    v.edge_flag=ctx->current_edge_flag;
    ctx->im_vertices.push_back(v);
}

void NativeGLVertex2f(GLContext *ctx, float x, float y) { PushVertex(ctx, x, y, 0.0f, 1.0f); }
void NativeGLVertex3f(GLContext *ctx, float x, float y, float z) { PushVertex(ctx, x, y, z, 1.0f); }
void NativeGLVertex4f(GLContext *ctx, float x, float y, float z, float w) { PushVertex(ctx, x, y, z, w); }

void NativeGLVertex2d(GLContext *ctx, double x, double y) { PushVertex(ctx, (float)x, (float)y, 0.0f, 1.0f); }
void NativeGLVertex3d(GLContext *ctx, double x, double y, double z) { PushVertex(ctx, (float)x, (float)y, (float)z, 1.0f); }
void NativeGLVertex4d(GLContext *ctx, double x, double y, double z, double w) { PushVertex(ctx, (float)x, (float)y, (float)z, (float)w); }

void NativeGLVertex2i(GLContext *ctx, int32_t x, int32_t y) { PushVertex(ctx, (float)x, (float)y, 0.0f, 1.0f); }
void NativeGLVertex3i(GLContext *ctx, int32_t x, int32_t y, int32_t z) { PushVertex(ctx, (float)x, (float)y, (float)z, 1.0f); }
void NativeGLVertex4i(GLContext *ctx, int32_t x, int32_t y, int32_t z, int32_t w) { PushVertex(ctx, (float)x, (float)y, (float)z, (float)w); }

void NativeGLVertex2s(GLContext *ctx, int16_t x, int16_t y) { PushVertex(ctx, (float)x, (float)y, 0.0f, 1.0f); }
void NativeGLVertex3s(GLContext *ctx, int16_t x, int16_t y, int16_t z) { PushVertex(ctx, (float)x, (float)y, (float)z, 1.0f); }
void NativeGLVertex4s(GLContext *ctx, int16_t x, int16_t y, int16_t z, int16_t w) { PushVertex(ctx, (float)x, (float)y, (float)z, (float)w); }

// Pointer variants read from Mac memory
void NativeGLVertex2fv(GLContext *ctx, uint32_t mac_ptr) {
    float v[2];
    uint32_t tmp;
    tmp = ReadMacInt32(mac_ptr); memcpy(&v[0], &tmp, 4);
    tmp = ReadMacInt32(mac_ptr + 4); memcpy(&v[1], &tmp, 4);
    PushVertex(ctx, v[0], v[1], 0.0f, 1.0f);
}
void NativeGLVertex3fv(GLContext *ctx, uint32_t mac_ptr) {
    float v[3];
    for (int i = 0; i < 3; i++) { uint32_t tmp = ReadMacInt32(mac_ptr + i * 4); memcpy(&v[i], &tmp, 4); }
    PushVertex(ctx, v[0], v[1], v[2], 1.0f);
}
void NativeGLVertex4fv(GLContext *ctx, uint32_t mac_ptr) {
    float v[4];
    for (int i = 0; i < 4; i++) { uint32_t tmp = ReadMacInt32(mac_ptr + i * 4); memcpy(&v[i], &tmp, 4); }
    PushVertex(ctx, v[0], v[1], v[2], v[3]);
}
void NativeGLVertex2dv(GLContext *ctx, uint32_t mac_ptr) {
    double v[2];
    for (int i = 0; i < 2; i++) {
        uint64_t b = ((uint64_t)ReadMacInt32(mac_ptr + i * 8) << 32) | ReadMacInt32(mac_ptr + i * 8 + 4);
        memcpy(&v[i], &b, 8);
    }
    PushVertex(ctx, (float)v[0], (float)v[1], 0.0f, 1.0f);
}
void NativeGLVertex3dv(GLContext *ctx, uint32_t mac_ptr) {
    double v[3];
    for (int i = 0; i < 3; i++) {
        uint64_t b = ((uint64_t)ReadMacInt32(mac_ptr + i * 8) << 32) | ReadMacInt32(mac_ptr + i * 8 + 4);
        memcpy(&v[i], &b, 8);
    }
    PushVertex(ctx, (float)v[0], (float)v[1], (float)v[2], 1.0f);
}
void NativeGLVertex4dv(GLContext *ctx, uint32_t mac_ptr) {
    double v[4];
    for (int i = 0; i < 4; i++) {
        uint64_t b = ((uint64_t)ReadMacInt32(mac_ptr + i * 8) << 32) | ReadMacInt32(mac_ptr + i * 8 + 4);
        memcpy(&v[i], &b, 8);
    }
    PushVertex(ctx, (float)v[0], (float)v[1], (float)v[2], (float)v[3]);
}
void NativeGLVertex2iv(GLContext *ctx, uint32_t mac_ptr) {
    int32_t v[2];
    v[0] = (int32_t)ReadMacInt32(mac_ptr); v[1] = (int32_t)ReadMacInt32(mac_ptr + 4);
    PushVertex(ctx, (float)v[0], (float)v[1], 0.0f, 1.0f);
}
void NativeGLVertex3iv(GLContext *ctx, uint32_t mac_ptr) {
    int32_t v[3];
    for (int i = 0; i < 3; i++) v[i] = (int32_t)ReadMacInt32(mac_ptr + i * 4);
    PushVertex(ctx, (float)v[0], (float)v[1], (float)v[2], 1.0f);
}
void NativeGLVertex4iv(GLContext *ctx, uint32_t mac_ptr) {
    int32_t v[4];
    for (int i = 0; i < 4; i++) v[i] = (int32_t)ReadMacInt32(mac_ptr + i * 4);
    PushVertex(ctx, (float)v[0], (float)v[1], (float)v[2], (float)v[3]);
}
void NativeGLVertex2sv(GLContext *ctx, uint32_t mac_ptr) {
    int16_t x = (int16_t)ReadMacInt16(mac_ptr), y = (int16_t)ReadMacInt16(mac_ptr + 2);
    PushVertex(ctx, (float)x, (float)y, 0.0f, 1.0f);
}
void NativeGLVertex3sv(GLContext *ctx, uint32_t mac_ptr) {
    int16_t v[3];
    for (int i = 0; i < 3; i++) v[i] = (int16_t)ReadMacInt16(mac_ptr + i * 2);
    PushVertex(ctx, (float)v[0], (float)v[1], (float)v[2], 1.0f);
}
void NativeGLVertex4sv(GLContext *ctx, uint32_t mac_ptr) {
    int16_t v[4];
    for (int i = 0; i < 4; i++) v[i] = (int16_t)ReadMacInt16(mac_ptr + i * 2);
    PushVertex(ctx, (float)v[0], (float)v[1], (float)v[2], (float)v[3]);
}


// ---- Color submission ----

void NativeGLColor3f(GLContext *ctx, float r, float g, float b) {
    ctx->current_color[0] = r; ctx->current_color[1] = g;
    ctx->current_color[2] = b; ctx->current_color[3] = 1.0f;
    GLApplyColorMaterial(ctx);
}
void NativeGLColor4f(GLContext *ctx, float r, float g, float b, float a) {
    ctx->current_color[0] = r; ctx->current_color[1] = g;
    ctx->current_color[2] = b; ctx->current_color[3] = a;
    GLApplyColorMaterial(ctx);
}
void NativeGLColor3d(GLContext *ctx, double r, double g, double b) {
    NativeGLColor3f(ctx, (float)r, (float)g, (float)b);
}
void NativeGLColor4d(GLContext *ctx, double r, double g, double b, double a) {
    NativeGLColor4f(ctx, (float)r, (float)g, (float)b, (float)a);
}
void NativeGLColor3b(GLContext *ctx, int8_t r, int8_t g, int8_t b) {
    NativeGLColor3f(ctx, (2.0f*r+1)/255.0f, (2.0f*g+1)/255.0f, (2.0f*b+1)/255.0f);
}
void NativeGLColor4b(GLContext *ctx, int8_t r, int8_t g, int8_t b, int8_t a) {
    NativeGLColor4f(ctx, (2.0f*r+1)/255.0f, (2.0f*g+1)/255.0f, (2.0f*b+1)/255.0f, (2.0f*a+1)/255.0f);
}
void NativeGLColor3ub(GLContext *ctx, uint8_t r, uint8_t g, uint8_t b) {
    NativeGLColor3f(ctx, r / 255.0f, g / 255.0f, b / 255.0f);
}
void NativeGLColor4ub(GLContext *ctx, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    NativeGLColor4f(ctx, r / 255.0f, g / 255.0f, b / 255.0f, a / 255.0f);
}
void NativeGLColor3i(GLContext *ctx, int32_t r, int32_t g, int32_t b) {
    NativeGLColor3f(ctx, (float)((2.0*double(r)+1.0)/double(UINT32_MAX)),
                         (float)((2.0*double(g)+1.0)/double(UINT32_MAX)),
                         (float)((2.0*double(b)+1.0)/double(UINT32_MAX)));
}
void NativeGLColor4i(GLContext *ctx, int32_t r, int32_t g, int32_t b, int32_t a) {
    NativeGLColor4f(ctx, (float)((2.0*double(r)+1.0)/double(UINT32_MAX)),
                         (float)((2.0*double(g)+1.0)/double(UINT32_MAX)),
                         (float)((2.0*double(b)+1.0)/double(UINT32_MAX)),
                         (float)((2.0*double(a)+1.0)/double(UINT32_MAX)));
}
void NativeGLColor3s(GLContext *ctx, int16_t r, int16_t g, int16_t b) {
    NativeGLColor3f(ctx, (2.0f*r+1)/65535.0f, (2.0f*g+1)/65535.0f, (2.0f*b+1)/65535.0f);
}
void NativeGLColor4s(GLContext *ctx, int16_t r, int16_t g, int16_t b, int16_t a) {
    NativeGLColor4f(ctx, (2.0f*r+1)/65535.0f, (2.0f*g+1)/65535.0f, (2.0f*b+1)/65535.0f, (2.0f*a+1)/65535.0f);
}
void NativeGLColor3ui(GLContext *ctx, uint32_t r, uint32_t g, uint32_t b) {
    NativeGLColor3f(ctx, r / (float)UINT32_MAX, g / (float)UINT32_MAX, b / (float)UINT32_MAX);
}
void NativeGLColor4ui(GLContext *ctx, uint32_t r, uint32_t g, uint32_t b, uint32_t a) {
    NativeGLColor4f(ctx, r / (float)UINT32_MAX, g / (float)UINT32_MAX, b / (float)UINT32_MAX, a / (float)UINT32_MAX);
}
void NativeGLColor3us(GLContext *ctx, uint16_t r, uint16_t g, uint16_t b) {
    NativeGLColor3f(ctx, r / 65535.0f, g / 65535.0f, b / 65535.0f);
}
void NativeGLColor4us(GLContext *ctx, uint16_t r, uint16_t g, uint16_t b, uint16_t a) {
    NativeGLColor4f(ctx, r / 65535.0f, g / 65535.0f, b / 65535.0f, a / 65535.0f);
}

static inline float ReadMacFloat(uint32_t addr) {
    uint32_t bits = ReadMacInt32(addr);
    float f; memcpy(&f, &bits, 4);
    return f;
}

void NativeGLColor3fv(GLContext *ctx, uint32_t mac_ptr) {
    NativeGLColor3f(ctx, ReadMacFloat(mac_ptr), ReadMacFloat(mac_ptr + 4), ReadMacFloat(mac_ptr + 8));
}
void NativeGLColor4fv(GLContext *ctx, uint32_t mac_ptr) {
    NativeGLColor4f(ctx, ReadMacFloat(mac_ptr), ReadMacFloat(mac_ptr + 4),
                         ReadMacFloat(mac_ptr + 8), ReadMacFloat(mac_ptr + 12));
}
void NativeGLColor3bv(GLContext *ctx, uint32_t mac_ptr) {
    NativeGLColor3b(ctx, (int8_t)ReadMacInt8(mac_ptr), (int8_t)ReadMacInt8(mac_ptr + 1), (int8_t)ReadMacInt8(mac_ptr + 2));
}
void NativeGLColor4bv(GLContext *ctx, uint32_t mac_ptr) {
    NativeGLColor4b(ctx, (int8_t)ReadMacInt8(mac_ptr), (int8_t)ReadMacInt8(mac_ptr + 1),
                         (int8_t)ReadMacInt8(mac_ptr + 2), (int8_t)ReadMacInt8(mac_ptr + 3));
}
void NativeGLColor3ubv(GLContext *ctx, uint32_t mac_ptr) {
    NativeGLColor3ub(ctx, ReadMacInt8(mac_ptr), ReadMacInt8(mac_ptr + 1), ReadMacInt8(mac_ptr + 2));
}
void NativeGLColor4ubv(GLContext *ctx, uint32_t mac_ptr) {
    NativeGLColor4ub(ctx, ReadMacInt8(mac_ptr), ReadMacInt8(mac_ptr + 1),
                          ReadMacInt8(mac_ptr + 2), ReadMacInt8(mac_ptr + 3));
}
void NativeGLColor3dv(GLContext *ctx, uint32_t mac_ptr) {
    double r, g, b;
    uint64_t bits;
    bits = ((uint64_t)ReadMacInt32(mac_ptr) << 32) | ReadMacInt32(mac_ptr + 4); memcpy(&r, &bits, 8);
    bits = ((uint64_t)ReadMacInt32(mac_ptr + 8) << 32) | ReadMacInt32(mac_ptr + 12); memcpy(&g, &bits, 8);
    bits = ((uint64_t)ReadMacInt32(mac_ptr + 16) << 32) | ReadMacInt32(mac_ptr + 20); memcpy(&b, &bits, 8);
    NativeGLColor3f(ctx, (float)r, (float)g, (float)b);
}
void NativeGLColor4dv(GLContext *ctx, uint32_t mac_ptr) {
    double v[4];
    for (int i = 0; i < 4; i++) {
        uint64_t bits = ((uint64_t)ReadMacInt32(mac_ptr + i * 8) << 32) | ReadMacInt32(mac_ptr + i * 8 + 4);
        memcpy(&v[i], &bits, 8);
    }
    NativeGLColor4f(ctx, (float)v[0], (float)v[1], (float)v[2], (float)v[3]);
}
void NativeGLColor3iv(GLContext *ctx, uint32_t mac_ptr) {
    NativeGLColor3i(ctx, (int32_t)ReadMacInt32(mac_ptr), (int32_t)ReadMacInt32(mac_ptr + 4), (int32_t)ReadMacInt32(mac_ptr + 8));
}
void NativeGLColor4iv(GLContext *ctx, uint32_t mac_ptr) {
    NativeGLColor4i(ctx, (int32_t)ReadMacInt32(mac_ptr), (int32_t)ReadMacInt32(mac_ptr + 4),
                         (int32_t)ReadMacInt32(mac_ptr + 8), (int32_t)ReadMacInt32(mac_ptr + 12));
}
void NativeGLColor3sv(GLContext *ctx, uint32_t mac_ptr) {
    NativeGLColor3s(ctx, (int16_t)ReadMacInt16(mac_ptr), (int16_t)ReadMacInt16(mac_ptr + 2), (int16_t)ReadMacInt16(mac_ptr + 4));
}
void NativeGLColor4sv(GLContext *ctx, uint32_t mac_ptr) {
    NativeGLColor4s(ctx, (int16_t)ReadMacInt16(mac_ptr), (int16_t)ReadMacInt16(mac_ptr + 2),
                         (int16_t)ReadMacInt16(mac_ptr + 4), (int16_t)ReadMacInt16(mac_ptr + 6));
}
void NativeGLColor3uiv(GLContext *ctx, uint32_t mac_ptr) {
    NativeGLColor3ui(ctx, ReadMacInt32(mac_ptr), ReadMacInt32(mac_ptr + 4), ReadMacInt32(mac_ptr + 8));
}
void NativeGLColor4uiv(GLContext *ctx, uint32_t mac_ptr) {
    NativeGLColor4ui(ctx, ReadMacInt32(mac_ptr), ReadMacInt32(mac_ptr + 4),
                          ReadMacInt32(mac_ptr + 8), ReadMacInt32(mac_ptr + 12));
}
void NativeGLColor3usv(GLContext *ctx, uint32_t mac_ptr) {
    NativeGLColor3us(ctx, ReadMacInt16(mac_ptr), ReadMacInt16(mac_ptr + 2), ReadMacInt16(mac_ptr + 4));
}
void NativeGLColor4usv(GLContext *ctx, uint32_t mac_ptr) {
    NativeGLColor4us(ctx, ReadMacInt16(mac_ptr), ReadMacInt16(mac_ptr + 2),
                          ReadMacInt16(mac_ptr + 4), ReadMacInt16(mac_ptr + 6));
}


// ---- Normal submission ----

void NativeGLNormal3f(GLContext *ctx, float x, float y, float z) {
    ctx->current_normal[0] = x; ctx->current_normal[1] = y; ctx->current_normal[2] = z;
}
void NativeGLNormal3d(GLContext *ctx, double x, double y, double z) {
    NativeGLNormal3f(ctx, (float)x, (float)y, (float)z);
}
void NativeGLNormal3b(GLContext *ctx, int8_t x, int8_t y, int8_t z) {
    // Signed byte normals map [-128,127] to [-1,1]
    NativeGLNormal3f(ctx, x / 127.0f, y / 127.0f, z / 127.0f);
}
void NativeGLNormal3i(GLContext *ctx, int32_t x, int32_t y, int32_t z) {
    NativeGLNormal3f(ctx, (float)((double)x / (double)INT32_MAX),
                          (float)((double)y / (double)INT32_MAX),
                          (float)((double)z / (double)INT32_MAX));
}
void NativeGLNormal3s(GLContext *ctx, int16_t x, int16_t y, int16_t z) {
    NativeGLNormal3f(ctx, x / 32767.0f, y / 32767.0f, z / 32767.0f);
}

void NativeGLNormal3fv(GLContext *ctx, uint32_t mac_ptr) {
    NativeGLNormal3f(ctx, ReadMacFloat(mac_ptr), ReadMacFloat(mac_ptr + 4), ReadMacFloat(mac_ptr + 8));
}
void NativeGLNormal3dv(GLContext *ctx, uint32_t mac_ptr) {
    double v[3];
    for (int i = 0; i < 3; i++) {
        uint64_t bits = ((uint64_t)ReadMacInt32(mac_ptr + i * 8) << 32) | ReadMacInt32(mac_ptr + i * 8 + 4);
        memcpy(&v[i], &bits, 8);
    }
    NativeGLNormal3f(ctx, (float)v[0], (float)v[1], (float)v[2]);
}
void NativeGLNormal3bv(GLContext *ctx, uint32_t mac_ptr) {
    NativeGLNormal3b(ctx, (int8_t)ReadMacInt8(mac_ptr), (int8_t)ReadMacInt8(mac_ptr + 1), (int8_t)ReadMacInt8(mac_ptr + 2));
}
void NativeGLNormal3iv(GLContext *ctx, uint32_t mac_ptr) {
    NativeGLNormal3i(ctx, (int32_t)ReadMacInt32(mac_ptr), (int32_t)ReadMacInt32(mac_ptr + 4), (int32_t)ReadMacInt32(mac_ptr + 8));
}
void NativeGLNormal3sv(GLContext *ctx, uint32_t mac_ptr) {
    NativeGLNormal3s(ctx, (int16_t)ReadMacInt16(mac_ptr), (int16_t)ReadMacInt16(mac_ptr + 2), (int16_t)ReadMacInt16(mac_ptr + 4));
}


// ---- TexCoord submission ----

void NativeGLTexCoord1f(GLContext *ctx, float s) {
    int u = ctx->active_texture;
    ctx->current_texcoord[u][0] = s;
    ctx->current_texcoord[u][1] = 0.0f;
    ctx->current_texcoord[u][2] = 0.0f;
    ctx->current_texcoord[u][3] = 1.0f;
}
void NativeGLTexCoord2f(GLContext *ctx, float s, float t) {
    int u = ctx->active_texture;
    ctx->current_texcoord[u][0] = s;
    ctx->current_texcoord[u][1] = t;
    ctx->current_texcoord[u][2] = 0.0f;
    ctx->current_texcoord[u][3] = 1.0f;
}
void NativeGLTexCoord3f(GLContext *ctx, float s, float t, float r) {
    int u = ctx->active_texture;
    ctx->current_texcoord[u][0] = s;
    ctx->current_texcoord[u][1] = t;
    ctx->current_texcoord[u][2] = r;
    ctx->current_texcoord[u][3] = 1.0f;
}
void NativeGLTexCoord4f(GLContext *ctx, float s, float t, float r, float q) {
    int u = ctx->active_texture;
    ctx->current_texcoord[u][0] = s;
    ctx->current_texcoord[u][1] = t;
    ctx->current_texcoord[u][2] = r;
    ctx->current_texcoord[u][3] = q;
}

void NativeGLTexCoord1d(GLContext *ctx, double s) { NativeGLTexCoord1f(ctx, (float)s); }
void NativeGLTexCoord2d(GLContext *ctx, double s, double t) { NativeGLTexCoord2f(ctx, (float)s, (float)t); }
void NativeGLTexCoord3d(GLContext *ctx, double s, double t, double r) { NativeGLTexCoord3f(ctx, (float)s, (float)t, (float)r); }
void NativeGLTexCoord4d(GLContext *ctx, double s, double t, double r, double q) { NativeGLTexCoord4f(ctx, (float)s, (float)t, (float)r, (float)q); }

void NativeGLTexCoord1i(GLContext *ctx, int32_t s) { NativeGLTexCoord1f(ctx, (float)s); }
void NativeGLTexCoord2i(GLContext *ctx, int32_t s, int32_t t) { NativeGLTexCoord2f(ctx, (float)s, (float)t); }
void NativeGLTexCoord3i(GLContext *ctx, int32_t s, int32_t t, int32_t r) { NativeGLTexCoord3f(ctx, (float)s, (float)t, (float)r); }
void NativeGLTexCoord4i(GLContext *ctx, int32_t s, int32_t t, int32_t r, int32_t q) { NativeGLTexCoord4f(ctx, (float)s, (float)t, (float)r, (float)q); }

void NativeGLTexCoord1s(GLContext *ctx, int16_t s) { NativeGLTexCoord1f(ctx, (float)s); }
void NativeGLTexCoord2s(GLContext *ctx, int16_t s, int16_t t) { NativeGLTexCoord2f(ctx, (float)s, (float)t); }
void NativeGLTexCoord3s(GLContext *ctx, int16_t s, int16_t t, int16_t r) { NativeGLTexCoord3f(ctx, (float)s, (float)t, (float)r); }
void NativeGLTexCoord4s(GLContext *ctx, int16_t s, int16_t t, int16_t r, int16_t q) { NativeGLTexCoord4f(ctx, (float)s, (float)t, (float)r, (float)q); }

void NativeGLTexCoord1fv(GLContext *ctx, uint32_t mac_ptr) { NativeGLTexCoord1f(ctx, ReadMacFloat(mac_ptr)); }
void NativeGLTexCoord2fv(GLContext *ctx, uint32_t mac_ptr) { NativeGLTexCoord2f(ctx, ReadMacFloat(mac_ptr), ReadMacFloat(mac_ptr + 4)); }
void NativeGLTexCoord3fv(GLContext *ctx, uint32_t mac_ptr) { NativeGLTexCoord3f(ctx, ReadMacFloat(mac_ptr), ReadMacFloat(mac_ptr + 4), ReadMacFloat(mac_ptr + 8)); }
void NativeGLTexCoord4fv(GLContext *ctx, uint32_t mac_ptr) { NativeGLTexCoord4f(ctx, ReadMacFloat(mac_ptr), ReadMacFloat(mac_ptr + 4), ReadMacFloat(mac_ptr + 8), ReadMacFloat(mac_ptr + 12)); }

void NativeGLTexCoord1dv(GLContext *ctx, uint32_t mac_ptr) {
    double v; uint64_t b = ((uint64_t)ReadMacInt32(mac_ptr) << 32) | ReadMacInt32(mac_ptr + 4); memcpy(&v, &b, 8);
    NativeGLTexCoord1f(ctx, (float)v);
}
void NativeGLTexCoord2dv(GLContext *ctx, uint32_t mac_ptr) {
    double v[2];
    for (int i = 0; i < 2; i++) { uint64_t b = ((uint64_t)ReadMacInt32(mac_ptr + i*8) << 32) | ReadMacInt32(mac_ptr + i*8 + 4); memcpy(&v[i], &b, 8); }
    NativeGLTexCoord2f(ctx, (float)v[0], (float)v[1]);
}
void NativeGLTexCoord3dv(GLContext *ctx, uint32_t mac_ptr) {
    double v[3];
    for (int i = 0; i < 3; i++) { uint64_t b = ((uint64_t)ReadMacInt32(mac_ptr + i*8) << 32) | ReadMacInt32(mac_ptr + i*8 + 4); memcpy(&v[i], &b, 8); }
    NativeGLTexCoord3f(ctx, (float)v[0], (float)v[1], (float)v[2]);
}
void NativeGLTexCoord4dv(GLContext *ctx, uint32_t mac_ptr) {
    double v[4];
    for (int i = 0; i < 4; i++) { uint64_t b = ((uint64_t)ReadMacInt32(mac_ptr + i*8) << 32) | ReadMacInt32(mac_ptr + i*8 + 4); memcpy(&v[i], &b, 8); }
    NativeGLTexCoord4f(ctx, (float)v[0], (float)v[1], (float)v[2], (float)v[3]);
}
void NativeGLTexCoord1iv(GLContext *ctx, uint32_t mac_ptr) { NativeGLTexCoord1i(ctx, (int32_t)ReadMacInt32(mac_ptr)); }
void NativeGLTexCoord2iv(GLContext *ctx, uint32_t mac_ptr) { NativeGLTexCoord2i(ctx, (int32_t)ReadMacInt32(mac_ptr), (int32_t)ReadMacInt32(mac_ptr + 4)); }
void NativeGLTexCoord3iv(GLContext *ctx, uint32_t mac_ptr) { NativeGLTexCoord3i(ctx, (int32_t)ReadMacInt32(mac_ptr), (int32_t)ReadMacInt32(mac_ptr + 4), (int32_t)ReadMacInt32(mac_ptr + 8)); }
void NativeGLTexCoord4iv(GLContext *ctx, uint32_t mac_ptr) { NativeGLTexCoord4i(ctx, (int32_t)ReadMacInt32(mac_ptr), (int32_t)ReadMacInt32(mac_ptr + 4), (int32_t)ReadMacInt32(mac_ptr + 8), (int32_t)ReadMacInt32(mac_ptr + 12)); }
void NativeGLTexCoord1sv(GLContext *ctx, uint32_t mac_ptr) { NativeGLTexCoord1s(ctx, (int16_t)ReadMacInt16(mac_ptr)); }
void NativeGLTexCoord2sv(GLContext *ctx, uint32_t mac_ptr) { NativeGLTexCoord2s(ctx, (int16_t)ReadMacInt16(mac_ptr), (int16_t)ReadMacInt16(mac_ptr + 2)); }
void NativeGLTexCoord3sv(GLContext *ctx, uint32_t mac_ptr) { NativeGLTexCoord3s(ctx, (int16_t)ReadMacInt16(mac_ptr), (int16_t)ReadMacInt16(mac_ptr + 2), (int16_t)ReadMacInt16(mac_ptr + 4)); }
void NativeGLTexCoord4sv(GLContext *ctx, uint32_t mac_ptr) { NativeGLTexCoord4s(ctx, (int16_t)ReadMacInt16(mac_ptr), (int16_t)ReadMacInt16(mac_ptr + 2), (int16_t)ReadMacInt16(mac_ptr + 4), (int16_t)ReadMacInt16(mac_ptr + 6)); }


// ============================================================================
//  Vertex Array Rendering
// ============================================================================

// Read one array component from guest memory as float
static inline float ReadArrayComponent(uint32_t addr, uint32_t type) {
    switch (type) {
    case GL_FLOAT: {
        uint32_t bits = ReadMacInt32(addr);
        float f; memcpy(&f, &bits, 4);
        return f;
    }
    case GL_DOUBLE: {
        uint64_t bits = ((uint64_t)ReadMacInt32(addr) << 32) | ReadMacInt32(addr + 4);
        double d; memcpy(&d, &bits, 8);
        return (float)d;
    }
    case GL_INT:
        return (float)(int32_t)ReadMacInt32(addr);
    case GL_UNSIGNED_INT:
        return (float)ReadMacInt32(addr);
    case GL_SHORT:
        return (float)(int16_t)ReadMacInt16(addr);
    case GL_UNSIGNED_SHORT:
        return (float)ReadMacInt16(addr);
    case GL_BYTE:
        return (float)(int8_t)ReadMacInt8(addr);
    case GL_UNSIGNED_BYTE:
        return (float)ReadMacInt8(addr);
    default:
        return 0.0f;
    }
}

static inline int TypeSize(uint32_t type) {
    switch (type) {
    case GL_FLOAT:          return 4;
    case GL_DOUBLE:         return 8;
    case GL_INT:            return 4;
    case GL_UNSIGNED_INT:   return 4;
    case GL_SHORT:          return 2;
    case GL_UNSIGNED_SHORT: return 2;
    case GL_BYTE:           return 1;
    case GL_UNSIGNED_BYTE:  return 1;
    default:                return 4;
    }
}

// Stride 0 means tightly packed
static inline int EffectiveStride(const GLVertexArrayPointer &arr) {
    if (arr.stride > 0) return arr.stride;
    return arr.size * TypeSize(arr.type);
}

// GL 1.1 table 2.6: color and normal integer components are fixed point.
// Vertex positions and texture coordinates keep their ordinary numeric values.
static inline float ReadArrayNormalizedComponent(uint32_t addr, uint32_t type) {
    switch (type) {
    case GL_BYTE: return float((2.0 * (int8_t)ReadMacInt8(addr) + 1.0) / 255.0);
    case GL_SHORT: return float((2.0 * (int16_t)ReadMacInt16(addr) + 1.0) / 65535.0);
    case GL_INT: return float((2.0 * (int32_t)ReadMacInt32(addr) + 1.0) / 4294967295.0);
    case GL_UNSIGNED_BYTE: return float(ReadMacInt8(addr) / 255.0);
    case GL_UNSIGNED_SHORT: return float(ReadMacInt16(addr) / 65535.0);
    case GL_UNSIGNED_INT: return float(ReadMacInt32(addr) / 4294967295.0);
    default: return ReadArrayComponent(addr, type);
    }
}

// Validate the same descriptors FetchArrayVertex consumes, before changing
// immediate-mode state or reading any enabled array. All arithmetic is wide.
static bool GLMetalValidateArrayRange(GLContext *ctx, uint32_t first, uint32_t last)
{
    auto valid = [&](const GLVertexArrayPointer &array, int components = 0) {
        if (!array.enabled) return true;
        // Pixel uploads exclude GL_DOUBLE; client geometry arrays accept it.
        const int scalar = array.type == GL_DOUBLE ? 8 : GLPixelScalarTypeBytes(array.type);
        if (!scalar || array.size < 1 || array.size > 4 || array.stride < 0 ||
            (components && array.size != components)) return false;
        const uint32_t element = uint32_t(scalar * array.size);
        const uint32_t stride = array.stride ? uint32_t(array.stride) : element;
        return GfxGuestStridedRange(array.pointer, first, last, stride, element,
            RAMBase, RAMSize, ROMBase, ROM_SIZE);
    };
    bool ok = valid(ctx->vertex_array) && valid(ctx->normal_array, 3) && valid(ctx->color_array) &&
        valid(ctx->secondary_color_array, 3) && valid(ctx->edge_flag_array, 1);
    for (int unit = 0; unit < 4; ++unit) ok = ok && valid(ctx->texcoord_array[unit]);
    if (!ok && !ctx->last_error) ctx->last_error = 0x0501;
    return ok;
}

static bool GLMetalValidateDrawSize(GLContext *ctx, uint32_t mode, int32_t count)
{
    if (count <= 0) return true;
    const GLMetalState *ms = (GLMetalState *)ctx->metal;
    // Bound temporary geometry by guest RAM size and the device upload limit,
    // so repeated indices cannot force an unbounded allocation.
    const uint64_t budget = ms && ms->initialized
        ? std::min<uint64_t>(RAMSize, ms->device.maxBufferLength) : RAMSize;
    const bool flat = ctx->shade_model == 0x1d00;
    const uint64_t expansion = mode == 2 || (mode == 3 && flat) ? 2 :
        mode >= 6 || (mode == 5 && flat) ? 3 : 1;
    const uint64_t bytes = uint64_t(count) *
        std::max(sizeof(GLVertex), sizeof(GLMetalVertex)) * expansion;
    if (bytes <= budget) return true;
    if (!ctx->last_error) ctx->last_error = 0x0505;
    return false;
}

static void FetchArrayVertex(GLContext *ctx, uint32_t i, GLVertex &v) {
    if (ctx->vertex_array.enabled && ctx->vertex_array.pointer) {
        int es = EffectiveStride(ctx->vertex_array);
        uint32_t base = ctx->vertex_array.pointer + i * es;
        int sz = ctx->vertex_array.size;
        v.position[0] = (sz >= 1) ? ReadArrayComponent(base + 0 * TypeSize(ctx->vertex_array.type), ctx->vertex_array.type) : 0.0f;
        v.position[1] = (sz >= 2) ? ReadArrayComponent(base + 1 * TypeSize(ctx->vertex_array.type), ctx->vertex_array.type) : 0.0f;
        v.position[2] = (sz >= 3) ? ReadArrayComponent(base + 2 * TypeSize(ctx->vertex_array.type), ctx->vertex_array.type) : 0.0f;
        v.position[3] = (sz >= 4) ? ReadArrayComponent(base + 3 * TypeSize(ctx->vertex_array.type), ctx->vertex_array.type) : 1.0f;
    } else {
        v.position[0] = v.position[1] = v.position[2] = 0.0f; v.position[3] = 1.0f;
    }

    if (ctx->color_array.enabled && ctx->color_array.pointer) {
        int es = EffectiveStride(ctx->color_array);
        uint32_t base = ctx->color_array.pointer + i * es;
        int sz = ctx->color_array.size;
        uint32_t ct = ctx->color_array.type;
        v.color[0] = (sz >= 1) ? ReadArrayNormalizedComponent(base + 0 * TypeSize(ct), ct) : 0.0f;
        v.color[1] = (sz >= 2) ? ReadArrayNormalizedComponent(base + 1 * TypeSize(ct), ct) : 0.0f;
        v.color[2] = (sz >= 3) ? ReadArrayNormalizedComponent(base + 2 * TypeSize(ct), ct) : 0.0f;
        v.color[3] = (sz >= 4) ? ReadArrayNormalizedComponent(base + 3 * TypeSize(ct), ct) : 1.0f;
    } else {
        memcpy(v.color, ctx->current_color, sizeof(float) * 4);
    }

    if (ctx->normal_array.enabled && ctx->normal_array.pointer) {
        int es = EffectiveStride(ctx->normal_array);
        uint32_t base = ctx->normal_array.pointer + i * es;
        for (int c = 0; c < 3; c++)
            v.normal[c] = ReadArrayNormalizedComponent(base + c * TypeSize(ctx->normal_array.type), ctx->normal_array.type);
    } else {
        memcpy(v.normal, ctx->current_normal, sizeof(float) * 3);
    }

    for (int u = 0; u < 4; u++) {
        const GLVertexArrayPointer *texcoord = GLMetalTexCoordArrayForDraw(ctx, u);
        if (texcoord) {
            int es = EffectiveStride(*texcoord);
            uint32_t base = texcoord->pointer + i * es;
            int sz = texcoord->size;
            uint32_t ct = texcoord->type;
            v.texcoord[u][0] = (sz >= 1) ? ReadArrayComponent(base + 0 * TypeSize(ct), ct) : 0.0f;
            v.texcoord[u][1] = (sz >= 2) ? ReadArrayComponent(base + 1 * TypeSize(ct), ct) : 0.0f;
            v.texcoord[u][2] = (sz >= 3) ? ReadArrayComponent(base + 2 * TypeSize(ct), ct) : 0.0f;
            v.texcoord[u][3] = (sz >= 4) ? ReadArrayComponent(base + 3 * TypeSize(ct), ct) : 1.0f;
        } else {
            memcpy(v.texcoord[u], ctx->current_texcoord[u], sizeof(float) * 4);
        }
    }

    if (ctx->secondary_color_array.enabled && ctx->secondary_color_array.pointer) {
        const auto &array = ctx->secondary_color_array;
        const uint32_t base = array.pointer + i * EffectiveStride(array);
        for (int c = 0; c < 3; ++c)
            v.secondary_color[c] = ReadArrayNormalizedComponent(base + c * TypeSize(array.type), array.type);
    } else {
        memcpy(v.secondary_color, ctx->current_secondary_color, sizeof(float) * 3);
    }
    v.fog_coord = ctx->current_fog_coord;
    GLSnapshotVertexMaterial(*ctx, v);
    v.edge_flag=ctx->edge_flag_array.enabled && ctx->edge_flag_array.pointer ?
        ReadMacInt8(ctx->edge_flag_array.pointer+i*EffectiveStride(ctx->edge_flag_array))!=0 : ctx->current_edge_flag;
}


/*
 *  Shared vertex-array draw. Smooth indexed draws fetch each vertex once and
 *  expand only indices; flat draws expand vertices.
 */
static bool GLMetalIndexTopology(uint32_t mode, const std::vector<uint32_t> &in,
    std::vector<uint32_t> &out, MTLPrimitiveType &primitive)
{
    const size_t n = in.size();
    switch (mode) {
    case GL_POINTS: primitive = MTLPrimitiveTypePoint; out = in; break;
    case GL_LINES:
        primitive = MTLPrimitiveTypeLine;
        out.assign(in.begin(), in.begin() + (n / 2) * 2); break;
    case GL_LINE_STRIP:
        primitive = MTLPrimitiveTypeLineStrip; if (n >= 2) out = in; break;
    case GL_LINE_LOOP:
        primitive = MTLPrimitiveTypeLineStrip;
        if (n >= 2) { out = in; out.push_back(in.front()); } break;
    case GL_TRIANGLES:
        primitive = MTLPrimitiveTypeTriangle;
        out.assign(in.begin(), in.begin() + (n / 3) * 3); break;
    case GL_TRIANGLE_STRIP:
        primitive = MTLPrimitiveTypeTriangleStrip; if (n >= 3) out = in; break;
    case GL_TRIANGLE_FAN: case GL_POLYGON:
        primitive = MTLPrimitiveTypeTriangle;
        if (n >= 3) out.reserve((n - 2) * 3);
        for (size_t i = 1; i + 1 < n; ++i) out.insert(out.end(), {in[0], in[i], in[i+1]});
        break;
    case GL_QUADS:
        primitive = MTLPrimitiveTypeTriangle; out.reserve((n / 4) * 6);
        for (size_t i = 0; i + 3 < n; i += 4)
            out.insert(out.end(), {in[i], in[i+1], in[i+2], in[i], in[i+2], in[i+3]});
        break;
    case GL_QUAD_STRIP:
        primitive = MTLPrimitiveTypeTriangle;
        if (n >= 4) out.reserve(((n - 2) / 2) * 6);
        for (size_t i = 0; i + 3 < n; i += 2)
            out.insert(out.end(), {in[i], in[i+1], in[i+3], in[i], in[i+3], in[i+2]});
        break;
    default: return false;
    }
    return !out.empty();
}

static void GLMetalDrawVertexArray(GLContext *ctx, uint32_t mode,
    const uint32_t *indices, int32_t count, bool preserveIndices)
{
    if (count <= 0) return;
    uint32_t first = UINT32_MAX, last = 0;
    for (int32_t i = 0; i < count; ++i) {
        first = std::min(first, indices[i]); last = std::max(last, indices[i]);
    }
    if (!GLMetalValidateArrayRange(ctx, first, last)) return;
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (ctx->render_mode==0x1c00 && (!ms || !ms->initialized)) return;
    ctx->im_mode = mode;
    ctx->im_vertices.clear();

    // Flat shading rewrites per-primitive colors, so it cannot share vertices.
    if (ctx->render_mode!=0x1c00 || (!ms->framebufferFetch && (ctx->color_logic_op || ctx->blend)) || ctx->line_stipple_enabled || ctx->polygon_mode_front!=0x1b02 || ctx->polygon_mode_back!=0x1b02 || !preserveIndices || ctx->shade_model == 0x1D00 /* GL_FLAT */) {
        ctx->im_vertices.reserve(count);
        for (int32_t j = 0; j < count; ++j) {
            GLVertex v;
            FetchArrayVertex(ctx, indices[j], v);
            ctx->im_vertices.push_back(v);
        }
        GLMetalFlushImmediateMode(ctx);
        return;
    }

    std::unordered_map<uint32_t, uint32_t> remap;
    std::vector<uint32_t> compactIndices;
    compactIndices.reserve(count);
    for (int32_t j = 0; j < count; ++j) {
        const uint32_t index = indices[j];
        auto entry = remap.emplace(index, uint32_t(ctx->im_vertices.size()));
        if (entry.second) {
            GLVertex v;
            FetchArrayVertex(ctx, index, v);
            ctx->im_vertices.push_back(v);
        }
        compactIndices.push_back(entry.first->second);
    }
    std::vector<uint32_t> drawIndices;
    MTLPrimitiveType primitive;
    if (!GLMetalIndexTopology(mode, compactIndices, drawIndices, primitive)) return;
    GLMetalSubmitVertices(ctx, &drawIndices, primitive);
}


void NativeGLDrawArrays(GLContext *ctx, uint32_t mode, int32_t first, int32_t count)
{
    GL_METAL_VLOG("glDrawArrays(0x%04x, %d, %d)", mode, first, count);
    if (!ctx) return;
    if (ctx->in_begin) { if (!ctx->last_error) ctx->last_error = 0x0502; return; }
    if (mode > GL_POLYGON) { if (!ctx->last_error) ctx->last_error = 0x0500; return; }
    if (count < 0 || first < 0 || int64_t(first) + count > INT32_MAX) {
        if (!ctx->last_error) ctx->last_error = 0x0501; return;
    }
    if (count == 0) return;

    if (!GLMetalValidateDrawSize(ctx, mode, count) ||
        !GLMetalValidateArrayRange(ctx, uint32_t(first), uint32_t(first + count - 1))) return;
    try {
        std::vector<uint32_t> indices(count);
        for (int32_t i = 0; i < count; i++) indices[i] = first + i;

        GLMetalDrawVertexArray(ctx, mode, indices.data(), count, false);
    } catch (const std::bad_alloc &) { if (!ctx->last_error) ctx->last_error = 0x0505; }
}


void NativeGLDrawElements(GLContext *ctx, uint32_t mode, int32_t count, uint32_t type, uint32_t indices_ptr)
{
    GL_METAL_VLOG("glDrawElements(0x%04x, %d, 0x%04x, 0x%08x)", mode, count, type, indices_ptr);
    if (!ctx) return;
    if (ctx->in_begin) { if (!ctx->last_error) ctx->last_error = 0x0502; return; }
    if (mode > GL_POLYGON || (type != GL_UNSIGNED_INT && type != GL_UNSIGNED_SHORT && type != GL_UNSIGNED_BYTE)) {
        if (!ctx->last_error) ctx->last_error = 0x0500; return;
    }
    if (count < 0) { if (!ctx->last_error) ctx->last_error = 0x0501; return; }
    if (count == 0) return;

    const uint32_t scalar = type == GL_UNSIGNED_INT ? 4 : type == GL_UNSIGNED_SHORT ? 2 : 1;
    if (!indices_ptr || !GLGuestMappedRange(indices_ptr, uint64_t(count) * scalar,
        RAMBase, RAMSize, ROMBase, ROM_SIZE)) {
        if (!ctx->last_error) ctx->last_error = 0x0501;
        return;
    }
    if (!GLMetalValidateDrawSize(ctx, mode, count)) return;
    try {
        std::vector<uint32_t> indices(count);
        for (int32_t i = 0; i < count; i++) {
            switch (type) {
            case GL_UNSIGNED_INT:
                indices[i] = ReadMacInt32(indices_ptr + uint32_t(i) * 4);
                break;
            case GL_UNSIGNED_SHORT:
                indices[i] = ReadMacInt16(indices_ptr + uint32_t(i) * 2);
                break;
            case GL_UNSIGNED_BYTE:
                indices[i] = ReadMacInt8(indices_ptr + i);
                break;
            default: return; // validated above
            }
        }

        GLMetalDrawVertexArray(ctx, mode, indices.data(), count, true);
    } catch (const std::bad_alloc &) { if (!ctx->last_error) ctx->last_error = 0x0505; }
}


// The range hint is ignored.
void NativeGLDrawRangeElements(GLContext *ctx, uint32_t mode, uint32_t start, uint32_t end,
                                int32_t count, uint32_t type, uint32_t indices_ptr)
{
    (void)start; (void)end;
    NativeGLDrawElements(ctx, mode, count, type, indices_ptr);
}


void NativeGLArrayElement(GLContext *ctx, int32_t i)
{
    if (i < 0) { if (!ctx->last_error) ctx->last_error = 0x0501; return; }
    if (!GLMetalValidateArrayRange(ctx, uint32_t(i), uint32_t(i))) return;
    GLVertex v;
    FetchArrayVertex(ctx, i, v);
    if (ctx->color_array.enabled) { memcpy(ctx->current_color,v.color,sizeof(v.color)); GLApplyColorMaterial(ctx); }
    if (ctx->normal_array.enabled) memcpy(ctx->current_normal,v.normal,sizeof(v.normal));
    for(int unit=0;unit<4;++unit) if(ctx->texcoord_array[unit].enabled)
        memcpy(ctx->current_texcoord[unit],v.texcoord[unit],sizeof(v.texcoord[unit]));
    if(ctx->edge_flag_array.enabled)ctx->current_edge_flag=v.edge_flag;
    if(ctx->secondary_color_array.enabled)memcpy(ctx->current_secondary_color,v.secondary_color,sizeof(v.secondary_color));
    if(ctx->vertex_array.enabled) ctx->im_vertices.push_back(v);
}


void NativeGLInterleavedArrays(GLContext *ctx, uint32_t format, int32_t stride, uint32_t pointer)
{
    GL_METAL_VLOG("glInterleavedArrays(0x%04x, %d, 0x%08x)", format, stride, pointer);

    ctx->color_array.enabled = false;
    ctx->normal_array.enabled = false;
    ctx->texcoord_array[ctx->client_active_texture].enabled = false;
    ctx->edge_flag_array.enabled = false;
    ctx->index_array.enabled = false;

    int totalStride = 0;

    switch (format) {
    case GL_V2F:
        totalStride = stride ? stride : 8;
        ctx->vertex_array.enabled = true; ctx->vertex_array.size = 2;
        ctx->vertex_array.type = GL_FLOAT; ctx->vertex_array.stride = totalStride;
        ctx->vertex_array.pointer = pointer;
        break;
    case GL_V3F:
        totalStride = stride ? stride : 12;
        ctx->vertex_array.enabled = true; ctx->vertex_array.size = 3;
        ctx->vertex_array.type = GL_FLOAT; ctx->vertex_array.stride = totalStride;
        ctx->vertex_array.pointer = pointer;
        break;
    case GL_C4UB_V2F:
        totalStride = stride ? stride : 12;
        ctx->color_array.enabled = true; ctx->color_array.size = 4;
        ctx->color_array.type = GL_UNSIGNED_BYTE; ctx->color_array.stride = totalStride;
        ctx->color_array.pointer = pointer;
        ctx->vertex_array.enabled = true; ctx->vertex_array.size = 2;
        ctx->vertex_array.type = GL_FLOAT; ctx->vertex_array.stride = totalStride;
        ctx->vertex_array.pointer = pointer + 4;
        break;
    case GL_C4UB_V3F:
        totalStride = stride ? stride : 16;
        ctx->color_array.enabled = true; ctx->color_array.size = 4;
        ctx->color_array.type = GL_UNSIGNED_BYTE; ctx->color_array.stride = totalStride;
        ctx->color_array.pointer = pointer;
        ctx->vertex_array.enabled = true; ctx->vertex_array.size = 3;
        ctx->vertex_array.type = GL_FLOAT; ctx->vertex_array.stride = totalStride;
        ctx->vertex_array.pointer = pointer + 4;
        break;
    case GL_C3F_V3F:
        totalStride = stride ? stride : 24;
        ctx->color_array.enabled = true; ctx->color_array.size = 3;
        ctx->color_array.type = GL_FLOAT; ctx->color_array.stride = totalStride;
        ctx->color_array.pointer = pointer;
        ctx->vertex_array.enabled = true; ctx->vertex_array.size = 3;
        ctx->vertex_array.type = GL_FLOAT; ctx->vertex_array.stride = totalStride;
        ctx->vertex_array.pointer = pointer + 12;
        break;
    case GL_N3F_V3F:
        totalStride = stride ? stride : 24;
        ctx->normal_array.enabled = true; ctx->normal_array.size = 3;
        ctx->normal_array.type = GL_FLOAT; ctx->normal_array.stride = totalStride;
        ctx->normal_array.pointer = pointer;
        ctx->vertex_array.enabled = true; ctx->vertex_array.size = 3;
        ctx->vertex_array.type = GL_FLOAT; ctx->vertex_array.stride = totalStride;
        ctx->vertex_array.pointer = pointer + 12;
        break;
    case GL_C4F_N3F_V3F:
        totalStride = stride ? stride : 40;
        ctx->color_array.enabled = true; ctx->color_array.size = 4;
        ctx->color_array.type = GL_FLOAT; ctx->color_array.stride = totalStride;
        ctx->color_array.pointer = pointer;
        ctx->normal_array.enabled = true; ctx->normal_array.size = 3;
        ctx->normal_array.type = GL_FLOAT; ctx->normal_array.stride = totalStride;
        ctx->normal_array.pointer = pointer + 16;
        ctx->vertex_array.enabled = true; ctx->vertex_array.size = 3;
        ctx->vertex_array.type = GL_FLOAT; ctx->vertex_array.stride = totalStride;
        ctx->vertex_array.pointer = pointer + 28;
        break;
    case GL_T2F_V3F:
        totalStride = stride ? stride : 20;
        ctx->texcoord_array[ctx->client_active_texture].enabled = true;
        ctx->texcoord_array[ctx->client_active_texture].size = 2;
        ctx->texcoord_array[ctx->client_active_texture].type = GL_FLOAT;
        ctx->texcoord_array[ctx->client_active_texture].stride = totalStride;
        ctx->texcoord_array[ctx->client_active_texture].pointer = pointer;
        ctx->vertex_array.enabled = true; ctx->vertex_array.size = 3;
        ctx->vertex_array.type = GL_FLOAT; ctx->vertex_array.stride = totalStride;
        ctx->vertex_array.pointer = pointer + 8;
        break;
    case GL_T4F_V4F:
        totalStride = stride ? stride : 32;
        ctx->texcoord_array[ctx->client_active_texture].enabled = true;
        ctx->texcoord_array[ctx->client_active_texture].size = 4;
        ctx->texcoord_array[ctx->client_active_texture].type = GL_FLOAT;
        ctx->texcoord_array[ctx->client_active_texture].stride = totalStride;
        ctx->texcoord_array[ctx->client_active_texture].pointer = pointer;
        ctx->vertex_array.enabled = true; ctx->vertex_array.size = 4;
        ctx->vertex_array.type = GL_FLOAT; ctx->vertex_array.stride = totalStride;
        ctx->vertex_array.pointer = pointer + 16;
        break;
    case GL_T2F_C4UB_V3F:
        totalStride = stride ? stride : 24;
        ctx->texcoord_array[ctx->client_active_texture].enabled = true;
        ctx->texcoord_array[ctx->client_active_texture].size = 2;
        ctx->texcoord_array[ctx->client_active_texture].type = GL_FLOAT;
        ctx->texcoord_array[ctx->client_active_texture].stride = totalStride;
        ctx->texcoord_array[ctx->client_active_texture].pointer = pointer;
        ctx->color_array.enabled = true; ctx->color_array.size = 4;
        ctx->color_array.type = GL_UNSIGNED_BYTE; ctx->color_array.stride = totalStride;
        ctx->color_array.pointer = pointer + 8;
        ctx->vertex_array.enabled = true; ctx->vertex_array.size = 3;
        ctx->vertex_array.type = GL_FLOAT; ctx->vertex_array.stride = totalStride;
        ctx->vertex_array.pointer = pointer + 12;
        break;
    case GL_T2F_C3F_V3F:
        totalStride = stride ? stride : 32;
        ctx->texcoord_array[ctx->client_active_texture].enabled = true;
        ctx->texcoord_array[ctx->client_active_texture].size = 2;
        ctx->texcoord_array[ctx->client_active_texture].type = GL_FLOAT;
        ctx->texcoord_array[ctx->client_active_texture].stride = totalStride;
        ctx->texcoord_array[ctx->client_active_texture].pointer = pointer;
        ctx->color_array.enabled = true; ctx->color_array.size = 3;
        ctx->color_array.type = GL_FLOAT; ctx->color_array.stride = totalStride;
        ctx->color_array.pointer = pointer + 8;
        ctx->vertex_array.enabled = true; ctx->vertex_array.size = 3;
        ctx->vertex_array.type = GL_FLOAT; ctx->vertex_array.stride = totalStride;
        ctx->vertex_array.pointer = pointer + 20;
        break;
    case GL_T2F_N3F_V3F:
        totalStride = stride ? stride : 32;
        ctx->texcoord_array[ctx->client_active_texture].enabled = true;
        ctx->texcoord_array[ctx->client_active_texture].size = 2;
        ctx->texcoord_array[ctx->client_active_texture].type = GL_FLOAT;
        ctx->texcoord_array[ctx->client_active_texture].stride = totalStride;
        ctx->texcoord_array[ctx->client_active_texture].pointer = pointer;
        ctx->normal_array.enabled = true; ctx->normal_array.size = 3;
        ctx->normal_array.type = GL_FLOAT; ctx->normal_array.stride = totalStride;
        ctx->normal_array.pointer = pointer + 8;
        ctx->vertex_array.enabled = true; ctx->vertex_array.size = 3;
        ctx->vertex_array.type = GL_FLOAT; ctx->vertex_array.stride = totalStride;
        ctx->vertex_array.pointer = pointer + 20;
        break;
    case GL_T2F_C4F_N3F_V3F:
        totalStride = stride ? stride : 48;
        ctx->texcoord_array[ctx->client_active_texture].enabled = true;
        ctx->texcoord_array[ctx->client_active_texture].size = 2;
        ctx->texcoord_array[ctx->client_active_texture].type = GL_FLOAT;
        ctx->texcoord_array[ctx->client_active_texture].stride = totalStride;
        ctx->texcoord_array[ctx->client_active_texture].pointer = pointer;
        ctx->color_array.enabled = true; ctx->color_array.size = 4;
        ctx->color_array.type = GL_FLOAT; ctx->color_array.stride = totalStride;
        ctx->color_array.pointer = pointer + 8;
        ctx->normal_array.enabled = true; ctx->normal_array.size = 3;
        ctx->normal_array.type = GL_FLOAT; ctx->normal_array.stride = totalStride;
        ctx->normal_array.pointer = pointer + 24;
        ctx->vertex_array.enabled = true; ctx->vertex_array.size = 3;
        ctx->vertex_array.type = GL_FLOAT; ctx->vertex_array.stride = totalStride;
        ctx->vertex_array.pointer = pointer + 36;
        break;
    case GL_T4F_C4F_N3F_V4F:
        totalStride = stride ? stride : 60;
        ctx->texcoord_array[ctx->client_active_texture].enabled = true;
        ctx->texcoord_array[ctx->client_active_texture].size = 4;
        ctx->texcoord_array[ctx->client_active_texture].type = GL_FLOAT;
        ctx->texcoord_array[ctx->client_active_texture].stride = totalStride;
        ctx->texcoord_array[ctx->client_active_texture].pointer = pointer;
        ctx->color_array.enabled = true; ctx->color_array.size = 4;
        ctx->color_array.type = GL_FLOAT; ctx->color_array.stride = totalStride;
        ctx->color_array.pointer = pointer + 16;
        ctx->normal_array.enabled = true; ctx->normal_array.size = 3;
        ctx->normal_array.type = GL_FLOAT; ctx->normal_array.stride = totalStride;
        ctx->normal_array.pointer = pointer + 32;
        ctx->vertex_array.enabled = true; ctx->vertex_array.size = 4;
        ctx->vertex_array.type = GL_FLOAT; ctx->vertex_array.stride = totalStride;
        ctx->vertex_array.pointer = pointer + 44;
        break;
    default:
        GL_METAL_LOG("glInterleavedArrays: unknown format 0x%04x", format);
        break;
    }
}
