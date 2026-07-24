/*
 *  ppc-jit.cpp - PowerPC dynamic translation (mid-level)
 *
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

#include "sysdeps.h"

#if ENABLE_DYNGEN

#include "cpu/jit/dyngen-exec.h"
#include "cpu/ppc/ppc-jit.hpp"
#include "cpu/ppc/ppc-cpu.hpp"
#include "cpu/ppc/ppc-instructions.hpp"
#include "cpu/ppc/ppc-operands.hpp"
#include "utils/utils-cpuinfo.hpp"
#include "utils/utils-sentinel.hpp"

// Mid-level code generator info
const powerpc_jit::jit_info_t *powerpc_jit::jit_info[PPC_I(MAX)];

// PowerPC JIT initializer
powerpc_jit::powerpc_jit(dyngen_cpu_base cpu)
	: powerpc_dyngen(cpu)
{
}

#if defined(__i386__) || defined(__x86_64__)
// An operand that refers to an address relative to the emulated machine
static x86_memory_operand vm_memory_operand(int32 d, int b, int i = X86_NOREG, int s = 1) {
	return x86_memory_operand(d + VMBaseDiff, b, i, s);
}
#endif

bool powerpc_jit::initialize(void)
{
	if (!powerpc_dyngen::initialize())
		return false;

	static bool once = true;

	if (once) {
		once = false;

		// default to no handler
		static const jit_info_t jit_not_available = {
			-1,
			(gen_handler_t)&powerpc_jit::gen_not_available,
		};
		for (int i = 0; i < PPC_I(MAX); i++)
			jit_info[i] = &jit_not_available;

		// generic altivec handlers
		static const jit_info_t gen_vector[] = {
#define DEFINE_OP(MNEMO, GEN_OP, DYNGEN_OP) \
			{ PPC_I(MNEMO), (gen_handler_t)&powerpc_jit::gen_vector_generic_##GEN_OP, &powerpc_dyngen::gen_op_##DYNGEN_OP }
			DEFINE_OP(VADDFP,	2, vaddfp_VD_V0_V1),
			DEFINE_OP(VSUBFP,	2, vsubfp_VD_V0_V1),
			DEFINE_OP(VMADDFP,	3, vmaddfp_VD_V0_V1_V2),
			DEFINE_OP(VNMSUBFP,	3, vnmsubfp_VD_V0_V1_V2),
			DEFINE_OP(VAND,		2, vand_VD_V0_V1),
			DEFINE_OP(VANDC,	2, vandc_VD_V0_V1),
			DEFINE_OP(VNOR,		2, vnor_VD_V0_V1),
			DEFINE_OP(VOR,		2, vor_VD_V0_V1),
			DEFINE_OP(VXOR,		2, vxor_VD_V0_V1),
			DEFINE_OP(MFVSCR,	1, mfvscr_VD),
			DEFINE_OP(MTVSCR,	1, mtvscr_V0),
#undef DEFINE_OP
#define DEFINE_OP(MNEMO, GEN_OP) \
			{ PPC_I(MNEMO), (gen_handler_t)&powerpc_jit::gen_vector_generic_##GEN_OP, }
			DEFINE_OP(LVX,		load),
			DEFINE_OP(LVXL,		load),
			DEFINE_OP(LVEWX,	load_word),
			DEFINE_OP(STVX,		store),
			DEFINE_OP(STVXL,	store),
			DEFINE_OP(STVEWX,	store_word),
#undef DEFINE_OP
		};
		for (int i = 0; i < sizeof(gen_vector) / sizeof(gen_vector[0]); i++)
			jit_info[gen_vector[i].mnemo] = &gen_vector[i];

#if defined(__aarch64__)
		// NEON handlers: dyngen-op route through the generic handlers
		// (V0/V1/V2 pointers in x20-x22, VD in x24); op bodies live in
		// ppc-dyngen-ops-arm64.hpp. The mmx_* op names are historical --
		// on arm64 they are plain NEON bodies with the same semantics.
		static const jit_info_t neon_vector[] = {
#define DEFINE_OP(MNEMO, GEN_OP, DYNGEN_OP) \
			{ PPC_I(MNEMO), (gen_handler_t)&powerpc_jit::gen_vector_generic_##GEN_OP, &powerpc_dyngen::gen_op_##DYNGEN_OP }
			DEFINE_OP(VADDUBM,	2, mmx_vaddubm),
			DEFINE_OP(VADDUHM,	2, mmx_vadduhm),
			DEFINE_OP(VADDUWM,	2, mmx_vadduwm),
			DEFINE_OP(VSUBUBM,	2, mmx_vsububm),
			DEFINE_OP(VSUBUHM,	2, mmx_vsubuhm),
			DEFINE_OP(VSUBUWM,	2, mmx_vsubuwm),
			DEFINE_OP(VMAXSH,	2, mmx_vmaxsh),
			DEFINE_OP(VMAXUB,	2, mmx_vmaxub),
			DEFINE_OP(VMINSH,	2, mmx_vminsh),
			DEFINE_OP(VMINUB,	2, mmx_vminub),
			DEFINE_OP(VAVGUB,	2, neon_vavgub),
			DEFINE_OP(VAVGUH,	2, neon_vavguh),
			DEFINE_OP(VCMPEQUB,	c, mmx_vcmpequb),
			DEFINE_OP(VCMPEQUH,	c, mmx_vcmpequh),
			DEFINE_OP(VCMPEQUW,	c, mmx_vcmpequw),
			DEFINE_OP(VCMPGTSB,	c, mmx_vcmpgtsb),
			DEFINE_OP(VCMPGTSH,	c, mmx_vcmpgtsh),
			DEFINE_OP(VCMPGTSW,	c, mmx_vcmpgtsw),
			DEFINE_OP(VCMPEQFP,	c, neon_vcmpeqfp),
			DEFINE_OP(VCMPGEFP,	c, neon_vcmpgefp),
			DEFINE_OP(VCMPGTFP,	c, neon_vcmpgtfp),
			DEFINE_OP(VSEL,		3, neon_vsel),
			DEFINE_OP(VPERM,	3, neon_vperm),
#undef DEFINE_OP
#define DEFINE_OP(MNEMO, GEN_OP) \
			{ PPC_I(MNEMO), (gen_handler_t)&powerpc_jit::gen_neon_##GEN_OP, }
			DEFINE_OP(VSPLTB,	vsplat),
			DEFINE_OP(VSPLTH,	vsplat),
			DEFINE_OP(VSPLTW,	vsplat),
			DEFINE_OP(VSPLTISB,	vsplatis),
			DEFINE_OP(VSPLTISH,	vsplatis),
			DEFINE_OP(VSPLTISW,	vsplatis),
#undef DEFINE_OP
		};
		for (int i = 0; i < sizeof(neon_vector) / sizeof(neon_vector[0]); i++)
			jit_info[neon_vector[i].mnemo] = &neon_vector[i];
#endif

#if defined(__i386__) || defined(__x86_64__)
		// x86 optimized handlers
		static const jit_info_t x86_vector[] = {
#define DEFINE_OP(MNEMO, GEN_OP) \
			{ PPC_I(MNEMO), (gen_handler_t)&powerpc_jit::gen_x86_##GEN_OP, }
			DEFINE_OP(MTVSCR,	mtvscr),
			DEFINE_OP(MFVSCR,	mfvscr),
			DEFINE_OP(LVX,		lvx),
			DEFINE_OP(LVXL,		lvx),
			DEFINE_OP(STVX,		stvx),
			DEFINE_OP(STVXL,	stvx)
#undef DEFINE_OP
		};
		for (int i = 0; i < sizeof(x86_vector) / sizeof(x86_vector[0]); i++) {
#if defined(__APPLE__)
			// lvx/stvx fold VMBaseDiff into an int32 displacement, which
			// cannot hold MEM_BULK's 64-bit base; leave them to the
			// generic (stub-translated) vector load/store ops.
			if (x86_vector[i].mnemo == PPC_I(LVX) || x86_vector[i].mnemo == PPC_I(LVXL)
					|| x86_vector[i].mnemo == PPC_I(STVX) || x86_vector[i].mnemo == PPC_I(STVXL))
				continue;
#endif
			jit_info[x86_vector[i].mnemo] = &x86_vector[i];
		}

		// MMX optimized handlers
		static const jit_info_t mmx_vector[] = {
#define DEFINE_OP(MNEMO, GEN_OP, DYNGEN_OP) \
			{ PPC_I(MNEMO), (gen_handler_t)&powerpc_jit::gen_mmx_arith_##GEN_OP, &powerpc_dyngen::gen_op_mmx_##DYNGEN_OP }
			DEFINE_OP(VADDUBM,	2, vaddubm),
			DEFINE_OP(VADDUHM,	2, vadduhm),
			DEFINE_OP(VADDUWM,	2, vadduwm),
			DEFINE_OP(VAND,		2, vand),
			DEFINE_OP(VANDC,	2, vandc),
			DEFINE_OP(VCMPEQUB,	c, vcmpequb),
			DEFINE_OP(VCMPEQUH,	c, vcmpequh),
			DEFINE_OP(VCMPEQUW,	c, vcmpequw),
			DEFINE_OP(VCMPGTSB,	c, vcmpgtsb),
			DEFINE_OP(VCMPGTSH,	c, vcmpgtsh),
			DEFINE_OP(VCMPGTSW,	c, vcmpgtsw),
			DEFINE_OP(VOR,		2, vor),
			DEFINE_OP(VSUBUBM,	2, vsububm),
			DEFINE_OP(VSUBUHM,	2, vsubuhm),
			DEFINE_OP(VSUBUWM,	2, vsubuwm),
			DEFINE_OP(VXOR,		2, vxor)
#undef DEFINE_OP
		};
		if (cpuinfo_check_mmx()) {
			for (int i = 0; i < sizeof(mmx_vector) / sizeof(mmx_vector[0]); i++)
				jit_info[mmx_vector[i].mnemo] = &mmx_vector[i];
		}

		// SSE optimized handlers
		static const jit_info_t sse_vector[] = {
			// new MMX instructions brought into SSE capable CPUs
#define DEFINE_OP(MNEMO, GEN_OP, DYNGEN_OP) \
			{ PPC_I(MNEMO), (gen_handler_t)&powerpc_jit::gen_mmx_arith_##GEN_OP, &powerpc_dyngen::gen_op_mmx_##DYNGEN_OP }
			DEFINE_OP(VMAXSH,	2, vmaxsh),
			DEFINE_OP(VMAXUB,	2, vmaxub),
			DEFINE_OP(VMINSH,	2, vminsh),
			DEFINE_OP(VMINUB,	2, vminub),
#undef DEFINE_OP
			// full SSE instructions
#define DEFINE_OP(MNEMO, GEN_OP, TYPE_OP, SSE_OP) \
			{ PPC_I(MNEMO), (gen_handler_t)&powerpc_jit::gen_sse_arith_##GEN_OP, (X86_INSN_SSE_##TYPE_OP << 8) | X86_SSE_##SSE_OP }
			DEFINE_OP(VADDFP,	2, PS,ADD),
			DEFINE_OP(VAND,		2, PS,AND),
			DEFINE_OP(VANDC,	s, PS,ANDN),
			DEFINE_OP(VMAXFP,	2, PS,MAX),
			DEFINE_OP(VMINFP,	2, PS,MIN),
			DEFINE_OP(VOR,		2, PS,OR),
			DEFINE_OP(VSUBFP,	2, PS,SUB),
			DEFINE_OP(VXOR,		2, PS,XOR),
			DEFINE_OP(VMINUB,	2, PI,PMINUB),
			DEFINE_OP(VMAXUB,	2, PI,PMAXUB),
			DEFINE_OP(VMINSH,	2, PI,PMINSW),
			DEFINE_OP(VMAXSH,	2, PI,PMAXSW),
			DEFINE_OP(VAVGUB,	2, PI,PAVGB),
			DEFINE_OP(VAVGUH,	2, PI,PAVGW),
#undef DEFINE_OP
#define DEFINE_OP(MNEMO, COND) \
			{ PPC_I(MNEMO), (gen_handler_t)&powerpc_jit::gen_sse_arith_c, X86_SSE_CC_##COND }
			DEFINE_OP(VCMPEQFP,	EQ),
			DEFINE_OP(VCMPGEFP,	GE),
			DEFINE_OP(VCMPGTFP,	GT),
#undef DEFINE_OP
#define DEFINE_OP(MNEMO, GEN_OP) \
			{ PPC_I(MNEMO), (gen_handler_t)&powerpc_jit::gen_sse_##GEN_OP }
			DEFINE_OP(VSEL,		vsel),
			DEFINE_OP(VMADDFP,	vmaddfp),
			DEFINE_OP(VNMSUBFP,	vnmsubfp)
#undef DEFINE_OP
		};

#if defined(__APPLE__)
		// Packed-float fast paths whose SSE semantics differ from the
		// interpreter's C arithmetic — NaN sign/payload, ±0 ordering in
		// max/min, non-fused multiply-add rounding, unordered compares,
		// and hardware estimate precision. Keep these on the generic ops
		// so the JIT stays bit-identical with the interpreter (the
		// lockstep harness holds this line).
#define KPX_SSE_FLOAT_INEXACT(m) \
		((m) == PPC_I(VADDFP) || (m) == PPC_I(VSUBFP)      \
		 || (m) == PPC_I(VMAXFP) || (m) == PPC_I(VMINFP)   \
		 || (m) == PPC_I(VMADDFP) || (m) == PPC_I(VNMSUBFP) \
		 || (m) == PPC_I(VCMPEQFP) || (m) == PPC_I(VCMPGEFP) \
		 || (m) == PPC_I(VCMPGTFP) \
		 || (m) == PPC_I(VREFP) || (m) == PPC_I(VRSQRTEFP))
#else
#define KPX_SSE_FLOAT_INEXACT(m) 0
#endif

		if (cpuinfo_check_sse()) {
			for (int i = 0; i < sizeof(sse_vector) / sizeof(sse_vector[0]); i++) {
				if (KPX_SSE_FLOAT_INEXACT(sse_vector[i].mnemo))
					continue;
				jit_info[sse_vector[i].mnemo] = &sse_vector[i];
			}
		}

		// SSE2 optimized handlers
		static const jit_info_t sse2_vector[] = {
#define DEFINE_OP(MNEMO, GEN_OP, TYPE_OP, SSE_OP) \
			{ PPC_I(MNEMO), (gen_handler_t)&powerpc_jit::gen_sse2_arith_##GEN_OP, (X86_INSN_SSE_##TYPE_OP << 8) | X86_SSE_##SSE_OP }
			DEFINE_OP(VADDUBM,	2, PI,PADDB),
			DEFINE_OP(VADDUHM,	2, PI,PADDW),
			DEFINE_OP(VADDUWM,	2, PI,PADDD),
			DEFINE_OP(VSUBUBM,	2, PI,PSUBB),
			DEFINE_OP(VSUBUHM,	2, PI,PSUBW),
			DEFINE_OP(VSUBUWM,	2, PI,PSUBD),
			DEFINE_OP(VAND,		2, PI,PAND),
			DEFINE_OP(VANDC,	s, PI,PANDN),
			DEFINE_OP(VOR,		2, PI,POR),
			DEFINE_OP(VXOR,		2, PI,PXOR),
			DEFINE_OP(VCMPEQUB,	c, PI,PCMPEQB),
			DEFINE_OP(VCMPEQUH,	c, PI,PCMPEQW),
			DEFINE_OP(VCMPEQUW,	c, PI,PCMPEQD),
			DEFINE_OP(VCMPGTSB,	c, PI,PCMPGTB),
			DEFINE_OP(VCMPGTSH,	c, PI,PCMPGTW),
			DEFINE_OP(VCMPGTSW,	c, PI,PCMPGTD),
			DEFINE_OP(VREFP,	2, PS,RCP),
			DEFINE_OP(VRSQRTEFP,2, PS,RSQRT),
#undef DEFINE_OP
#define DEFINE_OP(MNEMO, GEN_OP) \
			{ PPC_I(MNEMO), (gen_handler_t)&powerpc_jit::gen_sse2_##GEN_OP, }
			DEFINE_OP(VSEL,		vsel),
			DEFINE_OP(VSLDOI,	vsldoi),
			DEFINE_OP(VSPLTB,	vspltb),
			DEFINE_OP(VSPLTH,	vsplth),
			DEFINE_OP(VSPLTW,	vspltw),
			DEFINE_OP(VSPLTISB,	vspltisb),
			DEFINE_OP(VSPLTISH,	vspltish),
			DEFINE_OP(VSPLTISW,	vspltisw)
#undef DEFINE_OP
		};

		if (cpuinfo_check_sse2()) {
			for (int i = 0; i < sizeof(sse2_vector) / sizeof(sse2_vector[0]); i++) {
				if (KPX_SSE_FLOAT_INEXACT(sse2_vector[i].mnemo))
					continue;
				jit_info[sse2_vector[i].mnemo] = &sse2_vector[i];
			}
		}

#if defined(__APPLE__) && defined(__x86_64__)
		// Vector-float ops go to the interpreter wholesale. The frozen
		// generic dyngen ops were compiled from the upstream-era C and
		// cannot track this fork's evolved float semantics (fused
		// vmaddfp/vnmsubfp, NaN sign/payload propagation, estimate
		// precision), and the SSE fast paths differ further (±0 in
		// max/min, unordered compares). The lockstep harness holds the
		// JIT bit-identical to the interpreter; only the float family
		// pays the interpreter-invoke cost.
		static const int vecfp_to_interp[] = {
			PPC_I(VADDFP), PPC_I(VSUBFP), PPC_I(VMAXFP), PPC_I(VMINFP),
			PPC_I(VMADDFP), PPC_I(VNMSUBFP), PPC_I(VREFP), PPC_I(VRSQRTEFP),
			PPC_I(VCMPEQFP), PPC_I(VCMPGEFP), PPC_I(VCMPGTFP), PPC_I(VCMPBFP),
			PPC_I(VCTSXS), PPC_I(VCTUXS), PPC_I(VCFSX), PPC_I(VCFUX),
			PPC_I(VRFIN), PPC_I(VRFIZ), PPC_I(VRFIP), PPC_I(VRFIM),
			PPC_I(VLOGEFP), PPC_I(VEXPTEFP),
		};
		for (int i = 0; i < (int)(sizeof(vecfp_to_interp) / sizeof(vecfp_to_interp[0])); i++)
			jit_info[vecfp_to_interp[i]] = &jit_not_available;
#endif

		// SSSE3 optimized handlers
		static const jit_info_t ssse3_vector[] = {
#define DEFINE_OP(MNEMO, GEN_OP) \
			{ PPC_I(MNEMO), (gen_handler_t)&powerpc_jit::gen_ssse3_##GEN_OP, }
			DEFINE_OP(LVX,		lvx),
			DEFINE_OP(LVXL,		lvx),
			DEFINE_OP(STVX,		stvx),
			DEFINE_OP(STVXL,	stvx),
			DEFINE_OP(VPERM,	vperm)
#undef DEFINE_OP
		};

		// The SSSE3 fast paths reference their literal pools through
		// absolute disp32 operands, which requires the JIT data pool below
		// 4GB. Darwin has no MAP_32BIT, so under MEM_BULK that cannot be
		// guaranteed — leave lvx/stvx/vperm to the generic vector ops.
#if !defined(__APPLE__)
		if (cpuinfo_check_ssse3()) {
			for (int i = 0; i < sizeof(ssse3_vector) / sizeof(ssse3_vector[0]); i++)
				jit_info[ssse3_vector[i].mnemo] = &ssse3_vector[i];
		}
#endif
#endif
	}

	return true;
}

// Differential-harness hook: proves vector ops actually took the native
// path at translate time (never defined in shipping builds)
#ifdef KPX_JIT_INSTRUMENT
extern unsigned long kpx_jit_vector_native_count;
#define KPX_COUNT_VECTOR_NATIVE(ok) do { if (ok) kpx_jit_vector_native_count++; } while (0)
#else
#define KPX_COUNT_VECTOR_NATIVE(ok) do { } while (0)
#endif

// Dispatch mid-level code generators
bool powerpc_jit::gen_vector_1(int mnemo, int vD)
{
    if (jit_info[mnemo]->handler == (gen_handler_t)&powerpc_jit::gen_not_available) return false;
	bool ok = (this->*((bool (powerpc_jit::*)(int, int))jit_info[mnemo]->handler))(mnemo, vD);
	KPX_COUNT_VECTOR_NATIVE(ok);
	return ok;
}

bool powerpc_jit::gen_vector_2(int mnemo, int vD, int vA, int vB)
{
    if (jit_info[mnemo]->handler == (gen_handler_t)&powerpc_jit::gen_not_available) return false;
	bool ok = (this->*((bool (powerpc_jit::*)(int, int, int, int))jit_info[mnemo]->handler))(mnemo, vD, vA, vB);
	KPX_COUNT_VECTOR_NATIVE(ok);
	return ok;
}

bool powerpc_jit::gen_vector_3(int mnemo, int vD, int vA, int vB, int vC)
{
    if (jit_info[mnemo]->handler == (gen_handler_t)&powerpc_jit::gen_not_available) return false;
	bool ok = (this->*((bool (powerpc_jit::*)(int, int, int, int, int))jit_info[mnemo]->handler))(mnemo, vD, vA, vB, vC);
	KPX_COUNT_VECTOR_NATIVE(ok);
	return ok;
}

bool powerpc_jit::gen_vector_compare(int mnemo, int vD, int vA, int vB, bool Rc)
{
    if (jit_info[mnemo]->handler == (gen_handler_t)&powerpc_jit::gen_not_available) return false;
	bool ok = (this->*((bool (powerpc_jit::*)(int, int, int, int, bool))jit_info[mnemo]->handler))(mnemo, vD, vA, vB, Rc);
	KPX_COUNT_VECTOR_NATIVE(ok);
	return ok;
}


bool powerpc_jit::gen_not_available(int mnemo)
{
	return false;
}

bool powerpc_jit::gen_vector_generic_1(int mnemo, int vD)
{
	gen_load_ad_VD_VR(vD);
	(this->*(jit_info[mnemo]->o.dyngen_handler))();
	return true;
}

bool powerpc_jit::gen_vector_generic_2(int mnemo, int vD, int vA, int vB)
{
	gen_load_ad_VD_VR(vD);
	gen_load_ad_V0_VR(vA);
	gen_load_ad_V1_VR(vB);
	(this->*(jit_info[mnemo]->o.dyngen_handler))();
	return true;
}

bool powerpc_jit::gen_vector_generic_3(int mnemo, int vD, int vA, int vB, int vC)
{
	gen_load_ad_VD_VR(vD);
	gen_load_ad_V0_VR(vA);
	gen_load_ad_V1_VR(vB);
	gen_load_ad_V2_VR(vC);
	(this->*(jit_info[mnemo]->o.dyngen_handler))();
	return true;
}

bool powerpc_jit::gen_vector_generic_c(int mnemo, int vD, int vA, int vB, bool Rc)
{
	gen_vector_generic_2(mnemo, vD, vA, vB);
	if (Rc)
		gen_record_cr6_VD();
	return true;
}

bool powerpc_jit::gen_vector_generic_load(int mnemo, int vD, int rA, int rB)
{
	// NOTE: T0/VD are clobbered in the following instructions!
	gen_load_T0_GPR(rB);
	if (rA != 0) {
		gen_load_T1_GPR(rA);
		gen_add_32_T0_T1();
	}
	gen_load_vect_VD_T0(vD);
	return true;
}

bool powerpc_jit::gen_vector_generic_store(int mnemo, int vS, int rA, int rB)
{
	// NOTE: T0/VS are clobbered in the following instructions!
	gen_load_T0_GPR(rB);
	if (rA != 0) {
		gen_load_T1_GPR(rA);
		gen_add_32_T0_T1();
	}
	gen_store_vect_VS_T0(vS);
	return true;
}

bool powerpc_jit::gen_vector_generic_load_word(int mnemo, int vD, int rA, int rB)
{
	// NOTE: T0/VD are clobbered in the following instructions!
	gen_load_T0_GPR(rB);
	if (rA != 0) {
		gen_load_T1_GPR(rA);
		gen_add_32_T0_T1();
	}
	gen_load_word_VD_T0(vD);
	return true;
}

bool powerpc_jit::gen_vector_generic_store_word(int mnemo, int vS, int rA, int rB)
{
	// NOTE: T0/VS are clobbered in the following instructions!
	gen_load_T0_GPR(rB);
	if (rA != 0) {
		gen_load_T1_GPR(rA);
		gen_add_32_T0_T1();
	}
	gen_store_word_VS_T0(vS);
	return true;
}

#if defined(__aarch64__)
// NEON splats. The guest element number converts to a host lane with the
// byte-in-word involution: powerpc_vr.w[i] is guest word element i as a
// host-endian value, so guest byte k lives at host byte k^3 and guest
// halfword k at host half k^1 (words map identically).
bool powerpc_jit::gen_neon_vsplat(int mnemo, int vD, int uimm, int vB)
{
	gen_load_ad_VD_VR(vD);
	gen_load_ad_V0_VR(vB);
	switch (mnemo) {
	case PPC_I(VSPLTB): gen_op_neon_vsplat_b_im((uimm & 15) ^ 3); break;
	case PPC_I(VSPLTH): gen_op_neon_vsplat_h_im((uimm & 7) ^ 1); break;
	case PPC_I(VSPLTW): gen_op_neon_vsplat_w_im(uimm & 3); break;
	default: return false;
	}
	return true;
}

bool powerpc_jit::gen_neon_vsplatis(int mnemo, int vD, int simm, int unused)
{
	gen_load_ad_VD_VR(vD);
	switch (mnemo) {
	case PPC_I(VSPLTISB): gen_op_neon_vsplatis_b_im(simm); break;
	case PPC_I(VSPLTISH): gen_op_neon_vsplatis_h_im(simm); break;
	case PPC_I(VSPLTISW): gen_op_neon_vsplatis_w_im(simm); break;
	default: return false;
	}
	return true;
}
#endif

#if PPC_PROFILE_REGS_USE
// XXX update reginfo[] counts for xPPC_GPR() accesses
static uint8 dummy_ppc_context[sizeof(powerpc_cpu)];
#define xPPC_CONTEXT	((powerpc_cpu *)dummy_ppc_context)
#else
#define xPPC_CONTEXT	((powerpc_cpu *)0)
#endif
#define xPPC_FIELD(M)	(((uintptr)&xPPC_CONTEXT->M) - (uintptr)xPPC_CONTEXT)
#define xPPC_GPR(N)		xPPC_FIELD(gpr(N))
#define xPPC_VR(N)		xPPC_FIELD(vr(N))
#define xPPC_CR			xPPC_FIELD(cr())
#define xPPC_VSCR		xPPC_FIELD(vscr())

#if defined(__i386__) || defined(__x86_64__)
/*
 *	X86 optimizations
 */

