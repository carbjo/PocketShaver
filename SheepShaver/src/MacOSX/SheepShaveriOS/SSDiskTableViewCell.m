//
//  SSDiskTableViewCell.m
//  SheepShaver_Xcode8
//
//  Created by Tom Padula on 7/22/22.
//

#import "SSDiskTableViewCell.h"

#import "UIView+SDCAutoLayout.h"

@interface SSPreferencesDisksViewController(SSDiskTableViewCell)

- (void) _writePrefs;

@end

@implementation SSDiskTableViewCell

- (void)awakeFromNib {
    [super awakeFromNib];
    // Initialization code
}

- (instancetype) initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier
{
	// Create everything by hand. Kickin' it old school.
	if (self = [super initWithStyle:style reuseIdentifier:reuseIdentifier]) {
				
		self.diskMountEnableSwitch = [UISwitch new];
		self.isCDROMSwitch = [UISwitch new];
		self.diskNameLabel = [UILabel new];
		
		[self.contentView addSubview:self.diskMountEnableSwitch];
		[self.contentView addSubview:self.isCDROMSwitch];
		[self.contentView addSubview:self.diskNameLabel];
		
		[self.diskMountEnableSwitch addTarget:self action:@selector(diskMountEnableSwitchHit:) forControlEvents:UIControlEventValueChanged];
		[self.isCDROMSwitch addTarget:self action:@selector(isCDROMSwitchHit:) forControlEvents:UIControlEventValueChanged];

		CGRect aContentFrame = self.contentView.frame;
		
		// CDROM switch on the far right.
		CGRect aCDROMFrame = self.isCDROMSwitch.frame;
		aCDROMFrame.origin.x = (aContentFrame.origin.x + aContentFrame.size.width) - aCDROMFrame.size.width - 16;
		aCDROMFrame.origin.y = (aContentFrame.size.height / 2) - (aCDROMFrame.size.height / 2);
		[self.isCDROMSwitch setFrame:aCDROMFrame];
		
		// Mount enable switch to the left of CDROM switch.
		CGRect aMountFrame = self.diskMountEnableSwitch.frame;
		aMountFrame.origin.x = aCDROMFrame.origin.x - aMountFrame.size.width - 12;
		aMountFrame.origin.y = (aContentFrame.size.height / 2) - (aMountFrame.size.height / 2);
		[self.diskMountEnableSwitch setFrame:aMountFrame];
		
		// Label gets the rest of the space from the left edge to the mount enable switch.
		CGRect aFileNameFrame = self.diskNameLabel.frame;
		aFileNameFrame.size.width = aMountFrame.origin.x - 12;
		aFileNameFrame.size.height = 21;
		aFileNameFrame.origin.x = 8;
		aFileNameFrame.origin.y = (aContentFrame.size.height / 2) - (aFileNameFrame.size.height / 2);
		[self.diskNameLabel setFrame:aFileNameFrame];
	}
	
	return self;
}

- (IBAction)diskMountEnableSwitchHit:(id)sender
{
	if ([self.disksViewController.diskArray count] != 1) {
		self.disk.disable = !self.diskMountEnableSwitch.isOn;
		[self.disksViewController _writePrefs];
	}
}

- (IBAction)isCDROMSwitchHit:(id)sender
{
	self.disk.isCDROM = self.isCDROMSwitch.isOn;
	[self.disksViewController _writePrefs];
}

// This will probably never be called, but just for completeness:
- (void) prepareForReuse
{
	self.diskMountEnableSwitch = nil;
	self.diskNameLabel = nil;
	self.isCDROMSwitch = nil;
	
	self.disksViewController = nil;
	self.disk = nil;
	
	[super prepareForReuse];
}
@end
