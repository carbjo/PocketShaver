//
//  MemoryDump.cpp
//  PocketShaver
//
//  Created by Carl Björkman on 2026-03-28.
//

#include <cstdio>
#include <cstdlib>
#include "sysdeps.h"
#include "cpu_emulation.h"
#include "MiscellaneousSettingsObjCCppHeader.h"

void cpp_dump_mem(const char *path) {
	const size_t size = 1024 * 1024 * objc_getRamInMb();
	void *data = (void *)Mac2HostAddr(0x10000000);
	if(data != NULL)
	{
		FILE *out = fopen(path, "wb");
		if(out != NULL)
		{
			size_t to_go = size;
			fwrite(data, to_go, 1, out);
		}
		fclose(out);
	}
}
