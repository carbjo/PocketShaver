/*
 *  dyngen-target-exec.h - arm64 register assignments for the hand-written
 *                         JIT backend
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

#ifndef DYNGEN_TARGET_EXEC_H
#define DYNGEN_TARGET_EXEC_H

/*
 *  Unlike the other backends these are not consumed by dyngen-compiled op
 *  templates (there are none on arm64); they document and centralize the
 *  register plan of the hand emitters in *-dyngen-ops-arm64.hpp:
 *    x19 = CPU (powerpc_cpu *), x20 = T0/A0, x21 = T1/A1, x22 = T2/A2.
 *  All four are AAPCS64 callee-saved, so C helper calls made from inside
 *  generated code preserve them; op_execute saves/restores them around
 *  block execution.
 *
 *  AREG4 is deliberately NOT defined: defining it would make dyngen-exec.h
 *  define REG_T3, which toggles an optional powerpc_dyngen data member on
 *  and off per translation unit depending on include order.
 */

#define AREG0 "x19"
#define AREG1 "x20"
#define AREG2 "x21"
#define AREG3 "x22"

enum {
  AREG0_ID = 19,
  AREG1_ID = 20,
  AREG2_ID = 21,
  AREG3_ID = 22
};

/*
 *  DYNGEN_FAST_DISPATCH arms direct block chaining in the translator
 *  (direct_chaining_possible, ppc-translate.cpp). On arm64 only its
 *  definedness is consumed — the dyngen op template sources that expand
 *  the macro body are never compiled here (gen_op_branch_chain_1/2 are
 *  hand-emitted in ppc-dyngen-ops-arm64.hpp instead).
 */
#define DYNGEN_FAST_DISPATCH(TARGET) do { } while (0)

#endif /* DYNGEN_TARGET_EXEC_H */
