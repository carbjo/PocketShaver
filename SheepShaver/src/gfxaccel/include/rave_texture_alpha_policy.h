/*
 *  rave_texture_alpha_policy.h - RAVE texture alpha policy helpers.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 */

#ifndef RAVE_TEXTURE_ALPHA_POLICY_H
#define RAVE_TEXTURE_ALPHA_POLICY_H

#include <stdint.h>

#define RAVE_QAPIXEL_ALPHA1       0
#define RAVE_QAPIXEL_RGB16        1
#define RAVE_QAPIXEL_ARGB16       2
#define RAVE_QAPIXEL_RGB32        3
#define RAVE_QAPIXEL_ARGB32       4
#define RAVE_QAPIXEL_CL4          5
#define RAVE_QAPIXEL_CL8          6
#define RAVE_QAPIXEL_RGB16_565    7
#define RAVE_QAPIXEL_RGB24        8
#define RAVE_QAPIXEL_RGB8_332     9
#define RAVE_QAPIXEL_ARGB16_4444 10
#define RAVE_QAPIXEL_ACL16_88    11
#define RAVE_QAPIXEL_I8          12
#define RAVE_QAPIXEL_AI16_88     13
#define RAVE_QAPIXEL_YUVS        14
#define RAVE_QAPIXEL_YUVU        15

#define RAVE_GL_ZERO                      0x0000u
#define RAVE_GL_ONE                       0x0001u
#define RAVE_GL_SRC_COLOR                 0x0300u
#define RAVE_GL_ONE_MINUS_SRC_COLOR       0x0301u
#define RAVE_GL_SRC_ALPHA                 0x0302u
#define RAVE_GL_ONE_MINUS_SRC_ALPHA       0x0303u
#define RAVE_GL_DST_ALPHA                 0x0304u
#define RAVE_GL_ONE_MINUS_DST_ALPHA       0x0305u
#define RAVE_GL_DST_COLOR                 0x0306u
#define RAVE_GL_ONE_MINUS_DST_COLOR       0x0307u
#define RAVE_GL_SRC_ALPHA_SATURATE        0x0308u

#define RAVE_TEXTURE_OP_FORCE_OPAQUE_ALPHA 0x40000000

static inline int RaveTextureDiagUsesOpaqueAlphaGuard(uint32_t diag_alpha_zero)
{
	return diag_alpha_zero == 0;
}

static inline int RaveTextureRgbCoverageIsMostlyBlack(uint32_t rgb_nonzero_pixels,
                                                       uint32_t total_pixels)
{
	if (total_pixels == 0) return 0;
	return rgb_nonzero_pixels <= (total_pixels / 16u);
}

#endif /* RAVE_TEXTURE_ALPHA_POLICY_H */
