#if defined(__x86_64__)
#ifdef __APPLE__
	#include "basic-dyngen-ops-x86_64_macos.hpp"
#else
	#include "basic-dyngen-ops-x86_64.hpp"
#endif
#elif defined(__i386__)
	#include "basic-dyngen-ops-x86_32.hpp"
#elif defined(__aarch64__)
	#include "basic-dyngen-ops-arm64.hpp"
#else
	#error Unknown platform
#endif
