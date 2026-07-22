/*
 *  glide_pef_register.cpp - intentionally empty
 *
 *  Host 3dfx GlideLib*.bin / PEF files are for offline analysis only.
 *  The guest already has the Glide CFM extension; GlideInstallHooks patches
 *  it with FindLibSymbol exactly like DSpInstallHooks.
 */

#include "sysdeps.h"
#include "glide_engine.h"

bool GlideRegisterCfmLibraries(void)
{
	return true;
}
