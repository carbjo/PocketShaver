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
#import "MouseHapticFeedbackObjC.h"
#import "ADBObjC.h"

void objc_initOverlayViewController(void) {
	@autoreleasepool {
		[OverlayViewController injectOverlayViewController];

		if (MiscellaneousSettingsObjC.isRelateiveMouseModeSettingAlwaysOn) {
			objc_setRelativeMouseMode(true);
			objc_reportRelativeMouseModeEnabled();
		}
		if (MiscellaneousSettingsObjC.isBootInHoverModeOn) {
			objc_ADBSetHoverOffsetMode(HoverOffsetModeHoverNoOffset);
		}
	}
}

void objc_reportVideoSize(unsigned short width, unsigned short height) {
	CGSize deviceScreenSize = UIScreen.mainScreen.bounds.size;
	double deviceApsectRatio = deviceScreenSize.width / deviceScreenSize.height;
	double emulatedAspectRatio = ((double) width) / ((double) height);

	double multiplier;
	int offsetModeX, offsetModeY;

	double offsetMultiplier = 0.33;

	if (emulatedAspectRatio >= deviceApsectRatio) {
		// Screen is bounded by width
		multiplier = width / deviceScreenSize.width;

		offsetModeX = (int) (width * offsetMultiplier);
		offsetModeY = (int) (offsetModeX / deviceApsectRatio);
	} else {
		// Screen is bounded by height
		multiplier = height / deviceScreenSize.height;

		offsetModeY = (int) (height * offsetMultiplier);
		offsetModeX = (int) (offsetModeY * deviceApsectRatio);
	}

	int tolerance = round(10 * multiplier);
	int screenMiddleX = width / 2;

	ADBConfigure(screenMiddleX, tolerance, offsetModeX, offsetModeY);
}

void objc_reportRelativeMouseModeEnabled() {
	[LocalNotificationsObjCProxy sendRelativeMouseModeEnabled];
}

void objc_reportRelativeMouseModeDisabled() {
	[LocalNotificationsObjCProxy sendRelativeMouseModeDisabled];
}

