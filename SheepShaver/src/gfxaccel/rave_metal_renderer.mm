/*
 *  rave_metal_renderer.mm - Metal rendering infrastructure for RAVE
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Implements:
 *    - Offscreen texture rendering through compositor overlay API
 *    - Per-context Metal resource initialization (device, queue, pipelines, depth states)
 *    - RenderStart/End/Abort/Flush/Sync methods
 *    - Uber-shader pipeline pre-building with function constants
 */

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <unordered_map>
#include <vector>

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "rave_engine.h"
#include "rave_metal_renderer.h"
#include "metal_device_shared.h"
#include "metal_compositor.h"

// Forward declare Mac_sysalloc (from macos_util.h) to avoid UIKit header conflicts
extern uint32 Mac_sysalloc(uint32 size);

// RAVE error codes
#define kQANoErr           0
#define kQAError          -2

// Viewport uniform (matches Viewport struct in rave_shaders.metal)
struct RaveViewport {
    float width;
    float height;
    float znear;
    float zfar;
};

// Vertex uniforms (matches VertexUniforms struct in rave_shaders.metal)
struct VertexUniforms {
	float point_width;
};

// Fragment uniforms (must match FragmentUniforms in rave_shaders.metal exactly)
struct FragmentUniforms {
    int32_t  texture_op;
    int32_t  fog_mode;
    float    fog_color_a;
    float    fog_color_r;
    float    fog_color_g;
    float    fog_color_b;
    float    fog_start;
    float    fog_end;
    float    fog_density;
    float    fog_max_depth;
    int32_t  alpha_test_func;
    float    alpha_test_ref;
    uint32_t multi_texture_op;      // 0=Add, 1=Modulate, 2=BlendAlpha, 3=Fixed
    float    multi_texture_factor;  // blend factor for Fixed mode
    float    mipmap_bias;           // LOD bias for texture sampling (BIA-01)
    float    multi_texture_mipmap_bias;  // LOD bias for second texture (tag 42)
    float    env_color_r;           // kQATextureOp_Blend env color (tags 150-153)
    float    env_color_g;
    float    env_color_b;
    float    env_color_a;
};

// kQAContext flag bits
#define kQAContext_NoZBuffer  (1 << 0)

/*
 *  RaveMetalState - Opaque Metal resource container
 *
 *  Holds all ObjC Metal objects. Allocated by RaveInitMetalResources,
 *  freed by RaveReleaseMetalResources. Referenced from RaveDrawPrivate
 *  via an opaque pointer (RaveDrawPrivate.metal).
 */
struct RaveMetalState {
	id<MTLDevice>               device;
	id<MTLCommandQueue>         commandQueue;
	id<MTLRenderPipelineState>  pipelines[48];     // 16 function constant combos x 3 blend modes
	id<MTLDepthStencilState>    depthStates[9];     // 9 ZFunction values (depth write enabled)
	id<MTLDepthStencilState>    depthStatesNoWrite[9]; // 9 ZFunction values (depth write disabled)
	int                         currentPipelineIdx; // currently bound pipeline (-1 = none)
	id<MTLTexture>              depthBuffer;

	id<MTLCommandBuffer>        currentCommandBuffer;
	id<MTLRenderCommandEncoder> currentEncoder;
	id<MTLTexture>              overlayTexture;        // offscreen render target from compositor
	id<MTLCommandBuffer>        lastCommittedBuffer;
	bool                        renderPassActive;

	// Saved for lazy MSAA pipeline creation
	id<MTLLibrary>              shaderLibrary;
	MTLVertexDescriptor        *vertexDescriptor;

	// MSAA 4x resources (allocated lazily on demand)
	id<MTLTexture>              msaaColorTexture;   // 4x MSAA render target (nil until needed)
	id<MTLTexture>              msaaDepthTexture;   // 4x MSAA depth (nil until needed)
	id<MTLRenderPipelineState>  msaaPipelines[48];  // MSAA variants of all 48 pipelines
	bool                        msaaActive;         // currently rendering in MSAA mode
	bool                        msaaResourcesReady; // MSAA textures allocated

	// Pre-built sampler states (Phase 4)
	id<MTLSamplerState>         samplers[3];        // [0]=nearest, [1]=bilinear, [2]=trilinear

	// Diagnostic counters (per-frame, reset at RenderStart)
	uint32_t                    drawCallCount;      // total draw method invocations this frame
	uint32_t                    triangleCount;      // triangles submitted this frame
	// Per-method counters for debugging which draw paths are active
	uint32_t                    triGouraudCount;    // DrawTriGouraud calls
	uint32_t                    triTextureCount;    // DrawTriTexture calls
	uint32_t                    vGouraudCount;      // DrawVGouraud calls
	uint32_t                    vTextureCount;      // DrawVTexture calls
	uint32_t                    meshGouraudCount;   // DrawTriMeshGouraud calls
	uint32_t                    meshTextureCount;   // DrawTriMeshTexture calls
	uint32_t                    bitmapCount;        // DrawBitmap calls
	uint32_t                    pointCount;         // DrawPoint calls
	uint32_t                    lineCount;          // DrawLine calls

	// Buffer access staging (AccessDrawBuffer/AccessZBuffer)
	id<MTLTexture>              stagingDrawBuffer;    // CPU-readable color staging (MTLStorageModeShared)
	id<MTLTexture>              stagingZBuffer;       // CPU-readable depth staging (MTLStorageModeShared, Float32)
	uint8_t                    *drawBufferCPU;        // Mac-addressable color buffer (Mac_sysalloc)
	uint32_t                    drawBufferCPUMac;     // Mac address of drawBufferCPU
	uint32_t                    drawBufferCPUSize;    // byte size of draw buffer CPU allocation
	uint8_t                    *zBufferCPU;           // Mac-addressable depth buffer (Mac_sysalloc)
	uint32_t                    zBufferCPUMac;        // Mac address of zBufferCPU
	uint32_t                    zBufferCPUSize;       // byte size of Z buffer CPU allocation
	bool                        drawBufferAccessed;   // currently in AccessDrawBuffer state
	bool                        zBufferAccessed;      // currently in AccessZBuffer state

	// Depth-only clear pipeline (ClearZBuffer)
	id<MTLDepthStencilState>    depthAlwaysWriteState; // depth=always, write=yes

	// Channel mask pipeline cache (MSK-01): lazy pipeline variants with colorWriteMask
	// Key: (pipelineIndex << 4) | (channelMask & 0xF), bit 32 set for MSAA
	std::unordered_map<uint64_t, id<MTLRenderPipelineState>> maskedPipelines;

	// GL blend pipeline cache (kQABlend_OpenGL = 2)
	// Key: (funcConstBits << 48) | (msaa << 32) | (glBlendSrc << 16) | glBlendDst
	std::unordered_map<uint64_t, id<MTLRenderPipelineState>> glBlendPipelines;

	// RTT texture handles (TextureNewFromDrawContext / BitmapNewFromDrawContext)
	std::vector<uint32_t>       rttTextureHandles;
};


/*
 *  Overlay reference counting (shared across RAVE and GL engines).
 *  The overlay is now a compositor-owned offscreen texture.
 */
static int accel_overlay_refcount = 0;

void RaveCreateMetalOverlay(int32_t left, int32_t top, int32_t width, int32_t height)
{
	// Check if compositor already has an overlay texture of the right size
	if (MetalCompositorGetOverlayTexture() != nullptr) {
		RAVE_LOG("RaveCreateMetalOverlay: reusing existing compositor overlay texture");
		MetalCompositorSetOverlayRect(left, top, width, height);
		MetalCompositorSetOverlayActive(1);
		return;
	}

	// Request offscreen texture from compositor
	int result = MetalCompositorCreateOverlayTexture(width, height);
	if (result != 0) {
		RAVE_LOG("RaveCreateMetalOverlay: MetalCompositorCreateOverlayTexture(%d,%d) FAILED", width, height);
		return;
	}

	MetalCompositorSetOverlayRect(left, top, width, height);
	MetalCompositorSetOverlayActive(1);
	RAVE_LOG("RaveCreateMetalOverlay: using compositor offscreen texture %dx%d at (%d,%d)", width, height, left, top);
}


void RaveDestroyMetalOverlay(void)
{
	RAVE_LOG("RaveDestroyMetalOverlay: deactivating compositor overlay");
	MetalCompositorSetOverlayActive(0);
}



/*
 *  Deferred overlay destruction
 *
 *  Prevents flicker during rapid context create/destroy cycles (e.g., RAVE Bench
 *  windowed mode). Instead of immediately destroying the overlay when the last
 *  context is deleted, we schedule destruction after ~100ms. If a new context
 *  is created within that window, the destroy is cancelled and the overlay reused.
 */

static bool pending_overlay_destroy_scheduled = false;
static bool pending_overlay_destroy_cancelled = false;

void RaveScheduleDeferredOverlayDestroy(void)
{
	if (pending_overlay_destroy_scheduled) {
		RAVE_LOG("DeferredOverlayDestroy: already scheduled, skipping");
		return;
	}
	pending_overlay_destroy_scheduled = true;
	pending_overlay_destroy_cancelled = false;

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
	               dispatch_get_main_queue(), ^{
		if (pending_overlay_destroy_cancelled) {
			RAVE_LOG("DeferredOverlayDestroy: was cancelled, skipping");
		} else if (accel_overlay_refcount > 0) {
			RAVE_LOG("DeferredOverlayDestroy: refcount is %d, skipping (defense-in-depth)", accel_overlay_refcount);
		} else {
			RAVE_LOG("DeferredOverlayDestroy: firing -- destroying overlay");
			RaveClearOverlayToTransparent();
			RaveDestroyMetalOverlay();
		}
		pending_overlay_destroy_scheduled = false;
		pending_overlay_destroy_cancelled = false;
	});
	RAVE_LOG("DeferredOverlayDestroy: scheduled (100ms)");
}

void RaveCancelDeferredOverlayDestroy(void)
{
	if (pending_overlay_destroy_scheduled) {
		pending_overlay_destroy_cancelled = true;
		RAVE_LOG("DeferredOverlayDestroy: cancelled -- reusing overlay");
	}
}


/*
 *  Overlay reference counting
 *
 *  The overlay texture is shared between RAVE and GL engines.
 *  Each engine retains the overlay when it creates a context and releases
 *  when the context is destroyed. Deferred destroy only fires at refcount 0.
 */

void RaveOverlayRetain(void)
{
	accel_overlay_refcount++;
	pending_overlay_destroy_cancelled = true;  // cancel any pending deferred destroy
	RAVE_LOG("RaveOverlayRetain: refcount now %d", accel_overlay_refcount);
}

void RaveOverlayRelease(void)
{
	accel_overlay_refcount--;
	if (accel_overlay_refcount <= 0) {
		accel_overlay_refcount = 0;
		RAVE_LOG("RaveOverlayRelease: refcount reached 0, scheduling deferred destroy");
		RaveScheduleDeferredOverlayDestroy();
	} else {
		RAVE_LOG("RaveOverlayRelease: refcount now %d", accel_overlay_refcount);
	}
}


/*
 *  RaveClearOverlayToTransparent - deactivate the compositor overlay
 *
 *  Called when the last RAVE context is deleted. With the offscreen texture
 *  architecture, we simply deactivate the overlay so the compositor skips the
 *  3D compositing pass. The texture content becomes stale but invisible.
 */
void RaveClearOverlayToTransparent(void)
{
	MetalCompositorSetOverlayActive(0);
	RAVE_LOG("Overlay deactivated (clear to transparent)");
}


/*
 *  Metal resource initialization
 */

// ZFunction compare function mapping (RAVE -> Metal)
// kQAZFunction_None(0), LT(1), EQ(2), LE(3), GT(4), NE(5), GE(6), Always(7), Never(8)
static MTLCompareFunction ZFunctionToMTL(int zfunc)
{
	switch (zfunc) {
		case 0:  return MTLCompareFunctionAlways;   // None: always pass, no write
		case 1:  return MTLCompareFunctionLess;
		case 2:  return MTLCompareFunctionEqual;
		case 3:  return MTLCompareFunctionLessEqual;
		case 4:  return MTLCompareFunctionGreater;
		case 5:  return MTLCompareFunctionNotEqual;
		case 6:  return MTLCompareFunctionGreaterEqual;
		case 7:  return MTLCompareFunctionAlways;
		case 8:  return MTLCompareFunctionNever;
		default: return MTLCompareFunctionAlways;
	}
}


/*
 *  RaveChannelMaskToMTL - convert RAVE channel mask bits to Metal colorWriteMask
 *
 *  RAVE: bit0=R, bit1=G, bit2=B, bit3=A
 */
static MTLColorWriteMask RaveChannelMaskToMTL(uint32_t raveMask) {
	MTLColorWriteMask m = MTLColorWriteMaskNone;
	if (raveMask & 1) m |= MTLColorWriteMaskRed;
	if (raveMask & 2) m |= MTLColorWriteMaskGreen;
	if (raveMask & 4) m |= MTLColorWriteMaskBlue;
	if (raveMask & 8) m |= MTLColorWriteMaskAlpha;
	return m;
}


/*
 *  GetMaskedPipeline - get or lazily create a pipeline with channel mask applied
 *
 *  Clones the base pipeline configuration but overrides colorAttachments[0].writeMask.
 *  Results are cached in ms->maskedPipelines keyed by (pipeIdx << 4) | mask | (msaa << 32).
 */
static id<MTLRenderPipelineState> GetMaskedPipeline(RaveMetalState *ms, int pipeIdx, uint32_t channelMask, bool msaa) {
	uint64_t key = ((uint64_t)pipeIdx << 4) | (channelMask & 0xF);
	if (msaa) key |= (1ULL << 32);

	auto it = ms->maskedPipelines.find(key);
	if (it != ms->maskedPipelines.end()) return it->second;

	// Derive function constants from pipeline index
	int blend = pipeIdx / 16;
	int bits = pipeIdx % 16;
	bool tex      = (bits & 1) != 0;
	bool fog      = (bits & 2) != 0;
	bool alpha    = (bits & 4) != 0;
	bool multiTex = (bits & 8) != 0;

	MTLFunctionConstantValues *constants = [[MTLFunctionConstantValues alloc] init];
	[constants setConstantValue:&tex      type:MTLDataTypeBool atIndex:0];
	[constants setConstantValue:&fog      type:MTLDataTypeBool atIndex:1];
	[constants setConstantValue:&alpha    type:MTLDataTypeBool atIndex:2];
	[constants setConstantValue:&multiTex type:MTLDataTypeBool atIndex:3];

	NSError *err = nil;
	id<MTLFunction> vertexFunc = [ms->shaderLibrary newFunctionWithName:@"rave_vertex"
	                                                     constantValues:constants error:&err];
	id<MTLFunction> fragmentFunc = [ms->shaderLibrary newFunctionWithName:@"rave_fragment"
	                                                       constantValues:constants error:&err];
	if (!vertexFunc || !fragmentFunc) {
		RAVE_LOG("GetMaskedPipeline: function creation failed for pipe %d mask 0x%x", pipeIdx, channelMask);
		return nil;
	}

	MTLRenderPipelineDescriptor *pipeDesc = [[MTLRenderPipelineDescriptor alloc] init];
	pipeDesc.vertexFunction = vertexFunc;
	pipeDesc.fragmentFunction = fragmentFunc;
	pipeDesc.vertexDescriptor = ms->vertexDescriptor;
	pipeDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	pipeDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	pipeDesc.sampleCount = msaa ? 4 : 1;

	// Blend factors (same logic as BuildPipelines)
	pipeDesc.colorAttachments[0].blendingEnabled = YES;
	pipeDesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
	pipeDesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
	if (blend == 0) {
		pipeDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
		pipeDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	} else {
		pipeDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
		pipeDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	}
	pipeDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
	pipeDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

	// Apply channel mask (the whole reason for this pipeline variant)
	pipeDesc.colorAttachments[0].writeMask = RaveChannelMaskToMTL(channelMask);

	id<MTLRenderPipelineState> pipeline = [ms->device newRenderPipelineStateWithDescriptor:pipeDesc error:&err];
	if (!pipeline) {
		RAVE_LOG("GetMaskedPipeline: creation failed for pipe %d mask 0x%x: %s",
		         pipeIdx, channelMask, [[err localizedDescription] UTF8String]);
		return nil;
	}

	ms->maskedPipelines[key] = pipeline;
	RAVE_LOG("GetMaskedPipeline: created pipe %d mask 0x%x msaa=%d (cache size=%zu)",
	         pipeIdx, channelMask, msaa, ms->maskedPipelines.size());
	return pipeline;
}


/*
 *  BuildPipelines - create 48 pipeline states for given sample count
 *
 *  Shared between initial resource creation (sampleCount=1) and
 *  lazy MSAA resource creation (sampleCount=4).
 *  16 function constant combos (bits 0-3) x 3 blend modes = 48 pipelines.
 */
static void BuildPipelines(id<MTLDevice> device, id<MTLLibrary> lib,
                           MTLVertexDescriptor *vertDesc,
                           id<MTLRenderPipelineState> __strong *outPipelines,
                           int sampleCount)
{
	for (int blend = 0; blend < 3; blend++) {
		for (int i = 0; i < 16; i++) {
			int pipeIdx = i + blend * 16;
			bool tex      = (i & 1) != 0;
			bool fog      = (i & 2) != 0;
			bool alpha    = (i & 4) != 0;
			bool multiTex = (i & 8) != 0;

			MTLFunctionConstantValues *constants = [[MTLFunctionConstantValues alloc] init];
			[constants setConstantValue:&tex      type:MTLDataTypeBool atIndex:0];
			[constants setConstantValue:&fog      type:MTLDataTypeBool atIndex:1];
			[constants setConstantValue:&alpha    type:MTLDataTypeBool atIndex:2];
			[constants setConstantValue:&multiTex type:MTLDataTypeBool atIndex:3];

			NSError *err = nil;
			id<MTLFunction> vertexFunc = [lib newFunctionWithName:@"rave_vertex"
			                                       constantValues:constants error:&err];
			if (!vertexFunc) {
				RAVE_LOG("Pipeline %d (samples=%d): vertex function error: %s",
				         pipeIdx, sampleCount, [[err localizedDescription] UTF8String]);
				continue;
			}

			id<MTLFunction> fragmentFunc = [lib newFunctionWithName:@"rave_fragment"
			                                         constantValues:constants error:&err];
			if (!fragmentFunc) {
				RAVE_LOG("Pipeline %d (samples=%d): fragment function error: %s",
				         pipeIdx, sampleCount, [[err localizedDescription] UTF8String]);
				continue;
			}

			MTLRenderPipelineDescriptor *pipeDesc = [[MTLRenderPipelineDescriptor alloc] init];
			pipeDesc.vertexFunction = vertexFunc;
			pipeDesc.fragmentFunction = fragmentFunc;
			pipeDesc.vertexDescriptor = vertDesc;
			pipeDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
			pipeDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
			pipeDesc.sampleCount = sampleCount;

			// Blend factors per mode
			pipeDesc.colorAttachments[0].blendingEnabled = YES;
			pipeDesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
			pipeDesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

			if (blend == 0) {
				pipeDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
				pipeDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
			} else {
				pipeDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
				pipeDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
			}
			pipeDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
			pipeDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

			outPipelines[pipeIdx] = [device newRenderPipelineStateWithDescriptor:pipeDesc error:&err];
			if (!outPipelines[pipeIdx]) {
				RAVE_LOG("Pipeline %d (samples=%d): creation error: %s",
				         pipeIdx, sampleCount, [[err localizedDescription] UTF8String]);
			}
		}
	}
}


/*
 *  EnsureMSAAResources - lazy allocation of 4x MSAA textures and pipelines
 *
 *  Called on first frame that requests MSAA. Creates multisample color and
 *  depth textures plus 24 MSAA pipeline variants.
 */
static void EnsureMSAAResources(RaveDrawPrivate *priv)
{
	RaveMetalState *ms = priv->metal;
	if (ms->msaaResourcesReady) return;

	// Create 4x MSAA color texture
	MTLTextureDescriptor *colorDesc = [MTLTextureDescriptor
	    texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
	                                width:(NSUInteger)priv->width
	                               height:(NSUInteger)priv->height
	                            mipmapped:NO];
	colorDesc.textureType = MTLTextureType2DMultisample;
	colorDesc.sampleCount = 4;
	colorDesc.storageMode = MTLStorageModePrivate;
	colorDesc.usage = MTLTextureUsageRenderTarget;
	ms->msaaColorTexture = [ms->device newTextureWithDescriptor:colorDesc];

	// Create 4x MSAA depth texture
	MTLTextureDescriptor *depthDesc = [MTLTextureDescriptor
	    texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
	                                width:(NSUInteger)priv->width
	                               height:(NSUInteger)priv->height
	                            mipmapped:NO];
	depthDesc.textureType = MTLTextureType2DMultisample;
	depthDesc.sampleCount = 4;
	depthDesc.storageMode = MTLStorageModePrivate;
	depthDesc.usage = MTLTextureUsageRenderTarget;
	ms->msaaDepthTexture = [ms->device newTextureWithDescriptor:depthDesc];

	// Build 48 MSAA pipeline variants
	BuildPipelines(ms->device, ms->shaderLibrary, ms->vertexDescriptor,
	               ms->msaaPipelines, 4);

	ms->msaaResourcesReady = true;
	RAVE_LOG("MSAA 4x resources allocated: %dx%d (~%.1f MB)",
	         priv->width, priv->height,
	         (priv->width * priv->height * 4 * 4 * 2) / (1024.0 * 1024.0));
}


