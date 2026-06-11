/*
 *  pso_archive.mm - PSO binary archive module implementation.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Loads a shipped MTLBinaryArchive from the app bundle at init time
 *  so stock PSO descriptors resolve without runtime shader compilation.
 *  On iOS 13.x, the module is a no-op (MTLBinaryArchive requires iOS 14+).
 *
 *  The TESTING_BUILD capture function generates the archive by exercising
 *  all stock PSO descriptors (Compositor + NQD; RAVE and GL deferred
 *  until shader permutations stabilize).
 *
 *  Threading: single-writer from PPC emul thread or test main thread.
 *  No concurrency primitives.
 */

#import <Metal/Metal.h>
#include "pso_archive.h"
#include "metal_device_shared.h"

#include <cstdio>

// ---------------------------------------------------------------------------
// Static singleton state
// ---------------------------------------------------------------------------

static id<MTLBinaryArchive> s_archive     = nil;
static bool                 s_initialized = false;

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

extern "C" int32_t pso_archive_init(void)
{
	if (s_initialized) {
		return 0;
	}

	if (@available(iOS 14, *)) {
		id<MTLDevice> device = (__bridge id<MTLDevice>)SharedMetalDevice();
		if (!device) {
			fprintf(stderr, "[pso_archive] init: SharedMetalDevice() returned nil\n");
			s_initialized = true;
			return 0;  // Non-fatal: runtime compile fallback
		}

		NSURL *archiveURL = [[NSBundle mainBundle]
			URLForResource:@"stock_pipelines"
			 withExtension:@"metalarchive"];
		if (!archiveURL) {
			// Archive not shipped yet (or not in this bundle). Non-fatal:
			// all PSOs will be runtime-compiled as before.
			printf("[pso_archive] init: stock_pipelines.metalarchive not found "
			       "in bundle -- runtime compile fallback\n");
			s_initialized = true;
			return 0;
		}

		MTLBinaryArchiveDescriptor *loadDesc =
			[[MTLBinaryArchiveDescriptor alloc] init];
		loadDesc.url = archiveURL;

		NSError *err = nil;
		s_archive = [device newBinaryArchiveWithDescriptor:loadDesc error:&err];
		if (!s_archive) {
			fprintf(stderr, "[pso_archive] init: newBinaryArchiveWithDescriptor "
			        "failed: %s\n",
			        [[err localizedDescription] UTF8String]);
			s_initialized = true;
			return kGfxAccelErrPSOArchiveLoadFailed;
		}

		printf("[pso_archive] init: loaded archive from %s\n",
		       [[archiveURL path] UTF8String]);
		s_initialized = true;
		return 0;
	} else {
		// iOS 13.x: MTLBinaryArchive not available. Non-fatal.
		printf("[pso_archive] init: iOS < 14 -- archive not available\n");
		s_initialized = true;
		return kGfxAccelErrPSOArchiveNotAvailable;
	}
}

extern "C" void pso_archive_shutdown(void)
{
	if (!s_initialized) {
		return;
	}

	s_archive = nil;
	s_initialized = false;
}

// ---------------------------------------------------------------------------
// Lookup
// ---------------------------------------------------------------------------

extern "C" void *pso_archive_lookup_render(void *descriptor)
{
	if (!s_archive || !descriptor) {
		return NULL;
	}

	if (@available(iOS 14, *)) {
		id<MTLDevice> device = (__bridge id<MTLDevice>)SharedMetalDevice();
		if (!device) {
			return NULL;
		}

		MTLRenderPipelineDescriptor *desc =
			(__bridge MTLRenderPipelineDescriptor *)descriptor;

		// Hint Metal to check the archive first.
		desc.binaryArchives = @[s_archive];

		NSError *err = nil;
		id<MTLRenderPipelineState> pso =
			[device newRenderPipelineStateWithDescriptor:desc error:&err];
		if (!pso) {
			// Archive miss: clear hint and return NULL so caller
			// does runtime compile.
			desc.binaryArchives = nil;
			return NULL;
		}

		return (__bridge void *)pso;
	}

	return NULL;
}

extern "C" void *pso_archive_lookup_compute(void *descriptor)
{
	if (!s_archive || !descriptor) {
		return NULL;
	}

	if (@available(iOS 14, *)) {
		id<MTLDevice> device = (__bridge id<MTLDevice>)SharedMetalDevice();
		if (!device) {
			return NULL;
		}

		MTLComputePipelineDescriptor *desc =
			(__bridge MTLComputePipelineDescriptor *)descriptor;

		// Hint Metal to check the archive first.
		desc.binaryArchives = @[s_archive];

		NSError *err = nil;
		id<MTLComputePipelineState> pso =
			[device newComputePipelineStateWithDescriptor:desc
			                                     options:0
			                                  reflection:nil
			                                       error:&err];
		if (!pso) {
			// Archive miss: clear hint and return NULL.
			desc.binaryArchives = nil;
			return NULL;
		}

		return (__bridge void *)pso;
	}

	return NULL;
}

extern "C" uint32_t pso_archive_is_available(void)
{
	return s_archive != nil ? 1u : 0u;
}

