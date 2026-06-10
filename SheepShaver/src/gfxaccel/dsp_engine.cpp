/*
 *  dsp_engine.cpp - DrawSprocket (DSp) engine lifecycle
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  The three lifecycle handlers:
 *    - DSpStartupHandler: idempotent refcount-based init that registers
 *      gfxaccel_resources attach/detach handlers on the first call.
 *    - DSpShutdownHandler: refcount-decrement + resource release on the
 *      final matching call; safe when refcount is already 0.
 *    - DSpGetVersionHandler: returns kDSpVersion_Current for app version
 *      probes.
 *
 *  Engine-peer registration mirrors RAVE's RaveRegisterResourceHandlers
 *  pattern (rave_engine.cpp): a one-shot
 *  dsp_resource_handlers_registered flag guards the
 *  gfxaccel_resources_register_engine call. The attach/detach handlers
 *  themselves start as no-op stubs (no DSp resources exist until context
 *  lifecycle is wired); the context-lifecycle code populates them with real
 *  back-buffer MTLTexture pre-vend / release logic.
 */

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "macos_util.h"
#include "thunks.h"
#include "dsp_engine.h"
#include "dsp_draw_context.h"
#include "dsp_mode_enumerate.h"        /* mode cache lifecycle */
#include "vbl_source.h"
#include "gfxaccel_resources.h"
#include "display_mode_controller.h"   /* DMCOwner enum + dmc_set_active_owner signature */

#include <stdatomic.h>                  /* _Atomic uint32_t bg/fg pending flag */

/* MainDevice PixMap redirect/restore helpers
 * defined in dsp_draw_context.mm. The forward declarations live here so
 * the dsp_engine.cpp translation unit can call them from the emul-thread
 * bridge sites; the DSp-Active PixMap redirect must be
 * dropped BEFORE the back_buffer goes away and re-applied at foreground
 * resume.
 *
 * Threading note: DSpOnBackground / DSpOnForeground below run on the
 * OBSERVER'S MAIN THREAD and only flip an atomic. The actual table walk
 * + PixMap mutation must execute on the EMUL THREAD per the
 * DSpContextPrivate single-writer convention; the emul-thread bridges
 * DSpHandleBackgroundFromEmulThread / DSpHandleForegroundFromEmulThread
 * (in dsp_draw_context.mm) own the walks. The references below in
 * DSpOnBackground / DSpOnForeground are documentation-only. */
extern "C" void DSpRedirectMainDevicePixMap(struct DSpContextPrivate *ctx);
extern "C" void DSpRestoreMainDevicePixMap(struct DSpContextPrivate *ctx);

/* Forward decl for the 5th VBL secondary callback, the
 * VBL-driven auto-publish shim. Defined in dsp_draw_context.mm (next to
 * DSpVBLServiceCallback so the VBL callbacks are co-located). The
 * register/unregister pair below in DSpInit / DSpShutdownHandler is the
 * only call site — secondary-callback fan-out is owned by vbl_source.mm
 * after registration. */
extern "C" void DSpVBLCompositorPublishCallback(void *cb_ctx,
                                                 void *drawable,
                                                 double ts);

#if ACCEL_LOGGING_ENABLED
#ifdef __APPLE__
os_log_t dsp_log = OS_LOG_DEFAULT;

/* Initialize os_log on first use (matches RAVE/GL pattern in rave_dispatch.cpp). */
static struct DSpLogInit {
	DSpLogInit() {
		dsp_log = os_log_create("com.pocketshaver.dsp", "engine");
	}
} dsp_log_init;
#endif

/* Diagnostic logging is enabled by default for graphics diagnostics. */
bool dsp_logging_enabled = accel_log_detail::subsystem_on("dsp");
#endif /* ACCEL_LOGGING_ENABLED */