void RaveInitMetalResources(RaveDrawPrivate *priv)
{
	RaveMetalState *ms = new RaveMetalState();
	priv->metal = ms;

	// Get device from shared Metal device (compositor owns the device lifecycle).
	ms->device = (__bridge id<MTLDevice>)SharedMetalDevice();
	if (!ms->device) {
		RAVE_LOG("RaveInitMetalResources: SharedMetalDevice failed");
		return;
	}

	// Cache the compositor's offscreen overlay texture
	ms->overlayTexture = (__bridge id<MTLTexture>)MetalCompositorGetOverlayTexture();

	ms->commandQueue = [ms->device newCommandQueue];

	// Load pre-compiled shader library (.metallib)
	id<MTLLibrary> lib = [ms->device newDefaultLibrary];
	if (!lib) {
		RAVE_LOG("RaveInitMetalResources: newDefaultLibrary failed (no .metallib?)");
		return;
	}
	ms->shaderLibrary = lib;

	// Create vertex descriptor: position(float4), color(float4), texcoord(float2)
	MTLVertexDescriptor *vertDesc = [[MTLVertexDescriptor alloc] init];
	vertDesc.attributes[0].format = MTLVertexFormatFloat4;
	vertDesc.attributes[0].offset = 0;
	vertDesc.attributes[0].bufferIndex = 0;
	vertDesc.attributes[1].format = MTLVertexFormatFloat4;
	vertDesc.attributes[1].offset = 16;
	vertDesc.attributes[1].bufferIndex = 0;
	vertDesc.attributes[2].format = MTLVertexFormatFloat4;
	vertDesc.attributes[2].offset = 32;
	vertDesc.attributes[2].bufferIndex = 0;
	vertDesc.layouts[0].stride = 48;
	vertDesc.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
	ms->vertexDescriptor = vertDesc;

	// AUDIT: M003/S04/T01 — RAVE blend state verified correct.
	// 48 pipelines = 3 blend modes x 16 function constant combos.
	// Blend mode 0: premultiplied alpha (src=One, dst=OneMinusSrcAlpha)
	// Blend mode 1: standard alpha (src=SrcAlpha, dst=OneMinusSrcAlpha)
	// Blend mode 2 (kQABlend_OpenGL): handled separately via GetGLBlendPipeline
	// All pipelines have blendingEnabled=YES, which is correct for RAVE
	// (RAVE always blends; it's a compositing rasterizer, not an opaque renderer).
	// Pre-build 48 pipeline states (sampleCount=1)
	BuildPipelines(ms->device, lib, vertDesc, ms->pipelines, 1);
	RAVE_LOG("48 pipeline states created");

	// AUDIT: M003/S04/T01 — RAVE depth state configuration verified correct.
	// 9 ZFunction values mapped to Metal compare functions (ZFunctionToMTL).
	// kQAZFunction_None(0) maps to MTLCompareFunctionAlways with depth write disabled,
	// which is correct (no depth buffer = always pass, never write).
	// All other functions (1-8) have depth write enabled by default; a separate
	// depthStatesNoWrite[9] array handles ZBufferMask=0 (depth write disabled).
	// Create 9 depth stencil states (one per ZFunction)
	for (int i = 0; i < 9; i++) {
		MTLDepthStencilDescriptor *dsDesc = [[MTLDepthStencilDescriptor alloc] init];
		dsDesc.depthCompareFunction = ZFunctionToMTL(i);
		dsDesc.depthWriteEnabled = (i != 0);
		ms->depthStates[i] = [ms->device newDepthStencilStateWithDescriptor:dsDesc];
	}
	// Create 9 depth stencil states with depth writes disabled (for ZBufferMask=0)
	for (int i = 0; i < 9; i++) {
		MTLDepthStencilDescriptor *dsDesc = [[MTLDepthStencilDescriptor alloc] init];
		dsDesc.depthCompareFunction = ZFunctionToMTL(i);
		dsDesc.depthWriteEnabled = NO;
		ms->depthStatesNoWrite[i] = [ms->device newDepthStencilStateWithDescriptor:dsDesc];
	}
	RAVE_LOG("9+9 depth stencil states created (write enabled + disabled)");

	// [AUDIT-T02] Verified: 3 sampler states with MTLSamplerAddressModeRepeat (correct for
	// UV-wrapped 3D geometry). nearest/bilinear/trilinear filter progression matches RAVE
	// kQATextureFilter_Fast(0)/Mid(1)/Best(2). GL tags override sampler in ApplyDirtyState.
	// Create 3 sampler states (nearest, bilinear, trilinear)
	{
		MTLSamplerDescriptor *sampDesc = [[MTLSamplerDescriptor alloc] init];
		sampDesc.sAddressMode = MTLSamplerAddressModeRepeat;
		sampDesc.tAddressMode = MTLSamplerAddressModeRepeat;

		// [0] nearest (kQATextureFilter_Fast = 0)
		sampDesc.minFilter = MTLSamplerMinMagFilterNearest;
		sampDesc.magFilter = MTLSamplerMinMagFilterNearest;
		sampDesc.mipFilter = MTLSamplerMipFilterNotMipmapped;
		ms->samplers[0] = [ms->device newSamplerStateWithDescriptor:sampDesc];

		// [1] bilinear (kQATextureFilter_Mid = 1)
		sampDesc.minFilter = MTLSamplerMinMagFilterLinear;
		sampDesc.magFilter = MTLSamplerMinMagFilterLinear;
		sampDesc.mipFilter = MTLSamplerMipFilterNearest;
		ms->samplers[1] = [ms->device newSamplerStateWithDescriptor:sampDesc];

		// [2] trilinear (kQATextureFilter_Best = 2)
		sampDesc.mipFilter = MTLSamplerMipFilterLinear;
		ms->samplers[2] = [ms->device newSamplerStateWithDescriptor:sampDesc];
	}
	RAVE_LOG("3 sampler states created");

	// Create depth buffer texture
	if (priv->width > 0 && priv->height > 0) {
		MTLTextureDescriptor *depthDesc = [MTLTextureDescriptor
		    texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
		                                width:(NSUInteger)priv->width
		                               height:(NSUInteger)priv->height
		                            mipmapped:NO];
		depthDesc.textureType = MTLTextureType2D;
		depthDesc.storageMode = MTLStorageModePrivate;
		depthDesc.usage = MTLTextureUsageRenderTarget;
		ms->depthBuffer = [ms->device newTextureWithDescriptor:depthDesc];
		RAVE_LOG("Depth buffer created: %dx%d", priv->width, priv->height);
	}

	ms->renderPassActive = false;
	ms->currentPipelineIdx = -1;
	ms->msaaActive = false;
	ms->msaaResourcesReady = false;

	// Buffer access staging (lazy allocation)
	ms->stagingDrawBuffer = nil;
	ms->stagingZBuffer = nil;
	ms->drawBufferCPU = nullptr;
	ms->drawBufferCPUMac = 0;
	ms->drawBufferCPUSize = 0;
	ms->zBufferCPU = nullptr;
	ms->zBufferCPUMac = 0;
	ms->zBufferCPUSize = 0;
	ms->drawBufferAccessed = false;
	ms->zBufferAccessed = false;

	// Depth-always-write state for ClearZBuffer
	{
		MTLDepthStencilDescriptor *dsDesc = [[MTLDepthStencilDescriptor alloc] init];
		dsDesc.depthCompareFunction = MTLCompareFunctionAlways;
		dsDesc.depthWriteEnabled = YES;
		ms->depthAlwaysWriteState = [ms->device newDepthStencilStateWithDescriptor:dsDesc];
	}

	RAVE_LOG("Metal resources initialized: device=%p queue=%p", ms->device, ms->commandQueue);
}


void RaveReleaseMetalResources(RaveDrawPrivate *priv)
{
	RaveMetalState *ms = priv->metal;
	if (!ms) return;

	// LIFECYCLE AUDIT (M003/S04/T02): All Metal resource types verified:
	// (1) RTT texture handles: freed from resource table (created by this context)
	// (2) 48+48 pipeline states: nil'd (ARC releases)
	// (3) 9+9 depth-stencil states: nil'd (ARC releases)
	// (4) 3 samplers: nil'd (ARC releases)
	// (5) Staging buffers: nil'd (ARC releases)
	// (6) Masked/GL-blend pipeline caches: cleared (ARC releases)
	// (7) MSAA textures + pipelines: nil'd (ARC releases)
	// (8) Depth buffer, shader library, vertex descriptor: nil'd (ARC releases)
	// (9) Command queue, device, command buffers: nil'd (ARC releases)

	// Free RTT (render-to-texture) handles created by this draw context
	for (uint32_t rttHandle : ms->rttTextureHandles) {
		RaveResourceFree(rttHandle);
	}
	if (!ms->rttTextureHandles.empty()) {
		RAVE_LOG("RaveReleaseMetalResources: freed %zu RTT texture handles",
		         ms->rttTextureHandles.size());
	}
	ms->rttTextureHandles.clear();

	// (0) Ensure no pending GPU work before releasing resources
	if (ms->currentEncoder) {
		[ms->currentEncoder endEncoding];
		ms->currentEncoder = nil;
	}
	if (ms->currentCommandBuffer) {
		[ms->currentCommandBuffer commit];
		[ms->currentCommandBuffer waitUntilCompleted];
		ms->currentCommandBuffer = nil;
	}
	if (ms->lastCommittedBuffer) {
		[ms->lastCommittedBuffer waitUntilCompleted];
		ms->lastCommittedBuffer = nil;
	}

	// Nil out all Metal objects (ARC handles release)
	for (int i = 0; i < 48; i++)
		ms->pipelines[i] = nil;
	for (int i = 0; i < 48; i++)
		ms->msaaPipelines[i] = nil;
	for (int i = 0; i < 9; i++)
		ms->depthStates[i] = nil;
	for (int i = 0; i < 9; i++)
		ms->depthStatesNoWrite[i] = nil;

	for (int i = 0; i < 3; i++)
		ms->samplers[i] = nil;

	ms->stagingDrawBuffer = nil;
	ms->stagingZBuffer = nil;
	ms->depthAlwaysWriteState = nil;
	// Note: drawBufferCPU/zBufferCPU are Mac_sysalloc'd -- no explicit free needed
	// (Mac heap is reclaimed on emulator shutdown)

	ms->maskedPipelines.clear();
	ms->glBlendPipelines.clear();

	ms->msaaColorTexture = nil;
	ms->msaaDepthTexture = nil;
	ms->shaderLibrary = nil;
	ms->vertexDescriptor = nil;
	ms->depthBuffer = nil;
	ms->currentCommandBuffer = nil;
	ms->currentEncoder = nil;
	ms->overlayTexture = nil;
	ms->lastCommittedBuffer = nil;
	ms->commandQueue = nil;
	ms->device = nil;

	delete ms;
	priv->metal = nullptr;

	RAVE_LOG("Metal resources released");
}


/*
 *  Render method helper
 */

static RaveDrawPrivate *GetContextFromDrawAddr(uint32 drawContextAddr)
{
	uint32 handle = ReadMacInt32(drawContextAddr + 0);
	return RaveGetContext(handle);
}


/*
 *  GLBlendToMTL - map OpenGL blend factor constants to Metal blend factors
 */
static MTLBlendFactor GLBlendToMTL(uint32_t glFactor) {
	switch (glFactor) {
		case 0x0000: return MTLBlendFactorZero;
		case 0x0001: return MTLBlendFactorOne;
		case 0x0300: return MTLBlendFactorSourceColor;
		case 0x0301: return MTLBlendFactorOneMinusSourceColor;
		case 0x0302: return MTLBlendFactorSourceAlpha;
		case 0x0303: return MTLBlendFactorOneMinusSourceAlpha;
		case 0x0304: return MTLBlendFactorDestinationAlpha;
		case 0x0305: return MTLBlendFactorOneMinusDestinationAlpha;
		case 0x0306: return MTLBlendFactorDestinationColor;
		case 0x0307: return MTLBlendFactorOneMinusDestinationColor;
		case 0x0308: return MTLBlendFactorSourceAlphaSaturated;
		default:     return MTLBlendFactorOne;
	}
}


/*
 *  GetGLBlendPipeline - get or lazily create a pipeline with GL blend factors
 *
 *  Used when kQABlend_OpenGL (blend mode 2) is active. Caches pipelines
 *  keyed by (funcConstBits, glBlendSrc, glBlendDst, msaa).
 */
static id<MTLRenderPipelineState> GetGLBlendPipeline(RaveMetalState *ms, int funcConstBits,
                                                       uint32_t glBlendSrc, uint32_t glBlendDst, bool msaa) {
	uint64_t key = ((uint64_t)(funcConstBits & 0xF) << 48) | ((uint64_t)(msaa ? 1 : 0) << 32)
	             | ((uint64_t)(glBlendSrc & 0xFFFF) << 16) | (uint64_t)(glBlendDst & 0xFFFF);

	auto it = ms->glBlendPipelines.find(key);
	if (it != ms->glBlendPipelines.end()) return it->second;

	// Derive function constants from bits 0-3
	bool tex      = (funcConstBits & 1) != 0;
	bool fog      = (funcConstBits & 2) != 0;
	bool alpha    = (funcConstBits & 4) != 0;
	bool multiTex = (funcConstBits & 8) != 0;

	MTLFunctionConstantValues *constants = [[MTLFunctionConstantValues alloc] init];
	[constants setConstantValue:&tex      type:MTLDataTypeBool atIndex:0];
	[constants setConstantValue:&fog      type:MTLDataTypeBool atIndex:1];
	[constants setConstantValue:&alpha    type:MTLDataTypeBool atIndex:2];
	[constants setConstantValue:&multiTex type:MTLDataTypeBool atIndex:3];

	NSError *err = nil;
	id<MTLFunction> vertexFunc = [ms->shaderLibrary newFunctionWithName:@"rave_vertex"
	                                                     constantValues:constants error:&err];
	id<MTLFunction> fragmentFunc = [ms->shaderLibrary newFunctionWithName:@"rave_fragment"
	                                                       constantValues:constants error:&err];
	if (!vertexFunc || !fragmentFunc) {
		RAVE_LOG("GetGLBlendPipeline: function creation failed for bits %d src 0x%x dst 0x%x",
		         funcConstBits, glBlendSrc, glBlendDst);
		return nil;
	}

	MTLRenderPipelineDescriptor *pipeDesc = [[MTLRenderPipelineDescriptor alloc] init];
	pipeDesc.vertexFunction = vertexFunc;
	pipeDesc.fragmentFunction = fragmentFunc;
	pipeDesc.vertexDescriptor = ms->vertexDescriptor;
	pipeDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	pipeDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	pipeDesc.sampleCount = msaa ? 4 : 1;

	// GL blend factors
	pipeDesc.colorAttachments[0].blendingEnabled = YES;
	pipeDesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
	pipeDesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
	pipeDesc.colorAttachments[0].sourceRGBBlendFactor = GLBlendToMTL(glBlendSrc);
	pipeDesc.colorAttachments[0].destinationRGBBlendFactor = GLBlendToMTL(glBlendDst);
	pipeDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
	pipeDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

	id<MTLRenderPipelineState> pipeline = [ms->device newRenderPipelineStateWithDescriptor:pipeDesc error:&err];
	if (!pipeline) {
		RAVE_LOG("GetGLBlendPipeline: creation failed for bits %d src 0x%x dst 0x%x: %s",
		         funcConstBits, glBlendSrc, glBlendDst, [[err localizedDescription] UTF8String]);
		return nil;
	}

	ms->glBlendPipelines[key] = pipeline;
	RAVE_LOG("GetGLBlendPipeline: created bits %d src 0x%x dst 0x%x msaa=%d (cache size=%zu)",
	         funcConstBits, glBlendSrc, glBlendDst, msaa, ms->glBlendPipelines.size());
	return pipeline;
}


/*
 *  ApplyDirtyState - set pipeline and depth state on encoder per dirty flags
 *
 *  textured: when true, selects has_texture=1 pipeline variant and binds
 *            the current texture, sampler, and fragment uniforms (TextureOp).
 */
