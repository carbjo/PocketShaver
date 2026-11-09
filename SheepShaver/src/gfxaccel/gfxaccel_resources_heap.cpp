/*
 *  gfxaccel_resources_heap.cpp - GPU heap bookkeeping (C++ side).
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  PSO cache, purgeable LRU list and the per-mode-exit heap reset. Metal
 *  objects live in gfxaccel_resources_heap.mm. Emul thread only; the .mm
 *  side routes memory warnings through the emul serial queue.
 */

#include "gfxaccel_resources_heap.h"
#include "display_mode_controller.h"

#include <cstdio>
#include <cstring>
#include <unordered_map>
#include <deque>
#include <vector>

// Implemented in gfxaccel_resources_heap.mm.
extern "C" void gfxaccel_resources_heap_mm_init(void);
extern "C" void gfxaccel_resources_heap_mm_shutdown(void);
extern "C" void *gfxaccel_resources_heap_mm_get(uint32_t heap_id);
extern "C" void *gfxaccel_resources_heap_mm_alloc_buffer(uint32_t heap_id,
                                                          uint32_t length,
                                                          uint32_t options);
extern "C" void gfxaccel_resources_heap_mm_lru_purge(void);
extern "C" uint64_t gfxaccel_resources_heap_mm_reset(uint32_t heap_id);
extern "C" void gfxaccel_resources_heap_mm_note_allocation_released(uint32_t heap_id);
extern "C" uint32_t gfxaccel_resources_heap_mm_live_allocation_count(uint32_t heap_id);

namespace {

static bool s_heap_initialized = false;

// ---------------------------------------------------------------------------
// PSO cache
// ---------------------------------------------------------------------------

struct PSOCacheKey {
	uint64_t shader_pair_hash;
	uint64_t vertex_descriptor_hash;
	uint32_t color_format[4];

	bool operator==(const PSOCacheKey &other) const {
		return shader_pair_hash == other.shader_pair_hash &&
		       vertex_descriptor_hash == other.vertex_descriptor_hash &&
		       color_format[0] == other.color_format[0] &&
		       color_format[1] == other.color_format[1] &&
		       color_format[2] == other.color_format[2] &&
		       color_format[3] == other.color_format[3];
	}
};

struct PSOCacheKeyHash {
	size_t operator()(const PSOCacheKey &k) const {
		// FNV-1a style combine
		size_t h = 14695981039346656037ULL;
		h ^= k.shader_pair_hash;
		h *= 1099511628211ULL;
		h ^= k.vertex_descriptor_hash;
		h *= 1099511628211ULL;
		for (int i = 0; i < 4; ++i) {
			h ^= (size_t)k.color_format[i];
			h *= 1099511628211ULL;
		}
		return h;
	}
};

// Values are id<MTLRenderPipelineState>, retained by the .mm side.
static std::unordered_map<PSOCacheKey, void*, PSOCacheKeyHash> g_pso_cache;

// ---------------------------------------------------------------------------
// LRU purgeable list
// ---------------------------------------------------------------------------

struct PurgeableEntry {
	uint32_t heap_id;
	void    *resource;       // id<MTLResource> as void*
	uint64_t last_use_frame;
};

static std::deque<PurgeableEntry> g_lru;

// ---------------------------------------------------------------------------
// DMC on_mode_exit heap reset
// ---------------------------------------------------------------------------
//
// Registered after the compositor and gfxaccel_resources subscribers, so it
// runs last on mode exit (DMC fires exits in FIFO order), after every
// engine has detached. The reset also refuses a heap that still has live
// allocations, so placement heaps cannot alias live bytes.
static int32_t s_heap_reset_on_mode_exit(const struct DMCModeSnapshot *outgoing,
                                          void *ctx)
{
	(void)outgoing;
	(void)ctx;
	for (uint32_t i = 0; i < (uint32_t)kHeapCount; ++i) {
		if (i == (uint32_t)kHeapEngineDSp) continue;  // DSp buffers survive mode switches; DSp resets its heap itself when idle.
		uint64_t reclaimed = gfxaccel_resources_heap_mm_reset(i);
		if (reclaimed > 0) {
			fprintf(stderr,
			        "[gfxaccel-heap] on_mode_exit: heap_id=%u reset "
			        "reclaimed %llu bytes\n",
			        (unsigned)i, (unsigned long long)reclaimed);
		}
	}
	return kDMCNoErr;
}

static DMCSubscriber s_heap_reset_subscriber = {
	/* .name          = */ "gfxaccel_heap_reset",
	/* .on_mode_exit  = */ s_heap_reset_on_mode_exit,
	/* .on_mode_enter = */ NULL,
	/* .ctx           = */ NULL
};

} // namespace (anonymous)

