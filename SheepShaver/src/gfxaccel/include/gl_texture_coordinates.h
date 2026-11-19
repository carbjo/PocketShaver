/*
 *  gl_texture_coordinates.h - OpenGL texture generation and coordinate transforms.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef GL_TEXTURE_COORDINATES_H
#define GL_TEXTURE_COORDINATES_H

#include <cmath>
#include <cstring>
#include "gl_engine.h"

static inline void GLInitTextureGeneration(GLTextureUnit &unit)
{
    unit.texgen_s_enabled = unit.texgen_t_enabled = false;
    unit.texgen_r_enabled = unit.texgen_q_enabled = false;
    unit.texgen_s_mode = unit.texgen_t_mode = 0x2400; // GL_EYE_LINEAR
    unit.texgen_r_mode = unit.texgen_q_mode = 0x2400;
    std::memset(unit.texgen_object_plane, 0, sizeof(unit.texgen_object_plane));
    std::memset(unit.texgen_eye_plane, 0, sizeof(unit.texgen_eye_plane));
    for (int c = 0; c < 2; ++c) {
        unit.texgen_object_plane[c][c] = 1;
        unit.texgen_eye_plane[c][c] = 1;
    }
}

// Invert the full modelview, including legal non-affine matrices. Eye planes
// are transformed when specified, rather than following later matrix changes.
static inline bool GLTextureInverseMatrix(double inverse[4][4], const float m[16])
{
    double a[4][8] = {};
    for (int r = 0; r < 4; ++r)
        for (int c = 0; c < 4; ++c) {
            a[r][c] = m[c * 4 + r];
            a[r][c + 4] = r == c ? 1 : 0;
        }
    for (int c = 0; c < 4; ++c) {
        int pivot = c;
        for (int r = c + 1; r < 4; ++r)
            if (std::fabs(a[r][c]) > std::fabs(a[pivot][c])) pivot = r;
        if (!(std::fabs(a[pivot][c]) > 1e-30)) return false;
        if (pivot != c)
            for (int k = 0; k < 8; ++k) {
                const double t = a[c][k]; a[c][k] = a[pivot][k]; a[pivot][k] = t;
            }
        const double divisor = a[c][c];
        for (int k = 0; k < 8; ++k) a[c][k] /= divisor;
        for (int r = 0; r < 4; ++r) {
            if (r == c) continue;
            const double factor = a[r][c];
            for (int k = 0; k < 8; ++k) a[r][k] -= factor * a[c][k];
        }
    }
    for (int r = 0; r < 4; ++r)
        for (int c = 0; c < 4; ++c) inverse[r][c] = a[r][c + 4];
    return true;
}

static inline bool GLTextureTransformPlane(double out[4], const double plane[4],
                                           const float modelview[16])
{
    double inverse[4][4];
    if (!GLTextureInverseMatrix(inverse, modelview)) return false;
    double result[4] = {};
    for (int c = 0; c < 4; ++c)
        for (int r = 0; r < 4; ++r) result[c] += plane[r] * inverse[r][c];
    std::memcpy(out, result, sizeof(result));
    return true;
}

static inline void GLTextureTransformVector(float out[4], const float m[16],
                                            const float in[4])
{
    float result[4] = {};
    for (int r = 0; r < 4; ++r)
        for (int c = 0; c < 4; ++c) result[r] += m[c * 4 + r] * in[c];
    std::memcpy(out, result, sizeof(result));
}

static inline void GLGenerateTextureCoordinates(float out[4], const GLTextureUnit &unit,
    const float current[4], const float object[4], const float eye[4],
    const float normal[3], const float matrix[16])
{
    const bool enabled[4] = {unit.texgen_s_enabled, unit.texgen_t_enabled,
                             unit.texgen_r_enabled, unit.texgen_q_enabled};
    const int mode[4] = {unit.texgen_s_mode, unit.texgen_t_mode,
                         unit.texgen_r_mode, unit.texgen_q_mode};
    float generated[4];
    std::memcpy(generated, current, sizeof(generated));
    float sphere[2] = {.5f, .5f};
    if ((enabled[0] && mode[0] == 0x2402) || (enabled[1] && mode[1] == 0x2402)) {
        const float length = std::sqrt(eye[0]*eye[0] + eye[1]*eye[1] + eye[2]*eye[2]);
        if (length > 0) {
            const float dot = (eye[0]*normal[0] + eye[1]*normal[1] + eye[2]*normal[2]) / length;
            const float x = eye[0]/length - 2*normal[0]*dot;
            const float y = eye[1]/length - 2*normal[1]*dot;
            const float z = eye[2]/length - 2*normal[2]*dot + 1;
            const float denominator = 2 * std::sqrt(x*x + y*y + z*z);
            if (denominator > 0) { sphere[0] += x/denominator; sphere[1] += y/denominator; }
        }
    }
    for (int c = 0; c < 4; ++c) {
        if (!enabled[c]) continue;
        if (mode[c] == 0x2402 && c < 2) generated[c] = sphere[c];
        else {
            const double *plane = mode[c] == 0x2401 ? unit.texgen_object_plane[c] : unit.texgen_eye_plane[c];
            const float *position = mode[c] == 0x2401 ? object : eye;
            double value = 0;
            for (int k = 0; k < 4; ++k) value += plane[k] * position[k];
            generated[c] = (float)value;
        }
    }
    GLTextureTransformVector(out, matrix, generated);
}
#endif
