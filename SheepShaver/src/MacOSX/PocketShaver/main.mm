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

#import "PocketShaver-Swift-ObjCHeader.h"


extern "C" int main_ios(int argc, char* argv[]);


/* UIScene adoption. The iOS 27 SDK requires the scene life cycle, but the
 * bundled SDL2 creates its UIWindow with -initWithFrame: and no windowScene,
 * so it never reaches the screen. Every app-level window created that way is
 * attached to the connected UIWindowScene, or queued until one connects.
 * Info.plist names PocketShaverSceneDelegate in UIApplicationSceneManifest. */

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
	if (!is_app_window(window))
		return;
	// Queue first: two nil scenes do not mean the window is attached.
	if (!g_window_scene)
		[g_sceneless_windows addObject:window];
	else if (window.windowScene != g_window_scene)
		window.windowScene = g_window_scene;
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

// URL opens arrive at the scene; forward them to SDL's app delegate.
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
	/* If PS_STDIO_FILE is set, redirect stdout and stderr to that file so
	 * diagnostics survive launches without an attached console. */
	if (const char *stdio_path = getenv("PS_STDIO_FILE")) {
		if (freopen(stdio_path, "a", stderr)) setvbuf(stderr, NULL, _IONBF, 0);
		if (freopen(stdio_path, "a", stdout)) setvbuf(stdout, NULL, _IOLBF, 0);
		fprintf(stderr, "--- PS_STDIO_FILE capture started ---\n");
	}
	/* Must run before the emulator core or Swift touches any files. */
#if TARGET_OS_MACCATALYST
	pocketshaver_migrate_home_if_needed();
#endif
	/* Install before SDL's run loop starts so the first didEnterBackground
	 * isn't missed. */
	[GfxAccelBackgroundLifecycleObserver.shared install];

	/* The C shim only flags an eviction; the next SubmitFrame performs it. */
	[GfxAccelMemoryWarningObserver.shared install];

	/* Must be installed before the first DSp context goes active. */
	[DSpIdleTimerService.shared install];

	/* The scene normally connects before SDL calls this. If not, pump briefly
	 * so the emulator's windows can attach as they are created. */
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
