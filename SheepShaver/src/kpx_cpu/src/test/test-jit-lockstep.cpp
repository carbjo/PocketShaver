/*
 *  test-jit-lockstep.cpp - interpreter vs JIT differential harness
 *
 *  Runs two powerpc_cpu instances in one process — one interpreter, one
 *  JIT — over synthetic guest programs and compares the full register
 *  file after each. The interpreter is the trusted oracle, so no
 *  pre-recorded reference file is needed. Deterministic: no ROM, no
 *  interrupts, no wall clock.
 *
 *  This is validation scaffolding for the arm64 JIT backend; it is not
 *  part of any shipping target.
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
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <mach/mach_time.h>
#include "vm_alloc.h"
#include "cpu/ppc/ppc-cpu.hpp"
#include "cpu/ppc/ppc-instructions.hpp"
#include "cpu/jit/jit-wx.hpp"

// ---- glue stubs the kpx core expects under SHEEPSHAVER --------------------
uint32 ROMBase = 0x40800000;
int64 TimebaseSpeed = 25000000;
uint32 PVR = 0x000c0000;
bool PrefsFindBool(const char *) { return false; }
uint64 GetTicks_usec(void) { return clock(); }
void HandleInterrupt(powerpc_registers *) {}

// iOS/Catalyst app-bridge stubs referenced by ppc-execute.cpp (C++ linkage,
// matching the header declarations)
void objc_displayRamAllocFailedAlert(void) {}
void objc_displayEncounteredIllegalInstructionAlert(void) {}
bool objc_getIgnoreIllegalInstructions(void) { return true; }
bool objc_getAltivec(void) { return true; }

// Guest zero-page / kernel-data window backing stores (vm.hpp redirect
// targets) and the resource-lock repair hooks the illegal path calls
uint8 gZeroPage[0x3000];
uint8 gKernelData[0x4000];
bool RsrcLocksTryRepair(uint32, uint32 *, uint32 *) { return false; }
void RsrcLocksDumpOnCrash(void) {}

// Bumped by compile_block under -DKPX_JIT_INSTRUMENT; proves the JIT ran
unsigned long kpx_jit_compile_count = 0;
// Bumped by compile_chain_block; proves direct block chaining resolved links
unsigned long kpx_jit_chain_count = 0;
unsigned long kpx_jit_trap_chain_count = 0;
unsigned long kpx_jit_vector_native_count = 0;
// Bumped by the kpx_fp_* arithmetic helpers; proves native FP executed
unsigned long kpx_jit_fp_helper_count = 0;
// Bumped at translate time per inline-fastmem access emitted; proves the
// memory whitelist still routes loads/stores to the inline path
unsigned long kpx_jit_inline_mem_emitted = 0;
// Bumped by the kpx_vm_*/kpx_fp_load_single helpers (fastmem cold path);
// proves the coarse filter actually diverts kernel-window traffic
unsigned long kpx_jit_mem_cold_count = 0;
#if PPC_ENABLE_JIT && PPC_REENTRANT_JIT
void init_emul_op_trampolines(basic_dyngen &) {}
#endif

// ---- test CPU: adds a "return" pseudo-op and register accessors ----------
const uint32 POWERPC_BLR  = 0x4e800020;
const uint32 POWERPC_BLRL = 0x4e800021;
const uint32 POWERPC_EMUL_OP = 0x18000000;	// D-form primary op 6 -> return

struct test_cpu : public powerpc_cpu {
	// Under SHEEPSHAVER powerpc_cpu has a no-arg constructor
	test_cpu() : powerpc_cpu() { init_return_op(); }

	// Mini execute_sheep: low 6 bits select behavior, mirroring the app's
	// SHEEP dispatch closely enough to exercise trap chaining. 0 = return
	// (non-continuable), 3 = data-dependent redirect (resumes at +4 OR
	// jumps to LR -- the trap-chain resume guard must catch the redirect),
	// 4 = self-modifying op (rewrites the guest word at r8 to r9's value
	// and range-invalidates it -- the guard must see the spcflag and bail
	// before running a stale inline continuation), >= 5 = plain continuable
	// pseudo-EmulOp (r7 += low6; resume at +4).
	void execute_return(uint32 opcode) {
		switch (opcode & 0x3f) {
		case 0:
			spcflags().set(SPCFLAG_CPU_EXEC_RETURN);
			break;
		case 3:
			if (gpr(6) & 1)
				pc() = lr();
			else
				pc() += 4;
			break;
		case 4: {
			const uint32 site = gpr(8);
			vm_write_memory_4(site, gpr(9));
			invalidate_cache_range(site, site + 4);
			pc() += 4;
			break;
		}
		default:
			gpr(7) += opcode & 0x3f;
			pc() += 4;
			break;
		}
	}

	void init_return_op() {
		static const instr_info_t ii = {
			"return", (execute_pmf)&test_cpu::execute_return,
			PPC_I(MAX), D_form, 6, 0, CFLOW_JUMP
		};
		init_decoder_entry(&ii);
	}

	uint32 get_gpr(int i) const { return gpr(i); }
	void   set_gpr(int i, uint32 v) { gpr(i) = v; }
	uint32 get_lr() const { return lr(); }
	void   set_lr(uint32 v) { lr() = v; }
	uint32 get_ctr() const { return ctr(); }
	void   set_ctr(uint32 v) { ctr() = v; }
	uint32 get_vrsave() const { return vrsave(); }
	void   set_vrsave(uint32 v) { vrsave() = v; }
	uint32 get_cr() const { return cr().get(); }
	void   set_cr(uint32 v) { cr().set(v); }
	uint32 get_xer() const { return xer().get(); }
	void   set_xer(uint32 v) { xer().set(v); }
	uint64 get_fpr(int i) const { return fpr_dw(i); }
	void   set_fpr(int i, uint64 v) { fpr_dw(i) = v; }
	uint32 get_fpscr() const { return fpscr(); }
	void   set_fpscr(uint32 v) { fpscr() = v; }
	uint32 get_vr_w(int i, int j) const { return vr(i).w[j]; }
	void   set_vr_w(int i, int j, uint32 v) { vr(i).w[j] = v; }
	// Consume the transient redecode flag so a range-invalidated block is
	// subsequently reached through a normal cache hit (models the real gap
	// between an invalidation and a much-later execution of a stale block)
	void   clear_jit_return() { spcflags().clear(SPCFLAG_JIT_EXEC_RETURN); }
};

// ---- guest memory --------------------------------------------------------
static uint32 guest_trampoline;		// BLRL ; return-op
static uint32 guest_code;			// where snippets are written
static uint32 guest_data;			// load/store playground (never overlaps code)
static const uint32 DATA_SIZE = 0x8000;

static void mem_init()
{
	// One 64 KB guest arena, addressed by GUEST address under MEM_BULK
	const uint32 arena = 64 << 10;
	uint8 *host = (uint8 *)vm_acquire(arena);
	if (host == VM_MAP_FAILED) { fprintf(stderr, "vm_acquire failed\n"); exit(2); }
	uint32 base = (uint32)vm_do_get_virtual_address(host);

	guest_trampoline = base;
	guest_code = base + 0x100;
	guest_data = base + 0x4000;
	vm_write_memory_4(guest_trampoline + 0, POWERPC_BLRL);
	vm_write_memory_4(guest_trampoline + 4, POWERPC_EMUL_OP);
}

// Deterministically (re)fill the data area so both engines see identical
// initial memory; direct host access is fine (byte-wise, no endian concern)
static void fill_data(uint32 seed)
{
	uint8 *p = vm_do_get_real_address(guest_data);
	for (uint32 i = 0; i < DATA_SIZE; i++) {
		seed = seed*1103515245u + 12345u;
		p[i] = (uint8)(seed >> 16);
	}
}

static uint8 data_snap[DATA_SIZE];
static void snap_data() { memcpy(data_snap, vm_do_get_real_address(guest_data), DATA_SIZE); }
static int diff_data(const char *name)
{
	if (memcmp(data_snap, vm_do_get_real_address(guest_data), DATA_SIZE) == 0)
		return 0;
	printf("  [%s] guest data area diverged\n", name);
	return 1;
}

static uint8 kdata_snap[0x4000];

// Write a snippet (array of opcodes, must end in BLR) at guest_code
static void load_snippet(const uint32 *ops, int n)
{
	for (int i = 0; i < n; i++)
		vm_write_memory_4(guest_code + i * 4, ops[i]);
}

static void run(test_cpu &cpu)
{
	// Each program reuses the same guest address, so both engines must
	// drop any block cached from the previous program or they would
	// re-run stale code (and match vacuously)
	cpu.invalidate_cache();
	cpu.set_lr(guest_code);
	cpu.execute(guest_trampoline);
}

// ---- comparison ----------------------------------------------------------
struct regfile {
	uint32 gpr[32], lr, ctr, cr, xer, fpscr;
	uint64 fpr[32];
	uint32 vr[32][4];
	regfile() { memset(this, 0, sizeof *this); }
};

static void snapshot(test_cpu &c, regfile &r)
{
	for (int i = 0; i < 32; i++) r.gpr[i] = c.get_gpr(i);
	for (int i = 0; i < 32; i++) r.fpr[i] = c.get_fpr(i);
	for (int i = 0; i < 32; i++)
		for (int j = 0; j < 4; j++) r.vr[i][j] = c.get_vr_w(i, j);
	r.lr = c.get_lr(); r.ctr = c.get_ctr();
	r.cr = c.get_cr(); r.xer = c.get_xer(); r.fpscr = c.get_fpscr();
}

static void seed(test_cpu &c, const regfile &r)
{
	for (int i = 0; i < 32; i++) c.set_gpr(i, r.gpr[i]);
	for (int i = 0; i < 32; i++) c.set_fpr(i, r.fpr[i]);
	for (int i = 0; i < 32; i++)
		for (int j = 0; j < 4; j++) c.set_vr_w(i, j, r.vr[i][j]);
	c.set_lr(r.lr); c.set_ctr(r.ctr); c.set_cr(r.cr); c.set_xer(r.xer);
	c.set_fpscr(r.fpscr);
}

