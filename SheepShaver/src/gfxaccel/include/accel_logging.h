/*
 *  accel_logging.h - Compile-time logging flag for acceleration subsystems
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Master compile-time switch for RAVE, GL, and NQD diagnostic logging.
 *  When ACCEL_LOGGING_ENABLED is 1 (default): all subsystem logging macros
 *  (RAVE_LOG, GL_LOG, GL_METAL_LOG, NQD_LOG) compile in and are controlled
 *  by their respective runtime bools.
 *  When ACCEL_LOGGING_ENABLED is 0: all diagnostic logging compiles to
 *  zero-cost no-ops, runtime bools become compile-time false for dead-code
 *  elimination, and Apple-specific os_log imports/objects are excluded.
 *  NQD_ERR (always-on error logging) is NOT gated by this flag.
 */

#ifndef ACCEL_LOGGING_H
#define ACCEL_LOGGING_H

#ifndef ACCEL_LOGGING_ENABLED
#define ACCEL_LOGGING_ENABLED 1
#endif

#endif /* ACCEL_LOGGING_H */
