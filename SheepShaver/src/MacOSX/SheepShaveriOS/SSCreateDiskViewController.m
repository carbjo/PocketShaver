//
//  SSCreateDiskViewController.m
//  SheepShaveriOS
//
//  Created by Tom Padula on 9/7/22.
//

#import "SSCreateDiskViewController.h"

#import "SSPreferencesDisksViewController.h"

#define DEBUG_CREATEDISK 0

#if DEBUG_CREATEDISK
#define NSLOG(...) NSLog(__VA_ARGS__)
#else
#define NSLOG(...)
#endif

@interface SSPreferencesDisksViewController (createDisk)

- (void) _createDiskWithName:(NSString*)inName size:(int)inSizeInMB;

@end

@interface SSCreateDiskViewController ()

@property (readwrite, nonatomic) NSCharacterSet* anIllegalFileNameCharSet;

@end

@implementation SSCreateDiskViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view from its nib.
	
	self.nameField.delegate = self;
	self.sizeField.delegate = self;
	
	[self _updateCreateButton];
	
	self.anIllegalFileNameCharSet = [NSCharacterSet characterSetWithCharactersInString:@":/"];
	
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_textFieldChanged:) name:UITextFieldTextDidChangeNotification object:nil];
}

- (void) _updateCreateButton
{
	// Both fields need to have valid chars.
	BOOL aValidFields = YES;
	if (self.nameField.text.length == 0) {
		aValidFields = NO;
	}
	if (self.sizeField.text.length == 0) {
		aValidFields = NO;
	} else {
		int aSizeMB = atoi(self.sizeField.text.UTF8String);
		if ((aSizeMB < 1) || (aSizeMB > 10000)) {
			aValidFields = NO;
		}
	}
	
	self.createButton.enabled = aValidFields;
}

- (IBAction)sizeFieldHit:(id)sender
{
	
}

- (IBAction)nameFieldHit:(id)sender
{
	
}

- (IBAction)cancelButtonHit:(id)sender
{
	[self.presentingViewController dismissViewControllerAnimated:YES completion:^(void) {
		
	}];
	
	// Nothing else to do...
}

- (IBAction)createButtonHit:(id)sender
{
	// Make sure that disk name has .dsk extension.
	NSString* aFileName = self.nameField.text;
	if ([[aFileName pathExtension] compare:@"dsk" options:NSCaseInsensitiveSearch] != NSOrderedSame) {
		aFileName = [aFileName stringByAppendingPathExtension:@"dsk"];
	}
	[self.disksViewController _createDiskWithName:aFileName size:atoi(self.sizeField.text.UTF8String)];

	[self.presentingViewController dismissViewControllerAnimated:YES completion:^(void) {
		
	}];
}

// UITextFieldDelegate:
// This gets called for each character typed or deleted (range is nonzero but string is empty).
- (BOOL) textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string
{
	NSLOG (@"%s new string: %@", __PRETTY_FUNCTION__, string);
	if (textField == self.sizeField) {
		// Only allow numerals.
		if (string.length > 0) {
			if ([string rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].length > 0) {
				return NO;
			}
		}
	}
	
	// Disallow colon and forward slash.
	if (textField == self.nameField) {
		if ([string rangeOfCharacterFromSet:self.anIllegalFileNameCharSet].length > 0) {
			return NO;
		}
	}
	
	[self _updateCreateButton];
	
	return YES;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField              // called when 'return' key pressed. return NO to ignore.
{
	NSLOG (@"%s text field: %@", __PRETTY_FUNCTION__, textField);
	[textField endEditing:NO];		// NO == don't force, this is usually YES when the view vanishes from screen, for example.
	[self _updateCreateButton];
	return YES;
}

// This gets called with every character typed or deleted if there is no delegate set for the text field. Object id the text field.
- (void) _textFieldChanged:(NSNotification*)inNotification
{
	//NSLOG (@"%s Notification: %@", __PRETTY_FUNCTION__, inNotification);
}

@end
