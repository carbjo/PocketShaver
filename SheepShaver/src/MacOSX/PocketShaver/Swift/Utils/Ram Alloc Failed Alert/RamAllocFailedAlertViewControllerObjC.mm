//
//  RamAllocFailedAlertViewControllerObjC.mm
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-23.
//

#import "PocketShaver-Swift-ObjCHeader.h"
#import "sysdeps.h"
#import "prefs.h"

void objc_displayRamAllocFailedAlert(void) {
	@autoreleasepool {
		[RamAllocFailedAlertViewController present];

		while (true) {
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
		}
	}
}
