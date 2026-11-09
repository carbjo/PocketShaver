/*
 *  rave_engine.h - RAVE (QD3D Acceleration) engine thunks and dispatch
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef RAVE_ENGINE_H
#define RAVE_ENGINE_H

#include <stdint.h>

#include "rave_ati_tag_policy.h"

struct RaveBGRAImageStats {
	uint32_t nonzero;       // any BGRA channel is non-zero
	uint32_t alpha;         // alpha channel is non-zero
	uint32_t rgb;           // at least one RGB channel is non-zero
	uint32_t white;         // opaque/near-opaque white RGB pixels
	uint32_t first_nonzero; // pixelCount if absent
	uint32_t first_alpha;   // pixelCount if absent
	uint32_t first_rgb;     // pixelCount if absent
};

/*
 * Bugdom's ARGB16 sprite textures often have transparent top-left borders,
 * so diagnostics and empty checks need whole-image scans instead of leading
 * samples.
 */
static inline RaveBGRAImageStats RaveBGRAImageAnalyze(const uint8_t *pixels, uint32_t pixelCount)
{
	RaveBGRAImageStats stats = {0, 0, 0, 0, pixelCount, pixelCount, pixelCount};
	if (!pixels) return stats;
	for (uint32_t i = 0; i < pixelCount; i++) {
		const uint32_t off = i * 4;
		const uint8_t b = pixels[off];
		const uint8_t g = pixels[off + 1];
		const uint8_t r = pixels[off + 2];
		const uint8_t a = pixels[off + 3];
		const bool hasRGB = (b != 0 || g != 0 || r != 0);
		if (hasRGB || a != 0) {
			if (stats.nonzero == 0) stats.first_nonzero = i;
			stats.nonzero++;
		}
		if (a != 0) {
			if (stats.alpha == 0) stats.first_alpha = i;
			stats.alpha++;
		}
		if (hasRGB) {
			if (stats.rgb == 0) stats.first_rgb = i;
			stats.rgb++;
		}
		if (a >= 0xF0 && r >= 0xF0 && g >= 0xF0 && b >= 0xF0) {
			stats.white++;
		}
	}
	return stats;
}

static inline bool RaveBGRAImageHasData(const uint8_t *pixels, uint32_t pixelCount)
{
	return RaveBGRAImageAnalyze(pixels, pixelCount).nonzero != 0;
}

/*
 * Some QD3D/RAVE clients pass ARGB32 masks with the image in alpha and all-black
 * RGB, which vanish under kQATextureOp_Modulate on dark scenes. Treat them as
 * coverage masks with white color, like Bugdom's grayscale-is-alpha path.
 */
static inline bool RaveBGRAWhitenAlphaOnlyMask(uint8_t *pixels, uint32_t pixelCount)
{
	RaveBGRAImageStats stats = RaveBGRAImageAnalyze(pixels, pixelCount);
	if (!pixels || stats.alpha == 0 || stats.rgb != 0) return false;
	for (uint32_t i = 0; i < pixelCount; i++) {
		const uint32_t off = i * 4;
		if (pixels[off + 3] != 0) {
			pixels[off] = 0xFF;
			pixels[off + 1] = 0xFF;
			pixels[off + 2] = 0xFF;
		}
	}
	return true;
}

/*
 *  RAVE sub-opcodes, all dispatched through NATIVE_RAVE_DISPATCH with the
 *  sub-opcode in a scratch word. Draw methods are 0-34 (TQADrawMethodTag),
 *  engine methods 100-117.
 */