static int diff(const char *name, const regfile &a, const regfile &b)
{
	int n = 0;
	for (int i = 0; i < 32; i++)
		if (a.gpr[i] != b.gpr[i]) {
			printf("  [%s] r%-2d interp=%08x jit=%08x\n", name, i, a.gpr[i], b.gpr[i]); n++;
		}
	for (int i = 0; i < 32; i++)
		if (a.fpr[i] != b.fpr[i]) {
			printf("  [%s] f%-2d interp=%016llx jit=%016llx\n", name, i,
				   (unsigned long long)a.fpr[i], (unsigned long long)b.fpr[i]); n++;
		}
	for (int i = 0; i < 32; i++)
		for (int j = 0; j < 4; j++)
			if (a.vr[i][j] != b.vr[i][j]) {
				printf("  [%s] v%-2d.w%d interp=%08x jit=%08x\n", name, i, j,
					   a.vr[i][j], b.vr[i][j]); n++;
			}
	if (a.lr  != b.lr)  { printf("  [%s] LR  interp=%08x jit=%08x\n", name, a.lr,  b.lr);  n++; }
	if (a.ctr != b.ctr) { printf("  [%s] CTR interp=%08x jit=%08x\n", name, a.ctr, b.ctr); n++; }
	if (a.cr  != b.cr)  { printf("  [%s] CR  interp=%08x jit=%08x\n", name, a.cr,  b.cr);  n++; }
	if (a.xer != b.xer) { printf("  [%s] XER interp=%08x jit=%08x\n", name, a.xer, b.xer); n++; }
#if defined(__x86_64__)
	// The classic x86 dyngen scalar-FP ops have never modeled FPRF (FPSCR
	// bits 12..16) — a known upstream gap; FP register values themselves
	// are held bit-exact above. Compare everything but that field.
	const uint32 fpscr_mask = ~0x0001f000u;
#else
	const uint32 fpscr_mask = 0xffffffffu;
#endif
	if ((a.fpscr & fpscr_mask) != (b.fpscr & fpscr_mask)) {
		printf("  [%s] FPSCR interp=%08x jit=%08x\n", name, a.fpscr, b.fpscr); n++;
	}
	return n;
}

// ---- PPC opcode builders (scalar integer surface) -------------------------
static uint32 D(int op,int rd,int ra,int imm){return (op<<26)|(rd<<21)|(ra<<16)|(imm&0xffff);}
static uint32 X(int op,int rt,int ra,int rb,int xo,int rc){return (op<<26)|(rt<<21)|(ra<<16)|(rb<<11)|(xo<<1)|rc;}
static uint32 M(int op,int s,int a,int sh,int mb,int me,int rc){return (op<<26)|(s<<21)|(a<<16)|(sh<<11)|(mb<<6)|(me<<1)|rc;}
static uint32 addi(int d,int a,int i){return D(14,d,a,i);}
static uint32 addis(int d,int a,int i){return D(15,d,a,i);}
static uint32 addic(int d,int a,int i){return D(12,d,a,i);}
static uint32 addic_(int d,int a,int i){return D(13,d,a,i);}
static uint32 subfic(int d,int a,int i){return D(8,d,a,i);}
static uint32 mulli(int d,int a,int i){return D(7,d,a,i);}
static uint32 ori(int a,int s,int u){return D(24,s,a,u);}
static uint32 oris(int a,int s,int u){return D(25,s,a,u);}
static uint32 xori(int a,int s,int u){return D(26,s,a,u);}
static uint32 andi_(int a,int s,int u){return D(28,s,a,u);}
static uint32 andis_(int a,int s,int u){return D(29,s,a,u);}
static uint32 cmpwi(int cr,int a,int i){return D(11,cr<<2,a,i);}
static uint32 cmplwi(int cr,int a,int i){return D(10,cr<<2,a,i);}
static uint32 add_(int d,int a,int b,int rc){return X(31,d,a,b,266,rc);}
static uint32 subf(int d,int a,int b,int rc){return X(31,d,a,b,40,rc);}
static uint32 addc(int d,int a,int b,int rc){return X(31,d,a,b,10,rc);}
static uint32 adde(int d,int a,int b,int rc){return X(31,d,a,b,138,rc);}
static uint32 addze(int d,int a,int rc){return X(31,d,a,0,202,rc);}
static uint32 addme(int d,int a,int rc){return X(31,d,a,0,234,rc);}
static uint32 subfc(int d,int a,int b,int rc){return X(31,d,a,b,8,rc);}
static uint32 subfe(int d,int a,int b,int rc){return X(31,d,a,b,136,rc);}
static uint32 subfze(int d,int a,int rc){return X(31,d,a,0,200,rc);}
static uint32 and_(int a,int s,int b,int rc){return X(31,s,a,b,28,rc);}
static uint32 andc(int a,int s,int b,int rc){return X(31,s,a,b,60,rc);}
static uint32 or_(int a,int s,int b,int rc){return X(31,s,a,b,444,rc);}
static uint32 orc(int a,int s,int b,int rc){return X(31,s,a,b,412,rc);}
static uint32 xor_(int a,int s,int b,int rc){return X(31,s,a,b,316,rc);}
static uint32 nand(int a,int s,int b,int rc){return X(31,s,a,b,476,rc);}
static uint32 nor(int a,int s,int b,int rc){return X(31,s,a,b,124,rc);}
static uint32 eqv(int a,int s,int b,int rc){return X(31,s,a,b,284,rc);}
static uint32 slw(int a,int s,int b,int rc){return X(31,s,a,b,24,rc);}
static uint32 srw(int a,int s,int b,int rc){return X(31,s,a,b,536,rc);}
static uint32 sraw(int a,int s,int b,int rc){return X(31,s,a,b,792,rc);}
static uint32 srawi(int a,int s,int sh,int rc){return X(31,s,a,sh,824,rc);}
static uint32 cntlzw(int a,int s,int rc){return X(31,s,a,0,26,rc);}
static uint32 extsb(int a,int s,int rc){return X(31,s,a,0,954,rc);}
static uint32 extsh(int a,int s,int rc){return X(31,s,a,0,922,rc);}
static uint32 cmpw(int cr,int a,int b){return X(31,cr<<2,a,b,0,0);}
static uint32 cmplw(int cr,int a,int b){return X(31,cr<<2,a,b,32,0);}
static uint32 mullw(int d,int a,int b,int rc){return X(31,d,a,b,235,rc);}
static uint32 mulhw(int d,int a,int b,int rc){return X(31,d,a,b,75,rc);}
static uint32 mulhwu(int d,int a,int b,int rc){return X(31,d,a,b,11,rc);}
static uint32 divw(int d,int a,int b,int rc){return X(31,d,a,b,491,rc);}
static uint32 divwu(int d,int a,int b,int rc){return X(31,d,a,b,459,rc);}
static uint32 neg(int d,int a,int rc){return X(31,d,a,0,104,rc);}
static uint32 rlwinm(int a,int s,int sh,int mb,int me,int rc){return M(21,s,a,sh,mb,me,rc);}
static uint32 rlwimi(int a,int s,int sh,int mb,int me,int rc){return M(20,s,a,sh,mb,me,rc);}
static uint32 rlwnm(int a,int s,int b,int mb,int me,int rc){return M(23,s,a,b,mb,me,rc);}
static uint32 crop(int xo,int d,int a,int b){return (19<<26)|(d<<21)|(a<<16)|(b<<11)|(xo<<1);}
static uint32 mfcr(int d){return X(31,d,0,0,19,0);}
static uint32 mtcrf(int mask,int s){return (31<<26)|(s<<21)|(mask<<12)|(144<<1);}
static uint32 mfspr(int d,int spr){return X(31,d,spr&31,(spr>>5)&31,339,0);}
static uint32 mtspr(int spr,int s){return X(31,s,spr&31,(spr>>5)&31,467,0);}
// branch: b/bc (relative), blr, bclr/bcctr (register targets)
static uint32 b_(int disp,int lk){return (18<<26)|(disp&0x03fffffc)|lk;}
static uint32 bc(int bo,int bi,int disp,int lk){return (16<<26)|(bo<<21)|(bi<<16)|(disp&0xfffc)|lk;}
static uint32 bclr(int bo,int bi,int lk){return (19<<26)|(bo<<21)|(bi<<16)|(16<<1)|lk;}
static uint32 bcctr(int bo,int bi,int lk){return (19<<26)|(bo<<21)|(bi<<16)|(528<<1)|lk;}
// integer loads/stores (D-form)
static uint32 lwz(int d,int a,int i){return D(32,d,a,i);}
static uint32 lwzu(int d,int a,int i){return D(33,d,a,i);}
static uint32 lbz(int d,int a,int i){return D(34,d,a,i);}
static uint32 lbzu(int d,int a,int i){return D(35,d,a,i);}
static uint32 stw(int s,int a,int i){return D(36,s,a,i);}
static uint32 stwu(int s,int a,int i){return D(37,s,a,i);}
static uint32 stb(int s,int a,int i){return D(38,s,a,i);}
static uint32 lhz(int d,int a,int i){return D(40,d,a,i);}
static uint32 lha(int d,int a,int i){return D(42,d,a,i);}
static uint32 lhau(int d,int a,int i){return D(43,d,a,i);}
static uint32 sth(int s,int a,int i){return D(44,s,a,i);}
static uint32 sthu(int s,int a,int i){return D(45,s,a,i);}
static uint32 lmw(int d,int a,int i){return D(46,d,a,i);}
static uint32 stmw(int s,int a,int i){return D(47,s,a,i);}
// integer loads/stores (X-form, indexed)
static uint32 lwzx(int d,int a,int b){return X(31,d,a,b,23,0);}
static uint32 lbzx(int d,int a,int b){return X(31,d,a,b,87,0);}
static uint32 lhzx(int d,int a,int b){return X(31,d,a,b,279,0);}
static uint32 lhax(int d,int a,int b){return X(31,d,a,b,343,0);}
static uint32 stwx(int s,int a,int b){return X(31,s,a,b,151,0);}
static uint32 stbx(int s,int a,int b){return X(31,s,a,b,215,0);}
static uint32 sthx(int s,int a,int b){return X(31,s,a,b,407,0);}
static uint32 lwzux(int d,int a,int b){return X(31,d,a,b,55,0);}
static uint32 stwux(int s,int a,int b){return X(31,s,a,b,183,0);}
// reservation + cache block ops
static uint32 lwarx_(int d,int a,int b){return X(31,d,a,b,20,0);}
static uint32 stwcx_(int s,int a,int b){return X(31,s,a,b,150,1);}
static uint32 dcbz_(int a,int b){return X(31,0,a,b,1014,0);}
// FP arithmetic (A-form: frD,frA,frB,frC; fmadd family computes frA*frC+frB)
static uint32 A(int op,int d,int a,int b,int c,int xo,int rc){return (op<<26)|(d<<21)|(a<<16)|(b<<11)|(c<<6)|(xo<<1)|rc;}
static uint32 fadd(int d,int a,int b,int rc){return A(63,d,a,b,0,21,rc);}
static uint32 fsub(int d,int a,int b,int rc){return A(63,d,a,b,0,20,rc);}
static uint32 fmul(int d,int a,int c,int rc){return A(63,d,a,0,c,25,rc);}
static uint32 fdiv(int d,int a,int b,int rc){return A(63,d,a,b,0,18,rc);}
static uint32 fadds_(int d,int a,int b,int rc){return A(59,d,a,b,0,21,rc);}
static uint32 fsubs_(int d,int a,int b,int rc){return A(59,d,a,b,0,20,rc);}
static uint32 fmuls_(int d,int a,int c,int rc){return A(59,d,a,0,c,25,rc);}
static uint32 fdivs_(int d,int a,int b,int rc){return A(59,d,a,b,0,18,rc);}
static uint32 fmadd(int d,int a,int b,int c,int rc){return A(63,d,a,b,c,29,rc);}
static uint32 fmsub(int d,int a,int b,int c,int rc){return A(63,d,a,b,c,28,rc);}
static uint32 fnmadd(int d,int a,int b,int c,int rc){return A(63,d,a,b,c,31,rc);}
static uint32 fnmsub(int d,int a,int b,int c,int rc){return A(63,d,a,b,c,30,rc);}
static uint32 fmadds_(int d,int a,int b,int c,int rc){return A(59,d,a,b,c,29,rc);}
static uint32 fnmsubs_(int d,int a,int b,int c,int rc){return A(59,d,a,b,c,30,rc);}
static uint32 fmr(int d,int b,int rc){return X(63,d,0,b,72,rc);}
static uint32 fabs_(int d,int b,int rc){return X(63,d,0,b,264,rc);}
static uint32 fneg_(int d,int b,int rc){return X(63,d,0,b,40,rc);}
static uint32 fnabs_(int d,int b,int rc){return X(63,d,0,b,136,rc);}
// FP loads/stores
static uint32 lfs(int d,int a,int i){return D(48,d,a,i);}
static uint32 lfsu(int d,int a,int i){return D(49,d,a,i);}
static uint32 lfd(int d,int a,int i){return D(50,d,a,i);}
static uint32 lfdu(int d,int a,int i){return D(51,d,a,i);}
static uint32 stfs(int s,int a,int i){return D(52,s,a,i);}
static uint32 stfsu(int s,int a,int i){return D(53,s,a,i);}
static uint32 stfd(int s,int a,int i){return D(54,s,a,i);}
static uint32 stfdu(int s,int a,int i){return D(55,s,a,i);}
static uint32 lfsx(int d,int a,int b){return X(31,d,a,b,535,0);}
static uint32 lfdx(int d,int a,int b){return X(31,d,a,b,599,0);}
static uint32 stfsx(int s,int a,int b){return X(31,s,a,b,663,0);}
static uint32 stfdx(int s,int a,int b){return X(31,s,a,b,727,0);}
// AltiVec: VX (11-bit xo), VXR (Rc + 10-bit xo), VA (6-bit xo) forms
static uint32 vx(int xo,int d,int a,int b){return (4<<26)|(d<<21)|(a<<16)|(b<<11)|xo;}
static uint32 vxr(int xo,int d,int a,int b,int rc){return (4<<26)|(d<<21)|(a<<16)|(b<<11)|(rc<<10)|xo;}
static uint32 va(int xo,int d,int a,int b,int c){return (4<<26)|(d<<21)|(a<<16)|(b<<11)|(c<<6)|xo;}
static uint32 lvx_(int d,int a,int b){return X(31,d,a,b,103,0);}
static uint32 lvxl_(int d,int a,int b){return X(31,d,a,b,359,0);}
static uint32 stvx_(int s,int a,int b){return X(31,s,a,b,231,0);}
static uint32 stvxl_(int s,int a,int b){return X(31,s,a,b,487,0);}
static uint32 lvewx_(int d,int a,int b){return X(31,d,a,b,71,0);}
static uint32 stvewx_(int s,int a,int b){return X(31,s,a,b,199,0);}

