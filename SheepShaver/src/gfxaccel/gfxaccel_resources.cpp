/*
 *  gfxaccel_resources.cpp - resource-manager fan-out logic.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Subscribes to DMC mode changes and fans them out to each engine's
 *  attach/detach handlers. Metal state lives in gfxaccel_resources.mm.
 *  Emul thread only.
 */

#include "gfxaccel_resources.h"
#include "gfxaccel_resources_heap.h"
#include "pso_archive.h"
#include "display_mode_controller.h"

#include <cstdio>
#include <cstring>
#include <vector>

// Implemented in gfxaccel_resources.mm.
extern "C" void gfxaccel_resources_mm_init_metal_state(void);
extern "C" void gfxaccel_resources_mm_shutdown_metal_state(void);
extern "C" void gfxaccel_handle_background_enter(void);
extern "C" void gfxaccel_handle_foreground_enter(void);
extern "C" void gfxaccel_set_dsp_background_hook(GfxAccelLifecycleHookFn fn, void *ctx);
extern "C" void gfxaccel_set_dsp_foreground_hook(GfxAccelLifecycleHookFn fn, void *ctx);

namespace {

struct GfxResEngineRegistration {
	uint32_t                    engine_id;
	struct GfxResEngineHandlers handlers;
};

static std::vector<GfxResEngineRegistration> s_engine_handlers;
static bool                                  s_initialized = false;

static int32_t GfxRes_OnModeExit(const struct DMCModeSnapshot *outgoing, void *ctx);
static int32_t GfxRes_OnModeEnter(const struct DMCModeSnapshot *incoming, void *ctx);

static DMCSubscriber s_dmc_subscriber = {
	/* .name          = */ "gfxaccel_resources",
	/* .on_mode_exit  = */ GfxRes_OnModeExit,
	/* .on_mode_enter = */ GfxRes_OnModeEnter,
	/* .ctx           = */ NULL
};

// ---------------------------------------------------------------------------
// Fan-out callbacks
// ---------------------------------------------------------------------------

// Detach runs in registration order. Its result is only logged: DMC does
// not allow vetoing a committed exit.
static int32_t GfxRes_OnModeExit(const struct DMCModeSnapshot *outgoing, void *ctx)
{
	(void)ctx;
	for (size_t i = 0; i < s_engine_handlers.size(); ++i) {
		const GfxResEngineRegistration &entry = s_engine_handlers[i];
		if (entry.handlers.detach != NULL) {
			int32_t r = entry.handlers.detach(entry.engine_id, outgoing,
			                                   entry.handlers.ctx);
			if (r != 0) {
				fprintf(stderr,
				        "[gfxaccel_resources] detach(engine_id=%u) returned %d "
				        "during on_mode_exit (advisory; ignored)\n",
				        (unsigned)entry.engine_id, (int)r);
			}
		}
	}
	return kDMCNoErr;
}

// Attach runs in reverse registration order, matching DMC. A failed attach
// is returned as kDMCErrSubscriberRejected so DMC rolls back.
static int32_t GfxRes_OnModeEnter(const struct DMCModeSnapshot *incoming, void *ctx)
{
	(void)ctx;
	for (std::vector<GfxResEngineRegistration>::reverse_iterator it = s_engine_handlers.rbegin();
	     it != s_engine_handlers.rend(); ++it) {
		if (it->handlers.attach != NULL) {
			int32_t r = it->handlers.attach(it->engine_id, incoming,
			                                 it->handlers.ctx);
			if (r != 0) {
				fprintf(stderr,
				        "[gfxaccel_resources] attach(engine_id=%u) returned %d "
				        "during on_mode_enter - propagating as subscriber rejection\n",
				        (unsigned)it->engine_id, (int)r);
				return kDMCErrSubscriberRejected;
			}
		}
	}
	return kDMCNoErr;
}

} // namespace (anonymous)

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

extern "C" int32_t gfxaccel_resources_init(void)
{
	if (s_initialized) {
		return kGfxAccelResNoErr;
	}

	// Must subscribe after metal_compositor (see gfxaccel_resources.h).
	// Already-registered is fine across repeated init/shutdown cycles.
	int32_t sub_err = dmc_subscribe(&s_dmc_subscriber);
	if (sub_err != kDMCNoErr && sub_err != kDMCErrSubscriberAlreadyRegistered) {
		fprintf(stderr,
		        "[gfxaccel_resources] dmc_subscribe('gfxaccel_resources') FAILED "
		        "err=%d - resource manager not usable\n", (int)sub_err);
		return kGfxAccelResErrGeneric;
	}

	gfxaccel_resources_mm_init_metal_state();

	gfxaccel_resources_heap_init();

	// Optional; without the archive PSOs are compiled at runtime.
	{
		int32_t pso_err = pso_archive_init();
		if (pso_err != 0 && pso_err != kGfxAccelErrPSOArchiveNotAvailable) {
			fprintf(stderr,
			        "[gfxaccel_resources] pso_archive_init() returned %d "
			        "(non-fatal; runtime compile fallback)\n", (int)pso_err);
		}
	}

	s_initialized = true;
	return kGfxAccelResNoErr;
}

extern "C" void gfxaccel_resources_shutdown(void)
{
	if (!s_initialized) {
		return;
	}

	pso_archive_shutdown();

	// Engines that did not unregister are dropped silently.
	s_engine_handlers.clear();

	// Before the Metal state, so heap-backed buffers are released while
	// their heaps still exist.
	gfxaccel_resources_heap_shutdown();

	gfxaccel_resources_mm_shutdown_metal_state();

	int32_t unsub_err = dmc_unsubscribe(s_dmc_subscriber.name);
	if (unsub_err != kDMCNoErr && unsub_err != kDMCErrSubscriberNotFound) {
		fprintf(stderr,
		        "[gfxaccel_resources] dmc_unsubscribe('gfxaccel_resources') "
		        "returned err=%d (tolerated)\n", (int)unsub_err);
	}

	s_initialized = false;
}

extern "C" void gfxaccel_resources_register_engine(uint32_t engine_id,
                                                   const struct GfxResEngineHandlers *h)
{
	if (h == NULL) {
		fprintf(stderr, "[gfxaccel_resources] register_engine(%u) with NULL handlers "
		                "- ignored\n", (unsigned)engine_id);
		return;
	}
	if (engine_id >= (uint32_t)kGfxEngineCount) {
		fprintf(stderr, "[gfxaccel_resources] register_engine: engine_id=%u out of "
		                "range (max=%u)\n",
		        (unsigned)engine_id, (unsigned)kGfxEngineCount);
		return;
	}

	// Re-registering replaces the engine's handlers.
	for (size_t i = 0; i < s_engine_handlers.size(); ++i) {
		if (s_engine_handlers[i].engine_id == engine_id) {
			s_engine_handlers[i].handlers = *h;
			return;
		}
	}

	GfxResEngineRegistration entry;
	entry.engine_id = engine_id;
	entry.handlers  = *h;
	s_engine_handlers.push_back(entry);
}

extern "C" void gfxaccel_resources_unregister_engine(uint32_t engine_id)
{
	for (size_t i = 0; i < s_engine_handlers.size(); ++i) {
		if (s_engine_handlers[i].engine_id == engine_id) {
			s_engine_handlers.erase(s_engine_handlers.begin() + (std::ptrdiff_t)i);
			return;
		}
	}
}

