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
 *  DSpStartup/DSpShutdown are refcounted; the first Startup registers the
 *  gfxaccel_resources handlers and the final Shutdown tears everything down.
 */

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "macos_util.h"
#include "thunks.h"
#include "dsp_engine.h"
#include "dsp_draw_context.h"
#include "dsp_mode_enumerate.h"
#include "vbl_source.h"
#include "gfxaccel_resources.h"
#include "gfxaccel_resources_heap.h"
#include "display_mode_controller.h"

#include <stdatomic.h>

/* Defined in dsp_draw_context.mm. The DSp-Active PixMap redirect must be
 * dropped before the back buffer goes away and re-applied on foreground. */
extern "C" void DSpRedirectMainDevicePixMap(struct DSpContextPrivate *ctx);
extern "C" void DSpRestoreMainDevicePixMap(struct DSpContextPrivate *ctx);

/* VBL-driven auto-publish callback, defined in dsp_draw_context.mm. */
extern "C" void DSpVBLCompositorPublishCallback(void *cb_ctx,
                                                 void *drawable,
                                                 double ts);

#if ACCEL_LOGGING_ENABLED
#ifdef __APPLE__
os_log_t dsp_log = OS_LOG_DEFAULT;

static struct DSpLogInit {
	DSpLogInit() {
		dsp_log = os_log_create("com.pocketshaver.dsp", "engine");
	}
} dsp_log_init;
#endif

bool dsp_logging_enabled = accel_log_detail::subsystem_on("dsp");
#endif /* ACCEL_LOGGING_ENABLED */

/*
 *  dsp_registered is set by DSpInit (bring-up from VideoInstallAccel);
 *  dsp_startup_refcount counts the guest's DSpStartup/DSpShutdown calls.
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
 *  Pending lifecycle events, as a bitmask (kDSpPendingBackground,
 *  kDSpPendingForeground). Bits accumulate so a foreground event cannot
 *  erase an undrained background one. Set by the lifecycle hooks; cleared
 *  by the emul-thread drain. DSp uses atomics only, no mutexes.
 */
static _Atomic uint32_t s_dsp_bg_fg_pending = 0;

/*
 *  Background/foreground hooks. They run on the main thread, which is the
 *  emul thread (see gfxaccel_threading_policy.h).
 *
 *  Each hook sets its pending bit and drains synchronously. That is required
 *  on background: the VBL source is already paused, so the VBL drain would
 *  never run. DSpDrainLifecycleSync defers to the in-flight tick when called
 *  from inside the VBL chain, and DSpRevalidateSwapContext protects
 *  SwapBuffers against a drain landing inside a busyProc runloop pump.
 */
static void DSpOnBackground(void * /*ctx*/)
{
	atomic_fetch_or_explicit(&s_dsp_bg_fg_pending, kDSpPendingBackground,
	                         memory_order_release);
	DSP_LOG("OnBackground: pending bit set; draining synchronously");
	/* gfxaccel_handle_background_enter already waited for the GPU, so the
	 * back-buffer release cannot race in-flight encodes. */
	DSpDrainLifecycleSync();
}

static void DSpOnForeground(void * /*ctx*/)
{
	atomic_fetch_or_explicit(&s_dsp_bg_fg_pending, kDSpPendingForeground,
	                         memory_order_release);
	DSP_LOG("OnForeground: pending bit set; draining synchronously");
	/* Re-allocate back buffers now so the first resumed frame presents. A
	 * still-pending background bit is processed first. */
	DSpDrainLifecycleSync();
}

/* Called by DSpVBLBackgroundForegroundDrain; returns and clears the bits. */
extern "C" uint32_t DSpExchangeBgFgPending(void)
{
	return atomic_exchange_explicit(&s_dsp_bg_fg_pending, 0u,
	                                 memory_order_acquire);
}

/*
 *  gfxaccel_resources fan-out handlers. DSp holds no per-mode resources
 *  here, so both accept every transition.
 *
 *  Must not call back into DMC: the fan-out runs under the DMC writer
 *  mutex, so re-subscribing would deadlock.
 */
static int32_t DSpOnAttach(uint32_t /* engine_id */,
                           const struct DMCModeSnapshot * /* incoming */,
                           void * /* ctx */)
{
	return 0;  /* kGfxAccelResNoErr */
}

