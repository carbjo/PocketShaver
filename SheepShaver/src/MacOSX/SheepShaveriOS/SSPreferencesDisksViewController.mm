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

@property (readwrite, nonatomic) NSMutableArray<DiskTypeiOS*>* diskArray;
@property (readwrite, nonatomic) SSCreateDiskViewController* createDiskViewController;

@end

@implementation SSPreferencesDisksViewController

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
	[self _loadDiskData];
	
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

- (void) _loadDiskData
{
	self.diskArray = [NSMutableArray new];

	// First we scan for all available disks in the Documents directory. Then we reconcile that
	// with the "disk" prefs, eliminating any existing prefs that we can't find in the Documents
	// directory. This we use to populate diskArray.
	const char *dsk;
	int index = 0;
	while ((dsk = PrefsFindString("disk", index++)) != NULL) {
		DiskTypeiOS *disk = [DiskTypeiOS new];
		[disk setPath:[NSString stringWithUTF8String: dsk ]];
		[disk setIsCDROM:NO];
		
		[self.diskArray addObject:disk];
	}
	
	/* Fetch all CDROMs */
	index = 0;
	while ((dsk = PrefsFindString("cdrom", index++)) != NULL) {
		NSString *path = [NSString stringWithUTF8String: dsk ];
		if (![path hasPrefix:@"/dev/"]) {
			DiskTypeiOS *disk = [DiskTypeiOS new];
			[disk setPath:[NSString stringWithUTF8String: dsk ]];
			[disk setIsCDROM:YES];
			
			[self.diskArray addObject:disk];
		}
	}
	
	NSLOG (@"%s Array from cdrom prefs: %@", __PRETTY_FUNCTION__, self.diskArray);

	// Ok, we have a list of disks that the prefs know about. Get the actual files in the Documents directory.
	
	NSString* aDocsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	NSError* anError = nil;
	NSArray* anAllElements = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:aDocsDirectory error:&anError];
	if (anError) {
		NSLOG (@"%s contents of directory at path: %@ returned error: %@", __PRETTY_FUNCTION__, aDocsDirectory, anError);
		
		// Should we clear the list completely here?
		
		return;
	}
	NSLOG (@"%s All elements in directory: %@\n%@", __PRETTY_FUNCTION__, aDocsDirectory, anAllElements);

	NSMutableArray<NSString*>* aDiskCandidateFiles = [NSMutableArray new];
	for (NSString* anElementName in anAllElements) {
		NSString* anElementPath = [aDocsDirectory stringByAppendingPathComponent:anElementName];
		BOOL aIsDirectory = NO;
		if (![[NSFileManager defaultManager] fileExistsAtPath:anElementPath isDirectory:&aIsDirectory] || (aIsDirectory)) {
			NSLOG (@"%s File doesn't exist or is a directory, continuing: %@", __PRETTY_FUNCTION__, anElementName);
			continue;
		}

		// Ok, we have a file (as opposed to a directory) and it exists. See if it has an extension that's not a disk file.
		if (anElementPath.pathExtension.length > 0) {
			if ([anElementPath.pathExtension compare:@"dsk" options:NSCaseInsensitiveSearch] == NSOrderedSame) {
				// Extension exists and is "dsk".
				[aDiskCandidateFiles addObject:anElementPath];
			} else if ([anElementPath.pathExtension compare:@"dmg" options:NSCaseInsensitiveSearch] == NSOrderedSame) {
				[aDiskCandidateFiles addObject:anElementPath];
			} else if ([anElementPath.pathExtension compare:@"cdr" options:NSCaseInsensitiveSearch] == NSOrderedSame) {
				[aDiskCandidateFiles addObject:anElementPath];
			} else {
				NSLOG (@"%s Extension %@ is unknown: %@", __PRETTY_FUNCTION__, anElementPath.pathExtension, anElementName);
			}
		}
	}
	
	NSLOG (@"%s Disk candidate files: %@", __PRETTY_FUNCTION__, aDiskCandidateFiles);

	// Compare the lists. For any disk that we have that doesn't actually exist, eliminate it from the disks list.
	// For any disk that actually exists that we don't already know about, create an entry but mark it disabled.
	// Note that we compare last path components only, because the path to the file may change as installations
	// on devices change.
	
	// First look for the ones in the prefs that don't actually exist. Since we will be eliminating things from the
	// array, we have to be careful not to invalidate iterators.
	int aDiskArrayIndex = 0;
	while (aDiskArrayIndex < self.diskArray.count) {
		// Starting at the top, search for a path in the disk array from within the disk files. If something doesn't
		// match, we can eliminate it. Otherwise, bump the index and continue.
		DiskTypeiOS* aSearchDisk = [self.diskArray objectAtIndex:aDiskArrayIndex];
		NSString* aSearchPath = [aSearchDisk path];
		
		BOOL aFoundIt = NO;
		for (int aDiskCandidateIndex = 0; aDiskCandidateIndex < aDiskCandidateFiles.count; aDiskCandidateIndex++) {
			if ([aSearchPath.lastPathComponent compare:[aDiskCandidateFiles objectAtIndex:aDiskCandidateIndex].lastPathComponent options:NSCaseInsensitiveSearch] == NSOrderedSame) {
				aFoundIt = YES;
				break;
			}
		}
		if (aFoundIt) {
			aDiskArrayIndex++;
		} else {
			[self.diskArray removeObjectAtIndex:aDiskArrayIndex];		// note do not increment index.
		}
	}
	
	NSLOG (@"%s Disk array after eliminating phantoms: %@", __PRETTY_FUNCTION__, self.diskArray);

	// Ok, now self.diskArray contains only things that actually exist, let's see if there is anything else to add to it,
	// that is, files that exist that aren't already accounted for.
	int aDiskCandidateIndex = 0;
	while (aDiskCandidateIndex < aDiskCandidateFiles.count) {
		NSString* anExistingDiskPath = [aDiskCandidateFiles objectAtIndex:aDiskCandidateIndex];
		BOOL aFoundIt = NO;
		for (aDiskArrayIndex = 0; aDiskArrayIndex < self.diskArray.count; aDiskArrayIndex++) {
			DiskTypeiOS* aSearchDisk = [self.diskArray objectAtIndex:aDiskArrayIndex];
			NSString* aSearchPath = [aSearchDisk path];
			if ([aSearchPath.lastPathComponent compare:anExistingDiskPath.lastPathComponent options:NSCaseInsensitiveSearch] == NSOrderedSame) {
				aFoundIt = YES;
				break;
			}
		}
		if (!aFoundIt) {
			DiskTypeiOS *disk = [DiskTypeiOS new];
			[disk setPath:anExistingDiskPath];
			if ([anExistingDiskPath.pathExtension compare:@"cdr" options:NSCaseInsensitiveSearch] == NSOrderedSame) {
				[disk setIsCDROM:YES];
			} else {
				[disk setIsCDROM:NO];
			}
			[disk setDisable:YES];
			
			[self.diskArray addObject:disk];
		}
		aDiskCandidateIndex++;
	}
	
	// If there is but one disk, make sure it is enabled.
	if (self.diskArray.count == 1) {
		self.diskArray.firstObject.disable = NO;
	}
		
	NSLOG (@"%s Disk array after adding disabled real disks: %@", __PRETTY_FUNCTION__, self.diskArray);
	
	[self _writePrefs];
}

