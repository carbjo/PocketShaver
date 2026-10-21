/*
 *  jit-cache.cpp - Translation cache management
 *
 *  Kheperix (C) 2003-2005 Gwenole Beauchesne
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#include "sysdeps.h"
#include "vm_alloc.h"
#include "cpu/jit/jit-wx.hpp"

/*
 *  W^X code-memory primitives (see jit-wx.hpp). Compiled regardless of
 *  ENABLE_DYNGEN so the write path can be validated in builds that do
 *  not yet carry a JIT backend.
 */

#if defined(__APPLE__) && defined(__aarch64__)

#include <TargetConditionals.h>
#include <pthread.h>
#include <sys/mman.h>
#include <libkern/OSCacheControl.h>

#if TARGET_OS_IPHONE && !TARGET_OS_MACCATALYST && !TARGET_OS_SIMULATOR
#define JIT_WX_IOS_DUAL_MAP 1
#else
#define JIT_WX_IOS_DUAL_MAP 0
#endif

#if JIT_WX_IOS_DUAL_MAP

#include <dlfcn.h>
#include <errno.h>
#include <stdarg.h>
#include <time.h>
#include <unistd.h>
#include <os/log.h>
#include <mach/mach.h>
#include <CoreFoundation/CoreFoundation.h>

/*
 *  The handshake usually runs with no Xcode console attached (StikDebug
 *  launches the app), so every step goes to the unified log and to
 *  Documents/jit-log.txt, which the Files app can read back.
 */
static void jit_ios_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void jit_ios_log(const char *fmt, ...)
{
	// Called from the main thread and the acquisition thread
	static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
	static os_log_t handle;
	static FILE *file;
	static bool file_opened;

	char message[512];
	va_list args;
	va_start(args, fmt);
	vsnprintf(message, sizeof(message), fmt, args);
	va_end(args);

	pthread_mutex_lock(&lock);
	if (handle == NULL)
		handle = os_log_create("com.pocketshaver.jit", "ios");
	os_log_error(handle, "JIT: %{public}s", message);

	if (!file_opened) {
		file_opened = true;
		const char *home = getenv("HOME");
		if (home != NULL) {
			char path[1024];
			snprintf(path, sizeof(path), "%s/Documents/jit-log.txt", home);
			file = fopen(path, "a");
			if (file != NULL)
				fprintf(file, "---- pid %d\n", getpid());
		}
	}
	if (file != NULL) {
		time_t now = time(NULL);
		struct tm local;
		localtime_r(&now, &local);
		fprintf(file, "%02d:%02d:%02d %s\n", local.tm_hour, local.tm_min, local.tm_sec, message);
		// The next step may crash the process
		fflush(file);
	}
	pthread_mutex_unlock(&lock);
}
#define JIT_IOS_LOG(...) jit_ios_log(__VA_ARGS__)

void jit_ios_note(const char *message)
{
	JIT_IOS_LOG("%s", message);
}

/*
 *  iOS devices: one code arena, reserved once by jit_ios_acquire and never
 *  released, since a TXM device cannot prepare a new region after the
 *  debugger detaches. The translation cache borrows it via jit_wx_map.
 *  Two ways to write into it:
 *
 *  - iOS 26 TXM devices: StikDebug prepares an RX region and an RW alias
 *    of the same pages is written while the RX view runs.
 *  - Earlier iOS: the process maps the arena itself, and code signing
 *    rejects executing a page that also has a writable alias, even when
 *    debugged. Each publish flips the touched pages RW, copies, and flips
 *    them back to RX instead. Only the CPU thread publishes and runs
 *    translated code, so no other thread can execute from a page while
 *    it is writable.
 */

// Covers the default translation cache (32 MB + guard, 16 KB rounded;
// see the static_assert by JIT_CACHE_SIZE). StikDebug touches every page
// while preparing it, so keep the slack small.
static const uint32 JIT_IOS_ARENA_SIZE = 33 * 1024 * 1024;

static uint8 *g_ios_rx;
static uint8 *g_ios_rw;
static bool g_ios_arena_in_use;

