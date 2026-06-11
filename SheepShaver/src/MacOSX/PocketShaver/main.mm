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
	/* Diagnostic stdio capture: when PS_STDIO_FILE is set (Xcode scheme env
	 * or launchctl setenv), mirror stdout+stderr to that file so emulator
	 * printf/fprintf diagnostics survive launches without an attached
	 * console (LaunchServices `open`, tap-to-launch, resume relaunches). */
	if (const char *stdio_path = getenv("PS_STDIO_FILE")) {
		if (freopen(stdio_path, "a", stderr)) setvbuf(stderr, NULL, _IONBF, 0);
		if (freopen(stdio_path, "a", stdout)) setvbuf(stdout, NULL, _IOLBF, 0);
		fprintf(stderr, "--- PS_STDIO_FILE capture started ---\n");
	}
	/* Install background/foreground observer
	 * so gfxaccel_handle_background_enter / _foreground_enter run on the
	 * OS lifecycle transitions. Install here — SDL's UIKit delegate is
	 * about to enter its run loop and UIApplication notifications start
	 * firing from that point forward; installing before SDL_UIKitRunApp
	 * ensures the first didEnterBackground is never missed. */
	[GfxAccelBackgroundLifecycleObserver.shared install];

	/* Install memory-pressure observer. The notification arrives on the
	 * main thread; the C shim only marks an atomic pending-eviction flag.
	 * The next compositor SubmitFrame drains that request on the engine
	 * call path, keeping heap mutation off UIKit's notification callback. */
	[GfxAccelMemoryWarningObserver.shared install];

	/* Install DSp idle-timer
	 * observer. Observes UIApplication.didEnterBackground /
	 * willEnterForeground + the custom DSpHostBridge.activeFullscreenChanged
	 * notification; toggles UIApplication.shared.isIdleTimerDisabled on main
	 * thread. Must install BEFORE the first DSpContext_SetStateHandler
	 * Active transition fires (usually well after app launch, so
	 * install-at-startup is comfortable timing). */
	[DSpIdleTimerService.shared install];

	/* Install DSp input-event integration. Background/foreground DSp
	 * lifecycle is handled by GfxAccelBackgroundLifecycleObserver through
	 * gfxaccel_resources' atomic flag-and-drain path; DSpEventService only
	 * fans out kbd/gamepad/mouse events to active DSp contexts. */
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
