//
//  ADBObjC.h
//  PocketShaver
//
//  Created by Carl Björkman on 2025-12-31.
//

#import <Foundation/Foundation.h>
#import "OffsetMode.h"

#ifdef __cplusplus
extern "C"
#endif
void objc_ADBKeyDown(NSInteger key);

#ifdef __cplusplus
extern "C"
#endif
void objc_ADBKeyUp(NSInteger key);

#ifdef __cplusplus
extern "C"
#endif
void objc_ADBSetHoverMode(bool is_on);

#ifdef __cplusplus
extern "C"
#endif
void objc_ADBWriteMouseDown(NSInteger button);

#ifdef __cplusplus
extern "C"
#endif
void objc_ADBWriteMouseUp(NSInteger button);

#ifdef __cplusplus
extern "C"
#endif
void objc_ADBMouseMoved(NSInteger x, NSInteger y);

#ifdef __cplusplus
extern "C"
#endif
void objc_ADBSetOffsetMode(enum OffsetMode mode);

#ifdef __cplusplus
extern "C"
#endif
BOOL objc_ADBHoversOnMouseDown();
