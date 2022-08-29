//
//  SSPreferencesViewController.m
//  SheepShaveriOS
//
//  Created by Tom Padula on 7/15/22.
//

#import "SSPreferencesViewController.h"

#import "UIView+SDCAutoLayout.h"

#include "SSGestureRecognizerManager.h"

#define int32 int32_t
#import "prefs.h"

SSPreferencesViewController* gPrefsController;
UIWindow* gPrefsWindow;

enum EPrefsPanes {
	EPrefsPanes_Hardware = 0,
	EPrefsPanes_Disks,
	EPrefsPanes_AV,
	EPrefsPanes_IO
} EPrefsPanes;

UIWindow* prefsWindow()
{
	if (!gPrefsWindow) {
		gPrefsWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
		NSLog (@"%s [UIScreen mainScreen].bounds: %@", __PRETTY_FUNCTION__, NSStringFromCGRect([UIScreen mainScreen].bounds));
		gPrefsWindow.rootViewController = [UIViewController new];
	}
	return gPrefsWindow;
}

bool SS_ShowiOSPreferences(void)
{
	// This can be called multiple times, we will reuse the same window, root view controller, and prefs view controller.
	prefsWindow().windowLevel = UIWindowLevelAlert;
	[prefsWindow() makeKeyAndVisible];
	
	[prefsWindow().rootViewController presentViewController:[SSPreferencesViewController sharedPreferencesViewController] animated:NO completion:nil];
	[SSPreferencesViewController sharedPreferencesViewController].prefsDone = NO;
	
	@autoreleasepool {
		/* Run the main event loop until the alert has finished */
		/* Note that this needs to be done on the main thread */
		while (![SSPreferencesViewController sharedPreferencesViewController].prefsDone) {
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
		}
	}

	[prefsWindow().rootViewController dismissViewControllerAnimated:NO completion:nil];
	prefsWindow().hidden = YES;

	return true;
}

@interface UIView (subviews)
- (UIView*) lowestSubview;		// recursively finds the view with the greatest origin.y + size.height. Can return nil if there are no subviews.
- (CGFloat) lowestSubviewY;		// Returns the Y location of the lowest edge of the lowest subview, if there is one. Otherwise returns lowest point of self.
@end

@implementation UIView (subviews)
- (UIView*) lowestSubview
{
	UIView* aLowest = nil;
	for (UIView* aView in self.subviews) {
		if (!aLowest) {
			aLowest = aView;
		} else {
			if ((aView.frame.origin.y + aView.frame.size.height) > (aLowest.frame.origin.y + aLowest.frame.size.height)) {
				aLowest = aView;
			}
		}
	}
	return aLowest;
}

- (CGFloat) lowestSubviewY
{
	UIView* aLowestSubview = [self lowestSubview];
	if (aLowestSubview) {
		return aLowestSubview.frame.origin.y + aLowestSubview.frame.size.height;
	}
	
	return self.frame.origin.y + self.frame.size.height;
}

@end

@interface SSPreferencesViewController ()

@end

@implementation SSPreferencesViewController

+ (instancetype)sharedPreferencesViewController
{
	if (!gPrefsController) {
		gPrefsController = [[SSPreferencesViewController alloc] initWithNibName:@"SSPreferencesViewController" bundle:[NSBundle mainBundle]];
	}
	return gPrefsController;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view from its nib.
	self.prefsDone = NO;
	
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_didRotate:) name:UIDeviceOrientationDidChangeNotification object:nil];
//	NSArray* aDirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
//	NSLog (@"Document dirs:\n%@", aDirs);
	
	// Create the view panes.
	self.hardwarePaneViewController = [[SSPreferencesHardwareViewController alloc] initWithNibName:@"SSPreferencesHardwareViewController" bundle:[NSBundle mainBundle]];
	self.disksPaneViewController = [[SSPreferencesDisksViewController alloc] initWithNibName:@"SSPreferencesDisksViewController" bundle:[NSBundle mainBundle]];
	self.avPaneViewController = [[SSPreferencesAVViewController alloc] initWithNibName:@"SSPreferencesAVViewController" bundle:[NSBundle mainBundle]];
	self.ioPaneViewController = [[SSPreferencesIOViewController alloc] initWithNibName:@"SSPreferencesIOViewController" bundle:[NSBundle mainBundle]];
		
	self.paneScroller.layer.borderWidth = 1;
	self.paneScroller.layer.borderColor = [UIColor lightGrayColor].CGColor;
	self.paneScroller.layer.cornerRadius = 4;

	// Start with the hardware view. This looks fine on launch with either orientation, though the hardware view for
	// some reason is much too tall.
	for (UIView* aSubView in [self.scrollerContentView subviews]) {
		[aSubView removeFromSuperview];
	}

	NSLog (@"paneScroller: %@", self.paneScroller);
	[self.scrollerContentView addSubview:self.hardwarePaneViewController.view];
	[self.hardwarePaneViewController.view sdc_alignEdgesWithSuperview:UIRectEdgeLeft + UIRectEdgeRight insets:UIEdgeInsetsMake(1, 1, 0, 0)];
