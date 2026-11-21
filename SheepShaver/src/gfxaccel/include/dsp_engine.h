/*
 *  dsp_engine.h - DrawSprocket (DSp) engine public API
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  DSp is the fourth gfxaccel engine, alongside NQD, RAVE and GL.
 *  Sub-opcode ranges: 100 context lifecycle, 200 mode enumeration,
 *  300 CLUT, 400 gamma/fade, 500 VBL, 700+ the remaining DrawSprocketLib
 *  PEF exports. Slots 400, 401, 501, 502 and 600 stay unused: those calls
 *  are not DrawSprocketLib exports.
 */

#ifndef DSP_ENGINE_H
#define DSP_ENGINE_H

#include <stdint.h>
#include "dsp_version_policy.h"

/* DSp sub-opcodes. 0..2 are library lifecycle; ranges as in the file header. */
enum {
	kDSpStartup                     = 0,    /* DSpStartup() - idempotent */
	kDSpShutdown                    = 1,    /* DSpShutdown() - idempotent */
	kDSpGetVersion                  = 2,    /* Gestalt('dspv') handler */

	/* Context lifecycle. */
	kDSpContext_Reserve             = 100,
	kDSpContext_Release             = 101,
	kDSpContext_GetBackBuffer       = 102,
	kDSpContext_SwapBuffers         = 103,
	kDSpContext_SetState            = 104,
	kDSpContext_GetState            = 105,
	kDSpContext_InvalBackBufferRect = 106,

	/* Mode enumeration + best-match. */
	kDSpGetFirstContext             = 200,
	kDSpFindBestContext             = 201,
	kDSpContext_GetAttributes       = 202,

	/* Ends with kDSpContextNotFoundErr (DSp 1.7 p.17). */
	kDSpGetNextContext              = 203,

	/* 300-399: CLUT. */
	kDSpContext_SetCLUTEntries      = 300,
	kDSpContext_GetCLUTEntries      = 301,

	/* 400-499: gamma and fade. SetGamma/GetGamma (400/401) are not
	 * DrawSprocketLib exports; those slots stay unused. */
	kDSpContext_FadeGammaIn         = 402,
	kDSpContext_FadeGammaOut        = 403,
	kDSpContext_FadeGamma           = 404,

	/* 500-599: VBL. GetVBLProc (503) is an internal helper, not a DSp 1.7
	 * API (p.81 uninstalls via SetVBLProc(0)), and is not installed in
	 * dsp_install_symbols[]. 501/502 (GetVBLCount, BlankFill) are not
	 * exports and stay unused. */
	kDSpContext_SetVBLProc          = 500,
	kDSpContext_GetVBLProc          = 503,  /* round-trip helper */

	/* 600-699: unused. DSpContext_ProcessEvent is not an export; the real
	 * DSpProcessEvent(EventRecord*, Boolean*) takes the app's event in and
	 * lives at 750. */

	/* The remaining 33 DrawSprocketLib exports. */

	/* 700-705 — AltBuffers (underlay/overlay). */
	kDSpAltBuffer_New                 = 700,
	kDSpAltBuffer_Dispose             = 701,
	kDSpAltBuffer_GetCGrafPtr         = 702,
	kDSpAltBuffer_InvalRect           = 703,
	kDSpContext_GetUnderlayAltBuffer  = 704,
	kDSpContext_SetUnderlayAltBuffer  = 705,

	/* 710-711 — Blit. */
	kDSpBlit_Faster                   = 710,
	kDSpBlit_Fastest                  = 711,

	/* 720-723 — coords / mouse. */
	kDSpGetMouse                      = 720,
	kDSpContext_GlobalToLocal         = 721,
	kDSpContext_LocalToGlobal         = 722,
	kDSpFindContextFromPoint          = 723,

	/* 730-738 — queries / dirty-rect grid / frame-rate. */
	kDSpContext_IsBusy                = 730,
	kDSpContext_GetDisplayID          = 731,
	kDSpContext_GetFrontBuffer        = 732,
	kDSpContext_GetMonitorFrequency   = 733,
	kDSpContext_GetMaxFrameRate       = 734,
	kDSpContext_SetMaxFrameRate       = 735,
	kDSpContext_GetDirtyRectGridSize  = 736,
	kDSpContext_SetDirtyRectGridSize  = 737,
	kDSpContext_GetDirtyRectGridUnits = 738,

