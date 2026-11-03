/*
 *  rave_guest_buffer.h - RAVE guest-buffer ownership and callback guards.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef RAVE_GUEST_BUFFER_H
#define RAVE_GUEST_BUFFER_H
#include <cstdint>

// Guest NewPtrSys/DisposePtr execute guest code. RAVE entry points must not
// expose partially changed context state to callbacks during those calls.
inline unsigned &RaveGuestMemoryCallDepth() { static unsigned depth = 0; return depth; }
struct RaveGuestMemoryScope {
    RaveGuestMemoryScope() { ++RaveGuestMemoryCallDepth(); }
    ~RaveGuestMemoryScope() { --RaveGuestMemoryCallDepth(); }
};
inline bool RaveGuestMemoryCallActive() { return RaveGuestMemoryCallDepth() != 0; }

template<class Allocate, class Map, class Release>
bool RaveReplaceGuestBuffer(uint32_t &address, uint8_t *&host, uint32_t &size,
                            uint32_t required, Allocate allocate, Map map, Release release)
{
    if (address && size == required) return true;
    RaveGuestMemoryScope guard;
    const uint32_t replacement = allocate(required);
    if (!replacement) return false;
    const uint32_t previous = address;
    address = replacement;
    host = map(replacement);
    size = required;
    if (previous) release(previous);
    return true;
}

template<class Release>
void RaveReleaseGuestBuffer(uint32_t &address, uint8_t *&host, uint32_t &size, Release release)
{
    RaveGuestMemoryScope guard;
    const uint32_t previous = address;
    address = 0;
    host = nullptr;
    size = 0;
    if (previous) release(previous);
}
#endif
