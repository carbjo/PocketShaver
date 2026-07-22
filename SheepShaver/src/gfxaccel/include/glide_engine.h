/*
 *  glide_engine.h - 3dfx Glide 2.x / 3.x guest API (CFM hooks + dispatch)
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  Peer to rave_engine.h / gl_engine.h / dsp_engine.h. Guest Glide library
 *  exports are patched to TVECTs that land in NATIVE_GLIDE_DISPATCH.
 *
 *  Diablo II (Mac) is the first acceptance title and uses Glide 3.0.
 *  Glide 2.x shares the same raster path with a separate symbol table.
 */

#ifndef GLIDE_ENGINE_H
#define GLIDE_ENGINE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Sub-opcode ranges:
 *   0-199:   shared / Glide 2 core
 *   200-399: Glide 3 combinatorial / query API
 *   400-499: LFB / extension
 */
enum {
	/* Lifecycle / SST */
	kGlide_grGlideInit                 = 0,
	kGlide_grGlideShutdown             = 1,
	kGlide_grGlideGetVersion           = 2,
	kGlide_grSstQueryBoards            = 3,
	kGlide_grSstQueryHardware          = 4,
	kGlide_grSstSelect                 = 5,
	kGlide_grSstWinOpen                = 6,
	kGlide_grSstWinClose               = 7,
	kGlide_grSstControl                = 8,
	kGlide_grSstIdle                   = 9,
	kGlide_grSstIsBusy                 = 10,
	kGlide_grSstOrigin                 = 11,
	kGlide_grSstScreenWidth            = 12,
	kGlide_grSstScreenHeight           = 13,
	kGlide_grSstStatus                 = 14,
	kGlide_grSstVRetraceOn             = 15,
	kGlide_grSstVideoLine              = 16,

	/* Buffering */
	kGlide_grBufferClear               = 20,
	kGlide_grBufferSwap                = 21,
	kGlide_grBufferNumPending          = 22,
	kGlide_grRenderBuffer              = 23,

	/* Drawing */
	kGlide_grDrawPoint                 = 30,
	kGlide_grDrawLine                  = 31,
	kGlide_grDrawTriangle              = 32,
	kGlide_grDrawPlanarPolygon         = 33,
	kGlide_grDrawPlanarPolygonVertexList = 34,
	kGlide_grDrawPolygon               = 35,
	kGlide_grDrawPolygonVertexList     = 36,
	kGlide_grAADrawTriangle            = 37,

	/* State (Glide 2 style + shared) */
	kGlide_grAlphaBlendFunction        = 50,
	kGlide_grAlphaCombine              = 51,
	kGlide_grAlphaControlsITRGBLighting = 52,
	kGlide_grAlphaTestFunction         = 53,
	kGlide_grAlphaTestReferenceValue   = 54,
	kGlide_grChromakeyMode             = 55,
	kGlide_grChromakeyValue            = 56,
	kGlide_grClipWindow                = 57,
	kGlide_grColorCombine              = 58,
	kGlide_grColorMask                 = 59,
	kGlide_grConstantColorValue        = 60,
	kGlide_grConstantColorValue4       = 61,
	kGlide_grCullMode                  = 62,
	kGlide_grDepthBiasLevel            = 63,
	kGlide_grDepthBufferFunction       = 64,
	kGlide_grDepthBufferMode           = 65,
	kGlide_grDepthMask                 = 66,
	kGlide_grDisableAllEffects         = 67,
	kGlide_grDitherMode                = 68,
	kGlide_grFogColorValue             = 69,
	kGlide_grFogMode                   = 70,
	kGlide_grFogTable                  = 71,
	kGlide_grGammaCorrectionValue      = 72,
	kGlide_grHints                     = 73,
	kGlide_grSplash                    = 74,

	/* Textures */
	kGlide_grTexCalcMemRequired        = 90,
	kGlide_grTexTextureMemRequired     = 91,
	kGlide_grTexMinAddress             = 92,
	kGlide_grTexMaxAddress             = 93,
	kGlide_grTexNCCTable               = 94,
	kGlide_grTexSource                 = 95,
	kGlide_grTexClampMode              = 96,
	kGlide_grTexCombine                = 97,
	kGlide_grTexDetailControl          = 98,
	kGlide_grTexFilterMode             = 99,
	kGlide_grTexLodBiasValue           = 100,
	kGlide_grTexLodTable               = 101,
	kGlide_grTexMipMapMode             = 102,
	kGlide_grTexDownloadMipMap         = 103,
	kGlide_grTexDownloadMipMapLevel    = 104,
	kGlide_grTexDownloadMipMapLevelPartial = 105,
	kGlide_grTexDownloadTable          = 106,
	kGlide_grTexDownloadTablePartial   = 107,
	kGlide_grTexMultibase              = 108,
	kGlide_grTexMultibaseAddress       = 109,

