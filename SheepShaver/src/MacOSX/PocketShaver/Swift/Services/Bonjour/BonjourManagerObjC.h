//
//  BonjourManagerObjC.h
//  PocketShaver
//
//  Created by Carl Björkman on 2026-02-09.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class IpAddress;

#ifdef __cplusplus
extern "C"
#endif
void objc_bonjourReceiveData(NSData *data);

#ifdef __cplusplus
extern "C"
#endif
void objc_sendBootReply(NSData *requestData, IpAddress *routerIpAddress, IpAddress *offeredIpAddress, BOOL thisDeviceIsRequesting, BOOL isAcknowledgement);

#ifdef __cplusplus
extern "C"
#endif
void objc_sendArpReply(NSData *requestData, NSData *requestedHardwareAddressData, BOOL thisDeviceIsRequesting);

NS_ASSUME_NONNULL_END
