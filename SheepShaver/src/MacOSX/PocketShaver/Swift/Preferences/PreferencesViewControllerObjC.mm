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

// Only the emulation runs full screen by default on Mac — the startup settings
// menu stays a normal window (see objc_displayPreferencesStartup, which enters
// full screen after the menu is dismissed). The Info.plist keys that would request
// launch-full-screen (UILaunchToFullScreenByDefaultOnMac / UISupportsTrueScreenSizeOnMac)
// are honored by the "Designed for iPad" runtime but are unreliable for a real Mac
// Catalyst binary on macOS 12+, so drive it programmatically. AppKit is reached
// through the ObjC runtime because Catalyst ships no AppKit headers — the same
// technique as catalyst_pump_appkit_events above. All of this is Catalyst-only
// (iOS/iPadOS are always full screen).
#if TARGET_OS_MACCATALYST
// The AppKit window backing the app: key window (front), else main window, else the
// first window AppKit knows about.
static id catalyst_front_window(void) {
	Class NSApplicationClass = NSClassFromString(@"NSApplication");
	if (!NSApplicationClass) return nil;
	id app = ((id (*)(Class, SEL))objc_msgSend)(NSApplicationClass, sel_registerName("sharedApplication"));
	if (!app) return nil;
	id window = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("keyWindow"));
	if (!window) window = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("mainWindow"));
	if (!window) {
		id windows = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("windows"));
		if (windows) window = ((id (*)(id, SEL))objc_msgSend)(windows, sel_registerName("firstObject"));
	}
	return window;
}

// NSWindowStyleMaskFullScreen == 1 << 14.
static bool catalyst_front_window_is_fullscreen(void) {
	id window = catalyst_front_window();
	if (!window) return false;
	NSUInteger styleMask = ((NSUInteger (*)(id, SEL))objc_msgSend)(window, sel_registerName("styleMask"));
	return (styleMask & (1UL << 14)) != 0;
}

// Enter full screen once. Idempotent: skips the toggle when already full screen
// (so it never toggles *out*, e.g. if the Info.plist key did take effect), and only
// ever fires once per launch.
static void catalyst_request_launch_fullscreen(void) {
	static bool requested = false;
	if (requested) return;

	id window = catalyst_front_window();
	if (!window) return;

	SEL toggleSel = sel_registerName("toggleFullScreen:");
	if (![window respondsToSelector:toggleSel]) return;

	if (catalyst_front_window_is_fullscreen()) { requested = true; return; }

	// Make sure the window is allowed to go full screen. Catalyst windows carry
	// NSWindowCollectionBehaviorFullScreenPrimary (1 << 7) by default; assert it
	// defensively before toggling.
	SEL cbGet = sel_registerName("collectionBehavior");
	SEL cbSet = sel_registerName("setCollectionBehavior:");
	if ([window respondsToSelector:cbGet] && [window respondsToSelector:cbSet]) {
		NSUInteger behavior = ((NSUInteger (*)(id, SEL))objc_msgSend)(window, cbGet);
		((void (*)(id, SEL, NSUInteger))objc_msgSend)(window, cbSet, behavior | (1UL << 7));
	}

	((void (*)(id, SEL, id))objc_msgSend)(window, toggleSel, nil);
	requested = true;
}
#endif

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

#if TARGET_OS_MACCATALYST
		// The startup settings menu ran as a normal window; now that it's dismissed
		// and the emulator is about to boot, take the app full screen for emulation.
		// Pump a live run loop until the transition lands (bounded to ~2s so a stuck
		// transition can't hang launch), because right after this returns the
		// emulator claims the main thread and only NSEvent-pumps AppKit afterward —
		// too coarse to drive the full-screen animation to completion.
		catalyst_request_launch_fullscreen();
		for (int i = 0; i < 120 && !catalyst_front_window_is_fullscreen(); i++) {
			catalyst_pump_appkit_events();
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
									 beforeDate:[NSDate dateWithTimeIntervalSinceNow:(1.0 / 60.0)]];
		}
#endif
	}
}

void objc_displayPreferencesDuringEmulationOnMain(void) {
	dispatch_sync(dispatch_get_main_queue(), ^{
		[LocalNotificationObjCProxy sendDisplayPreferencesRequested];
	});
}
