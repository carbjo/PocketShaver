/*
 *  gl_input_validation.h - OpenGL evaluator definitions and guest input ranges.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef GL_INPUT_VALIDATION_H
#define GL_INPUT_VALIDATION_H
#include <cmath>
#include <cstdint>
#include "gfx_guest_range.h"

// A captured/read payload must lie wholly in one mapped guest memory region.
// The end check is in 64 bits and precedes both host allocation and guest reads.
static inline bool GLGuestMappedRange(uint32_t address,uint64_t bytes,
    uint32_t ramBase,uint32_t ramSize,uint32_t romBase,uint32_t romSize)
{
    return GfxGuestMappedRange(address,bytes,ramBase,ramSize,romBase,romSize);
}

struct GLEvaluatorDefinitionLayout {
    int dimension=0,index=-1;
    uint64_t bytes=0;
};
static inline uint32_t GLValidateEvaluatorDefinition(bool inBegin,uint32_t target,bool surface,
    uint32_t address,int scalarBytes,int uOrder,int uStride,double u1,double u2,
    int vOrder,int vStride,double v1,double v2,
    uint32_t ramBase,uint32_t ramSize,uint32_t romBase,uint32_t romSize,
    GLEvaluatorDefinitionLayout &layout)
{
    layout={};
    if(inBegin)return 0x0502; // INVALID_OPERATION
    const uint32_t base=surface?0x0db0:0x0d90;
    if(target<base || target>base+8)return 0x0500; // INVALID_ENUM
    const int dimensions[9]={4,1,3,1,2,3,4,3,4};
    const int indices[9]={3,2,4,5,6,7,8,0,1};
    const int dimension=dimensions[target-base];
    auto domain=[](double low,double high) {
        return std::isfinite(low) && std::isfinite(high) && low!=high &&
            std::isfinite(float(low)) && std::isfinite(float(high)) && float(low)!=float(high);
    };
    if(!address || (scalarBytes!=4 && scalarBytes!=8) ||
       uOrder<1 || uOrder>30 || uStride<dimension || !domain(u1,u2) ||
       (surface && (vOrder<1 || vOrder>30 || vStride<dimension || !domain(v1,v2))))return 0x0501;
    const uint64_t elements=uint64_t(uOrder-1)*uint32_t(uStride)+
        (surface?uint64_t(vOrder-1)*uint32_t(vStride):0)+dimension;
    const uint64_t bytes=elements*uint32_t(scalarBytes);
    if(!GLGuestMappedRange(address,bytes,ramBase,ramSize,romBase,romSize))return 0x0501;
    layout.dimension=dimension;layout.index=indices[target-base];layout.bytes=bytes;
    return 0;
}
#endif
