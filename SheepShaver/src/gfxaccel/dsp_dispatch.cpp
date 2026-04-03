/*
 *  dsp_dispatch.cpp - DrawSprocket multiplexed dispatch from sub-opcode to handler
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Reads the sub-opcode from the scratch word written by the PPC thunk
 *  and dispatches to the appropriate DrawSprocket handler function.
 *  Initial implementation: all cases return noErr (0) with a DSP_LOG trace.
 *  Real implementations are added in T03.
 */

#include <cstring>
#include <cstdio>

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "dsp_engine.h"
#include "accel_logging.h"

// Logging state — disabled by default, toggled via preference
#if ACCEL_LOGGING_ENABLED
bool dsp_logging_enabled = false;

#ifdef __APPLE__
#include <os/log.h>
os_log_t dsp_log = OS_LOG_DEFAULT;
#endif

#endif /* ACCEL_LOGGING_ENABLED */

// DrawSprocket error codes (from Mac OS headers)
enum {
	kDSpNoErr             = 0,
	kDSpNotSupportedErr   = -7004
};

/*
 *  DSpDispatch — multiplexed dispatch entry point
 *
 *  Called from execute_native_op() when NATIVE_DSP_DISPATCH fires.
 *  Receives PPC registers r3-r8 as arguments, returns value for gpr(3).
 *
 *  Reads the sub-opcode from dsp_scratch_addr (written by the PPC thunk).
 */
