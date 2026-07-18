/*
 *  arm64-helpers.cpp - C helpers called by JIT-generated arm64 code
 *
 *  The flag-producing arithmetic (XER carry/overflow), divides, and XER
 *  packing are transcribed directly from the interpreter's semantics
 *  (ppc-execute.hpp do_execute_addition/subtract, ppc-registers.hpp XER
 *  accessors) so they are correct by construction. The generated code
 *  keeps values in T0/T1 (w20/w21) and marshals them as C arguments,
 *  reading/writing XER through the CPU pointer (x19).
 *
 *  PocketShaver arm64 JIT backend (C) 2026 Sierra Burkhart
 *  Kheperix (C) 2003-2005 Gwenole Beauchesne
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 */

#include "sysdeps.h"

#if ENABLE_DYNGEN && defined(__aarch64__)

#include <math.h>
#include "cpu/ppc/ppc-cpu.hpp"
#include "cpu/vm.hpp"
#include "mathlib/mathlib.hpp"

// Sign bit as 0/1, matching the interpreter's `(int32)X < 0` booleans
static inline uint32 sgn(uint32 x) { return x >> 31; }

// ---- addition family: RD = RA + RB (+ carry-in) --------------------------
// EX = carry in from XER.CA; CA = compute unextended carry out; OE = overflow
template<bool EX, bool CA, bool OE>
static inline uint32 do_add(powerpc_cpu *c, uint32 RA, uint32 RB)
{
	uint32 RD = RA + RB + (EX ? c->jit_xer().get_ca() : 0);
	uint32 _RA = sgn(RA), _RB = sgn(RB), _RD = sgn(RD);
	if (EX)      c->jit_xer().set_ca(_RB ^ ((_RB ^ _RA) & (_RA ^ _RD)));
	else if (CA) c->jit_xer().set_ca((uint32)RD < (uint32)RA);
	if (OE)      c->jit_xer().set_ov((_RB ^ _RD) & (_RA ^ _RD));
	return RD;
}

// ---- subtract family: RD = RB - RA ---------------------------------------
template<bool CA, bool OE>
static inline uint32 do_sub(powerpc_cpu *c, uint32 RA, uint32 RB)
{
	uint32 RD = RB - RA;
	uint32 _RA = sgn(RA), _RB = sgn(RB), _RD = sgn(RD);
	if (CA) c->jit_xer().set_ca((uint32)RD <= (uint32)RB);
	if (OE) c->jit_xer().set_ov((_RA ^ _RB) & (_RD ^ _RB));
	return RD;
}

// ---- subtract-extended: RD = ~RA + RB + CA -------------------------------
template<bool OE>
static inline uint32 do_sub_e(powerpc_cpu *c, uint32 RA, uint32 RB)
{
	uint32 RD = ~RA + RB + c->jit_xer().get_ca();
	uint32 _RA = sgn(RA), _RB = sgn(RB), _RD = sgn(RD);
	c->jit_xer().set_ca((uint32)(!_RA) ^ ((_RA ^ _RD) & (_RB ^ _RD)));
	if (OE) c->jit_xer().set_ov((_RA ^ _RB) & (_RD ^ _RB));
	return RD;
}

