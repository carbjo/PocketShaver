/*
 *  dsp_dispatch.cpp - DSp multiplexed dispatch from sub-opcode to handlers
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Called from sheepshaver_glue.cpp's NATIVE_DSP_DISPATCH case. The
 *  sub-opcode is the word the TVECT thunk stored at dsp_scratch_addr
 *  (dsp_thunks.cpp:AllocateDSpTVECT); r3-r8 are the guest call's own
 *  argument registers, so r3 is the first real argument. The return value
 *  goes back to gpr(3). Same shape as RaveDispatch and GLDispatch.
 */

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "dsp_engine.h"
#include "dsp_draw_context.h"
#include "dsp_mode_enumerate.h"

/*
 *  Caller LR and r11, set by sheepshaver_glue.cpp before DSpDispatch for
 *  call-site diagnostics. Under CFM, r11 holds the TVECT being called, which
 *  identifies the DSp symbol. Emul thread only.
 */
uint32_t dsp_caller_lr = 0;
uint32_t dsp_caller_r11 = 0;


uint32_t DSpDispatch(uint32_t r3, uint32_t r4, uint32_t r5,
                     uint32_t r6, uint32_t r7, uint32_t r8)
{
	/* The sub-opcode comes from the scratch word, not r3. */
	const uint32_t subop = ReadMacInt32(dsp_scratch_addr);

	DSP_LOG("DSpDispatch: subop %u (r3=0x%08x r4=0x%08x r5=0x%08x r6=0x%08x)",
	        (unsigned)subop, r3, r4, r5, r6);

	/* No handler takes more than four arguments. */
	(void)r7;
	(void)r8;
	switch (subop) {
		case kDSpStartup:
			return (uint32_t)DSpStartupHandler();
		case kDSpShutdown:
			return (uint32_t)DSpShutdownHandler();
		case kDSpGetVersion:
			return DSpGetVersionHandler(r3);

		/* Reserve (DSp p.25): r3 is the existing ctxRef from FindBest /
		 * GetFirstContext, not an out-param. */
		case kDSpContext_Reserve:
			return (uint32_t)DSpContext_ReserveHandler(r3 /* ctxRef */,
			                                            r4 /* attrAddr */);
		case kDSpContext_Release:
			return (uint32_t)DSpContext_ReleaseHandler(r3 /* ctxRef */);

		case kDSpContext_GetBackBuffer:
			return (uint32_t)DSpContext_GetBackBufferHandler(r3, r4, r5);
		case kDSpContext_SwapBuffers:
			return (uint32_t)DSpContext_SwapBuffersHandler(r3, r4, r5);
		case kDSpContext_SetState:
			return (uint32_t)DSpContext_SetStateHandler(r3, r4);
		case kDSpContext_GetState:
			return (uint32_t)DSpContext_GetStateHandler(r3, r4);
		case kDSpContext_InvalBackBufferRect:
			return (uint32_t)DSpContext_InvalBackBufferRectHandler(r3, r4);

		/* 200 */
		case kDSpGetFirstContext:
			return (uint32_t)DSpGetFirstContextHandler(r3 /* displayID */,
			                                            r4 /* outContextRefAddr */);

		/* 201: depth-mask filter, then depth, then resolution preference. */
		case kDSpFindBestContext:
			return (uint32_t)DSpFindBestContextHandler(r3 /* attrAddr */,
			                                            r4 /* outContextRefAddr */);

		/* 202: writes ctx->attr in the DSp p.65 layout. Implemented in
		 * dsp_draw_context.mm because it needs DSpContextPrivate. */
		case kDSpContext_GetAttributes:
			return (uint32_t)DSpContext_GetAttributesHandler(r3 /* ctxRef */,
			                                                  r4 /* outAttrAddr */);

		/* 203: walks the mode list; kDSpContextNotFoundErr and *out = 0 at
		 * the end (DSp p.17). */
		case kDSpGetNextContext:
			return (uint32_t)DSpGetNextContextHandler(r3 /* prevCtxRef */,
			                                           r4 /* outContextRefAddr */);

		/* 300/301 (DSp pp.56-57): pointer before index. r4 is the ColorSpec
		 * array, r6 is a zero-based count (entries start..start+r6). */
		case kDSpContext_SetCLUTEntries:
			return (uint32_t)DSpContext_SetCLUTEntriesHandler(r3 /* ctxRef */,
			                                                   r4 /* inEntries (ptr) */,
			                                                   r5 /* inStartingEntry */,
			                                                   r6 /* inLastEntry */);
		case kDSpContext_GetCLUTEntries:
			return (uint32_t)DSpContext_GetCLUTEntriesHandler(r3 /* ctxRef */,
			                                                   r4 /* outEntries (ptr) */,
			                                                   r5 /* inStartingEntry */,
			                                                   r6 /* inLastEntry */);

		/* Fades 402-404 (DSp pp.32-35). SetGamma/GetGamma (400/401) are not
		 * DrawSprocketLib exports.
		 *   FadeGammaIn/Out: r3 = ctxRef, r4 = RGBColor *zeroIntensity
		 *   FadeGamma:       r3 = ctxRef, r4 = SInt32 percent, r5 = RGBColor * */
		case kDSpContext_FadeGammaIn:
			return (uint32_t)DSpContext_FadeGammaInHandler(r3 /* ctxRef */,
			                                                r4 /* colorAddr */);
		case kDSpContext_FadeGammaOut:
			return (uint32_t)DSpContext_FadeGammaOutHandler(r3 /* ctxRef */,
			                                                 r4 /* colorAddr */);
		case kDSpContext_FadeGamma:
			return (uint32_t)DSpContext_FadeGammaHandler(r3 /* ctxRef */,
			                                              (int32_t)r4 /* inPercent (SInt32) */,
			                                              r5 /* colorAddr */);

		/* 500/503. GetVBLCount and BlankFill (501/502) are not
		 * DrawSprocketLib exports. */
		case kDSpContext_SetVBLProc:
			return (uint32_t)DSpContext_SetVBLProcHandler(r3 /* ctxRef */,
			                                               r4 /* procPtr */,
			                                               r5 /* refCon */);
		case kDSpContext_GetVBLProc:
			return (uint32_t)DSpContext_GetVBLProcHandler(r3 /* ctxRef */,
			                                               r4 /* procOutAddr */,
			                                               r5 /* refConOutAddr */);

		/* Queries, 730-738 and 745. r3 = ctxRef (displayID for 745). */
		case kDSpContext_IsBusy:                                    /* sub-op 730 */
			return (uint32_t)DSpContext_IsBusyHandler(r3 /* ctxRef */,
			                                           r4 /* outBusyAddr */);
		case kDSpContext_GetDisplayID:                              /* sub-op 731 */
			return (uint32_t)DSpContext_GetDisplayIDHandler(r3 /* ctxRef */,
			                                                 r4 /* outIDAddr */);
		case kDSpContext_GetDirtyRectGridUnits:                     /* sub-op 738 */
			return (uint32_t)DSpContext_GetDirtyRectGridUnitsHandler(r3 /* ctxRef */,
			                                                          r4 /* outWAddr */,
			                                                          r5 /* outHAddr */);
		case kDSpContext_GetMaxFrameRate:                           /* sub-op 734 */
			return (uint32_t)DSpContext_GetMaxFrameRateHandler(r3 /* ctxRef */,
			                                                    r4 /* outMaxFPSAddr */);
		case kDSpContext_SetMaxFrameRate:                           /* sub-op 735 */
			return (uint32_t)DSpContext_SetMaxFrameRateHandler(r3 /* ctxRef */,
			                                                    r4 /* inMaxFPS */);
		case kDSpContext_GetMonitorFrequency:                       /* sub-op 733 */
			return (uint32_t)DSpContext_GetMonitorFrequencyHandler(r3 /* ctxRef */,
			                                                        r4 /* outFixedAddr */);
		case kDSpContext_GetDirtyRectGridSize:                      /* sub-op 736 */
			return (uint32_t)DSpContext_GetDirtyRectGridSizeHandler(r3 /* ctxRef */,
			                                                         r4 /* outWAddr */,
			                                                         r5 /* outHAddr */);
		case kDSpContext_SetDirtyRectGridSize:                      /* sub-op 737 */
			return (uint32_t)DSpContext_SetDirtyRectGridSizeHandler(r3 /* ctxRef */,
			                                                         r4 /* inW */,
			                                                         r5 /* inH */);
		case kDSpContext_GetFrontBuffer:                            /* sub-op 732 */
			return (uint32_t)DSpContext_GetFrontBufferHandler(r3 /* ctxRef */,
			                                                   r4 /* outCGrafPtrAddr */);
		case kDSpGetCurrentContext:                                 /* sub-op 745 */
			/* r3 is a displayID, not a ctxRef. */
			return (uint32_t)DSpGetCurrentContextHandler(r3 /* displayID */,
			                                              r4 /* outCtxRefAddr */);

		/* Coordinates and mouse, 720-723. GetMouse has no ctxRef.
		 * GlobalToLocal / LocalToGlobal are identity (single fullscreen
		 * display at origin 0,0). */
		case kDSpGetMouse:                                          /* sub-op 720 */
			/* r3 is the out-Point address. */
			return (uint32_t)DSpGetMouseHandler(r3 /* outGlobalPointAddr */);
		case kDSpContext_GlobalToLocal:                             /* sub-op 721 */
			return (uint32_t)DSpContext_GlobalToLocalHandler(r3 /* ctxRef */,
			                                                  r4 /* ioPointAddr */);
		case kDSpContext_LocalToGlobal:                             /* sub-op 722 */
			return (uint32_t)DSpContext_LocalToGlobalHandler(r3 /* ctxRef */,
			                                                  r4 /* ioPointAddr */);
		case kDSpFindContextFromPoint: {                            /* sub-op 723 */
			/* The Point is passed by value: v in the high half, h in the
			 * low half. Do not dereference r3. */
			const int16_t v = (int16_t)(r3 >> 16);
			const int16_t h = (int16_t)(r3 & 0xFFFF);
			return (uint32_t)DSpFindContextFromPointHandler(v, h,
			                                                r4 /* outCtxRefAddr */);
		}

		/* Discovery, 744-747, 760-761. Single display: the OnDisplayID and
		 * UserSelect variants delegate to FindBest (no dialog), and
		 * CanUserSelectContext reports false. 760/761 have no ctxRef. */
		case kDSpFindBestContextOnDisplayID:                        /* sub-op 744 */
			return (uint32_t)DSpFindBestContextOnDisplayIDHandler(r3 /* attrAddr */,
			                                                       r4 /* outCtxRefAddr */,
			                                                       r5 /* inDisplayID */);
		case kDSpCanUserSelectContext:                              /* sub-op 746 */
			return (uint32_t)DSpCanUserSelectContextHandler(r3 /* attrAddr */,
			                                                 r4 /* outCanAddr */);
		case kDSpUserSelectContext:                                 /* sub-op 747 */
			return (uint32_t)DSpUserSelectContextHandler(r3 /* attrAddr */,
			                                              r4 /* dialogLoc */,
			                                              r5 /* eventProc */,
			                                              r6 /* outCtxRefAddr */);
		case kDSpSetBlankingColor:                                  /* sub-op 760 */
			/* r3 is the RGBColor address. */
			return (uint32_t)DSpSetBlankingColorHandler(r3 /* inRGBColorAddr */);
		case kDSpSetDebugMode:                                      /* sub-op 761 */
			/* r3 is the Boolean value. */
			return (uint32_t)DSpSetDebugModeHandler(r3 /* inDebugMode */);

		/* DSpProcessEvent (750, DSp p.58): r3 = EventRecord *, r4 = Boolean *.
		 * No ctxRef. The app passes its own event in for suspend/resume. */
		case kDSpProcessEvent:                                      /* sub-op 750 */
			return (uint32_t)DSpProcessEventHandler(r3 /* inEventAddr */,
			                                        r4 /* outProcessedAddr */);

		/* Any exported sub-op without a case falls to default and fails with
		 * kDSpInternalErr rather than faking success. */

		/* AltBuffers, 700-705. */
		case kDSpAltBuffer_New:                                     /* sub-op 700 */
			return (uint32_t)DSpAltBuffer_NewHandler(r3 /* ctxRef */,
			                                         r4 /* inVRAMBuffer */,
			                                         r5 /* inAttributes */,
			                                         r6 /* outAltBuffer */);
		case kDSpAltBuffer_Dispose:                                 /* sub-op 701 */
			return (uint32_t)DSpAltBuffer_DisposeHandler(r3 /* altBuffer */);
		case kDSpAltBuffer_GetCGrafPtr:                             /* sub-op 702 */
			return (uint32_t)DSpAltBuffer_GetCGrafPtrHandler(r3 /* altBuffer */,
			                                                 r4 /* bufferKind */,
			                                                 r5 /* outCGrafPtr */);
		case kDSpAltBuffer_InvalRect:                              /* sub-op 703 */
			return (uint32_t)DSpAltBuffer_InvalRectHandler(r3 /* altBuffer */,
			                                               r4 /* inInvalidRect */);
		case kDSpContext_GetUnderlayAltBuffer:                     /* sub-op 704 */
			return (uint32_t)DSpContext_GetUnderlayAltBufferHandler(r3 /* ctxRef */,
			                                                        r4 /* outUnderlay */);
		case kDSpContext_SetUnderlayAltBuffer:                     /* sub-op 705 */
			return (uint32_t)DSpContext_SetUnderlayAltBufferHandler(r3 /* ctxRef */,
			                                                        r4 /* inNewUnderlay */);

		/* Blit, 710-711. Faster scales via nqd_bitblt_scaled, Fastest uses
		 * 1:1 nqd_bitblt. Async requests complete synchronously. */
		case kDSpBlit_Faster:                                      /* sub-op 710 */
			return (uint32_t)DSpBlit_FasterHandler(r3 /* inBlitInfo */,
			                                       r4 /* inAsyncFlag */);
		case kDSpBlit_Fastest:                                     /* sub-op 711 */
			return (uint32_t)DSpBlit_FastestHandler(r3 /* inBlitInfo */,
			                                        r4 /* inAsyncFlag */);

		/* Flatten / Restore, 739-741. Only pre-Active state is serialized.
		 * A magic/version mismatch on Restore returns kDSpContextNotFoundErr
		 * (DSp p.22). */
		case kDSpContext_Flatten:                                  /* sub-op 739 */
			return (uint32_t)DSpContext_FlattenHandler(r3 /* ctxRef */,
			                                           r4 /* outFlatContext */);
		case kDSpContext_GetFlattenedSize:                         /* sub-op 740 */
			return (uint32_t)DSpContext_GetFlattenedSizeHandler(r3 /* ctxRef */,
			                                                    r4 /* outSize */);
		case kDSpContext_Restore:                                  /* sub-op 741 */
			return (uint32_t)DSpContext_RestoreHandler(r3 /* inFlatContext */,
			                                           r4 /* outRestoredContext */);

		/* Queue / Switch, 742-743 (DSp pp.26-27). */
		case kDSpContext_Queue:                                    /* sub-op 742 */
			return (uint32_t)DSpContext_QueueHandler(r3 /* parentCtx */,
			                                         r4 /* childCtx */,
			                                         r5 /* inDesiredAttributes */);
		case kDSpContext_Switch:                                   /* sub-op 743 */
			return (uint32_t)DSpContext_SwitchHandler(r3 /* oldCtx */,
			                                          r4 /* newCtx */);

		default:
			DSP_LOG("DSpDispatch: unknown sub-opcode %u - returning kDSpInternalErr",
			        (unsigned)subop);
			return (uint32_t)kDSpInternalErr;
	}
}
