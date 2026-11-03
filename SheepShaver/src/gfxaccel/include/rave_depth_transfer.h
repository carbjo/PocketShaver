/*
 *  rave_depth_transfer.h - Aligned RAVE depth-buffer transfers.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef RAVE_DEPTH_TRANSFER_H
#define RAVE_DEPTH_TRANSFER_H
#include <cstdint>
#include <cstring>
#include <cstddef>

inline size_t RaveDepthTransferPitch(uint32_t width) { return (size_t(width) * 4 + 255) & ~size_t(255); }

template<class Write>
void RaveDepthReadback(const void *staging, size_t pitch, uint32_t width, uint32_t height, Write write)
{
    for (uint32_t y = 0; y < height; ++y)
        for (uint32_t x = 0; x < width; ++x) {
            uint32_t bits;
            memcpy(&bits, static_cast<const uint8_t *>(staging) + y*pitch + x*4, 4);
            write(y*width + x, bits);
        }
}

template<class Read>
void RaveDepthUploadRegion(void *staging, size_t pitch, uint32_t x, uint32_t y,
                          uint32_t width, uint32_t height, Read read)
{
    for (uint32_t row = 0; row < height; ++row)
        for (uint32_t col = 0; col < width; ++col) {
            const uint32_t bits = read(x+col, y+row);
            memcpy(static_cast<uint8_t *>(staging) + row*pitch + col*4, &bits, 4);
        }
}
#ifdef __OBJC__
inline void RaveEncodeDepthReadback(id<MTLBlitCommandEncoder> blit, id<MTLTexture> depth,
                                    id<MTLBuffer> staging, NSUInteger pitch)
{
    [blit copyFromTexture:depth sourceSlice:0 sourceLevel:0
            sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(depth.width,depth.height,1)
                toBuffer:staging destinationOffset:0
  destinationBytesPerRow:pitch destinationBytesPerImage:pitch*depth.height];
}
inline void RaveEncodeDepthUpload(id<MTLBlitCommandEncoder> blit, id<MTLBuffer> staging,
                                 NSUInteger pitch, id<MTLTexture> depth,
                                 NSUInteger x, NSUInteger y, NSUInteger width, NSUInteger height)
{
    [blit copyFromBuffer:staging sourceOffset:0 sourceBytesPerRow:pitch sourceBytesPerImage:pitch*height
             sourceSize:MTLSizeMake(width,height,1) toTexture:depth destinationSlice:0 destinationLevel:0
      destinationOrigin:MTLOriginMake(x,y,0)];
}
#endif
#endif
