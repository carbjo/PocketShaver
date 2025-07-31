//
//  SSPreferencesDisksViewController.m
//  SheepShaver_Xcode8
//
//  Created by Tom Padula on 7/21/22.
//

#import "SSPreferencesDisksViewController.h"

#import "DiskTypeiOS.h"
#import "SSCreateDiskViewController.h"
#import "SSDiskTableHeaderView.h"
#import "SSDiskTableViewCell.h"

#import <stdio.h>
#import <unistd.h>

#define int32 int32_t
#import "prefs.h"

#define DEBUG_DISK_PREFS 1

#if DEBUG_DISK_PREFS
#define NSLOG(...) NSLog(__VA_ARGS__)
#else
#define NSLOG(...)
#endif

const int kCDROMRefNum = -62;			// RefNum of driver

@interface SSPreferencesDisksViewController ()

@property (nonatomic) SSDiskManager *diskManager;
@property (readwrite, nonatomic) SSCreateDiskViewController* createDiskViewController;

@end

@implementation SSPreferencesDisksViewController

- (void)injectDiskManager:(SSDiskManager*) diskManager {
	self.diskManager = diskManager;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	// Do any additional setup after loading the view from its nib.
		
	//	[self.diskTable registerClass:[SSDiskTableViewCell class] forCellReuseIdentifier:@"diskCell"];
	
	[self _setUpDiskTableUI];
	[self _setUpBootFromUI];
	[self _setUpCreateDiskUI];
}

- (void) _setUpDiskTableUI
{
	[self.diskManager loadDiskData];

	self.diskTable.delegate = self;
	self.diskTable.dataSource = self;
}

- (void) _setUpBootFromUI
{
	BOOL aBootFromCDROMFirst = NO;
	if (PrefsFindInt32("bootdriver") == kCDROMRefNum) {
		aBootFromCDROMFirst = YES;
	}
	[self.bootFromCDROMFirstSwitch setOn:aBootFromCDROMFirst];
}

- (void) _setUpCreateDiskUI
{
//	self.createNewDiskButton.layer.borderColor = self.createNewDiskButton.titleLabel.textColor.CGColor;
//	self.createNewDiskButton.layer.borderWidth = 1;
//	self.createNewDiskButton.layer.cornerRadius = 4;
//	self.createNewDiskButton.contentEdgeInsets = UIEdgeInsetsMake(4, 4, 4, 4);
}

// UITableViewDataSource
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	return self.diskManager.diskArray.count;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	return 1;
}

- (BOOL) tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath
{
	return NO;
}

// This should never be hit, selection is turned off.
- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	NSLOG (@"%s selected row at index path: %@", __PRETTY_FUNCTION__, indexPath);
	NSLOG (@"    tableView.visibleCells: %@", tableView.visibleCells);
}

// Row display. Implementers should *always* try to reuse cells by setting each cell's reuseIdentifier and querying for available reusable cells with dequeueReusableCellWithIdentifier:
// Cell gets various attributes set automatically based on table (separators) and data source (accessory views, editing controls)
//
// This table is rarely updated while the app is running and is small. There is little chance that any cell would actually be reused
// and IB (Xcode 12.4) is having indigestion again. So we do it the old way.
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	NSLOG (@"%s index path row: %ld", __PRETTY_FUNCTION__, (long)indexPath.row);
	if (indexPath.row >= self.diskManager.diskArray.count) {
		return nil;
	}
	
	SSDiskTableViewCell* aCell = nil;
	
