/*
 *  glide_engine.cpp - CFM symbol-table patcher for 3Dfx Glide (DSp twin)
 *
 *  Byte-for-byte the same model as dsp_install_hooks.cpp:
 *    FindLibSymbol the guest library that already exists on the Mac
 *    (Extensions / CFM search path), then overwrite the first 4 PPC
 *  instructions at each export's code to branch into our native TVECT.
 *
 *  We do NOT load host PEF files, GetMemFragment, or install Extensions.
 *  Host 3dfx GlideLib*.bin files are for offline analysis only.
 *
 * (C) 2026 RandoOnSteam (battlemageloveryt@gmail.com)
 */

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "macos_util.h"
#include "thunks.h"
#include "glide_engine.h"
#include "gfx_log.h"
#include "prefs.h"

#include <cstring>
#include <vector>

extern uint32_t glide_method_tvects[GLIDE_MAX_SUBOPCODE];
extern uint32_t glide_scratch_addr;

static bool glide_hooks_installed = false;
static bool glide_hooks_in_progress = false;
static bool glide_thunks_ready = false;
static int  glide_hooks_attempts = 0;
static const int GLIDE_HOOKS_MAX_ATTEMPTS = 3;

struct GlideInstallSymbol {
	const char *pascal_sym;
	int sub_opcode;
	const char *name;
};

