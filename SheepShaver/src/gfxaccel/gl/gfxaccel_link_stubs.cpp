/*
 * Link stubs for symbols still migrating off Metal-only translation units.
 * Match C++ linkage used by callers (do not force extern "C" unless headers do).
 */
#include "sysdeps.h"
#include "cpu_emulation.h"
#include "dsp_draw_context.h"
#include "dsp_mode_enumerate.h"
#include "rave_metal_renderer.h"

#include <cstdint>

/* RsrcLocksDumpOnCrash now has a real implementation in rsrc_patches.cpp
 * (DII 'nift' CFM monitor); the placeholder stub was removed to avoid LNK2005. */

void DSpDrainLifecycleSync(void) {}
extern "C" void DSpVBLCompositorPublishCallback(void *, void *, double) {}

int32_t NativeATIClearDrawBuffer(uint32_t ctx, uint32_t rect)
{
	return NativeClearDrawBuffer(ctx, rect, 0);
}
int32_t NativeATIClearZBuffer(uint32_t ctx, uint32_t rect)
{
	return NativeClearZBuffer(ctx, rect, 0);
}
/* RaveForgetRTT / batch begin-end live in rave_gl_renderer.cpp now */
