//
//  ClipboardSharing.mm
//  PocketShaver
//
//  Created by Carl Björkman on 2026-07-19.
//

#import "utils_ios.h"
#import "ClipboardSharing.h"

void objc_copyHostClipboardToGuestScrap() {
	SyncHostPasteboardToPending();
}

void objc_copyGuestScrapToHostClipboard() {
	WritePendingGuestScrapToHostPasteboard();
}
