/*
 *  arm64-emit.hpp - A64 instruction builders for the hand-written JIT
 *                   backend ops
 *
 *  PocketShaver arm64 JIT backend (C) 2026 Sierra Burkhart
 *  Kheperix (C) 2003-2005 Gwenole Beauchesne
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#ifndef ARM64_EMIT_H
#define ARM64_EMIT_H

#include <assert.h>

/*
 *  Register plan (see arm64/dyngen-target-exec.h): x19 = CPU,
 *  x20 = T0/A0, x21 = T1/A1, x22 = T2/A2, x16/x17 = intra-op scratch
 *  (IP0/IP1, caller-saved, never live across an emitted call), and
 *  x23 = VMBASE, the guest->host translation base (VMBaseDiff) pinned
 *  for inline fastmem. All of x19-x23 are AAPCS64 callee-saved, so C
 *  helper calls made from generated code preserve them; op_execute
 *  saves/restores them (plus d8-d11, which the FP value plan treats as
 *  scratch but whose low halves are callee-saved toward op_execute's
 *  caller) and materializes VMBASE in its prologue.
 *
 *  Every emitter writes through basic_jit_cache::emit_32, which routes
 *  the store to the RW shadow of the MAP_JIT region; code_ptr() values
 *  remain execute-view addresses throughout.
 */

// Gen-time services provided by the C++ side of the engine
extern "C" void kpx_jit_unimplemented_op(const char *name);
extern "C" void *kpx_jit_jump_next(void *cpu, void *bi);
extern "C" uintptr kpx_vm_base(void);	// VMBaseDiff (0 when not MEM_BULK)
extern "C" unsigned long kpx_jit_pc_offset(void *cpu);
extern "C" unsigned long kpx_jit_spcflags_offset(void *cpu);
extern "C" unsigned long kpx_jit_gpr_offset(void *cpu, int i);
extern "C" unsigned long kpx_jit_cr_offset(void *cpu);
extern "C" unsigned long kpx_jit_xer_offset(void *cpu);
extern "C" unsigned long kpx_jit_lr_offset(void *cpu);
extern "C" unsigned long kpx_jit_ctr_offset(void *cpu);
extern "C" unsigned long kpx_jit_vrsave_offset(void *cpu);

