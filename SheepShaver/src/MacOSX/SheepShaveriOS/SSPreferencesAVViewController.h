//
//  SSPreferencesAVViewController.h
//  SheepShaver_Xcode8
//
//  Created by Tom Padula on 7/21/22.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SSPreferencesAVViewController : UIViewController

@property (readwrite, nonatomic) IBOutlet UIStepper* rateStepper;
@property (readwrite, nonatomic) IBOutlet UILabel* rateLabel;
@property (readwrite, nonatomic) IBOutlet UISwitch* audioDisableSwitch;

- (IBAction)rateStepperHit:(id)sender;
- (IBAction)audioDisableSwitchHit:(id)sender;

@end

NS_ASSUME_NONNULL_END