//	aCell = [tableView dequeueReusableCellWithIdentifier:@"diskCell" forIndexPath:indexPath];
	if (!aCell) {
		aCell = [[SSDiskTableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"diskCell"];
	}

	__weak SSPreferencesDisksViewController *weakSelf = self;
	aCell.writePrefs = ^{
		[weakSelf.diskManager writePrefs];
	};
	aCell.disk = [self.diskManager.diskArray objectAtIndex:indexPath.row];

	if (tableView.rowHeight == UITableViewAutomaticDimension) {
		tableView.rowHeight = 44;
	}
	CGRect aFrame = CGRectMake(0, 0, tableView.contentSize.width, tableView.rowHeight);
	[aCell.contentView setFrame:aFrame];
	[aCell setFrame:aFrame];
	
	NSLOG (@"%s SSDiskTableViewCell frame: %@", __PRETTY_FUNCTION__, NSStringFromCGRect(aFrame));
	
	// No need to show the whole path.
	DiskTypeiOS* aDisk = [self.diskManager.diskArray objectAtIndex:indexPath.row];
	[aCell.diskNameLabel setText:[aDisk.path lastPathComponent]];
	[aCell.isCDROMSwitch setOn:aDisk.isCDROM];
	[aCell.diskMountEnableSwitch setOn:!aDisk.disable];
	
	NSLOG (@"    aCell: %@", aCell);
	NSLOG (@"    aCell.diskNameLabel: %@", aCell.diskNameLabel);
	NSLOG (@"    aCell.isCDROMSwitch: %@", aCell.isCDROMSwitch);
	NSLOG (@"    aCell.diskMountEnableSwitch: %@", aCell.diskMountEnableSwitch);
	NSLOG (@"    aCell.contentView: %@", aCell.contentView);
	NSLOG (@"    aCell.contentView.subviews: %@", aCell.contentView.subviews);

	[aCell setSelectionStyle:UITableViewCellSelectionStyleNone];
	[aCell setUserInteractionEnabled:YES];
	
	return aCell;
}

// These are belt-and-suspenders, they should default to NO anyway.
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
	return NO;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
	return NO;
}

- (nullable NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
	return nil;
}

- (nullable NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
	return nil;
}

- (IBAction)createNewDiskButtonHit:(id)sender
{
	self.createDiskViewController.disksViewController = self;
	[self presentViewController:self.createDiskViewController animated:YES completion:^(void){
		
	}];
}

- (IBAction)bootFromCDROMFirstSwitchHit:(id)sender
{
	if (self.bootFromCDROMFirstSwitch.isOn) {
		PrefsReplaceInt32("bootdriver", kCDROMRefNum);
	} else {
		PrefsReplaceInt32("bootdriver", 0);
	}
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
	NSLOG (@"%s new size: %@", __PRETTY_FUNCTION__, NSStringFromCGSize(size));

	[super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
	
	[self.diskTable performSelectorOnMainThread:@selector(reloadData) withObject:nil waitUntilDone:NO];
}

- (SSCreateDiskViewController*)createDiskViewController
{
	if (!_createDiskViewController) {
		_createDiskViewController = [SSCreateDiskViewController new];
	}
	return _createDiskViewController;
}

- (void) _createDiskWithName:(NSString*)inName size:(int)inSizeInMB
{
	NSLOG (@"%s Name: %@, size: %d MB", __PRETTY_FUNCTION__, inName, inSizeInMB);
	
	NSString* aDocsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	NSString* aFilePath = [aDocsDirectory stringByAppendingPathComponent:inName];
	
	// If this file already exists, give the user the option to replace it. For now, just do nothing.
	if ([[NSFileManager defaultManager] fileExistsAtPath:aFilePath isDirectory:nil]) {
		NSLOG (@"%s Name %@ already exists, bailing out.", __PRETTY_FUNCTION__, inName);
		return;
	}
	
	// Use the file manager to create the file, then use truncate to set the length.
	char aBytes[1024];
	bzero (aBytes, 1024);
	NSData* aData = [NSData dataWithBytes:aBytes length:1024];
	NSNumber *fileSizeInMB = @(inSizeInMB);
	NSNumber *oneMB = @(1048576);
	NSNumber *fileSizeInBytes = @(fileSizeInMB.longValue * oneMB.longValue);
	NSLog(@"fileSize %@ inSizeInMB %d", fileSizeInBytes, inSizeInMB);
	BOOL fileCreationSuccesful = [[NSFileManager defaultManager] createFileAtPath:aFilePath contents:aData attributes:@{NSFileType: NSFileTypeRegular}];
	NSLOG (@" fileCreationSuccesful: %@", fileCreationSuccesful ? @"YES" : @"NO");

	int aFileDescriptor = truncate(aFilePath.UTF8String, fileSizeInBytes.longValue);
	NSLOG(@"%s truncate file: %s, descriptor: %d", __PRETTY_FUNCTION__, aFilePath.UTF8String, aFileDescriptor);
	if (aFileDescriptor < 0) {
		NSLOG (@"    error: %d, %s", errno, strerror(errno));
	}
	
	// Force a rebuild of the disk list.
	[self.diskManager loadDiskData];
	[self.diskTable performSelectorOnMainThread:@selector(reloadData) withObject:nil waitUntilDone:NO];
}

@end
