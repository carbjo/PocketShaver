/*
 *  dsp_engine.h - DrawSprocket acceleration engine thunks and dispatch
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#ifndef DSP_ENGINE_H
#define DSP_ENGINE_H

#include <stdint.h>

/*
 *  DrawSprocket sub-opcode constants
 *
 *  All DrawSprocket methods are dispatched through a single NATIVE_OP slot
 *  (NATIVE_DSP_DISPATCH) using a scratch word to carry the sub-opcode.
 *
 *  Sub-opcodes 0-53 cover the full DrawSprocket 1.7 public API.
 */

enum {
	/* Startup / shutdown / version */
	DSP_SUB_STARTUP                       = 0,
	DSP_SUB_SHUTDOWN                      = 1,
	DSP_SUB_GET_VERSION                   = 2,

	/* Display management */
	DSP_SUB_GET_FIRST_DISPLAY_ID          = 3,
	DSP_SUB_GET_NEXT_DISPLAY_ID           = 4,
	DSP_SUB_GET_CURRENT_DISPLAY_ID        = 5,
	DSP_SUB_GET_DISPLAY_ATTRIBUTES        = 6,
	DSP_SUB_SET_DISPLAY_ATTRIBUTES        = 7,

	/* Context lifecycle */
	DSP_SUB_CONTEXT_GET_ATTRIBUTES        = 8,
	DSP_SUB_CONTEXT_GET_DISPLAY_ID        = 9,
	DSP_SUB_CONTEXT_SET_STATE             = 10,
	DSP_SUB_CONTEXT_GET_STATE             = 11,
	DSP_SUB_CONTEXT_GLOBAL_TO_LOCAL       = 12,
	DSP_SUB_CONTEXT_LOCAL_TO_GLOBAL       = 13,

	/* Alternate buffers */
	DSP_SUB_GET_FRONT_BUFFER              = 14,
	DSP_SUB_GET_BACK_BUFFER               = 15,
	DSP_SUB_SWAP_BUFFERS                  = 16,
	DSP_SUB_FIND_BEST_CONTEXT_ON_DISPLAY_ID = 17,

	/* Context enumeration */
	DSP_SUB_FIND_BEST_CONTEXT             = 18,
	DSP_SUB_CONTEXT_COUNT_ATTRIBUTES      = 19,
	DSP_SUB_CONTEXT_GET_NTH_ATTRIBUTE     = 20,

	/* New context API */
	DSP_SUB_NEW_CONTEXT                   = 21,
	DSP_SUB_DISPOSE_CONTEXT               = 22,
	DSP_SUB_RESERVE                       = 23,
	DSP_SUB_RELEASE                       = 24,

	/* Fading / gamma fade */
	DSP_SUB_FADE_GAMMA                    = 25,
	DSP_SUB_FADE_GAMMA_OUT                = 26,
	DSP_SUB_SET_BLANKING_COLOR            = 27,
	DSP_SUB_GET_BLANKING_COLOR            = 28,

	/* Gamma */
	DSP_SUB_SET_GAMMA                     = 29,
	DSP_SUB_GET_GAMMA                     = 30,
	DSP_SUB_GET_GAMMA_BY_DEVICE           = 31,
	DSP_SUB_RESET_GAMMA                   = 32,

	/* Palette */
	DSP_SUB_SET_PALETTE                   = 33,
	DSP_SUB_GET_PALETTE                   = 34,
	DSP_SUB_SET_PALETTE_ENTRIES           = 35,
	DSP_SUB_GET_PALETTE_ENTRIES           = 36,
	DSP_SUB_GET_PALETTE_BY_DEVICE         = 37,

	/* Cursor / CLUT operations */
	DSP_SUB_SET_CLUT_ENTRIES              = 38,
	DSP_SUB_GET_CLUT_ENTRIES              = 39,
	DSP_SUB_SHOW_CURSOR                   = 40,
	DSP_SUB_OBSCURE_CURSOR                = 41,
	DSP_SUB_SET_CURSOR                    = 42,