// mtvscr
bool powerpc_jit::gen_x86_mtvscr(int mnemo, int vD)
{
	gen_mov_32(x86_memory_operand(xPPC_VR(vD) + 3*4, REG_CPU_ID), REG_T0_ID);
	gen_mov_32(REG_T0_ID, x86_memory_operand(xPPC_VSCR, REG_CPU_ID));
	return true;
}

// mfvscr
bool powerpc_jit::gen_x86_mfvscr(int mnemo, int vB)
{
	gen_xor_32(REG_T0_ID, REG_T0_ID);
	gen_mov_32(x86_memory_operand(xPPC_VSCR, REG_CPU_ID), REG_T1_ID);
#if SIZEOF_VOID_P == 8
	gen_mov_64(REG_T0_ID, x86_memory_operand(xPPC_VR(vB) + 0*4, REG_CPU_ID));
#else
	gen_mov_32(REG_T0_ID, x86_memory_operand(xPPC_VR(vB) + 0*4, REG_CPU_ID));
	gen_mov_32(REG_T0_ID, x86_memory_operand(xPPC_VR(vB) + 1*4, REG_CPU_ID));
#endif
	gen_mov_32(REG_T0_ID, x86_memory_operand(xPPC_VR(vB) + 2*4, REG_CPU_ID));
	gen_mov_32(REG_T1_ID, x86_memory_operand(xPPC_VR(vB) + 3*4, REG_CPU_ID));
	return true;
}

