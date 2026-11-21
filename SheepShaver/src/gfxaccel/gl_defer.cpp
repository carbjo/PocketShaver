/*
 *  gl_defer.cpp - GL immediate-mode deferred batching: descriptors and drain
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Each GLDeferDesc says how to snapshot one immediate-mode setter's args so
 *  the call can be replayed later through GLDispatch verbatim. The table is
 *  hand-authored: gl_func_signatures[] only covers float functions, so it
 *  cannot give integer GPR counts.
 *
 *  Argument wire model (matches gl_dispatch.cpp / sheepshaver_glue.cpp):
 *    - scalar_gpr_count integer/pointer args arrive verbatim in r3...
 *    - Each float or double arg takes one 32-bit slot in float_bits[] (the
 *      glue narrows every FPR to float), so f and d variants share a mask.
 *    - "...v" variants take scalar_gpr_count ints then one trailing pointer;
 *      ptr_bytes is the guest array size to snapshot.
 *    - An opcode is either scalar/FP or trailing-pointer, never both.
 */

#include "gl_defer.h"

#include <cstdint>
#include <cstring>
#include <cassert>

#include "sysdeps.h"
#include "cpu_emulation.h"

// No header exposes these; defined in gl_thunks.cpp / gl_dispatch.cpp.
extern uint32_t gl_scratch_addr;            // scratch word holding the sub-opcode
extern uint32_t gl_ppc_sp;                  // PPC SP for stack-arg reads
extern int      gl_ppc_stack_arg_offset;    // dispatch-table stack shift
extern uint32_t GLDispatch(uint32_t r3, uint32_t r4, uint32_t r5, uint32_t r6,
                           uint32_t r7, uint32_t r8, uint32_t r9, uint32_t r10,
                           const uint32_t *float_bits, int num_float_args);

GLDeferDesc gl_defer_desc[GL_MAX_SUBOPCODE];
bool gl_defer_draining = false;

// Set when GLDrainDeferred detects ring corruption. Deferral then stays off for
// the session; glEndList checks this so it cannot re-enable it and drop
// vertices every batch.
bool gl_defer_failsafe_tripped = false;

// Diagnostic counters, always incremented.
uint64_t g_defer_records_drained = 0;  // total records replayed
uint64_t g_defer_drain_calls     = 0;  // total GLDrainDeferred calls that did work
uint64_t g_defer_fallbacks       = 0;  // deferrable opcodes that hit GLDispatch directly

// SheepMem ring addresses, set at thunk init. 0 means "not allocated";
// GLDrainDeferred checks gl_defer_count_addr.
uint32_t gl_defer_ring_base    = 0;
uint32_t gl_defer_head_addr    = 0;
uint32_t gl_defer_count_addr   = 0;
uint32_t gl_defer_enabled_addr = 0;
uint32_t gl_defer_common_tail  = 0;