/*
 *  File-scope state.
 *
 *    - dsp_registered: flipped true once DSpInit runs; used by
 *      DSpIsRegistered() and by matching Shutdown teardown. Distinct
 *      from dsp_startup_refcount — DSpInit is the PPC-thread bring-up
 *      hook (VideoInstallAccel), DSpStartup/Shutdown is the emulated-app
 *      lifecycle refcount.
 *    - dsp_startup_refcount: Startup/Shutdown call count. The
 *      idempotent-Startup semantics live here.
 *    - dsp_resource_handlers_registered: one-shot guard so the fan-out
 *      handlers are registered with gfxaccel_resources exactly once even
 *      across repeated Startup/Shutdown cycles. Mirrors
 *      rave_resource_handlers_registered in rave_engine.cpp.
 */
static bool     dsp_registered                    = false;
static uint32_t dsp_startup_refcount              = 0;
static bool     dsp_resource_handlers_registered  = false;
static bool     dsp_gestalt_registered            = false;
static uint32_t dsp_gestalt_callback              = 0;
static uint32_t dsp_gestalt_old_callback_slot     = 0;

typedef int16 (*DSpNewGestaltProc)(uint32, uint32);
typedef int16 (*DSpReplaceGestaltProc)(uint32, uint32, uint32);

/*
 *  Main-thread flag-and-drain pending state.
 *    0 = none, 1 = background enter pending, 2 = foreground enter pending.
 *  Written by main-thread (observer hook via gfxaccel_resources.mm C shim);
 *  read + cleared by emul-thread (VBL secondary-callback drain chain in
 *  dsp_draw_context.mm). Matches the memory-warning single-word
 *  atomic pattern — _Atomic counters are the ONE
 *  sanctioned DSp concurrency primitive; no mutex / @synchronized.
 */
static _Atomic uint32_t s_dsp_bg_fg_pending = 0;

/* ---------------------------------------------------------------------- *
 *  Background / Foreground hook bodies                                  *
 *  -------------------------------------------------------------------- *
 *  Both run on the OBSERVER'S MAIN THREAD
 *  (BackgroundLifecycleObserver.swift + gfxaccel_resources.mm C shim
 *  already handle NSNotificationCenter registration). These
 *  hook bodies are allocation-free atomic stores so the
 *  50 ms main-thread budget is inviolate.
 *
 *  No dsp_context_table reads/writes happen here — that's the emul
 *  thread's exclusive scope, drained from the VBL secondary callback
 *  via DSpVBLBackgroundForegroundDrain → DSpExchangeBgFgPending bridge.
 */
static void DSpOnBackground(void * /*ctx*/)
{
	atomic_store_explicit(&s_dsp_bg_fg_pending, 1u,
	                      memory_order_release);
	/* The PixMap-redirect drop happens on the
	 * EMUL THREAD inside DSpHandleBackgroundFromEmulThread, which walks
	 * dsp_context_table[] and calls DSpRestoreMainDevicePixMap on every
	 * Active context BEFORE DSpQueueReleaseAtVBLPartial frees the
	 * back_buffer. Touching the table from this main-thread hook would
	 * race with the emul-thread single-writer; the atomic flag above is
	 * the documented cross-thread bridge. */
	DSP_LOG("OnBackground: pending flag set (main thread)");
}

static void DSpOnForeground(void * /*ctx*/)
{
	atomic_store_explicit(&s_dsp_bg_fg_pending, 2u,
	                      memory_order_release);
	/* The PixMap-redirect re-apply happens on the
	 * EMUL THREAD inside DSpHandleForegroundFromEmulThread, which walks
	 * dsp_context_table[] and calls DSpRedirectMainDevicePixMap on every
	 * context resuming Active. Same threading rationale as
	 * DSpOnBackground above. */
	DSP_LOG("OnForeground: pending flag set (main thread)");
}

/*
 *  Emul-thread bridge. Called from DSpVBLBackgroundForegroundDrain in
 *  dsp_draw_context.mm — isolates s_dsp_bg_fg_pending so the draw-context
 *  file doesn't need to know about the atomic. atomic_exchange clears the
 *  slot with acquire semantics so the emul-thread reader sees every
 *  release-store the main-thread writer performed.
 */
extern "C" uint32_t DSpExchangeBgFgPending(void)
{
	return atomic_exchange_explicit(&s_dsp_bg_fg_pending, 0u,
	                                 memory_order_acquire);
}

