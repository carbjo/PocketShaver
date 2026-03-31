/*
 *  dsp_thunks.cpp - DrawSprocket PPC-to-native thunk allocation
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Allocates PPC-callable TVECTs in SheepMem for all 54 DrawSprocket
 *  functions. Each TVECT writes a sub-opcode to a scratch word then
 *  executes NATIVE_DSP_DISPATCH to reach the native handler.
 *
 *  Pattern is identical to gl_thunks.cpp / rave_thunks.cpp. Each TVECT
 *  is a proper PPC transition vector: 8-byte header (code_ptr, TOC)
 *  followed by thunk code.
 */

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "thunks.h"
#include "dsp_engine.h"

// Storage for TVECT addresses and scratch word
uint32_t dsp_method_tvects[DSP_MAX_SUBOPCODE];
uint32_t dsp_scratch_addr = 0;

/*
 *  Allocate a single DSp TVECT thunk in SheepMem
 *
 *  Layout is identical to AllocateGLTVECT (32 bytes):
 *    +0:  code_ptr (= base + 8)
 *    +4:  TOC (= 0)
 *    +8:  lis   r11, scratch_hi16
 *   +12:  ori   r11, r11, scratch_lo16
 *   +16:  li    r12, method_id
 *   +20:  stw   r12, 0(r11)
 *   +24:  <dsp_opcode>    -- NATIVE_DSP_DISPATCH
 *   +28:  blr
 */
static uint32 AllocateDSpTVECT(int method_id, uint32 dsp_opcode)
{
	uint32 scratch_hi = (dsp_scratch_addr >> 16) & 0xFFFF;
	uint32 scratch_lo = dsp_scratch_addr & 0xFFFF;

	uint32 base = SheepMem::ReserveProc(32);
	uint32 code = base + 8;

	// TVECT header
	WriteMacInt32(base + 0, code);
	WriteMacInt32(base + 4, 0);

	const uint32 r11 = 11;
	const uint32 r12 = 12;

	// lis r11, scratch_hi16
	WriteMacInt32(code + 0, 0x3C000000 | (r11 << 21) | (scratch_hi & 0xFFFF));
	// ori r11, r11, scratch_lo16
	WriteMacInt32(code + 4, 0x60000000 | (r11 << 21) | (r11 << 16) | (scratch_lo & 0xFFFF));
	// li r12, method_id
	WriteMacInt32(code + 8, 0x38000000 | (r12 << 21) | (method_id & 0xFFFF));
	// stw r12, 0(r11)
	WriteMacInt32(code + 12, 0x90000000 | (r12 << 21) | (r11 << 16));
	// NATIVE_DSP_DISPATCH opcode
	WriteMacInt32(code + 16, dsp_opcode);
	// blr
	WriteMacInt32(code + 20, 0x4E800020);

	return base;
}

/*
 *  Initialize all DSp TVECTs
 *
 *  Called from ThunksInit() after GLThunksInit().
 */
void DSpThunksInit(void)
{
	// Allocate scratch word for sub-opcode passing
	dsp_scratch_addr = SheepMem::Reserve(4);
	WriteMacInt32(dsp_scratch_addr, 0);

	// Get the native opcode for DSp dispatch
	uint32 dsp_opcode = NativeOpcode(NATIVE_DSP_DISPATCH);

	// Clear the tvects array
	memset(dsp_method_tvects, 0, sizeof(dsp_method_tvects));

	// Allocate one TVECT per DrawSprocket sub-opcode (0 to DSP_SUB_COUNT-1)
	for (int i = 0; i < DSP_SUB_COUNT; i++) {
		dsp_method_tvects[i] = AllocateDSpTVECT(i, dsp_opcode);
	}

	DSP_LOG("DSpThunksInit: allocated %d TVECTs (%d bytes), scratch at 0x%08x",
	        DSP_SUB_COUNT, DSP_SUB_COUNT * 32, dsp_scratch_addr);
}
