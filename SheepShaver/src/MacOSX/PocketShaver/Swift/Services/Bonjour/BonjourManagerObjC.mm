//
//  BonjourManagerObjC.mm
//  PocketShaver
//
//  Created by Carl Björkman on 2026-02-09.
//

#import <sysdeps.h>
#import "BonjourManagerObjC.h"
#import "BonjourManagerObjCCppHeader.h"
#import "PocketShaver-Swift-ObjCHeader.h"
#import "UdpChecksum.h"

#define BONJOUR_BOOT_PACKET_LENGTH 310
#define BONJOUR_ARP_PACKET_LENGTH 42

void sendBootReply(uint8 *request, IpAddress *routerIpAddress, IpAddress *offeredIpAddress, BOOL thisDeviceIsRequesting, BOOL isAcknowledgement);
void sendArpReply(uint8 *request, uint8 *requestedHardwareAddress, BOOL thisDeviceIsRequesting);
uint16 ipv4HeaderChecksum(uint16 *addr, int count);

void objc_bonjourReceiveData(NSData *data) {
	uint8 *rawData = (uint8*) data.bytes;
	int length = (int) data.length;

	if (length >= 285 &&
		// Option 53 (DHCP Message Type) = DHCPACK
		rawData[282] == 0x35 &&
		rawData[283] == 0x01 &&
		rawData[284] == 0x05
		) {
			IpAddress *ipAddress = [[IpAddress alloc] init:rawData[30] :rawData[31] :rawData[32] :rawData[33]];
			dispatch_async(dispatch_get_main_queue(), ^{
				[NetworkSettingsObjCProxy reportGotIpAddress:ipAddress];
			});
		}

	receive_rawdata_func(rawData, length);
}

void objc_bonjourSendData(uint8 *rawData, int length) {
	NSData *data = [NSData dataWithBytesNoCopy:rawData length:length freeWhenDone:NO]; // MALLOC??
	[BonjourManagerObjCProxy sendToRouter:data];
}

void objc_sendBootReply(NSData *requestData, IpAddress *routerIpAddress, IpAddress *offeredIpAddress, BOOL thisDeviceIsRequesting, BOOL isAcknowledgement) {
	sendBootReply((uint8*) requestData.bytes, routerIpAddress, offeredIpAddress, thisDeviceIsRequesting, isAcknowledgement);
}


