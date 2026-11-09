/*
 *  compositor_shaders.metal - Fullscreen compositor shaders for 2D framebuffer
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Compositor shaders: guest framebuffer presentation at each Mac depth, and
 *  the SubmitFrame layer pipeline.
 */

#include <metal_stdlib>
using namespace metal;

struct CompositorVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

static inline float3 apply_display_gamma_lut(float3 c,
                                             constant uchar *gamma_lut)
{
    uint3 idx = uint3(round(saturate(c) * 255.0));
    return float3(float(gamma_lut[idx.r])        / 255.0,
                  float(gamma_lut[256u + idx.g]) / 255.0,
                  float(gamma_lut[512u + idx.b]) / 255.0);
}

/*
 *  Fullscreen triangle from vertex_id, no vertex buffer: (-1,-1), (3,-1),
 *  (-1,3) covers clip space. Y is flipped for Metal's top-left texture origin.
 */
vertex CompositorVertexOut compositor_vertex(uint vid [[vertex_id]])
{
    CompositorVertexOut out;

    float2 pos;
    pos.x = (vid == 1) ? 3.0 : -1.0;
    pos.y = (vid == 2) ? 3.0 : -1.0;
    out.position = float4(pos, 0.0, 1.0);

    out.texCoord.x = (pos.x + 1.0) * 0.5;
    out.texCoord.y = (1.0 - pos.y) * 0.5;

    return out;
}

/*
 *  32 bpp. Guest pixels are big-endian ARGB in memory ([A][R][G][B]), and
 *  BGRA8Unorm reads them as .b=A .g=R .r=G .a=B. Swizzle back and force
 *  alpha to 1 (Mac OS leaves the alpha byte 0 for opaque pixels).
 */
fragment float4 compositor_fragment_32bpp(CompositorVertexOut in [[stage_in]],
                                          texture2d<float> tex [[texture(0)]],
                                          sampler samp [[sampler(0)]],
                                          constant uchar *gamma_lut [[buffer(0)]])
{
    float4 s = tex.sample(samp, in.texCoord);
    float3 c = float3(s.g, s.r, s.a);

    return float4(apply_display_gamma_lut(c, gamma_lut), 1.0);
}

/*
 *  1/2/4/8 bpp indexed. R8Uint texture, one byte per texel; sub-8-bit pixels
 *  are packed MSB-first. Looks up the 256-entry RGBA palette. Integer
 *  textures need tex.read(), not sample().
 */
fragment float4 compositor_fragment_indexed(CompositorVertexOut in [[stage_in]],
                                            texture2d<uint, access::read> tex [[texture(0)]],
                                            constant uchar4 *palette [[buffer(0)]],
                                            constant uint &bits_per_pixel [[buffer(1)]],
                                            constant uchar *gamma_lut [[buffer(2)]],
                                            constant uint &pixel_width [[buffer(3)]])
{
    uint px = uint(in.texCoord.x * float(pixel_width));
    uint py = uint(in.texCoord.y * float(tex.get_height()));

    // Clamp to valid range
    px = min(px, pixel_width - 1);
    py = min(py, tex.get_height() - 1);

    uint index = 0;
    if (bits_per_pixel == 8) {
        index = tex.read(uint2(px, py)).r;
    } else if (bits_per_pixel == 4) {
        uint byte_val = tex.read(uint2(px / 2, py)).r;
        index = (px % 2 == 0) ? (byte_val >> 4) : (byte_val & 0xF);
    } else if (bits_per_pixel == 2) {
        uint byte_val = tex.read(uint2(px / 4, py)).r;
        uint shift = (3 - (px % 4)) * 2;
        index = (byte_val >> shift) & 0x3;
    } else if (bits_per_pixel == 1) {
        uint byte_val = tex.read(uint2(px / 8, py)).r;
        index = (byte_val >> (7 - (px % 8))) & 0x1;
    }

    uchar4 color = palette[index];

    return float4(apply_display_gamma_lut(float3(float(color.r),
                                                float(color.g),
                                                float(color.b)) / 255.0,
                                          gamma_lut),
                  1.0);
}

/*
 *  16 bpp: big-endian xRGB1555 in an R16Uint texture, so byte-swap before
 *  extracting channels. Integer textures need tex.read(), not sample().
 */
