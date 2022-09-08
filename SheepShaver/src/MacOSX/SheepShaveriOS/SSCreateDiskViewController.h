//
//  SSCreateDiskViewController.h
//  SheepShaveriOS
//
//  Created by Tom Padula on 9/7/22.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class SSPreferencesDisksViewController;

@interface SSCreateDiskViewController : UIViewController <UITextFieldDelegate>

@property (readwrite, nonatomic) SSPreferencesDisksViewController* _Nullable disksViewController;

@property (readwrite, nonatomic) IBOutlet UITextField* sizeField;
@property (readwrite, nonatomic) IBOutlet UITextField* nameField;
@property (readwrite, nonatomic) IBOutlet UIButton* cancelButton;
@property (readwrite, nonatomic) IBOutlet UIButton* createButton;

- (IBAction)sizeFieldHit:(id)sender;
- (IBAction)nameFieldHit:(id)sender;
- (IBAction)cancelButtonHit:(id)sender;
- (IBAction)createButtonHit:(id)sender;

@end

NS_ASSUME_NONNULL_END
