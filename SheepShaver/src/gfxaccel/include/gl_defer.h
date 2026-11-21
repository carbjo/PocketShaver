#ifndef GL_DEFER_H
#define GL_DEFER_H
#include <cstdint>
#include "gl_engine.h"

#ifndef GL_DEFER_RING_SIZE
#define GL_DEFER_RING_SIZE 65536   // 64 KiB SheepMem ring
#endif
#define GL_DEFER_MAX_RECORD 128    // worst-case single record (header + scalars/fprs/ptr)

struct GLDeferDesc {
    uint8_t  scalar_gpr_count;  // leading verbatim GPR args (r3..)
    uint16_t fpr_mask;          // bit i set => arg i is an FPR float (stored 32-bit)
    uint8_t  ptr_bytes;         // >0 => trailing GPR (index scalar_gpr_count) is a ptr; snapshot this many bytes
    uint8_t  deferrable;        // 1 => has a deferrable stub
};

// Guest-memory addresses (SheepMem), set in GLDeferInit / GLThunksInit:
extern uint32_t gl_defer_ring_base;    // first byte of ring
extern uint32_t gl_defer_head_addr;    // guest word: current write offset-from-base (bytes)
extern uint32_t gl_defer_count_addr;   // guest word: number of records pending
extern uint32_t gl_defer_enabled_addr; // guest word: 1=defer active, 0=fall back to trap (kill-switch + display-list gate)
extern uint32_t gl_defer_common_tail;  // shared fallback stubs `b` to when deferral is off or the
                                       // ring is full. Code address of its first instruction, not
                                       // a TVECT: it is branched to, not called.

extern GLDeferDesc gl_defer_desc[GL_MAX_SUBOPCODE];  // host authoritative table
extern bool gl_defer_draining;                        // host re-entrancy guard
extern bool gl_defer_failsafe_tripped;                // latched on ring corruption; never re-enable deferral once set

void GLDeferBuildDescriptors(void);    // build gl_defer_desc[] from signatures + ptr tables
bool GLDeferIsDeferrable(uint32_t sub_opcode);
void GLDrainDeferred(void);            // replay and clear the ring

// Diagnostic counters. g_defer_fallbacks counts deferrable opcodes that reached
// GLDispatch outside a drain (ring full or deferral disabled).
extern uint64_t g_defer_records_drained;
extern uint64_t g_defer_drain_calls;
extern uint64_t g_defer_fallbacks;

// Decode one record at guest addr `rec`; outputs args for GLDispatch.
struct GLDeferDecoded {
    uint32_t sub_opcode;
    uint32_t gpr[8];      // r3..r10 reconstructed (ptr arg => in-ring snapshot guest addr)
    int      ngpr;
    uint32_t float_bits[13];
    int      nfloat;
};
uint32_t GLDeferDecodeRecord(uint32_t rec, GLDeferDecoded *out);
#endif
