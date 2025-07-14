//
//  SSDiskManager.h
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-14.
//

#import <UIKit/UIKit.h>

#import "DiskTypeiOS.h"

@class SSDiskManager;

@interface SSDiskManager : NSObject

@property (readonly, nonatomic) NSMutableArray<DiskTypeiOS*>* diskArray;

- (void) loadDiskData;
- (void) writePrefs;

@end

