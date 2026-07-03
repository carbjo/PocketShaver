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

// Launch in full screen by default on Mac. The Info.plist keys that request this
// (UILaunchToFullScreenByDefaultOnMac / UISupportsTrueScreenSizeOnMac) are honored
// by the "Designed for iPad" runtime but are unreliable for a real Mac Catalyst
// binary on macOS 12+, so drive it programmatically: ask AppKit's front window to
// enter full screen. AppKit is reached through the ObjC runtime because Catalyst
// ships no AppKit headers — the same technique as catalyst_pump_appkit_events above.
// No-op off Catalyst (iOS/iPadOS are always full screen). Idempotent: it skips the
// toggle when the window is already full screen (e.g. the Info.plist key did take
// effect, or the OS restored a full-screen session), so it never toggles *out* of
// full screen, and it only ever fires once per launch.
#if TARGET_OS_MACCATALYST
static void catalyst_request_launch_fullscreen(void) {
	static bool requested = false;
	if (requested) return;

	Class NSApplicationClass = NSClassFromString(@"NSApplication");
	if (!NSApplicationClass) return;
	id app = ((id (*)(Class, SEL))objc_msgSend)(NSApplicationClass, sel_registerName("sharedApplication"));
	if (!app) return;

	// Prefer the key window (the front settings window at launch), then the main
	// window, then the first window AppKit knows about.
	id window = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("keyWindow"));
	if (!window) window = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("mainWindow"));
	if (!window) {
		id windows = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("windows"));
		if (windows) window = ((id (*)(id, SEL))objc_msgSend)(windows, sel_registerName("firstObject"));
	}
	if (!window) return;

	SEL toggleSel = sel_registerName("toggleFullScreen:");
	if (![window respondsToSelector:toggleSel]) return;

	// NSWindowStyleMaskFullScreen == 1 << 14. Already full screen ⇒ nothing to do.
	const NSUInteger NSWindowStyleMaskFullScreen = (1UL << 14);
	NSUInteger styleMask = ((NSUInteger (*)(id, SEL))objc_msgSend)(window, sel_registerName("styleMask"));
	if (styleMask & NSWindowStyleMaskFullScreen) { requested = true; return; }

	// Make sure the window is allowed to go full screen. Catalyst windows carry
	// NSWindowCollectionBehaviorFullScreenPrimary (1 << 7) by default; assert it
	// defensively before toggling.
	SEL cbGet = sel_registerName("collectionBehavior");
	SEL cbSet = sel_registerName("setCollectionBehavior:");
	if ([window respondsToSelector:cbGet] && [window respondsToSelector:cbSet]) {
		const NSUInteger NSWindowCollectionBehaviorFullScreenPrimary = (1UL << 7);
		NSUInteger behavior = ((NSUInteger (*)(id, SEL))objc_msgSend)(window, cbGet);
		((void (*)(id, SEL, NSUInteger))objc_msgSend)(window, cbSet,
			behavior | NSWindowCollectionBehaviorFullScreenPrimary);
	}

	((void (*)(id, SEL, id))objc_msgSend)(window, toggleSel, nil);
	requested = true;
}
#endif

__weak __typeof(PreferencesViewController) *vc;

void objc_displayPreferencesStartup(void) {
	@autoreleasepool {
		vc = [PreferencesViewController presentStartup];

#if TARGET_OS_MACCATALYST
		// Launch full screen by default on Mac. Requested here — while the run
		// loop below is actively pumping — so the full-screen transition can
		// complete before the emulator claims the main thread for good.
		catalyst_request_launch_fullscreen();
#endif

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
