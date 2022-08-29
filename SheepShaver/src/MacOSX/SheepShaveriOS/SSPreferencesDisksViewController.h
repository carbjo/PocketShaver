//
//  SSPreferencesDisksViewController.h
//  SheepShaver_Xcode8
//
//  Created by Tom Padula on 7/21/22.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SSPreferencesDisksViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>

@property (readwrite, nonatomic) IBOutlet UITableView* diskTable;

@end

NS_ASSUME_NONNULL_END
