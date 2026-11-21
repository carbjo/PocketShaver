/*
 *  gl_thunks.cpp - OpenGL PPC-to-native thunk allocation
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  PPC TVECTs in SheepMem for every GL/AGL/GLU/GLUT entry point. Each one
 *  stores its sub-opcode to a scratch word and executes
 *  NATIVE_OPENGL_DISPATCH. Same layout as rave_thunks.cpp.
 */

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "thunks.h"
#include "gl_engine.h"
#include "gl_defer.h"
#include "gl_ppc_emit.h"
#include <cassert>

uint32_t gl_method_tvects[GL_MAX_SUBOPCODE];
uint32_t gl_scratch_addr = 0;

// Dispatch-table TVECTs: the game passes the context index in r3, so the real
// GL args start at r4.
uint32_t gl_dt_method_tvects[GL_MAX_SUBOPCODE];

// Logging no-op TVECTs for context-handle dispatch slots with no real GL
// function, so a game reading an unmapped slot does not jump through
// uninitialized guest heap. Sub-opcode is GL_DT_DIAG_BASE + slot.
uint32_t gl_dt_diag_tvects[GL_CTX_DISPATCH_SLOTS];

// Calling-convention flag. Stub TVECTs (FindLibSymbol) take args from r3;
// dispatch-table TVECTs set it to 1 and take args from r4. gl_dispatch.cpp
// uses it for the register base and for the stack-arg offset of 9+ argument
// calls (glTexImage2D etc.). Emul thread only.
uint32_t gl_dt_flag_addr = 0;  // 1 = dispatch-table call, 0 = stub call

/*
 *  Per-sub-opcode argument types. float_mask bit N set means arg N arrives in
 *  an FPR (f1..f13) rather than a GPR (r3..r10). Unlisted functions default
 *  to all-integer.
 */
GLFuncSignature gl_func_signatures[GL_MAX_SUBOPCODE];

/*
 *  Plain GL TVECT, same as AllocateRaveTVECT (32 bytes):
 *    +0:  code_ptr (= base + 8)
 *    +4:  TOC (= 0)
 *    +8:  lis   r11, scratch_hi16
 *   +12:  ori   r11, r11, scratch_lo16
 *   +16:  li    r12, method_id
 *   +20:  stw   r12, 0(r11)
 *   +24:  <gl_opcode>    -- NATIVE_OPENGL_DISPATCH
 *   +28:  blr
 */
static uint32 AllocateGLTVECT(int method_id, uint32 gl_opcode)
{
	uint32 scratch_hi = (gl_scratch_addr >> 16) & 0xFFFF;
	uint32 scratch_lo = gl_scratch_addr & 0xFFFF;

	uint32 base = SheepMem::ReserveProc(32);
	uint32 code = base + 8;

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
	// NATIVE_OPENGL_DISPATCH opcode
	WriteMacInt32(code + 16, gl_opcode);
	// blr
	WriteMacInt32(code + 20, 0x4E800020);

	return base;
}

/*
 *  Dispatch-table TVECT: as above, but first stores 1 to gl_dt_flag_addr so
 *  the handler reads args from r4. Layout (48 bytes):
 *    +0:  code_ptr (= base + 8)
 *    +4:  TOC (= 0)
 *    +8:  lis   r11, flag_hi16
 *   +12:  ori   r11, r11, flag_lo16
 *   +16:  li    r12, 1
 *   +20:  stw   r12, 0(r11)          -- set flag = 1
 *   +24:  lis   r11, scratch_hi16
 *   +28:  ori   r11, r11, scratch_lo16
 *   +32:  li    r12, method_id
 *   +36:  stw   r12, 0(r11)          -- write sub-opcode
 *   +40:  <gl_opcode>                -- NATIVE_OPENGL_DISPATCH
 *   +44:  blr
 */
