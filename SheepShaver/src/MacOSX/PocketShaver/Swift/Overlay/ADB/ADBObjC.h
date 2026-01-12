//
//  ADBObjC.h
//  PocketShaver
//
//  Created by Carl Björkman on 2025-12-31.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ADBBeginAnimationState : NSObject

@property NSInteger x;
@property NSInteger y;

- (instancetype)initWithX:(NSInteger)x y:(NSInteger)y;

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
void objc_ADBEnableHoverModeWith(CGFloat offset_x, CGFloat offset_y);

#ifdef __cplusplus
extern "C"
#endif
void objc_ADBDisableHoverMode();

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

#ifdef __cplusplus
extern "C"
#endif
void objc_ADBSetTouchInput(BOOL isOn);

#ifdef __cplusplus
extern "C"
#endif
void objc_ADBSetHoverGestureDragging(BOOL isOn);

NS_ASSUME_NONNULL_END