	/* Underlay / overlay alt buffers */
	DSP_SUB_GET_UNDERLAY_ALT_BUFFER       = 43,
	DSP_SUB_GET_OVERLAY_ALT_BUFFER        = 44,

	/* Context queue */
	DSP_SUB_CONTEXT_QUEUE_ADD             = 45,
	DSP_SUB_CONTEXT_QUEUE_REMOVE          = 46,

	/* User notification callback */
	DSP_SUB_INSTALL_USER_SELECT_CALLBACK  = 47,
	DSP_SUB_REMOVE_USER_SELECT_CALLBACK   = 48,

	/* Blit operations */
	DSP_SUB_BLIT                          = 49,
	DSP_SUB_BLIT_RECT                     = 50,
	DSP_SUB_BLIT_PIXEL                    = 51,
	DSP_SUB_BLIT_REGION                   = 52,
	DSP_SUB_BLIT_FASTEST                  = 53,

	/* Gamma fade (FadeGammaIn) and alt buffer operations (S03) */
	DSP_SUB_FADE_GAMMA_IN                 = 54,
	DSP_SUB_SET_UNDERLAY_ALT_BUFFER       = 55,
	DSP_SUB_SET_OVERLAY_ALT_BUFFER        = 56,
	DSP_SUB_ALT_BUFFER_NEW                = 57,
	DSP_SUB_ALT_BUFFER_DISPOSE            = 58,
	DSP_SUB_ALT_BUFFER_INVAL_RECT         = 59,

	DSP_SUB_COUNT                         = 60
};

/* Room for future DrawSprocket extensions */
#define DSP_MAX_SUBOPCODE 65

/*
 *  TVECT table and scratch word
 */

/* Array of TVECT Mac addresses indexed by sub-opcode */
extern uint32_t dsp_method_tvects[DSP_MAX_SUBOPCODE];

/* Scratch word Mac address (passes sub-opcode from PPC thunk to native dispatch) */
extern uint32_t dsp_scratch_addr;

/*
 *  Public interface
 */

/* Allocate all DSp TVECTs in SheepMem (called during ThunksInit) */
extern void DSpThunksInit(void);

/* Multiplexed dispatch entry point (called from execute_native_op) */
/* Receives PPC registers r3-r8 as arguments, returns value for gpr(3) */
extern uint32_t DSpDispatch(uint32_t r3, uint32_t r4, uint32_t r5,
                            uint32_t r6, uint32_t r7, uint32_t r8);

/* Install hooks on DrawSprocketLib exported symbols via FindLibSymbol */
extern void DSpInstallHooks(void);

/*
 *  Handler functions for key DrawSprocket operations
 *  (called from DSpDispatch in dsp_dispatch.cpp)
 */
extern uint32_t DSpHandleStartup(void);
extern uint32_t DSpHandleShutdown(void);
extern uint32_t DSpHandleGetVersion(uint32_t r3);
extern uint32_t DSpHandleGetFirstDisplayID(uint32_t r3);
extern uint32_t DSpHandleGetNextDisplayID(uint32_t r3, uint32_t r4);
extern uint32_t DSpHandleGetCurrentDisplayID(uint32_t r3, uint32_t r4);
extern uint32_t DSpHandleGetDisplayAttributes(uint32_t r3, uint32_t r4);
extern uint32_t DSpHandleContextGetAttributes(uint32_t r3, uint32_t r4);
extern uint32_t DSpHandleContextGetDisplayID(uint32_t r3, uint32_t r4);
extern uint32_t DSpHandleFindBestContext(uint32_t r3, uint32_t r4);
extern uint32_t DSpHandleFindBestContextOnDisplayID(uint32_t r3, uint32_t r4, uint32_t r5);

