/*
 *  gl_vertex_pipeline.h - OpenGL vertex conversion and primitive expansion.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef GL_VERTEX_PIPELINE_H
#define GL_VERTEX_PIPELINE_H
#include "gl_texture_coordinates.h"

struct GLMetalVertex {
    float position[4];
    float color[4];
    float normal[3];
    float texcoord[4]; // s, t, r, q
    float texcoord1[4];
    float secondary_color[3];
    // Flat lighting must use the provoking vertex's eye position, while
    // clipping, fog and rasterization continue to use each original position.
    float lighting_position[4];
    GLMaterial material[2];
    float stipple_distance = 0;
};

enum class GLDrawPrimitive { Point, Line, LineStrip, Triangle, TriangleStrip };

// Capture materials when the vertex is specified, including array color tracking.
static inline void GLSnapshotVertexMaterial(const GLContext &ctx, GLVertex &vertex)
{
    std::memcpy(vertex.material, ctx.materials, sizeof(vertex.material));
    if (!ctx.color_material_enabled) return;
    for (int face=0;face<2;++face) {
        if (ctx.color_material_face != 0x0408 && ctx.color_material_face != uint32_t(0x0404+face)) continue;
        auto &m=vertex.material[face];
        const auto mode=ctx.color_material_mode;
        if (mode==0x1200 || mode==0x1602) std::memcpy(m.ambient,vertex.color,16);
        if (mode==0x1201 || mode==0x1602) std::memcpy(m.diffuse,vertex.color,16);
        if (mode==0x1202) std::memcpy(m.specular,vertex.color,16);
        if (mode==0x1600) std::memcpy(m.emission,vertex.color,16);
    }
}

static inline void GLConvertDrawVertices(const GLContext &ctx,
    const std::vector<GLVertex> &input, std::vector<GLMetalVertex> &out)
{
    const float *mv = ctx.modelview_stack[ctx.modelview_depth];
    bool sphere = false;
    bool needsEye = false;
    bool direct[GL_RENDER_TEXTURE_UNITS];
    for (int u = 0; u < GL_RENDER_TEXTURE_UNITS; ++u) {
        const auto &t = ctx.tex_units[u];
        const bool enabled[] = {t.texgen_s_enabled, t.texgen_t_enabled,
                                 t.texgen_r_enabled, t.texgen_q_enabled};
        const int modes[] = {t.texgen_s_mode, t.texgen_t_mode,
                              t.texgen_r_mode, t.texgen_q_mode};
        direct[u] = true;
        for (int c = 0; c < 4; ++c) {
            if (enabled[c]) direct[u] = false;
            needsEye |= enabled[c] && modes[c] != 0x2401;
        }
        const float *matrix = ctx.texture_stack[u][ctx.texture_depth[u]];
        for (int k = 0; k < 16; ++k)
            if (matrix[k] != (k % 5 == 0 ? 1.0f : 0.0f)) direct[u] = false;
        sphere |= (t.texgen_s_enabled && t.texgen_s_mode == 0x2402) ||
                  (t.texgen_t_enabled && t.texgen_t_mode == 0x2402);
    }
    double inverse[4][4] = {};
    if (sphere && !GLTextureInverseMatrix(inverse, mv))
        for (int i = 0; i < 4; ++i) inverse[i][i] = 1;
    out.resize(input.size());
    for (size_t i = 0; i < input.size(); ++i) {
        const auto &src = input[i]; auto &dst = out[i];
        std::memcpy(dst.position, src.position, sizeof(dst.position));
        std::memcpy(dst.lighting_position, src.position, sizeof(dst.lighting_position));
        std::memcpy(dst.normal, src.normal, sizeof(dst.normal));
        std::memcpy(dst.color, src.color, sizeof(dst.color));
        std::memcpy(dst.material, src.material, sizeof(dst.material));
        std::memcpy(dst.secondary_color, src.secondary_color, sizeof(dst.secondary_color));
        float eye[4] = {};
        if (needsEye) GLTextureTransformVector(eye, mv, src.position);
        float normal[3] = {};
        if (sphere) {
            for (int r = 0; r < 3; ++r)
                for (int c = 0; c < 3; ++c) normal[r] += (float)inverse[c][r] * src.normal[c];
            if (ctx.normalize) {
                float length = std::sqrt(normal[0]*normal[0] + normal[1]*normal[1] + normal[2]*normal[2]);
                if (length > 0) for (float &n : normal) n /= length;
            }
        }
        for (int u = 0; u < GL_RENDER_TEXTURE_UNITS; ++u) {
            float coords[4];
            if (direct[u]) std::memcpy(coords, src.texcoord[u], sizeof(coords));
            else GLGenerateTextureCoordinates(coords, ctx.tex_units[u], src.texcoord[u],
                src.position, eye, normal, ctx.texture_stack[u][ctx.texture_depth[u]]);
            float *packed = u == 0 ? dst.texcoord : dst.texcoord1;
            std::memcpy(packed, coords, sizeof(coords));
        }
    }
}

// Expand from the ORIGINAL GL topology. Selecting a triangle's last vertex
// after quad triangulation loses the quad's provoking vertex (GL 1.2.1 table 2.9).
static inline bool GLExpandDrawPrimitives(uint32_t mode, bool flat,
    const std::vector<GLMetalVertex> &in, std::vector<GLMetalVertex> &out,
    GLDrawPrimitive &primitive)
{
    out.clear();
    const size_t n = in.size();
    auto emit = [&](size_t index, size_t provoking) {
        GLMetalVertex v = in[index];
        if (flat) {
            const auto &p = in[provoking];
            std::memcpy(v.color, p.color, sizeof(v.color));
            std::memcpy(v.material, p.material, sizeof(v.material));
            std::memcpy(v.secondary_color, p.secondary_color, sizeof(v.secondary_color));
            std::memcpy(v.normal, p.normal, sizeof(v.normal));
            std::memcpy(v.lighting_position, p.lighting_position, sizeof(v.lighting_position));
        }
        out.push_back(v);
    };
    auto tri = [&](size_t a, size_t b, size_t c, size_t p) { emit(a,p); emit(b,p); emit(c,p); };
    primitive = GLDrawPrimitive::Triangle;
    switch (mode) {
    case 0: primitive = GLDrawPrimitive::Point; return false;
    case 1:
        primitive = GLDrawPrimitive::Line;
        if (!flat) return false;
        for (size_t i=0;i+1<n;i+=2) { emit(i,i+1); emit(i+1,i+1); }
        break;
    case 2: case 3:
        primitive = flat || mode==2 ? GLDrawPrimitive::Line : GLDrawPrimitive::LineStrip;
        if (!flat && mode==3) return false;
        for (size_t i=0;i+1<n;++i) { emit(i,i+1); emit(i+1,i+1); }
        if (mode==2 && n>=2) { emit(n-1,0); emit(0,0); }
        break;
    case 4:
        if (!flat) return false;
        for (size_t i=0;i+2<n;i+=3) tri(i,i+1,i+2,i+2);
        break;
    case 5:
        if (!flat) { primitive=GLDrawPrimitive::TriangleStrip; return false; }
        for (size_t i=0;i+2<n;++i) tri(i+(i%2),i+1-(i%2),i+2,i+2);
        break;
    case 6: case 9:
        for (size_t i=1;i+1<n;++i) tri(0,i,i+1,mode==9?0:i+1);
        break;
    case 7:
        for (size_t i=0;i+3<n;i+=4) { tri(i,i+1,i+2,i+3); tri(i,i+2,i+3,i+3); }
        break;
    case 8:
        for (size_t i=0;i+3<n;i+=2) { tri(i,i+1,i+3,i+3); tri(i,i+3,i+2,i+3); }
        break;
    default: return false;
    }
    return true;
}
#endif
