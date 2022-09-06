//
//  SSPreferencesAVViewController.m
//  SheepShaver_Xcode8
//
//  Created by Tom Padula on 7/21/22.
//

#import "SSPreferencesAVViewController.h"

#define int32 int32_t
#import "prefs.h"

#define DEBUG_AV_PREFS 1

#if DEBUG_AV_PREFS
#define NSLOG(...) NSLog(__VA_ARGS__)
#else
#define NSLOG(...)
#endif

@interface SSPreferencesAVViewController ()

@property (readwrite, nonatomic) NSArray* rateValueArray;
@property (readwrite, nonatomic) NSArray* frameSkipValueArray;

@end

@implementation SSPreferencesAVViewController

-(void) _setUpRateUI
{
	self.rateValueArray = @[@(5), @(7.5), @(10), @(15), @(30), @(60)];
	self.frameSkipValueArray = @[@(12), @(8), @(6), @(4), @(2), @(1)];

	self.rateStepper.maximumValue = self.rateValueArray.count - 1;
	
	int aFrameSkip = PrefsFindInt32("frameskip");
	NSLOG (@"%s read frameskip: %d", __PRETTY_FUNCTION__, aFrameSkip);
	if (aFrameSkip > [[self.frameSkipValueArray firstObject] intValue]) {
		aFrameSkip = [[self.frameSkipValueArray firstObject] intValue];
	}
	if (aFrameSkip < [[self.frameSkipValueArray lastObject] intValue]) {
		aFrameSkip = [[self.frameSkipValueArray lastObject] intValue];
	}
	
	NSNumber* aRateValue = @(0);
	int anIndex = 0;
	for (; anIndex < self.frameSkipValueArray.count; anIndex++) {
		NSNumber* aFrameSkipElement = self.frameSkipValueArray [anIndex];
		if (aFrameSkip >= [aFrameSkipElement intValue]) {
			aRateValue = self.rateValueArray[anIndex];			// found it.
			break;
		}
	}
	if (([aRateValue intValue] == 0) || (anIndex >= self.frameSkipValueArray.count)) {		// didn't find it?
		aRateValue = self.rateValueArray.lastObject;		// Use 60 Hz
		anIndex = (int)self.rateValueArray.count - 1;
	}
	PrefsReplaceInt32("frameskip", [self.frameSkipValueArray[anIndex] intValue]);
	self.rateStepper.value = anIndex;

	[self rateStepperHit:self.rateStepper];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view from its nib.
	
	[self _setUpRateUI];
}

- (void) rateStepperHit:(id)sender
{
	NSNumber* aNewRate = [self.rateValueArray objectAtIndex:self.rateStepper.value];
	NSString* aNewRateString = [NSString stringWithFormat:@"%@ Hz", aNewRate];
	NSLOG (@"rateStepperHit, %@", aNewRateString);
	
	[self.rateLabel setText:aNewRateString];
	
	int aFrameSkip = [[self.frameSkipValueArray objectAtIndex:self.rateStepper.value] intValue];
	PrefsReplaceInt32("frameskip", aFrameSkip);
	
	NSLOG (@"%s wrote frameskip: %d", __PRETTY_FUNCTION__, aFrameSkip);
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