// Draw method sub-opcodes (TQADrawMethodTag values)
enum {
	kRaveDrawSetFloat          = 0,
	kRaveDrawSetInt            = 1,
	kRaveDrawSetPtr            = 2,
	kRaveDrawGetFloat          = 3,
	kRaveDrawGetInt            = 4,
	kRaveDrawGetPtr            = 5,
	kRaveDrawDrawPoint         = 6,
	kRaveDrawDrawLine          = 7,
	kRaveDrawDrawTriGouraud    = 8,
	kRaveDrawDrawTriTexture    = 9,
	kRaveDrawDrawVGouraud      = 10,
	kRaveDrawDrawVTexture      = 11,
	kRaveDrawDrawBitmap        = 12,
	kRaveDrawRenderStart       = 13,
	kRaveDrawRenderEnd         = 14,
	kRaveDrawRenderAbort       = 15,
	kRaveDrawFlush             = 16,
	kRaveDrawSync              = 17,
	kRaveDrawSubmitVerticesGouraud = 18,
	kRaveDrawSubmitVerticesTexture = 19,
	kRaveDrawDrawTriMeshGouraud   = 20,
	kRaveDrawDrawTriMeshTexture   = 21,
	kRaveDrawSetNoticeMethod      = 22,
	kRaveDrawGetNoticeMethod      = 23,
	kRaveDrawSubmitMultiTextureVertex = 24,
	kRaveDrawAccessDrawBuffer     = 25,
	kRaveDrawAccessDrawBufferEnd  = 26,
	kRaveDrawAccessZBuffer        = 27,
	kRaveDrawAccessZBufferEnd     = 28,
	kRaveDrawClearDrawBuffer      = 29,
	kRaveDrawClearZBuffer         = 30,
	kRaveDrawTextureFromContext   = 31,
	kRaveDrawBitmapFromContext    = 32,
	kRaveDrawBusy                 = 33,
	kRaveDrawSwapBuffers          = 34,

	kRaveDrawMethodCount          = 35
};

#ifndef RAVE_MAX_CONTEXTS
#define RAVE_MAX_CONTEXTS 8
#endif

// Engine method sub-opcodes: DDK TQAEngineMethodTag N -> 100 + N.
// GetMethod (the QARegisterEngine callback) is not a TQAEngineMethodTag; it
// shares sub-opcode 100 with DrawPrivateNew, discriminated by r3.
enum {
	kRaveEngineDrawPrivateNew       = 100,  // DDK tag 0
	kRaveEngineDrawPrivateDelete    = 101,  // DDK tag 1
	kRaveEngineCheckDevice          = 102,  // DDK tag 2
	kRaveEngineGestalt              = 103,  // DDK tag 3
	kRaveEngineTextureNew           = 104,  // DDK tag 4
	kRaveEngineTextureDetach        = 105,  // DDK tag 5
	kRaveEngineTextureDelete        = 106,  // DDK tag 6
	kRaveEngineBitmapNew            = 107,  // DDK tag 7
	kRaveEngineBitmapDetach         = 108,  // DDK tag 8
	kRaveEngineBitmapDelete         = 109,  // DDK tag 9
	kRaveEngineColorTableNew        = 110,  // DDK tag 10
	kRaveEngineColorTableDelete     = 111,  // DDK tag 11
	kRaveEngineTextureBindColorTable = 112, // DDK tag 12
	kRaveEngineBitmapBindColorTable = 113,  // DDK tag 13
	kRaveEngineAccessTexture        = 114,  // DDK tag 14
	kRaveEngineAccessTextureEnd     = 115,  // DDK tag 15
	kRaveEngineAccessBitmap         = 116,  // DDK tag 16
	kRaveEngineAccessBitmapEnd      = 117,  // DDK tag 17

	kRaveEngineMethodCount          = 18
};

