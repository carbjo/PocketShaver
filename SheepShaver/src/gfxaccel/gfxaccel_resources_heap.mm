/*
 *  gfxaccel_resources_heap.mm - Metal heap implementation.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Metal-side half of gfxaccel_resources_heap. Owns:
 *    - Per-engine MTLHeap creation (lazy).
 *    - Sub-allocation from heaps via the `:offset:` API variants
 *      (newBufferWithLength:options:offset:, newTextureWithDescriptor:offset:).
 *    - Per-heap bump sub-allocator (next_offset), advanced on each alloc
 *      and reset on DMC on_mode_exit.
 *    - Three-tier eviction pipeline: LRU purge, PSO flush, loud fail.
 *    - Memory-warning C shim: dispatch_async to emul serial queue.
 *    - Compositor handshake: dispatch_semaphore for eviction-done.
 *
 *  Placement-heap policy is used on iOS 17+ via the `:offset:` alloc API
 *  variants. A per-heap bump allocator tracks next_offset, advanced on
 *  each alloc and reset on DMC on_mode_exit. This gives exact memory
 *  accounting.
 *
 *  Alignment floor: each allocation aligns to max(Metal-reported-align,
 *  256). Over-commit returns NULL + os_log_fault without invoking
 *  Metal alloc (prevents Placement validation assertion from firing).
 *
 *  ARC ownership: g_heaps[] are strong references under ARC. Setting nil
 *  releases the heap and all sub-allocations.
 *
 *  Threading: NO std::mutex, NO std::atomic. The emul serial
 *  queue (gfxaccel_emul_queue()) is the synchronization primitive.
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <os/log.h>
#import <TargetConditionals.h>

#include <cstdint>
#include <cstdio>
#include <dispatch/dispatch.h>

#include "gfxaccel_resources_heap.h"
#include "metal_device_shared.h"

// ---------------------------------------------------------------------------
// File-scope Metal state
// ---------------------------------------------------------------------------

static id<MTLHeap> g_heaps[kHeapCount] = { nil, nil, nil, nil, nil };

// Per-heap monotonic bump offset (bump allocator).
// Reset to 0 on DMC on_mode_exit. All allocations
// compute their aligned start offset from this counter and advance it.
// No std::atomic: single-writer invariant (emul serial queue).
static NSUInteger g_next_offset[kHeapCount] = { 0, 0, 0, 0, 0 };

// Heap sizes (initial = ceiling constants from header; overridable via
// gfxaccel_heap_testing_set_ceiling for tests).
static NSUInteger g_heap_sizes[kHeapCount] = {
	kHeapCeiling_NQD,
	kHeapCeiling_RAVE,
	kHeapCeiling_GL,
	kHeapCeiling_Compositor,
	kHeapCeiling_DSp
};

// Default ceiling values for reset.
static const NSUInteger g_heap_defaults[kHeapCount] = {
	kHeapCeiling_NQD,
	kHeapCeiling_RAVE,
	kHeapCeiling_GL,
	kHeapCeiling_Compositor,
	kHeapCeiling_DSp
};

// ---------------------------------------------------------------------------
// Emul serial queue
// ---------------------------------------------------------------------------

static dispatch_queue_t gfxaccel_emul_queue(void)
{
	static dispatch_queue_t q = NULL;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		q = dispatch_queue_create("com.carbjo.pocketshaver.gfxaccel.emul",
		                          DISPATCH_QUEUE_SERIAL);
	});
	return q;
}

// ---------------------------------------------------------------------------
// Eviction semaphore
// ---------------------------------------------------------------------------

static dispatch_semaphore_t g_eviction_done_sem = NULL;
static bool g_eviction_pending = false;

// os_log subsystem for heap exhaustion + eviction timeout
static os_log_t gfxaccel_heap_log(void)
{
	static os_log_t log = NULL;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		log = os_log_create("com.carbjo.pocketshaver.gfxaccel", "heap");
	});
	return log;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// Forward declarations of C++ side eviction functions.
extern "C" void gfxaccel_heap_lru_purge_volatile(void);
extern "C" void gfxaccel_heap_pso_cache_clear(void);

// Align `offset` up to `alignment`, honoring the floor of 256
// bytes. Metal's reported alignment may be lower (e.g., 16 bytes for a
// simple buffer); 256 is the conservative cache-line / MTL offset
// alignment requirement that also matches the RAVE ring buffer stride.
static inline NSUInteger align_offset_up(NSUInteger offset,
                                          NSUInteger alignment)
{
	if (alignment == 0) {
		alignment = 256;
	}
	NSUInteger a = alignment < 256 ? 256 : alignment;
	return (offset + (a - 1)) & ~(a - 1);
}

// ---------------------------------------------------------------------------
// extern "C" helpers called from gfxaccel_resources_heap.cpp
// ---------------------------------------------------------------------------

extern "C" void gfxaccel_resources_heap_mm_init(void)
{
	// No-op: heaps are lazy. Initialize the eviction semaphore.
	if (g_eviction_done_sem == NULL) {
		g_eviction_done_sem = dispatch_semaphore_create(0);
	}
	g_eviction_pending = false;
}

extern "C" void gfxaccel_resources_heap_mm_shutdown(void)
{
	// Release all heaps (ARC).
	for (int i = 0; i < kHeapCount; ++i) {
		g_heaps[i] = nil;
	}

	// Reset heap sizes to defaults.
	for (int i = 0; i < kHeapCount; ++i) {
		g_heap_sizes[i] = g_heap_defaults[i];
	}

	// Reset per-heap bump offsets.
	for (int i = 0; i < kHeapCount; ++i) {
		g_next_offset[i] = 0;
	}

	// Reset eviction state.
	g_eviction_done_sem = NULL;
	g_eviction_pending = false;
}

extern "C" void *gfxaccel_resources_heap_mm_get(uint32_t heap_id)
{
	if (heap_id >= kHeapCount) {
		return NULL;
	}

	// Lazy-create the heap on first access.
	if (g_heaps[heap_id] != nil) {
		return (__bridge void *)g_heaps[heap_id];
	}

	id<MTLDevice> device = (__bridge id<MTLDevice>)SharedMetalDevice();
	if (device == nil) {
		fprintf(stderr, "[gfxaccel-heap] heap_get(id=%u): SharedMetalDevice() "
		                "returned nil\n", (unsigned)heap_id);
		return NULL;
	}

	MTLHeapDescriptor *desc = [[MTLHeapDescriptor alloc] init];
	desc.size = g_heap_sizes[heap_id];
#if TARGET_OS_SIMULATOR
	// iOS simulator Metal driver requires MTLStorageModePrivate for heaps.
	// On-device builds use Shared for CPU+GPU access.
	desc.storageMode = MTLStorageModePrivate;
#else
	desc.storageMode = MTLStorageModeShared;
#endif
	desc.hazardTrackingMode = MTLHazardTrackingModeUntracked;

	// Placement on iOS 17+ for exact memory accounting. Alloc paths use
	// the :offset: API variants required by Placement. Automatic retained
	// for iOS 13.4-16.x.
	if (@available(iOS 17, *)) {
		desc.type = MTLHeapTypePlacement;
	} else {
		desc.type = MTLHeapTypeAutomatic;
	}

	g_heaps[heap_id] = [device newHeapWithDescriptor:desc];
	if (g_heaps[heap_id] == nil) {
		os_log_fault(gfxaccel_heap_log(),
		             "Failed to create MTLHeap for heap_id=%u size=%lu",
		             (unsigned)heap_id, (unsigned long)g_heap_sizes[heap_id]);
		return NULL;
	}

	return (__bridge void *)g_heaps[heap_id];
}

extern "C" void *gfxaccel_resources_heap_mm_alloc_buffer(uint32_t heap_id,
                                                          uint32_t length,
                                                          uint32_t options)
{
	// Ensure heap exists (lazy create).
	if (gfxaccel_resources_heap_mm_get(heap_id) == NULL) {
		return NULL;
	}

	id<MTLHeap> heap = g_heaps[heap_id];

	// On simulator, heap uses Private storage; force buffer options to match.
#if TARGET_OS_SIMULATOR
	MTLResourceOptions allocOptions = MTLResourceStorageModePrivate;
#else
	MTLResourceOptions allocOptions = (MTLResourceOptions)options;
#endif

	// Bump allocator: query the device for the size/alignment
	// requirement (Metal's heapBuffer/heapTexture size-and-align APIs live
	// on MTLDevice, not MTLHeap), align the current bump offset up, call
	// the :offset: variant required by Placement heaps, and advance the
	// bump offset.
	id<MTLDevice> device = (__bridge id<MTLDevice>)SharedMetalDevice();
	MTLSizeAndAlign sa = [device heapBufferSizeAndAlignWithLength:(NSUInteger)length
	                                                       options:allocOptions];

	id<MTLBuffer> buf = nil;
	for (int tier = 0; tier < 3; ++tier) {
		NSUInteger aligned = align_offset_up(g_next_offset[heap_id], sa.align);

		// Over-commit pre-check: if the aligned placement would exceed
		// the heap's size, skip the Metal call (Placement would fire a
		// validation assertion) and fall through to the eviction tier.
		if (aligned + sa.size > g_heap_sizes[heap_id]) {
			// Fall through to eviction below.
		} else {
			buf = [heap newBufferWithLength:(NSUInteger)length
			                        options:allocOptions
			                         offset:aligned];
			if (buf != nil) {
				g_next_offset[heap_id] = aligned + sa.size;
				return (__bridge_retained void *)buf;
			}
			// Metal refused at this offset; advance past the failed
			// attempt so we don't re-hit the same offset next tier.
			g_next_offset[heap_id] = aligned + sa.size;
		}

		// Eviction pipeline: tier 0 -> LRU purge, tier 1 -> PSO flush.
		// Tier 2 has no additional eviction action; it's the final retry.
		if (tier == 0) {
			gfxaccel_heap_lru_purge_volatile();
		} else if (tier == 1) {
			gfxaccel_heap_pso_cache_clear();
		}
	}

	// Tier 3 - Loud failure. No silent fallback.
	os_log_fault(gfxaccel_heap_log(),
	             "Heap exhausted for heap_id=%u: alloc_buffer(length=%u) "
	             "failed after 3-tier eviction (next_offset=%lu, size=%lu, align=%lu)",
	             (unsigned)heap_id, (unsigned)length,
	             (unsigned long)g_next_offset[heap_id],
	             (unsigned long)sa.size, (unsigned long)sa.align);

	return NULL;
}

extern "C" void *gfxaccel_resources_heap_mm_alloc_texture(uint32_t heap_id,
                                                           void *descriptor)
{
	if (descriptor == NULL) {
		fprintf(stderr, "[gfxaccel-heap] alloc_texture: NULL descriptor\n");
		return NULL;
	}

	// Ensure heap exists (lazy create).
	if (gfxaccel_resources_heap_mm_get(heap_id) == NULL) {
		return NULL;
	}

	id<MTLHeap> heap = g_heaps[heap_id];
	MTLTextureDescriptor *desc = (__bridge MTLTextureDescriptor *)descriptor;

	// Bump allocator: query the device for the size+alignment of
	// the texture when placed in a heap (Metal's heap size-and-align API
	// lives on MTLDevice), align the bump offset up, call the :offset:
	// variant required by Placement heaps, advance the bump offset.
	id<MTLDevice> device = (__bridge id<MTLDevice>)SharedMetalDevice();
	MTLSizeAndAlign sa = [device heapTextureSizeAndAlignWithDescriptor:desc];

	id<MTLTexture> tex = nil;
	for (int tier = 0; tier < 3; ++tier) {
		NSUInteger aligned = align_offset_up(g_next_offset[heap_id], sa.align);

		// Over-commit pre-check: skip the Metal call to avoid the
		// Placement validation assertion.
		if (aligned + sa.size > g_heap_sizes[heap_id]) {
			// Fall through to eviction below.
		} else {
			tex = [heap newTextureWithDescriptor:desc offset:aligned];
			if (tex != nil) {
				g_next_offset[heap_id] = aligned + sa.size;
				return (__bridge_retained void *)tex;
			}
			// Metal refused at this offset; advance past it.
			g_next_offset[heap_id] = aligned + sa.size;
		}

		// Eviction pipeline: tier 0 -> LRU purge, tier 1 -> PSO flush.
		if (tier == 0) {
			gfxaccel_heap_lru_purge_volatile();
		} else if (tier == 1) {
			gfxaccel_heap_pso_cache_clear();
		}
	}

	// Tier 3 - Loud failure.
	os_log_fault(gfxaccel_heap_log(),
	             "Heap exhausted for heap_id=%u: alloc_texture failed "
	             "after 3-tier eviction (next_offset=%lu, size=%lu, align=%lu)",
	             (unsigned)heap_id,
	             (unsigned long)g_next_offset[heap_id],
	             (unsigned long)sa.size, (unsigned long)sa.align);

	return NULL;
}

// Per-heap bump-offset reset. Zeros g_next_offset[heap_id] and returns
// the number of bytes reclaimed (= the previous next_offset). Does NOT
// release g_heaps[heap_id] — only the offset counter is reset.
// Invalid heap_id is a no-op returning 0 (bounds check at function entry).
extern "C" uint64_t gfxaccel_resources_heap_mm_reset(uint32_t heap_id)
{
	if (heap_id >= kHeapCount) {
		return 0;
	}
	NSUInteger reclaimed = g_next_offset[heap_id];
	g_next_offset[heap_id] = 0;
	return (uint64_t)reclaimed;
}

extern "C" void gfxaccel_resources_heap_mm_lru_purge(void)
{
	// Walk heaps and set purgeable state to Empty for any heap that
	// has resources. This is the Tier 1 eviction action.
	for (int i = 0; i < kHeapCount; ++i) {
		if (g_heaps[i] != nil) {
			[g_heaps[i] setPurgeableState:MTLPurgeableStateEmpty];
		}
	}
}

extern "C" uint32_t gfxaccel_resources_heap_mm_heap_count(void)
{
	uint32_t count = 0;
	for (int i = 0; i < kHeapCount; ++i) {
		if (g_heaps[i] != nil) {
			count++;
		}
	}
	return count;
}

// ---------------------------------------------------------------------------
// Memory-warning handler
// ---------------------------------------------------------------------------

extern "C" void gfxaccel_handle_memory_warning(void)
{
	// Ensure semaphore exists.
	if (g_eviction_done_sem == NULL) {
		g_eviction_done_sem = dispatch_semaphore_create(0);
	}

	g_eviction_pending = true;

	dispatch_async(gfxaccel_emul_queue(), ^{
		// Run the eviction pipeline on the emul queue.
		gfxaccel_heap_lru_purge_volatile();
		gfxaccel_heap_pso_cache_clear();

		g_eviction_pending = false;
		dispatch_semaphore_signal(g_eviction_done_sem);
	});
}

extern "C" int32_t gfxaccel_heap_wait_for_eviction(uint64_t frame_interval_usec)
{
	if (!g_eviction_pending) {
		return kGfxAccelResNoErr;
	}
	if (g_eviction_done_sem == NULL) {
		return kGfxAccelResNoErr;
	}

	int64_t timeout_ns = (int64_t)frame_interval_usec * 1000;
	long result = dispatch_semaphore_wait(g_eviction_done_sem,
	                                      dispatch_time(DISPATCH_TIME_NOW,
	                                                    timeout_ns));
	if (result != 0) {
		os_log_fault(gfxaccel_heap_log(),
		             "Eviction wait timed out after %llu us — "
		             "frame skipped",
		             (unsigned long long)frame_interval_usec);
		return kGfxAccelResErrMemoryWarningTimeout;
	}

	return kGfxAccelResNoErr;
}

// ---------------------------------------------------------------------------
// Public wrappers (route through heap_mm_ variants)
// ---------------------------------------------------------------------------

// gfxaccel_resources_heap_get, gfxaccel_resources_heap_alloc_buffer,
// gfxaccel_resources_heap_alloc_texture, gfxaccel_resources_heap_engine_attach,
// gfxaccel_resources_heap_engine_detach are implemented in the .cpp side
// and call through to the _mm_ variants declared above.

// ---------------------------------------------------------------------------
// RaveRingBuffer implementation
//
// Triple-buffered ring for RAVE per-draw vertex staging. Eliminates 15+
// newBufferWithBytes: calls per frame. Allocated directly from the device
// (not from kHeapEngineRAVE heap) because CPU write access (memcpy) requires
// MTLResourceStorageModeShared, which is incompatible with the simulator's
// MTLStorageModePrivate heap requirement. Matches GL ring buffer allocation
// pattern (gl_metal_renderer.mm:641).
// ---------------------------------------------------------------------------

#define RAVE_RING_BUFFER_SIZE  (4 * 1024 * 1024)   // 4 MiB per slot (matches GL precedent)
#define RAVE_RING_BUFFER_COUNT 3                     // triple-buffered

static id<MTLBuffer> g_rave_ring_buffer = nil;
static uint32_t      g_rave_ring_slot_index = 0;
static NSUInteger    g_rave_ring_offset = 0;  // write offset within current slot
static dispatch_semaphore_t g_rave_ring_sem = NULL;

extern "C" int32_t gfxaccel_rave_ring_init(void)
{
	if (g_rave_ring_buffer != nil) {
		return kGfxAccelResNoErr;  // idempotent
	}

	id<MTLDevice> device = (__bridge id<MTLDevice>)SharedMetalDevice();
	if (device == nil) {
		fprintf(stderr, "[gfxaccel-heap] rave_ring_init: SharedMetalDevice() nil\n");
		return -4006;
	}

	NSUInteger totalSize = (NSUInteger)RAVE_RING_BUFFER_SIZE * RAVE_RING_BUFFER_COUNT;
	g_rave_ring_buffer = [device newBufferWithLength:totalSize
	                                         options:MTLResourceStorageModeShared];
	if (g_rave_ring_buffer == nil) {
		os_log_fault(gfxaccel_heap_log(),
		             "rave_ring_init: failed to allocate %lu byte ring buffer",
		             (unsigned long)totalSize);
		return -4006;
	}

	g_rave_ring_sem = dispatch_semaphore_create(RAVE_RING_BUFFER_COUNT);
	g_rave_ring_slot_index = 0;
	g_rave_ring_offset = 0;

	return kGfxAccelResNoErr;
}

extern "C" void gfxaccel_rave_ring_shutdown(void)
{
	g_rave_ring_buffer = nil;
	g_rave_ring_sem = NULL;
	g_rave_ring_slot_index = 0;
	g_rave_ring_offset = 0;
}

extern "C" void *gfxaccel_rave_ring_stage(const void *data, uint32_t size,
                                          uint32_t *out_offset)
{
	if (g_rave_ring_buffer == nil || data == NULL || out_offset == NULL) {
		return NULL;
	}

	// Align size to 256 bytes (Metal vertex buffer offset alignment).
	NSUInteger alignedSize = ((NSUInteger)size + 255) & ~(NSUInteger)255;

	// Check if current slot has room.
	if (g_rave_ring_offset + alignedSize > (NSUInteger)RAVE_RING_BUFFER_SIZE) {
		// Current slot full -- advance to next slot.
		// Wait on semaphore to ensure the next slot's GPU work is complete.
		dispatch_semaphore_wait(g_rave_ring_sem, DISPATCH_TIME_FOREVER);

		g_rave_ring_slot_index = (g_rave_ring_slot_index + 1) % RAVE_RING_BUFFER_COUNT;
		g_rave_ring_offset = 0;
	}

	NSUInteger slotBase = (NSUInteger)g_rave_ring_slot_index * RAVE_RING_BUFFER_SIZE;
	NSUInteger writeOff = slotBase + g_rave_ring_offset;

	// Verify write stays within slot boundary.
	if (writeOff + size > slotBase + RAVE_RING_BUFFER_SIZE) {
		fprintf(stderr, "[gfxaccel-heap] rave_ring_stage: size %u exceeds slot "
		        "capacity at offset %lu\n", (unsigned)size,
		        (unsigned long)g_rave_ring_offset);
		return NULL;
	}

	memcpy((char *)[g_rave_ring_buffer contents] + writeOff, data, size);
	*out_offset = (uint32_t)writeOff;

	g_rave_ring_offset += alignedSize;

	return (__bridge void *)g_rave_ring_buffer;
}

extern "C" void gfxaccel_rave_ring_frame_end(void)
{
	if (g_rave_ring_buffer == nil || g_rave_ring_sem == NULL) {
		return;
	}

	// Signal the semaphore to indicate this slot is done.
	// This is called after the command buffer for this frame is committed.
	// The GPU completion handler would ideally signal, but for simplicity
	// and matching GL's synchronous pattern, we signal here and rely on
	// the triple-buffering depth to absorb GPU latency.
	dispatch_semaphore_signal(g_rave_ring_sem);

	// Advance to next slot for the next frame.
	g_rave_ring_slot_index = (g_rave_ring_slot_index + 1) % RAVE_RING_BUFFER_COUNT;
	g_rave_ring_offset = 0;
}

extern "C" void *gfxaccel_rave_ring_buffer_ptr(void)
{
	if (g_rave_ring_buffer == nil) {
		return NULL;
	}
	return (__bridge void *)g_rave_ring_buffer;
}

// ---------------------------------------------------------------------------
// TESTING_BUILD helpers
// ---------------------------------------------------------------------------

#ifdef TESTING_BUILD

extern "C" void gfxaccel_resources_heap_mm_set_ceiling(uint32_t heap_id,
                                                        uint32_t bytes)
{
	if (heap_id >= kHeapCount) {
		return;
	}
	if (bytes == 0) {
		g_heap_sizes[heap_id] = g_heap_defaults[heap_id];
	} else {
		g_heap_sizes[heap_id] = (NSUInteger)bytes;
	}
}

// Bump-allocator introspection hooks for the PlacementHeapSubAllocatorTests
// regression suite. These are NOT exposed outside TESTING_BUILD; production
// callers should never inspect next_offset directly.

extern "C" uint64_t gfxaccel_heap_testing_next_offset(uint32_t heap_id)
{
	if (heap_id >= kHeapCount) {
		return 0;
	}
	return (uint64_t)g_next_offset[heap_id];
}

extern "C" uint64_t gfxaccel_heap_testing_heap_size(uint32_t heap_id)
{
	if (heap_id >= kHeapCount) {
		return 0;
	}
	return (uint64_t)g_heap_sizes[heap_id];
}

// Returns 1 if the heap was created with MTLHeapTypePlacement, 0 if
// Automatic, -1 if the heap has not been created yet. The iOS-17 gate
// test uses this to assert the Placement policy fired.
extern "C" int32_t gfxaccel_heap_testing_is_placement(uint32_t heap_id)
{
	if (heap_id >= kHeapCount) {
		return -1;
	}
	if (g_heaps[heap_id] == nil) {
		return -1;
	}
	return (g_heaps[heap_id].type == MTLHeapTypePlacement) ? 1 : 0;
}

#endif /* TESTING_BUILD */
