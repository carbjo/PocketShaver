/*
 *  display_mode_controller.cpp - Authoritative owner of display-mode state
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Sole writer of display-mode state. A state machine (Quiescent /
 *  QuickDrawOwner / ThreeDOwner / Transitioning / Blanking) accepts legal
 *  transitions and rejects the rest with a kDMCErr* code.
 *
 *  Each transition fires on_mode_exit in registration order before the
 *  snapshot swap, then on_mode_enter in reverse order after it. If an enter
 *  rejects, the outgoing snapshot is restored and kDMCErrSubscriberRejected
 *  returned. Late subscribers get a synthetic enter with the current snapshot.
 *
 *  Concurrency: writes are emul-thread only and serialized by s_write_mutex.
 *  Readers load s_current lock-free (acquire). Snapshots are immutable once
 *  published; a two-slot retirement ring keeps a reader's pointer valid for
 *  one more generation. A thread_local guard makes re-entrant calls from
 *  subscriber callbacks fail with kDMCErrReentrantRequest before locking.
 *
 *  Does not touch emulated Mac memory.
 */

#include "sysdeps.h"
#include "display_mode_controller.h"
#include "gfx_color_policy.h"

#include <cstring>
#include <cstdlib>
#include <vector>

#include <mutex>
#include <atomic>
#include <pthread.h>
#include <cassert>

#define DEBUG 0
#include "debug.h"

// DMC_ERR prints in release builds too, so rollbacks are always visible.
#define DMC_LOG(fmt, ...) D(bug("[DMC] " fmt "\n", ##__VA_ARGS__))
#define DMC_ERR(fmt, ...) do { printf("[DMC ERROR] " fmt "\n", ##__VA_ARGS__); } while (0)

// s_current is the only state readers touch. Everything else is guarded by
// s_write_mutex, which writers also hold when publishing s_current.
static std::mutex                             s_write_mutex;
static std::atomic<const DMCModeSnapshot *>   s_current{NULL};
static DMCState                               s_state = kDMCStateQuiescent;
static uint32_t                               s_next_generation = 1;
static bool                                   s_dmc_initialized = false;

// Registration order. Exit walks forward, enter walks backward.
static std::vector<DMCSubscriber>             s_subscribers;

// Retirement ring, indexed by (generation - 1) % 2. Publishing generation N
// frees N-2, which no reader can still hold.
static const DMCModeSnapshot *                s_retired[2] = { NULL, NULL };

// Set while inside a dmc_* write call; catches re-entry from subscribers.
static thread_local bool                      s_in_dmc_call = false;


// Captured by the first dmc_create; writes from other threads assert.
static pthread_t                              s_emul_thread = 0;

// Create at the top of every write API, before locking. If `installed` is
// false the call is re-entrant: return kDMCErrReentrantRequest without
// taking the (non-recursive) mutex.
struct DMCReentryScope {
	bool installed;
	DMCReentryScope() {
		if (s_in_dmc_call) {
			installed = false;
		} else {
			s_in_dmc_call = true;
			installed = true;
		}
	}
	~DMCReentryScope() {
		if (installed) {
			s_in_dmc_call = false;
		}
	}
};

#define DMC_ASSERT_EMUL_THREAD() \
	do { \
		if (s_emul_thread != 0 && pthread_self() != s_emul_thread) { \
			DMC_ERR("dmc_* called from non-emul thread (got %p, expected %p)", \
			        (void *)pthread_self(), (void *)s_emul_thread); \
			assert(0 && "DMC write from wrong thread"); \
		} \
	} while (0)

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

static int32_t dmc_validate_mode_desc(const DMCModeDesc *m) {
	if (m == NULL) {
		return kDMCErrInvalidModeDesc;
	}
	if (m->width == 0 || m->width > 4096) {
		return kDMCErrInvalidModeDesc;
	}
	if (m->height == 0 || m->height > 4096) {
		return kDMCErrInvalidModeDesc;
	}
	if (m->depth != 1 && m->depth != 2 && m->depth != 4 &&
	    m->depth != 8 && m->depth != 16 && m->depth != 32) {
		return kDMCErrInvalidModeDesc;
	}
	if (m->row_bytes == 0) {
		return kDMCErrInvalidModeDesc;
	}
	if (m->pitch < m->row_bytes) {
		return kDMCErrInvalidModeDesc;
	}
	return kDMCNoErr;
}