// Runtime helpers called by generated code (arm64-helpers.cpp). Only their
// addresses are taken here, so a forward declaration of powerpc_cpu suffices.
class powerpc_cpu;
extern "C" {
uint32 kpx_op_addo(powerpc_cpu*,uint32,uint32);   uint32 kpx_op_addc(powerpc_cpu*,uint32,uint32);
uint32 kpx_op_addco(powerpc_cpu*,uint32,uint32);  uint32 kpx_op_adde(powerpc_cpu*,uint32,uint32);
uint32 kpx_op_addeo(powerpc_cpu*,uint32,uint32);  uint32 kpx_op_addc_im(powerpc_cpu*,uint32,uint32);
uint32 kpx_op_addme(powerpc_cpu*,uint32);         uint32 kpx_op_addmeo(powerpc_cpu*,uint32);
uint32 kpx_op_addze(powerpc_cpu*,uint32);         uint32 kpx_op_addzeo(powerpc_cpu*,uint32);
uint32 kpx_op_subfo(powerpc_cpu*,uint32,uint32);  uint32 kpx_op_subfc(powerpc_cpu*,uint32,uint32);
uint32 kpx_op_subfco(powerpc_cpu*,uint32,uint32); uint32 kpx_op_subfc_im(powerpc_cpu*,uint32,uint32);
uint32 kpx_op_subfe(powerpc_cpu*,uint32,uint32);  uint32 kpx_op_subfeo(powerpc_cpu*,uint32,uint32);
uint32 kpx_op_subfme(powerpc_cpu*,uint32);        uint32 kpx_op_subfmeo(powerpc_cpu*,uint32);
uint32 kpx_op_subfze(powerpc_cpu*,uint32);        uint32 kpx_op_subfzeo(powerpc_cpu*,uint32);
uint32 kpx_op_nego(powerpc_cpu*,uint32);          uint32 kpx_op_mullwo(powerpc_cpu*,uint32,uint32);
uint32 kpx_op_divw(powerpc_cpu*,uint32,uint32);   uint32 kpx_op_divwo(powerpc_cpu*,uint32,uint32);
uint32 kpx_op_divwu(powerpc_cpu*,uint32,uint32);  uint32 kpx_op_divwuo(powerpc_cpu*,uint32,uint32);
uint32 kpx_op_sraw(powerpc_cpu*,uint32,uint32);   uint32 kpx_op_srawi(powerpc_cpu*,uint32,uint32);
uint32 kpx_op_load_xer(powerpc_cpu*);             void   kpx_op_store_xer(powerpc_cpu*,uint32);
uint32 kpx_vm_read_1(uint32);                     void   kpx_vm_write_1(uint32,uint32);
uint32 kpx_vm_read_2(uint32);                     void   kpx_vm_write_2(uint32,uint32);
uint32 kpx_vm_read_4(uint32);                     void   kpx_vm_write_4(uint32,uint32);
uint64 kpx_vm_read_8(uint32);                     void   kpx_vm_write_8(uint32,uint64);
void   kpx_op_lmw(powerpc_cpu*,uint32,uint32);    void   kpx_op_stmw(powerpc_cpu*,uint32,uint32);
uint32 kpx_op_lwarx(powerpc_cpu*,uint32);         void   kpx_op_stwcx(powerpc_cpu*,uint32,uint32);
void   kpx_op_dcbz(uint32);
uint64 kpx_fp_load_single(uint32);                void   kpx_fp_store_single(uint32,uint64);
double kpx_fp_fadd(powerpc_cpu*,double,double);   double kpx_fp_fadds(powerpc_cpu*,double,double);
double kpx_fp_fsub(powerpc_cpu*,double,double);   double kpx_fp_fsubs(powerpc_cpu*,double,double);
double kpx_fp_fmul(powerpc_cpu*,double,double);   double kpx_fp_fmuls(powerpc_cpu*,double,double);
double kpx_fp_fdiv(powerpc_cpu*,double,double);   double kpx_fp_fdivs(powerpc_cpu*,double,double);
double kpx_fp_fmadd(powerpc_cpu*,double,double,double);   double kpx_fp_fmadds(powerpc_cpu*,double,double,double);
double kpx_fp_fmsub(powerpc_cpu*,double,double,double);   double kpx_fp_fmsubs(powerpc_cpu*,double,double,double);
double kpx_fp_fnmadd(powerpc_cpu*,double,double,double);  double kpx_fp_fnmadds(powerpc_cpu*,double,double,double);
double kpx_fp_fnmsub(powerpc_cpu*,double,double,double);  double kpx_fp_fnmsubs(powerpc_cpu*,double,double,double);
unsigned long kpx_jit_fpr_offset(void *cpu, int i);
unsigned long kpx_jit_fpscr_offset(void *cpu);
unsigned long kpx_jit_vr_offset(void *cpu, int i);
void kpx_op_load_vect(void *cpu, void *vr, uint32 ea);
void kpx_op_store_vect(void *cpu, void *vr, uint32 ea);
void kpx_op_load_word_vect(void *cpu, void *vr, uint32 ea);
void kpx_op_store_word_vect(void *cpu, void *vr, uint32 ea);
}

enum {
	A64_X9 = 9, A64_X10 = 10, A64_X11 = 11,	// intra-op scratch (caller-saved, no live-across)
	A64_X16 = 16, A64_X17 = 17,
	A64_CPU = 19,			// AREG0
	A64_T0	= 20,			// AREG1, aliases A0
	A64_T1	= 21,			// AREG2, aliases A1
	A64_T2	= 22,			// AREG3, aliases A2
	A64_VMBASE = 23,		// VMBaseDiff, pinned by op_execute for inline fastmem
	A64_VD	= 24,			// AltiVec VD pointer (reg_VD/A3 analog), saved by op_execute
	A64_FP	= 29, A64_LR = 30, A64_SP = 31, A64_ZR = 31
};

// arm64 condition codes
enum { A64_EQ=0, A64_NE=1, A64_HS=2, A64_LO=3, A64_HI=8, A64_LS=9, A64_GE=10, A64_LT=11, A64_GT=12, A64_LE=13 };

// ---- bare encoders -------------------------------------------------------

static inline uint32 a64_movz_w(int rd, uint32 imm16, int hw)
	{ assert(imm16 <= 0xffff && hw <= 1); return 0x52800000 | (hw << 21) | (imm16 << 5) | rd; }
static inline uint32 a64_movk_w(int rd, uint32 imm16, int hw)
	{ assert(imm16 <= 0xffff && hw <= 1); return 0x72800000 | (hw << 21) | (imm16 << 5) | rd; }
