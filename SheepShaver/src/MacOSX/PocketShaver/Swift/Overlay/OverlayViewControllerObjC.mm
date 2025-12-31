//
//  OverlayViewController.m
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-03.
//

#import "OverlayViewControllerObjC.h"
#import <UIKit/UIKit.h>
#import "PocketShaver-Swift.h"
#include "sysdeps.h"
#include "adb.h"
#include "math.h"
#import "MiscellaneousSettingsObjC.h"
#import "HapticFeedbackObjC.h"

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
				case SpecialButtonMouseClick:
					if (isDown) {
						ADBWriteMouseDown(0);

						if ([MiscellaneousSettingsObjC isKeyHapticFeedbackOn]) {
							objc_hapticFeedback();
						}
					} else {
						ADBWriteMouseUp(0);
					}
					break;
				case SpecialButtonCmdW:
					if (!isDown) {
						ADBKeyDown((int)SDLKeyObjCProxy.cmdValue);
						ADBKeyDown((int)SDLKeyObjCProxy.wValue);

						dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
							ADBKeyUp((int)SDLKeyObjCProxy.cmdValue);
							ADBKeyUp((int)SDLKeyObjCProxy.wValue);
						});
					}
					break;
			}
		} didFireJoystick:^(CGPoint point) {
			int x = (int) point.x;
			int y = (int) point.y;

			ADBMouseMoved(x, y);
		}];

		if (MiscellaneousSettingsObjC.isRelateiveMouseModeSettingAlwaysOn) {
			objc_setRelativeMouseMode(true);
		}
	}
}

void objc_reportVideoSize(unsigned short width, unsigned short height) {
	CGSize deviceScreenSize = UIScreen.mainScreen.bounds.size;
	double deviceApsectRatio = deviceScreenSize.width / deviceScreenSize.height;
	double emulatedAspectRatio = ((double) width) / ((double) height);

	double multiplier;

	if (emulatedAspectRatio >= deviceApsectRatio) {
		// Screen is bounded by width
		multiplier = width / deviceScreenSize.width;
	} else {
		// Screen is bounded by height
		multiplier = height / deviceScreenSize.height;
	}

	int tolerance = round(10 * multiplier);

	ADBSetMouseMoveTolerance(tolerance);
}

void objc_reportRelativeMouseModeEnabled() {
	[LocalNotificationsObjCProxy sendRelativeMouseModeEnabled];
}

void objc_reportRelativeMouseModeDisabled() {
	[LocalNotificationsObjCProxy sendRelativeMouseModeDisabled];
}

