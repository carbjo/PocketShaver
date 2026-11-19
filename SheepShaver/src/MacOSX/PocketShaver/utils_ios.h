/*
 *	utils_ios.h - iOS utility functions.
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

#ifndef UTILS_IOS_H
#define UTILS_IOS_H

// Invokes the specified function with an NSAutoReleasePool in place.
void NSAutoReleasePool_wrap(void (*fn)(void));

#ifdef USE_SDL
#include <SDL2/SDL.h>
#include "SDL2/SDL_version.h"
#if SDL_VERSION_ATLEAST(2,0,0)
void disable_SDL2_macosx_menu_bar_keyboard_shortcuts();
bool is_fullscreen_osx(SDL_Window * window);
#endif
#endif

void set_menu_bar_visible_osx(bool visible);

void set_current_directory();
const char* home_directory();
const char* document_directory();
// Catalyst only: the app container's Data directory
// (~/Library/Containers/<bundle-id>/Data), created if needed. App data lives
// here rather than in the user's visible home.
const char* pocketshaver_home_directory();

// Catalyst only: moves a legacy ~/PocketShaver Home into the container Data
// directory once. Idempotent; call at launch before any file access.
void pocketshaver_migrate_home_if_needed();

bool MetalIsAvailable();

extern void set_relative_mouse_enabled();
extern void set_relative_mouse_disabled();
extern void toggle_relative_mouse();
extern void set_relative_mouse_automatic();
extern void report_relative_mouse_capability();
extern void setup_frame_rate();
extern void set_input_disabled(bool is_disabled);
extern void SyncHostPasteboardToPending(void);
extern void WritePendingGuestScrapToHostPasteboard(void);

#endif