// lvx, lvxl
bool powerpc_jit::gen_x86_lvx(int mnemo, int vD, int rA, int rB)
{
	gen_mov_32(x86_memory_operand(xPPC_GPR(rB), REG_CPU_ID), REG_T0_ID);
	if (rA != 0)
		gen_add_32(x86_memory_operand(xPPC_GPR(rA), REG_CPU_ID), REG_T0_ID);
	gen_and_32(x86_immediate_operand(-16), REG_T0_ID);
#if SIZEOF_VOID_P == 8
	gen_mov_64(vm_memory_operand(0, REG_T0_ID), REG_T1_ID);
	gen_mov_64(vm_memory_operand(8, REG_T0_ID), REG_T2_ID);
	gen_bswap_64(REG_T1_ID);
	gen_bswap_64(REG_T2_ID);
	gen_rol_64(x86_immediate_operand(32), REG_T1_ID);
	gen_rol_64(x86_immediate_operand(32), REG_T2_ID);
	gen_mov_64(REG_T1_ID, x86_memory_operand(xPPC_VR(vD) + 0, REG_CPU_ID));
	gen_mov_64(REG_T2_ID, x86_memory_operand(xPPC_VR(vD) + 8, REG_CPU_ID));
#else
	gen_mov_32(vm_memory_operand(0*4, REG_T0_ID), REG_T1_ID);
	gen_mov_32(vm_memory_operand(1*4, REG_T0_ID), REG_T2_ID);
	gen_bswap_32(REG_T1_ID);
	gen_bswap_32(REG_T2_ID);
	gen_mov_32(REG_T1_ID, x86_memory_operand(xPPC_VR(vD) + 0*4, REG_CPU_ID));
	gen_mov_32(REG_T2_ID, x86_memory_operand(xPPC_VR(vD) + 1*4, REG_CPU_ID));
	gen_mov_32(vm_memory_operand(2*4, REG_T0_ID), REG_T1_ID);
	gen_mov_32(vm_memory_operand(3*4, REG_T0_ID), REG_T2_ID);
	gen_bswap_32(REG_T1_ID);
	gen_bswap_32(REG_T2_ID);
	gen_mov_32(REG_T1_ID, x86_memory_operand(xPPC_VR(vD) + 2*4, REG_CPU_ID));
	gen_mov_32(REG_T2_ID, x86_memory_operand(xPPC_VR(vD) + 3*4, REG_CPU_ID));
#endif
	return true;
}