// ---------------------------------------------------------------------------
// Public API - Lifecycle
// ---------------------------------------------------------------------------

extern "C" int32_t gfxaccel_resources_heap_init(void)
{
	if (s_heap_initialized) {
		return kGfxAccelResNoErr;
	}

	gfxaccel_resources_heap_mm_init();

	// Non-fatal: without it only the automatic per-mode-exit reset is lost.
	int32_t sub_err = dmc_subscribe(&s_heap_reset_subscriber);
	if (sub_err != kDMCNoErr &&
	    sub_err != kDMCErrSubscriberAlreadyRegistered) {
		fprintf(stderr,
		        "[gfxaccel-heap] dmc_subscribe('gfxaccel_heap_reset') "
		        "returned %d (non-fatal; automatic per-mode-exit reset "
		        "disabled for this session)\n",
		        (int)sub_err);
	}

	s_heap_initialized = true;
	return kGfxAccelResNoErr;
}

extern "C" void gfxaccel_resources_heap_shutdown(void)
{
	if (!s_heap_initialized) {
		return;
	}

	// Unsubscribe before tearing down the Metal side.
	(void)dmc_unsubscribe(s_heap_reset_subscriber.name);

	gfxaccel_heap_pso_cache_clear();
	g_lru.clear();
	gfxaccel_resources_heap_mm_shutdown();

	s_heap_initialized = false;
}

// ---------------------------------------------------------------------------
// Public API - Heap access + sub-allocation
// ---------------------------------------------------------------------------

extern "C" void *gfxaccel_resources_heap_get(uint32_t heap_id)
{
	if (heap_id >= kHeapCount) {
		fprintf(stderr, "[gfxaccel-heap] heap_get: heap_id=%u out of range "
		                "(max=%u)\n", (unsigned)heap_id, (unsigned)kHeapCount);
		return NULL;
	}
	return gfxaccel_resources_heap_mm_get(heap_id);
}

extern "C" void *gfxaccel_resources_heap_alloc_buffer(uint32_t heap_id,
                                                       uint32_t length,
                                                       uint32_t options)
{
	if (heap_id >= kHeapCount) {
		fprintf(stderr, "[gfxaccel-heap] alloc_buffer: heap_id=%u out of range\n",
		        (unsigned)heap_id);
		return NULL;
	}
	return gfxaccel_resources_heap_mm_alloc_buffer(heap_id, length, options);
}

extern "C" uint64_t gfxaccel_resources_heap_reset(uint32_t heap_id)
{
	if (heap_id >= kHeapCount) {
		return 0;
	}
	return gfxaccel_resources_heap_mm_reset(heap_id);
}

extern "C" void gfxaccel_resources_heap_note_allocation_released(uint32_t heap_id)
{
	if (heap_id >= kHeapCount) {
		fprintf(stderr, "[gfxaccel-heap] note_allocation_released: heap_id=%u "
		                "out of range\n", (unsigned)heap_id);
		return;
	}
	gfxaccel_resources_heap_mm_note_allocation_released(heap_id);
}

extern "C" uint32_t gfxaccel_resources_heap_live_allocation_count(uint32_t heap_id)
{
	if (heap_id >= kHeapCount) {
		return 0;
	}
	return gfxaccel_resources_heap_mm_live_allocation_count(heap_id);
}

// ---------------------------------------------------------------------------
// Public API - Eviction pipeline
// ---------------------------------------------------------------------------

extern "C" void gfxaccel_heap_pso_cache_clear(void)
{
	// Nothing inserts into the cache yet. Once something does, entries must
	// be released on the .mm side before clearing.
	g_pso_cache.clear();
}

extern "C" void gfxaccel_heap_lru_purge_volatile(void)
{
	gfxaccel_resources_heap_mm_lru_purge();
	g_lru.clear();
}

