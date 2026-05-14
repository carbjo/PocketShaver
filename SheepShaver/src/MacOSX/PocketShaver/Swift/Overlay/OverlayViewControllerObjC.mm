//
//  OverlayViewController.m
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-03.
//

#import "OverlayViewControllerObjC.h"
#import "PocketShaver-Swift-ObjCHeader.h"
#include "sysdeps.h"
#include "adb.h"
#include "math.h"
#include "video.h"
#import "MiscellaneousSettingsObjC.h"
#import "MouseHapticFeedbackObjC.h"
#import "ADBObjC.h"
#import "touch_input_config.h"

void objc_initOverlayViewController(void) {
	@autoreleasepool {
		[OverlayViewController injectOverlayViewController];
	}
}

void objc_reportVideoSize(unsigned short width, unsigned short height, unsigned int depth) {
	CGSize deviceScreenSize = UIScreen.mainScreen.bounds.size;
	double deviceApsectRatio = deviceScreenSize.width / deviceScreenSize.height;
	double emulatedAspectRatio = ((double) width) / ((double) height);

	double multiplier;
	CGFloat offsetModeX, offsetModeY;

	double offsetMultiplier = 0.33;

	bool isBoundedByHeight;
	double screenMarginPercentage;

	if (emulatedAspectRatio >= deviceApsectRatio) {
		// Screen is bounded by width
		multiplier = width / deviceScreenSize.width;

		offsetModeX = width * offsetMultiplier;
		offsetModeY = offsetModeX / deviceApsectRatio;

		isBoundedByHeight = false;
		screenMarginPercentage = (1 - (deviceApsectRatio / emulatedAspectRatio)) / 2;
	} else {
		// Screen is bounded by height
		multiplier = height / deviceScreenSize.height;

		offsetModeY = height * offsetMultiplier;
		offsetModeX = offsetModeY * deviceApsectRatio;

		isBoundedByHeight = true;
		screenMarginPercentage = (1 - (emulatedAspectRatio / deviceApsectRatio)) / 2;
	}

	int tolerance = round(10 * multiplier);

	TouchInputConfig touchInputConfig;
	touchInputConfig.screen_width = width;
	touchInputConfig.screen_height = height;
	touchInputConfig.screen_margin_percentage = screenMarginPercentage;
	touchInputConfig.margin_is_horizontal_axis = isBoundedByHeight;
	touchInputConfig.double_click_tolerance = tolerance;

	ADBConfigure(touchInputConfig);
	[InputInteractionModelObjC configureWithOffsetX:offsetModeX offsetY:offsetModeY];

	BOOL isClassicResolution = (width == 640 && height == 480) ||
								(width == 800 && height == 600) ||
								(width == 1024 && height == 768) ||
								(width == 1152 && height == 870);
	BOOL isJaggyCursorResolution = !isClassicResolution &&
							(depth == APPLE_8_BIT || depth == APPLE_16_BIT);

	if (isJaggyCursorResolution) {
		[LocalNotificationObjCProxy sendJaggyCursorResolutionSelected];
	}
}

void objc_reportRelativeMouseModeEnabled() {
	[LocalNotificationObjCProxy sendRelativeMouseModeEnabled];
}

void objc_reportRelativeMouseModeDisabled() {
	[LocalNotificationObjCProxy sendRelativeMouseModeDisabled];
}

