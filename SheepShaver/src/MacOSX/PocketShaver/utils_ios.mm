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
#include "my_sdl.h"
#include "utils_ios.h"

#if SDL_VERSION_ATLEAST(2,0,0)
#include <SDL2/SDL_syswm.h>
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

#if TARGET_OS_MACCATALYST
// Must match the Swift side (FileManager.pocketShaverHome), fallback included.
static NSString *pocketshaver_bundle_identifier()
{
	NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
	return bid.length ? bid : @"com.carbjo.pocketshaver";
}

// ~/Library/Containers/<bundle-id>/Data. The build is unsandboxed, so
// NSHomeDirectory() is the real user home.
static NSString *pocketshaver_container_data_path()
{
	NSString *containers = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Containers"];
	NSString *container  = [containers stringByAppendingPathComponent:pocketshaver_bundle_identifier()];
	return [container stringByAppendingPathComponent:@"Data"];
}

void pocketshaver_migrate_home_if_needed()
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSFileManager *fm = [NSFileManager defaultManager];
		NSString *newHome = pocketshaver_container_data_path();
		NSString *oldHome = [NSHomeDirectory() stringByAppendingPathComponent:@"PocketShaver Home"];

		// An empty container counts as not migrated, so an interrupted attempt
		// or an early empty mkdir doesn't strand the legacy home.
		NSArray *newContents = [fm contentsOfDirectoryAtPath:newHome error:nil];
		BOOL newHasContent = (newContents.count > 0);
		BOOL oldExists = [fm fileExistsAtPath:oldHome];

		if (!newHasContent && oldExists) {
			// Move and copy both fail if the destination exists, so clear it.
			[fm createDirectoryAtPath:[newHome stringByDeletingLastPathComponent]
				  withIntermediateDirectories:YES attributes:nil error:nil];
			[fm removeItemAtPath:newHome error:nil];

			NSError *err = nil;
			if ([fm moveItemAtPath:oldHome toPath:newHome error:&err]) {
				printf("Migrated app home %s -> %s\n",
					   [oldHome fileSystemRepresentation], [newHome fileSystemRepresentation]);
			} else {
				// Move can fail across volumes; fall back to a copy, keeping the
				// legacy home intact.
				[fm removeItemAtPath:newHome error:nil];
				NSError *cErr = nil;
				if ([fm copyItemAtPath:oldHome toPath:newHome error:&cErr]) {
					printf("Copied app home %s -> %s (move failed: %s)\n",
						   [oldHome fileSystemRepresentation], [newHome fileSystemRepresentation],
						   [[err localizedDescription] UTF8String]);
				} else {
					// Discard any partial copy so the next launch retries from
					// the intact legacy home.
					[fm removeItemAtPath:newHome error:nil];
					printf("WARNING: could not migrate app home %s -> %s (%s)\n",
						   [oldHome fileSystemRepresentation], [newHome fileSystemRepresentation],
						   [[cErr localizedDescription] UTF8String]);
				}
			}
		} else if (newHasContent && oldExists) {
			// Both exist: leave the legacy dir alone rather than risk live data.
			printf("Note: both container home %s and legacy %s exist; leaving legacy dir in place.\n",
				   [newHome fileSystemRepresentation], [oldHome fileSystemRepresentation]);
		}

		[fm createDirectoryAtPath:newHome withIntermediateDirectories:YES attributes:nil error:nil];
	});
}

const char* pocketshaver_home_directory()
{
	// Covers callers that run before main()'s explicit migration call.
	pocketshaver_migrate_home_if_needed();
	NSString *home = pocketshaver_container_data_path();
	// Recreated each call in case it was removed at runtime.
	[[NSFileManager defaultManager] createDirectoryAtPath:home
							  withIntermediateDirectories:YES attributes:nil error:nil];
	static char buf[1024];
	strlcpy(buf, [home fileSystemRepresentation], sizeof(buf));
	return buf;
}
#endif

const char* document_directory()
{
#if TARGET_OS_MACCATALYST
	// Catalyst: Documents (ROM, prefs, disks, extfs root) lives under the
	// PocketShaver home, not the user's ~/Documents.
	static char buf[1024];
	NSString *docs = [[NSString stringWithUTF8String:pocketshaver_home_directory()]
					  stringByAppendingPathComponent:@"Documents"];
	[[NSFileManager defaultManager] createDirectoryAtPath:docs
							  withIntermediateDirectories:YES
											   attributes:nil
													error:nil];
	strlcpy(buf, [docs fileSystemRepresentation], sizeof(buf));
	return buf;
#else
	NSArray* aDirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	//	NSLog (@"%s Found dirs: %@", __PRETTY_FUNCTION__, aDirs);
	if ([aDirs count]) {
		return [[aDirs firstObject] UTF8String];
	}
	return "";
#endif
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