static void ApplyDirtyState(RaveDrawPrivate *priv, bool forceAll, bool textured = false)
{
	RaveMetalState *ms = priv->metal;
	if (!ms->currentEncoder) return;

	// Determine current pipeline index
	// bit 0 = has_texture, bit 1 = has_fog, bit 2 = has_alpha_test, bit 3 = has_multi_texture
	int blend_mode = (int)priv->state[9].i;  // kQATag_Blend
	int func_const_bits = 0;
	if (textured) func_const_bits |= 1;  // bit 0 = has_texture
	if (priv->state[17].i != 0 || priv->ati_fog_active) func_const_bits |= 2;  // bit 1: has_fog
	if (priv->state[31].i != 0 && priv->state[31].i != 7) func_const_bits |= 4;  // bit 2: has_alpha_test
	if (priv->multiTextureActive) func_const_bits |= 8;  // bit 3: has_multi_texture

	id<MTLRenderPipelineState> selectedPipeline = nil;

	if (blend_mode == 2) {
		// kQABlend_OpenGL: use GL blend factors from tags 109/110
		uint32_t glSrc = priv->state[109].i;  // kQATagGL_BlendSrc
		uint32_t glDst = priv->state[110].i;  // kQATagGL_BlendDst
		selectedPipeline = GetGLBlendPipeline(ms, func_const_bits, glSrc, glDst, ms->msaaActive);
	}

	int pipe_idx = (blend_mode == 2 ? 0 : (blend_mode < 0 || blend_mode > 1 ? 0 : blend_mode)) * 16 + func_const_bits;

	if (forceAll || pipe_idx != ms->currentPipelineIdx || selectedPipeline != nil) {
		if (selectedPipeline) {
			// GL blend pipeline (kQABlend_OpenGL)
			[ms->currentEncoder setRenderPipelineState:selectedPipeline];
			ms->currentPipelineIdx = pipe_idx;
		} else {
			// Check if channel mask requires a masked pipeline variant
			uint32_t channelMask = priv->state[27].i;  // kQATag_ChannelMask, default 0xF (all)
			if (channelMask != 0xF && channelMask != 0) {
				id<MTLRenderPipelineState> maskedPipe = GetMaskedPipeline(ms, pipe_idx, channelMask, ms->msaaActive);
				if (maskedPipe) {
					[ms->currentEncoder setRenderPipelineState:maskedPipe];
					ms->currentPipelineIdx = pipe_idx;
				}
			} else {
				id<MTLRenderPipelineState> __strong *pipeArray = ms->msaaActive ? ms->msaaPipelines : ms->pipelines;
				if (pipe_idx >= 0 && pipe_idx < 48 && pipeArray[pipe_idx]) {
					[ms->currentEncoder setRenderPipelineState:pipeArray[pipe_idx]];
					ms->currentPipelineIdx = pipe_idx;
				}
			}
		}
	}

	// Apply depth state from ZFunction tag (state[0]) and ZBufferMask (state[28])
	if (forceAll || (priv->dirty_flags & 1)) {
		int zfunc = (int)priv->state[0].i;
		if (zfunc >= 0 && zfunc < 9) {
			bool depthWriteEnabled = (priv->state[28].i != 0);
			__strong id<MTLDepthStencilState> *dsArray = depthWriteEnabled ? ms->depthStates : ms->depthStatesNoWrite;
			if (dsArray[zfunc]) {
				[ms->currentEncoder setDepthStencilState:dsArray[zfunc]];
			}
		}
	}

	// Apply GL scissor rect if GL tags are set (tags 105-108)
	if (priv->state[105].i != 0 || priv->state[106].i != 0 ||
	    priv->state[107].i != 0 || priv->state[108].i != 0) {
		MTLScissorRect scissor;
		scissor.x = (NSUInteger)priv->state[105].i;       // kQATagGL_ScissorXMin
		scissor.y = (NSUInteger)priv->state[106].i;       // kQATagGL_ScissorYMin
		scissor.width = (NSUInteger)(priv->state[107].i - priv->state[105].i);   // XMax - XMin
		scissor.height = (NSUInteger)(priv->state[108].i - priv->state[106].i);  // YMax - YMin
		// Clamp to drawable dimensions to avoid Metal validation errors
		if (scissor.x + scissor.width > (NSUInteger)priv->width)
			scissor.width = priv->width - scissor.x;
		if (scissor.y + scissor.height > (NSUInteger)priv->height)
			scissor.height = priv->height - scissor.y;
		if (scissor.width > 0 && scissor.height > 0) {
			[ms->currentEncoder setScissorRect:scissor];
		}
	}

	// Bind texture and sampler when rendering textured geometry
	if (textured) {
		// Bind texture from kQATag_Texture (state[13])
		uint32_t tex_mac_addr = priv->state[13].i;
		if (tex_mac_addr != 0) {
			uint32_t tex_handle = RaveResourceFindByAddr(tex_mac_addr);
			RaveResourceEntry *tex_entry = RaveResourceGet(tex_handle);
			if (tex_entry) {
				// Deferred texture creation: if metal_texture is nil but we have
				// a pixmap address, the texture was created with placeholder data
				// at QATextureNew time. The game has since written the real pixels
				// into Mac memory. Read them now and create the Metal texture.
				if (!tex_entry->metal_texture && tex_entry->pixmap_mac_addr != 0) {
					RaveRealizeDeferredTexture(tex_entry);
				}
				// Live pixmap re-upload: the original RAVE software renderer reads
				// from the pixmap on every draw call (no GPU upload step). QD3D's
				// Interactive Renderer writes directly to the pixmap between frames.
				// We must re-read and re-upload every frame to match this behavior.
				else if (tex_entry->metal_texture && !tex_entry->pixels_copied && tex_entry->pixmap_mac_addr != 0) {
					RaveRefreshTextureFromPixmap(tex_entry);
				}
				if (tex_entry->metal_texture) {
					id<MTLTexture> mtlTex = (__bridge id<MTLTexture>)tex_entry->metal_texture;
					[ms->currentEncoder setFragmentTexture:mtlTex atIndex:0];
				}
			}
		}

		// Bind sampler: check GL wrap/filter tags (101-104) for custom sampler
		uint32_t glWrapU  = priv->state[101].i;  // kQATagGL_TextureWrapU
		uint32_t glWrapV  = priv->state[102].i;  // kQATagGL_TextureWrapV
		uint32_t glMagFilt = priv->state[103].i;  // kQATagGL_TextureMagFilter
		uint32_t glMinFilt = priv->state[104].i;  // kQATagGL_TextureMinFilter
		if (glWrapU != 0 || glWrapV != 0 || glMagFilt != 0 || glMinFilt != 0) {
			// GL tags set: create ad-hoc sampler (Metal caches internally)
			MTLSamplerDescriptor *sampDesc = [[MTLSamplerDescriptor alloc] init];
			sampDesc.sAddressMode = (glWrapU == 1) ? MTLSamplerAddressModeClampToEdge : MTLSamplerAddressModeRepeat;
			sampDesc.tAddressMode = (glWrapV == 1) ? MTLSamplerAddressModeClampToEdge : MTLSamplerAddressModeRepeat;
			sampDesc.magFilter = (glMagFilt == 1) ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
			sampDesc.minFilter = (glMinFilt == 1) ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
			id<MTLSamplerState> glSampler = [ms->device newSamplerStateWithDescriptor:sampDesc];
			[ms->currentEncoder setFragmentSamplerState:glSampler atIndex:0];
		} else {
			// Use standard sampler from kQATag_TextureFilter (state[11])
			int filter = (int)priv->state[11].i;
			if (filter < 0 || filter > 2) filter = 0;
			[ms->currentEncoder setFragmentSamplerState:ms->samplers[filter] atIndex:0];
		}

		// Multi-texture: bind second texture and sampler at indices 1
		if (priv->multiTextureActive && priv->multiTextureHandle != 0) {
			uint32_t tex2_handle = RaveResourceFindByAddr(priv->multiTextureHandle);
			RaveResourceEntry *tex2_entry = RaveResourceGet(tex2_handle);
			if (tex2_entry) {
				if (!tex2_entry->metal_texture && tex2_entry->pixmap_mac_addr != 0) {
					RaveRealizeDeferredTexture(tex2_entry);
				}
				if (tex2_entry->metal_texture) {
					id<MTLTexture> mtlTex2 = (__bridge id<MTLTexture>)tex2_entry->metal_texture;
					[ms->currentEncoder setFragmentTexture:mtlTex2 atIndex:1];
				}
			}
			// Use same sampler filter for second texture
			int filter = (int)priv->state[11].i;
			if (filter < 0 || filter > 2) filter = 0;
			[ms->currentEncoder setFragmentSamplerState:ms->samplers[filter] atIndex:1];
		}
	}

	// Bind vertex uniforms (point width from kQATag_Width) at buffer(2)
	VertexUniforms vertUniforms;
	vertUniforms.point_width = priv->state[5].f;  // kQATag_Width
	if (vertUniforms.point_width < 1.0f) vertUniforms.point_width = 1.0f;
	[ms->currentEncoder setVertexBytes:&vertUniforms length:sizeof(vertUniforms) atIndex:2];

	// Always bind fragment uniforms (needed for fog/alpha_test even without texture)
	FragmentUniforms fragUniforms = {};
	if (textured) fragUniforms.texture_op = (int32_t)priv->state[12].i;
	// Fog parameters: ATI fog overrides standard when ati_fog_active is true
	if (priv->ati_fog_active) {
		int ati_fog_mode = (int)priv->ati_state[2].i;  // kATIFogMode (index 2)
		switch (ati_fog_mode) {
			case 0: fragUniforms.fog_mode = 0; break;  // kQATIFogDisable -> None
			case 1: fragUniforms.fog_mode = 3; break;  // kQATIFogExp -> Exponential
			case 2: fragUniforms.fog_mode = 4; break;  // kQATIFogExp2 -> ExponentialSquared
			case 3: fragUniforms.fog_mode = 1; break;  // kQATIFogAlpha -> Alpha
			case 4: fragUniforms.fog_mode = 2; break;  // kQATIFogLinear -> Linear
			default: fragUniforms.fog_mode = 0; break;
		}
		fragUniforms.fog_color_r = priv->ati_state[3].f;   // kATIFogColor_r
		fragUniforms.fog_color_g = priv->ati_state[4].f;   // kATIFogColor_g
		fragUniforms.fog_color_b = priv->ati_state[5].f;   // kATIFogColor_b
		fragUniforms.fog_color_a = priv->ati_state[6].f;   // kATIFogColor_a
		fragUniforms.fog_density = priv->ati_state[7].f;    // kATIFogDensity
		fragUniforms.fog_start   = priv->ati_state[8].f;    // kATIFogStart
		fragUniforms.fog_end     = priv->ati_state[9].f;    // kATIFogEnd
		fragUniforms.fog_max_depth = priv->state[25].f != 0.0f ? priv->state[25].f : 1.0f;
	} else {
		fragUniforms.fog_mode       = (int32_t)priv->state[17].i;
		fragUniforms.fog_color_a    = priv->state[18].f;
		fragUniforms.fog_color_r    = priv->state[19].f;
		fragUniforms.fog_color_g    = priv->state[20].f;
		fragUniforms.fog_color_b    = priv->state[21].f;
		fragUniforms.fog_start      = priv->state[22].f;
		fragUniforms.fog_end        = priv->state[23].f;
		fragUniforms.fog_density    = priv->state[24].f;
		fragUniforms.fog_max_depth  = priv->state[25].f != 0.0f ? priv->state[25].f : 1.0f;
	}
	fragUniforms.alpha_test_func = (int32_t)priv->state[31].i;
	fragUniforms.alpha_test_ref = priv->state[46].f;
	fragUniforms.multi_texture_op = priv->state[35].i;      // kQATag_MultiTextureOp
	fragUniforms.multi_texture_factor = priv->state[51].f;  // kQATag_MultiTextureFactor
	fragUniforms.mipmap_bias = priv->state[41].f;           // kQATag_MipmapBias
	fragUniforms.multi_texture_mipmap_bias = priv->state[42].f;  // kQATag_MultiTextureMipmapBias
	// TextureOp Blend env color from GL texture env color tags (150-153)
	fragUniforms.env_color_r = priv->state[151].f;  // kQATagGL_TextureEnvColor_r
	fragUniforms.env_color_g = priv->state[152].f;  // kQATagGL_TextureEnvColor_g
	fragUniforms.env_color_b = priv->state[153].f;  // kQATagGL_TextureEnvColor_b
	fragUniforms.env_color_a = priv->state[150].f;  // kQATagGL_TextureEnvColor_a
	[ms->currentEncoder setFragmentBytes:&fragUniforms length:sizeof(fragUniforms) atIndex:0];

	priv->dirty_flags = 0;
}


/*
 *  Vertex conversion helpers
 */

// RaveVertex matches the Metal vertex layout (48 bytes)
struct RaveVertex {
	float pos[4];    // x, y, z, w          (16 bytes)
	float color[4];  // r, g, b, a          (16 bytes)
	float uv[4];     // uOverW, vOverW, invW, 0  (16 bytes)
};

// Read a float from Mac address space.
// ReadMacInt32 already returns host-endian (bswap_32 applied internally).
// We just reinterpret the uint32 bits as float.
static inline float ReadMacFloat(uint32 addr) {
	uint32 bits = ReadMacInt32(addr);
	float f;
	memcpy(&f, &bits, sizeof(float));
	return f;
}

static void ConvertGouraudVertex(uint32 srcAddr, RaveVertex *dst, bool perspZ) {
	dst->pos[0] = ReadMacFloat(srcAddr + 0);   // x (pixel)
	dst->pos[1] = ReadMacFloat(srcAddr + 4);   // y (pixel)
	float z    = ReadMacFloat(srcAddr + 8);     // z (0..1)
	float invW = ReadMacFloat(srcAddr + 12);    // 1/w
	// Always use raw z for depth buffer. The perspZ flag (kQATag_PerspectiveZ)
	// tells the hardware about z-value distribution (linear vs 1/z) for
	// precision, but z is already in [0,1] range for the depth buffer.
	// Using 1/invW (= w) produces values like 95.0 for Tomb Raider,
	// which are clipped by Metal's [0,1] depth range.
	dst->pos[2] = z;
	dst->pos[3] = 1.0f;

	dst->color[0] = ReadMacFloat(srcAddr + 16); // r
	dst->color[1] = ReadMacFloat(srcAddr + 20); // g
	dst->color[2] = ReadMacFloat(srcAddr + 24); // b
	dst->color[3] = ReadMacFloat(srcAddr + 28); // a

	dst->uv[0] = 0.0f;
	dst->uv[1] = 0.0f;
	dst->uv[2] = invW;  // GAP-011: pass invW for fog depth computation
	dst->uv[3] = 0.0f;
}


/*
 *  Z-sorted transparency helpers
 *
 *  When kQATag_ZSortedHint (tag 29) is set, transparent triangles are buffered
 *  instead of drawn immediately. At RenderEnd, they are sorted back-to-front
 *  (higher Z = farther = drawn first) and flushed with per-triangle state.
 */
static void BufferZSortTriangle(RaveDrawPrivate *priv, const RaveVertex *v0, const RaveVertex *v1,
                                 const RaveVertex *v2, bool textured)
{
	if (priv->zsortCount >= RAVE_ZSORT_MAX_TRIANGLES) {
		RAVE_LOG("ZSort: buffer full (%d triangles), dropping triangle", RAVE_ZSORT_MAX_TRIANGLES);
		return;
	}

	ZSortTriangle *tri = &priv->zsortBuffer[priv->zsortCount++];
	memcpy(&tri->verts[0], v0, sizeof(RaveVertex));
	memcpy(&tri->verts[1], v1, sizeof(RaveVertex));
	memcpy(&tri->verts[2], v2, sizeof(RaveVertex));
	tri->sortKey = (v0->pos[2] + v1->pos[2] + v2->pos[2]) / 3.0f;
	tri->textured = textured;
	tri->textureMacAddr = priv->state[13].i;  // kQATag_Texture
	tri->textureOp = (int32_t)priv->state[12].i;
	tri->blendMode = (int32_t)priv->state[9].i;
	tri->filterMode = (int32_t)priv->state[11].i;
}

static void FlushZSortBuffer(RaveDrawPrivate *priv)
{
	if (priv->zsortCount == 0) return;

	RaveMetalState *ms = priv->metal;
	if (!ms || !ms->currentEncoder) return;

	// Sort back-to-front (higher Z = farther = draw first)
	std::sort(priv->zsortBuffer, priv->zsortBuffer + priv->zsortCount,
	          [](const ZSortTriangle &a, const ZSortTriangle &b) {
	              return a.sortKey > b.sortKey;
	          });

	// Build fragment uniforms once (fog/alpha state is per-context, not per-triangle)
	FragmentUniforms fragUniforms = {};
	if (priv->ati_fog_active) {
		int ati_fog_mode = (int)priv->ati_state[2].i;
		switch (ati_fog_mode) {
			case 0: fragUniforms.fog_mode = 0; break;
			case 1: fragUniforms.fog_mode = 3; break;
			case 2: fragUniforms.fog_mode = 4; break;
			case 3: fragUniforms.fog_mode = 1; break;
			case 4: fragUniforms.fog_mode = 2; break;
			default: fragUniforms.fog_mode = 0; break;
		}
		fragUniforms.fog_color_r = priv->ati_state[3].f;
		fragUniforms.fog_color_g = priv->ati_state[4].f;
		fragUniforms.fog_color_b = priv->ati_state[5].f;
		fragUniforms.fog_color_a = priv->ati_state[6].f;
		fragUniforms.fog_density = priv->ati_state[7].f;
		fragUniforms.fog_start   = priv->ati_state[8].f;
		fragUniforms.fog_end     = priv->ati_state[9].f;
		fragUniforms.fog_max_depth = priv->state[25].f != 0.0f ? priv->state[25].f : 1.0f;
	} else {
		fragUniforms.fog_mode       = (int32_t)priv->state[17].i;
		fragUniforms.fog_color_a    = priv->state[18].f;
		fragUniforms.fog_color_r    = priv->state[19].f;
		fragUniforms.fog_color_g    = priv->state[20].f;
		fragUniforms.fog_color_b    = priv->state[21].f;
		fragUniforms.fog_start      = priv->state[22].f;
		fragUniforms.fog_end        = priv->state[23].f;
		fragUniforms.fog_density    = priv->state[24].f;
		fragUniforms.fog_max_depth  = priv->state[25].f != 0.0f ? priv->state[25].f : 1.0f;
	}
	fragUniforms.alpha_test_func = (int32_t)priv->state[31].i;
	fragUniforms.alpha_test_ref = priv->state[46].f;
	fragUniforms.mipmap_bias = priv->state[41].f;
	fragUniforms.multi_texture_mipmap_bias = priv->state[42].f;
	fragUniforms.env_color_r = priv->state[151].f;
	fragUniforms.env_color_g = priv->state[152].f;
	fragUniforms.env_color_b = priv->state[153].f;
	fragUniforms.env_color_a = priv->state[150].f;

	VertexUniforms vertUniforms;
	vertUniforms.point_width = priv->state[5].f;
	if (vertUniforms.point_width < 1.0f) vertUniforms.point_width = 1.0f;
	[ms->currentEncoder setVertexBytes:&vertUniforms length:sizeof(vertUniforms) atIndex:2];

	bool hasFog = (priv->state[17].i != 0 || priv->ati_fog_active);
	bool hasAlphaTest = (priv->state[31].i != 0 && priv->state[31].i != 7);

	// Batch consecutive triangles that share the same render state into single
	// draw calls.  The z-sort order is preserved within each batch since we
	// scan forward.  State keys: textured, textureMacAddr, blendMode,
	// filterMode, textureOp.  Triangles with different keys break the batch.
	//
	// Temporary vertex buffer: sized for the entire zsort buffer.
	// Most frames reuse a single batch for all triangles (same texture/blend).
	RaveVertex *batchVerts = new RaveVertex[priv->zsortCount * 3];
	uint32_t batchCount = 0;
	uint32_t drawCalls = 0;

	// State of the current batch (from the first triangle)
	int      curPipeIdx = -1;
	uint32_t curTexAddr = 0;
	int32_t  curTexOp   = 0;
	int      curFilter  = 0;
	bool     curTextured = false;

	auto flushBatch = [&]() {
		if (batchCount == 0) return;
		uint32_t vertCount = batchCount * 3;
		size_t dataSize = vertCount * sizeof(RaveVertex);

		// Set fragment uniforms with the current batch's textureOp
		fragUniforms.texture_op = curTextured ? curTexOp : 0;
		[ms->currentEncoder setFragmentBytes:&fragUniforms length:sizeof(fragUniforms) atIndex:0];

		if (dataSize > 4096) {
			id<MTLBuffer> buf = [ms->device newBufferWithBytes:batchVerts
			                                            length:dataSize
			                                           options:MTLResourceStorageModeShared];
			[ms->currentEncoder setVertexBuffer:buf offset:0 atIndex:0];
		} else {
			[ms->currentEncoder setVertexBytes:batchVerts length:dataSize atIndex:0];
		}
		[ms->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:vertCount];
		drawCalls++;
		batchCount = 0;
	};

	for (uint32_t i = 0; i < priv->zsortCount; i++) {
		ZSortTriangle *tri = &priv->zsortBuffer[i];

		int blend_mode = tri->blendMode;
		if (blend_mode < 0 || blend_mode > 2) blend_mode = 0;
		int pipe_idx = blend_mode * 16;
		if (tri->textured) pipe_idx |= 1;
		if (hasFog) pipe_idx |= 2;
		if (hasAlphaTest) pipe_idx |= 4;

		// Check if this triangle can join the current batch
		bool stateChanged = (pipe_idx != curPipeIdx ||
		                     tri->textured != curTextured ||
		                     tri->textureMacAddr != curTexAddr ||
		                     tri->textureOp != curTexOp ||
		                     tri->filterMode != curFilter);

		if (stateChanged) {
			// Flush previous batch
			flushBatch();

			// Set new GPU state
			curPipeIdx = pipe_idx;
			curTextured = tri->textured;
			curTexAddr = tri->textureMacAddr;
			curTexOp = tri->textureOp;
			curFilter = tri->filterMode;

			id<MTLRenderPipelineState> __strong *pipeArray = ms->msaaActive ? ms->msaaPipelines : ms->pipelines;
			if (pipe_idx >= 0 && pipe_idx < 48 && pipeArray[pipe_idx])
				[ms->currentEncoder setRenderPipelineState:pipeArray[pipe_idx]];

			if (tri->textured && tri->textureMacAddr != 0) {
				uint32_t tex_handle = RaveResourceFindByAddr(tri->textureMacAddr);
				RaveResourceEntry *tex_entry = RaveResourceGet(tex_handle);
				if (tex_entry) {
					if (!tex_entry->metal_texture && tex_entry->pixmap_mac_addr != 0) {
						RaveRealizeDeferredTexture(tex_entry);
					}
					if (tex_entry->metal_texture) {
						id<MTLTexture> mtlTex = (__bridge id<MTLTexture>)tex_entry->metal_texture;
						[ms->currentEncoder setFragmentTexture:mtlTex atIndex:0];
					}
				}
				int filter = tri->filterMode;
				if (filter < 0 || filter > 2) filter = 0;
				[ms->currentEncoder setFragmentSamplerState:ms->samplers[filter] atIndex:0];
			}
		}

		// Append triangle vertices to batch
		memcpy(&batchVerts[batchCount * 3], tri->verts, sizeof(RaveVertex) * 3);
		batchCount++;
	}

	// Flush final batch
	flushBatch();
	delete[] batchVerts;

	RAVE_LOG("ZSort: flushed %d triangles in %d draw calls", priv->zsortCount, drawCalls);
	priv->zsortCount = 0;
}


/*
 *  NativeDrawTriGouraud
 *
 *  DrawTriGouraud(drawContext, v0, v1, v2, flags)
 *  PPC args: r3=drawContextAddr, r4=v0Addr, r5=v1Addr, r6=v2Addr, r7=flags
 *
 *  flags: kQATriFlags_Backfacing (bit 0) = triangle is back-facing (hint only)
 *  Per RAVE spec p.1566, this flag is a hint to help resolve Z-buffer ambiguity,
 *  NOT a cull instruction. The QD3D IR handles actual backface culling before
 *  sending triangles to RAVE. We ignore this flag.
 */
int32 NativeDrawTriGouraud(uint32 drawContextAddr, uint32 v0Addr, uint32 v1Addr,
                            uint32 v2Addr, uint32 flags)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal || !priv->metal->renderPassActive) return kQANoErr;

	// kQATriFlags_Backfacing (bit 0) is a hint for Z-buffer disambiguation only.
	// The QD3D IR culls backfacing triangles itself before sending to RAVE.
	(void)flags;

	RaveMetalState *ms = priv->metal;
	bool perspZ = (priv->state[10].i != 0);  // kQATag_PerspectiveZ

	// Convert 3 vertices
	RaveVertex verts[3];
	ConvertGouraudVertex(v0Addr, &verts[0], perspZ);
	ConvertGouraudVertex(v1Addr, &verts[1], perspZ);
	ConvertGouraudVertex(v2Addr, &verts[2], perspZ);

	// Z-sorted transparency: buffer instead of drawing immediately
	if (priv->state[29].i == 1) {  // kQATag_ZSortedHint
		BufferZSortTriangle(priv, &verts[0], &verts[1], &verts[2], false);
		return kQANoErr;
	}

	// Apply pending state (pipeline, depth)
	ApplyDirtyState(priv, false);

	// Submit triangle
	[ms->currentEncoder setVertexBytes:verts length:sizeof(verts) atIndex:0];
	[ms->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	ms->drawCallCount++;
	ms->triangleCount += 1;
	ms->triGouraudCount++;

	return kQANoErr;
}


/*
 *  ConvertTextureVertex - convert TQAVTexture (64 bytes) to RaveVertex (48 bytes)
 *
 *  TQAVTexture layout (16 floats, 64 bytes):
 *    0: x, 4: y, 8: z, 12: invW
 *   16: r, 20: g, 24: b, 28: a
 *   32: uOverW, 36: vOverW
 *   40: kd_r, 44: kd_g, 48: kd_b
 *   52: ks_r, 56: ks_g, 60: ks_b
 *
 *  Color channel selection depends on TextureOp:
 *   Decal (bit 2): vertex rgb for blending
 *   Modulate (bit 0): kd_rgb for diffuse modulation
 *   Highlight (bit 1): ks_rgb for specular addition
 *   None: identity (1,1,1)
 */
