//
//  main.m
//  SheepShaveriOS
//
//  Created by Tom Padula on 5/9/22.

#import <UIKit/UIKit.h>

/* Include the SDL main definition header */
#include "my_sdl.h"


extern "C" int main_ios(int argc, char* argv[]);


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

