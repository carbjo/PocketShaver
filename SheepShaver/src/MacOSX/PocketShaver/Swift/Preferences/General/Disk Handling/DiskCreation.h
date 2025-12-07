//
//  DiskCreation.h
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-01.
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C"
#endif
BOOL objc_createDiskWithName(NSString *inName, NSInteger sizeInMb);