static inline uint32 a64_movz_x(int rd, uint32 imm16, int hw)
	{ assert(imm16 <= 0xffff && hw <= 3); return 0xd2800000 | (hw << 21) | (imm16 << 5) | rd; }
static inline uint32 a64_movk_x(int rd, uint32 imm16, int hw)
	{ assert(imm16 <= 0xffff && hw <= 3); return 0xf2800000 | (hw << 21) | (imm16 << 5) | rd; }

static inline uint32 a64_mov_x(int rd, int rm)	// ORR Xd, XZR, Xm
	{ return 0xaa0003e0 | (rm << 16) | rd; }
static inline uint32 a64_mov_w(int rd, int rm)	// ORR Wd, WZR, Wm
	{ return 0x2a0003e0 | (rm << 16) | rd; }
static inline uint32 a64_mov_from_sp(int rd)	// ADD Xd, SP, #0
	{ return 0x91000000 | (A64_SP << 5) | rd; }

static inline uint32 a64_ldr_w(int rt, int rn, uint32 byte_off)
	{ assert((byte_off & 3) == 0 && (byte_off >> 2) < 4096); return 0xb9400000 | ((byte_off >> 2) << 10) | (rn << 5) | rt; }
static inline uint32 a64_str_w(int rt, int rn, uint32 byte_off)
	{ assert((byte_off & 3) == 0 && (byte_off >> 2) < 4096); return 0xb9000000 | ((byte_off >> 2) << 10) | (rn << 5) | rt; }

static inline uint32 a64_br(int rn)	 { return 0xd61f0000 | (rn << 5); }
static inline uint32 a64_blr(int rn) { return 0xd63f0000 | (rn << 5); }
static inline uint32 a64_ret(void)	 { return 0xd65f03c0; }
static inline uint32 a64_nop(void)	 { return 0xd503201f; }

// byte / halfword memory (unscaled unsigned offset, 0..4095 * size)
static inline uint32 a64_ldrb(int rt,int rn,uint32 off){ return 0x39400000|((off&0xfff)<<10)|(rn<<5)|rt; }
static inline uint32 a64_strb(int rt,int rn,uint32 off){ return 0x39000000|((off&0xfff)<<10)|(rn<<5)|rt; }
static inline uint32 a64_ldrh(int rt,int rn,uint32 off){ return 0x79400000|(((off>>1)&0xfff)<<10)|(rn<<5)|rt; }
static inline uint32 a64_strh(int rt,int rn,uint32 off){ return 0x79000000|(((off>>1)&0xfff)<<10)|(rn<<5)|rt; }

// 64-bit GPR memory (scaled unsigned offset)
static inline uint32 a64_ldr_x(int rt,int rn,uint32 off)
	{ assert((off & 7) == 0 && (off >> 3) < 4096); return 0xf9400000|((off>>3)<<10)|(rn<<5)|rt; }
static inline uint32 a64_str_x(int rt,int rn,uint32 off)
	{ assert((off & 7) == 0 && (off >> 3) < 4096); return 0xf9000000|((off>>3)<<10)|(rn<<5)|rt; }

// register-offset memory, [Xn, Wm, UXTW] (no scaling: byte index) — the
// inline-fastmem access shape: base = pinned VMBASE, index = 32-bit guest EA
static inline uint32 a64_ldrb_uxtw(int rt,int rn,int rm){ return 0x38604800|(rm<<16)|(rn<<5)|rt; }
static inline uint32 a64_ldrh_uxtw(int rt,int rn,int rm){ return 0x78604800|(rm<<16)|(rn<<5)|rt; }
static inline uint32 a64_ldr_w_uxtw(int rt,int rn,int rm){ return 0xb8604800|(rm<<16)|(rn<<5)|rt; }
static inline uint32 a64_ldr_x_uxtw(int rt,int rn,int rm){ return 0xf8604800|(rm<<16)|(rn<<5)|rt; }
static inline uint32 a64_strb_uxtw(int rt,int rn,int rm){ return 0x38204800|(rm<<16)|(rn<<5)|rt; }
static inline uint32 a64_strh_uxtw(int rt,int rn,int rm){ return 0x78204800|(rm<<16)|(rn<<5)|rt; }
static inline uint32 a64_str_w_uxtw(int rt,int rn,int rm){ return 0xb8204800|(rm<<16)|(rn<<5)|rt; }
static inline uint32 a64_str_x_uxtw(int rt,int rn,int rm){ return 0xf8204800|(rm<<16)|(rn<<5)|rt; }

