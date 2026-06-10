/*
 *  nqd_metal_renderer.mm - Metal compute acceleration for NQD 2D operations
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Implements Metal compute shaders for NQD bitblt (srcCopy), fillrect,
 *  and invrect operations. Mac RAM is wrapped as a shared MTLBuffer so the
 *  GPU reads/writes the same memory the CPU emulator uses.
 */

#import <Metal/Metal.h>

#include <vector>
#include "sysdeps.h"
#include "cpu_emulation.h"
#include "nqd_accel.h"
#include "accel_logging.h"
#include "dsp_pixmap_offsets.h"
#include "gl_offscreen_policy.h"
#include "nqd_main_device_policy.h"
#include "nqd_packed_fill_policy.h"
#include "metal_device_shared.h"
#include "gfxaccel_resources_heap.h"

// ---------------------------------------------------------------------------
// Diagnostic logging
// ---------------------------------------------------------------------------

#import <os/log.h>
#if ACCEL_LOGGING_ENABLED
bool nqd_logging_enabled = accel_log_detail::subsystem_on("nqd");
os_log_t nqd_log = OS_LOG_DEFAULT;
static struct NQDLogInit {
    NQDLogInit() { nqd_log = os_log_create("com.pocketshaver.nqd", "metal"); }
} nqd_log_init;

#define NQD_LOG(fmt, ...)  do { if (nqd_logging_enabled) os_log(nqd_log, fmt, ##__VA_ARGS__); } while (0)
#define NQD_VLOG(fmt, ...) do { if (nqd_logging_enabled && ACCEL_LOG_VERBOSE) os_log(nqd_log, fmt, ##__VA_ARGS__); } while (0)
#else
#define NQD_LOG(fmt, ...)  do {} while (0)
#define NQD_VLOG(fmt, ...) do {} while (0)
#endif

// Always-on error logging (NOT gated by ACCEL_LOGGING_ENABLED).
#if ACCEL_LOGGING_ENABLED
#define NQD_ERR(fmt, ...) do { os_log_error(nqd_log, fmt, ##__VA_ARGS__); } while (0)
#else
#define NQD_ERR(fmt, ...) do { os_log_error(OS_LOG_DEFAULT, fmt, ##__VA_ARGS__); } while (0)
#endif

// ---------------------------------------------------------------------------
// NQD/DSp framebuffer-ownership conflict rule:
//
// Original rule: "if both NQD and DSp try to own kLayerSlotFramebuffer
// in the same mode window, DSp wins". This was first implemented as a
// BLANKET drop of every NQD entry when DMC owner == kDMCOwnerDSp. In
// practice, that gate was too broad — it silenced the legitimate
// DSp-1.7-sanctioned pattern of "Reserve + SetState(Active) + draw via
// QuickDraw to the main-screen port" (used by The Sims and other DSp
// games that do not call GetBackBuffer / SwapBuffers).
//
// Architectural reality: the NQD Metal path is only dispatched when
// the accl_params dest_base falls inside nqd_ram_buffer (see
// gfxaccel.cpp's NQDMetalAddrInBuffer guard at every NQD_* entry).
// The DSp back-buffer lives in a SEPARATE MTLBuffer allocated out of
// kHeapCompositor — it is NOT in nqd_ram_buffer, so an NQD op
// targeting the DSp back-buffer can never reach this file. Every NQD
// op that does reach us targets the emulator's main framebuffer
// (the_buffer — also the MTLBuffer the compositor_texture is a view
// over) or an app-owned offscreen pixmap in guest RAM. Writes to
// either are SAFE regardless of DSp owner state:
//   - main framebuffer writes: visible via MetalCompositorPresent
//     (compositor_texture is a zero-copy view over the_buffer) until
//     a DSp SwapBuffers blit overwrites them. Well-behaved DSp apps
//     SwapBuffers at the end of each frame; apps that draw via QD
//     instead of the back-buffer API (The Sims pattern) rely on
//     these writes being visible.
//   - app offscreen writes: not on the display path at all; DSp has
//     no claim over them.
//
// So: the blanket drop gate is REMOVED at the five NQD entry points.
// The s_nqd_fb_drop_count counter + TESTING_BUILD hooks are kept for
// coexistence tests that still need the "gate did not fire" assertion
// (DSpMultiEngineCoexistenceTests vendors NQD at kLayerSlotUnderlay
// with drop_count==0 as an author-mistake detector). The owner-map
// tagging in gfxaccel_resources (set_buffer_owner/get_buffer_owner)
// is authoritative per-buffer and remains unchanged — it is the
// correct place for ownership metadata if a future enforcement point
// needs it (e.g., a hypothetical NQD op that somehow reached a DSp
// back-buffer via an aliased pixmap would be caught by an address
// comparison there; no such pathway exists today).
//
// Compositor-blindness preserved: the compositor
// still never reads the owner map.
// ---------------------------------------------------------------------------

extern "C" int s_nqd_fb_drop_count;  /* owned by gfxaccel_resources.mm */
extern "C" uint64_t GLCompositeLatestOffscreenToGuestSurfaceUsingLatestExtentDirtyRect(
    uint32_t dstBaseaddr,
    uint32_t dstRowbytes,
    uint32_t dstDepthBits,
    int32_t dirtyX,
    int32_t dirtyY,
    int32_t dirtyWidth,
    int32_t dirtyHeight);

// ---------------------------------------------------------------------------
// Metal state (file-static)
// ---------------------------------------------------------------------------

bool nqd_metal_available = false;

static id<MTLDevice>              nqd_device       = nil;
static id<MTLCommandQueue>        nqd_queue        = nil;
static id<MTLComputePipelineState> nqd_bitblt_pipeline = nil;
static id<MTLComputePipelineState> nqd_bitblt_scaled_pipeline = nil;  /* DSpBlit_Faster scaling kernel */
static id<MTLComputePipelineState> nqd_fillrect_pipeline = nil;
static id<MTLBuffer>              nqd_ram_buffer   = nil;
static uint8                     *nqd_ram_base     = nullptr; // host pointer that corresponds to Metal buffer start
static uint32                     nqd_ram_size     = 0;       // size of the Metal buffer (== RAMSize)

#ifdef TESTING_BUILD
// ---------------------------------------------------------------------------
// Test-only device/queue override.
//
// When TESTING_BUILD is defined (ONLY on the PocketShaverTests target —
// never on the production app target), tests may inject their own
// per-test id<MTLDevice> + id<MTLCommandQueue> by calling
// NQDTesting_SetDevice() BEFORE NQDMetalInit().  NQDMetalInit() then
// uses the injected pair instead of SharedMetalDevice() /
// SharedMetalCommandQueue().  NQDTesting_Reset() clears all file-static
// state between tests so each XCTestCase starts with a fresh slate.
//
// NQDTesting_SetBundle() lets tests inject the
// NSBundle that `newDefaultLibrary` should load `default.metallib` from.
// Under xctest without a host app, `[MTLDevice newDefaultLibrary]` looks
// at NSBundle.mainBundle, which is the `xctest` runner — NOT the
// `.xctest` bundle that actually contains `default.metallib`.  Tests
// pass `[NSBundle bundleForClass:[<TestClass> class]]` to resolve the
// real test bundle; NQDMetalInit then uses
// `newDefaultLibraryWithBundle:` when the override is non-nil.
//
// Production builds (TESTING_BUILD undefined) do not see these symbols;
// the preprocessor drops the entire block.
// ---------------------------------------------------------------------------
static id<NSObject> nqd_testing_bundle = nil;

extern "C" void NQDTesting_SetDevice(void *device, void *queue)
{
	nqd_device = (__bridge id<MTLDevice>)device;
	nqd_queue  = (__bridge id<MTLCommandQueue>)queue;
}

extern "C" void NQDTesting_SetBundle(void *bundle)
{
	nqd_testing_bundle = (__bridge id<NSObject>)bundle;
}

extern "C" void NQDTesting_Reset(void)
{
	nqd_metal_available        = false;
	nqd_device                 = nil;
	nqd_queue                  = nil;
	nqd_bitblt_pipeline        = nil;
	nqd_bitblt_scaled_pipeline = nil;  // clear the scaled pipeline too so test
	                                   // isolation is complete — production
	                                   // NQDMetalCleanup already clears it.
	nqd_fillrect_pipeline      = nil;
	nqd_ram_buffer             = nil;
	nqd_ram_base               = nullptr;
	nqd_ram_size               = 0;
	nqd_testing_bundle         = nil;
}
#endif /* TESTING_BUILD */

// ---------------------------------------------------------------------------
// Batched command encoding state
//
// Instead of creating/committing a command buffer per NQD call, we accumulate
// multiple compute dispatches into a single command buffer + encoder. The batch
// is flushed (committed + waited) when:
//   1. NQDMetalFlush() is called (from NQD_sync_hook or MetalCompositorPresent)
//   2. A backward blit needs ordering guarantees
//   3. A mask operation needs the mask buffer (which may be reused across calls)
//
// This amortizes command buffer creation and GPU submission overhead across
// all NQD operations within a frame, which is the dominant perf bottleneck.
// ---------------------------------------------------------------------------

static id<MTLCommandBuffer>         nqd_batch_cmdbuf  = nil;
static id<MTLComputeCommandEncoder> nqd_batch_encoder = nil;
static int                          nqd_batch_count   = 0;

// Maximum dispatches before an automatic flush. Prevents unbounded accumulation
// (e.g. if sync_hook is never called). 128 dispatches ≈ one busy frame.
static const int NQD_BATCH_MAX = 128;

// ---------------------------------------------------------------------------
// CPU fast-path threshold (in total pixels)
//
// For small rects, the Metal submission overhead (command buffer alloc,
// encoder setup, GPU scheduling, waitUntilCompleted stall) far exceeds
// the actual compute time. The CPU path (memset/memmove/XOR loop) is
// faster for operations below this threshold.
//
// Even with batching, each dispatch adds encoder overhead. For tiny ops
// (icons, cursors, text glyphs), CPU is still faster.
// ---------------------------------------------------------------------------

static const int NQD_CPU_THRESHOLD_PIXELS = 4096;  // ~64x64 or equivalent

// Check if a Mac address is within the Metal-mapped RAM region.
static inline bool nqd_addr_in_buffer(uint32 mac_addr)
{
    return mac_addr >= RAMBase && mac_addr < RAMBase + nqd_ram_size;
}

bool NQDMetalAddrInBuffer(uint32 mac_addr)
{
    return nqd_addr_in_buffer(mac_addr);
}

// ---------------------------------------------------------------------------
// Batch command buffer helpers
// ---------------------------------------------------------------------------

// Ensure we have an active batch command buffer + encoder.
// Returns the encoder, creating a new batch if needed.
static id<MTLComputeCommandEncoder> nqd_get_batch_encoder(void)
{
    if (!nqd_batch_encoder) {
        nqd_batch_cmdbuf = [nqd_queue commandBuffer];
        if (!nqd_batch_cmdbuf) {
            NQD_ERR("nqd_get_batch_encoder: commandBuffer creation failed");
            return nil;
        }
        nqd_batch_encoder = [nqd_batch_cmdbuf computeCommandEncoder];
        if (!nqd_batch_encoder) {
            NQD_ERR("nqd_get_batch_encoder: computeCommandEncoder creation failed");
            nqd_batch_cmdbuf = nil;
            return nil;
        }
        nqd_batch_count = 0;
    }
    return nqd_batch_encoder;
}

// Increment batch count and auto-flush if we've hit the max.
static void nqd_batch_did_dispatch(void)
{
    nqd_batch_count++;
    if (nqd_batch_count >= NQD_BATCH_MAX) {
        NQDMetalFlush();
    }
}

// ---------------------------------------------------------------------------
// NQDMetalFlush — commit the batched command buffer and wait for completion
//
// Called from NQD_sync_hook (Mac OS sync point) and before
// MetalCompositorPresent (frame boundary). Also called internally when
// ordering guarantees are needed (backward blits, mask buffer reuse).
// ---------------------------------------------------------------------------

void NQDMetalFlush(void)
{
    if (!nqd_batch_encoder) return;

    @autoreleasepool {
    [nqd_batch_encoder endEncoding];
    [nqd_batch_cmdbuf commit];
    [nqd_batch_cmdbuf waitUntilCompleted];

    if (nqd_batch_cmdbuf.error) {
        NQD_ERR("NQDMetalFlush: GPU error after %d dispatches: %s",
                nqd_batch_count,
                [[nqd_batch_cmdbuf.error localizedDescription] UTF8String]);
    }

    NQD_VLOG("NQDMetalFlush: committed %d dispatches", nqd_batch_count);

    nqd_batch_encoder = nil;
    nqd_batch_cmdbuf = nil;
    nqd_batch_count = 0;
    } // @autoreleasepool
}

// ---------------------------------------------------------------------------
// Uniform struct — must match NQDBitbltUniforms in nqd_shaders.metal
// ---------------------------------------------------------------------------

struct NQDBitbltUniforms {
    uint32_t src_offset;
    uint32_t dst_offset;
    int32_t  src_row_bytes;
    int32_t  dst_row_bytes;
    uint32_t width_bytes;
    uint32_t height;
    uint32_t transfer_mode;
    uint32_t pixel_size;     // bytes per pixel (1, 2, or 4)
    uint32_t width_pixels;   // width in pixels (for arithmetic/hilite modes)
    uint32_t fore_pen;       // foreground pen color (big-endian packed)
    uint32_t back_pen;       // background pen color (big-endian packed)
    uint32_t hilite_color;   // HiliteRGB packed to pixel depth
    uint32_t mask_enabled;   // 1 = mask gating active, 0 = no mask
    uint32_t mask_offset;    // byte offset into mask_buffer where mask data starts
    uint32_t mask_stride;    // mask row stride (width_bytes for Boolean, width_pixels for arithmetic)
    uint32_t bits_per_pixel; // raw pixel depth in bits (1, 2, 4, 8, 16, or 32) — for packed pixel support
    // Per-channel rgbOpColor blend weights [0-65535] for mode
    // 32 (blend). Replaces the single scalar blend_weight; must match the
    // 3-field layout in NQDBitbltUniforms in nqd_shaders.metal exactly.
    uint32_t blend_weight_r;
    uint32_t blend_weight_g;
    uint32_t blend_weight_b;
};

// ---------------------------------------------------------------------------
// Uniform struct — must match NQDBitbltScaledUniforms in nqd_shaders.metal
// (DSpBlit_Faster scaling kernel). Field order + size must
// match the .metal struct EXACTLY.
// ---------------------------------------------------------------------------

struct NQDBitbltScaledUniforms {
    uint32_t src_offset;     // byte offset of src rect origin within the RAM buffer
    uint32_t dst_offset;     // byte offset of dst rect origin within the RAM buffer
    int32_t  src_row_bytes;
    int32_t  dst_row_bytes;
    uint32_t pixel_size;     // bytes per pixel (1, 2, or 4)
    uint32_t bits_per_pixel; // raw pixel depth in bits (8, 16, or 32)
    uint32_t src_w;          // source rect width in pixels
    uint32_t src_h;          // source rect height in pixels
    uint32_t dst_w;          // dest rect width in pixels
    uint32_t dst_h;          // dest rect height in pixels
    uint32_t interpolate;    // 1 = bilinear (kDSpBlitMode_Interpolation), 0 = nearest
    uint32_t src_key;        // source color key (big-endian packed pixel value)
    uint32_t dst_key;        // dest color key (big-endian packed pixel value)
    uint32_t key_enable;     // bit-or of kDSpBlitMode_SrcKey(1) / _DstKey(2); 0 = no key
    uint32_t ram_size;       // defense-in-depth: total mapped RAM bytes; the
                             // kernel clamps every per-pixel addr < ram_size so a
                             // resolved-geometry mismatch cannot OOB the buffer
};

// Uniforms for fillrect — must match NQDFillRectUniforms in nqd_shaders.metal
struct NQDFillRectUniforms {
    uint32_t dst_offset;
    int32_t  row_bytes;
    uint32_t width_bytes;
    uint32_t height;
    uint32_t fill_color;     // 32-bit fill pattern (fore or back pen, htonl'd)
    uint32_t bpp;            // bytes per pixel (1, 2, or 4)
    uint32_t transfer_mode;  // pen mode: 8-15 (Boolean), 32-39 (arithmetic), 50 (hilite)
    uint32_t pixel_size;     // bytes per pixel (same as bpp)
    uint32_t width_pixels;   // width in pixels (for arithmetic/hilite per-pixel dispatch)
    uint32_t fore_pen;       // foreground pen color (big-endian packed)
    uint32_t back_pen;       // background pen color (big-endian packed)
    uint32_t hilite_color;   // HiliteRGB packed to pixel depth
    uint32_t mask_enabled;   // 1 = mask gating active, 0 = no mask
    uint32_t mask_offset;    // byte offset into mask_buffer where mask data starts
    uint32_t mask_stride;    // mask row stride (width_bytes for Boolean, width_pixels for arithmetic)
    uint32_t bits_per_pixel; // raw pixel depth in bits (1, 2, 4, 8, 16, or 32) — for packed pixel support
    // Per-channel rgbOpColor blend weights [0-65535] for mode
    // 32 (blend). Replaces the single scalar blend_weight; must match the
    // 3-field layout in NQDFillRectUniforms in nqd_shaders.metal exactly.
    uint32_t blend_weight_r;
    uint32_t blend_weight_g;
    uint32_t blend_weight_b;
};

