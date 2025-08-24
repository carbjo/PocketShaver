//
//  PreferencesROMValidator.mm
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

#import "PreferencesROMValidator.h"
#import <Foundation/NSFileManager.h>

BOOL validateROM(NSString* _Nonnull romPath) {
	BOOL aIsDirectory = NO;
	NSError* anError = nil;
	if (![[NSFileManager defaultManager] fileExistsAtPath:romPath isDirectory:&aIsDirectory] || (aIsDirectory)) {
		NSLog (@"%s File doesn't exist or is a directory. Path: %@", __PRETTY_FUNCTION__, romPath);
		return NO;
	}

	// Ok, we have a file (as opposed to a directory) and it exists. See if it has an extension that's not a rom file.
	// We allow files with no extension at all to be considered as possible ROM files.
	if (romPath.pathExtension.length > 0) {
		if ([romPath.pathExtension compare:@"rom" options:NSCaseInsensitiveSearch] != NSOrderedSame) {
			// Extension exists but is not "rom".
			NSLog (@"%s Extension is not 'rom'", __PRETTY_FUNCTION__);
			return NO;
		}
	}

	// Ok, either the file has no extension or the extension is something like ".rom". Check its size.
	NSDictionary* anAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:romPath error:&anError];
	if (anError) {
		NSLog (@"%s attributesOfItemAtPath: %@ returned error: %@", __PRETTY_FUNCTION__, romPath, anError);
		return NO;
	}
	if (anAttributes.fileSize < (0x1 << 20)) {	// smaller than a megabyte
		NSLog (@"%s File too small@", __PRETTY_FUNCTION__);
		return NO;
	}
	if (anAttributes.fileSize > (0x1 << 22)) {	// larger than 4 megabytes
		NSLog (@"%s File too large", __PRETTY_FUNCTION__);
		return NO;
	}

	// Ok, we have a file with a reasonable size. Does it start with <CHRP-BOOT>? -- All New World ROMs do.
	// If not and its size is exactly 4MB, put it in the Old World candidates list.
	int aFileDescriptor = open([romPath UTF8String], O_RDONLY);
	if (aFileDescriptor < 0) {
		// Failed to open --?
		NSLog (@"%s Failed to open file for reading: %@", __PRETTY_FUNCTION__, romPath);
		return NO;
	}
	char aBuffer[16];
	lseek(aFileDescriptor, 0, SEEK_SET);
	size_t anActualRead = read(aFileDescriptor, (void *)aBuffer, 16);
	close(aFileDescriptor);
	if (anActualRead < 16) {		 // how did this happen --?
		NSLog (@"%s Failed to read 16 bytes", __PRETTY_FUNCTION__);
		return NO;
	}
	char aCompareString[] = "<CHRP-BOOT>";
	if (strncmp(aBuffer, aCompareString, strlen(aCompareString)) != 0) {
		if (anAttributes.fileSize == (0x1 << 22)) {					// Exactly 4MB
			NSLog (@"%s Did not start with expected string and exactly 4MB, might be Old World", __PRETTY_FUNCTION__);
		} else {
			NSLog (@"%s Did not start with expected string", __PRETTY_FUNCTION__);
			NSLog (@"%s Expected string is: %s", __PRETTY_FUNCTION__, aCompareString);
		}
		return NO;
	}

	return YES;
}