// Callers hold s_write_mutex.
static DMCModeSnapshot *dmc_alloc_zeroed_snapshot(void) {
	return (DMCModeSnapshot *)calloc(1, sizeof(DMCModeSnapshot));
}

static DMCModeSnapshot *dmc_alloc_raw_snapshot(void) {
	return (DMCModeSnapshot *)malloc(sizeof(DMCModeSnapshot));
}

// Despite the name, seeds the Mac Standard curve: the video driver's nil-table
// default and what the Display Manager pushes on mode switches. Using the same
// curve before the driver loads keeps the gamma policy consistent from the
// first frame.
static void dmc_init_identity_gamma(DMCModeSnapshot *snap) {
	for (int c = 0; c < 3; c++) {
		for (int i = 0; i < 256; i++) {
			const uint8_t v = GfxColorClassicMacToSRGBByte((uint8_t)i);
			snap->gamma_lut[c * 256 + i]        = v;
			snap->driver_gamma_lut[c * 256 + i] = v;
		}
	}
}

// palette_gen and gamma_gen start at 0 unless the caller copies them from
// the outgoing snapshot. Published snapshots always have transitioning == 0;
// the transition itself is tracked in s_state.
static DMCModeSnapshot *dmc_alloc_snapshot_from_desc(const DMCModeDesc *m,
                                                     uint32_t generation,
                                                     uint32_t active_owner,
                                                     const uint8_t blanking_rgba[4]) {
	DMCModeSnapshot *s = dmc_alloc_zeroed_snapshot();
	if (s == NULL) {
		return NULL;
	}
	s->generation       = generation;
	s->layout_gen       = generation;
	s->transitioning    = 0;
	s->width            = m->width;
	s->height           = m->height;
	s->depth            = m->depth;
	s->row_bytes        = m->row_bytes;
	s->pitch            = m->pitch;
	s->palette_gen      = 0;
	s->gamma_gen        = 0;
	s->fade_active      = 0;
	s->vbl_usec         = m->vbl_usec;
	s->active_owner     = active_owner;
	if (blanking_rgba != NULL) {
		s->blanking_rgba[0] = blanking_rgba[0];
		s->blanking_rgba[1] = blanking_rgba[1];
		s->blanking_rgba[2] = blanking_rgba[2];
		s->blanking_rgba[3] = blanking_rgba[3];
	} else {
		s->blanking_rgba[0] = 0;
		s->blanking_rgba[1] = 0;
		s->blanking_rgba[2] = 0;
		s->blanking_rgba[3] = 0xFF;
	}
	s->screen_base_mac  = m->screen_base_mac;
	s->screen_base_host = m->screen_base_host;
	dmc_init_identity_gamma(s);
	return s;
}

// Clone with a new owner and optionally new blanking_rgba. No revalidation:
// the fields were validated when first committed.
static DMCModeSnapshot *dmc_clone_snapshot_with_owner(const DMCModeSnapshot *src,
                                                      uint32_t generation,
                                                      uint32_t active_owner,
                                                      const uint8_t blanking_rgba[4]) {
	DMCModeSnapshot *s = dmc_alloc_zeroed_snapshot();
	if (s == NULL) {
		return NULL;
	}
	*s = *src;
	s->generation       = generation;
	s->layout_gen       = generation;
	s->transitioning    = 0;
	s->active_owner     = active_owner;
	if (blanking_rgba != NULL) {
		s->blanking_rgba[0] = blanking_rgba[0];
		s->blanking_rgba[1] = blanking_rgba[1];
		s->blanking_rgba[2] = blanking_rgba[2];
		s->blanking_rgba[3] = blanking_rgba[3];
	}
	return s;
}

// Blanking / Quiescent owners aren't valid here; callers handle them.
static DMCState dmc_target_state_for_owner(uint32_t owner) {
	if (owner == kDMCOwnerRAVE || owner == kDMCOwnerGL || owner == kDMCOwnerDSp) {
		return kDMCStateThreeDOwner;
	}
	return kDMCStateQuickDrawOwner;
}

