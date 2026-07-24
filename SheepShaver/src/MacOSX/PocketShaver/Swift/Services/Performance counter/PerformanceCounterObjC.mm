//
//  PerformanceCounterObjC.mm
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-11-29.
//

#import "PerformanceCounterObjCCppHeader.h"
#import "PerformanceCounterObjC.h"
#import "PocketShaver-Swift-ObjCHeader.h"

#import <stdatomic.h>

// Frame/byte tallies are file-static atomics. The writers run OFF the main
// thread — objc_reportFrameRender() from the Metal compositor present (VBL)
// path, objc_reportBytesTransferred() from the ether/slirp packet-reception
// threads — while the read-and-reset runs on the @MainActor 1-second timer.
// Relaxed ordering suffices: each is a monotonic tally with no dependent memory.
static _Atomic int s_framesRendered   = 0;
static _Atomic int s_bytesTransferred = 0;

static PerformanceCounterObjC *performanceCounter;

void objc_reportFrameRender(void) {
	atomic_fetch_add_explicit(&s_framesRendered, 1, memory_order_relaxed);
}

void objc_reportBytesTransferred(int numberOfBytes) {
	atomic_fetch_add_explicit(&s_bytesTransferred, numberOfBytes, memory_order_relaxed);
}

PerformanceCounterObjC* objc_getPerformanceCounter(void) {
	if (!performanceCounter) {
		performanceCounter = [PerformanceCounterObjC new];
	} else {
		atomic_store_explicit(&s_framesRendered, 0, memory_order_relaxed);
		atomic_store_explicit(&s_bytesTransferred, 0, memory_order_relaxed);
	}
	return performanceCounter;
}

@implementation PerformanceCounterObjC

- (PerformanceCounterReport*)reportOneSecondAndFetchReport {
	// Read-and-clear each tally atomically. The 1-second sampling window means
	// the frame count returned here IS the frames-per-second value.
	int framesRendered   = atomic_exchange_explicit(&s_framesRendered, 0, memory_order_relaxed);
	int bytesTransferred = atomic_exchange_explicit(&s_bytesTransferred, 0, memory_order_relaxed);

	PerformanceCounterReport *report = [[PerformanceCounterReport alloc] initWithFramesRendered:framesRendered bytesTransferred:bytesTransferred];

	return report;
}

@end
