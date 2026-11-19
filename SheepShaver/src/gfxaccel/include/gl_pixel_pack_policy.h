/* OpenGL color readback packing for the big-endian guest.
 * Packed component order follows OpenGL 1.2, section 3.6.4 / table 3.5.
 * https://registry.khronos.org/OpenGL/specs/gl/glspec121.pdf */
#ifndef GL_PIXEL_PACK_POLICY_H
#define GL_PIXEL_PACK_POLICY_H

#include <stdint.h>
#include <string.h>
#include "gl_pixel_unpack_policy.h"

static inline bool GLPixelPackFormatSupported(uint32_t format)
{
    switch (format) {
        case GLPixelFormatRed: case GLPixelFormatGreen: case GLPixelFormatBlue:
        case GLPixelFormatAlpha: case GLPixelFormatRGB: case GLPixelFormatRGBA:
        case GLPixelFormatBGR: case GLPixelFormatBGRA: case GLPixelFormatABGR:
        case GLPixelFormatLuminance: case GLPixelFormatLuminanceAlpha: return true;
        default: return false;
    }
}

static inline bool GLPixelPackBits(uint32_t type, int bits[4], bool *reverse)
{
    *reverse = false;
    switch (type) {
        case GLPixelTypeUnsignedByte233Rev: *reverse=true; [[fallthrough]];
        case GLPixelTypeUnsignedByte332: bits[0]=3;bits[1]=3;bits[2]=2;bits[3]=0;return true;
        case GLPixelTypeUnsignedShort565Rev: *reverse=true; [[fallthrough]];
        case GLPixelTypeUnsignedShort565: bits[0]=5;bits[1]=6;bits[2]=5;bits[3]=0;return true;
        case GLPixelTypeUnsignedShort4444Rev: *reverse=true; [[fallthrough]];
        case GLPixelTypeUnsignedShort4444: bits[0]=bits[1]=bits[2]=bits[3]=4;return true;
        case GLPixelTypeUnsignedShort1555Rev: *reverse=true; [[fallthrough]];
        case GLPixelTypeUnsignedShort5551: bits[0]=bits[1]=bits[2]=5;bits[3]=1;return true;
        case GLPixelTypeUnsignedInt8888Rev: *reverse=true; [[fallthrough]];
        case GLPixelTypeUnsignedInt8888: bits[0]=bits[1]=bits[2]=bits[3]=8;return true;
        case GLPixelTypeUnsignedInt2101010Rev: *reverse=true; [[fallthrough]];
        case GLPixelTypeUnsignedInt1010102: bits[0]=bits[1]=bits[2]=10;bits[3]=2;return true;
        default: return false;
    }
}

static inline uint32_t GLPixelPackError(uint32_t format, uint32_t type)
{
    if (!GLPixelPackFormatSupported(format)) return 0x0500; // GL_INVALID_ENUM
    int bits[4]; bool reverse;
    if (GLPixelPackBits(type,bits,&reverse)) {
        const bool compatible = bits[3] == 0
            ? (format == GLPixelFormatRGB)
            : (format == GLPixelFormatRGBA || format == GLPixelFormatBGRA);
        return compatible ? 0 : 0x0502; // GL_INVALID_OPERATION
    }
    return GLPixelScalarTypeBytes(type) ? 0 : 0x0500;
}

static inline int GLPixelPackBytesPerPixel(uint32_t format, uint32_t type)
{
    return GLPixelPackError(format,type) ? 0 : GLPixelSourceBytesPerPixel(format,type);
}

static inline void GLPixelPackStoreBigEndian(uint32_t value, int bytes, uint8_t *out)
{
    for (int i=0;i<bytes;++i) out[i]=(uint8_t)(value >> ((bytes-1-i)*8));
}

static inline bool GLPixelPackBGRA8(const uint8_t bgra[4], uint32_t format,
                                  uint32_t type, uint8_t *out)
{
    if (!bgra || !out || GLPixelPackError(format,type)) return false;
    const int count=GLPixelFormatComponentCount(format);
    uint8_t components[4]={};
    for(int i=0;i<count;++i) {
        switch(GLPixelFormatComponentAt(format,i)) {
            case GLPixelComponentRed: components[i]=bgra[2];break;
            case GLPixelComponentGreen: components[i]=bgra[1];break;
            case GLPixelComponentBlue: components[i]=bgra[0];break;
            case GLPixelComponentAlpha: components[i]=bgra[3];break;
            case GLPixelComponentLuminance: {
                const int sum=bgra[0]+bgra[1]+bgra[2];
                components[i]=(uint8_t)(sum>255 ? 255 : sum);break;
            }
            default: return false;
        }
    }
    int bits[4];bool reverse;
    if(GLPixelPackBits(type,bits,&reverse)) {
        const int bytes=GLPixelSourceBytesPerPixel(format,type);
        uint32_t packed=0;int used=0;
        for(int i=0;i<count;++i) {
            const uint32_t max=(1u<<bits[i])-1u;
            const uint32_t value=((uint32_t)components[i]*max+127u)/255u;
            const int shift=reverse ? used : bytes*8-used-bits[i];
            packed |= value << shift;
            used += bits[i];
        }
        GLPixelPackStoreBigEndian(packed,bytes,out);
        return true;
    }
    const int bytes=GLPixelScalarTypeBytes(type);
    for(int i=0;i<count;++i) {
        uint32_t value;
        if(type==GLPixelTypeFloat) {
            const float normalized=(float)components[i]/255.0f;
            memcpy(&value,&normalized,4);
        } else {
            const bool signedType=type==GLPixelTypeByte || type==GLPixelTypeShort || type==GLPixelTypeInt;
            const int bitsCount=bytes*8-(signedType ? 1 : 0);
            const uint64_t max=(1ull<<bitsCount)-1ull;
            value=(uint32_t)(((uint64_t)components[i]*max+127ull)/255ull);
        }
        GLPixelPackStoreBigEndian(value,bytes,out+i*bytes);
    }
    return true;
}
#endif
