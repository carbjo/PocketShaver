/*
 *  rsrc_patches.h - Resource patches
 *
 *  SheepShaver (C) 1997-2008 Christian Bauer and Marc Hellwig
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

#ifndef RSRC_PATCHES_H
#define RSRC_PATCHES_H

extern void CheckLoad(uint32 type, int16 id, uint16 *p, uint32 size);
extern void CheckLoad(uint32 type, const char *name, uint16 *p, uint32 size);
extern void PatchNativeResourceManager(void);

// DII splash-hang fix: lock Sound Manager component PEF code resources so they
// are not purged/heap-moved after CFM prepares them.  maybe_queue_nift_lock()
// records a handle at load (safe anywhere); DrainPendingResourceLocks() locks
// queued handles and MUST be called only from a legal Execute68kTrap context
// (the 60Hz VBL interrupt), never the native get_resource thunk.
extern void maybe_queue_nift_lock(uint32 type, uint32 h);
extern void DrainPendingResourceLocks(void);

// Diagnostic: dump monitored 'nift' handle state from the illegal-instruction
// handler.  Pure host-side reads, safe from any context.
extern void RsrcLocksDumpOnCrash(void);

// Fault-time repair: if pc lies in a monitored 'nift' container whose code has
// been zeroed (guest disposed it behind CFM's back), restore the container
// from the host snapshot and report the range to invalidate.  Returns nonzero
// if repaired and the faulting instruction should be retried.
extern int RsrcLocksTryRepair(uint32 pc, uint32 *out_start, uint32 *out_end);

// True iff guest handle h is a live monitored 'nift' whose backing store must
// never be freed (DII use-after-free root fix).  Used by the _DisposHandle
// head-patch (OP_DISPOSE_NIFT_GUARD) to skip the free for these handles only.
extern bool RsrcLockIsLiveNift(uint32 h);

// Stock _DisposHandle trap entry captured at head-patch install (host global); the
// dispose thunk's EMUL_OP returns it in A1 for the chain-to-stock (non-'nift') path.
extern uint32 RsrcLockDisposeOrig(void);

// Virtual-memory-present Gestalt spoof.  Stock _Gestalt ($A1AD) trap entry captured
// at head-patch install (host global); the thunk's EMUL_OP returns it in A1 to
// tail-jump to the genuine _Gestalt on the chain path.
extern uint32 GestaltHookOrig(void);

// Virtual-memory-present Gestalt spoof.  Address of the bare `rts` at the tail of
// the gestalt thunk; the OP_GESTALT_VM head-patch points A1 here on the spoof path
// so it returns the synthesized "VM present" A0/D0 without running the real _Gestalt.
extern uint32 GestaltRtsStub(void);

// Virtual-memory-present Gestalt spoof, process-scoped.  Returns true iff the
// current application (CurApName, low-mem 0x910) is one of the target apps that
// require VM, so the OP_GESTALT_VM head-patch reports gestaltVMAttr = "VM present"
// only for them and gives the truth (VM off) to everything else (spoofing it
// globally crashes boot).
extern bool GestaltFakeVMForCurrentApp(void);

#endif