// ---------------------------------------------------------------------------
// Helper: read OpColor blend weight from Mac low-memory 0x0A28.
// OpColor is an RGBColor (3 x uint16). The red channel is used as the
// single-valued blend weight for transfer mode 32 (blend).
// Returns [0-65535] where 0 = all destination, 65535 = all source.
//
// This is the DOCUMENTED FALLBACK target for nqd_read_rgb_op_color():
// the non-canonical lowmem 0x0A28 scalar is only used when the current
// port's GrafVars handle is genuinely unreachable (port==0 / OOB / basic
// GrafPort), and only with a logged NQD_LOG message — never silently.
// ---------------------------------------------------------------------------
#ifdef TESTING_BUILD
// Test-only seams for the two raw lowmem reads in the blend path.
// Under EMULATED_PPC=0 (the test build) ReadMacInt32/16 are raw host-pointer
// dereferences, so reading guest lowmem addresses 0x0916 (thePort) and 0x0A28
// (OpColor scalar) would data-fault (the EMULATED_PPC=0
// caveat documented at the non-blend zero-set sites). These seams let the
// headless logic gate inject a fake thePort (which may point INTO the
// fake RAM so steps 3-5 of the walk run for real) and a fake 0x0A28 scalar.
// Production builds (TESTING_BUILD undefined) never see these; the raw lowmem
// reads are used directly and are safe because ReadMacInt* maps guest memory.
static bool     nqd_test_lowmem_override   = false;
static uint32_t nqd_test_theport_0x0916    = 0;
static uint16_t nqd_test_opcolor_0x0A28    = 0;

extern "C" void NQDTesting_SetLowmemOverride(int enable,
                                             uint32_t theport_0x0916,
                                             uint16_t opcolor_0x0A28)
{
    nqd_test_lowmem_override = (enable != 0);
    nqd_test_theport_0x0916  = theport_0x0916;
    nqd_test_opcolor_0x0A28  = opcolor_0x0A28;
}
#endif /* TESTING_BUILD */

static inline uint16_t nqd_read_lowmem_opcolor_scalar()
{
#ifdef TESTING_BUILD
    if (nqd_test_lowmem_override) return nqd_test_opcolor_0x0A28;
    // Under EMULATED_PPC=0 (the test build) ReadMacInt16(0x0A28) is
    // a literal host-pointer deref of unmapped lowmem (SIGSEGV). Every
    // *_WithHost dispatch reaches this via the unconditional blend walk.
    // With no override set, return 0 — the safe headless default (no OpColor
    // weight). Production (TESTING_BUILD undefined) keeps the real read below.
    return 0;
#else
    return (uint16_t)ReadMacInt16(0x0A28);
#endif
}

static inline uint32_t nqd_read_lowmem_theport()
{
#ifdef TESTING_BUILD
    if (nqd_test_lowmem_override) return nqd_test_theport_0x0916;
    // Under EMULATED_PPC=0 ReadMacInt32(0x0916) is a raw host-ptr
    // deref of unmapped fake-RAM lowmem (deterministic SIGSEGV). Every
    // *_WithHost dispatch hits this through the unconditional blend
    // walk in NQDMetalBitblt_WithHost. With no override set, return 0 (thePort
    // == 0) — nqd_read_rgb_op_color() then takes the safe lowmem-0x0A28
    // fallback, which is itself overridden/zeroed above. Production
    // (TESTING_BUILD undefined) keeps the real read below.
    return 0;
#else
    return ReadMacInt32(0x0916);
#endif
}

// In-RAM walk reads for nqd_read_rgb_op_color() Steps 2-5. Under production
// these are plain ReadMacInt*; under the EMULATED_PPC=0 test build with the
// lowmem override active, the host pointer (RAMBaseHost) does NOT equal the
// truncated 32-bit RAMBase when the fake-RAM mmap lands above 4 GiB, so a raw
// ReadMacInt*(macAddr) would data-fault (the mmap-low-4GiB hint is best-effort,
// not guaranteed). The seam reads via RAMBaseHost + (macAddr - RAMBase) — the
// same host-pointer convention the rest of the NQD test harness uses
// (PSFakeMacRAM / *_WithHost) — so the GrafVars walk is exercisable headlessly.
static inline uint16_t nqd_walk_read16(uint32_t mac_addr)
{
#ifdef TESTING_BUILD
    if (nqd_test_lowmem_override && RAMBaseHost &&
        mac_addr >= RAMBase && (mac_addr - RAMBase) < RAMSize) {
        return *(const uint16_t *)(RAMBaseHost + (mac_addr - RAMBase));
    }
#endif
    return (uint16_t)ReadMacInt16(mac_addr);
}

static inline uint32_t nqd_walk_read32(uint32_t mac_addr)
{
#ifdef TESTING_BUILD
    if (nqd_test_lowmem_override && RAMBaseHost &&
        mac_addr >= RAMBase && (mac_addr - RAMBase) < RAMSize) {
        return *(const uint32_t *)(RAMBaseHost + (mac_addr - RAMBase));
    }
#endif
    return ReadMacInt32(mac_addr);
}

static inline bool nqd_lowmem_or_ram_inrange(uint32_t mac_addr)
{
    const uint32_t ram_lo = (uint32_t)RAMBase;
    const uint32_t ram_hi = (uint32_t)(RAMBase + RAMSize);
    return (mac_addr < 0x3000u) || (mac_addr >= ram_lo && mac_addr < ram_hi);
}

static inline NQDMainDevicePixMapSnapshot nqd_read_main_device_pixmap_snapshot()
{
    NQDMainDevicePixMapSnapshot snap = { false, 0, 0, 0 };
    uint32_t mainDeviceH = ReadMacInt32(LMADDR_MAIN_DEVICE);
    if (mainDeviceH == 0 || !nqd_lowmem_or_ram_inrange(mainDeviceH)) return snap;

    uint32_t gdevicePtr = nqd_walk_read32(mainDeviceH);
    if (gdevicePtr == 0 || !nqd_lowmem_or_ram_inrange(gdevicePtr)) return snap;
    if (!nqd_lowmem_or_ram_inrange(gdevicePtr + GDEVICE_OFF_PMAP)) return snap;

    uint32_t pixMapH = nqd_walk_read32(gdevicePtr + GDEVICE_OFF_PMAP);
    if (pixMapH == 0 || !nqd_lowmem_or_ram_inrange(pixMapH)) return snap;

    uint32_t pixMapPtr = nqd_walk_read32(pixMapH);
    if (pixMapPtr == 0 || !nqd_lowmem_or_ram_inrange(pixMapPtr)) return snap;
    if (!nqd_lowmem_or_ram_inrange(
            pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_CMPSIZE + 2)) return snap;

    snap.valid = true;
    snap.baseAddr = nqd_walk_read32(pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_BASEADDR);
    snap.rowBytes = (uint32_t)(nqd_walk_read16(
        pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_ROWBYTES) & 0x7FFFu);
    snap.pixelSize = nqd_walk_read16(
        pixMapPtr + DSP_MAINDEVICE_PIXMAP_OFF_PIXELSIZE);
    return snap;
}

static inline bool nqd_should_drop_stale_main_device_params(NQDMainDevicePixMapSnapshot snap,
                                                             uint32_t dest_base,
                                                             int32_t dest_row_bytes,
                                                             uint32_t pixel_size)
{
    return NQDShouldDropStaleMainDeviceParams(snap, dest_base, dest_row_bytes,
                                              pixel_size);
}

static inline bool nqd_is_packed_main_device_alias(NQDMainDevicePixMapSnapshot snap,
                                                    uint32_t dest_base,
                                                    int32_t dest_row_bytes,
                                                    uint32_t pixel_size)
{
    return NQDIsPackedMainDeviceAlias(snap, dest_base, dest_row_bytes,
                                      pixel_size);
}

static inline bool nqd_should_use_cpu_packed_main_device_path(NQDMainDevicePixMapSnapshot snap,
                                                               uint32_t dest_base,
                                                               int32_t dest_row_bytes,
                                                               uint32_t pixel_size)
{
    return NQDShouldUseCPUPackedMainDevicePath(snap, dest_base, dest_row_bytes,
                                               pixel_size);
}

static inline bool nqd_should_use_cpu_mixed_depth_main_device_bitblt(NQDMainDevicePixMapSnapshot snap,
                                                                      uint32_t dest_base,
                                                                      int32_t dest_row_bytes,
                                                                      uint32_t src_pixel_size,
                                                                      uint32_t dest_pixel_size,
                                                                      uint32_t transfer_mode)
{
    return NQDShouldUseCPUMixedDepthMainDeviceBitBlt(snap, dest_base,
                                                     dest_row_bytes,
                                                     src_pixel_size,
                                                     dest_pixel_size,
                                                     transfer_mode);
}

static inline uint32_t nqd_effective_main_device_pixel_size(NQDMainDevicePixMapSnapshot snap,
                                                             uint32_t dest_base,
                                                             int32_t dest_row_bytes,
                                                             uint32_t pixel_size)
{
    return NQDEffectiveMainDevicePixelSize(snap, dest_base, dest_row_bytes,
                                           pixel_size);
}

static inline bool nqd_should_bridge_gl_offscreen_after_bitblt(
    NQDMainDevicePixMapSnapshot main_device,
    uint32_t src_base,
    int32_t src_row_bytes,
    uint32_t src_pixel_size,
    uint32_t dest_base,
    int32_t dest_row_bytes,
    uint32_t dest_pixel_size,
    uint32_t transfer_mode)
{
    return GLShouldBridgeOffscreenAfterNQDFrontBlt(
        main_device.valid,
        main_device.baseAddr,
        (int32_t)main_device.rowBytes,
        src_base,
        src_row_bytes,
        src_pixel_size,
        dest_base,
        dest_row_bytes,
        dest_pixel_size,
        transfer_mode);
}

static inline void nqd_bridge_gl_offscreen_after_bitblt(uint32_t dest_base,
                                                        int32_t dest_row_bytes,
                                                        uint32_t dest_pixel_size,
                                                        int16_t dest_X,
                                                        int16_t dest_Y,
                                                        int16_t width,
                                                        int16_t height)
{
    if (dest_row_bytes <= 0) return;

    const uint64_t gl_composited =
        GLCompositeLatestOffscreenToGuestSurfaceUsingLatestExtentDirtyRect(
            dest_base,
            (uint32_t)dest_row_bytes,
            dest_pixel_size,
            dest_X,
            dest_Y,
            width,
            height);
    if (gl_composited != 0) {
        NQD_VLOG("NQDMetalBitblt: composited %llu GL offscreen pixels "
                 "after world blit into 0x%08x",
                 (unsigned long long)gl_composited, dest_base);
    }
}

static inline uint32_t nqd_read_blend_weight()
{
    // OpColor at Mac low-memory 0x0DA0 is actually HiliteRGB.
    // OpColor is at 0x0A28 (RGBColor: {red, green, blue} as big-endian uint16).
    return (uint32_t)nqd_read_lowmem_opcolor_scalar();
}

// ---------------------------------------------------------------------------
// Per-channel rgbOpColor blend weights.
//
// Transfer mode 32 (blend) is weighted by the current CGrafPort's OpColor,
// which Color QuickDraw stores per-channel as an RGBColor in the port's
// GrafVars handle (Imaging With QuickDraw 4-40 / 4-62 / 4-78 / 4-110). The
// legacy nqd_read_blend_weight() reads ONE big-endian uint16 from the
// non-canonical lowmem 0x0A28 scalar and applies it to all three channels.
// This helper reads the per-channel
// R/G/B rgbOpColor from the canonical source.
//
// SECURITY: the GrafVars pointer chain is
// guest-controlled (an emulated app sets thePort and the GrafVars Handle to
// arbitrary values). EVERY ReadMacInt* in the walk is preceded by an
// NQD_INRANGE OOB gate so a garbage pointer cannot trigger a host OOB read.
// The gate + per-step graceful-return idiom is copied verbatim in shape from
// DSpRedirectMainDevicePixMap (dsp_draw_context.mm:3616). On any gate failure
// or a basic (non-colour) GrafPort, fall back to the lowmem 0x0A28 scalar
// applied to all 3 channels WITH an NQD_LOG — never silent.
// ---------------------------------------------------------------------------
struct NQDRgbOpColor { uint32_t r, g, b; };

static inline NQDRgbOpColor nqd_read_rgb_op_color()
{
    // NQD_INRANGE gate: RAM range [RAMBase, RAMBase+RAMSize) UNION lowmem
    // gZeroPage [0, 0x3000). Identical in shape to DSP_REDIR_INRANGE
    // (dsp_draw_context.mm:3616). Implemented as a scope-local lambda (not a
    // #define) so every gate site in the walk can use it safely without the
    // multiple-#undef hazard a function-local macro carries.
    const uint32_t kLomemBase = 0x0;
    const uint32_t kLomemTop  = 0x3000;        // matches gZeroPage in vm.hpp
    const uint32_t kRamLo     = (uint32_t)RAMBase;
    const uint32_t kRamHi     = (uint32_t)(RAMBase + RAMSize);
    auto NQD_INRANGE = [&](uint32_t a) -> bool {
        return ((a >= kRamLo && a < kRamHi) ||
                (a >= kLomemBase && a < kLomemTop));
    };

    // Fallback: lowmem 0x0A28 scalar applied to all 3 channels.
    NQDRgbOpColor fallback;
    fallback.r = fallback.g = fallback.b = nqd_read_blend_weight();

    // Step 1: thePort — lowmem 0x0916, the classic Mac OS current-GrafPort
    // global. 0x0916 lives inside gZeroPage so the read itself is always safe
    // under EMULATED_PPC=1; gate the VALUE before dereferencing it. (Under the
    // EMULATED_PPC=0 test build this routes through the TESTING_BUILD seam.)
    uint32_t portPtr = nqd_read_lowmem_theport();
    if (portPtr == 0 || !NQD_INRANGE(portPtr)) {
        NQD_LOG("nqd_read_rgb_op_color: rgbOpColor unreachable (step 1: thePort"
                "=0x%08x) — lowmem 0x0A28 fallback", portPtr);
        return fallback;
    }

    // Step 2: CGrafPort detect — portVersion @ +6; a colour port has the high
    // two bits set (& 0xC000). A basic GrafPort has no GrafVars/OpColor, so
    // OpColor has no effect → fallback. portPtr is INRANGE (step 1); gate the
    // FULL 2-byte read extent (+6..+7) for spill safety. Previously only
    // the START byte (+6) was gated, allowing a ≤1-byte over-read when portPtr
    // lands at kRamHi-1; gate the END byte (+6+1) to match step 5.
    if (!NQD_INRANGE(portPtr + 6 + 1)) {
        NQD_LOG("nqd_read_rgb_op_color: rgbOpColor unreachable (step 2: "
                "portVersion@+6 spilled, portPtr=0x%08x) — lowmem 0x0A28 "
                "fallback", portPtr);
        return fallback;
    }
    uint16_t portVersion = nqd_walk_read16(portPtr + 6);
    if ((portVersion & 0xC000) == 0) {
        NQD_LOG("nqd_read_rgb_op_color: rgbOpColor unreachable (step 2: basic "
                "GrafPort, portVersion=0x%04x) — lowmem 0x0A28 fallback",
                portVersion);
        return fallback;
    }

    // Step 3: grafVars Handle @ CGrafPort + 8. Gate the FULL 4-byte read extent
    // (+8..+11), then the resulting Handle value. Previously only the
    // START byte (+8) was gated, allowing a ≤3-byte over-read; gate the END byte
    // (+8+3) to match step 5.
    if (!NQD_INRANGE(portPtr + 8 + 3)) {
        NQD_LOG("nqd_read_rgb_op_color: rgbOpColor unreachable (step 3: "
                "grafVars@+8 spilled, portPtr=0x%08x) — lowmem 0x0A28 fallback",
                portPtr);
        return fallback;
    }
    uint32_t grafVarsH = nqd_walk_read32(portPtr + 8);
    // Gate the FULL 4-byte Handle deref extent (grafVarsH..grafVarsH+3) BEFORE
    // step 4 reads it. Previously only the START byte (grafVarsH) was
    // gated, allowing a ≤3-byte over-read when grafVarsH lands at kRamHi-1.
    if (grafVarsH == 0 || !NQD_INRANGE(grafVarsH) || !NQD_INRANGE(grafVarsH + 3)) {
        NQD_LOG("nqd_read_rgb_op_color: rgbOpColor unreachable (step 3: "
                "grafVarsH=0x%08x) — lowmem 0x0A28 fallback", grafVarsH);
        return fallback;
    }

    // Step 4: dereference Handle → GrafVars pointer. Gate the resulting ptr.
    uint32_t grafVarsPtr = nqd_walk_read32(grafVarsH);
    if (grafVarsPtr == 0 || !NQD_INRANGE(grafVarsPtr)) {
        NQD_LOG("nqd_read_rgb_op_color: rgbOpColor unreachable (step 4: "
                "grafVarsPtr=0x%08x) — lowmem 0x0A28 fallback", grafVarsPtr);
        return fallback;
    }

    // Step 5: rgbOpColor RGBColor @ GrafVars + 0 — red/green/blue as 3
    // big-endian uint16. Confirm the whole 6-byte RGBColor fits in range
    // before reading any channel.
    if (!NQD_INRANGE(grafVarsPtr + 4 + 1)) {
        NQD_LOG("nqd_read_rgb_op_color: rgbOpColor unreachable (step 5: "
                "RGBColor spilled, grafVarsPtr=0x%08x) — lowmem 0x0A28 "
                "fallback", grafVarsPtr);
        return fallback;
    }
    NQDRgbOpColor out;
    out.r = (uint32_t)nqd_walk_read16(grafVarsPtr + 0);
    out.g = (uint32_t)nqd_walk_read16(grafVarsPtr + 2);
    out.b = (uint32_t)nqd_walk_read16(grafVarsPtr + 4);
    return out;
}

