/*
 *  dsp_thunks.cpp - DSp PPC-to-native thunk allocation
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  One TVECT per DSp sub-opcode. Each stub stores its sub-opcode in a
 *  scratch word and traps to NATIVE_DSP_DISPATCH, like the RAVE thunks.
 */

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "thunks.h"
#include "dsp_engine.h"
#include "dsp_draw_context.h"
#include "dsp_alt_buffer.h"
#include "dsp_guest_port_storage.h"

#include <cstring>

/* Indexed by sub-opcode; DSpInstallHooks patches exports to branch here. */
uint32_t dsp_method_tvects[DSP_MAX_SUBOPCODE] = {};

/* The stubs store the sub-opcode at +0. DSpDispatch must read it from
 * here, not from r3, which holds the guest's first argument.
 * Layout: [0..3] sub-opcode, [4..7] spare, [8..15] diagnostic. */
uint32_t dsp_scratch_addr = 0;
uint32_t dsp_guest_port_storage_addr = 0;

/*
 *  Layout (32 bytes):
 *    +0:  code_ptr (= base + 8, points to first instruction)
 *    +4:  TOC (= 0, unused)
 *    +8:  lis   r11, scratch_hi16
 *   +12:  ori   r11, r11, scratch_lo16
 *   +16:  li    r12, method_id
 *   +20:  stw   r12, 0(r11)
 *   +24:  <dsp_opcode>               -- NATIVE_DSP_DISPATCH
 *   +28:  blr
 *
 *  Only r11/r12 (volatile) are used, so r3-r10 still hold the guest
 *  arguments. Returns the TVECT address, not the code address.
 */
static uint32 AllocateDSpTVECT(int method_id, uint32 dsp_opcode)
{
	uint32 scratch_hi = (dsp_scratch_addr >> 16) & 0xFFFF;
	uint32 scratch_lo = dsp_scratch_addr & 0xFFFF;

	uint32 base = SheepMem::ReserveProc(32);
	uint32 code = base + 8;

	WriteMacInt32(base + 0, code);
	WriteMacInt32(base + 4, 0);

	const uint32 r11 = 11;
	const uint32 r12 = 12;

	/* lis r11, scratch_hi16 */
	WriteMacInt32(code + 0, 0x3C000000 | (r11 << 21) | (scratch_hi & 0xFFFF));

	/* ori r11, r11, scratch_lo16 */
	WriteMacInt32(code + 4, 0x60000000 | (r11 << 21) | (r11 << 16) | (scratch_lo & 0xFFFF));

	/* li r12, method_id */
	WriteMacInt32(code + 8, 0x38000000 | (r12 << 21) | (method_id & 0xFFFF));

	/* stw r12, 0(r11) */
	WriteMacInt32(code + 12, 0x90000000 | (r12 << 21) | (r11 << 16) | (0 & 0xFFFF));

	/* NATIVE_DSP_DISPATCH opcode */
	WriteMacInt32(code + 16, dsp_opcode);

	/* blr */
	WriteMacInt32(code + 20, 0x4E800020);

	return base;
}

