//
//  ADBObjC.mm
//  PocketShaver
//
//  Created by Carl Björkman on 2025-12-31.
//

#include "ADBObjC.h"
#include "sysdeps.h"
#include "adb.h"

void objc_ADBKeyDown(NSInteger key) {
	ADBKeyDown((int)key);
}

void objc_ADBKeyUp(NSInteger key) {
	ADBKeyUp((int)key);
}

void objc_ADBSetHover(bool isDown) {
	ADBSetHover(isDown);
}

void objc_ADBSetHoverMode(HoverMode mode) {
	ADBSetHoverMode(mode);
}

void objc_ADBWriteMouseDown(NSInteger button) {
	ADBWriteMouseDown((int)button);
}

void objc_ADBWriteMouseUp(NSInteger button) {
	ADBWriteMouseUp((int)button);
}

void objc_ADBMouseMoved(NSInteger x, NSInteger y) {
	ADBMouseMoved((int)x, (int)y);
}