/* Context lifecycle and buffer handlers (S02) */
extern uint32_t DSpHandleContextReserve(uint32_t r3, uint32_t r4);
extern uint32_t DSpHandleContextRelease(uint32_t r3);
extern uint32_t DSpHandleContextSetState(uint32_t r3, uint32_t r4);
extern uint32_t DSpHandleContextGetState(uint32_t r3, uint32_t r4);
extern uint32_t DSpHandleGetBackBuffer(uint32_t r3, uint32_t r4, uint32_t r5);
extern uint32_t DSpHandleGetFrontBuffer(uint32_t r3, uint32_t r4);

/* SwapBuffers and blit handlers (S02-T02) */
extern uint32_t DSpHandleSwapBuffers(uint32_t r3, uint32_t r4, uint32_t r5);
extern uint32_t DSpHandleBlit(uint32_t r3);
extern uint32_t DSpHandleBlitRect(uint32_t r3, uint32_t r4, uint32_t r5, uint32_t r6);
extern uint32_t DSpHandleBlitFastest(uint32_t r3, uint32_t r4, uint32_t r5);
extern uint32_t DSpHandleBlitPixel(uint32_t r3, uint32_t r4, uint32_t r5, uint32_t r6);
extern uint32_t DSpHandleBlitRegion(uint32_t r3, uint32_t r4, uint32_t r5, uint32_t r6);

/* CLUT, blanking color, coordinate translation handlers (S02-T03) */
extern uint32_t DSpHandleSetCLUTEntries(uint32_t r3, uint32_t r4, uint32_t r5, uint32_t r6);
extern uint32_t DSpHandleSetBlankingColor(uint32_t r3, uint32_t r4);
extern uint32_t DSpHandleGetBlankingColor(uint32_t r3, uint32_t r4);
extern uint32_t DSpHandleGlobalToLocal(uint32_t r3, uint32_t r4);
extern uint32_t DSpHandleLocalToGlobal(uint32_t r3, uint32_t r4);

/* Gamma fade handlers (S03) */
extern uint32_t DSpHandleFadeGamma(uint32_t r3, uint32_t r4, uint32_t r5);
extern uint32_t DSpHandleFadeGammaOut(uint32_t r3, uint32_t r4);
extern uint32_t DSpHandleFadeGammaIn(uint32_t r3, uint32_t r4);

/* Alt buffer handlers (S03-T02) */
extern uint32_t DSpHandleAltBufferNew(uint32_t r3, uint32_t r4, uint32_t r5);
extern uint32_t DSpHandleAltBufferDispose(uint32_t r3);
extern uint32_t DSpHandleAltBufferInvalRect(uint32_t r3, uint32_t r4);
extern uint32_t DSpHandleSetUnderlayAltBuffer(uint32_t r3, uint32_t r4);
extern uint32_t DSpHandleGetUnderlayAltBuffer(uint32_t r3, uint32_t r4);
extern uint32_t DSpHandleSetOverlayAltBuffer(uint32_t r3, uint32_t r4);
extern uint32_t DSpHandleGetOverlayAltBuffer(uint32_t r3, uint32_t r4);

/*
 *  Logging
 */

#include "accel_logging.h"

#if ACCEL_LOGGING_ENABLED

#ifdef __APPLE__
#include <os/log.h>
extern os_log_t dsp_log;
#endif

extern bool dsp_logging_enabled;

#ifdef __APPLE__
#define DSP_LOG(fmt, ...) do { \
	if (dsp_logging_enabled) \
		os_log(dsp_log, fmt, ##__VA_ARGS__); \
} while (0)
#else
#define DSP_LOG(fmt, ...) do { \
	if (dsp_logging_enabled) \
		printf("DSP: " fmt "\n", ##__VA_ARGS__); \
} while (0)
#endif

#else /* !ACCEL_LOGGING_ENABLED */

static constexpr bool dsp_logging_enabled = false;
#define DSP_LOG(fmt, ...) do {} while (0)

#endif /* ACCEL_LOGGING_ENABLED */

#endif /* DSP_ENGINE_H */