#ifdef TESTING_BUILD
// Headless gate hook: exposes the per-channel rgbOpColor walk
// (and its logged lowmem 0x0A28 fallback) to NQDTransferModeTests so the
// 3-channel / fallback behaviour can be asserted on a host with no GPU (the
// headless logic gate). Forward-declared in the test as
// `extern "C" void NQDTesting_ReadRgbOpColor(uint32_t *r, uint32_t *g,
// uint32_t *b)`. Thin forwarder so the static-inline helper need not be
// exported. Defined AFTER nqd_read_rgb_op_color() (use-after-declaration).
extern "C" void NQDTesting_ReadRgbOpColor(uint32_t *out_r, uint32_t *out_g,
                                          uint32_t *out_b)
{
	NQDRgbOpColor op = nqd_read_rgb_op_color();
	if (out_r) *out_r = op.r;
	if (out_g) *out_g = op.g;
	if (out_b) *out_b = op.b;
}
#endif /* TESTING_BUILD */

// ---------------------------------------------------------------------------
// Helper: bytes per pixel
// ---------------------------------------------------------------------------

static inline int nqd_bytes_per_pixel(uint32 pixel_size)
{
    switch (pixel_size) {
        case 8:        return 1;
        case 15:
        case 16:       return 2;
        case 24:
        case 32:       return 4;
        default:       return 1;
    }
}

// ---------------------------------------------------------------------------
// Helper: packed pixel width in bytes (handles sub-byte depths)
// Matches TrivialBytesPerRow from video.h for all 6 Apple depths.
// ---------------------------------------------------------------------------

static inline uint32_t nqd_packed_width_bytes(int width, uint32_t pixel_size_bits)
{
    switch (pixel_size_bits) {
        case 1:  return (uint32_t)((width + 7) / 8);
        case 2:  return (uint32_t)((width + 3) / 4);
        case 4:  return (uint32_t)((width + 1) / 2);
        case 8:  return (uint32_t)width;
        case 15:
        case 16: return (uint32_t)(width * 2);
        case 24:
        case 32: return (uint32_t)(width * 4);
        default: return (uint32_t)width;
    }
}

// ---------------------------------------------------------------------------
// Helper: byte offset for pixel X coordinate (handles sub-byte depths)
// For packed depths (1/2/4), returns the byte containing pixel X.
// ---------------------------------------------------------------------------

static inline uint32_t nqd_packed_byte_offset(int x, uint32_t pixel_size_bits)
{
    switch (pixel_size_bits) {
        case 1:  return (uint32_t)(x / 8);
        case 2:  return (uint32_t)(x / 4);
        case 4:  return (uint32_t)(x / 2);
        case 8:  return (uint32_t)x;
        case 15:
        case 16: return (uint32_t)(x * 2);
        case 24:
        case 32: return (uint32_t)(x * 4);
        default: return (uint32_t)x;
    }
}

// ---------------------------------------------------------------------------
// NQDMetalInit — create device, queue, pipeline, wrap Mac RAM
// ---------------------------------------------------------------------------

void NQDMetalInit(void)
{
    NQD_LOG("NQDMetalInit: starting");

#ifdef TESTING_BUILD
    // Test injection path: if the test has already called
    // NQDTesting_SetDevice(), honour the injected pair.  Otherwise fall
    // back to the shared singletons so legacy smoke tests still work.
    if (!nqd_device) {
        nqd_device = (__bridge id<MTLDevice>)SharedMetalDevice();
    }
    if (!nqd_device) {
        NQD_ERR("NQDMetalInit: no injected device + SharedMetalDevice failed — no Metal GPU");
        return;
    }
    NQD_LOG("NQDMetalInit: device=%p (%s)", nqd_device, [[nqd_device name] UTF8String]);

    if (!nqd_queue) {
        nqd_queue = (__bridge id<MTLCommandQueue>)SharedMetalCommandQueue();
    }
    if (!nqd_queue) {
        NQD_ERR("NQDMetalInit: no injected queue + SharedMetalCommandQueue failed");
        nqd_device = nil;
        return;
    }
#else
    // Production path (TESTING_BUILD undefined): always use shared singletons.
    nqd_device = (__bridge id<MTLDevice>)SharedMetalDevice();
    if (!nqd_device) {
        NQD_ERR("NQDMetalInit: SharedMetalDevice failed — no Metal GPU");
        return;
    }
    NQD_LOG("NQDMetalInit: device=%p (%s)", nqd_device, [[nqd_device name] UTF8String]);

    // Create command queue
    nqd_queue = (__bridge id<MTLCommandQueue>)SharedMetalCommandQueue();
    if (!nqd_queue) {
        NQD_ERR("NQDMetalInit: SharedMetalCommandQueue failed");
        nqd_device = nil;
        return;
    }
#endif /* TESTING_BUILD */

    // Load shader library (compiled into app bundle as default metallib)
    id<MTLLibrary> library = nil;
#ifdef TESTING_BUILD
    if (nqd_testing_bundle) {
        // Under xctest (no host app), NSBundle.mainBundle is the `xctest`
        // runner, not the `.xctest` bundle that actually contains
        // `default.metallib`.  Tests call NQDTesting_SetBundle() with
        // `[NSBundle bundleForClass:<TestClass>]` to direct the loader
        // at the right bundle.
        NSError *libErr = nil;
        NSBundle *bundle = (NSBundle *)nqd_testing_bundle;
        library = [nqd_device newDefaultLibraryWithBundle:bundle error:&libErr];
        if (!library) {
            NQD_ERR("NQDMetalInit: newDefaultLibraryWithBundle:%s failed: %s",
                    [[bundle bundlePath] UTF8String],
                    libErr ? [[libErr localizedDescription] UTF8String] : "(no error)");
        }
    }
    if (!library) {
        library = [nqd_device newDefaultLibrary];
    }
#else
    library = [nqd_device newDefaultLibrary];
#endif
    if (!library) {
        NQD_ERR("NQDMetalInit: newDefaultLibrary failed — no .metallib in bundle");
        nqd_queue = nil;
        nqd_device = nil;
        return;
    }

    // Create compute pipeline for nqd_bitblt kernel
    id<MTLFunction> bitblt_func = [library newFunctionWithName:@"nqd_bitblt"];
    if (!bitblt_func) {
        NQD_ERR("NQDMetalInit: kernel function 'nqd_bitblt' not found in library");
        nqd_queue = nil;
        nqd_device = nil;
        return;
    }

    NSError *error = nil;
    nqd_bitblt_pipeline = [nqd_device newComputePipelineStateWithFunction:bitblt_func error:&error];
    if (!nqd_bitblt_pipeline) {
        NQD_ERR("NQDMetalInit: bitblt pipeline creation failed: %s",
                [[error localizedDescription] UTF8String]);
        nqd_queue = nil;
        nqd_device = nil;
        return;
    }

    // Create compute pipeline for nqd_bitblt_scaled kernel (DSpBlit_Faster
    // scaling path). Built the same way as nqd_bitblt_pipeline.
    id<MTLFunction> bitblt_scaled_func = [library newFunctionWithName:@"nqd_bitblt_scaled"];
    if (!bitblt_scaled_func) {
        NQD_ERR("NQDMetalInit: kernel function 'nqd_bitblt_scaled' not found in library");
        nqd_bitblt_pipeline = nil;
        nqd_queue = nil;
        nqd_device = nil;
        return;
    }

    error = nil;
    nqd_bitblt_scaled_pipeline = [nqd_device newComputePipelineStateWithFunction:bitblt_scaled_func error:&error];
    if (!nqd_bitblt_scaled_pipeline) {
        NQD_ERR("NQDMetalInit: bitblt_scaled pipeline creation failed: %s",
                [[error localizedDescription] UTF8String]);
        nqd_bitblt_pipeline = nil;
        nqd_queue = nil;
        nqd_device = nil;
        return;
    }

    // Create compute pipeline for nqd_fillrect kernel
    id<MTLFunction> fillrect_func = [library newFunctionWithName:@"nqd_fillrect"];
    if (!fillrect_func) {
        NQD_ERR("NQDMetalInit: kernel function 'nqd_fillrect' not found in library");
        nqd_bitblt_scaled_pipeline = nil;
        nqd_bitblt_pipeline = nil;
        nqd_queue = nil;
        nqd_device = nil;
        return;
    }

    error = nil;
    nqd_fillrect_pipeline = [nqd_device newComputePipelineStateWithFunction:fillrect_func error:&error];
    if (!nqd_fillrect_pipeline) {
        NQD_ERR("NQDMetalInit: fillrect pipeline creation failed: %s",
                [[error localizedDescription] UTF8String]);
        nqd_bitblt_scaled_pipeline = nil;
        nqd_bitblt_pipeline = nil;
        nqd_queue = nil;
        nqd_device = nil;
        return;
    }

    // Wrap Mac RAM as a shared Metal buffer (zero-copy — GPU reads/writes CPU memory)
    // Use RAMBaseHost (the mmap'd allocation) instead of Mac2HostAddr(0), which
    // may hit the gZeroPage intercept and return a non-page-aligned global array.
    // Metal's newBufferWithBytesNoCopy requires both pointer and length to be page-aligned.
    uint8 *ram_host = RAMBaseHost;
    nqd_ram_buffer = [nqd_device newBufferWithBytesNoCopy:ram_host
                                                   length:RAMSize
                                                  options:MTLResourceStorageModeShared
                                              deallocator:nil];
    if (!nqd_ram_buffer) {
        NQD_ERR("NQDMetalInit: newBufferWithBytesNoCopy failed (RAMSize=%u, host=%p)", RAMSize, ram_host);
        nqd_fillrect_pipeline = nil;
        nqd_bitblt_scaled_pipeline = nil;
        nqd_bitblt_pipeline = nil;
        nqd_queue = nil;
        nqd_device = nil;
        return;
    }

    nqd_ram_base = ram_host;
    nqd_ram_size = RAMSize;
    nqd_metal_available = true;
    NQD_LOG("NQDMetalInit: success — device=%s, RAMSize=%u, ram_buffer=%p",
            [[nqd_device name] UTF8String], RAMSize, nqd_ram_buffer);
}

// ---------------------------------------------------------------------------
// Helper: check if transfer mode is arithmetic/hilite (per-pixel dispatch)
// ---------------------------------------------------------------------------

static inline bool nqd_is_pixel_mode(uint32_t mode)
{
    return (mode >= 32 && mode <= 39) || mode == 50;
}

// ---------------------------------------------------------------------------
// Helper: pack HiliteRGB from Mac low-memory global into pixel-depth value
//
// HiliteRGB at Mac address 0x0DA0: 6 bytes = uint16 red, uint16 green, uint16 blue
// (big-endian, each 0-65535). Pack to pixel-depth representation matching
// framebuffer byte order (big-endian packed via htonl pattern).
// ---------------------------------------------------------------------------

#ifdef TESTING_BUILD
// Test-only seam for the HiliteRGB lowmem read. Under EMULATED_PPC=0 (the test
// build) ReadMacInt16 is a raw host-pointer dereference, so reading guest lowmem
// 0x0DA0/0x0DA2/0x0DA4 (HiliteRGB) would data-fault (same EMULATED_PPC=0 caveat
// as the thePort/OpColor seam above). This lets the
// one-directional-hilite pixel gate inject a known HiliteRGB so u.hilite_color
// is deterministic. Production builds never see this; the raw lowmem reads are
// used directly and are safe because ReadMacInt* maps guest memory.
static bool     nqd_test_hilite_override = false;
static uint16_t nqd_test_hilite_r        = 0;
static uint16_t nqd_test_hilite_g        = 0;
static uint16_t nqd_test_hilite_b        = 0;

extern "C" void NQDTesting_SetHiliteOverride(int enable,
                                             uint16_t r, uint16_t g, uint16_t b)
{
    nqd_test_hilite_override = (enable != 0);
    nqd_test_hilite_r = r;
    nqd_test_hilite_g = g;
    nqd_test_hilite_b = b;
}
#endif /* TESTING_BUILD */

static uint32_t nqd_pack_hilite_color(int bpp)
{
    uint16 r16, g16, b16;
#ifdef TESTING_BUILD
    if (nqd_test_hilite_override) {
        // SHORT-CIRCUIT the raw lowmem reads: under EMULATED_PPC=0 a raw
        // ReadMacInt16(0x0DA0) is a literal host-pointer deref and would
        // data-fault. The injected HiliteRGB stands in for the lowmem read.
        r16 = nqd_test_hilite_r;
        g16 = nqd_test_hilite_g;
        b16 = nqd_test_hilite_b;
    } else
#endif
    {
        r16 = (uint16)ReadMacInt16(0x0DA0);
        g16 = (uint16)ReadMacInt16(0x0DA2);
        b16 = (uint16)ReadMacInt16(0x0DA4);
    }

    if (bpp == 1) {
        // 8bpp indexed: use red channel high byte as index approximation
        // (DELIBERATE-documented approximation; no
        // Color-Manager inverse-table is reachable from the NQD path).
        return (r16 >> 8) & 0xFF;
    } else if (bpp == 2) {
        // 16bpp 1-5-5-5 ARGB: truncate 16-bit channels to 5-bit, set alpha=1
        uint16 r5 = (r16 >> 11) & 0x1F;
        uint16 g5 = (g16 >> 11) & 0x1F;
        uint16 b5 = (b16 >> 11) & 0x1F;
        return (uint32_t)((1 << 15) | (r5 << 10) | (g5 << 5) | b5);
    } else {
        // 32bpp ARGB: truncate 16-bit channels to 8-bit, alpha=0xFF
        uint8_t r8 = (r16 >> 8) & 0xFF;
        uint8_t g8 = (g16 >> 8) & 0xFF;
        uint8_t b8 = (b16 >> 8) & 0xFF;
        return (uint32_t)((0xFF << 24) | (r8 << 16) | (g8 << 8) | b8);
    }
}

static bool nqd_cpu_fillrect_packed_boolean(uint32 dest_base,
                                            int32 dest_row_bytes,
                                            int16 dest_X,
                                            int16 dest_Y,
                                            int16 width,
                                            int16 height,
                                            uint32 pixel_size,
                                            uint32 transfer_mode,
                                            uint32 fill_color)
{
    if (pixel_size == 0 || pixel_size >= 8) return false;
    if (transfer_mode < 8 || transfer_mode > 15) return false;

    NQDMetalFlush();

    uint8 *dst_ptr = Mac2HostAddr(dest_base)
                   + (dest_Y * dest_row_bytes)
                   + nqd_packed_byte_offset(dest_X, pixel_size);
    const uint32 width_bytes = nqd_packed_width_bytes(width, pixel_size);
    const uint8_t fill = (uint8_t)(fill_color & 0xFFu);

    if (pixel_size == 1) {
        const uint32_t fill_index = NQDPacked1BppIndexFromNativeColor(fill_color);
        uint8 *dst_row = Mac2HostAddr(dest_base) + (dest_Y * dest_row_bytes);
        for (int row = 0; row < height; row++) {
            for (int col = 0; col < width; col++) {
                const uint32_t x = (uint32_t)dest_X + (uint32_t)col;
                uint8_t *byte = dst_row + (x >> 3);
                const uint32_t d = NQDPackedGet1BppPixel(*byte, x);
                uint32_t out = 0;
                switch (transfer_mode) {
                    case 8:  out = fill_index;              break;
                    case 9:  out = fill_index | d;          break;
                    case 10: out = fill_index ^ d;          break;
                    case 11: out = (~fill_index) & d;       break;
                    case 12: out = ~fill_index;             break;
                    case 13: out = (~fill_index) | d;       break;
                    case 14: out = (~fill_index) ^ d;       break;
                    case 15: out = fill_index & d;          break;
                }
                *byte = NQDPackedSet1BppPixel(*byte, x, out);
            }
            dst_row += dest_row_bytes;
        }
        return true;
    }

    for (int row = 0; row < height; row++) {
        for (uint32 b = 0; b < width_bytes; b++) {
            uint8_t d = dst_ptr[b];
            switch (transfer_mode) {
                case 8:  dst_ptr[b] = fill;             break;
                case 9:  dst_ptr[b] = fill | d;         break;
                case 10: dst_ptr[b] = fill ^ d;         break;
                case 11: dst_ptr[b] = (uint8_t)(~fill) & d; break;
                case 12: dst_ptr[b] = (uint8_t)(~fill); break;
                case 13: dst_ptr[b] = (uint8_t)(~fill) | d; break;
                case 14: dst_ptr[b] = (uint8_t)(~fill) ^ d; break;
                case 15: dst_ptr[b] = fill & d;         break;
            }
        }
        dst_ptr += dest_row_bytes;
    }

    return true;
}

