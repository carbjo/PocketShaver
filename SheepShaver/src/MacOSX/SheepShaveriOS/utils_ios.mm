/*
 *	utils_ios.mm - iOS utility functions.
 *
 *  Copyright (C) 2011 Alexei Svitkine
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
 
 Additional code by Tom Padula 2022.
 
 */

#include <UIKit/UIKit.h>
#include "sysdeps.h"
#include <SDL.h>
#include "utils_ios.h"

#if SDL_VERSION_ATLEAST(2,0,0)
#include <SDL_syswm.h>
#endif

#include <sys/sysctl.h>
#include <Metal/Metal.h>

// This is used from video_sdl.cpp.
void NSAutoReleasePool_wrap(void (*fn)(void))
{
//	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	fn();
//	[pool release];
}

#if SDL_VERSION_ATLEAST(2,0,0)

void disable_SDL2_macosx_menu_bar_keyboard_shortcuts() {
#if 0
	for (NSMenuItem * menu_item in [NSApp mainMenu].itemArray) {
		if (menu_item.hasSubmenu) {
			for (NSMenuItem * sub_item in menu_item.submenu.itemArray) {
				sub_item.keyEquivalent = @"";
				sub_item.keyEquivalentModifierMask = 0;
			}
		}
		if ([menu_item.title isEqualToString:@"View"]) {
			[[NSApp mainMenu] removeItem:menu_item];
			break;
		}
	}
#endif
	
}

bool is_fullscreen_osx(SDL_Window * window)
{
	return false;
#if 0
	if (!window) {
		return false;
	}
	
	SDL_SysWMinfo wmInfo;
	SDL_VERSION(&wmInfo.version);
	if (!SDL_GetWindowWMInfo(window, &wmInfo)) {
		return false;
	}

	const NSWindowStyleMask styleMask = [wmInfo.info.cocoa.window styleMask];
	return (styleMask & NSWindowStyleMaskFullScreen) != 0;
#endif
}
#endif

void set_menu_bar_visible_osx(bool visible)
{
//	[NSMenu setMenuBarVisible:(visible ? YES : NO)];
}

void set_current_directory()
{
//	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	chdir([[[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent] UTF8String]);
//	[pool release];
}

const char* document_directory()
{
	NSArray* aDirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	//	NSLog (@"%s Found dirs: %@", __PRETTY_FUNCTION__, aDirs);
	if ([aDirs count]) {
		return [[aDirs firstObject] UTF8String];
	}
	return "";
}

const char* home_directory()
{
	return [NSHomeDirectory() UTF8String];
}

bool MetalIsAvailable() {
	return true;
#if 0
	const int EL_CAPITAN = 15; // Darwin major version of El Capitan
	char s[16];
	size_t size = sizeof(s);
	int v;
	if (sysctlbyname("kern.osrelease", s, &size, NULL, 0) || sscanf(s, "%d", &v) != 1 || v < EL_CAPITAN) return false;
	id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
	bool r = dev != nil;
	[dev release];
	return r;
#endif
}
