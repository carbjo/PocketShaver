/*
 *  jit-target-cache.hpp - arm64 translation cache flush
 *
 *  PocketShaver arm64 JIT backend (C) 2026 Sierra Burkhart
 *  Kheperix (C) 2003-2005 Gwenole Beauchesne
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#ifndef JIT_TARGET_CACHE_H
#define JIT_TARGET_CACHE_H

#include "cpu/jit/jit-wx.hpp"

/*
 *  On Apple Silicon the emitters assemble into a plain-RW shadow buffer
 *  (see basic_jit_cache::wx_write_delta); gen_end() lands here and is the
 *  single point where a finished block is copied into the MAP_JIT region
 *  and the instruction cache is invalidated.
 */
static inline void flush_icache_range(unsigned long start, unsigned long stop)
{
	jit_wx_publish_range((uintptr)start, (uintptr)stop);
}

#endif /* JIT_TARGET_CACHE_H */
