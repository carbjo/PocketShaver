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
#import "KeyHapticFeedbackObjC.h"

void objc_initOverlayViewController(void) {
	@autoreleasepool {
		[OverlayViewController injectOverlayViewController];

		if (MiscellaneousSettingsObjC.isRelateiveMouseModeSettingAlwaysOn) {
			objc_setRelativeMouseMode(true);
			objc_reportRelativeMouseModeEnabled();
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

