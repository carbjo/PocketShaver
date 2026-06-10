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
 *  Vertex shader generates a fullscreen triangle from vertex_id (no vertex
 *  buffer needed). Fragment shader samples the 32-bit BGRA framebuffer texture.
 *  The oversized triangle is clipped by the CAMetalLayer viewport, so only
 *  the visible region is rasterized.
 */

#include <metal_stdlib>
using namespace metal;

struct CompositorVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

/*
 *  Fullscreen triangle trick: three vertices cover the entire clip space.
 *  Positions: (-1,-1), (3,-1), (-1,3)  — triangle covers [-1,1]x[-1,1]
 *
 *  UV mapping: Metal's texture origin is top-left (0,0).
 *  Clip-space (-1,-1) is bottom-left, so we flip Y:
 *    vertex 0: pos(-1,-1) → UV(0,1)   bottom-left
 *    vertex 1: pos( 3,-1) → UV(2,1)   bottom-right (overscanned)
 *    vertex 2: pos(-1, 3) → UV(0,-1)  top-left (overscanned)
 */
vertex CompositorVertexOut compositor_vertex(uint vid [[vertex_id]])
{
    CompositorVertexOut out;

    // Generate clip-space position from vertex_id
    float2 pos;
    pos.x = (vid == 1) ? 3.0 : -1.0;
    pos.y = (vid == 2) ? 3.0 : -1.0;
    out.position = float4(pos, 0.0, 1.0);

    // Map clip-space to UV with Y-flip for top-left origin
    out.texCoord.x = (pos.x + 1.0) * 0.5;
    out.texCoord.y = (1.0 - pos.y) * 0.5;

    return out;
}

/*
 *  Sample the 32-bit framebuffer texture.
 *
 *  On iOS (non-VOSF, little-endian arm64), the PPC interpreter writes
 *  32-bit ARGB pixels in big-endian byte order via do_put_mem_long():
 *    b[0]=A, b[1]=R, b[2]=G, b[3]=B  →  memory bytes [A][R][G][B]
 *
 *  Metal's BGRA8Unorm reads bytes as [B][G][R][A], so it maps our bytes:
 *    .b = byte0 = A(actual)
 *    .g = byte1 = R(actual)
 *    .r = byte2 = G(actual)
 *    .a = byte3 = B(actual)
 *
 *  Swizzle to recover correct (R, G, B) and force alpha to 1.0 (classic
 *  Mac OS framebuffers store 0x00 in the alpha byte for opaque pixels).
 */
fragment float4 compositor_fragment_32bpp(CompositorVertexOut in [[stage_in]],
                                          texture2d<float> tex [[texture(0)]],
                                          sampler samp [[sampler(0)]],
                                          constant uchar *gamma_lut [[buffer(0)]],
                                          constant uint &fade_active [[buffer(1)]])
{
    float4 s = tex.sample(samp, in.texCoord);
    // Recover (R, G, B) from the big-endian swizzle.
    float3 c = float3(s.g, s.r, s.a);

    // Apply the planar gamma LUT (first 256 = R, next 256 = G, last
    // 256 = B) so a DSp FadeGamma is VISIBLE at 32bpp (the depth DSp games are
    // force-resized to). Indices are round([0,1]*255) ∈ [0,255], so the planar
    // offsets land in [0,767] by construction — no OOB read (trusted buffer).
    uint3 idx = uint3(round(c * 255.0));
    float r = float(gamma_lut[idx.r])         / 255.0;
    float g = float(gamma_lut[256u + idx.g])  / 255.0;
    float b = float(gamma_lut[512u + idx.b])  / 255.0;

    // Apply the Classic-Mac 1.8 -> 2.2 correction at direct
    // color too for cross-depth consistency when NOT fading; bypass during a
    // fade so the LUT marches linearly (DSp-1.7).
    if (fade_active == 0u) {
        r = pow(r, 1.8 / 2.2);
        g = pow(g, 1.8 / 2.2);
        b = pow(b, 1.8 / 2.2);
    }

    return float4(r, g, b, 1.0);
}

/*
 *  Indexed color fragment shader for 1/2/4/8-bit Mac depths.
 *
 *  The framebuffer texture is R8Uint — one byte per texel. For sub-8-bit
 *  depths, multiple pixels are packed into each byte (MSB = leftmost pixel).
 *  The shader unpacks the pixel index from the byte using bits_per_pixel,
 *  then looks up the color in the 256-entry RGBA palette buffer.
 *
 *  Integer textures require tex.read(uint2) — tex.sample() is not
 *  available for MTLPixelFormatR8Uint.
 */