- (void) _writePrefs
{
	// Clear the prefs and rewrite them. If there is but one real disk and no remaining prefs disks, we should just
	// set the one as the prefs disk without bothering the user.
	while (PrefsFindString("disk") != 0) {
		PrefsRemoveItem("disk");
	}
	while (PrefsFindString("cdrom") != 0) {
		PrefsRemoveItem("cdrom");
	}
	
	// Update the paths with the current documents directory. This isn't normally a big deal, but during development the identity of
	// the document directory can change.
	NSString* aDocsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	if (self.diskArray.count == 1) {
		PrefsAddString(self.diskArray.firstObject.isCDROM ? "cdrom" : "disk", [self.diskArray.firstObject.path UTF8String]);		// even if it is disabled, since it's the only one
	} else {
		for (DiskTypeiOS* aDiskType in self.diskArray) {
			if (aDiskType.disable == NO) {
				NSString* aFileName = aDiskType.path.lastPathComponent;
				NSString* aFilePath = [aDocsDirectory stringByAppendingPathComponent:aFileName];
				PrefsAddString(aDiskType.isCDROM ? "cdrom" : "disk", [aFilePath UTF8String]);
			}
		}
	}
	
	// Ensure that /dev/poll/cdrom is present exactly once.
	const char* aPollCDROM = nil;
	int anIndex = 0;
	do {
		aPollCDROM = PrefsFindString("cdrom", anIndex++);
		if (!aPollCDROM) {
			break;
		}
		if (strlen(aPollCDROM) != strlen("/dev/poll/cdrom")) {
			continue;
		}
	}
	while (strncmp (aPollCDROM, "/dev/poll/cdrom", strlen(aPollCDROM)) != 0);
	if (!aPollCDROM) {
		PrefsAddString("cdrom", "/dev/poll/cdrom");		// This is also added in sys_unix.cpp.
	}
	
	NSLOG (@"%s write %lu new disk paths:", __PRETTY_FUNCTION__, (unsigned long)self.diskArray.count);
	for (DiskTypeiOS* aDiskType in self.diskArray) {
		NSLOG (@"    %@", aDiskType.path);
	}
}