// `this_gen` is the generation just published. Frees the snapshot retired
// two publishes ago. Caller holds s_write_mutex.
static void dmc_retire_snapshot(const DMCModeSnapshot *old_snap, uint32_t this_gen) {
	if (old_snap == NULL) {
		return;
	}
	int slot = (int)((this_gen - 1) % 2);
	if (s_retired[slot] != NULL) {
		free((void *)s_retired[slot]);
		s_retired[slot] = NULL;
	}
	s_retired[slot] = old_snap;
}

// Subscriber dispatch, called with s_write_mutex held. Exit runs in
// registration order and can't veto. Enter runs in reverse order; a non-zero
// return stops dispatch and the caller rolls back.

static void dmc_internal_fire_exit_events(const DMCModeSnapshot *outgoing) {
	for (size_t i = 0; i < s_subscribers.size(); ++i) {
		if (s_subscribers[i].on_mode_exit != NULL) {
			int32_t r = s_subscribers[i].on_mode_exit(outgoing, s_subscribers[i].ctx);
			if (r != kDMCNoErr) {
				DMC_LOG("subscriber %s on_mode_exit returned %d (advisory; not vetoable)",
				        s_subscribers[i].name != NULL ? s_subscribers[i].name : "?", (int)r);
			}
		}
	}
}

static int32_t dmc_internal_fire_enter_events(const DMCModeSnapshot *incoming) {
	for (size_t i = s_subscribers.size(); i > 0; --i) {
		size_t idx = i - 1;  // walk in reverse without size_t underflow
		if (s_subscribers[idx].on_mode_enter != NULL) {
			int32_t r = s_subscribers[idx].on_mode_enter(incoming, s_subscribers[idx].ctx);
			if (r != kDMCNoErr) {
				DMC_ERR("subscriber %s on_mode_enter returned %d - initiating rollback",
				        s_subscribers[idx].name != NULL ? s_subscribers[idx].name : "?", (int)r);
				return kDMCErrSubscriberRejected;
			}
		}
	}
	return kDMCNoErr;
}

static void dmc_internal_fire_enter_events_advisory(
	const DMCModeSnapshot *incoming,
	const char *reason)
{
	if (incoming == NULL) return;
	for (size_t i = s_subscribers.size(); i > 0; --i) {
		size_t idx = i - 1;
		if (s_subscribers[idx].on_mode_enter != NULL) {
			int32_t r = s_subscribers[idx].on_mode_enter(incoming,
			                                             s_subscribers[idx].ctx);
			if (r != kDMCNoErr) {
				DMC_ERR("subscriber %s on_mode_enter returned %d during "
				        "%s - rollback compensation continues",
				        s_subscribers[idx].name != NULL ? s_subscribers[idx].name : "?",
				        (int)r, reason != NULL ? reason : "rollback compensation");
			}
		}
	}
}

static void dmc_internal_compensate_rejected_transition(
	const DMCModeSnapshot *rejected,
	const DMCModeSnapshot *restored,
	DMCState restored_state,
	const char *reason)
{
	if (rejected != NULL) {
		dmc_internal_fire_exit_events(rejected);
	}
	s_current.store(restored, std::memory_order_release);
	s_state = restored_state;
	dmc_internal_fire_enter_events_advisory(restored, reason);
}

// Public API. Each write: re-entry guard, lock, thread assert, validation,
// then build the incoming snapshot, fire exits, publish, fire enters, and
// retire the outgoing snapshot (or roll back on an enter veto).

int32_t dmc_create(const struct DMCModeDesc *initial_mode) {
	DMCReentryScope reentry;
	if (!reentry.installed) {
		return kDMCErrReentrantRequest;
	}
	std::lock_guard<std::mutex> guard(s_write_mutex);
	// No thread assert: this call captures s_emul_thread.

	if (s_dmc_initialized) {
		return kDMCErrAlreadyInitialized;
	}
	int32_t verr = dmc_validate_mode_desc(initial_mode);
	if (verr != kDMCNoErr) {
		return verr;
	}

	if (s_emul_thread == 0) {
		s_emul_thread = pthread_self();
	}

	const uint8_t default_blanking[4] = { 0x00, 0x00, 0x00, 0xFF };
	DMCModeSnapshot *snap = dmc_alloc_snapshot_from_desc(initial_mode,
	                                                     s_next_generation,
	                                                     (uint32_t)kDMCOwnerQuickDraw,
	                                                     default_blanking);
	if (snap == NULL) {
		return kDMCErrOutOfMemory;
	}
	s_next_generation++;

	// Nothing to exit: the source state is Quiescent.
	s_current.store(snap, std::memory_order_release);
	s_state = kDMCStateQuickDrawOwner;
	s_dmc_initialized = true;

	// No subscribers can exist yet; this is for safety.
	int32_t enter_err = dmc_internal_fire_enter_events(snap);
	if (enter_err != kDMCNoErr) {
		// No prior snapshot, so roll back to Quiescent.
		dmc_internal_compensate_rejected_transition(
		    snap, NULL, kDMCStateQuiescent, "dmc_create enter veto");
		free(snap);
		s_dmc_initialized = false;
		s_next_generation--;
		return kDMCErrSubscriberRejected;
	}
	return kDMCNoErr;
}

