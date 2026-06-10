/*
 *  gl_synthetic_symbol_policy.h - synthetic OpenGLLibrary CFM symbol policy.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 */

#ifndef GL_SYNTHETIC_SYMBOL_POLICY_H
#define GL_SYNTHETIC_SYMBOL_POLICY_H

#include <stdint.h>

#include "gl_engine.h"

static inline bool GLPascalStringEqualsLiteral(const char *actual,
                                               const char *literal)
{
	if (actual == nullptr || literal == nullptr) return false;
	const uint8_t len = (uint8_t)literal[0];
	if ((uint8_t)actual[0] != len) return false;
	for (uint8_t i = 0; i <= len; i++) {
		if ((uint8_t)actual[i] != (uint8_t)literal[i]) return false;
	}
	return true;
}

static inline bool GLSyntheticFindLibSymbolSubOpcode(const char *lib,
                                                     const char *sym,
                                                     uint16_t *out_sub_opcode)
{
	if (out_sub_opcode != nullptr) *out_sub_opcode = 0;
	if (!GLPascalStringEqualsLiteral(lib, "\015OpenGLLibrary")) return false;

	if (GLPascalStringEqualsLiteral(sym, "\020aglNextPixelFormat")) {
		if (out_sub_opcode != nullptr)
			*out_sub_opcode = (uint16_t)GL_SUB_AGL_NEXTPIXELFORMAT;
		return true;
	}

	return false;
}

#endif /* GL_SYNTHETIC_SYMBOL_POLICY_H */
