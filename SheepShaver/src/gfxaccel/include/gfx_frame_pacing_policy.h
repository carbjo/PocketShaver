/*
 *  gfx_frame_pacing_policy.h - 3D frame pacing policy.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 */

#ifndef GFX_FRAME_PACING_POLICY_H
#define GFX_FRAME_PACING_POLICY_H

#include <stdint.h>

enum GfxFramePacingEngine {
	kGfxFramePacingEngineDSp = 0,
	kGfxFramePacingEngineGL = 1,
	kGfxFramePacingEngineRAVE = 2,
	kGfxFramePacingEngineLegacy = 3,
	kGfxFramePacingEngineCount = 4
};

/*
 * Deadline pacing is per engine: each engine advances one deadline per 3D
 * frame and never consumes another engine's banked VBL credits. If
 * display-link ticks stop, callers fall back to the current cadence.
 *
 * A vblank that already passed since an engine's previous sync satisfies
 * that sync: it returns without sleeping and the deadline moves to the next
 * future boundary. This keeps co-resident engines (DSp+GL in The Sims) on
 * the same vblank instead of a half-rate cap, avoids an extra full-period
 * wait after a long frame, and lets SetMaxFrameRate's N-syncs-per-swap loop
 * count render time toward the cap.
 */
static inline uint64_t GfxFramePacingClampCadenceUsec(uint64_t cadence_usec)
{
	if (cadence_usec < 8333) return 8333;     /* 120 Hz ceiling */
	if (cadence_usec > 33333) return 33333;   /* 30 Hz floor */
	return cadence_usec;
}

#define GFX_FRAME_PACING_DEFAULT_USEC 16667
#define GFX_FRAME_PACING_STALE_TICKS  4

#endif /* GFX_FRAME_PACING_POLICY_H */