namespace {

// One authored row. deferrable is implied.
struct GLDeferRow {
    uint16_t op;
    uint8_t  scalar_gpr_count;
    uint16_t fpr_mask;
    uint8_t  ptr_bytes;
};

// fpr masks for N consecutive floating args.
#define FPR1 0x1
#define FPR2 0x3
#define FPR3 0x7
#define FPR4 0xF

// Per-component byte sizes for the "...v" array variants.
#define BV_b  1
#define BV_ub 1
#define BV_s  2
#define BV_us 2
#define BV_i  4
#define BV_ui 4
#define BV_f  4
#define BV_d  8

// Only immediate-mode per-vertex setters. State changes, queries, glEnd,
// glArrayElement, glEval* and glRect* are intentionally absent, as is
// glFogCoord* (no GL_SUB_ constant exists).
const GLDeferRow kRows[] = {
    // --- glBegin --------------------------------------------------------------
    { GL_SUB_BEGIN, 1, 0, 0 },

    // --- glVertex{2,3,4}{s,i,f,d} + v variants --------------------------------
    // 2 components
    { GL_SUB_VERTEX2S, 2, 0, 0 },
    { GL_SUB_VERTEX2I, 2, 0, 0 },
    { GL_SUB_VERTEX2F, 0, FPR2, 0 },
    { GL_SUB_VERTEX2D, 0, FPR2, 0 },
    { GL_SUB_VERTEX2SV, 0, 0, 2 * BV_s },
    { GL_SUB_VERTEX2IV, 0, 0, 2 * BV_i },
    { GL_SUB_VERTEX2FV, 0, 0, 2 * BV_f },
    { GL_SUB_VERTEX2DV, 0, 0, 2 * BV_d },
    // 3 components
    { GL_SUB_VERTEX3S, 3, 0, 0 },
    { GL_SUB_VERTEX3I, 3, 0, 0 },
    { GL_SUB_VERTEX3F, 0, FPR3, 0 },
    { GL_SUB_VERTEX3D, 0, FPR3, 0 },
    { GL_SUB_VERTEX3SV, 0, 0, 3 * BV_s },
    { GL_SUB_VERTEX3IV, 0, 0, 3 * BV_i },
    { GL_SUB_VERTEX3FV, 0, 0, 3 * BV_f },
    { GL_SUB_VERTEX3DV, 0, 0, 3 * BV_d },
    // 4 components
    { GL_SUB_VERTEX4S, 4, 0, 0 },
    { GL_SUB_VERTEX4I, 4, 0, 0 },
    { GL_SUB_VERTEX4F, 0, FPR4, 0 },
    { GL_SUB_VERTEX4D, 0, FPR4, 0 },
    { GL_SUB_VERTEX4SV, 0, 0, 4 * BV_s },
    { GL_SUB_VERTEX4IV, 0, 0, 4 * BV_i },
    { GL_SUB_VERTEX4FV, 0, 0, 4 * BV_f },
    { GL_SUB_VERTEX4DV, 0, 0, 4 * BV_d },

    // --- glColor{3,4}{b,s,i,f,d,ub,us,ui} + v variants ------------------------
    // 3 components
    { GL_SUB_COLOR3B, 3, 0, 0 },
    { GL_SUB_COLOR3S, 3, 0, 0 },
    { GL_SUB_COLOR3I, 3, 0, 0 },
    { GL_SUB_COLOR3F, 0, FPR3, 0 },
    { GL_SUB_COLOR3D, 0, FPR3, 0 },
    { GL_SUB_COLOR3UB, 3, 0, 0 },
    { GL_SUB_COLOR3US, 3, 0, 0 },
    { GL_SUB_COLOR3UI, 3, 0, 0 },
    { GL_SUB_COLOR3BV, 0, 0, 3 * BV_b },
    { GL_SUB_COLOR3SV, 0, 0, 3 * BV_s },
    { GL_SUB_COLOR3IV, 0, 0, 3 * BV_i },
    { GL_SUB_COLOR3FV, 0, 0, 3 * BV_f },
    { GL_SUB_COLOR3DV, 0, 0, 3 * BV_d },
    { GL_SUB_COLOR3UBV, 0, 0, 3 * BV_ub },
    { GL_SUB_COLOR3USV, 0, 0, 3 * BV_us },
    { GL_SUB_COLOR3UIV, 0, 0, 3 * BV_ui },
    // 4 components
    { GL_SUB_COLOR4B, 4, 0, 0 },
    { GL_SUB_COLOR4S, 4, 0, 0 },
    { GL_SUB_COLOR4I, 4, 0, 0 },
    { GL_SUB_COLOR4F, 0, FPR4, 0 },
    { GL_SUB_COLOR4D, 0, FPR4, 0 },
    { GL_SUB_COLOR4UB, 4, 0, 0 },
    { GL_SUB_COLOR4US, 4, 0, 0 },
    { GL_SUB_COLOR4UI, 4, 0, 0 },
    { GL_SUB_COLOR4BV, 0, 0, 4 * BV_b },
    { GL_SUB_COLOR4SV, 0, 0, 4 * BV_s },
    { GL_SUB_COLOR4IV, 0, 0, 4 * BV_i },
    { GL_SUB_COLOR4FV, 0, 0, 4 * BV_f },
    { GL_SUB_COLOR4DV, 0, 0, 4 * BV_d },
    { GL_SUB_COLOR4UBV, 0, 0, 4 * BV_ub },
    { GL_SUB_COLOR4USV, 0, 0, 4 * BV_us },
    { GL_SUB_COLOR4UIV, 0, 0, 4 * BV_ui },

    // --- glTexCoord{1,2,3,4}{s,i,f,d} + v variants ----------------------------
    // 1 component
    { GL_SUB_TEX_COORD1S, 1, 0, 0 },
    { GL_SUB_TEX_COORD1I, 1, 0, 0 },
    { GL_SUB_TEX_COORD1F, 0, FPR1, 0 },
    { GL_SUB_TEX_COORD1D, 0, FPR1, 0 },
    { GL_SUB_TEX_COORD1SV, 0, 0, 1 * BV_s },
    { GL_SUB_TEX_COORD1IV, 0, 0, 1 * BV_i },
    { GL_SUB_TEX_COORD1FV, 0, 0, 1 * BV_f },
    { GL_SUB_TEX_COORD1DV, 0, 0, 1 * BV_d },
    // 2 components
    { GL_SUB_TEX_COORD2S, 2, 0, 0 },
    { GL_SUB_TEX_COORD2I, 2, 0, 0 },
    { GL_SUB_TEX_COORD2F, 0, FPR2, 0 },
    { GL_SUB_TEX_COORD2D, 0, FPR2, 0 },
    { GL_SUB_TEX_COORD2SV, 0, 0, 2 * BV_s },
    { GL_SUB_TEX_COORD2IV, 0, 0, 2 * BV_i },
    { GL_SUB_TEX_COORD2FV, 0, 0, 2 * BV_f },
    { GL_SUB_TEX_COORD2DV, 0, 0, 2 * BV_d },
    // 3 components
    { GL_SUB_TEX_COORD3S, 3, 0, 0 },
    { GL_SUB_TEX_COORD3I, 3, 0, 0 },
    { GL_SUB_TEX_COORD3F, 0, FPR3, 0 },
    { GL_SUB_TEX_COORD3D, 0, FPR3, 0 },
    { GL_SUB_TEX_COORD3SV, 0, 0, 3 * BV_s },
    { GL_SUB_TEX_COORD3IV, 0, 0, 3 * BV_i },
    { GL_SUB_TEX_COORD3FV, 0, 0, 3 * BV_f },
    { GL_SUB_TEX_COORD3DV, 0, 0, 3 * BV_d },
    // 4 components
    { GL_SUB_TEX_COORD4S, 4, 0, 0 },
    { GL_SUB_TEX_COORD4I, 4, 0, 0 },
    { GL_SUB_TEX_COORD4F, 0, FPR4, 0 },
    { GL_SUB_TEX_COORD4D, 0, FPR4, 0 },
    { GL_SUB_TEX_COORD4SV, 0, 0, 4 * BV_s },
    { GL_SUB_TEX_COORD4IV, 0, 0, 4 * BV_i },
    { GL_SUB_TEX_COORD4FV, 0, 0, 4 * BV_f },
    { GL_SUB_TEX_COORD4DV, 0, 0, 4 * BV_d },

    // --- glNormal3{b,s,i,f,d} + v variants ------------------------------------
    { GL_SUB_NORMAL3B, 3, 0, 0 },
    { GL_SUB_NORMAL3S, 3, 0, 0 },
    { GL_SUB_NORMAL3I, 3, 0, 0 },
    { GL_SUB_NORMAL3F, 0, FPR3, 0 },
    { GL_SUB_NORMAL3D, 0, FPR3, 0 },
    { GL_SUB_NORMAL3BV, 0, 0, 3 * BV_b },
    { GL_SUB_NORMAL3SV, 0, 0, 3 * BV_s },
    { GL_SUB_NORMAL3IV, 0, 0, 3 * BV_i },
    { GL_SUB_NORMAL3FV, 0, 0, 3 * BV_f },
    { GL_SUB_NORMAL3DV, 0, 0, 3 * BV_d },

    // --- glMultiTexCoord{1,2,3,4}{s,i,f,d}ARB + v variants --------------------
    // The GLenum target is one int GPR. fpr_mask bits are arg positions and
    // arg0 is the target, so FP components start at bit 1: (FPRn << 1).
    // 1 component
    { GL_SUB_MULTI_TEX_COORD1S_ARB, 2, 0, 0 },
    { GL_SUB_MULTI_TEX_COORD1I_ARB, 2, 0, 0 },
    { GL_SUB_MULTI_TEX_COORD1F_ARB, 1, (FPR1 << 1), 0 },
    { GL_SUB_MULTI_TEX_COORD1D_ARB, 1, (FPR1 << 1), 0 },
    { GL_SUB_MULTI_TEX_COORD1SV_ARB, 1, 0, 1 * BV_s },
    { GL_SUB_MULTI_TEX_COORD1IV_ARB, 1, 0, 1 * BV_i },
    { GL_SUB_MULTI_TEX_COORD1FV_ARB, 1, 0, 1 * BV_f },
    { GL_SUB_MULTI_TEX_COORD1DV_ARB, 1, 0, 1 * BV_d },
    // 2 components
    { GL_SUB_MULTI_TEX_COORD2S_ARB, 3, 0, 0 },
    { GL_SUB_MULTI_TEX_COORD2I_ARB, 3, 0, 0 },
    { GL_SUB_MULTI_TEX_COORD2F_ARB, 1, (FPR2 << 1), 0 },
    { GL_SUB_MULTI_TEX_COORD2D_ARB, 1, (FPR2 << 1), 0 },
    { GL_SUB_MULTI_TEX_COORD2SV_ARB, 1, 0, 2 * BV_s },
    { GL_SUB_MULTI_TEX_COORD2IV_ARB, 1, 0, 2 * BV_i },
    { GL_SUB_MULTI_TEX_COORD2FV_ARB, 1, 0, 2 * BV_f },
    { GL_SUB_MULTI_TEX_COORD2DV_ARB, 1, 0, 2 * BV_d },
    // 3 components
    { GL_SUB_MULTI_TEX_COORD3S_ARB, 4, 0, 0 },
    { GL_SUB_MULTI_TEX_COORD3I_ARB, 4, 0, 0 },
    { GL_SUB_MULTI_TEX_COORD3F_ARB, 1, (FPR3 << 1), 0 },
    { GL_SUB_MULTI_TEX_COORD3D_ARB, 1, (FPR3 << 1), 0 },
    { GL_SUB_MULTI_TEX_COORD3SV_ARB, 1, 0, 3 * BV_s },
    { GL_SUB_MULTI_TEX_COORD3IV_ARB, 1, 0, 3 * BV_i },
    { GL_SUB_MULTI_TEX_COORD3FV_ARB, 1, 0, 3 * BV_f },
    { GL_SUB_MULTI_TEX_COORD3DV_ARB, 1, 0, 3 * BV_d },
    // 4 components
    { GL_SUB_MULTI_TEX_COORD4S_ARB, 5, 0, 0 },
    { GL_SUB_MULTI_TEX_COORD4I_ARB, 5, 0, 0 },
    { GL_SUB_MULTI_TEX_COORD4F_ARB, 1, (FPR4 << 1), 0 },
    { GL_SUB_MULTI_TEX_COORD4D_ARB, 1, (FPR4 << 1), 0 },
    { GL_SUB_MULTI_TEX_COORD4SV_ARB, 1, 0, 4 * BV_s },
    { GL_SUB_MULTI_TEX_COORD4IV_ARB, 1, 0, 4 * BV_i },
    { GL_SUB_MULTI_TEX_COORD4FV_ARB, 1, 0, 4 * BV_f },
    { GL_SUB_MULTI_TEX_COORD4DV_ARB, 1, 0, 4 * BV_d },

    // --- glSecondaryColor3{b,s,i,f,d,ub,us,ui}EXT + v variants ----------------
    // (constant naming in gl_engine.h is inconsistent for the b/bv/d rows.)
    { GL_SUB_SECONDARYCOLOR3B_EXT, 3, 0, 0 },
    { GL_SUB_SECONDARY_COLOR3S_EXT, 3, 0, 0 },
    { GL_SUB_SECONDARY_COLOR3I_EXT, 3, 0, 0 },
    { GL_SUB_SECONDARY_COLOR3F_EXT, 0, FPR3, 0 },
    { GL_SUB_SECONDARYCOLOR3D_EXT, 0, FPR3, 0 },
    { GL_SUB_SECONDARY_COLOR3UB_EXT, 3, 0, 0 },
    { GL_SUB_SECONDARY_COLOR3US_EXT, 3, 0, 0 },
    { GL_SUB_SECONDARY_COLOR3UI_EXT, 3, 0, 0 },
    { GL_SUB_SECONDARYCOLOR3BV_EXT, 0, 0, 3 * BV_b },
    { GL_SUB_SECONDARY_COLOR3SV_EXT, 0, 0, 3 * BV_s },
    { GL_SUB_SECONDARY_COLOR3IV_EXT, 0, 0, 3 * BV_i },
    { GL_SUB_SECONDARY_COLOR3FV_EXT, 0, 0, 3 * BV_f },
    { GL_SUB_SECONDARY_COLOR3DV_EXT, 0, 0, 3 * BV_d },
    { GL_SUB_SECONDARY_COLOR3UBV_EXT, 0, 0, 3 * BV_ub },
    { GL_SUB_SECONDARY_COLOR3USV_EXT, 0, 0, 3 * BV_us },
    { GL_SUB_SECONDARY_COLOR3UIV_EXT, 0, 0, 3 * BV_ui },

    // --- glEdgeFlag{,v} -------------------------------------------------------
    { GL_SUB_EDGE_FLAG, 1, 0, 0 },
    { GL_SUB_EDGE_FLAGV, 0, 0, 1 * BV_b },

    // --- glIndex{i,f,d,s,ub} + v variants -------------------------------------
    { GL_SUB_INDEXI, 1, 0, 0 },
    { GL_SUB_INDEXF, 0, FPR1, 0 },
    { GL_SUB_INDEXD, 0, FPR1, 0 },
    { GL_SUB_INDEXS, 1, 0, 0 },
    { GL_SUB_INDEXUB, 1, 0, 0 },
    { GL_SUB_INDEXIV, 0, 0, 1 * BV_i },
    { GL_SUB_INDEXFV, 0, 0, 1 * BV_f },
    { GL_SUB_INDEXDV, 0, 0, 1 * BV_d },
    { GL_SUB_INDEXSV, 0, 0, 1 * BV_s },
    { GL_SUB_INDEXUBV, 0, 0, 1 * BV_ub },
};

int popcount16(uint16_t v) {
    int n = 0;
    while (v) { n += (v & 1u); v >>= 1; }
    return n;
}

int round_up_4(int n) { return (n + 3) & ~3; }

// Wire size of one record: 8-byte header + scalars + floats + padded snapshot.
int record_size(const GLDeferDesc &d) {
    return 8
         + 4 * (int)d.scalar_gpr_count
         + 4 * popcount16(d.fpr_mask)
         + round_up_4((int)d.ptr_bytes);
}

}  // namespace