// Hook sub-opcodes (200+) for PPC thunks that replace RAVE manager TVECTs.
// A thunk dispatches here when its engine/object argument is ours and
// otherwise chains to the original function.
enum {
	kRaveHookGetFirstEngine   = 200,  // QADeviceGetFirstEngine hook
	kRaveHookGetNextEngine    = 201,  // QADeviceGetNextEngine hook
	kRaveHookEngineGestalt    = 202,  // QAEngineGestalt hook
	kRaveHookEngineCheckDevice = 203, // QAEngineCheckDevice hook
	kRaveHookDrawContextNew   = 204,  // QADrawContextNew hook
	kRaveHookTextureNew       = 205,  // QATextureNew hook
	kRaveHookBitmapNew        = 206,  // QABitmapNew hook
	kRaveHookColorTableNew    = 207,  // QAColorTableNew hook
	kRaveHookDrawContextDelete = 208, // QADrawContextDelete hook
	kRaveHookTextureDelete    = 209,  // QATextureDelete hook
	kRaveHookBitmapDelete     = 210,  // QABitmapDelete hook
	kRaveHookColorTableDelete = 211,  // QAColorTableDelete hook
	kRaveHookTextureBindColorTable = 212,  // QATextureBindColorTable hook
	kRaveHookBitmapBindColorTable  = 213,  // QABitmapBindColorTable hook
	kRaveHookTextureDetach    = 214,  // QATextureDetach hook
	kRaveHookBitmapDetach     = 215,  // QABitmapDetach hook
	kRaveHookAccessTexture    = 216,  // QAAccessTexture hook
	kRaveHookAccessTextureEnd = 217,  // QAAccessTextureEnd hook
	kRaveHookAccessBitmap     = 218,  // QAAccessBitmap hook
	kRaveHookAccessBitmapEnd  = 219,  // QAAccessBitmapEnd hook
	// Q3Pixmap_Set_Image: r3 = pixmapAddr, r4 = srcHostAddr, r5 = byteCount.
	// Dispatch only; no thunk installs this hook yet.
	kRaveHookQ3PixmapSetImage = 220,
	kRaveHookEngineEnable     = 221,  // QAEngineEnable hook
	kRaveHookEngineDisable    = 222,  // QAEngineDisable hook

	kRaveHookCount            = 23
};

// ATI RaveExtFuncs sub-opcodes: TVECTs handed out via kATIRaveExtFuncs.
enum {
	kRaveATIClearDrawBuffer  = 300,
	kRaveATIClearZBuffer     = 301,
	kRaveATITextureUpdate    = 302,
	kRaveATIBindCodeBook     = 303,
	kRaveATIGetDrawBuffer    = 304,  // slot 4: GetDrawBuffer(ctx, TQADevice*) — Myth II
	kRaveATIStub             = 305,  // filler for unidentified table slots; returns kQANotSupported

	kRaveATIMethodCount      = 6
};

// Total TVECT count
#define RAVE_TOTAL_METHODS (kRaveDrawMethodCount + kRaveEngineMethodCount + kRaveHookCount + kRaveATIMethodCount)

// Array size; must cover the ATI sub-opcodes.
#define RAVE_MAX_SUBOPCODE 306

/*
 *  Draw context private data
 */

#define RAVE_MAX_TAG 154  // covers GL tags up to kQATagGL_TextureEnvColor_b (153)
static inline bool RaveEffectiveDepthWriteEnabled(uint32_t standardZBufferMask,
                                                  uint32_t atiDepthWriteEnable)
{
	return standardZBufferMask != 0 && atiDepthWriteEnable != 0;
}

static inline float RaveClampMetalDepth(float z)
{
	if (!(z >= 0.0f)) return 0.0f;
	if (z > 1.0f) return 1.0f;
	return z;
}

union RaveStateValue {
	float    f;
	uint32_t i;
	void    *p;
};

struct RaveMetalState;  // opaque, defined in rave_metal_renderer.mm

// Notice method storage (for 2D/3D compositing callbacks)
// Selectors: 0=RenderCompletion, 1=DisplayModeChanged, 2=ReloadTextures,
//            3=ImageBufferInitialize, 4=ImageBuffer2DComposite
#define RAVE_NUM_NOTICE_METHODS 5

struct RaveNoticeMethod {
	uint32_t callback;  // PPC function pointer (TVECT address), 0 = not set
	uint32_t refCon;    // PPC refCon value
};

/*
 *  With kQATag_ZSortedHint=1, transparent triangles are buffered and drawn
 *  back-to-front at RenderEnd. Vertices are raw floats because RaveVertex is
 *  private to rave_metal_renderer.mm; the layout must match RaveVertex.
 */