static uint32 g_rng = 0x12345678;
static uint32 rnd() { g_rng = g_rng*1103515245u + 12345u; return g_rng; }

// Self-modifying-code interior-invalidation regression. A decode-cache block
// predecoded BELOW the execute() entry PC must still be range-invalidated
// when its own bytes are rewritten. If min_pc is set to the execute() entry
// rather than the block's own start, a below-entry block gets min_pc > max_pc
// (inverted), and clear_range's intersect misses it -- the stale predecoded
// block stays live (the Open Transport CFM-binding boot crash). Runs a low
// subroutine reached from a higher entry, rewrites the subroutine's code,
// range-invalidates just that line, and returns r3 from a second run: a
// correct engine re-decodes and yields 2; a stale block yields the old 1.
static uint32 smc_below_entry_scenario(test_cpu &c)
{
	const uint32 Lo = guest_code;			// low subroutine
	const uint32 Hi = guest_code + 0x400;	// entry, above Lo

	vm_write_memory_4(Hi + 0, b_((int)Lo - (int)Hi, 1));	// bl Lo (LK)
	vm_write_memory_4(Hi + 4, POWERPC_EMUL_OP);			// return-op
	vm_write_memory_4(Lo + 0, addi(3, 0, 1));			// li r3,1
	vm_write_memory_4(Lo + 4, POWERPC_BLR);				// blr

	c.invalidate_cache();
	c.set_gpr(3, 0);
	c.execute(Hi);						// predecodes the below-entry block at Lo

	vm_write_memory_4(Lo + 0, addi(3, 0, 2));			// self-modify: li r3,2
	c.invalidate_cache_range(Lo, Lo + 4);
	c.clear_jit_return();
	c.set_gpr(3, 0);
	c.execute(Hi);						// stale block -> 1 ; re-decoded -> 2
	return c.get_gpr(3);
}

// Cross-page direct block chaining: a block ending in `bl` chains to a target
// TWO pages away. After the target's page is range-invalidated (the source's
// page is NOT in the invalidation window), the source's patched branch must
// have been reset to its resolver via the target's incoming dependency list.
// A stale chain keeps jumping to the old target code and returns the old
// value. Expected composite: 112 (run1=1, run2=1 via hot chain, run3=2).
static uint32 crosspage_chain_scenario(test_cpu &c)
{
	const uint32 Lo = guest_code;			// target, low page
	const uint32 Hi = guest_code + 0x2000;	// source, two pages up

	vm_write_memory_4(Hi + 0, b_((int)Lo - (int)Hi, 1));	// bl Lo (chains)
	vm_write_memory_4(Hi + 4, POWERPC_EMUL_OP);			// return-op
	vm_write_memory_4(Lo + 0, addi(3, 0, 1));			// li r3,1
	vm_write_memory_4(Lo + 4, POWERPC_BLR);				// blr -> Hi+4

	c.invalidate_cache();
	c.clear_jit_return();
	c.set_gpr(3, 0);
	c.execute(Hi);						// resolver runs, chain patched
	uint32 r1 = c.get_gpr(3);

	c.set_gpr(3, 0);
	c.execute(Hi);						// hot chain
	uint32 r2 = c.get_gpr(3);

	vm_write_memory_4(Lo + 0, addi(3, 0, 2));			// retarget: li r3,2
	c.invalidate_cache_range(Lo, Lo + 4);	// page-rounded: kills Lo only
	c.clear_jit_return();
	c.set_gpr(3, 0);
	c.execute(Hi);						// stale chain -> 1 ; unchained -> 2
	uint32 r3 = c.get_gpr(3);

	return r1 * 100 + r2 * 10 + r3;
}

// Conditional cross-page chaining, both slots, then SOURCE-page invalidation:
// the dying source must unlink its outgoing links from the surviving target's
// incoming list (remove_deps), so the target's later invalidation walks a
// clean list instead of patching through a freed block_info. Expected
// composite: 9-7-11-7 packed as 0x97b7.
static uint32 crosspage_cond_chain_scenario(test_cpu &c)
{
	const uint32 Lo = guest_code;			// taken target, low page
	const uint32 Hi = guest_code + 0x2000;	// conditional source, two pages up

	vm_write_memory_4(Hi + 0, cmpwi(0, 3, 0));
	vm_write_memory_4(Hi + 4, bc(12, 2, (int)Lo - (int)(Hi + 4), 0));	// beq Lo
	vm_write_memory_4(Hi + 8, addi(4, 0, 7));			// fallthrough: li r4,7
	vm_write_memory_4(Hi + 12, POWERPC_BLR);
	vm_write_memory_4(Hi + 16, POWERPC_EMUL_OP);		// LR target: return-op
	vm_write_memory_4(Lo + 0, addi(4, 0, 9));			// taken: li r4,9
	vm_write_memory_4(Lo + 4, POWERPC_BLR);

	c.invalidate_cache();
	c.clear_jit_return();
	c.set_lr(Hi + 16);
	c.set_gpr(3, 0); c.set_gpr(4, 0);
	c.execute(Hi);						// taken slot resolves
	uint32 r1 = c.get_gpr(4);

	c.set_lr(Hi + 16);
	c.set_gpr(3, 1); c.set_gpr(4, 0);
	c.execute(Hi);						// fallthrough slot resolves
	uint32 r2 = c.get_gpr(4);

	// Kill the SOURCE page: Hi's blocks die and must unlink from Lo's
	// incoming list. Lo's block survives.
	c.invalidate_cache_range(Hi, Hi + 4);
	c.clear_jit_return();

	// Now retarget and kill Lo: its invalidate() walks the incoming list,
	// which must no longer reference the freed source block
	vm_write_memory_4(Lo + 0, addi(4, 0, 11));			// li r4,11
	c.invalidate_cache_range(Lo, Lo + 4);
	c.clear_jit_return();

	c.set_lr(Hi + 16);
	c.set_gpr(3, 0); c.set_gpr(4, 0);
	c.execute(Hi);						// recompiled everywhere
	uint32 r3 = c.get_gpr(4);

	c.set_lr(Hi + 16);
	c.set_gpr(3, 1); c.set_gpr(4, 0);
	c.execute(Hi);
	uint32 r4 = c.get_gpr(4);

	return (r1 << 12) | (r2 << 8) | (r3 << 4) | r4;
}

