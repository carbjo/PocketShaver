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
 *  Implements:
 *    - Metal pipeline state cache for GL blend/depth combinations
 *    - Triple-buffered vertex ring buffer (4MB per frame)
 *    - Immediate mode vertex submission (glBegin/glEnd -> Metal draw)
 *    - Primitive conversion: quads/polygon/fan -> triangle lists on CPU
 *    - Uniform upload for MVP, lighting, fog, texenv, alpha test
 *    - Frame begin/end/present via shared AccelMetalView
 */

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>

#include <cstring>
#include <cstdio>
#include <cmath>
#include <unordered_map>
#include <vector>

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "gl_engine.h"
#include "rave_metal_renderer.h"  // for RaveCreateMetalOverlay, AccelMetalView access
#include "accel_logging.h"

// Logging macro (matches gl_dispatch.cpp pattern)
#if ACCEL_LOGGING_ENABLED
#define GL_METAL_LOG(fmt, ...) do { \
    if (gl_logging_enabled) printf("GL_METAL: " fmt "\n", ##__VA_ARGS__); \
} while(0)
#else
#define GL_METAL_LOG(fmt, ...) do {} while(0)
#endif

// Forward declare Mac_sysalloc (from macos_util.h) to avoid UIKit header conflicts
extern uint32 Mac_sysalloc(uint32 size);

// GL constants needed for blend factor mapping
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


// ---- Vertex layout for Metal buffer submission ----
// Must match GLVertexIn in gl_shaders.metal
struct GLMetalVertex {
    float position[4];   // float4, offset 0
    float color[4];      // float4, offset 16
    float normal[3];     // float3, offset 32
    float texcoord[2];   // float2, offset 44
    // Total stride = 52 bytes
};

// Must match GLVertexUniforms in gl_shaders.metal
struct GLMetalVertexUniforms {
    float mvp_matrix[16];       // float4x4
    float modelview_matrix[16]; // float4x4
    float normal_matrix[12];    // float3x3 (3 columns x 3 rows, but Metal pads to 3x float4 = 48 bytes)
    int32_t lighting_enabled;
    int32_t normalize_enabled;
    int32_t num_active_lights;
    int32_t fog_enabled;
    int32_t fog_mode;
    float   fog_start;
    float   fog_end;
    float   fog_density;
};

// Must match GLFragmentUniforms in gl_shaders.metal
// Metal float4 has 16-byte alignment, so padding is needed after int fields
struct GLMetalFragmentUniforms {
    int32_t texenv_mode;
    int32_t _pad0, _pad1, _pad2;    // align texenv_color to 16 bytes
    float   texenv_color[4];         // offset 16 (Metal float4 alignment)
    float   fog_color[4];            // offset 32
    int32_t alpha_test_enabled;      // offset 48
    int32_t alpha_func;              // offset 52
    float   alpha_ref;               // offset 56
    int32_t has_texture;             // offset 60
    int32_t shade_model;             // offset 64
    int32_t _pad3, _pad4, _pad5;    // pad to 80 (16-byte struct alignment)
};

// Must match GLLight in gl_shaders.metal
// Metal float3 has 16-byte alignment and occupies 16 bytes (4th component is padding)
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
    float _pad0, _pad1, _pad2;      // offset 104-112
    float _pad3, _pad4, _pad5;      // offset 116-128 (pad to 128, 16-byte struct alignment)
};

// Must match GLMaterialData in gl_shaders.metal
struct GLMetalMaterial {
    float ambient[4];
    float diffuse[4];
    float specular[4];
    float emission[4];
    float shininess;
    float _pad0, _pad1, _pad2;
};

// Must match GLLightingData in gl_shaders.metal
struct GLMetalLightingData {
    GLMetalLight lights[8];
    GLMetalMaterial material;
    float global_ambient[4];
};

// Compile-time verification that C++ struct sizes match Metal shader expectations.
// Metal float3 occupies 16 bytes (padded), float4 has 16-byte alignment.
// If any of these fail, the struct layout doesn't match gl_shaders.metal.
static_assert(sizeof(GLMetalVertexUniforms) == 208, "GLMetalVertexUniforms size must match Metal GLVertexUniforms (208 bytes)");
static_assert(sizeof(GLMetalFragmentUniforms) == 80, "GLMetalFragmentUniforms size must match Metal GLFragmentUniforms (80 bytes)");
static_assert(sizeof(GLMetalLight) == 128, "GLMetalLight size must match Metal GLLight (128 bytes)");
static_assert(sizeof(GLMetalMaterial) == 80, "GLMetalMaterial size must match Metal GLMaterialData (80 bytes)");
static_assert(sizeof(GLMetalLightingData) == 1120, "GLMetalLightingData size must match Metal GLLightingData (1120 bytes)");


// Ring buffer constants
#define GL_RING_BUFFER_SIZE (4 * 1024 * 1024)   // 4 MB per ring buffer
#define GL_RING_BUFFER_COUNT 3                    // triple buffering


/*
 *  GLMetalState - Opaque Metal resource container for GL contexts
 */
struct GLMetalState {
    id<MTLDevice>               device;
    id<MTLCommandQueue>         commandQueue;
    id<MTLLibrary>              shaderLibrary;
    MTLVertexDescriptor        *vertexDescriptor;

    // Pipeline state cache: key = hash of (blend_enabled, blend_src, blend_dst,
    // depth_write, color_mask, has_texture)
    std::unordered_map<uint64_t, id<MTLRenderPipelineState>> pipelineCache;

    // Depth stencil state cache
    std::unordered_map<uint64_t, id<MTLDepthStencilState>> depthStencilCache;

    // Triple-buffered vertex ring buffer
    id<MTLBuffer>               vertexBuffers[GL_RING_BUFFER_COUNT];
    int                         currentBufferIndex;
    int                         bufferOffset;

    // Uniform buffers
    id<MTLBuffer>               vertexUniformBuffer;
    id<MTLBuffer>               fragmentUniformBuffer;
    id<MTLBuffer>               lightUniformBuffer;

    // Current frame state
    id<MTLCommandBuffer>        currentCommandBuffer;
    id<MTLRenderCommandEncoder> currentEncoder;
    CAMetalLayer               *layer;
    id<CAMetalDrawable>         currentDrawable;
    id<MTLTexture>              depthBuffer;
    id<MTLCommandBuffer>        lastCommittedBuffer;
    bool                        renderPassActive;
    bool                        initialized;

    // Sampler state
    id<MTLSamplerState>         linearSampler;
    id<MTLSamplerState>         nearestSampler;
};


// Forward declarations
static id<MTLSamplerState> GLMetalGetSampler(GLMetalState *ms, GLTextureObject *texObj);

// Sampler cache -- keyed by (minFilter, magFilter, wrapS, wrapT)
// Declared here (used by GLMetalRelease and GLMetalGetSampler)
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
        default:                     return MTLBlendFactorOne;
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
// Verified that MakePipelineKey includes all Metal render pipeline
// state: blend_enabled, blend_src, blend_dst, depth_write, color_mask_bits, has_texture.
// Depth test/func, stencil, and cull face are NOT part of the Metal pipeline state object
// (they are set separately via setDepthStencilState: and setCullMode:), so their absence
// from this key is correct. Depth-stencil state has its own cache key (MakeDepthStencilKey).
static uint64_t MakePipelineKey(bool blend_enabled, uint32_t blend_src, uint32_t blend_dst,
                                 bool depth_write, uint32_t color_mask_bits, bool has_texture) {
    uint64_t key = 0;
    key |= (blend_enabled ? 1ULL : 0);
    key |= ((uint64_t)(blend_src & 0xFFF)) << 1;
    key |= ((uint64_t)(blend_dst & 0xFFF)) << 13;
    key |= (depth_write ? 1ULL : 0) << 25;
    key |= ((uint64_t)(color_mask_bits & 0xF)) << 26;
    key |= (has_texture ? 1ULL : 0) << 30;
    return key;
}


// ---- Depth stencil state key ----
static uint64_t MakeDepthStencilKey(GLContext *ctx) {
    // Hash depth + stencil state into a 64-bit key
    uint64_t key = 0;
    key |= (ctx->depth_test ? 1ULL : 0);
    key |= ((ctx->depth_mask ? 1ULL : 0) << 1);
    key |= ((uint64_t)(ctx->depth_func & 0xFF) << 2);
    key |= ((ctx->stencil_test ? 1ULL : 0) << 10);
    key |= ((uint64_t)(ctx->stencil.func & 0xFF) << 11);
    key |= ((uint64_t)(ctx->stencil.ref & 0xFF) << 19);
    key |= ((uint64_t)(ctx->stencil.value_mask & 0xFF) << 27);
    key |= ((uint64_t)(ctx->stencil.write_mask & 0xFF) << 35);
    key |= ((uint64_t)(ctx->stencil.sfail & 0xF) << 43);
    key |= ((uint64_t)(ctx->stencil.dpfail & 0xF) << 47);
    key |= ((uint64_t)(ctx->stencil.dppass & 0xF) << 51);
    return key;
}


/*
 *  GLMetalInit - Initialize Metal resources for a GL context
 */
void GLMetalInit(GLContext *ctx)
{
    if (ctx->metal) return;  // already initialized

    // Note: Do NOT memset here. GLMetalState contains std::unordered_map and
    // ARC-managed id<> members whose constructors must not be destroyed.
    // Value-initialization via () already zeroes POD fields.
    GLMetalState *ms = new GLMetalState();
    ms->initialized = false;
    ms->currentBufferIndex = 0;
    ms->bufferOffset = 0;
    ms->renderPassActive = false;

    // Get the shared Metal device from the RAVE overlay's CAMetalLayer.
    // This ensures GL uses the same device as the layer and RAVE contexts,
    // avoiding undefined behavior when encoding to shared drawables.
    CAMetalLayer *sharedLayer = (__bridge CAMetalLayer *)RaveGetMetalLayer();
    ms->device = sharedLayer ? sharedLayer.device : nil;
    if (!ms->device) {
        // Defensive fallback — should not happen since RaveCreateMetalOverlay
        // sets the layer device before GL init.
        GL_METAL_LOG("GLMetalInit: layer device nil, falling back to MTLCreateSystemDefaultDevice");
        ms->device = MTLCreateSystemDefaultDevice();
    }
    if (!ms->device) {
        GL_METAL_LOG("GLMetalInit: MTLCreateSystemDefaultDevice failed");
        delete ms;
        return;
    }

    // Create command queue
    ms->commandQueue = [ms->device newCommandQueue];

    // Load shader library
    NSError *err = nil;
    NSString *libPath = [[NSBundle mainBundle] pathForResource:@"gl_shaders" ofType:@"metallib"];
    if (libPath) {
        ms->shaderLibrary = [ms->device newLibraryWithFile:libPath error:&err];
    }
    if (!ms->shaderLibrary) {
        // Try default library
        ms->shaderLibrary = [ms->device newDefaultLibrary];
    }
    if (!ms->shaderLibrary) {
        GL_METAL_LOG("GLMetalInit: failed to load shader library: %s",
                     err ? [[err localizedDescription] UTF8String] : "unknown");
        delete ms;
        return;
    }

    // Create vertex descriptor matching GLMetalVertex layout
    ms->vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
    // position: float4 at offset 0
    ms->vertexDescriptor.attributes[0].format = MTLVertexFormatFloat4;
    ms->vertexDescriptor.attributes[0].offset = 0;
    ms->vertexDescriptor.attributes[0].bufferIndex = 0;
    // color: float4 at offset 16
    ms->vertexDescriptor.attributes[1].format = MTLVertexFormatFloat4;
    ms->vertexDescriptor.attributes[1].offset = 16;
    ms->vertexDescriptor.attributes[1].bufferIndex = 0;
    // normal: float3 at offset 32
    ms->vertexDescriptor.attributes[2].format = MTLVertexFormatFloat3;
    ms->vertexDescriptor.attributes[2].offset = 32;
    ms->vertexDescriptor.attributes[2].bufferIndex = 0;
    // texcoord: float2 at offset 44
    ms->vertexDescriptor.attributes[3].format = MTLVertexFormatFloat2;
    ms->vertexDescriptor.attributes[3].offset = 44;
    ms->vertexDescriptor.attributes[3].bufferIndex = 0;
    // stride = 52
    ms->vertexDescriptor.layouts[0].stride = sizeof(GLMetalVertex);

    // Allocate triple-buffered vertex ring buffers (4MB each)
    for (int i = 0; i < GL_RING_BUFFER_COUNT; i++) {
        ms->vertexBuffers[i] = [ms->device newBufferWithLength:GL_RING_BUFFER_SIZE
                                                       options:MTLResourceStorageModeShared];
    }
    ms->currentBufferIndex = 0;
    ms->bufferOffset = 0;

    // Allocate uniform buffers
    ms->vertexUniformBuffer = [ms->device newBufferWithLength:sizeof(GLMetalVertexUniforms)
                                                      options:MTLResourceStorageModeShared];
    ms->fragmentUniformBuffer = [ms->device newBufferWithLength:sizeof(GLMetalFragmentUniforms)
                                                        options:MTLResourceStorageModeShared];
    ms->lightUniformBuffer = [ms->device newBufferWithLength:sizeof(GLMetalLightingData)
                                                     options:MTLResourceStorageModeShared];

    // Create sampler states
    MTLSamplerDescriptor *sampDesc = [[MTLSamplerDescriptor alloc] init];
    sampDesc.minFilter = MTLSamplerMinMagFilterLinear;
    sampDesc.magFilter = MTLSamplerMinMagFilterLinear;
    sampDesc.sAddressMode = MTLSamplerAddressModeRepeat;
    sampDesc.tAddressMode = MTLSamplerAddressModeRepeat;
    ms->linearSampler = [ms->device newSamplerStateWithDescriptor:sampDesc];

    sampDesc.minFilter = MTLSamplerMinMagFilterNearest;
    sampDesc.magFilter = MTLSamplerMinMagFilterNearest;
    ms->nearestSampler = [ms->device newSamplerStateWithDescriptor:sampDesc];

    ms->initialized = true;
    ctx->metal = (void *)ms;

    GL_METAL_LOG("GLMetalInit: success (device=%p queue=%p lib=%p)",
                 ms->device, ms->commandQueue, ms->shaderLibrary);
}