static uint32 AllocateGLDispatchTableTVECT(int method_id, uint32 gl_opcode)
{
	uint32 flag_hi = (gl_dt_flag_addr >> 16) & 0xFFFF;
	uint32 flag_lo = gl_dt_flag_addr & 0xFFFF;
	uint32 scratch_hi = (gl_scratch_addr >> 16) & 0xFFFF;
	uint32 scratch_lo = gl_scratch_addr & 0xFFFF;

	uint32 base = SheepMem::ReserveProc(48);
	uint32 code = base + 8;

	WriteMacInt32(base + 0, code);
	WriteMacInt32(base + 4, 0);

	const uint32 r11 = 11;
	const uint32 r12 = 12;

	// Set dispatch-table flag = 1
	WriteMacInt32(code + 0, 0x3C000000 | (r11 << 21) | (flag_hi & 0xFFFF));       // lis r11, flag_hi
	WriteMacInt32(code + 4, 0x60000000 | (r11 << 21) | (r11 << 16) | (flag_lo & 0xFFFF)); // ori r11, r11, flag_lo
	WriteMacInt32(code + 8, 0x38000000 | (r12 << 21) | 1);                        // li r12, 1
	WriteMacInt32(code + 12, 0x90000000 | (r12 << 21) | (r11 << 16));             // stw r12, 0(r11)

	// Write sub-opcode to scratch
	WriteMacInt32(code + 16, 0x3C000000 | (r11 << 21) | (scratch_hi & 0xFFFF));   // lis r11, scratch_hi
	WriteMacInt32(code + 20, 0x60000000 | (r11 << 21) | (r11 << 16) | (scratch_lo & 0xFFFF)); // ori r11, r11, scratch_lo
	WriteMacInt32(code + 24, 0x38000000 | (r12 << 21) | (method_id & 0xFFFF));    // li r12, method_id
	WriteMacInt32(code + 28, 0x90000000 | (r12 << 21) | (r11 << 16));             // stw r12, 0(r11)

	// NATIVE_OPENGL_DISPATCH opcode
	WriteMacInt32(code + 32, gl_opcode);
	// blr
	WriteMacInt32(code + 36, 0x4E800020);

	return base;
}

/*
 *  Shared fallback for deferrable stubs when deferral is off or the ring is
 *  full. Stubs `b` here (+/-32 MiB) with the sub-opcode in r12, and the call
 *  traps normally. That is enough on its own: GLDispatch drains the ring
 *  before handling the trapped call.
 *
 *  This is the tail of AllocateGLTVECT. It is a branch target, not a callee,
 *  so it has no TVECT header; gl_defer_common_tail holds the address of the
 *  first instruction.
 *
 *    lis  r11, scratch_hi16
 *    ori  r11, r11, scratch_lo16
 *    stw  r12, 0(r11)
 *    <gl_opcode>
 *    blr
 */
static void EmitDeferFallback(uint32 gl_opcode)
{
	uint32 scratch_hi = (gl_scratch_addr >> 16) & 0xFFFF;
	uint32 scratch_lo = gl_scratch_addr & 0xFFFF;

	uint32 code = SheepMem::ReserveProc(5 * 4);

	const int r11 = 11;
	const int r12 = 12;

	WriteMacInt32(code +  0, ppc_lis(r11, scratch_hi));            // lis  r11, scratch_hi
	WriteMacInt32(code +  4, ppc_ori(r11, r11, scratch_lo));       // ori  r11, r11, scratch_lo
	WriteMacInt32(code +  8, ppc_stw(r12, 0, r11));                // stw  r12, 0(r11)
	WriteMacInt32(code + 12, gl_opcode);                          // NATIVE_OPENGL_DISPATCH
	WriteMacInt32(code + 16, ppc_blr());                          // blr

	gl_defer_common_tail = code;
}