extern "C" {

uint32 kpx_op_addo   (powerpc_cpu *c, uint32 t0, uint32 t1) { return do_add<false,false,true >(c, t0, t1); }
uint32 kpx_op_addc   (powerpc_cpu *c, uint32 t0, uint32 t1) { return do_add<false,true, false>(c, t0, t1); }
uint32 kpx_op_addco  (powerpc_cpu *c, uint32 t0, uint32 t1) { return do_add<false,true, true >(c, t0, t1); }
uint32 kpx_op_adde   (powerpc_cpu *c, uint32 t0, uint32 t1) { return do_add<true, false,false>(c, t0, t1); }
uint32 kpx_op_addeo  (powerpc_cpu *c, uint32 t0, uint32 t1) { return do_add<true, false,true >(c, t0, t1); }
uint32 kpx_op_addc_im(powerpc_cpu *c, uint32 t0, uint32 im){ return do_add<false,true, false>(c, t0, im); }
uint32 kpx_op_addme  (powerpc_cpu *c, uint32 t0) { return do_add<true,false,false>(c, t0, 0xffffffffu); }
uint32 kpx_op_addmeo (powerpc_cpu *c, uint32 t0) { return do_add<true,false,true >(c, t0, 0xffffffffu); }
uint32 kpx_op_addze  (powerpc_cpu *c, uint32 t0) { return do_add<true,false,false>(c, t0, 0); }
uint32 kpx_op_addzeo (powerpc_cpu *c, uint32 t0) { return do_add<true,false,true >(c, t0, 0); }

uint32 kpx_op_subfo  (powerpc_cpu *c, uint32 t0, uint32 t1) { return do_sub<false,true>(c, t0, t1); }
uint32 kpx_op_subfc  (powerpc_cpu *c, uint32 t0, uint32 t1) { return do_sub<true, false>(c, t0, t1); }
uint32 kpx_op_subfco (powerpc_cpu *c, uint32 t0, uint32 t1) { return do_sub<true, true>(c, t0, t1); }
uint32 kpx_op_subfc_im(powerpc_cpu *c, uint32 t0, uint32 im){ return do_sub<true, false>(c, t0, im); }
uint32 kpx_op_subfe  (powerpc_cpu *c, uint32 t0, uint32 t1) { return do_sub_e<false>(c, t0, t1); }
uint32 kpx_op_subfeo (powerpc_cpu *c, uint32 t0, uint32 t1) { return do_sub_e<true>(c, t0, t1); }
uint32 kpx_op_subfme (powerpc_cpu *c, uint32 t0) { return do_sub_e<false>(c, t0, 0xffffffffu); }
uint32 kpx_op_subfmeo(powerpc_cpu *c, uint32 t0) { return do_sub_e<true >(c, t0, 0xffffffffu); }
uint32 kpx_op_subfze (powerpc_cpu *c, uint32 t0) { return do_sub_e<false>(c, t0, 0); }
uint32 kpx_op_subfzeo(powerpc_cpu *c, uint32 t0) { return do_sub_e<true >(c, t0, 0); }

uint32 kpx_op_nego(powerpc_cpu *c, uint32 t0)
{
	c->jit_xer().set_ov(t0 == 0x80000000u);
	return -t0;
}

uint32 kpx_op_mullwo(powerpc_cpu *c, uint32 t0, uint32 t1)
{
	int64 rd = (int64)(int32)t0 * (int64)(int32)t1;
	c->jit_xer().set_ov((int32)rd != rd);
	return (uint32)rd;
}

// PPC divide edge cases differ from arm64 SDIV/UDIV; replicate exactly
uint32 kpx_op_divw(powerpc_cpu *, uint32 t0, uint32 t1)
{
	if (t1 == 0 || (t0 == 0x80000000u && t1 == 0xffffffffu))
		return (uint32)((int32)t0 >> 31);
	return (uint32)((int32)t0 / (int32)t1);
}
uint32 kpx_op_divwo(powerpc_cpu *c, uint32 t0, uint32 t1)
{
	if (t1 == 0 || (t0 == 0x80000000u && t1 == 0xffffffffu)) {
		c->jit_xer().set_ov(1);
		return (uint32)((int32)t0 >> 31);
	}
	c->jit_xer().set_ov(0);
	return (uint32)((int32)t0 / (int32)t1);
}
uint32 kpx_op_divwu(powerpc_cpu *, uint32 t0, uint32 t1)
{
	return t1 == 0 ? 0 : (t0 / t1);
}
uint32 kpx_op_divwuo(powerpc_cpu *c, uint32 t0, uint32 t1)
{
	if (t1 == 0) { c->jit_xer().set_ov(1); return 0; }
	c->jit_xer().set_ov(0);
	return t0 / t1;
}

// sraw / srawi: arithmetic right shift setting XER.CA
uint32 kpx_op_sraw(powerpc_cpu *c, uint32 t0, uint32 t1)
{
	t1 &= 0x3f;
	if (t1 & 0x20) { uint32 sb = t0 >> 31; c->jit_xer().set_ca(sb); return (uint32)-(int32)sb; }
	uint32 rd = (uint32)((int32)t0 >> t1);
	c->jit_xer().set_ca(((int32)t0 < 0) && (t0 & ~(0xffffffffu << t1)));
	return rd;
}
uint32 kpx_op_srawi(powerpc_cpu *c, uint32 t0, uint32 n)
{
	uint32 rd = (uint32)((int32)t0 >> n);
	c->jit_xer().set_ca(((int32)t0 < 0) && (t0 & ~(0xffffffffu << n)));
	return rd;
}

// XER pack/unpack (four bytes <-> 32-bit word)
uint32 kpx_op_load_xer(powerpc_cpu *c) { return c->jit_xer().get(); }
void   kpx_op_store_xer(powerpc_cpu *c, uint32 v) { c->jit_xer().set(v); }

// ---- guest memory access ---------------------------------------------------
// Under MEM_BULK the generated code translates flat guest->host inline
// against the VMBASE register (x23) and only calls these helpers on the
// coarse-filter cold path (kernel-data windows and wild addresses); the vm
// accessors then apply the exact translation semantics (32-bit wrap, window
// redirect, VMBaseDiff, big-endian byteswap). Without MEM_BULK every access
// still routes through here.
extern "C" uintptr kpx_vm_base(void)
{
#ifdef MEM_BULK
	return VMBaseDiff;
#else
	return 0;
#endif
}

static inline void kpx_mem_cold_instrument()
{
#ifdef KPX_JIT_INSTRUMENT
	// Differential-harness hook: proves the inline-fastmem cold path (and
	// with it the coarse filter) is being exercised (never defined in
	// shipping builds)
	extern unsigned long kpx_jit_mem_cold_count;
	kpx_jit_mem_cold_count++;
#endif
}

uint32 kpx_vm_read_1(uint32 ea) { kpx_mem_cold_instrument(); return vm_read_memory_1(ea); }
uint32 kpx_vm_read_2(uint32 ea) { kpx_mem_cold_instrument(); return vm_read_memory_2(ea); }
uint32 kpx_vm_read_4(uint32 ea) { kpx_mem_cold_instrument(); return vm_read_memory_4(ea); }
void kpx_vm_write_1(uint32 ea, uint32 v) { kpx_mem_cold_instrument(); vm_write_memory_1(ea, v); }
void kpx_vm_write_2(uint32 ea, uint32 v) { kpx_mem_cold_instrument(); vm_write_memory_2(ea, v); }
void kpx_vm_write_4(uint32 ea, uint32 v) { kpx_mem_cold_instrument(); vm_write_memory_4(ea, v); }

void kpx_op_lmw(powerpc_cpu *c, uint32 ea, uint32 r)
{
	for (uint32 i = r; i <= 31; i++, ea += 4)
		c->gpr(i) = vm_read_memory_4(ea);
}
void kpx_op_stmw(powerpc_cpu *c, uint32 ea, uint32 r)
{
	for (uint32 i = r; i <= 31; i++, ea += 4)
		vm_write_memory_4(ea, c->gpr(i));
}

// lwarx/stwcx reservation protocol (single-CPU form, KPX_MAX_CPUS == 1)
uint32 kpx_op_lwarx(powerpc_cpu *c, uint32 ea)
{
	uint32 v = vm_read_memory_4(ea);
	c->jit_regs().reserve_valid = 1;
	c->jit_regs().reserve_addr = ea;
	return v;
}
void kpx_op_stwcx(powerpc_cpu *c, uint32 val, uint32 ea)
{
	powerpc_registers &r = c->jit_regs();
	uint32 cr = r.cr.get() & ~0xf0000000;
	cr |= c->jit_xer().get_so() << 28;
	if (r.reserve_valid) {
		r.reserve_valid = 0;
		if (r.reserve_addr == ea) {
			vm_write_memory_4(ea, val);
			cr |= 0x20000000;	// EQ: store performed
		}
	}
	r.cr.set(cr);
}

void kpx_op_dcbz(uint32 ea)
{
	ea &= (uint32)-32;
	uint8 *p = vm_do_get_real_address(ea);
	for (int i = 0; i < 32; i++)
		p[i] = 0;
}

// AltiVec 128-bit and element loads/stores. Transcribed from the dyngen op
// bodies (ppc-dyngen-ops.cpp op_load_vect_VD_T0 & friends): w[i] holds
// guest word element i as a host-endian value; the vm accessors provide
// byteswap and the kernel-window redirect.
void kpx_op_load_vect(void *cpu, void *vrp, uint32 ea)
{
	powerpc_vr &v = *(powerpc_vr *)vrp;
	ea &= ~15;
	v.w[0] = vm_read_memory_4(ea +  0);
	v.w[1] = vm_read_memory_4(ea +  4);
	v.w[2] = vm_read_memory_4(ea +  8);
	v.w[3] = vm_read_memory_4(ea + 12);
}
void kpx_op_store_vect(void *cpu, void *vrp, uint32 ea)
{
	powerpc_vr &v = *(powerpc_vr *)vrp;
	ea &= ~15;
	vm_write_memory_4(ea +  0, v.w[0]);
	vm_write_memory_4(ea +  4, v.w[1]);
	vm_write_memory_4(ea +  8, v.w[2]);
	vm_write_memory_4(ea + 12, v.w[3]);
}
void kpx_op_load_word_vect(void *cpu, void *vrp, uint32 ea)
{
	powerpc_vr &v = *(powerpc_vr *)vrp;
	v.w[(ea >> 2) & 3] = vm_read_memory_4(ea & ~3);
}
void kpx_op_store_word_vect(void *cpu, void *vrp, uint32 ea)
{
	powerpc_vr &v = *(powerpc_vr *)vrp;
	vm_write_memory_4(ea & ~3, v.w[(ea >> 2) & 3]);
}

} // extern "C"

