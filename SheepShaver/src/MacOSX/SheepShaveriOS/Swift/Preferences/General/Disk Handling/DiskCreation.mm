//
//  DiskCreation.mm
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-01.
//

#import "DiskCreation.h"

BOOL objc_createDiskWithName(NSString *inName, NSInteger sizeInMb)
{
	NSString* aDocsDirectory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	NSString* aFilePath = [aDocsDirectory stringByAppendingPathComponent:inName];

	// Use the file manager to create the file, then use truncate to set the length.
	char aBytes[1024];
	bzero (aBytes, 1024);
	NSData* aData = [NSData dataWithBytes:aBytes length:1024];
	NSNumber *fileSizeInMB = @(sizeInMb);
	NSNumber *oneMB = @(1048576);
	NSNumber *fileSizeInBytes = @(fileSizeInMB.longValue * oneMB.longValue);

	BOOL fileCreationSuccesful = [[NSFileManager defaultManager] createFileAtPath:aFilePath contents:aData attributes:@{NSFileType: NSFileTypeRegular}];

	if (!fileCreationSuccesful) {
		return NO;
	}

	int aFileDescriptor = truncate(aFilePath.UTF8String, fileSizeInBytes.longValue);

	BOOL succesful = aFileDescriptor >= 0;

	return succesful;
}

