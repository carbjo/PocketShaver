/*
 *  gfxaccel_resources_heap.h - Per-engine MTLHeap sub-allocator.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Per-engine MTLHeap sub-allocator, PSO cache, LRU purgeable list,
 *  three-tier eviction pipeline, ring buffer primitive, and
 *  memory-warning C shim entry point.
 *
 *  Design notes:
 *    - Separate module from gfxaccel_resources.{h,cpp,mm}.
 *    - Four MTLHeaps (NQD / RAVE / GL / Compositor).
 *    - iOS 17+ -> MTLHeapTypePlacement; 13.4-16.x -> Automatic.
 *    - Per-heap ceilings (32 / 128 / 96 / 48 MiB).
 *    - Heap creation is lazy (first use, not init).
 *    - Three-tier eviction: LRU purge -> PSO flush -> loud assert.
 *    - Memory-warning C shim called from Swift observer.
 *    - Compositor handshake via dispatch_semaphore.
 *    - In-memory PSO cache (std::unordered_map).
 *    - Engine attach/detach plugs into the resource fan-out.
 *
 *  Threading: single-writer from PPC emul thread. Memory-warning
 *  handler marshals main -> emul via dispatch_async onto a serial queue
 *  owned by this module. NO std::mutex, NO std::atomic.
 *
 *  C-callable throughout: the header can be included from .cpp, .mm, or
 *  Swift-via-bridging-header without pulling in Metal types; id<MTLHeap>,
 *  id<MTLBuffer>, id<MTLTexture> return values are exposed as void* and
 *  bridge-cast inside the .mm implementation.
 */

#ifndef GFXACCEL_RESOURCES_HEAP_H
#define GFXACCEL_RESOURCES_HEAP_H

#include <stdint.h>

#include "gfxaccel_resources.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * GfxHeapId enum.
 *
 * Four heaps partition ownership:
 *   - NQD:        mask buffer, scratch textures (engine-private).
 *   - RAVE:       overlay texture + per-draw vertex/index ring buffer.
 *   - GL:         overlay texture + ring buffers + uniform buffers.
 *   - Compositor: resources crossing the engine<->compositor boundary
 *                 (DepthStencil, palette buffer, overlay textures vended
 *                 by vend_overlay_texture).
 */
typedef enum {
	kHeapEngineNQD   = 0,
	kHeapEngineRAVE  = 1,
	kHeapEngineGL    = 2,
	kHeapCompositor  = 3,
	kHeapEngineDSp   = 4,   // 5th per-engine heap; exempt from on_mode_exit reset (bump-with-conditional-reset).
	kHeapCount       = 5
} GfxHeapId;

/*
 * Error codes extending the -4000 block (-4001..-4006 used elsewhere).
 */
enum GfxAccelHeapError {
	kGfxAccelResErrHeapExhausted       = -4007,
	kGfxAccelResErrMemoryWarningTimeout = -4008
};

/*
 * Per-heap ceilings. Initial values; tunable via UAT.
 * CI assertion in HeapBudgetTests.testHeapBudgetsWithinClassFloor
 * verifies the sum + system overhead stays below kHeapCeiling_TotalMax.
 */
#define kHeapCeiling_NQD            (32  * 1024 * 1024)
#define kHeapCeiling_RAVE           (128 * 1024 * 1024)
#define kHeapCeiling_GL             (96  * 1024 * 1024)
#define kHeapCeiling_Compositor     (48  * 1024 * 1024)
#define kHeapCeiling_DSp            (32  * 1024 * 1024)  // back buffers + per-context overlays (32 MiB)
#define kHeapCeiling_SystemOverhead (96  * 1024 * 1024)
#define kHeapCeiling_TotalMax       (544 * 1024 * 1024)  // was 512; +32 MiB for the DSp heap

/* --- Lifecycle --- */

/*
 * Initialize the heap sub-allocator. Idempotent - a second call returns
 * kGfxAccelResNoErr without side effects. Must be called after
 * SharedMetalDevice() is available.
 *
 * Heaps themselves are NOT created here (lazy on first use).
 */
int32_t gfxaccel_resources_heap_init(void);

/*
 * Shut down the heap sub-allocator. Releases all heaps, clears the PSO
 * cache, drains the LRU list. Idempotent.
 */
void gfxaccel_resources_heap_shutdown(void);

/* --- Heap access + sub-allocation --- */

/*
 * Return the MTLHeap for the given heap_id as void*. Lazy-creates the
 * heap on first call. Returns NULL if heap creation fails.
 */
void *gfxaccel_resources_heap_get(uint32_t heap_id);

/*
 * Sub-allocate a buffer from the named heap. Returns id<MTLBuffer> as
 * void*. On failure (heap exhausted after eviction), returns NULL.
 * options: MTLResourceOptions (e.g. MTLResourceStorageModeShared).
 */
void *gfxaccel_resources_heap_alloc_buffer(uint32_t heap_id,
                                           uint32_t length,
                                           uint32_t options);

/*
 * Sub-allocate a texture from the named heap. Returns id<MTLTexture>
 * as void*. descriptor is id<MTLTextureDescriptor> passed as void*.
 * On failure (heap exhausted after eviction), returns NULL.
 */
void *gfxaccel_resources_heap_alloc_texture(uint32_t heap_id,
                                            void *descriptor);

/*
 * Reset the bump allocator's offset counter for a single heap. Returns
 * the number of bytes reclaimed (equal to the previous next_offset).
 * Idempotent: a second call on a freshly-reset heap returns 0.
 * Does NOT release the underlying MTLHeap — only resets the offset.
 *
 * Typically called from the DMC on_mode_exit fan-out (bump allocator is
 * per-mode-scope). Direct callers outside the DMC subscriber exist for
 * tests only. Invalid heap_id (>= kHeapCount) is a no-op that returns 0.
 */