int32_t dmc_shutdown(void) {
	DMCReentryScope reentry;
	if (!reentry.installed) {
		return kDMCErrReentrantRequest;
	}
	std::lock_guard<std::mutex> guard(s_write_mutex);
	DMC_ASSERT_EMUL_THREAD();

	if (!s_dmc_initialized) {
		return kDMCErrNotInitialized;
	}
	// Exit only: Quiescent has no incoming snapshot.
	const DMCModeSnapshot *cur = s_current.load(std::memory_order_relaxed);
	if (cur != NULL) {
		dmc_internal_fire_exit_events(cur);
	}
	s_current.store(NULL, std::memory_order_release);
	s_state = kDMCStateQuiescent;
	s_dmc_initialized = false;

	// No readers remain after shutdown, so free everything.
	if (cur != NULL) {
		free((void *)cur);
	}
	for (int i = 0; i < 2; ++i) {
		if (s_retired[i] != NULL) {
			free((void *)s_retired[i]);
			s_retired[i] = NULL;
		}
	}
	s_subscribers.clear();
	return kDMCNoErr;
}

int32_t dmc_subscribe(const struct DMCSubscriber *sub) {
	DMCReentryScope reentry;
	if (!reentry.installed) {
		return kDMCErrReentrantRequest;
	}
	std::lock_guard<std::mutex> guard(s_write_mutex);
	DMC_ASSERT_EMUL_THREAD();

	if (!s_dmc_initialized) {
		return kDMCErrNotInitialized;
	}
	if (sub == NULL || sub->name == NULL) {
		return kDMCErrSubscriberRejected;
	}
	for (size_t i = 0; i < s_subscribers.size(); ++i) {
		if (s_subscribers[i].name != NULL &&
		    strcmp(s_subscribers[i].name, sub->name) == 0) {
			return kDMCErrSubscriberAlreadyRegistered;
		}
	}
	DMCSubscriber copy = *sub;
	s_subscribers.push_back(copy);

	// Catch the new subscriber up with a synthetic enter. It can't veto an
	// already-committed state, so the return value is ignored.
	const DMCModeSnapshot *cur = s_current.load(std::memory_order_relaxed);
	if (cur != NULL && copy.on_mode_enter != NULL) {
		(void)copy.on_mode_enter(cur, copy.ctx);
	}
	return kDMCNoErr;
}

int32_t dmc_unsubscribe(const char *name) {
	DMCReentryScope reentry;
	if (!reentry.installed) {
		return kDMCErrReentrantRequest;
	}
	std::lock_guard<std::mutex> guard(s_write_mutex);
	DMC_ASSERT_EMUL_THREAD();

	if (!s_dmc_initialized) {
		return kDMCErrNotInitialized;
	}
	if (name == NULL) {
		return kDMCErrSubscriberNotFound;
	}
	for (size_t i = 0; i < s_subscribers.size(); ++i) {
		if (s_subscribers[i].name != NULL &&
		    strcmp(s_subscribers[i].name, name) == 0) {
			s_subscribers.erase(s_subscribers.begin() + i);
			return kDMCNoErr;
		}
	}
	return kDMCErrSubscriberNotFound;
}

// Lock-free, any thread. The pointer stays valid for at least one more
// publish (retirement ring).
const struct DMCModeSnapshot *dmc_current_snapshot(void) {
	return s_current.load(std::memory_order_acquire);
}

