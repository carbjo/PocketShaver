//
//  SSPreferencesViewController.m
//  SheepShaveriOS
//
//  Created by Tom Padula on 7/15/22.
//

#import "SSPreferencesViewController.h"

#import "UIView+SDCAutoLayout.h"

#include "SSGestureRecognizerManager.h"
#include "utils_ios.h"

#define int32 int32_t
#import "prefs.h"

#define DEBUG_PREFS 1

#if DEBUG_PREFS
#define NSLOG(...) NSLog(__VA_ARGS__)
#else
#define NSLOG(...)
#endif

SSPreferencesViewController* gPrefsController;
UIWindow* gPrefsWindow;

enum EPrefsPanes {
	EPrefsPanes_BootROM = 0,
	EPrefsPanes_Disks,
	EPrefsPanes_AV,
	EPrefsPanes_IO,
	EPrefsPanes_Hardware,
	
	EPrefsPanes_NumPrefsPanes		// always last
} EPrefsPanes;

UIWindow* prefsWindow()
{
	if (!gPrefsWindow) {
		gPrefsWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
//		NSLog (@"%s [UIScreen mainScreen].bounds: %@", __PRETTY_FUNCTION__, NSStringFromCGRect([UIScreen mainScreen].bounds));
//		gPrefsWindow.rootViewController = [UIViewController new];
	}
	return gPrefsWindow;
}

bool SS_ShowiOSPreferences(void)
{
	// This can be called multiple times, we will reuse the same window, root view controller, and prefs view controller.
	prefsWindow().windowLevel = UIWindowLevelNormal;
	[prefsWindow() makeKeyAndVisible];
	
	//[prefsWindow().rootViewController presentViewController:[SSPreferencesViewController sharedPreferencesViewController] animated:NO completion:nil];
	prefsWindow().rootViewController = [SSPreferencesViewController sharedPreferencesViewController];
	[SSPreferencesViewController sharedPreferencesViewController].prefsDone = NO;
	
	
	@autoreleasepool {
		/* Run the main event loop until the alert has finished */
		/* Note that this needs to be done on the main thread */
		while (![SSPreferencesViewController sharedPreferencesViewController].prefsDone) {
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
		}
	}

//	[prefsWindow().rootViewController dismissViewControllerAnimated:NO completion:nil];
	[[SSPreferencesViewController sharedPreferencesViewController] removeFromParentViewController];
	prefsWindow().rootViewController = nil;
	prefsWindow().hidden = YES;

	return true;
}

int SS_ShowBootROMChooser()
{
	[SSPreferencesViewController sharedPreferencesViewController].showBootROMPaneInitially = YES;

	SS_ShowiOSPreferences();
	
	int rom_fd = open(PrefsFindString("rom"), O_RDONLY);

	if (rom_fd < 0) {
		NSLOG (@"%s rom_fd < 0 after open(): %d, errno: %d, %s", __PRETTY_FUNCTION__, rom_fd, errno, strerror(errno));
		NSLOG (@" at path: %s", PrefsFindString("rom"));
	}

	return rom_fd;
}

void SS_ShowROMRequestAlert(BOOL* outTryAgain)
{
	UIAlertController* anAlert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"ROMRequestAlertTitle", nil) message:NSLocalizedString(@"ROMRequestAlertMessage", nil) preferredStyle:UIAlertControllerStyleAlert];
	
	BOOL __block anAlertDone = NO;
	[anAlert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Try again", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction* _Nonnull inAction) {
		if (outTryAgain) {
			*outTryAgain = YES;
		}
		anAlertDone = YES;
	}]];
	
	[anAlert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Quit", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction* _Nonnull inAction) {
		if (outTryAgain) {
			*outTryAgain = NO;
		}
		anAlertDone = YES;
	}]];
	
	prefsWindow().windowLevel = UIWindowLevelAlert;
	[prefsWindow() makeKeyAndVisible];
	
	if (!prefsWindow().rootViewController) {
		prefsWindow().rootViewController = [UIViewController new];
	}
	[prefsWindow().rootViewController presentViewController:anAlert animated:NO completion:nil];
	prefsWindow().hidden = NO;

	@autoreleasepool {
		/* Run the main event loop until the alert has finished */
		/* Note that this needs to be done on the main thread */
		while (!anAlertDone) {
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
		}
	}
	
	[prefsWindow().rootViewController dismissViewControllerAnimated:NO completion:nil];
	prefsWindow().hidden = YES;
	
	[prefsWindow().rootViewController removeFromParentViewController];
}

