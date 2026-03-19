//
//  ImpTextEncodingConverter.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-02.
//

#import "ImpTextEncodingConverter.h"

#import "ImpPrintf.h"
#import "ImpByteOrder.h"
#import "ImpErrorUtilities.h"

enum {
	ImpExtFinderFlagsHasEmbeddedScriptCodeMask = 1 << 15,
	ImpExtFinderFlagsScriptCodeMask = 0x7f << 8,
};

@implementation ImpTextEncodingConverter
{
}


- (NSString *_Nonnull const) stringForPascalString:(ConstStr31Param)pascalString {
    int numChars = pascalString[0];

    char *cStr = (char*) malloc(sizeof(char)*numChars+1);
    for (int i=0;i<numChars;i++) {
        cStr[i] = pascalString[i+1];
    }
    cStr[numChars] = 0;

    NSString *str = [NSString stringWithCString:cStr encoding:NSMacOSRomanStringEncoding];

    return str;
}

- (NSString *_Nonnull const) stringFromHFSUniStr255:(ConstHFSUniStr255Param)unicodeName swapBytes:(bool const)shouldSwap {
	UniCharCount const length = shouldSwap ? OSSwapInt16(unicodeName->length) : unicodeName->length;
	if (length == 0) {
		return @"";
	}
	if (shouldSwap) {
		unichar swapped[256];
		UniCharCount const clampedLen = (length <= 255) ? length : 255;
		for (UniCharCount i = 0; i < clampedLen; i++) {
			swapped[i] = OSSwapInt16(unicodeName->unicode[i]);
		}
		return [NSString stringWithCharacters:swapped length:clampedLen];
	} else {
		return [NSString stringWithCharacters:unicodeName->unicode length:length];
	}
}
- (NSString *_Nonnull const) stringFromHFSUniStr255:(ConstHFSUniStr255Param _Nonnull const)unicodeName {
#if __LITTLE_ENDIAN__
	bool const shouldSwap = true;
#else
	bool const shouldSwap = false;
#endif
	return [self stringFromHFSUniStr255:unicodeName swapBytes:shouldSwap];
}

#pragma mark String escaping

- (NSString *_Nonnull const) stringByEscapingString:(NSString *_Nonnull const)inString {
	unichar escapedBuf[1024];
	NSUInteger escapedLen = 0;

	unichar unescapedBuf[256];
	NSUInteger unescapedLen = inString.length;
	[inString getCharacters:unescapedBuf range:(NSRange){ 0, unescapedLen }];

	for (NSUInteger unescapedChIdx = 0; unescapedChIdx < unescapedLen; ++unescapedChIdx) {
		unichar const ch = unescapedBuf[unescapedChIdx];
		switch (ch) {
			case 0:
				escapedBuf[escapedLen++] = '\\';
				escapedBuf[escapedLen++] = '0';
				break;
			case '\b':
				escapedBuf[escapedLen++] = '\\';
				escapedBuf[escapedLen++] = 'b';
				break;
			case '\t':
				escapedBuf[escapedLen++] = '\\';
				escapedBuf[escapedLen++] = 't';
				break;
			case 0xa:
				escapedBuf[escapedLen++] = '\\';
				escapedBuf[escapedLen++] = 'r';
				break;
			case '\v':
				escapedBuf[escapedLen++] = '\\';
				escapedBuf[escapedLen++] = 'v';
				break;
			case '\f':
				escapedBuf[escapedLen++] = '\\';
				escapedBuf[escapedLen++] = 'f';
				break;
			case 0xd:
				escapedBuf[escapedLen++] = '\\';
				escapedBuf[escapedLen++] = 'n';
				break;

			case 0x01:
			case 0x02:
			case 0x03:
			case 0x04:
			case 0x05:
			case 0x06:
			case 0x07:
			case 0x0e:
			case 0x0f:
			case 0x10:
			case 0x11:
			case 0x12:
			case 0x13:
			case 0x14:
			case 0x15:
			case 0x16:
			case 0x17:
			case 0x18:
			case 0x19:
			case 0x1a:
			case 0x1b:
			case 0x1c:
			case 0x1d:
			case 0x1e:
			case 0x1f:
			case 0x7f:
				escapedBuf[escapedLen++] = '\\';
				escapedBuf[escapedLen++] = 'x';
				escapedBuf[escapedLen++] = '0' + ((ch >> 4) & 0xf);
				escapedBuf[escapedLen++] = '0' + ((ch >> 0) & 0xf);
				break;

			default:
				escapedBuf[escapedLen++] = ch;
				break;
		}
	}

	return [NSString stringWithCharacters:escapedBuf length:escapedLen];
}

@end
