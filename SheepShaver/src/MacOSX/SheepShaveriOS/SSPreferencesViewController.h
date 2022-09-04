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
#import "SSPreferencesBootROMViewController.h"

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C"
#endif
bool SS_ShowiOSPreferences(void);

#ifdef __cplusplus
extern "C"
#endif
int SS_ChooseiOSBootRom(const char* inFileName);	// returns file descriptor or error

@interface SSPreferencesViewController : UIViewController

@property (readwrite, nonatomic) BOOL prefsDone;
@property (readwrite, nonatomic) BOOL showBootROMPaneInitially;
@property (readwrite, nonatomic) NSArray* bootROMCandidateFilePaths;

@property (readwrite, nonatomic) IBOutlet UISegmentedControl* paneSelector;
@property (readwrite, nonatomic) IBOutlet UIButton* doneButton;

@property (readwrite, nonatomic) IBOutlet UIView* scrollerContentView;
@property (readwrite, nonatomic) IBOutlet UIScrollView* paneScroller;

@property (readwrite, nonatomic) SSPreferencesHardwareViewController* hardwarePaneViewController;
@property (readwrite, nonatomic) SSPreferencesDisksViewController* disksPaneViewController;
@property (readwrite, nonatomic) SSPreferencesAVViewController* avPaneViewController;
@property (readwrite, nonatomic) SSPreferencesIOViewController* ioPaneViewController;
@property (readwrite, nonatomic) SSPreferencesBootROMViewController* bootROMPaneViewController;

+ (instancetype)sharedPreferencesViewController;

- (IBAction)paneSelectorHit:(id)sender;
- (IBAction)doneButtonHit:(id)sender;

@end

NS_ASSUME_NONNULL_END
