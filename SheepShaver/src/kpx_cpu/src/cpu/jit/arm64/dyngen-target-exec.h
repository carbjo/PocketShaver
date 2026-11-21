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
 *  Register plan of the hand emitters (*-dyngen-ops-arm64.hpp). No
 *  dyngen-compiled op templates consume these on arm64.
 *    x19 = CPU (powerpc_cpu *), x20 = T0/A0, x21 = T1/A1, x22 = T2/A2.
 *  All are AAPCS64 callee-saved, so they survive C helper calls;
 *  op_execute saves/restores them around block execution.
 *
 *  Do not define AREG4: dyngen-exec.h would then define REG_T3, which
 *  toggles an optional powerpc_dyngen member per translation unit
 *  depending on include order.
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
 *  DYNGEN_FAST_DISPATCH enables direct block chaining in the translator
 *  (direct_chaining_possible, ppc-translate.cpp). On arm64 only its
 *  definedness matters: gen_op_branch_chain_1/2 are hand-emitted in
 *  ppc-dyngen-ops-arm64.hpp.
 */
#define DYNGEN_FAST_DISPATCH(TARGET) do { } while (0)

#endif /* DYNGEN_TARGET_EXEC_H */