// True while a 3D or DrawSprocket context owns the screen. SynchIdleTime
// (emul_op.cpp) caps its host sleep then, so per-frame and per-read guest
// yields do not each wait for the next 60Hz tick.
extern "C" int gfx_idle_latency_sensitive(void) {
	const DMCModeSnapshot *snap = dmc_current_snapshot();
	if (!snap) return 0;
	return snap->active_owner == kDMCOwnerRAVE ||
	       snap->active_owner == kDMCOwnerGL ||
	       snap->active_owner == kDMCOwnerDSp;
}

int32_t dmc_request_mode_switch(const struct DMCModeDesc *new_mode) {
	DMCReentryScope reentry;
	if (!reentry.installed) {
		return kDMCErrReentrantRequest;
	}
	std::lock_guard<std::mutex> guard(s_write_mutex);
	DMC_ASSERT_EMUL_THREAD();

	if (!s_dmc_initialized) {
		return kDMCErrNotInitialized;
	}
	if (s_state == kDMCStateTransitioning) {
		return kDMCErrTransitionInProgress;
	}
	if (s_state == kDMCStateBlanking) {
		return kDMCErrIllegalTransition;
	}
	int32_t verr = dmc_validate_mode_desc(new_mode);
	if (verr != kDMCNoErr) {
		return verr;
	}

	// Relaxed is fine: we hold the writer mutex.
	const DMCModeSnapshot *outgoing = s_current.load(std::memory_order_relaxed);
	DMCState         src_state = s_state;
	uint32_t prior_owner = (outgoing != NULL) ? outgoing->active_owner : (uint32_t)kDMCOwnerQuickDraw;
	uint32_t new_owner;
	if (prior_owner == kDMCOwnerRAVE ||
	    prior_owner == kDMCOwnerGL ||
	    prior_owner == kDMCOwnerDSp) {
		new_owner = prior_owner;
	} else {
		new_owner = (uint32_t)kDMCOwnerQuickDraw;
	}
	// Carry these across the switch. fade_active matters because DSp games
	// can FadeGammaOut across a resolution change.
	uint32_t carry_palette_gen = (outgoing != NULL) ? outgoing->palette_gen : 0;
	uint32_t carry_gamma_gen   = (outgoing != NULL) ? outgoing->gamma_gen   : 0;
	uint32_t carry_fade_active = (outgoing != NULL) ? outgoing->fade_active : 0;
	const uint8_t carry_blanking[4] = {
		(outgoing != NULL) ? outgoing->blanking_rgba[0] : (uint8_t)0,
		(outgoing != NULL) ? outgoing->blanking_rgba[1] : (uint8_t)0,
		(outgoing != NULL) ? outgoing->blanking_rgba[2] : (uint8_t)0,
		(outgoing != NULL) ? outgoing->blanking_rgba[3] : (uint8_t)0xFF
	};

	// Readers keep seeing `outgoing` until the publish below.
	s_state = kDMCStateTransitioning;

	if (outgoing != NULL) {
		dmc_internal_fire_exit_events(outgoing);
	}

	DMCModeSnapshot *incoming = dmc_alloc_snapshot_from_desc(new_mode,
	                                                         s_next_generation,
	                                                         new_owner,
	                                                         carry_blanking);
	if (incoming == NULL) {
		// Exits already ran, so compensate with an advisory enter.
		s_state = src_state;
		dmc_internal_fire_enter_events_advisory(
		    outgoing, "dmc_request_mode_switch allocation rollback");
		return kDMCErrOutOfMemory;
	}
	incoming->palette_gen = carry_palette_gen;
	incoming->gamma_gen   = carry_gamma_gen;
	incoming->fade_active = carry_fade_active;
	// Replace the default gamma with the outgoing LUTs.
	if (outgoing != NULL) {
		memcpy(incoming->gamma_lut, outgoing->gamma_lut, 768);
		memcpy(incoming->driver_gamma_lut, outgoing->driver_gamma_lut, 768);
	}
	s_next_generation++;

	s_current.store(incoming, std::memory_order_release);
	DMCState target = dmc_target_state_for_owner(new_owner);
	s_state = target;

	int32_t enter_err = dmc_internal_fire_enter_events(incoming);
	if (enter_err != kDMCNoErr) {
		dmc_internal_compensate_rejected_transition(
		    incoming, outgoing, src_state,
		    "dmc_request_mode_switch enter veto");
		// Readers may have loaded `incoming`, so retire it through the ring
		// rather than freeing it. Its generation stays consumed; the slot
		// math depends on s_next_generation not being decremented.
		dmc_retire_snapshot(incoming, incoming->generation + 1);
		return kDMCErrSubscriberRejected;
	}

	dmc_retire_snapshot(outgoing, incoming->generation);
	return kDMCNoErr;
}

