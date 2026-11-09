/*
 *  gfxaccel_arc_shim.mm - ObjC++ @autoreleasepool wrappers for PPC dispatch
 *                         entry points.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  The emul thread runs the PPC interpreter with no outer autorelease pool,
 *  so autoreleased Metal objects from RAVE/GL calls would pile up for the
 *  whole session. These wrappers give each NATIVE_RAVE_DISPATCH /
 *  NATIVE_GL_DISPATCH call its own pool; the C++ glue cannot.
 */

#import <Foundation/Foundation.h>

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "rave_engine.h"
#include "gl_engine.h"

uint32_t RaveDispatchARC(uint32_t r3, uint32_t r4, uint32_t r5,
                                     uint32_t r6, uint32_t r7, uint32_t r8)
{
	uint32_t result = 0;
	@autoreleasepool {
		result = RaveDispatch(r3, r4, r5, r6, r7, r8);
	}
	return result;
}

// Immediate-mode setters whose handlers (and display-list recording) create
// no ObjC objects, so a pool is pure overhead. They dominate call volume in
// immediate-mode titles. glEnd is not listed: it flushes to Metal. The
// neighbouring *_POINTER opcodes fall outside these ranges.
//   GL_SUB_BEGIN                                       (4)    glBegin
//   GL_SUB_COLOR3B     .. GL_SUB_COLOR4USV       (17..48)    glColor{3,4}{b,d,f,i,s,ub,ui,us}[v]
//   GL_SUB_NORMAL3B    .. GL_SUB_NORMAL3SV     (178..187)    glNormal3{b,d,f,i,s}[v]
//   GL_SUB_TEX_COORD1D .. GL_SUB_TEX_COORD4SV  (257..288)    glTexCoord{1..4}{d,f,i,s}[v]
//   GL_SUB_VERTEX2D    .. GL_SUB_VERTEX4SV     (310..333)    glVertex{2..4}{d,f,i,s}[v]
static inline bool GLOpcodeIsObjCFreeImmediate(uint32_t op)
{
	return op == GL_SUB_BEGIN
	    || (op >= GL_SUB_COLOR3B     && op <= GL_SUB_COLOR4USV)
	    || (op >= GL_SUB_NORMAL3B    && op <= GL_SUB_NORMAL3SV)
	    || (op >= GL_SUB_TEX_COORD1D && op <= GL_SUB_TEX_COORD4SV)
	    || (op >= GL_SUB_VERTEX2D    && op <= GL_SUB_VERTEX4SV);
}

uint32_t GLDispatchARC(uint32_t r3, uint32_t r4, uint32_t r5,
                                   uint32_t r6, uint32_t r7, uint32_t r8,
                                   uint32_t r9, uint32_t r10,
                                   const uint32_t *float_bits, int num_float_args)
{
	// Same sub-opcode word GLDispatch reads.
	if (GLOpcodeIsObjCFreeImmediate(ReadMacInt32(gl_scratch_addr))) {
		return GLDispatch(r3, r4, r5, r6, r7, r8, r9, r10,
		                  float_bits, num_float_args);
	}

	uint32_t result = 0;
	@autoreleasepool {
		result = GLDispatch(r3, r4, r5, r6, r7, r8, r9, r10,
		                    float_bits, num_float_args);
	}
	return result;
}