/* D2 PEF-import surface + common Glide 3 exports (same idea as DSp's 53-row table). */
static const GlideInstallSymbol glide_symbols[] = {
	{ "\013grGlideInit",              kGlide_grGlideInit,              "grGlideInit" },
	{ "\017grGlideShutdown",          kGlide_grGlideShutdown,          "grGlideShutdown" },
	{ "\021grGlideGetVersion",        kGlide_grGlideGetVersion,        "grGlideGetVersion" },
	{ "\020grSstQueryBoards",         kGlide_grSstQueryBoards,         "grSstQueryBoards" },
	{ "\022grSstQueryHardware",       kGlide_grSstQueryHardware,       "grSstQueryHardware" },
	{ "\013grSstSelect",              kGlide_grSstSelect,              "grSstSelect" },
	{ "\014grSstWinOpen",             kGlide_grSstWinOpen,             "grSstWinOpen" },
	{ "\015grSstWinClose",            kGlide_grSstWinClose,            "grSstWinClose" },
	{ "\014grSstControl",             kGlide_grSstControl,             "grSstControl" },
	{ "\011grSstIdle",                kGlide_grSstIdle,                "grSstIdle" },
	{ "\013grSstIsBusy",              kGlide_grSstIsBusy,              "grSstIsBusy" },
	{ "\013grSstOrigin",              kGlide_grSstOrigin,              "grSstOrigin" },
	{ "\020grSstScreenWidth",         kGlide_grSstScreenWidth,         "grSstScreenWidth" },
	{ "\021grSstScreenHeight",        kGlide_grSstScreenHeight,        "grSstScreenHeight" },
	{ "\013grSstStatus",              kGlide_grSstStatus,              "grSstStatus" },
	{ "\017grSstVRetraceOn",          kGlide_grSstVRetraceOn,          "grSstVRetraceOn" },
	/* Alternate export spellings seen on some Mac 3Dfx builds.
	 * grSstVRetrace is 13 chars - was wrongly \016 (14) so FindLibSymbol never hit. */
	{ "\015grSstVRetrace",            kGlide_grSstVRetraceOn,          "grSstVRetrace" },
	{ "\016grSstVideoLine",           kGlide_grSstVideoLine,           "grSstVideoLine" },
	{ "\015grBufferClear",            kGlide_grBufferClear,            "grBufferClear" },
	{ "\014grBufferSwap",             kGlide_grBufferSwap,             "grBufferSwap" },
	{ "\022grBufferNumPending",       kGlide_grBufferNumPending,       "grBufferNumPending" },
	{ "\020grBuffersPending",         kGlide_grBufferNumPending,       "grBuffersPending" },
	{ "\016grRenderBuffer",           kGlide_grRenderBuffer,           "grRenderBuffer" },
	{ "\013grDrawPoint",              kGlide_grDrawPoint,              "grDrawPoint" },
	{ "\012grDrawLine",               kGlide_grDrawLine,               "grDrawLine" },
	{ "\016grDrawTriangle",           kGlide_grDrawTriangle,           "grDrawTriangle" },
	{ "\020grAADrawTriangle",         kGlide_grAADrawTriangle,         "grAADrawTriangle" },
	{ "\024grAlphaBlendFunction",     kGlide_grAlphaBlendFunction,     "grAlphaBlendFunction" },
	{ "\016grAlphaCombine",           kGlide_grAlphaCombine,           "grAlphaCombine" },
	{ "\014grClipWindow",             kGlide_grClipWindow,             "grClipWindow" },
	{ "\016grColorCombine",           kGlide_grColorCombine,           "grColorCombine" },
	{ "\013grColorMask",              kGlide_grColorMask,              "grColorMask" },
	{ "\024grConstantColorValue",     kGlide_grConstantColorValue,     "grConstantColorValue" },
	{ "\012grCullMode",               kGlide_grCullMode,               "grCullMode" },
	{ "\025grDepthBufferFunction",    kGlide_grDepthBufferFunction,    "grDepthBufferFunction" },
	{ "\021grDepthBufferMode",        kGlide_grDepthBufferMode,        "grDepthBufferMode" },
	{ "\013grDepthMask",              kGlide_grDepthMask,              "grDepthMask" },
	{ "\011grFogMode",                kGlide_grFogMode,                "grFogMode" },
	{ "\017grChromakeyMode",          kGlide_grChromakeyMode,          "grChromakeyMode" },
	{ "\020grChromakeyValue",         kGlide_grChromakeyValue,         "grChromakeyValue" },
	{ "\014grDitherMode",             kGlide_grDitherMode,             "grDitherMode" },
	{ "\013grTexSource",              kGlide_grTexSource,              "grTexSource" },
	{ "\016grTexClampMode",           kGlide_grTexClampMode,           "grTexClampMode" },
	{ "\014grTexCombine",             kGlide_grTexCombine,             "grTexCombine" },
	{ "\017grTexFilterMode",          kGlide_grTexFilterMode,          "grTexFilterMode" },
	{ "\017grTexMipMapMode",          kGlide_grTexMipMapMode,          "grTexMipMapMode" },
	{ "\023grTexDownloadMipMap",      kGlide_grTexDownloadMipMap,      "grTexDownloadMipMap" },
	{ "\030grTexDownloadMipMapLevel", kGlide_grTexDownloadMipMapLevel, "grTexDownloadMipMapLevel" },
	{ "\022grTexDownloadTable",       kGlide_grTexDownloadTable,       "grTexDownloadTable" },
	{ "\017grTexMinAddress",          kGlide_grTexMinAddress,          "grTexMinAddress" },
	{ "\017grTexMaxAddress",          kGlide_grTexMaxAddress,          "grTexMaxAddress" },
	{ "\024grTexCalcMemRequired",     kGlide_grTexCalcMemRequired,     "grTexCalcMemRequired" },
	{ "\005grGet",                    kGlide_grGet,                    "grGet" },
	{ "\013grGetString",              kGlide_grGetString,              "grGetString" },
	{ "\020grGetProcAddress",         kGlide_grGetProcAddress,         "grGetProcAddress" },
	{ "\007grReset",                  kGlide_grReset,                  "grReset" },
	{ "\010grEnable",                 kGlide_grEnable,                 "grEnable" },
	{ "\011grDisable",                kGlide_grDisable,                "grDisable" },
	{ "\022grCoordinateSystem",       kGlide_grCoordinateSystem,       "grCoordinateSystem" },
	{ "\021grCoordinateSpace",        kGlide_grCoordinateSystem,       "grCoordinateSpace" },
	{ "\016grVertexLayout",           kGlide_grVertexLayout,           "grVertexLayout" },
	{ "\021grDrawVertexArray",        kGlide_grDrawVertexArray,        "grDrawVertexArray" },
	{ "\033grDrawVertexArrayContiguous", kGlide_grDrawVertexArrayContiguous, "grDrawVertexArrayContiguous" },
	{ "\010grFinish",                 kGlide_grFinish,                 "grFinish" },
	{ "\007grFlush",                  kGlide_grFlush,                  "grFlush" },
	{ "\011grLfbLock",                kGlide_grLfbLock,                "grLfbLock" },
	{ "\013grLfbUnlock",              kGlide_grLfbUnlock,              "grLfbUnlock" },
	{ "\017grLfbReadRegion",          kGlide_grLfbReadRegion,          "grLfbReadRegion" },
	{ "\020grLfbWriteRegion",         kGlide_grLfbWriteRegion,         "grLfbWriteRegion" },
	/* "guGammaCorrectionRGB" is 20 chars; was wrongly \023 (19) - MISMATCH
	 * meant FindLibSymbol never resolved it and stock PEF could spin on HW. */
	{ "\024guGammaCorrectionRGB",     kGlide_guGammaCorrectionRGB,     "guGammaCorrectionRGB" },
	/* Extra wait/status aliases - grSstBusy is 9 chars; was wrongly \014 (12). */
	{ "\011grSstBusy",                kGlide_grSstIsBusy,              "grSstBusy" },
};
static const int num_glide_symbols =
	(int)(sizeof(glide_symbols) / sizeof(glide_symbols[0]));