/*
 *  GLMetalGetPipeline - get or create cached pipeline state
 */
static id<MTLRenderPipelineState> GLMetalGetPipeline(GLMetalState *ms, GLContext *ctx) {
    bool blend_enabled = ctx->blend;
    uint32_t blend_src = ctx->blend_src;
    uint32_t blend_dst = ctx->blend_dst;
    bool depth_write = ctx->depth_mask;
    uint32_t color_mask_bits = (ctx->color_mask[0] ? 1 : 0) | (ctx->color_mask[1] ? 2 : 0) |
                               (ctx->color_mask[2] ? 4 : 0) | (ctx->color_mask[3] ? 8 : 0);
    bool has_texture = ctx->tex_units[ctx->active_texture].enabled_2d &&
                       ctx->tex_units[ctx->active_texture].bound_texture_2d != 0;

    uint64_t key = MakePipelineKey(blend_enabled, blend_src, blend_dst,
                                    depth_write, color_mask_bits, has_texture);

    auto it = ms->pipelineCache.find(key);
    if (it != ms->pipelineCache.end()) return it->second;

    // Create new pipeline
    NSError *err = nil;
    id<MTLFunction> vertexFunc = [ms->shaderLibrary newFunctionWithName:@"gl_vertex_main"];
    id<MTLFunction> fragmentFunc = [ms->shaderLibrary newFunctionWithName:@"gl_fragment_main"];
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

    // Blend state
    if (blend_enabled) {
        pipeDesc.colorAttachments[0].blendingEnabled = YES;
        pipeDesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pipeDesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        pipeDesc.colorAttachments[0].sourceRGBBlendFactor = GLBlendToMetal(blend_src);
        pipeDesc.colorAttachments[0].destinationRGBBlendFactor = GLBlendToMetal(blend_dst);
        // Independent alpha factors: maintain alpha=1.0 invariant regardless of RGB blend mode.
        // Matches RAVE pattern (rave_metal_renderer.mm:675-676) — prevents alpha degradation
        // that would make the overlay transparent through the CAMetalLayer.
        pipeDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pipeDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    } else {
        pipeDesc.colorAttachments[0].blendingEnabled = NO;
    }

    // Color write mask
    MTLColorWriteMask mask = MTLColorWriteMaskNone;
    if (color_mask_bits & 1) mask |= MTLColorWriteMaskRed;
    if (color_mask_bits & 2) mask |= MTLColorWriteMaskGreen;
    if (color_mask_bits & 4) mask |= MTLColorWriteMaskBlue;
    if (color_mask_bits & 8) mask |= MTLColorWriteMaskAlpha;
    pipeDesc.colorAttachments[0].writeMask = mask;

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


/*
 *  GLMetalCreateDepthStencilState - get or create cached depth stencil state
 */
static id<MTLDepthStencilState> GLMetalCreateDepthStencilState(GLMetalState *ms, GLContext *ctx) {
    uint64_t key = MakeDepthStencilKey(ctx);

    auto it = ms->depthStencilCache.find(key);
    if (it != ms->depthStencilCache.end()) return it->second;

    MTLDepthStencilDescriptor *desc = [[MTLDepthStencilDescriptor alloc] init];
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


/*
 *  Matrix multiplication helpers
 */
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
 *  Compute the normal matrix (inverse transpose of upper-left 3x3 of modelview).
 *  Output is in column-major order for Metal's float3x3:
 *  Metal float3x3 layout: columns[0].xyz, columns[1].xyz, columns[2].xyz
 *  stored as 3 x float4 (with padding) = 12 floats in memory.
 */
static void compute_normal_matrix(float *out12, const float *mv) {
    // Extract upper-left 3x3
    float a = mv[0], b = mv[4], c = mv[8];
    float d = mv[1], e = mv[5], f = mv[9];
    float g = mv[2], h = mv[6], k = mv[10];

    // Determinant
    float det = a * (e * k - f * h) - b * (d * k - f * g) + c * (d * h - e * g);
    if (fabsf(det) < 1e-12f) det = 1.0f;
    float inv_det = 1.0f / det;

    // Inverse of 3x3 (adjugate / det), then transpose for normal matrix
    // Normal matrix = transpose(inverse(M_3x3))
    // inverse:
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

    // Transpose of inverse -> normal matrix
    // Metal float3x3: column-major, packed as 3x float4 (col0.xyz, pad, col1.xyz, pad, col2.xyz, pad)
    out12[0] = inv[0]; out12[1] = inv[3]; out12[2] = inv[6]; out12[3] = 0.0f;
    out12[4] = inv[1]; out12[5] = inv[4]; out12[6] = inv[7]; out12[7] = 0.0f;
    out12[8] = inv[2]; out12[9] = inv[5]; out12[10] = inv[8]; out12[11] = 0.0f;
}


/*
 *  Create or recreate the depth buffer for the given dimensions
 */
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


/*
 *  GLMetalBeginFrame - start a new render pass for the current frame
 */
void GLMetalBeginFrame(GLContext *ctx)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->initialized) return;
    if (ms->renderPassActive) return;

    // Get the CAMetalLayer from the shared AccelMetalView
    // (created by RaveCreateMetalOverlay or by us)
    if (!ms->layer) {
        GL_METAL_LOG("GLMetalBeginFrame: no layer set");
        return;
    }

    ms->currentDrawable = [ms->layer nextDrawable];
    if (!ms->currentDrawable) {
        GL_METAL_LOG("GLMetalBeginFrame: nextDrawable returned nil");
        return;
    }

    int w = (int)[ms->currentDrawable.texture width];
    int h = (int)[ms->currentDrawable.texture height];
    EnsureDepthBuffer(ms, w, h);

    ms->currentCommandBuffer = [ms->commandQueue commandBuffer];

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = ms->currentDrawable.texture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    // Force alpha=1.0: games leave clear alpha at 0.0 (fully transparent) because
    // original GL had no overlay compositing. Without opaque alpha, the CAMetalLayer's
    // transparent background bleeds through, making the GL scene invisible.
    rpd.colorAttachments[0].clearColor = MTLClearColorMake(
        ctx->clear_color[0], ctx->clear_color[1],
        ctx->clear_color[2], 1.0  // always opaque for overlay compositing
    );

    rpd.depthAttachment.texture = ms->depthBuffer;
    rpd.depthAttachment.loadAction = MTLLoadActionClear;
    rpd.depthAttachment.storeAction = MTLStoreActionDontCare;
    rpd.depthAttachment.clearDepth = ctx->clear_depth;

    rpd.stencilAttachment.texture = ms->depthBuffer;
    rpd.stencilAttachment.loadAction = MTLLoadActionClear;
    rpd.stencilAttachment.storeAction = MTLStoreActionDontCare;
    rpd.stencilAttachment.clearStencil = ctx->clear_stencil;

    ms->currentEncoder = [ms->currentCommandBuffer renderCommandEncoderWithDescriptor:rpd];

    // Set viewport
    // AUDIT: VIEWPORT Y-ORIGIN (M003/S04/T01)
    // GL uses bottom-left origin; Metal uses top-left origin. Currently we pass
    // the GL viewport values directly to Metal without any Y-flip. This is
    // intentional: the game's projection matrix (glFrustum/glOrtho) already
    // encodes the coordinate space, and Metal's NDC Y-axis runs from -1 (bottom)
    // to +1 (top) — same as GL's NDC. The viewport Y origin only matters for
    // mapping NDC to framebuffer pixels. If games assume GL's bottom-left
    // viewport origin AND pass viewport.y != 0, rendering may be vertically
    // offset. However, most Mac OS 9 games set viewport to (0,0,w,h), where
    // the origin convention is irrelevant.
    //
    // STATUS: No speculative fix applied. Flagged for on-device investigation.
    // DIAGNOSTIC: If vertical offset is observed, try:
    //   vp.originY = drawable_height - (ctx->viewport[1] + ctx->viewport[3]);
    // to convert GL bottom-left to Metal top-left viewport origin.
    MTLViewport vp;
    vp.originX = ctx->viewport[0];
    vp.originY = ctx->viewport[1];
    vp.width   = ctx->viewport[2];
    vp.height  = ctx->viewport[3];
    vp.znear   = ctx->depth_range_near;
    vp.zfar    = ctx->depth_range_far;
    [ms->currentEncoder setViewport:vp];

    // Set scissor if enabled
    if (ctx->scissor_test) {
        MTLScissorRect sr;
        sr.x = ctx->scissor_box[0];
        sr.y = ctx->scissor_box[1];
        sr.width = ctx->scissor_box[2];
        sr.height = ctx->scissor_box[3];
        [ms->currentEncoder setScissorRect:sr];
    }

    ms->renderPassActive = true;
    ms->bufferOffset = 0;  // Reset ring buffer offset for new frame

    GL_METAL_LOG("GLMetalBeginFrame: encoder=%p drawable=%p", ms->currentEncoder, ms->currentDrawable);
}


/*
 *  Expand non-native primitives to triangle lists on CPU
 *
 *  Returns the expanded vertices in out_vertices. If no expansion is needed
 *  (already triangles/lines/points), returns false and caller should use original.
 */
