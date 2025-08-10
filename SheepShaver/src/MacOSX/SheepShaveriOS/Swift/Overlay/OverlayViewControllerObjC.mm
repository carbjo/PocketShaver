//
//  OverlayViewController.m
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-03.
//

#import "OverlayViewControllerObjC.h"
#import <UIKit/UIKit.h>
#import "SheepShaveriOS-Swift.h"
#include "sysdeps.h"
#include "adb.h"

void objc_initOverlayViewController(void) {
	@autoreleasepool {

		[OverlayViewController injectOverlayViewControllerWithKeyInteraction:^(NSInteger key, BOOL isDown){
			if (isDown) {
				ADBKeyDown((int)key);
			} else {
				ADBKeyUp((int)key);
			}
		} specialButtonInteraction:^(enum SpecialButton button, BOOL isDown) {
			switch (button) {
				case SpecialButtonHover:
					ADBSetHover(isDown);
					break;
				case SpecialButtonHoverAbove:
					ADBSetHover(isDown);
					if (isDown) {
						ADBSetHoverMode(Above);
					} else {
						ADBSetHoverMode(Regular);
					}
					break;
				case SpecialButtonHoverBelow:
					ADBSetHover(isDown);
					if (isDown) {
						ADBSetHoverMode(Below);
					} else {
						ADBSetHoverMode(Regular);
					}
					break;
			}
		}];
	}
}
