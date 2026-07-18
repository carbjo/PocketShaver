/*
 *  jit-wx.hpp - W^X code-memory primitives for JIT backends
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

#ifndef JIT_WX_H
#define JIT_WX_H

/*
 *  On Apple Silicon (macOS / Mac Catalyst), executable memory must be
 *  mapped with MAP_JIT and is write-protected per-thread by default:
 *  writes land only inside pthread_jit_write_with_callback_np (the
 *  classic pthread_jit_write_protect_np is compile-time unavailable on
 *  Mac Catalyst), and every write must be followed by
 *  sys_icache_invalidate before execution. Backends therefore assemble
 *  each block into plain scratch memory and publish it with one
 *  jit_wx_publish call; chain backpatches are small publishes.
 *
 *  On other hosts these degrade to a plain RWX mapping and memcpy.
 */

// True when this process can map and use W^X code memory
extern bool jit_wx_available(void);

// Map a code region of `size` bytes (page-rounded). NULL on failure.
extern void *jit_wx_map(uint32 size);
extern void jit_wx_unmap(void *base, uint32 size);

// Copy `len` bytes from `src` (plain memory) to `dst` inside a mapped
// code region, then invalidate the instruction cache for that range
extern bool jit_wx_publish(void *dst, const void *src, uint32 len);

// Map + publish + execute + republish + re-execute probe
extern bool jit_wx_selftest(void);

/*
 *  Shadow registration for backends that assemble through a plain-RW
 *  mirror of the code region: emitters write at execute-address +
 *  delta, and a finished range is pushed through jit_wx_publish once.
 */

// Register/replace the (single) shadowed code region
extern void jit_wx_register_shadow(void *exec_base, void *write_base, uint32 size);

// Translate an execute-view address to its writable counterpart
// (identity when the address is outside the registered region)
extern uint8 *jit_wx_writable(void *exec_addr);

// Publish [start, stop) from the shadow into the executable region;
// no-op for directly-writable caches
extern void jit_wx_publish_range(uintptr start, uintptr stop);

#endif /* JIT_WX_H */
