/*
 *  dsp_host_bridge.mm - DSp <-> iOS host bridge implementation.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Tells DSpIdleTimerService.swift when a DSp context goes Active fullscreen
 *  so it can disable the idle timer. The setter runs on the emul thread; the
 *  Swift observer handles the notification on the main queue.
 *
 *  The flag is also re-read on willEnterForeground, because a transition
 *  made while backgrounded would otherwise be missed.
 */

#import <Foundation/Foundation.h>

#import "dsp_host_bridge.h"

#include <stdatomic.h>

/* Written by the emul thread only; read from any thread. */
static _Atomic bool s_dsp_active_fullscreen = false;

extern "C" void DSpHostBridge_SetActiveFullscreen(bool active)
{
	/* Store before posting so the observer sees the new value. */
	atomic_store_explicit(&s_dsp_active_fullscreen, active,
	                      memory_order_relaxed);

	/* Name must match the Swift observer. The emul thread has no
	 * enclosing autorelease pool. */
	@autoreleasepool {
		[[NSNotificationCenter defaultCenter]
		    postNotificationName:@"DSpHostBridge.activeFullscreenChanged"
		                  object:nil];
	}
}

extern "C" bool DSpHostBridge_GetActiveFullscreen(void)
{
	return atomic_load_explicit(&s_dsp_active_fullscreen,
	                            memory_order_relaxed);
}