int32_t dmc_set_active_owner(uint32_t owner) {
	DMCReentryScope reentry;
	if (!reentry.installed) {
		return kDMCErrReentrantRequest;
	}
	std::lock_guard<std::mutex> guard(s_write_mutex);
	DMC_ASSERT_EMUL_THREAD();

	if (!s_dmc_initialized) {
		return kDMCErrNotInitialized;
	}
	// Blanking and Quiescent are reached via dmc_request_blanking and
	// dmc_shutdown, not here.
	if (owner > (uint32_t)kDMCOwnerQuiescent) {
		return kDMCErrInvalidOwner;
	}
	if (owner == (uint32_t)kDMCOwnerBlanking ||
	    owner == (uint32_t)kDMCOwnerQuiescent) {
		return kDMCErrInvalidOwner;
	}
	if (s_state == kDMCStateBlanking) {
		return kDMCErrIllegalTransition;
	}
	if (s_state == kDMCStateTransitioning) {
		return kDMCErrTransitionInProgress;
	}

	const DMCModeSnapshot *outgoing = s_current.load(std::memory_order_relaxed);
	// Engines may call this every frame, so skip the transition when both
	// owner and state already match.
	if (outgoing != NULL &&
	    outgoing->active_owner == owner &&
	    s_state == dmc_target_state_for_owner(owner)) {
		return kDMCNoErr;
	}
	DMCState         src_state = s_state;

	s_state = kDMCStateTransitioning;
	if (outgoing != NULL) {
		dmc_internal_fire_exit_events(outgoing);
	}

	DMCModeSnapshot *incoming = dmc_clone_snapshot_with_owner(outgoing,
	                                                          s_next_generation,
	                                                          owner,
	                                                          NULL);
	if (incoming == NULL) {
		// Exits already ran, so compensate.
		s_state = src_state;
		dmc_internal_fire_enter_events_advisory(
		    outgoing, "dmc_set_active_owner allocation rollback");
		return kDMCErrOutOfMemory;
	}
	s_next_generation++;
	s_current.store(incoming, std::memory_order_release);
	DMCState target = dmc_target_state_for_owner(owner);
	s_state = target;

	int32_t enter_err = dmc_internal_fire_enter_events(incoming);
	if (enter_err != kDMCNoErr) {
		dmc_internal_compensate_rejected_transition(
		    incoming, outgoing, src_state,
		    "dmc_set_active_owner enter veto");
		// Retire, don't free (see dmc_request_mode_switch).
		dmc_retire_snapshot(incoming, incoming->generation + 1);
		return kDMCErrSubscriberRejected;
	}

	dmc_retire_snapshot(outgoing, incoming->generation);
	return kDMCNoErr;
}

int32_t dmc_request_blanking(const uint8_t rgba[4]) {
	DMCReentryScope reentry;
	if (!reentry.installed) {
		return kDMCErrReentrantRequest;
	}
	std::lock_guard<std::mutex> guard(s_write_mutex);
	DMC_ASSERT_EMUL_THREAD();

	if (!s_dmc_initialized) {
		return kDMCErrNotInitialized;
	}
	if (s_state == kDMCStateBlanking) {
		return kDMCErrBlankingAlreadyActive;
	}
	if (s_state == kDMCStateTransitioning) {
		return kDMCErrTransitionInProgress;
	}

	const DMCModeSnapshot *outgoing = s_current.load(std::memory_order_relaxed);
	DMCState         src_state = s_state;

	s_state = kDMCStateTransitioning;
	if (outgoing != NULL) {
		dmc_internal_fire_exit_events(outgoing);
	}

	DMCModeSnapshot *incoming = dmc_clone_snapshot_with_owner(outgoing,
	                                                          s_next_generation,
	                                                          (uint32_t)kDMCOwnerBlanking,
	                                                          rgba);
	if (incoming == NULL) {
		// Exits already ran, so compensate.
		s_state = src_state;
		dmc_internal_fire_enter_events_advisory(
		    outgoing, "dmc_request_blanking allocation rollback");
		return kDMCErrOutOfMemory;
	}
	s_next_generation++;
	s_current.store(incoming, std::memory_order_release);
	s_state = kDMCStateBlanking;

	int32_t enter_err = dmc_internal_fire_enter_events(incoming);
	if (enter_err != kDMCNoErr) {
		dmc_internal_compensate_rejected_transition(
		    incoming, outgoing, src_state,
		    "dmc_request_blanking enter veto");
		// Retire, don't free (see dmc_request_mode_switch).
		dmc_retire_snapshot(incoming, incoming->generation + 1);
		return kDMCErrSubscriberRejected;
	}

	dmc_retire_snapshot(outgoing, incoming->generation);
	return kDMCNoErr;
}

