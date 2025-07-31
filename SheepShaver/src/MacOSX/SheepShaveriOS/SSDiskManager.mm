//
//  SSDiskManager.m
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-14.
//

#import "SSDiskManager.h"

#define int32 int32_t
#import "prefs.h"

@interface SSDiskManager ()

@property (nonatomic) NSMutableArray<DiskTypeiOS*>* diskArray;

@end

@implementation SSDiskManager

- (void) loadDiskData
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

	NSLog (@"%s Array from cdrom prefs: %@", __PRETTY_FUNCTION__, self.diskArray);

	// Ok, we have a list of disks that the prefs know about. Get the actual files in the Documents directory.

	NSString* aDocsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	NSError* anError = nil;
	NSArray* anAllElements = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:aDocsDirectory error:&anError];
	if (anError) {
		NSLog (@"%s contents of directory at path: %@ returned error: %@", __PRETTY_FUNCTION__, aDocsDirectory, anError);

		// Should we clear the list completely here?

		return;
	}
	NSLog (@"%s All elements in directory: %@\n%@", __PRETTY_FUNCTION__, aDocsDirectory, anAllElements);

	NSMutableArray<NSString*>* aDiskCandidateFiles = [NSMutableArray new];
	for (NSString* anElementName in anAllElements) {
		NSString* anElementPath = [aDocsDirectory stringByAppendingPathComponent:anElementName];
		BOOL aIsDirectory = NO;
		if (![[NSFileManager defaultManager] fileExistsAtPath:anElementPath isDirectory:&aIsDirectory] || (aIsDirectory)) {
			NSLog (@"%s File doesn't exist or is a directory, continuing: %@", __PRETTY_FUNCTION__, anElementName);
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
			} else if ([anElementPath.pathExtension compare:@"iso" options:NSCaseInsensitiveSearch] == NSOrderedSame) {
				[aDiskCandidateFiles addObject:anElementPath];
			} else if ([anElementPath.pathExtension compare:@"toast" options:NSCaseInsensitiveSearch] == NSOrderedSame) {
				[aDiskCandidateFiles addObject:anElementPath];
			} else if ([anElementPath.pathExtension compare:@"img" options:NSCaseInsensitiveSearch] == NSOrderedSame) {
				[aDiskCandidateFiles addObject:anElementPath];
			} else {
				NSLog (@"%s Extension %@ is unknown: %@", __PRETTY_FUNCTION__, anElementPath.pathExtension, anElementName);
			}
		}
	}

	NSLog (@"%s Disk candidate files: %@", __PRETTY_FUNCTION__, aDiskCandidateFiles);

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

	NSLog (@"%s Disk array after eliminating phantoms: %@", __PRETTY_FUNCTION__, self.diskArray);

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

	NSLog (@"%s Disk array after adding disabled real disks: %@", __PRETTY_FUNCTION__, self.diskArray);

	[self writePrefs];
}

- (void) writePrefs
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
	for (DiskTypeiOS* aDiskType in self.diskArray) {
		if (aDiskType.disable == NO) {
			NSString* aFileName = aDiskType.path.lastPathComponent;
			NSString* aFilePath = [aDocsDirectory stringByAppendingPathComponent:aFileName];
			PrefsAddString(aDiskType.isCDROM ? "cdrom" : "disk", [aFilePath UTF8String]);
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

	NSLog (@"%s write %lu new disk paths:", __PRETTY_FUNCTION__, (unsigned long)self.diskArray.count);
	for (DiskTypeiOS* aDiskType in self.diskArray) {
		NSLog (@"    %@", aDiskType.path);
	}
}

@end
