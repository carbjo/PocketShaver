/*
 *  gl_buffer_policy.h - OpenGL framebuffer selection and validation helpers.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  GL 1.1 mono framebuffer selection. Bits 0/1 select front/back color.
 */

#ifndef GL_BUFFER_POLICY_H
#define GL_BUFFER_POLICY_H
#include <cstdint>

static inline unsigned GLDrawBufferTargets(uint32_t mode, bool doubleBuffered)
{
    switch (mode) {
    case 0: return 0; // GL_NONE: depth and stencil still run
    case 0x0400: case 0x0404: return 1; // FRONT_LEFT, FRONT
    case 0x0402: case 0x0405: return 2; // BACK_LEFT, BACK
    case 0x0406: case 0x0408: return doubleBuffered ? 3 : 1; // LEFT, FRONT_AND_BACK
    default: return 0;
    }
}

static inline uint32_t GLBufferSelectionError(uint32_t mode, bool doubleBuffered, bool read)
{
    switch (mode) {
    case 0: return read ? 0x0500 : 0;
    case 0x0400: case 0x0404: case 0x0406: return 0;
    case 0x0402: case 0x0405: return doubleBuffered ? 0 : 0x0502;
    case 0x0408: return read ? 0x0500 : 0;
    case 0x0401: case 0x0403: case 0x0407: // right/stereo buffers
    case 0x0409: case 0x040a: case 0x040b: case 0x040c: return 0x0502; // auxiliary buffers
    default: return 0x0500;
    }
}
#endif