extern "C" void pso_archive_set_on_descriptor(void *descriptor)
{
	if (!s_archive || !descriptor) {
		return;
	}

	if (@available(iOS 14, *)) {
		MTLRenderPipelineDescriptor *desc =
			(__bridge MTLRenderPipelineDescriptor *)descriptor;
		desc.binaryArchives = @[s_archive];
	}
}

// ---------------------------------------------------------------------------
// TESTING_BUILD introspection
// ---------------------------------------------------------------------------

#ifdef TESTING_BUILD

extern "C" uint32_t pso_archive_testing_is_initialized(void)
{
	return s_initialized ? 1u : 0u;
}

extern "C" void pso_archive_testing_reset(void)
{
	pso_archive_shutdown();
}

extern "C" int32_t pso_archive_testing_capture_stock(const char *output_path)
{
	if (!output_path) {
		fprintf(stderr, "[pso_archive] capture_stock: output_path is NULL\n");
		return -1;
	}

	if (@available(iOS 14, *)) {
		id<MTLDevice> device = (__bridge id<MTLDevice>)SharedMetalDevice();
		if (!device) {
			fprintf(stderr, "[pso_archive] capture_stock: SharedMetalDevice() nil\n");
			return -1;
		}

		// Create an empty archive for capturing
		MTLBinaryArchiveDescriptor *archDesc =
			[[MTLBinaryArchiveDescriptor alloc] init];
		// archDesc.url = nil for new empty archive

		NSError *err = nil;
		id<MTLBinaryArchive> archive =
			[device newBinaryArchiveWithDescriptor:archDesc error:&err];
		if (!archive) {
			fprintf(stderr, "[pso_archive] capture_stock: "
			        "newBinaryArchiveWithDescriptor failed: %s\n",
			        [[err localizedDescription] UTF8String]);
			return -1;
		}

		// Get the Metal library with shader functions.
		// In TESTING_BUILD, the shaders may be compiled into the test
		// bundle rather than the main bundle, so try all known bundles.
		id<MTLLibrary> library = [device newDefaultLibrary];
		if (!library) {
			// Try the bundle containing this class (test bundle)
			NSBundle *classBundle = [NSBundle bundleForClass:
				NSClassFromString(@"PSOArchiveCaptureTests")];
			if (classBundle) {
				NSError *libErr = nil;
				library = [device newDefaultLibraryWithBundle:classBundle
				                                       error:&libErr];
			}
		}
		if (!library) {
			// Last resort: iterate all loaded bundles
			for (NSBundle *b in [NSBundle allBundles]) {
				NSError *libErr = nil;
				id<MTLLibrary> candidate =
					[device newDefaultLibraryWithBundle:b error:&libErr];
				if (candidate) {
					library = candidate;
					break;
				}
			}
		}
		if (!library) {
			fprintf(stderr, "[pso_archive] capture_stock: "
			        "no Metal library found in any bundle\n");
			return -1;
		}

		// ---------------------------------------------------------------
		// Compositor render PSOs: 3 fragment variants x 1 vertex
		// ---------------------------------------------------------------
		NSArray<NSString *> *compositorFragments = @[
			@"compositor_fragment_indexed",
			@"compositor_fragment_16bpp",
			@"compositor_fragment_32bpp"
		];

		id<MTLFunction> compositorVertex =
			[library newFunctionWithName:@"compositor_vertex"];
		if (!compositorVertex) {
			fprintf(stderr, "[pso_archive] capture_stock: "
			        "compositor_vertex not found in library\n");
			return -1;
		}

		for (NSString *fragName in compositorFragments) {
			id<MTLFunction> fragFunc =
				[library newFunctionWithName:fragName];
			if (!fragFunc) {
				fprintf(stderr, "[pso_archive] capture_stock: "
				        "%s not found in library\n",
				        [fragName UTF8String]);
				return -1;
			}

			MTLRenderPipelineDescriptor *pd =
				[[MTLRenderPipelineDescriptor alloc] init];
			pd.vertexFunction   = compositorVertex;
			pd.fragmentFunction = fragFunc;
			pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

			err = nil;
			BOOL ok = [archive addRenderPipelineFunctionsWithDescriptor:pd
			                                                     error:&err];
			if (!ok) {
				fprintf(stderr, "[pso_archive] capture_stock: "
				        "addRenderPipelineFunctions(%s) failed: %s\n",
				        [fragName UTF8String],
				        [[err localizedDescription] UTF8String]);
				return -1;
			}
		}

		// ---------------------------------------------------------------
		// SubmitFrame render PSOs: 3 blend modes
		// ---------------------------------------------------------------
		id<MTLFunction> sfVertex =
			[library newFunctionWithName:@"submitframe_vertex"];
		id<MTLFunction> sfFragment =
			[library newFunctionWithName:@"submitframe_fragment"];
		id<MTLFunction> sfDisplayPremultiplied =
			[library newFunctionWithName:@"submitframe_fragment_display_premultiplied"];

		if (sfVertex && sfFragment) {
			// Opaque (no blending)
			{
				MTLRenderPipelineDescriptor *pd =
					[[MTLRenderPipelineDescriptor alloc] init];
				pd.vertexFunction   = sfVertex;
				pd.fragmentFunction = sfFragment;
				pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
				pd.colorAttachments[0].blendingEnabled = NO;

				err = nil;
				[archive addRenderPipelineFunctionsWithDescriptor:pd
				                                           error:&err];
			}

			// Premultiplied alpha
			{
				MTLRenderPipelineDescriptor *pd =
					[[MTLRenderPipelineDescriptor alloc] init];
				pd.vertexFunction   = sfVertex;
				pd.fragmentFunction = sfFragment;
				pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
				pd.colorAttachments[0].blendingEnabled           = YES;
				pd.colorAttachments[0].sourceRGBBlendFactor      = MTLBlendFactorOne;
				pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
				pd.colorAttachments[0].sourceAlphaBlendFactor    = MTLBlendFactorOne;
				pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
				pd.colorAttachments[0].rgbBlendOperation   = MTLBlendOperationAdd;
				pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

				err = nil;
				[archive addRenderPipelineFunctionsWithDescriptor:pd
				                                           error:&err];
			}

			// Straight alpha
			{
				MTLRenderPipelineDescriptor *pd =
					[[MTLRenderPipelineDescriptor alloc] init];
				pd.vertexFunction   = sfVertex;
				pd.fragmentFunction = sfFragment;
				pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
				pd.colorAttachments[0].blendingEnabled           = YES;
				pd.colorAttachments[0].sourceRGBBlendFactor      = MTLBlendFactorSourceAlpha;
				pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
				pd.colorAttachments[0].sourceAlphaBlendFactor    = MTLBlendFactorOne;
				pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
				pd.colorAttachments[0].rgbBlendOperation   = MTLBlendOperationAdd;
				pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

				err = nil;
				[archive addRenderPipelineFunctionsWithDescriptor:pd
				                                           error:&err];
			}

			if (sfDisplayPremultiplied) {
				MTLRenderPipelineDescriptor *pd =
					[[MTLRenderPipelineDescriptor alloc] init];
				pd.vertexFunction   = sfVertex;
				pd.fragmentFunction = sfDisplayPremultiplied;
				pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
				pd.colorAttachments[0].blendingEnabled           = YES;
				pd.colorAttachments[0].sourceRGBBlendFactor      = MTLBlendFactorOne;
				pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
				pd.colorAttachments[0].sourceAlphaBlendFactor    = MTLBlendFactorOne;
				pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
				pd.colorAttachments[0].rgbBlendOperation   = MTLBlendOperationAdd;
				pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

				err = nil;
				[archive addRenderPipelineFunctionsWithDescriptor:pd
				                                           error:&err];
			}
		} else {
			printf("[pso_archive] capture_stock: submitframe shaders not "
			       "found -- skipping (non-fatal)\n");
		}

		// ---------------------------------------------------------------
		// NQD compute PSOs: nqd_bitblt, nqd_fillrect
		// ---------------------------------------------------------------
		NSArray<NSString *> *nqdKernels = @[
			@"nqd_bitblt",
			@"nqd_fillrect"
		];

		for (NSString *kernelName in nqdKernels) {
			id<MTLFunction> kernelFunc =
				[library newFunctionWithName:kernelName];
			if (!kernelFunc) {
				printf("[pso_archive] capture_stock: %s not found "
				       "in library -- skipping (non-fatal)\n",
				       [kernelName UTF8String]);
				continue;
			}

			MTLComputePipelineDescriptor *cpd =
				[[MTLComputePipelineDescriptor alloc] init];
			cpd.computeFunction = kernelFunc;

			err = nil;
			BOOL ok = [archive addComputePipelineFunctionsWithDescriptor:cpd
			                                                       error:&err];
			if (!ok) {
				fprintf(stderr, "[pso_archive] capture_stock: "
				        "addComputePipelineFunctions(%s) failed: %s\n",
				        [kernelName UTF8String],
				        [[err localizedDescription] UTF8String]);
				// Non-fatal: continue capturing other descriptors
			}
		}

		// ---------------------------------------------------------------
		// NOTE: RAVE and GL PSO descriptors are deferred.
		// The runtime-compile fallback covers any PSO not in the archive,
		// so correctness is unaffected -- only first-launch latency for
		// RAVE/GL-heavy apps is deferred.
		// ---------------------------------------------------------------

		// Serialize the archive to disk
		NSURL *outURL = [NSURL fileURLWithPath:@(output_path)];
		err = nil;
		BOOL serialized = [archive serializeToURL:outURL error:&err];
		if (!serialized) {
			fprintf(stderr, "[pso_archive] capture_stock: "
			        "serializeToURL failed: %s\n",
			        [[err localizedDescription] UTF8String]);
			return -1;
		}

		printf("[pso_archive] capture_stock: wrote archive to %s\n",
		       output_path);
		return 0;
	} else {
		fprintf(stderr, "[pso_archive] capture_stock: "
		        "MTLBinaryArchive requires iOS 14+\n");
		return kGfxAccelErrPSOArchiveNotAvailable;
	}
}

#endif /* TESTING_BUILD */