int32_t dmc_end_blanking(void) {
	DMCReentryScope reentry;
	if (!reentry.installed) {
		return kDMCErrReentrantRequest;
	}
	std::lock_guard<std::mutex> guard(s_write_mutex);
	DMC_ASSERT_EMUL_THREAD();

	if (!s_dmc_initialized) {
		return kDMCErrNotInitialized;
	}
	if (s_state != kDMCStateBlanking) {
		return kDMCErrNotBlanking;
	}

	const DMCModeSnapshot *outgoing = s_current.load(std::memory_order_relaxed);
	DMCState         src_state = s_state;

	s_state = kDMCStateTransitioning;
	if (outgoing != NULL) {
		dmc_internal_fire_exit_events(outgoing);
	}

	DMCModeSnapshot *incoming = dmc_clone_snapshot_with_owner(outgoing,
	                                                          s_next_generation,
	                                                          (uint32_t)kDMCOwnerQuickDraw,
	                                                          NULL);
	if (incoming == NULL) {
		// Exits already ran, so compensate.
		s_state = src_state;
		dmc_internal_fire_enter_events_advisory(
		    outgoing, "dmc_end_blanking allocation rollback");
		return kDMCErrOutOfMemory;
	}
	s_next_generation++;
	s_current.store(incoming, std::memory_order_release);
	s_state = kDMCStateQuickDrawOwner;

	int32_t enter_err = dmc_internal_fire_enter_events(incoming);
	if (enter_err != kDMCNoErr) {
		dmc_internal_compensate_rejected_transition(
		    incoming, outgoing, src_state,
		    "dmc_end_blanking enter veto");
		// Retire, don't free (see dmc_request_mode_switch).
		dmc_retire_snapshot(incoming, incoming->generation + 1);
		return kDMCErrSubscriberRejected;
	}

	dmc_retire_snapshot(outgoing, incoming->generation);
	return kDMCNoErr;
}

// Field-only updates (palette, gamma, blanking color) still publish a fresh
// snapshot with a new generation, keeping the retirement ring consistent.
// They fire no subscriber events; listeners compare palette_gen / gamma_gen.
int32_t dmc_record_palette_change(void) {
	DMCReentryScope reentry;
	if (!reentry.installed) {
		return kDMCErrReentrantRequest;
	}
	std::lock_guard<std::mutex> guard(s_write_mutex);
	DMC_ASSERT_EMUL_THREAD();

	if (!s_dmc_initialized) {
		return kDMCErrNotInitialized;
	}
	const DMCModeSnapshot *old = s_current.load(std::memory_order_relaxed);
	if (old == NULL) {
		return kDMCErrNotInitialized;
	}
	DMCModeSnapshot *fresh = dmc_alloc_raw_snapshot();
	if (fresh == NULL) {
		return kDMCErrOutOfMemory;
	}
	memcpy(fresh, old, sizeof(DMCModeSnapshot));
	fresh->generation  = s_next_generation++;
	fresh->palette_gen = old->palette_gen + 1;

	s_current.store(fresh, std::memory_order_release);
	dmc_retire_snapshot(old, fresh->generation);
	return kDMCNoErr;
}

