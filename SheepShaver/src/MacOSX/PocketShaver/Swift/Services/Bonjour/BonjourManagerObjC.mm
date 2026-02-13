//
//  BonjourManagerObjC.mm
//  PocketShaver
//
//  Created by Carl Björkman on 2026-02-09.
//

#import "BonjourManagerObjC.h"
#import "BonjourManagerObjCCppHeader.h"
#import "PocketShaver-Swift-ObjCHeader.h"

void objc_bonjourReceiveData(NSData *data) {
	unsigned char *rawData = (unsigned char *) data.bytes;
	int length = (int) data.length;
	receive_rawdata_func(rawData, length);
}

void objc_bonjourSendData(unsigned char *rawData, int length) {
	NSData *data = [NSData dataWithBytes:rawData length:length];
	[BonjourManagerObjCProxy sendWithData:data];
}