static bool ExpandPrimitives(uint32_t gl_mode, const std::vector<GLVertex> &in,
                              std::vector<GLMetalVertex> &out,
                              MTLPrimitiveType &mtl_prim)
{
    auto copyVertex = [](GLMetalVertex &dst, const GLVertex &src) {
        memcpy(dst.position, src.position, sizeof(float) * 4);
        memcpy(dst.color, src.color, sizeof(float) * 4);
        memcpy(dst.normal, src.normal, sizeof(float) * 3);
        // Use texcoord from unit 0
        dst.texcoord[0] = src.texcoord[0][0];
        dst.texcoord[1] = src.texcoord[0][1];
    };

    size_t n = in.size();

    switch (gl_mode) {
        case GL_TRIANGLES:
            mtl_prim = MTLPrimitiveTypeTriangle;
            return false;  // direct, no expansion

        case GL_TRIANGLE_STRIP:
            mtl_prim = MTLPrimitiveTypeTriangleStrip;
            return false;

        case GL_TRIANGLE_FAN: {
            // Fan: vertex 0 is hub, triangle i = (0, i, i+1)
            mtl_prim = MTLPrimitiveTypeTriangle;
            if (n < 3) return true;  // empty output
            out.reserve((n - 2) * 3);
            for (size_t i = 1; i + 1 < n; i++) {
                GLMetalVertex v0, v1, v2;
                copyVertex(v0, in[0]);
                copyVertex(v1, in[i]);
                copyVertex(v2, in[i + 1]);
                out.push_back(v0);
                out.push_back(v1);
                out.push_back(v2);
            }
            return true;
        }

        case GL_QUADS: {
            // Each quad (4 verts) -> 2 triangles
            mtl_prim = MTLPrimitiveTypeTriangle;
            size_t numQuads = n / 4;
            out.reserve(numQuads * 6);
            for (size_t i = 0; i < numQuads; i++) {
                size_t base = i * 4;
                GLMetalVertex v0, v1, v2, v3;
                copyVertex(v0, in[base + 0]);
                copyVertex(v1, in[base + 1]);
                copyVertex(v2, in[base + 2]);
                copyVertex(v3, in[base + 3]);
                // Triangle 1: 0,1,2
                out.push_back(v0); out.push_back(v1); out.push_back(v2);
                // Triangle 2: 0,2,3
                out.push_back(v0); out.push_back(v2); out.push_back(v3);
            }
            return true;
        }

        case GL_QUAD_STRIP: {
            // Pairs of quads from consecutive vert pairs
            mtl_prim = MTLPrimitiveTypeTriangle;
            if (n < 4) return true;
            size_t numQuads = (n - 2) / 2;
            out.reserve(numQuads * 6);
            for (size_t i = 0; i < numQuads; i++) {
                size_t base = i * 2;
                GLMetalVertex v0, v1, v2, v3;
                copyVertex(v0, in[base + 0]);
                copyVertex(v1, in[base + 1]);
                copyVertex(v2, in[base + 3]);
                copyVertex(v3, in[base + 2]);
                out.push_back(v0); out.push_back(v1); out.push_back(v2);
                out.push_back(v0); out.push_back(v2); out.push_back(v3);
            }
            return true;
        }

        case GL_POLYGON: {
            // Same as triangle fan: vertex 0 is hub
            mtl_prim = MTLPrimitiveTypeTriangle;
            if (n < 3) return true;
            out.reserve((n - 2) * 3);
            for (size_t i = 1; i + 1 < n; i++) {
                GLMetalVertex v0, v1, v2;
                copyVertex(v0, in[0]);
                copyVertex(v1, in[i]);
                copyVertex(v2, in[i + 1]);
                out.push_back(v0);
                out.push_back(v1);
                out.push_back(v2);
            }
            return true;
        }

        case GL_LINES:
            mtl_prim = MTLPrimitiveTypeLine;
            return false;

        case GL_LINE_STRIP:
            mtl_prim = MTLPrimitiveTypeLineStrip;
            return false;

        case GL_LINE_LOOP: {
            // Line strip + closing edge
            mtl_prim = MTLPrimitiveTypeLine;
            if (n < 2) return true;
            out.reserve(n * 2);
            for (size_t i = 0; i + 1 < n; i++) {
                GLMetalVertex v0, v1;
                copyVertex(v0, in[i]);
                copyVertex(v1, in[i + 1]);
                out.push_back(v0);
                out.push_back(v1);
            }
            // Close the loop
            GLMetalVertex vLast, vFirst;
            copyVertex(vLast, in[n - 1]);
            copyVertex(vFirst, in[0]);
            out.push_back(vLast);
            out.push_back(vFirst);
            return true;
        }

        case GL_POINTS:
            mtl_prim = MTLPrimitiveTypePoint;
            return false;

        default:
            mtl_prim = MTLPrimitiveTypeTriangle;
            return false;
    }
}


/*
 *  Convert im_vertices to GLMetalVertex format (no expansion needed)
 */
static void ConvertVertices(const std::vector<GLVertex> &in, std::vector<GLMetalVertex> &out) {
    out.resize(in.size());
    for (size_t i = 0; i < in.size(); i++) {
        memcpy(out[i].position, in[i].position, sizeof(float) * 4);
        memcpy(out[i].color, in[i].color, sizeof(float) * 4);
        memcpy(out[i].normal, in[i].normal, sizeof(float) * 3);
        out[i].texcoord[0] = in[i].texcoord[0][0];
        out[i].texcoord[1] = in[i].texcoord[0][1];
    }
}


/*
 *  Upload fog mode as integer constant for the shader
 */
static int32_t GLFogModeToShader(uint32_t gl_mode) {
    switch (gl_mode) {
        case GL_LINEAR: return 1;
        case GL_EXP:    return 2;
        case GL_EXP2:   return 3;
        default:        return 0;
    }
}


// GL texenv mode constants
#define GL_MODULATE_TEX    0x2100
#define GL_DECAL_TEX       0x2101
#define GL_BLEND_TEXENV    0x0BE2
#define GL_REPLACE_TEX     0x1E01
#define GL_ADD_TEX         0x0104

/*
 *  Convert GL texenv mode enum to shader integer constant
 *  Shader expects: 0=modulate, 1=decal, 2=blend, 3=replace, 4=add
 */
static int32_t GLTexEnvModeToShader(uint32_t gl_mode) {
    switch (gl_mode) {
        case GL_MODULATE_TEX:  return 0;
        case GL_DECAL_TEX:     return 1;
        case GL_BLEND_TEXENV:  return 2;
        case GL_REPLACE_TEX:   return 3;
        case GL_ADD_TEX:       return 4;
        default:               return 0;  // default to modulate
    }
}


/*
 *  Convert GL alpha comparison func enum (0x0200-0x0207) to shader integer 0-7
 */
static int32_t GLAlphaFuncToShader(uint32_t gl_func) {
    if (gl_func >= GL_NEVER && gl_func <= GL_ALWAYS) {
        return (int32_t)(gl_func - GL_NEVER);
    }
    return 7;  // default to GL_ALWAYS
}


/*
 *  GLMetalFlushAndResetRingBuffer - mid-frame flush when ring buffer is full
 *
 *  Commits the current command buffer, resets the ring buffer write offset to 0,
 *  and begins a new render pass with MTLLoadActionLoad to preserve existing
 *  framebuffer content.  The caller (GLMetalFlushImmediateMode) sets all per-draw
 *  Metal state (pipeline, depth-stencil, cull, textures, uniforms) after this
 *  returns, so we only need to restore viewport and scissor on the new encoder.
 *
 *  Returns true if the new encoder is ready; false if recovery failed (caller
 *  should skip the draw call).
 */
static bool GLMetalFlushAndResetRingBuffer(GLContext *ctx)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;

    GL_METAL_LOG("GLMetalFlushAndResetRingBuffer: ring buffer full (offset=%d/%d), flushing mid-frame",
                 ms->bufferOffset, GL_RING_BUFFER_SIZE);

    // (a) End current render command encoder
    if (ms->currentEncoder) {
        [ms->currentEncoder endEncoding];
        ms->currentEncoder = nil;
    }

    // (b) Commit current command buffer and wait for completion
    if (ms->currentCommandBuffer) {
        [ms->currentCommandBuffer commit];
        [ms->currentCommandBuffer waitUntilCompleted];
        ms->lastCommittedBuffer = ms->currentCommandBuffer;
        ms->currentCommandBuffer = nil;
    }

    // (c) Reset ring buffer write offset to 0
    ms->bufferOffset = 0;

    // (d) Create a new command buffer
    ms->currentCommandBuffer = [ms->commandQueue commandBuffer];
    if (!ms->currentCommandBuffer) {
        GL_METAL_LOG("GLMetalFlushAndResetRingBuffer: failed to create new command buffer");
        return false;
    }

    // (e) Create a new render pass descriptor with MTLLoadActionLoad
    //     to preserve existing framebuffer content (color + depth + stencil)
    if (!ms->currentDrawable) {
        GL_METAL_LOG("GLMetalFlushAndResetRingBuffer: no drawable, cannot restart encoder");
        return false;
    }

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = ms->currentDrawable.texture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    if (ms->depthBuffer) {
        rpd.depthAttachment.texture = ms->depthBuffer;
        rpd.depthAttachment.loadAction = MTLLoadActionLoad;
        rpd.depthAttachment.storeAction = MTLStoreActionStore;
        rpd.stencilAttachment.texture = ms->depthBuffer;
        rpd.stencilAttachment.loadAction = MTLLoadActionLoad;
        rpd.stencilAttachment.storeAction = MTLStoreActionStore;
    }

    // (f) Begin a new render command encoder
    ms->currentEncoder = [ms->currentCommandBuffer renderCommandEncoderWithDescriptor:rpd];
    if (!ms->currentEncoder) {
        GL_METAL_LOG("GLMetalFlushAndResetRingBuffer: failed to create new encoder");
        return false;
    }

    // (g) Restore viewport and scissor on the new encoder
    //     (pipeline, depth-stencil, cull, textures, uniforms are set per-draw
    //      by GLMetalFlushImmediateMode after we return)
    MTLViewport vp;
    vp.originX = ctx->viewport[0];
    vp.originY = ctx->viewport[1];
    vp.width   = ctx->viewport[2];
    vp.height  = ctx->viewport[3];
    vp.znear   = ctx->depth_range_near;
    vp.zfar    = ctx->depth_range_far;
    [ms->currentEncoder setViewport:vp];

    if (ctx->scissor_test) {
        MTLScissorRect sr;
        sr.x = ctx->scissor_box[0];
        sr.y = ctx->scissor_box[1];
        sr.width = ctx->scissor_box[2];
        sr.height = ctx->scissor_box[3];
        [ms->currentEncoder setScissorRect:sr];
    }

    GL_METAL_LOG("GLMetalFlushAndResetRingBuffer: mid-frame flush complete, encoder restarted");
    return true;
}


/*
 *  GLMetalFlushImmediateMode - flush accumulated im_vertices to a Metal draw call
 *
 *  Called at glEnd(). Converts accumulated vertices, uploads uniforms,
 *  and encodes a draw command.
 */
