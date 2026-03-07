//
//  NetworkSettingsObjC.mm
//  PocketShaver
//
//  Created by Carl Björkman on 2026-02-13.
//

#import "PocketShaver-Swift-ObjCHeader.h"
#import "NetworkSettingsObjCCppHeader.h"
#include <malloc/malloc.h>

bool objc_getNetworkServiceTypeIsBonjour() {
	return [NetworkSettingsObjCProxy getNetworkServiceTypeIsBonjour];
}

void objc_fetchHardwareAddressData(uint8 * p) {
	NSData *hardwareAddressData = [NetworkSettingsObjCProxy getHardwareAddressData];
	if (!hardwareAddressData) {
		NSLog(@"- no hardwareAddressData found!");
		return;
	}

	memcpy(p, hardwareAddressData.bytes, 6);
}