// UITableViewDataSource
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	return self.diskArray.count;
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
	if (indexPath.row >= self.diskArray.count) {
		return nil;
	}
	
	SSDiskTableViewCell* aCell = nil;
	
//	aCell = [tableView dequeueReusableCellWithIdentifier:@"diskCell" forIndexPath:indexPath];
	if (!aCell) {
		aCell = [[SSDiskTableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"diskCell"];
	}
	aCell.disksViewController = self;
	aCell.disk = [self.diskArray objectAtIndex:indexPath.row];
	
	if (tableView.rowHeight == UITableViewAutomaticDimension) {
		tableView.rowHeight = 44;
	}
	CGRect aFrame = CGRectMake(0, 0, tableView.contentSize.width, tableView.rowHeight);
	[aCell.contentView setFrame:aFrame];
	[aCell setFrame:aFrame];
	
	NSLOG (@"%s SSDiskTableViewCell frame: %@", __PRETTY_FUNCTION__, NSStringFromCGRect(aFrame));
	
	// No need to show the whole path.
	DiskTypeiOS* aDisk = [self.diskArray objectAtIndex:indexPath.row];
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
	BOOL aSuccess = [[NSFileManager defaultManager] createFileAtPath:aFilePath contents:aData attributes:@{NSFileType: NSFileTypeRegular, NSFileSize: @(inSizeInMB << 20)}];
	NSLOG (@" aSuccess: %@", aSuccess ? @"YES" : @"NO");
			
	off_t aLength = inSizeInMB << 20;
	int aFileDescriptor = truncate(aFilePath.UTF8String, aLength);
	NSLOG(@"%s truncate file: %s, descriptor: %d", __PRETTY_FUNCTION__, aFilePath.UTF8String, aFileDescriptor);
	if (aFileDescriptor < 0) {
		NSLOG (@"    error: %d, %s", errno, strerror(errno));
	}
	
	// Force a rebuild of the disk list.
	[self _loadDiskData];
	[self.diskTable performSelectorOnMainThread:@selector(reloadData) withObject:nil waitUntilDone:NO];
}

@end
