//
//  SSPreferencesBootROMViewController.m
//  SheepShaveriOS
//
//  Created by Tom Padula on 8/29/22.
//

#import "SSPreferencesBootROMViewController.h"

#define int32 int32_t
#import "prefs.h"

#define DEBUG_ROM_PREFS 1

#if DEBUG_ROM_PREFS
#define NSLOG(...) NSLog(__VA_ARGS__)
#else
#define NSLOG(...)
#endif

NSArray* gBootROMFilePaths;

@interface SSPreferencesBootROMViewController ()

@property (class, readwrite, nonatomic) NSArray* bootROMFilePaths;

@end

@implementation SSPreferencesBootROMViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view from its nib.
	
	[self.bootROMTable setDelegate:self];
	[self.bootROMTable setDataSource:self];
	
	const char* aSelectedString = PrefsFindString("rom");
	NSLOG (@"%s selected string from prefs: %s", __PRETTY_FUNCTION__, aSelectedString);
	
	if (aSelectedString) {
		NSString* aSelectedPath = [NSString stringWithCString:aSelectedString encoding:NSUTF8StringEncoding];
		
		NSInteger anIndex = 0;
		for (NSString* aPath in [SSPreferencesBootROMViewController romFilePaths]) {
			if ([[aPath lastPathComponent] compare:[aSelectedPath lastPathComponent] options:NSCaseInsensitiveSearch] == NSOrderedSame) {
				break;
			}
			anIndex++;
		}
		
		if (anIndex < [[SSPreferencesBootROMViewController romFilePaths] count]) {
			[self.bootROMTable selectRowAtIndexPath:[NSIndexPath indexPathForRow:anIndex inSection:0] animated:NO scrollPosition:UITableViewScrollPositionMiddle];
		}
	}
}

/*
#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
}
*/

// UITableViewDelegate:
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	if (indexPath.row >= [[SSPreferencesBootROMViewController romFilePaths] count]) {
		return;
	}
	
	NSString* aSelectedPath = [[SSPreferencesBootROMViewController romFilePaths] objectAtIndex:indexPath.row];
	PrefsReplaceString("rom", [aSelectedPath UTF8String], 0);		// 0 == first string found
}

// UITableViewDataSource:
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	NSLOG (@"%s num rom file paths: %ld", __PRETTY_FUNCTION__, [[SSPreferencesBootROMViewController romFilePaths] count]);
	return [[SSPreferencesBootROMViewController romFilePaths] count];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	return 1;
}

// Row display. Implementers should *always* try to reuse cells by setting each cell's reuseIdentifier and querying for available reusable cells with dequeueReusableCellWithIdentifier:
// Cell gets various attributes set automatically based on table (separators) and data source (accessory views, editing controls)

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	NSLOG (@"%s index path row: %ld", __PRETTY_FUNCTION__, (long)indexPath.row);
	if (indexPath.row >= [[SSPreferencesBootROMViewController romFilePaths] count]) {
		return nil;
	}
	
	UITableViewCell* aCell = nil;

	aCell = [tableView dequeueReusableCellWithIdentifier:@"romCell"];
	if (!aCell) {
		aCell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"romCell"];
	}
	
	CGRect aFrame = CGRectMake(0, 0, tableView.contentSize.width, tableView.rowHeight);
	[aCell.contentView setFrame:aFrame];
	[aCell setFrame:aFrame];
	
	[aCell.textLabel setText:[[[SSPreferencesBootROMViewController romFilePaths] objectAtIndex:indexPath.row] lastPathComponent]];
	
	[aCell setSelectionStyle:UITableViewCellSelectionStyleBlue];
	[aCell setUserInteractionEnabled:YES];

	return aCell;
}

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