static void ConvertTextureVertex(uint32 srcAddr, RaveVertex *dst, bool perspZ, int textureOp) {
	dst->pos[0] = ReadMacFloat(srcAddr + 0);   // x
	dst->pos[1] = ReadMacFloat(srcAddr + 4);   // y
	float z     = ReadMacFloat(srcAddr + 8);    // z
	float invW  = ReadMacFloat(srcAddr + 12);   // invW
	// Always use raw z for depth buffer (see ConvertGouraudVertex comment).
	dst->pos[2] = z;
	dst->pos[3] = 1.0f;

	// Color: depends on TextureOp
	if (textureOp & 4) {  // Decal: use vertex rgb for blending
		dst->color[0] = ReadMacFloat(srcAddr + 16);  // r
		dst->color[1] = ReadMacFloat(srcAddr + 20);  // g
		dst->color[2] = ReadMacFloat(srcAddr + 24);  // b
	} else if (textureOp & 1) {  // Modulate: use kd_rgb
		dst->color[0] = ReadMacFloat(srcAddr + 40);  // kd_r
		dst->color[1] = ReadMacFloat(srcAddr + 44);  // kd_g
		dst->color[2] = ReadMacFloat(srcAddr + 48);  // kd_b
	} else if (textureOp & 2) {  // Highlight: use ks_rgb
		dst->color[0] = ReadMacFloat(srcAddr + 52);  // ks_r
		dst->color[1] = ReadMacFloat(srcAddr + 56);  // ks_g
		dst->color[2] = ReadMacFloat(srcAddr + 60);  // ks_b
	} else {  // None: identity multiply
		dst->color[0] = 1.0f;
		dst->color[1] = 1.0f;
		dst->color[2] = 1.0f;
	}
	dst->color[3] = ReadMacFloat(srcAddr + 28);  // alpha (always needed)

	// Perspective-correct UV data
	// RAVE/QD3D V=0 maps to the first row of the TQAImage pixel buffer.
	// Metal textures also store row 0 at the top.  However, the QD3D
	// Interactive Renderer was originally backed by ATI's OpenGL-based
	// RAVE engine, where textures are stored with row 0 at the *bottom*
	// (OpenGL convention).  QD3D's IR therefore emits V coordinates in
	// OpenGL convention: V=0 = bottom of texture, V=1 = top.
	// Since our Metal textures have row 0 at the top, we must flip V:
	//   v_metal = 1 - v_gl
	// In perspective-divided form: vOverW_flipped = invW - vOverW
	float uOverW = ReadMacFloat(srcAddr + 32);
	float vOverW = ReadMacFloat(srcAddr + 36);
	dst->uv[0] = uOverW;
	dst->uv[1] = invW - vOverW;  // flip V for Metal's top-left origin
	dst->uv[2] = invW;                         // for fragment shader division
	dst->uv[3] = 0.0f;
}


/*
 *  NativeDrawTriTexture
 *
 *  DrawTriTexture(drawContext, v0, v1, v2, flags)
 *  PPC args: r3=drawContextAddr, r4=v0Addr, r5=v1Addr, r6=v2Addr, r7=flags
 *
 *  Renders a single textured triangle with perspective-correct UVs.
 *  TQAVTexture vertices are 64 bytes each.
 */
int32 NativeDrawTriTexture(uint32 drawContextAddr, uint32 v0Addr, uint32 v1Addr,
                            uint32 v2Addr, uint32 flags)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal || !priv->metal->renderPassActive) return kQANoErr;

	// kQATriFlags_Backfacing (bit 0) is a hint for Z-buffer disambiguation only.
	// The QD3D IR culls backfacing triangles itself before sending to RAVE.
	(void)flags;

	RaveMetalState *ms = priv->metal;
	bool perspZ = (priv->state[10].i != 0);
	int textureOp = (int)priv->state[12].i;

	RaveVertex verts[3];
	ConvertTextureVertex(v0Addr, &verts[0], perspZ, textureOp);
	ConvertTextureVertex(v1Addr, &verts[1], perspZ, textureOp);
	ConvertTextureVertex(v2Addr, &verts[2], perspZ, textureOp);

	// Z-sorted transparency: buffer instead of drawing immediately
	if (priv->state[29].i == 1) {  // kQATag_ZSortedHint
		BufferZSortTriangle(priv, &verts[0], &verts[1], &verts[2], true);
		return kQANoErr;
	}

	ApplyDirtyState(priv, false, true);  // textured=true

	[ms->currentEncoder setVertexBytes:verts length:sizeof(verts) atIndex:0];

	// Bind UV2 for multi-texture (DrawTriTexture draws 3 vertices per call,
	// multi-texture UV2 only applies if staging count matches)
	if (priv->multiTextureActive && priv->multiTexStagingCount >= 3) {
		size_t multiTexSize = 3 * 16;  // 4 floats per vertex
		[ms->currentEncoder setVertexBytes:priv->multiTexStagingBuffer
		                            length:multiTexSize atIndex:3];
	}

	[ms->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
	ms->drawCallCount++;
	ms->triangleCount += 1;
	ms->triTextureCount++;

	return kQANoErr;
}


/*
 *  NativeDrawVGouraud
 *
 *  DrawVGouraud(drawContext, nVertices, vertexMode, vertices[], flags[])
 *  PPC args: r3=drawContextAddr, r4=nVertices, r5=vertexMode, r6=verticesAddr, r7=flagsAddr
 *
 *  verticesAddr: Mac address of TQAVGouraud[] array (each 32 bytes)
 *  flagsAddr: Mac address of uint32[] per-triangle flags array
 *             May be NULL for points/lines. For triangles, one flags entry per triangle.
 */
int32 NativeDrawVGouraud(uint32 drawContextAddr, uint32 nVertices, uint32 vertexMode,
                          uint32 verticesAddr, uint32 flagsAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal || !priv->metal->renderPassActive) return kQANoErr;
	if (nVertices == 0) return kQANoErr;

	RaveMetalState *ms = priv->metal;
	ms->drawCallCount++;
	ms->vGouraudCount++;
	bool perspZ = (priv->state[10].i != 0);

	ApplyDirtyState(priv, false);

	switch (vertexMode) {
	case 0: // kQAVertexMode_Point
	{
		RaveVertex *verts = new RaveVertex[nVertices];
		for (uint32 i = 0; i < nVertices; i++) {
			ConvertGouraudVertex(verticesAddr + i * 32, &verts[i], perspZ);
		}
		size_t dataSize = nVertices * sizeof(RaveVertex);
		if (dataSize > 4096) {
			id<MTLBuffer> buf = [ms->device newBufferWithBytes:verts length:dataSize options:MTLResourceStorageModeShared];
			[ms->currentEncoder setVertexBuffer:buf offset:0 atIndex:0];
		} else {
			[ms->currentEncoder setVertexBytes:verts length:dataSize atIndex:0];
		}
		[ms->currentEncoder drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:nVertices];
		delete[] verts;
		break;
	}

	case 1: // kQAVertexMode_Line
	{
		uint32 nLines = nVertices / 2;
		if (nLines == 0) break;
		uint32 count = nLines * 2;
		RaveVertex *verts = new RaveVertex[count];
		for (uint32 i = 0; i < count; i++) {
			ConvertGouraudVertex(verticesAddr + i * 32, &verts[i], perspZ);
		}
		size_t dataSize = count * sizeof(RaveVertex);
		if (dataSize > 4096) {
			id<MTLBuffer> buf = [ms->device newBufferWithBytes:verts length:dataSize options:MTLResourceStorageModeShared];
			[ms->currentEncoder setVertexBuffer:buf offset:0 atIndex:0];
		} else {
			[ms->currentEncoder setVertexBytes:verts length:dataSize atIndex:0];
		}
		[ms->currentEncoder drawPrimitives:MTLPrimitiveTypeLine vertexStart:0 vertexCount:count];
		delete[] verts;
		break;
	}

	case 2: // kQAVertexMode_Polyline
	{
		if (nVertices < 2) break;
		RaveVertex *verts = new RaveVertex[nVertices];
		for (uint32 i = 0; i < nVertices; i++) {
			ConvertGouraudVertex(verticesAddr + i * 32, &verts[i], perspZ);
		}
		size_t dataSize = nVertices * sizeof(RaveVertex);
		if (dataSize > 4096) {
			id<MTLBuffer> buf = [ms->device newBufferWithBytes:verts length:dataSize options:MTLResourceStorageModeShared];
			[ms->currentEncoder setVertexBuffer:buf offset:0 atIndex:0];
		} else {
			[ms->currentEncoder setVertexBytes:verts length:dataSize atIndex:0];
		}
		[ms->currentEncoder drawPrimitives:MTLPrimitiveTypeLineStrip vertexStart:0 vertexCount:nVertices];
		delete[] verts;
		break;
	}

	case 3: // kQAVertexMode_Tri (triangle list)
	{
		uint32 nTris = nVertices / 3;
		if (nTris == 0) break;

		// kQATriFlags_Backfacing is a hint only (RAVE spec p.1566) -- do not cull.
		// The QD3D IR handles backface culling before sending triangles to RAVE.
		uint32 totalVerts = nTris * 3;
		RaveVertex *allVerts = new RaveVertex[totalVerts];
		for (uint32 i = 0; i < totalVerts; i++) {
			ConvertGouraudVertex(verticesAddr + i * 32, &allVerts[i], perspZ);
		}

		size_t dataSize = totalVerts * sizeof(RaveVertex);
		if (dataSize > 4096) {
			id<MTLBuffer> buf = [ms->device newBufferWithBytes:allVerts length:dataSize options:MTLResourceStorageModeShared];
			[ms->currentEncoder setVertexBuffer:buf offset:0 atIndex:0];
		} else {
			[ms->currentEncoder setVertexBytes:allVerts length:dataSize atIndex:0];
		}
		[ms->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:totalVerts];
		delete[] allVerts;
		break;
	}

	case 4: // kQAVertexMode_Strip
	{
		if (nVertices < 3) break;

		// kQATriFlags_Backfacing is a hint only -- do not cull.
		RaveVertex *allVerts = new RaveVertex[nVertices];
		for (uint32 i = 0; i < nVertices; i++) {
			ConvertGouraudVertex(verticesAddr + i * 32, &allVerts[i], perspZ);
		}

		size_t dataSize = nVertices * sizeof(RaveVertex);
		if (dataSize > 4096) {
			id<MTLBuffer> buf = [ms->device newBufferWithBytes:allVerts length:dataSize options:MTLResourceStorageModeShared];
			[ms->currentEncoder setVertexBuffer:buf offset:0 atIndex:0];
		} else {
			[ms->currentEncoder setVertexBytes:allVerts length:dataSize atIndex:0];
		}
		[ms->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:nVertices];
		delete[] allVerts;
		break;
	}

	case 5: // kQAVertexMode_Fan
	{
		if (nVertices < 3) break;
		uint32 nTris = nVertices - 2;

		// kQATriFlags_Backfacing is a hint only -- do not cull.
		// Metal has no triangle fan primitive, so expand to triangle list.
		RaveVertex *allVerts = new RaveVertex[nVertices];
		for (uint32 i = 0; i < nVertices; i++) {
			ConvertGouraudVertex(verticesAddr + i * 32, &allVerts[i], perspZ);
		}

		RaveVertex *expanded = new RaveVertex[nTris * 3];
		uint32 outIdx = 0;
		for (uint32 t = 0; t < nTris; t++) {
			expanded[outIdx++] = allVerts[0];
			expanded[outIdx++] = allVerts[t + 1];
			expanded[outIdx++] = allVerts[t + 2];
		}
		size_t dataSize = outIdx * sizeof(RaveVertex);
		if (dataSize > 4096) {
			id<MTLBuffer> buf = [ms->device newBufferWithBytes:expanded length:dataSize options:MTLResourceStorageModeShared];
			[ms->currentEncoder setVertexBuffer:buf offset:0 atIndex:0];
		} else {
			[ms->currentEncoder setVertexBytes:expanded length:dataSize atIndex:0];
		}
		[ms->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:outIdx];
		delete[] expanded;
		delete[] allVerts;
		break;
	}

	default:
		RAVE_LOG("DrawVGouraud: unknown vertexMode %d", vertexMode);
		break;
	}

	return kQANoErr;
}


/*
 *  NativeSubmitVerticesGouraud
 *
 *  SubmitVerticesGouraud(drawContext, nVertices, vertices[])
 *  PPC args: r3=drawContextAddr, r4=nVertices, r5=verticesAddr
 *  Copies and byte-swaps vertices into per-context staging buffer.
 *  Replaces buffer contents (spec behavior).
 */
int32 NativeSubmitVerticesGouraud(uint32 drawContextAddr, uint32 nVertices, uint32 verticesAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv) return kQANoErr;

	if (nVertices > priv->vertexStagingCapacity) {
		RAVE_LOG("SubmitVerticesGouraud: %d vertices exceeds capacity %d, clamping",
		         nVertices, priv->vertexStagingCapacity);
		nVertices = priv->vertexStagingCapacity;
	}

	bool perspZ = (priv->state[10].i != 0);
	RaveVertex *dst = (RaveVertex *)priv->vertexStagingBuffer;

	for (uint32 i = 0; i < nVertices; i++) {
		ConvertGouraudVertex(verticesAddr + i * 32, &dst[i], perspZ);
	}
	priv->vertexStagingCount = nVertices;

	// Diagnostic: dump vertex bounds for first 10 frames of each context
	if (priv->frameCount <= 10 && nVertices > 0) {
		float minX = dst[0].pos[0], maxX = dst[0].pos[0];
		float minY = dst[0].pos[1], maxY = dst[0].pos[1];
		float minZ = dst[0].pos[2], maxZ = dst[0].pos[2];
		float minA = dst[0].color[3], maxA = dst[0].color[3];
		float minR = dst[0].color[0], maxR = dst[0].color[0];
		float minG = dst[0].color[1], maxG = dst[0].color[1];
		float minB = dst[0].color[2], maxB = dst[0].color[2];
		for (uint32 i = 1; i < nVertices; i++) {
			if (dst[i].pos[0] < minX) minX = dst[i].pos[0];
			if (dst[i].pos[0] > maxX) maxX = dst[i].pos[0];
			if (dst[i].pos[1] < minY) minY = dst[i].pos[1];
			if (dst[i].pos[1] > maxY) maxY = dst[i].pos[1];
			if (dst[i].pos[2] < minZ) minZ = dst[i].pos[2];
			if (dst[i].pos[2] > maxZ) maxZ = dst[i].pos[2];
			if (dst[i].color[3] < minA) minA = dst[i].color[3];
			if (dst[i].color[3] > maxA) maxA = dst[i].color[3];
			if (dst[i].color[0] < minR) minR = dst[i].color[0];
			if (dst[i].color[0] > maxR) maxR = dst[i].color[0];
			if (dst[i].color[1] < minG) minG = dst[i].color[1];
			if (dst[i].color[1] > maxG) maxG = dst[i].color[1];
			if (dst[i].color[2] < minB) minB = dst[i].color[2];
			if (dst[i].color[2] > maxB) maxB = dst[i].color[2];
		}
		RAVE_LOG("SubmitVGour: f=%u n=%u x=[%.1f,%.1f] y=[%.1f,%.1f] z=[%.3f,%.3f] a=[%.2f,%.2f] rgb=[%.2f-%.2f,%.2f-%.2f,%.2f-%.2f] perspZ=%d",
		         priv->frameCount, nVertices,
		         minX, maxX, minY, maxY, minZ, maxZ, minA, maxA,
		         minR, maxR, minG, maxG, minB, maxB,
		         perspZ ? 1 : 0);
	}

	return kQANoErr;
}


/*
 *  NativeDrawVTexture
 *
 *  DrawVTexture(drawContext, nVertices, vertexMode, vertices[], flags[])
 *  PPC args: r3=drawContextAddr, r4=nVertices, r5=vertexMode, r6=verticesAddr, r7=flagsAddr
 *
 *  verticesAddr: Mac address of TQAVTexture[] array (each 64 bytes)
 *  flagsAddr: Mac address of uint32[] per-triangle flags array
 *             May be NULL for points/lines. For triangles, one flags entry per triangle.
 */
int32 NativeDrawVTexture(uint32 drawContextAddr, uint32 nVertices, uint32 vertexMode,
                          uint32 verticesAddr, uint32 flagsAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal || !priv->metal->renderPassActive) return kQANoErr;
	if (nVertices == 0) return kQANoErr;

	RaveMetalState *ms = priv->metal;
	ms->drawCallCount++;
	ms->vTextureCount++;
	bool perspZ = (priv->state[10].i != 0);
	int textureOp = (int)priv->state[12].i;

	ApplyDirtyState(priv, false, true);  // textured=true

	// Bind UV2 staging buffer for multi-texture at buffer index 3
	if (priv->multiTextureActive && priv->multiTexStagingCount > 0) {
		size_t multiTexSize = priv->multiTexStagingCount * 16;  // 4 floats per vertex
		[ms->currentEncoder setVertexBytes:priv->multiTexStagingBuffer
		                            length:multiTexSize atIndex:3];
	}

	switch (vertexMode) {
	case 0: // kQAVertexMode_Point
	{
		RaveVertex *verts = new RaveVertex[nVertices];
		for (uint32 i = 0; i < nVertices; i++) {
			ConvertTextureVertex(verticesAddr + i * 64, &verts[i], perspZ, textureOp);
		}
		size_t dataSize = nVertices * sizeof(RaveVertex);
		if (dataSize > 4096) {
			id<MTLBuffer> buf = [ms->device newBufferWithBytes:verts length:dataSize options:MTLResourceStorageModeShared];
			[ms->currentEncoder setVertexBuffer:buf offset:0 atIndex:0];
		} else {
			[ms->currentEncoder setVertexBytes:verts length:dataSize atIndex:0];
		}
		[ms->currentEncoder drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:nVertices];
		delete[] verts;
		break;
	}

	case 1: // kQAVertexMode_Line
	{
		uint32 nLines = nVertices / 2;
		if (nLines == 0) break;
		uint32 count = nLines * 2;
		RaveVertex *verts = new RaveVertex[count];
		for (uint32 i = 0; i < count; i++) {
			ConvertTextureVertex(verticesAddr + i * 64, &verts[i], perspZ, textureOp);
		}
		size_t dataSize = count * sizeof(RaveVertex);
		if (dataSize > 4096) {
			id<MTLBuffer> buf = [ms->device newBufferWithBytes:verts length:dataSize options:MTLResourceStorageModeShared];
			[ms->currentEncoder setVertexBuffer:buf offset:0 atIndex:0];
		} else {
			[ms->currentEncoder setVertexBytes:verts length:dataSize atIndex:0];
		}
		[ms->currentEncoder drawPrimitives:MTLPrimitiveTypeLine vertexStart:0 vertexCount:count];
		delete[] verts;
		break;
	}

	case 2: // kQAVertexMode_Polyline
	{
		if (nVertices < 2) break;
		RaveVertex *verts = new RaveVertex[nVertices];
		for (uint32 i = 0; i < nVertices; i++) {
			ConvertTextureVertex(verticesAddr + i * 64, &verts[i], perspZ, textureOp);
		}
		size_t dataSize = nVertices * sizeof(RaveVertex);
		if (dataSize > 4096) {
			id<MTLBuffer> buf = [ms->device newBufferWithBytes:verts length:dataSize options:MTLResourceStorageModeShared];
			[ms->currentEncoder setVertexBuffer:buf offset:0 atIndex:0];
		} else {
			[ms->currentEncoder setVertexBytes:verts length:dataSize atIndex:0];
		}
		[ms->currentEncoder drawPrimitives:MTLPrimitiveTypeLineStrip vertexStart:0 vertexCount:nVertices];
		delete[] verts;
		break;
	}

	case 3: // kQAVertexMode_Tri (triangle list)
	{
		uint32 nTris = nVertices / 3;
		if (nTris == 0) break;

		// kQATriFlags_Backfacing is a hint only (RAVE spec p.1566) -- do not cull.
		uint32 totalVerts = nTris * 3;
		RaveVertex *allVerts = new RaveVertex[totalVerts];
		for (uint32 i = 0; i < totalVerts; i++) {
			ConvertTextureVertex(verticesAddr + i * 64, &allVerts[i], perspZ, textureOp);
		}

		size_t dataSize = totalVerts * sizeof(RaveVertex);
		if (dataSize > 4096) {
			id<MTLBuffer> buf = [ms->device newBufferWithBytes:allVerts length:dataSize options:MTLResourceStorageModeShared];
			[ms->currentEncoder setVertexBuffer:buf offset:0 atIndex:0];
		} else {
			[ms->currentEncoder setVertexBytes:allVerts length:dataSize atIndex:0];
		}
		[ms->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:totalVerts];
		delete[] allVerts;
		break;
	}

	case 4: // kQAVertexMode_Strip
	{
		if (nVertices < 3) break;

		// kQATriFlags_Backfacing is a hint only -- do not cull.
		RaveVertex *allVerts = new RaveVertex[nVertices];
		for (uint32 i = 0; i < nVertices; i++) {
			ConvertTextureVertex(verticesAddr + i * 64, &allVerts[i], perspZ, textureOp);
		}

		size_t dataSize = nVertices * sizeof(RaveVertex);
		if (dataSize > 4096) {
			id<MTLBuffer> buf = [ms->device newBufferWithBytes:allVerts length:dataSize options:MTLResourceStorageModeShared];
			[ms->currentEncoder setVertexBuffer:buf offset:0 atIndex:0];
		} else {
			[ms->currentEncoder setVertexBytes:allVerts length:dataSize atIndex:0];
		}
		[ms->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:nVertices];
		delete[] allVerts;
		break;
	}

	case 5: // kQAVertexMode_Fan
	{
		if (nVertices < 3) break;
		uint32 nTris = nVertices - 2;

		// kQATriFlags_Backfacing is a hint only -- do not cull.
		// Metal has no triangle fan primitive, so expand to triangle list.
		RaveVertex *allVerts = new RaveVertex[nVertices];
		for (uint32 i = 0; i < nVertices; i++) {
			ConvertTextureVertex(verticesAddr + i * 64, &allVerts[i], perspZ, textureOp);
		}

		RaveVertex *expanded = new RaveVertex[nTris * 3];
		uint32 outIdx = 0;
		for (uint32 t = 0; t < nTris; t++) {
			expanded[outIdx++] = allVerts[0];
			expanded[outIdx++] = allVerts[t + 1];
			expanded[outIdx++] = allVerts[t + 2];
		}
		size_t dataSize = outIdx * sizeof(RaveVertex);
		if (dataSize > 4096) {
			id<MTLBuffer> buf = [ms->device newBufferWithBytes:expanded length:dataSize options:MTLResourceStorageModeShared];
			[ms->currentEncoder setVertexBuffer:buf offset:0 atIndex:0];
		} else {
			[ms->currentEncoder setVertexBytes:expanded length:dataSize atIndex:0];
		}
		[ms->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:outIdx];
		delete[] expanded;
		delete[] allVerts;
		break;
	}

	default:
		RAVE_LOG("DrawVTexture: unknown vertexMode %d", vertexMode);
		break;
	}

	return kQANoErr;
}


