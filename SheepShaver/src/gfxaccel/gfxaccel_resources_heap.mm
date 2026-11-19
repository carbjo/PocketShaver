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
 *  Metal side of gfxaccel_resources_heap: lazy per-engine MTLHeaps with a
 *  bump sub-allocator (Placement heaps on iOS 17+, reset on DMC mode exit),
 *  standalone budgeted DSp buffers, three-tier eviction (LRU purge, PSO
 *  flush, loud fail), and the RAVE vertex ring.
 *
 *  Threading: heap alloc/reset/purge is single-writer on the engine call
 *  path. The memory-warning callback only sets an atomic pending flag.
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <os/log.h>
#import <TargetConditionals.h>
#import <objc/runtime.h>

#include <cstdint>
#include <cstdio>
#include <dispatch/dispatch.h>
#include <array>
#include <atomic>
#include <memory>

#include "gfxaccel_resources_heap.h"
#include "gfxaccel_live_buffer_budget.h"
#include "metal_device_shared.h"

static id<MTLHeap> g_heaps[kHeapCount] = { nil, nil, nil, nil, nil };

// Per-heap bump offset, reset to 0 on DMC on_mode_exit. Emul thread only.
static NSUInteger g_next_offset[kHeapCount] = { 0, 0, 0, 0, 0 };

// Per-heap live sub-allocation count. A placement heap's bump offset can only
// be reset when this is zero; otherwise offset 0 could alias a live resource.
static uint32_t g_live_allocations[kHeapCount] = { 0, 0, 0, 0, 0 };

// Tracks heaps explicitly marked MTLPurgeableStateEmpty by eviction. A heap
// set Empty is restored to NonVolatile before the next placement allocation.
static bool g_heap_purgeable_empty[kHeapCount] = { false, false, false, false, false };

// Per-heap GPU-completion latch. Heaps are hazard-untracked and
// g_live_allocations tracks CPU ownership only, so a reset while a command
// buffer is still in flight could placement-alias bytes the GPU is reading.
// Engines note each command buffer that touches heap memory before commit;
// reset defers (returns 0) while pending != completed. pending is written
// on the emul thread; completed is bumped from Metal's completion thread.
static uint64_t g_gpu_commits_pending[kHeapCount] = { 0, 0, 0, 0, 0 };
static std::atomic<uint64_t> g_gpu_commits_completed[kHeapCount];

// Heap sizes; overridable via gfxaccel_heap_testing_set_ceiling.
static NSUInteger g_heap_sizes[kHeapCount] = {
	kHeapCeiling_NQD,
	kHeapCeiling_RAVE,
	kHeapCeiling_GL,
	kHeapCeiling_Compositor,
	kHeapCeiling_DSp
};

static const NSUInteger g_heap_defaults[kHeapCount] = {
	kHeapCeiling_NQD,
	kHeapCeiling_RAVE,
	kHeapCeiling_GL,
	kHeapCeiling_Compositor,
	kHeapCeiling_DSp
};

static os_log_t gfxaccel_heap_log(void)
{
	static os_log_t log = NULL;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		log = os_log_create("com.carbjo.pocketshaver.gfxaccel", "heap");
	});
	return log;
}

static std::atomic_bool g_eviction_pending(false);

// DSp buffers have independent lifetimes (a back buffer may outlive hundreds
// of alt buffers), so they are device allocations, not placement ranges.
// The budget is charged via an associated token that lives as long as the
// MTLBuffer (command buffers and texture views retain it). Each shutdown
// starts a fresh budget so late frees cannot debit a new session.
static std::shared_ptr<GfxAccelLiveBufferBudget> g_dsp_buffer_budget =
    std::make_shared<GfxAccelLiveBufferBudget>();
static char g_dsp_buffer_charge_key;

@interface GfxAccelDSpBufferCharge : NSObject {
@public
    std::shared_ptr<GfxAccelLiveBufferBudget> budget;
    uint64_t bytes;
}
@end
@implementation GfxAccelDSpBufferCharge
- (void)dealloc
{
    if (budget) budget->release(bytes);
}
@end

extern "C" void gfxaccel_heap_lru_purge_volatile(void);
extern "C" void gfxaccel_heap_pso_cache_clear(void);

// Align up with a 256-byte floor (Metal may report as low as 16; 256 also
// matches the RAVE ring stride).
static inline NSUInteger align_offset_up(NSUInteger offset,
                                          NSUInteger alignment)
{
	if (alignment == 0) {
		alignment = 256;
	}
	NSUInteger a = alignment < 256 ? 256 : alignment;
	return (offset + (a - 1)) & ~(a - 1);
}

