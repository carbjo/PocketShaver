//
//  PreferencesViewControllerObjC.mm
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

#import "PocketShaver-Swift-ObjCHeader.h"
#import <TargetConditionals.h>
#import "PrefsObjC.h"
#if TARGET_OS_MACCATALYST
#import <objc/message.h>
// Defined in the Catalyst helper block below.
static void catalyst_detect_fullscreen_change(void);
static void catalyst_resize_window_for_guest(int guest_w, int guest_h);
// Defined in metal_compositor.mm.
extern "C" void MetalCompositorReapplyWindowPinning(void);
extern "C" double MetalCompositorWindowedContentInsetTop(void);
// Last guest resolution seen, for re-sizing the window on a return to windowed.
static int s_last_guest_w = 0;
static int s_last_guest_h = 0;
#endif

// Catalyst: the emulator owns the main thread, so -[NSApplication run] never
// dequeues the NSEvents that carry UIKit input and the UI goes dead. Drain them
// here instead. Called ~60Hz from the emulator interrupt path and the startup
// prefs loop. Catalyst has no AppKit headers, so AppKit is reached through the
// ObjC runtime (here and below). No-op off Catalyst.
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
	catalyst_detect_fullscreen_change();
#endif
}

// Catalyst full-screen handling. The startup menu stays windowed and emulation
// goes full screen afterwards. This is driven programmatically because the
// launch-full-screen Info.plist keys are unreliable for Catalyst binaries.
#if TARGET_OS_MACCATALYST
// Key window, else main window, else the first window.
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

// Idempotent: no-op when the window is already in the requested state.
static void catalyst_set_fullscreen(bool enable) {
	id window = catalyst_front_window();
	if (!window) return;

	SEL toggleSel = sel_registerName("toggleFullScreen:");
	if (![window respondsToSelector:toggleSel]) return;

	if (catalyst_front_window_is_fullscreen() == enable) return;

	if (enable) {
		// Ensure NSWindowCollectionBehaviorFullScreenPrimary (1 << 7). Catalyst
		// sets it by default; this is defensive.
		SEL cbGet = sel_registerName("collectionBehavior");
		SEL cbSet = sel_registerName("setCollectionBehavior:");
		if ([window respondsToSelector:cbGet] && [window respondsToSelector:cbSet]) {
			NSUInteger behavior = ((NSUInteger (*)(id, SEL))objc_msgSend)(window, cbGet);
			((void (*)(id, SEL, NSUInteger))objc_msgSend)(window, cbSet, behavior | (1UL << 7));
		}
	}

	((void (*)(id, SEL, id))objc_msgSend)(window, toggleSel, nil);
}

// Polled from the AppKit pump to catch full-screen changes made by any means.
// It fires on a real window-state transition, not on pref-vs-window mismatch:
// the styleMask flips asynchronously during the animation, so a mismatch check
// could revert the pref mid-change. It never toggles the window itself.
// Active only during emulation, so the startup menu's forced-windowed state
// never rewrites the pref.
static bool s_fullscreen_sync_active = false;

static void catalyst_detect_fullscreen_change(void) {
	if (!s_fullscreen_sync_active) return;
	static int lastKnown = -1;   // -1 = uninitialized
	bool isFull = catalyst_front_window_is_fullscreen();
	if (lastKnown == -1) { lastKnown = isFull ? 1 : 0; return; }   // seed, no action
	if ((isFull ? 1 : 0) == lastKnown) return;
	lastKnown = isFull ? 1 : 0;

	MetalCompositorReapplyWindowPinning();
	// Back to windowed: re-size to the guest so no letterbox lingers.
	if (!isFull && s_last_guest_w > 0 && s_last_guest_h > 0)
		catalyst_resize_window_for_guest(s_last_guest_w, s_last_guest_h);

	if (objc_findBool(@"catalystfullscreen") != isFull) {
		objc_replaceBool(@"catalystfullscreen", isFull);
		objc_savePrefs();
	}
	[LocalNotificationObjCProxy sendCatalystFullscreenStateChanged];
}

