//
//  SSPreferencesIOViewController.h
//  SheepShaver_Xcode8
//
//  Created by Tom Padula on 7/21/22.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SSPreferencesIOViewController : UIViewController

@property (readwrite, nonatomic) IBOutlet UISwitch* useiPadMousePassthroughSwitch;
@property (readwrite, nonatomic) IBOutlet UISwitch* anotherSwitch;

- (IBAction)useiPadMousePassthroughSwitchHit:(id)sender;
- (IBAction)anotherSwitchHit:(id)sender;

@end

NS_ASSUME_NONNULL_END