//	CGFloat aHeight = [self.hardwarePaneViewController.view lowestSubviewY];
//	NSLog (@"Lowest point of %@: %f", self.hardwarePaneViewController.view, aHeight);
//	[self.hardwarePaneViewController.view sdc_pinHeight:aHeight];
	
	[self.paneScroller setContentSize:self.hardwarePaneViewController.view.frame.size];
}

-(void)viewDidAppear:(BOOL)animated
{
	self.prefsDone = NO;
}

- (void) _didRotate:(NSNotification*)inNotification
{
	[self.view setNeedsLayout];
	[self.view setNeedsDisplay];
}

- (IBAction)paneSelectorHit:(id)sender
{
	//NSLog (@"Selected segment: %ld, %@", (long)self.paneSelector.selectedSegmentIndex, [self.paneSelector titleForSegmentAtIndex:self.paneSelector.selectedSegmentIndex]);
	for (UIView* aSubView in [self.scrollerContentView subviews]) {
		[aSubView removeFromSuperview];
	}
	
	UIEdgeInsets aOnePixelInsets = UIEdgeInsetsMake(1, 1, 0, 0);
	UIRectEdge aRectEdges = UIRectEdgeAll;//UIRectEdgeTop + UIRectEdgeBottom;
	
	// These successfully switch subviews, but the edges of the views don't get set properly. The IO, AV, and Disks should be
	// centered when the bounds are set, but the size isn't changed for whatever reason.
	switch (self.paneSelector.selectedSegmentIndex) {
		case EPrefsPanes_Hardware:
			[self.scrollerContentView addSubview:self.hardwarePaneViewController.view];
			[self.hardwarePaneViewController.view sdc_alignEdgesWithSuperview:aRectEdges insets:aOnePixelInsets];
//			[self.hardwarePaneViewController.view sdc_horizontallyCenterInSuperview];
			[self.paneScroller setContentSize:self.hardwarePaneViewController.view.frame.size];
			break;
		case EPrefsPanes_Disks:
			[self.scrollerContentView addSubview:self.disksPaneViewController.view];
			[self.disksPaneViewController.view sdc_alignEdgesWithSuperview:aRectEdges insets:aOnePixelInsets];
//			[self.disksPaneViewController.view sdc_horizontallyCenterInSuperview];
			[self.paneScroller setContentSize:self.disksPaneViewController.view.frame.size];
			break;
		case EPrefsPanes_AV:
			[self.scrollerContentView addSubview:self.avPaneViewController.view];
			[self.avPaneViewController.view sdc_alignEdgesWithSuperview:aRectEdges insets:aOnePixelInsets];
//			[self.avPaneViewController.view sdc_horizontallyCenterInSuperview];
			[self.paneScroller setContentSize:self.avPaneViewController.view.frame.size];
			break;
		case EPrefsPanes_IO:
			[self.scrollerContentView addSubview:self.ioPaneViewController.view];
			[self.ioPaneViewController.view sdc_alignEdgesWithSuperview:aRectEdges insets:aOnePixelInsets];
//			[self.ioPaneViewController.view sdc_horizontallyCenterInSuperview];
			[self.paneScroller setContentSize:self.ioPaneViewController.view.frame.size];
			break;
		default:
			break;
	}
	
	[self.view setNeedsLayout];
	[self.view setNeedsDisplay];
}

- (void) _initGestures
{
	[SSGestureRecognizerManager initGestureRecognizers];
}

- (IBAction)doneButtonHit:(id)sender
{
	while (PrefsFindString("disk") != 0) {
		PrefsRemoveItem("disk");
	}
//	PrefsReplaceInt32("ramsize", 64 * 1024 * 1024);
	PrefsReplaceString("disk", "MacOS9.dsk");
	PrefsReplaceInt32("frameskip", 0);
	
	int aWidth = [UIScreen mainScreen].bounds.size.width;
	int aHeight = [UIScreen mainScreen].bounds.size.height;
	char aScreenString[256];
	sprintf(aScreenString, "dga/%d/%d", aWidth, aHeight);
	PrefsReplaceString("screen", aScreenString);
//	PrefsReplaceString("screen", "dga/1024/768");			// on iOS, dga is all that matters here, it causes the app to be full screen with no status bar.
//	PrefsReplaceBool("scale_nearest", true);
//	PrefsReplaceBool("scale_integer", true);
//	PrefsReplaceBool("sdl_vsync", true);
	PrefsReplaceString("sdlrender", "metal");
	SavePrefs();
	self.prefsDone = YES;
	
	NSLog (@"%s", __PRETTY_FUNCTION__);
	
	[self _initGestures];
}

/*
#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
}
*/

@end
