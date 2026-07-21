/*
 * Link stubs for symbols still migrating off Metal-only translation units.
 * Match C++ linkage used by callers (do not force extern "C" unless headers do).
 */
#include "sysdeps.h"
#include "cpu_emulation.h"
#include "dsp_draw_context.h"
#include "dsp_mode_enumerate.h"
#include "rave_metal_renderer.h"

#include <cstdint>


/* RaveForgetRTT / batch begin-end live in rave_gl_renderer.cpp now */