// Trap chaining vs self-modifying code: a continuable pseudo-EmulOp (low6=4)
// rewrites the NEXT instruction of its own block and range-invalidates it.
// The resume guard must see SPCFLAG_JIT_EXEC_RETURN and bail out to the
// driver, which recompiles and runs the NEW instruction (r3 = 42). A JIT
// that continues inline past the trap runs the stale translation (r3 = 7).
static uint32 trap_smc_scenario(test_cpu &c)
{
	const uint32 A = guest_code;
	vm_write_memory_4(A + 0, POWERPC_EMUL_OP | 4);		// SMC pseudo-op
	vm_write_memory_4(A + 4, addi(3, 0, 7));			// original: li r3,7
	vm_write_memory_4(A + 8, POWERPC_BLR);

	c.invalidate_cache();
	c.clear_jit_return();
	c.set_gpr(3, 0);
	c.set_gpr(8, A + 4);				// rewrite site
	c.set_gpr(9, addi(3, 0, 42));		// replacement: li r3,42
	c.set_lr(guest_trampoline + 4);		// final BLR -> return-op
	c.execute(A);
	return c.get_gpr(3);
}

// ---- vm accessor contract (host-side unit test, no CPU involved) -----------
// The lockstep suites compare interpreter vs JIT, but both share vm.hpp, so a
// semantic bug in vm_do_get_real_address itself would cancel out. This pins
// the translation contract directly: exact window membership and the flat
// VMBaseDiff mapping everywhere else (pointer math only — out-of-range
// pointers are compared, never dereferenced).
static int unit_accessor()
{
	static const uint32 cases[] = {
		0x00000000, 0x00001000, 0x00002fff, 0x00003000,	// low RAM (no zero-page redirect under MEM_BULK)
		0x40000000, 0x50000000, 0x505fffff,				// RAM top / ROM / SheepMem neighborhood
		0x5ff7fffc, 0x5ff80000, 0x5fffbfff,				// below and inside any coarse pre-filter band
		0x5fffc000, 0x5fffdfff, 0x5fffe000, 0x5fffffff,	// KERNEL_DATA2 window (16 KB)
		0x60000000, 0x68ffbfff,							// between the windows
		0x68ffc000, 0x68ffe000, 0x68ffffff,				// KERNEL_DATA window (16 KB)
		0x69000000, 0x80000000, 0xfffffffc,				// beyond (wild, but must still map flat)
	};
	int bad = 0;
	for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
		const uint32 a = cases[i];
		uint8 *got = vm_do_get_real_address(a);
		uint8 *want = ((a & ~0x3fffu) == 0x68ffc000u || (a & ~0x3fffu) == 0x5fffc000u)
			? &gKernelData[a & 0x3fff]
			: (uint8 *)(VMBaseDiff + a);
		if (got != want) {
			printf("  [accessor] %08x -> %p, expected %p\n", a, got, want);
			bad++;
		}
	}
	// Round-trip: a store through one kernel window must be readable through
	// the other (same gKernelData slot) with big-endian byte order
	memset(gKernelData, 0, sizeof gKernelData);
	vm_write_memory_4(0x68ffe008, 0xa1b2c3d4);
	if (gKernelData[0x2008] != 0xa1 || gKernelData[0x200b] != 0xd4) {
		printf("  [accessor] window store not big-endian in gKernelData\n");
		bad++;
	}
	if (vm_read_memory_4(0x5fffe008) != 0xa1b2c3d4) {
		printf("  [accessor] window alias 0x5fffe008 != 0x68ffe008\n");
		bad++;
	}
	memset(gKernelData, 0, sizeof gKernelData);
	printf("accessor contract: %s\n\n", bad ? "FAIL" : "pass");
	return bad;
}

// ---- --bench: guest-CPU throughput over loop-heavy snippets ----------------
// Steady-state measurement: translate once, then time whole execute() calls
// of a CTR-counted loop (best of 3). No cache invalidation between timed
// runs, so the JIT numbers measure execution, not translation.
static double now_ns()
{
	static mach_timebase_info_data_t tb;
	if (!tb.denom) mach_timebase_info(&tb);
	return (double)mach_absolute_time() * tb.numer / tb.denom;
}

struct bench_prog {
	const char *name;
	uint32 ops[16];
	int n;
	uint64 insns;		// guest instructions per execute() (loop body only)
	uint32 r10;			// preseeded r10 base (0 = guest_data + DATA_SIZE/2)
};

static int bench_build(bench_prog *bp, uint32 iters)
{
	int np = 0;
	{	// native scalar-integer mix (whitelisted ops only)
		bench_prog &p = bp[np++]; p.name = "alu "; p.n = 0; p.r10 = 0;
		p.ops[p.n++] = mtspr(9, 3);				// ctr = r3 = iters
		p.ops[p.n++] = addi(4,4,1);				// loop:
		p.ops[p.n++] = xor_(5,5,4,0);
		p.ops[p.n++] = add_(6,6,5,0);
		p.ops[p.n++] = rlwinm(7,6,3,0,31,0);
		p.ops[p.n++] = or_(8,8,7,0);
		p.ops[p.n++] = subf(9,4,8,0);
		p.ops[p.n++] = extsh(11,9,0);
		p.ops[p.n++] = cmpwi(7,11,0);
		p.ops[p.n++] = bc(16,0,-32,0);			// bdnz loop
		p.ops[p.n++] = POWERPC_BLR;
		p.insns = (uint64)iters * 9;
	}
	{	// integer loads/stores against the data area (8 accesses/iter)
		bench_prog &p = bp[np++]; p.name = "mem "; p.n = 0; p.r10 = 0;
		p.ops[p.n++] = mtspr(9, 3);
		p.ops[p.n++] = lwz(4,10,0);				// loop:
		p.ops[p.n++] = lwz(5,10,4);
		p.ops[p.n++] = stw(4,10,8);
		p.ops[p.n++] = stw(5,10,12);
		p.ops[p.n++] = lhz(6,10,2);
		p.ops[p.n++] = stb(6,10,17);
		p.ops[p.n++] = lbz(7,10,5);
		p.ops[p.n++] = sth(7,10,20);
		p.ops[p.n++] = bc(16,0,-32,0);
		p.ops[p.n++] = POWERPC_BLR;
		p.insns = (uint64)iters * 9;
	}
	{	// FP loads/stores + arithmetic (double and single rounding)
		bench_prog &p = bp[np++]; p.name = "fp  "; p.n = 0; p.r10 = 0;
		p.ops[p.n++] = mtspr(9, 3);
		p.ops[p.n++] = lfd(3,10,0);				// loop:
		p.ops[p.n++] = lfd(4,10,8);
		p.ops[p.n++] = fadd(5,3,4,0);
		p.ops[p.n++] = fmul(6,5,3,0);
		p.ops[p.n++] = stfd(6,10,16);
		p.ops[p.n++] = fadds_(7,5,4,0);
		p.ops[p.n++] = bc(16,0,-24,0);
		p.ops[p.n++] = POWERPC_BLR;
		p.insns = (uint64)iters * 7;
	}
	{	// kernel-data window traffic (the redirected translation path)
		bench_prog &p = bp[np++]; p.name = "kwin"; p.n = 0; p.r10 = 0x68ffc000;
		p.ops[p.n++] = mtspr(9, 3);
		p.ops[p.n++] = lwz(4,10,0);				// loop:
		p.ops[p.n++] = stw(4,10,4);
		p.ops[p.n++] = lwz(5,10,8);
		p.ops[p.n++] = stw(5,10,12);
		p.ops[p.n++] = bc(16,0,-16,0);
		p.ops[p.n++] = POWERPC_BLR;
		p.insns = (uint64)iters * 5;
	}
	return np;
}

static double bench_engine(test_cpu &cpu, const regfile &in, regfile &warm_out)
{
	cpu.invalidate_cache();
	seed(cpu, in);
	cpu.set_lr(guest_code);
	cpu.execute(guest_trampoline);			// warm: translate + first pass
	snapshot(cpu, warm_out);
	double best = 1e30;
	for (int r = 0; r < 3; r++) {
		seed(cpu, in);
		cpu.set_lr(guest_code);
		double t0 = now_ns();
		cpu.execute(guest_trampoline);
		double dt = now_ns() - t0;
		if (dt < best) best = dt;
	}
	return best;
}

static int run_bench(test_cpu &interp, test_cpu &jit, uint32 iters)
{
	bench_prog progs[8];
	const int np = bench_build(progs, iters);
	printf("bench: %u loop iterations per run, best of 3 (steady state)\n\n", iters);
	int bad = 0;
	for (int i = 0; i < np; i++) {
		const bench_prog &p = progs[i];
		load_snippet(p.ops, p.n);

		regfile in;
		for (int r = 0; r < 32; r++) in.gpr[r] = 0x1000 + r;
		in.gpr[3] = iters;
		in.gpr[10] = p.r10 ? p.r10 : guest_data + DATA_SIZE/2;
		in.lr = 0;

		// Reset memory to the same state before EACH engine; the FP operand
		// seeds must land AFTER the refill or they would be clobbered by it
		regfile oi, oj;
		double ti = 0, tj = 0;
		union { double d; uint64 j; } v;
		for (int e = 0; e < 2; e++) {
			fill_data(0xbeef1234);
			memset(gKernelData, 0, sizeof gKernelData);
			v.d = 1.5;  vm_write_memory_8(in.gpr[10],     v.j);
			v.d = 2.25; vm_write_memory_8(in.gpr[10] + 8, v.j);
			if (e == 0) ti = bench_engine(interp, in, oi);
			else        tj = bench_engine(jit, in, oj);
		}

		if (diff(p.name, oi, oj)) bad++;	// warm-run sanity: engines agree
		if (!(ti > 0) || !(tj > 0)) {
			// e.g. callee-saved FP state corrupted across execute()
			printf("bench %s  FAIL: non-positive elapsed time (interp %.1f ns, jit %.1f ns)\n",
				   p.name, ti, tj);
			bad++;
			continue;
		}

		const double mips_i = (double)p.insns / ti * 1000.0;
		const double mips_j = (double)p.insns / tj * 1000.0;
		printf("bench %s  interp %8.1f MIPS (%5.2f ns/insn)   jit %8.1f MIPS (%5.2f ns/insn)   %5.2fx\n",
			   p.name, mips_i, ti / (double)p.insns, mips_j, tj / (double)p.insns, mips_i > 0 ? mips_j / mips_i : 0);
	}
	if (bad) {
		printf("\nFAIL: %d bench program(s) diverged between engines\n", bad);
		return 1;
	}
	return 0;
}

// Random double bit patterns biased toward interesting FP classes
static uint64 rnd_fp()
{
	uint64 sign = (uint64)(rnd() & 1) << 63;
	switch (rnd() % 10) {
	case 0: return sign;										// +/-0
	case 1: return sign | 0x7ff0000000000000ull;				// +/-inf
	case 2: return 0x7ff8000000000000ull | rnd();				// NaN
	case 3: {	// exponent window 874..896 (store-single denormalization)
		uint64 e = 874 + (rnd() % 23);
		return sign | (e << 52) | ((uint64)rnd() << 20);
	}
	case 4: {	// subnormal doubles
		return sign | ((uint64)(rnd() & 0xfffff) << 32) | rnd();
	}
	default: {	// normals with moderate exponents
		uint64 e = 0x3f0 + (rnd() % 0x20);
		return sign | (e << 52) | ((uint64)(rnd() & 0xfffff) << 32) | rnd();
	}
	}
}