#define RAVE_VERTEX_FLOATS 20
#define RAVE_VERTEX_BYTES  (RAVE_VERTEX_FLOATS * sizeof(float))

void RaveFlushPendingDraws(void);

struct ZSortTriangle {
	RaveStateValue state[RAVE_MAX_TAG];
	bool multiTextureActive;
	uint32_t multiTextureHandle;
	float multiTexUV[12];
	float      verts[3][RAVE_VERTEX_FLOATS];
	float      sortKey;
	bool       textured;
};

#define RAVE_ZSORT_MAX_TRIANGLES 16384

struct RaveDrawPrivate {
	uint64_t       generation;      // unique lifetime, including reused slots/storage
	RaveStateValue state[RAVE_MAX_TAG];
	uint32_t       dirty_flags;
	uint32_t       flags;           // kQAContext_xxx from creation
	int32_t        width, height;
	int32_t        left, top;
	uint32_t       drawContextAddr; // Mac address of TQADrawContext
	struct RaveMetalState *metal;   // Metal resources, opaque to .cpp

	// Vertex staging buffer for geometry submission
	uint8_t       *vertexStagingBuffer;   // native heap, 64K vertices
	uint32_t       vertexStagingCount;    // current vertex count in staging buffer
	uint32_t       vertexStagingCapacity; // max vertices (65536)

	// Notice method callbacks for 2D/3D compositing
	RaveNoticeMethod noticeMethods[RAVE_NUM_NOTICE_METHODS];

	// Z-sorted transparency buffer (allocated per context)
	ZSortTriangle *zsortBuffer;     // heap-allocated, RAVE_ZSORT_MAX_TRIANGLES entries
	uint32_t       zsortCount;      // current count in buffer

	// Multi-texture state (RAVE 1.6 extension)
	bool           multiTextureActive;     // set by SubmitMultiTextureParams, cleared at draw
	uint32_t       multiTextureHandle;     // Mac address of second texture resource
	uint32_t       multiTextureOp;         // compositing operation (0=Add, 1=Mod, 2=BlendA, 3=Fixed)
	float          multiTextureFactor;     // blend factor for Fixed mode
	uint8_t       *multiTexStagingBuffer;  // parallel UV2 staging buffer (matches vertexStagingBuffer)

	// Grow-only per-draw scratch (RaveDrawScratchEnsure), fully consumed before
	// each draw method returns. A: primary vertices. B: fan-expansion array
	// live alongside A. F: indexed multi-texture UV2 floats.
	uint8_t       *drawScratchA;
	uint32_t       drawScratchACap;   // bytes
	uint8_t       *drawScratchB;
	uint32_t       drawScratchBCap;   // bytes
	uint8_t       *drawScratchF;
	uint32_t       drawScratchFCap;   // bytes
	uint32_t       multiTexStagingCount;   // current vertex count in multi-tex staging

	// ATI private tags, kept apart from the main state array
	RaveStateValue ati_state[RAVE_ATI_TAG_COUNT];  // indexed by (tag - 1000)
	uint32_t       ati_ext_funcs_owned; // engine-owned eight-entry guest table; never a SetPtr buffer
	bool           ati_fog_active;  // true when any ATI fog tag (indices 2-9) has been set

	uint32_t       frameCount;      // diagnostic; incremented each RenderStart
};

/*
 *  Public interface
 */

// Allocates all RAVE TVECTs in SheepMem (from ThunksInit).
extern void RaveThunksInit(void);

// Dispatch entry: takes r3-r8, returns the value for r3.
extern uint32_t RaveDispatch(uint32_t r3, uint32_t r4, uint32_t r5,
                             uint32_t r6, uint32_t r7, uint32_t r8);

// @autoreleasepool wrapper around RaveDispatch (gfxaccel_arc_shim.mm), used by
// NATIVE_RAVE_DISPATCH. Without it autoreleased Metal temporaries pile up on
// the emul thread (Nanosaur memory growth).
extern uint32_t RaveDispatchARC(uint32_t r3, uint32_t r4, uint32_t r5,
                                uint32_t r6, uint32_t r7, uint32_t r8);


