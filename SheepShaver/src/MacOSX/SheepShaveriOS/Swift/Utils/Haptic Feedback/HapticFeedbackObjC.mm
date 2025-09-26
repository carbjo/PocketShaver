//
//  HapticFeedbackObjC.m
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-26.
//

#import <UIKit/UIKit.h>
#import "SheepShaveriOS-Swift.h"

UIImpactFeedbackGenerator *objCHapticFeedbackgenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];

void objc_hapticFeedback(void) {
	[objCHapticFeedbackgenerator impactOccurred];
}