// data processing (W-form, 32-bit) — Rd=0..30, ZR=31
static inline uint32 a64_add_reg(int d,int n,int m){ return 0x0b000000|(m<<16)|(n<<5)|d; }
static inline uint32 a64_sub_reg(int d,int n,int m){ return 0x4b000000|(m<<16)|(n<<5)|d; }
static inline uint32 a64_and_reg(int d,int n,int m){ return 0x0a000000|(m<<16)|(n<<5)|d; }
static inline uint32 a64_orr_reg(int d,int n,int m){ return 0x2a000000|(m<<16)|(n<<5)|d; }
static inline uint32 a64_eor_reg(int d,int n,int m){ return 0x4a000000|(m<<16)|(n<<5)|d; }
static inline uint32 a64_orn_reg(int d,int n,int m){ return 0x2a200000|(m<<16)|(n<<5)|d; }   // Rn ORR ~Rm
static inline uint32 a64_bic_reg(int d,int n,int m){ return 0x0a200000|(m<<16)|(n<<5)|d; }   // Rn AND ~Rm
static inline uint32 a64_mvn_reg(int d,int m){ return 0x2a2003e0|(m<<16)|d; }                // ORN Rd,ZR,Rm
static inline uint32 a64_neg_reg(int d,int m){ return 0x4b0003e0|(m<<16)|d; }                // SUB Rd,ZR,Rm

// immediate add/sub (unsigned imm12)
static inline uint32 a64_add_imm(int d,int n,uint32 imm){ return 0x11000000|((imm&0xfff)<<10)|(n<<5)|d; }
static inline uint32 a64_sub_imm(int d,int n,uint32 imm){ return 0x51000000|((imm&0xfff)<<10)|(n<<5)|d; }

// multiply
static inline uint32 a64_mul(int d,int n,int m){ return 0x1b007c00|(m<<16)|(n<<5)|d; }        // MADD Rd,Rn,Rm,ZR (W)
static inline uint32 a64_smull(int d,int n,int m){ return 0x9b207c00|(m<<16)|(n<<5)|d; }      // Xd = Wn * Wm signed
static inline uint32 a64_umull(int d,int n,int m){ return 0x9ba07c00|(m<<16)|(n<<5)|d; }      // Xd = Wn * Wm unsigned

// variable shifts (W-form): mask count mod 32
static inline uint32 a64_lslv(int d,int n,int m){ return 0x1ac02000|(m<<16)|(n<<5)|d; }
static inline uint32 a64_lsrv(int d,int n,int m){ return 0x1ac02400|(m<<16)|(n<<5)|d; }
static inline uint32 a64_asrv(int d,int n,int m){ return 0x1ac02800|(m<<16)|(n<<5)|d; }
static inline uint32 a64_rorv(int d,int n,int m){ return 0x1ac02c00|(m<<16)|(n<<5)|d; }
// X-form variable left/right shift (for 6-bit slw/srw on zero-extended value)
static inline uint32 a64_lslv_x(int d,int n,int m){ return 0x9ac02000|(m<<16)|(n<<5)|d; }
static inline uint32 a64_lsrv_x(int d,int n,int m){ return 0x9ac02400|(m<<16)|(n<<5)|d; }

// immediate shifts via UBFM/SBFM (W-form, immr/imms in 0..31)
static inline uint32 a64_lsl_imm(int d,int n,int sh){ int immr=(-sh)&31, imms=31-sh; return 0x53000000|(immr<<16)|(imms<<10)|(n<<5)|d; }
static inline uint32 a64_lsr_imm(int d,int n,int sh){ return 0x53000000|(sh<<16)|(31<<10)|(n<<5)|d; }   // UBFM d,n,#sh,#31
static inline uint32 a64_asr_imm(int d,int n,int sh){ return 0x13000000|(sh<<16)|(31<<10)|(n<<5)|d; }   // SBFM d,n,#sh,#31
static inline uint32 a64_ror_imm(int d,int n,int sh){ return 0x13800000|(n<<16)|(sh<<10)|(n<<5)|d; }    // EXTR d,n,n,#sh
static inline uint32 a64_ubfm(int d,int n,int immr,int imms){ return 0x53000000|(immr<<16)|(imms<<10)|(n<<5)|d; }
static inline uint32 a64_bfm(int d,int n,int immr,int imms){ return 0x33000000|(immr<<16)|(imms<<10)|(n<<5)|d; }
// X-form logical shift-right immediate (extract high word of a 64-bit product)
static inline uint32 a64_lsr_imm_x(int d,int n,int sh){ return 0xd340fc00|(sh<<16)|(n<<5)|d; } // UBFM x,#sh,#63