/*
 *  NativeSubmitVerticesTexture
 *
 *  SubmitVerticesTexture(drawContext, nVertices, vertices[])
 *  PPC args: r3=drawContextAddr, r4=nVertices, r5=verticesAddr
 *  Copies and byte-swaps textured vertices into per-context staging buffer.
 *  TQAVTexture is 64 bytes (16 floats) per vertex.
 */
int32 NativeSubmitVerticesTexture(uint32 drawContextAddr, uint32 nVertices, uint32 verticesAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv) return kQANoErr;

	if (nVertices > priv->vertexStagingCapacity) {
		RAVE_LOG("SubmitVerticesTexture: %d vertices exceeds capacity %d, clamping",
		         nVertices, priv->vertexStagingCapacity);
		nVertices = priv->vertexStagingCapacity;
	}

	bool perspZ = (priv->state[10].i != 0);
	int textureOp = (int)priv->state[12].i;
	RaveVertex *dst = (RaveVertex *)priv->vertexStagingBuffer;

	for (uint32 i = 0; i < nVertices; i++) {
		ConvertTextureVertex(verticesAddr + i * 64, &dst[i], perspZ, textureOp);
	}
	priv->vertexStagingCount = nVertices;

	// Diagnostic: dump vertex bounds for first 5 frames of each context
	if (priv->frameCount <= 10 && nVertices > 0) {
		float minX = dst[0].pos[0], maxX = dst[0].pos[0];
		float minY = dst[0].pos[1], maxY = dst[0].pos[1];
		float minZ = dst[0].pos[2], maxZ = dst[0].pos[2];
		float minA = dst[0].color[3], maxA = dst[0].color[3];
		float minU = dst[0].uv[0], maxU = dst[0].uv[0];
		float minV = dst[0].uv[1], maxV = dst[0].uv[1];
		float minW = dst[0].uv[2], maxW = dst[0].uv[2];
		for (uint32 i = 1; i < nVertices; i++) {
			if (dst[i].pos[0] < minX) minX = dst[i].pos[0];
			if (dst[i].pos[0] > maxX) maxX = dst[i].pos[0];
			if (dst[i].pos[1] < minY) minY = dst[i].pos[1];
			if (dst[i].pos[1] > maxY) maxY = dst[i].pos[1];
			if (dst[i].pos[2] < minZ) minZ = dst[i].pos[2];
			if (dst[i].pos[2] > maxZ) maxZ = dst[i].pos[2];
			if (dst[i].color[3] < minA) minA = dst[i].color[3];
			if (dst[i].color[3] > maxA) maxA = dst[i].color[3];
			if (dst[i].uv[0] < minU) minU = dst[i].uv[0];
			if (dst[i].uv[0] > maxU) maxU = dst[i].uv[0];
			if (dst[i].uv[1] < minV) minV = dst[i].uv[1];
			if (dst[i].uv[1] > maxV) maxV = dst[i].uv[1];
			if (dst[i].uv[2] < minW) minW = dst[i].uv[2];
			if (dst[i].uv[2] > maxW) maxW = dst[i].uv[2];
		}
		fprintf(stderr, "SubmitVTex: f=%u n=%u x=[%.1f,%.1f] y=[%.1f,%.1f] z=[%.3f,%.3f] a=[%.2f,%.2f] texOp=%d perspZ=%d\n",
		         priv->frameCount, nVertices,
		         minX, maxX, minY, maxY, minZ, maxZ, minA, maxA,
		         textureOp, perspZ ? 1 : 0);
		fprintf(stderr, "  UV: uOverW=[%.4f,%.4f] vOverW=[%.4f,%.4f] invW=[%.6f,%.6f]\n",
		         minU, maxU, minV, maxV, minW, maxW);
		// Dump first 3 vertices' raw UV data for inspection
		for (uint32 i = 0; i < 3 && i < nVertices; i++) {
			float rawU = ReadMacFloat(verticesAddr + i * 64 + 32);
			float rawV = ReadMacFloat(verticesAddr + i * 64 + 36);
			float rawInvW = ReadMacFloat(verticesAddr + i * 64 + 12);
			float finalU = (rawInvW != 0.0f) ? rawU / rawInvW : 0.0f;
			float finalV = (rawInvW != 0.0f) ? rawV / rawInvW : 0.0f;
			fprintf(stderr, "  v[%d]: uOverW=%.4f vOverW=%.4f invW=%.6f -> u=%.4f v=%.4f\n",
			         i, rawU, rawV, rawInvW, finalU, finalV);
		}
	}

	return kQANoErr;
}


/*
 *  NativeSubmitMultiTextureParams
 *
 *  SubmitMultiTextureVertex(drawContext, nVertices, multiTexParams[])
 *  PPC args: r3=drawContextAddr, r4=nVertices, r5=multiTexParamsAddr
 *
 *  RAVE 1.6 multi-texture extension. Receives per-vertex UV data for a
 *  second texture layer, stored in a parallel staging buffer alongside the
 *  primary vertex staging buffer. The struct layout is speculative based on
 *  the RAVE 1.6 DDK specification:
 *
 *  TQAVMultiTexture (12 bytes per vertex, per RAVE 1.6 spec):
 *    0: invW    (float) - inverse W for perspective correction
 *    4: uOverW  (float) - perspective-correct U for second texture
 *    8: vOverW  (float) - perspective-correct V for second texture
 *
 *  The texture handle for the second layer is set via kQATag_MultiTextureTexture
 *  (state tag) or passed as a separate parameter, NOT embedded in the per-vertex struct.
 */
int32 NativeSubmitMultiTextureParams(uint32 drawContextAddr, uint32 nVertices, uint32 multiTexParamsAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv) return kQANoErr;

	if (nVertices == 0 || multiTexParamsAddr == 0) return kQANoErr;

	// TQAVMultiTexture: 12 bytes per vertex (invW, uOverW, vOverW) per RAVE 1.6 spec
	static const uint32 kMultiTexStride = 12;

	// Cap to staging buffer capacity
	uint32 maxVerts = priv->vertexStagingCapacity;
	if (nVertices > maxVerts) nVertices = maxVerts;

	// Extract per-vertex UV2 data into multi-texture staging buffer
	// Staging buffer layout: 16 bytes per vertex (uOverW2, vOverW2, invW2, pad)
	float *dst = (float *)priv->multiTexStagingBuffer;

	for (uint32 i = 0; i < nVertices; i++) {
		uint32 srcAddr = multiTexParamsAddr + i * kMultiTexStride;
		float invW    = ReadMacFloat(srcAddr + 0);   // invW is FIRST in RAVE 1.6 spec
		float uOverW  = ReadMacFloat(srcAddr + 4);   // uOverW second
		float vOverW  = ReadMacFloat(srcAddr + 8);   // vOverW third

		// Store as (uOverW2, vOverW2, invW2, 0) for shader consumption
		// Flip V for Metal's top-left texture origin (same as primary UV path)
		dst[i * 4 + 0] = uOverW;
		dst[i * 4 + 1] = invW - vOverW;  // flip V
		dst[i * 4 + 2] = invW;
		dst[i * 4 + 3] = 0.0f;
	}

	priv->multiTexStagingCount = nVertices;
	priv->multiTextureActive = true;
	// Multi-texture texture pointer comes from kQATag_MultiTexture (tag 26, TQATagPtr) per RAVE.h,
	// set via QASetPtr(ctx, kQATag_MultiTexture, texture). Use existing handle if already set.
	if (priv->multiTextureHandle == 0) {
		priv->multiTextureHandle = priv->state[26].i;  // kQATag_MultiTexture = 26
	}
	priv->multiTextureOp = 0;       // default: Add (will be set by state tag if available)
	priv->multiTextureFactor = 0.5f; // default factor for Fixed mode

	RAVE_LOG("SubmitMultiTex: stored %u verts, texHandle=0x%08x", nVertices, priv->multiTextureHandle);

	return kQANoErr;
}


/*
 *  NativeDrawBitmap
 *
 *  DrawBitmap(drawContext, vertex, bitmap)
 *  PPC args: r3=drawContextAddr, r4=vertexAddr, r5=bitmapMacAddr
 *
 *  Renders a screen-aligned textured quad for 2D sprites and HUD elements.
 *  The single TQAVGouraud vertex (32 bytes) provides screen position (x,y) and alpha.
 *  The bitmap Mac address identifies the resource whose Metal texture is used.
 *  Depth test is disabled (z=0, ZFunction_Always) so HUD renders on top.
 */
int32 NativeDrawBitmap(uint32 drawContextAddr, uint32 vertexAddr, uint32 bitmapMacAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal || !priv->metal->renderPassActive) return kQANoErr;

	RaveMetalState *ms = priv->metal;

	// Look up bitmap resource by Mac address
	uint32_t bmpHandle = RaveResourceFindByAddr(bitmapMacAddr);
	if (bmpHandle == 0) {
		RAVE_LOG("DrawBitmap: bitmap not found at 0x%08x", bitmapMacAddr);
		return kQANoErr;
	}
	RaveResourceEntry *bmpEntry = RaveResourceGet(bmpHandle);
	if (!bmpEntry) {
		RAVE_LOG("DrawBitmap: bitmap not found (handle=%d)", bmpHandle);
		return kQANoErr;
	}
	if (!bmpEntry->metal_texture && bmpEntry->pixmap_mac_addr != 0) {
		RaveRealizeDeferredTexture(bmpEntry);
	}
	if (!bmpEntry->metal_texture) {
		RAVE_LOG("DrawBitmap: bitmap has no Metal texture (handle=%d)", bmpHandle);
		return kQANoErr;
	}

	// Read position and alpha from TQAVGouraud vertex (32 bytes)
	float x = ReadMacFloat(vertexAddr + 0);
	float y = ReadMacFloat(vertexAddr + 4);
	float alpha = ReadMacFloat(vertexAddr + 28);  // vertex alpha

	float w = (float)bmpEntry->width;
	float h = (float)bmpEntry->height;

	// Apply bitmap scale factors (tags 52 and 53, default 1.0)
	float scaleX = priv->state[52].f;
	float scaleY = priv->state[53].f;
	if (scaleX <= 0.0f) scaleX = 1.0f;  // guard against zero/negative
	if (scaleY <= 0.0f) scaleY = 1.0f;
	w *= scaleX;
	h *= scaleY;

	// Generate 6 vertices for screen-aligned quad (2 triangles)
	// Depth test disabled: z=0 (front), w=1
	// UV is simple 0-1 mapping, no perspective correction needed (invW=1)
	RaveVertex verts[6];

	// Triangle 1: top-left, top-right, bottom-left
	// v0: top-left (x, y)
	verts[0].pos[0] = x;     verts[0].pos[1] = y;
	verts[0].pos[2] = 0.0f;  verts[0].pos[3] = 1.0f;
	verts[0].color[0] = 1.0f; verts[0].color[1] = 1.0f;
	verts[0].color[2] = 1.0f; verts[0].color[3] = alpha;
	verts[0].uv[0] = 0.0f;  verts[0].uv[1] = 0.0f;
	verts[0].uv[2] = 1.0f;  verts[0].uv[3] = 0.0f;  // invW=1 for no perspective

	// v1: top-right (x+w, y)
	verts[1].pos[0] = x + w; verts[1].pos[1] = y;
	verts[1].pos[2] = 0.0f;  verts[1].pos[3] = 1.0f;
	verts[1].color[0] = 1.0f; verts[1].color[1] = 1.0f;
	verts[1].color[2] = 1.0f; verts[1].color[3] = alpha;
	verts[1].uv[0] = 1.0f;  verts[1].uv[1] = 0.0f;
	verts[1].uv[2] = 1.0f;  verts[1].uv[3] = 0.0f;

	// v2: bottom-left (x, y+h)
	verts[2].pos[0] = x;     verts[2].pos[1] = y + h;
	verts[2].pos[2] = 0.0f;  verts[2].pos[3] = 1.0f;
	verts[2].color[0] = 1.0f; verts[2].color[1] = 1.0f;
	verts[2].color[2] = 1.0f; verts[2].color[3] = alpha;
	verts[2].uv[0] = 0.0f;  verts[2].uv[1] = 1.0f;
	verts[2].uv[2] = 1.0f;  verts[2].uv[3] = 0.0f;

	// Triangle 2: top-right, bottom-right, bottom-left
	verts[3] = verts[1];  // top-right

	// v4: bottom-right (x+w, y+h)
	verts[4].pos[0] = x + w; verts[4].pos[1] = y + h;
	verts[4].pos[2] = 0.0f;  verts[4].pos[3] = 1.0f;
	verts[4].color[0] = 1.0f; verts[4].color[1] = 1.0f;
	verts[4].color[2] = 1.0f; verts[4].color[3] = alpha;
	verts[4].uv[0] = 1.0f;  verts[4].uv[1] = 1.0f;
	verts[4].uv[2] = 1.0f;  verts[4].uv[3] = 0.0f;

	verts[5] = verts[2];  // bottom-left

	// Select textured pipeline with current blend mode (default to Interpolate for bitmaps)
	int blend_mode = (int)priv->state[9].i;
	if (blend_mode < 0 || blend_mode > 2) blend_mode = 1;  // default Interpolate for bitmaps
	int pipe_idx = 1 + blend_mode * 16;  // has_texture=1

	id<MTLRenderPipelineState> __strong *pipeArray = ms->msaaActive ? ms->msaaPipelines : ms->pipelines;
	if (pipe_idx >= 0 && pipe_idx < 48 && pipeArray[pipe_idx]) {
		[ms->currentEncoder setRenderPipelineState:pipeArray[pipe_idx]];
	}

	// Disable depth test for bitmap (ZFunction_Always = 7, no depth writes)
	if (ms->depthStatesNoWrite[7]) {
		[ms->currentEncoder setDepthStencilState:ms->depthStatesNoWrite[7]];
	}

	// Bind bitmap texture directly (not from state[13])
	id<MTLTexture> bmpTex = (__bridge id<MTLTexture>)bmpEntry->metal_texture;
	[ms->currentEncoder setFragmentTexture:bmpTex atIndex:0];

	// Select sampler based on BitmapFilter (tag 54): 0=nearest, 1=bilinear, 2=trilinear
	int bmpFilter = (int)priv->state[54].i;
	if (bmpFilter < 0 || bmpFilter > 2) bmpFilter = 0;
	[ms->currentEncoder setFragmentSamplerState:ms->samplers[bmpFilter] atIndex:0];

	// Set fragment uniforms for bitmap -- TextureOp=None, no fog/alpha_test
	FragmentUniforms fragUniforms = {};
	fragUniforms.texture_op = 0;
	fragUniforms.fog_max_depth = 1.0f;
	[ms->currentEncoder setFragmentBytes:&fragUniforms length:sizeof(fragUniforms) atIndex:0];

	[ms->currentEncoder setVertexBytes:verts length:sizeof(verts) atIndex:0];
	[ms->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
	ms->drawCallCount++;
	ms->bitmapCount++;
	ms->triangleCount += 2;

	// Force pipeline re-selection on next draw (we changed pipeline/depth)
	ms->currentPipelineIdx = -1;
	priv->dirty_flags |= 1;  // force depth state re-application

	return kQANoErr;
}


/*
 *  NativeDrawTriMeshGouraud
 *
 *  DrawTriMeshGouraud(drawContext, numTriangles, triangles[])
 *  PPC args: r3=drawContextAddr, r4=numTriangles, r5=trianglesAddr
 *
 *  Indexed triangle mesh drawing using previously submitted Gouraud vertices.
 *  trianglesAddr points to an array of TQAIndexedTriangle structs (16 bytes each):
 *    offset 0: triangleFlags (uint32) - bit 0 = backfacing
 *    offset 4: vertices[3] (3 x uint32) - indices into staging buffer
 */
int32 NativeDrawTriMeshGouraud(uint32 drawContextAddr, uint32 numTriangles, uint32 trianglesAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal || !priv->metal->renderPassActive) return kQANoErr;
	if (numTriangles == 0 || priv->vertexStagingCount == 0) return kQANoErr;

	RaveMetalState *ms = priv->metal;
	RaveVertex *staged = (RaveVertex *)priv->vertexStagingBuffer;
	uint32 maxIdx = priv->vertexStagingCount;

	ApplyDirtyState(priv, false);

	// Build triangle list from indexed triangles
	// kQATriFlags_Backfacing (bit 0) is a hint only (RAVE spec p.1566) -- do not cull.
	// The QD3D IR handles backface culling before sending triangles to RAVE.
	RaveVertex *verts = new RaveVertex[numTriangles * 3];
	uint32 outIdx = 0;
	uint32 oobCount = 0;

	for (uint32 t = 0; t < numTriangles; t++) {
		uint32 triAddr = trianglesAddr + t * 16;
		// flags at offset 0 contain kQATriFlags_Backfacing hint -- ignored

		uint32 i0 = ReadMacInt32(triAddr + 4);
		uint32 i1 = ReadMacInt32(triAddr + 8);
		uint32 i2 = ReadMacInt32(triAddr + 12);

		// Bounds check indices
		if (i0 >= maxIdx || i1 >= maxIdx || i2 >= maxIdx) { oobCount++; continue; }

		verts[outIdx++] = staged[i0];
		verts[outIdx++] = staged[i1];
		verts[outIdx++] = staged[i2];
	}

	// Diagnostic: log draw state for first 5 frames of each context
	if (priv->frameCount <= 10) {
		// Dump first triangle's raw data for struct layout verification
		uint32 raw0 = 0, raw1 = 0, raw2 = 0, raw3 = 0;
		if (numTriangles > 0) {
			raw0 = ReadMacInt32(trianglesAddr + 0);
			raw1 = ReadMacInt32(trianglesAddr + 4);
			raw2 = ReadMacInt32(trianglesAddr + 8);
			raw3 = ReadMacInt32(trianglesAddr + 12);
		}
		RAVE_LOG("MeshGour: f=%u tris=%u/%u(oob=%u) staged=%u zfunc=%d blend=%d raw0=[%u,%u,%u,%u]",
		         priv->frameCount, outIdx / 3, numTriangles, oobCount,
		         priv->vertexStagingCount,
		         (int)priv->state[0].i, (int)priv->state[9].i,
		         raw0, raw1, raw2, raw3);
	}

	if (outIdx > 0) {
		size_t dataSize = outIdx * sizeof(RaveVertex);
		if (dataSize > 4096) {
			id<MTLBuffer> buf = [ms->device newBufferWithBytes:verts length:dataSize options:MTLResourceStorageModeShared];
			[ms->currentEncoder setVertexBuffer:buf offset:0 atIndex:0];
		} else {
			[ms->currentEncoder setVertexBytes:verts length:dataSize atIndex:0];
		}
		[ms->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:outIdx];
		ms->drawCallCount++;
		ms->triangleCount += outIdx / 3;
		ms->meshGouraudCount++;
	}

	delete[] verts;
	return kQANoErr;
}


/*
 *  NativeDrawTriMeshTexture
 *
 *  DrawTriMeshTexture(drawContext, numTriangles, triangles[])
 *  PPC args: r3=drawContextAddr, r4=numTriangles, r5=trianglesAddr
 *
 *  Indexed triangle mesh drawing using previously submitted textured vertices.
 *  Same TQAIndexedTriangle struct layout as Gouraud version.
 */
