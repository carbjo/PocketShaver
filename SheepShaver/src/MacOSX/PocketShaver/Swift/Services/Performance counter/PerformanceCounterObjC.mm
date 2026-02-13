//
//  PerformanceCounterObjC.mm
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-11-29.
//

#import "PerformanceCounterObjCCppHeader.h"
#import "PerformanceCounterObjC.h"
#import "PocketShaver-Swift-ObjCHeader.h"

@interface PerformanceCounterObjC()

@property int framesRendered;
@property int bytesTransferred;

- (void)reportFrameRender;
- (void)reportBytesTransferred:(int)numberOfBytes;

@end

static PerformanceCounterObjC *performanceCounter;

void objc_reportFrameRender(void) {
	if (performanceCounter) {
		[performanceCounter reportFrameRender];
	}
}

void objc_reportBytesTransferred(int numberOfBytes) {
	if (performanceCounter) {
		[performanceCounter reportBytesTransferred:numberOfBytes];
	}
}

PerformanceCounterObjC* objc_getPerformanceCounter(void) {
	if (!performanceCounter) {
		performanceCounter = [PerformanceCounterObjC new];
	} else {
		performanceCounter.framesRendered = 0;
		performanceCounter.bytesTransferred = 0;
	}
	return performanceCounter;
}

@implementation PerformanceCounterObjC

- (void)reportFrameRender {
	_framesRendered++;
}

- (void)reportBytesTransferred:(int)numberOfBytes {
	_bytesTransferred += numberOfBytes;
}

- (PerformanceCounterReport*)reportOneSecondAndFetchReport {
	int framesRendered = _framesRendered;
	int bytesTransferred = _bytesTransferred;
	_framesRendered = 0;
	_bytesTransferred = 0;

	PerformanceCounterReport *report = [[PerformanceCounterReport alloc] initWithFramesRendered:framesRendered bytesTransferred:bytesTransferred];

	return report;
}

@end