// scalar FP (double). FP value plan: d8 = F0, d9 = F1, d10 = F2, d11 = FD
// (low 64 bits of v8-v11 are callee-saved, so values survive helper calls)
static inline uint32 a64_ldr_d(int rt,int rn,uint32 off)
	{ assert((off & 7) == 0 && (off >> 3) < 4096); return 0xfd400000|((off>>3)<<10)|(rn<<5)|rt; }
static inline uint32 a64_str_d(int rt,int rn,uint32 off)
	{ assert((off & 7) == 0 && (off >> 3) < 4096); return 0xfd000000|((off>>3)<<10)|(rn<<5)|rt; }
static inline uint32 a64_fmov_d(int rd,int rn){ return 0x1e604000|(rn<<5)|rd; }     // FMOV Dd, Dn
static inline uint32 a64_fmov_d_x(int dd,int xn){ return 0x9e670000|(xn<<5)|dd; }   // FMOV Dd, Xn
static inline uint32 a64_fmov_x_d(int xd,int dn){ return 0x9e660000|(dn<<5)|xd; }   // FMOV Xd, Dn
static inline uint32 a64_fmov_s_w(int sd,int wn){ return 0x1e270000|(wn<<5)|sd; }   // FMOV Sd, Wn
static inline uint32 a64_fcvt_d_s(int dd,int sn){ return 0x1e22c000|(sn<<5)|dd; }   // FCVT Dd, Sn
static inline uint32 a64_fabs_d(int rd,int rn){ return 0x1e60c000|(rn<<5)|rd; }
static inline uint32 a64_fneg_d(int rd,int rn){ return 0x1e614000|(rn<<5)|rd; }

// ---- NEON (AltiVec value plan: q0-q3 intra-op scratch; pointers to the
// guest VRs live in x20/x21/x22 (V0/V1/V2, aliasing T0-T2) and x24 (VD)) --
// 128-bit load/store, unsigned scaled imm (byte_off multiple of 16)
static inline uint32 a64_ldr_q(int rt,int rn,uint32 off)
	{ assert((off & 15) == 0 && (off >> 4) < 4096); return 0x3dc00000|((off>>4)<<10)|(rn<<5)|rt; }
static inline uint32 a64_str_q(int rt,int rn,uint32 off)
	{ assert((off & 15) == 0 && (off >> 4) < 4096); return 0x3d800000|((off>>4)<<10)|(rn<<5)|rt; }