void GLDeferBuildDescriptors(void) {
    std::memset(gl_defer_desc, 0, sizeof(gl_defer_desc));

    for (const GLDeferRow &row : kRows) {
        assert(row.op < GL_MAX_SUBOPCODE && "descriptor opcode out of range");
        GLDeferDesc &d = gl_defer_desc[row.op];
        assert(d.deferrable == 0 && "duplicate descriptor opcode");

        d.scalar_gpr_count = row.scalar_gpr_count;
        d.fpr_mask         = row.fpr_mask;
        d.ptr_bytes        = row.ptr_bytes;
        d.deferrable       = 1;

        assert(!(d.ptr_bytes > 0 && d.fpr_mask != 0) &&
               "descriptor cannot mix fpr args and a trailing pointer");

        assert(record_size(d) <= GL_DEFER_MAX_RECORD &&
               "descriptor record exceeds GL_DEFER_MAX_RECORD");
    }
}

bool GLDeferIsDeferrable(uint32_t op) {
    return op < GL_MAX_SUBOPCODE && gl_defer_desc[op].deferrable;
}

// Decode the record at guest address `rec` into GLDispatch args. Returns the
// record size from its header.
//
// Wire layout (big-endian guest words):
//   rec+0 : sub_opcode
//   rec+4 : size_bytes
//   rec+8 : scalars, then float bits, then round_up_4(ptr_bytes) snapshot bytes.
//
// A trailing pointer is replaced by the in-ring address of the snapshot, since
// the guest's original buffer may already be reused. Unused slots are zeroed.
uint32_t GLDeferDecodeRecord(uint32_t rec, GLDeferDecoded *out) {
    std::memset(out, 0, sizeof(*out));

    const uint32_t sub_opcode = ReadMacInt32(rec + 0);
    const uint32_t size_bytes = ReadMacInt32(rec + 4);

    out->sub_opcode = sub_opcode;

    assert(sub_opcode < GL_MAX_SUBOPCODE && "decoded sub_opcode out of range");
    const GLDeferDesc &d = gl_defer_desc[sub_opcode];

    const int scalar_count = (int)d.scalar_gpr_count;
    const int fpr_count    = popcount16(d.fpr_mask);

    const uint32_t scalars_off = rec + 8;
    for (int k = 0; k < scalar_count; ++k)
        out->gpr[k] = ReadMacInt32(scalars_off + 4u * (uint32_t)k);

    const uint32_t fprs_off = scalars_off + 4u * (uint32_t)scalar_count;
    for (int n = 0; n < fpr_count; ++n)
        out->float_bits[n] = ReadMacInt32(fprs_off + 4u * (uint32_t)n);
    out->nfloat = fpr_count;

    if (d.ptr_bytes > 0) {
        // fpr_count is always 0 here (asserted at build); kept for safety.
        const uint32_t ptr_off = fprs_off + 4u * (uint32_t)fpr_count;
        out->gpr[scalar_count] = ptr_off;
        out->ngpr = scalar_count + 1;
    } else {
        out->ngpr = scalar_count;
    }

    assert(size_bytes == (uint32_t)(8
                + 4 * scalar_count
                + 4 * fpr_count
                + round_up_4((int)d.ptr_bytes)) &&
           "record size header disagrees with descriptor layout");

    return size_bytes;
}