fragment float4 compositor_fragment_16bpp(CompositorVertexOut in [[stage_in]],
                                          texture2d<uint, access::read> tex [[texture(0)]],
                                          constant uchar *gamma_lut [[buffer(0)]])
{
    uint px = uint(in.texCoord.x * float(tex.get_width()));
    uint py = uint(in.texCoord.y * float(tex.get_height()));

    // Clamp to valid range
    px = min(px, tex.get_width() - 1);
    py = min(py, tex.get_height() - 1);

    uint packed = tex.read(uint2(px, py)).r;

    // Byte-swap big-endian to little-endian
    packed = ((packed & 0xFF) << 8) | ((packed >> 8) & 0xFF);

    // Extract xRGB1555: x R4-R0 G4-G0 B4-B0
    uint R = (packed >> 10) & 0x1F;
    uint G = (packed >> 5) & 0x1F;
    uint B = packed & 0x1F;

    uint3 idx = uint3((R * 255u) / 31u,
                      (G * 255u) / 31u,
                      (B * 255u) / 31u);
    return float4(float(gamma_lut[idx.r])         / 255.0,
                  float(gamma_lut[256u + idx.g])  / 255.0,
                  float(gamma_lut[512u + idx.b])  / 255.0,
                  1.0);
}

/*
 *  SubmitFrame shaders: each CompositeLayer draws a triangle over its
 *  destination viewport and samples its source rect, clamped to texel
 *  centers so linear filtering can't bleed neighbouring texels. All three
 *  blend modes share these; only the pipeline blend state differs.
 */

struct SubmitFrameVOut {
    float4 position [[position]];
    float2 uv;
};

struct SubmitFrameUniform {
    float2 src_origin;
    float2 src_size;
    float2 dst_origin;
    float2 dst_size;
    float  alpha;
    float  _pad[3];
};

static inline float2 submitframe_source_uv(float2 uv,
                                           constant SubmitFrameUniform &u,
                                           uint width, uint height)
{
    float2 pixel = u.src_origin + uv * u.src_size;
    pixel = clamp(pixel, u.src_origin + 0.5,
                         u.src_origin + max(u.src_size - 0.5, float2(0.5)));
    return pixel / float2(width, height);
}

vertex SubmitFrameVOut submitframe_vertex(uint vid [[vertex_id]],
                                         constant SubmitFrameUniform &u [[buffer(0)]])
{
    /* Same fullscreen triangle as compositor_vertex. */
    float2 pos;
    pos.x = (vid == 1) ? 3.0 : -1.0;
    pos.y = (vid == 2) ? 3.0 : -1.0;

    SubmitFrameVOut out;
    out.position = float4(pos, 0.0, 1.0);
    out.uv.x = (pos.x + 1.0) * 0.5;
    out.uv.y = (1.0 - pos.y) * 0.5;
    return out;
}

fragment float4 submitframe_fragment(SubmitFrameVOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]],
                                    constant SubmitFrameUniform &u [[buffer(0)]])
{
    constexpr sampler samp(filter::linear, address::clamp_to_edge);
    float2 uv = submitframe_source_uv(in.uv, u, tex.get_width(), tex.get_height());
    float4 c = tex.sample(samp, uv);
    /* Per-layer alpha; ignored by Opaque pipelines, which disable blending. */
    c.a *= u.alpha;
    return c;
}

fragment float4 submitframe_fragment_display_premultiplied(SubmitFrameVOut in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]],
                                    constant SubmitFrameUniform &u [[buffer(0)]],
                                    constant uchar *gamma_lut [[buffer(1)]])
{
    constexpr sampler samp(filter::linear, address::clamp_to_edge);
    float2 uv = submitframe_source_uv(in.uv, u, tex.get_width(), tex.get_height());
    float4 c = tex.sample(samp, uv);
    if (c.a > 0.0) {
        float3 straight_rgb = c.rgb / c.a;
        c.rgb = apply_display_gamma_lut(straight_rgb, gamma_lut) * c.a;
    } else {
        c.rgb = float3(0.0);
    }
    c.rgb *= u.alpha;
    c.a *= u.alpha;
    return c;
}