/*
 *  Capture stub for a deferrable opcode, used in place of AllocateGLTVECT.
 *  A real TVECT (the game calls it as the GL function). When deferral is
 *  enabled and the ring has room it appends the call's args to the guest ring
 *  and returns without trapping; otherwise it branches to
 *  gl_defer_common_tail.
 *
 *  Registers: args in r3.. and f1.. (dense). r12 holds the sub-opcode until
 *  the commit, since the fallback needs it. Only r0, r11 and r12 are
 *  clobbered, none of which carry args. The commit uses r12, not r0, as the
 *  value temp because addi with RA=0 means literal 0.
 *
 *  Record layout (must match GLDeferDecodeRecord):
 *    [u32 sub_opcode][u32 size_bytes][scalar x u32 from r3..]
 *    [fpr_count x f32 from f1.. via stfs][round_up_4(ptr_bytes) snapshot]
 */
static int gl_round_up_4(int n) { return (n + 3) & ~3; }
static int gl_popcount16(uint32 v) { int n = 0; while (v) { n += (v & 1u); v >>= 1; } return n; }

static uint32 EmitDeferStub(int sub_opcode, const GLDeferDesc &desc, uint32 gl_opcode)
{
	const int scalar  = desc.scalar_gpr_count;
	const int fprc    = gl_popcount16(desc.fpr_mask);
	const int ptrb    = desc.ptr_bytes;
	const int ptr_pad = gl_round_up_4(ptrb);
	const int need    = 8 + 4 * scalar + 4 * fprc + ptr_pad;   // size_bytes header value

	// Copy the pointer payload as words, then a halfword, then a byte.
	const int ptr_words = ptrb / 4;
	int rem = ptrb - ptr_words * 4;
	const bool ptr_half = (rem >= 2);
	if (ptr_half) rem -= 2;
	const bool ptr_byte = (rem >= 1);

	// Instruction count; must be exact (asserted below).
	//   li r12              : 1
	//   enabled: lis,ori,lwz,cmpwi,bne,b   : 6
	//   space:   lis,ori,lwz,cmplwi,ble,b  : 6
	//   wptr:    lis,ori,add               : 3
	//   header:  stw r12; li r0; stw r0    : 3
	//   scalars                            : scalar
	//   fprs                               : fprc
	//   ptr:     (lwz+stw) per word + (lhz+sth) + (lbz+stb)
	//   commit:  head(lis,ori,lwz,addi,stw)+count(lis,ori,lwz,addi,stw) : 10
	//   blr                                : 1
	const int ninstr = 1 + 6 + 6 + 3 + 3
	                 + scalar + fprc
	                 + ptr_words * 2 + (ptr_half ? 2 : 0) + (ptr_byte ? 2 : 0)
	                 + 10 + 1;

	const uint32 enabled_hi = (gl_defer_enabled_addr >> 16) & 0xFFFF;
	const uint32 enabled_lo =  gl_defer_enabled_addr        & 0xFFFF;
	const uint32 head_hi    = (gl_defer_head_addr    >> 16) & 0xFFFF;
	const uint32 head_lo    =  gl_defer_head_addr           & 0xFFFF;
	const uint32 count_hi   = (gl_defer_count_addr   >> 16) & 0xFFFF;
	const uint32 count_lo   =  gl_defer_count_addr          & 0xFFFF;
	const uint32 ring_hi    = (gl_defer_ring_base    >> 16) & 0xFFFF;
	const uint32 ring_lo    =  gl_defer_ring_base           & 0xFFFF;

	uint32 base = SheepMem::ReserveProc(8 + 4 * ninstr);
	uint32 code = base + 8;

	WriteMacInt32(base + 0, code);
	WriteMacInt32(base + 4, 0);

	const int r0 = 0, r11 = 11, r12 = 12;

	int idx = 0;
	#define A() (code + 4 * idx)                       // absolute addr of slot idx
	#define EMIT(word) do { WriteMacInt32(code + 4 * idx, (word)); ++idx; } while (0)

	EMIT(ppc_li(r12, sub_opcode));

	// --- enabled check: if (*enabled == 0) goto fallback -----------------------
	EMIT(ppc_lis(r11, enabled_hi));
	EMIT(ppc_ori(r11, r11, enabled_lo));
	EMIT(ppc_lwz(r0, 0, r11));
	EMIT(ppc_cmpwi(r0, 0));
	{ uint32 a = A(); EMIT(ppc_bne(a, a + 8)); }       // r0 != 0 -> skip the long branch
	{ uint32 a = A(); EMIT(ppc_b(a, gl_defer_common_tail)); }  // disabled -> fallback

	// --- space check: if (head >u RING_SIZE-need) goto fallback ----------------
	EMIT(ppc_lis(r11, head_hi));
	EMIT(ppc_ori(r11, r11, head_lo));
	EMIT(ppc_lwz(r0, 0, r11));                          // r0 = head (byte offset)
	EMIT(ppc_cmplwi(r0, (uint32)(GL_DEFER_RING_SIZE - need)));  // UNSIGNED compare
	{ uint32 a = A(); EMIT(ppc_ble(a, a + 8)); }       // head <=u limit -> space ok
	{ uint32 a = A(); EMIT(ppc_b(a, gl_defer_common_tail)); }  // full -> fallback

	// --- write pointer = ring_base + head --------------------------------------
	// r0 still holds head from the space check (untouched above).
	EMIT(ppc_lis(r11, ring_hi));
	EMIT(ppc_ori(r11, r11, ring_lo));
	EMIT(ppc_add(r11, r11, r0));                        // r11 = ring_base + head

	// --- record header ---------------------------------------------------------
	EMIT(ppc_stw(r12, 0, r11));                         // [0] sub_opcode
	EMIT(ppc_li(r0, need));
	EMIT(ppc_stw(r0, 4, r11));                          // [4] size_bytes

	// --- scalar GPRs: r(3+k) -> (8 + 4k)(r11) ----------------------------------
	for (int k = 0; k < scalar; ++k)
		EMIT(ppc_stw(3 + k, 8 + 4 * k, r11));

	// --- FPRs (dense): f(1+n) -> (8 + 4*scalar + 4*n)(r11) ---------------------
	const int fpr_base_off = 8 + 4 * scalar;
	for (int n = 0; n < fprc; ++n)
		EMIT(ppc_stfs(1 + n, fpr_base_off + 4 * n, r11));

	// --- trailing pointer snapshot ---------------------------------------------
	// src ptr arg = r(3+scalar); dst offset = 8 + 4*scalar + 4*fprc.
	if (ptrb > 0) {
		const int src     = 3 + scalar;
		const int dst_off = 8 + 4 * scalar + 4 * fprc;
		int off = 0;
		for (int w = 0; w < ptr_words; ++w, off += 4) {
			EMIT(ppc_lwz(r0, off, src));
			EMIT(ppc_stw(r0, dst_off + off, r11));
		}
		if (ptr_half) {
			EMIT(ppc_lhz(r0, off, src));
			EMIT(ppc_sth(r0, dst_off + off, r11));
			off += 2;
		}
		if (ptr_byte) {
			EMIT(ppc_lbz(r0, off, src));
			EMIT(ppc_stb(r0, dst_off + off, r11));
			off += 1;
		}
	}

	// --- commit: head += need; count += 1 --------------------------------------
	// Value temp must not be r0 (addi RA=0 is literal 0). r12's sub-opcode is
	// dead here.
	EMIT(ppc_lis(r11, head_hi));
	EMIT(ppc_ori(r11, r11, head_lo));
	EMIT(ppc_lwz(r12, 0, r11));
	EMIT(ppc_addi(r12, r12, need));    // r12 = head + need
	EMIT(ppc_stw(r12, 0, r11));

	EMIT(ppc_lis(r11, count_hi));
	EMIT(ppc_ori(r11, r11, count_lo));
	EMIT(ppc_lwz(r12, 0, r11));
	EMIT(ppc_addi(r12, r12, 1));       // r12 = count + 1
	EMIT(ppc_stw(r12, 0, r11));

	EMIT(ppc_blr());

	#undef A
	#undef EMIT

	assert(idx == ninstr && "EmitDeferStub instruction count mismatch");

	return base;
}