/* Guest CFM fragment name candidates (Pascal). D2 PEF-imports 3DfxGlideLib3.x. */
static const char *const kGlideLibCandidates[] = {
	"\0173DfxGlideLib3.x",   /* 15 - D2 import / real cfrg name */
	"\0203dfx GlideLib3.x",  /* 16 - file name with space */
	"\007Glide3x",
	"\0173DfxGlideLib2.x",
	"\0203dfx GlideLib2.x",
	"\0153DfxGlideLib3",
	"\014Glide Library",
};
static const int kGlideLibCandidateCount =
	(int)(sizeof(kGlideLibCandidates) / sizeof(kGlideLibCandidates[0]));

/*
 * Same mechanics as dsp_install_patch_one:
 *   overwrite first 4 PPC instructions at the export's code with a branch
 *   into our native thunk. CFM callers load code from the TVECT; some paths
 *   also cache/use the code pointer. TVECT-only rewrite produced zero runtime
 *   GlideDispatch (D2 still ran stock entry points) - code smash is required.
 *
 * Also rewrite TVECT[0] so any TVECT that still pointed at the old entry is
 * consistent if something reloads it.
 */
static int glide_install_patch_one(uint32_t orig_tvect, uint32_t hook_tvect, const char *name)
{
	if (hook_tvect == 0) {
		QD3D_INIT_LOG("Glide: hook TVECT for %s not allocated", name);
		return 0;
	}
	if (orig_tvect == 0) {
		QD3D_INIT_LOG("Glide: null guest TVECT for %s", name);
		return 0;
	}

	uint32_t orig_code = ReadMacInt32(orig_tvect);
	uint32_t hook_code = ReadMacInt32(hook_tvect);
	if (hook_code == 0) {
		QD3D_INIT_LOG("Glide: hook code for %s is zero", name);
		return 0;
	}
	if (orig_code == 0) {
		QD3D_INIT_LOG("Glide: orig_code for %s is zero (tvect=0x%08x)", name, orig_tvect);
		return 0;
	}

	/* Already fully redirected? */
	if (orig_code == hook_code)
		return 1;

	/* 1) TVECT code pointer -> our thunk */
	WriteMacInt32(orig_tvect + 0, hook_code);

	/* 2) DSp-style: branch at original entry so any direct code call hits us */
	const uint32_t r11 = 11;
	uint32_t hook_hi = (hook_code >> 16) & 0xFFFF;
	uint32_t hook_lo = hook_code & 0xFFFF;

	WriteMacInt32(orig_code + 0,  0x3C000000 | (r11 << 21) | hook_hi);
	WriteMacInt32(orig_code + 4,  0x60000000 | (r11 << 21) | (r11 << 16) | hook_lo);
	WriteMacInt32(orig_code + 8,  0x7C0903A6 | (r11 << 21)); /* mtctr r11 */
	WriteMacInt32(orig_code + 12, 0x4E800420);               /* bctr */

#if EMULATED_PPC
	FlushCodeCache(orig_code, orig_code + 16);
#endif

	QD3D_INIT_LOG("Glide: patched %s: tvect=0x%08x orig_code=0x%08x -> hook=0x%08x",
				  name, orig_tvect, orig_code, hook_code);
	return 1;
}