void GLMetalFlushImmediateMode(GLContext *ctx)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->initialized) return;
    if (ctx->im_vertices.empty()) return;

    // Auto-start frame if needed
    if (!ms->renderPassActive) {
        GLMetalBeginFrame(ctx);
        if (!ms->renderPassActive) return;
    }

    // ---- Determine primitive type and expand if needed ----
    MTLPrimitiveType mtlPrim;
    std::vector<GLMetalVertex> expandedVerts;
    bool expanded = ExpandPrimitives(ctx->im_mode, ctx->im_vertices, expandedVerts, mtlPrim);

    const GLMetalVertex *vertData;
    size_t vertCount;

    if (expanded) {
        vertData = expandedVerts.data();
        vertCount = expandedVerts.size();
    } else {
        // Convert directly (no primitive expansion needed)
        ConvertVertices(ctx->im_vertices, expandedVerts);
        vertData = expandedVerts.data();
        vertCount = expandedVerts.size();
    }

    if (vertCount == 0) return;

    size_t vertBytes = vertCount * sizeof(GLMetalVertex);

    // ---- Check ring buffer space ----
    if (ms->bufferOffset + (int)vertBytes > GL_RING_BUFFER_SIZE) {
        // Mid-frame flush: commit current work, reset ring buffer, restart encoder
        if (!GLMetalFlushAndResetRingBuffer(ctx)) {
            GL_METAL_LOG("GLMetalFlushImmediateMode: ring buffer flush failed, dropping draw");
            return;
        }
        // After flush, offset is 0 — verify the single draw fits in the buffer
        if ((int)vertBytes > GL_RING_BUFFER_SIZE) {
            GL_METAL_LOG("GLMetalFlushImmediateMode: single draw exceeds ring buffer (%zu > %d)",
                         vertBytes, GL_RING_BUFFER_SIZE);
            return;
        }
    }

    // Copy vertices into ring buffer
    id<MTLBuffer> vb = ms->vertexBuffers[ms->currentBufferIndex];
    memcpy((uint8_t *)[vb contents] + ms->bufferOffset, vertData, vertBytes);

    // ---- Compute MVP matrix ----
    const float *mv = ctx->modelview_stack[ctx->modelview_depth];
    const float *proj = ctx->projection_stack[ctx->projection_depth];
    float mvp[16];
    mat4_multiply(mvp, proj, mv);

    // ---- Upload vertex uniforms ----
    GLMetalVertexUniforms *vu = (GLMetalVertexUniforms *)[ms->vertexUniformBuffer contents];
    memcpy(vu->mvp_matrix, mvp, sizeof(float) * 16);
    memcpy(vu->modelview_matrix, mv, sizeof(float) * 16);
    compute_normal_matrix(vu->normal_matrix, mv);
    vu->lighting_enabled = ctx->lighting_enabled ? 1 : 0;
    vu->normalize_enabled = ctx->normalize ? 1 : 0;
    vu->num_active_lights = 0;
    for (int i = 0; i < 8; i++) {
        if (ctx->lights[i].enabled) vu->num_active_lights++;
    }
    vu->fog_enabled = ctx->fog_enabled ? 1 : 0;
    vu->fog_mode = ctx->fog_enabled ? GLFogModeToShader(ctx->fog_mode) : 0;
    vu->fog_start = ctx->fog_start;
    vu->fog_end = ctx->fog_end;
    vu->fog_density = ctx->fog_density;

    // ---- Upload fragment uniforms ----
    GLMetalFragmentUniforms *fu = (GLMetalFragmentUniforms *)[ms->fragmentUniformBuffer contents];
    int texUnit = ctx->active_texture;
    fu->texenv_mode = GLTexEnvModeToShader(ctx->tex_units[texUnit].env_mode);
    memcpy(fu->texenv_color, ctx->tex_units[texUnit].env_color, sizeof(float) * 4);
    if (ctx->fog_enabled) {
        memcpy(fu->fog_color, ctx->fog_color, sizeof(float) * 4);
    } else {
        fu->fog_color[0] = fu->fog_color[1] = fu->fog_color[2] = 0.0f;
        fu->fog_color[3] = -1.0f;  // sentinel: fog inactive
    }
    fu->alpha_test_enabled = ctx->alpha_test ? 1 : 0;
    fu->alpha_func = GLAlphaFuncToShader(ctx->alpha_func);
    fu->alpha_ref = ctx->alpha_ref;
    fu->has_texture = (ctx->tex_units[texUnit].enabled_2d &&
                       ctx->tex_units[texUnit].bound_texture_2d != 0) ? 1 : 0;
    fu->shade_model = (ctx->shade_model == GL_SMOOTH) ? 1 : 0;

    // ---- Upload lighting data ----
    GLMetalLightingData *ld = (GLMetalLightingData *)[ms->lightUniformBuffer contents];
    for (int i = 0; i < 8; i++) {
        memcpy(ld->lights[i].ambient, ctx->lights[i].ambient, sizeof(float) * 4);
        memcpy(ld->lights[i].diffuse, ctx->lights[i].diffuse, sizeof(float) * 4);
        memcpy(ld->lights[i].specular, ctx->lights[i].specular, sizeof(float) * 4);
        memcpy(ld->lights[i].position, ctx->lights[i].position, sizeof(float) * 4);
        memcpy(ld->lights[i].spot_direction, ctx->lights[i].spot_direction, sizeof(float) * 3);
        ld->lights[i].spot_exponent = ctx->lights[i].spot_exponent;
        // Convert cutoff angle: if 180 degrees, store -1.0 as sentinel (no spotlight)
        if (ctx->lights[i].spot_cutoff >= 180.0f) {
            ld->lights[i].spot_cutoff = -1.0f;
        } else {
            ld->lights[i].spot_cutoff = cosf(ctx->lights[i].spot_cutoff * M_PI / 180.0f);
        }
        ld->lights[i].constant_atten = ctx->lights[i].constant_attenuation;
        ld->lights[i].linear_atten = ctx->lights[i].linear_attenuation;
        ld->lights[i].quadratic_atten = ctx->lights[i].quadratic_attenuation;
        ld->lights[i].enabled = ctx->lights[i].enabled ? 1 : 0;
    }
    // Material (front face)
    memcpy(ld->material.ambient, ctx->materials[0].ambient, sizeof(float) * 4);
    memcpy(ld->material.diffuse, ctx->materials[0].diffuse, sizeof(float) * 4);
    memcpy(ld->material.specular, ctx->materials[0].specular, sizeof(float) * 4);
    memcpy(ld->material.emission, ctx->materials[0].emission, sizeof(float) * 4);
    ld->material.shininess = ctx->materials[0].shininess;
    memcpy(ld->global_ambient, ctx->light_model_ambient, sizeof(float) * 4);

    // ---- Get/create pipeline state ----
    id<MTLRenderPipelineState> pipeline = GLMetalGetPipeline(ms, ctx);
    if (!pipeline) return;

    // ---- Get/create depth stencil state ----
    id<MTLDepthStencilState> dsState = GLMetalCreateDepthStencilState(ms, ctx);

    // ---- Encode draw call ----
    [ms->currentEncoder setRenderPipelineState:pipeline];
    [ms->currentEncoder setDepthStencilState:dsState];

    // Set stencil reference value when stencil test is active
    if (ctx->stencil_test) {
        [ms->currentEncoder setStencilReferenceValue:(uint32_t)(ctx->stencil.ref & 0xFF)];
    }

    // Cull face
    if (ctx->cull_face_enabled) {
        // GL_BACK (0x0405) = cull back faces = MTLCullModeBack; GL_FRONT (0x0404) = cull front faces = MTLCullModeFront
        MTLCullMode cm = (ctx->cull_face_mode == 0x0405) ? MTLCullModeBack : MTLCullModeFront;
        [ms->currentEncoder setCullMode:cm];
        MTLWinding winding = (ctx->front_face == 0x0901) ? MTLWindingCounterClockwise : MTLWindingClockwise;  // GL_CCW=0x0901
        [ms->currentEncoder setFrontFacingWinding:winding];
    } else {
        [ms->currentEncoder setCullMode:MTLCullModeNone];
    }

    // Vertex data at buffer 0 (via vertex descriptor), uniforms at buffer 1, lighting at buffer 2
    // Shader uses [[buffer(1)]] for vertex uniforms and [[buffer(2)]] for lighting data
    [ms->currentEncoder setVertexBuffer:vb offset:ms->bufferOffset atIndex:0];
    [ms->currentEncoder setVertexBuffer:ms->vertexUniformBuffer offset:0 atIndex:1];
    [ms->currentEncoder setVertexBuffer:ms->lightUniformBuffer offset:0 atIndex:2];

    [ms->currentEncoder setFragmentBuffer:ms->fragmentUniformBuffer offset:0 atIndex:1];

    // Bind texture if available -- use per-texture sampler from cache
    if (fu->has_texture) {
        uint32_t texName = ctx->tex_units[texUnit].bound_texture_2d;
        auto texIt = ctx->texture_objects.find(texName);
        if (texIt != ctx->texture_objects.end() && texIt->second.metal_texture) {
            id<MTLTexture> mtlTex = (__bridge id<MTLTexture>)(texIt->second.metal_texture);
            [ms->currentEncoder setFragmentTexture:mtlTex atIndex:0];
            // Use sampler derived from texture's filter/wrap parameters
            id<MTLSamplerState> sampler = GLMetalGetSampler(ms, &texIt->second);
            [ms->currentEncoder setFragmentSamplerState:sampler atIndex:0];
        }
    }

    [ms->currentEncoder drawPrimitives:mtlPrim vertexStart:0 vertexCount:vertCount];

    // Advance ring buffer offset
    ms->bufferOffset += (int)vertBytes;
    // Align to 256 bytes for Metal buffer offset requirements
    ms->bufferOffset = (ms->bufferOffset + 255) & ~255;

    GL_METAL_LOG("GLMetalFlushImmediateMode: drew %zu verts as prim %d, offset now %d",
                 vertCount, (int)mtlPrim, ms->bufferOffset);
}


/*
 *  GLMetalDrawPixels - render BGRA8 pixel data as a screen-aligned textured quad
 *
 *  Called from NativeGLDrawPixels after ConvertPixelsToBGRA8. Creates a transient
 *  Metal texture, computes an NDC quad at the current raster position, and draws
 *  with depth write/test disabled. Uses the current blend state.
 */
