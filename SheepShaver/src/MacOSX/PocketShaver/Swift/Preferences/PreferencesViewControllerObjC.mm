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
// Defined below in the Catalyst-only helper block; called from catalyst_pump_appkit_events
// (defined above that block), so forward-declare it here.
static void catalyst_detect_fullscreen_change(void);
static void catalyst_resize_window_for_guest(int guest_w, int guest_h);
// Defined in metal_compositor.mm — re-pins the compositor view (full-bounds vs title-bar-safe)
// on a full-screen change, and reports the windowed drawable's top inset (safe-area top).
extern "C" void MetalCompositorReapplyWindowPinning(void);
extern "C" double MetalCompositorWindowedContentInsetTop(void);
// Last guest resolution the window auto-resize saw; used to re-size the window when returning
// to windowed so no stray letterbox lingers.
static int s_last_guest_w = 0;
static int s_last_guest_h = 0;
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
	// After draining input, notice fullscreen changes made by any means and sync them.
	catalyst_detect_fullscreen_change();
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

// Toggle the app's AppKit window to match `enable`. State-idempotent: a no-op when the
// window is already in the desired state, so it never double-toggles and re-applying a
// state the window already holds is free. Used by the launch path and the live in-emulation
// toggle.
static void catalyst_set_fullscreen(bool enable) {
	id window = catalyst_front_window();
	if (!window) return;

	SEL toggleSel = sel_registerName("toggleFullScreen:");
	if (![window respondsToSelector:toggleSel]) return;

	if (catalyst_front_window_is_fullscreen() == enable) return;   // already in desired state

	if (enable) {
		// Make sure the window is allowed to go full screen. Catalyst windows carry
		// NSWindowCollectionBehaviorFullScreenPrimary (1 << 7) by default; assert it
		// defensively before toggling.
		SEL cbGet = sel_registerName("collectionBehavior");
		SEL cbSet = sel_registerName("setCollectionBehavior:");
		if ([window respondsToSelector:cbGet] && [window respondsToSelector:cbSet]) {
			NSUInteger behavior = ((NSUInteger (*)(id, SEL))objc_msgSend)(window, cbGet);
			((void (*)(id, SEL, NSUInteger))objc_msgSend)(window, cbSet, behavior | (1UL << 7));
		}
	}

	((void (*)(id, SEL, id))objc_msgSend)(window, toggleSel, nil);
}

// Poll-based detector for fullscreen changes made by ANY means: the green title-bar button,
// the View menu, Ctrl-Cmd-F, a Mission Control gesture, or our own toggle. Called from the
// ~60Hz AppKit pump, so it covers both the startup menu and emulation. It keys off the
// actual window-state transition (compared to a cached last-known value) rather than
// pref-vs-window: the fullscreen animation flips the styleMask asynchronously, so comparing
// pref-vs-window mid-animation could spuriously revert the pref while our own live setter is
// applying a change. Firing only on a real transition avoids that race and any feedback loop
// (the detector never toggles the window; it only records state and refreshes the UI).
// Two-way sync only runs DURING EMULATION (green button / View menu / ⌃⌘F). It stays off
// through the startup settings menu so that forcing the menu windowed — and applying the
// launch full-screen choice — is never mistaken for a user action that rewrites the pref.
static bool s_fullscreen_sync_active = false;

static void catalyst_detect_fullscreen_change(void) {
	if (!s_fullscreen_sync_active) return;
	static int lastKnown = -1;   // -1 = uninitialized
	bool isFull = catalyst_front_window_is_fullscreen();
	if (lastKnown == -1) { lastKnown = isFull ? 1 : 0; return; }   // seed, no action
	if ((isFull ? 1 : 0) == lastKnown) return;                    // no change
	lastKnown = isFull ? 1 : 0;

	// Re-apply the pin + letterbox colour for the new mode.
	MetalCompositorReapplyWindowPinning();
	// Returning to windowed: re-size the window to the guest so no stray letterbox lingers.
	if (!isFull && s_last_guest_w > 0 && s_last_guest_h > 0)
		catalyst_resize_window_for_guest(s_last_guest_w, s_last_guest_h);

	if (objc_findBool(@"catalystfullscreen") != isFull) {
		objc_replaceBool(@"catalystfullscreen", isFull);
		objc_savePrefs();   // persist so the next launch respects an externally-made change
	}
	// Refresh the Windowed/Full Screen control if the settings overlay is on screen.
	[LocalNotificationObjCProxy sendCatalystFullscreenStateChanged];
}