uint64_t gfxaccel_resources_heap_reset(uint32_t heap_id);

/* --- Engine attach/detach --- */

/*
 * Notify the heap sub-allocator that an engine is attaching during a
 * DMC mode-enter transition. Lazy-creates the heap on first attach.
 * incoming may be NULL (for initial creation without a mode snapshot).
 */
void gfxaccel_resources_heap_engine_attach(uint32_t engine_id,
                                           const struct DMCModeSnapshot *incoming);

/*
 * Notify the heap sub-allocator that an engine is detaching during a
 * DMC mode-exit transition. Does NOT release the heap (heap persists
 * for potential re-attach). outgoing may be NULL.
 */
void gfxaccel_resources_heap_engine_detach(uint32_t engine_id,
                                           const struct DMCModeSnapshot *outgoing);

/* --- Memory-warning handler --- */

/*
 * C shim called from the Swift MemoryWarningObserver on the main thread.
 * dispatch_async's the eviction work to the emul serial queue and returns
 * immediately (<=1 ms on main thread).
 */
void gfxaccel_handle_memory_warning(void);

/*
 * Compositor handshake: called from SubmitFrame to wait for
 * an in-progress eviction to complete before presenting. Blocks for
 * up to frame_interval_usec microseconds. Returns kGfxAccelResNoErr
 * if eviction completed (or none was pending), or
 * kGfxAccelResErrMemoryWarningTimeout if the timeout expired.
 */
int32_t gfxaccel_heap_wait_for_eviction(uint64_t frame_interval_usec);

/* --- Eviction pipeline --- */

/*
 * Tier 1: purge LRU volatile resources. Called as part of the eviction
 * pipeline or independently.
 */
void gfxaccel_heap_lru_purge_volatile(void);

/*
 * Tier 2: flush the in-memory PSO cache. Drops all cached
 * pipeline states. Next frame pays recompile cost.
 */
void gfxaccel_heap_pso_cache_clear(void);

/* --- RAVE Ring Buffer --- */

/*
 * Initialize the RAVE triple-buffered ring buffer. Allocates a single
 * MTLBuffer of RAVE_RING_BUFFER_SIZE * RAVE_RING_BUFFER_COUNT (4 MiB x 3)
 * from the device (MTLResourceStorageModeShared for CPU write access).
 * Creates dispatch_semaphore for triple-buffer synchronization.
 * Idempotent. Returns 0 on success, -4006 on failure.
 */
int32_t gfxaccel_rave_ring_init(void);

/*
 * Shut down the RAVE ring buffer. Releases the MTLBuffer and semaphore.
 */
void gfxaccel_rave_ring_shutdown(void);

/*
 * Stage vertex data into the ring buffer. Copies 'size' bytes from 'data'
 * into the current write position. Sets *out_offset to the byte offset
 * into the ring buffer for use with setVertexBuffer:offset:atIndex:.
 * Advances write offset by size aligned to 256 bytes.
 * If current slot overflows, advances to next slot (waits on semaphore).
 * Returns the ring buffer as void* (caller bridge-casts to id<MTLBuffer>).
 * Returns NULL if ring is not initialized or data/out_offset is NULL.
 */
void *gfxaccel_rave_ring_stage(const void *data, uint32_t size,
                               uint32_t *out_offset);

/*
 * Called at end of RAVE frame submission (after command buffer commit).
 * Signals the semaphore and advances to the next ring slot.
 */
void gfxaccel_rave_ring_frame_end(void);

/*
 * Returns the ring buffer as void* for direct setVertexBuffer calls.
 * Returns NULL if ring is not initialized.
 */
void *gfxaccel_rave_ring_buffer_ptr(void);

/* --- TESTING_BUILD introspection --- */
#ifdef TESTING_BUILD

/*
 * Returns 1 if gfxaccel_resources_heap_init() has completed and
 * shutdown has not reset, 0 otherwise.
 */
uint32_t gfxaccel_heap_testing_is_initialized(void);

/*
 * Returns the count of non-nil heaps currently alive.
 */
uint32_t gfxaccel_heap_testing_heap_count(void);

/*
 * Returns the number of entries in the PSO cache.
 */
uint32_t gfxaccel_heap_testing_pso_cache_count(void);

/*
 * Full teardown + reset for test isolation.
 */
void gfxaccel_heap_testing_reset(void);

/*
 * Override the ceiling for a specific heap_id (bytes). Pass 0 to
 * restore the default ceiling. Used by tests to pin a small budget.
 */
void gfxaccel_heap_testing_set_ceiling(uint32_t heap_id, uint32_t bytes);

/*
 * Bump-allocator introspection hooks.
 *
 * gfxaccel_heap_testing_next_offset: returns the current per-heap bump
 * offset (advances on each alloc; reset on DMC on_mode_exit / shutdown).
 *
 * gfxaccel_heap_testing_heap_size: returns the heap's size in bytes
 * (matches the testing ceiling if set; otherwise the default ceiling).
 *
 * gfxaccel_heap_testing_is_placement: returns 1 if the heap was created
 * with MTLHeapTypePlacement, 0 if Automatic, -1 if the heap has not
 * been created yet. Used to assert the iOS-17 Placement gate fired.
 */
uint64_t gfxaccel_heap_testing_next_offset(uint32_t heap_id);
uint64_t gfxaccel_heap_testing_heap_size(uint32_t heap_id);
int32_t  gfxaccel_heap_testing_is_placement(uint32_t heap_id);

#endif /* TESTING_BUILD */

#ifdef __cplusplus
}
#endif

#endif /* GFXACCEL_RESOURCES_HEAP_H */