// three-same integer (size: 0=16b, 1=8h, 2=4s)
static inline uint32 a64_neon_add(int sz,int d,int n,int m){ return 0x4e208400|(sz<<22)|(m<<16)|(n<<5)|d; }
static inline uint32 a64_neon_sub(int sz,int d,int n,int m){ return 0x6e208400|(sz<<22)|(m<<16)|(n<<5)|d; }
static inline uint32 a64_neon_cmeq(int sz,int d,int n,int m){ return 0x6e208c00|(sz<<22)|(m<<16)|(n<<5)|d; }
static inline uint32 a64_neon_cmgt(int sz,int d,int n,int m){ return 0x4e203400|(sz<<22)|(m<<16)|(n<<5)|d; }  // signed >
static inline uint32 a64_neon_cmhi(int sz,int d,int n,int m){ return 0x6e203400|(sz<<22)|(m<<16)|(n<<5)|d; }  // unsigned >
static inline uint32 a64_neon_smax(int sz,int d,int n,int m){ return 0x4e206400|(sz<<22)|(m<<16)|(n<<5)|d; }
static inline uint32 a64_neon_smin(int sz,int d,int n,int m){ return 0x4e206c00|(sz<<22)|(m<<16)|(n<<5)|d; }
static inline uint32 a64_neon_umax(int sz,int d,int n,int m){ return 0x6e206400|(sz<<22)|(m<<16)|(n<<5)|d; }
static inline uint32 a64_neon_umin(int sz,int d,int n,int m){ return 0x6e206c00|(sz<<22)|(m<<16)|(n<<5)|d; }
static inline uint32 a64_neon_urhadd(int sz,int d,int n,int m){ return 0x6e201400|(sz<<22)|(m<<16)|(n<<5)|d; } // (a+b+1)>>1
// three-same logical (.16b)
static inline uint32 a64_neon_and(int d,int n,int m){ return 0x4e201c00|(m<<16)|(n<<5)|d; }
static inline uint32 a64_neon_bic(int d,int n,int m){ return 0x4e601c00|(m<<16)|(n<<5)|d; }  // Vn & ~Vm
static inline uint32 a64_neon_orr(int d,int n,int m){ return 0x4ea01c00|(m<<16)|(n<<5)|d; }
static inline uint32 a64_neon_orn(int d,int n,int m){ return 0x4ee01c00|(m<<16)|(n<<5)|d; }
static inline uint32 a64_neon_eor(int d,int n,int m){ return 0x6e201c00|(m<<16)|(n<<5)|d; }
static inline uint32 a64_neon_bsl(int d,int n,int m){ return 0x6e601c00|(m<<16)|(n<<5)|d; }  // d = (d&n)|(~d&m)
static inline uint32 a64_neon_not(int d,int n){ return 0x6e205800|(n<<5)|d; }
// three-same float (.4s)
static inline uint32 a64_neon_fadd(int d,int n,int m){ return 0x4e20d400|(m<<16)|(n<<5)|d; }
static inline uint32 a64_neon_fsub(int d,int n,int m){ return 0x4ea0d400|(m<<16)|(n<<5)|d; }
static inline uint32 a64_neon_fmul(int d,int n,int m){ return 0x6e20dc00|(m<<16)|(n<<5)|d; }
static inline uint32 a64_neon_fmla(int d,int n,int m){ return 0x4e20cc00|(m<<16)|(n<<5)|d; }  // d += n*m (fused)
static inline uint32 a64_neon_fmls(int d,int n,int m){ return 0x4ea0cc00|(m<<16)|(n<<5)|d; }  // d -= n*m (fused)
static inline uint32 a64_neon_fcmeq(int d,int n,int m){ return 0x4e20e400|(m<<16)|(n<<5)|d; }
static inline uint32 a64_neon_fcmge(int d,int n,int m){ return 0x6e20e400|(m<<16)|(n<<5)|d; }
static inline uint32 a64_neon_fcmgt(int d,int n,int m){ return 0x6ea0e400|(m<<16)|(n<<5)|d; }
static inline uint32 a64_neon_fneg(int d,int n){ return 0x6ea0f800|(n<<5)|d; }               // .4s
// across-lanes / element moves
static inline uint32 a64_neon_umaxv_b(int d,int n){ return 0x6e30a800|(n<<5)|d; }            // Bd = max of .16b
static inline uint32 a64_neon_uminv_b(int d,int n){ return 0x6e31a800|(n<<5)|d; }            // Bd = min of .16b
static inline uint32 a64_neon_umov_b0(int wd,int vn){ return 0x0e013c00|(vn<<5)|wd; }        // Wd = Vn.b[0]
// dup: element form (host lane index) and general-register form
static inline uint32 a64_neon_dup_elem_b(int d,int n,int idx){ return 0x4e000400|((((idx)<<1)|1)<<16)|(n<<5)|d; }
static inline uint32 a64_neon_dup_elem_h(int d,int n,int idx){ return 0x4e000400|((((idx)<<2)|2)<<16)|(n<<5)|d; }
static inline uint32 a64_neon_dup_elem_s(int d,int n,int idx){ return 0x4e000400|((((idx)<<3)|4)<<16)|(n<<5)|d; }
static inline uint32 a64_neon_dup_gen_b(int d,int wn){ return 0x4e010c00|(wn<<5)|d; }
static inline uint32 a64_neon_dup_gen_h(int d,int wn){ return 0x4e020c00|(wn<<5)|d; }
static inline uint32 a64_neon_dup_gen_s(int d,int wn){ return 0x4e040c00|(wn<<5)|d; }
// movi Vd.16b, #imm8
static inline uint32 a64_neon_movi_b(int d,uint32 imm8)
	{ assert(imm8 <= 0xff); return 0x4f00e400|(((imm8>>5)&7)<<16)|((imm8&0x1f)<<5)|d; }
