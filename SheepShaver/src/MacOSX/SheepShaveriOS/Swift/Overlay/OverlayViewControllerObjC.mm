//
//  OverlayViewController.m
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-03.
//

#import "OverlayViewControllerObjC.h"
#import <stdio.h>
#import <UIKit/UIKit.h>
#import "SheepShaveriOS-Swift.h"
#include "sysdeps.h"
#include "adb.h"

void objc_initOverlayViewController(void) {
	[OverlayViewController injectOverlayViewControllerWithTestPushed:^(SDLKey key){
		NSLog(@"push down");
		
		ADBKeyDown((int)key);

	} testReleased:^(SDLKey key){
		NSLog(@"release");

		ADBKeyUp((int)key);
	} testRaw:^(NSInteger key){
		NSLog(@"release");

		ADBKeyDown((int)key);
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			ADBKeyUp((int)key);
		});
	}];
}