+ (NSArray*) romFilePaths
{
	if ([SSPreferencesBootROMViewController.bootROMFilePaths count] == 0) {
		// We are looking for files of an appropriate size, with either no extension or a .rom (case-insensitive) extension.
		NSString* aDocsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
		NSError* anError = nil;
		NSArray* anAllElements = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:aDocsDirectory error:&anError];
		if (anError) {
			NSLOG (@"%s contents of directory at path: %@ returned error: %@", __PRETTY_FUNCTION__, aDocsDirectory, anError);
			return nil;
		}
		NSLOG (@"%s All elements in directory: %@\n%@", __PRETTY_FUNCTION__, aDocsDirectory, anAllElements);
		
		NSMutableArray* aROMCandidateFiles = [NSMutableArray new];
		NSMutableArray* anOldWorldROMCandidateFilePaths = [NSMutableArray new];
		for (NSString* anElementName in anAllElements) {
			NSString* anElementPath = [aDocsDirectory stringByAppendingPathComponent:anElementName];
			BOOL aIsDirectory = NO;
			if (![[NSFileManager defaultManager] fileExistsAtPath:anElementPath isDirectory:&aIsDirectory] || (aIsDirectory)) {
				NSLOG (@"%s File doesn't exist or is a direcotry, continuing: %@", __PRETTY_FUNCTION__, anElementName);
				continue;
			}
			
			// Ok, we have a file (as opposed to a directory) and it exists. See if it has an extension that's not a rom file.
			// We allow files with no extension at all to be considered as possible ROM files.
			if (anElementPath.pathExtension.length > 0) {
				if ([anElementPath.pathExtension compare:@"rom" options:NSCaseInsensitiveSearch] != NSOrderedSame) {
					// Extension exists but is not "rom".
					NSLOG (@"%s Extension is not 'rom': %@", __PRETTY_FUNCTION__, anElementName);
					continue;
				}
			}
			
			// Ok, either the file has no extension or the extension is something like ".rom". Check its size.
			NSDictionary* anAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:anElementPath error:&anError];
			if (anError) {
				NSLOG (@"%s attributesOfItemAtPath: %@ returned error: %@", __PRETTY_FUNCTION__, anElementPath, anError);
				continue;
			}
			if (anAttributes.fileSize < (0x1 << 20)) {	// smaller than a megabyte
				NSLOG (@"%s File too small, continuing: %@", __PRETTY_FUNCTION__, anElementName);
				continue;
			}
			if (anAttributes.fileSize > (0x1 << 22)) {	// larger than 4 megabytes
				NSLOG (@"%s File too large, continuing: %@", __PRETTY_FUNCTION__, anElementName);
				continue;
			}
			
			// Ok, we have a file with a reasonable size. Does it start with <CHRP-BOOT>? -- All New World ROMs do.
			// If not and its size is exactly 4MB, put it in the Old World candidates list.
			int aFileDescriptor = open([anElementPath UTF8String], O_RDONLY);
			if (aFileDescriptor < 0) {
				// Failed to open --?
				NSLOG (@"%s Failed to open file for reading: %@", __PRETTY_FUNCTION__, anElementPath);
				continue;
			}
			char aBuffer[16];
			lseek(aFileDescriptor, 0, SEEK_SET);
			size_t anActualRead = read(aFileDescriptor, (void *)aBuffer, 16);
			close(aFileDescriptor);
			if (anActualRead < 16) {		 // how did this happen --?
				NSLOG (@"%s Failed to read 16 bytes: %@", __PRETTY_FUNCTION__, anElementName);
				continue;
			}
			char aCompareString[] = "<CHRP-BOOT>";
			if (strncmp(aBuffer, aCompareString, strlen(aCompareString)) != 0) {
				if (anAttributes.fileSize == (0x1 << 22)) {					// Exactly 4MB
					NSLOG (@"%s Did not start with expected string and exactly 4MB, might be Old World: %@", __PRETTY_FUNCTION__, anElementName);
					[anOldWorldROMCandidateFilePaths addObject:anElementPath];
				} else {
					NSLOG (@"%s Did not start with expected string: %@", __PRETTY_FUNCTION__, anElementName);
					NSLOG (@"%s Expected string is: %s", __PRETTY_FUNCTION__, aCompareString);
				}
				continue;
			}
			
			// Passed all tests, it's a ROM file.
			[aROMCandidateFiles addObject:anElementPath];
		}
		
		// We can use some Old World ROMs: TNT, Alchemy, Zanzibar, Gazelle, and Gossamer.
		//		TNT: PowerMac 7200, 7300, 7500, 7600, 8500, 8600, 9500, 9600 versions 1 and 2
		//		Alchemy: PowerMac/Performa 6400
		//		Zanzibar: PowerMac 4400 (we don't have this ROM file to test with)
		//		Gazelle: PowerMac 6500
		//		Gossamer: PowerMac G3
		// We cannot use any others (yet) such as:
		// 		Cordyceps: PowerMac/Performa 5200, 5300, 6200, and 6300
		//		PBX: Powerbook 1400, 1400cs, 2300, & 500-series
		//		GRX: Wallstreet and Wallstreet PDQ
		// In addition, New World ROMs which have been uncompressed are also 4MB, and we can use them.
		for (NSString* anElementPath in anOldWorldROMCandidateFilePaths) {		// we put entire paths in here
			// See line 681 in rom_patches.cpp to see how to check if these are ROMs we can use.
			int aFileDescriptor = open([anElementPath UTF8String], O_RDONLY);
			if (aFileDescriptor < 0) {
				// Failed to open --?
				NSLOG (@"%s Failed to open file for reading: %@", __PRETTY_FUNCTION__, anElementPath);
				continue;
			}
			char aBuffer[17];
			lseek(aFileDescriptor, 0x30d064, SEEK_SET);		// Magic location for the boot type string
			size_t anActualRead = read(aFileDescriptor, (void *)aBuffer, 16);
			close(aFileDescriptor);

			if (anActualRead < 16) {		 // how did this happen --?
				NSLOG (@"%s Failed to read 16 bytes: %@", __PRETTY_FUNCTION__, anElementPath);
				continue;
			}
			if (!(strncmp(aBuffer, "Boot TNT", 8)) &&
				!(strncmp(aBuffer, "Boot Alchemy", 12)) &&
				!(strncmp(aBuffer, "Boot Zanzibar", 13)) &&
				!(strncmp(aBuffer, "Boot Gazelle", 12)) &&
				!(strncmp(aBuffer, "Boot Gossamer", 13)) &&
				!(strncmp(aBuffer, "NewWorld", 8))) {
				
				// We can't use this file as a ROM.
				aBuffer[16] = 0;		// ensure string ends
				NSLOG (@"%s Can't use this ROM type: %s", __PRETTY_FUNCTION__, aBuffer);
				NSLOG (@"    File: %@", anElementPath);
				continue;
			}
			
			// Good to use this ROM file.
			[aROMCandidateFiles addObject:anElementPath];
		}

		SSPreferencesBootROMViewController.bootROMFilePaths = aROMCandidateFiles;
		NSLOG (@"%s ROM file candidates: %@", __PRETTY_FUNCTION__, aROMCandidateFiles);
#if 0
		if ([SSPreferencesBootROMViewController.bootROMFilePaths count] == 0) {
			SSPreferencesBootROMViewController.bootROMFilePaths = @[@"/First/boot/ROM/file", @"/Second/Boot/ROM/file.rom"];
		}
		NSLOG (@"%s %@", __PRETTY_FUNCTION__, SSPreferencesBootROMViewController.bootROMFilePaths);
#endif
	}
	
	return SSPreferencesBootROMViewController.bootROMFilePaths;
}

+ (NSArray*)bootROMFilePaths
{
	return gBootROMFilePaths;
}

+ (void) setBootROMFilePaths:(NSArray *)bootROMFilePaths
{
	gBootROMFilePaths = bootROMFilePaths;
}

@end
