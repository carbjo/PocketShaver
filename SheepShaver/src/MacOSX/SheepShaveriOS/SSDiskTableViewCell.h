//
//  SSDiskTableViewCell.h
//  SheepShaver_Xcode8
//
//  Created by Tom Padula on 7/22/22.
//

#import <UIKit/UIKit.h>

#import "SSPreferencesDisksViewController.h"

#import "DiskTypeiOS.h"

NS_ASSUME_NONNULL_BEGIN

// This class has no apparent connection to the class of the same name in IB, nor to the class registered
// in our table view. It inits as if from zero, not from a nib at all.
@interface SSDiskTableViewCell : UITableViewCell

@property (readwrite, nonatomic)  IBOutlet UILabel* _Nullable diskNameLabel;
@property (readwrite, nonatomic)  IBOutlet UISwitch* _Nullable isCDROMSwitch;
@property (readwrite, nonatomic)  IBOutlet UISwitch* _Nullable diskMountEnableSwitch;

@property (readwrite, nonatomic) SSPreferencesDisksViewController* _Nullable disksViewController;
@property (readwrite, nonatomic) DiskTypeiOS* _Nullable disk;

- (IBAction)diskMountEnableSwitchHit:(UISwitch*)sender;
- (IBAction)isCDROMSwitchHit:(UISwitch*)sender;

@end

NS_ASSUME_NONNULL_END
