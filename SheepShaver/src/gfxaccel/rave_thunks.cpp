/*
 *  rave_thunks.cpp - RAVE PPC-to-native thunk allocation
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  Allocates PPC-callable TVECTs in SheepMem for RAVE methods. Each thunk
 *  stores a sub-opcode in a scratch word and executes NATIVE_RAVE_DISPATCH.
 *  CFM callers (including the RAVE manager) expect TVECT pointers, so each
 *  has the 8-byte {code_ptr, TOC} header.
 */

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "thunks.h"
#include "rave_engine.h"

// Storage for TVECT addresses and scratch word
uint32_t rave_method_tvects[RAVE_MAX_SUBOPCODE];
uint32_t rave_scratch_addr = 0;

// Sentinel engine handle and saved original TVECTs (set by RaveInstallHooks)
uint32_t rave_sentinel_engine = 0;
uint32_t rave_orig_get_first_engine = 0;
uint32_t rave_orig_get_next_engine = 0;
uint32_t rave_orig_engine_gestalt = 0;
uint32_t rave_orig_engine_check_device = 0;
uint32_t rave_orig_draw_context_new = 0;
uint32_t rave_orig_texture_new = 0;
uint32_t rave_orig_bitmap_new = 0;
uint32_t rave_orig_color_table_new = 0;
uint32_t rave_orig_draw_context_delete = 0;
uint32_t rave_orig_texture_delete = 0;
uint32_t rave_orig_bitmap_delete = 0;
uint32_t rave_orig_color_table_delete = 0;
uint32_t rave_orig_texture_bind_color_table = 0;
uint32_t rave_orig_bitmap_bind_color_table = 0;
uint32_t rave_orig_texture_detach = 0;
uint32_t rave_orig_bitmap_detach = 0;
uint32_t rave_orig_access_texture = 0;
uint32_t rave_orig_access_texture_end = 0;
uint32_t rave_orig_access_bitmap = 0;
uint32_t rave_orig_access_bitmap_end = 0;
uint32_t rave_orig_engine_enable = 0;
uint32_t rave_orig_engine_disable = 0;

/*
 *  Allocate one RAVE TVECT thunk (32 bytes). Returns the TVECT address, not
 *  the code address.
 *    +0:  code_ptr (= base + 8)
 *    +4:  TOC (0, unused)
 *    +8:  lis   r11, scratch_hi16
 *   +12:  ori   r11, r11, scratch_lo16
 *   +16:  li    r12, method_id
 *   +20:  stw   r12, 0(r11)
 *   +24:  NATIVE_RAVE_DISPATCH
 *   +28:  blr
 *
 *  r11/r12 are volatile scratch, so r3-r10 (the RAVE method args) survive.
 *  r0 cannot be the stw base: rA=0 means literal 0.
 */
static uint32 AllocateRaveTVECT(int method_id, uint32 rave_opcode)
{
	uint32 scratch_hi = (rave_scratch_addr >> 16) & 0xFFFF;
	uint32 scratch_lo = rave_scratch_addr & 0xFFFF;

	// Reserve 32 bytes: 8-byte TVECT header + 24 bytes (6 instructions)
	uint32 base = SheepMem::ReserveProc(32);
	uint32 code = base + 8;

	// Write TVECT header: {code_ptr, TOC}
	WriteMacInt32(base + 0, code);	// Code pointer -> first instruction
	WriteMacInt32(base + 4, 0);		// TOC (unused)

	// PPC instruction encodings:
	// lis rD, imm     = addis rD, 0, imm = 0x3C000000 | (rD << 21) | (imm & 0xFFFF)
	// ori rS, rA, imm = 0x60000000 | (rS << 21) | (rA << 16) | (imm & 0xFFFF)
	// li rD, imm      = addi rD, 0, imm  = 0x38000000 | (rD << 21) | (imm & 0xFFFF)
	// stw rS, d(rA)   = 0x90000000 | (rS << 21) | (rA << 16) | (d & 0xFFFF)

	const uint32 r11 = 11;
	const uint32 r12 = 12;

	// lis r11, scratch_hi16
	WriteMacInt32(code + 0, 0x3C000000 | (r11 << 21) | (scratch_hi & 0xFFFF));

	// ori r11, r11, scratch_lo16
	WriteMacInt32(code + 4, 0x60000000 | (r11 << 21) | (r11 << 16) | (scratch_lo & 0xFFFF));

	// li r12, method_id
	WriteMacInt32(code + 8, 0x38000000 | (r12 << 21) | (method_id & 0xFFFF));

	// stw r12, 0(r11)
	WriteMacInt32(code + 12, 0x90000000 | (r12 << 21) | (r11 << 16) | (0 & 0xFFFF));

	// NATIVE_RAVE_DISPATCH opcode
	WriteMacInt32(code + 16, rave_opcode);

	// blr
	WriteMacInt32(code + 20, 0x4E800020);

	return base;
}

