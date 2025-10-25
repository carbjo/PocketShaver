//
//  RomPathObjC.mm
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-29.
//

#import <Foundation/Foundation.h>

const char *objc_romPath(void) {
	NSString* docsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	NSString *romPath = [docsDirectory stringByAppendingPathComponent:@".rom"];
	const char *returnString = [romPath cStringUsingEncoding:NSISOLatin1StringEncoding];

	return returnString;
};