// ---- floating point --------------------------------------------------------
// Transcribed from the interpreter's execute_fp_arith / fp_classify
// (ppc-execute.cpp) and the C.6/C.7 single-precision converters
// (ppc-execute.hpp): FP arithmetic computes in double via the same
// expressions (mathlib_fmadd/fmsub for the fused family), then updates
// FPSCR[FPRF] with the class and sign of the result unless FPSCR[VE] is
// set. The FABS/FMR/FNABS/FNEG move ops do not classify (decode table
// passes FPSCR=false) and are emitted inline, not through helpers.

template< class FP >
static inline void kpx_fp_classify(powerpc_cpu *c, FP x)
{
	uint32 f = c->jit_regs().fpscr & ~FPSCR_FPRF_field::mask();
	switch (fpclassify(x)) {
	case FP_NAN:
		f |= FPSCR_FPRF_FU_field::mask() | FPSCR_FPRF_C_field::mask();
		break;
	case FP_ZERO:
		f |= FPSCR_FPRF_FE_field::mask();
		if (signbit(x))
			f |= FPSCR_FPRF_C_field::mask();
		break;
	case FP_INFINITE:
		f |= FPSCR_FPRF_FU_field::mask();
		goto FL_FG_field;
	case FP_SUBNORMAL:
		f |= FPSCR_FPRF_C_field::mask();
		// fall-through
	case FP_NORMAL:
	  FL_FG_field:
		if (x < 0)
			f |= FPSCR_FPRF_FL_field::mask();
		else
			f |= FPSCR_FPRF_FG_field::mask();
		break;
	}
	c->jit_regs().fpscr = f;
}

