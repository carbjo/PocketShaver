//
//  main.m
//  SheepShaveriOS
//
//  Created by Tom Padula on 5/9/22.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

/* Include the SDL main definition header */
#include "my_sdl.h"
#include "utils_ios.h"

/* Expose Swift host-bridge observers (GfxAccelBackgroundLifecycleObserver,
 * DSpIdleTimerService) to this Obj-C++ translation unit via
 * the auto-generated Swift umbrella header. The observers' @objc
 * singleton classes become callable through the standard ObjC message
 * syntax after this import. */
#import "PocketShaver-Swift-ObjCHeader.h"


extern "C" int main_ios(int argc, char* argv[]);


/* UIScene life cycle adoption. Apps built with the iOS 27 SDK must adopt
 * scenes or UIKit refuses to launch them ("UIScene life cycle is required").
 * The bundled SDL2 has no scene support: its app delegate still drives launch
 * and it creates its UIWindow with -initWithFrame: and no windowScene, which
 * under the scene life cycle never reaches the screen. The legacy model
 * attached such windows to the app's implicit scene automatically; this
 * restores that. Every app-level UIWindow created with -initWithFrame: (SDL's
 * window, the preferences window, the fatal-error window, SDL message boxes)
 * is attached to the connected UIWindowScene as it is created, and any made
 * before the scene connected (or while it was disconnected) are attached when
 * it connects. Info.plist names PocketShaverSceneDelegate in
 * UIApplicationSceneManifest. */

static UIWindowScene *g_window_scene;
static NSHashTable<UIWindow *> *g_sceneless_windows;

// UIKit's private windows (keyboard, text effects, ...) manage their own scene.
static bool is_app_window(UIWindow *window)
{
	Class cls = [window class];
	return cls == [UIWindow class] ||
		[NSBundle bundleForClass:cls] != [NSBundle bundleForClass:[UIWindow class]];
}

static void adopt_window(UIWindow *window)
{
	if (!is_app_window(window) || window.windowScene == g_window_scene)
		return;
	if (g_window_scene)
		window.windowScene = g_window_scene;
	else
		[g_sceneless_windows addObject:window];
}

@implementation UIWindow (PocketShaverSceneAdoption)

// Swapped with -initWithFrame:, so this call runs the original implementation.
- (instancetype)initWithFrameAdoptingScene:(CGRect)frame
{
	self = [self initWithFrameAdoptingScene:frame];
	if (self && !self.windowScene)
		adopt_window(self);
	return self;
}

@end

static void install_window_scene_adoption(void)
{
	g_sceneless_windows = [NSHashTable weakObjectsHashTable];
	Class cls = [UIWindow class];
	Method original = class_getInstanceMethod(cls, @selector(initWithFrame:));
	Method adopting = class_getInstanceMethod(cls, @selector(initWithFrameAdoptingScene:));
	// UIWindow may inherit -initWithFrame: from UIView; never swap UIView's.
	if (class_addMethod(cls, @selector(initWithFrame:), method_getImplementation(adopting), method_getTypeEncoding(adopting)))
		class_replaceMethod(cls, @selector(initWithFrameAdoptingScene:), method_getImplementation(original), method_getTypeEncoding(original));
	else
		method_exchangeImplementations(original, adopting);
}

@interface PocketShaverSceneDelegate : UIResponder <UIWindowSceneDelegate>
@end

@implementation PocketShaverSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions
{
	if (![scene isKindOfClass:[UIWindowScene class]])
		return;
	g_window_scene = (UIWindowScene *)scene;
	for (UIWindow *window in g_sceneless_windows.allObjects)
		adopt_window(window);
	[g_sceneless_windows removeAllObjects];
	[self forwardURLContexts:connectionOptions.URLContexts];
}