// tbl with a two-register table {Vn, Vn+1}
static inline uint32 a64_neon_tbl2(int d,int n,int m){ return 0x4e002000|(m<<16)|(1<<13)|(n<<5)|d; }
// rev32 .16b: byte-reverse within each 32-bit element (guest<->host vector layout)
static inline uint32 a64_neon_rev32_b(int d,int n){ return 0x6e200800|(n<<5)|d; }
// X-form add (pointer arithmetic for VR addresses)
static inline uint32 a64_add_imm_x(int d,int n,uint32 imm)
	{ assert(imm < 4096); return 0x91000000|(imm<<10)|(n<<5)|d; }
static inline uint32 a64_add_reg_x(int d,int n,int m){ return 0x8b000000|(m<<16)|(n<<5)|d; }

// extends / clz / rev
static inline uint32 a64_sxtb(int d,int n){ return 0x13001c00|(n<<5)|d; }   // SBFM d,n,#0,#7
static inline uint32 a64_sxth(int d,int n){ return 0x13003c00|(n<<5)|d; }   // SBFM d,n,#0,#15
static inline uint32 a64_uxtb(int d,int n){ return 0x53001c00|(n<<5)|d; }
static inline uint32 a64_uxth(int d,int n){ return 0x53003c00|(n<<5)|d; }
static inline uint32 a64_clz(int d,int n){ return 0x5ac01000|(n<<5)|d; }
static inline uint32 a64_rev(int d,int n){ return 0x5ac00800|(n<<5)|d; }    // REV (W)
static inline uint32 a64_rev16(int d,int n){ return 0x5ac00400|(n<<5)|d; }
static inline uint32 a64_rev_x(int d,int n){ return 0xdac00c00|(n<<5)|d; }  // REV (X, 64-bit)

// compare / conditional-select (W-form). cond codes: EQ0 NE1 CS/HS2 CC/LO3 HI8 LS9 GE10 LT11 GT12 LE13
static inline uint32 a64_cmp_reg(int n,int m){ return 0x6b00001f|(m<<16)|(n<<5); }           // SUBS ZR,Rn,Rm
static inline uint32 a64_cmp_imm(int n,uint32 imm){ return 0x7100001f|((imm&0xfff)<<10)|(n<<5); }
static inline uint32 a64_tst_imm_bit31(int n){ return 0x7200001f|(0<<16)|(0<<10)|(n<<5); }   // placeholder, unused
static inline uint32 a64_cset(int d,int cond){ int inv=cond^1; return 0x1a9f07e0|(inv<<12)|d; } // CSINC d,ZR,ZR,!cond
static inline uint32 a64_csel(int d,int n,int m,int cond){ return 0x1a800000|(m<<16)|(cond<<12)|(n<<5)|d; }
static inline uint32 a64_ands_imm31(int n){ return 0; }  // unused placeholder

static inline uint32 a64_b(intptr rel)
	{ assert((rel & 3) == 0 && rel >= -(intptr)0x8000000 && rel < (intptr)0x8000000);
	  return 0x14000000 | (((uint32)(rel >> 2)) & 0x03ffffff); }
static inline uint32 a64_b_cond(int cond, intptr rel)
	{ assert((rel & 3) == 0 && rel >= -(intptr)0x100000 && rel < (intptr)0x100000);
	  return 0x54000000 | ((((uint32)(rel >> 2)) & 0x7ffff) << 5) | cond; }
static inline uint32 a64_cbz_w(int rt, intptr rel)
	{ assert((rel & 3) == 0 && rel >= -(intptr)0x100000 && rel < (intptr)0x100000);
	  return 0x34000000 | ((((uint32)(rel >> 2)) & 0x7ffff) << 5) | rt; }
static inline uint32 a64_cbz_x(int rt, intptr rel)
	{ assert((rel & 3) == 0 && rel >= -(intptr)0x100000 && rel < (intptr)0x100000);
	  return 0xb4000000 | ((((uint32)(rel >> 2)) & 0x7ffff) << 5) | rt; }

// SIMD&FP register pairs (64-bit D form, signed offset). op_execute must
// save d8-d11: the FP value plan hands them to generated code as scratch,
// but AAPCS64 makes their low halves callee-saved toward OUR caller.
static inline uint32 a64_stp_d(int rt, int rt2, int rn, int byte_off)
	{ assert((byte_off & 7) == 0 && byte_off >= -512 && byte_off < 512);
	  return 0x6d000000 | ((((uint32)(byte_off / 8)) & 0x7f) << 15) | (rt2 << 10) | (rn << 5) | rt; }
