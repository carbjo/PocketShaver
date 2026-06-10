/*
 *  dsp_dispatch.h - DSp dispatch-table header
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This header re-exports DSpDispatch() from dsp_engine.h; dispatch-specific
 *  constants (sub-opcode range boundaries, per-category iteration macros) may
 *  later split out of dsp_engine.h into this file, mirroring gl_dispatch's
 *  split from gl_engine.
 */

#ifndef DSP_DISPATCH_H
#define DSP_DISPATCH_H

#include "dsp_engine.h"   /* re-exports DSpDispatch and sub-opcode enum */

#endif /* DSP_DISPATCH_H */