/* Initialize all RAVE TVECTs */
void RaveThunksInit(void)
{
	// Scratch block: [0..3] sub-opcode, [4..7] spare, [8..15] TQADevice,
	// [16..19] gestalt response.
	rave_scratch_addr = SheepMem::Reserve(32);
	WriteMacInt32(rave_scratch_addr, 0);

	// One guest handle word per resource-table slot, reserved up front so
	// texture/bitmap/color-table creation never touches the SheepMem stack.
	rave_resource_addr_base = SheepMem::Reserve(RAVE_MAX_RESOURCES * 4);

	uint32 rave_opcode = NativeOpcode(NATIVE_RAVE_DISPATCH);

	memset(rave_method_tvects, 0, sizeof(rave_method_tvects));

	int tvect_count = 0;

	// Allocate TVECTs for 35 draw methods (sub-opcodes 0-34)
	for (int i = 0; i < kRaveDrawMethodCount; i++) {
		rave_method_tvects[i] = AllocateRaveTVECT(i, rave_opcode);
		tvect_count++;
	}

	// Allocate TVECTs for 18 engine methods (sub-opcodes 100-117)
	for (int i = 0; i < kRaveEngineMethodCount; i++) {
		int method_id = kRaveEngineDrawPrivateNew + i;
		rave_method_tvects[method_id] = AllocateRaveTVECT(method_id, rave_opcode);
		tvect_count++;
	}

	// Hook thunks (sub-opcodes 200+). The native handler does the sentinel
	// check and chains to the original if needed.
	for (int i = 0; i < kRaveHookCount; i++) {
		int method_id = kRaveHookGetFirstEngine + i;
		rave_method_tvects[method_id] = AllocateRaveTVECT(method_id, rave_opcode);
		tvect_count++;
	}

	// ATI RaveExtFuncs thunks (sub-opcodes 300+)
	for (int i = 0; i < kRaveATIMethodCount; i++) {
		int method_id = kRaveATIClearDrawBuffer + i;
		rave_method_tvects[method_id] = AllocateRaveTVECT(method_id, rave_opcode);
		tvect_count++;
	}

	// Sentinel TQAEngine struct. An unhooked API taking a TQAEngine* (e.g.
	// QATextureDetach, QAAccessTexture) runs the manager's own code, which reads
	// method TVECTs at fixed offsets. Observed layout (TextureDetach, tag 5,
	// loads 0x24(engine), so the header is 16 bytes):
	//   +0x00 magic, +0x04 GetMethod TVECT, +0x08 refCon, +0x0C internal
	//   +0x10 + tag*4: engine method TVECT for tag N (tag 17 at +0x54)
	// 0x58 bytes are needed. 128 are allocated and every slot holds a valid
	// TVECT, so any offset read returns a callable pointer.
	#define RAVE_SENTINEL_SIZE 128
	#define RAVE_ENGINE_METHOD_TABLE_OFFSET 0x10

	rave_sentinel_engine = SheepMem::Reserve(RAVE_SENTINEL_SIZE);
	memset(Mac2HostAddr(rave_sentinel_engine), 0, RAVE_SENTINEL_SIZE);
	WriteMacInt32(rave_sentinel_engine, RAVE_ENGINE_MAGIC);

	// Store GetMethod TVECT at offset +4 (common layout for engine struct)
	WriteMacInt32(rave_sentinel_engine + 4,
	              rave_method_tvects[kRaveEngineDrawPrivateNew]);

	// Populate method table at offset 0x10: tag N -> rave_method_tvects[100+N]
	for (int tag = 0; tag < kRaveEngineMethodCount; tag++) {
		uint32 tvect = rave_method_tvects[kRaveEngineDrawPrivateNew + tag];
		WriteMacInt32(rave_sentinel_engine + RAVE_ENGINE_METHOD_TABLE_OFFSET + tag * 4,
		              tvect);
	}

	// Fill the remaining zero slots too, in case the header-size guess is wrong:
	// worst case a wrong method, not a crash. Offset 0 holds the magic.
	uint32 fallback_tvect = rave_method_tvects[kRaveEngineDrawPrivateNew];
	for (uint32 off = 4; off < RAVE_SENTINEL_SIZE; off += 4) {
		if (ReadMacInt32(rave_sentinel_engine + off) == 0)
			WriteMacInt32(rave_sentinel_engine + off, fallback_tvect);
	}

	RAVE_LOG("RaveThunksInit: allocated %d TVECTs, scratch at 0x%08x, sentinel at 0x%08x",
			 tvect_count, rave_scratch_addr, rave_sentinel_engine);

	// TVECT diagnostic dump
	if (rave_logging_enabled) {
		printf("RAVE ThunksInit: scratch=0x%08x, rave_opcode=0x%08x\n",
		       rave_scratch_addr, rave_opcode);
		for (int i = 0; i < kRaveDrawMethodCount; i++) {
			uint32 base = rave_method_tvects[i];
			uint32 code = ReadMacInt32(base);       // code_ptr at TVECT[0]
			uint32 instr = ReadMacInt32(code);       // first instruction
			printf("  draw[%2d] TVECT=0x%08x code=0x%08x instr=0x%08x\n",
			       i, base, code, instr);
		}
	}
}
