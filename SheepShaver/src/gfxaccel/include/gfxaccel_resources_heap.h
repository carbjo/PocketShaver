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
 *  Per-engine Metal heap bump sub-allocator, PSO cache, LRU purge list,
 *  eviction pipeline (LRU purge, PSO flush, loud fail) and the RAVE vertex
 *  ring. Heaps are created lazily, Placement on iOS 17+ and Automatic
 *  before. Bump reset is legal only with no live sub-allocations.
 *
 *  Emul thread only, except the memory-warning entry point, which just sets
 *  an atomic flag. Metal objects are exposed as void* so the header works
 *  from .cpp, .mm and Swift.
 */

#ifndef GFXACCEL_RESOURCES_HEAP_H
#define GFXACCEL_RESOURCES_HEAP_H

#include <stdint.h>

#include "gfxaccel_resources.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Heap ownership:
 *   NQD:        mask buffer and scratch textures.
 *   RAVE, GL:   engine-private transient resources.
 *   Compositor: resources crossing the engine/compositor boundary.
 *   DSp:        back and alt buffers.
 */
typedef enum {
	kHeapEngineNQD   = 0,
	kHeapEngineRAVE  = 1,
	kHeapEngineGL    = 2,
	kHeapCompositor  = 3,
	kHeapEngineDSp   = 4,   // Live device-buffer budget, independent of placement heap resets.
	kHeapCount       = 5
} GfxHeapId;

/* Extends the -4000 block; -4001..-4006 are used elsewhere. */
enum GfxAccelHeapError {
	kGfxAccelResErrHeapExhausted       = -4007,
	kGfxAccelResErrMemoryWarningTimeout = -4008
};

/* Per-heap ceilings. The sum plus system overhead must stay under
 * kHeapCeiling_TotalMax. */
#define kHeapCeiling_NQD            (32  * 1024 * 1024)
#define kHeapCeiling_RAVE           (128 * 1024 * 1024)
#define kHeapCeiling_GL             (96  * 1024 * 1024)
#define kHeapCeiling_Compositor     (48  * 1024 * 1024)
#define kHeapCeiling_DSp            (32  * 1024 * 1024)  // back buffers + per-context overlays
#define kHeapCeiling_SystemOverhead (96  * 1024 * 1024)
#define kHeapCeiling_TotalMax       (544 * 1024 * 1024)

/* --- Lifecycle --- */

/* Idempotent. Requires SharedMetalDevice(); heaps are created lazily. */
int32_t gfxaccel_resources_heap_init(void);

/* Release all heaps, clear the PSO cache and LRU list. Idempotent. */
void gfxaccel_resources_heap_shutdown(void);

/* --- Heap access and sub-allocation --- */

/* MTLHeap for heap_id, created on first call. NULL if creation fails. */
void *gfxaccel_resources_heap_get(uint32_t heap_id);

/*
 * Allocate a buffer within heap_id's budget. Returns a retained
 * id<MTLBuffer> that the caller hands to ARC or releases; NULL if the budget
 * is exhausted after eviction. options is MTLResourceOptions.
 *
 * DSp buffers are standalone device buffers, never placement-aliased, so
 * disposing one frees its memory without waiting on other buffers. The DSp
 * budget stays charged until the last reference (texture views, command
 * buffers) is dropped.
 */
void *gfxaccel_resources_heap_alloc_buffer(uint32_t heap_id,
                                           uint32_t length,
                                           uint32_t options);

/*
 * Reset one heap's bump offset without releasing the MTLHeap. Returns the
 * bytes reclaimed (0 if already reset or heap_id is invalid). Normally driven
 * by the DMC on_mode_exit fan-out, since allocations are mode-scoped.
 */
uint64_t gfxaccel_resources_heap_reset(uint32_t heap_id);

/*
 * Accounting only: an owner released one sub-allocation; the caller keeps
 * ownership of the object. Reset refuses while the count is nonzero. For DSp
 * the live-byte charge is dropped later, when the buffer is destroyed after
 * GPU and view references end.
 */
void gfxaccel_resources_heap_note_allocation_released(uint32_t heap_id);

/* Live sub-allocations for heap_id; 0 for an invalid id. */
uint32_t gfxaccel_resources_heap_live_allocation_count(uint32_t heap_id);

/* --- GPU-completion latch --- */

/*
 * Note that command_buffer (id<MTLCommandBuffer>, NULL is a no-op) uses
 * memory from heap_id. Must be called before commit, since completion
 * handlers can't be added afterwards. Heap reset defers (returns 0) until
 * every noted buffer completes, so a reset and re-alloc can't alias bytes
 * the GPU may still read. Heaps are hazard-untracked, and the live count
 * only covers CPU ownership.
 */
void gfxaccel_resources_heap_note_gpu_commit(uint32_t heap_id,
                                             void *command_buffer);

/*
 * Bump reset for callers that already proved GPU idleness (e.g. background
 * entry after waitUntilCompleted). Skips the GPU-completion latch; the
 * live-allocation gate still applies.
 */
uint64_t gfxaccel_resources_heap_reset_gpu_idle(uint32_t heap_id);

/* --- Memory-warning handler --- */

/*
 * Called from the Swift MemoryWarningObserver on the main thread. Only sets
 * an atomic pending flag; the next SubmitFrame runs the eviction.
 */
void gfxaccel_handle_memory_warning(void);

/*
 * Run a pending memory-warning eviction; called from SubmitFrame.
 * frame_interval_usec is unused (kept for ABI). Returns kGfxAccelResNoErr if
 * nothing was pending or the pipeline drained.
 */
int32_t gfxaccel_heap_wait_for_eviction(uint64_t frame_interval_usec);

/* --- Eviction pipeline --- */

/* Eviction step 1: purge LRU volatile resources. */
void gfxaccel_heap_lru_purge_volatile(void);

/* Eviction step 2: drop all cached pipeline states (next frame recompiles). */
void gfxaccel_heap_pso_cache_clear(void);

/* --- RAVE ring buffer --- */

#define GFXACCEL_RAVE_RING_SLOT_BYTES (4u * 1024u * 1024u)

/*
 * Allocate the shared RAVE vertex ring (3 slots x 4 MiB) and its per-slot
 * semaphores. Idempotent. Returns 0 on success, -4006 on failure.
 */
int32_t gfxaccel_rave_ring_init(void);

void gfxaccel_rave_ring_shutdown(void);

/*
 * Copy size bytes into the ring for command_buffer (id<MTLCommandBuffer>)
 * and set out_offset to the 256-byte-aligned offset. Slots stay owned until
 * that command buffer completes. Returns the ring MTLBuffer, or NULL if no
 * slot is free; never waits, so callers fall back to a dedicated upload.
 */
void *gfxaccel_rave_ring_stage(void *command_buffer, const void *data,
                               uint32_t size, uint32_t *out_offset);

/* Register completion signals for this command buffer's slots. Call before
 * committing it, including during context teardown. */
void gfxaccel_rave_ring_frame_end(void *command_buffer);

/* Returns 1 when this uncommitted command buffer owns at least two slots;
 * poll at draw-sequence boundaries and submit early. */
int32_t gfxaccel_rave_ring_submission_near_exhaustion(void *command_buffer);

#ifdef __cplusplus
}
#endif

#endif /* GFXACCEL_RESOURCES_HEAP_H */
