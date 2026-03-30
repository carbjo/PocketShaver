//
//  PrefsObjC.mm
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-29.
//

#define int32 int32_t
#import "prefs.h"
#include "my_sdl.h"
#import "PrefsObjC.h"
#import "audio_sdl.h"

#ifndef SDL_HINT_IOS_IPAD_MOUSE_PASSTHROUGH
#define SDL_HINT_IOS_IPAD_MOUSE_PASSTHROUGH "SDL_HINT_IOS_IPAD_MOUSE_PASSTHROUGH"
#endif

NSString* _Nullable objc_findString(NSString * _Nonnull name) {
	const char *paramCString = [name cStringUsingEncoding:NSISOLatin1StringEncoding];
	const char *outputCString = PrefsFindString(paramCString);
	
	if (outputCString) {
		NSString *result = [NSString stringWithCString:outputCString encoding:NSISOLatin1StringEncoding];
		return result;
	} else {
		return nil;
	}
};

NSString* _Nullable objc_findStringWithIndex(NSString * _Nonnull name, int index) {
	const char *paramCString = [name cStringUsingEncoding:NSISOLatin1StringEncoding];
	const char *outputCString = PrefsFindString(paramCString, index);

	if (outputCString) {
		NSString *result = [NSString stringWithCString:outputCString encoding:NSISOLatin1StringEncoding];
		return result;
	} else {
		return nil;
	}
};

void objc_removeItem(NSString * _Nonnull name) {
	const char *paramCString = [name cStringUsingEncoding:NSISOLatin1StringEncoding];
	PrefsRemoveItem(paramCString);
};

void objc_addString(NSString * _Nonnull name, NSString * _Nonnull str) {
	const char *nameCString = [name cStringUsingEncoding:NSISOLatin1StringEncoding];
	const char *strCString = [str cStringUsingEncoding:NSISOLatin1StringEncoding];
	PrefsAddString(nameCString, strCString);
}

void objc_replaceString(NSString * _Nonnull name, NSString * _Nonnull str) {
	const char *nameCString = [name cStringUsingEncoding:NSISOLatin1StringEncoding];
	const char *strCString = [str cStringUsingEncoding:NSISOLatin1StringEncoding];
	PrefsReplaceString(nameCString, strCString);
}

NSInteger objc_findInt32(NSString * _Nonnull name) {
	const char *nameCString = [name cStringUsingEncoding:NSISOLatin1StringEncoding];
	return PrefsFindInt32(nameCString);
}

void objc_replaceInt32(NSString * _Nonnull name, NSInteger value) {
	const char *nameCString = [name cStringUsingEncoding:NSISOLatin1StringEncoding];
	PrefsReplaceInt32(nameCString, (int32_t) value);
}

BOOL objc_findBool(NSString * _Nonnull name) {
	const char *nameCString = [name cStringUsingEncoding:NSISOLatin1StringEncoding];
	return PrefsFindBool(nameCString);
}

void objc_replaceBool(NSString * _Nonnull name, BOOL value) {
	const char *nameCString = [name cStringUsingEncoding:NSISOLatin1StringEncoding];
	PrefsReplaceBool(nameCString, value);
}

void objc_update_sdl_ipad_mouse_setting(BOOL isOn) {
	SDL_SetHint(SDL_HINT_IOS_IPAD_MOUSE_PASSTHROUGH, (isOn ? "1" : "0"));
}

void objc_update_audio_enabled_setting(BOOL isEnabled) {
	if (isEnabled) {
		open_audio();
	} else {
		close_audio();
	}
}

void objc_savePrefs(void) {
	SavePrefs();
}