	/* 739-747 — save/restore/flatten + queue/switch + discovery. */
	kDSpContext_Flatten               = 739,
	kDSpContext_GetFlattenedSize      = 740,
	kDSpContext_Restore               = 741,
	kDSpContext_Queue                 = 742,
	kDSpContext_Switch                = 743,
	kDSpFindBestContextOnDisplayID    = 744,
	kDSpGetCurrentContext             = 745,
	kDSpCanUserSelectContext          = 746,
	kDSpUserSelectContext             = 747,

	/* 750 — DSpProcessEvent. */
	kDSpProcessEvent                  = 750,

	/* 760-761 — blanking color + debug mode. */
	kDSpSetBlankingColor              = 760,
	kDSpSetDebugMode                  = 761,

	kDSpMethodCount                 = 762
};

#define DSP_MAX_SUBOPCODE 762

/*
 *  Caps on guest-supplied alt-buffer size. Without them a crafted
 *  DSpAltBuffer_New overflows the uint32 rowBytes/size products or asks for
 *  a multi-GiB GPU allocation (iOS kills the app).
 *
 *  4032 is the widest 32 bpp row whose 256-aligned rowBytes (0x3F00) fits
 *  the 14-bit PixMap rowBytes field; 4033 aligns to 0x4000 and overflows it
 *  in DSpAltBuffer_GetCGrafPtr. Height shares the cap. The 64 MiB byte cap
 *  catches skewed dimensions (4032x4032x4 is just above it).
 */
#define DSP_ALT_MAX_DIM            4032u
#define DSP_ALT_MAX_BACKING_BYTES  (64u * 1024u * 1024u)

/*
 *  DSp 1.7 result codes (p.87), -30440..-30450. There is no "not supported"
 *  code: unsupported modes return kDSpContextNotFoundErr (p.13). Apps test
 *  these exact values, so don't add new ones.
 *
 *  On macOS/Catalyst, CarbonCore/MacErrors.h (pulled in by Foundation)
 *  already defines these enumerators, and C forbids redefining them. Such
 *  TUs include Foundation first, so gate on its include guard. kDSpNoErr and
 *  kDSpErrGeneric are always ours.
 */
#ifndef __MACERRORS__
enum {
	kDSpNotInitializedErr         = -30440,
	kDSpSystemSWTooOldErr         = -30441,
	kDSpInvalidContextErr         = -30442,
	kDSpInvalidAttributesErr      = -30443,
	kDSpContextAlreadyReservedErr = -30444,
	kDSpContextNotReservedErr     = -30445,
	kDSpContextNotFoundErr        = -30446,
	kDSpFrameRateNotReadyErr      = -30447,
	kDSpConfirmSwitchWarning      = -30448,
	kDSpInternalErr               = -30449,
	kDSpStereoContextErr          = -30450
};
#endif

enum {
	kDSpNoErr                     = 0,

	/* Legacy alias; new code should use a specific kDSp*Err. */
	kDSpErrGeneric                = kDSpInternalErr
};

/*
 *  Context-loss reason codes are positive values, not errors (DSp 1.7
 *  around p.92). On iOS only Lost applies, triggered by entering the
 *  background. Value 1 is unconfirmed against DrawSprocketLib.
 *
 *  Also defined in dsp_event_record.h; the guard lets either header come
 *  first.
 */
#ifndef DSP_CONTEXT_REASON_LOST_DEFINED
#define DSP_CONTEXT_REASON_LOST_DEFINED 1
enum {
	kDSpContextReason_Lost        = 1
};
#endif

/*
 *  DSp play states (DSp 1.7 pp.75, 86). Reserve starts Inactive (p.29).
 *  9 valid transitions, 3 invalid.
 */
enum DSpContextState {
	kDSpContextState_Active   = 0L,   /* owns display; DMC owner = kDMCOwnerDSp */
	kDSpContextState_Paused   = 1L,   /* menu bar visible; DMC owner = kDMCOwnerQuickDraw */
	kDSpContextState_Inactive = 2L    /* default play state; no blanking */
};