/* --- gfxaccel_resources fan-out handlers (no-op stubs).
 *
 *  The context-lifecycle code replaces these with real attach/detach
 *  that pre-vend / release DSp front-buffer Metal textures when DSp has
 *  an active context. Until the engine has resources,
 *  both callbacks always return kGfxAccelResNoErr (0) — the mode
 *  transition is unconditionally accepted.
 *
 *  Both handlers must NOT call back into DMC (the resource manager
 *  fan-out runs on the DMC writer's thread while holding the writer
 *  mutex — recursive subscribe/unsubscribe would deadlock; matches the
 *  RAVE threat model cited in rave_engine.cpp).
 */
static int32_t DSpOnAttach(uint32_t /* engine_id */,
                           const struct DMCModeSnapshot * /* incoming */,
                           void * /* ctx */)
{
	/* No DSp resources yet; always accept the mode transition. */
	return 0;  /* kGfxAccelResNoErr */
}

static int32_t DSpOnDetach(uint32_t /* engine_id */,
                           const struct DMCModeSnapshot * /* outgoing */,
                           void * /* ctx */)
{
	/* No DSp resources to release. */
	return 0;
}

static void DSpRegisterResourceHandlers(void)
{
	if (dsp_resource_handlers_registered) return;
	struct GfxResEngineHandlers dsp_handlers;
	dsp_handlers.attach = DSpOnAttach;
	dsp_handlers.detach = DSpOnDetach;
	dsp_handlers.ctx    = NULL;
	gfxaccel_resources_register_engine(kGfxEngineDSp, &dsp_handlers);
	dsp_resource_handlers_registered = true;
	DSP_LOG("DSpRegisterResourceHandlers: registered kGfxEngineDSp with gfxaccel_resources");
}

static uint32_t DSpAllocateGestaltCallback(uint32_t value)
{
	/* 28 bytes: 8-byte TVECT header + 5 PPC instructions. */
	uint32_t base = SheepMem::ReserveProc(28);
	if (base == 0) return 0;
	uint32_t code = base + 8;

	WriteMacInt32(base, code);
	WriteMacInt32(base + 4, 0);

	const uint32_t r3 = 3, r4 = 4, r5 = 5;
	WriteMacInt32(code + 0, 0x3C000000 | (r5 << 21) |
	                         ((value >> 16) & 0xFFFF));
	WriteMacInt32(code + 4, 0x60000000 | (r5 << 21) |
	                         (r5 << 16) | (value & 0xFFFF));
	WriteMacInt32(code + 8, 0x90000000 | (r5 << 21) | (r4 << 16));
	WriteMacInt32(code + 12, 0x38000000 | (r3 << 21));
	WriteMacInt32(code + 16, 0x4E800020);

	return base;
}

static bool DSpVersionResultAddressIsWritable(uint32_t addr)
{
	if (addr == 0 || (addr & 3u) != 0) return false;

	const uint64_t ram_lo = (uint64_t)(uint32_t)RAMBase;
	const uint64_t ram_hi = ram_lo + (uint64_t)(uint32_t)RAMSize;
	const uint64_t write_hi = (uint64_t)addr + 4u;
	if (RAMSize != 0 && (uint64_t)addr >= ram_lo && write_hi <= ram_hi)
		return true;

	return write_hi <= 0x3000u;
}

static void DSpRegisterGestaltVersion(void)
{
	if (dsp_gestalt_registered) return;

	const uint32_t new_gestalt_tvect =
		FindLibSymbol("\014InterfaceLib", "\012NewGestalt");
	const uint32_t replace_gestalt_tvect =
		FindLibSymbol("\014InterfaceLib", "\016ReplaceGestalt");
	if (new_gestalt_tvect == 0 && replace_gestalt_tvect == 0) {
		return;
	}

	if (dsp_gestalt_callback == 0) {
		dsp_gestalt_callback =
			DSpAllocateGestaltCallback(kDSpVersion_Current);
	}
	if (dsp_gestalt_callback == 0) {
		return;
	}

	if (new_gestalt_tvect != 0) {
		const int16 gerr = (int16)CallMacOS2(DSpNewGestaltProc,
		                                     new_gestalt_tvect,
		                                     kDSpGestaltSelector,
		                                     dsp_gestalt_callback);
		if (gerr == 0) {
			dsp_gestalt_registered = true;
			return;
		}
	}

	if (replace_gestalt_tvect != 0) {
		if (dsp_gestalt_old_callback_slot == 0) {
			dsp_gestalt_old_callback_slot = Mac_sysalloc(4);
		}
		if (dsp_gestalt_old_callback_slot == 0) {
			return;
		}
		const int16 rerr = (int16)CallMacOS3(DSpReplaceGestaltProc,
		                                     replace_gestalt_tvect,
		                                     kDSpGestaltSelector,
		                                     dsp_gestalt_callback,
		                                     dsp_gestalt_old_callback_slot);
		dsp_gestalt_registered = (rerr == 0);
	}
}

