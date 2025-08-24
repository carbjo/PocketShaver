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
void objc_update_sdl_ipad_mouse_setting(void);

#ifdef __cplusplus
extern "C"
#endif
void objc_savePrefs(void);
