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
 *  Loads the bundled MTLBinaryArchive so compositor and NQD PSOs skip
 *  runtime shader compilation. No-op before iOS 14. Emul thread only.
 */

#import <Metal/Metal.h>
#include "pso_archive.h"
#include "metal_device_shared.h"

#include <cstdio>

static id<MTLBinaryArchive> s_archive     = nil;
static bool                 s_initialized = false;

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
			// Not in this bundle. Non-fatal: PSOs compile at runtime.
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
		// Non-fatal.
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
			// Archive miss: clear the hint; caller compiles at runtime.
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

		desc.binaryArchives = @[s_archive];

		NSError *err = nil;
		id<MTLComputePipelineState> pso =
			[device newComputePipelineStateWithDescriptor:desc
			                                     options:0
			                                  reflection:nil
			                                       error:&err];
		if (!pso) {
			// Archive miss: clear the hint.
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

