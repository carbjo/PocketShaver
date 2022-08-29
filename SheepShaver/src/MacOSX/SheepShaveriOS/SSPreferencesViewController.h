//
//  SSPreferencesViewController.h
//  SheepShaveriOS
//
//  Created by Tom Padula on 7/15/22.
//

#import <UIKit/UIKit.h>

#import "SSPreferencesHardwareViewController.h"
#import "SSPreferencesDisksViewController.h"
#import "SSPreferencesAVViewController.h"
#import "SSPreferencesIOViewController.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C"
#endif
bool SS_ShowiOSPreferences(void);

@interface SSPreferencesViewController : UIViewController

@property (readwrite, nonatomic) BOOL prefsDone;

@property (readwrite, nonatomic) IBOutlet UISegmentedControl* paneSelector;
@property (readwrite, nonatomic) IBOutlet UIButton* doneButton;

@property (readwrite, nonatomic) IBOutlet UIView* scrollerContentView;
@property (readwrite, nonatomic) IBOutlet UIScrollView* paneScroller;

@property (readwrite, nonatomic) SSPreferencesHardwareViewController* hardwarePaneViewController;
@property (readwrite, nonatomic) SSPreferencesDisksViewController* disksPaneViewController;
@property (readwrite, nonatomic) SSPreferencesAVViewController* avPaneViewController;
@property (readwrite, nonatomic) SSPreferencesIOViewController* ioPaneViewController;

+ (instancetype)sharedPreferencesViewController;

- (IBAction)paneSelectorHit:(id)sender;
- (IBAction)doneButtonHit:(id)sender;

@end

NS_ASSUME_NONNULL_END
