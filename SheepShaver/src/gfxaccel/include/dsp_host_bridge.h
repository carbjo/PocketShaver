/*
 *  dsp_host_bridge.h - DSp <-> iOS host C-callable bridge.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Pure C, usable from .cpp, .mm and the Swift bridging header. Lets the DSp
 *  engine drive UIApplication.isIdleTimerDisabled via DSpIdleTimerService.
 */

#ifndef DSP_HOST_BRIDGE_H
#define DSP_HOST_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stdint.h>

/*
 *  Set whether any DSp context is Active and fullscreen. Called by
 *  DSpContext_SetStateHandler on state edges (idle-timer suppression is
 *  fullscreen-only, DSp 1.7 p.88). Stores an atomic flag and posts
 *  "DSpHostBridge.activeFullscreenChanged" so DSpIdleTimerService can toggle
 *  the idle timer on the main thread.
 *
 *  Emul thread writes, main thread reads; relaxed ordering is enough.
 */
void DSpHostBridge_SetActiveFullscreen(bool active);

/* Read on foreground re-entry to decide whether to re-assert
 * isIdleTimerDisabled after iOS reset it. */
bool DSpHostBridge_GetActiveFullscreen(void);

#ifdef __cplusplus
}
#endif

#endif /* DSP_HOST_BRIDGE_H */
