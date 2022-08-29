//
//  SSPreferencesHardwareViewController.h
//  SheepShaver_Xcode8
//
//  Created by Tom Padula on 7/20/22.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SSPreferencesHardwareViewController : UIViewController

@property (readwrite, nonatomic) IBOutlet UIStepper* ramStepper;
@property (readwrite, nonatomic) IBOutlet UILabel* ramSizeLabel;

@property (readwrite, nonatomic) IBOutlet UISwitch* useJITSwitch;
@property (readwrite, nonatomic) IBOutlet UISwitch* allowCPUIdleSwitch;
@property (readwrite, nonatomic) IBOutlet UISwitch* ignoreIllegalInstructionsSwitch;
@property (readwrite, nonatomic) IBOutlet UISwitch* ignoreIllegalMemorySwitch;
@property (readwrite, nonatomic) IBOutlet UISwitch* enable68kEmulatorSwitch;

- (IBAction)ramStepperHit:(id)sender;

- (IBAction)useJITSwitchHit:(id)sender;
- (IBAction)allowCPUIdleSwitchHit:(id)sender;
- (IBAction)ignoreIllegalInstructionsSwitchHit:(id)sender;
- (IBAction)ignoreIllegalMemorySwitchHit:(id)sender;
- (IBAction)enable68kEmulatorSwitchHit:(id)sender;

@end

NS_ASSUME_NONNULL_END