extern void RaveRegisterEngine(void);

extern bool RaveIsRegistered(void);

// Patches the RAVE manager entry points so our engine appears in enumeration
// and our objects route to us. Called from RaveRegisterEngine.
extern void RaveInstallHooks(void);

// Our TQAEngine* handle: a SheepMem word holding RAVE_ENGINE_MAGIC. Hooks
// intercept calls that pass it.
#define RAVE_ENGINE_MAGIC 0x50534852  // 'PSHR'
extern uint32_t rave_sentinel_engine;  // Mac address of sentinel (contains RAVE_ENGINE_MAGIC)

// Saved original TVECT addresses for chaining
extern uint32_t rave_orig_get_first_engine;
extern uint32_t rave_orig_get_next_engine;
extern uint32_t rave_orig_engine_gestalt;
extern uint32_t rave_orig_engine_check_device;
extern uint32_t rave_orig_draw_context_new;
extern uint32_t rave_orig_texture_new;
extern uint32_t rave_orig_bitmap_new;
extern uint32_t rave_orig_color_table_new;
extern uint32_t rave_orig_draw_context_delete;
extern uint32_t rave_orig_texture_delete;
extern uint32_t rave_orig_bitmap_delete;
extern uint32_t rave_orig_color_table_delete;
extern uint32_t rave_orig_texture_bind_color_table;
extern uint32_t rave_orig_bitmap_bind_color_table;
extern uint32_t rave_orig_texture_detach;
extern uint32_t rave_orig_bitmap_detach;
extern uint32_t rave_orig_access_texture;
extern uint32_t rave_orig_access_texture_end;
extern uint32_t rave_orig_access_bitmap;
extern uint32_t rave_orig_access_bitmap_end;
extern uint32_t rave_orig_engine_enable;
extern uint32_t rave_orig_engine_disable;

// Per-hook state for unpatch-call-repatch chaining, used instead of a
// trampoline because a trampoline clobbers r11.
struct RaveHookPatchInfo {
	uint32_t orig_tvect;        // Original TVECT address (for CallMacOS)
	uint32_t orig_code;         // Code entry point (first instruction address)
	uint32_t saved_instr[4];    // Original first 4 instructions (saved before patching)
	uint32_t hook_instr[4];     // Hook patch instructions (to re-apply after chain)
	bool     active;            // Whether this hook is installed
};

#define RAVE_NUM_HOOKED_APIS 22
extern RaveHookPatchInfo rave_hook_patches[RAVE_NUM_HOOKED_APIS];

// Hook indices into rave_hook_patches[] — matches apis[] order in RaveInstallHooks
enum {
	kRaveHookIdx_GetFirstEngine   = 0,
	kRaveHookIdx_GetNextEngine    = 1,
	kRaveHookIdx_EngineGestalt    = 2,
	kRaveHookIdx_EngineCheckDevice = 3,
	kRaveHookIdx_DrawContextNew   = 4,
	kRaveHookIdx_TextureNew       = 5,
	kRaveHookIdx_BitmapNew        = 6,
	kRaveHookIdx_ColorTableNew    = 7,
	kRaveHookIdx_DrawContextDelete = 8,
	kRaveHookIdx_TextureDelete    = 9,
	kRaveHookIdx_BitmapDelete     = 10,
	kRaveHookIdx_ColorTableDelete = 11,
	kRaveHookIdx_TextureBindColorTable = 12,
	kRaveHookIdx_BitmapBindColorTable  = 13,
	kRaveHookIdx_TextureDetach    = 14,
	kRaveHookIdx_BitmapDetach     = 15,
	kRaveHookIdx_AccessTexture    = 16,
	kRaveHookIdx_AccessTextureEnd = 17,
	kRaveHookIdx_AccessBitmap     = 18,
	kRaveHookIdx_AccessBitmapEnd  = 19,
	kRaveHookIdx_EngineEnable     = 20,
	kRaveHookIdx_EngineDisable    = 21
};