static bool nqd_cpu_bitblt_packed_boolean(uint32 src_base,
                                          int32 src_row_bytes,
                                          uint32 dest_base,
                                          int32 dest_row_bytes,
                                          int16 src_X,
                                          int16 src_Y,
                                          int16 dest_X,
                                          int16 dest_Y,
                                          int16 width,
                                          int16 height,
                                          uint32 pixel_size,
                                          uint32 transfer_mode,
                                          uint32 fore_pen,
                                          uint32 back_pen)
{
    if (pixel_size == 0 || pixel_size >= 8) return false;
    if (transfer_mode > 7) return false;

    NQDMetalFlush();

    uint8 *src_ptr = Mac2HostAddr(src_base)
                   + (src_Y * src_row_bytes)
                   + nqd_packed_byte_offset(src_X, pixel_size);
    uint8 *dst_ptr = Mac2HostAddr(dest_base)
                   + (dest_Y * dest_row_bytes)
                   + nqd_packed_byte_offset(dest_X, pixel_size);
    const uint32 width_bytes = nqd_packed_width_bytes(width, pixel_size);

    if (pixel_size == 1) {
        const uint32 fore_bit = NQDPacked1BppIndexFromNativeColor(ntohl(fore_pen));
        const uint32 back_bit = NQDPacked1BppIndexFromNativeColor(ntohl(back_pen));
        uint8 *src_row = Mac2HostAddr(src_base) + (src_Y * src_row_bytes);
        uint8 *dst_row = Mac2HostAddr(dest_base) + (dest_Y * dest_row_bytes);
        for (int row = 0; row < height; row++) {
            for (int col = 0; col < width; col++) {
                const uint32_t sx = (uint32_t)src_X + (uint32_t)col;
                const uint32_t dx = (uint32_t)dest_X + (uint32_t)col;
                uint8_t *src_byte = src_row + (sx >> 3);
                uint8_t *dst_byte = dst_row + (dx >> 3);
                const uint32_t s_index =
                    NQDPackedGet1BppPixel(*src_byte, sx) ? fore_bit : back_bit;
                const uint32_t d = NQDPackedGet1BppPixel(*dst_byte, dx);
                uint32_t out = 0;
                switch (transfer_mode) {
                    case 0:  out = s_index;                break;
                    case 1:  out = s_index | d;            break;
                    case 2:  out = s_index ^ d;            break;
                    case 3:  out = (~s_index) & d;         break;
                    case 4:  out = ~s_index;               break;
                    case 5:  out = (~s_index) | d;         break;
                    case 6:  out = (~s_index) ^ d;         break;
                    case 7:  out = s_index & d;            break;
                }
                *dst_byte = NQDPackedSet1BppPixel(*dst_byte, dx, out);
            }
            src_row += src_row_bytes;
            dst_row += dest_row_bytes;
        }
        return true;
    }

    for (int row = 0; row < height; row++) {
        for (uint32 b = 0; b < width_bytes; b++) {
            uint8_t src = src_ptr[b];
            uint8_t dst = dst_ptr[b];

            switch (transfer_mode) {
                case 0:  dst_ptr[b] = src;              break;
                case 1:  dst_ptr[b] = src | dst;        break;
                case 2:  dst_ptr[b] = src ^ dst;        break;
                case 3:  dst_ptr[b] = (uint8_t)(~src) & dst; break;
                case 4:  dst_ptr[b] = (uint8_t)(~src);  break;
                case 5:  dst_ptr[b] = (uint8_t)(~src) | dst; break;
                case 6:  dst_ptr[b] = (uint8_t)(~src) ^ dst; break;
                case 7:  dst_ptr[b] = src & dst;        break;
            }
        }
        src_ptr += src_row_bytes;
        dst_ptr += dest_row_bytes;
    }

    return true;
}

static inline uint32_t nqd_direct_pixel_from_native_color(uint32_t native_color,
                                                          uint32_t pixel_size)
{
    const uint32_t rgb = native_color & 0x00ffffffu;
    const uint32_t r = (rgb >> 16) & 0xffu;
    const uint32_t g = (rgb >> 8) & 0xffu;
    const uint32_t b = rgb & 0xffu;

    if (pixel_size == 16) {
        return 0x8000u | ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
    }
    if (pixel_size == 32) {
        return 0xff000000u | (r << 16) | (g << 8) | b;
    }
    return native_color;
}

static inline uint32_t nqd_apply_boolean_pixel(uint32_t src,
                                               uint32_t dst,
                                               uint32_t transfer_mode,
                                               uint32_t mask)
{
    uint32_t out = 0;
    switch (transfer_mode) {
        case 0:  out = src;          break;
        case 1:  out = src | dst;    break;
        case 2:  out = src ^ dst;    break;
        case 3:  out = (~src) & dst; break;
        case 4:  out = ~src;         break;
        case 5:  out = (~src) | dst; break;
        case 6:  out = (~src) ^ dst; break;
        case 7:  out = src & dst;    break;
        default: out = dst;          break;
    }
    return out & mask;
}

static bool nqd_cpu_bitblt_1bpp_to_direct_boolean(uint32 src_base,
                                                  int32 src_row_bytes,
                                                  uint32 dest_base,
                                                  int32 dest_row_bytes,
                                                  int16 src_X,
                                                  int16 src_Y,
                                                  int16 dest_X,
                                                  int16 dest_Y,
                                                  int16 width,
                                                  int16 height,
                                                  uint32 dest_pixel_size,
                                                  uint32 transfer_mode,
                                                  uint32 fore_pen_native,
                                                  uint32 back_pen_native)
{
    if (dest_pixel_size != 16 && dest_pixel_size != 32) return false;
    if (transfer_mode > 7) return false;

    NQDMetalFlush();

    const uint32_t dest_bpp = dest_pixel_size / 8u;
    const uint32_t mask = (dest_pixel_size == 16) ? 0xffffu : 0xffffffffu;
    const uint32_t fore_pixel =
        nqd_direct_pixel_from_native_color(fore_pen_native, dest_pixel_size);
    const uint32_t back_pixel =
        nqd_direct_pixel_from_native_color(back_pen_native, dest_pixel_size);

    uint8 *src_row = Mac2HostAddr(src_base) + (src_Y * src_row_bytes);
    uint8 *dst_row = Mac2HostAddr(dest_base) + (dest_Y * dest_row_bytes);

    for (int row = 0; row < height; row++) {
        for (int col = 0; col < width; col++) {
            const uint32_t sx = (uint32_t)src_X + (uint32_t)col;
            const uint32_t dx = (uint32_t)dest_X + (uint32_t)col;
            const uint8_t *src_byte = src_row + (sx >> 3);
            uint8_t *dst = dst_row + (dx * dest_bpp);
            const uint32_t src_pixel =
                NQDPackedGet1BppPixel(*src_byte, sx) ? fore_pixel : back_pixel;
            uint32_t dst_pixel = 0;

            if (dest_pixel_size == 16) {
                dst_pixel = ((uint32_t)dst[0] << 8) | (uint32_t)dst[1];
            } else {
                dst_pixel = ((uint32_t)dst[0] << 24) |
                            ((uint32_t)dst[1] << 16) |
                            ((uint32_t)dst[2] << 8) |
                            (uint32_t)dst[3];
            }

            const uint32_t out =
                nqd_apply_boolean_pixel(src_pixel, dst_pixel, transfer_mode, mask);
            if (dest_pixel_size == 16) {
                dst[0] = (uint8_t)((out >> 8) & 0xffu);
                dst[1] = (uint8_t)(out & 0xffu);
            } else {
                dst[0] = (uint8_t)((out >> 24) & 0xffu);
                dst[1] = (uint8_t)((out >> 16) & 0xffu);
                dst[2] = (uint8_t)((out >> 8) & 0xffu);
                dst[3] = (uint8_t)(out & 0xffu);
            }
        }
        src_row += src_row_bytes;
        dst_row += dest_row_bytes;
    }

    return true;
}

// ---------------------------------------------------------------------------
// Mask buffer management (file-static)
// ---------------------------------------------------------------------------

static id<MTLBuffer>  nqd_mask_buffer      = nil;
static NSUInteger     nqd_mask_buffer_size  = 0;

static void nqd_ensure_mask_buffer(NSUInteger needed)
{
    if (nqd_mask_buffer && nqd_mask_buffer_size >= needed) return;
    // Round up to 4 KB granularity for reuse
    NSUInteger alloc_size = (needed + 4095) & ~(NSUInteger)4095;
    nqd_mask_buffer = (__bridge_transfer id<MTLBuffer>)
        gfxaccel_resources_heap_alloc_buffer(kHeapEngineNQD,
                                             (uint32_t)alloc_size,
                                             MTLResourceStorageModeShared);
    if (!nqd_mask_buffer) {
        NQD_ERR("heap alloc failed for mask buffer (%lu bytes); falling back to device alloc",
                (unsigned long)alloc_size);
        nqd_mask_buffer = [nqd_device newBufferWithLength:alloc_size
                                                  options:MTLResourceStorageModeShared];  // heap-exempt: startup fallback
    }
    nqd_mask_buffer_size = alloc_size;
    NQD_LOG("nqd_ensure_mask_buffer: allocated %lu bytes", (unsigned long)alloc_size);
}

// ---------------------------------------------------------------------------
// nqd_decode_region — QuickDraw Region to 1-byte-per-cell bitmap
//
// Takes a Mac address pointing to a QuickDraw Region, the destination rect
// dimensions (for coordinate mapping), and an output buffer pointer + size.
// Returns true on success. The output bitmap is 1 byte per cell where 1 means
// "inside region" and 0 means "outside".
//
// For mask_width: this is either width_bytes (Boolean modes) or width_pixels
// (arithmetic modes). The caller provides the correct stride.
// ---------------------------------------------------------------------------

static bool nqd_decode_region(uint32 rgn_addr, int dest_width, int dest_height,
                               uint8_t *out_mask, NSUInteger mask_size)
{
    if (rgn_addr == 0) {
        NQD_ERR("nqd_decode_region: null region address");
        return false;
    }

    // Bounds-check the region header (10 bytes minimum)
    uint16 rgnSize = ReadMacInt16(rgn_addr);
    if (rgnSize < 10) {
        NQD_ERR("nqd_decode_region: invalid rgnSize %u (< 10)", rgnSize);
        return false;
    }

    int16 bbox_top    = (int16)ReadMacInt16(rgn_addr + 2);
    int16 bbox_left   = (int16)ReadMacInt16(rgn_addr + 4);
    int16 bbox_bottom = (int16)ReadMacInt16(rgn_addr + 6);
    int16 bbox_right  = (int16)ReadMacInt16(rgn_addr + 8);

    if (bbox_top >= bbox_bottom || bbox_left >= bbox_right) {
        NQD_ERR("nqd_decode_region: invalid bbox (%d,%d)-(%d,%d)",
                bbox_top, bbox_left, bbox_bottom, bbox_right);
        return false;
    }

    int rgn_width  = bbox_right - bbox_left;

    NQD_VLOG("nqd_decode_region: rgnSize=%u bbox=(%d,%d,%d,%d) dest=%dx%d",
             rgnSize, bbox_top, bbox_left, bbox_bottom, bbox_right,
             dest_width, dest_height);

    // Ensure output buffer is large enough
    NSUInteger needed = (NSUInteger)(dest_width * dest_height);
    if (needed > mask_size) {
        NQD_ERR("nqd_decode_region: mask_size %lu < needed %lu",
                (unsigned long)mask_size, (unsigned long)needed);
        return false;
    }

    // Rectangular region (rgnSize == 10): fill all 1s (region = bbox = dest rect)
    if (rgnSize == 10) {
        NQD_VLOG("nqd_decode_region: rectangular region — filling all 1s");
        memset(out_mask, 1, needed);
        return true;
    }

    // Complex region: decode RLE scanline data
    // Initialize mask to all 0s; we'll set 1s for inside pixels
    memset(out_mask, 0, needed);

    // Scanline state: tracks which columns are "inside" the region.
    // The region scanline data works by inversion: each h-point toggles inside/outside.
    // State persists across scanlines (running state).
    int max_cols = rgn_width;
    if (max_cols <= 0 || max_cols > 16384) {
        NQD_ERR("nqd_decode_region: unreasonable rgn_width %d", max_cols);
        return false;
    }

    // Running state: one bool per column of the region bbox
    std::vector<uint8_t> col_state(max_cols, 0);

    uint32 offset = rgn_addr + 10;  // Start of scanline data
    uint32 rgn_end = rgn_addr + rgnSize;
    int prev_v = bbox_top;
    int inversion_count = 0;

    while (offset + 2 <= rgn_end) {
        int16 v_coord = (int16)ReadMacInt16(offset);
        offset += 2;

        // End sentinel
        if (v_coord == 0x7FFF) break;

        // Fill mask rows from prev_v to v_coord using current col_state
        for (int row = prev_v; row < v_coord; row++) {
            int mask_row = row - bbox_top;
            if (mask_row < 0 || mask_row >= dest_height) continue;
            for (int c = 0; c < max_cols && c < dest_width; c++) {
                if (col_state[c]) {
                    out_mask[mask_row * dest_width + c] = 1;
                }
            }
        }

        // Read horizontal inversion points for this scanline
        while (offset + 2 <= rgn_end) {
            int16 h_point = (int16)ReadMacInt16(offset);
            offset += 2;

            if (h_point == 0x7FFF) break;  // End of h-points for this scanline

            // Toggle all columns from h_point to the next h_point
            int h_col = h_point - bbox_left;
            if (h_col >= 0 && h_col < max_cols) {
                // Toggle from h_col onward (next h_point will stop the toggle)
                // Actually, inversion points work in pairs: toggle from h_col to next h_point
                // But the way QuickDraw encodes it, each point just toggles the running state
                // for that column onward. Let's apply it correctly:
                // Read the next h_point to know the range end
                // Actually, QD region points toggle the inside/outside state at each x coordinate.
                // They come in pairs and toggle entire ranges.
                for (int c = h_col; c < max_cols; c++) {
                    col_state[c] = !col_state[c];
                }
                inversion_count++;
            }
        }

        prev_v = v_coord;
    }

    // Fill remaining rows from prev_v to bbox_bottom
    for (int row = prev_v; row < bbox_bottom; row++) {
        int mask_row = row - bbox_top;
        if (mask_row < 0 || mask_row >= dest_height) continue;
        for (int c = 0; c < max_cols && c < dest_width; c++) {
            if (col_state[c]) {
                out_mask[mask_row * dest_width + c] = 1;
            }
        }
    }

    NQD_VLOG("nqd_decode_region: complex region decoded, %d inversions", inversion_count);
    return true;
}

// ---------------------------------------------------------------------------
// NQDMetalBltMask — bitblt with mask via Metal compute
//
// Reads accl_params + mask region from Mac memory. Decodes region to bitmap,
// dispatches through existing nqd_bitblt pipeline with mask buffer at index 2.
// ---------------------------------------------------------------------------

void NQDMetalBltMask(uint32 p)
{
    if (!nqd_metal_available) return;

    // Flush any pending batch — mask ops use the shared mask buffer which
    // may be overwritten between calls, so we need serial execution.
    NQDMetalFlush();

    // Extract bitblt parameters (same as NQDMetalBitblt)
    int16 src_X  = (int16)ReadMacInt16(p + NQD_acclSrcRect + 2) - (int16)ReadMacInt16(p + NQD_acclSrcBoundsRect + 2);
    int16 src_Y  = (int16)ReadMacInt16(p + NQD_acclSrcRect + 0) - (int16)ReadMacInt16(p + NQD_acclSrcBoundsRect + 0);
    int16 dest_X = (int16)ReadMacInt16(p + NQD_acclDestRect + 2) - (int16)ReadMacInt16(p + NQD_acclDestBoundsRect + 2);
    int16 dest_Y = (int16)ReadMacInt16(p + NQD_acclDestRect + 0) - (int16)ReadMacInt16(p + NQD_acclDestBoundsRect + 0);
    int16 width  = (int16)ReadMacInt16(p + NQD_acclDestRect + 6) - (int16)ReadMacInt16(p + NQD_acclDestRect + 2);
    int16 height = (int16)ReadMacInt16(p + NQD_acclDestRect + 4) - (int16)ReadMacInt16(p + NQD_acclDestRect + 0);

    if (width <= 0 || height <= 0) return;

    uint32 src_pixel_size = ReadMacInt32(p + NQD_acclSrcPixelSize);
    int bpp = nqd_bytes_per_pixel(src_pixel_size);
    if (src_pixel_size < 8) bpp = 1;  // packed depths: byte-level ops
    uint32 width_bytes = nqd_packed_width_bytes(width, src_pixel_size);
    uint32 width_pixels = (uint32)width;

    uint32 src_base = ReadMacInt32(p + NQD_acclSrcBaseAddr);
    uint32 dest_base = ReadMacInt32(p + NQD_acclDestBaseAddr);
    int32 src_row_bytes = (int32)ReadMacInt32(p + NQD_acclSrcRowBytes);
    int32 dest_row_bytes = (int32)ReadMacInt32(p + NQD_acclDestRowBytes);

    uint32_t transfer_mode = ReadMacInt32(p + NQD_acclTransferMode);
    uint32_t fore_pen = htonl(ReadMacInt32(p + NQD_acclForePen));
    uint32_t back_pen = htonl(ReadMacInt32(p + NQD_acclBackPen));
    uint32_t hilite_color = (transfer_mode == 50) ? nqd_pack_hilite_color(bpp) : 0;

    bool pixel_mode = nqd_is_pixel_mode(transfer_mode);

    // Read mask region address from accl_params
    uint32 mask_rgn_addr = ReadMacInt32(p + NQD_acclMaskAddr);
    NQD_VLOG("NQDMetalBltMask: mask_rgn_addr=0x%08x mode=%d %dx%d bpp=%d bits_per_pixel=%u",
             mask_rgn_addr, transfer_mode, width, height, bpp, src_pixel_size);

    // Determine mask stride based on mode
    uint32_t mask_stride = pixel_mode ? width_pixels : width_bytes;
    NSUInteger mask_size = (NSUInteger)(mask_stride * (uint32)height);

    // Allocate mask bitmap on CPU, decode region
    std::vector<uint8_t> cpu_mask(mask_size, 0);
    if (!nqd_decode_region(mask_rgn_addr, (int)mask_stride, (int)height,
                            cpu_mask.data(), mask_size)) {
        NQD_ERR("NQDMetalBltMask: region decode failed, skipping");
        return;
    }

    // Copy mask into GPU buffer
    nqd_ensure_mask_buffer(mask_size);
    memcpy([nqd_mask_buffer contents], cpu_mask.data(), mask_size);

    // Compute offsets
    uint8 *ram_base = nqd_ram_base;
    uint8 *src_ptr = Mac2HostAddr(src_base) + (src_Y * abs(src_row_bytes)) + nqd_packed_byte_offset(src_X, src_pixel_size);
    uint8 *dst_ptr = Mac2HostAddr(dest_base) + (dest_Y * abs(dest_row_bytes)) + nqd_packed_byte_offset(dest_X, src_pixel_size);
    uint32_t src_offset = (uint32_t)(src_ptr - ram_base);
    uint32_t dst_offset = (uint32_t)(dst_ptr - ram_base);

    NQDBitbltUniforms uniforms;
    uniforms.src_offset    = src_offset;
    uniforms.dst_offset    = dst_offset;
    uniforms.src_row_bytes = abs(src_row_bytes);
    uniforms.dst_row_bytes = abs(dest_row_bytes);
    uniforms.width_bytes   = width_bytes;
    uniforms.height        = (uint32_t)height;
    uniforms.transfer_mode = transfer_mode;
    uniforms.pixel_size    = (uint32_t)bpp;
    uniforms.width_pixels  = width_pixels;
    uniforms.fore_pen      = fore_pen;
    uniforms.back_pen      = back_pen;
    uniforms.hilite_color  = hilite_color;
    uniforms.mask_enabled  = 1;
    uniforms.mask_offset   = 0;
    uniforms.mask_stride   = mask_stride;
    uniforms.bits_per_pixel = src_pixel_size;
    {   // Per-channel rgbOpColor blend weights for mode 32.
        // The GrafVars walk (a 5-step guest-controlled Mac-VM read) is
        // consumed ONLY by blend mode 32, so gate it on the mode — for every
        // other transfer mode the weights are dead. This narrows the
        // guest-controlled OOB-read attack surface to blend dispatches and skips
        // the per-op lowmem traffic. Mode-32 behaviour is byte-identical.
        NQDRgbOpColor _op = (transfer_mode == 32) ? nqd_read_rgb_op_color()
                                                  : NQDRgbOpColor{0, 0, 0};
        uniforms.blend_weight_r = _op.r;
        uniforms.blend_weight_g = _op.g;
        uniforms.blend_weight_b = _op.b;
    }

    NSUInteger total_threads = (pixel_mode && src_pixel_size >= 8)
        ? (NSUInteger)(width_pixels * height)
        : (NSUInteger)(width_bytes * height);

    // Mask ops dispatch into a fresh batch (we flushed above) and immediately
    // flush again, since the next mask call may overwrite nqd_mask_buffer.
    id<MTLComputeCommandEncoder> encoder = nqd_get_batch_encoder();
    if (!encoder) return;

    [encoder setComputePipelineState:nqd_bitblt_pipeline];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:0];
    [encoder setBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setBuffer:nqd_mask_buffer offset:0 atIndex:2];

    NSUInteger threadgroup_size = nqd_bitblt_pipeline.maxTotalThreadsPerThreadgroup;
    if (threadgroup_size > 256) threadgroup_size = 256;
    if (threadgroup_size > total_threads) threadgroup_size = total_threads;

    MTLSize grid = MTLSizeMake(total_threads, 1, 1);
    MTLSize group = MTLSizeMake(threadgroup_size, 1, 1);
    [encoder dispatchThreads:grid threadsPerThreadgroup:group];

    NQDMetalFlush();  // must complete before mask buffer is reused
}