	/* Glide 3 */
	kGlide_grGet                       = 200,
	kGlide_grGetString                 = 201,
	kGlide_grReset                     = 202,
	kGlide_grEnable                    = 203,
	kGlide_grDisable                   = 204,
	kGlide_grCoordinateSystem          = 205,
	kGlide_grGetProcAddress            = 227, /* Glide 3 extension lookup */
	kGlide_guGammaCorrectionRGB        = 228,
	kGlide_grDeviceQueryExt            = 229, /* D2 detection extension */
	kGlide_grVertexLayout              = 206,
	kGlide_grDrawVertexArray           = 207,
	kGlide_grDrawVertexArrayContiguous = 208,
	kGlide_grGlideGetState             = 209,
	kGlide_grGlideSetState             = 210,
	kGlide_grGlideGetVertexLayout      = 211,
	kGlide_grGlideSetVertexLayout      = 212,
	kGlide_grFinish                    = 213,
	kGlide_grFlush                     = 214,
	kGlide_grLoadIdentity              = 215,
	kGlide_grLoadMatrix                = 216,
	kGlide_grMultMatrix                = 217,
	kGlide_grRotatef                   = 218,
	kGlide_grScalef                    = 219,
	kGlide_grTranslatef                = 220,
	kGlide_grViewport                  = 221,
	kGlide_grDepthRange                = 222,
	kGlide_grTexDownloadMipMapPartial  = 223,
	kGlide_grTexNCCTableG3             = 224,
	kGlide_grSelectContext             = 225,
	kGlide_grSstWinOpenG3              = 226, /* alias if export differs */

	/* LFB */
	kGlide_grLfbLock                   = 400,
	kGlide_grLfbUnlock                 = 401,
	kGlide_grLfbReadRegion             = 402,
	kGlide_grLfbWriteRegion            = 403,
	kGlide_grLfbConstantAlpha          = 404,
	kGlide_grLfbConstantDepth          = 405,
	kGlide_grLfbWriteColorFormat       = 406,
	kGlide_grLfbWriteColorSwizzle      = 407,

	/* CFM gate hooks (InterfaceLib) — intercept guest Glide loads.
	 * Synthetic conn IDs are unknown to the real CFM manager, so we must
	 * also handle CountSymbols / GetIndSymbol / CloseConnection or the
	 * guest crashes when it probes the connection after FindSymbol. */
	kGlide_HookGetSharedLibrary        = 500,
	kGlide_HookFindSymbol              = 501,
	kGlide_HookCloseConnection         = 502,
	kGlide_HookCountSymbols            = 503,
	kGlide_HookGetIndSymbol            = 504,

	kGlide_SUBOPCODE_MAX               = 510
};

#define GLIDE_MAX_SUBOPCODE 512

/* Error / bool style used by Glide (FxBool, FxI32). */
#ifndef FXTRUE
#define FXTRUE  1
#define FXFALSE 0
#endif

/* Common GrScreenResolution_t values */
enum {
	GR_RESOLUTION_320x200   = 0x0,
	GR_RESOLUTION_320x240   = 0x1,
	GR_RESOLUTION_400x256   = 0x2,
	GR_RESOLUTION_512x384   = 0x3,
	GR_RESOLUTION_640x200   = 0x4,
	GR_RESOLUTION_640x350   = 0x5,
	GR_RESOLUTION_640x400   = 0x6,
	GR_RESOLUTION_640x480   = 0x7,
	GR_RESOLUTION_800x600   = 0x8,
	GR_RESOLUTION_960x720   = 0x9,
	GR_RESOLUTION_856x480   = 0xa,
	GR_RESOLUTION_512x256   = 0xb,
	GR_RESOLUTION_1024x768  = 0xc,
	GR_RESOLUTION_1280x1024 = 0xd,
	GR_RESOLUTION_1600x1200 = 0xe,
	GR_RESOLUTION_400x300   = 0xf,
	GR_RESOLUTION_NONE      = 0xff
};

enum {
	GR_REFRESH_60Hz = 0x0,
	GR_REFRESH_70Hz = 0x1,
	GR_REFRESH_72Hz = 0x2,
	GR_REFRESH_75Hz = 0x3,
	GR_REFRESH_80Hz = 0x4,
	GR_REFRESH_90Hz = 0x5,
	GR_REFRESH_100Hz = 0x6,
	GR_REFRESH_85Hz = 0x7,
	GR_REFRESH_120Hz = 0x8,
	GR_REFRESH_NONE = 0xff
};

enum {
	GR_COLORFORMAT_ARGB = 0x0,
	GR_COLORFORMAT_ABGR = 0x1,
	GR_COLORFORMAT_RGBA = 0x2,
	GR_COLORFORMAT_BGRA = 0x3
};

