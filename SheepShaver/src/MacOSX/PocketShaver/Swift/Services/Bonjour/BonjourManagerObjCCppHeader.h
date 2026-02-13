//
//  BonjourManagerObjCCppHeader.h
//  PocketShaver
//
//  Created by Carl Björkman on 2026-02-09.
//

extern void receive_rawdata_func(unsigned char *data, int length);

void objc_bonjourSendData(unsigned char *rawData, int length);