// ---------------------------------------------------------------------------
// NQDMetalFillMask — fill rect with mask via Metal compute
//
// Reads accl_params + mask region from Mac memory. Decodes region to bitmap,
// dispatches through existing nqd_fillrect pipeline with mask buffer at index 2.
// ---------------------------------------------------------------------------

void NQDMetalFillMask(uint32 p)
{
    if (!nqd_metal_available) return;

    // Flush any pending batch — mask ops use the shared mask buffer
    NQDMetalFlush();

    // Extract fillrect parameters (same as NQDMetalFillRect)
    int16 dest_X = (int16)ReadMacInt16(p + NQD_acclDestRect + 2) - (int16)ReadMacInt16(p + NQD_acclDestBoundsRect + 2);
    int16 dest_Y = (int16)ReadMacInt16(p + NQD_acclDestRect + 0) - (int16)ReadMacInt16(p + NQD_acclDestBoundsRect + 0);
    int16 width  = (int16)ReadMacInt16(p + NQD_acclDestRect + 6) - (int16)ReadMacInt16(p + NQD_acclDestRect + 2);
    int16 height = (int16)ReadMacInt16(p + NQD_acclDestRect + 4) - (int16)ReadMacInt16(p + NQD_acclDestRect + 0);

    if (width <= 0 || height <= 0) return;

    uint32 pixel_size = ReadMacInt32(p + NQD_acclDestPixelSize);
    int bpp = nqd_bytes_per_pixel(pixel_size);
    if (pixel_size < 8) bpp = 1;  // packed depths: byte-level ops
    int32 dest_row_bytes = (int32)ReadMacInt32(p + NQD_acclDestRowBytes);
    uint32 dest_base = ReadMacInt32(p + NQD_acclDestBaseAddr);

    uint32_t transfer_mode = ReadMacInt32(p + NQD_acclTransferMode);
    uint32_t pen_mode = ReadMacInt32(p + NQD_acclPenMode);
    uint32_t fore_pen = htonl(ReadMacInt32(p + NQD_acclForePen));
    uint32_t back_pen = htonl(ReadMacInt32(p + NQD_acclBackPen));
    uint32_t fore_pen_native = ReadMacInt32(p + NQD_acclForePen);
    uint32_t back_pen_native = ReadMacInt32(p + NQD_acclBackPen);
    uint32_t fill_color = (pen_mode == 8) ? fore_pen_native : back_pen_native;

    uint32 width_bytes = nqd_packed_width_bytes(width, pixel_size);
    uint32 width_pixels = (uint32)width;

    uint32_t hilite_color = (transfer_mode == 50) ? nqd_pack_hilite_color(bpp) : 0;
    bool pixel_mode = nqd_is_pixel_mode(transfer_mode);

    // Read mask region address from accl_params
    uint32 mask_rgn_addr = ReadMacInt32(p + NQD_acclMaskAddr);
    NQD_VLOG("NQDMetalFillMask: mask_rgn_addr=0x%08x mode=%d %dx%d bpp=%d bits_per_pixel=%u",
             mask_rgn_addr, transfer_mode, width, height, bpp, pixel_size);

    // Determine mask stride based on mode
    uint32_t mask_stride = pixel_mode ? width_pixels : width_bytes;
    NSUInteger mask_size = (NSUInteger)(mask_stride * (uint32)height);

    // Allocate mask bitmap on CPU, decode region
    std::vector<uint8_t> cpu_mask(mask_size, 0);
    if (!nqd_decode_region(mask_rgn_addr, (int)mask_stride, (int)height,
                            cpu_mask.data(), mask_size)) {
        NQD_ERR("NQDMetalFillMask: region decode failed, skipping");
        return;
    }

    // Copy mask into GPU buffer
    nqd_ensure_mask_buffer(mask_size);
    memcpy([nqd_mask_buffer contents], cpu_mask.data(), mask_size);

    // Compute offset
    uint8 *ram_base = nqd_ram_base;
    uint8 *dst_ptr = Mac2HostAddr(dest_base) + (dest_Y * dest_row_bytes) + nqd_packed_byte_offset(dest_X, pixel_size);
    uint32_t dst_offset = (uint32_t)(dst_ptr - ram_base);

    NQDFillRectUniforms uniforms;
    uniforms.dst_offset    = dst_offset;
    uniforms.row_bytes     = dest_row_bytes;
    uniforms.width_bytes   = width_bytes;
    uniforms.height        = (uint32_t)height;
    uniforms.fill_color    = fill_color;
    uniforms.bpp           = (uint32_t)bpp;
    uniforms.transfer_mode = transfer_mode;
    uniforms.pixel_size    = (uint32_t)bpp;
    uniforms.width_pixels  = width_pixels;
    uniforms.fore_pen      = fore_pen;
    uniforms.back_pen      = back_pen;
    uniforms.hilite_color  = hilite_color;
    uniforms.mask_enabled  = 1;
    uniforms.mask_offset   = 0;
    uniforms.mask_stride   = mask_stride;
    uniforms.bits_per_pixel = pixel_size;
    {   // Per-channel rgbOpColor blend weights for mode 32.
        // The GrafVars walk (a 5-step guest-controlled Mac-VM read) is
        // consumed ONLY by blend mode 32, so gate it on the mode — for every
        // other transfer mode the weights are dead. This narrows the
        // guest-controlled OOB-read attack surface to blend dispatches and skips
        // the per-op lowmem traffic. Mode-32 behaviour is byte-identical.
        NQDRgbOpColor _op = (transfer_mode == 32) ? nqd_read_rgb_op_color()
                                                  : NQDRgbOpColor{0, 0, 0};
        uniforms.blend_weight_r = _op.r;
        uniforms.blend_weight_g = _op.g;
        uniforms.blend_weight_b = _op.b;
    }

    NSUInteger total_threads = (pixel_mode && pixel_size >= 8)
        ? (NSUInteger)(width_pixels * height)
        : (NSUInteger)(width_bytes * height);

    id<MTLComputeCommandEncoder> encoder = nqd_get_batch_encoder();
    if (!encoder) return;

    [encoder setComputePipelineState:nqd_fillrect_pipeline];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:0];
    [encoder setBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setBuffer:nqd_mask_buffer offset:0 atIndex:2];

    NSUInteger threadgroup_size = nqd_fillrect_pipeline.maxTotalThreadsPerThreadgroup;
    if (threadgroup_size > 256) threadgroup_size = 256;
    if (threadgroup_size > total_threads) threadgroup_size = total_threads;

    MTLSize grid = MTLSizeMake(total_threads, 1, 1);
    MTLSize group = MTLSizeMake(threadgroup_size, 1, 1);
    [encoder dispatchThreads:grid threadsPerThreadgroup:group];

    NQDMetalFlush();  // must complete before mask buffer is reused
}

// ---------------------------------------------------------------------------
// NQDMetalCleanup — release all Metal resources
// ---------------------------------------------------------------------------

void NQDMetalCleanup(void)
{
    NQD_LOG("NQDMetalCleanup: releasing Metal resources");

    // Flush any pending batch before releasing resources
    NQDMetalFlush();

    nqd_metal_available = false;
    nqd_ram_base = nullptr;
    nqd_ram_size = 0;
    nqd_mask_buffer = nil;
    nqd_mask_buffer_size = 0;
    nqd_ram_buffer = nil;
    nqd_fillrect_pipeline = nil;
    nqd_bitblt_scaled_pipeline = nil;
    nqd_bitblt_pipeline = nil;
    nqd_queue = nil;
    nqd_device = nil;

    NQD_LOG("NQDMetalCleanup: done");
}

// ---------------------------------------------------------------------------
// NQDMetalBitblt — bitblt via Metal compute for all transfer modes
//
// Reads accl_params from Mac memory at address p. Dispatches the nqd_bitblt
// compute kernel. For overlapping blits (negative row_bytes), rows are
// dispatched one at a time in reverse order to ensure correctness.
//
// Boolean modes (0-7): per-byte dispatch (width_bytes * height threads)
// Arithmetic modes (32-39) + hilite (50): per-pixel dispatch (width_pixels * height)
// ---------------------------------------------------------------------------

