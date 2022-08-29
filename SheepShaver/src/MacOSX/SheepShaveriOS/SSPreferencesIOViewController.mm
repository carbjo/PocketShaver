//
//  SSPreferencesIOViewController.m
//  SheepShaver_Xcode8
//
//  Created by Tom Padula on 7/21/22.
//

#import "SSPreferencesIOViewController.h"

#define int32 int32_t
#import "prefs.h"

#import "SDL_hints.h"

#ifndef SDL_HINT_IOS_IPAD_MOUSE_PASSTHROUGH
#define SDL_HINT_IOS_IPAD_MOUSE_PASSTHROUGH "SDL_HINT_IOS_IPAD_MOUSE_PASSTHROUGH"
#endif

@interface SSPreferencesIOViewController ()

@end

@implementation SSPreferencesIOViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view from its nib.
	
	[self _setUpUI];
}

- (void)_setUpUI
{
	UIUserInterfaceIdiom anIdiom = [UIDevice currentDevice].userInterfaceIdiom;
	if (anIdiom == UIUserInterfaceIdiomPhone) {
		// Disable the iPad-only mouse passthrough switch.
		[self.useiPadMousePassthroughSwitch setOn:NO];
		[self.useiPadMousePassthroughSwitch setEnabled:NO];
	} else {
		[self.useiPadMousePassthroughSwitch setOn:PrefsFindBool("ipadmousepassthrough")];
		SDL_SetHint(SDL_HINT_IOS_IPAD_MOUSE_PASSTHROUGH, (self.useiPadMousePassthroughSwitch.isOn ? "1" : "0"));
	}
}

/*
#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
}
*/

- (IBAction)useiPadMousePassthroughSwitchHit:(id)sender
{
	PrefsReplaceBool("ipadmousepassthrough", self.useiPadMousePassthroughSwitch.isOn);
	SDL_SetHint(SDL_HINT_IOS_IPAD_MOUSE_PASSTHROUGH, (self.useiPadMousePassthroughSwitch.isOn ? "1" : "0"));
	
	NSLog (@"%s Passthrough on: %@", __PRETTY_FUNCTION__, (self.useiPadMousePassthroughSwitch.isOn ? @"YES" : @"NO"));
}

- (IBAction)anotherSwitchHit:(id)sender
{
	NSLog (@"%s switch on: %@", __PRETTY_FUNCTION__, (self.anotherSwitch.isOn ? @"YES" : @"NO"));
}
@end