enum {
	GR_ORIGIN_UPPER_LEFT = 0x0,
	GR_ORIGIN_LOWER_LEFT = 0x1
};

/*
 * grGet / grGetString tokens — official Glide 3 (3Dfx glide.h GLIDE3 block).
 * Earlier invented values were wrong and broke D2 detection (e.g. 0x0f is
 * GR_NUM_FB, not max texture size; 0xa0 is GR_EXTENSION, not garbage).
 */
enum {
	GR_BITS_DEPTH                   = 0x01,
	GR_BITS_RGBA                    = 0x02,
	GR_FIFO_FULLNESS                = 0x03,
	GR_FOG_TABLE_ENTRIES            = 0x04,
	GR_GAMMA_TABLE_ENTRIES          = 0x05,
	GR_IS_BUSY                      = 0x06,
	GR_LFB_PIXEL_PIPE               = 0x07,
	GR_MAX_TEXTURE_SIZE             = 0x08,
	GR_MAX_TEXTURE_ASPECT_RATIO     = 0x09,
	GR_MEMORY_FB                    = 0x0a,
	GR_MEMORY_TMU                   = 0x0b,
	GR_MEMORY_UMA                   = 0x0c,
	GR_NUM_BOARDS                   = 0x0d,
	GR_NUM_POWER_OF_TWO_TEXTURES    = 0x0e,
	GR_NUM_FB                       = 0x0f,
	GR_NUM_TMU                      = 0x10,
	GR_PENDING_BUFFERSWAPS          = 0x11,
	GR_REVISION_FB                  = 0x12,
	GR_REVISION_TMU                 = 0x13,
	GR_SWAP_HISTORY                 = 0x1f,
	GR_TEXTURE_ALIGN                = 0x20,
	GR_VIDEO_POSITION               = 0x21,
	GR_VIEWPORT                     = 0x22,
	GR_WDEPTH_MIN_MAX               = 0x23,
	GR_ZDEPTH_MIN_MAX               = 0x24,
	/* Some builds also expose these via grGet: */
	GR_GLIDE_STATE_SIZE             = 0x32,
	GR_GLIDE_VERTEXLAYOUT_SIZE      = 0x33,
	GR_NUM_CONTEXTS                 = 0x05, /* same as GR_GAMMA_TABLE_ENTRIES in some docs; keep alias */

	/* grGetString */
	GR_EXTENSION                    = 0xa0,
	GR_HARDWARE                     = 0xa1,
	GR_RENDERER                     = 0xa2,
	GR_VENDOR                       = 0xa3,
	GR_VERSION                      = 0xa4
};

void GlideThunksInit(void);
void GlideInstallHooks(void);
bool GlideInstallHooksSweepComplete(void);
void GlideResetForReboot(void);
/* No-op: guest already has the extension (DSp model). */
bool GlideRegisterCfmLibraries(void);

/* Dispatch: called from sheepshaver_glue NATIVE_GLIDE_DISPATCH. */
uint32_t GlideDispatch(uint32_t r3, uint32_t r4, uint32_t r5,
                       uint32_t r6, uint32_t r7, uint32_t r8);

/* CFM gate handlers + host-side FindLibSymbol synthetic resolve. */
uint32_t NativeGlideHookGetSharedLibrary(uint32_t libName, uint32_t arch,
                                         uint32_t flags, uint32_t connIDPtr,
                                         uint32_t mainAddrPtr, uint32_t errMsgPtr);
uint32_t NativeGlideHookFindSymbol(uint32_t conn, uint32_t symName,
                                   uint32_t symAddrPtr, uint32_t symClassPtr);
uint32_t NativeGlideHookCloseConnection(uint32_t connIDPtr);
uint32_t NativeGlideHookCountSymbols(uint32_t conn, uint32_t countPtr);
uint32_t NativeGlideHookGetIndSymbol(uint32_t conn, uint32_t index,
                                     uint32_t namePtr, uint32_t addrPtr,
                                     uint32_t classPtr);
uint32_t GlideResolveSyntheticSymbol(const char *lib_pascal,
                                     const char *sym_pascal);

/* Scratch / TVECT table (defined in glide_thunks.cpp). */
extern uint32_t glide_scratch_addr;
extern uint32_t glide_method_tvects[GLIDE_MAX_SUBOPCODE];

/* GL renderer entry points (gl/glide_gl_renderer.cpp). */
int  GlideGLInit(void);
void GlideGLShutdown(void);
int  GlideGLWinOpen(int width, int height, int origin_upper_left);
void GlideGLWinClose(void);
void GlideGLBufferClear(uint32_t color, uint32_t alpha, uint32_t depth);
void GlideGLBufferSwap(int swap_interval);
void GlideGLDrawTriangle(const void *a, const void *b, const void *c);
void GlideGLApplyState(void);

#ifdef __cplusplus
}
#endif

#endif /* GLIDE_ENGINE_H */