void NQDMetalBitblt(uint32 p)
{
    if (!nqd_metal_available) return;

    // Extract parameters from accl_params in Mac memory
    int16 src_X  = (int16)ReadMacInt16(p + NQD_acclSrcRect + 2) - (int16)ReadMacInt16(p + NQD_acclSrcBoundsRect + 2);
    int16 src_Y  = (int16)ReadMacInt16(p + NQD_acclSrcRect + 0) - (int16)ReadMacInt16(p + NQD_acclSrcBoundsRect + 0);
    int16 dest_X = (int16)ReadMacInt16(p + NQD_acclDestRect + 2) - (int16)ReadMacInt16(p + NQD_acclDestBoundsRect + 2);
    int16 dest_Y = (int16)ReadMacInt16(p + NQD_acclDestRect + 0) - (int16)ReadMacInt16(p + NQD_acclDestBoundsRect + 0);
    int16 width  = (int16)ReadMacInt16(p + NQD_acclDestRect + 6) - (int16)ReadMacInt16(p + NQD_acclDestRect + 2);
    int16 height = (int16)ReadMacInt16(p + NQD_acclDestRect + 4) - (int16)ReadMacInt16(p + NQD_acclDestRect + 0);

    // Edge case: nothing to blit
    if (width <= 0 || height <= 0) return;

    uint32 src_pixel_size  = ReadMacInt32(p + NQD_acclSrcPixelSize);
    uint32 dest_pixel_size = ReadMacInt32(p + NQD_acclDestPixelSize);
    int bpp = nqd_bytes_per_pixel(src_pixel_size);
    if (src_pixel_size < 8) bpp = 1;  // packed depths: byte-level ops
    uint32 width_bytes = nqd_packed_width_bytes(width, src_pixel_size);
    uint32 width_pixels = (uint32)width;

    uint32 src_base  = ReadMacInt32(p + NQD_acclSrcBaseAddr);
    uint32 dest_base = ReadMacInt32(p + NQD_acclDestBaseAddr);
    int32 src_row_bytes  = (int32)ReadMacInt32(p + NQD_acclSrcRowBytes);
    int32 dest_row_bytes = (int32)ReadMacInt32(p + NQD_acclDestRowBytes);

    // Read transfer mode and pen colors from accl_params
    uint32_t transfer_mode = ReadMacInt32(p + NQD_acclTransferMode);

    NQD_VLOG("NQDMetalBitblt: src=(%d,%d) dst=(%d,%d) %dx%d bpp=%d bits_per_pixel=%u dest_bits=%u mode=%d src_base=0x%08x dest_base=0x%08x src_rb=%d dst_rb=%d",
             src_X, src_Y, dest_X, dest_Y, width, height, bpp, src_pixel_size,
             dest_pixel_size, transfer_mode, src_base, dest_base,
             src_row_bytes, dest_row_bytes);

    NQDMainDevicePixMapSnapshot main_device = nqd_read_main_device_pixmap_snapshot();
    uint32_t packet_src_pixel_size = src_pixel_size;
    uint32_t packet_dest_pixel_size = dest_pixel_size;
    int32 packet_dest_row_bytes = dest_row_bytes;
    bool dest_packed_main_device_alias =
        nqd_is_packed_main_device_alias(main_device, dest_base,
                                        dest_row_bytes,
                                        packet_dest_pixel_size);
    if (nqd_should_drop_stale_main_device_params(main_device, dest_base,
                                                 dest_row_bytes,
                                                 packet_dest_pixel_size)) {
        NQD_VLOG("NQDMetalBitblt: dropped stale MainDevice params "
                 "(base=0x%08x bits_per_pixel=%u dst_rb=%d)",
                 dest_base, packet_dest_pixel_size, dest_row_bytes);
        return;
    }
    if (dest_packed_main_device_alias) {
        dest_row_bytes = (int32)main_device.rowBytes;
        NQD_VLOG("NQDMetalBitblt: redirected packed MainDevice dest alias "
                 "(packet_bits=%u live_bits=%u packet_rb=%d live_rb=%d)",
                 packet_dest_pixel_size, main_device.pixelSize,
                 packet_dest_row_bytes, dest_row_bytes);
    }
    src_pixel_size = nqd_effective_main_device_pixel_size(main_device,
                                                          src_base,
                                                          src_row_bytes,
                                                          src_pixel_size);
    dest_pixel_size = nqd_effective_main_device_pixel_size(main_device,
                                                           dest_base,
                                                           dest_row_bytes,
                                                           dest_pixel_size);
    if (src_pixel_size != packet_src_pixel_size) {
        bpp = nqd_bytes_per_pixel(src_pixel_size);
        if (src_pixel_size < 8) bpp = 1;
        width_bytes = nqd_packed_width_bytes(width, src_pixel_size);
        NQD_VLOG("NQDMetalBitblt: coerced redirected MainDevice source depth "
                 "packet=%u live=%u src_rb=%d",
                 packet_src_pixel_size, src_pixel_size, src_row_bytes);
    }
    if (dest_pixel_size != packet_dest_pixel_size) {
        NQD_VLOG("NQDMetalBitblt: coerced redirected MainDevice dest depth "
                 "packet=%u live=%u dst_rb=%d",
                 packet_dest_pixel_size, dest_pixel_size, dest_row_bytes);
    }
    if (nqd_should_use_cpu_mixed_depth_main_device_bitblt(main_device,
                                                          dest_base,
                                                          dest_row_bytes,
                                                          src_pixel_size,
                                                          dest_pixel_size,
                                                          transfer_mode)) {
        uint32_t fore_pen = ReadMacInt32(p + NQD_acclForePen);
        uint32_t back_pen = ReadMacInt32(p + NQD_acclBackPen);
        if (src_pixel_size == 1 &&
            nqd_cpu_bitblt_1bpp_to_direct_boolean(src_base, src_row_bytes,
                                                  dest_base, dest_row_bytes,
                                                  src_X, src_Y, dest_X, dest_Y,
                                                  width, height,
                                                  dest_pixel_size,
                                                  transfer_mode,
                                                  fore_pen, back_pen)) {
            NQD_VLOG("NQDMetalBitblt: used CPU mixed-depth MainDevice path "
                     "(base=0x%08x src_bits=%u dst_bits=%u dst_rb=%d mode=%u "
                     "fore=0x%08x back=0x%08x)",
                     dest_base, src_pixel_size, dest_pixel_size,
                     dest_row_bytes, transfer_mode, fore_pen, back_pen);
            return;
        }
    }
    if (src_pixel_size != dest_pixel_size &&
        main_device.valid && dest_base == main_device.baseAddr &&
        dest_row_bytes == (int32_t)main_device.rowBytes) {
        NQD_VLOG("NQDMetalBitblt: dropped unsupported mixed-depth MainDevice blit "
                 "(src_bits=%u dst_bits=%u mode=%u)",
                 src_pixel_size, dest_pixel_size, transfer_mode);
        return;
    }
    if (nqd_should_use_cpu_packed_main_device_path(main_device, dest_base, dest_row_bytes, src_pixel_size)) {
        uint32_t fore_pen = htonl(ReadMacInt32(p + NQD_acclForePen));
        uint32_t back_pen = htonl(ReadMacInt32(p + NQD_acclBackPen));
        if (nqd_cpu_bitblt_packed_boolean(src_base, src_row_bytes,
                                          dest_base, dest_row_bytes,
                                          src_X, src_Y, dest_X, dest_Y,
                                          width, height, src_pixel_size,
                                          transfer_mode, fore_pen, back_pen)) {
            NQD_VLOG("NQDMetalBitblt: used CPU packed MainDevice path "
                     "(base=0x%08x bits_per_pixel=%u dst_rb=%d mode=%u "
                     "fore=0x%08x back=0x%08x)",
                     dest_base, src_pixel_size, dest_row_bytes,
                     transfer_mode, fore_pen, back_pen);
            return;
        }
    }

    const bool bridge_gl_after_bitblt =
        nqd_should_bridge_gl_offscreen_after_bitblt(main_device,
                                                    src_base,
                                                    src_row_bytes,
                                                    src_pixel_size,
                                                    dest_base,
                                                    dest_row_bytes,
                                                    dest_pixel_size,
                                                    transfer_mode);

    // -----------------------------------------------------------------------
    // CPU fast path for small operations and simple modes
    //
    // For srcCopy (mode 0) on standard depths (>= 8bpp), memmove is faster
    // than any Metal path for small rects. For backward blits (negative
    // row_bytes), CPU is always preferred since Metal would need per-row
    // serialization or a temp buffer.
    //
    // All Boolean modes (0-7) get CPU fast paths for small rects — the
    // per-byte logic is trivial and doesn't benefit from GPU parallelism
    // at these sizes.
    // -----------------------------------------------------------------------

    int total_pixels = (int)width * (int)height;

    if (src_row_bytes < 0) {
        // Backward blit — always use CPU. Metal per-row dispatch was the
        // worst case: N command buffers for N rows. CPU memmove is trivial.
        NQDMetalFlush();  // ensure any pending GPU writes are visible to CPU
        int32 abs_src_rb = -src_row_bytes;
        int32 abs_dst_rb = -dest_row_bytes;
        uint8 *src_start = Mac2HostAddr(src_base) + ((src_Y + height - 1) * abs_src_rb) + nqd_packed_byte_offset(src_X, src_pixel_size);
        uint8 *dst_start = Mac2HostAddr(dest_base) + ((dest_Y + height - 1) * abs_dst_rb) + nqd_packed_byte_offset(dest_X, src_pixel_size);
        for (int row = height - 1; row >= 0; row--) {
            memmove(dst_start, src_start, width_bytes);
            src_start -= abs_src_rb;
            dst_start -= abs_dst_rb;
        }
        if (bridge_gl_after_bitblt) {
            nqd_bridge_gl_offscreen_after_bitblt(dest_base,
                                                 dest_row_bytes,
                                                 dest_pixel_size,
                                                 dest_X,
                                                 dest_Y,
                                                 width,
                                                 height);
        }
        return;
    }

    if (transfer_mode <= 7 && src_pixel_size >= 8 && total_pixels < NQD_CPU_THRESHOLD_PIXELS) {
        // Boolean bitblt modes, small rect, standard depth — CPU is faster.
        NQDMetalFlush();  // ensure any pending GPU writes are visible to CPU
        uint8 *src_ptr = Mac2HostAddr(src_base) + (src_Y * src_row_bytes) + (src_X * bpp);
        uint8 *dst_ptr = Mac2HostAddr(dest_base) + (dest_Y * dest_row_bytes) + (dest_X * bpp);
        int op_bytes = width * bpp;
        if (transfer_mode == 0) {
            // srcCopy — plain memmove
            for (int row = 0; row < height; row++) {
                memmove(dst_ptr, src_ptr, op_bytes);
                src_ptr += src_row_bytes;
                dst_ptr += dest_row_bytes;
            }
        } else {
            // Modes 1-7: per-byte Boolean ops
            for (int row = 0; row < height; row++) {
                for (int b = 0; b < op_bytes; b++) {
                    uint8_t s = src_ptr[b];
                    uint8_t d = dst_ptr[b];
                    switch (transfer_mode) {
                        case 1: dst_ptr[b] = s | d;      break; // srcOr
                        case 2: dst_ptr[b] = s ^ d;      break; // srcXor
                        case 3: dst_ptr[b] = (~s) & d;   break; // srcBic
                        case 4: dst_ptr[b] = ~s;          break; // notSrcCopy
                        case 5: dst_ptr[b] = (~s) | d;   break; // notSrcOr
                        case 6: dst_ptr[b] = (~s) ^ d;   break; // notSrcXor
                        case 7: dst_ptr[b] = s & d;       break; // notSrcBic
                    }
                }
                src_ptr += src_row_bytes;
                dst_ptr += dest_row_bytes;
            }
        }
        if (bridge_gl_after_bitblt) {
            nqd_bridge_gl_offscreen_after_bitblt(dest_base,
                                                 dest_row_bytes,
                                                 dest_pixel_size,
                                                 dest_X,
                                                 dest_Y,
                                                 width,
                                                 height);
        }
        return;
    }

    // -----------------------------------------------------------------------
    // Metal batched path — forward blit, single dispatch covering all rows
    // -----------------------------------------------------------------------

    uint32_t fore_pen = htonl(ReadMacInt32(p + NQD_acclForePen));
    uint32_t back_pen = htonl(ReadMacInt32(p + NQD_acclBackPen));
    uint32_t hilite_color = (transfer_mode == 50) ? nqd_pack_hilite_color(bpp) : 0;
    bool pixel_mode = nqd_is_pixel_mode(transfer_mode);

    uint8 *ram_base = nqd_ram_base;
    uint8 *src_ptr = Mac2HostAddr(src_base) + (src_Y * src_row_bytes) + nqd_packed_byte_offset(src_X, src_pixel_size);
    uint8 *dst_ptr = Mac2HostAddr(dest_base) + (dest_Y * dest_row_bytes) + nqd_packed_byte_offset(dest_X, src_pixel_size);

    NQDBitbltUniforms uniforms;
    uniforms.src_offset    = (uint32_t)(src_ptr - ram_base);
    uniforms.dst_offset    = (uint32_t)(dst_ptr - ram_base);
    uniforms.src_row_bytes = src_row_bytes;
    uniforms.dst_row_bytes = dest_row_bytes;
    uniforms.width_bytes   = width_bytes;
    uniforms.height        = (uint32_t)height;
    uniforms.transfer_mode = transfer_mode;
    uniforms.pixel_size    = (uint32_t)bpp;
    uniforms.width_pixels  = width_pixels;
    uniforms.fore_pen      = fore_pen;
    uniforms.back_pen      = back_pen;
    uniforms.hilite_color  = hilite_color;
    uniforms.mask_enabled  = 0;
    uniforms.mask_offset   = 0;
    uniforms.mask_stride   = 0;
    uniforms.bits_per_pixel = src_pixel_size;
    {   // Per-channel rgbOpColor blend weights for mode 32.
        // The GrafVars walk (a 5-step guest-controlled Mac-VM read) is
        // consumed ONLY by blend mode 32, so gate it on the mode — for every
        // other transfer mode the weights are dead. This narrows the
        // guest-controlled OOB-read attack surface to blend dispatches and skips
        // the per-op lowmem traffic. Mode-32 behaviour is byte-identical.
        NQDRgbOpColor _op = (transfer_mode == 32) ? nqd_read_rgb_op_color()
                                                  : NQDRgbOpColor{0, 0, 0};
        uniforms.blend_weight_r = _op.r;
        uniforms.blend_weight_g = _op.g;
        uniforms.blend_weight_b = _op.b;
    }

    NSUInteger total_threads = (pixel_mode && src_pixel_size >= 8)
        ? (NSUInteger)(width_pixels * height)
        : (NSUInteger)(width_bytes * height);

    id<MTLComputeCommandEncoder> encoder = nqd_get_batch_encoder();
    if (!encoder) return;

    [encoder setComputePipelineState:nqd_bitblt_pipeline];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:0];
    [encoder setBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:2];  // dummy mask buffer (mask_enabled=0)

    NSUInteger threadgroup_size = nqd_bitblt_pipeline.maxTotalThreadsPerThreadgroup;
    if (threadgroup_size > 256) threadgroup_size = 256;
    if (threadgroup_size > total_threads) threadgroup_size = total_threads;

    MTLSize grid = MTLSizeMake(total_threads, 1, 1);
    MTLSize group = MTLSizeMake(threadgroup_size, 1, 1);
    [encoder dispatchThreads:grid threadsPerThreadgroup:group];

    nqd_batch_did_dispatch();
    if (bridge_gl_after_bitblt) {
        NQDMetalFlush();
        nqd_bridge_gl_offscreen_after_bitblt(dest_base,
                                             dest_row_bytes,
                                             dest_pixel_size,
                                             dest_X,
                                             dest_Y,
                                             width,
                                             height);
    }
}

// ---------------------------------------------------------------------------
// NQDMetalBitblt1to1 — 1:1 bitblt via Metal compute (DSpBlit_Fastest)
//
// DSpBlit_Fastest (sub-op 711) is a strict 1:1
// copy (srcRect == dstRect, no scaling). It REUSES the proven nqd_bitblt kernel
// (UNCHANGED) by filling NQDBitbltUniforms directly from the DSp blit handler's
// resolved geometry + a CGrafPtr->RAM-offset shim (the same Mac2HostAddr-
// relative subtraction NQDMetalBitblt uses). transfer_mode is
// srcCopy (0) by default, or transparent (36) when SrcKey is set (the existing
// kernel's mode-36 "skip if src == back_pen" branch with back_pen = src_key).
// Encodes into the EXISTING NQD batch on the single shared MTLCommandQueue.
// Returns false on unavailable Metal / degenerate geometry /
// OOB baseAddr (caller maps false -> kDSpInternalErr).
// ---------------------------------------------------------------------------

bool NQDMetalBitblt1to1(uint32 src_base, int32 src_row_bytes,
                        uint32 dst_base, int32 dst_row_bytes,
                        uint32 pixel_size_bytes, uint32 bits_per_pixel,
                        uint32 width_pixels, uint32 height,
                        uint32 transfer_mode, uint32 src_key)
{
    if (!nqd_metal_available) return false;
    if (width_pixels == 0 || height == 0) return false;
    if (pixel_size_bytes != 1 && pixel_size_bytes != 2 && pixel_size_bytes != 4) return false;
    if (!nqd_addr_in_buffer(src_base) || !nqd_addr_in_buffer(dst_base)) return false;

    uint8 *ram_base = nqd_ram_base;
    uint8 *src_ptr  = Mac2HostAddr(src_base);
    uint8 *dst_ptr  = Mac2HostAddr(dst_base);

    // The rect-origin check above bounds ONLY the first byte. Validate
    // the full blit EXTENT against nqd_ram_size before dispatch so a guest
    // cannot drive the kernel to stride dy*row_bytes past the mapped RAM
    // MTLBuffer (OOB GPU read/write). Compute the worst-case last byte each
    // side addresses in 64-bit UNSIGNED arithmetic (so the overflow that would
    // itself defeat the check cannot occur), using abs(row_bytes)
    // (a negative stride must still be range-checked at its magnitude).
    // src/dst last byte = (h-1)*|row_bytes| + (w-1)*bpp + (bpp-1) == h*|rb| ...
    // we use the conservative upper bound h*|rb| + w*bpp which is >= the true
    // extent (reject OOB extent BEFORE GPU dispatch).
    uint64_t src_rb  = (uint64_t)(src_row_bytes < 0 ? -(int64_t)src_row_bytes : (int64_t)src_row_bytes);
    uint64_t dst_rb  = (uint64_t)(dst_row_bytes < 0 ? -(int64_t)dst_row_bytes : (int64_t)dst_row_bytes);
    uint64_t span    = (uint64_t)height * src_rb + (uint64_t)width_pixels * pixel_size_bytes;
    uint64_t dst_span = (uint64_t)height * dst_rb + (uint64_t)width_pixels * pixel_size_bytes;
    uint32_t src_off = (uint32_t)(src_ptr - ram_base);
    uint32_t dst_off = (uint32_t)(dst_ptr - ram_base);
    if (span     > nqd_ram_size || src_off > nqd_ram_size - span)     return false;
    if (dst_span > nqd_ram_size || dst_off > nqd_ram_size - dst_span) return false;

    NQDBitbltUniforms uniforms;
    uniforms.src_offset     = (uint32_t)(src_ptr - ram_base);   // Mac2HostAddr-relative
    uniforms.dst_offset     = (uint32_t)(dst_ptr - ram_base);
    uniforms.src_row_bytes  = src_row_bytes;
    uniforms.dst_row_bytes  = dst_row_bytes;
    uniforms.width_bytes    = width_pixels * pixel_size_bytes;
    uniforms.height         = height;
    uniforms.transfer_mode  = transfer_mode;          // 0 srcCopy, or 36 transparent (SrcKey)
    uniforms.pixel_size     = pixel_size_bytes;
    uniforms.width_pixels   = width_pixels;
    uniforms.fore_pen       = 0;
    uniforms.back_pen       = src_key;                // mode-36 transparent key
    uniforms.hilite_color   = 0;
    uniforms.mask_enabled   = 0;
    uniforms.mask_offset    = 0;
    uniforms.mask_stride    = 0;
    uniforms.bits_per_pixel = bits_per_pixel;
    // Non-blend path — zero all 3 rgbOpColor channels.
    uniforms.blend_weight_r = 0;
    uniforms.blend_weight_g = 0;
    uniforms.blend_weight_b = 0;

    // mode 36 (transparent) dispatches per-pixel for standard depths;
    // srcCopy (0) dispatches per-byte. Mirror NQDMetalBitblt's choice.
    bool pixel_mode = (transfer_mode == 36) && (bits_per_pixel >= 8);
    NSUInteger total_threads = pixel_mode
        ? (NSUInteger)width_pixels * (NSUInteger)height
        : (NSUInteger)uniforms.width_bytes * (NSUInteger)height;

    id<MTLComputeCommandEncoder> encoder = nqd_get_batch_encoder();
    if (!encoder) return false;

    [encoder setComputePipelineState:nqd_bitblt_pipeline];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:0];
    [encoder setBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:2];  // dummy mask (mask_enabled=0)

    NSUInteger threadgroup_size = nqd_bitblt_pipeline.maxTotalThreadsPerThreadgroup;
    if (threadgroup_size > 256) threadgroup_size = 256;
    if (threadgroup_size > total_threads) threadgroup_size = total_threads;
    if (threadgroup_size == 0) threadgroup_size = 1;

    MTLSize grid  = MTLSizeMake(total_threads, 1, 1);
    MTLSize group = MTLSizeMake(threadgroup_size, 1, 1);
    [encoder dispatchThreads:grid threadsPerThreadgroup:group];

    nqd_batch_did_dispatch();
    return true;
}

// ---------------------------------------------------------------------------
// NQDMetalBitbltScaled — scaling bitblt via Metal compute (DSpBlit_Faster)
//
// The DSp blit handler reads the DSpBlitInfo,
// resolves the src/dst CGrafPtr baseAddr to Mac addresses + row bytes + rects,
// then calls this entry. We compute the Mac2HostAddr-relative byte offset of
// each rect origin (NEVER a raw (uint32)(uintptr_t) cast — arm64 >4GiB UB
// on the arm64 simulator), fill NQDBitbltScaledUniforms, and encode into the
// EXISTING NQD batch on the SINGLE shared MTLCommandQueue (no
// DSp-specific path, no new concurrency primitive). One thread per dst pixel.
//
// src_base / dst_base : Mac (guest) addresses of the src/dst rect origins'
//                       PIXMAP baseAddr (NOT the rect origin — caller folds in
//                       the rect top/left when passing src_base/dst_base).
// Returns true if the dispatch was encoded; false if Metal is unavailable, the
// geometry is degenerate, or an offset would fall outside the mapped RAM
// buffer (the caller maps false -> kDSpInternalErr).
// ---------------------------------------------------------------------------

