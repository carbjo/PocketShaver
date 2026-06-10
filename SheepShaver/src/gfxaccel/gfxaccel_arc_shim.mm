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
 *  PURPOSE
 *  -------
 *  The PPC emul thread (main_unix.cpp:emul_func -> jump_to_rom) runs the
 *  PowerPC interpreter in a tight loop with NO outer @autoreleasepool.
 *  When RAVE / GL draw methods create autoreleased ObjC objects
 *  (MTLCommandBuffer, MTLRenderCommandEncoder, MTLRenderPassDescriptor,
 *  MTLBlitCommandEncoder, MTLTextureDescriptor, MTLVertexDescriptor, and
 *  the many transient NSString/NSError objects Metal creates under
 *  validation), those objects accumulate in the thread's top-level
 *  autorelease pool and are never drained during a gameplay session.
 *  The result is LINEAR memory growth tied to rendered frames -- exactly
 *  what Nanosaur exhibited after the 97ab9856+2c873706+fa1a003c+44510413
 *  fix chain landed and steady-state gameplay became possible.
 *
 *  FIX
 *  ---
 *  Wrap the RAVE and GL dispatch entry points in @autoreleasepool.  The
 *  pool drains on every NATIVE_RAVE_DISPATCH / NATIVE_GL_DISPATCH call
 *  (every RAVE draw method, every GL entry point invoked by the emulated
 *  app).  This is the idiomatic pattern for ObjC++ code running outside
 *  a Cocoa run loop and matches MetalCompositorPresent (which already
 *  wraps its per-frame body).
 *
 *  sheepshaver_glue.cpp:NATIVE_RAVE_DISPATCH / NATIVE_GL_DISPATCH are
 *  compiled as C++; they cannot host the @autoreleasepool directive.
 *  This shim lives in ObjC++ and is called via the extern "C" signatures
 *  declared in rave_engine.h / gl_engine.h.
 */

#import <Foundation/Foundation.h>

#include "sysdeps.h"
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

uint32_t GLDispatchARC(uint32_t r3, uint32_t r4, uint32_t r5,
                                   uint32_t r6, uint32_t r7, uint32_t r8,
                                   uint32_t r9, uint32_t r10,
                                   const uint32_t *float_bits, int num_float_args)
{
	uint32_t result = 0;
	@autoreleasepool {
		result = GLDispatch(r3, r4, r5, r6, r7, r8, r9, r10,
		                    float_bits, num_float_args);
	}
	return result;
}