/* --- Public lifecycle --- */

bool DSpIsRegistered(void)
{
	return dsp_registered;
}

void DSpInit(void)
{
	if (dsp_registered) {
		DSpRegisterGestaltVersion();
		DSP_LOG("DSpInit: already initialized, no-op");
		return;
	}

	DSP_LOG("DSpInit: alive; handlers registered lazily on first DSpStartup");

	/*
	 *  DSpInit flips dsp_registered so the
	 *  DSpIsRegistered() probe works for DMC integration checks
	 *  and for test isolation. Real gfxaccel_resources
	 *  handler registration moves into DSpStartupHandler (below) so
	 *  the refcount is the single source of truth for lifecycle —
	 *  matching the DSp 1.7 API contract (Startup is where the
	 *  subsystem actually initializes per resources/
	 *  DrawSprocket1.7.pdf p.15).
	 */
	dsp_registered = true;
	DSpRegisterGestaltVersion();

	/* Populate DSp mode cache from VModes[]. Runs
	 * once per DSpInit (which is idempotent via the dsp_registered
	 * guard); DSpShutdown pairs this with DSpClearModes(). */
	DSpBuildModesFromVModes();

	/* Register the DSp VBL-bounded release drain
	 * as a VBL secondary callback. The bg/fg drain chains
	 * off the same hook (DSpVBLReleaseCallback calls
	 * DSpVBLBackgroundForegroundDrain at the end). */
	vbl_source_register_secondary_callback(DSpVBLReleaseCallback, NULL);

	/* Register the VBL-latched CLUT snapshot
	 * callback alongside the release drain. Slot budget:
	 * VBL_SECONDARY_CALLBACK_MAX=4, current use=2 (release + clut-latch).
	 * Registration is idempotent via the DSpInit early-return guard. */
	vbl_source_register_secondary_callback(DSpVBLClutLatchCallback, NULL);

	/* Register the gamma-fade interpolation
	 * callback alongside the release drain and CLUT
	 * snapshot drain. Slot budget: VBL_SECONDARY_CALLBACK_MAX=4, current
	 * use=3 (release + clut-latch + gamma-fade). Registration is
	 * idempotent via the DSpInit early-return guard. The callback walks
	 * the context table and applies the per-VBL fade interpolation. */
	vbl_source_register_secondary_callback(DSpVBLGammaFadeCallback, NULL);

	/* Register the VBL service callback —
	 * 4th VBL secondary callback slot. The callback body
	 * atomic-increments s_dsp_vbl_count and runs the
	 * per-context walk + PPC VBLProc invocation. */
	vbl_source_register_secondary_callback(DSpVBLServiceCallback, NULL);

	/* Register the DSp VBL
	 * compositor publish callback — 5th and FINAL VBL secondary callback
	 * (VBL_SECONDARY_CALLBACK_MAX raised 4 → 5 in vbl_source.h).
	 * Fires AFTER DSpVBLServiceCallback so the GetVBLCount
	 * atomic increment + user-VBLProc dispatch complete BEFORE we publish
	 * — automatically preserves the "after user-VBLProc dispatch" ordering.
	 * Slot use is now 5 of 5; future DSp work MUST deprecate an
	 * existing callback before registering another. Registration is
	 * idempotent via the DSpInit early-return guard. */
	vbl_source_register_secondary_callback(DSpVBLCompositorPublishCallback, NULL);

	/* Plug bg/fg hook bodies into the already-wired seam. Swift
	 * BackgroundLifecycleObserver + gfxaccel_resources.mm C shim handle
	 * the main-thread observer registration; DSp just plugs in flag-only
	 * hooks — all real work happens on the emul thread via
	 * DSpVBLBackgroundForegroundDrain. */
	gfxaccel_set_dsp_background_hook(DSpOnBackground, NULL);
	gfxaccel_set_dsp_foreground_hook(DSpOnForeground, NULL);
}