static inline uint32 a64_ldp_d(int rt, int rt2, int rn, int byte_off)
	{ assert((byte_off & 7) == 0 && byte_off >= -512 && byte_off < 512);
	  return 0x6d400000 | ((((uint32)(byte_off / 8)) & 0x7f) << 15) | (rt2 << 10) | (rn << 5) | rt; }

static inline uint32 a64_stp_x_pre(int rt, int rt2, int rn, int byte_off)
	{ assert((byte_off & 7) == 0 && byte_off >= -512 && byte_off < 512);
	  return 0xa9800000 | ((((uint32)(byte_off / 8)) & 0x7f) << 15) | (rt2 << 10) | (rn << 5) | rt; }
static inline uint32 a64_stp_x(int rt, int rt2, int rn, int byte_off)
	{ assert((byte_off & 7) == 0 && byte_off >= -512 && byte_off < 512);
	  return 0xa9000000 | ((((uint32)(byte_off / 8)) & 0x7f) << 15) | (rt2 << 10) | (rn << 5) | rt; }
static inline uint32 a64_ldp_x(int rt, int rt2, int rn, int byte_off)
	{ assert((byte_off & 7) == 0 && byte_off >= -512 && byte_off < 512);
	  return 0xa9400000 | ((((uint32)(byte_off / 8)) & 0x7f) << 15) | (rt2 << 10) | (rn << 5) | rt; }
static inline uint32 a64_ldp_x_post(int rt, int rt2, int rn, int byte_off)
	{ assert((byte_off & 7) == 0 && byte_off >= -512 && byte_off < 512);
	  return 0xa8c00000 | ((((uint32)(byte_off / 8)) & 0x7f) << 15) | (rt2 << 10) | (rn << 5) | rt; }

// ---- composite emitters (write through the cache's shadow) --------------

static inline void a64_emit_mov_imm32(basic_jit_cache &c, int wd, uint32 v)
{
	c.emit_32(a64_movz_w(wd, v & 0xffff, 0));
	c.emit_32(a64_movk_w(wd, (v >> 16) & 0xffff, 1));
}

static inline void a64_emit_mov_imm64(basic_jit_cache &c, int xd, uint64 v)
{
	c.emit_32(a64_movz_x(xd, v & 0xffff, 0));
	c.emit_32(a64_movk_x(xd, (v >> 16) & 0xffff, 1));
	c.emit_32(a64_movk_x(xd, (v >> 32) & 0xffff, 2));
	c.emit_32(a64_movk_x(xd, (v >> 48) & 0xffff, 3));
}

// Call an absolute host address; clobbers x16 (and x0.. per C ABI)
static inline void a64_emit_call(basic_jit_cache &c, uintptr target)
{
	a64_emit_mov_imm64(c, A64_X16, target);
	c.emit_32(a64_blr(A64_X16));
}

// Jump to an absolute host address; clobbers x16
static inline void a64_emit_jmp_abs(basic_jit_cache &c, uintptr target)
{
	a64_emit_mov_imm64(c, A64_X16, target);
	c.emit_32(a64_br(A64_X16));
}

/*
 *  Retarget a patchable branch instruction located (in execute view) at
 *  insn_addr. Handles the two shapes the backend emits: unconditional B
 *  and CBZ/CBNZ. Returns the new instruction word; the caller decides
 *  how to store it (shadow write at translate time, jit_wx_publish for
 *  live code).
 */
static inline uint32 a64_retarget_branch(uint32 insn, const uint8 *insn_addr, const uint8 *target)
{
	const intptr rel = (intptr)(target - insn_addr);
	assert((rel & 3) == 0);
	if ((insn & 0xfc000000) == 0x14000000) {		// B imm26
		assert(rel >= -(intptr)0x8000000 && rel < (intptr)0x8000000);
		return 0x14000000 | (((uint32)(rel >> 2)) & 0x03ffffff);
	}
	if ((insn & 0x7e000000) == 0x34000000) {		// CBZ/CBNZ imm19
		assert(rel >= -(intptr)0x100000 && rel < (intptr)0x100000);
		return (insn & ~0x00ffffe0) | ((((uint32)(rel >> 2)) & 0x7ffff) << 5);
	}
	kpx_jit_unimplemented_op("a64_retarget_branch: unknown patch site");
	return insn;
}

#endif /* ARM64_EMIT_H */