void sendBootReply(uint8 *request, IpAddress *routerIpAddress, IpAddress *offeredIpAddress, BOOL thisDeviceIsRequesting, BOOL isAcknowledgement) {

	uint8 response[BONJOUR_BOOT_PACKET_LENGTH];

	for (int i=0;i<BONJOUR_BOOT_PACKET_LENGTH;i++) {
		response[i] = 0;
	}

	// ==== Ethernet header ====
	// Destination MAC = Source MAC of discover/request message
	response[0] = request[6];
	response[1] = request[7];
	response[2] = request[8];
	response[3] = request[9];
	response[4] = request[10];
	response[5] = request[11];

	// Source MAC
	NSData *routerHardwareAddressData = [NetworkSettingsObjCProxy getRouterHardwareAddressData];
	uint8 *routerHardwareAddress = (uint8*)routerHardwareAddressData.bytes;
	response[6] = routerHardwareAddress[0];
	response[7] = routerHardwareAddress[1];
	response[8] = routerHardwareAddress[2];
	response[9] = routerHardwareAddress[3];
	response[10] = routerHardwareAddress[4];
	response[11] = routerHardwareAddress[5];

	// Ether type = Ethernet
	response[12] = 0x08;
	response[13] = 0x00;


	// ==== IPv4 header ====
	// IPv4 header length
	response[14] = 0x45;

	response[15] = 0x10;

	// Total length (UDP header + payload)
	uint16 updHeaderAndPayloadLength = BONJOUR_BOOT_PACKET_LENGTH - 14;
	response[16] = (updHeaderAndPayloadLength >> 8) & 0xff;
	response[17] = updHeaderAndPayloadLength & 0xff;

	// TTL = 60
	response[22] = 0x40;

	// Protocol = 17 UDP
	response[23] = 0x11;

	// Source address
	response[26] = routerIpAddress.byte0;
	response[27] = routerIpAddress.byte1;
	response[28] = routerIpAddress.byte2;
	response[29] = routerIpAddress.byte3;

	// Destination address
	if (request[26] == 0x00 &&
		request[27] == 0x00 &&
		request[28] == 0x00 &&
		request[29] == 0x00) {
		response[30] = offeredIpAddress.byte0;
		response[31] = offeredIpAddress.byte1;
		response[32] = offeredIpAddress.byte2;
		response[33] = offeredIpAddress.byte3;
	} else {
		response[30] = request[26];
		response[31] = request[27];
		response[32] = request[28];
		response[33] = request[29];
	}

	// IPv4 header checksum
	uint16 *ipv4HeaderChecksumPtr = (uint16*) (response + 24);
	uint16 *ipv4Header = (uint16*) (response + 14);
	*ipv4HeaderChecksumPtr = ipv4HeaderChecksum(ipv4Header, 20);

	// ==== UDP header ====
	// Source port = 67
	response[34] = 0x00;
	response[35] = 0x43;

	// Destination port = 68
	response[36] = 0x00;
	response[37] = 0x44;

	// Total length (payload)
	uint16 payloadLength = BONJOUR_BOOT_PACKET_LENGTH - 14 - 20;
	response[38] = (payloadLength >> 8) & 0xff;
	response[39] = payloadLength & 0xff;


	// ==== DHCP payload ====
	// OP = DHCPOFFER
	response[42] = 0x02;

	// HTYPE = Ethernet
	response[43] = 0x01;

	// HLEN = 6
	response[44] = 0x06;

	// XID = copy from discover/request message
	response[46] = request[46];
	response[47] = request[47];
	response[48] = request[48];
	response[49] = request[49];

	// YIADDR
	response[58] = offeredIpAddress.byte0;
	response[59] = offeredIpAddress.byte1;
	response[60] = offeredIpAddress.byte2;
	response[61] = offeredIpAddress.byte3;

	// SIADDR
	response[62] = routerIpAddress.byte0;
	response[63] = routerIpAddress.byte1;
	response[64] = routerIpAddress.byte2;
	response[65] = routerIpAddress.byte3;

	// CHADDR = copy from discover/request message
	response[70] = request[70];
	response[71] = request[71];
	response[72] = request[72];
	response[73] = request[73];
	response[74] = request[74];
	response[75] = request[75];

	// Magic cookie
	response[278] = 0x63;
	response[279] = 0x82;
	response[280] = 0x53;
	response[281] = 0x63;

	// ==== DHCP options ====
	// First option: DHCP Message Type
	response[282] = 0x35; // Option 53 (DHCP Message Type)
	response[283] = 0x01; // 1 octet
	if (isAcknowledgement) {
		response[284] = 0x05; // DHCPACK
	} else {
		response[284] = 0x02; // DHCPOFFER
	}


	// Second option: DHCP server identifier = router
	response[285] = 0x36; // Option 54 (DHCP server identifier)
	response[286] = 0x04; // 4 octets
	// Server identier =  Router IP address
	response[287] = routerIpAddress.byte0;
	response[288] = routerIpAddress.byte1;
	response[289] = routerIpAddress.byte2;
	response[290] = routerIpAddress.byte3;

	// Third option: Subnet mask = 255.255.255.0
	response[291] = 0x01; // Option 1 (Subnet mask)
	response[292] = 0x04; // 4 octets
	// Subnet mask = 255.255.255.0
	response[293] = 0xff;
	response[294] = 0xff;
	response[295] = 0xff;
	response[296] = 0x00;

	// Fourth option: Router = 10.8.0.100
	response[297] = 0x03; // Option 3 (Router)
	response[298] = 0x04; // 4 octets
	// Router = 10.8.0.100
	response[299] = routerIpAddress.byte0;
	response[300] = routerIpAddress.byte1;
	response[301] = routerIpAddress.byte2;
	response[302] = routerIpAddress.byte3;

	// Sixth option: Address time = 24 hours
	response[303] = 0x33; // Option 51 (Address time)
	response[304] = 0x04; // 4 octets
	// Address time = 86400 seconds (24h)
	response[305] = 0x00;
	response[306] = 0x01;
	response[307] = 0x50;
	response[308] = 0x80;

	// End
	response[309] = 0xff;

	//	// Fifth option: DNS = router
	//	dhcpOffer[303] = 0x06; // Option 6 (DNS)
	//	dhcpOffer[304] = 0x04; // 4 octets
	//	// Router = server IP address
	//	dhcpOffer[305] = dnsIpAddress[0];
	//	dhcpOffer[306] = dnsIpAddress[1];
	//	dhcpOffer[307] = dnsIpAddress[2];
	//	dhcpOffer[308] = dnsIpAddress[3];


	// UPD CHECKSUM
	net_checksum_calculate(response, BONJOUR_BOOT_PACKET_LENGTH);


	if (isAcknowledgement) {
		printf("===== DHCP ACK =====\n");
	} else {
		printf("===== DHCP OFFER =====\n");
	}

//    for (int i = 0; i< BONJOUR_BOOT_PACKET_LENGTH; i++) {
//        printf("%02x", response[i]);
//    }
	printf("\n");

	if (thisDeviceIsRequesting) {
		// Emulator on this device was the source of the request. Send reply back there.
		NSData *data = [NSData dataWithBytes:response length:BONJOUR_BOOT_PACKET_LENGTH];
		objc_bonjourReceiveData(data);
	} else {
		// Other device was source of the request, send via Bonjour.
		objc_bonjourSendData(response, BONJOUR_BOOT_PACKET_LENGTH);
	}


	printf("- Send complete \n");
}

