//
//  PreferencesViewControllerObjC.mm
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

#import "PocketShaver-Swift-ObjCHeader.h"
#import <TargetConditionals.h>
#if TARGET_OS_MACCATALYST
#import <objc/message.h>
#endif

// On Mac Catalyst the emulator owns the main thread and AppKit's
// -[NSApplication run] is blocked up-stack, so UIKitMacHelper's NSEvents (which
// carry UIKit clicks) are never dequeued and the app appears unresponsive
// (spinning wheel) with a dead UI. Cooperatively drain and dispatch AppKit's
// NSEvent queue so UIKit input stays live while the main thread is inside the
// emulator or a nested run loop. No-op off Catalyst (iOS/device deliver UIKit
// events through the CFRunLoop as usual). Catalyst ships no AppKit headers, so
// NSApplication is reached via the ObjC runtime. Called ~60Hz from the
// emulator interrupt path and each iteration of the startup prefs loop.
extern "C" void catalyst_pump_appkit_events(void) {
#if TARGET_OS_MACCATALYST
	Class NSApplicationClass = NSClassFromString(@"NSApplication");
	if (!NSApplicationClass) return;
	id app = ((id (*)(Class, SEL))objc_msgSend)(NSApplicationClass, sel_registerName("sharedApplication"));
	if (!app) return;
	const NSUInteger NSEventMaskAny = NSUIntegerMax;
	NSDate *past = [NSDate distantPast];
	SEL nextSel = sel_registerName("nextEventMatchingMask:untilDate:inMode:dequeue:");
	SEL sendSel = sel_registerName("sendEvent:");
	// Bounded, non-blocking drain so a flood of events can't starve the guest.
	for (int i = 0; i < 64; i++) {
		id ev = ((id (*)(id, SEL, NSUInteger, id, id, BOOL))objc_msgSend)(
			app, nextSel, NSEventMaskAny, past, NSDefaultRunLoopMode, YES);
		if (!ev) break;
		((void (*)(id, SEL, id))objc_msgSend)(app, sendSel, ev);
	}
#endif
}

__weak __typeof(PreferencesViewController) *vc;

void objc_displayPreferencesStartup(void) {
	@autoreleasepool {
		vc = [PreferencesViewController presentStartup];

		while (!vc.isDone) {
#if TARGET_OS_MACCATALYST
			// UIKit clicks aren't CFRunLoop sources on Catalyst, so a distantFuture
			// wait would never wake to pump AppKit. Pump each iteration at 60Hz —
			// matching the emulator's interrupt-path pump so the whole app runs at a
			// single cadence — with the run loop free to return earlier if one of
			// its own sources/timers fires.
			catalyst_pump_appkit_events();
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
									 beforeDate:[NSDate dateWithTimeIntervalSinceNow:(1.0 / 60.0)]];
#else
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
#endif
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
