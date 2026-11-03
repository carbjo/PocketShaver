/*
 *  gl_texture_environment.h - OpenGL texture environment uniforms.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef GL_TEXTURE_ENVIRONMENT_H
#define GL_TEXTURE_ENVIRONMENT_H
#include <cstring>
#include "gl_texture_format_policy.h"
// Must match GLFragmentUniforms in gl_shaders.metal
// Metal float4 has 16-byte alignment, so padding is needed after int fields
struct GLMetalFragmentUniforms {
    int32_t texenv_mode;
    int32_t _pad0, _pad1, _pad2;    // align texenv_color to 16 bytes
    float   texenv_color[4];         // offset 16 (Metal float4 alignment)
    float   fog_color[4];            // offset 32
    int32_t alpha_test_enabled;      // offset 48
    int32_t alpha_func;              // offset 52
    float   alpha_ref;               // offset 56
    int32_t has_texture;             // offset 60
    int32_t has_texture_3d;          // offset 64
    int32_t shade_model;             // offset 68
    int32_t color_sum_enabled;       // offset 72 — EXT_secondary_color / GL_COLOR_SUM (consumes former _pad3)
    int32_t has_texture_unit1;       // offset 76 — ARB_multitexture: unit 1 has a bound+enabled 2D texture (consumes former _pad4)
    int32_t texenv1_mode;            // offset 80 — unit-1 texenv mode (GLTexEnvModeToShader: 0=modulate..4=add)
    int32_t force_opaque_output;     // offset 84 — window overlay with GL blending disabled stores coverage alpha
    int32_t tex_format, tex1_format; // offset 88-92, base internal-format tokens
    float texenv1_color[4];          // offset 96, independent unit-1 environment
    int32_t has_texture_1d;          // offset 112, ignore T for the primary 1D target
    int32_t has_texture_unit1_1d;
    int32_t bitmap_mask;            // offset 120, sampled alpha is coverage only
    int32_t _pad9;                  // pad to 128, matching Metal struct alignment
    int32_t polygon_stipple_enabled;
    int32_t line_stipple_enabled;
    int32_t line_stipple_factor;
    int32_t framebuffer_height;
    uint32_t polygon_stipple[32];
    int32_t has_texture_unit1_3d;
    int32_t _raster_pad[3];
};

static inline int32_t GLTexEnvModeToShader(uint32_t gl_mode) {
    switch (gl_mode) {
        case 0x2100: return 0; // GL_MODULATE
        case 0x2101: return 1; // GL_DECAL
        case 0x0be2: return 2; // GL_BLEND
        case 0x1e01: return 3; // GL_REPLACE
        case 0x0104: return 4; // GL_ADD
        default:     return 0;
    }
}

static inline void GLMetalSetTextureEnvironments(GLMetalFragmentUniforms &uniforms,
                                                 const GLContext &ctx)
{
    uniforms.bitmap_mask = 0;
    uniforms.polygon_stipple_enabled=0;
    uniforms.line_stipple_enabled=0;
    uniforms.line_stipple_factor=std::max(1,std::min(256,ctx.line_stipple_factor));
    uniforms.framebuffer_height=0;
    uniforms.has_texture_unit1_3d=0;
    uniforms._raster_pad[0]=ctx.line_stipple_pattern;
    std::memcpy(uniforms.polygon_stipple,ctx.polygon_stipple,sizeof(uniforms.polygon_stipple));
    uniforms.texenv_mode = GLTexEnvModeToShader(ctx.tex_units[0].env_mode);
    uniforms.texenv1_mode = GLTexEnvModeToShader(ctx.tex_units[1].env_mode);
    std::memcpy(uniforms.texenv_color, ctx.tex_units[0].env_color, sizeof(uniforms.texenv_color));
    std::memcpy(uniforms.texenv1_color, ctx.tex_units[1].env_color, sizeof(uniforms.texenv1_color));
    for (int unit = 0; unit < GL_RENDER_TEXTURE_UNITS; ++unit) {
        const auto &textureUnit = ctx.tex_units[unit];
        const uint32_t target = GLTextureUnitTarget(textureUnit, textureUnit.enabled_2d);
        const GLTextureObject *texture = GLBoundTextureObject(&ctx, unit, target);
        const int32_t format = texture ? GLTextureLevelBaseFormat(*texture, 0) : 0x1908;
        if (unit == 0) {
            uniforms.tex_format = format;
            uniforms.has_texture_1d = target == 0x0de0;
        } else {
            uniforms.tex1_format = format;
            uniforms.has_texture_unit1_1d = target == 0x0de0;
        }
    }
}
#endif
