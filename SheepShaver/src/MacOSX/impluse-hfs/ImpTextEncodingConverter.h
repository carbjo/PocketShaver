//
//  ImpTextEncodingConverter.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-02.
//

#import <Foundation/Foundation.h>
#import "hfs-ios.h"

@interface ImpTextEncodingConverter : NSObject

#pragma mark Conversion


- (NSString *_Nonnull const) stringForPascalString:(ConstStr31Param _Nonnull const)pascalString;

///Create an NSString from an HFSUniStr255 in big-endian byte order. Uses stringFromHFSUniStr255:swapBytes:, instructing it to swap if the native byte order is not big-endian.
- (NSString *_Nonnull const) stringFromHFSUniStr255:(ConstHFSUniStr255Param _Nonnull const)unicodeName;


#pragma mark String escaping

- (NSString *_Nonnull const) stringByEscapingString:(NSString *_Nonnull const)inStr;

@end