static bool restore_heap_if_purgeable(uint32_t heap_id)
{
	if (heap_id >= kHeapCount || g_heaps[heap_id] == nil) {
		return false;
	}
	if (!g_heap_purgeable_empty[heap_id]) {
		return true;
	}

	MTLPurgeableState previous =
	    [g_heaps[heap_id] setPurgeableState:MTLPurgeableStateNonVolatile];
	g_heap_purgeable_empty[heap_id] = false;
	if (previous == MTLPurgeableStateEmpty) {
		os_log(gfxaccel_heap_log(),
		       "heap_id=%u restored from MTLPurgeableStateEmpty before reuse",
		       (unsigned)heap_id);
	}
	return true;
}

// ---------------------------------------------------------------------------
// Called from gfxaccel_resources_heap.cpp
// ---------------------------------------------------------------------------

extern "C" void gfxaccel_resources_heap_mm_init(void)
{
	// Heaps are created lazily.
	g_eviction_pending.store(false, std::memory_order_release);
}

extern "C" void gfxaccel_resources_heap_mm_shutdown(void)
{
	for (int i = 0; i < kHeapCount; ++i) {
		g_heaps[i] = nil;
	}

	for (int i = 0; i < kHeapCount; ++i) {
		g_heap_sizes[i] = g_heap_defaults[i];
	}

	for (int i = 0; i < kHeapCount; ++i) {
		g_next_offset[i] = 0;
	}

	// All sub-allocations were released with the heaps.
	for (int i = 0; i < kHeapCount; ++i) {
		g_live_allocations[i] = 0;
	}

	for (int i = 0; i < kHeapCount; ++i) {
		g_heap_purgeable_empty[i] = false;
	}

	// Outstanding DSp resources retain their own accounting generation.
	g_dsp_buffer_budget = std::make_shared<GfxAccelLiveBufferBudget>();

	g_eviction_pending.store(false, std::memory_order_release);
}