/* --- Handlers --- */

int32_t DSpStartupHandler(void)
{
	/*
	 *  Idempotent startup:
	 *    First call registers the gfxaccel_resources handlers and
	 *    bumps refcount to 1. Subsequent calls just bump the refcount
	 *    and return kDSpNoErr without side effects — explicitly
	 *    permitted per DSp 1.7 API docs (resources/DrawSprocket1.7.pdf
	 *    p.15: "Clients may call DSpStartup multiple times; the
	 *    subsystem is reference-counted and a matching number of
	 *    DSpShutdown calls must be made").
	 *
	 *  Lifecycle wiring: first-call registration path
	 *    guarantees kGfxEngineDSp appears in the gfxaccel_resources
	 *    fan-out registry, so DMC on_mode_enter/exit reach the DSp
	 *    engine via this module (not via DMC-direct subscription).
	 */
	if (dsp_startup_refcount == 0) {
		if (!dsp_registered) {
			DSpInit();
		}
		DSpRegisterResourceHandlers();
		/* Mirror dsp_registered for the already-initialized path. A
		 * post-Shutdown restart takes the DSpInit path above, which also
		 * rebuilds the mode cache cleared by final Shutdown. */
		dsp_registered = true;
		DSP_LOG("DSpStartupHandler: first-call init complete");
	}
	dsp_startup_refcount++;
	return kDSpNoErr;
}

int32_t DSpShutdownHandler(void)
{
	/*
	 *  Clean Shutdown:
	 *    Decrements the refcount. When the refcount reaches 0 the
	 *    final matching Shutdown releases all DSp state —
	 *    unregistering from gfxaccel_resources and
	 *    flipping dsp_registered = false.
	 *
	 *  Safe on already-shutdown: calling Shutdown when
	 *  dsp_startup_refcount == 0 returns kDSpNoErr without crashing
	 *  and without re-invoking unregister. Matches DSp 1.7 semantics
	 *  (double-shutdown is a common classic-Mac app pattern — atexit-
	 *  style handlers pair DSpShutdown unconditionally).
	 */
	if (dsp_startup_refcount == 0) {
		DSP_LOG("DSpShutdownHandler: refcount already 0 - no-op");
		return kDSpNoErr;
	}
	dsp_startup_refcount--;
	if (dsp_startup_refcount == 0) {
		if (dsp_resource_handlers_registered) {
			gfxaccel_resources_unregister_engine(kGfxEngineDSp);
			dsp_resource_handlers_registered = false;
		}
		/* Clear DSp mode cache symmetrically with
		 * DSpInit's DSpBuildModesFromVModes call. Idempotent: an
		 * already-empty cache is a no-op. */
		DSpClearModes();
		/* Unregister FIRST in reverse registration order — the publish shim
		 * is the 5th/final callback registered. Idempotent: unregister is a
		 * search-and-remove that does nothing when the callback isn't in the
		 * table. */
		vbl_source_unregister_secondary_callback(DSpVBLCompositorPublishCallback);
		/* Unregister in reverse registration order — vbl-service is the 4th
		 * callback registered (now second to remove after the publish shim).
		 * Idempotent: unregister is a search-and-remove that does nothing when
		 * the callback isn't in the table. */
		vbl_source_unregister_secondary_callback(DSpVBLServiceCallback);
		/* Unregister in REVERSE registration order — gamma-fade second (after
		 * vbl-service), then clut-latch, then release. Idempotent: unregister
		 * is a search-and-remove that does nothing when the callback isn't in
		 * the table. */
		vbl_source_unregister_secondary_callback(DSpVBLGammaFadeCallback);
		/* Unregister in REVERSE registration order — clut-latch first, release
		 * second. Idempotent: unregister is a search-and-remove that does
		 * nothing when the callback isn't in the table. */
		vbl_source_unregister_secondary_callback(DSpVBLClutLatchCallback);
		/* Symmetric with DSpInit — drop the VBL secondary callback so the
		 * release FIFO isn't invoked after full teardown. Idempotent:
		 * unregister is a search-and-remove that does nothing when the
		 * callback isn't in the table. */
		vbl_source_unregister_secondary_callback(DSpVBLReleaseCallback);
		/* Symmetric clear of the bg/fg hook slots + reset the pending-flag
		 * so a follow-up re-init doesn't re-drain stale state. */
		gfxaccel_set_dsp_background_hook(NULL, NULL);
		gfxaccel_set_dsp_foreground_hook(NULL, NULL);
		atomic_store_explicit(&s_dsp_bg_fg_pending, 0u,
		                      memory_order_relaxed);
		dsp_registered = false;
		DSP_LOG("DSpShutdownHandler: final-call teardown complete");
	}
	return kDSpNoErr;
}