// Restores the original code, calls it via CallMacOS, then re-patches.
// hook_index is a kRaveHookIdx_* value.
extern uint32_t RaveChainToOriginal(int hook_index, int nargs, uint32_t const *args);

// TVECT addresses indexed by sub-opcode.
extern uint32_t rave_method_tvects[RAVE_MAX_SUBOPCODE];

// Guest word through which thunks pass the sub-opcode.
extern uint32_t rave_scratch_addr;

/*
 *  Draw context lifecycle and state management (rave_draw_context.mm)
 */
extern int32_t NativeDrawPrivateNew(uint32_t drawContextAddr, uint32_t deviceAddr,
                                    uint32_t rectAddr, uint32_t clipAddr, uint32_t flags);
extern int32_t NativeDrawPrivateDelete(uint32_t drawPrivateHandle);

extern int32_t NativeSetFloat(uint32_t drawContextAddr, uint32_t tag, uint32_t valueBits);
extern int32_t NativeSetInt(uint32_t drawContextAddr, uint32_t tag, uint32_t value);
extern int32_t NativeSetPtr(uint32_t drawContextAddr, uint32_t tag, uint32_t ptr);
extern uint32_t NativeGetFloat(uint32_t drawContextAddr, uint32_t tag);
extern uint32_t NativeGetInt(uint32_t drawContextAddr, uint32_t tag);
extern uint32_t NativeGetPtr(uint32_t drawContextAddr, uint32_t tag);

extern RaveDrawPrivate *RaveGetContext(uint32_t handle);
extern int rave_context_count;  // for CAMetalLayer lifecycle

// Most recently created draw context, returned by
// EngineGestalt(kQATIGestalt_CurrentContext) so the QD3D IR can find its
// method table. Cleared when the last context is deleted.
extern uint32_t rave_current_draw_context_addr;

/*
 *  Logging
 */

#include "accel_logging.h"

#if ACCEL_LOGGING_ENABLED

#ifdef __APPLE__
#include <os/log.h>
extern os_log_t rave_log;
#endif

extern bool rave_logging_enabled;

#ifdef __APPLE__
#define RAVE_LOG(fmt, ...) do { \
	if (rave_logging_enabled) \
		os_log(rave_log, fmt, ##__VA_ARGS__); \
} while (0)
#define RAVE_VLOG(fmt, ...) do { \
	if (rave_logging_enabled && ACCEL_LOG_VERBOSE) \
		os_log(rave_log, fmt, ##__VA_ARGS__); \
} while (0)
#else
#define RAVE_LOG(fmt, ...) do { \
	if (rave_logging_enabled) \
		printf("RAVE: " fmt "\n", ##__VA_ARGS__); \
} while (0)
#define RAVE_VLOG(fmt, ...) do { \
	if (rave_logging_enabled && ACCEL_LOG_VERBOSE) \
		printf("RAVE: " fmt "\n", ##__VA_ARGS__); \
} while (0)
#endif

#else /* !ACCEL_LOGGING_ENABLED */

static constexpr bool rave_logging_enabled = false;
#define RAVE_LOG(fmt, ...) do {} while (0)
#define RAVE_VLOG(fmt, ...) do {} while (0)

#endif /* ACCEL_LOGGING_ENABLED */

/*
 *  Texture, bitmap and color-table resources: fixed table, 1-based handles,
 *  entries hold real Metal textures.
 */
enum RaveResourceType {
	kRaveResourceFree = 0,
	kRaveResourceTexture,    // 'TEXT' - dummy texture
	kRaveResourceBitmap,     // 'BMPP' - dummy bitmap
	kRaveResourceColorTable  // 'COLR' - dummy color table
};

struct RaveResourceEntry {
	RaveResourceType type;
	uint32_t         mac_addr;   // SheepMem address visible to PPC side
	uint32_t         generation; // increments whenever a resource table slot is reused

