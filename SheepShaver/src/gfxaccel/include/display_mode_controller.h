/*
 *  display_mode_controller.h - Authoritative owner of display-mode state
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  C interface to the Display-Mode Controller (DMC), the single writer of
 *  display state. Plain C types only, so plain .cpp files can include it.
 *  Native callers only; not reachable from PPC code.
 *
 *  The controller is a 5-state FSM (Quiescent / QuickDrawOwner /
 *  ThreeDOwner / Transitioning / Blanking) with legal transitions T1..T12.
 *  Illegal transitions return a kDMCErr* code and leave state unchanged.
 */

#ifndef DISPLAY_MODE_CONTROLLER_H
#define DISPLAY_MODE_CONTROLLER_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Negative OSErr-style codes in -3001 .. -3099. These are native programmer
 * errors, not guest faults, and must never be suppressed by the
 * ignoreIllegalInstructions preference.
 */
enum DMCError {
	kDMCNoErr                          = 0,
	kDMCErrNotInitialized              = -3001,  /* call before dmc_create() */
	kDMCErrAlreadyInitialized          = -3002,  /* dmc_create() called twice */
	kDMCErrTransitionInProgress        = -3003,  /* request_* called while in Transitioning */
	kDMCErrInvalidModeDesc             = -3004,  /* unknown depth, zero width, row_bytes invalid, etc. */
	kDMCErrInvalidOwner                = -3005,  /* set_active_owner with unknown enum value */
	kDMCErrOwnerMismatch               = -3006,  /* caller releases an owner different from the current one */
	kDMCErrSubscriberRejected          = -3007,  /* reserved (on_mode_enter returned non-zero) */
	kDMCErrConcurrentWrite             = -3008,  /* reserved (writer mutex contention) */
	kDMCErrIllegalTransition           = -3009,  /* catch-all for state-matrix miss */
	kDMCErrBlankingAlreadyActive       = -3010,  /* request_blanking from Blanking state */
	kDMCErrNotBlanking                 = -3011,  /* end_blanking from non-Blanking state */
	kDMCErrSnapshotStale               = -3012,  /* reserved (reader held a pointer across a transition) */
	kDMCErrReentrantRequest            = -3013,  /* reserved (re-entry guard) */
	kDMCErrSubscriberNotFound          = -3014,  /* dmc_unsubscribe: name does not match any registered subscriber */
	kDMCErrSubscriberAlreadyRegistered = -3015, /* dmc_subscribe: duplicate name */
	kDMCErrOutOfMemory                 = -3016, /* allocation failure (distinct from param-invalid codes) */
	kDMCDriverGammaDeferred            = 1      /* success: driver gamma stored but not displayed because a DSp
	                                             * fade is in progress. Caller must not push it to the compositor. */
};

/*
 * The subsystem currently driving the display; exactly one at a time
 * (matches the compositor's single overlay_active flag). The owner drives
 * mode semantics (VBL pacing, palette, blanking), not composition layering.
 */
enum DMCOwner {
	kDMCOwnerQuickDraw   = 0,  /* default - 2D framebuffer, no 3D overlay */
	kDMCOwnerRAVE        = 1,  /* RAVE 3D context active */
	kDMCOwnerGL          = 2,  /* OpenGL 3D context active */
	kDMCOwnerDSp         = 3,  /* DrawSprocket context active */
	kDMCOwnerBlanking    = 4,  /* solid-color blanking (fade / app-suspend) */
	kDMCOwnerQuiescent   = 5   /* no display */
};

/*
 * FSM states. Transitioning spans the exit-then-enter event sequence;
 * Blanking backs DSp fades and blanking.
 */
enum DMCState {
	kDMCStateQuiescent       = 0,
	kDMCStateQuickDrawOwner  = 1,
	kDMCStateThreeDOwner     = 2,
	kDMCStateTransitioning   = 3,
	kDMCStateBlanking        = 4
};

/*
 * Input to dmc_create() and dmc_request_mode_switch(). Validated before any
 * state change; failures return kDMCErrInvalidModeDesc.
 */
struct DMCModeDesc {
	uint32_t  width;            /* pixels, > 0, <= 4096 */
	uint32_t  height;           /* pixels, > 0, <= 4096 */
	uint32_t  depth;            /* VIDEO_DEPTH_* constant; one of {1,2,4,8,16,32} */
	uint32_t  row_bytes;        /* per-row stride in bytes; > 0 */
	uint32_t  pitch;            /* allocation stride (>= row_bytes) */
	uint32_t  vbl_usec;         /* microseconds per VBL; 0 = derive from the frame-rate setting */
	uint32_t  screen_base_mac;  /* Mac framebuffer address; 0 = set later */
	void     *screen_base_host; /* host framebuffer pointer; may be NULL */
};

/*
 * Immutable snapshot of the published display state, read from any thread
 * via dmc_current_snapshot().
 */
