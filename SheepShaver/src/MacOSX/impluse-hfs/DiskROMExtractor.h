//
//  DiskROMExtractor.h
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-10-24.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface DiskROMExtractor: NSObject

+ (BOOL)extractRomFromDiskUrl: (NSURL*)fromUrl toUrl:(NSURL*)toUrl;

@end

NS_ASSUME_NONNULL_END