	// Metal texture data
	void            *metal_texture;   // id<MTLTexture> stored as void* for C++ header
	uint32_t         pixel_type;      // kQAPixel_* value
	uint32_t         width;
	uint32_t         height;
	uint32_t         mip_levels;      // number of mipmap levels
	uint8_t         *original_pixels; // retained indexed pixel data (CL8/CL4) for re-expansion
	uint32_t         original_size;   // size of original_pixels buffer
	uint32_t         row_bytes;       // original row bytes for level 0
	uint32_t         bound_clut;      // resource handle of bound color table (0 = none)
	uint8_t          priority;        // 4-bit priority (0-15) from bits [31:28] per RAVE 1.6 spec
	uint32_t         pixmap_mac_addr; // deferred direct texture Mac address
	bool             pixels_copied;   // true once non-empty direct texture data has been observed
	uint32_t         diag_alpha_zero; // diagnostic: transparent pixels after latest CLUT expansion
	uint32_t         diag_index_zero; // diagnostic: source index-zero pixels after latest CLUT expansion
	uint32_t         diag_rgb_nonzero; // diagnostic: non-black level-0 RGB pixels after conversion

	// CPU pixel access (AccessTexture/AccessBitmap support)
	uint8_t         *cpu_pixel_data;       // permanent CPU copy in original Mac format
	uint32_t         cpu_pixel_data_size;   // total bytes
	uint32_t         cpu_pixel_mac_addr;    // Mac-visible address (for PPC access)

	// Set by NativeHookQ3PixmapSetImage. Draw-time reads must then use
	// cpu_pixel_data, because the game may already have freed the memory at
	// pixmap_mac_addr.
	bool             cpu_pixel_data_is_authoritative;

	// Color table specific fields
	uint32_t        *clut_data;       // expanded BGRA32 palette (256 or 16 entries)
	uint32_t         clut_count;      // number of palette entries (256 for CL8, 16 for CL4)
	int32_t          transparent_index; // -1 if none
};

static inline bool RaveTextureNeedsLivePixmapRefresh(const RaveResourceEntry *entry)
{
	return entry &&
	       entry->metal_texture != nullptr &&
	       entry->pixmap_mac_addr != 0 &&
	       !entry->cpu_pixel_data_is_authoritative &&
	       !entry->pixels_copied;
}

// Unreal Tournament's surface cache and weapon effects need well over 512 live
// textures; running out renders surfaces black. Entries are ~200 B, so 4096 is
// ~800 KB; GPU memory tracks only what the guest creates.
#define RAVE_MAX_RESOURCES 4096

extern RaveResourceEntry rave_resource_table[RAVE_MAX_RESOURCES];
// Guest-visible handle words from SheepMem; slot i owns base + i*4.
extern uint32_t rave_resource_addr_base;

// Returns a 1-based handle, or 0 if the table is full.
extern uint32_t RaveResourceAlloc(RaveResourceType type);
extern bool RaveResourceFree(uint32_t handle);
// nullptr if the handle is invalid or free.
extern RaveResourceEntry *RaveResourceGet(uint32_t handle);
// O(1) address-to-handle lookup; 0 if not found.
extern uint32_t RaveResourceFindByAddr(uint32_t mac_addr);
// Remove a render-to-texture handle token from live draw contexts.
extern void RaveForgetRTTResourceHandle(uint32_t handle, uint32_t generation);

// Texture entry whose pixmap_mac_addr is pixmapAddr, or nullptr (the common
// case). Linear scan of the resource table. RAVE dispatch thread only.
extern RaveResourceEntry *RaveFindTextureByPixmapAddr(uint32_t pixmapAddr);

// Q3Pixmap_Set_Image intercept. If a texture tracks pixmapAddr (the pixmap
// storage the game will later free), copies min(byteCount, cpu_pixel_data_size)
// bytes from guest address srcHostAddr into its cpu_pixel_data and marks it
// authoritative, before the guest buffer is recycled. Otherwise does nothing.
extern void NativeHookQ3PixmapSetImage(uint32_t pixmapAddr,
                                        uint32_t srcHostAddr,
                                        uint32_t byteCount);