struct DMCModeSnapshot {
	uint32_t       generation;              /* monotonic, bumped per commit; 0 reserved */
	uint32_t       layout_gen;              /* generation of the last mode/owner/blanking commit; gamma and palette changes keep it */
	int32_t        transitioning;           /* always 0 in published snapshots */
	uint32_t       width;
	uint32_t       height;
	uint32_t       depth;
	uint32_t       row_bytes;
	uint32_t       pitch;
	uint32_t       palette_gen;             /* bumped on every CLUT change */
	uint32_t       gamma_gen;               /* bumped on every gamma change */
	uint8_t        gamma_lut[768];          /* Mac-side planar LUT: 256 R + 256 G + 256 B */
	uint32_t       fade_active;             /* 1 during a DSp gamma fade; disables the compositor's static 1.8->2.2
	                                         * LUT composition so the fade is linear. Published with gamma_lut. */
	uint8_t        driver_gamma_lut[768];   /* last guest SetGamma table (identity until set). DSp fades restore
	                                         * to this, since games may install non-identity ramps. Outside
	                                         * fades, gamma_lut == driver_gamma_lut. */
	uint32_t       vbl_usec;
	uint32_t       active_owner;            /* DMCOwner value */
	uint8_t        blanking_rgba[4];        /* RGBA; only meaningful in Blanking state */
	uint32_t       screen_base_mac;
	void          *screen_base_host;
};

/*
 * Subscriber callbacks (both nullable). Exit fires before the outgoing
 * snapshot is retired, in registration order. Enter fires after the incoming
 * snapshot is published, in reverse order. A non-zero enter return rolls the
 * transition back: exit(rejected), then advisory enter(restored). Exit
 * returns are ignored.
 */
typedef int32_t (*DMCExitFn)(const struct DMCModeSnapshot *outgoing, void *ctx);
typedef int32_t (*DMCEnterFn)(const struct DMCModeSnapshot *incoming, void *ctx);

struct DMCSubscriber {
	const char    *name;                    /* unique key, also used in logs */
	DMCExitFn      on_mode_exit;            /* nullable */
	DMCEnterFn     on_mode_enter;           /* nullable */
	void          *ctx;
};

/*
 * Call once, on the emulator thread, before any other dmc_* call.
 * Quiescent -> QuickDrawOwner (T1); publishes generation 1. All write calls
 * must come from that thread.
 */
int32_t dmc_create(const struct DMCModeDesc *initial_mode);

/* Any state -> Quiescent (T10/T11/T12). Frees snapshots, clears subscribers. */
int32_t dmc_shutdown(void);

/*
 * The struct is copied, but `name` is borrowed: keep it alive while
 * registered. A late subscriber gets a synthetic on_mode_enter(current)
 * whose return value is ignored.
 *
 * Returns kDMCErrSubscriberRejected for a NULL sub or name, and
 * kDMCErrSubscriberAlreadyRegistered for a duplicate name.
 */
int32_t dmc_subscribe(const struct DMCSubscriber *sub);

int32_t dmc_unsubscribe(const char *name);

/*
 * Lock-free; callable from any thread. Returns NULL in Quiescent. The
 * pointer stays valid for at least one more publish. Do not free or mutate.
 */
const struct DMCModeSnapshot *dmc_current_snapshot(void);

/*
 * T2 (from QuickDrawOwner) or T6 (from ThreeDOwner); the active owner is
 * preserved. Synchronous, with exit/enter dispatch. Returns
 * kDMCErrIllegalTransition from Blanking (end blanking first).
 */
int32_t dmc_request_mode_switch(const struct DMCModeDesc *new_mode);

/*
 * T4 (QuickDrawOwner -> ThreeDOwner) for RAVE/GL/DSp; T5 back for QuickDraw.
 * owner is a DMCOwner passed as uint32_t for a fixed C ABI width. Returns
 * kDMCErrIllegalTransition from Blanking.
 */
int32_t dmc_set_active_owner(uint32_t owner);

/* T8. While blanking, the compositor draws the solid color every frame. */
int32_t dmc_request_blanking(const uint8_t rgba[4]);

/* T9: Blanking -> QuickDrawOwner. */
int32_t dmc_end_blanking(void);

/* Bump palette_gen; the compositor picks up the new CLUT next frame. */
int32_t dmc_record_palette_change(void);

/* Bump gamma_gen without changing the LUT. */
int32_t dmc_record_gamma_change(void);

/*
 * lut is 768 bytes, planar (256 R, 256 G, 256 B). NULL keeps the current LUT
 * and only bumps gamma_gen.
 */
int32_t dmc_record_gamma_change_with_lut(const uint8_t *lut);

/*
 * As above, but also publishes fade_active in the same snapshot so no frame
 * pairs a mid-fade LUT with a stale flag. The DSp fade driver passes 1 on
 * mid-fade frames and 0 on the final frame.
 */
int32_t dmc_record_gamma_change_with_lut_fade(const uint8_t *lut, int fade_active);

/*
 * Guest SetGamma table. Always stored in driver_gamma_lut; applied to the
 * displayed LUT only when no fade is in progress (applying mid-fade would
 * pop; the fade end-state delivers it instead).
 *
 * Returns kDMCNoErr if applied (caller pushes it to the compositor),
 * kDMCDriverGammaDeferred if only stored (caller must not push), or
 * kDMCErrInvalidModeDesc for a NULL lut.
 */
int32_t dmc_record_driver_gamma_change(const uint8_t *lut);

/*
 * Set the blanking color without entering Blanking. DSpSetBlankingColor only
 * sets the color for the next blank; it does not blank now (DSp 1.7 p.30).
 * rgba is R, G, B, A.
 */
int32_t dmc_set_blanking_color(const uint8_t rgba[4]);

#ifdef __cplusplus
}
#endif

#endif /* DISPLAY_MODE_CONTROLLER_H */