int32 NativeDrawTriMeshTexture(uint32 drawContextAddr, uint32 numTriangles, uint32 trianglesAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal || !priv->metal->renderPassActive) return kQANoErr;
	if (numTriangles == 0 || priv->vertexStagingCount == 0) return kQANoErr;

	RaveMetalState *ms = priv->metal;
	RaveVertex *staged = (RaveVertex *)priv->vertexStagingBuffer;
	uint32 maxIdx = priv->vertexStagingCount;

	ApplyDirtyState(priv, false, true);  // textured=true

	// Build triangle list from indexed triangles
	// kQATriFlags_Backfacing (bit 0) is a hint only (RAVE spec p.1566) -- do not cull.
	// The QD3D IR handles backface culling before sending triangles to RAVE.
	RaveVertex *verts = new RaveVertex[numTriangles * 3];
	uint32 outIdx = 0;
	uint32 oobCount = 0;

	for (uint32 t = 0; t < numTriangles; t++) {
		uint32 triAddr = trianglesAddr + t * 16;
		// flags at offset 0 contain kQATriFlags_Backfacing hint -- ignored

		uint32 i0 = ReadMacInt32(triAddr + 4);
		uint32 i1 = ReadMacInt32(triAddr + 8);
		uint32 i2 = ReadMacInt32(triAddr + 12);

		// Bounds check indices
		if (i0 >= maxIdx || i1 >= maxIdx || i2 >= maxIdx) { oobCount++; continue; }

		verts[outIdx++] = staged[i0];
		verts[outIdx++] = staged[i1];
		verts[outIdx++] = staged[i2];
	}

	// Diagnostic: log draw state for first 5 frames of each context
	if (priv->frameCount <= 10) {
		uint32 raw0 = 0, raw1 = 0, raw2 = 0, raw3 = 0;
		if (numTriangles > 0) {
			raw0 = ReadMacInt32(trianglesAddr + 0);
			raw1 = ReadMacInt32(trianglesAddr + 4);
			raw2 = ReadMacInt32(trianglesAddr + 8);
			raw3 = ReadMacInt32(trianglesAddr + 12);
		}
		RAVE_LOG("MeshTex: f=%u tris=%u/%u(oob=%u) staged=%u zfunc=%d blend=%d tex=0x%08x texOp=%d raw0=[%u,%u,%u,%u]",
		         priv->frameCount, outIdx / 3, numTriangles, oobCount,
		         priv->vertexStagingCount,
		         (int)priv->state[0].i, (int)priv->state[9].i,
		         priv->state[13].i, (int)priv->state[12].i,
		         raw0, raw1, raw2, raw3);
	}

	if (outIdx > 0) {
		size_t dataSize = outIdx * sizeof(RaveVertex);
		if (dataSize > 4096) {
			id<MTLBuffer> buf = [ms->device newBufferWithBytes:verts length:dataSize options:MTLResourceStorageModeShared];
			[ms->currentEncoder setVertexBuffer:buf offset:0 atIndex:0];
		} else {
			[ms->currentEncoder setVertexBytes:verts length:dataSize atIndex:0];
		}

		// Bind UV2 for multi-texture: build indexed UV2 from staging buffer
		if (priv->multiTextureActive && priv->multiTexStagingCount > 0) {
			float *uv2Staged = (float *)priv->multiTexStagingBuffer;
			float *uv2Indexed = new float[outIdx * 4];
			uint32 uv2Out = 0;
			for (uint32 t = 0; t < numTriangles; t++) {
				uint32 triAddr = trianglesAddr + t * 16;
				uint32 i0 = ReadMacInt32(triAddr + 4);
				uint32 i1 = ReadMacInt32(triAddr + 8);
				uint32 i2 = ReadMacInt32(triAddr + 12);
				if (i0 >= maxIdx || i1 >= maxIdx || i2 >= maxIdx) continue;
				for (int c = 0; c < 4; c++) uv2Indexed[uv2Out * 4 + c] = (i0 < priv->multiTexStagingCount) ? uv2Staged[i0 * 4 + c] : 0.0f;
				uv2Out++;
				for (int c = 0; c < 4; c++) uv2Indexed[uv2Out * 4 + c] = (i1 < priv->multiTexStagingCount) ? uv2Staged[i1 * 4 + c] : 0.0f;
				uv2Out++;
				for (int c = 0; c < 4; c++) uv2Indexed[uv2Out * 4 + c] = (i2 < priv->multiTexStagingCount) ? uv2Staged[i2 * 4 + c] : 0.0f;
				uv2Out++;
			}
			size_t uv2Size = uv2Out * 16;
			[ms->currentEncoder setVertexBytes:uv2Indexed length:uv2Size atIndex:3];
			delete[] uv2Indexed;
		}

		[ms->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:outIdx];
		ms->drawCallCount++;
		ms->triangleCount += outIdx / 3;
		ms->meshTextureCount++;
	}

	delete[] verts;
	return kQANoErr;
}


/*
 *  NativeDrawPoint
 *
 *  DrawPoint(drawContext, v0)
 *  PPC args: r3=drawContextAddr, r4=v0Addr
 */
int32 NativeDrawPoint(uint32 drawContextAddr, uint32 v0Addr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal || !priv->metal->renderPassActive) return kQANoErr;

	RaveMetalState *ms = priv->metal;
	bool perspZ = (priv->state[10].i != 0);

	RaveVertex vert;
	ConvertGouraudVertex(v0Addr, &vert, perspZ);

	ApplyDirtyState(priv, false);
	[ms->currentEncoder setVertexBytes:&vert length:sizeof(vert) atIndex:0];
	[ms->currentEncoder drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:1];
	ms->drawCallCount++;
	ms->pointCount++;

	return kQANoErr;
}


/*
 *  NativeDrawLine
 *
 *  DrawLine(drawContext, v0, v1)
 *  PPC args: r3=drawContextAddr, r4=v0Addr, r5=v1Addr
 *
 *  NOTE: Metal on iOS does not support line width > 1px.
 *  kQATag_Width is ignored for lines. No known QD3D game relies on wide lines.
 */
int32 NativeDrawLine(uint32 drawContextAddr, uint32 v0Addr, uint32 v1Addr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal || !priv->metal->renderPassActive) return kQANoErr;

	RaveMetalState *ms = priv->metal;
	bool perspZ = (priv->state[10].i != 0);

	RaveVertex verts[2];
	ConvertGouraudVertex(v0Addr, &verts[0], perspZ);
	ConvertGouraudVertex(v1Addr, &verts[1], perspZ);

	ApplyDirtyState(priv, false);
	[ms->currentEncoder setVertexBytes:verts length:sizeof(verts) atIndex:0];
	[ms->currentEncoder drawPrimitives:MTLPrimitiveTypeLine vertexStart:0 vertexCount:2];
	ms->drawCallCount++;
	ms->lineCount++;

	return kQANoErr;
}


/*
 *  Notice method storage, retrieval, and invocation
 *
 *  Notice methods are PPC callbacks registered by the application for
 *  compositing events. Selectors:
 *    0 = kQAMethod_RenderCompletion      -- after present
 *    1 = kQAMethod_DisplayModeChanged    -- not relevant on iOS
 *    2 = kQAMethod_ReloadTextures        -- not relevant
 *    3 = kQAMethod_ImageBufferInitialize -- at RenderStart
 *    4 = kQAMethod_ImageBuffer2DComposite -- during RenderEnd, before present
 */

int32_t NativeSetNoticeMethod(uint32_t drawContextAddr, uint32_t method,
                               uint32_t callback, uint32_t refCon)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv) return kQAError;
	if (method >= RAVE_NUM_NOTICE_METHODS) return kQAError;

	priv->noticeMethods[method].callback = callback;
	priv->noticeMethods[method].refCon = refCon;

	RAVE_LOG("SetNoticeMethod: selector=%d callback=0x%08x refCon=0x%08x",
	         method, callback, refCon);
	return kQANoErr;
}

int32_t NativeGetNoticeMethod(uint32_t drawContextAddr, uint32_t method,
                               uint32_t callbackOutPtr, uint32_t refConOutPtr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv) return kQAError;
	if (method >= RAVE_NUM_NOTICE_METHODS) return kQAError;

	if (callbackOutPtr != 0)
		WriteMacInt32(callbackOutPtr, priv->noticeMethods[method].callback);
	if (refConOutPtr != 0)
		WriteMacInt32(refConOutPtr, priv->noticeMethods[method].refCon);

	return kQANoErr;
}

static void FireNoticeMethod(RaveDrawPrivate *priv, int selector)
{
	if (selector >= RAVE_NUM_NOTICE_METHODS) return;
	uint32_t callback = priv->noticeMethods[selector].callback;
	if (callback == 0) return;

	uint32_t refCon = priv->noticeMethods[selector].refCon;

	if (selector == 3 || selector == 4) {
		// Buffer notice: TQABufferNoticeMethod(drawContext, buffer, dirtyRect, refCon)
		// Pass drawContextAddr as both drawContext and buffer (buffer IS the draw context per spec)
		// Pass 0 for dirtyRect (whole buffer dirty)
		call_macos4(callback, priv->drawContextAddr, priv->drawContextAddr, 0, refCon);
	} else {
		// Standard notice: TQAStandardNoticeMethod(drawContext, refCon)
		call_macos2(callback, priv->drawContextAddr, refCon);
	}

	RAVE_LOG("FireNoticeMethod: selector=%d callback=0x%08x", selector, callback);
}


/*
 *  NativeRenderStart
 *
 *  Creates a Metal render pass with clear color from state tags.
 *  PPC args: r3=drawContext, r4=dirtyRect, r5=initialContext
 */
int32 NativeRenderStart(uint32 drawContextAddr, uint32 dirtyRectAddr, uint32 initialContextAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal) {
		RAVE_LOG("RenderStart: invalid context 0x%08x", drawContextAddr);
		return kQAError;
	}

	RaveMetalState *ms = priv->metal;

	if (ms->renderPassActive) {
		RAVE_LOG("RenderStart: render pass already active, returning error");
		return kQAError;
	}

	// Get the compositor's offscreen overlay texture
	ms->overlayTexture = (__bridge id<MTLTexture>)MetalCompositorGetOverlayTexture();
	if (!ms->overlayTexture) {
		RAVE_LOG("NativeRenderStart: no overlay texture from compositor");
		return kQAError;
	}

	// Check if MSAA is requested
	// kQAAntialias_Fast (1) = default, no MSAA
	// kQAAntialias_Best (2) = 4x MSAA
	bool wantMSAA = (priv->state[8].i >= 2);

	if (wantMSAA) {
		EnsureMSAAResources(priv);
		ms->msaaActive = true;
	} else {
		ms->msaaActive = false;
	}

	// Build render pass descriptor
	MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];

	// Color attachment: clear to background color with alpha=1.0 (opaque).
	// The compositor uses MTLViewport set to the RAVE render rect to position
	// the overlay correctly, so 2D content outside the 3D viewport is visible.
	rpd.colorAttachments[0].clearColor = MTLClearColorMake(
		priv->state[2].f,  // red
		priv->state[3].f,  // green
		priv->state[4].f,  // blue
		1.0                // opaque — viewport positioning handles 2D visibility
	);
	rpd.colorAttachments[0].loadAction = MTLLoadActionClear;

	if (ms->msaaActive) {
		// MSAA: render to multisample texture, resolve to offscreen overlay
		rpd.colorAttachments[0].texture = ms->msaaColorTexture;
		rpd.colorAttachments[0].resolveTexture = ms->overlayTexture;
		rpd.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
	} else {
		rpd.colorAttachments[0].texture = ms->overlayTexture;
		rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
	}

	// Depth attachment (if depth buffer exists)
	if (!(priv->flags & kQAContext_NoZBuffer)) {
		id<MTLTexture> depthTex = (ms->msaaActive && ms->msaaDepthTexture) ? ms->msaaDepthTexture : ms->depthBuffer;
		if (depthTex) {
			rpd.depthAttachment.texture = depthTex;
			rpd.depthAttachment.loadAction = MTLLoadActionClear;
			rpd.depthAttachment.storeAction = MTLStoreActionDontCare;
			rpd.depthAttachment.clearDepth = 1.0;
		}
	}

	// Create command buffer and encoder
	ms->currentCommandBuffer = [ms->commandQueue commandBuffer];
	ms->currentEncoder = [ms->currentCommandBuffer renderCommandEncoderWithDescriptor:rpd];

	if (!ms->currentEncoder) {
		RAVE_LOG("RenderStart: failed to create render command encoder");
		ms->currentCommandBuffer = nil;
		return kQAError;
	}

	// Set scissor rect from context dimensions
	MTLScissorRect scissor;
	scissor.x = 0;
	scissor.y = 0;
	scissor.width = (NSUInteger)priv->width;
	scissor.height = (NSUInteger)priv->height;
	[ms->currentEncoder setScissorRect:scissor];

	// Set viewport to match context dimensions
	MTLViewport viewport;
	viewport.originX = 0.0;
	viewport.originY = 0.0;
	viewport.width = (double)priv->width;
	viewport.height = (double)priv->height;
	viewport.znear = 0.0;
	viewport.zfar = 1.0;
	[ms->currentEncoder setViewport:viewport];

	// Set viewport uniform for vertex shader (buffer index 1)
	RaveViewport vp = { (float)priv->width, (float)priv->height, 0.0f, 1.0f };
	[ms->currentEncoder setVertexBytes:&vp length:sizeof(vp) atIndex:1];

	// Set vertex uniforms (point width from kQATag_Width) at buffer(2)
	VertexUniforms vertUniforms;
	vertUniforms.point_width = priv->state[5].f;  // kQATag_Width
	if (vertUniforms.point_width < 1.0f) vertUniforms.point_width = 1.0f;
	[ms->currentEncoder setVertexBytes:&vertUniforms length:sizeof(vertUniforms) atIndex:2];

	// Set default depth stencil state based on ZFunction tag (state[0]) and ZBufferMask (state[28])
	{
		int zfunc = (int)priv->state[0].i;
		if (zfunc >= 0 && zfunc < 9) {
			bool depthWriteEnabled = (priv->state[28].i != 0);
			__strong id<MTLDepthStencilState> *dsArray = depthWriteEnabled ? ms->depthStates : ms->depthStatesNoWrite;
			if (dsArray[zfunc]) {
				[ms->currentEncoder setDepthStencilState:dsArray[zfunc]];
			}
		}
	}

	ms->renderPassActive = true;
	ms->currentPipelineIdx = -1;  // Force pipeline selection on first draw

	// Reset per-frame diagnostic counters
	ms->drawCallCount = 0;
	ms->triangleCount = 0;
	ms->triGouraudCount = 0;
	ms->triTextureCount = 0;
	ms->vGouraudCount = 0;
	ms->vTextureCount = 0;
	ms->meshGouraudCount = 0;
	ms->meshTextureCount = 0;
	ms->bitmapCount = 0;
	ms->pointCount = 0;
	ms->lineCount = 0;

	// Reset Z-sort buffer for this frame
	priv->zsortCount = 0;

	// Reset multi-texture state for this frame
	priv->multiTextureActive = false;
	priv->multiTexStagingCount = 0;

	// Increment frame counter for diagnostics
	priv->frameCount++;

	// Fire kQAMethod_ImageBufferInitialize (selector 3) callback
	FireNoticeMethod(priv, 3);

	// Update the compositor overlay viewport to match the actual RAVE render
	// dimensions. The overlay texture may be larger than the render viewport
	// (e.g. game resizes its viewport after context creation).
	MetalCompositorSetOverlayRect(priv->left, priv->top, priv->width, priv->height);

	RAVE_LOG("RenderStart: ctx=0x%08x clear=(%.2f,%.2f,%.2f,%.2f) size=%dx%d",
	         drawContextAddr,
	         priv->state[2].f, priv->state[3].f, priv->state[4].f, priv->state[1].f,
	         priv->width, priv->height);

	return kQANoErr;
}


/*
 *  NativeRenderEnd
 *
 *  Presents the Metal drawable showing the clear color.
 *  PPC args: r3=drawContext, r4=modifiedRect
 */
int32 NativeRenderEnd(uint32 drawContextAddr, uint32 modifiedRectAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal) return kQANoErr;

	RaveMetalState *ms = priv->metal;

	if (!ms->renderPassActive) return kQANoErr;

	// Flush Z-sorted transparent triangles (back-to-front)
	FlushZSortBuffer(priv);

	// Fire kQAMethod_ImageBuffer2DComposite (selector 4) before ending the render pass.
	// This fires while the encoder is still active so the app can submit 2D overlay
	// draw commands (menus, HUD) if it uses Metal.
	FireNoticeMethod(priv, 4);

	[ms->currentEncoder endEncoding];

	// GAP-018: Blit offscreen overlay content to RTT textures
	if (!ms->rttTextureHandles.empty() && ms->overlayTexture) {
		id<MTLBlitCommandEncoder> blit = [ms->currentCommandBuffer blitCommandEncoder];
		id<MTLTexture> srcTex = ms->overlayTexture;
		NSUInteger w = srcTex.width;
		NSUInteger h = srcTex.height;
		for (uint32_t rttHandle : ms->rttTextureHandles) {
			RaveResourceEntry *entry = RaveResourceGet(rttHandle);
			if (entry && entry->metal_texture) {
				id<MTLTexture> rttTex = (__bridge id<MTLTexture>)entry->metal_texture;
				[blit copyFromTexture:srcTex
				          sourceSlice:0 sourceLevel:0
				         sourceOrigin:MTLOriginMake(0, 0, 0)
				           sourceSize:MTLSizeMake(w, h, 1)
				            toTexture:rttTex
				     destinationSlice:0 destinationLevel:0
				    destinationOrigin:MTLOriginMake(0, 0, 0)];
			}
		}
		[blit endEncoding];
	}

	// DontSwap: with offscreen texture, the rendered content persists regardless.
	// DontSwap just controls whether we log "committed" vs "frame complete".
	// No presentDrawable — the compositor reads the offscreen texture on its next VBL.
	int32_t dont_swap = (int32_t)priv->state[32].i;

	[ms->currentCommandBuffer commit];

	ms->lastCommittedBuffer = ms->currentCommandBuffer;
	ms->currentEncoder = nil;
	ms->currentCommandBuffer = nil;
	ms->renderPassActive = false;

	// Write modified rect to Mac memory if requested
	if (modifiedRectAddr != 0) {
		WriteMacInt32(modifiedRectAddr + 0,  (uint32)priv->left);
		WriteMacInt32(modifiedRectAddr + 4,  (uint32)priv->top);
		WriteMacInt32(modifiedRectAddr + 8,  (uint32)(priv->left + priv->width));
		WriteMacInt32(modifiedRectAddr + 12, (uint32)(priv->top + priv->height));
	}

	// Fire kQAMethod_RenderCompletion (selector 0) after present/commit
	FireNoticeMethod(priv, 0);

	if (rave_logging_enabled) {
		RAVE_LOG("RenderEnd: ctx=0x%08x draws=%u tris=%u [tG=%u tT=%u vG=%u vT=%u mG=%u mT=%u bm=%u pt=%u ln=%u] %s",
		         drawContextAddr, ms->drawCallCount, ms->triangleCount,
		         ms->triGouraudCount, ms->triTextureCount,
		         ms->vGouraudCount, ms->vTextureCount,
		         ms->meshGouraudCount, ms->meshTextureCount,
		         ms->bitmapCount, ms->pointCount, ms->lineCount,
		         dont_swap ? "committed (DontSwap)" : "frame committed to offscreen");
	}

	// Throttle to VBL cadence — prevent 3D from outrunning the compositor
	MetalCompositorSync3DFramePacing();

	return kQANoErr;
}


/*
 *  NativeSwapBuffers
 *
 *  Explicitly presents the held drawable from a DontSwap RenderEnd.
 *  If no drawable is held (DontSwap was not set), this is a no-op.
 *  GAP-019: dirtyRect parameter intentionally ignored -- Metal always presents full drawable;
 *  partial present is not supported by the Metal API
 *  PPC args: r3=drawContextAddr
 */
int32 NativeSwapBuffers(uint32 drawContextAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal) return kQANoErr;

	// With offscreen texture rendering, the rendered content persists and
	// the compositor reads it on every VBL. SwapBuffers is effectively a no-op.
	RAVE_LOG("SwapBuffers: ctx=0x%08x no-op (offscreen texture persists)", drawContextAddr);
	return kQANoErr;
}


/*
 *  NativeBusy
 *
 *  Returns whether the engine has uncommitted/in-flight command buffers.
 *  Returns 1 (busy) if the last committed buffer has not completed, 0 (idle) otherwise.
 *  PPC args: r3=drawContextAddr
 */
int32 NativeBusy(uint32 drawContextAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal) return 0;

	RaveMetalState *ms = priv->metal;

	if (!ms->lastCommittedBuffer) return 0;

	MTLCommandBufferStatus status = [ms->lastCommittedBuffer status];
	return (status != MTLCommandBufferStatusCompleted &&
	        status != MTLCommandBufferStatusError) ? 1 : 0;
}


/*
 *  NativeTextureNewFromDrawContext
 *
 *  Creates an offscreen render target (MTLTexture) at the draw context's
 *  dimensions, usable as a texture resource for render-to-texture passes.
 *  PPC args: r3=drawContextAddr
 *  Returns: Mac address of new texture resource (TQATexture*)
 *
 *  GAP-017: The RAVE 1.6 spec includes a flags parameter (Lock/Mipmap bits)
 *  in TQATextureNewFromDrawContext. These flags are not meaningful for
 *  render-to-texture -- Metal manages GPU memory directly, and RTT textures
 *  don't need client-side locking or mipmaps. Intentionally ignored per spec
 *  flexibility. The PPC thunk passes only drawContextAddr (r3).
 */
uint32 NativeTextureNewFromDrawContext(uint32 drawContextAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal) return 0;

	RaveMetalState *ms = priv->metal;
	id<MTLDevice> device = ms->device;
	if (!device) return 0;

	uint32_t w = (uint32_t)priv->width;
	uint32_t h = (uint32_t)priv->height;

	// Allocate resource table entry
	uint32_t handle = RaveResourceAlloc(kRaveResourceTexture);
	if (handle == 0) return 0;
	RaveResourceEntry *entry = RaveResourceGet(handle);

	// Create MTLTexture for render-to-texture with shader read capability
	MTLTextureDescriptor *desc = [MTLTextureDescriptor
		texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		                            width:w
		                           height:h
		                        mipmapped:NO];
	desc.storageMode = MTLStorageModePrivate;
	desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;

	id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
	if (!texture) {
		RaveResourceFree(handle);
		RAVE_LOG("TextureNewFromDrawContext: failed to create %dx%d texture", w, h);
		return 0;
	}

	// Create matching depth texture for RTT passes
	MTLTextureDescriptor *depthDesc = [MTLTextureDescriptor
		texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
		                            width:w
		                           height:h
		                        mipmapped:NO];
	depthDesc.storageMode = MTLStorageModePrivate;
	depthDesc.usage = MTLTextureUsageRenderTarget;
	// Depth texture stored separately -- not needed in resource entry

	entry->metal_texture = (__bridge_retained void *)texture;
	entry->pixel_type = 4;  // kQAPixel_ARGB32
	entry->width = w;
	entry->height = h;
	entry->mip_levels = 1;
	entry->row_bytes = w * 4;

	// Allocate CPU pixel buffer for AccessTexture support
	uint32_t cpuBufSize = w * h * 4;
	uint32_t cpuMacAddr = Mac_sysalloc(cpuBufSize);
	if (cpuMacAddr != 0) {
		entry->cpu_pixel_mac_addr = cpuMacAddr;
		entry->cpu_pixel_data = Mac2HostAddr(cpuMacAddr);
		entry->cpu_pixel_data_size = cpuBufSize;
	}

	priv->metal->rttTextureHandles.push_back(handle);

	RAVE_LOG("TextureNewFromDrawContext: %dx%d handle=%d mac=0x%08x",
	         w, h, handle, entry->mac_addr);
	return entry->mac_addr;
}


