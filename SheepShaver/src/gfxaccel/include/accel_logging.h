/*
 *  accel_logging.h - Compile-time + runtime control plane for accel logging
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  ACCEL_LOGGING_ENABLED=1 compiles in the subsystem *_LOG / *_VLOG macros,
 *  each gated at runtime by the environment. At 0 (ship default) they compile
 *  away. *_ERR macros are always on.
 *
 *  Runtime control (tools/gfxlog.sh):
 *    GFXACCEL_LOG          = "all" or a comma list of gl,rave,dsp,nqd,comp
 *                            (unset = all on)
 *    GFXACCEL_LOG_VERBOSE  = 1 for the per-draw/per-frame tier
 */

#ifndef ACCEL_LOGGING_H
#define ACCEL_LOGGING_H

#ifndef ACCEL_LOGGING_ENABLED
#define ACCEL_LOGGING_ENABLED 0
#endif

#ifdef __cplusplus
#if ACCEL_LOGGING_ENABLED

#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace accel_log_detail {

/* True if GFXACCEL_LOG is unset, "all", or a comma list containing `name`.
 * Has no static-init ordering dependency, so gate bools can call it. */
inline bool subsystem_on(const char *name) {
    const char *env = std::getenv("GFXACCEL_LOG");
    if (!env || !*env) return true;
    /* C strings only: <string> pulls in libc++ <atomic>, which conflicts
     * with <stdatomic.h> in some TUs before C++23. */
    char hay[256];
    std::snprintf(hay, sizeof(hay), ",%s,", env);
    if (std::strstr(hay, ",all,")) return true;
    char needle[40];
    std::snprintf(needle, sizeof(needle), ",%s,", name);
    return std::strstr(hay, needle) != nullptr;
}

inline bool verbose_env() {
    const char *e = std::getenv("GFXACCEL_LOG_VERBOSE");
    if (!e || !*e) return false;
    return e[0] == '1' || e[0] == 't' || e[0] == 'T' || e[0] == 'y' || e[0] == 'Y';
}

/* Read once; an inline function's local static is shared across TUs. */
inline bool verbose() { static bool v = verbose_env(); return v; }

} /* namespace accel_log_detail */

#define ACCEL_LOG_VERBOSE (accel_log_detail::verbose())

#else  /* !ACCEL_LOGGING_ENABLED */
#define ACCEL_LOG_VERBOSE false
#endif
#endif /* __cplusplus */

#endif /* ACCEL_LOGGING_H */
