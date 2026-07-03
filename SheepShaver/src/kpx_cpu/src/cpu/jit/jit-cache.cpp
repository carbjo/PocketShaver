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

#if ENABLE_DYNGEN

#include "cpu/jit/jit-cache.hpp"

#define DEBUG 0
#include "debug.h"

// Default cache size in KB
#if defined(__alpha__)
const int JIT_CACHE_SIZE = 2 * 1024;
#elif defined(__powerpc__) || defined(__ppc__)
const int JIT_CACHE_SIZE = 4 * 1024;
#else
const int JIT_CACHE_SIZE = 8 * 1024;
#endif
const int JIT_CACHE_SIZE_GUARD = 4096;

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
#else
		ptr = (uint8 *)vm_acquire(to_alloc, VM_MAP_PRIVATE | VM_MAP_32BIT);
#endif
		if (ptr == VM_MAP_FAILED) {
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