/* Depth masks, one bit per depth (DSp 1.7 pp.66-67). */
enum {
	kDSpDepthMask_1  = 1u <<  0,
	kDSpDepthMask_2  = 1u <<  1,
	kDSpDepthMask_4  = 1u <<  2,
	kDSpDepthMask_8  = 1u <<  3,
	kDSpDepthMask_16 = 1u <<  4,
	kDSpDepthMask_32 = 1u <<  5
};

/*
 *  contextOptions bits (DSp 1.7 p.74). PageFlip and QD3DAccel are accepted
 *  and round-tripped but have no effect.
 */
enum {
	kDSpContextOption_QD3DAccel   = 1u << 0,  /* "Not implemented" per PDF; accept + no-op */
	kDSpContextOption_PageFlip    = 1u << 1,  /* CAMetalLayer.maximumDrawableCount=3 handles */
	kDSpContextOption_DontSyncVBL = 1u << 2   /* SwapBuffers skips DSp frame pacing */
};

/*
 *  DSpContextAttributes (DSp 1.7 pp.65-67). Field order follows the 72-byte
 *  guest layout; offsets are noted per field. filler[3] at +52 is not
 *  stored. Every field is widened to uint32_t, so guest I/O must go through
 *  ReadMacInt / WriteMacInt at the guest offsets, never a struct copy.
 *
 *  backBufferWidth/Height are host-only mirrors of displayWidth/Height for
 *  dirty-rect clipping, set at Reserve and mode-cache build. They sit after
 *  the guest trailer so bytes 0..71 keep the guest layout.
 */
typedef struct DSpContextAttributes {
	uint32_t  frequency;              /* +0  Fixed; ignored on input, 0 if unknown (p.66) */
	uint32_t  displayWidth;           /* +4  pixels */
	uint32_t  displayHeight;          /* +8  pixels */
	uint32_t  reserved1;              /* +12 always 0 */
	uint32_t  reserved2;              /* +16 always 0 */
	uint32_t  colorNeeds;             /* +20 kDSpColorNeeds_{DontCare=0,Request=1,Require=2} */
	uint32_t  colorTable;             /* +24 CTabHandle; 0 for direct modes (p.66) */
	uint32_t  contextOptions;         /* +28 kDSpContextOption_* */
	uint32_t  backBufferDepthMask;    /* +32 kDSpDepthMask_* */
	uint32_t  displayDepthMask;       /* +36 kDSpDepthMask_* */
	uint32_t  backBufferBestDepth;    /* +40 bits per pixel */
	uint32_t  displayBestDepth;       /* +44 bits per pixel */
	uint32_t  pageCount;              /* +48 1..3 pages */
	uint32_t  gameMustConfirmSwitch;  /* +55 Boolean, output only (p.67) */
	uint32_t  reserved3[4];           /* +56..71 always 0 */
	/* --- host-only fields, never read or written in guest memory --- */
	uint32_t  backBufferWidth;        /* mirrors displayWidth */
	uint32_t  backBufferHeight;       /* mirrors displayHeight */
} DSpContextAttributes;

/*
 *  AltBuffer types (sub-ops 700-705). Fields are widened to uint32_t like
 *  DSpContextAttributes.
 *
 *  DSp 1.7 p.50 defines only kDSpBufferKind_Normal; GetCGrafPtr returns
 *  kDSpInvalidAttributesErr for any other kind.
 */
enum DSpBufferKind {
	kDSpBufferKind_Normal = 0   /* only supported kind */
};

/* RowBytesEqualsWidth requests tightly packed rows (DSp 1.7 p.68). */
enum DSpAltBufferOption {
	kDSpAltBufferOption_RowBytesEqualsWidth = 1 << 0
};

/*
 *  DSpAltBuffer_New attributes (DSp 1.7 p.68). NULL means "same as the
 *  context"; non-NULL makes an overlay that can't be an underlay (p.49).
 *  Guest layout: width@0, height@4, options@8, reserved[4]@12, 28 bytes.
 */
struct DSpAltBufferAttributes {
	uint32_t  width;        /* pixels */
	uint32_t  height;       /* pixels */
	uint32_t  options;      /* DSpAltBufferOption bits */
	uint32_t  reserved[4];  /* always 0 */
};