/*
 *  NativeBitmapNewFromDrawContext
 *
 *  Creates an offscreen render target usable as a bitmap resource.
 *  Same as TextureNewFromDrawContext but single mip level and bitmap type.
 *  PPC args: r3=drawContextAddr
 *  Returns: Mac address of new bitmap resource (TQABitmap*)
 */
uint32 NativeBitmapNewFromDrawContext(uint32 drawContextAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal) return 0;

	RaveMetalState *ms = priv->metal;
	id<MTLDevice> device = ms->device;
	if (!device) return 0;

	uint32_t w = (uint32_t)priv->width;
	uint32_t h = (uint32_t)priv->height;

	// Allocate resource table entry as bitmap
	uint32_t handle = RaveResourceAlloc(kRaveResourceBitmap);
	if (handle == 0) return 0;
	RaveResourceEntry *entry = RaveResourceGet(handle);

	// Create MTLTexture -- no depth needed for bitmaps
	MTLTextureDescriptor *desc = [MTLTextureDescriptor
		texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		                            width:w
		                           height:h
		                        mipmapped:NO];
	desc.storageMode = MTLStorageModePrivate;
	desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;

	id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
	if (!texture) {
		RaveResourceFree(handle);
		RAVE_LOG("BitmapNewFromDrawContext: failed to create %dx%d texture", w, h);
		return 0;
	}

	entry->metal_texture = (__bridge_retained void *)texture;
	entry->pixel_type = 4;  // kQAPixel_ARGB32
	entry->width = w;
	entry->height = h;
	entry->mip_levels = 1;
	entry->row_bytes = w * 4;

	// Allocate CPU pixel buffer for AccessBitmap support
	uint32_t cpuBufSize = w * h * 4;
	uint32_t cpuMacAddr = Mac_sysalloc(cpuBufSize);
	if (cpuMacAddr != 0) {
		entry->cpu_pixel_mac_addr = cpuMacAddr;
		entry->cpu_pixel_data = Mac2HostAddr(cpuMacAddr);
		entry->cpu_pixel_data_size = cpuBufSize;
	}

	priv->metal->rttTextureHandles.push_back(handle);

	RAVE_LOG("BitmapNewFromDrawContext: %dx%d handle=%d mac=0x%08x",
	         w, h, handle, entry->mac_addr);
	return entry->mac_addr;
}


/*
 *  NativeRenderAbort
 *
 *  Discards the in-progress command buffer and logs a warning.
 *  PPC args: r3=drawContext
 */
int32 NativeRenderAbort(uint32 drawContextAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal) return kQANoErr;

	RaveMetalState *ms = priv->metal;

	if (!ms->renderPassActive) return kQANoErr;

	[ms->currentEncoder endEncoding];
	// Must commit even on abort per Metal rules
	[ms->currentCommandBuffer commit];

	ms->currentEncoder = nil;
	ms->currentCommandBuffer = nil;
	ms->renderPassActive = false;

	RAVE_LOG("RenderAbort: ctx=0x%08x render pass aborted", drawContextAddr);

	return kQANoErr;
}


/*
 *  NativeFlush
 *
 *  Mid-frame commit: ends the current encoder, commits the command buffer
 *  (non-blocking), then starts a new command buffer and encoder so the CPU
 *  can continue encoding while the GPU processes earlier work.
 *
 *  The drawable is NOT presented here -- presentation happens only in RenderEnd.
 *  The new encoder uses MTLLoadActionLoad to preserve existing framebuffer content.
 *
 *  PPC args: r3=drawContext
 */
int32 NativeFlush(uint32 drawContextAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal) return kQANoErr;

	RaveMetalState *ms = priv->metal;

	if (!ms->renderPassActive || !ms->currentEncoder) {
		// Nothing to flush if no render pass is active
		return kQANoErr;
	}

	// End current encoder and commit (non-blocking, no present)
	[ms->currentEncoder endEncoding];
	[ms->currentCommandBuffer commit];
	ms->lastCommittedBuffer = ms->currentCommandBuffer;

	// Create new command buffer to continue encoding
	ms->currentCommandBuffer = [ms->commandQueue commandBuffer];

	// Build render pass descriptor with LoadActionLoad to preserve content
	MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];

	if (ms->msaaActive && ms->msaaColorTexture) {
		rpd.colorAttachments[0].texture = ms->msaaColorTexture;
		rpd.colorAttachments[0].resolveTexture = ms->overlayTexture;
		rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
		rpd.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
	} else {
		rpd.colorAttachments[0].texture = ms->overlayTexture;
		rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
		rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
	}

	if (!(priv->flags & kQAContext_NoZBuffer)) {
		id<MTLTexture> depthTex = (ms->msaaActive && ms->msaaDepthTexture) ? ms->msaaDepthTexture : ms->depthBuffer;
		if (depthTex) {
			rpd.depthAttachment.texture = depthTex;
			rpd.depthAttachment.loadAction = MTLLoadActionLoad;
			rpd.depthAttachment.storeAction = MTLStoreActionDontCare;
		}
	}

	ms->currentEncoder = [ms->currentCommandBuffer renderCommandEncoderWithDescriptor:rpd];

	if (!ms->currentEncoder) {
		RAVE_LOG("Flush: failed to create continuation encoder");
		ms->currentCommandBuffer = nil;
		ms->renderPassActive = false;
		return kQAError;
	}

	// Restore viewport and scissor on the new encoder
	MTLScissorRect scissor;
	scissor.x = 0;
	scissor.y = 0;
	scissor.width = (NSUInteger)priv->width;
	scissor.height = (NSUInteger)priv->height;
	[ms->currentEncoder setScissorRect:scissor];

	MTLViewport viewport;
	viewport.originX = 0.0;
	viewport.originY = 0.0;
	viewport.width = (double)priv->width;
	viewport.height = (double)priv->height;
	viewport.znear = 0.0;
	viewport.zfar = 1.0;
	[ms->currentEncoder setViewport:viewport];

	// Restore viewport uniform for vertex shader (buffer index 1)
	RaveViewport vp = { (float)priv->width, (float)priv->height, 0.0f, 1.0f };
	[ms->currentEncoder setVertexBytes:&vp length:sizeof(vp) atIndex:1];

	// Restore vertex uniforms (point width) at buffer(2)
	VertexUniforms vertUniforms;
	vertUniforms.point_width = priv->state[5].f;  // kQATag_Width
	if (vertUniforms.point_width < 1.0f) vertUniforms.point_width = 1.0f;
	[ms->currentEncoder setVertexBytes:&vertUniforms length:sizeof(vertUniforms) atIndex:2];

	// Force pipeline re-bind on next draw after flush
	ms->currentPipelineIdx = -1;

	// Restore depth stencil state (respecting ZBufferMask)
	{
		int zfunc = (int)priv->state[0].i;
		if (zfunc >= 0 && zfunc < 9) {
			bool depthWriteEnabled = (priv->state[28].i != 0);
			__strong id<MTLDepthStencilState> *dsArray = depthWriteEnabled ? ms->depthStates : ms->depthStatesNoWrite;
			if (dsArray[zfunc]) {
				[ms->currentEncoder setDepthStencilState:dsArray[zfunc]];
			}
		}
	}

	RAVE_LOG("Flush: ctx=0x%08x mid-frame commit, new encoder started", drawContextAddr);

	return kQANoErr;
}


/*
 *  NativeSync
 *
 *  Blocks until all GPU work is complete.
 *  PPC args: r3=drawContext
 *
 *  Handles both mid-frame and post-frame states:
 *  - Mid-frame (renderPassActive): flush current work via NativeFlush (which
 *    commits the buffer and starts a new encoder), then wait on the committed buffer.
 *  - Post-frame (!renderPassActive): wait on lastCommittedBuffer if available.
 */
int32 NativeSync(uint32 drawContextAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal) return kQANoErr;

	RaveMetalState *ms = priv->metal;

	if (ms->renderPassActive) {
		// Mid-frame sync: flush to commit current work, then wait on it
		// NativeFlush saves the committed buffer in lastCommittedBuffer
		int32 flushResult = NativeFlush(drawContextAddr);
		if (flushResult != kQANoErr) {
			RAVE_LOG("Sync: flush failed during mid-frame sync");
			return flushResult;
		}
		// Now wait on the buffer that was just committed by Flush
		if (ms->lastCommittedBuffer) {
			[ms->lastCommittedBuffer waitUntilCompleted];
			RAVE_LOG("Sync: ctx=0x%08x mid-frame wait completed", drawContextAddr);
		}
	} else {
		// Post-frame sync: wait on the most recently committed buffer
		if (ms->lastCommittedBuffer) {
			[ms->lastCommittedBuffer waitUntilCompleted];
			RAVE_LOG("Sync: ctx=0x%08x post-frame wait completed", drawContextAddr);
		}
	}

	return kQANoErr;
}


/*
 *  Metal texture creation/upload functions
 *
 *  Called from rave_engine.cpp (C++ code) to create ObjC Metal objects.
 *  Use void* to cross the ObjC++/C++ language boundary.
 */

/*
 *  Helper: restart render pass with LoadActionLoad (preserves existing content).
 *  Used after AccessDrawBufferEnd and AccessZBufferEnd to continue rendering.
 */
static int32_t RestartRenderPassWithLoad(RaveDrawPrivate *priv)
{
	RaveMetalState *ms = priv->metal;
	ms->currentCommandBuffer = [ms->commandQueue commandBuffer];
	MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
	if (ms->msaaActive && ms->msaaColorTexture) {
		rpd.colorAttachments[0].texture = ms->msaaColorTexture;
		rpd.colorAttachments[0].resolveTexture = ms->overlayTexture;
		rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
		rpd.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
	} else {
		rpd.colorAttachments[0].texture = ms->overlayTexture;
		rpd.colorAttachments[0].loadAction = MTLLoadActionLoad;
		rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
	}
	if (!(priv->flags & kQAContext_NoZBuffer)) {
		id<MTLTexture> depthTex = (ms->msaaActive && ms->msaaDepthTexture) ? ms->msaaDepthTexture : ms->depthBuffer;
		if (depthTex) {
			rpd.depthAttachment.texture = depthTex;
			rpd.depthAttachment.loadAction = MTLLoadActionLoad;
			rpd.depthAttachment.storeAction = MTLStoreActionDontCare;
		}
	}
	ms->currentEncoder = [ms->currentCommandBuffer renderCommandEncoderWithDescriptor:rpd];
	if (!ms->currentEncoder) {
		RAVE_LOG("RestartRenderPassWithLoad: failed to create encoder");
		ms->currentCommandBuffer = nil;
		ms->renderPassActive = false;
		return kQAError;
	}
	MTLScissorRect scissor;
	scissor.x = 0; scissor.y = 0;
	scissor.width = (NSUInteger)priv->width;
	scissor.height = (NSUInteger)priv->height;
	[ms->currentEncoder setScissorRect:scissor];
	MTLViewport viewport;
	viewport.originX = 0.0; viewport.originY = 0.0;
	viewport.width = (double)priv->width; viewport.height = (double)priv->height;
	viewport.znear = 0.0; viewport.zfar = 1.0;
	[ms->currentEncoder setViewport:viewport];
	RaveViewport vp = { (float)priv->width, (float)priv->height, 0.0f, 1.0f };
	[ms->currentEncoder setVertexBytes:&vp length:sizeof(vp) atIndex:1];
	VertexUniforms vertUniforms;
	vertUniforms.point_width = priv->state[5].f;
	if (vertUniforms.point_width < 1.0f) vertUniforms.point_width = 1.0f;
	[ms->currentEncoder setVertexBytes:&vertUniforms length:sizeof(vertUniforms) atIndex:2];
	ms->currentPipelineIdx = -1;
	{
		int zfunc = (int)priv->state[0].i;
		if (zfunc >= 0 && zfunc < 9) {
			bool depthWriteEnabled = (priv->state[28].i != 0);
			__strong id<MTLDepthStencilState> *dsArray = depthWriteEnabled ? ms->depthStates : ms->depthStatesNoWrite;
			if (dsArray[zfunc])
				[ms->currentEncoder setDepthStencilState:dsArray[zfunc]];
		}
	}
	return kQANoErr;
}


/*
 *  SDK: TQAError AccessDrawBuffer(const TQADrawContext*, TQAPixelBuffer*)
 *  TQAPixelBuffer = TQADeviceMemory = {rowBytes(+0), pixelType(+4), width(+8), height(+12), baseAddr(+16)}
 *  Populates the TQAPixelBuffer struct at bufferStructAddr with draw buffer info.
 */
int32_t NativeAccessDrawBuffer(uint32_t drawContextAddr, uint32_t bufferStructAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal) return kQAError;
	RaveMetalState *ms = priv->metal;
	if (!ms->renderPassActive || !ms->overlayTexture) return kQAError;
	if (ms->currentEncoder) {
		[ms->currentEncoder endEncoding];
		ms->currentEncoder = nil;
	}
	id<MTLTexture> drawableTexture = ms->overlayTexture;
	NSUInteger w = drawableTexture.width;
	NSUInteger h = drawableTexture.height;
	if (!ms->stagingDrawBuffer ||
	    ms->stagingDrawBuffer.width != w || ms->stagingDrawBuffer.height != h) {
		MTLTextureDescriptor *desc = [MTLTextureDescriptor
			texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
			                            width:w height:h mipmapped:NO];
		desc.storageMode = MTLStorageModeShared;
		desc.usage = MTLTextureUsageShaderRead;
		ms->stagingDrawBuffer = [ms->device newTextureWithDescriptor:desc];
	}
	uint32_t rowBytes = (uint32_t)(w * 4);
	uint32_t bufSize = rowBytes * (uint32_t)h;
	if (!ms->drawBufferCPU || ms->drawBufferCPUSize != bufSize) {
		uint32_t macAddr = Mac_sysalloc(bufSize);
		if (macAddr == 0) return kQAError;
		ms->drawBufferCPU = Mac2HostAddr(macAddr);
		ms->drawBufferCPUMac = macAddr;
		ms->drawBufferCPUSize = bufSize;
	}
	id<MTLCommandBuffer> blitCmdBuf = [ms->commandQueue commandBuffer];
	id<MTLBlitCommandEncoder> blit = [blitCmdBuf blitCommandEncoder];
	[blit copyFromTexture:drawableTexture sourceSlice:0 sourceLevel:0
	         sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(w,h,1)
	            toTexture:ms->stagingDrawBuffer destinationSlice:0
	     destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
	[blit endEncoding];
	[blitCmdBuf commit];
	[blitCmdBuf waitUntilCompleted];
	[ms->stagingDrawBuffer getBytes:ms->drawBufferCPU bytesPerRow:rowBytes
	                     fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
	// Populate TQAPixelBuffer (TQADeviceMemory) struct
	WriteMacInt32(bufferStructAddr + 0,  rowBytes);
	WriteMacInt32(bufferStructAddr + 4,  4 /* kQAPixel_ARGB32 */);
	WriteMacInt32(bufferStructAddr + 8,  (uint32_t)w);
	WriteMacInt32(bufferStructAddr + 12, (uint32_t)h);
	WriteMacInt32(bufferStructAddr + 16, ms->drawBufferCPUMac);
	ms->drawBufferAccessed = true;
	ms->currentCommandBuffer = [ms->commandQueue commandBuffer];
	RAVE_LOG("AccessDrawBuffer: ctx=0x%08x %lux%lu buf=0x%08x rowBytes=%d",
	         drawContextAddr, (unsigned long)w, (unsigned long)h, ms->drawBufferCPUMac, rowBytes);
	return kQANoErr;
}


int32_t NativeAccessDrawBufferEnd(uint32_t drawContextAddr, uint32_t dirtyRectAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal) return kQAError;
	RaveMetalState *ms = priv->metal;
	if (!ms->drawBufferAccessed) return kQANoErr;
	id<MTLTexture> drawableTexture = ms->overlayTexture;
	NSUInteger w = drawableTexture.width;
	NSUInteger h = drawableTexture.height;
	uint32_t rowBytes = (uint32_t)(w * 4);

	// GAP-021: Use dirtyRect to limit upload region when provided
	NSUInteger uploadX = 0, uploadY = 0, uploadW = w, uploadH = h;
	if (dirtyRectAddr != 0) {
		// RAVE dirtyRect: top(int16), left(int16), bottom(int16), right(int16) -- Rect format
		int16_t dTop    = (int16_t)ReadMacInt16(dirtyRectAddr + 0);
		int16_t dLeft   = (int16_t)ReadMacInt16(dirtyRectAddr + 2);
		int16_t dBottom = (int16_t)ReadMacInt16(dirtyRectAddr + 4);
		int16_t dRight  = (int16_t)ReadMacInt16(dirtyRectAddr + 6);
		// Clamp to texture bounds
		if (dLeft < 0) dLeft = 0;
		if (dTop < 0) dTop = 0;
		if ((NSUInteger)dRight > w) dRight = (int16_t)w;
		if ((NSUInteger)dBottom > h) dBottom = (int16_t)h;
		if (dRight > dLeft && dBottom > dTop) {
			uploadX = (NSUInteger)dLeft;
			uploadY = (NSUInteger)dTop;
			uploadW = (NSUInteger)(dRight - dLeft);
			uploadH = (NSUInteger)(dBottom - dTop);
			RAVE_LOG("AccessDrawBufferEnd: using dirtyRect (%d,%d,%d,%d)", dTop, dLeft, dBottom, dRight);
		}
	}

	// Upload only the dirty region (or full buffer if no dirtyRect)
	const uint8_t *srcBytes = (const uint8_t *)ms->drawBufferCPU + uploadY * rowBytes + uploadX * 4;
	[ms->stagingDrawBuffer replaceRegion:MTLRegionMake2D(uploadX, uploadY, uploadW, uploadH)
	                         mipmapLevel:0 withBytes:srcBytes
	                         bytesPerRow:rowBytes];
	id<MTLCommandBuffer> blitCmdBuf = [ms->commandQueue commandBuffer];
	id<MTLBlitCommandEncoder> blit = [blitCmdBuf blitCommandEncoder];
	[blit copyFromTexture:ms->stagingDrawBuffer sourceSlice:0 sourceLevel:0
	         sourceOrigin:MTLOriginMake(uploadX, uploadY, 0) sourceSize:MTLSizeMake(uploadW, uploadH, 1)
	            toTexture:drawableTexture destinationSlice:0
	     destinationLevel:0 destinationOrigin:MTLOriginMake(uploadX, uploadY, 0)];
	[blit endEncoding];
	[blitCmdBuf commit];
	[blitCmdBuf waitUntilCompleted];
	ms->drawBufferAccessed = false;
	int32_t result = RestartRenderPassWithLoad(priv);
	RAVE_LOG("AccessDrawBufferEnd: ctx=0x%08x uploaded region (%lu,%lu %lux%lu), render pass restarted",
	         drawContextAddr, (unsigned long)uploadX, (unsigned long)uploadY,
	         (unsigned long)uploadW, (unsigned long)uploadH);
	return result;
}


/*
 *  SDK: TQAError AccessZBuffer(const TQADrawContext*, TQAZBuffer*)
 *  TQAZBuffer = {width(+0), height(+4), rowBytes(+8), zbuffer(+12), zDepth(+16), isBigEndian(+20)}
 *  Populates the TQAZBuffer struct at bufferStructAddr with Z buffer info.
 */