void GLMetalDrawPixels(GLContext *ctx, int width, int height, const uint8_t *bgra_data, int data_len)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->initialized) return;

    // Auto-start frame if needed
    if (!ms->renderPassActive) {
        GLMetalBeginFrame(ctx);
        if (!ms->renderPassActive) return;
    }

    // Create transient texture from BGRA8 data
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

    // Compute NDC quad from raster position and viewport
    float vp_x = (float)ctx->viewport[0];
    float vp_y = (float)ctx->viewport[1];
    float vp_w = (float)ctx->viewport[2];
    float vp_h = (float)ctx->viewport[3];
    if (vp_w <= 0 || vp_h <= 0) return;

    float win_x = ctx->raster_pos[0];
    float win_y = ctx->raster_pos[1];

    // Apply pixel zoom to quad dimensions (in pixels)
    float quad_w = (float)width * ctx->pixel_zoom_x;
    float quad_h = (float)height * ctx->pixel_zoom_y;

    // Convert to NDC
    float ndc_x0 = (win_x - vp_x) / vp_w * 2.0f - 1.0f;
    float ndc_y0 = (win_y - vp_y) / vp_h * 2.0f - 1.0f;
    float ndc_x1 = ndc_x0 + quad_w / vp_w * 2.0f;
    float ndc_y1 = ndc_y0 + quad_h / vp_h * 2.0f;

    // Build 4 vertices for triangle strip (positions in NDC, white color, texcoords 0→1)
    GLMetalVertex verts[4];
    memset(verts, 0, sizeof(verts));
    // v0: bottom-left
    verts[0].position[0] = ndc_x0; verts[0].position[1] = ndc_y0; verts[0].position[2] = 0; verts[0].position[3] = 1;
    verts[0].color[0] = 1; verts[0].color[1] = 1; verts[0].color[2] = 1; verts[0].color[3] = 1;
    verts[0].texcoord[0] = 0; verts[0].texcoord[1] = 1;  // GL bottom row = texture V=1
    // v1: bottom-right
    verts[1].position[0] = ndc_x1; verts[1].position[1] = ndc_y0; verts[1].position[2] = 0; verts[1].position[3] = 1;
    verts[1].color[0] = 1; verts[1].color[1] = 1; verts[1].color[2] = 1; verts[1].color[3] = 1;
    verts[1].texcoord[0] = 1; verts[1].texcoord[1] = 1;
    // v2: top-left
    verts[2].position[0] = ndc_x0; verts[2].position[1] = ndc_y1; verts[2].position[2] = 0; verts[2].position[3] = 1;
    verts[2].color[0] = 1; verts[2].color[1] = 1; verts[2].color[2] = 1; verts[2].color[3] = 1;
    verts[2].texcoord[0] = 0; verts[2].texcoord[1] = 0;
    // v3: top-right
    verts[3].position[0] = ndc_x1; verts[3].position[1] = ndc_y1; verts[3].position[2] = 0; verts[3].position[3] = 1;
    verts[3].color[0] = 1; verts[3].color[1] = 1; verts[3].color[2] = 1; verts[3].color[3] = 1;
    verts[3].texcoord[0] = 1; verts[3].texcoord[1] = 0;

    // Set up identity MVP (NDC pass-through)
    GLMetalVertexUniforms *vu = (GLMetalVertexUniforms *)[ms->vertexUniformBuffer contents];
    static const float identity[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
    memcpy(vu->mvp_matrix, identity, sizeof(float) * 16);
    memcpy(vu->modelview_matrix, identity, sizeof(float) * 16);
    memset(vu->normal_matrix, 0, sizeof(float) * 12);
    vu->normal_matrix[0] = 1; vu->normal_matrix[4] = 1; vu->normal_matrix[8] = 1;
    vu->lighting_enabled = 0;
    vu->normalize_enabled = 0;
    vu->num_active_lights = 0;
    vu->fog_enabled = 0;
    vu->fog_mode = 0;
    vu->fog_start = 0; vu->fog_end = 1; vu->fog_density = 0;

    // Set up fragment uniforms: replace mode, has_texture, no alpha test, fog inactive
    GLMetalFragmentUniforms *fu = (GLMetalFragmentUniforms *)[ms->fragmentUniformBuffer contents];
    fu->texenv_mode = 3;  // replace: use texture color directly
    fu->texenv_color[0] = fu->texenv_color[1] = fu->texenv_color[2] = fu->texenv_color[3] = 1.0f;
    fu->fog_color[0] = fu->fog_color[1] = fu->fog_color[2] = 0.0f;
    fu->fog_color[3] = -1.0f;  // sentinel: fog inactive
    fu->alpha_test_enabled = 0;
    fu->alpha_func = 0;
    fu->alpha_ref = 0;
    fu->has_texture = 1;
    fu->shade_model = 1;  // smooth

    // Get pipeline with current blend state (DrawPixels respects existing blend)
    // Temporarily override depth_mask for pipeline key (no depth write for pixel draws)
    bool saved_depth_mask = ctx->depth_mask;
    ctx->depth_mask = false;
    id<MTLRenderPipelineState> pipeline = GLMetalGetPipeline(ms, ctx);
    ctx->depth_mask = saved_depth_mask;
    if (!pipeline) return;

    // Depth stencil: depth write OFF, depth test OFF
    MTLDepthStencilDescriptor *dsDesc = [[MTLDepthStencilDescriptor alloc] init];
    dsDesc.depthCompareFunction = MTLCompareFunctionAlways;
    dsDesc.depthWriteEnabled = NO;
    id<MTLDepthStencilState> dsState = [ms->device newDepthStencilStateWithDescriptor:dsDesc];

    // Encode draw
    [ms->currentEncoder setRenderPipelineState:pipeline];
    [ms->currentEncoder setDepthStencilState:dsState];
    [ms->currentEncoder setCullMode:MTLCullModeNone];
    [ms->currentEncoder setVertexBytes:verts length:sizeof(verts) atIndex:0];
    [ms->currentEncoder setVertexBuffer:ms->vertexUniformBuffer offset:0 atIndex:1];
    [ms->currentEncoder setVertexBuffer:ms->lightUniformBuffer offset:0 atIndex:2];
    [ms->currentEncoder setFragmentBuffer:ms->fragmentUniformBuffer offset:0 atIndex:1];
    [ms->currentEncoder setFragmentTexture:tex atIndex:0];
    [ms->currentEncoder setFragmentSamplerState:ms->nearestSampler atIndex:0];
    [ms->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];

    GL_METAL_LOG("GLMetalDrawPixels: %dx%d at raster (%.1f, %.1f) zoom (%.1f, %.1f)",
                 width, height, ctx->raster_pos[0], ctx->raster_pos[1],
                 ctx->pixel_zoom_x, ctx->pixel_zoom_y);
}


/*
 *  GLMetalBitmap - render unpacked 1-bit bitmap as a screen-aligned textured quad
 *
 *  Called from NativeGLBitmap after 1-bit → BGRA8 expansion. Same rendering
 *  approach as GLMetalDrawPixels but always uses SrcAlpha/OneMinusSrcAlpha blend
 *  for bitmap transparency (bit=0 pixels are fully transparent).
 */
void GLMetalBitmap(GLContext *ctx, int width, int height, const uint8_t *bgra_data, int data_len)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->initialized) return;

    // Auto-start frame if needed
    if (!ms->renderPassActive) {
        GLMetalBeginFrame(ctx);
        if (!ms->renderPassActive) return;
    }

    // Create transient texture from BGRA8 data
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

    // Compute NDC quad from raster position and viewport
    float vp_x = (float)ctx->viewport[0];
    float vp_y = (float)ctx->viewport[1];
    float vp_w = (float)ctx->viewport[2];
    float vp_h = (float)ctx->viewport[3];
    if (vp_w <= 0 || vp_h <= 0) return;

    float win_x = ctx->raster_pos[0];
    float win_y = ctx->raster_pos[1];

    // Apply pixel zoom to quad dimensions (in pixels)
    float quad_w = (float)width * ctx->pixel_zoom_x;
    float quad_h = (float)height * ctx->pixel_zoom_y;

    // Convert to NDC
    float ndc_x0 = (win_x - vp_x) / vp_w * 2.0f - 1.0f;
    float ndc_y0 = (win_y - vp_y) / vp_h * 2.0f - 1.0f;
    float ndc_x1 = ndc_x0 + quad_w / vp_w * 2.0f;
    float ndc_y1 = ndc_y0 + quad_h / vp_h * 2.0f;

    // Build 4 vertices for triangle strip
    GLMetalVertex verts[4];
    memset(verts, 0, sizeof(verts));
    verts[0].position[0] = ndc_x0; verts[0].position[1] = ndc_y0; verts[0].position[2] = 0; verts[0].position[3] = 1;
    verts[0].color[0] = 1; verts[0].color[1] = 1; verts[0].color[2] = 1; verts[0].color[3] = 1;
    verts[0].texcoord[0] = 0; verts[0].texcoord[1] = 1;
    verts[1].position[0] = ndc_x1; verts[1].position[1] = ndc_y0; verts[1].position[2] = 0; verts[1].position[3] = 1;
    verts[1].color[0] = 1; verts[1].color[1] = 1; verts[1].color[2] = 1; verts[1].color[3] = 1;
    verts[1].texcoord[0] = 1; verts[1].texcoord[1] = 1;
    verts[2].position[0] = ndc_x0; verts[2].position[1] = ndc_y1; verts[2].position[2] = 0; verts[2].position[3] = 1;
    verts[2].color[0] = 1; verts[2].color[1] = 1; verts[2].color[2] = 1; verts[2].color[3] = 1;
    verts[2].texcoord[0] = 0; verts[2].texcoord[1] = 0;
    verts[3].position[0] = ndc_x1; verts[3].position[1] = ndc_y1; verts[3].position[2] = 0; verts[3].position[3] = 1;
    verts[3].color[0] = 1; verts[3].color[1] = 1; verts[3].color[2] = 1; verts[3].color[3] = 1;
    verts[3].texcoord[0] = 1; verts[3].texcoord[1] = 0;

    // Set up identity MVP (NDC pass-through)
    GLMetalVertexUniforms *vu = (GLMetalVertexUniforms *)[ms->vertexUniformBuffer contents];
    static const float identity[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};
    memcpy(vu->mvp_matrix, identity, sizeof(float) * 16);
    memcpy(vu->modelview_matrix, identity, sizeof(float) * 16);
    memset(vu->normal_matrix, 0, sizeof(float) * 12);
    vu->normal_matrix[0] = 1; vu->normal_matrix[4] = 1; vu->normal_matrix[8] = 1;
    vu->lighting_enabled = 0;
    vu->normalize_enabled = 0;
    vu->num_active_lights = 0;
    vu->fog_enabled = 0;
    vu->fog_mode = 0;
    vu->fog_start = 0; vu->fog_end = 1; vu->fog_density = 0;

    // Fragment uniforms: replace mode, textured, no alpha test, fog inactive
    GLMetalFragmentUniforms *fu = (GLMetalFragmentUniforms *)[ms->fragmentUniformBuffer contents];
    fu->texenv_mode = 3;  // replace
    fu->texenv_color[0] = fu->texenv_color[1] = fu->texenv_color[2] = fu->texenv_color[3] = 1.0f;
    fu->fog_color[0] = fu->fog_color[1] = fu->fog_color[2] = 0.0f;
    fu->fog_color[3] = -1.0f;
    fu->alpha_test_enabled = 0;
    fu->alpha_func = 0;
    fu->alpha_ref = 0;
    fu->has_texture = 1;
    fu->shade_model = 1;

    // Pipeline with blend enabled (SrcAlpha/OneMinusSrcAlpha) for bitmap transparency
    // Temporarily override blend state and depth_mask for pipeline key
    bool saved_blend = ctx->blend;
    uint32_t saved_src = ctx->blend_src;
    uint32_t saved_dst = ctx->blend_dst;
    bool saved_depth_mask = ctx->depth_mask;
    ctx->blend = true;
    ctx->blend_src = 0x0302;  // GL_SRC_ALPHA
    ctx->blend_dst = 0x0303;  // GL_ONE_MINUS_SRC_ALPHA
    ctx->depth_mask = false;
    id<MTLRenderPipelineState> pipeline = GLMetalGetPipeline(ms, ctx);
    ctx->blend = saved_blend;
    ctx->blend_src = saved_src;
    ctx->blend_dst = saved_dst;
    ctx->depth_mask = saved_depth_mask;
    if (!pipeline) return;

    // Depth stencil: depth write OFF, depth test OFF
    MTLDepthStencilDescriptor *dsDesc = [[MTLDepthStencilDescriptor alloc] init];
    dsDesc.depthCompareFunction = MTLCompareFunctionAlways;
    dsDesc.depthWriteEnabled = NO;
    id<MTLDepthStencilState> dsState = [ms->device newDepthStencilStateWithDescriptor:dsDesc];

    // Encode draw
    [ms->currentEncoder setRenderPipelineState:pipeline];
    [ms->currentEncoder setDepthStencilState:dsState];
    [ms->currentEncoder setCullMode:MTLCullModeNone];
    [ms->currentEncoder setVertexBytes:verts length:sizeof(verts) atIndex:0];
    [ms->currentEncoder setVertexBuffer:ms->vertexUniformBuffer offset:0 atIndex:1];
    [ms->currentEncoder setVertexBuffer:ms->lightUniformBuffer offset:0 atIndex:2];
    [ms->currentEncoder setFragmentBuffer:ms->fragmentUniformBuffer offset:0 atIndex:1];
    [ms->currentEncoder setFragmentTexture:tex atIndex:0];
    [ms->currentEncoder setFragmentSamplerState:ms->nearestSampler atIndex:0];
    [ms->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];

    GL_METAL_LOG("GLMetalBitmap: %dx%d at raster (%.1f, %.1f) zoom (%.1f, %.1f)",
                 width, height, ctx->raster_pos[0], ctx->raster_pos[1],
                 ctx->pixel_zoom_x, ctx->pixel_zoom_y);
}


/*
 *  GLMetalEndFrame - finish rendering and present
 */
void GLMetalEndFrame(GLContext *ctx)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->renderPassActive) return;

    [ms->currentEncoder endEncoding];
    ms->currentEncoder = nil;

    if (ms->currentDrawable) {
        [ms->currentCommandBuffer presentDrawable:ms->currentDrawable];
    }

    [ms->currentCommandBuffer commit];
    ms->lastCommittedBuffer = ms->currentCommandBuffer;
    ms->currentCommandBuffer = nil;
    ms->currentDrawable = nil;
    ms->renderPassActive = false;

    // Advance ring buffer
    ms->currentBufferIndex = (ms->currentBufferIndex + 1) % GL_RING_BUFFER_COUNT;
    ms->bufferOffset = 0;

    GL_METAL_LOG("GLMetalEndFrame: frame committed, buffer index now %d", ms->currentBufferIndex);
}


/*
 *  NativeGLFinish - end current encoder, commit command buffer, wait until complete
 */
