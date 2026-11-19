/*
 *  gl_pixel_readback.h - Checked pixel packing for GL framebuffer and texture readback.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

// Shared checked big-endian guest packing for framebuffer and texture readback.
#ifndef GL_PIXEL_READBACK_H
#define GL_PIXEL_READBACK_H
#include "gl_engine.h"
#include "gl_pixel_pack_policy.h"
struct GLMetalPackLayout {
    uint64_t rowStride;
    uint64_t start;
};

// Color and depth readbacks share exactly the same guest address bounds.
// Validate the whole range before writing any pixels, using wide arithmetic.
static inline bool GLMetalGetPackLayout(GLContext *ctx, int32_t width, int32_t height,
                                 uint32_t bytesPerPixel, uint32_t base,
                                 GLMetalPackLayout &layout)
{
    const GLPixelStore &ps = ctx->pixel_store;
    auto invalid = [&]() {
        if (!ctx->last_error) ctx->last_error = 0x0501; // GL_INVALID_VALUE
        return false;
    };
    if (width <= 0 || height <= 0 || !bytesPerPixel ||
        ps.pack_row_length < 0 || ps.pack_skip_rows < 0 || ps.pack_skip_pixels < 0)
        return invalid();
    int32_t alignment = ps.pack_alignment;
    if (alignment != 1 && alignment != 2 && alignment != 4 && alignment != 8) {
        alignment = 4;
    }
    // A row length shorter than width is legal and produces overlapping rows.
    const uint64_t rowPixels = ps.pack_row_length > 0 ? ps.pack_row_length : width;
    layout.rowStride = (rowPixels * bytesPerPixel + alignment - 1u) &
                       ~(uint64_t)(alignment - 1u);
    if (layout.rowStride > 0xffffffffull) return invalid();
    layout.start = (uint64_t)ps.pack_skip_rows * layout.rowStride +
                   (uint64_t)ps.pack_skip_pixels * bytesPerPixel;
    const uint64_t available = 0x100000000ull - base;
    if (layout.start > available) return invalid();
    const uint64_t tail = (uint64_t)(height - 1) * layout.rowStride +
                          (uint64_t)width * bytesPerPixel;
    return tail <= available - layout.start ? true : invalid();
}


static inline void GLReadbackApplyByteOrder(bool swapBytes,uint32_t type,uint32_t bpp,uint8_t *packed)
{
    if(!swapBytes)return;
    int bits[4];bool reverse;
    const int scalar=GLPixelPackBits(type,bits,&reverse) ? int(bpp) : GLPixelScalarTypeBytes(type);
    if(scalar>1)for(uint32_t component=0;component<bpp;component+=scalar)
        for(int lo=0,hi=scalar-1;lo<hi;++lo,--hi){
            const uint8_t v=packed[component+lo];packed[component+lo]=packed[component+hi];packed[component+hi]=v;
        }
}

template<class StoreByte>
static bool GLStoreReadbackPixels(GLContext *ctx, const uint8_t *pixels,
    int32_t width, int32_t height, uint32_t format, uint32_t type,
    uint32_t address, bool flipRows, StoreByte store)
{
    const uint32_t error = GLPixelPackError(format,type);
    if (error) { if (!ctx->last_error) ctx->last_error=error; return false; }
    const uint32_t bpp=GLPixelPackBytesPerPixel(format,type);
    GLMetalPackLayout layout;
    if (!pixels || !GLMetalGetPackLayout(ctx,width,height,bpp,address,layout)) return false;
    for (int32_t y=0;y<height;++y) for(int32_t x=0;x<width;++x) {
        uint8_t packed[16];
        const size_t row=flipRows ? height-1-y : y;
        GLPixelPackBGRA8(pixels+(row*width+x)*4,format,type,packed);
        GLReadbackApplyByteOrder(ctx->pixel_store.pack_swap_bytes,type,bpp,packed);
        const uint32_t dst=uint32_t(address+layout.start+uint64_t(y)*layout.rowStride+uint64_t(x)*bpp);
        for(uint32_t b=0;b<bpp;++b) store(dst+b,packed[b]);
    }
    return true;
}
#endif
