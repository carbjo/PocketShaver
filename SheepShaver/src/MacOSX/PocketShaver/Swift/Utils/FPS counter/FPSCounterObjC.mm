//
//  FPSCounterObjC.mm
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-11-29.
//

#import "FPSCounterObjCCppHeader.h"
#import "FPSCounterObjC.h"
#import <cmath>

@interface FPSCounterObjC()

@property int counter;

- (void)reportFrameRender;

@end

static FPSCounterObjC *fpsCounter;

void objc_reportFrameRender(void) {
	if (fpsCounter) {
		[fpsCounter reportFrameRender];
	}
}

FPSCounterObjC* objc_getFpsCounter(void) {
	if (!fpsCounter) {
		fpsCounter = [FPSCounterObjC new];
	} else {
		fpsCounter.counter = 0;
	}
	return fpsCounter;
}

@implementation FPSCounterObjC

- (void)reportFrameRender {
	_counter++;
}

- (NSInteger)reportOneSecondAndFetchFps {
	int fps = _counter;
	_counter = 0;
	return fps;
}

@end