// Creates the Metal texture from guest memory on first draw when
// metal_texture is nullptr and pixmap_mac_addr is set.
extern void RaveRealizeDeferredTexture(RaveResourceEntry *entry);
extern void RaveRefreshTextureFromPixmap(RaveResourceEntry *entry);
extern bool ConvertPixels(uint32_t pixelType, uint32 srcAddr, uint8_t *dst,
                          uint32_t width, uint32_t height, uint32_t rowBytes);

/*
 *  Engine method dispatch functions (called from rave_dispatch.cpp)
 *  Implemented in rave_engine.cpp
 */
extern int32_t NativeEngineTextureNew(uint32_t flags, uint32_t pixelType, uint32_t imagesAddr, uint32_t newTexturePtr);
extern int32_t NativeEngineTextureDetach(uint32_t textureAddr);
extern void NativeEngineTextureDelete(uint32_t textureAddr);
extern int32_t NativeEngineBitmapNew(uint32_t flags, uint32_t pixelType, uint32_t imageAddr, uint32_t newBitmapPtr);
extern int32_t NativeEngineBitmapDetach(uint32_t bitmapAddr);
extern void NativeEngineBitmapDelete(uint32_t bitmapAddr);
extern int32_t NativeEngineColorTableNew(uint32_t tableType, uint32_t pixelDataAddr, uint32_t transparentIndexOrFlag, uint32_t newTablePtr);
extern void NativeEngineColorTableDelete(uint32_t colorTableAddr);
extern int32_t NativeEngineTextureBindColorTable(uint32_t textureAddr, uint32_t colorTableAddr);
extern int32_t NativeEngineBitmapBindColorTable(uint32_t bitmapAddr, uint32_t colorTableAddr);
extern bool RaveGetLastCL8ColorTableRGBSnapshot(uint8_t outRGB[768]);

// RAVE 1.6 CPU pixel access. TQAPixelBuffer = TQADeviceMemory:
// rowBytes +0, pixelType +4, width +8, height +12, baseAddr +16.
extern int32_t NativeEngineAccessTexture(uint32_t textureAddr, uint32_t mipmapLevel, uint32_t flags, uint32_t bufferStructAddr);
extern int32_t NativeEngineAccessTextureEnd(uint32_t textureAddr, uint32_t dirtyRectAddr);
extern int32_t NativeEngineAccessBitmap(uint32_t bitmapAddr, uint32_t flags, uint32_t bufferStructAddr);
extern int32_t NativeEngineAccessBitmapEnd(uint32_t bitmapAddr, uint32_t dirtyRectAddr);

/*
 *  Metal texture helpers (rave_metal_renderer.mm); textures are void*.
 */
extern void *RaveCreateMetalTexture(uint32_t width, uint32_t height, uint32_t mipLevels,
                                     const uint8_t *pixelData, uint32_t bytesPerRow);
extern void RaveUploadMipLevel(void *metalTexture, uint32_t level, uint32_t width, uint32_t height,
                                const uint8_t *pixelData, uint32_t bytesPerRow);
/* Bracket a mip-chain upload so the render pass is broken once, not per
 * level. Nestable. */
extern void RaveTextureUploadBatchBegin(void);
extern void RaveTextureUploadBatchEnd(void);
extern void RaveGenerateMipmaps(void *metalTexture);
extern void RaveReleaseTexture(void *metalTexture);

/*
 *  ATI RaveExtFuncs handlers (rave_metal_renderer.mm)
 */
extern int32_t NativeATIClearDrawBuffer(uint32_t drawContextAddr, uint32_t rectAddr);
extern int32_t NativeATIClearZBuffer(uint32_t drawContextAddr, uint32_t rectAddr);
extern int32_t NativeATITextureUpdate(uint32_t flags, uint32_t pixelType, uint32_t imagesAddr, uint32_t textureAddr);
extern int32_t NativeATIBindCodeBook(uint32_t textureAddr, uint32_t codebookPtr);
extern int32_t NativeATIGetDrawBuffer(uint32_t drawContextAddr, uint32_t deviceStructAddr);

#endif /* RAVE_ENGINE_H */
