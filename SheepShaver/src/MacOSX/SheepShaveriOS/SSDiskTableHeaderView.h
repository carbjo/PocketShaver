//
//  SSDiskTableHeaderView.h
//  SheepShaveriOS
//
//  Created by Tom Padula on 9/6/22.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SSDiskTableHeaderView : UIView

@property (readwrite, nonatomic) IBOutlet UILabel* diskNameLabel;
@property (readwrite, nonatomic) IBOutlet UILabel* enableLabel;
@property (readwrite, nonatomic) IBOutlet UILabel* isCDROMLabel;

@end

NS_ASSUME_NONNULL_END