void DSpThunksInit(void)
{
	// Allocate before any guest callback can hold SheepVar temporaries. Port
	// creation later only reuses slots and never grows the LIFO stack.
	dsp_guest_port_storage_addr = SheepMem::Reserve(
	    (2 * DSP_MAX_CONTEXTS + DSP_MAX_ALT_BUFFERS) * DSpGuestPortStorageBytes);
	dsp_scratch_addr = SheepMem::Reserve(16);
	WriteMacInt32(dsp_scratch_addr, 0);

	/* NativeOpcode() exists only with EMULATED_PPC. Without it the stubs are
	 * never executed, so 0 is a safe placeholder. */
#if EMULATED_PPC
	uint32 dsp_opcode = NativeOpcode(NATIVE_DSP_DISPATCH);
#else
	uint32 dsp_opcode = 0;
#endif

	std::memset(dsp_method_tvects, 0, sizeof(dsp_method_tvects));

	int tvect_count = 0;

	/* The sub-opcode space is sparse, so each contiguous band gets its own
	 * loop. Gaps (400-401, 501-502) are not PEF exports. */

	/* 0-2: Startup, Shutdown, GetVersion. Apps probe DSpStartup first (p.10). */
	for (int op = kDSpStartup; op <= kDSpGetVersion; op++) {
		uint32 tvect = AllocateDSpTVECT(op, dsp_opcode);
		if (tvect == 0) {
			DSP_LOG("DSpThunksInit: TVECT alloc failed for subop %d", op);
			continue;
		}
		dsp_method_tvects[op] = tvect;
		tvect_count++;
	}

	/* 100-106: context lifecycle. */
	for (int op = kDSpContext_Reserve;
	     op <= kDSpContext_InvalBackBufferRect; op++) {
		uint32 tvect = AllocateDSpTVECT(op, dsp_opcode);
		if (tvect == 0) {
			DSP_LOG("DSpThunksInit: TVECT alloc failed for subop %d", op);
			continue;
		}
		dsp_method_tvects[op] = tvect;
		tvect_count++;
	}

	/* 200-202: GetFirstContext, FindBestContext, GetAttributes. */
	for (int op = kDSpGetFirstContext;
	     op <= kDSpContext_GetAttributes; op++) {
		uint32 tvect = AllocateDSpTVECT(op, dsp_opcode);
		if (tvect == 0) {
			DSP_LOG("DSpThunksInit: TVECT alloc failed for subop %d", op);
			continue;
		}
		dsp_method_tvects[op] = tvect;
		tvect_count++;
	}

	/* 203: GetNextContext. */
	for (int op = kDSpGetNextContext; op <= kDSpGetNextContext; op++) {
		uint32 tvect = AllocateDSpTVECT(op, dsp_opcode);
		if (tvect == 0) {
			DSP_LOG("DSpThunksInit: TVECT alloc failed for subop %d", op);
			continue;
		}
		dsp_method_tvects[op] = tvect;
		tvect_count++;
	}

	/* 300-301: CLUT entries. */
	for (int op = kDSpContext_SetCLUTEntries;
	     op <= kDSpContext_GetCLUTEntries; op++) {
		uint32 tvect = AllocateDSpTVECT(op, dsp_opcode);
		if (tvect == 0) {
			DSP_LOG("DSpThunksInit: TVECT alloc failed for subop %d", op);
			continue;
		}
		dsp_method_tvects[op] = tvect;
		tvect_count++;
	}

	/* 402-404: FadeGammaIn, FadeGammaOut, FadeGamma. */
	for (int op = kDSpContext_FadeGammaIn;
	     op <= kDSpContext_FadeGamma; op++) {
		uint32 tvect = AllocateDSpTVECT(op, dsp_opcode);
		if (tvect == 0) {
			DSP_LOG("DSpThunksInit: TVECT alloc failed for subop %d", op);
			continue;
		}
		dsp_method_tvects[op] = tvect;
		tvect_count++;
	}

	/* 500: SetVBLProc. 503: GetVBLProc, internal only (not a PEF export). */
	for (int op = kDSpContext_SetVBLProc;
	     op <= kDSpContext_SetVBLProc; op++) {
		uint32 tvect = AllocateDSpTVECT(op, dsp_opcode);
		if (tvect == 0) {
			DSP_LOG("DSpThunksInit: TVECT alloc failed for subop %d", op);
			continue;
		}
		dsp_method_tvects[op] = tvect;
		tvect_count++;
	}
	for (int op = kDSpContext_GetVBLProc;
	     op <= kDSpContext_GetVBLProc; op++) {
		uint32 tvect = AllocateDSpTVECT(op, dsp_opcode);
		if (tvect == 0) {
			DSP_LOG("DSpThunksInit: TVECT alloc failed for subop %d", op);
			continue;
		}
		dsp_method_tvects[op] = tvect;
		tvect_count++;
	}

	/* 700-761: AltBuffers, Blit, coords/mouse, queries, flatten/queue,
	 * ProcessEvent, blanking/debug. */
	for (int op = kDSpAltBuffer_New;
	     op <= kDSpContext_SetUnderlayAltBuffer; op++) {       /* 700..705 */
		uint32 tvect = AllocateDSpTVECT(op, dsp_opcode);
		if (tvect == 0) {
			DSP_LOG("DSpThunksInit: TVECT alloc failed for subop %d", op);
			continue;
		}
		dsp_method_tvects[op] = tvect;
		tvect_count++;
	}
	for (int op = kDSpBlit_Faster;
	     op <= kDSpBlit_Fastest; op++) {                        /* 710..711 */
		uint32 tvect = AllocateDSpTVECT(op, dsp_opcode);
		if (tvect == 0) {
			DSP_LOG("DSpThunksInit: TVECT alloc failed for subop %d", op);
			continue;
		}
		dsp_method_tvects[op] = tvect;
		tvect_count++;
	}
	for (int op = kDSpGetMouse;
	     op <= kDSpFindContextFromPoint; op++) {                /* 720..723 */
		uint32 tvect = AllocateDSpTVECT(op, dsp_opcode);
		if (tvect == 0) {
			DSP_LOG("DSpThunksInit: TVECT alloc failed for subop %d", op);
			continue;
		}
		dsp_method_tvects[op] = tvect;
		tvect_count++;
	}
	for (int op = kDSpContext_IsBusy;
	     op <= kDSpUserSelectContext; op++) {                   /* 730..747 */
		uint32 tvect = AllocateDSpTVECT(op, dsp_opcode);
		if (tvect == 0) {
			DSP_LOG("DSpThunksInit: TVECT alloc failed for subop %d", op);
			continue;
		}
		dsp_method_tvects[op] = tvect;
		tvect_count++;
	}
	for (int op = kDSpProcessEvent;
	     op <= kDSpProcessEvent; op++) {                        /* 750 */
		uint32 tvect = AllocateDSpTVECT(op, dsp_opcode);
		if (tvect == 0) {
			DSP_LOG("DSpThunksInit: TVECT alloc failed for subop %d", op);
			continue;
		}
		dsp_method_tvects[op] = tvect;
		tvect_count++;
	}
	for (int op = kDSpSetBlankingColor;
	     op <= kDSpSetDebugMode; op++) {                        /* 760..761 */
		uint32 tvect = AllocateDSpTVECT(op, dsp_opcode);
		if (tvect == 0) {
			DSP_LOG("DSpThunksInit: TVECT alloc failed for subop %d", op);
			continue;
		}
		dsp_method_tvects[op] = tvect;
		tvect_count++;
	}

	DSP_LOG("DSpThunksInit: %d TVECTs allocated (sub-opcodes %d..%d + %d..%d + %d..%d + %d..%d + %d..%d + %d..%d + %d + %d + %d..%d + %d..%d + %d..%d + %d..%d + %d + %d..%d), "
	        "scratch at 0x%08x",
	        tvect_count,
	        (int)kDSpStartup,
	        (int)kDSpGetVersion,
	        (int)kDSpContext_Reserve,
	        (int)kDSpContext_InvalBackBufferRect,
	        (int)kDSpGetFirstContext,
	        (int)kDSpContext_GetAttributes,
	        (int)kDSpGetNextContext,
	        (int)kDSpGetNextContext,
	        (int)kDSpContext_SetCLUTEntries,
	        (int)kDSpContext_GetCLUTEntries,
	        (int)kDSpContext_FadeGammaIn,
	        (int)kDSpContext_FadeGamma,
	        (int)kDSpContext_SetVBLProc,
	        (int)kDSpContext_GetVBLProc,
	        (int)kDSpAltBuffer_New,
	        (int)kDSpContext_SetUnderlayAltBuffer,
	        (int)kDSpBlit_Faster,
	        (int)kDSpBlit_Fastest,
	        (int)kDSpGetMouse,
	        (int)kDSpFindContextFromPoint,
	        (int)kDSpContext_IsBusy,
	        (int)kDSpUserSelectContext,
	        (int)kDSpProcessEvent,
	        (int)kDSpSetBlankingColor,
	        (int)kDSpSetDebugMode,
	        (unsigned)dsp_scratch_addr);
}