// Publishes fade_active in the same snapshot as the LUT. A separate setter
// would allow one torn frame with a mid-fade LUT and a stale flag.
int32_t dmc_record_gamma_change_with_lut_fade(const uint8_t *lut, int fade_active) {
	DMCReentryScope reentry;
	if (!reentry.installed) {
		return kDMCErrReentrantRequest;
	}
	std::lock_guard<std::mutex> guard(s_write_mutex);
	DMC_ASSERT_EMUL_THREAD();

	if (!s_dmc_initialized) {
		return kDMCErrNotInitialized;
	}
	const DMCModeSnapshot *old = s_current.load(std::memory_order_relaxed);
	if (old == NULL) {
		return kDMCErrNotInitialized;
	}
	DMCModeSnapshot *fresh = dmc_alloc_raw_snapshot();
	if (fresh == NULL) {
		return kDMCErrOutOfMemory;
	}
	memcpy(fresh, old, sizeof(DMCModeSnapshot));
	fresh->generation  = s_next_generation++;
	fresh->gamma_gen   = old->gamma_gen + 1;
	fresh->fade_active = (uint32_t)(fade_active ? 1 : 0);

	if (lut != NULL) {
		memcpy(fresh->gamma_lut, lut, 768);
	}

	s_current.store(fresh, std::memory_order_release);
	dmc_retire_snapshot(old, fresh->generation);
	return kDMCNoErr;
}

// lut is planar 768 bytes (256 R, G, B); NULL keeps the current LUT. Not a
// fade, so fade_active is cleared.
int32_t dmc_record_gamma_change_with_lut(const uint8_t *lut) {
	return dmc_record_gamma_change_with_lut_fade(lut, 0);
}

// Guest SetGamma table. Always stored as driver_gamma_lut (what DSp fades
// blend toward), but applied to gamma_lut only when no fade is running;
// otherwise the faded screen would pop. The fade's end state applies it.
int32_t dmc_record_driver_gamma_change(const uint8_t *lut) {
	if (lut == NULL) {
		return kDMCErrInvalidModeDesc;
	}
	DMCReentryScope reentry;
	if (!reentry.installed) {
		return kDMCErrReentrantRequest;
	}
	std::lock_guard<std::mutex> guard(s_write_mutex);
	DMC_ASSERT_EMUL_THREAD();

	if (!s_dmc_initialized) {
		return kDMCErrNotInitialized;
	}
	const DMCModeSnapshot *old = s_current.load(std::memory_order_relaxed);
	if (old == NULL) {
		return kDMCErrNotInitialized;
	}
	DMCModeSnapshot *fresh = dmc_alloc_raw_snapshot();
	if (fresh == NULL) {
		return kDMCErrOutOfMemory;
	}
	memcpy(fresh, old, sizeof(DMCModeSnapshot));
	fresh->generation = s_next_generation++;
	memcpy(fresh->driver_gamma_lut, lut, 768);

	const bool apply_now = (old->fade_active == 0);
	if (apply_now) {
		fresh->gamma_gen = old->gamma_gen + 1;
		memcpy(fresh->gamma_lut, lut, 768);
	}

	s_current.store(fresh, std::memory_order_release);
	dmc_retire_snapshot(old, fresh->generation);
	return apply_now ? kDMCNoErr : kDMCDriverGammaDeferred;
}

// Bump gamma_gen without changing the LUT.
int32_t dmc_record_gamma_change(void) {
	return dmc_record_gamma_change_with_lut(NULL);
}

// Sets the color for the next blank without blanking now (DSpSetBlankingColor,
// DSp 1.7 p.30), so no state transition.
int32_t dmc_set_blanking_color(const uint8_t rgba[4]) {
	DMCReentryScope reentry;
	if (!reentry.installed) {
		return kDMCErrReentrantRequest;
	}
	std::lock_guard<std::mutex> guard(s_write_mutex);
	DMC_ASSERT_EMUL_THREAD();

	if (!s_dmc_initialized) {
		return kDMCErrNotInitialized;
	}
	if (rgba == NULL) {
		return kDMCErrInvalidModeDesc;
	}
	const DMCModeSnapshot *old = s_current.load(std::memory_order_relaxed);
	if (old == NULL) {
		return kDMCErrNotInitialized;
	}
	DMCModeSnapshot *fresh = dmc_alloc_raw_snapshot();
	if (fresh == NULL) {
		return kDMCErrOutOfMemory;
	}
	memcpy(fresh, old, sizeof(DMCModeSnapshot));
	fresh->generation = s_next_generation++;
	memcpy(fresh->blanking_rgba, rgba, 4);

	s_current.store(fresh, std::memory_order_release);
	dmc_retire_snapshot(old, fresh->generation);
	return kDMCNoErr;
}