void NativeGLFinish(GLContext *ctx)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms) return;

    if (ms->renderPassActive && ms->currentEncoder) {
        [ms->currentEncoder endEncoding];
        ms->currentEncoder = nil;
    }
    if (ms->currentCommandBuffer) {
        [ms->currentCommandBuffer commit];
        [ms->currentCommandBuffer waitUntilCompleted];
        ms->lastCommittedBuffer = ms->currentCommandBuffer;
        ms->currentCommandBuffer = nil;
        ms->renderPassActive = false;
    }
    GL_METAL_LOG("NativeGLFinish: completed");
}


/*
 *  NativeGLFlush - end current encoder, commit command buffer (don't wait)
 */
void NativeGLFlush(GLContext *ctx)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms) return;

    if (ms->renderPassActive && ms->currentEncoder) {
        [ms->currentEncoder endEncoding];
        ms->currentEncoder = nil;
    }
    if (ms->currentCommandBuffer) {
        [ms->currentCommandBuffer commit];
        ms->lastCommittedBuffer = ms->currentCommandBuffer;
        ms->currentCommandBuffer = nil;
        ms->renderPassActive = false;
    }
    GL_METAL_LOG("NativeGLFlush: committed");
}


/*
 *  GLMetalRelease - release all Metal resources for a GL context
 *
 *  LIFECYCLE: Verified cleanup of all resource types:
 *  - Pending command buffers: committed + waited before teardown
 *  - GL texture objects: CFRelease on each metal_texture (CFBridgingRetain'd)
 *  - Pipeline state cache: cleared (ARC releases id<MTLRenderPipelineState>)
 *  - Depth-stencil cache: cleared (ARC releases id<MTLDepthStencilState>)
 *  - Global sampler cache: cleared (shared across contexts, safe since GL is
 *    single-threaded and new contexts will rebuild it)
 *  - Ring buffers (3x 4MB MTLBuffer): ARC releases when ms is deleted
 *  - Uniform buffers: ARC releases when ms is deleted
 *  - Depth buffer texture: ARC releases when ms is deleted
 *  - Display lists: no Metal resources (CPU-only command recording)
 *  - Accum buffer: freed separately in gl_engine.cpp with delete context
 */
void GLMetalRelease(GLContext *ctx)
{
    if (!ctx->metal) return;

    GLMetalState *ms = (GLMetalState *)ctx->metal;

    // (1) Finish any in-flight GPU work
    if (ms->renderPassActive && ms->currentEncoder) {
        [ms->currentEncoder endEncoding];
        ms->currentEncoder = nil;
    }
    if (ms->currentCommandBuffer) {
        [ms->currentCommandBuffer commit];
        [ms->currentCommandBuffer waitUntilCompleted];
        ms->currentCommandBuffer = nil;
    }
    // Also wait on the last committed buffer to ensure no pending GPU refs
    if (ms->lastCommittedBuffer) {
        [ms->lastCommittedBuffer waitUntilCompleted];
        ms->lastCommittedBuffer = nil;
    }

    // (2) Release all GL texture objects' Metal textures (CFBridgingRetain'd)
    size_t tex_count = 0;
    for (auto &pair : ctx->texture_objects) {
        if (pair.second.metal_texture) {
            CFRelease(pair.second.metal_texture);
            pair.second.metal_texture = nullptr;
            tex_count++;
        }
    }
    ctx->texture_objects.clear();

    // (3) Clear pipeline state caches (ARC releases each id<>)
    size_t pipe_count = ms->pipelineCache.size();
    ms->pipelineCache.clear();
    size_t ds_count = ms->depthStencilCache.size();
    ms->depthStencilCache.clear();

    // (4) Clear global sampler cache (rebuilt on demand by next context)
    size_t sampler_count = gl_sampler_cache.size();
    gl_sampler_cache.clear();

    GL_METAL_LOG("GLMetalRelease: released %zu textures, %zu pipelines, %zu depth-stencil states, %zu samplers",
                 tex_count, pipe_count, ds_count, sampler_count);

    // (5) Delete the Metal state container (ARC releases all remaining id<> members:
    //     ring buffers, uniform buffers, depth buffer, layer ref, samplers, etc.)
    delete ms;
    ctx->metal = nullptr;

    GL_METAL_LOG("GLMetalRelease: all Metal resources released");
}


/*
 *  GLMetalSetLayer - set the CAMetalLayer for rendering
 */
void GLMetalSetLayer(GLContext *ctx, void *layer)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms) return;
    ms->layer = (__bridge CAMetalLayer *)layer;
    GL_METAL_LOG("GLMetalSetLayer: layer=%p", layer);
}


// ==========================================================================
//  Texture upload and sampler management
// ==========================================================================

// GL filter constants (must match gl_state.cpp definitions)
#define GL_NEAREST                        0x2600
#define GL_LINEAR_FILTER                  0x2601
#define GL_NEAREST_MIPMAP_NEAREST         0x2700
#define GL_LINEAR_MIPMAP_NEAREST          0x2701
#define GL_NEAREST_MIPMAP_LINEAR          0x2702
#define GL_LINEAR_MIPMAP_LINEAR           0x2703

// GL wrap constants
#define GL_REPEAT                         0x2901
#define GL_CLAMP                          0x2900
#define GL_CLAMP_TO_EDGE                  0x812F
#define GL_MIRRORED_REPEAT                0x8370

// GL pixel format constants
#define GL_RGBA                           0x1908
// GL_UNSIGNED_BYTE defined above with data types


/*
 *  GLMetalUploadTexture -- create/replace Metal texture from converted pixel data
 */
void GLMetalUploadTexture(GLContext *ctx, GLTextureObject *texObj, int level,
                           int width, int height, const uint8_t *data, int dataLen)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->device) return;

    id<MTLTexture> existing = texObj->metal_texture ?
        (__bridge id<MTLTexture>)(texObj->metal_texture) : nil;

    // Need new texture if: no existing, or base level dimensions changed
    bool needNew = !existing ||
                   (level == 0 && (texObj->width != width || texObj->height != height));

    // For mipmap levels > 0 on existing texture, just upload
    if (level > 0 && existing) {
        texObj->has_mipmaps = true;
    }

    if (needNew && level == 0) {
        // Release old texture
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

    // Upload pixel data to the specified mipmap level
    int mipWidth = width;
    int mipHeight = height;
    // For mip levels > 0, the width/height should already be correct from the caller

    MTLRegion region = MTLRegionMake2D(0, 0, mipWidth, mipHeight);
    [existing replaceRegion:region
                mipmapLevel:level
                  withBytes:data
                bytesPerRow:mipWidth * 4];

    GL_METAL_LOG("GLMetalUploadTexture: tex=%u level=%d %dx%d (%d bytes)",
                 texObj->name, level, mipWidth, mipHeight, dataLen);
}


/*
 *  GLMetalUploadSubTexture -- partial update of an existing Metal texture
 */
void GLMetalUploadSubTexture(GLContext *ctx, GLTextureObject *texObj, int level,
                              int xoff, int yoff, int w, int h,
                              const uint8_t *data, int bytesPerRow)
{
    if (!texObj->metal_texture) return;

    id<MTLTexture> mtlTex = (__bridge id<MTLTexture>)(texObj->metal_texture);
    MTLRegion region = MTLRegionMake2D(xoff, yoff, w, h);
    [mtlTex replaceRegion:region
              mipmapLevel:level
                withBytes:data
              bytesPerRow:bytesPerRow];

    GL_METAL_LOG("GLMetalUploadSubTexture: tex=%u level=%d region=(%d,%d,%d,%d)",
                 texObj->name, level, xoff, yoff, w, h);
}


/*
 *  GLMetalDestroyTexture -- release Metal texture resource
 */
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


/*
 *  GLMetalUpload3DTexture -- create/replace Metal 3D texture from BGRA8 data
 *
 *  Data layout: depth consecutive width×height slices in BGRA8 format.
 */
void GLMetalUpload3DTexture(GLContext *ctx, GLTextureObject *texObj, int level,
                            int width, int height, int depth,
                            const uint8_t *data, int dataLen)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->device) return;

    id<MTLTexture> existing = texObj->metal_texture ?
        (__bridge id<MTLTexture>)(texObj->metal_texture) : nil;

    bool needNew = !existing ||
                   (level == 0 && (texObj->width != width || texObj->height != height || texObj->depth != depth));

    if (needNew && level == 0) {
        if (texObj->metal_texture) {
            CFRelease(texObj->metal_texture);
            texObj->metal_texture = nullptr;
        }

        MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
        desc.textureType = MTLTextureType3D;
        desc.pixelFormat = MTLPixelFormatBGRA8Unorm;
        desc.width = width;
        desc.height = height;
        desc.depth = depth;
        desc.mipmapLevelCount = 1;
        desc.usage = MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;

        id<MTLTexture> newTex = [ms->device newTextureWithDescriptor:desc];
        if (!newTex) {
            GL_METAL_LOG("GLMetalUpload3DTexture: failed to create %dx%dx%d texture", width, height, depth);
            return;
        }

        texObj->metal_texture = (void *)CFBridgingRetain(newTex);
        texObj->width = width;
        texObj->height = height;
        texObj->depth = depth;
        existing = newTex;
    }

    if (!existing) return;

    // Upload all slices at once
    MTLRegion region = MTLRegionMake3D(0, 0, 0, width, height, depth);
    [existing replaceRegion:region
                mipmapLevel:level
                      slice:0
                  withBytes:data
                bytesPerRow:width * 4
              bytesPerImage:width * height * 4];

    GL_METAL_LOG("GLMetalUpload3DTexture: tex=%u level=%d %dx%dx%d (%d bytes)",
                 texObj->name, level, width, height, depth, dataLen);
}


/*
 *  GLMetalUploadSubTexture3D -- partial update of an existing Metal 3D texture
 */
void GLMetalUploadSubTexture3D(GLContext * /*ctx*/, GLTextureObject *texObj, int level,
                               int xoff, int yoff, int zoff,
                               int w, int h, int d,
                               const uint8_t *data, int bytesPerRow, int bytesPerImage)
{
    if (!texObj->metal_texture) return;

    id<MTLTexture> mtlTex = (__bridge id<MTLTexture>)(texObj->metal_texture);
    MTLRegion region = MTLRegionMake3D(xoff, yoff, zoff, w, h, d);
    [mtlTex replaceRegion:region
              mipmapLevel:level
                    slice:0
                withBytes:data
              bytesPerRow:bytesPerRow
            bytesPerImage:bytesPerImage];

    GL_METAL_LOG("GLMetalUploadSubTexture3D: tex=%u level=%d region=(%d,%d,%d,%d,%d,%d)",
                 texObj->name, level, xoff, yoff, zoff, w, h, d);
}


/*
 *  Sampler cache -- keyed by (minFilter, magFilter, wrapS, wrapT)
 *  (Defined near GLMetalState; see forward declaration above GLMetalRelease)
 */

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
    // Build cache key from filter and wrap parameters
    uint64_t key = (uint64_t)(texObj->min_filter & 0xFFFF)
                 | ((uint64_t)(texObj->mag_filter & 0xFFFF) << 16)
                 | ((uint64_t)(texObj->wrap_s & 0xFFFF) << 32)
                 | ((uint64_t)(texObj->wrap_t & 0xFFFF) << 48);

    auto it = gl_sampler_cache.find(key);
    if (it != gl_sampler_cache.end()) return it->second;

    // Create new sampler descriptor
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
 *  NativeGLReadPixels -- read pixels from framebuffer to PPC memory
 */