int main(int argc, char **argv)
{
	// --bench [iters]: throughput mode (skips the correctness suites)
	uint32 bench_iters = 0;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--bench") == 0)
			bench_iters = 2000000;
		else if (bench_iters && argv[i][0] >= '1' && argv[i][0] <= '9')
			bench_iters = (uint32)strtoul(argv[i], NULL, 10);
	}

	if (vm_init() < 0) { fprintf(stderr, "vm_init failed\n"); return 2; }
	mem_init();

	// Heap-allocate: powerpc_cpu asserts 16-byte alignment of its vector
	// registers, which malloc guarantees but a stack object may not
	test_cpu &interp = *new test_cpu();
	test_cpu &jit = *new test_cpu();
	jit.enable_jit();
	printf("JIT W^X self-test: %s\n", jit_wx_selftest() ? "pass" : "unavailable");

	if (bench_iters)
		return run_bench(interp, jit, bench_iters);

	int total = 0, failed = 0;

	// --- suite 0: vm accessor contract (host-side, counted as one program) ---
	total++;
	if (unit_accessor())
		failed++;

	// --- negative control: the comparator must catch a real divergence ---
	{
		uint32 ops[] = { addi(3, 0, 0x1234), POWERPC_BLR };
		load_snippet(ops, 2);
		regfile z; memset(&z, 0, sizeof z);
		regfile a, b;
		seed(interp, z); run(interp); snapshot(interp, a);
		seed(jit, z);    run(jit);    snapshot(jit, b);
		b.gpr[3] ^= 1;	// inject an artificial mismatch
		if (diff("neg-control", a, b) == 0) {
			printf("FAIL: comparator did not detect an injected divergence\n");
			return 2;
		}
		printf("(negative control: injected divergence correctly detected)\n\n");
	}

	// --- suite 1: straight-line ALU blocks, random seeds ---
	// Divide corner cases (0 divisor, 0x80000000/-1) have architecturally
	// undefined results; they get a dedicated suite instead of random soup
	for (int t = 0; t < 4000; t++) {
		uint32 ops[40]; int n = 0;
		int len = 2 + (rnd() % 24);
		for (int k = 0; k < len && n < 36; k++) {
			int d = 3 + (rnd() % 8), a = 3 + (rnd() % 8), b = 3 + (rnd() % 8);
			int rc = rnd() & 1;
			int sh = rnd() & 31, mb = rnd() & 31, me = rnd() & 31;
			switch (rnd() % 40) {
			case 0: ops[n++] = addi(d,a,(int16)rnd()); break;
			case 1: ops[n++] = addis(d,a,(int16)rnd()); break;
			case 2: ops[n++] = addic(d,a,(int16)rnd()); break;
			case 3: ops[n++] = addic_(d,a,(int16)rnd()); break;
			case 4: ops[n++] = subfic(d,a,(int16)rnd()); break;
			case 5: ops[n++] = mulli(d,a,(int16)rnd()); break;
			case 6: ops[n++] = ori(d,a,(uint16)rnd()); break;
			case 7: ops[n++] = oris(d,a,(uint16)rnd()); break;
			case 8: ops[n++] = xori(d,a,(uint16)rnd()); break;
			case 9: ops[n++] = andi_(d,a,(uint16)rnd()); break;
			case 10: ops[n++] = andis_(d,a,(uint16)rnd()); break;
			case 11: ops[n++] = add_(d,a,b,rc); break;
			case 12: ops[n++] = subf(d,a,b,rc); break;
			case 13: ops[n++] = addc(d,a,b,rc); break;
			case 14: ops[n++] = adde(d,a,b,rc); break;
			case 15: ops[n++] = addze(d,a,rc); break;
			case 16: ops[n++] = addme(d,a,rc); break;
			case 17: ops[n++] = subfc(d,a,b,rc); break;
			case 18: ops[n++] = subfe(d,a,b,rc); break;
			case 19: ops[n++] = subfze(d,a,rc); break;
			case 20: ops[n++] = and_(d,a,b,rc); break;
			case 21: ops[n++] = andc(d,a,b,rc); break;
			case 22: ops[n++] = or_(d,a,b,rc); break;
			case 23: ops[n++] = orc(d,a,b,rc); break;
			case 24: ops[n++] = xor_(d,a,b,rc); break;
			case 25: ops[n++] = nand(d,a,b,rc); break;
			case 26: ops[n++] = nor(d,a,b,rc); break;
			case 27: ops[n++] = eqv(d,a,b,rc); break;
			case 28: ops[n++] = slw(d,a,b,rc); break;
			case 29: ops[n++] = srw(d,a,b,rc); break;
			case 30: ops[n++] = sraw(d,a,b,rc); break;
			case 31: ops[n++] = srawi(d,a,sh,rc); break;
			case 32: ops[n++] = cntlzw(d,a,rc); break;
			case 33: ops[n++] = extsb(d,a,rc); break;
			case 34: ops[n++] = extsh(d,a,rc); break;
			case 35: ops[n++] = mullw(d,a,b,rc); break;
			case 36: ops[n++] = mulhw(d,a,b,rc); break;
			case 37: ops[n++] = mulhwu(d,a,b,rc); break;
			case 38: ops[n++] = neg(d,a,rc); break;
			case 39:
				switch (rnd() % 6) {
				case 0: ops[n++] = rlwinm(d,a,sh,mb,me,rc); break;
				case 1: ops[n++] = rlwimi(d,a,sh,mb,me,rc); break;
				case 2: ops[n++] = rlwnm(d,a,b,mb,me,rc); break;
				case 3: ops[n++] = cmpw(rnd()%8,a,b); break;
				case 4: ops[n++] = cmplw(rnd()%8,a,b); break;
				case 5: ops[n++] = cmpwi(rnd()%8,a,(int16)rnd()); break;
				}
				break;
			}
		}
		ops[n++] = POWERPC_BLR;

		regfile in;
		for (int i = 0; i < 32; i++) in.gpr[i] = rnd();
		in.lr = 0; in.ctr = rnd(); in.cr = rnd(); in.xer = rnd() & 0xe000007f;

		load_snippet(ops, n);
		regfile ai, aj;
		seed(interp, in); run(interp); snapshot(interp, ai);
		seed(jit, in);    run(jit);    snapshot(jit, aj);

		total++;
		char nm[32]; snprintf(nm, sizeof nm, "alu#%d", t);
		if (diff(nm, ai, aj)) failed++;
	}

	// --- suite 2: divides with well-defined operands ---
	for (int t = 0; t < 500; t++) {
		uint32 ops[10]; int n = 0;
		int rc = rnd() & 1;
		ops[n++] = divw(3,4,5,rc);
		ops[n++] = divwu(6,7,8,rc & 0);
		ops[n++] = POWERPC_BLR;
		regfile in;
		for (int i = 0; i < 32; i++) in.gpr[i] = rnd();
		in.gpr[5] = in.gpr[5] ? in.gpr[5] : 3;		// nonzero divisors
		in.gpr[8] = in.gpr[8] ? in.gpr[8] : 7;
		if (in.gpr[4] == 0x80000000u && in.gpr[5] == 0xffffffffu) in.gpr[5] = 5;
		in.lr = 0; in.ctr = 0; in.cr = rnd(); in.xer = rnd() & 0xe000007f;
		load_snippet(ops, n);
		regfile ai, aj;
		seed(interp, in); run(interp); snapshot(interp, ai);
		seed(jit, in);    run(jit);    snapshot(jit, aj);
		total++;
		char nm[32]; snprintf(nm, sizeof nm, "div#%d", t);
		if (diff(nm, ai, aj)) failed++;
	}

	// --- suite 3: CR-field logic + SPR moves ---
	for (int t = 0; t < 500; t++) {
		uint32 ops[16]; int n = 0;
		ops[n++] = cmpw(0, 3, 4);
		ops[n++] = cmpw(1, 5, 6);
		static const int crxo[8] = { 257, 449, 193, 225, 33, 289, 129, 417 };
		for (int k = 0; k < 4; k++)
			ops[n++] = crop(crxo[rnd()%8], rnd()%32, rnd()%32, rnd()%32);
		ops[n++] = mfcr(7);
		ops[n++] = mtcrf(rnd() & 0xff, 8);
		ops[n++] = mfspr(9, 9);				// mfctr r9
		ops[n++] = mtspr(9, 10);			// mtctr r10
		ops[n++] = POWERPC_BLR;
		regfile in;
		for (int i = 0; i < 32; i++) in.gpr[i] = rnd();
		in.lr = 0; in.ctr = rnd(); in.cr = rnd(); in.xer = rnd() & 0xe000007f;
		load_snippet(ops, n);
		regfile ai, aj;
		seed(interp, in); run(interp); snapshot(interp, ai);
		seed(jit, in);    run(jit);    snapshot(jit, aj);
		total++;
		char nm[32]; snprintf(nm, sizeof nm, "cr#%d", t);
		if (diff(nm, ai, aj)) failed++;
	}

	// --- suite 3b: VRSAVE (SPR 256) — a plain uint32 SPR reached through the
	// whitelisted mfspr/mtspr path. Regression guard: the arm64 backend once
	// stubbed load/store_T0_VRSAVE (grouped with the deferred AltiVec ops) and
	// aborted here. Seeding vrsave and reading it back cross-checks the field
	// offset against the interpreter, not just a self-consistent round-trip.
	for (int t = 0; t < 200; t++) {
		uint32 ops[8]; int n = 0;
		ops[n++] = mfspr(4, 256);			// r4 = VRSAVE (seeded value)
		ops[n++] = mtspr(256, 3);			// VRSAVE = r3
		ops[n++] = mfspr(5, 256);			// r5 = VRSAVE (== r3)
		ops[n++] = POWERPC_BLR;
		regfile in;
		for (int i = 0; i < 32; i++) in.gpr[i] = rnd();
		uint32 seed_vr = rnd();
		load_snippet(ops, n);
		regfile ai, aj;
		seed(interp, in); interp.set_vrsave(seed_vr); run(interp); snapshot(interp, ai);
		seed(jit, in);    jit.set_vrsave(seed_vr);    run(jit);    snapshot(jit, aj);
		total++;
		char nm[32]; snprintf(nm, sizeof nm, "vrsave#%d", t);
		if (diff(nm, ai, aj)) failed++;
	}

	// --- suite 4: branches — counted loops, conditional skips, chaining ---
	for (int t = 0; t < 1000; t++) {
		uint32 ops[24]; int n = 0;
		int shape = rnd() % 5;
		switch (shape) {
		case 0:
			// bdnz countdown via CTR (exercises prep_branch CTR decrement)
			ops[n++] = mtspr(9, 3);				// ctr = r3
			ops[n++] = addi(4,0,0);
			ops[n++] = addi(4,4,1);				// loop: r4++
			ops[n++] = bc(16,0,-4,0);			// bdnz loop
			ops[n++] = POWERPC_BLR;
			break;
		case 1:
			// compare-driven backward loop
			ops[n++] = addi(4,0,0);
			ops[n++] = add_(4,4,3,0);			// loop: r4 += r3
			ops[n++] = addi(3,3,-1);
			ops[n++] = cmpwi(0,3,0);
			ops[n++] = bc(12,1,-12,0);			// bgt cr0 -> loop
			ops[n++] = POWERPC_BLR;
			break;
		case 2:
			// forward conditional skip over 1-2 ops + unconditional b
			ops[n++] = cmpw(0, 3, 4);
			ops[n++] = bc(12 + ((rnd()&1)<<3), rnd()%4, 12, 0);	// cond fwd +12
			ops[n++] = addi(5,5,17);
			ops[n++] = xor_(6,6,3,0);
			ops[n++] = b_(8,0);					// skip next
			ops[n++] = addi(7,7,99);
			ops[n++] = or_(8,8,4,1);
			ops[n++] = POWERPC_BLR;
			break;
		case 3:
			// conditional early return via bclr (branch commit through T0);
			// LR here is the trampoline return, so a taken bclr ends the
			// program with the remaining ops skipped
			ops[n++] = cmpw(0, 3, 4);
			ops[n++] = bclr(4 + ((rnd()&1)<<3), rnd()%4, 0);
			ops[n++] = mfspr(9, 8);				// mflr r9
			ops[n++] = addi(5,5,17);
			ops[n++] = or_(6,6,4,1);
			ops[n++] = POWERPC_BLR;
			break;
		case 4:
			// bcctr to a register target (r20 preseeded to the final BLR)
			ops[n++] = mtspr(9, 20);			// ctr = r20
			ops[n++] = bcctr(20, 0, 0);			// branch always
			ops[n++] = addi(6,6,1);				// skipped
			ops[n++] = POWERPC_BLR;				// bcctr target
			break;
		}

		regfile in;
		for (int i = 0; i < 32; i++) in.gpr[i] = rnd();
		in.gpr[3] = 1 + (rnd() % 24);
		if (shape == 4) in.gpr[20] = guest_code + 12;
		in.lr = 0; in.ctr = 0; in.cr = rnd(); in.xer = rnd() & 0xe000007f;

		load_snippet(ops, n);
		regfile ai, aj;
		seed(interp, in); run(interp); snapshot(interp, ai);
		seed(jit, in);    run(jit);    snapshot(jit, aj);
		total++;
		char nm[32]; snprintf(nm, sizeof nm, "br#%d", t);
		if (diff(nm, ai, aj)) failed++;
	}

	// --- suite 5: integer loads/stores over the data area ---
	// Random mixes of D-form, indexed and update forms at arbitrary (incl.
	// unaligned) offsets; the data area is compared byte-for-byte afterwards
	for (int t = 0; t < 1500; t++) {
		uint32 ops[40]; int n = 0;
		int len = 4 + (rnd() % 20);
		for (int k = 0; k < len && n < 36; k++) {
			int d = 3 + (rnd() % 7);					// r3..r9
			int b = 11 + (rnd() % 2);					// r11..r12
			int off = (int)(rnd() % 0x400) - 0x200;		// +/-0x200 around center
			int uoff = (int)(rnd() % 0x40) - 0x20;		// small update drift
			switch (rnd() % 20) {
			case 0: ops[n++] = lwz(d,10,off); break;
			case 1: ops[n++] = lbz(d,10,off); break;
			case 2: ops[n++] = lhz(d,10,off); break;
			case 3: ops[n++] = lha(d,10,off); break;
			case 4: ops[n++] = stw(d,10,off); break;
			case 5: ops[n++] = stb(d,10,off); break;
			case 6: ops[n++] = sth(d,10,off); break;
			case 7: ops[n++] = lwzx(d,10,b); break;
			case 8: ops[n++] = lbzx(d,10,b); break;
			case 9: ops[n++] = lhzx(d,10,b); break;
			case 10: ops[n++] = lhax(d,10,b); break;
			case 11: ops[n++] = stwx(d,10,b); break;
			case 12: ops[n++] = stbx(d,10,b); break;
			case 13: ops[n++] = sthx(d,10,b); break;
			case 14: ops[n++] = lwzu(d,10,uoff); break;
			case 15: ops[n++] = stwu(d,10,uoff); break;
			case 16: ops[n++] = lbzu(d,10,uoff); break;
			case 17: ops[n++] = sthu(d,10,uoff); break;
			case 18: ops[n++] = lhau(d,10,uoff); break;
			case 19: ops[n++] = lwzux(d,10,b); break;
			}
		}
		ops[n++] = POWERPC_BLR;

		regfile in;
		for (int i = 0; i < 32; i++) in.gpr[i] = rnd();
		in.gpr[10] = guest_data + DATA_SIZE/2;
		in.gpr[11] = rnd() % 0x100;
		in.gpr[12] = rnd() % 0x100;
		in.lr = 0; in.ctr = rnd(); in.cr = rnd(); in.xer = rnd() & 0xe000007f;

		load_snippet(ops, n);
		uint32 fill = rnd();
		regfile ai, aj;
		fill_data(fill);
		seed(interp, in); run(interp); snapshot(interp, ai); snap_data();
		fill_data(fill);
		seed(jit, in);    run(jit);    snapshot(jit, aj);
		total++;
		char nm[32]; snprintf(nm, sizeof nm, "mem#%d", t);
		if (diff(nm, ai, aj) + diff_data(nm)) failed++;
	}

	// --- suite 6: kernel-data window (0x68ffc000 / 0x5fffc000 redirect) ---
	for (int t = 0; t < 300; t++) {
		uint32 ops[24]; int n = 0;
		int hi = (rnd() & 1) ? 0x6900 : 0x6000;
		ops[n++] = addis(10,0,hi);
		ops[n++] = addi(10,10,-0x4000);		// r10 = 0x68ffc000 or 0x5fffc000
		for (int k = 0; k < 8; k++) {
			int d = 3 + (rnd() % 7);
			int off = rnd() % 0x3ffc;
			switch (rnd() % 4) {
			case 0: ops[n++] = stw(d,10,off & ~3); break;
			case 1: ops[n++] = lwz(d,10,off & ~3); break;
			case 2: ops[n++] = stb(d,10,off); break;
			case 3: ops[n++] = lbz(d,10,off); break;
			}
		}
		ops[n++] = POWERPC_BLR;

		regfile in;
		for (int i = 0; i < 32; i++) in.gpr[i] = rnd();
		in.lr = 0; in.ctr = 0; in.cr = rnd(); in.xer = rnd() & 0xe000007f;

		load_snippet(ops, n);
		regfile ai, aj;
		memset(gKernelData, 0, sizeof gKernelData);
		seed(interp, in); run(interp); snapshot(interp, ai);
		memcpy(kdata_snap, gKernelData, sizeof gKernelData);
		memset(gKernelData, 0, sizeof gKernelData);
		seed(jit, in);    run(jit);    snapshot(jit, aj);
		total++;
		char nm[32]; snprintf(nm, sizeof nm, "kwin#%d", t);
		int bad = diff(nm, ai, aj);
		if (memcmp(kdata_snap, gKernelData, sizeof gKernelData)) {
			printf("  [%s] kernel-data window contents diverged\n", nm);
			bad++;
		}
		if (bad) failed++;
	}

	// --- suite 7: lmw/stmw, lwarx/stwcx reservation protocol, dcbz ---
	for (int t = 0; t < 400; t++) {
		uint32 ops[24]; int n = 0;
		switch (rnd() % 3) {
		case 0: {
			// stmw/lmw round-trips (r>=26 hits the specialized ops, r<26
			// the _im form); scramble some of the high regs in between
			int r1 = 20 + (rnd() % 12);
			int r2 = 20 + (rnd() % 12);
			ops[n++] = stmw(r1, 10, (int)(rnd() % 0x100) - 0x80);
			ops[n++] = addi(25,26,123);
			ops[n++] = xor_(28,28,29,0);
			ops[n++] = lmw(r2, 10, (int)(rnd() % 0x100) - 0x80);
			break;
		}
		case 1:
			// reservation protocol: success, EA mismatch, and no-reserve
			ops[n++] = lwarx_(3, 0, 10);
			ops[n++] = addi(3, 3, 1);
			ops[n++] = (rnd() & 1) ? stwcx_(3, 0, 10) : stwcx_(3, 0, 11);
			ops[n++] = mfcr(7);
			if (rnd() & 1) {
				ops[n++] = stwcx_(4, 0, 10);	// reserve consumed -> fails
				ops[n++] = mfcr(8);
			}
			break;
		case 2:
			// dcbz (EA aligned down to 32) + boundary reads
			ops[n++] = dcbz_(0, 10);
			ops[n++] = lwz(4, 10, 0);
			ops[n++] = lwz(5, 10, 28);
			ops[n++] = lwz(6, 10, -4);
			ops[n++] = lwz(7, 10, 32);
			break;
		}
		ops[n++] = POWERPC_BLR;

		regfile in;
		for (int i = 0; i < 32; i++) in.gpr[i] = rnd();
		in.gpr[10] = guest_data + DATA_SIZE/2 + (rnd() % 0x100);
		in.gpr[11] = guest_data + 0x100;	// distinct stwcx EA (never stores)
		in.lr = 0; in.ctr = 0; in.cr = rnd(); in.xer = rnd() & 0xe000007f;

		load_snippet(ops, n);
		uint32 fill = rnd();
		regfile ai, aj;
		fill_data(fill);
		seed(interp, in); run(interp); snapshot(interp, ai); snap_data();
		fill_data(fill);
		seed(jit, in);    run(jit);    snapshot(jit, aj);
		total++;
		char nm[32]; snprintf(nm, sizeof nm, "multi#%d", t);
		if (diff(nm, ai, aj) + diff_data(nm)) failed++;
	}

	// --- suite 8: FP arithmetic (incl. FPSCR[FPRF] classify fidelity) ---
	// Random FPR bit patterns: normals, zeros, infinities, NaNs, and the
	// exponent window 874..896 that triggers store-single denormalization
	for (int t = 0; t < 600; t++) {
		uint32 ops[32]; int n = 0;
		int len = 3 + (rnd() % 12);
		for (int k = 0; k < len && n < 28; k++) {
			int d = 3 + (rnd() % 7), a = 3 + (rnd() % 7), b = 3 + (rnd() % 7), c = 3 + (rnd() % 7);
			int rc = rnd() & 1;
			switch (rnd() % 18) {
			case 0: ops[n++] = fadd(d,a,b,rc); break;
			case 1: ops[n++] = fsub(d,a,b,rc); break;
			case 2: ops[n++] = fmul(d,a,c,rc); break;
			case 3: ops[n++] = fdiv(d,a,b,rc); break;
			case 4: ops[n++] = fadds_(d,a,b,rc); break;
			case 5: ops[n++] = fsubs_(d,a,b,rc); break;
			case 6: ops[n++] = fmuls_(d,a,c,rc); break;
			case 7: ops[n++] = fdivs_(d,a,b,rc); break;
			case 8: ops[n++] = fmadd(d,a,b,c,rc); break;
			case 9: ops[n++] = fmsub(d,a,b,c,rc); break;
			case 10: ops[n++] = fnmadd(d,a,b,c,rc); break;
			case 11: ops[n++] = fnmsub(d,a,b,c,rc); break;
			case 12: ops[n++] = fmadds_(d,a,b,c,rc); break;
			case 13: ops[n++] = fnmsubs_(d,a,b,c,rc); break;
			case 14: ops[n++] = fmr(d,b,rc); break;
			case 15: ops[n++] = fabs_(d,b,rc); break;
			case 16: ops[n++] = fneg_(d,b,rc); break;
			case 17: ops[n++] = fnabs_(d,b,rc); break;
			}
		}
		ops[n++] = POWERPC_BLR;

		regfile in;
		for (int i = 0; i < 32; i++) in.gpr[i] = rnd();
		for (int i = 0; i < 32; i++) in.fpr[i] = rnd_fp();
		in.lr = 0; in.ctr = 0; in.cr = rnd(); in.xer = rnd() & 0xe000007f;
		in.fpscr = rnd() & 0x000000ff;	// exercise the VE classify guard

		load_snippet(ops, n);
		regfile ai, aj;
		seed(interp, in); run(interp); snapshot(interp, ai);
		seed(jit, in);    run(jit);    snapshot(jit, aj);
		total++;
		char nm[32]; snprintf(nm, sizeof nm, "fp#%d", t);
		if (diff(nm, ai, aj)) failed++;
	}

	// --- suite 9: FP loads/stores (single conversion + data compare) ---
	for (int t = 0; t < 500; t++) {
		uint32 ops[32]; int n = 0;
		int len = 4 + (rnd() % 12);
		for (int k = 0; k < len && n < 28; k++) {
			int d = 3 + (rnd() % 7);
			int b = 11 + (rnd() % 2);
			int off = ((int)(rnd() % 0x100) - 0x80) & ~3;
			int uoff = ((int)(rnd() % 0x40) - 0x20) & ~7;
			switch (rnd() % 12) {
			case 0: ops[n++] = lfd(d,10,off); break;
			case 1: ops[n++] = lfs(d,10,off); break;
			case 2: ops[n++] = stfd(d,10,off); break;
			case 3: ops[n++] = stfs(d,10,off); break;
			case 4: ops[n++] = lfdx(d,10,b); break;
			case 5: ops[n++] = lfsx(d,10,b); break;
			case 6: ops[n++] = stfdx(d,10,b); break;
			case 7: ops[n++] = stfsx(d,10,b); break;
			case 8: ops[n++] = lfdu(d,10,uoff ? uoff : 8); break;
			case 9: ops[n++] = stfdu(d,10,uoff ? uoff : -8); break;
			case 10: ops[n++] = lfsu(d,10,uoff ? uoff : 4); break;
			case 11: ops[n++] = stfsu(d,10,uoff ? uoff : -4); break;
			}
		}
		ops[n++] = POWERPC_BLR;

		regfile in;
		for (int i = 0; i < 32; i++) in.gpr[i] = rnd();
		for (int i = 0; i < 32; i++) in.fpr[i] = rnd_fp();
		in.gpr[10] = guest_data + DATA_SIZE/2;
		in.gpr[11] = (rnd() % 0x100) & ~3;
		in.gpr[12] = (rnd() % 0x100) & ~3;
		in.lr = 0; in.ctr = 0; in.cr = rnd(); in.xer = rnd() & 0xe000007f;
		in.fpscr = rnd() & 0x000000ff;

		load_snippet(ops, n);
		uint32 fill = rnd();
		regfile ai, aj;
		fill_data(fill);
		seed(interp, in); run(interp); snapshot(interp, ai); snap_data();
		fill_data(fill);
		seed(jit, in);    run(jit);    snapshot(jit, aj);
		total++;
		char nm[32]; snprintf(nm, sizeof nm, "fpmem#%d", t);
		if (diff(nm, ai, aj) + diff_data(nm)) failed++;
	}

	// --- suite 10: self-modifying-code interior invalidation (below-entry) ---
	// Not a differential-vs-JIT check: both engines must independently reach 2.
	// A stale below-entry predecoded block yields 1 (interpreter path); the JIT
	// path uses the block's own entry as min_pc and re-decodes correctly.
	{
		uint32 ri = smc_below_entry_scenario(interp);
		uint32 rj = smc_below_entry_scenario(jit);
		total++;
		if (ri != 2 || rj != 2) {
			printf("  [smc-below-entry] interp r3=%u  jit r3=%u  (both must be 2; "
				   "1 = stale predecoded block survived range invalidation)\n", ri, rj);
			failed++;
		}
	}

	// --- suite 11: cross-page direct chaining + unchain-on-invalidate ---
	// Both engines must independently reach the expected composites; the JIT
	// side additionally proves the incoming-dependency unchain protocol (a
	// stale cross-page chain returns the pre-invalidation value).
	{
		uint32 ri = crosspage_chain_scenario(interp);
		uint32 rj = crosspage_chain_scenario(jit);
		total++;
		if (ri != 112 || rj != 112) {
			printf("  [xpage-chain] interp=%u jit=%u (both must be 112; "
				   "xx1 = stale cross-page chain survived target invalidation)\n", ri, rj);
			failed++;
		}
	}
	{
		uint32 ri = crosspage_cond_chain_scenario(interp);
		uint32 rj = crosspage_cond_chain_scenario(jit);
		total++;
		if (ri != 0x97b7 || rj != 0x97b7) {
			printf("  [xpage-cond-chain] interp=%04x jit=%04x (both must be 97b7)\n",
				   ri, rj);
			failed++;
		}
	}

	// --- suite 13: NEON AltiVec — element-wise arith/logic/minmax/compare,
	// splats, vsel/vperm; VRs seeded with random bits (float ops get
	// float-biased patterns via rnd_fp splits) and fully compared ---
	for (int t = 0; t < 800; t++) {
		uint32 ops[32]; int n = 0;
		int len = 3 + (rnd() % 10);
		for (int k = 0; k < len && n < 28; k++) {
			int d = rnd() % 8, a = rnd() % 8, b = rnd() % 8, c = rnd() % 8;
			int rc = rnd() & 1;
			switch (rnd() % 30) {
			case 0: ops[n++] = vx(0,d,a,b); break;			// vaddubm
			case 1: ops[n++] = vx(64,d,a,b); break;			// vadduhm
			case 2: ops[n++] = vx(128,d,a,b); break;		// vadduwm
			case 3: ops[n++] = vx(1024,d,a,b); break;		// vsububm
			case 4: ops[n++] = vx(1088,d,a,b); break;		// vsubuhm
			case 5: ops[n++] = vx(1152,d,a,b); break;		// vsubuwm
			case 6: ops[n++] = vx(1028,d,a,b); break;		// vand
			case 7: ops[n++] = vx(1092,d,a,b); break;		// vandc
			case 8: ops[n++] = vx(1156,d,a,b); break;		// vor
			case 9: ops[n++] = vx(1220,d,a,b); break;		// vxor
			case 10: ops[n++] = vx(1284,d,a,b); break;		// vnor
			case 11: ops[n++] = vx(2,d,a,b); break;			// vmaxub
			case 12: ops[n++] = vx(322,d,a,b); break;		// vmaxsh
			case 13: ops[n++] = vx(514,d,a,b); break;		// vminub
			case 14: ops[n++] = vx(834,d,a,b); break;		// vminsh
			case 15: ops[n++] = vx(1026,d,a,b); break;		// vavgub
			case 16: ops[n++] = vx(1090,d,a,b); break;		// vavguh
			case 17: ops[n++] = vxr(6,d,a,b,rc); break;		// vcmpequb[.]
			case 18: ops[n++] = vxr(70,d,a,b,rc); break;	// vcmpequh[.]
			case 19: ops[n++] = vxr(134,d,a,b,rc); break;	// vcmpequw[.]
			case 20: ops[n++] = vxr(774,d,a,b,rc); break;	// vcmpgtsb[.]
			case 21: ops[n++] = vxr(838,d,a,b,rc); break;	// vcmpgtsh[.]
			case 22: ops[n++] = vxr(902,d,a,b,rc); break;	// vcmpgtsw[.]
			case 23: ops[n++] = va(42,d,a,b,c); break;		// vsel
			case 24: ops[n++] = va(43,d,a,b,c); break;		// vperm
			case 25: ops[n++] = vx(524,d,rnd()%16,b); break;	// vspltb
			case 26: ops[n++] = vx(588,d,rnd()%8,b); break;		// vsplth
			case 27: ops[n++] = vx(652,d,rnd()%4,b); break;		// vspltw
			case 28: ops[n++] = vx(780,d,rnd()%32,0); break;	// vspltisb
			case 29: ops[n++] = vx(908,d,rnd()%32,0); break;	// vspltisw
			}
		}
		ops[n++] = POWERPC_BLR;

		regfile in;
		for (int i = 0; i < 32; i++) in.gpr[i] = rnd();
		for (int i = 0; i < 32; i++)
			for (int j = 0; j < 4; j++) in.vr[i][j] = rnd();
		in.lr = 0; in.ctr = 0; in.cr = rnd(); in.xer = rnd() & 0xe000007f;

		load_snippet(ops, n);
		regfile ai, aj;
		seed(interp, in); run(interp); snapshot(interp, ai);
		seed(jit, in);    run(jit);    snapshot(jit, aj);
		total++;
		char nm[32]; snprintf(nm, sizeof nm, "vec#%d", t);
		if (diff(nm, ai, aj)) failed++;
	}

	// --- suite 13b: vector float (vaddfp/vsubfp/vmaddfp/vnmsubfp + float
	// compares) over float-biased lane patterns: normals, zeros, infs,
	// NaNs, subnormals ---
	for (int t = 0; t < 400; t++) {
		uint32 ops[24]; int n = 0;
		int len = 2 + (rnd() % 8);
		for (int k = 0; k < len && n < 20; k++) {
			int d = rnd() % 8, a = rnd() % 8, b = rnd() % 8, c = rnd() % 8;
			int rc = rnd() & 1;
			switch (rnd() % 7) {
			case 0: ops[n++] = vx(10,d,a,b); break;			// vaddfp
			case 1: ops[n++] = vx(74,d,a,b); break;			// vsubfp
			case 2: ops[n++] = va(46,d,a,b,c); break;		// vmaddfp
			case 3: ops[n++] = va(47,d,a,b,c); break;		// vnmsubfp
			case 4: ops[n++] = vxr(198,d,a,b,rc); break;	// vcmpeqfp[.]
			case 5: ops[n++] = vxr(454,d,a,b,rc); break;	// vcmpgefp[.]
			case 6: ops[n++] = vxr(710,d,a,b,rc); break;	// vcmpgtfp[.]
			}
		}
		ops[n++] = POWERPC_BLR;

		regfile in;
		for (int i = 0; i < 32; i++) in.gpr[i] = rnd();
		for (int i = 0; i < 32; i++) {
			// halves of rnd_fp() doubles give biased single patterns;
			// mix in pure float specials occasionally
			uint64 x = rnd_fp(), y = rnd_fp();
			in.vr[i][0] = (uint32)x; in.vr[i][1] = (uint32)(x >> 32);
			in.vr[i][2] = (uint32)y; in.vr[i][3] = (uint32)(y >> 32);
			if ((rnd() & 7) == 0) {
				static const uint32 fs[] = { 0x00000000, 0x80000000, 0x7f800000,
					0xff800000, 0x7fc00001, 0x00400000, 0x3f800000, 0xbf800000 };
				in.vr[i][rnd() & 3] = fs[rnd() & 7];
			}
		}
		in.lr = 0; in.ctr = 0; in.cr = rnd(); in.xer = rnd() & 0xe000007f;

		load_snippet(ops, n);
		regfile ai, aj;
		seed(interp, in); run(interp); snapshot(interp, ai);
		seed(jit, in);    run(jit);    snapshot(jit, aj);
		total++;
		char nm[32]; snprintf(nm, sizeof nm, "vecfp#%d", t);
		if (diff(nm, ai, aj)) failed++;
	}

	// --- suite 14: LVX/STVX/LVEWX/STVEWX round-trips over the data area,
	// byte-compared afterwards ---
	for (int t = 0; t < 300; t++) {
		uint32 ops[24]; int n = 0;
		int len = 3 + (rnd() % 8);
		for (int k = 0; k < len && n < 20; k++) {
			int d = rnd() % 8;
			int b = 11 + (rnd() % 2);
			switch (rnd() % 6) {
			case 0: ops[n++] = lvx_(d,0,10); break;
			case 1: ops[n++] = stvx_(d,0,10); break;
			case 2: ops[n++] = lvxl_(d,10,b); break;
			case 3: ops[n++] = stvxl_(d,10,b); break;
			case 4: ops[n++] = lvewx_(d,10,b); break;
			case 5: ops[n++] = stvewx_(d,10,b); break;
			}
		}
		ops[n++] = POWERPC_BLR;

		regfile in;
		for (int i = 0; i < 32; i++) in.gpr[i] = rnd();
		for (int i = 0; i < 32; i++)
			for (int j = 0; j < 4; j++) in.vr[i][j] = rnd();
		in.gpr[10] = guest_data + DATA_SIZE/2;
		in.gpr[11] = rnd() % 0x100;		// arbitrary (incl. unaligned) offsets
		in.gpr[12] = rnd() % 0x100;
		in.lr = 0; in.ctr = 0; in.cr = rnd(); in.xer = rnd() & 0xe000007f;

		load_snippet(ops, n);
		uint32 fill = rnd();
		regfile ai, aj;
		fill_data(fill);
		seed(interp, in); run(interp); snapshot(interp, ai); snap_data();
		fill_data(fill);
		seed(jit, in);    run(jit);    snapshot(jit, aj);
		total++;
		char nm[32]; snprintf(nm, sizeof nm, "vecmem#%d", t);
		if (diff(nm, ai, aj) + diff_data(nm)) failed++;
	}

	// --- suite 12: trap chaining through continuable pseudo-EmulOps ---
	// a) random ALU + pseudo-EmulOp interleavings: with trap chaining the
	// whole program is one JIT block crossing several handler invokes
	for (int t = 0; t < 300; t++) {
		uint32 ops[24]; int n = 0;
		int len = 3 + (rnd() % 8);
		for (int k = 0; k < len; k++) {
			switch (rnd() % 4) {
			case 0: ops[n++] = addi(4, 4, 1 + (rnd() % 7)); break;
			case 1: ops[n++] = xor_(5, 5, 4, 0); break;
			case 2: ops[n++] = add_(9, 9, 7, 1); break;
			default: ops[n++] = POWERPC_EMUL_OP | (5 + (rnd() % 59)); break;
			}
		}
		ops[n++] = POWERPC_BLR;

		regfile in;
		for (int i = 0; i < 32; i++) in.gpr[i] = rnd();
		in.lr = 0; in.ctr = 0; in.cr = rnd(); in.xer = rnd() & 0xe000007f;

		load_snippet(ops, n);
		regfile ai, aj;
		seed(interp, in); run(interp); snapshot(interp, ai);
		seed(jit, in);    run(jit);    snapshot(jit, aj);
		total++;
		char nm[32]; snprintf(nm, sizeof nm, "trap#%d", t);
		if (diff(nm, ai, aj)) failed++;
	}

	// b) data-dependent redirect (low6=3): resumes at +4 when r6 is even,
	// jumps to LR (ending the program) when odd -- the resume guard's pc
	// check must catch the redirect on a block compiled for fall-through
	for (int t = 0; t < 40; t++) {
		uint32 ops[8]; int n = 0;
		ops[n++] = POWERPC_EMUL_OP | 3;
		ops[n++] = addi(4, 4, 7);
		ops[n++] = xor_(5, 5, 4, 0);
		ops[n++] = POWERPC_BLR;

		regfile in;
		for (int i = 0; i < 32; i++) in.gpr[i] = rnd();
		in.gpr[6] = (in.gpr[6] & ~1u) | (t & 1);	// alternate parity
		in.lr = 0; in.ctr = 0; in.cr = rnd(); in.xer = rnd() & 0xe000007f;

		load_snippet(ops, n);
		regfile ai, aj;
		seed(interp, in); run(interp); snapshot(interp, ai);
		seed(jit, in);    run(jit);    snapshot(jit, aj);
		total++;
		char nm[32]; snprintf(nm, sizeof nm, "trapredir#%d", t);
		if (diff(nm, ai, aj)) failed++;
	}

	// c) trap-chained self-modifying code: both engines must yield 42
	{
		uint32 ri = trap_smc_scenario(interp);
		uint32 rj = trap_smc_scenario(jit);
		total++;
		if (ri != 42 || rj != 42) {
			printf("  [trap-smc] interp r3=%u jit r3=%u (both must be 42; "
				   "7 = stale inline continuation past an invalidating trap)\n", ri, rj);
			failed++;
		}
	}

	printf("\n%d/%d programs matched, %d diverged\n", total - failed, total, failed);
	printf("JIT blocks compiled: %lu (0 would mean the JIT never ran)\n",
		   kpx_jit_compile_count);
	printf("Direct chain links resolved: %lu (0 would mean chaining never engaged)\n",
		   kpx_jit_chain_count);
	printf("Trap-chained SHEEP continuations: %lu (0 would mean trap chaining never engaged)\n",
		   kpx_jit_trap_chain_count);
	printf("Native vector emissions: %lu (0 would mean AltiVec stayed generic)\n",
		   kpx_jit_vector_native_count);
