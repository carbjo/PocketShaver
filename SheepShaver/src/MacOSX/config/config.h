#if defined(KPX_IOS)
	#if defined(__x86_64__)
		#include "config-ios-x86_64.h"
	#elif defined(__aarch64__)
		#include "config-ios-aarch64.h"
	#else
		#error Unknown iOS platform
	#endif
#else
#if defined(__x86_64__)
	#include "config-macosx-x86_64.h"
#elif defined(__i386__)
	#include "config-macosx-x86_32.h"
#elif defined(__ppc__)
	#include "config-macosx-ppc_32.h"
#elif defined(__aarch64__)
	#include "config-macosx-aarch64.h"
	#elif
		#error Unknown Mac platform
	#endif
#endif
