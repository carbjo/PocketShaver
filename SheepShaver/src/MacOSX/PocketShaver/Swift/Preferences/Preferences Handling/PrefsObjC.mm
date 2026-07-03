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
#import <TargetConditionals.h>
#if TARGET_OS_MACCATALYST
#import <objc/message.h>
#endif

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

double catalyst_screen_top_inset(void) {
#if TARGET_OS_MACCATALYST
	// The Mac camera housing (notch) / menu-bar strip is surfaced only by AppKit's
	// NSScreen.safeAreaInsets — UIKit's view/window safeAreaInsets are 0 in a
	// Catalyst process even on a notched Mac (unlike "Designed for iPad", where the
	// notch is a UIKit inset). Catalyst ships no AppKit headers, so NSScreen is
	// reached through the ObjC runtime, the same technique the app already uses for
	// NSApplication in catalyst_pump_appkit_events.
	Class NSScreenClass = NSClassFromString(@"NSScreen");
	if (!NSScreenClass) return 0;
	id screen = ((id (*)(Class, SEL))objc_msgSend)(NSScreenClass, sel_registerName("mainScreen"));
	if (!screen) return 0;
	SEL saiSel = sel_registerName("safeAreaInsets");
	if (![screen respondsToSelector:saiSel]) return 0; // pre-macOS 12 / pre-notch
	// NSEdgeInsets == { CGFloat top, left, bottom, right }. On arm64 (AAPCS64) this
	// small homogeneous-float aggregate is returned in registers, so the plain
	// objc_msgSend cast is correct here — do NOT use objc_msgSend_stret.
	struct CatalystNSEdgeInsets { CGFloat top; CGFloat left; CGFloat bottom; CGFloat right; };
	CatalystNSEdgeInsets insets =
		((CatalystNSEdgeInsets (*)(id, SEL))objc_msgSend)(screen, saiSel);
	return (double)insets.top; // 0 on notchless built-ins and external displays
#else
	return 0;
#endif
}