void NativeGLReadPixels(GLContext *ctx, int32_t x, int32_t y, int32_t width, int32_t height,
                         uint32_t format, uint32_t type, uint32_t mac_pixels)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->initialized || mac_pixels == 0) return;

    // Need to end current encoder to access framebuffer
    if (ms->renderPassActive && ms->currentEncoder) {
        [ms->currentEncoder endEncoding];
        ms->currentEncoder = nil;
    }

    // Get the current drawable texture
    id<MTLTexture> srcTex = nil;
    if (ms->currentDrawable) {
        srcTex = ms->currentDrawable.texture;
    }
    if (!srcTex) {
        GL_METAL_LOG("NativeGLReadPixels: no drawable texture available");
        return;
    }

    // Create staging texture (MTLStorageModeShared for CPU readback)
    MTLTextureDescriptor *stagingDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:width
                                                                                         height:height
                                                                                      mipmapped:NO];
    stagingDesc.usage = MTLTextureUsageShaderRead;
    stagingDesc.storageMode = MTLStorageModeShared;

    id<MTLTexture> staging = [ms->device newTextureWithDescriptor:stagingDesc];
    if (!staging) return;

    // Blit from drawable to staging
    id<MTLCommandBuffer> blitCmdBuf = [ms->commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [blitCmdBuf blitCommandEncoder];

    [blit copyFromTexture:srcTex
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(x, y, 0)
               sourceSize:MTLSizeMake(width, height, 1)
                toTexture:staging
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];

    [blit endEncoding];
    [blitCmdBuf commit];
    [blitCmdBuf waitUntilCompleted];

    // Read pixels from staging texture and write to PPC memory
    uint8_t *stagingBytes = (uint8_t *)malloc(width * height * 4);
    if (!stagingBytes) return;

    MTLRegion region = MTLRegionMake2D(0, 0, width, height);
    [staging getBytes:stagingBytes bytesPerRow:width * 4 fromRegion:region mipmapLevel:0];

    // Get pack alignment from context pixel store
    int packAlign = ctx->pixel_store.pack_alignment;
    if (packAlign < 1) packAlign = 4;

    // Convert from BGRA8 to requested format and write to PPC memory
    for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
            uint8_t *src = stagingBytes + (row * width + col) * 4;
            uint8_t b = src[0], g = src[1], r = src[2], a = src[3];

            if (format == GL_RGBA && type == GL_UNSIGNED_BYTE) {
                uint32_t dstAddr = mac_pixels + (row * width + col) * 4;
                WriteMacInt8(dstAddr + 0, r);
                WriteMacInt8(dstAddr + 1, g);
                WriteMacInt8(dstAddr + 2, b);
                WriteMacInt8(dstAddr + 3, a);
            } else {
                // Minimal fallback: write RGBA
                uint32_t dstAddr = mac_pixels + (row * width + col) * 4;
                WriteMacInt8(dstAddr + 0, r);
                WriteMacInt8(dstAddr + 1, g);
                WriteMacInt8(dstAddr + 2, b);
                WriteMacInt8(dstAddr + 3, a);
            }
        }
    }

    free(stagingBytes);

    // Restart render encoder if we were mid-frame
    if (ms->renderPassActive) {
        // Re-create encoder -- GLMetalBeginFrame will handle this
        // Actually we need to create a new pass that loads existing content
        if (ms->currentDrawable) {
            MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
            rpd.colorAttachments[0].texture = ms->currentDrawable.texture;
            rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
            rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
            if (ms->depthBuffer) {
                rpd.depthAttachment.texture = ms->depthBuffer;
                rpd.depthAttachment.loadAction = MTLLoadActionLoad;
                rpd.depthAttachment.storeAction = MTLStoreActionStore;
                rpd.stencilAttachment.texture = ms->depthBuffer;
                rpd.stencilAttachment.loadAction = MTLLoadActionLoad;
                rpd.stencilAttachment.storeAction = MTLStoreActionStore;
            }
            if (!ms->currentCommandBuffer) {
                ms->currentCommandBuffer = [ms->commandQueue commandBuffer];
            }
            ms->currentEncoder = [ms->currentCommandBuffer renderCommandEncoderWithDescriptor:rpd];
        }
    }

    GL_METAL_LOG("NativeGLReadPixels: read %dx%d at (%d,%d) -> mac addr 0x%08x",
                 width, height, x, y, mac_pixels);
}


// ==========================================================================
//  Accumulation buffer -- CPU-side float buffer with Metal readback/writeback
// ==========================================================================

// Accum op constants (GL spec values)
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

// Read framebuffer into a temporary float array (BGRA8 -> float RGBA)
static float *gl_accum_read_framebuffer(GLContext *ctx, int *out_w, int *out_h)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->initialized) return nullptr;

    // End current encoder to access framebuffer
    if (ms->renderPassActive && ms->currentEncoder) {
        [ms->currentEncoder endEncoding];
        ms->currentEncoder = nil;
    }

    id<MTLTexture> srcTex = nil;
    if (ms->currentDrawable) srcTex = ms->currentDrawable.texture;
    if (!srcTex) return nullptr;

    int width = (int)[srcTex width];
    int height = (int)[srcTex height];

    // Create staging texture for readback
    MTLTextureDescriptor *stagingDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:width
                                                                                         height:height
                                                                                      mipmapped:NO];
    stagingDesc.usage = MTLTextureUsageShaderRead;
    stagingDesc.storageMode = MTLStorageModeShared;
    id<MTLTexture> staging = [ms->device newTextureWithDescriptor:stagingDesc];
    if (!staging) return nullptr;

    // Blit from drawable to staging
    id<MTLCommandBuffer> blitBuf = [ms->commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [blitBuf blitCommandEncoder];
    [blit copyFromTexture:srcTex sourceSlice:0 sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(width, height, 1)
                toTexture:staging destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [blitBuf commit];
    [blitBuf waitUntilCompleted];

    // Read bytes and convert BGRA8 -> float RGBA
    uint8_t *raw = (uint8_t *)malloc(width * height * 4);
    if (!raw) return nullptr;
    MTLRegion region = MTLRegionMake2D(0, 0, width, height);
    [staging getBytes:raw bytesPerRow:width * 4 fromRegion:region mipmapLevel:0];

    float *result = (float *)malloc(width * height * 4 * sizeof(float));
    if (!result) { free(raw); return nullptr; }

    for (int i = 0; i < width * height; i++) {
        result[i * 4 + 0] = raw[i * 4 + 2] / 255.0f; // R (from BGRA offset 2)
        result[i * 4 + 1] = raw[i * 4 + 1] / 255.0f; // G
        result[i * 4 + 2] = raw[i * 4 + 0] / 255.0f; // B (from BGRA offset 0)
        result[i * 4 + 3] = raw[i * 4 + 3] / 255.0f; // A
    }
    free(raw);

    *out_w = width;
    *out_h = height;
    return result;
}

// Restart render encoder after framebuffer access (reused pattern from ReadPixels)
static void gl_accum_restart_encoder(GLContext *ctx)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->renderPassActive || !ms->currentDrawable) return;

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = ms->currentDrawable.texture;
    rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    if (ms->depthBuffer) {
        rpd.depthAttachment.texture = ms->depthBuffer;
        rpd.depthAttachment.loadAction = MTLLoadActionLoad;
        rpd.depthAttachment.storeAction = MTLStoreActionStore;
        rpd.stencilAttachment.texture = ms->depthBuffer;
        rpd.stencilAttachment.loadAction = MTLLoadActionLoad;
        rpd.stencilAttachment.storeAction = MTLStoreActionStore;
    }
    if (!ms->currentCommandBuffer) {
        ms->currentCommandBuffer = [ms->commandQueue commandBuffer];
    }
    ms->currentEncoder = [ms->currentCommandBuffer renderCommandEncoderWithDescriptor:rpd];
}

// Write accum buffer contents back to framebuffer (float RGBA -> BGRA8)
static void gl_accum_write_framebuffer(GLContext *ctx, float scale)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->initialized || !ctx->accum_allocated) return;

    // End current encoder
    if (ms->renderPassActive && ms->currentEncoder) {
        [ms->currentEncoder endEncoding];
        ms->currentEncoder = nil;
    }

    id<MTLTexture> dstTex = nil;
    if (ms->currentDrawable) dstTex = ms->currentDrawable.texture;
    if (!dstTex) return;

    int width = ctx->accum_width;
    int height = ctx->accum_height;
    int dstW = (int)[dstTex width];
    int dstH = (int)[dstTex height];
    int w = (width < dstW) ? width : dstW;
    int h = (height < dstH) ? height : dstH;

    // Convert float RGBA -> BGRA8
    uint8_t *pixels = (uint8_t *)malloc(w * h * 4);
    if (!pixels) return;

    for (int i = 0; i < w * h; i++) {
        float r = ctx->accum_buffer[i * 4 + 0] * scale;
        float g = ctx->accum_buffer[i * 4 + 1] * scale;
        float b = ctx->accum_buffer[i * 4 + 2] * scale;
        float a = ctx->accum_buffer[i * 4 + 3] * scale;
        // Clamp to [0, 1]
        r = r < 0.0f ? 0.0f : (r > 1.0f ? 1.0f : r);
        g = g < 0.0f ? 0.0f : (g > 1.0f ? 1.0f : g);
        b = b < 0.0f ? 0.0f : (b > 1.0f ? 1.0f : b);
        a = a < 0.0f ? 0.0f : (a > 1.0f ? 1.0f : a);
        pixels[i * 4 + 0] = (uint8_t)(b * 255.0f + 0.5f); // B
        pixels[i * 4 + 1] = (uint8_t)(g * 255.0f + 0.5f); // G
        pixels[i * 4 + 2] = (uint8_t)(r * 255.0f + 0.5f); // R
        pixels[i * 4 + 3] = (uint8_t)(a * 255.0f + 0.5f); // A
    }

    // Write to drawable texture via replaceRegion
    MTLRegion region = MTLRegionMake2D(0, 0, w, h);
    [dstTex replaceRegion:region mipmapLevel:0 withBytes:pixels bytesPerRow:w * 4];

    free(pixels);

    // Restart encoder
    gl_accum_restart_encoder(ctx);

    GL_METAL_LOG("Accum RETURN: scale=%.3f, %dx%d written to framebuffer", scale, w, h);
}

void NativeGLAccum(GLContext *ctx, uint32_t op, float value)
{
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->initialized) return;

    int fb_w = 0, fb_h = 0;

    switch (op) {
    case GL_ACCUM_OP: {
        // Read framebuffer, multiply by value, add to accum buffer
        float *fb = gl_accum_read_framebuffer(ctx, &fb_w, &fb_h);
        if (!fb) { gl_accum_restart_encoder(ctx); return; }
        gl_accum_ensure_allocated(ctx, fb_w, fb_h);
        if (!ctx->accum_allocated) { free(fb); gl_accum_restart_encoder(ctx); return; }
        int n = fb_w * fb_h * 4;
        for (int i = 0; i < n; i++)
            ctx->accum_buffer[i] += fb[i] * value;
        free(fb);
        gl_accum_restart_encoder(ctx);
        GL_METAL_LOG("Accum ACCUM: value=%.3f, %dx%d", value, fb_w, fb_h);
        break;
    }
    case GL_LOAD_OP: {
        // Read framebuffer, multiply by value, store into accum buffer
        float *fb = gl_accum_read_framebuffer(ctx, &fb_w, &fb_h);
        if (!fb) { gl_accum_restart_encoder(ctx); return; }
        gl_accum_ensure_allocated(ctx, fb_w, fb_h);
        if (!ctx->accum_allocated) { free(fb); gl_accum_restart_encoder(ctx); return; }
        int n = fb_w * fb_h * 4;
        for (int i = 0; i < n; i++)
            ctx->accum_buffer[i] = fb[i] * value;
        free(fb);
        gl_accum_restart_encoder(ctx);
        GL_METAL_LOG("Accum LOAD: value=%.3f, %dx%d", value, fb_w, fb_h);
        break;
    }
    case GL_MULT_OP: {
        // Multiply each accum channel by value (no readback needed)
        if (!ctx->accum_allocated) return;
        int n = ctx->accum_width * ctx->accum_height * 4;
        for (int i = 0; i < n; i++)
            ctx->accum_buffer[i] *= value;
        GL_METAL_LOG("Accum MULT: value=%.3f", value);
        break;
    }
    case GL_ADD_OP: {
        // Add value to each accum channel (no readback needed)
        if (!ctx->accum_allocated) return;
        int n = ctx->accum_width * ctx->accum_height * 4;
        for (int i = 0; i < n; i++)
            ctx->accum_buffer[i] += value;
        GL_METAL_LOG("Accum ADD: value=%.3f", value);
        break;
    }
    case GL_RETURN_OP: {
        // Multiply accum buffer by value, write to framebuffer
        gl_accum_write_framebuffer(ctx, value);
        break;
    }
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
    GL_METAL_LOG("glBegin(0x%04x)", mode);
}

