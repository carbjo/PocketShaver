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
                                          sampler samp [[sampler(0)]])
{
    float4 s = tex.sample(samp, in.texCoord);
    return float4(s.g, s.r, s.a, 1.0);
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
                                            constant uint &pixel_width [[buffer(2)]])
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
    return float4(float(color.r), float(color.g), float(color.b), 255.0) / 255.0;
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
                                          texture2d<uint, access::read> tex [[texture(0)]])
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

    return float4(float(R) / 31.0, float(G) / 31.0, float(B) / 31.0, 1.0);
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
