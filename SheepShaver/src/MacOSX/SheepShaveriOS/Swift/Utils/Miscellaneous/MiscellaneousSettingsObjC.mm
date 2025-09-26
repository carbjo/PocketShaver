//
//  MiscellaneousSettingsObjC.mm
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-26.
//

#import "MiscellaneousSettingsObjC.h"
#include "sysdeps.h"
#include "adb.h"

void objc_setMouseHapticFeedbackEnabled(BOOL isOn) {
	ADBSetHapticFeedback(isOn);
}
