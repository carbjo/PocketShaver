//
//  ADBObjC.h
//  PocketShaver
//
//  Created by Carl Björkman on 2025-12-31.
//

#include <Foundation/Foundation.h>
#include "HoverMode.h"

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
void objc_ADBSetHover(bool isDown);

#ifdef __cplusplus
extern "C"
#endif
void objc_ADBSetHoverMode(enum HoverMode mode);

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
