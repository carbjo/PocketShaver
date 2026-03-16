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

/*
 *  RAVE sub-opcode constants
 *
 *  All RAVE methods are dispatched through a single NATIVE_OP slot
 *  (NATIVE_RAVE_DISPATCH) using a scratch word to carry the sub-opcode.
 *
 *  Draw methods use tags 0-34 directly (matching TQADrawMethodTag).
 *  Engine methods use 100-117 (offset to avoid collision with draw tags).
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

// Engine method sub-opcodes, offset by 100
// Order matches DDK TQAEngineMethodTag exactly so that
// DDK tag N -> sub-opcode (100 + N) with no mapping table needed.
//
// NOTE: GetMethod and MethodNameToIndex are NOT in TQAEngineMethodTag.
// GetMethod is the callback passed to QARegisterEngine (sub-opcode 100
// is shared: DrawPrivateNew and EngineGetMethod are discriminated by r3).
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

// Hook sub-opcodes for intercepting RAVE manager enumeration APIs.
// These are used by PPC thunks that replace the original TVECTs for
// QADeviceGetFirstEngine, QADeviceGetNextEngine, QAEngineGestalt,
// QAEngineCheckDevice, and QADrawContextNew. Each thunk checks if the
// engine argument is our sentinel handle; if so, it dispatches here
// via NATIVE_RAVE_DISPATCH; if not, it jumps to the original function.
//
// Sub-opcodes 200+ to avoid collision with draw (0-34) and engine (100-117).
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

	kRaveHookCount            = 20
};

// ATI RaveExtFuncs sub-opcodes (300-303)
// These are PPC-callable TVECTs delivered via SetPtr(kATIRaveExtFuncs)
enum {
	kRaveATIClearDrawBuffer  = 300,
	kRaveATIClearZBuffer     = 301,
	kRaveATITextureUpdate    = 302,
	kRaveATIBindCodeBook     = 303,

	kRaveATIMethodCount      = 4
};

// Total TVECT count
#define RAVE_TOTAL_METHODS (kRaveDrawMethodCount + kRaveEngineMethodCount + kRaveHookCount + kRaveATIMethodCount)

// Maximum sub-opcode value (for array sizing)
// Must cover ATI extension sub-opcodes at 300-303
#define RAVE_MAX_SUBOPCODE 304

/*
 *  Draw context private data
 */

#define RAVE_MAX_TAG 154  // covers GL tags up to kQATagGL_TextureEnvColor_b (153)
#define RAVE_ATI_TAG_COUNT 43  // kATITriCache(0) through kATIMeshAsStrip(42)

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
 *  Z-sorted transparency buffer
 *
 *  Transparent triangles are buffered during draw calls (when kQATag_ZSortedHint=1)
 *  and flushed back-to-front at RenderEnd for correct transparency compositing.
 *  Uses float[3][12] instead of RaveVertex[3] because RaveVertex is defined in
 *  rave_metal_renderer.mm, not this header. Layout is identical (12 floats = 48 bytes).
 */
struct ZSortTriangle {
	float      verts[3][12];   // 3 vertices x 12 floats (pos4+color4+uv4) = 144 bytes
	float      sortKey;
	bool       textured;
	uint32_t   textureMacAddr;
	int32_t    textureOp;
	int32_t    blendMode;
	int32_t    filterMode;
};

#define RAVE_ZSORT_MAX_TRIANGLES 16384

struct RaveDrawPrivate {
	RaveStateValue state[RAVE_MAX_TAG];
	uint32_t       dirty_flags;
	uint32_t       flags;           // kQAContext_xxx from creation
	int32_t        width, height;
	int32_t        left, top;
	uint32_t       drawContextAddr; // Mac address of TQADrawContext
	struct RaveMetalState *metal;   // Metal resources, opaque to .cpp

	// Vertex staging buffer for geometry submission
	uint8_t       *vertexStagingBuffer;   // native heap, 64K vertices * 40 bytes = 2.5MB
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
	uint32_t       multiTexStagingCount;   // current vertex count in multi-tex staging

	// ATI engine-specific tag storage (separate from main state array per user decision)
	RaveStateValue ati_state[RAVE_ATI_TAG_COUNT];  // indexed by (tag - 1000)
	bool           ati_fog_active;  // true when any ATI fog tag (indices 2-9) has been set

	// Diagnostic: frame counter for vertex dump (first N frames of each context)
	uint32_t       frameCount;      // incremented each RenderStart
};

/*
 *  Public interface
 */

// Allocate all RAVE TVECTs in SheepMem (called during ThunksInit)
extern void RaveThunksInit(void);

// Multiplexed dispatch entry point (called from execute_native_op)
// Receives PPC registers r3-r8 as arguments, returns value for gpr(3)
extern uint32_t RaveDispatch(uint32_t r3, uint32_t r4, uint32_t r5,
                             uint32_t r6, uint32_t r7, uint32_t r8);

// Engine registration entry point (implemented in plan 02)
extern void RaveRegisterEngine(void);

// Returns true if RAVE engine has been successfully registered
extern bool RaveIsRegistered(void);

// Install hooks on RAVE enumeration APIs (called from RaveRegisterEngine)
// Patches TVECTs for QADeviceGetFirstEngine, QADeviceGetNextEngine,
// QAEngineGestalt, QAEngineCheckDevice, and QADrawContextNew to inject
// our engine into the enumeration results.
extern void RaveInstallHooks(void);

// Sentinel TQAEngine* handle -- a SheepMem-allocated word with magic value.
// When PPC code passes this as an engine argument, our hooks intercept it.
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