// stvx, stvxl
bool powerpc_jit::gen_x86_stvx(int mnemo, int vS, int rA, int rB)
{
	// NOTE: primitive scheduling
	gen_mov_32(x86_memory_operand(xPPC_GPR(rB), REG_CPU_ID), REG_T0_ID);
#if SIZEOF_VOID_P == 8
	gen_mov_64(x86_memory_operand(xPPC_VR(vS) + 0, REG_CPU_ID), REG_T1_ID);
	gen_mov_64(x86_memory_operand(xPPC_VR(vS) + 8, REG_CPU_ID), REG_T2_ID);
	if (rA != 0)
		gen_add_32(x86_memory_operand(xPPC_GPR(rA), REG_CPU_ID), REG_T0_ID);
	gen_bswap_64(REG_T1_ID);
	gen_bswap_64(REG_T2_ID);
	gen_and_32(x86_immediate_operand(-16), REG_T0_ID);
	gen_rol_64(x86_immediate_operand(32), REG_T1_ID);
	gen_rol_64(x86_immediate_operand(32), REG_T2_ID);
	gen_mov_64(REG_T1_ID, vm_memory_operand(0, REG_T0_ID));
	gen_mov_64(REG_T2_ID, vm_memory_operand(8, REG_T0_ID));
#else
	gen_mov_32(x86_memory_operand(xPPC_VR(vS) + 0*4, REG_CPU_ID), REG_T1_ID);
	gen_mov_32(x86_memory_operand(xPPC_VR(vS) + 1*4, REG_CPU_ID), REG_T2_ID);
	if (rA != 0)
		gen_add_32(x86_memory_operand(xPPC_GPR(rA), REG_CPU_ID), REG_T0_ID);
	gen_bswap_32(REG_T1_ID);
	gen_bswap_32(REG_T2_ID);
	gen_and_32(x86_immediate_operand(-16), REG_T0_ID);
	gen_mov_32(REG_T1_ID, vm_memory_operand(0*4, REG_T0_ID));
	gen_mov_32(REG_T2_ID, vm_memory_operand(1*4, REG_T0_ID));
	gen_mov_32(x86_memory_operand(xPPC_VR(vS) + 2*4, REG_CPU_ID), REG_T1_ID);
	gen_mov_32(x86_memory_operand(xPPC_VR(vS) + 3*4, REG_CPU_ID), REG_T2_ID);
	gen_bswap_32(REG_T1_ID);
	gen_bswap_32(REG_T2_ID);
	gen_mov_32(REG_T1_ID, vm_memory_operand(2*4, REG_T0_ID));
	gen_mov_32(REG_T2_ID, vm_memory_operand(3*4, REG_T0_ID));
#endif
	return true;
}

