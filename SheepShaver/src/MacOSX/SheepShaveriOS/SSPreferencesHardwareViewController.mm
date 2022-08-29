//
//  SSPreferencesHardwareViewController.m
//  SheepShaver_Xcode8
//
//  Created by Tom Padula on 7/20/22.
//

#import "SSPreferencesHardwareViewController.h"

#define int32 int32_t
#import "prefs.h"

@interface SSPreferencesHardwareViewController ()

@property (readwrite, nonatomic) NSArray* ramValueArray;

@end

@implementation SSPreferencesHardwareViewController

- (void)_setUpRamUI
{
	self.ramValueArray = @[@(16), @(32), @(64), @(128), @(256)];
	
	self.ramStepper.maximumValue = self.ramValueArray.count - 1;
	
	int aRamSize = PrefsFindInt32("ramsize");
	if (aRamSize > 1024) {
		aRamSize >>= 20;
	}
	if (aRamSize < 24) {
		aRamSize = 16;
		self.ramStepper.value = 0;
	} else if (aRamSize < 48) {
		aRamSize = 32;
		self.ramStepper.value = 1;
	} else if (aRamSize < 96) {
		aRamSize = 64;
		self.ramStepper.value = 2;
	} else if (aRamSize < 132) {
		aRamSize = 128;
		self.ramStepper.value = 3;
	} else {
		aRamSize = 245;
		self.ramStepper.value = 4;
	}

	[self ramStepperHit:self.ramStepper];
}

- (void)_setUpCPUUI
{
	[self.ignoreIllegalMemorySwitch setOn:PrefsFindBool("ignoresegv")];
	[self.ignoreIllegalInstructionsSwitch setOn: PrefsFindBool("ignoreillegal") ];
	[self.allowCPUIdleSwitch setOn: PrefsFindBool("idlewait") ];
	[self.useJITSwitch setOn: PrefsFindBool("jit") ];
	[self.enable68kEmulatorSwitch setOn: PrefsFindBool("jit68k") ];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view from its nib.
	
	[self _setUpRamUI];
	[self _setUpCPUUI];
}

/*
#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
}
*/

- (IBAction)ramStepperHit:(id)sender
{
	NSNumber* aNewRamSize = [self.ramValueArray objectAtIndex:self.ramStepper.value];
	NSString* aNewRamSizeString = [NSString stringWithFormat:@"%@ MB", aNewRamSize];
	NSLog (@"ramStepperHit, %@", aNewRamSizeString);
	
	[self.ramSizeLabel setText:aNewRamSizeString];
	
	PrefsReplaceInt32("ramsize", [aNewRamSize intValue]);
}

- (IBAction)useJITSwitchHit:(id)sender
{
	PrefsReplaceBool("jit", self.useJITSwitch.isOn);
}

- (IBAction)allowCPUIdleSwitchHit:(id)sender
{
	PrefsReplaceBool("idlewait", self.allowCPUIdleSwitch.isOn);
}

- (IBAction)ignoreIllegalInstructionsSwitchHit:(id)sender
{
	PrefsReplaceBool("ignoreillegal", self.ignoreIllegalInstructionsSwitch.isOn);
}

- (IBAction)ignoreIllegalMemorySwitchHit:(id)sender
{
	PrefsReplaceBool("ignoresegv", self.ignoreIllegalMemorySwitch.isOn);
}

- (IBAction)enable68kEmulatorSwitchHit:(id)sender
{
	PrefsReplaceBool("jit68k", self.enable68kEmulatorSwitch.isOn);
}

@end