- (void)sceneDidDisconnect:(UIScene *)scene
{
	if (scene != g_window_scene)
		return;
	g_window_scene = nil;
	// Keep the windows so a reconnected scene picks them back up.
	for (UIWindow *window in ((UIWindowScene *)scene).windows)
		if (is_app_window(window))
			[g_sceneless_windows addObject:window];
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts
{
	[self forwardURLContexts:URLContexts];
}

// URL opens now arrive at the scene; hand them to SDL's app delegate as before.
- (void)forwardURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts
{
	UIApplication *app = UIApplication.sharedApplication;
	id<UIApplicationDelegate> delegate = app.delegate;
	if (![delegate respondsToSelector:@selector(application:openURL:options:)])
		return;
	for (UIOpenURLContext *context in URLContexts)
		[delegate application:app openURL:context.URL options:@{}];
}

@end


// Because main is #defined as SDL_main, this function is actually SDL_main. This gets called from -[SDLUIKitDelegate postFinishLaunch].
int main(int argc, char * argv[]) {
	/* Diagnostic stdio capture: when PS_STDIO_FILE is set (Xcode scheme env
	 * or launchctl setenv), mirror stdout+stderr to that file so emulator
	 * printf/fprintf diagnostics survive launches without an attached
	 * console (LaunchServices `open`, tap-to-launch, resume relaunches). */
	if (const char *stdio_path = getenv("PS_STDIO_FILE")) {
		if (freopen(stdio_path, "a", stderr)) setvbuf(stderr, NULL, _IONBF, 0);
		if (freopen(stdio_path, "a", stdout)) setvbuf(stdout, NULL, _IOLBF, 0);
		fprintf(stderr, "--- PS_STDIO_FILE capture started ---\n");
	}
	/* Relocate app data from the legacy visible-home location
	 * (~/PocketShaver Home) into the app container's Data directory exactly
	 * once, before the emulator core (main_ios) or any Swift file access reads
	 * or creates anything. Idempotent; Catalyst-only. */
#if TARGET_OS_MACCATALYST
	pocketshaver_migrate_home_if_needed();
#endif
	/* Install background/foreground observer
	 * so gfxaccel_handle_background_enter / _foreground_enter run on the
	 * OS lifecycle transitions. Install here — SDL's UIKit delegate is
	 * about to enter its run loop and UIApplication notifications start
	 * firing from that point forward; installing before SDL_UIKitRunApp
	 * ensures the first didEnterBackground is never missed. */
	[GfxAccelBackgroundLifecycleObserver.shared install];

	/* Install memory-pressure observer. The notification arrives on the
	 * main thread; the C shim only marks an atomic pending-eviction flag.
	 * The next compositor SubmitFrame drains that request on the engine
	 * call path, keeping heap mutation off UIKit's notification callback. */
	[GfxAccelMemoryWarningObserver.shared install];

	/* Install DSp idle-timer
	 * observer. Observes UIApplication.didEnterBackground /
	 * willEnterForeground + the custom DSpHostBridge.activeFullscreenChanged
	 * notification; toggles UIApplication.shared.isIdleTimerDisabled on main
	 * thread. Must install BEFORE the first DSpContext_SetStateHandler
	 * Active transition fires (usually well after app launch, so
	 * install-at-startup is comfortable timing). */
	[DSpIdleTimerService.shared install];

	/* The window scene normally connects during UIApplicationMain's launch
	 * transaction, before SDL schedules this function. If it hasn't yet, pump
	 * briefly so the windows the emulator creates from here on are attached
	 * to it as they are created. */
	for (int i = 0; i < 500 && !g_window_scene; i++)
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
	if (!g_window_scene)
		fprintf(stderr, "main: no UIWindowScene connected after 5s; windows will attach when it does\n");

	return main_ios(argc, argv);		// This is in SS/Source/Unix/main_Unix.cpp
}

// This is where we turn off the #define of SDL_main. This function is our actual main(), which does here exactly
// what it would do in SDL_uikit_main.c, which cannot be linked in to a dynamic library such as a framework. (Well,
// it can, but main() can't be found when it's in a dynamic library, so the app will not have a main to link with.)
#ifndef SDL_MAIN_HANDLED
#ifdef main
#undef main
#endif

int
main(int argc, char *argv[])
{
	install_window_scene_adoption();
	return SDL_UIKitRunApp(argc, argv, SDL_main);
}
#endif /* !SDL_MAIN_HANDLED */