#ifdef KPX_JIT_INSTRUMENT
	printf("Native FP helper calls: %lu (0 would mean FP stayed generic)\n",
		   kpx_jit_fp_helper_count);
	printf("Inline fastmem accesses emitted: %lu (0 would mean memory ops fell back to helpers)\n",
		   kpx_jit_inline_mem_emitted);
	printf("Fastmem cold-path helper calls: %lu (expected: kernel-window suite traffic only)\n",
		   kpx_jit_mem_cold_count);
	if (kpx_jit_compile_count == 0) {
		printf("FAIL: JIT path was never exercised\n");
		return 2;
	}
	if (kpx_jit_chain_count == 0) {
		printf("FAIL: direct block chaining was never exercised\n");
		return 2;
	}
	if (kpx_jit_vector_native_count == 0) {
		printf("FAIL: native AltiVec path was never exercised\n");
		return 2;
	}
#if defined(__aarch64__)
	// arm64-backend-only teeth: trap chaining, native FP helpers, inline
	// fastmem, and the coarse-filter cold path exist only in that backend.
	// The x86 dyngen backend routes SHEEP/FP/memory through its own
	// (stub-translated) mechanisms and legitimately reports 0 here.
	if (kpx_jit_trap_chain_count == 0) {
		printf("FAIL: trap chaining was never exercised\n");
		return 2;
	}
	if (kpx_jit_fp_helper_count == 0) {
		printf("FAIL: native FP path was never exercised\n");
		return 2;
	}
	if (kpx_jit_inline_mem_emitted == 0) {
		printf("FAIL: inline fastmem was never emitted\n");
		return 2;
	}
	// Only suite 6's kernel-window traffic may legitimately go cold (the
	// guest arena is bump-allocated from guest 0, far below the coarse
	// bound). Equality — not just nonzero — also catches the inverse
	// regression, where a broken filter sends ALL traffic to the (correct
	// but slow) helpers and every program still byte-matches.
	const unsigned long expected_cold = 300 * 8;	// kwin programs x accesses
	if (kpx_jit_mem_cold_count != expected_cold) {
		printf("FAIL: fastmem cold-path count %lu != expected %lu (filter mis-routing)\n",
			   kpx_jit_mem_cold_count, expected_cold);
		return 2;
	}
#endif
#else
	printf("(instrument counters unavailable: built without KPX_JIT_INSTRUMENT)\n");
#endif
	return failed ? 1 : 0;
}