bool NQDMetalBitbltScaled(uint32 src_base, int32 src_row_bytes,
                          uint32 dst_base, int32 dst_row_bytes,
                          uint32 pixel_size_bytes, uint32 bits_per_pixel,
                          uint32 src_w, uint32 src_h,
                          uint32 dst_w, uint32 dst_h,
                          uint32 interpolate,
                          uint32 src_key, uint32 dst_key,
                          uint32 key_enable)
{
    if (!nqd_metal_available) return false;
    if (src_w == 0 || src_h == 0 || dst_w == 0 || dst_h == 0) return false;
    if (pixel_size_bytes != 1 && pixel_size_bytes != 2 && pixel_size_bytes != 4) return false;

    // Both rect origins must lie inside the Metal-mapped RAM buffer
    // (T-22.5.3-02-01 — reject OOB baseAddr BEFORE GPU dispatch).
    if (!nqd_addr_in_buffer(src_base) || !nqd_addr_in_buffer(dst_base)) return false;

    uint8 *ram_base = nqd_ram_base;
    uint8 *src_ptr  = Mac2HostAddr(src_base);
    uint8 *dst_ptr  = Mac2HostAddr(dst_base);

    // The rect-origin check bounds ONLY the first byte. Validate the
    // full blit EXTENT of BOTH sides against nqd_ram_size before dispatch.
    // The src side is read at scaled coordinates; the bilinear path also reads
    // the +1 neighbor row/col (sx1/sy1), so the conservative src extent adds an
    // extra row+col. All arithmetic is 64-bit UNSIGNED so the overflow that
    // would defeat the check cannot occur, and uses abs(row_bytes).
    uint64_t src_rb  = (uint64_t)(src_row_bytes < 0 ? -(int64_t)src_row_bytes : (int64_t)src_row_bytes);
    uint64_t dst_rb  = (uint64_t)(dst_row_bytes < 0 ? -(int64_t)dst_row_bytes : (int64_t)dst_row_bytes);
    // src worst case: bilinear may touch row sy1 (<= src_h) and col sx1 (<= src_w),
    // so bound by (src_h+1)*|src_rb| + (src_w+1)*bpp.
    uint64_t src_span = (uint64_t)(src_h + 1u) * src_rb + (uint64_t)(src_w + 1u) * pixel_size_bytes;
    uint64_t dst_span = (uint64_t)dst_h * dst_rb + (uint64_t)dst_w * pixel_size_bytes;
    uint32_t src_off  = (uint32_t)(src_ptr - ram_base);
    uint32_t dst_off  = (uint32_t)(dst_ptr - ram_base);
    if (src_span > nqd_ram_size || src_off > nqd_ram_size - src_span) return false;
    if (dst_span > nqd_ram_size || dst_off > nqd_ram_size - dst_span) return false;

    NQDBitbltScaledUniforms uniforms;
    uniforms.src_offset     = (uint32_t)(src_ptr - ram_base);   // Mac2HostAddr-relative
    uniforms.dst_offset     = (uint32_t)(dst_ptr - ram_base);
    uniforms.src_row_bytes  = src_row_bytes;
    uniforms.dst_row_bytes  = dst_row_bytes;
    uniforms.pixel_size     = pixel_size_bytes;
    uniforms.bits_per_pixel = bits_per_pixel;
    uniforms.src_w          = src_w;
    uniforms.src_h          = src_h;
    uniforms.dst_w          = dst_w;
    uniforms.dst_h          = dst_h;
    uniforms.interpolate    = interpolate ? 1u : 0u;
    uniforms.src_key        = src_key;
    uniforms.dst_key        = dst_key;
    uniforms.key_enable     = key_enable;
    uniforms.ram_size       = nqd_ram_size;   // per-pixel clamp ceiling

    NSUInteger total_threads = (NSUInteger)dst_w * (NSUInteger)dst_h;

    id<MTLComputeCommandEncoder> encoder = nqd_get_batch_encoder();
    if (!encoder) return false;

    [encoder setComputePipelineState:nqd_bitblt_scaled_pipeline];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:0];
    [encoder setBytes:&uniforms length:sizeof(uniforms) atIndex:1];

    NSUInteger threadgroup_size = nqd_bitblt_scaled_pipeline.maxTotalThreadsPerThreadgroup;
    if (threadgroup_size > 256) threadgroup_size = 256;
    if (threadgroup_size > total_threads) threadgroup_size = total_threads;
    if (threadgroup_size == 0) threadgroup_size = 1;

    MTLSize grid  = MTLSizeMake(total_threads, 1, 1);
    MTLSize group = MTLSizeMake(threadgroup_size, 1, 1);
    [encoder dispatchThreads:grid threadsPerThreadgroup:group];

    nqd_batch_did_dispatch();
    return true;
}

// ---------------------------------------------------------------------------
// NQDMetalFillRect — fill rect via Metal compute (all pen modes)
//
// Reads accl_params from Mac memory at address p. Dispatches the nqd_fillrect
// compute kernel. For Boolean modes (8-15), dispatches per-byte threads.
// For arithmetic modes (32-39) and hilite (50), dispatches per-pixel threads.
// ---------------------------------------------------------------------------

#ifdef TESTING_BUILD
// ---------------------------------------------------------------------------
// NQDMetalFillRect_WithHost — test-only entry that reads accl_params via
// the host pointer instead of the Mac-address ABI.
//
// Rationale: under EMULATED_PPC=0 on iOS
// simulator, RAMBaseHost lives above 4 GiB, so ReadMacInt*(mac_addr)
// (which under EMULATED_PPC=0 is literally *(uint16 *)(uintptr_t)mac_addr)
// data-faults.  Production builds use EMULATED_PPC=1 with a vm_read
// translation layer and are unaffected.  This helper accepts a
// host-side pointer to the accl_params struct and resolves the
// dest_base Mac address to a host pointer via RAMBase/RAMBaseHost
// arithmetic.  It dispatches to the same Metal fillrect pipeline the
// production path uses, so the test exercises the real kernel.
//
// Declared extern "C" for linker-symbol parity with the other
// NQDTesting_* hooks.
// ---------------------------------------------------------------------------

extern "C" void NQDMetalFillRect_WithHost(void *accl_params_host)
{
    if (!nqd_metal_available) return;
    if (!accl_params_host) return;

    const uint8_t *ph = (const uint8_t *)accl_params_host;

    // Raw host-side reads — accl_params was written by PSFakeMacRAM in
    // host-native byte order (little-endian on arm64 iOS simulator),
    // matching the EMULATED_PPC=0 ReadMacInt* pointer-cast semantics.
    auto r16 = [](const uint8_t *b, size_t o) -> int16 { return (int16)(*(const uint16_t *)(b + o)); };
    auto r32 = [](const uint8_t *b, size_t o) -> uint32 { return *(const uint32_t *)(b + o); };

    int16 dest_X = r16(ph, NQD_acclDestRect + 2) - r16(ph, NQD_acclDestBoundsRect + 2);
    int16 dest_Y = r16(ph, NQD_acclDestRect + 0) - r16(ph, NQD_acclDestBoundsRect + 0);
    int16 width  = r16(ph, NQD_acclDestRect + 6) - r16(ph, NQD_acclDestRect + 2);
    int16 height = r16(ph, NQD_acclDestRect + 4) - r16(ph, NQD_acclDestRect + 0);

    if (width <= 0 || height <= 0) return;

    uint32 pixel_size = r32(ph, NQD_acclDestPixelSize);
    int bpp = nqd_bytes_per_pixel(pixel_size);
    if (pixel_size < 8) bpp = 1;
    int32 dest_row_bytes = (int32)r32(ph, NQD_acclDestRowBytes);
    uint32 dest_base = r32(ph, NQD_acclDestBaseAddr);

    uint32_t transfer_mode = r32(ph, NQD_acclTransferMode);
    uint32_t pen_mode      = r32(ph, NQD_acclPenMode);

    // Only Metal path is supported in testing — the CPU fast path
    // (transfer_mode 8-15, total < 4096 px) dereferences Mac2HostAddr
    // which the caller has already sidestepped by setting
    // transfer_mode=0 via PSFakeMacRAM_WriteAcclParamsFillRect.
    uint32_t fore_pen        = htonl(r32(ph, NQD_acclForePen));
    uint32_t back_pen        = htonl(r32(ph, NQD_acclBackPen));
    uint32_t fore_pen_native = r32(ph, NQD_acclForePen);
    uint32_t back_pen_native = r32(ph, NQD_acclBackPen);
    uint32_t fill_color      = (pen_mode == 8) ? fore_pen_native : back_pen_native;

    uint32 width_bytes  = nqd_packed_width_bytes(width, pixel_size);
    uint32 width_pixels = (uint32)width;

    bool pixel_mode = nqd_is_pixel_mode(transfer_mode);

    // Resolve dest host pointer via RAMBase/RAMBaseHost arithmetic
    // (32-bit-ABI-safe even when RAMBaseHost is above 4 GiB).
    if (dest_base < RAMBase || dest_base - RAMBase >= nqd_ram_size) {
        NQD_ERR("NQDMetalFillRect_WithHost: dest_base 0x%08x out of mapped RAM [0x%08x..0x%08x]",
                dest_base, RAMBase, RAMBase + nqd_ram_size);
        return;
    }
    uint32_t dst_offset = (dest_base - RAMBase)
                        + (uint32_t)(dest_Y * dest_row_bytes)
                        + nqd_packed_byte_offset(dest_X, pixel_size);

    NQDFillRectUniforms uniforms;
    uniforms.dst_offset    = dst_offset;
    uniforms.row_bytes     = dest_row_bytes;
    uniforms.width_bytes   = width_bytes;
    uniforms.height        = (uint32_t)height;
    uniforms.fill_color    = fill_color;
    uniforms.bpp           = (uint32_t)bpp;
    uniforms.transfer_mode = transfer_mode;
    uniforms.pixel_size    = (uint32_t)bpp;
    uniforms.width_pixels  = width_pixels;
    uniforms.fore_pen      = fore_pen;
    uniforms.back_pen      = back_pen;
    // Mirror the production NQDMetalFillRect path: mode 50 (hilite) must pack
    // the HiliteRGB to pixel depth so the kernel's one-directional replace
    // writes the real highlight colour. The prior hardcoded 0
    // meant this test-only host entry could never exercise mode 50 faithfully.
    // Safe under EMULATED_PPC=0 because nqd_pack_hilite_color()'s lowmem read
    // routes through the NQDTesting_SetHiliteOverride seam in the test build.
    uniforms.hilite_color  = (transfer_mode == 50) ? nqd_pack_hilite_color(bpp) : 0;
    uniforms.mask_enabled  = 0;
    uniforms.mask_offset   = 0;
    uniforms.mask_stride   = 0;
    uniforms.bits_per_pixel = pixel_size;
    // Non-blend path — zero all 3 rgbOpColor channels.
    uniforms.blend_weight_r = 0;
    uniforms.blend_weight_g = 0;
    uniforms.blend_weight_b = 0;

    NSUInteger total_threads = (pixel_mode && pixel_size >= 8)
        ? (NSUInteger)(width_pixels * height)
        : (NSUInteger)(width_bytes * height);

    id<MTLComputeCommandEncoder> encoder = nqd_get_batch_encoder();
    if (!encoder) return;

    [encoder setComputePipelineState:nqd_fillrect_pipeline];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:0];
    [encoder setBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:2];  // dummy mask buffer

    NSUInteger threadgroup_size = nqd_fillrect_pipeline.maxTotalThreadsPerThreadgroup;
    if (threadgroup_size > 256) threadgroup_size = 256;
    if (threadgroup_size > total_threads) threadgroup_size = total_threads;

    MTLSize grid  = MTLSizeMake(total_threads, 1, 1);
    MTLSize group = MTLSizeMake(threadgroup_size, 1, 1);
    [encoder dispatchThreads:grid threadsPerThreadgroup:group];

    nqd_batch_did_dispatch();
}

// ---------------------------------------------------------------------------
// NQDMetalBitblt_WithHost — test-only entry that reads accl_params via
// the host pointer instead of the Mac-address ABI.
//
// Rationale: under EMULATED_PPC=0 on iOS simulator,
// RAMBaseHost lives above 4 GiB, so ReadMacInt*(mac_addr) data-faults.
// The production NQDMetalBitblt reads accl_params via ReadMacInt16/32;
// this helper accepts a host-side pointer and resolves both src_base
// and dest_base Mac addresses to host pointers via RAMBase arithmetic.
// It dispatches to the same production nqd_bitblt Metal compute kernel.
//
// Unlike the production path, this ALWAYS takes the Metal path (never
// the CPU fast-path) — tests want to validate the GPU kernel.
//
// Declared extern "C" for linker-symbol parity with the other
// NQDTesting_* hooks.
// ---------------------------------------------------------------------------

extern "C" void NQDMetalBitblt_WithHost(void *accl_params_host)
{
    if (!nqd_metal_available) return;
    if (!accl_params_host) return;

    const uint8_t *ph = (const uint8_t *)accl_params_host;

    // Raw host-side reads — accl_params was written by PSFakeMacRAM in
    // host-native byte order (little-endian on arm64 iOS simulator),
    // matching the EMULATED_PPC=0 ReadMacInt* pointer-cast semantics.
    auto r16 = [](const uint8_t *b, size_t o) -> int16 { return (int16)(*(const uint16_t *)(b + o)); };
    auto r32 = [](const uint8_t *b, size_t o) -> uint32 { return *(const uint32_t *)(b + o); };

    // Extract parameters — mirrors production NQDMetalBitblt (line 950-974)
    int16 src_X  = r16(ph, NQD_acclSrcRect + 2) - r16(ph, NQD_acclSrcBoundsRect + 2);
    int16 src_Y  = r16(ph, NQD_acclSrcRect + 0) - r16(ph, NQD_acclSrcBoundsRect + 0);
    int16 dest_X = r16(ph, NQD_acclDestRect + 2) - r16(ph, NQD_acclDestBoundsRect + 2);
    int16 dest_Y = r16(ph, NQD_acclDestRect + 0) - r16(ph, NQD_acclDestBoundsRect + 0);
    int16 width  = r16(ph, NQD_acclDestRect + 6) - r16(ph, NQD_acclDestRect + 2);
    int16 height = r16(ph, NQD_acclDestRect + 4) - r16(ph, NQD_acclDestRect + 0);

    if (width <= 0 || height <= 0) return;

    uint32 src_pixel_size = r32(ph, NQD_acclSrcPixelSize);
    int bpp = nqd_bytes_per_pixel(src_pixel_size);
    if (src_pixel_size < 8) bpp = 1;  // packed depths: byte-level ops
    uint32 width_bytes  = nqd_packed_width_bytes(width, src_pixel_size);
    uint32 width_pixels = (uint32)width;

    uint32 src_base      = r32(ph, NQD_acclSrcBaseAddr);
    uint32 dest_base     = r32(ph, NQD_acclDestBaseAddr);
    int32 src_row_bytes  = (int32)r32(ph, NQD_acclSrcRowBytes);
    int32 dest_row_bytes = (int32)r32(ph, NQD_acclDestRowBytes);

    uint32_t transfer_mode = r32(ph, NQD_acclTransferMode);
    uint32_t fore_pen      = htonl(r32(ph, NQD_acclForePen));
    uint32_t back_pen      = htonl(r32(ph, NQD_acclBackPen));
    // Mirror the production NQDMetalBitblt path: mode 50 (hilite) must pack the
    // HiliteRGB to pixel depth so the kernel sees the real highlight colour.
    // Safe under EMULATED_PPC=0 because nqd_pack_hilite_color()'s raw lowmem
    // read (0x0DA0) routes through the NQDTesting_SetHiliteOverride seam in the
    // test build — the override SHORT-CIRCUITS the data-faulting deref. The
    // 1-bit Table 4-2 srcXor revert drives mode 50 at 1bpp through
    // this entry, so the override is required to exercise it without a fault.
    // The prior hardcoded 0 meant this host entry could never
    // reach mode 50 faithfully.
    uint32_t hilite_color  = (transfer_mode == 50) ? nqd_pack_hilite_color(bpp) : 0;
    bool pixel_mode        = nqd_is_pixel_mode(transfer_mode);

    // Resolve src_base and dest_base via RAMBase arithmetic
    // (32-bit-ABI-safe even when RAMBaseHost is above 4 GiB).
    if (src_base < RAMBase || src_base - RAMBase >= nqd_ram_size) {
        NQD_ERR("NQDMetalBitblt_WithHost: src_base 0x%08x out of mapped RAM [0x%08x..0x%08x]",
                src_base, RAMBase, RAMBase + nqd_ram_size);
        return;
    }
    if (dest_base < RAMBase || dest_base - RAMBase >= nqd_ram_size) {
        NQD_ERR("NQDMetalBitblt_WithHost: dest_base 0x%08x out of mapped RAM [0x%08x..0x%08x]",
                dest_base, RAMBase, RAMBase + nqd_ram_size);
        return;
    }

    uint32_t src_offset = (src_base - RAMBase)
                        + (uint32_t)(src_Y * src_row_bytes)
                        + nqd_packed_byte_offset(src_X, src_pixel_size);
    uint32_t dst_offset = (dest_base - RAMBase)
                        + (uint32_t)(dest_Y * dest_row_bytes)
                        + nqd_packed_byte_offset(dest_X, src_pixel_size);

    NQDBitbltUniforms uniforms;
    uniforms.src_offset     = src_offset;
    uniforms.dst_offset     = dst_offset;
    uniforms.src_row_bytes  = src_row_bytes;
    uniforms.dst_row_bytes  = dest_row_bytes;
    uniforms.width_bytes    = width_bytes;
    uniforms.height         = (uint32_t)height;
    uniforms.transfer_mode  = transfer_mode;
    uniforms.pixel_size     = (uint32_t)bpp;
    uniforms.width_pixels   = width_pixels;
    uniforms.fore_pen       = fore_pen;
    uniforms.back_pen       = back_pen;
    uniforms.hilite_color   = hilite_color;
    uniforms.mask_enabled   = 0;
    uniforms.mask_offset    = 0;
    uniforms.mask_stride    = 0;
    uniforms.bits_per_pixel = src_pixel_size;
    {   // Per-channel rgbOpColor blend weights for mode 32.
        // Mirrors the production NQDMetalBitblt call-site. Under EMULATED_PPC=0
        // the lowmem reads route through the TESTING_BUILD seam
        // (NQDTesting_SetLowmemOverride), so blend mode 32 IS now testable via
        // _WithHost — the pixel gate relies on this.
        // Gate the walk on blend mode 32 (its only consumer), matching
        // the production call-sites — narrows the guest-controlled OOB-read
        // surface and skips the walk on non-blend dispatches.
        NQDRgbOpColor _op = (transfer_mode == 32) ? nqd_read_rgb_op_color()
                                                  : NQDRgbOpColor{0, 0, 0};
        uniforms.blend_weight_r = _op.r;
        uniforms.blend_weight_g = _op.g;
        uniforms.blend_weight_b = _op.b;
    }

    NSUInteger total_threads = (pixel_mode && src_pixel_size >= 8)
        ? (NSUInteger)(width_pixels * height)
        : (NSUInteger)(width_bytes * height);

    id<MTLComputeCommandEncoder> encoder = nqd_get_batch_encoder();
    if (!encoder) return;

    [encoder setComputePipelineState:nqd_bitblt_pipeline];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:0];
    [encoder setBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:2];  // dummy mask buffer (mask_enabled=0)

    NSUInteger threadgroup_size = nqd_bitblt_pipeline.maxTotalThreadsPerThreadgroup;
    if (threadgroup_size > 256) threadgroup_size = 256;
    if (threadgroup_size > total_threads) threadgroup_size = total_threads;

    MTLSize grid  = MTLSizeMake(total_threads, 1, 1);
    MTLSize group = MTLSizeMake(threadgroup_size, 1, 1);
    [encoder dispatchThreads:grid threadsPerThreadgroup:group];

    nqd_batch_did_dispatch();
}
#endif /* TESTING_BUILD */

