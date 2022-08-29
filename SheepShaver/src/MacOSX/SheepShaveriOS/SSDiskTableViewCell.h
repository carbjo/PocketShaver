//
//  SSDiskTableViewCell.h
//  SheepShaver_Xcode8
//
//  Created by Tom Padula on 7/22/22.
//

#import <UIKit/UIKit.h>

#import "SSPreferencesDisksViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface SSDiskTableViewCell : UITableViewCell

@property (readwrite, nonatomic) IBOutlet UILabel* diskNameLabel;
@property (readwrite, nonatomic) IBOutlet UISwitch* diskMountEnableSwitch;
@property (readwrite, nonatomic) IBOutlet UISwitch* diskBootEnableSwitch;

@property (readwrite, nonatomic) SSPreferencesDisksViewController* disksViewController;

- (IBAction)diskMountEnableSwitchHit:(id)sender;
- (IBAction)diskBootEnableSwitchHit:(id)sender;

@end

NS_ASSUME_NONNULL_END
