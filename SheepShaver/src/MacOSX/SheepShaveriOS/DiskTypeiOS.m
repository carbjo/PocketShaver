//
//  DiskTypeiOS.m
//  SheepShaveriOS
//
//  Created by Tom Padula on 9/6/22.
//

#import "DiskTypeiOS.h"

@implementation DiskTypeiOS

-(NSString*)description {
	return [NSString stringWithFormat:@"DiskType, path:%@ isCDROM:%hhd disable:%hhd", _path, _isCDROM, self.disable];
}

@end
