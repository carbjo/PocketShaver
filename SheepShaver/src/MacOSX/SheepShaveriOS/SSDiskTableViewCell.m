//
//  SSDiskTableViewCell.m
//  SheepShaver_Xcode8
//
//  Created by Tom Padula on 7/22/22.
//

#import "SSDiskTableViewCell.h"

#import "UIView+SDCAutoLayout.h"

@implementation SSDiskTableViewCell

- (void)awakeFromNib {
    [super awakeFromNib];
    // Initialization code
	
//	self.diskMountEnableSwitch = [UISwitch new];
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
		
//		[self setAutoresizingMask:UIViewAutoresizingNone];
//		[self.contentView setAutoresizingMask:UIViewAutoresizingNone];
//		[self.diskMountEnableSwitch setAutoresizingMask:UIViewAutoresizingNone];
//		[self.isCDROMSwitch setAutoresizingMask:UIViewAutoresizingNone];
//		[self.diskNameLabel setAutoresizingMask:UIViewAutoresizingNone];
		
		CGRect aContentFrame = self.contentView.frame;
		
		CGRect aCDROMFrame = self.isCDROMSwitch.frame;
		aCDROMFrame.origin.x = (aContentFrame.origin.x + aContentFrame.size.width) - aCDROMFrame.size.width - 16;
		aCDROMFrame.origin.y = (aContentFrame.size.height / 2) - (aCDROMFrame.size.height / 2);
		[self.isCDROMSwitch setFrame:aCDROMFrame];
		
		CGRect aMountFrame = self.diskMountEnableSwitch.frame;
		aMountFrame.origin.x = aCDROMFrame.origin.x - aMountFrame.size.width - 12;
		aMountFrame.origin.y = (aContentFrame.size.height / 2) - (aMountFrame.size.height / 2);
		[self.diskMountEnableSwitch setFrame:aMountFrame];
		
		CGRect aFileNameFrame = self.diskNameLabel.frame;
		aFileNameFrame.size.width = aMountFrame.origin.x - 12;
		aFileNameFrame.size.height = 21;
		aFileNameFrame.origin.x = 8;
		aFileNameFrame.origin.y = (aContentFrame.size.height / 2) - (aFileNameFrame.size.height / 2);
		[self.diskNameLabel setFrame:aFileNameFrame];

//		[self.isCDROMSwitch sdc_alignEdge:UIRectEdgeRight withEdge:UIRectEdgeRight ofView:self.isCDROMSwitch.superview inset:30];
//		[self.isCDROMSwitch sdc_alignEdge:UIRectEdgeBottom withEdge:UIRectEdgeBottom ofView:self.isCDROMSwitch.superview inset:6];

	}
	return self;
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];

    // Configure the view for the selected state
}

- (IBAction)diskMountEnableSwitchHit:(id)sender
{
	
}

- (IBAction)isCDROMSwitchHit:(id)sender
{
	
}

@end