void objc_sendArpReply(NSData *requestData, NSData *requestedHardwareAddressData, BOOL thisDeviceIsRequesting) {
	sendArpReply((uint8*) requestData.bytes, (uint8*) requestedHardwareAddressData.bytes, thisDeviceIsRequesting);
}

void sendArpReply(uint8 *request, uint8 *requestedHardwareAddress, BOOL thisDeviceIsRequesting) {

	uint8 response[BONJOUR_ARP_PACKET_LENGTH];

	for (int i=0;i<BONJOUR_ARP_PACKET_LENGTH;i++) {
		response[i] = 0;
	}

	// ==== Ethernet header ====
	// Destination = requesting device
	response[0] = request[6];
	response[1] = request[7];
	response[2] = request[8];
	response[3] = request[9];
	response[4] = request[10];
	response[5] = request[11];

	// Source = router
	NSData *routerHardwareAddressData = [NetworkSettingsObjCProxy getRouterHardwareAddressData];
	uint8 *routerHardwareAddress = (uint8*)routerHardwareAddressData.bytes;
	response[6] = routerHardwareAddress[0];
	response[7] = routerHardwareAddress[1];
	response[8] = routerHardwareAddress[2];
	response[9] = routerHardwareAddress[3];
	response[10] = routerHardwareAddress[4];
	response[11] = routerHardwareAddress[5];

	// Type = ARP
	response[12] = 0x08;
	response[13] = 0x06;

	// ==== ARP payload ====
	// Hardware type = Ethernet
	response[14] = 0x00;
	response[15] = 0x01;

	// Protocol type = IPv4
	response[16] = 0x08;
	response[17] = 0x00;

	// Hardware size = 6
	response[18] = 0x06;

	// Protocol size = 4
	response[19] = 0x04;

	// Opcode = reply
	response[20] = 0x00;
	response[21] = 0x02;

	// Sender hardware address = the hardware address asked for
	response[22] = requestedHardwareAddress[0];
	response[23] = requestedHardwareAddress[1];
	response[24] = requestedHardwareAddress[2];
	response[25] = requestedHardwareAddress[3];
	response[26] = requestedHardwareAddress[4];
	response[27] = requestedHardwareAddress[5];

	// Sender ip address = the ip address asked for
	response[28] = request[38];
	response[29] = request[39];
	response[30] = request[40];
	response[31] = request[41];

	// Target hardware address = hardware address of requesting device
	response[32] = request[22];
	response[33] = request[23];
	response[34] = request[24];
	response[35] = request[25];
	response[36] = request[26];
	response[37] = request[27];

	// Target ip address = the ip address of requesting device
	response[38] = request[28];
	response[39] = request[29];
	response[40] = request[30];
	response[41] = request[31];

	printf("===== ARP RESPONSE =====\n");

//	for (int i = 0; i< BONJOUR_ARP_PACKET_LENGTH; i++) {
//		printf("%02x", response[i]);
//	}
	printf("\n");

	if (thisDeviceIsRequesting) {
		// Emulator on this device was the source of the request. Send reply back there.
		receive_rawdata_func(response, BONJOUR_ARP_PACKET_LENGTH);
	} else {
		// Other device was source of the request, send via Bonjour.
		objc_bonjourSendData(response, BONJOUR_ARP_PACKET_LENGTH);
	}

	printf("- Send complete \n");
}

uint16 ipv4HeaderChecksum(uint16 *addr, int count) {
	/* Compute Internet Checksum for "count" bytes
	 * beginning at location "addr".
	 */
	int64 sum = 0;

	while( count > 1 )  {
		/* This is the inner loop */
		sum += * (uint16 *) addr++;
		count -= 2;
	}

	/*  Add left-over byte, if any */
	if ( count > 0 )
		sum += * (uint8 *) addr;

	/*  Fold 32-bit sum to 16 bits */
	while (sum>>16)
		sum = (sum & 0xffff) + (sum >> 16);

	uint16 result = (uint16) ~sum;
	printf("- IPv4 header checksum: %d\n", result);
	return result;
}

