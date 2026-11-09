/*
 * gl_texture_format_policy.h - GL texture storage component and target rules.
 *
 * (C) 2026 Sierra Burkhart (sierra760)
 * Licensed under the GNU General Public License, version 2 or later.
 */
#ifndef GL_TEXTURE_FORMAT_POLICY_H
#define GL_TEXTURE_FORMAT_POLICY_H
#include <cstddef>
#include "gl_engine.h"

static inline unsigned GLTextureMipLevelCount(uint64_t width, uint64_t height, uint64_t depth = 1)
{
    uint64_t size = width > height ? width : height;
    if (depth > size) size = depth;
    unsigned count = 0;
    do { ++count; size >>= 1; } while (size);
    return count;
}

// Bound dimensions before signed byte counts or Metal descriptors are built.
// 1024 matches GL_MAX_TEXTURE_SIZE; the byte limit matches the upload API's int.
static inline bool GLTextureImageSizeIsValid(int level, int width, int height, int depth = 1)
{
    if (level < 0 || level > 10 || width < 0 || height < 0 || depth < 0) return false;
    const int maximum = 1024 >> level;
    return width <= maximum && height <= maximum && depth <= maximum &&
           uint64_t(width) * uint64_t(height) * uint64_t(depth) * 4 <= INT32_MAX;
}

static inline bool GLTextureRegionFits(int level, int x, int y, int z,
    int width, int height, int depth, uint64_t baseWidth, uint64_t baseHeight,
    uint64_t baseDepth, unsigned mipCount)
{
    if (level < 0 || level >= 32 || unsigned(level) >= mipCount ||
        x < 0 || y < 0 || z < 0 || width < 0 || height < 0 || depth < 0 ||
        !baseWidth || !baseHeight || !baseDepth) return false;
    const uint64_t w = baseWidth >> level, h = baseHeight >> level, d = baseDepth >> level;
    return uint64_t(x) + uint64_t(width) <= (w ? w : 1) &&
           uint64_t(y) + uint64_t(height) <= (h ? h : 1) &&
           uint64_t(z) + uint64_t(depth) <= (d ? d : 1);
}

static inline uint32_t GLTextureSubImageError(const GLTextureObject &texture,
    int level, int x, int y, int z, int width, int height, int depth = 1)
{
    if (level < 0 || level >= 32 || x < 0 || y < 0 || z < 0 ||
        width < 0 || height < 0 || depth < 0) return 0x0501;
    if (!texture.metal_texture || texture.width <= 0 || texture.height <= 0) return 0x0502;
    const uint64_t baseDepth = texture.depth > 0 ? texture.depth : 1;
    const unsigned count = texture.has_mipmaps
        ? GLTextureMipLevelCount(texture.width, texture.height, baseDepth) : 1;
    return GLTextureRegionFits(level, x, y, z, width, height, depth,
        texture.width, texture.height, baseDepth, count) ? 0 : 0x0501;
}

static inline uint32_t GLTextureBaseInternalFormat(int32_t format)
{
    switch (format) {
    case 1: case 0x1909: case 0x803f: case 0x8040: case 0x8041: case 0x8042: return 0x1909;
    case 2: case 0x190a: case 0x8043: case 0x8044: case 0x8045: case 0x8046: case 0x8047: case 0x8048: return 0x190a;
    case 3: case 0x1907: case 0x2a10: case 0x804f: case 0x8050: case 0x8051: case 0x8052: case 0x8053: case 0x8054: case 0x83f0: return 0x1907;
    case 4: case 0x1908: case 0x8055: case 0x8056: case 0x8057: case 0x8058: case 0x8059: case 0x805a: case 0x805b:
    case 0x80e2: case 0x80e3: case 0x80e4: case 0x80e5: case 0x80e6: case 0x80e7:
    case 0x83f1: case 0x83f2: case 0x83f3: return 0x1908;
    case 0x1906: case 0x803b: case 0x803c: case 0x803d: case 0x803e: return 0x1906;
    case 0x8049: case 0x804a: case 0x804b: case 0x804c: case 0x804d: return 0x8049;
    default: return 0;
    }
}

