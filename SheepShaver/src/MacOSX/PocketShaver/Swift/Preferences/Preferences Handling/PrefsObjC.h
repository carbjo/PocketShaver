//
//  PrefsObjC.h
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-29.
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C"
#endif
NSString* _Nullable objc_findString(NSString * _Nonnull name);

#ifdef __cplusplus
extern "C"
#endif
NSString* _Nullable objc_findStringWithIndex(NSString * _Nonnull name, int index);

#ifdef __cplusplus
extern "C"
#endif
void objc_removeItem(NSString * _Nonnull name);

#ifdef __cplusplus
extern "C"
#endif
void objc_addString(NSString * _Nonnull name, NSString * _Nonnull str);

#ifdef __cplusplus
extern "C"
#endif
void objc_replaceString(NSString * _Nonnull name, NSString * _Nonnull str);

#ifdef __cplusplus
extern "C"
#endif
NSInteger objc_findInt32(NSString * _Nonnull name);

#ifdef __cplusplus
extern "C"
#endif
void objc_replaceInt32(NSString * _Nonnull name, NSInteger value);

#ifdef __cplusplus
extern "C"
#endif
BOOL objc_findBool(NSString * _Nonnull name);

#ifdef __cplusplus
extern "C"
#endif
void objc_replaceBool(NSString * _Nonnull name, BOOL value);

#ifdef __cplusplus
extern "C"
#endif
void objc_update_sdl_ipad_mouse_setting(BOOL);

#ifdef __cplusplus
extern "C"
#endif
void objc_update_audio_enabled_setting(BOOL isEnabled);

#ifdef __cplusplus
extern "C"
#endif
void objc_savePrefs(void);

// Keep SDL's rotation policy consistent with the selected boot layout.
#ifdef __cplusplus
extern "C"
#endif
void objc_set_emulation_orientation(BOOL portrait);

// Catalyst only: apply Windowed (NO) / Full Screen (YES) to the live emulation window.
#ifdef __cplusplus
extern "C"
#endif
void objc_set_catalyst_fullscreen(BOOL enable);

// Catalyst only: height in points of the notch / menu-bar safe-area strip, from
// AppKit's NSScreen (UIKit reports 0 in Catalyst). Returns 0 off Catalyst, on
// notchless or external displays, and on macOS < 12.
#ifdef __cplusplus
extern "C"
#endif
double catalyst_screen_top_inset(void);
