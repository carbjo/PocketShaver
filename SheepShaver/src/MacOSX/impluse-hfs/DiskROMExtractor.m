//
//  DiskROMExtractor.m
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-10-24.
//

#import "DiskROMExtractor.h"
#import "ImpHFSExtractor.h"

@implementation DiskROMExtractor

+ (BOOL)extractRomFromDiskUrl:(NSURL *)fromUrl toUrl:(NSURL *)toUrl {

	ImpHFSExtractor *extractor = [ImpHFSExtractor new];
	extractor.sourceDevice = fromUrl;
	extractor.quarryNameOrPath = @":System Folder:Mac OS ROM";
	extractor.shouldCopyToDestination = YES;
	extractor.destinationPath = toUrl.path;

	NSError *_Nullable error = nil;

	[extractor performExtractionOrReturnError:&error];

	if (error) {
		NSLog(@"-- extraction error: %@", error);
	}

	return error == nil;
}

@end