/*
 *	MMX optimizations
 */

// Generic MMX arith
bool powerpc_jit::gen_mmx_arith_2(int mnemo, int vD, int vA, int vB)
{
	gen_load_ad_VD_VR(vD);
	gen_load_ad_V0_VR(vA);
	gen_load_ad_V1_VR(vB);
	(this->*(jit_info[mnemo]->o.dyngen_handler))();
	gen_op_emms();
	return true;
}

// MMX comparison
bool powerpc_jit::gen_mmx_arith_c(int mnemo, int vD, int vA, int vB, bool Rc)
{
	gen_mmx_arith_2(mnemo, vD, vA, vB);
	if (Rc)
		gen_record_cr6_VD();
	return true;
}

/*
 *	SSE optimizations
 */

// Record CR6 (vD contains the result of the CMP instruction)
void powerpc_jit::gen_sse_record_cr6(int vD)
{
	// NOTE: %ecx & %edx are caller saved registers and not static allocated at this time
	assert(REG_T2_ID != (int)X86_ECX && REG_T2_ID != (int)X86_EDX);
	gen_xor_32(X86_ECX, X86_ECX);										// xor %t0,%t0
	gen_xor_32(X86_EDX, X86_EDX);										// xor %t1,%t1
	gen_insn(X86_INSN_SSE_PS, X86_SSE_MOVMSK, vD, REG_T2_ID);			// movmskps %v0,%t2
	gen_cmp_32(x86_immediate_operand(0), REG_T2_ID);					// cmp $0,%t2
	gen_setcc(X86_CC_Z, X86_CL);										// sete %t0
	gen_cmp_32(x86_immediate_operand(0xf), REG_T2_ID);					// cmp $0xf,%t1
	gen_setcc(X86_CC_E, X86_DL);										// sete %t1
	gen_lea_32(x86_memory_operand(0, X86_ECX, X86_EDX, 4), REG_T2_ID);	// %t2 = %t0 + %t1*4
	gen_mov_32(x86_memory_operand(xPPC_CR, REG_CPU_ID), X86_ECX);		// mov $xPPC_CR(%cpu),%t0
	gen_shl_32(x86_immediate_operand(5), REG_T2_ID);					// %t2 holds new cr6
	gen_and_32(x86_immediate_operand(0xffffff0f), X86_ECX);				// and $0xffffff0f,%t0
	gen_or_32(X86_ECX, REG_T2_ID);										// or %t0,%t2
	gen_mov_32(REG_T2_ID, x86_memory_operand(xPPC_CR, REG_CPU_ID));		// mov %t0,$xPPC_CR(%cpu)
}

// Generic SSE arith
bool powerpc_jit::gen_sse_arith_2(int mnemo, int vD, int vA, int vB)
{
	gen_movaps(x86_memory_operand(xPPC_VR(vA), REG_CPU_ID), REG_V0_ID);
	const uint16 insn = jit_info[mnemo]->o.value;
	gen_insn(insn >> 8, insn & 0xff, x86_memory_operand(xPPC_VR(vB), REG_CPU_ID), REG_V0_ID);
	gen_movaps(REG_V0_ID, x86_memory_operand(xPPC_VR(vD), REG_CPU_ID));
	return true;
}

// Generic SSE arith with swapped operands (ANDPS)
bool powerpc_jit::gen_sse_arith_s(int mnemo, int vD, int vA, int vB)
{
	return gen_sse_arith_2(mnemo, vD, vB, vA);
}

