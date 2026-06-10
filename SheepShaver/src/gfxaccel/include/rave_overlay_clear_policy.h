/*
 *  rave_overlay_clear_policy.h - RAVE overlay clear alpha helpers.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 */

#ifndef RAVE_OVERLAY_CLEAR_POLICY_H
#define RAVE_OVERLAY_CLEAR_POLICY_H

#include <stdint.h>

static inline float RaveOverlayClearAlpha(float guest_clear_alpha)
{
	if (guest_clear_alpha < 0.0f) {
		return 0.0f;
	}
	if (guest_clear_alpha > 1.0f) {
		return 1.0f;
	}
	return guest_clear_alpha;
}

static inline int RaveOverlayCoversMode(
    uint32_t overlay_width,
    uint32_t overlay_height,
    uint32_t mode_width,
    uint32_t mode_height)
{
	return mode_width == 0 || mode_height == 0 ||
	       (overlay_width >= mode_width && overlay_height >= mode_height);
}

static inline int RaveOverlayClearIsBlack(float r, float g, float b)
{
	return r == 0.0f && g == 0.0f && b == 0.0f;
}

static inline float RaveOverlayEffectiveClearAlpha(
    float r,
    float g,
    float b,
    float guest_clear_alpha,
    uint32_t overlay_width,
    uint32_t overlay_height,
    uint32_t mode_width,
    uint32_t mode_height)
{
	float alpha = RaveOverlayClearAlpha(guest_clear_alpha);

	(void)r;
	(void)g;
	(void)b;
	(void)overlay_width;
	(void)overlay_height;
	(void)mode_width;
	(void)mode_height;

	if (alpha == 0.0f) {
		return 1.0f;
	}
	return alpha;
}

static inline float RaveOverlayPremultipliedClearComponent(
    float guest_clear_component, float guest_clear_alpha)
{
	return guest_clear_component * RaveOverlayClearAlpha(guest_clear_alpha);
}

#endif /* RAVE_OVERLAY_CLEAR_POLICY_H */