// Per-hook patch info for unpatch-call-repatch chaining.
// Stores the original 4 instructions and addresses needed to safely chain
// to the original function without using a trampoline (which clobbers r11).
struct RaveHookPatchInfo {
	uint32_t orig_tvect;        // Original TVECT address (for CallMacOS)
	uint32_t orig_code;         // Code entry point (first instruction address)
	uint32_t saved_instr[4];    // Original first 4 instructions (saved before patching)
	uint32_t hook_instr[4];     // Hook patch instructions (to re-apply after chain)
	bool     active;            // Whether this hook is installed
};

#define RAVE_NUM_HOOKED_APIS 20
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
	kRaveHookIdx_AccessBitmapEnd  = 19
};

// Safe chaining: temporarily restores original code, calls via CallMacOS, re-patches.
// hook_index = index into rave_hook_patches[] (0-11, matching apis[] order in RaveInstallHooks).
extern uint32_t RaveChainToOriginal(int hook_index, int nargs, uint32_t const *args);

// Array of TVECT Mac addresses indexed by sub-opcode
// Draw methods at indices 0-34, engine methods at indices 100-117
extern uint32_t rave_method_tvects[RAVE_MAX_SUBOPCODE];

// Scratch word Mac address (used to pass sub-opcode from PPC thunk to native dispatch)
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

// Context table accessor
extern RaveDrawPrivate *RaveGetContext(uint32_t handle);
extern int rave_context_count;  // for CAMetalLayer lifecycle

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
#else
#define RAVE_LOG(fmt, ...) do { \
	if (rave_logging_enabled) \
		printf("RAVE: " fmt "\n", ##__VA_ARGS__); \
} while (0)
#endif

#else /* !ACCEL_LOGGING_ENABLED */

static constexpr bool rave_logging_enabled = false;
#define RAVE_LOG(fmt, ...) do {} while (0)

#endif /* ACCEL_LOGGING_ENABLED */

/*
 *  Resource handle table for dummy texture/bitmap/color table resources.
 *  Same pattern as draw context table (1-based handles, fixed size).
 *  Entries hold real Metal textures alongside CPU pixel data.
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
	uint16_t         priority;        // priority bits from flags >> 16 (per RAVE 1.6 spec)
	uint32_t         pixmap_mac_addr; // deferred: Mac address of pixel data (indexed textures)
	bool             pixels_copied;   // true once pixel data has been copied (at Detach time)

	// CPU pixel access (AccessTexture/AccessBitmap support)
	uint8_t         *cpu_pixel_data;       // permanent CPU copy in original Mac format
	uint32_t         cpu_pixel_data_size;   // total bytes
	uint32_t         cpu_pixel_mac_addr;    // Mac-visible address (for PPC access)

	// Color table specific fields
	uint32_t        *clut_data;       // expanded BGRA32 palette (256 or 16 entries)
	uint32_t         clut_count;      // number of palette entries (256 for CL8, 16 for CL4)
	int32_t          transparent_index; // -1 if none
};

#define RAVE_MAX_RESOURCES 64

extern RaveResourceEntry rave_resource_table[RAVE_MAX_RESOURCES];

// Allocate a slot in the resource table. Returns 1-based handle, or 0 on failure.
extern uint32_t RaveResourceAlloc(RaveResourceType type);
// Free a slot. Returns true if found and freed.
extern bool RaveResourceFree(uint32_t handle);
// Lookup by handle. Returns nullptr if invalid/free.
extern RaveResourceEntry *RaveResourceGet(uint32_t handle);
// Lookup by Mac address. Returns 1-based handle, or 0 if not found.
extern uint32_t RaveResourceFindByAddr(uint32_t mac_addr);

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

// AccessTexture/AccessBitmap CPU pixel access (RAVE 1.6)
extern int32_t NativeEngineAccessTexture(uint32_t textureAddr, uint32_t pixelTypePtr, uint32_t pixelBufferPtr, uint32_t rowBytesPtr);
extern int32_t NativeEngineAccessTextureEnd(uint32_t textureAddr, uint32_t dirtyRectAddr);
extern int32_t NativeEngineAccessBitmap(uint32_t bitmapAddr, uint32_t pixelTypePtr, uint32_t pixelBufferPtr, uint32_t rowBytesPtr);
extern int32_t NativeEngineAccessBitmapEnd(uint32_t bitmapAddr, uint32_t dirtyRectAddr);

/*
 *  Metal texture creation functions (implemented in rave_metal_renderer.mm)
 *  Use void* to cross ObjC++/C++ boundary
 */
extern void *RaveCreateMetalTexture(uint32_t width, uint32_t height, uint32_t mipLevels,
                                     const uint8_t *pixelData, uint32_t bytesPerRow);
extern void RaveUploadMipLevel(void *metalTexture, uint32_t level, uint32_t width, uint32_t height,
                                const uint8_t *pixelData, uint32_t bytesPerRow);
extern void RaveGenerateMipmaps(void *metalTexture);
extern void RaveReleaseTexture(void *metalTexture);

/*
 *  ATI RaveExtFuncs native handlers (implemented in rave_metal_renderer.mm)
 *  Weak stubs in rave_dispatch.cpp; real implementations in rave_metal_renderer.mm.
 */
extern int32_t NativeATIClearDrawBuffer(uint32_t drawContextAddr, uint32_t rectAddr);
extern int32_t NativeATIClearZBuffer(uint32_t drawContextAddr, uint32_t rectAddr);
extern int32_t NativeATITextureUpdate(uint32_t flags, uint32_t pixelType, uint32_t imagesAddr, uint32_t textureAddr);
extern int32_t NativeATIBindCodeBook(uint32_t textureAddr, uint32_t codebookPtr);

#endif /* RAVE_ENGINE_H */
