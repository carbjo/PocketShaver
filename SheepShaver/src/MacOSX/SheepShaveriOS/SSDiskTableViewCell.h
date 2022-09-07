//
//  SSDiskTableViewCell.h
//  SheepShaver_Xcode8
//
//  Created by Tom Padula on 7/22/22.
//

#import <UIKit/UIKit.h>

#import "SSPreferencesDisksViewController.h"

NS_ASSUME_NONNULL_BEGIN

// This class has no apparent connection to the class of the same name in IB, nor to the class registered
// in our table view. It inits as if from zero, not from a nib at all.
@interface SSDiskTableViewCell : UITableViewCell

@property (readwrite, nonatomic, strong) IBOutlet UILabel* diskNameLabel;
@property (readwrite, nonatomic, strong) IBOutlet UISwitch* isCDROMSwitch;
@property (readwrite, nonatomic, strong) IBOutlet UISwitch* diskMountEnableSwitch;

@property (readwrite, nonatomic) SSPreferencesDisksViewController* disksViewController;

- (IBAction)diskMountEnableSwitchHit:(id)sender;
- (IBAction)isCDROMSwitchHit:(id)sender;

@end

NS_ASSUME_NONNULL_END
