//
//  DiskROMExtractor.m
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-10-24.
//

#import "DiskROMExtractor.h"
#import "ImpHFSExtractor.h"

@implementation DiskROMExtractor

+ (BOOL)extractRomFromDiskUrl:(NSURL *)fromUrl toUrl:(NSURL *)toUrl quarryNameOrPath:(NSString*)quarryNameOrPath {

	ImpHFSExtractor *extractor = [ImpHFSExtractor new];
	extractor.sourceDevice = fromUrl;
	extractor.quarryNameOrPath = quarryNameOrPath;
	extractor.shouldCopyToDestination = YES;
	extractor.destinationPath = toUrl.path;

	NSError *_Nullable error = nil;

	[extractor performExtractionOrReturnError:&error];

	if (error) {
		NSLog(@"- Extraction error %@", error);
	}

	return error == nil;
}

+ (BOOL)extractRomFromDiskUrl:(NSURL *)fromUrl toUrl:(NSURL *)toUrl {

	if ([self extractRomFromDiskUrl:fromUrl toUrl:toUrl quarryNameOrPath:@":System Folder:Mac OS ROM"]) {
		return YES;
	}

	NSLog(@"- Extracting from absolute path failed. Trying full search.");

	return [self extractRomFromDiskUrl:fromUrl toUrl:toUrl quarryNameOrPath:@"Mac OS ROM"];
}

@end
