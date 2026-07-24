#if defined(__x86_64__)
#ifdef __APPLE__
#ifdef MEM_BULK
	/* Uniform guest->host translation via VMBaseDiff (PocketShaver Catalyst) */
	#include "ppc-dyngen-ops-x86_64_macos_membulk.hpp"
#else
	#include "ppc-dyngen-ops-x86_64_macos.hpp"
#endif
#else
	#include "ppc-dyngen-ops-x86_64.hpp"
#endif
#elif defined(__i386__)
	#include "ppc-dyngen-ops-x86_32.hpp"
#elif defined(__aarch64__)
	#include "ppc-dyngen-ops-arm64.hpp"
#else
	#error Unknown platform
#endif
