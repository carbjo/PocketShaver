//
//  BonjourManagerObjCCppHeader.h
//  PocketShaver
//
//  Created by Carl Björkman on 2026-02-09.
//

extern void receive_rawdata_func(uint8 *data, int length);

void objc_bonjourSendData(uint8 *rawData, int length);