void NativeGLEnd(GLContext *ctx)
{
    ctx->in_begin = false;
    GLMetalFlushImmediateMode(ctx);
    GL_METAL_LOG("glEnd: flushed %zu vertices", ctx->im_vertices.size());
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

// Pointer variants - read from Mac memory
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
}
void NativeGLColor4f(GLContext *ctx, float r, float g, float b, float a) {
    ctx->current_color[0] = r; ctx->current_color[1] = g;
    ctx->current_color[2] = b; ctx->current_color[3] = a;
}
void NativeGLColor3d(GLContext *ctx, double r, double g, double b) {
    NativeGLColor3f(ctx, (float)r, (float)g, (float)b);
}
void NativeGLColor4d(GLContext *ctx, double r, double g, double b, double a) {
    NativeGLColor4f(ctx, (float)r, (float)g, (float)b, (float)a);
}
void NativeGLColor3b(GLContext *ctx, int8_t r, int8_t g, int8_t b) {
    NativeGLColor3f(ctx, (r + 128) / 255.0f, (g + 128) / 255.0f, (b + 128) / 255.0f);
}
void NativeGLColor4b(GLContext *ctx, int8_t r, int8_t g, int8_t b, int8_t a) {
    NativeGLColor4f(ctx, (r + 128) / 255.0f, (g + 128) / 255.0f, (b + 128) / 255.0f, (a + 128) / 255.0f);
}
void NativeGLColor3ub(GLContext *ctx, uint8_t r, uint8_t g, uint8_t b) {
    NativeGLColor3f(ctx, r / 255.0f, g / 255.0f, b / 255.0f);
}
void NativeGLColor4ub(GLContext *ctx, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    NativeGLColor4f(ctx, r / 255.0f, g / 255.0f, b / 255.0f, a / 255.0f);
}
void NativeGLColor3i(GLContext *ctx, int32_t r, int32_t g, int32_t b) {
    NativeGLColor3f(ctx, (float)((double)(r - INT32_MIN) / (double)UINT32_MAX),
                         (float)((double)(g - INT32_MIN) / (double)UINT32_MAX),
                         (float)((double)(b - INT32_MIN) / (double)UINT32_MAX));
}
void NativeGLColor4i(GLContext *ctx, int32_t r, int32_t g, int32_t b, int32_t a) {
    NativeGLColor4f(ctx, (float)((double)(r - INT32_MIN) / (double)UINT32_MAX),
                         (float)((double)(g - INT32_MIN) / (double)UINT32_MAX),
                         (float)((double)(b - INT32_MIN) / (double)UINT32_MAX),
                         (float)((double)(a - INT32_MIN) / (double)UINT32_MAX));
}
void NativeGLColor3s(GLContext *ctx, int16_t r, int16_t g, int16_t b) {
    NativeGLColor3f(ctx, (r + 32768) / 65535.0f, (g + 32768) / 65535.0f, (b + 32768) / 65535.0f);
}
void NativeGLColor4s(GLContext *ctx, int16_t r, int16_t g, int16_t b, int16_t a) {
    NativeGLColor4f(ctx, (r + 32768) / 65535.0f, (g + 32768) / 65535.0f, (b + 32768) / 65535.0f, (a + 32768) / 65535.0f);
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

// Pointer variants for colors - read from Mac memory
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
    // GL spec: signed byte normals map [-128,127] to [-1.0, 1.0]
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

// Pointer variants for texcoords
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

/*
 *  ReadArrayComponent -- read one float from PPC vertex array memory
 *  Handles type conversion: GL_FLOAT, GL_DOUBLE, GL_INT, GL_SHORT,
 *  GL_UNSIGNED_BYTE, GL_UNSIGNED_SHORT, GL_UNSIGNED_INT, GL_BYTE
 */
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

/*
 *  TypeSize -- byte size of a GL data type
 */
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

/*
 *  EffectiveStride -- compute actual byte stride (0 means tightly packed)
 */
static inline int EffectiveStride(const GLVertexArrayPointer &arr) {
    if (arr.stride > 0) return arr.stride;
    return arr.size * TypeSize(arr.type);
}

/*
 *  FetchArrayVertex -- read one vertex from enabled client arrays at index i
 */
static void FetchArrayVertex(GLContext *ctx, int32_t i, GLVertex &v) {
    // Position from vertex array
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

    // Color from color array or current color
    if (ctx->color_array.enabled && ctx->color_array.pointer) {
        int es = EffectiveStride(ctx->color_array);
        uint32_t base = ctx->color_array.pointer + i * es;
        int sz = ctx->color_array.size;
        uint32_t ct = ctx->color_array.type;
        if (ct == GL_UNSIGNED_BYTE) {
            // Special: normalize to 0..1 range
            v.color[0] = (sz >= 1) ? ReadMacInt8(base) / 255.0f : 0.0f;
            v.color[1] = (sz >= 2) ? ReadMacInt8(base + 1) / 255.0f : 0.0f;
            v.color[2] = (sz >= 3) ? ReadMacInt8(base + 2) / 255.0f : 0.0f;
            v.color[3] = (sz >= 4) ? ReadMacInt8(base + 3) / 255.0f : 1.0f;
        } else {
            v.color[0] = (sz >= 1) ? ReadArrayComponent(base + 0 * TypeSize(ct), ct) : 0.0f;
            v.color[1] = (sz >= 2) ? ReadArrayComponent(base + 1 * TypeSize(ct), ct) : 0.0f;
            v.color[2] = (sz >= 3) ? ReadArrayComponent(base + 2 * TypeSize(ct), ct) : 0.0f;
            v.color[3] = (sz >= 4) ? ReadArrayComponent(base + 3 * TypeSize(ct), ct) : 1.0f;
        }
    } else {
        memcpy(v.color, ctx->current_color, sizeof(float) * 4);
    }

    // Normal from normal array or current normal
    if (ctx->normal_array.enabled && ctx->normal_array.pointer) {
        int es = EffectiveStride(ctx->normal_array);
        uint32_t base = ctx->normal_array.pointer + i * es;
        for (int c = 0; c < 3; c++)
            v.normal[c] = ReadArrayComponent(base + c * TypeSize(ctx->normal_array.type), ctx->normal_array.type);
    } else {
        memcpy(v.normal, ctx->current_normal, sizeof(float) * 3);
    }

    // Texcoord from texcoord array or current texcoord (unit 0)
    if (ctx->texcoord_array[0].enabled && ctx->texcoord_array[0].pointer) {
        int es = EffectiveStride(ctx->texcoord_array[0]);
        uint32_t base = ctx->texcoord_array[0].pointer + i * es;
        int sz = ctx->texcoord_array[0].size;
        uint32_t ct = ctx->texcoord_array[0].type;
        v.texcoord[0][0] = (sz >= 1) ? ReadArrayComponent(base + 0 * TypeSize(ct), ct) : 0.0f;
        v.texcoord[0][1] = (sz >= 2) ? ReadArrayComponent(base + 1 * TypeSize(ct), ct) : 0.0f;
        v.texcoord[0][2] = (sz >= 3) ? ReadArrayComponent(base + 2 * TypeSize(ct), ct) : 0.0f;
        v.texcoord[0][3] = (sz >= 4) ? ReadArrayComponent(base + 3 * TypeSize(ct), ct) : 1.0f;
    } else {
        memcpy(v.texcoord[0], ctx->current_texcoord[0], sizeof(float) * 4);
    }

    // Zero remaining texcoord units
    for (int u = 1; u < 4; u++)
        memcpy(v.texcoord[u], ctx->current_texcoord[u], sizeof(float) * 4);

    memcpy(v.secondary_color, ctx->current_secondary_color, sizeof(float) * 3);
    v.fog_coord = ctx->current_fog_coord;
}


/*
 *  GLMetalDrawVertexArray -- shared draw path for vertex arrays
 *
 *  Builds im_vertices from array data, then flushes through the same
 *  Metal draw path used by immediate mode (GLMetalFlushImmediateMode).
 */
static void GLMetalDrawVertexArray(GLContext *ctx, uint32_t mode, const int32_t *indices, int32_t count)
{
    if (count <= 0) return;

    // Early out if Metal rendering is not possible (no layer -> no output)
    GLMetalState *ms = (GLMetalState *)ctx->metal;
    if (!ms || !ms->initialized || !ms->layer) return;

    ctx->in_begin = true;
    ctx->im_mode = mode;
    ctx->im_vertices.clear();
    ctx->im_vertices.reserve(count);

    for (int32_t j = 0; j < count; j++) {
        GLVertex v;
        FetchArrayVertex(ctx, indices[j], v);
        ctx->im_vertices.push_back(v);
    }

    ctx->in_begin = false;
    GLMetalFlushImmediateMode(ctx);
}


/*
 *  NativeGLDrawArrays -- draw count vertices starting from first
 */
void NativeGLDrawArrays(GLContext *ctx, uint32_t mode, int32_t first, int32_t count)
{
    GL_METAL_LOG("glDrawArrays(0x%04x, %d, %d)", mode, first, count);
    if (count <= 0) return;

    // Build sequential index array
    std::vector<int32_t> indices(count);
    for (int32_t i = 0; i < count; i++) indices[i] = first + i;

    GLMetalDrawVertexArray(ctx, mode, indices.data(), count);
}


/*
 *  NativeGLDrawElements -- draw indexed geometry from vertex arrays
 */
void NativeGLDrawElements(GLContext *ctx, uint32_t mode, int32_t count, uint32_t type, uint32_t indices_ptr)
{
    GL_METAL_LOG("glDrawElements(0x%04x, %d, 0x%04x, 0x%08x)", mode, count, type, indices_ptr);
    if (count <= 0) return;

    // Read index array from PPC memory
    std::vector<int32_t> indices(count);
    for (int32_t i = 0; i < count; i++) {
        switch (type) {
        case GL_UNSIGNED_INT:
            indices[i] = (int32_t)ReadMacInt32(indices_ptr + i * 4);
            break;
        case GL_UNSIGNED_SHORT:
            indices[i] = (int32_t)ReadMacInt16(indices_ptr + i * 2);
            break;
        case GL_UNSIGNED_BYTE:
            indices[i] = (int32_t)ReadMacInt8(indices_ptr + i);
            break;
        default:
            indices[i] = i;
            break;
        }
    }

    GLMetalDrawVertexArray(ctx, mode, indices.data(), count);
}


/*
 *  NativeGLDrawRangeElements -- same as DrawElements with range hint (ignored)
 */
void NativeGLDrawRangeElements(GLContext *ctx, uint32_t mode, uint32_t start, uint32_t end,
                                int32_t count, uint32_t type, uint32_t indices_ptr)
{
    (void)start; (void)end;
    NativeGLDrawElements(ctx, mode, count, type, indices_ptr);
}


/*
 *  NativeGLArrayElement -- fetch one vertex from arrays (used inside glBegin/glEnd)
 */
void NativeGLArrayElement(GLContext *ctx, int32_t i)
{
    GLVertex v;
    FetchArrayVertex(ctx, i, v);
    ctx->im_vertices.push_back(v);
}


/*
 *  NativeGLInterleavedArrays -- set up multiple array pointers from interleaved format
 */
void NativeGLInterleavedArrays(GLContext *ctx, uint32_t format, int32_t stride, uint32_t pointer)
{
    GL_METAL_LOG("glInterleavedArrays(0x%04x, %d, 0x%08x)", format, stride, pointer);

    // Disable all client arrays first
    ctx->color_array.enabled = false;
    ctx->normal_array.enabled = false;
    ctx->texcoord_array[ctx->client_active_texture].enabled = false;
    ctx->edge_flag_array.enabled = false;
    ctx->index_array.enabled = false;

    // Set up based on format enum
    int offset = 0;
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
