//
//  ADBObjC.h
//  PocketShaver
//
//  Created by Carl Björkman on 2025-12-31.
//

#import <Foundation/Foundation.h>
#import "HoverOffsetMode.h"

NS_ASSUME_NONNULL_BEGIN

@interface ADBBeginAnimationState : NSObject

@property NSInteger x;
@property NSInteger y;

@property NSInteger offset_x;
@property NSInteger offset_y;

- (instancetype)initWithX:(NSInteger)x y:(NSInteger)y offset_x:(NSInteger)offset_x offset_y:(NSInteger)offset_y;

@end

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
void objc_ADBWriteMouseDown(NSInteger button);

#ifdef __cplusplus
extern "C"
#endif
void objc_ADBWriteMouseUp(NSInteger button);

#ifdef __cplusplus
extern "C"
#endif
void objc_ADBMouseClick(NSInteger button);

#ifdef __cplusplus
extern "C"
#endif
void objc_ADBMouseMoved(NSInteger x, NSInteger y);

#ifdef __cplusplus
extern "C"
#endif
void objc_ADBSetHoverOffsetMode(enum HoverOffsetMode mode);

#ifdef __cplusplus
extern "C"
#endif
BOOL objc_ADBHoversOnMouseDown();

#ifdef __cplusplus
extern "C"
#endif
BOOL objc_ADBHoverGestureStartWasLeftSide();

#ifdef __cplusplus
extern "C"
#endif
ADBBeginAnimationState *objc_ADBStartAnimation();

#ifdef __cplusplus
extern "C"
#endif
void objc_ADBAnimateMove(NSInteger x, NSInteger y);

#ifdef __cplusplus
extern "C"
#endif
void objc_ADBEndAnimation();

NS_ASSUME_NONNULL_END
