//
//  MemoryDumpObjC.mm
//  PocketShaver
//
//  Created by Carl Björkman on 2026-03-28.
//

#import <Foundation/Foundation.h>
#import "MemoryDump.h"
#import "PocketShaver-Swift-ObjCHeader.h"

void objc_dump_memory() {
	NSString *path = [[[NSFileManager documentUrl] URLByAppendingPathComponent:@"memdump"] path];
	const char *pathCString = [path cStringUsingEncoding:NSISOLatin1StringEncoding];
	cpp_dump_mem(pathCString);
}
