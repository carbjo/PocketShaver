//
//  SSPreferencesBootROMViewController.h
//  SheepShaveriOS
//
//  Created by Tom Padula on 8/29/22.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SSPreferencesBootROMViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>

@property (readwrite, nonatomic) IBOutlet UITableView* bootROMTable;

+ (NSArray*) romFilePaths;
+ (void) rescanForRomFiles;

@end

NS_ASSUME_NONNULL_END