// Only functions with float args need entries.
static void InitFuncSignatures()
{
	memset(gl_func_signatures, 0, sizeof(gl_func_signatures));

	#define SIG(sub, nargs, fmask) \
		gl_func_signatures[sub] = { (uint8_t)(nargs), (uint16_t)(fmask) }

	// nargs counts PPC-visible args from r3; the dispatch-table ctx argument
	// is not included.

	// Core GL

	SIG(GL_SUB_ACCUM, 2, 0x02);
	SIG(GL_SUB_ALPHA_FUNC, 2, 0x02);
	SIG(GL_SUB_CLEAR_ACCUM, 4, 0x0F);
	SIG(GL_SUB_CLEAR_COLOR, 4, 0x0F);
	SIG(GL_SUB_CLEAR_DEPTH, 1, 0x01);
	SIG(GL_SUB_CLEAR_INDEX, 1, 0x01);
	SIG(GL_SUB_COLOR3F, 3, 0x07);
	SIG(GL_SUB_COLOR3D, 3, 0x07);
	SIG(GL_SUB_COLOR4F, 4, 0x0F);
	SIG(GL_SUB_COLOR4D, 4, 0x0F);
	SIG(GL_SUB_DEPTH_RANGE, 2, 0x03);
	SIG(GL_SUB_FOGF, 2, 0x02);
	SIG(GL_SUB_FRUSTUM, 6, 0x3F);
	SIG(GL_SUB_INDEXD, 1, 0x01);
	SIG(GL_SUB_INDEXF, 1, 0x01);
	SIG(GL_SUB_LIGHTF, 3, 0x04);
	SIG(GL_SUB_LIGHT_MODELF, 2, 0x02);
	SIG(GL_SUB_LINE_WIDTH, 1, 0x01);
	SIG(GL_SUB_MATERIALF, 3, 0x04);
	SIG(GL_SUB_NORMAL3F, 3, 0x07);
	SIG(GL_SUB_NORMAL3D, 3, 0x07);
	SIG(GL_SUB_ORTHO, 6, 0x3F);
	SIG(GL_SUB_PASS_THROUGH, 1, 0x01);
	SIG(GL_SUB_PIXEL_STOREF, 2, 0x02);
	SIG(GL_SUB_PIXEL_TRANSFERF, 2, 0x02);
	SIG(GL_SUB_PIXEL_ZOOM, 2, 0x03);
	SIG(GL_SUB_POINT_SIZE, 1, 0x01);
	SIG(GL_SUB_POLYGON_OFFSET, 2, 0x03);
	SIG(GL_SUB_ROTATEF, 4, 0x0F);
	SIG(GL_SUB_ROTATED, 4, 0x0F);
	SIG(GL_SUB_SCALEF, 3, 0x07);
	SIG(GL_SUB_SCALED, 3, 0x07);
	SIG(GL_SUB_TEX_COORD1F, 1, 0x01);
	SIG(GL_SUB_TEX_COORD1D, 1, 0x01);
	SIG(GL_SUB_TEX_COORD2F, 2, 0x03);
	SIG(GL_SUB_TEX_COORD2D, 2, 0x03);
	SIG(GL_SUB_TEX_COORD3F, 3, 0x07);
	SIG(GL_SUB_TEX_COORD3D, 3, 0x07);
	SIG(GL_SUB_TEX_COORD4F, 4, 0x0F);
	SIG(GL_SUB_TEX_COORD4D, 4, 0x0F);
	SIG(GL_SUB_TEX_ENVF, 3, 0x04);
	SIG(GL_SUB_TEX_GEND, 3, 0x04);
	SIG(GL_SUB_TEX_GENF, 3, 0x04);
	SIG(GL_SUB_TEX_PARAMETERF, 3, 0x04);
	SIG(GL_SUB_TRANSLATEF, 3, 0x07);
	SIG(GL_SUB_TRANSLATED, 3, 0x07);
	SIG(GL_SUB_VERTEX2F, 2, 0x03);
	SIG(GL_SUB_VERTEX2D, 2, 0x03);
	SIG(GL_SUB_VERTEX3F, 3, 0x07);
	SIG(GL_SUB_VERTEX3D, 3, 0x07);
	SIG(GL_SUB_VERTEX4F, 4, 0x0F);
	SIG(GL_SUB_VERTEX4D, 4, 0x0F);
	SIG(GL_SUB_RECTF, 4, 0x0F);
	SIG(GL_SUB_RECTD, 4, 0x0F);
	SIG(GL_SUB_EVAL_COORD1F, 1, 0x01);
	SIG(GL_SUB_EVAL_COORD1D, 1, 0x01);
	SIG(GL_SUB_EVAL_COORD2F, 2, 0x03);
	SIG(GL_SUB_EVAL_COORD2D, 2, 0x03);
	// bitmap(w, h, xorig, yorig, xmove, ymove, ptr)
	SIG(GL_SUB_BITMAP, 7, 0x3C);
	SIG(GL_SUB_RASTER_POS2F, 2, 0x03);
	SIG(GL_SUB_RASTER_POS2D, 2, 0x03);
	SIG(GL_SUB_RASTER_POS3F, 3, 0x07);
	SIG(GL_SUB_RASTER_POS3D, 3, 0x07);
	SIG(GL_SUB_RASTER_POS4F, 4, 0x0F);
	SIG(GL_SUB_RASTER_POS4D, 4, 0x0F);
	SIG(GL_SUB_CONVOLUTION_PARAMETERF, 3, 0x04);

	// Extensions
	SIG(GL_SUB_BLEND_COLOR_EXT, 4, 0x0F);
	SIG(GL_SUB_BLEND_COLOR_1_2, 4, 0x0F);
	SIG(GL_SUB_SECONDARY_COLOR3F_EXT, 3, 0x07);
	SIG(GL_SUB_SECONDARYCOLOR3D_EXT, 3, 0x07);
	SIG(GL_SUB_MULTI_TEX_COORD1F_ARB, 2, 0x02);
	SIG(GL_SUB_MULTI_TEX_COORD2F_ARB, 3, 0x06);
	SIG(GL_SUB_MULTI_TEX_COORD3F_ARB, 4, 0x0E);
	SIG(GL_SUB_MULTI_TEX_COORD4F_ARB, 5, 0x1E);
	// multi_tex_coord*d_ARB: target is int, the rest double
	SIG(GL_SUB_MULTI_TEX_COORD1D_ARB, 2, 0x02);
	SIG(GL_SUB_MULTI_TEX_COORD2D_ARB, 3, 0x06);
	SIG(GL_SUB_MULTI_TEX_COORD3D_ARB, 4, 0x0E);
	SIG(GL_SUB_MULTI_TEX_COORD4D_ARB, 5, 0x1E);

	// GLU
	SIG(GL_SUB_GLU_PERSPECTIVE, 4, 0x0F);
	SIG(GL_SUB_GLU_LOOKAT, 9, 0x1FF);
	SIG(GL_SUB_GLU_ORTHO2D, 4, 0x0F);
	SIG(GL_SUB_GLU_SPHERE, 4, 0x02);  // quad=ptr, radius=double, slices=int, stacks=int
	SIG(GL_SUB_GLU_CYLINDER, 6, 0x0E);  // quad=ptr, base=dbl, top=dbl, height=dbl, slices=int, stacks=int
	SIG(GL_SUB_GLU_DISK, 5, 0x06);  // quad=ptr, inner=dbl, outer=dbl, slices=int, loops=int
	SIG(GL_SUB_GLU_PICKMATRIX, 5, 0x0F);

	// GLUT
	SIG(GL_SUB_GLUT_WIRESPHERE, 3, 0x01);
	SIG(GL_SUB_GLUT_SOLIDSPHERE, 3, 0x01);
	SIG(GL_SUB_GLUT_WIRECONE, 4, 0x03);
	SIG(GL_SUB_GLUT_SOLIDCONE, 4, 0x03);
	SIG(GL_SUB_GLUT_WIRECUBE, 1, 0x01);
	SIG(GL_SUB_GLUT_SOLIDCUBE, 1, 0x01);
	SIG(GL_SUB_GLUT_WIRETORUS, 4, 0x03);
	SIG(GL_SUB_GLUT_SOLIDTORUS, 4, 0x03);
	SIG(GL_SUB_GLUT_WIRETEAPOT, 1, 0x01);
	SIG(GL_SUB_GLUT_SOLIDTEAPOT, 1, 0x01);
	SIG(GL_SUB_GLUT_SETCOLOR, 4, 0x0E);

	// Evaluators
	SIG(GL_SUB_MAP1F, 6, 0x06);  // target=int, u1=float, u2=float, stride=int, order=int, points=ptr
	SIG(GL_SUB_MAP1D, 6, 0x06);
	SIG(GL_SUB_MAP2F, 10, 0x66);  // args 1,2,5,6
	SIG(GL_SUB_MAP2D, 10, 0x66);
	SIG(GL_SUB_MAP_GRID1F, 3, 0x06);
	SIG(GL_SUB_MAP_GRID1D, 3, 0x06);
	SIG(GL_SUB_MAP_GRID2F, 6, 0x36);  // args 1,2,4,5
	SIG(GL_SUB_MAP_GRID2D, 6, 0x36);

	// More GLU
	SIG(GL_SUB_GLU_PROJECT, 9, 0x07);  // doubles at positions 0,1,2
	SIG(GL_SUB_GLU_UNPROJECT, 9, 0x07);
	SIG(GL_SUB_GLU_PARTIALDISK, 7, 0x66);  // doubles at positions 1,2,5,6
	SIG(GL_SUB_GLU_TESSPROPERTY, 3, 0x04);  // double at position 2
	SIG(GL_SUB_GLU_TESSNORMAL, 4, 0x0E);  // doubles at positions 1,2,3
	SIG(GL_SUB_GLU_NURBSPROPERTY, 3, 0x04);  // float at position 2

	#undef SIG
}