/*
 *  DSpBlitInfo.mode bits (DSp 1.7 p.87); values are fixed by the spec.
 *  SrcKey skips source pixels equal to srcKey; DstKey preserves dest pixels
 *  equal to dstKey. Interpolation selects bilinear scaling, else nearest.
 */
enum DSpBlitMode {
	kDSpBlitMode_Plain         = 0,        /* opaque srcCopy, no key, no filter */
	kDSpBlitMode_SrcKey        = 1 << 0,   /* source color key */
	kDSpBlitMode_DstKey        = 1 << 1,   /* dest color key */
	kDSpBlitMode_Interpolation = 1 << 2    /* bilinear scaling */
};

/*
 *  DSpBlitInfo guest offsets (DSp 1.7 pp.68-69, big-endian, 68 bytes).
 *  Handlers read fields individually; never cast a host struct over guest
 *  memory. filler[3] is at +1. completionFlag is set true when the blit is
 *  done; completionProc is 0 for none.
 */
#define DSP_BLITINFO_OFF_completionFlag   0   /* Boolean (1 byte) */
#define DSP_BLITINFO_OFF_completionProc   4   /* u32 guest PPC fn-ptr */
#define DSP_BLITINFO_OFF_srcContext       8   /* u32 */
#define DSP_BLITINFO_OFF_srcBuffer       12   /* u32 CGrafPtr */
#define DSP_BLITINFO_OFF_srcRect         16   /* Rect: top@+0 left@+2 bottom@+4 right@+6 */
#define DSP_BLITINFO_OFF_srcKey          24   /* u32 */
#define DSP_BLITINFO_OFF_dstContext      28   /* u32 */
#define DSP_BLITINFO_OFF_dstBuffer       32   /* u32 CGrafPtr */
#define DSP_BLITINFO_OFF_dstRect         36   /* Rect: top@+0 left@+2 bottom@+4 right@+6 */
#define DSP_BLITINFO_OFF_dstKey          44   /* u32 */
#define DSP_BLITINFO_OFF_mode            48   /* u32 DSpBlitMode */
#define DSP_BLITINFO_OFF_reserved        52   /* u32[4] */
#define DSP_BLITINFO_SIZE                68   /* p.69 */

/*
 *  Flatten/Restore format (sub-ops 739-741, DSp 1.7 pp.21-23).
 *
 *  Flatten is called before the context goes Active (p.22), so no Metal
 *  resources exist and none are serialized. Restore is documented to fail
 *  often, so kDSpContextNotFoundErr on a magic, version or display mismatch
 *  is a valid result.
 *
 *  Only this emulator reads the blob back, so it is a private format: a
 *  magic/version/size header, the 12 Reserve-relevant attribute fields
 *  (frequency, reserved and filler are re-derived by Reserve), then
 *  max_frame_rate and the dirty-grid size. Runtime state is never saved.
 */
#define DSP_FLAT_MAGIC                   0x44537046u  /* 'DSpF' big-endian */
#define DSP_FLAT_VERSION                 1u

/* Flattened-format offsets, all u32. */
#define DSP_FLAT_OFF_magic                0
#define DSP_FLAT_OFF_version              4
#define DSP_FLAT_OFF_size                 8
#define DSP_FLAT_OFF_displayWidth        12
#define DSP_FLAT_OFF_displayHeight       16
#define DSP_FLAT_OFF_colorNeeds          20
#define DSP_FLAT_OFF_colorTable          24
#define DSP_FLAT_OFF_contextOptions      28
#define DSP_FLAT_OFF_backBufferDepthMask 32
#define DSP_FLAT_OFF_displayDepthMask    36
#define DSP_FLAT_OFF_backBufferBestDepth 40
#define DSP_FLAT_OFF_displayBestDepth    44
#define DSP_FLAT_OFF_pageCount           48
#define DSP_FLAT_OFF_gameMustConfirmSwitch 52 /* widened from the 1-byte Boolean */
#define DSP_FLAT_OFF_max_frame_rate      56
#define DSP_FLAT_OFF_dirty_grid_w        60
#define DSP_FLAT_OFF_dirty_grid_h        64
#define DSP_FLAT_SIZE                    68