void GlideInstallHooks(void)
{
	if (!PrefsFindBool("glideaccel")) return;
	if (glide_hooks_installed) return;
	if (glide_hooks_attempts >= GLIDE_HOOKS_MAX_ATTEMPTS) return;
	if (glide_hooks_in_progress) {
		QD3D_INIT_LOG("GlideInstallHooks: skipped (re-entrant)");
		return;
	}
	glide_hooks_in_progress = true;

	if (!glide_thunks_ready) {
		GlideThunksInit();
		glide_thunks_ready = true;
	}

	const int attempt_number = glide_hooks_attempts + 1;
	QD3D_INIT_LOG("GlideInstallHooks: installing FindLibSymbol hooks for Glide "
				  "(ATTEMPT %d / %d)",
				  attempt_number, GLIDE_HOOKS_MAX_ATTEMPTS);

	/* ---- Pick library name from known candidates (DSp pattern) ---- */
	const char *glide_lib = NULL;
	uint32_t probe_tvect = 0;
	for (int c = 0; c < kGlideLibCandidateCount; c++) {
		const char *candidate = kGlideLibCandidates[c];
		QD3D_INIT_LOG("GlideInstallHooks: trying library \"%s\" (%d chars)",
					  candidate + 1, (int)(unsigned char)candidate[0]);
		probe_tvect = FindLibSymbol(candidate, glide_symbols[0].pascal_sym);
		if (probe_tvect != 0) {
			glide_lib = candidate;
			QD3D_INIT_LOG("GlideInstallHooks: found library \"%s\" "
						  "(probe TVECT for %s = 0x%08x)",
						  glide_lib + 1, glide_symbols[0].name, probe_tvect);
			break;
		}
	}

	if (glide_lib == NULL) {
		QD3D_INIT_LOG("GlideInstallHooks: no Glide library candidate resolved "
					  "on this attempt (guest extension present?)");
	}

	struct CachedTVECT {
		uint32_t tvect;
		int sub_opcode;
		const char *name;
	};
	std::vector<CachedTVECT> cached_tvects;
	int found_count = 0;
	int not_found_count = 0;

	/* ---- Pass 1: resolve all (no WriteMacInt32 yet) ---- */
	if (glide_lib != NULL) {
		QD3D_INIT_LOG("GlideInstallHooks: unresolved-symbol-diagnostic begin - "
					  "ATTEMPT %d / %d (candidate lib = \"%s\")",
					  attempt_number, GLIDE_HOOKS_MAX_ATTEMPTS, glide_lib + 1);
		int length_mismatches = 0;
		for (int i = 0; i < num_glide_symbols; i++) {
			const char *psym = glide_symbols[i].pascal_sym;
			int pascal_len = (unsigned char)psym[0];
			int ascii_len = (int)strlen(psym + 1);
			int name_len = (int)strlen(glide_symbols[i].name);
			bool length_match = (pascal_len == ascii_len) && (ascii_len == name_len);
			if (!length_match) length_mismatches++;

			uint32_t tvect = FindLibSymbol(glide_lib, psym);
			/* If table length byte was wrong, rebuild a correct Pascal name from
			 * the C name and retry - wrong length = silent miss + stock HW spin. */
			char fixed_psym[64];
			if (tvect == 0 && name_len > 0 && name_len < 63) {
				fixed_psym[0] = (char)name_len;
				memcpy(fixed_psym + 1, glide_symbols[i].name, (size_t)name_len);
				fixed_psym[1 + name_len] = 0;
				if (!length_match || memcmp(psym + 1, glide_symbols[i].name, (size_t)name_len) != 0)
					tvect = FindLibSymbol(glide_lib, fixed_psym);
			}
			QD3D_INIT_LOG("[diagnostic] %-32s pascal_len=%d strlen(ascii)=%d "
						  "strlen(name)=%d match=%s FindLibSymbol=0x%08x",
						  glide_symbols[i].name, pascal_len, ascii_len, name_len,
						  length_match ? "OK" : "MISMATCH", tvect);

			if (tvect != 0) {
				cached_tvects.push_back({ tvect, glide_symbols[i].sub_opcode,
										  glide_symbols[i].name });
				found_count++;
			} else {
				not_found_count++;
			}
		}
		QD3D_INIT_LOG("GlideInstallHooks: unresolved-symbol-diagnostic end - "
					  "ATTEMPT %d / %d (%d / %d resolved; %d length mismatches; "
					  "%d not found)",
					  attempt_number, GLIDE_HOOKS_MAX_ATTEMPTS,
					  found_count, num_glide_symbols, length_mismatches,
					  not_found_count);
	}

	/* ---- Pass 2: patch all resolved symbols ---- */
	int patched_count = 0;
	for (size_t i = 0; i < cached_tvects.size(); i++) {
		uint32_t hook_tvect = glide_method_tvects[cached_tvects[i].sub_opcode];
		patched_count += glide_install_patch_one(cached_tvects[i].tvect, hook_tvect,
												 cached_tvects[i].name);
	}

	QD3D_INIT_LOG("GlideInstallHooks: ATTEMPT %d / %d - patched %d functions total "
				  "(resolved = %d, table = %d)",
				  attempt_number, GLIDE_HOOKS_MAX_ATTEMPTS,
				  patched_count, found_count, num_glide_symbols);

	glide_hooks_in_progress = false;

	/*
	 * Commit threshold (DSp-style). Our table may list more names than a given
	 * Glide 2/3 PEF exports, so success is "patched everything we resolved"
	 * with a minimum core surface (grGlideInit + friends), not table size.
	 */
	const int kMinCore = 8;
	if (patched_count >= kMinCore && patched_count == found_count) {
		glide_hooks_installed = true;
		QD3D_INIT_LOG("GlideInstallHooks: FULL SUCCESS - %d symbols patched "
					  "on attempt %d (%d table rows not in this PEF)",
					  patched_count, attempt_number, not_found_count);
	} else if (patched_count > 0) {
		glide_hooks_attempts++;
		if (glide_hooks_attempts >= GLIDE_HOOKS_MAX_ATTEMPTS) {
			glide_hooks_installed = true;
			QD3D_INIT_LOG("GlideInstallHooks: FINAL PARTIAL COMMIT after %d attempts - "
						  "%d symbols patched; committing installed=true",
						  glide_hooks_attempts, patched_count);
		} else {
			QD3D_INIT_LOG("GlideInstallHooks: PARTIAL SUCCESS - %d patched "
						  "on attempt %d, will retry",
						  patched_count, attempt_number);
		}
	} else {
		glide_hooks_attempts++;
		if (glide_hooks_attempts >= GLIDE_HOOKS_MAX_ATTEMPTS)
			QD3D_INIT_LOG("GlideInstallHooks: Glide library not available after %d "
						  "attempts, giving up",
						  glide_hooks_attempts);
		else
			QD3D_INIT_LOG("GlideInstallHooks: patched 0, will retry on next accRun "
						  "(attempt %d/%d)",
						  glide_hooks_attempts, GLIDE_HOOKS_MAX_ATTEMPTS);
	}
}

