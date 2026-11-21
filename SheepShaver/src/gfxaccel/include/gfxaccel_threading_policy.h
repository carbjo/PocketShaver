/*
 *  gfxaccel_threading_policy.h - iOS gfxaccel threading policy.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 */

#ifndef GFXACCEL_THREADING_POLICY_H
#define GFXACCEL_THREADING_POLICY_H

/*
 * On iOS, SDL_main runs on the UIKit main thread and runs the PPC emulator
 * inline, so the main thread is the emul thread. "Main vs emul thread" races
 * are really same-thread re-entry: the emulator pumps the runloop and guest
 * callbacks can re-enter gfxaccel before the outer handler returns.
 *
 * Re-entry points: HandleInterrupt -> SDL_PumpEvents, CallMacOS* guest
 * trampolines, CADisplayLink VBL callback fan-out, and UIKit notifications
 * delivered during a pump.
 *
 * Don't add locks for state that is single-threaded only because main==emul.
 * Defer work to a known drain point, guard nested fan-out, and revalidate
 * handles after any guest callback or runloop pump.
 *
 * If emulation ever leaves the main thread, every file including this header
 * is an audit site: statics guarded only by this policy need real
 * synchronization.
 */

#endif /* GFXACCEL_THREADING_POLICY_H */
