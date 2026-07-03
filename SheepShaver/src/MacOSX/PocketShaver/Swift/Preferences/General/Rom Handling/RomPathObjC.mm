//
//  RomPathObjC.mm
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-29.
//

#import <Foundation/Foundation.h>
#include "utils_ios.h"

const char *objc_romPath(void) {
	// Derive from document_directory() so the ROM follows the same relocation
	// as the prefs/disks (the container's Documents on iOS, ~/PocketShaver
	// Home/Documents on Mac Catalyst).
	NSString* docsDirectory = [NSString stringWithUTF8String:document_directory()];
	NSString *romPath = [docsDirectory stringByAppendingPathComponent:@".rom"];
	const char *returnString = [romPath cStringUsingEncoding:NSISOLatin1StringEncoding];

	return returnString;
};
