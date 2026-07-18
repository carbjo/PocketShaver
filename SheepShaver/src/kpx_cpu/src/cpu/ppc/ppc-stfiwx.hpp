/*
 *  ppc-stfiwx.hpp - PowerPC stfiwx helper
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 */

#ifndef PPC_STFIWX_H
#define PPC_STFIWX_H

#include <stdint.h>

static inline uint32_t PPCStfiwxStoreWord(uint64_t fpr_value)
{
	return (uint32_t)fpr_value;
}

static inline uint32_t PPCStfiwxEffectiveAddress(uint32_t base, uint32_t index)
{
	return base + index;
}

#endif /* PPC_STFIWX_H */