static inline uint32_t GLTextureUnitTarget(const GLTextureUnit &unit, bool texture2DEnabled)
{
    if (unit.enabled_3d) return 0x806f;
    if (unit.enabled_2d) return 0x0de1;
    if (unit.enabled_1d) return 0x0de0;
    // Compatibility latches can keep a legacy array draw textured after a
    // disable. They must not override an explicitly selected 1D target.
    return texture2DEnabled ? 0x0de1 : 0;
}

static inline uint32_t GLTextureUnitBoundName(const GLTextureUnit &unit, uint32_t target)
{
    if (target == 0x0de0) return unit.bound_texture_1d;
    if (target == 0x0de1) return unit.bound_texture_2d;
    if (target == 0x806f) return unit.bound_texture_3d;
    return 0;
}

static inline uint32_t GLTextureLevelBaseFormat(const GLTextureObject &texture, int level)
{
    if (level >= 0 && level < 32 && texture.level_internal_format[level])
        return GLTextureBaseInternalFormat(texture.level_internal_format[level]);
    return texture.base_internal_format ? texture.base_internal_format : 0x1908;
}

// GL stores only the selected internal components, regardless of source layout.
// Canonical BGRA gives absent RGB components their sampling defaults (one for
// alpha-only textures); the shader still uses the base format for texenv rules.
static inline void GLTextureApplyInternalFormatBGRA(uint8_t *pixels, size_t byteCount, uint32_t base)
{
    if (!pixels || base == 0x1908 || base == 0) return;
    for (size_t i = 0; i + 3 < byteCount; i += 4) {
        uint8_t *p = pixels + i;
        if (base == 0x1906) p[0] = p[1] = p[2] = 255;
        else if (base == 0x1909 || base == 0x190a || base == 0x8049) {
            p[0] = p[1] = p[2];
            if (base == 0x8049) p[3] = p[2];
            else if (base == 0x1909) p[3] = 255;
        } else if (base == 0x1907) p[3] = 255;
    }
}

static inline bool GLTextureDefineImage(GLTextureObject &texture, uint32_t target,
    int level, int32_t internalFormat, int width, int height, int depth = 1)
{
    const uint32_t base = GLTextureBaseInternalFormat(internalFormat);
    if (!base || level < 0 || level >= 32 || width < 0 || height < 0 || depth < 0) return false;
    texture.target = target;
    texture.level_internal_format[level] = uint32_t(internalFormat);
    texture.level_width[level] = width;
    texture.level_height[level] = height;
    texture.level_depth[level] = depth;
    if (level == 0) {
        texture.internal_format = uint32_t(internalFormat);
        texture.base_internal_format = base;
        texture.width = width; texture.height = height; texture.depth = depth;
        // A new base image establishes a new decoding chain. Client mip
        // heuristics from a previous image must not affect copies or GLU data.
        texture.legacy_ushort_palette_index_chain = false;
        texture.legacy_ushort_bgr332_chain = false;
        texture.legacy_ushort_index_gray_chain = false;
        texture.legacy_ushort_scalar_no_palette_chain = false;
    }
    return true;
}

// GetTexImage uses Table 6.1's return components, not the replicated values
// used when sampling: luminance and intensity appear only in red, and an
// alpha-only image returns zero RGB. Pixel packing happens after this step.
static inline void GLTexturePrepareReadbackBGRA(uint8_t *pixels, size_t byteCount, uint32_t base)
{
    if (!pixels || base == 0x1908 || base == 0) return;
    for (size_t i = 0; i + 3 < byteCount; i += 4) {
        uint8_t *p = pixels + i;
        if (base == 0x1906) p[0] = p[1] = p[2] = 0;
        else if (base == 0x1909 || base == 0x190a || base == 0x8049) {
            p[0] = p[1] = 0;
            if (base != 0x190a) p[3] = 255;
        } else if (base == 0x1907) p[3] = 255;
    }
}
#endif