// SSE comparison (CMPPS)
bool powerpc_jit::gen_sse_arith_c(int mnemo, int vD, int vA, int vB, bool Rc)
{
	// NOTE: this uses swapped operands for GT, GE (no change for EQ)
	gen_movaps(x86_memory_operand(xPPC_VR(vB), REG_CPU_ID), REG_V0_ID);
	gen_cmpps(jit_info[mnemo]->o.value, x86_memory_operand(xPPC_VR(vA), REG_CPU_ID), REG_V0_ID);
	gen_movaps(REG_V0_ID, x86_memory_operand(xPPC_VR(vD), REG_CPU_ID));
	if (Rc)
		gen_sse_record_cr6(REG_V0_ID);
	return true;
}

// vmaddfp
bool powerpc_jit::gen_sse_vmaddfp(int mnemo, int vD, int vA, int vB, int vC)
{
	gen_movaps(x86_memory_operand(xPPC_VR(vA), REG_CPU_ID), REG_V0_ID);
	gen_mulps(x86_memory_operand(xPPC_VR(vC), REG_CPU_ID), REG_V0_ID);
	gen_addps(x86_memory_operand(xPPC_VR(vB), REG_CPU_ID), REG_V0_ID);
	gen_movaps(REG_V0_ID, x86_memory_operand(xPPC_VR(vD), REG_CPU_ID));
	return true;
}

// vnmsubfp
bool powerpc_jit::gen_sse_vnmsubfp(int mnemo, int vD, int vA, int vB, int vC)
{
	gen_movaps(x86_memory_operand(xPPC_VR(vA), REG_CPU_ID), REG_V0_ID);
	gen_xorps(REG_V1_ID, REG_V1_ID);
	gen_mulps(x86_memory_operand(xPPC_VR(vC), REG_CPU_ID), REG_V0_ID);
	gen_subps(x86_memory_operand(xPPC_VR(vB), REG_CPU_ID), REG_V0_ID);
	gen_subps(REG_V0_ID, REG_V1_ID);
	gen_movaps(REG_V1_ID, x86_memory_operand(xPPC_VR(vD), REG_CPU_ID));
	return true;
}

// vsel
bool powerpc_jit::gen_sse_vsel(int mnemo, int vD, int vA, int vB, int vC)
{
	// NOTE: simplified into (vB & vC) | (vA & ~vC)
	gen_movaps(x86_memory_operand(xPPC_VR(vC), REG_CPU_ID), REG_V0_ID);
	gen_movaps(x86_memory_operand(xPPC_VR(vB), REG_CPU_ID), REG_V1_ID);
	gen_movaps(x86_memory_operand(xPPC_VR(vA), REG_CPU_ID), REG_V2_ID);
	gen_andps(REG_V0_ID, REG_V1_ID);
	gen_andnps(REG_V2_ID, REG_V0_ID);
	gen_orps(REG_V1_ID, REG_V0_ID);
	gen_movaps(REG_V0_ID, x86_memory_operand(xPPC_VR(vD), REG_CPU_ID));
	return true;
}

/*
 *	SSE2 optimizations
 */

// Record CR6 (vD contains the result of the CMP instruction)
void powerpc_jit::gen_sse2_record_cr6(int vD)
{
	// NOTE: %ecx & %edx are caller saved registers and not static allocated at this time
	assert(REG_T2_ID != (int)X86_ECX && REG_T2_ID != (int)X86_EDX);
	gen_xor_32(X86_ECX, X86_ECX);										// xor %t0,%t0
	gen_xor_32(X86_EDX, X86_EDX);										// xor %t1,%t1
	gen_pmovmskb(vD, REG_T2_ID);										// pmovmskb %v0,%t2
	gen_cmp_32(x86_immediate_operand(0), REG_T2_ID);					// cmp $0,%t2
	gen_setcc(X86_CC_Z, X86_CL);										// sete %t0
	gen_cmp_32(x86_immediate_operand(0xffff), REG_T2_ID);				// cmp $0xffff,%t1
	gen_setcc(X86_CC_E, X86_EDX);										// sete %t1
	gen_lea_32(x86_memory_operand(0, X86_ECX, X86_EDX, 4), REG_T2_ID);	// %t2 = %t0 + %t1*4
	gen_mov_32(x86_memory_operand(xPPC_CR, REG_CPU_ID), X86_ECX);		// mov $xPPC_CR(%cpu),%t0
	gen_shl_32(x86_immediate_operand(5), REG_T2_ID);					// %t2 holds new cr6
	gen_and_32(x86_immediate_operand(0xffffff0f), X86_ECX);				// and $0xffffff0f,%t0
	gen_or_32(X86_ECX, REG_T2_ID);										// or %t0,%t2
	gen_mov_32(REG_T2_ID, x86_memory_operand(xPPC_CR, REG_CPU_ID));		// mov %t0,$xPPC_CR(%cpu)
}

// Generic SSE2 arith
bool powerpc_jit::gen_sse2_arith_2(int mnemo, int vD, int vA, int vB)
{
	gen_movdqa(x86_memory_operand(xPPC_VR(vA), REG_CPU_ID), REG_V0_ID);
	const uint16 insn = jit_info[mnemo]->o.value;
	gen_insn(insn >> 8, insn & 0xff, x86_memory_operand(xPPC_VR(vB), REG_CPU_ID), REG_V0_ID);
	gen_movdqa(REG_V0_ID, x86_memory_operand(xPPC_VR(vD), REG_CPU_ID));
	return true;
}

// Generic SSE2 arith with swapped operands (PANDN)
bool powerpc_jit::gen_sse2_arith_s(int mnemo, int vD, int vA, int vB)
{
	return gen_sse2_arith_2(mnemo, vD, vB, vA);
}

// SSE2 comparison (PCMPEQ, PCMPGT)
bool powerpc_jit::gen_sse2_arith_c(int mnemo, int vD, int vA, int vB, bool Rc)
{
	gen_sse2_arith_2(mnemo, vD, vA, vB);
	if (Rc)
		gen_sse2_record_cr6(REG_V0_ID);
	return true;
}

// vsldoi
bool powerpc_jit::gen_sse2_vsldoi(int mnemo, int vD, int vA, int vB, int SH)
{
	// Optimize out vsldoi vX,vX,vB,0
	if (SH == 0 && vA == vD)
		return true;

	gen_movdqa(x86_memory_operand(xPPC_VR(vA), REG_CPU_ID), REG_V0_ID);
	if (SH) {
		gen_movdqa(x86_memory_operand(xPPC_VR(vB), REG_CPU_ID), REG_V1_ID);
		gen_pshufd(x86_immediate_operand(0x1b), REG_V0_ID, REG_V0_ID);
		gen_pshufd(x86_immediate_operand(0x1b), REG_V1_ID, REG_V1_ID);
		gen_pslldq(x86_immediate_operand(SH), REG_V0_ID);
		gen_psrldq(x86_immediate_operand(16 - SH), REG_V1_ID);
		gen_por(REG_V1_ID, REG_V0_ID);
		gen_pshufd(x86_immediate_operand(0x1b), REG_V0_ID, REG_V0_ID);
	}
	gen_movdqa(REG_V0_ID, x86_memory_operand(xPPC_VR(vD), REG_CPU_ID));
	return true;
}

