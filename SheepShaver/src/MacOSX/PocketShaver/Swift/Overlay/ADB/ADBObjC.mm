//
//  ADBObjC.mm
//  PocketShaver
//
//  Created by Carl Björkman on 2025-12-31.
//

#include "ADBObjC.h"
#include "sysdeps.h"
#include "adb.h"

@implementation ADBBeginAnimationState

- (instancetype)initWithX:(NSInteger)x y:(NSInteger)y offset_x:(NSInteger)offset_x offset_y:(NSInteger)offset_y {
	self.x = x;
	self.y = y;
	self.offset_x = offset_x;
	self.offset_y = offset_y;

	return self;
}

@end

void objc_ADBKeyDown(NSInteger key) {
	ADBKeyDown((int)key);
}

void objc_ADBKeyUp(NSInteger key) {
	ADBKeyUp((int)key);
}

void objc_ADBWriteMouseDown(NSInteger button) {
	ADBWriteMouseDown((int)button);
}

void objc_ADBWriteMouseUp(NSInteger button) {
	ADBWriteMouseUp((int)button);
}

void objc_ADBMouseClick(NSInteger button) {
	ADBMouseClick((int)button);
}

void objc_ADBMouseMoved(NSInteger x, NSInteger y) {
	ADBMouseMoved((int)x, (int)y);
}

void objc_ADBSetHoverOffsetMode(enum HoverOffsetMode mode) {
	ADBSetHoverOffsetMode(mode);
}

BOOL objc_ADBHoversOnMouseDown() {
	return ADBHoversOnMouseDown();
}

BOOL objc_ADBHoverGestureStartWasLeftSide() {
	return ADBHoverGestureStartWasLeftSide();
}

ADBBeginAnimationState *objc_ADBStartAnimation() {
	BeginAnimationState beginAnimationState = ADBStartAnimation();
	ADBBeginAnimationState *ret = [[ADBBeginAnimationState alloc] initWithX:beginAnimationState.x y:beginAnimationState.y offset_x:beginAnimationState.offset_x offset_y:beginAnimationState.offset_y];
	return ret;
}

void objc_ADBAnimateMove(NSInteger x, NSInteger y) {
	ADBAnimateMove((int)x, (int)y);
}

void objc_ADBEndAnimation() {
	ADBEndAnimation();
}
