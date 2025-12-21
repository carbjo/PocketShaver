//
//  MiscellaneousSettingsObjC.mm
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-26.
//

#import "MiscellaneousSettingsObjC.h"
#import "MiscellaneousSettingsObjCCppHeader.h"
#import <UIKit/UIKit.h>
#import "PocketShaver-Swift.h"
#include "sysdeps.h"
#include "adb.h"
#include "utils_ios.h"

void objc_setMouseHapticFeedbackEnabled(BOOL isOn) {
	ADBSetHapticFeedback(isOn);
}

void objc_setRelativeMouseMode(BOOL isOn) {
	if (isOn) {
		set_relative_mouse_enabled();
	} else {
		set_relative_mouse_disabled();
	}
}

void objc_setRelativeMouseModeAutomatic() {
	set_relative_mouse_automatic();
}

int objc_getFrameRateSetting(void) {
	return (int)MiscellaneousSettingsObjC.getFrameRateSetting;
}

bool objc_getIPadMousePassthroughOn(void) {
	return MiscellaneousSettingsObjC.isIPadMousePassthroughOn;
}

bool objc_getRelateiveMouseModeSettingIsAlwaysOn(void) {
	return MiscellaneousSettingsObjC.isRelateiveMouseModeSettingAlwaysOn;
}

bool objc_getRelateiveMouseModeSettingIsAlwaysAutomatic(void) {
	return MiscellaneousSettingsObjC.isRelateiveMouseModeSettingAlwaysAutomatic;
}

bool objc_getRelativeMouseTapToClick(void) {
	return MiscellaneousSettingsObjC.isRelativeMouseTapToClickOn;
}

bool objc_getSoundDisabled(void) {
	return MiscellaneousSettingsObjC.isSoundDisabled;
}