fragment float4 compositor_fragment_indexed(CompositorVertexOut in [[stage_in]],
                                            texture2d<uint, access::read> tex [[texture(0)]],
                                            constant uchar4 *palette [[buffer(0)]],
                                            constant uint &bits_per_pixel [[buffer(1)]],
                                            constant uchar *gamma_lut [[buffer(2)]],
                                            constant uint &pixel_width [[buffer(3)]],
                                            constant uint &fade_active [[buffer(4)]])
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

    // Apply gamma LUT (planar: first 256 = R, next 256 = G, last 256 = B)
    float r = float(gamma_lut[color.r]) / 255.0;
    float g = float(gamma_lut[256 + color.g]) / 255.0;
    float b = float(gamma_lut[512 + color.b]) / 255.0;

    // Apply Classic Mac 1.8 -> sRGB 2.2 gamma correction.
    // Classic Mac apps authored palettes for 1.8 gamma CRT; modern iOS is 2.2.
    // During a fade the LUT already encodes the DSp-1.7 linear ramp;
    // bypass the static 1.8->2.2 correction so the fade marches linearly in
    // display space (composing the static pow over a fading LUT warps the ramp).
    if (fade_active == 0u) {
        r = pow(r, 1.8 / 2.2);
        g = pow(g, 1.8 / 2.2);
        b = pow(b, 1.8 / 2.2);
    }

    return float4(r, g, b, 1.0);
}

/*
 *  16-bit fragment shader for big-endian xRGB1555 Mac depth.
 *
 *  The framebuffer texture is R16Uint — one 16-bit value per texel.
 *  Mac stores 16-bit pixels as big-endian xRGB1555, but the ARM64
 *  GPU reads them as little-endian, so we byte-swap before extracting
 *  the 5-bit RGB channels.
 *
 *  Integer textures require tex.read(uint2) — tex.sample() is not
 *  available for MTLPixelFormatR16Uint.
 */
fragment float4 compositor_fragment_16bpp(CompositorVertexOut in [[stage_in]],
                                          texture2d<uint, access::read> tex [[texture(0)]],
                                          constant uchar *gamma_lut [[buffer(0)]],
                                          constant uint &fade_active [[buffer(1)]])
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

    // Scale each 5-bit channel (0..31) to the 8-bit LUT index range
    // (0..255), then apply the planar gamma LUT so a DSp FadeGamma is visible
    // at 16bpp too. (255*31)/31 = 255, so indices land in [0,255] -> [0,767].
    uint idx_r = (R * 255u) / 31u;
    uint idx_g = (G * 255u) / 31u;
    uint idx_b = (B * 255u) / 31u;
    float r = float(gamma_lut[idx_r])         / 255.0;
    float g = float(gamma_lut[256u + idx_g])  / 255.0;
    float b = float(gamma_lut[512u + idx_b])  / 255.0;

    // Static 1.8 -> 2.2 correction when NOT fading; bypass
    // during a fade so the LUT marches linearly (DSp-1.7).
    if (fade_active == 0u) {
        r = pow(r, 1.8 / 2.2);
        g = pow(g, 1.8 / 2.2);
        b = pow(b, 1.8 / 2.2);
    }

    return float4(r, g, b, 1.0);
}

/*
 *  Compositing fragment shader for alpha-blending 3D overlay over 2D desktop.
 *
 *  Samples the offscreen BGRA8Unorm overlay texture and returns the color
 *  with its original alpha. The render pipeline enables alpha blending
 *  (src=one, dst=oneMinusSourceAlpha) so:
 *    - Where RAVE/GL rendered content: alpha=1.0 → overlay is opaque
 *    - Where nothing rendered: RGBA=(0,0,0,0) → 2D desktop shows through
 *
 *  The 2D framebuffer is already in the drawable from the first draw call;
 *  this second draw call blends the 3D content on top.
 */
fragment float4 compositor_fragment_composite(CompositorVertexOut in [[stage_in]],
                                              texture2d<float> overlay_tex [[texture(0)]],
                                              sampler samp [[sampler(0)]],
                                              constant float *uv_scale [[buffer(0)]])
{
    // Scale UVs to sample only the viewport portion of the overlay texture.
    float2 uv = in.texCoord * float2(uv_scale[0], uv_scale[1]);
    return overlay_tex.sample(samp, uv);
}

/* ========================================================================
 *  SubmitFrame pipeline shaders
 *
 *  Vertex + fragment siblings used by MetalCompositorSubmitFrame to encode
 *  CompositeLayer entries into the drawable (or, in TESTING_BUILD, into
 *  an offscreen target via MetalCompositorTesting_SetNextRenderTarget).
 *
 *  Simplification: each layer emits a fullscreen triangle
 *  with the source texture sampled across its full bounds. Per-rect
 *  clipping (dst_origin/dst_size) is deferred; for z-order verification
 *  the fullscreen emission is sufficient (each layer occupies the full
 *  screen in its blend mode, slot order determines final visible).
 *
 *  The three blend modes (Opaque / Premultiplied / Straight) share this
 *  shader pair; the pipeline object differs only in its color-attachment
 *  blend state (built at MetalCompositorInit time in s_pipe_for_blend[]).
 * ======================================================================== */

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

vertex SubmitFrameVOut submitframe_vertex(uint vid [[vertex_id]],
                                         constant SubmitFrameUniform &u [[buffer(0)]])
{
    /* Fullscreen triangle covering the viewport. UVs flipped so texture
     * origin at top-left maps correctly (matches compositor_vertex). */
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
    float4 c = tex.sample(samp, in.uv);
    /* Apply per-layer alpha for non-Opaque blend modes. kBlendOpaque
     * pipelines disable blending entirely so the alpha multiplier is
     * ignored even though we compute it. */
    c.a *= u.alpha;
    return c;
}
