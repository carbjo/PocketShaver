//
//  PreferencesROMValidator.mm
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

#import <UIKit/UIKit.h>
#import "SheepShaveriOS-Swift.h"
#import "PreferencesROMValidator.h"

BOOL isNewWorldRom(NSString* _Nonnull romPath) {
	BOOL aIsDirectory = NO;
	NSError* anError = nil;
	if (![[NSFileManager defaultManager] fileExistsAtPath:romPath isDirectory:&aIsDirectory] || (aIsDirectory)) {
		NSLog (@"%s File doesn't exist or is a directory. Path: %@", __PRETTY_FUNCTION__, romPath);
		return NO;
	}

	if (romPath.pathExtension.length > 0 &&
		[romPath.pathExtension compare:@"rom" options:NSCaseInsensitiveSearch] != NSOrderedSame) {
		// Extention should either be absent or exactly '.rom'
		NSLog (@"%s Extension is not 'rom'", __PRETTY_FUNCTION__);
		return NO;
	}

	// Check its size
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

	// We have a file with correct size. Does it start with <CHRP-BOOT>? -- All New World ROMs do.
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
		if (anAttributes.fileSize == (0x1 << 22)) { // Exactly 4MB
			NSLog (@"%s Did not start with expected string and exactly 4MB, might be Old World", __PRETTY_FUNCTION__);
		} else {
			NSLog (@"%s Did not start with expected string", __PRETTY_FUNCTION__);
			NSLog (@"%s Expected string is: %s", __PRETTY_FUNCTION__, aCompareString);
		}
		return NO;
	}

	return YES;
}

RomType oldWorldRomType(NSString* _Nonnull romPath) {
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

	// See line 681 in rom_patches.cpp to see how to check if these are ROMs we can use.
	int aFileDescriptor = open([romPath UTF8String], O_RDONLY);
	if (aFileDescriptor < 0) {
		// Failed to open --?
		NSLog (@"%s Failed to open file for reading: %@", __PRETTY_FUNCTION__, romPath);
		return RomTypeInvalid;
	}
	char aBuffer[17];
	lseek(aFileDescriptor, 0x30d064, SEEK_SET);		// Magic location for the boot type string
	size_t anActualRead = read(aFileDescriptor, (void *)aBuffer, 16);
	close(aFileDescriptor);

	if (anActualRead < 16) {		 // how did this happen --?
		NSLog (@"%s Failed to read 16 bytes: %@", __PRETTY_FUNCTION__, romPath);
		return RomTypeInvalid;
	}

	if (strncmp(aBuffer, "Boot TNT", 8)) {
		return RomTypeOldWorldTnt;
	} else if (strncmp(aBuffer, "Boot Alchemy", 12)) {
		return RomTypeOldWorldAlchemy;
	} else if (strncmp(aBuffer, "Boot Zanzibar", 13)) {
		return RomTypeOldWorldZanzibar;
	} else if (strncmp(aBuffer, "Boot Gazelle", 12)) {
		return RomTypeOldWorldGazelle;
	} else if (strncmp(aBuffer, "Boot Gossamer", 13)) {
		return RomTypeOldWorldGossamer;
	}

	return RomTypeInvalid;
}

RomType validateROM(NSString* _Nonnull romPath) {
	if (isNewWorldRom(romPath)) {
		return RomTypeNewWorld;
	}

	return oldWorldRomType(romPath);
}