/* Defined in dsp_draw_context.mm. */
struct DSpContextPrivate;

#ifdef __cplusplus
extern "C" {
#endif

/*
 *  DSpInit is called from VideoInstallAccel() after GLInstallHooks().
 *  Repeat calls bump a refcount and don't re-register.
 */
extern void DSpInit(void);
extern bool DSpIsRegistered(void);

/*
 *  CFM patcher, called from VideoInstallAccel() when "dspaccel" is set.
 *  Resolves DrawSprocketLib exports via FindLibSymbol and overwrites the
 *  first 4 instructions of each with a branch to dsp_method_tvects[subop].
 *  Idempotent; retries for up to 3 accRun ticks if the library isn't loaded
 *  yet. Mirrors GLInstallHooks().
 */
extern void DSpInstallHooks(void);

/*
 *  True once DSpInstallHooks() has committed or used up
 *  DSP_HOOKS_MAX_ATTEMPTS. sony.cpp's accRun gate (case 65) keeps calling
 *  PatchAfterStartup() until then; gating on RaveIsRegistered() alone would
 *  allow only one attempt and miss late-bound CFM symbols. Emul thread only.
 */
extern bool DSpInstallHooksSweepComplete(void);

/* Called from ThunksInit() after GLThunksInit(); allocates the SheepMem
 * TVECTs for the DSp entry points, as RaveThunksInit() does. */
extern void DSpThunksInit(void);

/*
 *  NATIVE_DSP_DISPATCH handler, called from sheepshaver_glue.cpp like
 *  RaveDispatch/GLDispatch. The sub-opcode comes from dsp_scratch_addr
 *  (stored by the TVECT thunk's `stw r12, 0(r11)`), not r3: r3-r8 are the
 *  guest's own arguments (r3 is e.g. ctxRef). Returns the new gpr(3).
 */
extern uint32_t DSpDispatch(uint32_t r3, uint32_t r4, uint32_t r5,
                            uint32_t r6, uint32_t r7, uint32_t r8);

/*
 *  Startup bumps the refcount; Shutdown releases resources when it hits 0.
 *  GetVersion returns kDSpVersion_Current and also stores it at
 *  outVersionAddr when that is a valid NumVersion buffer.
 */
extern int32_t DSpStartupHandler(void);
extern int32_t DSpShutdownHandler(void);
extern uint32_t DSpGetVersionHandler(uint32_t outVersionAddr);

#ifdef __cplusplus
}
#endif

/* Guest scratch word through which the TVECT thunk (`stw r12, 0(r11)`)
 * passes the sub-opcode to DSpDispatch. Set by DSpThunksInit. Same role as
 * rave_scratch_addr. */
extern uint32_t dsp_scratch_addr;


/* Logging: compiled out unless ACCEL_LOGGING_ENABLED, then gated at runtime
 * by dsp_logging_enabled. */
#include "accel_logging.h"

#if ACCEL_LOGGING_ENABLED
#ifdef __APPLE__
#include <os/log.h>
extern os_log_t dsp_log;
#endif
extern bool dsp_logging_enabled;

#ifdef __APPLE__
#define DSP_LOG(fmt, ...) do { \
    if (dsp_logging_enabled) os_log(dsp_log, fmt, ##__VA_ARGS__); \
} while (0)
#define DSP_VLOG(fmt, ...) do { \
    if (dsp_logging_enabled && ACCEL_LOG_VERBOSE) os_log(dsp_log, fmt, ##__VA_ARGS__); \
} while (0)
#else
#define DSP_LOG(fmt, ...) do { \
    if (dsp_logging_enabled) printf("DSp: " fmt "\n", ##__VA_ARGS__); \
} while (0)
#define DSP_VLOG(fmt, ...) do { \
    if (dsp_logging_enabled && ACCEL_LOG_VERBOSE) printf("DSp: " fmt "\n", ##__VA_ARGS__); \
} while (0)
#endif
#else
static constexpr bool dsp_logging_enabled = false;
#define DSP_LOG(fmt, ...) do {} while (0)
#define DSP_VLOG(fmt, ...) do {} while (0)
#endif

#endif /* DSP_ENGINE_H */
