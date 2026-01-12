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
	}
}

void objc_reportVideoSize(unsigned short width, unsigned short height) {
	CGSize deviceScreenSize = UIScreen.mainScreen.bounds.size;
	double deviceApsectRatio = deviceScreenSize.width / deviceScreenSize.height;
	double emulatedAspectRatio = ((double) width) / ((double) height);

	double multiplier;
	CGFloat offsetModeX, offsetModeY;

	double offsetMultiplier = 0.33;

	if (emulatedAspectRatio >= deviceApsectRatio) {
		// Screen is bounded by width
		multiplier = width / deviceScreenSize.width;

		offsetModeX = width * offsetMultiplier;
		offsetModeY = offsetModeX / deviceApsectRatio;
	} else {
		// Screen is bounded by height
		multiplier = height / deviceScreenSize.height;

		offsetModeY = height * offsetMultiplier;
		offsetModeX = offsetModeY * deviceApsectRatio;
	}

	int tolerance = round(10 * multiplier);
	int screenMiddleX = width / 2;

	ADBConfigure(screenMiddleX, tolerance);
	[InputInteractionModelObjC configureWithOffsetX:offsetModeX offsetY:offsetModeY];
}

void objc_reportRelativeMouseModeEnabled() {
	[LocalNotificationsObjCProxy sendRelativeMouseModeEnabled];
}

void objc_reportRelativeMouseModeDisabled() {
	[LocalNotificationsObjCProxy sendRelativeMouseModeDisabled];
}

