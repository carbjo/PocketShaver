/*
 *  dsp_front_staging_present_policy.h - front-staging change detection.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 */

#ifndef DSP_FRONT_STAGING_PRESENT_POLICY_H
#define DSP_FRONT_STAGING_PRESENT_POLICY_H

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

struct DSpFrontStagingPresentState {
	bool     valid;
	bool     encoded;
	uint32_t last_hash;
	uint32_t last_size;
	uint32_t last_gamma_gen;
	uint32_t last_fade_active;
	uint32_t unchanged_skips;
};

static inline uint32_t DSpFrontStagingHashBytes(const uint8_t *bytes,
                                                uint32_t size)
{
	/* Internal dirty-check hash only: the result is compared solely against a
	 * value produced by this same function (never persisted, never wire-visible,
	 * gamma-independent), so the algorithm is free to change as long as it stays
	 * full-coverage -- every byte must affect the result, or a partial guest
	 * update in skipped bytes would be missed and leave stale pixels under a 3D
	 * overlay. This word-wide 64-bit FNV-1a processes 8 bytes per iteration and
	 * folds to 32 bits, ~8x fewer iterations than the byte-at-a-time form over
	 * the ~1.9MB front-staging surface scanned every VBL on the emulator thread. */
	if (bytes == 0 || size == 0) return 2166136261u;

	const uint64_t kOffset = 1469598103934665603ull;
	const uint64_t kPrime  = 1099511628211ull;
	uint64_t hash = kOffset;

	uint32_t i = 0;
	const uint32_t wordEnd = size & ~(uint32_t)7u;
	for (; i < wordEnd; i += 8) {
		uint64_t w;
		memcpy(&w, bytes + i, sizeof(w));   /* unaligned-safe; one 64-bit load on ARM64 */
		hash ^= w;
		hash *= kPrime;
	}
	for (; i < size; i++) {
		hash ^= (uint64_t)bytes[i];
		hash *= kPrime;
	}
	return (uint32_t)(hash ^ (hash >> 32));
}

static inline void DSpFrontStagingRememberHashForGamma(
	DSpFrontStagingPresentState *state,
	uint32_t hash,
	uint32_t size,
	uint32_t gamma_gen,
	uint32_t fade_active)
{
	if (state == 0) return;
	state->valid = true;
	state->encoded = true;
	state->last_hash = hash;
	state->last_size = size;
	state->last_gamma_gen = gamma_gen;
	state->last_fade_active = fade_active;
	state->unchanged_skips = 0;
}

static inline void DSpFrontStagingRememberHash(
	DSpFrontStagingPresentState *state,
	uint32_t hash,
	uint32_t size)
{
	DSpFrontStagingRememberHashForGamma(state, hash, size, 0, 0);
}

static inline void DSpFrontStagingRememberSeedHash(
	DSpFrontStagingPresentState *state,
	uint32_t hash,
	uint32_t size)
{
	if (state == 0) return;
	state->valid = true;
	state->encoded = false;
	state->last_hash = hash;
	state->last_size = size;
	state->last_gamma_gen = 0;
	state->last_fade_active = 0;
	state->unchanged_skips = 0;
}

static inline void DSpFrontStagingRememberPresentedBytes(
	DSpFrontStagingPresentState *state,
	const uint8_t *bytes,
	uint32_t size)
{
	DSpFrontStagingRememberHash(
		state,
		DSpFrontStagingHashBytes(bytes, size),
		size);
}

static inline void DSpFrontStagingRememberSeedBytes(
	DSpFrontStagingPresentState *state,
	const uint8_t *bytes,
	uint32_t size)
{
	DSpFrontStagingRememberSeedHash(
		state,
		DSpFrontStagingHashBytes(bytes, size),
		size);
}

static inline bool DSpFrontStagingShouldEncodeHashForGamma(
	DSpFrontStagingPresentState *state,
	uint32_t hash,
	uint32_t size,
	uint32_t gamma_gen,
	uint32_t fade_active)
{
	if (state == 0) return true;
	if (state->valid &&
	    state->encoded &&
	    state->last_hash == hash &&
	    state->last_size == size &&
	    state->last_gamma_gen == gamma_gen &&
	    state->last_fade_active == fade_active) {
		state->unchanged_skips++;
		return false;
	}
	DSpFrontStagingRememberHashForGamma(state, hash, size, gamma_gen,
	                                    fade_active);
	return true;
}

static inline bool DSpFrontStagingShouldEncodeHash(
	DSpFrontStagingPresentState *state,
	uint32_t hash,
	uint32_t size)
{
	return DSpFrontStagingShouldEncodeHashForGamma(state, hash, size, 0, 0);
}

static inline bool DSpFrontStagingShouldEncodeChangedBytes(
	DSpFrontStagingPresentState *state,
	const uint8_t *bytes,
	uint32_t size)
{
	return DSpFrontStagingShouldEncodeHash(
		state,
		DSpFrontStagingHashBytes(bytes, size),
		size);
}

#endif /* DSP_FRONT_STAGING_PRESENT_POLICY_H */