void NQDMetalFillRect(uint32 p)
{
    if (!nqd_metal_available) return;

    // Extract parameters from accl_params
    int16 dest_X = (int16)ReadMacInt16(p + NQD_acclDestRect + 2) - (int16)ReadMacInt16(p + NQD_acclDestBoundsRect + 2);
    int16 dest_Y = (int16)ReadMacInt16(p + NQD_acclDestRect + 0) - (int16)ReadMacInt16(p + NQD_acclDestBoundsRect + 0);
    int16 width  = (int16)ReadMacInt16(p + NQD_acclDestRect + 6) - (int16)ReadMacInt16(p + NQD_acclDestRect + 2);
    int16 height = (int16)ReadMacInt16(p + NQD_acclDestRect + 4) - (int16)ReadMacInt16(p + NQD_acclDestRect + 0);

    if (width <= 0 || height <= 0) return;

    uint32 pixel_size = ReadMacInt32(p + NQD_acclDestPixelSize);
    int bpp = nqd_bytes_per_pixel(pixel_size);
    if (pixel_size < 8) bpp = 1;  // packed depths: byte-level ops
    int32 dest_row_bytes = (int32)ReadMacInt32(p + NQD_acclDestRowBytes);
    uint32 dest_base = ReadMacInt32(p + NQD_acclDestBaseAddr);

    // Read transfer mode and pen colors
    uint32_t transfer_mode = ReadMacInt32(p + NQD_acclTransferMode);
    uint32_t pen_mode = ReadMacInt32(p + NQD_acclPenMode);

    NQD_VLOG("NQDMetalFillRect: dst=(%d,%d) %dx%d bpp=%d bits_per_pixel=%u transfer_mode=%d mode=%d base=0x%08x rb=%d",
             dest_X, dest_Y, width, height, bpp, pixel_size, transfer_mode,
             pen_mode, dest_base, dest_row_bytes);

    NQDMainDevicePixMapSnapshot main_device = nqd_read_main_device_pixmap_snapshot();
    uint32_t packet_pixel_size = pixel_size;
    int32 packet_dest_row_bytes = dest_row_bytes;
    bool dest_packed_main_device_alias =
        nqd_is_packed_main_device_alias(main_device, dest_base,
                                        dest_row_bytes,
                                        packet_pixel_size);
    if (nqd_should_drop_stale_main_device_params(main_device, dest_base, dest_row_bytes, packet_pixel_size)) {
        NQD_VLOG("NQDMetalFillRect: dropped stale MainDevice params "
                 "(base=0x%08x bits_per_pixel=%u rb=%d)",
                 dest_base, packet_pixel_size, dest_row_bytes);
        return;
    }
    if (dest_packed_main_device_alias) {
        dest_row_bytes = (int32)main_device.rowBytes;
        NQD_VLOG("NQDMetalFillRect: redirected packed MainDevice dest alias "
                 "(packet_bits=%u live_bits=%u packet_rb=%d live_rb=%d)",
                 packet_pixel_size, main_device.pixelSize,
                 packet_dest_row_bytes, dest_row_bytes);
    }
    pixel_size = nqd_effective_main_device_pixel_size(main_device, dest_base,
                                                      dest_row_bytes, pixel_size);
    if (pixel_size != packet_pixel_size) {
        bpp = nqd_bytes_per_pixel(pixel_size);
        if (pixel_size < 8) bpp = 1;
        NQD_VLOG("NQDMetalFillRect: coerced redirected MainDevice depth "
                 "packet=%u live=%u rb=%d",
                 packet_pixel_size, pixel_size, dest_row_bytes);
    }
    if (nqd_should_use_cpu_packed_main_device_path(main_device, dest_base, dest_row_bytes, pixel_size)) {
        uint32_t fill_color = NQDPackedFillNativeColor(
            ReadMacInt32(p + NQD_acclForePen),
            ReadMacInt32(p + NQD_acclBackPen),
            pen_mode);
        uint32_t fill_raster_op = NQDPackedFillRasterOp(transfer_mode, pen_mode);
        if (nqd_cpu_fillrect_packed_boolean(dest_base, dest_row_bytes,
                                            dest_X, dest_Y, width, height,
                                            pixel_size, fill_raster_op,
                                            fill_color)) {
            NQD_VLOG("NQDMetalFillRect: used CPU packed MainDevice path "
                     "(base=0x%08x bits_per_pixel=%u rb=%d mode=%u "
                     "pen_mode=%u raster_op=%u fill=0x%08x)",
                     dest_base, pixel_size, dest_row_bytes, transfer_mode,
                     pen_mode, fill_raster_op, fill_color);
            return;
        }
    }

    // -----------------------------------------------------------------------
    // CPU fast path for small Boolean fills on standard depths
    //
    // Boolean fill modes (8-15) do per-byte operations on a repeating fill
    // pattern. For small rects, a tight CPU loop is much faster than Metal.
    // -----------------------------------------------------------------------

    int total_pixels = (int)width * (int)height;

    if (transfer_mode >= 8 && transfer_mode <= 15 && pixel_size >= 8 && total_pixels < NQD_CPU_THRESHOLD_PIXELS) {
        NQDMetalFlush();  // ensure any pending GPU writes are visible to CPU
        uint32_t color = htonl((pen_mode == 8) ? ReadMacInt32(p + NQD_acclForePen) : ReadMacInt32(p + NQD_acclBackPen));
        uint8 *dst_ptr = Mac2HostAddr(dest_base) + (dest_Y * dest_row_bytes) + (dest_X * bpp);
        int fill_bytes = width * bpp;

        if (transfer_mode == 8) {
            // patCopy — just fill
            if (bpp == 1) {
                for (int row = 0; row < height; row++) {
                    memset(dst_ptr, (uint8_t)(color & 0xFF), fill_bytes);
                    dst_ptr += dest_row_bytes;
                }
            } else if (bpp == 2) {
                uint16_t c16 = (uint16_t)(color & 0xFFFF);
                for (int row = 0; row < height; row++) {
                    uint16_t *p16 = (uint16_t *)dst_ptr;
                    for (int col = 0; col < width; col++) p16[col] = c16;
                    dst_ptr += dest_row_bytes;
                }
            } else {
                for (int row = 0; row < height; row++) {
                    uint32_t *p32 = (uint32_t *)dst_ptr;
                    for (int col = 0; col < width; col++) p32[col] = color;
                    dst_ptr += dest_row_bytes;
                }
            }
        } else {
            // Modes 9-15: per-byte Boolean ops with fill pattern
            for (int row = 0; row < height; row++) {
                for (int b = 0; b < fill_bytes; b++) {
                    uint8_t byte_in_pixel = b % bpp;
                    uint8_t shift = (3 - ((4 - bpp) + byte_in_pixel)) * 8;
                    uint8_t fill = (uint8_t)((color >> shift) & 0xFF);
                    uint8_t d = dst_ptr[b];
                    switch (transfer_mode) {
                        case 9:  dst_ptr[b] = fill | d;      break; // patOr
                        case 10: dst_ptr[b] = fill ^ d;      break; // patXor
                        case 11: dst_ptr[b] = (~fill) & d;   break; // patBic
                        case 12: dst_ptr[b] = ~fill;          break; // notPatCopy
                        case 13: dst_ptr[b] = (~fill) | d;   break; // notPatOr
                        case 14: dst_ptr[b] = (~fill) ^ d;   break; // notPatXor
                        case 15: dst_ptr[b] = fill & d;       break; // notPatBic
                    }
                }
                dst_ptr += dest_row_bytes;
            }
        }
        return;
    }

    // -----------------------------------------------------------------------
    // Metal batched path
    // -----------------------------------------------------------------------

    uint32_t fore_pen = htonl(ReadMacInt32(p + NQD_acclForePen));
    uint32_t back_pen = htonl(ReadMacInt32(p + NQD_acclBackPen));
    uint32_t fore_pen_native = ReadMacInt32(p + NQD_acclForePen);
    uint32_t back_pen_native = ReadMacInt32(p + NQD_acclBackPen);
    uint32_t fill_color = (pen_mode == 8) ? fore_pen_native : back_pen_native;

    uint32 width_bytes = nqd_packed_width_bytes(width, pixel_size);
    uint32 width_pixels = (uint32)width;

    uint32_t hilite_color = (transfer_mode == 50) ? nqd_pack_hilite_color(bpp) : 0;
    bool pixel_mode = nqd_is_pixel_mode(transfer_mode);

    uint8 *ram_base = nqd_ram_base;
    uint8 *dst_ptr = Mac2HostAddr(dest_base) + (dest_Y * dest_row_bytes) + nqd_packed_byte_offset(dest_X, pixel_size);
    uint32_t dst_offset = (uint32_t)(dst_ptr - ram_base);

    NQDFillRectUniforms uniforms;
    uniforms.dst_offset    = dst_offset;
    uniforms.row_bytes     = dest_row_bytes;
    uniforms.width_bytes   = width_bytes;
    uniforms.height        = (uint32_t)height;
    uniforms.fill_color    = fill_color;
    uniforms.bpp           = (uint32_t)bpp;
    uniforms.transfer_mode = transfer_mode;
    uniforms.pixel_size    = (uint32_t)bpp;
    uniforms.width_pixels  = width_pixels;
    uniforms.fore_pen      = fore_pen;
    uniforms.back_pen      = back_pen;
    uniforms.hilite_color  = hilite_color;
    uniforms.mask_enabled  = 0;
    uniforms.mask_offset   = 0;
    uniforms.mask_stride   = 0;
    uniforms.bits_per_pixel = pixel_size;
    {   // Per-channel rgbOpColor blend weights for mode 32.
        // The GrafVars walk (a 5-step guest-controlled Mac-VM read) is
        // consumed ONLY by blend mode 32, so gate it on the mode — for every
        // other transfer mode the weights are dead. This narrows the
        // guest-controlled OOB-read attack surface to blend dispatches and skips
        // the per-op lowmem traffic. Mode-32 behaviour is byte-identical.
        NQDRgbOpColor _op = (transfer_mode == 32) ? nqd_read_rgb_op_color()
                                                  : NQDRgbOpColor{0, 0, 0};
        uniforms.blend_weight_r = _op.r;
        uniforms.blend_weight_g = _op.g;
        uniforms.blend_weight_b = _op.b;
    }

    NSUInteger total_threads = (pixel_mode && pixel_size >= 8)
        ? (NSUInteger)(width_pixels * height)
        : (NSUInteger)(width_bytes * height);

    id<MTLComputeCommandEncoder> encoder = nqd_get_batch_encoder();
    if (!encoder) return;

    [encoder setComputePipelineState:nqd_fillrect_pipeline];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:0];
    [encoder setBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:2];  // dummy mask buffer (mask_enabled=0)

    NSUInteger threadgroup_size = nqd_fillrect_pipeline.maxTotalThreadsPerThreadgroup;
    if (threadgroup_size > 256) threadgroup_size = 256;
    if (threadgroup_size > total_threads) threadgroup_size = total_threads;

    MTLSize grid = MTLSizeMake(total_threads, 1, 1);
    MTLSize group = MTLSizeMake(threadgroup_size, 1, 1);
    [encoder dispatchThreads:grid threadsPerThreadgroup:group];

    nqd_batch_did_dispatch();
}

// ---------------------------------------------------------------------------
// NQDMetalInvertRect — invert rect via Metal compute
//
// Delegates to the fillrect kernel with transfer_mode=10 (patXor). The XOR
// of fill_color with each dest byte inverts all bits (equivalent to the old
// dedicated nqd_invert kernel which XOR'd with 0xFF).
//
// Mac OS dispatches invert through a separate thunk entry, so we keep this
// function as a thin wrapper that sets up the right fill parameters.
// ---------------------------------------------------------------------------

void NQDMetalInvertRect(uint32 p)
{
    if (!nqd_metal_available) return;

    // Extract parameters from accl_params
    int16 dest_X = (int16)ReadMacInt16(p + NQD_acclDestRect + 2) - (int16)ReadMacInt16(p + NQD_acclDestBoundsRect + 2);
    int16 dest_Y = (int16)ReadMacInt16(p + NQD_acclDestRect + 0) - (int16)ReadMacInt16(p + NQD_acclDestBoundsRect + 0);
    int16 width  = (int16)ReadMacInt16(p + NQD_acclDestRect + 6) - (int16)ReadMacInt16(p + NQD_acclDestRect + 2);
    int16 height = (int16)ReadMacInt16(p + NQD_acclDestRect + 4) - (int16)ReadMacInt16(p + NQD_acclDestRect + 0);

    if (width <= 0 || height <= 0) return;

    uint32 pixel_size = ReadMacInt32(p + NQD_acclDestPixelSize);
    int bpp = nqd_bytes_per_pixel(pixel_size);
    if (pixel_size < 8) bpp = 1;  // packed depths: byte-level ops
    int32 dest_row_bytes = (int32)ReadMacInt32(p + NQD_acclDestRowBytes);
    uint32 dest_base = ReadMacInt32(p + NQD_acclDestBaseAddr);

    uint32 width_bytes = nqd_packed_width_bytes(width, pixel_size);
    uint32 width_pixels = (uint32)width;

    NQD_VLOG("NQDMetalInvertRect: dst=(%d,%d) %dx%d bpp=%d bits_per_pixel=%u rb=%d",
             dest_X, dest_Y, width, height, bpp, pixel_size, dest_row_bytes);

    // -----------------------------------------------------------------------
    // CPU fast path for small inverts on standard depths
    //
    // Invert is just XOR with 0xFF per byte. A tight CPU loop is much faster
    // than Metal for small rects, and competitive even for medium ones since
    // the operation is purely sequential memory access.
    // -----------------------------------------------------------------------

    int total_pixels = (int)width * (int)height;

    if (pixel_size >= 8 && total_pixels < NQD_CPU_THRESHOLD_PIXELS) {
        NQDMetalFlush();  // ensure any pending GPU writes are visible to CPU
        uint8 *dst_ptr = Mac2HostAddr(dest_base) + (dest_Y * dest_row_bytes) + (dest_X * bpp);
        int invert_bytes = width * bpp;
        for (int row = 0; row < height; row++) {
            // XOR 8 bytes at a time for throughput
            uint8 *p8 = dst_ptr;
            int remaining = invert_bytes;
            while (remaining >= 8) {
                *(uint64_t *)p8 ^= 0xFFFFFFFFFFFFFFFFULL;
                p8 += 8;
                remaining -= 8;
            }
            while (remaining > 0) {
                *p8 ^= 0xFF;
                p8++;
                remaining--;
            }
            dst_ptr += dest_row_bytes;
        }
        return;
    }

    // -----------------------------------------------------------------------
    // Metal batched path — patXor with fill_color=0xFFFFFFFF
    // -----------------------------------------------------------------------

    uint32_t transfer_mode = 10;  // patXor
    uint32_t fore_pen = htonl(ReadMacInt32(p + NQD_acclForePen));
    uint32_t back_pen = htonl(ReadMacInt32(p + NQD_acclBackPen));
    uint32_t fill_color = 0xFFFFFFFF;

    uint8 *ram_base = nqd_ram_base;
    uint8 *dst_ptr = Mac2HostAddr(dest_base) + (dest_Y * dest_row_bytes) + nqd_packed_byte_offset(dest_X, pixel_size);
    uint32_t dst_offset = (uint32_t)(dst_ptr - ram_base);

    NQDFillRectUniforms uniforms;
    uniforms.dst_offset    = dst_offset;
    uniforms.row_bytes     = dest_row_bytes;
    uniforms.width_bytes   = width_bytes;
    uniforms.height        = (uint32_t)height;
    uniforms.fill_color    = fill_color;
    uniforms.bpp           = (uint32_t)bpp;
    uniforms.transfer_mode = transfer_mode;
    uniforms.pixel_size    = (uint32_t)bpp;
    uniforms.width_pixels  = width_pixels;
    uniforms.fore_pen      = fore_pen;
    uniforms.back_pen      = back_pen;
    uniforms.hilite_color  = 0;
    uniforms.mask_enabled  = 0;
    uniforms.mask_offset   = 0;
    uniforms.mask_stride   = 0;
    uniforms.bits_per_pixel = pixel_size;
    {   // Per-channel rgbOpColor blend weights for mode 32.
        // The GrafVars walk (a 5-step guest-controlled Mac-VM read) is
        // consumed ONLY by blend mode 32, so gate it on the mode — for every
        // other transfer mode the weights are dead. This narrows the
        // guest-controlled OOB-read attack surface to blend dispatches and skips
        // the per-op lowmem traffic. Mode-32 behaviour is byte-identical.
        NQDRgbOpColor _op = (transfer_mode == 32) ? nqd_read_rgb_op_color()
                                                  : NQDRgbOpColor{0, 0, 0};
        uniforms.blend_weight_r = _op.r;
        uniforms.blend_weight_g = _op.g;
        uniforms.blend_weight_b = _op.b;
    }

    // patXor is a Boolean mode → per-byte dispatch
    NSUInteger total_threads = (NSUInteger)(width_bytes * height);

    id<MTLComputeCommandEncoder> encoder = nqd_get_batch_encoder();
    if (!encoder) return;

    [encoder setComputePipelineState:nqd_fillrect_pipeline];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:0];
    [encoder setBytes:&uniforms length:sizeof(uniforms) atIndex:1];
    [encoder setBuffer:nqd_ram_buffer offset:0 atIndex:2];  // dummy mask buffer (mask_enabled=0)

    NSUInteger threadgroup_size = nqd_fillrect_pipeline.maxTotalThreadsPerThreadgroup;
    if (threadgroup_size > 256) threadgroup_size = 256;
    if (threadgroup_size > total_threads) threadgroup_size = total_threads;

    MTLSize grid = MTLSizeMake(total_threads, 1, 1);
    MTLSize group = MTLSizeMake(threadgroup_size, 1, 1);
    [encoder dispatchThreads:grid threadsPerThreadgroup:group];

    nqd_batch_did_dispatch();
}