static bool jit_ios_in_arena(void *exec_addr, uint32 len)
{
	uint8 *p = (uint8 *)exec_addr;
	return g_ios_rx != NULL && p >= g_ios_rx && p + len <= g_ios_rx + JIT_IOS_ARENA_SIZE;
}

void *jit_wx_map(uint32 size)
{
	if (g_ios_rx == NULL || g_ios_arena_in_use || size > JIT_IOS_ARENA_SIZE) {
		JIT_IOS_LOG("map(%u) refused: arena=%p in_use=%d", size, g_ios_rx, g_ios_arena_in_use);
		return NULL;
	}
	g_ios_arena_in_use = true;
	JIT_IOS_LOG("map(%u) -> %p", size, g_ios_rx);
	return g_ios_rx;
}

void jit_wx_unmap(void *base, uint32 size)
{
	// The arena outlives every translation cache built on it
	if (base != NULL && base == g_ios_rx)
		g_ios_arena_in_use = false;
}

bool jit_wx_publish(void *dst, const void *src, uint32 len)
{
	if (!jit_ios_in_arena(dst, len))
		return false;

	if (g_ios_rw != NULL)
		memcpy(g_ios_rw + ((uint8 *)dst - g_ios_rx), src, len);
	else {
		const uintptr page_mask = vm_page_size - 1;
		uintptr start = (uintptr)dst & ~page_mask;
		size_t span = (((uintptr)dst + len + page_mask) & ~page_mask) - start;
		if (mprotect((void *)start, span, PROT_READ | PROT_WRITE) != 0) {
			JIT_IOS_LOG("publish: mprotect(rw) failed: errno=%d", errno);
			return false;
		}
		memcpy(dst, src, len);
		if (mprotect((void *)start, span, PROT_READ | PROT_EXEC) != 0) {
			JIT_IOS_LOG("publish: mprotect(rx) failed: errno=%d", errno);
			return false;
		}
	}
	sys_icache_invalidate(dst, len);
	return true;
}

bool jit_wx_available(void)
{
	// Not cached: the arena appears only after the StikDebug handshake
	return g_ios_rx != NULL;
}

#else

struct jit_wx_write_ctx {
	void *dst;
	const void *src;
	size_t len;
};

static int jit_wx_write_cb(void *arg)
{
	jit_wx_write_ctx *ctx = (jit_wx_write_ctx *)arg;
	memcpy(ctx->dst, ctx->src, ctx->len);
	return 0;
}

// May be invoked only once per executable; this TU is that one place
#ifdef PTHREAD_JIT_WRITE_ALLOW_CALLBACKS_NP
PTHREAD_JIT_WRITE_ALLOW_CALLBACKS_NP(jit_wx_write_cb);
#endif

static bool jit_wx_api_available(void)
{
	if (__builtin_available(macOS 11.4, iOS 17.4, *))
		return true;
	return false;
}

