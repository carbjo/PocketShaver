//
//  PreferencesViewControllerObjC.mm
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

#import <UIKit/UIKit.h>
#import "SheepShaveriOS-Swift.h"

void objc_displayPreferences(void) {
	__weak __typeof(PreferencesViewController) *vc = [PreferencesViewController present];

	@autoreleasepool {
		while (!vc.isDone) {
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
		}
	}

	NSLog(@"- Went past while loop \n");

	/**

	 [[SSPreferencesViewController sharedPreferencesViewController] removeFromParentViewController];
	 prefsWindow().rootViewController = nil;
	 prefsWindow().hidden = YES;

	 */
}
