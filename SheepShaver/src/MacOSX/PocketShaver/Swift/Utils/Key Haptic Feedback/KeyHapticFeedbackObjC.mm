//
//  KeyHapticFeedbackObjC.m
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-26.
//

#import "KeyHapticFeedbackObjC.h"
#import <UIKit/UIKit.h>
#import "PocketShaver-Swift.h"

UIImpactFeedbackGenerator *objCHapticFeedbackgenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];

void objc_keyHapticFeedback(void) {
	[objCHapticFeedbackgenerator impactOccurred];
}