void SS_ShowROMLoadFailure(NSString* aROMName)
{
	NSString* aMessage = [NSString stringWithFormat:NSLocalizedString(@"ROMFailureAlertMessage", nil), aROMName];
	UIAlertController* anAlert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@"ROMFailureAlertTitle", nil) message:aMessage preferredStyle:UIAlertControllerStyleAlert];
	
	BOOL __block anAlertDone = NO;
	[anAlert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Quit", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction* _Nonnull inAction) {
		anAlertDone = YES;
	}]];
	
	prefsWindow().windowLevel = UIWindowLevelAlert;
	[prefsWindow() makeKeyAndVisible];
	
	if (!prefsWindow().rootViewController) {
		prefsWindow().rootViewController = [UIViewController new];
	}
	[prefsWindow().rootViewController presentViewController:anAlert animated:NO completion:nil];
	prefsWindow().hidden = NO;
	
	@autoreleasepool {
		/* Run the main event loop until the alert has finished */
		/* Note that this needs to be done on the main thread */
		while (!anAlertDone) {
			[[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
		}
	}
	
	[prefsWindow().rootViewController dismissViewControllerAnimated:NO completion:nil];
	prefsWindow().hidden = YES;

	[prefsWindow().rootViewController removeFromParentViewController];
}

// returns file descriptor or error
int SS_ChooseiOSBootRom(const char* inFileName)
{
	// First try the given file path. If that doesn't work, use "rom". If that doesn't work, see if we have any likely
	// ROM files at all. If none, ask the user to go get one (and quit). If exactly one, use it and continue booting. If more than
	// one, ask the user to choose.
	
	// Ah one...
	int rom_fd = -1;
	if (inFileName && *inFileName) {
		rom_fd = open(inFileName, O_RDONLY);
		if (rom_fd >= 0) {
			PrefsReplaceString("rom", inFileName, 0);		// 0 == first string found
		}
	}
	
	// And ah two...
	if ((rom_fd < 0) ) {
		// See if the current pref is valid, if so, use that.
		rom_fd = open(PrefsFindString("rom"), O_RDONLY);
	}

	// And ah three...
	if ([[SSPreferencesBootROMViewController romFilePaths] count] == 1) {
		NSString* aSelectedPath = [[SSPreferencesBootROMViewController romFilePaths] firstObject];
		PrefsReplaceString("rom", [aSelectedPath UTF8String], 0);		// 0 == first string found
		rom_fd = open(PrefsFindString("rom"), O_RDONLY);				// update the "rom" choice since it was clearly wrong
	}
	
	// Automatic search for the ROM file didn't work. Ask the user what to do.
	if (rom_fd < 0) {
		BOOL aTryAgain = NO;
		do {
			// See if we have any viable rom files. If it turns out we have exactly one, use it.
			if ([[SSPreferencesBootROMViewController romFilePaths] count] == 0) {
				// Put up an alert that there are no viable ROM files, please go get one. If the user chooses not to
				// try again, we will still have a bad rom_fd, and so we will exit.
				NSLOG (@"%s rom_fd < 0 after open(): %d, errno: %d, %s", __PRETTY_FUNCTION__, rom_fd, errno, strerror(errno));
				SS_ShowROMRequestAlert(&aTryAgain);
				if (aTryAgain) {
					[SSPreferencesBootROMViewController rescanForRomFiles];
				}
			} else if ([[SSPreferencesBootROMViewController romFilePaths] count] == 1) {
				NSString* aSelectedPath = [[SSPreferencesBootROMViewController romFilePaths] firstObject];
				PrefsReplaceString("rom", [aSelectedPath UTF8String], 0);		// 0 == first string found
				rom_fd = open(PrefsFindString("rom"), O_RDONLY);				// update the "rom" choice since it was clearly wrong
				aTryAgain = NO;
			} else if ([[SSPreferencesBootROMViewController romFilePaths] count] > 1) {
				// More than one viable file, and the "rom" choice wasn't among them. Ask the user to choose a ROM file.
				rom_fd = SS_ShowBootROMChooser();
				aTryAgain = NO;
			}
		} while (aTryAgain && (rom_fd < 0));
		
		return rom_fd;
	}
	
	// The choice for ROM file could not be opened for whatever reason. Tell the user what happened and bail.
	if (rom_fd < 0) {
		NSString* aROMName = [NSString stringWithCString:PrefsFindString("rom") encoding:NSUTF8StringEncoding];
		if (([aROMName length] == 0) && (inFileName)) {
			aROMName = [NSString stringWithCString:inFileName encoding:NSUTF8StringEncoding];
		}
		SS_ShowROMLoadFailure(aROMName);
	}
	
	return rom_fd;
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
	self.bootROMPaneViewController = [[SSPreferencesBootROMViewController alloc] initWithNibName:@"SSPreferencesBootROMViewController" bundle:[NSBundle mainBundle]];

	self.paneScroller.layer.borderWidth = 1;
	self.paneScroller.layer.borderColor = [UIColor lightGrayColor].CGColor;
	self.paneScroller.layer.cornerRadius = 4;

	for (UIView* aSubView in [self.scrollerContentView subviews]) {
		[aSubView removeFromSuperview];
	}

	NSLOG (@"paneScroller: %@", self.paneScroller);

	// Start with the hardware view unless we are to go directly to the boot ROM view. This looks fine on launch with
	// either orientation, though the hardware view for some reason is much too tall.
	if (self.showBootROMPaneInitially) {
		[self.paneSelector setSelectedSegmentIndex:EPrefsPanes_BootROM];
	} else {
		[self.paneSelector setSelectedSegmentIndex:EPrefsPanes_Hardware];
	}
	[self paneSelectorHit:self.paneSelector];
	
	self.showBootROMPaneInitially = NO;
	
//	CGFloat aHeight = [self.hardwarePaneViewController.view lowestSubviewY];
//	NSLog (@"Lowest point of %@: %f", self.hardwarePaneViewController.view, aHeight);
//	[self.hardwarePaneViewController.view sdc_pinHeight:aHeight];
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
		case EPrefsPanes_BootROM:
			[self.scrollerContentView addSubview:self.bootROMPaneViewController.view];
			[self.bootROMPaneViewController.view sdc_alignEdgesWithSuperview:aRectEdges insets:aOnePixelInsets];
			//			[self.bootROMPaneViewController.view sdc_horizontallyCenterInSuperview];
			[self.paneScroller setContentSize:self.bootROMPaneViewController.view.frame.size];
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
	// Still need a pref for this and for cdrom:
	while (PrefsFindString("disk") != 0) {
		PrefsRemoveItem("disk");
	}
	PrefsReplaceString("disk", "MacOS9.dsk");
	
	// There are no options for screen dimensions, SDL can only do fullscreen on iOS and cannot handle rotation, so
	// whatever the current dimensions are will be the ones we always use for this launch. If the device is rotated
	// to landscape, then SS will launch in landscape.
	int aWidth = [UIScreen mainScreen].bounds.size.width;
	int aHeight = [UIScreen mainScreen].bounds.size.height;
	char aScreenString[256];
	sprintf(aScreenString, "dga/%d/%d", aWidth, aHeight);
	PrefsReplaceString("screen", aScreenString);
	
	// These don't do anything when screen scale is 1:1.
//	PrefsReplaceBool("scale_nearest", true);
//	PrefsReplaceBool("scale_integer", true);

	// These will always be constant for iOS.
	PrefsReplaceString("sdlrender", "metal");
	PrefsReplaceString("extfs",document_directory());

	// We have prefs for these now.
	//	PrefsReplaceInt32("frameskip", 1);		// 1 == 60 Hz, 0 == as fast as possible, which burns up CPU and makes the OS grumpy.
	//	PrefsReplaceInt32("ramsize", 64 * 1024 * 1024);

	SavePrefs();
	self.prefsDone = YES;
	
	NSLog (@"%s", __PRETTY_FUNCTION__);
	
	[self _initGestures];
}

// This is hit when we start to scroll the view off the screen.
- (void) viewWillDisappear:(BOOL)animated
{
	[super viewWillDisappear:animated];
	NSLOG (@"%s", __PRETTY_FUNCTION__);
}

- (void) viewDidDisappear:(BOOL)animated
{
	[super viewDidDisappear:animated];
	NSLOG (@"%s", __PRETTY_FUNCTION__);
}

// This does not stop view from being scrolled away.
- (BOOL) shouldPerformSegueWithIdentifier:(NSString *)identifier sender:(id)sender
{
	NSLOG (@"%s", __PRETTY_FUNCTION__);
	return NO;
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
