/*
 *  overlay_clear_policy.h - shared accelerated overlay clear policy.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 */

#ifndef OVERLAY_CLEAR_POLICY_H
#define OVERLAY_CLEAR_POLICY_H

#include <stdbool.h>

/*
 * RAVE and GL window drawables are premultiplied overlays over the QuickDraw
 * framebuffer. A zero-alpha clear with nonzero RGB is treated as opaque, since
 * legacy titles use the clear color as the scene backdrop. Offscreen GL
 * drawables keep guest alpha because the guest reads them back.
 */

static inline float OverlayClearClampAlpha(float guest_clear_alpha)
{
	if (guest_clear_alpha < 0.0f)
		return 0.0f;
	if (guest_clear_alpha > 1.0f)
		return 1.0f;
	return guest_clear_alpha;
}

static inline float OverlayClearEffectiveAlpha(bool is_offscreen,
                                               float guest_clear_alpha)
{
	const float alpha = OverlayClearClampAlpha(guest_clear_alpha);
	if (is_offscreen)
		return alpha;
	return alpha == 0.0f ? 1.0f : alpha;
}

static inline float OverlayClearPremultipliedComponent(
	float guest_clear_component, float effective_clear_alpha)
{
	return guest_clear_component *
	       OverlayClearClampAlpha(effective_clear_alpha);
}

#endif /* OVERLAY_CLEAR_POLICY_H */