// vsel
bool powerpc_jit::gen_sse2_vsel(int mnemo, int vD, int vA, int vB, int vC)
{
	// NOTE: simplified into (vB & vC) | (vA & ~vC)
	gen_movdqa(x86_memory_operand(xPPC_VR(vC), REG_CPU_ID), REG_V0_ID);
	gen_movdqa(x86_memory_operand(xPPC_VR(vB), REG_CPU_ID), REG_V1_ID);
	gen_movdqa(x86_memory_operand(xPPC_VR(vA), REG_CPU_ID), REG_V2_ID);
	gen_pand(REG_V0_ID, REG_V1_ID);
	gen_pandn(REG_V2_ID, REG_V0_ID);
	gen_por(REG_V1_ID, REG_V0_ID);
	gen_movdqa(REG_V0_ID, x86_memory_operand(xPPC_VR(vD), REG_CPU_ID));
	return true;
}

/*
 *	Vector splat instructions
 *
 *  Reference: "Optimizing subroutines in assembly language", Agner, table 13.6
 */

void powerpc_jit::gen_sse2_vsplat(int vD, int rValue)
{
	gen_movd_lx(rValue, REG_V0_ID);
	gen_pshufd(x86_immediate_operand(0), REG_V0_ID, REG_V0_ID);
	gen_movdqa(REG_V0_ID, x86_memory_operand(xPPC_VR(vD), REG_CPU_ID));
}

// vspltisb
bool powerpc_jit::gen_sse2_vspltisb(int mnemo, int vD, int SIMM, int unused)
{
	switch (SIMM) {
	case 0:
		gen_pxor(REG_V0_ID, REG_V0_ID);
		goto commit;
	case 1:
		gen_pcmpeqw(REG_V0_ID, REG_V0_ID);
		gen_psrlw(x86_immediate_operand(15), REG_V0_ID);
		gen_packuswb(REG_V0_ID, REG_V0_ID);
		goto commit;
	case 2:
		gen_pcmpeqw(REG_V0_ID, REG_V0_ID);
		gen_psrlw(x86_immediate_operand(15), REG_V0_ID);
		gen_psllw(x86_immediate_operand(1), REG_V0_ID);
		gen_packuswb(REG_V0_ID, REG_V0_ID);
		goto commit;
	case 3:
		gen_pcmpeqw(REG_V0_ID, REG_V0_ID);
		gen_psrlw(x86_immediate_operand(14), REG_V0_ID);
		gen_packuswb(REG_V0_ID, REG_V0_ID);
		goto commit;
	case 4:
		gen_pcmpeqw(REG_V0_ID, REG_V0_ID);
		gen_psrlw(x86_immediate_operand(15), REG_V0_ID);
		gen_psllw(x86_immediate_operand(2), REG_V0_ID);
		gen_packuswb(REG_V0_ID, REG_V0_ID);
		goto commit;
	case -1:
		gen_pcmpeqw(REG_V0_ID, REG_V0_ID);
		goto commit;
	case -2:
		gen_pcmpeqw(REG_V0_ID, REG_V0_ID);
		gen_psllw(x86_immediate_operand(1), REG_V0_ID);
		gen_packsswb(REG_V0_ID, REG_V0_ID);
		goto commit;
	{
	  commit:
		gen_movdqa(REG_V0_ID, x86_memory_operand(xPPC_VR(vD), REG_CPU_ID));
		break;
	}
	default:
		const uint32 value = ((uint8)SIMM) * 0x01010101;
		gen_mov_32(x86_immediate_operand(value), REG_T0_ID);
		gen_sse2_vsplat(vD, REG_T0_ID);
		break;
	}
	return true;
}

// vspltish
bool powerpc_jit::gen_sse2_vspltish(int mnemo, int vD, int SIMM, int unused)
{
	switch (SIMM) {
	case 0:
		gen_pxor(REG_V0_ID, REG_V0_ID);
		goto commit;
	case 1:
		gen_pcmpeqw(REG_V0_ID, REG_V0_ID);
		gen_psrlw(x86_immediate_operand(15), REG_V0_ID);
		goto commit;
	case 2:
		gen_pcmpeqw(REG_V0_ID, REG_V0_ID);
		gen_psrlw(x86_immediate_operand(15), REG_V0_ID);
		gen_psllw(x86_immediate_operand(1), REG_V0_ID);
		goto commit;
	case 3:
		gen_pcmpeqw(REG_V0_ID, REG_V0_ID);
		gen_psrlw(x86_immediate_operand(14), REG_V0_ID);
		goto commit;
	case 4:
		gen_pcmpeqw(REG_V0_ID, REG_V0_ID);
		gen_psrlw(x86_immediate_operand(15), REG_V0_ID);
		gen_psllw(x86_immediate_operand(2), REG_V0_ID);
		goto commit;
	case -1:
		gen_pcmpeqw(REG_V0_ID, REG_V0_ID);
		goto commit;
	case -2:
		gen_pcmpeqw(REG_V0_ID, REG_V0_ID);
		gen_psllw(x86_immediate_operand(1), REG_V0_ID);
		goto commit;
	{
	  commit:
		gen_movdqa(REG_V0_ID, x86_memory_operand(xPPC_VR(vD), REG_CPU_ID));
		break;
	}
	default:
		const uint32 value = ((uint16)SIMM) * 0x10001;
		gen_mov_32(x86_immediate_operand(value), REG_T0_ID);
		gen_sse2_vsplat(vD, REG_T0_ID);
		break;
	}
	return true;
}

// vspltisw
bool powerpc_jit::gen_sse2_vspltisw(int mnemo, int vD, int SIMM, int unused)
{
	switch (SIMM) {
	case 0:
		gen_pxor(REG_V0_ID, REG_V0_ID);
		goto commit;
	case 1:
		gen_pcmpeqd(REG_V0_ID, REG_V0_ID);
		gen_psrld(x86_immediate_operand(31), REG_V0_ID);
		goto commit;
	case 2:
		gen_pcmpeqd(REG_V0_ID, REG_V0_ID);
		gen_psrld(x86_immediate_operand(31), REG_V0_ID);
		gen_pslld(x86_immediate_operand(1), REG_V0_ID);
		goto commit;
	case 3:
		gen_pcmpeqd(REG_V0_ID, REG_V0_ID);
		gen_psrld(x86_immediate_operand(30), REG_V0_ID);
		goto commit;
	case 4:
		gen_pcmpeqd(REG_V0_ID, REG_V0_ID);
		gen_psrld(x86_immediate_operand(31), REG_V0_ID);
		gen_pslld(x86_immediate_operand(2), REG_V0_ID);
		goto commit;
	case -1:
		gen_pcmpeqd(REG_V0_ID, REG_V0_ID);
		goto commit;
	case -2:
		gen_pcmpeqd(REG_V0_ID, REG_V0_ID);
		gen_pslld(x86_immediate_operand(1), REG_V0_ID);
		goto commit;
	{
	  commit:
		gen_movdqa(REG_V0_ID, x86_memory_operand(xPPC_VR(vD), REG_CPU_ID));
		break;
	}
	default:
		const uint32 value = SIMM;
		gen_mov_32(x86_immediate_operand(value), REG_T0_ID);
		gen_sse2_vsplat(vD, REG_T0_ID);
	}
	return true;
}

// vspltb
bool powerpc_jit::gen_sse2_vspltb(int mnemo, int vD, int UIMM, int vB)
{
	const int N = ev_mixed::byte_element(UIMM & 15);
	gen_mov_zx_8_32(x86_memory_operand(xPPC_VR(vB) + N * 1, REG_CPU_ID), REG_T0_ID);
	gen_imul_32(x86_immediate_operand(0x01010101), REG_T0_ID, REG_T0_ID);
	gen_sse2_vsplat(vD, REG_T0_ID);
	return true;
}