int32_t NativeAccessZBuffer(uint32_t drawContextAddr, uint32_t bufferStructAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal) return kQAError;
	RaveMetalState *ms = priv->metal;
	if (!ms->renderPassActive || !ms->depthBuffer) return kQAError;
	if (ms->currentEncoder) {
		[ms->currentEncoder endEncoding];
		ms->currentEncoder = nil;
	}
	NSUInteger w = ms->depthBuffer.width;
	NSUInteger h = ms->depthBuffer.height;
	if (!ms->stagingZBuffer ||
	    ms->stagingZBuffer.width != w || ms->stagingZBuffer.height != h) {
		MTLTextureDescriptor *desc = [MTLTextureDescriptor
			texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
			                            width:w height:h mipmapped:NO];
		desc.storageMode = MTLStorageModeShared;
		desc.usage = MTLTextureUsageShaderRead;
		ms->stagingZBuffer = [ms->device newTextureWithDescriptor:desc];
	}
	uint32_t rowBytes = (uint32_t)(w * 4);
	uint32_t bufSize = rowBytes * (uint32_t)h;
	if (!ms->zBufferCPU || ms->zBufferCPUSize != bufSize) {
		uint32_t macAddr = Mac_sysalloc(bufSize);
		if (macAddr == 0) return kQAError;
		ms->zBufferCPU = Mac2HostAddr(macAddr);
		ms->zBufferCPUMac = macAddr;
		ms->zBufferCPUSize = bufSize;
	}
	id<MTLCommandBuffer> blitCmdBuf = [ms->commandQueue commandBuffer];
	id<MTLBlitCommandEncoder> blit = [blitCmdBuf blitCommandEncoder];
	[blit copyFromTexture:ms->depthBuffer sourceSlice:0 sourceLevel:0
	         sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(w,h,1)
	            toTexture:ms->stagingZBuffer destinationSlice:0
	     destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
	[blit endEncoding];
	[blitCmdBuf commit];
	[blitCmdBuf waitUntilCompleted];
	[ms->stagingZBuffer getBytes:ms->zBufferCPU bytesPerRow:rowBytes
	                  fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
	// Populate TQAZBuffer struct
	WriteMacInt32(bufferStructAddr + 0,  (uint32_t)w);       // width
	WriteMacInt32(bufferStructAddr + 4,  (uint32_t)h);       // height
	WriteMacInt32(bufferStructAddr + 8,  rowBytes);           // rowBytes
	WriteMacInt32(bufferStructAddr + 12, ms->zBufferCPUMac);  // zbuffer pointer
	WriteMacInt32(bufferStructAddr + 16, 32);                  // zDepth (32-bit float)
	WriteMacInt32(bufferStructAddr + 20, 1);                   // isBigEndian (PPC = big-endian)
	ms->zBufferAccessed = true;
	ms->currentCommandBuffer = [ms->commandQueue commandBuffer];
	RAVE_LOG("AccessZBuffer: ctx=0x%08x %lux%lu buf=0x%08x rowBytes=%d",
	         drawContextAddr, (unsigned long)w, (unsigned long)h, ms->zBufferCPUMac, rowBytes);
	return kQANoErr;
}


int32_t NativeAccessZBufferEnd(uint32_t drawContextAddr, uint32_t dirtyRectAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal) return kQAError;
	RaveMetalState *ms = priv->metal;
	if (!ms->zBufferAccessed) return kQANoErr;
	NSUInteger w = ms->depthBuffer.width;
	NSUInteger h = ms->depthBuffer.height;
	uint32_t rowBytes = (uint32_t)(w * 4);
	[ms->stagingZBuffer replaceRegion:MTLRegionMake2D(0,0,w,h)
	                      mipmapLevel:0 withBytes:ms->zBufferCPU
	                      bytesPerRow:rowBytes];
	id<MTLCommandBuffer> blitCmdBuf = [ms->commandQueue commandBuffer];
	id<MTLBlitCommandEncoder> blit = [blitCmdBuf blitCommandEncoder];
	[blit copyFromTexture:ms->stagingZBuffer sourceSlice:0 sourceLevel:0
	         sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(w,h,1)
	            toTexture:ms->depthBuffer destinationSlice:0
	     destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
	[blit endEncoding];
	[blitCmdBuf commit];
	[blitCmdBuf waitUntilCompleted];
	ms->zBufferAccessed = false;
	int32_t result = RestartRenderPassWithLoad(priv);
	RAVE_LOG("AccessZBufferEnd: ctx=0x%08x depth uploaded, render pass restarted", drawContextAddr);
	return result;
}


int32_t NativeClearDrawBuffer(uint32_t drawContextAddr, uint32_t rectAddr, uint32_t initialContextAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal) return kQAError;
	RaveMetalState *ms = priv->metal;
	if (!ms->renderPassActive || !ms->currentEncoder) return kQAError;
	int32_t left   = (int32_t)ReadMacInt32(rectAddr + 0);
	int32_t top    = (int32_t)ReadMacInt32(rectAddr + 4);
	int32_t right  = (int32_t)ReadMacInt32(rectAddr + 8);
	int32_t bottom = (int32_t)ReadMacInt32(rectAddr + 12);
	if (left < 0) left = 0;
	if (top < 0) top = 0;
	if (right > priv->width) right = priv->width;
	if (bottom > priv->height) bottom = priv->height;
	if (right <= left || bottom <= top) return kQANoErr;
	// Read BG color: from initialContext if non-NULL per RAVE.h, else from current context
	float r, g, b, a;
	if (initialContextAddr != 0) {
		// Per RAVE.h: initialContext is a TQADrawContext* — read its drawPrivate handle
		// from offset 0, then look up the native context to read its BG color state
		uint32_t initHandle = ReadMacInt32(initialContextAddr);
		RaveDrawPrivate *initCtx = RaveGetContext(initHandle);
		if (initCtx) {
			a = 1.0f;                    // Force opaque for overlay compositing
			r = initCtx->state[2].f;     // kQATag_ColorBG_r
			g = initCtx->state[3].f;     // kQATag_ColorBG_g
			b = initCtx->state[4].f;     // kQATag_ColorBG_b
			RAVE_LOG("ClearDrawBuffer: using initialContext 0x%08x BG=(%.2f,%.2f,%.2f)",
			         initialContextAddr, r, g, b);
		} else {
			// initialContext handle invalid — fall back to current context
			a = 1.0f;
			r = priv->state[2].f;
			g = priv->state[3].f;
			b = priv->state[4].f;
			RAVE_LOG("ClearDrawBuffer: initialContext 0x%08x invalid handle %d, using current BG",
			         initialContextAddr, initHandle);
		}
	} else {
		// NULL initialContext — use current context's BG color
		a = 1.0f;              // Force opaque for overlay compositing
		r = priv->state[2].f;  // kQATag_ColorBG_r
		g = priv->state[3].f;  // kQATag_ColorBG_g
		b = priv->state[4].f;  // kQATag_ColorBG_b
	}
	MTLScissorRect clearScissor;
	clearScissor.x = (NSUInteger)left;
	clearScissor.y = (NSUInteger)top;
	clearScissor.width = (NSUInteger)(right - left);
	clearScissor.height = (NSUInteger)(bottom - top);
	[ms->currentEncoder setScissorRect:clearScissor];
	int pipe_idx = 0;
	// GAP-024: Apply channel mask from state[27] (kQATag_ChannelMask, default 0xF = all)
	uint32_t channelMask = priv->state[27].i;
	if (channelMask == 0) channelMask = 0xF;  // treat 0 as default (all channels)
	if (channelMask != 0xF) {
		// Use masked pipeline variant to respect per-channel write control
		id<MTLRenderPipelineState> maskedPipe = GetMaskedPipeline(ms, pipe_idx, channelMask, ms->msaaActive);
		if (maskedPipe)
			[ms->currentEncoder setRenderPipelineState:maskedPipe];
	} else {
		id<MTLRenderPipelineState> __strong *pipeArray = ms->msaaActive ? ms->msaaPipelines : ms->pipelines;
		if (pipeArray[pipe_idx])
			[ms->currentEncoder setRenderPipelineState:pipeArray[pipe_idx]];
	}
	if (ms->depthAlwaysWriteState)
		[ms->currentEncoder setDepthStencilState:ms->depthAlwaysWriteState];
	float x0 = 0.0f, y0 = 0.0f;
	float x1 = (float)priv->width, y1 = (float)priv->height;
	float z = 0.0f;
	RaveVertex quad[6];
	quad[0] = { {x0,y0,z,1.0f}, {r,g,b,a}, {0,0,0,0} };
	quad[1] = { {x1,y0,z,1.0f}, {r,g,b,a}, {0,0,0,0} };
	quad[2] = { {x0,y1,z,1.0f}, {r,g,b,a}, {0,0,0,0} };
	quad[3] = { {x1,y0,z,1.0f}, {r,g,b,a}, {0,0,0,0} };
	quad[4] = { {x1,y1,z,1.0f}, {r,g,b,a}, {0,0,0,0} };
	quad[5] = { {x0,y1,z,1.0f}, {r,g,b,a}, {0,0,0,0} };
	FragmentUniforms fragUniforms = {};
	fragUniforms.fog_max_depth = 1.0f;
	[ms->currentEncoder setFragmentBytes:&fragUniforms length:sizeof(fragUniforms) atIndex:0];
	[ms->currentEncoder setVertexBytes:quad length:sizeof(quad) atIndex:0];
	[ms->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
	MTLScissorRect fullScissor;
	fullScissor.x = 0; fullScissor.y = 0;
	fullScissor.width = (NSUInteger)priv->width;
	fullScissor.height = (NSUInteger)priv->height;
	[ms->currentEncoder setScissorRect:fullScissor];
	ms->currentPipelineIdx = -1;
	{
		int zfunc = (int)priv->state[0].i;
		if (zfunc >= 0 && zfunc < 9) {
			bool depthWriteEnabled = (priv->state[28].i != 0);
			__strong id<MTLDepthStencilState> *dsArray = depthWriteEnabled ? ms->depthStates : ms->depthStatesNoWrite;
			if (dsArray[zfunc])
				[ms->currentEncoder setDepthStencilState:dsArray[zfunc]];
		}
	}
	RAVE_LOG("ClearDrawBuffer: ctx=0x%08x rect=(%d,%d,%d,%d) initialCtx=0x%08x bg=(%.2f,%.2f,%.2f,%.2f) mask=0x%x",
	         drawContextAddr, left, top, right, bottom, initialContextAddr, r, g, b, a, channelMask);
	return kQANoErr;
}


int32_t NativeClearZBuffer(uint32_t drawContextAddr, uint32_t rectAddr, uint32_t initialContextAddr)
{
	RaveDrawPrivate *priv = GetContextFromDrawAddr(drawContextAddr);
	if (!priv || !priv->metal) return kQAError;
	RaveMetalState *ms = priv->metal;
	if (!ms->renderPassActive || !ms->currentEncoder) return kQAError;

	// GAP-025: ZBufferMask=0 means depth writes disabled; skip clear per spec
	if (priv->state[28].i == 0) {
		RAVE_LOG("ClearZBuffer: skipped (ZBufferMask=0, depth writes disabled)");
		return kQANoErr;
	}
	int32_t left   = (int32_t)ReadMacInt32(rectAddr + 0);
	int32_t top    = (int32_t)ReadMacInt32(rectAddr + 4);
	int32_t right  = (int32_t)ReadMacInt32(rectAddr + 8);
	int32_t bottom = (int32_t)ReadMacInt32(rectAddr + 12);
	if (left < 0) left = 0;
	if (top < 0) top = 0;
	if (right > priv->width) right = priv->width;
	if (bottom > priv->height) bottom = priv->height;
	if (right <= left || bottom <= top) return kQANoErr;
	// Determine clear depth: from initialContext if non-NULL per RAVE.h, else default 1.0
	float clearDepth;
	if (initialContextAddr != 0) {
		// Per RAVE.h: initialContext is a TQADrawContext* — read its drawPrivate handle
		// from offset 0, then look up its depth BG state
		uint32_t initHandle = ReadMacInt32(initialContextAddr);
		RaveDrawPrivate *initCtx = RaveGetContext(initHandle);
		if (initCtx) {
			// kQATagGL_DepthBG = 112 — if set, use it; otherwise default 1.0
			float depthBG = initCtx->state[112].f;
			clearDepth = (depthBG != 0.0f) ? depthBG : 1.0f;
			RAVE_LOG("ClearZBuffer: using initialContext 0x%08x depth=%.4f",
			         initialContextAddr, clearDepth);
		} else {
			clearDepth = 1.0f;
			RAVE_LOG("ClearZBuffer: initialContext 0x%08x invalid handle %d, using depth 1.0",
			         initialContextAddr, initHandle);
		}
	} else {
		// NULL initialContext — use far plane default
		clearDepth = 1.0f;
	}
	MTLScissorRect clearScissor;
	clearScissor.x = (NSUInteger)left;
	clearScissor.y = (NSUInteger)top;
	clearScissor.width = (NSUInteger)(right - left);
	clearScissor.height = (NSUInteger)(bottom - top);
	[ms->currentEncoder setScissorRect:clearScissor];
	int pipe_idx = 0;
	id<MTLRenderPipelineState> __strong *pipeArray = ms->msaaActive ? ms->msaaPipelines : ms->pipelines;
	if (pipeArray[pipe_idx])
		[ms->currentEncoder setRenderPipelineState:pipeArray[pipe_idx]];
	if (ms->depthAlwaysWriteState)
		[ms->currentEncoder setDepthStencilState:ms->depthAlwaysWriteState];
	float x0 = 0.0f, y0 = 0.0f;
	float x1 = (float)priv->width, y1 = (float)priv->height;
	RaveVertex quad[6];
	quad[0] = { {x0,y0,clearDepth,1.0f}, {0,0,0,0}, {0,0,0,0} };
	quad[1] = { {x1,y0,clearDepth,1.0f}, {0,0,0,0}, {0,0,0,0} };
	quad[2] = { {x0,y1,clearDepth,1.0f}, {0,0,0,0}, {0,0,0,0} };
	quad[3] = { {x1,y0,clearDepth,1.0f}, {0,0,0,0}, {0,0,0,0} };
	quad[4] = { {x1,y1,clearDepth,1.0f}, {0,0,0,0}, {0,0,0,0} };
	quad[5] = { {x0,y1,clearDepth,1.0f}, {0,0,0,0}, {0,0,0,0} };
	FragmentUniforms fragUniforms = {};
	fragUniforms.fog_max_depth = 1.0f;
	[ms->currentEncoder setFragmentBytes:&fragUniforms length:sizeof(fragUniforms) atIndex:0];
	[ms->currentEncoder setVertexBytes:quad length:sizeof(quad) atIndex:0];
	[ms->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
	MTLScissorRect fullScissor;
	fullScissor.x = 0; fullScissor.y = 0;
	fullScissor.width = (NSUInteger)priv->width;
	fullScissor.height = (NSUInteger)priv->height;
	[ms->currentEncoder setScissorRect:fullScissor];
	ms->currentPipelineIdx = -1;
	{
		int zfunc = (int)priv->state[0].i;
		if (zfunc >= 0 && zfunc < 9) {
			bool depthWriteEnabled = (priv->state[28].i != 0);
			__strong id<MTLDepthStencilState> *dsArray = depthWriteEnabled ? ms->depthStates : ms->depthStatesNoWrite;
			if (dsArray[zfunc])
				[ms->currentEncoder setDepthStencilState:dsArray[zfunc]];
		}
	}
	RAVE_LOG("ClearZBuffer: ctx=0x%08x rect=(%d,%d,%d,%d) initialCtx=0x%08x depth=%.4f",
	         drawContextAddr, left, top, right, bottom, initialContextAddr, clearDepth);
	return kQANoErr;
}


// [AUDIT-T02] Verified: MTLPixelFormatBGRA8Unorm matches converter output. bytesPerRow = width*4
// for BGRA8. replaceRegion origin (0,0) and size (width,height) correct. mipLevels > 1 sets
// mipmapLevelCount. Usage includes ShaderWrite when mipmapped (for generateMipmapsForTexture:).
void *RaveCreateMetalTexture(uint32_t width, uint32_t height, uint32_t mipLevels,
                              const uint8_t *pixelData, uint32_t bytesPerRow)
{
	id<MTLDevice> device = (__bridge id<MTLDevice>)SharedMetalDevice();
	if (!device) {
		RAVE_LOG("RaveCreateMetalTexture: no device available");
		return nullptr;
	}

	// [DIAG-T03] Metal texture creation diagnostic
	if (rave_logging_enabled) {
		printf("RAVE DIAG: MetalTexCreate %dx%d mips=%d bytesPerRow=%d shaderWrite=%d\n",
		       width, height, mipLevels, bytesPerRow, (mipLevels > 1) ? 1 : 0);
	}

	MTLTextureDescriptor *desc = [MTLTextureDescriptor
		texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
		                            width:width
		                           height:height
		                        mipmapped:(mipLevels > 1)];
	desc.storageMode = MTLStorageModeShared;
	// ShaderWrite is required for RaveGenerateMipmaps (blit encoder generateMipmapsForTexture:)
	desc.usage = MTLTextureUsageShaderRead | ((mipLevels > 1) ? MTLTextureUsageShaderWrite : 0);
	if (mipLevels > 1) desc.mipmapLevelCount = mipLevels;

	id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
	if (!texture) {
		RAVE_LOG("RaveCreateMetalTexture: newTextureWithDescriptor failed");
		return nullptr;
	}

	// Upload level 0
	[texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
	           mipmapLevel:0
	             withBytes:pixelData
	           bytesPerRow:bytesPerRow];

	return (__bridge_retained void *)texture;
}


// [AUDIT-T02] Verified: replaceRegion origin (0,0), size (width,height) at specified mip level.
// bytesPerRow must be width*4 for BGRA8 at that mip level (caller responsible).
void RaveUploadMipLevel(void *metalTexture, uint32_t level, uint32_t width, uint32_t height,
                         const uint8_t *pixelData, uint32_t bytesPerRow)
{
	if (!metalTexture) return;

	// [DIAG-T03] Upload diagnostic: log bytesPerRow, region, and mip level
	if (rave_logging_enabled) {
		printf("RAVE DIAG: UploadMip level=%d %dx%d bytesPerRow=%d origin=(0,0)\n",
		       level, width, height, bytesPerRow);
	}

	id<MTLTexture> tex = (__bridge id<MTLTexture>)metalTexture;
	[tex replaceRegion:MTLRegionMake2D(0, 0, width, height)
	       mipmapLevel:level
	         withBytes:pixelData
	       bytesPerRow:bytesPerRow];
}


// [AUDIT-T02] Verified: generateMipmapsForTexture: generates full mip chain from level 0.
// Requires MTLTextureUsageShaderWrite on the texture (fixed in RaveCreateMetalTexture).
void RaveGenerateMipmaps(void *metalTexture)
{
	if (!metalTexture) return;
	id<MTLTexture> tex = (__bridge id<MTLTexture>)metalTexture;
	id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)SharedMetalCommandQueue();
	if (!queue) return;

	@autoreleasepool {
		id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
		id<MTLBlitCommandEncoder> blit = [cmdBuf blitCommandEncoder];
		[blit generateMipmapsForTexture:tex];
		[blit endEncoding];
		[cmdBuf commit];
		[cmdBuf waitUntilCompleted];
	}
}


void RaveReleaseTexture(void *metalTexture)
{
	if (metalTexture) {
		id<MTLTexture> tex = (__bridge_transfer id<MTLTexture>)metalTexture;
		tex = nil;  // ARC releases
	}
}


/*
 *  RaveRefreshTextureFromPixmap - re-read pixmap and re-upload to Metal texture
 *
 *  Called every frame for deferred textures that were initially realized from
 *  all-zero data.  The original RAVE software renderer reads the pixmap live
 *  on every draw call, so QD3D's IR can write directly to the pixmap between
 *  frames.  We must mirror this by re-uploading each frame.
 *
 *  Once non-zero data is detected, marks pixels_copied=true to stop re-uploading
 *  (the texture content has stabilized).
 */
void RaveRefreshTextureFromPixmap(RaveResourceEntry *entry)
{
	if (!entry || !entry->metal_texture || entry->pixmap_mac_addr == 0) return;
	if (entry->pixels_copied) return;  // already has real data

	uint32_t w = entry->width;
	uint32_t h = entry->height;
	uint32_t pixelType = entry->pixel_type;
	uint32_t rowBytes = entry->row_bytes;
	uint32_t pixmap = entry->pixmap_mac_addr;

	// Always re-read and re-upload — the pixmap is a live buffer
	uint8_t *expanded = new uint8_t[w * h * 4];
	ConvertPixels(pixelType, pixmap, expanded, w, h, rowBytes);

	// Check if any non-black pixels exist
	bool hasData = false;
	uint32_t sampleCount = (w * h < 256) ? w * h : 256;
	for (uint32_t i = 0; i < sampleCount && !hasData; i++) {
		uint32_t off = i * 4;
		if (expanded[off] != 0 || expanded[off+1] != 0 || expanded[off+2] != 0) {
			hasData = true;
		}
	}

	// Replace Metal texture contents
	id<MTLTexture> mtlTex = (__bridge id<MTLTexture>)entry->metal_texture;
	MTLRegion region = MTLRegionMake2D(0, 0, w, h);
	[mtlTex replaceRegion:region mipmapLevel:0 withBytes:expanded bytesPerRow:w * 4];

	delete[] expanded;

	if (hasData) {
		// Data arrived — stop re-uploading
		if (entry->cpu_pixel_data && entry->cpu_pixel_mac_addr) {
			Host2Mac_memcpy(entry->cpu_pixel_mac_addr, Mac2HostAddr(pixmap), entry->cpu_pixel_data_size);
		}
		entry->pixels_copied = true;
		RAVE_LOG("TextureRefresh: pixelType=%d %dx%d pixmap=0x%08x -> data arrived, re-uploaded",
		       pixelType, w, h, pixmap);
	}
}


/*
 *  ATI RaveExtFuncs: clearDrawBuffer / clearZBuffer
 *
 *  These are the ATI extension versions of the standard RAVE clear methods.
 *  They take only 2 args (drawContext, rect) instead of 3 (no initialContextAddr).
 *  Delegate to the existing 3-arg implementations with initialContextAddr=0,
 *  which causes them to use the draw context's own state tags for clear values.
 */

int32_t NativeATIClearDrawBuffer(uint32_t drawContextAddr, uint32_t rectAddr)
{
	return NativeClearDrawBuffer(drawContextAddr, rectAddr, 0);
}

int32_t NativeATIClearZBuffer(uint32_t drawContextAddr, uint32_t rectAddr)
{
	return NativeClearZBuffer(drawContextAddr, rectAddr, 0);
}