// Size the window so one guest pixel is one point, scaled down uniformly if it
// won't fit the usable screen. Windowed only; runs on the main thread.
static void catalyst_resize_window_for_guest(int guest_w, int guest_h) {
	if (guest_w <= 0 || guest_h <= 0) return;
	s_last_guest_w = guest_w;
	s_last_guest_h = guest_h;
	dispatch_async(dispatch_get_main_queue(), ^{
		id window = catalyst_front_window();
		if (!window) return;
		if (catalyst_front_window_is_fullscreen()) return;

		SEL setSizeSel = sel_registerName("setContentSize:");
		if (![window respondsToSelector:setSizeSel]) return;

		// Windowed, the compositor view sits below the title bar, so add that inset
		// to the content height to make the drawable exactly guest-sized. Prefer the
		// compositor's safe-area top, then the measured title bar, then 28 pt.
		CGFloat titleBar = MetalCompositorWindowedContentInsetTop();
		if (titleBar <= 0.0) {
			titleBar = 28.0;
			SEL frameSel = sel_registerName("frame");
			SEL crffSel = sel_registerName("contentRectForFrameRect:");
			if ([window respondsToSelector:frameSel] && [window respondsToSelector:crffSel]) {
#if defined(__x86_64__)
				// CGRect returns via hidden sret pointer on x86-64
				CGRect frame, content;
				((void (*)(CGRect *, id, SEL))objc_msgSend_stret)(&frame, window, frameSel);
				((void (*)(CGRect *, id, SEL, CGRect))objc_msgSend_stret)(&content, window, crffSel, frame);
#else
				CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(window, frameSel);
				CGRect content = ((CGRect (*)(id, SEL, CGRect))objc_msgSend)(window, crffSel, frame);
#endif
				CGFloat measured = frame.size.height - content.size.height;
				if (measured > 0.0) titleBar = measured;
			}
		}

		CGFloat drawW = (CGFloat)guest_w;
		CGFloat drawH = (CGFloat)guest_h;

		// Fit into visibleFrame (excludes menu bar and Dock) minus the title bar.
		// visibleFrame needs objc_msgSend_stret on x86-64.
		id screen = ((id (*)(id, SEL))objc_msgSend)(window, sel_registerName("screen"));
		if (!screen) {
			Class NSScreenClass = NSClassFromString(@"NSScreen");
			if (NSScreenClass)
				screen = ((id (*)(Class, SEL))objc_msgSend)(NSScreenClass, sel_registerName("mainScreen"));
		}
		if (screen) {
			SEL vfSel = sel_registerName("visibleFrame");
			if ([screen respondsToSelector:vfSel]) {
#if defined(__x86_64__)
				CGRect vf;
				((void (*)(CGRect *, id, SEL))objc_msgSend_stret)(&vf, screen, vfSel);
#else
				CGRect vf = ((CGRect (*)(id, SEL))objc_msgSend)(screen, vfSel);
#endif
				CGFloat maxW = vf.size.width;
				CGFloat maxH = vf.size.height - titleBar;
				if (maxH < 1.0) maxH = vf.size.height;
				CGFloat scale = 1.0;
				if (drawW > maxW) scale = maxW / drawW;
				if (drawH * scale > maxH) scale = maxH / drawH;
				if (scale < 1.0) {
					drawW *= scale;
					drawH *= scale;
				}
			}
		}

		CGSize size = CGSizeMake(drawW, drawH + titleBar);
		((void (*)(id, SEL, CGSize))objc_msgSend)(window, setSizeSel, size);

		SEL centerSel = sel_registerName("center");
		if ([window respondsToSelector:centerSel])
			((void (*)(id, SEL))objc_msgSend)(window, centerSel);
	});
}
#endif

// Declared in PrefsObjC.h.
extern "C" void objc_set_catalyst_fullscreen(BOOL enable) {
#if TARGET_OS_MACCATALYST
	catalyst_set_fullscreen(enable);
#endif
}

// Used by the Metal compositor's window pinning. False off Catalyst.
extern "C" bool catalyst_is_window_fullscreen(void) {
#if TARGET_OS_MACCATALYST
	return catalyst_front_window_is_fullscreen();
#else
	return false;
#endif
}

// Declared in PreferencesViewControllerObjCCppHeader.h.
void objc_resize_catalyst_window_for_guest(int guest_w, int guest_h) {
#if TARGET_OS_MACCATALYST
	catalyst_resize_window_for_guest(guest_w, guest_h);
#endif
}

__weak __typeof(PreferencesViewController) *vc;

void objc_displayPreferencesStartup(void) {
	@autoreleasepool {
#if TARGET_OS_MACCATALYST
		// Stop macOS restoring the window to full screen on the next launch, so the
		// startup menu comes up windowed without an exit animation.
		{
			id restoreWin = catalyst_front_window();
			SEL setRestorableSel = sel_registerName("setRestorable:");
			if (restoreWin && [restoreWin respondsToSelector:setRestorableSel])
				((void (*)(id, SEL, BOOL))objc_msgSend)(restoreWin, setRestorableSel, NO);
		}
		// The startup menu is always windowed. Sync is still off, so the pref is untouched.
		catalyst_set_fullscreen(false);
#endif
		vc = [PreferencesViewController presentStartup];

		while (!vc.isDone) {
#if TARGET_OS_MACCATALYST
			// UIKit clicks aren't CFRunLoop sources on Catalyst, so a distantFuture
			// wait would never wake. Pump at 60Hz, like the emulator's pump.
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
		// Apply the launch Windowed/Full Screen choice. For full screen, run the
		// loop until the transition lands (max ~2s): once the emulator owns the
		// main thread, its NSEvent pump is too coarse to finish the animation.
		bool wantFullscreen = objc_findBool(@"catalystfullscreen");
		catalyst_set_fullscreen(wantFullscreen);
		for (int i = 0; wantFullscreen && i < 120 && !catalyst_front_window_is_fullscreen(); i++) {
			catalyst_pump_appkit_events();
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
									 beforeDate:[NSDate dateWithTimeIntervalSinceNow:(1.0 / 60.0)]];
		}
		// Enable sync for emulation. Its first tick seeds from the state just applied.
		s_fullscreen_sync_active = true;
#endif
	}
}

void objc_displayPreferencesDuringEmulationOnMain(void) {
	dispatch_sync(dispatch_get_main_queue(), ^{
		[LocalNotificationObjCProxy sendDisplayPreferencesRequested];
	});
}