bool GlideInstallHooksSweepComplete(void)
{
	return glide_hooks_installed ||
		   glide_hooks_attempts >= GLIDE_HOOKS_MAX_ATTEMPTS;
}

void GlideResetForReboot(void)
{
	QD3D_INIT_LOG("GlideResetForReboot: hooksInstalled=%d attempts=%d",
				  glide_hooks_installed, glide_hooks_attempts);
	glide_hooks_installed = false;
	glide_hooks_in_progress = false;
	/* Keep attempts at 0 so grGlideInit re-patch is allowed. */
	glide_hooks_attempts = 0;
}

/* Allow grGlideInit to force a re-patch without full reboot bookkeeping. */
void GlideForceReinstallHooks(void)
{
	glide_hooks_installed = false;
	glide_hooks_in_progress = false;
	glide_hooks_attempts = 0;
	GlideInstallHooks();
}

/* ---- Stubs: no synthetic CFM ---- */

uint32_t GlideResolveSyntheticSymbol(const char * /*lib_pascal*/,
									 const char * /*sym_pascal*/)
{
	/* Do not fake FindLibSymbol success - that hid real CFM failures. */
	return 0;
}

uint32_t NativeGlideHookGetSharedLibrary(uint32_t, uint32_t, uint32_t,
										 uint32_t, uint32_t, uint32_t)
{
	return (uint32_t)(int32_t)(-2800);
}

uint32_t NativeGlideHookFindSymbol(uint32_t, uint32_t, uint32_t, uint32_t)
{
	return (uint32_t)(int32_t)(-2804);
}

uint32_t NativeGlideHookCloseConnection(uint32_t)
{
	return 0;
}

uint32_t NativeGlideHookCountSymbols(uint32_t, uint32_t)
{
	return (uint32_t)(int32_t)(-2804);
}

uint32_t NativeGlideHookGetIndSymbol(uint32_t, uint32_t, uint32_t,
									 uint32_t, uint32_t)
{
	return (uint32_t)(int32_t)(-2804);
}
