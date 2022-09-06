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

- (IBAction)rateStepperHit:(id)sender;

@end

NS_ASSUME_NONNULL_END