// vsplth
bool powerpc_jit::gen_sse2_vsplth(int mnemo, int vD, int UIMM, int vB)
{
	const int N = ev_mixed::half_element(UIMM & 7);
	gen_mov_zx_16_32(x86_memory_operand(xPPC_VR(vB) + N * 2, REG_CPU_ID), REG_T0_ID);
	gen_imul_32(x86_immediate_operand(0x10001), REG_T0_ID, REG_T0_ID);
	gen_sse2_vsplat(vD, REG_T0_ID);
	return true;
}

// vspltw
bool powerpc_jit::gen_sse2_vspltw(int mnemo, int vD, int UIMM, int vB)
{
	const int N = UIMM & 3;
	gen_mov_32(x86_memory_operand(xPPC_VR(vB) + N * 4, REG_CPU_ID), REG_T0_ID);
	gen_sse2_vsplat(vD, REG_T0_ID);
	return true;
}

/*
 *	SSSE3 optimizations
 */

uintptr powerpc_jit::gen_ssse3_vswap_mask(void)
{
	// We must get the following bytes in memory
	// 0x3 0x2 0x1 0x0 0x7 0x6 0x5 0x4 0xb 0xa 0x9 0x8 0xf 0xe 0xd 0xc
	static uintptr control_mask = 0;
	if (control_mask == 0) {
		static const uint8 value[16] = {
			0x03, 0x02, 0x01, 0x00, 0x07, 0x06, 0x05, 0x04,
			0x0b, 0x0a, 0x09, 0x08, 0x0f, 0x0e, 0x0d, 0x0c
		};
		control_mask = (uintptr)copy_data(value, sizeof(value));
		assert(control_mask <= 0xffffffff);
	}
	return control_mask;
}

// lvx, lvxl
bool powerpc_jit::gen_ssse3_lvx(int mnemo, int vD, int rA, int rB)
{
	gen_mov_32(x86_memory_operand(xPPC_GPR(rB), REG_CPU_ID), REG_T0_ID);
	if (rA != 0)
		gen_add_32(x86_memory_operand(xPPC_GPR(rA), REG_CPU_ID), REG_T0_ID);
	gen_and_32(x86_immediate_operand(-16), REG_T0_ID);

	x86_memory_operand vswapmask(gen_ssse3_vswap_mask(), X86_NOREG);
	gen_movdqa(vm_memory_operand(0, REG_T0_ID), REG_V0_ID);
	gen_insn(X86_INSN_SSE_3P, X86_SSSE3_PSHUFB, vswapmask, REG_V0_ID);
	gen_movdqa(REG_V0_ID, x86_memory_operand(xPPC_VR(vD), REG_CPU_ID));
	return true;
}

// stvx, stvxl
bool powerpc_jit::gen_ssse3_stvx(int mnemo, int vS, int rA, int rB)
{
	gen_mov_32(x86_memory_operand(xPPC_GPR(rB), REG_CPU_ID), REG_T0_ID);
	if (rA != 0)
		gen_add_32(x86_memory_operand(xPPC_GPR(rA), REG_CPU_ID), REG_T0_ID);
	gen_and_32(x86_immediate_operand(-16), REG_T0_ID);

	x86_memory_operand vswapmask(gen_ssse3_vswap_mask(), X86_NOREG);
	gen_movdqa(x86_memory_operand(xPPC_VR(vS), REG_CPU_ID), REG_V0_ID);
	gen_insn(X86_INSN_SSE_3P, X86_SSSE3_PSHUFB, vswapmask, REG_V0_ID);
	gen_movdqa(REG_V0_ID, vm_memory_operand(0, REG_T0_ID));
	return true;
}

// vperm
bool powerpc_jit::gen_ssse3_vperm(int mnemo, int vD, int vA, int vB, int vC)
{
	static uintptr zero_mask = 0;
	if (zero_mask == 0) {
		static const uint8 value[16] = {
			0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80,
			0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80
		};
		zero_mask = (uintptr)copy_data(value, sizeof(value));
		assert(zero_mask <= 0xffffffff);
	}

	static uintptr index_mask = 0;
	if (index_mask == 0) {
		static const uint8 value[16] = {
			0x1f, 0x1f, 0x1f, 0x1f, 0x1f, 0x1f, 0x1f, 0x1f,
			0x1f, 0x1f, 0x1f, 0x1f, 0x1f, 0x1f, 0x1f, 0x1f
		};
		index_mask = (uintptr)copy_data(value, sizeof(value));
		assert(index_mask <= 0xffffffff);
	};

	/*
	 * PROP_IMSB(T) = T.index|most significant bit of T.index (T.bit0 = T.bit3)
	 * --> used to handle one vector at a time
	 *
	 * T.A = PSHUFB(PROP_IMSB(vC & IndexMask), vA);
	 * T.B = PSHUFB(PROP_IMSB(vC & IndexMaxk) ^ ZeroMask, vB);
	 * vD = T.A | T.B
	 */
	x86_memory_operand swap_mask(gen_ssse3_vswap_mask(), X86_NOREG);
	gen_movdqa(x86_memory_operand(xPPC_VR(vC), REG_CPU_ID), REG_V2_ID);
	gen_movdqa(swap_mask, REG_V3_ID);
	gen_movdqa(x86_memory_operand(xPPC_VR(vA), REG_CPU_ID), REG_V0_ID);
	gen_pand(x86_memory_operand(index_mask, X86_NOREG), REG_V2_ID);
	gen_insn(X86_INSN_SSE_3P, X86_SSSE3_PSHUFB, REG_V3_ID, REG_V0_ID);
	gen_insn(X86_INSN_SSE_3P, X86_SSSE3_PSHUFB, REG_V3_ID, REG_V2_ID);
	gen_movdqa(REG_V2_ID, REG_V1_ID);
	gen_psllq(x86_immediate_operand(3), REG_V2_ID);
	gen_pand(x86_memory_operand(zero_mask, X86_NOREG), REG_V2_ID);
	gen_por(REG_V2_ID, REG_V1_ID);
	gen_movdqa(x86_memory_operand(xPPC_VR(vB), REG_CPU_ID), REG_V2_ID);
	gen_insn(X86_INSN_SSE_3P, X86_SSSE3_PSHUFB, REG_V1_ID, REG_V0_ID);
	gen_insn(X86_INSN_SSE_3P, X86_SSSE3_PSHUFB, REG_V3_ID, REG_V2_ID);
	gen_pxor(x86_memory_operand(zero_mask, X86_NOREG), REG_V1_ID);
	gen_insn(X86_INSN_SSE_3P, X86_SSSE3_PSHUFB, REG_V1_ID, REG_V2_ID);
	gen_por(REG_V2_ID, REG_V0_ID);
	gen_insn(X86_INSN_SSE_3P, X86_SSSE3_PSHUFB, REG_V3_ID, REG_V0_ID);
	gen_movdqa(REG_V0_ID, x86_memory_operand(xPPC_VR(vD), REG_CPU_ID));
	return true;
}
#endif

#endif //ENABLE_DYNGEN

// arm64 JIT helper functions (self-guarded on ENABLE_DYNGEN && __aarch64__).
// Compiled here to avoid a separate Xcode source-list entry.
#include "cpu/jit/arm64/arm64-helpers.cpp"
