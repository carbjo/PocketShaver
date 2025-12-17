//
//  PreferencesViewControllerObjC.mm
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

#import <UIKit/UIKit.h>
#import "PocketShaver-Swift.h"

__weak __typeof(PreferencesViewController) *vc;

void objc_displayPreferences(void) {
	@autoreleasepool {
		vc = [PreferencesViewController present];

		while (!vc.isDone) {
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
		}

		[vc removeFromParentViewController];
		[PreferencesViewController resetPrefsWindow];
	}
}
