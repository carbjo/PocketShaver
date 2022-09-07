//
//  DiskTypeiOS.h
//  SheepShaveriOS
//
//  Created by Tom Padula on 9/6/22.
//

#import "DiskType.h"

NS_ASSUME_NONNULL_BEGIN

@interface DiskTypeiOS : DiskType

@property (readwrite, nonatomic) BOOL disable;

- (NSString*) description;

@end

NS_ASSUME_NONNULL_END