bool GLThunksInit(void)
{
	gl_scratch_addr = SheepMem::Reserve(4);
	WriteMacInt32(gl_scratch_addr, 0);

	gl_dt_flag_addr = SheepMem::Reserve(4);
	WriteMacInt32(gl_dt_flag_addr, 0);

	// Immediate-mode batching: guest command ring and its control words.
	gl_defer_ring_base    = SheepMem::Reserve(GL_DEFER_RING_SIZE);
	gl_defer_head_addr    = SheepMem::Reserve(4); WriteMacInt32(gl_defer_head_addr, 0);
	gl_defer_count_addr   = SheepMem::Reserve(4); WriteMacInt32(gl_defer_count_addr, 0);
	gl_defer_enabled_addr = SheepMem::Reserve(4); WriteMacInt32(gl_defer_enabled_addr, 1); // default ON
	GLDeferBuildDescriptors();

	uint32 gl_opcode = NativeOpcode(NATIVE_OPENGL_DISPATCH);

	// Must precede the TVECT loop: stubs encode a branch to gl_defer_common_tail.
	EmitDeferFallback(gl_opcode);

	memset(gl_method_tvects, 0, sizeof(gl_method_tvects));
	memset(gl_dt_method_tvects, 0, sizeof(gl_dt_method_tvects));
	memset(gl_dt_diag_tvects, 0, sizeof(gl_dt_diag_tvects));

	int tvect_count = 0;

	// Core GL: stub and dispatch-table variants
	for (int i = GL_CORE_FIRST; i <= GL_CORE_LAST; i++) {
		// Deferrable setters get a capture stub. Dispatch-table calls are
		// never batched.
		gl_method_tvects[i] = GLDeferIsDeferrable(i)
			? EmitDeferStub(i, gl_defer_desc[i], gl_opcode)
			: AllocateGLTVECT(i, gl_opcode);
		gl_dt_method_tvects[i] = AllocateGLDispatchTableTVECT(i, gl_opcode);
		tvect_count++;
	}

	// Diagnostic no-ops, one per dispatch slot (see gl_dt_diag_tvects).
	for (int s = 0; s < GL_CTX_DISPATCH_SLOTS; s++) {
		gl_dt_diag_tvects[s] = AllocateGLDispatchTableTVECT(GL_DT_DIAG_BASE + s, gl_opcode);
		tvect_count++;
	}

	// Extensions also get dispatch-table TVECTs, for games that read them from
	// the context's table (Cro-Mag Rally's glLockArraysEXT at slot 339).
	// Placement is driven by gl_dispatch_ext_slots[].
	for (int i = GL_EXT_FIRST; i <= GL_EXT_LAST; i++) {
		gl_method_tvects[i] = GLDeferIsDeferrable(i)
			? EmitDeferStub(i, gl_defer_desc[i], gl_opcode)
			: AllocateGLTVECT(i, gl_opcode);
		gl_dt_method_tvects[i] = AllocateGLDispatchTableTVECT(i, gl_opcode);
		tvect_count++;
	}

	// AGL
	for (int i = GL_AGL_FIRST; i <= GL_AGL_LAST; i++) {
		gl_method_tvects[i] = AllocateGLTVECT(i, gl_opcode);
		tvect_count++;
	}

	// GLU
	for (int i = GL_GLU_FIRST; i <= GL_GLU_LAST; i++) {
		gl_method_tvects[i] = AllocateGLTVECT(i, gl_opcode);
		tvect_count++;
	}

	// GLUT
	for (int i = GL_GLUT_FIRST; i <= GL_GLUT_LAST; i++) {
		gl_method_tvects[i] = AllocateGLTVECT(i, gl_opcode);
		tvect_count++;
	}

	InitFuncSignatures();

	GL_LOG("GLThunksInit: allocated %d TVECTs (%d bytes), scratch at 0x%08x",
	       tvect_count, tvect_count * 32, gl_scratch_addr);
	GL_LOG("  Core GL:    %d (sub %d-%d)", GL_CORE_LAST - GL_CORE_FIRST + 1, GL_CORE_FIRST, GL_CORE_LAST);
	GL_LOG("  Extensions: %d (sub %d-%d)", GL_EXT_LAST - GL_EXT_FIRST + 1, GL_EXT_FIRST, GL_EXT_LAST);
	GL_LOG("  AGL:        %d (sub %d-%d)", GL_AGL_LAST - GL_AGL_FIRST + 1, GL_AGL_FIRST, GL_AGL_LAST);
	GL_LOG("  GLU:        %d (sub %d-%d)", GL_GLU_LAST - GL_GLU_FIRST + 1, GL_GLU_FIRST, GL_GLU_LAST);
	GL_LOG("  GLUT:       %d (sub %d-%d)", GL_GLUT_LAST - GL_GLUT_FIRST + 1, GL_GLUT_FIRST, GL_GLUT_LAST);
	GL_LOG("GLThunksInit: deferred-batching ring at 0x%08x size %d", gl_defer_ring_base, GL_DEFER_RING_SIZE);
	GL_LOG("GLThunksInit: deferral fallback routine at 0x%08x", gl_defer_common_tail);

	return true;
}