// Resize the emulation window to the guest resolution (windowed only). Runs the AppKit work
// on the main thread. One guest pixel maps to one point (an 800x600 guest -> an 800x600-point
// window, drawn crisply at the backing scale); if that would exceed the usable screen it scales
// down uniformly to fit. Full screen is left alone — the compositor already fits the guest there.
static void catalyst_resize_window_for_guest(int guest_w, int guest_h) {
	if (guest_w <= 0 || guest_h <= 0) return;
	s_last_guest_w = guest_w;   // remember for re-sizing on a return to windowed
	s_last_guest_h = guest_h;
	dispatch_async(dispatch_get_main_queue(), ^{
		id window = catalyst_front_window();
		if (!window) return;
		if (catalyst_front_window_is_fullscreen()) return;

		SEL setSizeSel = sel_registerName("setContentSize:");
		if (![window respondsToSelector:setSizeSel]) return;

		// The compositor view is pinned BELOW the title bar in windowed mode, so its drawable
		// area is the content height minus that top inset. Size the window so the DRAWABLE
		// matches the guest (1 guest px = 1 pt) by adding the inset back into the content
		// height — otherwise the guest aspect-fits the too-short area and shows thin left/right
		// letterbox bars. Prefer the compositor's exact safe-area top; fall back to the window's
		// title-bar height, then 28 pt.
		CGFloat titleBar = MetalCompositorWindowedContentInsetTop();
		if (titleBar <= 0.0) {
			titleBar = 28.0;
			SEL frameSel = sel_registerName("frame");
			SEL crffSel = sel_registerName("contentRectForFrameRect:");
			if ([window respondsToSelector:frameSel] && [window respondsToSelector:crffSel]) {
#if defined(__x86_64__)
				// 32-byte CGRect returns via hidden sret pointer on x86-64
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

		// Guest drawable target (points), scaled down to fit the usable screen if larger.
		CGFloat drawW = (CGFloat)guest_w;
		CGFloat drawH = (CGFloat)guest_h;

		// Fit into the usable screen area (excludes menu bar + Dock), leaving room for the
		// title bar. NSScreen.visibleFrame is an HFA of 4 CGFloats, returned in registers on
		// arm64 (plain objc_msgSend) but via hidden sret pointer on x86-64
		// (objc_msgSend_stret required — see catalyst_screen_top_inset).
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
				CGFloat maxH = vf.size.height - titleBar;   // drawable room; title bar reserved
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

		// Content = the guest drawable plus the title-bar strip above it, so the drawable ends
		// up exactly guest-sized and fills the window width with no side letterbox.
		CGSize size = CGSizeMake(drawW, drawH + titleBar);
		((void (*)(id, SEL, CGSize))objc_msgSend)(window, setSizeSel, size);

		SEL centerSel = sel_registerName("center");
		if ([window respondsToSelector:centerSel])
			((void (*)(id, SEL))objc_msgSend)(window, centerSel);
	});
}
#endif

// Swift-callable bridge (declared in PrefsObjC.h). Applies the Windowed/Full Screen choice
// to the live window during emulation. No-op off Mac Catalyst.
extern "C" void objc_set_catalyst_fullscreen(BOOL enable) {
#if TARGET_OS_MACCATALYST
	catalyst_set_fullscreen(enable);
#endif
}

// Exposed for the Metal compositor's window pinning (fill edge-to-edge vs respect the title
// bar). No-op → false off Mac Catalyst.
extern "C" bool catalyst_is_window_fullscreen(void) {
#if TARGET_OS_MACCATALYST
	return catalyst_front_window_is_fullscreen();
#else
	return false;
#endif
}

// C++-callable bridge (declared in PreferencesViewControllerObjCCppHeader.h). No-op off Catalyst.
void objc_resize_catalyst_window_for_guest(int guest_w, int guest_h) {
#if TARGET_OS_MACCATALYST
	catalyst_resize_window_for_guest(guest_w, guest_h);
#endif
}

__weak __typeof(PreferencesViewController) *vc;

void objc_displayPreferencesStartup(void) {
	@autoreleasepool {
#if TARGET_OS_MACCATALYST
		// Stop macOS from restoring this window to full screen on the NEXT launch, so the
		// startup menu comes up windowed with no animated exit-from-full-screen. Emulation
		// still enters full screen below when the pref asks for it.
		{
			id restoreWin = catalyst_front_window();
			SEL setRestorableSel = sel_registerName("setRestorable:");
			if (restoreWin && [restoreWin respondsToSelector:setRestorableSel])
				((void (*)(id, SEL, BOOL))objc_msgSend)(restoreWin, setRestorableSel, NO);
		}
		// The startup settings menu is ALWAYS a window, even if macOS restored the app to
		// full screen from a prior full-screen emulation session. Force windowed before the
		// menu; two-way sync is still inert here, so this never rewrites the pref.
		catalyst_set_fullscreen(false);
#endif
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
		// Honor the user's Windowed/Full Screen choice on launch (windowed skips the wait).
		bool wantFullscreen = objc_findBool(@"catalystfullscreen");
		catalyst_set_fullscreen(wantFullscreen);
		for (int i = 0; wantFullscreen && i < 120 && !catalyst_front_window_is_fullscreen(); i++) {
			catalyst_pump_appkit_events();
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
									 beforeDate:[NSDate dateWithTimeIntervalSinceNow:(1.0 / 60.0)]];
		}
		// Emulation is starting: enable two-way full-screen sync now. Its first tick seeds to
		// the state we just applied, so this programmatic change doesn't fire the detector.
		s_fullscreen_sync_active = true;
#endif
	}
}

void objc_displayPreferencesDuringEmulationOnMain(void) {
	dispatch_sync(dispatch_get_main_queue(), ^{
		[LocalNotificationObjCProxy sendDisplayPreferencesRequested];
	});
}
