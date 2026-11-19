/* Checked CPU pixel conversion sizes and guest unpack ranges. */
#ifndef GL_PIXEL_UPLOAD_H
#define GL_PIXEL_UPLOAD_H
#include "gl_engine.h"

static inline bool GLPixelUploadInvalid(GLContext *ctx)
{
    if (ctx && !ctx->last_error) ctx->last_error = 0x0501; // INVALID_VALUE
    return false;
}

// The conversion/backend interface carries byte counts in an int.
static inline bool GLPixelBGRA8Size(GLContext *ctx, int width, int height, int &bytes)
{
    bytes = 0;
    if (width < 0 || height < 0 || uint64_t(width) * uint64_t(height) > INT32_MAX / 4)
        return GLPixelUploadInvalid(ctx);
    bytes = int(uint64_t(width) * uint64_t(height) * 4);
    return true;
}

struct GLPixelUnpackLayout {
    int rowStride;
    uint32_t start, bitOffset;
};

static inline bool GLPixelGetUnpackLayout(GLContext *ctx, const GLPixelStore &ps,
    uint32_t base, int width, int height, unsigned bitsPerPixel, GLPixelUnpackLayout &out)
{
    if (width <= 0 || height <= 0 || !bitsPerPixel || ps.unpack_row_length < 0 ||
        ps.unpack_skip_rows < 0 || ps.unpack_skip_pixels < 0)
        return GLPixelUploadInvalid(ctx);
    int align = ps.unpack_alignment;
    if (align != 1 && align != 2 && align != 4 && align != 8) align = 4;
    const uint64_t rowPixels = ps.unpack_row_length ? ps.unpack_row_length : width;
    const uint64_t pitch = ((rowPixels * bitsPerPixel + 7) / 8 + align - 1) & ~uint64_t(align - 1);
    if (pitch > INT32_MAX) return GLPixelUploadInvalid(ctx);
    const uint64_t skippedBits = uint64_t(ps.unpack_skip_pixels) * bitsPerPixel;
    const uint64_t start = uint64_t(ps.unpack_skip_rows) * pitch + skippedBits / 8;
    const uint64_t available = 0x100000000ull - base;
    if (start > available) return GLPixelUploadInvalid(ctx);
    const uint64_t tail = uint64_t(height - 1) * pitch +
        (skippedBits % 8 + uint64_t(width) * bitsPerPixel + 7) / 8;
    if (tail > available - start) return GLPixelUploadInvalid(ctx);
    out = {int(pitch), uint32_t(start), uint32_t(skippedBits % 8)};
    return true;
}
#endif
