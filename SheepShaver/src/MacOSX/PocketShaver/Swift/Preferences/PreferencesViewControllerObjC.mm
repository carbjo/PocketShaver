//
//  PreferencesViewControllerObjC.mm
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

#import "PocketShaver-Swift-ObjCHeader.h"

__weak __typeof(PreferencesViewController) *vc;

void objc_displayPreferencesStartup(void) {
	@autoreleasepool {
		vc = [PreferencesViewController presentStartup];

		while (!vc.isDone) {
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
		}

		[vc removeFromParentViewController];
		[PreferencesViewController resetPrefsWindow];
	}
}

void objc_displayPreferencesDuringEmulationOnMain(void) {
	dispatch_sync(dispatch_get_main_queue(), ^{
		[LocalNotificationObjCProxy sendDisplayPreferencesRequested];
	});
}
