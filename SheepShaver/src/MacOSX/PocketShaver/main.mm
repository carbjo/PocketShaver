//
//  main.m
//  SheepShaveriOS
//
//  Created by Tom Padula on 5/9/22.

#import <UIKit/UIKit.h>

/* Include the SDL main definition header */
#include "my_sdl.h"

/* Expose Swift host-bridge observers (GfxAccelBackgroundLifecycleObserver,
 * DSpIdleTimerService) to this Obj-C++ translation unit via
 * the auto-generated Swift umbrella header. The observers' @objc
 * singleton classes become callable through the standard ObjC message
 * syntax after this import. */
#import "PocketShaver-Swift-ObjCHeader.h"


extern "C" int main_ios(int argc, char* argv[]);


// Because main is #defined as SDL_main, this function is actually SDL_main. This gets called from -[SDLUIKitDelegate postFinishLaunch].
int main(int argc, char * argv[]) {
	/* Install background/foreground observer
	 * so gfxaccel_handle_background_enter / _foreground_enter run on the
	 * OS lifecycle transitions. Install here — SDL's UIKit delegate is
	 * about to enter its run loop and UIApplication notifications start
	 * firing from that point forward; installing before SDL_UIKitRunApp
	 * ensures the first didEnterBackground is never missed. */
	[GfxAccelBackgroundLifecycleObserver.shared install];

	/* Install DSp idle-timer
	 * observer. Observes UIApplication.didEnterBackground /
	 * willEnterForeground + the custom DSpHostBridge.activeFullscreenChanged
	 * notification; toggles UIApplication.shared.isIdleTimerDisabled on main
	 * thread. Must install BEFORE the first DSpContext_SetStateHandler
	 * Active transition fires (usually well after app launch, so
	 * install-at-startup is comfortable timing). */
	[DSpIdleTimerService.shared install];

	/* Install DSp event
	 * integration observer. Observes UIApplication.didEnterBackground /
	 * willEnterForeground; calls DSpHostBridge_OnBackground/OnForeground
	 * which walk dsp_context_table to enqueue osEvts + context-loss
	 * events + transition SetState Active<->Paused + manage
	 * paused_by_background flag. Must install BEFORE any DSp context is
	 * Reserved — otherwise the bg/fg observers miss the first transition.
	 * The background/foreground and idle-timer precedents show
	 * install-at-startup is correct timing. DSpEventService also handles
	 * kbd/gamepad/mouse fan-out — no main.mm change needed for that. */
	[DSpEventService.shared install];

	return main_ios(argc, argv);		// This is in SS/Source/Unix/main_Unix.cpp
}

// This is where we turn off the #define of SDL_main. This function is our actual main(), which does here exactly
// what it would do in SDL_uikit_main.c, which cannot be linked in to a dynamic library such as a framework. (Well,
// it can, but main() can't be found when it's in a dynamic library, so the app will not have a main to link with.)
#ifndef SDL_MAIN_HANDLED
#ifdef main
#undef main
#endif

int
main(int argc, char *argv[])
{
	return SDL_UIKitRunApp(argc, argv, SDL_main);
}
#endif /* !SDL_MAIN_HANDLED */

