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
 *  On iOS devices MAP_JIT needs an entitlement sideloaded apps lack.
 *  Instead, once a debugger has marked the process CS_DEBUGGED, one
 *  code arena is reserved up front as an RX view plus an RW alias of the
 *  same pages (see jit_ios_acquire); jit_wx_map hands that arena out and
 *  jit_wx_publish writes through the alias.
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

/*
 *  iOS code-arena acquisition through StikDebug. Declared with plain C
 *  types for the Swift bridge (PrefsObjC.h); all of them report false on
 *  hosts other than iOS devices.
 */
extern "C" {

// True when this build can JIT on an iOS device given a debugger
extern bool jit_ios_supported(void);

// True once a debugger has attached (CS_DEBUGGED); stays set after detach
extern bool jit_ios_debugger_attached(void);

// True when the code arena must be prepared through StikDebug's
// universal.js brk protocol (TXM devices). The app must then request
// that script when attaching, or the brk calls crash the process.
extern bool jit_ios_needs_prepare_script(void);

// Reserve, verify and (on TXM devices) detach. Requires
// jit_ios_debugger_attached(); may block while the debugger services the
// request, so call it off the main thread and never concurrently.
// Idempotent once it succeeds; on TXM devices it makes one attempt only,
// since the script has detached by the time it returns.
extern bool jit_ios_acquire(void);

// True once jit_ios_acquire has succeeded
extern bool jit_ios_ready(void);

// Append a line to the JIT setup log (unified log + Documents/jit-log.txt)
extern void jit_ios_note(const char *message);

}

#endif /* JIT_WX_H */
