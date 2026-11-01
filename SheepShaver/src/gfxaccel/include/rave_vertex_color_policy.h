/* Guest vertex colors must be finite before Metal interpolation. */
#ifndef RAVE_VERTEX_COLOR_POLICY_H
#define RAVE_VERTEX_COLOR_POLICY_H
#include <stdint.h>
#include <string.h>

static inline int RaveVertexColorBitsAreFinite(uint32_t bits)
{
    return (bits & 0x7f800000u) != 0x7f800000u;
}

static inline float RaveFiniteVertexComponent(uint32_t bits, float fallback)
{
    // Classify bits rather than relying on floating-point fast-math settings.
    if (!RaveVertexColorBitsAreFinite(bits)) return fallback;
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static inline float RaveFiniteVertexColor(uint32_t bits)
{
    // White/opaque is neutral for modulation. Preserve every finite value.
    return RaveFiniteVertexComponent(bits, 1.0f);
}
#endif