uint32_t DSpDispatch(uint32_t r3, uint32_t r4, uint32_t r5,
                     uint32_t r6, uint32_t r7, uint32_t r8)
{
	uint32_t sub_opcode = ReadMacInt32(dsp_scratch_addr);

	switch (sub_opcode) {

	/* Startup / shutdown / version */
	case DSP_SUB_STARTUP:
		DSP_LOG("DSpStartup()");
		return DSpHandleStartup();
	case DSP_SUB_SHUTDOWN:
		DSP_LOG("DSpShutdown()");
		return DSpHandleShutdown();
	case DSP_SUB_GET_VERSION:
		DSP_LOG("DSpGetVersion(r3=0x%08x)", r3);
		return DSpHandleGetVersion(r3);

	/* Display management */
	case DSP_SUB_GET_FIRST_DISPLAY_ID:
		DSP_LOG("DSpGetFirstDisplayID(r3=0x%08x)", r3);
		return DSpHandleGetFirstDisplayID(r3);
	case DSP_SUB_GET_NEXT_DISPLAY_ID:
		DSP_LOG("DSpGetNextDisplayID(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleGetNextDisplayID(r3, r4);
	case DSP_SUB_GET_CURRENT_DISPLAY_ID:
		DSP_LOG("DSpGetCurrentDisplayID(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleGetCurrentDisplayID(r3, r4);
	case DSP_SUB_GET_DISPLAY_ATTRIBUTES:
		DSP_LOG("DSpGetDisplayAttributes(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleGetDisplayAttributes(r3, r4);
	case DSP_SUB_SET_DISPLAY_ATTRIBUTES:
		DSP_LOG("DSpSetDisplayAttributes(r3=0x%08x, r4=0x%08x)", r3, r4);
		return kDSpNoErr;

	/* Context lifecycle */
	case DSP_SUB_CONTEXT_GET_ATTRIBUTES:
		DSP_LOG("DSpContext_GetAttributes(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleContextGetAttributes(r3, r4);
	case DSP_SUB_CONTEXT_GET_DISPLAY_ID:
		DSP_LOG("DSpContext_GetDisplayID(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleContextGetDisplayID(r3, r4);
	case DSP_SUB_CONTEXT_SET_STATE:
		DSP_LOG("DSpContext_SetState(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleContextSetState(r3, r4);
	case DSP_SUB_CONTEXT_GET_STATE:
		DSP_LOG("DSpContext_GetState(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleContextGetState(r3, r4);
	case DSP_SUB_CONTEXT_GLOBAL_TO_LOCAL:
		DSP_LOG("DSpContext_GlobalToLocal(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleGlobalToLocal(r3, r4);
	case DSP_SUB_CONTEXT_LOCAL_TO_GLOBAL:
		DSP_LOG("DSpContext_LocalToGlobal(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleLocalToGlobal(r3, r4);

	/* Alternate buffers */
	case DSP_SUB_GET_FRONT_BUFFER:
		DSP_LOG("DSpContext_GetFrontBuffer(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleGetFrontBuffer(r3, r4);
	case DSP_SUB_GET_BACK_BUFFER:
		DSP_LOG("DSpContext_GetBackBuffer(r3=0x%08x, r4=0x%08x, r5=0x%08x)", r3, r4, r5);
		return DSpHandleGetBackBuffer(r3, r4, r5);
	case DSP_SUB_SWAP_BUFFERS:
		DSP_LOG("DSpContext_SwapBuffers(r3=0x%08x, r4=0x%08x, r5=0x%08x)", r3, r4, r5);
		return DSpHandleSwapBuffers(r3, r4, r5);
	case DSP_SUB_FIND_BEST_CONTEXT_ON_DISPLAY_ID:
		DSP_LOG("DSpFindBestContextOnDisplayID(r3=0x%08x, r4=0x%08x, r5=0x%08x)", r3, r4, r5);
		return DSpHandleFindBestContextOnDisplayID(r3, r4, r5);

	/* Context enumeration */
	case DSP_SUB_FIND_BEST_CONTEXT:
		DSP_LOG("DSpFindBestContext(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleFindBestContext(r3, r4);
	case DSP_SUB_CONTEXT_COUNT_ATTRIBUTES:
		DSP_LOG("DSpContext_CountAttributes(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleContextCountAttributes(r3, r4);
	case DSP_SUB_CONTEXT_GET_NTH_ATTRIBUTE:
		DSP_LOG("DSpContext_GetNthAttribute(r3=0x%08x, r4=0x%08x, r5=0x%08x)", r3, r4, r5);
		return DSpHandleContextGetNthAttribute(r3, r4, r5);

	/* New context API */
	case DSP_SUB_NEW_CONTEXT:
		DSP_LOG("DSpContext_New(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleContextNew(r3, r4);
	case DSP_SUB_DISPOSE_CONTEXT:
		DSP_LOG("DSpContext_Dispose(r3=0x%08x)", r3);
		return DSpHandleContextDispose(r3);

	/* Context iteration (primary resolution enumeration for games) */
	case DSP_SUB_GET_FIRST_CONTEXT:
		DSP_LOG("DSpGetFirstContext(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleGetFirstContext(r3, r4);
	case DSP_SUB_GET_NEXT_CONTEXT:
		DSP_LOG("DSpGetNextContext(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleGetNextContext(r3, r4);

	case DSP_SUB_RESERVE:
		DSP_LOG("DSpContext_Reserve(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleContextReserve(r3, r4);
	case DSP_SUB_RELEASE:
		DSP_LOG("DSpContext_Release(r3=0x%08x)", r3);
		return DSpHandleContextRelease(r3);

	/* Fading / gamma fade */
	case DSP_SUB_FADE_GAMMA:
		DSP_LOG("DSpContext_FadeGamma(r3=0x%08x, r4=0x%08x, r5=0x%08x)", r3, r4, r5);
		return DSpHandleFadeGamma(r3, r4, r5);
	case DSP_SUB_FADE_GAMMA_OUT:
		DSP_LOG("DSpContext_FadeGammaOut(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleFadeGammaOut(r3, r4);
	case DSP_SUB_FADE_GAMMA_IN:
		DSP_LOG("DSpContext_FadeGammaIn(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleFadeGammaIn(r3, r4);
	case DSP_SUB_SET_BLANKING_COLOR:
		DSP_LOG("DSpContext_SetBlankingColor(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleSetBlankingColor(r3, r4);
	case DSP_SUB_GET_BLANKING_COLOR:
		DSP_LOG("DSpContext_GetBlankingColor(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleGetBlankingColor(r3, r4);

	/* Gamma */
	case DSP_SUB_SET_GAMMA:
		DSP_LOG("DSpContext_SetGamma(r3=0x%08x, r4=0x%08x)", r3, r4);
		return kDSpNoErr;
	case DSP_SUB_GET_GAMMA:
		DSP_LOG("DSpContext_GetGamma(r3=0x%08x, r4=0x%08x)", r3, r4);
		return kDSpNoErr;
	case DSP_SUB_GET_GAMMA_BY_DEVICE:
		DSP_LOG("DSpContext_GetGammaByDevice(r3=0x%08x, r4=0x%08x)", r3, r4);
		return kDSpNoErr;
	case DSP_SUB_RESET_GAMMA:
		DSP_LOG("DSpContext_ResetGamma(r3=0x%08x)", r3);
		return kDSpNoErr;

	/* Palette */
	case DSP_SUB_SET_PALETTE:
		DSP_LOG("DSpContext_SetPalette(r3=0x%08x, r4=0x%08x)", r3, r4);
		return kDSpNoErr;
	case DSP_SUB_GET_PALETTE:
		DSP_LOG("DSpContext_GetPalette(r3=0x%08x, r4=0x%08x)", r3, r4);
		return kDSpNoErr;
	case DSP_SUB_SET_PALETTE_ENTRIES:
		DSP_LOG("DSpContext_SetPaletteEntries(r3=0x%08x, r4=0x%08x, r5=0x%08x, r6=0x%08x)", r3, r4, r5, r6);
		return kDSpNoErr;
	case DSP_SUB_GET_PALETTE_ENTRIES:
		DSP_LOG("DSpContext_GetPaletteEntries(r3=0x%08x, r4=0x%08x, r5=0x%08x, r6=0x%08x)", r3, r4, r5, r6);
		return kDSpNoErr;
	case DSP_SUB_GET_PALETTE_BY_DEVICE:
		DSP_LOG("DSpContext_GetPaletteByDevice(r3=0x%08x, r4=0x%08x)", r3, r4);
		return kDSpNoErr;

	/* Cursor / CLUT operations */
	case DSP_SUB_SET_CLUT_ENTRIES:
		DSP_LOG("DSpContext_SetCLUTEntries(r3=0x%08x, r4=0x%08x, r5=0x%08x, r6=0x%08x)", r3, r4, r5, r6);
		return DSpHandleSetCLUTEntries(r3, r4, r5, r6);
	case DSP_SUB_GET_CLUT_ENTRIES:
		DSP_LOG("DSpContext_GetCLUTEntries(r3=0x%08x, r4=0x%08x, r5=0x%08x, r6=0x%08x)", r3, r4, r5, r6);
		return kDSpNoErr;
	case DSP_SUB_SHOW_CURSOR:
		DSP_LOG("DSpContext_ShowCursor(r3=0x%08x, r4=0x%08x)", r3, r4);
		return kDSpNoErr;
	case DSP_SUB_OBSCURE_CURSOR:
		DSP_LOG("DSpContext_ObscureCursor(r3=0x%08x)", r3);
		return kDSpNoErr;
	case DSP_SUB_SET_CURSOR:
		DSP_LOG("DSpContext_SetCursor(r3=0x%08x, r4=0x%08x)", r3, r4);
		return kDSpNoErr;

	/* Underlay / overlay alt buffers */
	case DSP_SUB_GET_UNDERLAY_ALT_BUFFER:
		DSP_LOG("DSpContext_GetUnderlayAltBuffer(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleGetUnderlayAltBuffer(r3, r4);
	case DSP_SUB_GET_OVERLAY_ALT_BUFFER:
		DSP_LOG("DSpContext_GetOverlayAltBuffer(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleGetOverlayAltBuffer(r3, r4);
	case DSP_SUB_SET_UNDERLAY_ALT_BUFFER:
		DSP_LOG("DSpContext_SetUnderlayAltBuffer(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleSetUnderlayAltBuffer(r3, r4);
	case DSP_SUB_SET_OVERLAY_ALT_BUFFER:
		DSP_LOG("DSpContext_SetOverlayAltBuffer(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleSetOverlayAltBuffer(r3, r4);
	case DSP_SUB_ALT_BUFFER_NEW:
		DSP_LOG("DSpAltBuffer_New(r3=0x%08x, r4=0x%08x, r5=0x%08x, r6=0x%08x)", r3, r4, r5, r6);
		return DSpHandleAltBufferNew(r3, r4, r5);
	case DSP_SUB_ALT_BUFFER_DISPOSE:
		DSP_LOG("DSpAltBuffer_Dispose(r3=0x%08x)", r3);
		return DSpHandleAltBufferDispose(r3);
	case DSP_SUB_ALT_BUFFER_INVAL_RECT:
		DSP_LOG("DSpAltBuffer_InvalRect(r3=0x%08x, r4=0x%08x)", r3, r4);
		return DSpHandleAltBufferInvalRect(r3, r4);

	/* Context queue */
	case DSP_SUB_CONTEXT_QUEUE_ADD:
		DSP_LOG("DSpContextQueue_Add(r3=0x%08x, r4=0x%08x)", r3, r4);
		return kDSpNoErr;
	case DSP_SUB_CONTEXT_QUEUE_REMOVE:
		DSP_LOG("DSpContextQueue_Remove(r3=0x%08x, r4=0x%08x)", r3, r4);
		return kDSpNoErr;

	/* User notification callback */
	case DSP_SUB_INSTALL_USER_SELECT_CALLBACK:
		DSP_LOG("DSpInstallUserSelectCallback(r3=0x%08x, r4=0x%08x)", r3, r4);
		return kDSpNoErr;
	case DSP_SUB_REMOVE_USER_SELECT_CALLBACK:
		DSP_LOG("DSpRemoveUserSelectCallback(r3=0x%08x)", r3);
		return kDSpNoErr;

	/* Blit operations */
	case DSP_SUB_BLIT:
		DSP_LOG("DSpBlit(r3=0x%08x, r4=0x%08x, r5=0x%08x)", r3, r4, r5);
		return DSpHandleBlit(r3);
	case DSP_SUB_BLIT_RECT:
		DSP_LOG("DSpBlitRect(r3=0x%08x, r4=0x%08x, r5=0x%08x, r6=0x%08x)", r3, r4, r5, r6);
		return DSpHandleBlitRect(r3, r4, r5, r6);
	case DSP_SUB_BLIT_PIXEL:
		DSP_LOG("DSpBlitPixel(r3=0x%08x, r4=0x%08x, r5=0x%08x, r6=0x%08x)", r3, r4, r5, r6);
		return DSpHandleBlitPixel(r3, r4, r5, r6);
	case DSP_SUB_BLIT_REGION:
		DSP_LOG("DSpBlitRegion(r3=0x%08x, r4=0x%08x, r5=0x%08x, r6=0x%08x)", r3, r4, r5, r6);
		return DSpHandleBlitRegion(r3, r4, r5, r6);
	case DSP_SUB_BLIT_FASTEST:
		DSP_LOG("DSpBlitFastest(r3=0x%08x, r4=0x%08x, r5=0x%08x)", r3, r4, r5);
		return DSpHandleBlitFastest(r3, r4, r5);

	default:
		printf("DSpDispatch: unknown sub-opcode %d (r3=0x%08x r4=0x%08x r5=0x%08x)\n",
		       sub_opcode, r3, r4, r5);
		return (uint32_t)kDSpNotSupportedErr;
	}
}