// Replay every buffered record through GLDispatch, then clear the ring.
void GLDrainDeferred(void) {
    if (gl_defer_draining) return;          // re-entrancy guard
    if (!gl_defer_count_addr) return;       // ring not allocated yet

    uint32_t count = ReadMacInt32(gl_defer_count_addr);
    if (!count) return;

    g_defer_drain_calls++;
    gl_defer_draining = true;

    // The drain runs inside GLDispatch for the triggering call, whose SP and
    // sub-opcode are already published. Replay clobbers them, so restore on
    // every exit or 9+ arg calls (glTexImage2D) read zeros.
    struct GLDeferCallerArgs {
        uint32_t sp, scratch;
        int      stack_arg_offset;
        GLDeferCallerArgs()
            : sp(gl_ppc_sp), scratch(ReadMacInt32(gl_scratch_addr)),
              stack_arg_offset(gl_ppc_stack_arg_offset) {}
        ~GLDeferCallerArgs() {
            gl_ppc_sp = sp;
            gl_ppc_stack_arg_offset = stack_arg_offset;
            WriteMacInt32(gl_scratch_addr, scratch);
        }
    } caller_args;

    uint32_t total = ReadMacInt32(gl_defer_head_addr);   // bytes written
    WriteMacInt32(gl_defer_count_addr, 0);               // reset before replay so replayed calls see an empty ring
    WriteMacInt32(gl_defer_head_addr, 0);

    static int s_failsafe_log_count = 0;

    uint32_t off = 0;
    for (uint32_t i = 0; i < count && off < total; i++) {
        // Structural failsafe: validate the header before decoding.
        uint32_t rec_base = gl_defer_ring_base + off;
        uint32_t sub_op   = ReadMacInt32(rec_base + 0);
        uint32_t hdr_size = ReadMacInt32(rec_base + 4);

        bool opcode_ok = (sub_op < GL_MAX_SUBOPCODE) && gl_defer_desc[sub_op].deferrable;

        uint32_t desc_size = 0;
        if (opcode_ok) {
            const GLDeferDesc &desc = gl_defer_desc[sub_op];
            desc_size = (uint32_t)(8
                + 4 * (int)desc.scalar_gpr_count
                + 4 * popcount16(desc.fpr_mask)
                + round_up_4((int)desc.ptr_bytes));
        }
        bool size_ok = (hdr_size != 0) && opcode_ok && (hdr_size == desc_size);

        bool bounds_ok = (off + hdr_size <= total) && (hdr_size != 0);

        if (!opcode_ok || !size_ok || !bounds_ok) {
            if (s_failsafe_log_count < 16) {
                s_failsafe_log_count++;
                GL_LOG("GLDrainDeferred failsafe: ring corruption at record %u "
                       "(off=%u hdr_size=%u desc_size=%u total=%u sub_op=%u "
                       "opcode_ok=%d size_ok=%d bounds_ok=%d) "
                       "-- disabling deferral, dropping tail, degrading to direct-trap",
                       i, off, hdr_size, desc_size, total, sub_op,
                       (int)opcode_ok, (int)size_ok, (int)bounds_ok);
            }
            // Fall back to direct traps for the rest of the session.
            gl_defer_failsafe_tripped = true;
            WriteMacInt32(gl_defer_enabled_addr, 0);
            // Ring is already reset above.
            gl_defer_draining = false;
            return;
        }

        GLDeferDecoded d;
        uint32_t sz = GLDeferDecodeRecord(rec_base, &d);
        if (sz == 0) break;

        WriteMacInt32(gl_scratch_addr, d.sub_opcode);
        gl_ppc_sp = 0;
        gl_ppc_stack_arg_offset = 0;
        GLDispatch(d.gpr[0], d.gpr[1], d.gpr[2], d.gpr[3],
                   d.gpr[4], d.gpr[5], d.gpr[6], d.gpr[7],
                   d.float_bits, d.nfloat);
        g_defer_records_drained++;
        off += sz;
    }

    gl_defer_draining = false;
}