void *jit_wx_map(uint32 size)
{
	if (!jit_wx_api_available())
		return NULL;
	void *p = mmap(NULL, size, PROT_READ | PROT_WRITE | PROT_EXEC,
				   MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
	return (p == MAP_FAILED) ? NULL : p;
}

void jit_wx_unmap(void *base, uint32 size)
{
	if (base)
		munmap(base, size);
}

bool jit_wx_publish(void *dst, const void *src, uint32 len)
{
	jit_wx_write_ctx ctx = { dst, src, len };
	if (__builtin_available(macOS 11.4, iOS 17.4, *)) {
		if (pthread_jit_write_with_callback_np(jit_wx_write_cb, &ctx) != 0)
			return false;
	}
	else
		return false;
	sys_icache_invalidate(dst, len);
	return true;
}

bool jit_wx_available(void)
{
	static int cached = -1;
	if (cached < 0) {
		void *p = jit_wx_map(16 * 1024);
		cached = (p != NULL);
		jit_wx_unmap(p, 16 * 1024);
	}
	return cached != 0;
}

#endif /* JIT_WX_IOS_DUAL_MAP */

// Single registered shadow region (one translation cache per process)
static uint8 *g_wx_exec_base;
static uint8 *g_wx_write_base;
static uint32 g_wx_span;

void jit_wx_register_shadow(void *exec_base, void *write_base, uint32 size)
{
	g_wx_exec_base = (uint8 *)exec_base;
	g_wx_write_base = (uint8 *)write_base;
	g_wx_span = size;
}

uint8 *jit_wx_writable(void *exec_addr)
{
	uint8 *p = (uint8 *)exec_addr;
	if (g_wx_write_base && p >= g_wx_exec_base && p < g_wx_exec_base + g_wx_span)
		return g_wx_write_base + (p - g_wx_exec_base);
	return p;
}

void jit_wx_publish_range(uintptr start, uintptr stop)
{
	if (stop <= start)
		return;
	uint8 *w = jit_wx_writable((void *)start);
	if (w != (uint8 *)start)
		jit_wx_publish((void *)start, w, (uint32)(stop - start));
	// Directly-writable caches (x86 hosts) need no action here
}

extern "C" void kpx_jit_unimplemented_op(const char *name)
{
	fprintf(stderr, "FATAL: JIT backend reached unimplemented op %s\n", name);
	abort();
}

bool jit_wx_selftest(void)
{
	if (!jit_wx_available())
		return false;
	const uint32 size = 16 * 1024;
	uint8 *code = (uint8 *)jit_wx_map(size);
	if (code == NULL)
		return false;
	// mov w0, #42 ; ret — then rewritten to return 99, proving that
	// already-executed code can be republished (chain backpatching)
	static const uint32 fn42[2] = { 0x52800540u, 0xd65f03c0u };
	static const uint32 fn99[2] = { 0x52800c60u, 0xd65f03c0u };
	typedef int (*fn_t)(void);
	bool ok = jit_wx_publish(code, fn42, sizeof(fn42))
		&& ((fn_t)code)() == 42
		&& jit_wx_publish(code, fn99, sizeof(fn99))
		&& ((fn_t)code)() == 99;
	jit_wx_unmap(code, size);
	return ok;
}

#if JIT_WX_IOS_DUAL_MAP

// csops(2) is exported by libsystem_kernel but has no public header
extern "C" int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define JIT_CS_OPS_STATUS	0
#define JIT_CS_DEBUGGED		0x10000000

/*
 *  StikDebug universal.js "syscalls": brk #0xf00d with the command in
 *  x16 and arguments in x0/x1, result in x0. Executing one without that
 *  script attached raises an unhandled SIGTRAP and kills the process, so
 *  they only run when jit_ios_needs_prepare_script() told the app to
 *  request the script.
 */
__attribute__((noinline, optnone, naked))
static void jit26_detach(void)
{
	asm volatile("mov x16, #0\n\tbrk #0xf00d\n\tret");
}

__attribute__((noinline, optnone, naked))
static void *jit26_prepare_region(void *addr, size_t len)
{
	asm volatile("mov x16, #1\n\tbrk #0xf00d\n\tret");
}

static bool g_ios_ready;

bool jit_ios_supported(void)
{
	return ENABLE_DYNGEN != 0;
}

bool jit_ios_debugger_attached(void)
{
	uint32_t flags = 0;
	if (csops(getpid(), JIT_CS_OPS_STATUS, &flags, sizeof(flags)) != 0)
		return false;
	return (flags & JIT_CS_DEBUGGED) != 0;
}

// Mirrors StikJIT's ProcessInfo.txmPresence: the device tree's
// chosen/memory-map node lists a "TXM" entry on devices running the
// Trusted Execution Monitor. IOKit has no public iOS headers, so it is
// resolved at runtime. Returns 1 present, 0 absent, -1 unknown.
static int jit_ios_txm_presence(void)
{
	typedef mach_port_t io_registry_entry_t;
	typedef io_registry_entry_t (*from_path_t)(mach_port_t, const char *);
	typedef CFTypeRef (*create_property_t)(io_registry_entry_t, CFStringRef, CFAllocatorRef, uint32_t);
	typedef kern_return_t (*release_t)(mach_port_t);

	void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
	if (iokit == NULL)
		return -1;
	from_path_t from_path = (from_path_t)dlsym(iokit, "IORegistryEntryFromPath");
	create_property_t create_property = (create_property_t)dlsym(iokit, "IORegistryEntryCreateCFProperty");
	release_t release = (release_t)dlsym(iokit, "IOObjectRelease");
	if (from_path == NULL || create_property == NULL || release == NULL)
		return -1;

	io_registry_entry_t node = from_path(MACH_PORT_NULL, "IODeviceTree:/chosen/memory-map");
	if (node == MACH_PORT_NULL)
		return -1;
	CFTypeRef keys = create_property(node, CFSTR("IORegistryEntryPropertyKeys"), kCFAllocatorDefault, 0);
	release(node);
	if (keys == NULL)
		return -1;

	int presence = -1;
	if (CFGetTypeID(keys) == CFArrayGetTypeID()) {
		CFArrayRef array = (CFArrayRef)keys;
		presence = CFArrayContainsValue(array, CFRangeMake(0, CFArrayGetCount(array)), CFSTR("TXM")) ? 1 : 0;
	}
	CFRelease(keys);
	return presence;
}

bool jit_ios_needs_prepare_script(void)
{
	static int cached = -1;
	if (cached < 0) {
		// TXM hardware (A15 and later) is present on earlier iOS releases
		// too, but only iOS 26 stops a debugged process from mapping its
		// own code. StikDebug likewise runs no script before iOS 26, so a
		// brk there would go unserviced.
		if (__builtin_available(iOS 26.0, *))
			cached = (jit_ios_txm_presence() != 0) ? 1 : 0;
		else
			cached = 0;
	}
	return cached == 1;
}

static bool jit_ios_region_is_executable(void *addr)
{
	vm_address_t region = (vm_address_t)addr;
	vm_size_t region_size = 0;
	vm_region_basic_info_data_64_t info;
	mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
	mach_port_t object = MACH_PORT_NULL;
	kern_return_t kr = vm_region_64(mach_task_self(), &region, &region_size, VM_REGION_BASIC_INFO_64,
									(vm_region_info_t)&info, &count, &object);
	if (kr != KERN_SUCCESS) {
		JIT_IOS_LOG("vm_region(%p) failed: kr=%d", addr, kr);
		return false;
	}
	JIT_IOS_LOG("vm_region(%p): start=%p prot=%d max=%d",
				addr, (void *)region, info.protection, info.max_protection);
	// vm_region reports the next mapping when addr itself is unmapped
	if (region > (vm_address_t)addr)
		return false;
	return (info.protection & VM_PROT_EXECUTE) != 0;
}

// Map a writable view of the arena's physical pages
static uint8 *jit_ios_make_rw_alias(uint8 *rx)
{
	vm_address_t rw = 0;
	vm_prot_t cur_prot, max_prot;
	kern_return_t kr = vm_remap(mach_task_self(), &rw, JIT_IOS_ARENA_SIZE, 0, VM_FLAGS_ANYWHERE,
								mach_task_self(), (vm_address_t)rx, FALSE, &cur_prot, &max_prot,
								VM_INHERIT_NONE);
	if (kr != KERN_SUCCESS) {
		JIT_IOS_LOG("vm_remap failed: kr=%d", kr);
		return NULL;
	}
	JIT_IOS_LOG("vm_remap -> %p (cur=%d max=%d)", (void *)rw, cur_prot, max_prot);
	kr = vm_protect(mach_task_self(), rw, JIT_IOS_ARENA_SIZE, FALSE, VM_PROT_READ | VM_PROT_WRITE);
	if (kr != KERN_SUCCESS) {
		JIT_IOS_LOG("vm_protect(alias, rw) failed: kr=%d", kr);
		vm_deallocate(mach_task_self(), rw, JIT_IOS_ARENA_SIZE);
		return NULL;
	}
	return (uint8 *)rw;
}

// Before iOS 26: once CS_DEBUGGED is set, the process may flip its own
// pages between RW and RX (see jit_wx_publish). Whether the execute bit
// sticks is checked by the probe before anything runs there.
static uint8 *jit_ios_map_debugged(void)
{
	void *p = mmap(NULL, JIT_IOS_ARENA_SIZE, PROT_READ | PROT_WRITE,
				   MAP_PRIVATE | MAP_ANON, -1, 0);
	if (p == MAP_FAILED) {
		JIT_IOS_LOG("mmap(rw) failed: errno=%d", errno);
		return NULL;
	}
	JIT_IOS_LOG("mmap(rw) -> %p", p);
	return (uint8 *)p;
}

// TXM devices: the debugger allocates and prepares the RX region. A NULL
// address selects its allocation branch; preparing a region this process
// mapped itself returns the same pointer but never makes it executable.
static uint8 *jit_ios_map_rx_prepared(void)
{
	JIT_IOS_LOG("requesting prepared region from StikDebug (brk #0xf00d)");
	void *rx = jit26_prepare_region(NULL, JIT_IOS_ARENA_SIZE);
	JIT_IOS_LOG("prepare_region -> %p", rx);
	// A request the script did not service can leave junk in x0
	if (rx == NULL || ((uintptr)rx & (vm_page_size - 1)) != 0
		|| !jit_ios_region_is_executable(rx))
		return NULL;
	return (uint8 *)rx;
}

// jit_wx_selftest with a log line ahead of every step, so a crash while
// executing from the arena is pinned to the step that faulted
static bool jit_ios_probe(void)
{
	static const uint32 fn42[2] = { 0x52800540u, 0xd65f03c0u };
	static const uint32 fn99[2] = { 0x52800c60u, 0xd65f03c0u };
	typedef int (*fn_t)(void);

	JIT_IOS_LOG("probe: publishing (%s)", g_ios_rw ? "through RW alias" : "RW/RX toggle");
	if (!jit_wx_publish(g_ios_rx, fn42, sizeof(fn42)))
		return false;
	if (!jit_ios_region_is_executable(g_ios_rx)) {
		JIT_IOS_LOG("probe: published page is not executable");
		return false;
	}
	JIT_IOS_LOG("probe: executing at %p", g_ios_rx);
	int r = ((fn_t)g_ios_rx)();
	JIT_IOS_LOG("probe: returned %d (expected 42)", r);
	if (r != 42)
		return false;
	if (!jit_wx_publish(g_ios_rx, fn99, sizeof(fn99)))
		return false;
	JIT_IOS_LOG("probe: executing rewritten code");
	r = ((fn_t)g_ios_rx)();
	JIT_IOS_LOG("probe: returned %d (expected 99)", r);
	return r == 99;
}

bool jit_ios_acquire(void)
{
	// The script detaches after the first round, so a second prepare
	// request would hit a brk nobody services
	static bool prepare_script_used;

	if (g_ios_ready)
		return true;

	uint32_t cs_flags = 0;
	int cs_result = csops(getpid(), JIT_CS_OPS_STATUS, &cs_flags, sizeof(cs_flags));
	const bool prepare_script = jit_ios_needs_prepare_script();
	JIT_IOS_LOG("acquire: csops=%d flags=0x%08x debugged=%d txm=%d prepare_script=%d",
				cs_result, cs_flags, (cs_flags & JIT_CS_DEBUGGED) != 0,
				jit_ios_txm_presence(), prepare_script);

	if (!jit_ios_debugger_attached())
		return false;
	if (prepare_script) {
		if (prepare_script_used) {
			JIT_IOS_LOG("acquire: prepare request already used; not retrying");
			return false;
		}
		prepare_script_used = true;
	}
	uint8 *rx = prepare_script ? jit_ios_map_rx_prepared() : jit_ios_map_debugged();
	uint8 *rw = (rx && prepare_script) ? jit_ios_make_rw_alias(rx) : NULL;

	bool ok = false;
	if (rx != NULL && (rw != NULL || !prepare_script)) {
		g_ios_rx = rx;
		g_ios_rw = rw;
		ok = jit_ios_probe();
	}
	if (!ok) {
		g_ios_rx = NULL;
		g_ios_rw = NULL;
		if (rw)
			vm_deallocate(mach_task_self(), (vm_address_t)rw, JIT_IOS_ARENA_SIZE);
		if (rx)
			vm_deallocate(mach_task_self(), (vm_address_t)rx, JIT_IOS_ARENA_SIZE);
	}

	// The script services brk calls until told to detach; release the
	// process whether or not preparation worked. Prepared pages stay
	// executable afterwards.
	if (prepare_script) {
		JIT_IOS_LOG("detaching StikDebug");
		jit26_detach();
	}

	g_ios_ready = ok;
	JIT_IOS_LOG("iOS code arena %s (%s)", ok ? "ready" : "unavailable",
				prepare_script ? "TXM, prepared by StikDebug" : "debugger-enabled RW/RX toggle");
	return ok;
}

bool jit_ios_ready(void)
{
	return g_ios_ready;
}

#endif /* JIT_WX_IOS_DUAL_MAP */

#else

#if defined(__APPLE__)
#include <sys/mman.h>

// MEM_BULK's vm_acquire() carves from the guest bulk arena (and needs
// vm_init() to have run) — host-side code memory must come straight from
// mmap. MAP_JIT + simultaneous RWX is permitted by the allow-jit
// entitlement on Intel, Rosetta included; no write-protect toggling
// exists or is needed on x86_64.
void *jit_wx_map(uint32 size)
{
	void *p = mmap(NULL, size, PROT_READ | PROT_WRITE | PROT_EXEC,
				   MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
	return (p == MAP_FAILED) ? NULL : p;
}

void jit_wx_unmap(void *base, uint32 size)
{
	if (base)
		munmap(base, size);
}
#else

void *jit_wx_map(uint32 size)
{
	void *p = vm_acquire(size, VM_MAP_PRIVATE);
	if (p == VM_MAP_FAILED)
		return NULL;
	if (vm_protect(p, size, VM_PAGE_READ | VM_PAGE_WRITE | VM_PAGE_EXECUTE) < 0) {
		vm_release(p, size);
		return NULL;
	}
	return p;
}

void jit_wx_unmap(void *base, uint32 size)
{
	if (base)
		vm_release(base, size);
}
#endif

bool jit_wx_publish(void *dst, const void *src, uint32 len)
{
	// Hosts with incoherent instruction caches other than Apple arm64
	// would need an icache flush here; x86 needs none
	memcpy(dst, src, len);
	return true;
}

bool jit_wx_available(void)
{
	static int cached = -1;
	if (cached < 0) {
		void *p = jit_wx_map(16 * 1024);
		cached = (p != NULL);
		jit_wx_unmap(p, 16 * 1024);
	}
	return cached != 0;
}

bool jit_wx_selftest(void)
{
	// No portable way to execute test code here; probe map + publish
	if (!jit_wx_available())
		return false;
	const uint32 size = 16 * 1024;
	uint8 *code = (uint8 *)jit_wx_map(size);
	if (code == NULL)
		return false;
	static const uint32 probe[2] = { 0x12345678u, 0x9abcdef0u };
	bool ok = jit_wx_publish(code, probe, sizeof(probe))
		&& memcmp(code, probe, sizeof(probe)) == 0;
	jit_wx_unmap(code, size);
	return ok;
}

#endif

#if !defined(JIT_WX_IOS_DUAL_MAP) || !JIT_WX_IOS_DUAL_MAP
bool jit_ios_supported(void)			{ return false; }
bool jit_ios_debugger_attached(void)	{ return false; }
bool jit_ios_needs_prepare_script(void)	{ return false; }
bool jit_ios_acquire(void)				{ return false; }
bool jit_ios_ready(void)				{ return false; }
void jit_ios_note(const char *message)	{ }
#endif

#if ENABLE_DYNGEN

#include "cpu/jit/jit-cache.hpp"

#define DEBUG 0
#include "debug.h"

// Default cache size in KB
#if defined(__alpha__)
const int JIT_CACHE_SIZE = 2 * 1024;
#elif defined(__powerpc__) || defined(__ppc__)
const int JIT_CACHE_SIZE = 4 * 1024;
#elif defined(__aarch64__)
// Large native games thrash smaller caches: at 8 MB their
// hot code refilled it several times a second, at 15 MB every ~2 s with
// most of each fill repeating the previous one. Bounded on iOS devices by
// the code arena, and by the +/-128 MB reach of direct block chaining.
const int JIT_CACHE_SIZE = 32 * 1024;
#else
const int JIT_CACHE_SIZE = 8 * 1024;
#endif
const int JIT_CACHE_SIZE_GUARD = 4096;

#if defined(JIT_WX_IOS_DUAL_MAP) && JIT_WX_IOS_DUAL_MAP
// init_translation_cache rounds the default size plus guard up to 16 KB,
// and jit_wx_map refuses anything larger than the arena, which would
// silently leave the interpreter in charge
static_assert(((JIT_CACHE_SIZE * 1024 + JIT_CACHE_SIZE_GUARD + 16 * 1024 - 1) & -(16 * 1024))
			  <= (int)JIT_IOS_ARENA_SIZE, "default JIT cache exceeds the iOS code arena");
#endif

basic_jit_cache::basic_jit_cache()
	: cache_size(0), tcode_start(NULL), code_start(NULL), code_p(NULL), code_end(NULL),
	  wx_write_delta(0), wx_scratch(NULL), data(NULL)
{
}

basic_jit_cache::~basic_jit_cache()
{
	kill_translation_cache();

	// Release data pool
	data_chunk_t *p = data;
	while (p) {
		data_chunk_t *d = p;
		p = p->next;
		D(bug("basic_jit_cache: Release data pool %p (%d KB)\n", d, d->size / 1024));
		vm_release(d, d->size);
	}
}

bool
basic_jit_cache::init_translation_cache(uint32 size)
{
	size *= 1024;

	// Round up translation cache size to 16 KB boundaries
	const uint32 roundup = 16 * 1024;
	cache_size = (size + JIT_CACHE_SIZE_GUARD + roundup - 1) & -roundup;
	assert(cache_size > 0);

#if defined(__APPLE__) && defined(__aarch64__)
	// Code memory must be MAP_JIT and all writes must go through
	// jit_wx_publish (see jit-wx.hpp). No VM_MAP_32BIT: arm64 code uses
	// pc-relative addressing, and one contiguous region <= 128MB keeps
	// every block B/BL-reachable from every other for direct chaining.
	tcode_start = (uint8 *)jit_wx_map(cache_size);
	if (tcode_start == NULL)
		return false;

	// The emitters assemble through a plain-RW mirror; gen_end()'s
	// flush_icache_range publishes each finished block
	wx_scratch = (uint8 *)vm_acquire(cache_size, VM_MAP_PRIVATE);
	if (wx_scratch == VM_MAP_FAILED) {
		jit_wx_unmap(tcode_start, cache_size);
		tcode_start = NULL;
		wx_scratch = NULL;
		return false;
	}
	wx_write_delta = wx_scratch - tcode_start;
	jit_wx_register_shadow(tcode_start, wx_scratch, cache_size);
#elif defined(__APPLE__)
	// Intel: RWX MAP_JIT memory is directly writable (no W^X toggling on
	// x86_64), so the emitters write straight into the cache — no shadow.
	// Must not come from vm_acquire: under MEM_BULK that carves guest
	// address space out of the bulk arena.
	tcode_start = (uint8 *)jit_wx_map(cache_size);
	if (tcode_start == NULL)
		return false;
#else
	tcode_start = (uint8 *)vm_acquire(cache_size, VM_MAP_PRIVATE | VM_MAP_32BIT);
	if (tcode_start == VM_MAP_FAILED) {
		tcode_start = NULL;
		return false;
	}

	if (vm_protect(tcode_start, cache_size,
				   VM_PAGE_READ | VM_PAGE_WRITE | VM_PAGE_EXECUTE) < 0) {
		vm_release(tcode_start, cache_size);
		tcode_start = NULL;
		return false;
	}
#endif

	D(bug("basic_jit_cache: Translation cache: %d KB at %p\n", cache_size / 1024, tcode_start));
	code_start = tcode_start;
	code_p = code_start;
	code_end = code_p + size;
	return true;
}

void
basic_jit_cache::kill_translation_cache()
{
	if (tcode_start) {
		D(bug("basic_jit_cache: Release translation cache\n"));
#if defined(__APPLE__) && defined(__aarch64__)
		jit_wx_unmap(tcode_start, cache_size);
		if (wx_scratch) {
			jit_wx_register_shadow(NULL, NULL, 0);
			vm_release(wx_scratch, cache_size);
			wx_scratch = NULL;
			wx_write_delta = 0;
		}
#elif defined(__APPLE__)
		jit_wx_unmap(tcode_start, cache_size);
#else
		vm_release(tcode_start, cache_size);
#endif
		cache_size = 0;
		tcode_start = NULL;
	}
}

bool
basic_jit_cache::initialize(void)
{
	if (cache_size == 0)
		set_cache_size(JIT_CACHE_SIZE);
	return tcode_start && cache_size;
}

void
basic_jit_cache::set_cache_size(uint32 size)
{
	kill_translation_cache();
	if (size)
		init_translation_cache(size);
}

uint8 *
basic_jit_cache::copy_data(const uint8 *block, uint32 size)
{
	const int ALIGN = 16;
	uint8 *ptr;

	if (data && (data->offs + size) < data->size)
		ptr = (uint8 *)data + data->offs;
	else {
		// No free space left, allocate a new chunk
		uint32 to_alloc = sizeof(*data) + size + ALIGN;
		uint32 page_size = vm_get_page_size();
		to_alloc = (to_alloc + page_size - 1) & -page_size;

		D(bug("basic_jit_cache: Allocate data pool (%d KB)\n", to_alloc / 1024));
#if defined(__aarch64__)
		// Data pool stays plain RW memory; arm64 code materializes its
		// 64-bit address, so 32-bit addressability is not required
		ptr = (uint8 *)vm_acquire(to_alloc, VM_MAP_PRIVATE);
		if (ptr == VM_MAP_FAILED)
			ptr = NULL;
#elif defined(__APPLE__)
		// Intel: must not come from vm_acquire (MEM_BULK guest arena).
		// Generated code reaches the pool through rel32 RIP-relative
		// references, so hint the mapping next to the translation cache
		// and verify it landed within +/-2GB.
		ptr = (uint8 *)mmap(tcode_start, to_alloc, PROT_READ | PROT_WRITE,
							MAP_PRIVATE | MAP_ANON, -1, 0);
		if (ptr == MAP_FAILED)
			ptr = NULL;
		else {
			intptr_t delta = (intptr_t)(ptr - tcode_start);
			if (delta > INT32_MAX || delta < INT32_MIN) {
				munmap(ptr, to_alloc);
				ptr = NULL;
			}
		}
#else
		ptr = (uint8 *)vm_acquire(to_alloc, VM_MAP_PRIVATE | VM_MAP_32BIT);
		if (ptr == VM_MAP_FAILED)
			ptr = NULL;
#endif
		if (ptr == NULL) {
			fprintf(stderr, "FATAL: Could not allocate data pool!\n");
			abort();
		}

		data_chunk_t *dcp = (data_chunk_t *)ptr;
		dcp->size = to_alloc;
		dcp->offs = (sizeof(*data) + ALIGN - 1) & -ALIGN;
		dcp->next = data;
		data = dcp;

		ptr += dcp->offs;
	}

	memcpy(ptr, block, size);
	data->offs += (size + ALIGN - 1) & -ALIGN;
	D(bug("basic_jit_cache: DATA %p, %d bytes [data=%p, offs=%u]\n", ptr, size, data, data->offs));
	return ptr;
}

#endif //ENABLE_DYNGEN