static int32_t DSpOnDetach(uint32_t /* engine_id */,
                           const struct DMCModeSnapshot * /* outgoing */,
                           void * /* ctx */)
{
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
	/* Gestalt calls the SelectorFunctionUPP through Mixed Mode, so a bare PPC
	 * TVECT would run as 68k code. Gestalt keeps the UPP, so the descriptor,
	 * TVECT and code live in permanent thunk storage. The code is
	 * "lis/ori r5, value; stw r5,0(r4); li r3,0; blr". */
	uint32_t base = SheepMem::ReserveProc(sizeof(RoutineDescriptor) + 28);
	if (base == 0) return 0;
	const uint32_t tvect = base + sizeof(RoutineDescriptor);
	const uint32_t code = tvect + 8;
	Mac_memset(base, 0, sizeof(RoutineDescriptor));
	WriteMacInt16(base + offsetof(RoutineDescriptor, goMixedModeTrap), 0xAAFE);
	WriteMacInt8(base + offsetof(RoutineDescriptor, version), 7);
	const uint32_t record = base + offsetof(RoutineDescriptor, routineRecords);
	/* uppSelectorFunctionProcInfo: Pascal OSErr (UInt32, SInt32 *). */
	WriteMacInt32(record + offsetof(RoutineRecord, procInfo), 0x000003E0);
	WriteMacInt8(record + offsetof(RoutineRecord, ISA), 1);  /* kPowerPCISA */
	WriteMacInt16(record + offsetof(RoutineRecord, routineFlags), 4);
	WriteMacInt32(record + offsetof(RoutineRecord, procDescriptor), tvect);

	WriteMacInt32(tvect, code);
	WriteMacInt32(tvect + 4, 0);

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

	/* Resource handler registration is left to DSpStartupHandler, where
	 * DSp 1.7 says the subsystem initializes (p.15). */
	dsp_registered = true;
	DSpRegisterGestaltVersion();

	/* Paired with DSpClearModes() in the final Shutdown. */
	DSpBuildModesFromVModes();

	/* VBL secondary callbacks, in order. All five slots
	 * (VBL_SECONDARY_CALLBACK_MAX) are used; Shutdown removes them in reverse.
	 * The release drain also runs DSpVBLBackgroundForegroundDrain. */
	vbl_source_register_secondary_callback(DSpVBLReleaseCallback, NULL);

	vbl_source_register_secondary_callback(DSpVBLClutLatchCallback, NULL);

	vbl_source_register_secondary_callback(DSpVBLGammaFadeCallback, NULL);

	vbl_source_register_secondary_callback(DSpVBLServiceCallback, NULL);

	/* Publish must run after the service callback has bumped the VBL count
	 * and dispatched the guest VBLProc. */
	vbl_source_register_secondary_callback(DSpVBLCompositorPublishCallback, NULL);

	gfxaccel_set_dsp_background_hook(DSpOnBackground, NULL);
	gfxaccel_set_dsp_foreground_hook(DSpOnForeground, NULL);
}

/* --- Handlers --- */

int32_t DSpStartupHandler(void)
{
	/* DSpStartup is refcounted (DSp 1.7 p.15); only the first call does
	 * any work. */
	if (dsp_startup_refcount == 0) {
		if (!dsp_registered) {
			DSpInit();
		}
		DSpRegisterResourceHandlers();
		/* A restart after final Shutdown goes through DSpInit above, which
		 * rebuilds the mode cache. */
		dsp_registered = true;
		DSP_LOG("DSpStartupHandler: first-call init complete");
	}
	dsp_startup_refcount++;
	return kDSpNoErr;
}

int32_t DSpShutdownHandler(void)
{
	/* The final matching Shutdown releases all DSp state. Extra Shutdowns
	 * are a no-op; classic apps often call it unconditionally at exit. */
	if (dsp_startup_refcount == 0) {
		DSP_LOG("DSpShutdownHandler: refcount already 0 - no-op");
		return kDSpNoErr;
	}
	if (dsp_startup_refcount == 1) {
		int32_t rc = DSpReleaseAllContexts();
		if (rc != kDSpNoErr) return rc;
	}
	dsp_startup_refcount--;
	if (dsp_startup_refcount == 0) {
		if (dsp_resource_handlers_registered) {
			gfxaccel_resources_unregister_engine(kGfxEngineDSp);
			dsp_resource_handlers_registered = false;
		}
		DSpClearModes();
		/* Unregister VBL callbacks in reverse registration order. Unregister
		 * is a no-op for a callback that is not registered. */
		vbl_source_unregister_secondary_callback(DSpVBLCompositorPublishCallback);
		vbl_source_unregister_secondary_callback(DSpVBLServiceCallback);
		vbl_source_unregister_secondary_callback(DSpVBLGammaFadeCallback);
		vbl_source_unregister_secondary_callback(DSpVBLClutLatchCallback);
		/* Flush the release FIFO once before dropping its callback. */
		DSpVBLReleaseCallback(NULL, NULL, 0.0);
		if (gfxaccel_resources_heap_live_allocation_count(kHeapEngineDSp) == 0) {
			uint64_t reclaimed = gfxaccel_resources_heap_reset(kHeapEngineDSp);
			if (reclaimed > 0) {
				DSP_LOG("DSpShutdownHandler: DSp heap reset reclaimed %llu bytes",
				        (unsigned long long)reclaimed);
			}
		} else {
			DSP_LOG("DSpShutdownHandler: DSp heap reset skipped; live allocations=%u",
			        (unsigned)gfxaccel_resources_heap_live_allocation_count(kHeapEngineDSp));
		}
		vbl_source_unregister_secondary_callback(DSpVBLReleaseCallback);
		/* Reset pending bits so a later re-init does not drain stale state. */
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
	/* Same version Gestalt('dspv') reports. */
	if (DSpVersionResultAddressIsWritable(outVersionAddr)) {
		WriteMacInt32(outVersionAddr, kDSpVersion_Current);
	}
	return kDSpVersion_Current;
}

/*
 *  Map DSp context state to DMC owner. Only Active owns the display; Paused
 *  restores the menu bar, so it counts as QuickDraw (DSp 1.7 p.29).
 *
 *  Returns uint32_t so dsp_draw_context.h need not include
 *  display_mode_controller.h. See DSpMapStateToDMCOwnerTyped().
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
