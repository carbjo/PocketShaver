//
//  MiscellaneousSettingsObjC.mm
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-26.
//

#import "MiscellaneousSettingsObjC.h"
#import "MiscellaneousSettingsObjCCppHeader.h"
#import "PocketShaver-Swift-ObjCHeader.h"
#include "sysdeps.h"
#include "adb.h"
#include "utils_ios.h"

void cpp_setRelativeMouseMode(BOOL isOn) {
	if (isOn) {
		set_relative_mouse_enabled();
	} else {
		set_relative_mouse_disabled();
	}
}

void cpp_setRelativeMouseModeAutomatic() {
	set_relative_mouse_automatic();
}

void cpp_toggle_relative_mouse_on_main() {
	dispatch_sync(dispatch_get_main_queue(), ^{
		toggle_relative_mouse();
	});
}

void objc_reportRelativeMouseModeCapability() {
	[LocalNotificationsObjCProxy sendRelativeMouseModeCapabilityFound];
}

int objc_getFrameRateSetting(void) {
	return (int)MiscellaneousSettingsObjC.getFrameRateSetting;
}

void cpp_updateFrameRateHz() {
	setup_frame_rate();
}

bool objc_getIPadMousePassthroughOn(void) {
	return MiscellaneousSettingsObjC.isIPadMousePassthroughOn;
}

bool objc_getRelateiveMouseModeSettingIsAlwaysOn(void) {
	return MiscellaneousSettingsObjC.isRelateiveMouseModeSettingAlwaysOn;
}

bool objc_getRelateiveMouseModeSettingIsAutomatic(void) {
	return MiscellaneousSettingsObjC.isRelateiveMouseModeSettingAutomatic;
}

bool objc_getRelativeMouseTapToClick(void) {
	return MiscellaneousSettingsObjC.isRelativeMouseTapToClickOn;
}

bool objc_getSoundDisabled(void) {
	return !MiscellaneousSettingsObjC.isAudioEnabled;
}

bool objc_getIsLinearGammaEnabled(void) {
	return MiscellaneousSettingsObjC.isLinearGammaEnabled;
}
