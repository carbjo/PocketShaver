//
//  KeyHapticFeedbackObjC.m
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-26.
//

#import "MouseHapticFeedbackObjC.h"
#import "PocketShaver-Swift-ObjCHeader.h"

UIImpactFeedbackGenerator *_mouseDownHapticFeedbackgenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];

NSDate *_latestMouseDownHapticFeedbackTimestamp;

void objc_mousedownHapticFeedback(void) {
	if (!MiscellaneousSettingsObjC.isMouseHapticFeedbackOn) {
		return;
	}
	
	[_mouseDownHapticFeedbackgenerator impactOccurred];
	_latestMouseDownHapticFeedbackTimestamp = [NSDate now];
}

NSDate *objc_getLatestMouseDownHapticFeedbackTimestamp() {
	return _latestMouseDownHapticFeedbackTimestamp;
}