uint32_t DSpGetVersionHandler(uint32_t outVersionAddr)
{
	/*
	 *  Direct DSpGetVersion probes and Gestalt('dspv') share the same
	 *  app-visible version policy.
	 */
	if (DSpVersionResultAddressIsWritable(outVersionAddr)) {
		WriteMacInt32(outVersionAddr, kDSpVersion_Current);
	}
	return kDSpVersion_Current;
}

/*
 *  Map DSp play state -> DMC owner.
 *    - Active   -> kDMCOwnerDSp  (DSp owns the display)
 *    - Paused   -> kDMCOwnerQuickDraw (menu bar visible; QuickDraw-like)
 *    - Inactive -> kDMCOwnerQuickDraw (Monitors-ctrl-panel resolution)
 *
 *  Inactive vs Paused differs in blanking-color semantics;
 *  from the DMC's perspective both are non-DSp owners (the PDF pp.29
 *  rationale: Paused restores the menu bar, so it is QuickDraw-equivalent
 *  at the display-ownership level).
 *
 *  Returns uint32_t (not DMCOwner) so the public DSp header
 *  include/dsp_draw_context.h does NOT need to transitively include
 *  display_mode_controller.h. dsp_engine_internal.h provides a typed
 *  inline wrapper DSpMapStateToDMCOwnerTyped() for gfxaccel-internal
 *  consumers (dsp_draw_context.mm SetState; the bg/fg hooks;
 *  multi-engine canaries). The returned value is safe to cast
 *  directly to DMCOwner at call sites that include the DMC header.
 */
extern "C" uint32_t DSpMapStateToDMCOwner(uint32_t dsp_state)
{
	switch (dsp_state) {
		case kDSpContextState_Active:   return (uint32_t)kDMCOwnerDSp;
		case kDSpContextState_Paused:   return (uint32_t)kDMCOwnerQuickDraw;
		case kDSpContextState_Inactive: return (uint32_t)kDMCOwnerQuickDraw;
		default:                         return (uint32_t)kDMCOwnerQuiescent;
	}
}

/* --- Testing hook ---
 *
 *  dsp_testing_reset zeros the lifecycle state for test isolation:
 *  it releases any registered gfxaccel_resources handlers and
 *  zeros every file-scope counter/flag so the next test starts
 *  from the exact same state as a freshly-booted process.
 *
 *  Gated by TESTING_BUILD (the PocketShaverTests target defines
 *  TESTING_BUILD=1 in its GCC_PREPROCESSOR_DEFINITIONS) — production
 *  PocketShaver and SheepShaver builds do NOT compile this hook.
 */
#ifdef TESTING_BUILD
extern "C" void dsp_testing_reset(void)
{
	if (dsp_resource_handlers_registered) {
		gfxaccel_resources_unregister_engine(kGfxEngineDSp);
	}
	dsp_resource_handlers_registered = false;
	dsp_startup_refcount              = 0;
	dsp_registered                    = false;
}
#endif