extern "C" void *gfxaccel_resources_heap_mm_get(uint32_t heap_id)
{
	if (heap_id >= kHeapCount) {
		return NULL;
	}

	if (g_heaps[heap_id] != nil) {
		restore_heap_if_purgeable(heap_id);
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
	// The simulator's Metal driver requires Private storage for heaps.
	desc.storageMode = MTLStorageModePrivate;
#else
	desc.storageMode = MTLStorageModeShared;
#endif
	desc.hazardTrackingMode = MTLHazardTrackingModeUntracked;

	// Placement on iOS 17+ for exact accounting (alloc uses the :offset:
	// variants); Automatic on older iOS.
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
	g_heap_purgeable_empty[heap_id] = false;

	return (__bridge void *)g_heaps[heap_id];
}

// Device buffers keep Shared storage even on the simulator, unlike heaps.
static void *alloc_dsp_buffer(uint32_t length, uint32_t options)
{
    if (length == 0) return NULL;
    id<MTLDevice> device = (__bridge id<MTLDevice>)SharedMetalDevice();
    if (!device) return NULL;
    MTLResourceOptions allocOptions = (MTLResourceOptions)options;
    // Reserve the requested length, then reconcile with allocatedSize.
    const uint64_t predicted = length;
    for (int tier = 0; tier < 3; ++tier) {
        if (g_dsp_buffer_budget->reserve(predicted, g_heap_sizes[kHeapEngineDSp])) {
            id<MTLBuffer> buffer = [device newBufferWithLength:length options:allocOptions];
            uint64_t charge = predicted;
            if (buffer) {
                const uint64_t actual = buffer.allocatedSize;
                // Reject if the real footprint pushes past budget.
                if (actual > charge) {
                    if (g_dsp_buffer_budget->reserve(actual - charge,
                                                    g_heap_sizes[kHeapEngineDSp])) {
                        charge = actual;
                    } else {
                        buffer = nil;
                    }
                } else if (actual != 0 && actual < charge) {
                    g_dsp_buffer_budget->release(charge - actual);
                    charge = actual;
                }
            }
            if (buffer) {
                GfxAccelDSpBufferCharge *token = [GfxAccelDSpBufferCharge new];
                token->budget = g_dsp_buffer_budget;
                token->bytes = charge;
                objc_setAssociatedObject(buffer, &g_dsp_buffer_charge_key, token,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                g_live_allocations[kHeapEngineDSp]++;
                return (__bridge_retained void *)buffer;
            }
            g_dsp_buffer_budget->release(charge);
        }
        if (tier == 0) gfxaccel_heap_lru_purge_volatile();
        else if (tier == 1) gfxaccel_heap_pso_cache_clear();
    }
    os_log_fault(gfxaccel_heap_log(),
                 "DSp live-buffer budget exhausted: alloc_buffer(length=%u)", length);
    return NULL;
}

extern "C" void *gfxaccel_resources_heap_mm_alloc_buffer(uint32_t heap_id,
                                                          uint32_t length,
                                                          uint32_t options)
{
    if (heap_id == kHeapEngineDSp) return alloc_dsp_buffer(length, options);
	if (gfxaccel_resources_heap_mm_get(heap_id) == NULL) {
		return NULL;
	}

	id<MTLHeap> heap = g_heaps[heap_id];

	// Simulator heaps are Private; buffer options must match.
#if TARGET_OS_SIMULATOR
	MTLResourceOptions allocOptions = MTLResourceStorageModePrivate;
#else
	MTLResourceOptions allocOptions = (MTLResourceOptions)options;
#endif

	// Size/align queries live on MTLDevice, not MTLHeap.
	id<MTLDevice> device = (__bridge id<MTLDevice>)SharedMetalDevice();
	MTLSizeAndAlign sa = [device heapBufferSizeAndAlignWithLength:(NSUInteger)length
	                                                       options:allocOptions];

	id<MTLBuffer> buf = nil;
	for (int tier = 0; tier < 3; ++tier) {
		restore_heap_if_purgeable(heap_id);
		NSUInteger aligned = align_offset_up(g_next_offset[heap_id], sa.align);

		// Skip the Metal call on over-commit: Placement would assert.
		if (aligned + sa.size > g_heap_sizes[heap_id]) {
			// Fall through to eviction below.
		} else {
			// :offset: is Placement-only. Automatic heaps place the buffer
			// themselves and the bump offset is accounting only.
			if (heap.type == MTLHeapTypePlacement) {
				buf = [heap newBufferWithLength:(NSUInteger)length
				                        options:allocOptions
				                         offset:aligned];
			} else {
				buf = [heap newBufferWithLength:(NSUInteger)length
				                        options:allocOptions];
			}
			if (buf != nil) {
				g_next_offset[heap_id] = aligned + sa.size;
				g_live_allocations[heap_id]++;
				return (__bridge_retained void *)buf;
			}
			// Metal refused this offset; skip past it for the next tier.
			g_next_offset[heap_id] = aligned + sa.size;
		}

		// Tier 0 -> LRU purge, tier 1 -> PSO flush, tier 2 is the final retry.
		if (tier == 0) {
			gfxaccel_heap_lru_purge_volatile();
		} else if (tier == 1) {
			gfxaccel_heap_pso_cache_clear();
		}
	}

	// No silent fallback.
	os_log_fault(gfxaccel_heap_log(),
	             "Heap exhausted for heap_id=%u: alloc_buffer(length=%u) "
	             "failed after 3-tier eviction (next_offset=%lu, size=%lu, align=%lu)",
	             (unsigned)heap_id, (unsigned)length,
	             (unsigned long)g_next_offset[heap_id],
	             (unsigned long)sa.size, (unsigned long)sa.align);

	return NULL;
}

// Zeros the bump offset (the heap itself is kept) and returns the bytes
// reclaimed, or 0 if deferred. gpu_idle_asserted skips the GPU-completion
// latch for callers that already waited on the queue; the live-allocation
// gate always applies.
static uint64_t heap_mm_reset_internal(uint32_t heap_id,
                                       bool gpu_idle_asserted)
{
	if (heap_id >= kHeapCount) {
		return 0;
	}
	if (g_live_allocations[heap_id] != 0) {
		os_log_fault(gfxaccel_heap_log(),
		             "heap reset skipped for heap_id=%u: %u live sub-allocations "
		             "(next_offset=%lu)",
		             (unsigned)heap_id,
		             (unsigned)g_live_allocations[heap_id],
		             (unsigned long)g_next_offset[heap_id]);
		fprintf(stderr,
		        "[gfxaccel-heap] reset skipped: heap_id=%u live=%u "
		        "next_offset=%llu\n",
		        (unsigned)heap_id,
		        (unsigned)g_live_allocations[heap_id],
		        (unsigned long long)g_next_offset[heap_id]);
		return 0;
	}
	if (!gpu_idle_asserted &&
	    g_gpu_commits_completed[heap_id].load(std::memory_order_acquire) <
	        g_gpu_commits_pending[heap_id]) {
		// Expected transient: the DSp VBL release drain retries next tick.
		os_log(gfxaccel_heap_log(),
		       "heap reset deferred for heap_id=%u: command buffer(s) "
		       "referencing this heap still in flight (next_offset=%lu)",
		       (unsigned)heap_id,
		       (unsigned long)g_next_offset[heap_id]);
		return 0;
	}
	NSUInteger reclaimed = g_next_offset[heap_id];
	g_next_offset[heap_id] = 0;
	return (uint64_t)reclaimed;
}

extern "C" uint64_t gfxaccel_resources_heap_mm_reset(uint32_t heap_id)
{
	return heap_mm_reset_internal(heap_id, false);
}

extern "C" uint64_t gfxaccel_resources_heap_reset_gpu_idle(uint32_t heap_id)
{
	return heap_mm_reset_internal(heap_id, true);
}

extern "C" void gfxaccel_resources_heap_note_gpu_commit(uint32_t heap_id,
                                                         void *command_buffer)
{
	if (heap_id >= kHeapCount || command_buffer == NULL) {
		return;
	}
	id<MTLCommandBuffer> cmd = (__bridge id<MTLCommandBuffer>)command_buffer;
	std::atomic<uint64_t> *completed = &g_gpu_commits_completed[heap_id];
	g_gpu_commits_pending[heap_id]++;
	[cmd addCompletedHandler:^(id<MTLCommandBuffer> completedCommandBuffer) {
		(void)completedCommandBuffer;
		completed->fetch_add(1, std::memory_order_release);
	}];
}

extern "C" void gfxaccel_resources_heap_mm_note_allocation_released(uint32_t heap_id)
{
	if (heap_id >= kHeapCount) {
		return;
	}
	if (g_live_allocations[heap_id] == 0) {
		os_log_fault(gfxaccel_heap_log(),
		             "heap live allocation underflow for heap_id=%u",
		             (unsigned)heap_id);
		fprintf(stderr,
		        "[gfxaccel-heap] live allocation underflow: heap_id=%u\n",
		        (unsigned)heap_id);
		return;
	}
	g_live_allocations[heap_id]--;
}

extern "C" uint32_t gfxaccel_resources_heap_mm_live_allocation_count(uint32_t heap_id)
{
	if (heap_id >= kHeapCount) {
		return 0;
	}
	return g_live_allocations[heap_id];
}

extern "C" void gfxaccel_resources_heap_mm_lru_purge(void)
{
	// Only heaps with no live resources: Empty makes contents discardable.
	for (int i = 0; i < kHeapCount; ++i) {
		if (g_heaps[i] == nil) {
			continue;
		}
		if (g_live_allocations[i] != 0) {
			os_log(gfxaccel_heap_log(),
			       "heap purge skipped for heap_id=%d: %u live sub-allocations",
			       i, (unsigned)g_live_allocations[i]);
			continue;
		}
		[g_heaps[i] setPurgeableState:MTLPurgeableStateEmpty];
		g_heap_purgeable_empty[i] = true;
	}
}

// ---------------------------------------------------------------------------
// Memory-warning handler
// ---------------------------------------------------------------------------

extern "C" void gfxaccel_handle_memory_warning(void)
{
	g_eviction_pending.store(true, std::memory_order_release);
}

extern "C" int32_t gfxaccel_heap_wait_for_eviction(uint64_t frame_interval_usec)
{
	(void)frame_interval_usec;
	if (!g_eviction_pending.exchange(false, std::memory_order_acq_rel)) {
		return kGfxAccelResNoErr;
	}

	gfxaccel_heap_lru_purge_volatile();
	gfxaccel_heap_pso_cache_clear();
	return kGfxAccelResNoErr;
}

// ---------------------------------------------------------------------------
// RAVE vertex ring
//
// Triple-buffered staging for per-draw RAVE vertices. Device-allocated, not
// from the RAVE heap, because memcpy needs Shared storage and simulator
// heaps are Private.
// ---------------------------------------------------------------------------

#define RAVE_RING_BUFFER_SIZE  GFXACCEL_RAVE_RING_SLOT_BYTES
#define RAVE_RING_BUFFER_COUNT 3

static id<MTLBuffer> g_rave_ring_buffer = nil;
// Only the emulation thread changes ownership/offsets. Completion handlers
// return the individual slot credit without touching that bookkeeping.
static dispatch_semaphore_t g_rave_ring_slot_sems[RAVE_RING_BUFFER_COUNT];
static void *g_rave_ring_slot_owners[RAVE_RING_BUFFER_COUNT];
static NSUInteger g_rave_ring_slot_offsets[RAVE_RING_BUFFER_COUNT];

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

	for (uint32_t i = 0; i < RAVE_RING_BUFFER_COUNT; i++) {
		g_rave_ring_slot_sems[i] = dispatch_semaphore_create(1);
		g_rave_ring_slot_owners[i] = NULL;
		g_rave_ring_slot_offsets[i] = 0;
	}

	return kGfxAccelResNoErr;
}

extern "C" void gfxaccel_rave_ring_shutdown(void)
{
	g_rave_ring_buffer = nil;
	for (uint32_t i = 0; i < RAVE_RING_BUFFER_COUNT; i++) {
		g_rave_ring_slot_sems[i] = NULL;
		g_rave_ring_slot_owners[i] = NULL;
		g_rave_ring_slot_offsets[i] = 0;
	}
}

extern "C" void *gfxaccel_rave_ring_stage(void *command_buffer,
                                          const void *data, uint32_t size,
                                          uint32_t *out_offset)
{
	if (g_rave_ring_buffer == nil || command_buffer == NULL ||
	    data == NULL || out_offset == NULL || size == 0) return NULL;

	NSUInteger alignedSize = ((NSUInteger)size + 255) & ~(NSUInteger)255;
	if (alignedSize > (NSUInteger)RAVE_RING_BUFFER_SIZE) return NULL;

	uint32_t slot = RAVE_RING_BUFFER_COUNT;
	for (uint32_t i = 0; i < RAVE_RING_BUFFER_COUNT; i++) {
		if (g_rave_ring_slot_owners[i] == command_buffer &&
		    g_rave_ring_slot_offsets[i] + alignedSize <= RAVE_RING_BUFFER_SIZE) {
			slot = i;
			break;
		}
	}
	if (slot == RAVE_RING_BUFFER_COUNT) {
		for (uint32_t i = 0; i < RAVE_RING_BUFFER_COUNT; i++) {
			if (g_rave_ring_slot_owners[i] == NULL &&
			    g_rave_ring_slot_sems[i] != NULL &&
			    dispatch_semaphore_wait(g_rave_ring_slot_sems[i], DISPATCH_TIME_NOW) == 0) {
				slot = i;
				g_rave_ring_slot_owners[i] = command_buffer;
				g_rave_ring_slot_offsets[i] = 0;
				break;
			}
		}
	}
	// Other contexts may hold every slot in unsubmitted passes. Never wait
	// for them on the emulation thread: the caller uses a dedicated upload.
	if (slot == RAVE_RING_BUFFER_COUNT) return NULL;

	NSUInteger writeOff = (NSUInteger)slot * RAVE_RING_BUFFER_SIZE +
	                      g_rave_ring_slot_offsets[slot];
	memcpy((char *)g_rave_ring_buffer.contents + writeOff, data, size);
	*out_offset = (uint32_t)writeOff;
	g_rave_ring_slot_offsets[slot] += alignedSize;
	return (__bridge void *)g_rave_ring_buffer;
}

extern "C" void gfxaccel_rave_ring_frame_end(void *command_buffer)
{
	id<MTLCommandBuffer> cmd = (__bridge id<MTLCommandBuffer>)command_buffer;
	if (g_rave_ring_buffer == nil || cmd == nil) return;

	// Capture only this command buffer's credits. An empty submission on
	// another context must not release an unsubmitted pass's vertex data.
	std::array<dispatch_semaphore_t, RAVE_RING_BUFFER_COUNT> sems = {};
	bool consumed = false;
	for (uint32_t i = 0; i < RAVE_RING_BUFFER_COUNT; i++) {
		if (g_rave_ring_slot_owners[i] != command_buffer) continue;
		sems[i] = g_rave_ring_slot_sems[i];
		g_rave_ring_slot_owners[i] = NULL;
		consumed = true;
	}
	if (!consumed) return;
	[cmd addCompletedHandler:^(id<MTLCommandBuffer> completedCommandBuffer) {
		(void)completedCommandBuffer;
		for (dispatch_semaphore_t sem : sems) {
			if (sem != NULL) dispatch_semaphore_signal(sem);
		}
	}];
}

extern "C" int32_t gfxaccel_rave_ring_submission_near_exhaustion(void *command_buffer)
{
	if (g_rave_ring_buffer == nil || command_buffer == NULL) return 0;
	uint32_t slots = 0;
	for (uint32_t i = 0; i < RAVE_RING_BUFFER_COUNT; i++) {
		if (g_rave_ring_slot_owners[i] == command_buffer) slots++;
	}
	return slots >= RAVE_RING_BUFFER_COUNT - 1 ? 1 : 0;
}
