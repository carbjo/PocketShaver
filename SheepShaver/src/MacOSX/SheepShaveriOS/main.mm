//
//  main.m
//  SheepShaveriOS
//
//  Created by Tom Padula on 5/9/22.

#import <UIKit/UIKit.h>
#import "AppDelegate.h"

/* Include the SDL main definition header */
#include "SDL_main.h"

extern "C" int main_ios(int argc, char* argv[]);

// Under SS, this is how we got here. UIKit is initted, the SDLUIKitDelegate's applicationDidFinishLaunching is done running, we
// should be able to catch notifications and put up UI and such.
/*
 frame #0: 0x0000000101ec9bef SheepShaveriOS`SDL_main(argc=1, argv=0x0000600000824140) at main.m:23:13
 frame #1: 0x00000001020cdd15 SheepShaveriOS`-[SDLUIKitDelegate postFinishLaunch](self=0x0000600000800150, _cmd="postFinishLaunch") at SDL_uikitappdelegate.m:349:19
 frame #2: 0x00007fff208318a9 Foundation`__NSFireDelayedPerform + 415
 frame #3: 0x00007fff20390c57 CoreFoundation`__CFRUNLOOP_IS_CALLING_OUT_TO_A_TIMER_CALLBACK_FUNCTION__ + 20
 frame #4: 0x00007fff2039072a CoreFoundation`__CFRunLoopDoTimer + 926
 frame #5: 0x00007fff2038fcdd CoreFoundation`__CFRunLoopDoTimers + 265
 frame #6: 0x00007fff2038a35e CoreFoundation`__CFRunLoopRun + 1949
 frame #7: 0x00007fff203896d6 CoreFoundation`CFRunLoopRunSpecific + 567
 frame #8: 0x00007fff2c257db3 GraphicsServices`GSEventRunModal + 139
 frame #9: 0x00007fff24696cf7 UIKitCore`-[UIApplication _run] + 912
 frame #10: 0x00007fff2469bba8 UIKitCore`UIApplicationMain + 101
 frame #11: 0x00000001020cc272 SheepShaveriOS`SDL_UIKitRunApp(argc=1, argv=0x00007ffeeddb9c28, mainFunction=(SheepShaveriOS`SDL_main at main.m:22)) at SDL_uikitappdelegate.m:61:9
 frame #12: 0x0000000102070789 SheepShaveriOS`main(argc=1, argv=0x00007ffeeddb9c28) at SDL_uikit_main.c:17:12
 frame #13: 0x00007fff2025a3e9 libdyld.dylib`start + 1
 frame #14: 0x00007fff2025a3e9 libdyld.dylib`start + 1

 */

// Because main is #defined as SDL_main, this function is actually SDL_main. This gets called from -[SDLUIKitDelegate postFinishLaunch].
int main(int argc, char * argv[]) {
	
	
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