// Result commit for double-typed and float-typed instructions (the FP
// template parameter in the decode table): classify runs on the same-typed
// value the interpreter uses; the FPR always receives the double
static inline void kpx_fp_instrument()
{
#ifdef KPX_JIT_INSTRUMENT
	// Differential-harness hook: proves the native FP path executed
	// (never defined in shipping builds)
	extern unsigned long kpx_jit_fp_helper_count;
	kpx_jit_fp_helper_count++;
#endif
}
static inline double kpx_fp_ret_d(powerpc_cpu *c, double d)
{
	kpx_fp_instrument();
	if (!FPSCR_VE_field::test(c->jit_regs().fpscr))
		kpx_fp_classify(c, d);
	return d;
}
static inline double kpx_fp_ret_f(powerpc_cpu *c, float d)
{
	kpx_fp_instrument();
	if (!FPSCR_VE_field::test(c->jit_regs().fpscr))
		kpx_fp_classify(c, d);
	return d;
}

extern "C" {

double kpx_fp_fadd (powerpc_cpu *c, double a, double b) { return kpx_fp_ret_d(c, a + b); }
double kpx_fp_fsub (powerpc_cpu *c, double a, double b) { return kpx_fp_ret_d(c, a - b); }
double kpx_fp_fmul (powerpc_cpu *c, double a, double b) { return kpx_fp_ret_d(c, a * b); }
double kpx_fp_fdiv (powerpc_cpu *c, double a, double b) { return kpx_fp_ret_d(c, a / b); }
double kpx_fp_fadds(powerpc_cpu *c, double a, double b) { return kpx_fp_ret_f(c, (float)(a + b)); }
double kpx_fp_fsubs(powerpc_cpu *c, double a, double b) { return kpx_fp_ret_f(c, (float)(a - b)); }
double kpx_fp_fmuls(powerpc_cpu *c, double a, double b) { return kpx_fp_ret_f(c, (float)(a * b)); }
double kpx_fp_fdivs(powerpc_cpu *c, double a, double b) { return kpx_fp_ret_f(c, (float)(a / b)); }

// Fused family: operands arrive as (frA, frC, frB) — multiplier second,
// addend third — matching the translator's F0/F1/F2 load order. FNMADDS
// and FNMSUBS are double-typed in the decode table (negation applied
// after single rounding), unlike FMADDS/FMSUBS which are float-typed.
double kpx_fp_fmadd  (powerpc_cpu *c, double a, double b, double x) { return kpx_fp_ret_d(c, mathlib_fmadd(a, b, x)); }
double kpx_fp_fmsub  (powerpc_cpu *c, double a, double b, double x) { return kpx_fp_ret_d(c, mathlib_fmsub(a, b, x)); }
double kpx_fp_fnmadd (powerpc_cpu *c, double a, double b, double x) { return kpx_fp_ret_d(c, -mathlib_fmadd(a, b, x)); }
double kpx_fp_fnmsub (powerpc_cpu *c, double a, double b, double x) { return kpx_fp_ret_d(c, -mathlib_fmsub(a, b, x)); }
double kpx_fp_fmadds (powerpc_cpu *c, double a, double b, double x) { return kpx_fp_ret_f(c, (float)mathlib_fmadd(a, b, x)); }
double kpx_fp_fmsubs (powerpc_cpu *c, double a, double b, double x) { return kpx_fp_ret_f(c, (float)mathlib_fmsub(a, b, x)); }
double kpx_fp_fnmadds(powerpc_cpu *c, double a, double b, double x) { return kpx_fp_ret_d(c, -(float)mathlib_fmadd(a, b, x)); }
double kpx_fp_fnmsubs(powerpc_cpu *c, double a, double b, double x) { return kpx_fp_ret_d(c, -(float)mathlib_fmsub(a, b, x)); }

// FP loads/stores: 64-bit vm access plus the single-precision converters
// transcribed from ppc-execute.hpp (fp_load_single_convert /
// fp_store_single_convert, including the denormalization window). Under
// MEM_BULK, read_8/write_8/load_single are cold-path only (the inline hot
// path replicates them: flat access + REV, and (double)f == FCVT for
// load_single); store_single stays a helper unconditionally because the
// out-of-range denormalization cases are NOT a plain FCVT.
uint64 kpx_vm_read_8(uint32 ea) { kpx_mem_cold_instrument(); return vm_read_memory_8(ea); }
void kpx_vm_write_8(uint32 ea, uint64 v) { kpx_mem_cold_instrument(); vm_write_memory_8(ea, v); }

uint64 kpx_fp_load_single(uint32 ea)
{
	kpx_mem_cold_instrument();
	union { uint32 i; float f; } s;
	union { uint64 j; double d; } t;
	s.i = vm_read_memory_4(ea);
	t.d = (double)s.f;
	return t.j;
}
void kpx_fp_store_single(uint32 ea, uint64 v)
{
	const int exp = (v >> 52) & 0x7ff;
	uint32 w;
	if (exp < 874 || exp > 896) {
		// No denormalization required (or "undefined" behaviour)
		w = (uint32)(((v >> 32) & 0xc0000000) | ((v >> 29) & 0x3fffffff));
	}
	else {
		// Handle denormalization (874 <= frS[1 - 11] <= 896)
		union { uint64 j; double d; } t;
		union { uint32 i; float f; } s;
		t.j = v;
		s.f = (float)t.d;
		w = s.i;
	}
	vm_write_memory_4(ea, w);
}

} // extern "C"

#endif // ENABLE_DYNGEN && __aarch64__
