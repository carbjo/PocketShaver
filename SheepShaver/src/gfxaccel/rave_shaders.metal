/*
 *  rave_shaders.metal - RAVE uber-shader with function constants
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  Uber-shader using Metal function constants for compile-time
 *  specialization. 16 pipeline state variants are pre-built from
 *  combinations of texture/fog/alpha_test/multi_texture boolean constants.
 */

#include <metal_stdlib>
using namespace metal;

// Function constants for pipeline specialization
// 2 x 2 x 2 x 2 = 16 pipeline state combinations
constant bool has_texture       [[function_constant(0)]];
constant bool has_fog           [[function_constant(1)]];
constant bool has_alpha_test    [[function_constant(2)]];
constant bool has_multi_texture [[function_constant(3)]];

struct VertexIn {
    float4 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
    float4 texcoord [[attribute(2)]];  // (uOverW, vOverW, invW, 0) for textured; (0,0,0,0) for Gouraud
};

struct VertexOut {
    float4 position [[position]];
    float  pointSize [[point_size]];
    float4 color;
    float4 texcoord;  // pass all 4 for perspective-correct interpolation
    float4 texcoord2; // second UV pair for multi-texture (uOverW2, vOverW2, invW2, 0)
};

struct Viewport {
    float width;
    float height;
    float znear;
    float zfar;
};

struct VertexUniforms {
    float point_width;  // from kQATag_Width (state[5])
};

struct FragmentUniforms {
    int texture_op;       // bitmask of TextureOp flags
    int fog_mode;         // 0=none, 1=alpha, 2=linear, 3=exp, 4=exp2
    float fog_color_a;
    float fog_color_r;
    float fog_color_g;
    float fog_color_b;
    float fog_start;
    float fog_end;
    float fog_density;
    float fog_max_depth;
    int alpha_test_func;  // 0-7
    float alpha_test_ref; // [0.0, 1.0]
    uint multi_texture_op;    // 0=Add, 1=Modulate, 2=BlendAlpha, 3=Fixed
    float multi_texture_factor; // blend factor for Fixed mode
    float mipmap_bias;          // LOD bias for texture sampling (BIA-01)
    float multi_texture_mipmap_bias;  // LOD bias for second texture (tag 42)
    float env_color_r;    // kQATextureOp_Blend env color (GL_TEXTURE_ENV_COLOR)
    float env_color_g;
    float env_color_b;
    float env_color_a;
};

vertex VertexOut rave_vertex(VertexIn in [[stage_in]],
                              constant Viewport &viewport [[buffer(1)]],
                              constant VertexUniforms &vertUniforms [[buffer(2)]],
                              constant float4 *multiTexUVs [[buffer(3), function_constant(has_multi_texture)]],
                              uint vid [[vertex_id]]) {
    VertexOut out;
    // RAVE provides pre-transformed screen-space coordinates.
    // Convert pixel coords to Metal NDC [-1, 1]:
    out.position.x = (in.position.x / viewport.width) * 2.0 - 1.0;
    out.position.y = 1.0 - (in.position.y / viewport.height) * 2.0;  // Y flipped
    out.position.z = in.position.z;  // depth [0..1]
    out.position.w = in.position.w;  // always 1.0 for now
    out.pointSize = vertUniforms.point_width;
    out.color = in.color;
    if (has_texture || has_fog) {
        out.texcoord = in.texcoord;  // pass through all 4 components (fog needs texcoord.z = invW)
    }
    if (has_multi_texture) {
        // UV2 comes from a separate buffer at index 3 (uOverW2, vOverW2, invW2, 0)
        out.texcoord2 = multiTexUVs[vid];
    }
    return out;
}

fragment float4 rave_fragment(VertexOut in [[stage_in]],
                              constant FragmentUniforms &uniforms [[buffer(0)]],
                              texture2d<float> tex [[texture(0), function_constant(has_texture)]],
                              sampler samp [[sampler(0), function_constant(has_texture)]],
                              texture2d<float> tex2 [[texture(1), function_constant(has_multi_texture)]],
                              sampler samp2 [[sampler(1), function_constant(has_multi_texture)]]) {
    float4 color = in.color;
    if (has_texture) {
        // Perspective-correct UV reconstruction
        float2 uv;
        if (in.texcoord.z > 0.0) {
            uv = float2(in.texcoord.x / in.texcoord.z,   // uOverW / invW = u
                         in.texcoord.y / in.texcoord.z);   // vOverW / invW = v
        } else {
            uv = float2(0.0, 0.0);
        }
        // V-axis: QD3D uses V=0 at top, V=1 at bottom (standard 2D convention).
        // After QD3D IR transforms, V is always in [0,1]. Nanosaur uses QD3D
        // exclusively — no direct RAVE callers send negative V.
        // Previously abs() was applied to uv.y as a heuristic to handle hypothetical
        // negative-V RAVE callers, but this folds UV space (coords -0.3 and +0.3
        // map to the same texel), producing garbled output. Removed in favor of
        // using V directly, which is correct for all QD3D-sourced geometry.

        float4 texPix = tex.sample(samp, uv, bias(uniforms.mipmap_bias));

        // TextureOp processing per RAVE spec
        // Per RAVE spec, Decal takes precedence over Modulate when both bits set
        if (uniforms.texture_op & 4) {  // Decal
            texPix.rgb = texPix.a * texPix.rgb + (1.0 - texPix.a) * color.rgb;
            texPix.a = color.a;
        } else if (uniforms.texture_op & 16) {  // Blend (bit 4): GL_TEXTURE_ENV_MODE GL_BLEND
            // Per GL spec: Cv = (1-Cs)*Cc + Cs*Cv where Cs=texture, Cc=env_color
            float3 envColor = float3(uniforms.env_color_r, uniforms.env_color_g, uniforms.env_color_b);
            texPix.rgb = (1.0 - texPix.rgb) * envColor + texPix.rgb * color.rgb;
            texPix.a *= color.a;
        } else if (uniforms.texture_op & 1) {  // Modulate: color.rgb carries kd_rgb (only if Decal/Blend not set)
            texPix.rgb = saturate(texPix.rgb * color.rgb);
            texPix.a *= color.a;
        } else {
            texPix.a *= color.a;
        }

        if (uniforms.texture_op & 2) {  // Highlight: color.rgb carries ks_rgb (additive)
            texPix.rgb = saturate(texPix.rgb + color.rgb);
        }

        color = texPix;
    }

    // Multi-texture compositing: sample second texture and composite
    if (has_multi_texture) {
        float2 uv2;
        if (in.texcoord2.z > 0.0) {
            uv2 = float2(in.texcoord2.x / in.texcoord2.z,   // uOverW2 / invW2
                          in.texcoord2.y / in.texcoord2.z);   // vOverW2 / invW2
        } else {
            uv2 = float2(0.0, 0.0);
        }
        // V-axis: same reasoning as primary UV — V is always non-negative
        // from QD3D IR. abs() removed to avoid UV space folding.
        float4 tex2Color = tex2.sample(samp2, uv2, bias(uniforms.multi_texture_mipmap_bias));
        if (uniforms.multi_texture_op == 0)       // Add
            color.rgb = saturate(color.rgb + tex2Color.rgb);
        else if (uniforms.multi_texture_op == 1)   // Modulate
            color.rgb *= tex2Color.rgb;
        else if (uniforms.multi_texture_op == 2)   // BlendAlpha
            color.rgb = mix(color.rgb, tex2Color.rgb, tex2Color.a);
        else if (uniforms.multi_texture_op == 3)   // Fixed
            color.rgb = mix(color.rgb, tex2Color.rgb, uniforms.multi_texture_factor);
    }

    // Alpha test FIRST per RAVE spec (discard before fog)
    if (has_alpha_test) {
        bool pass = true;
        int func = uniforms.alpha_test_func;
        float ref = uniforms.alpha_test_ref;
        if (func == 1) {        // LT
            pass = (color.a < ref);
        } else if (func == 2) { // EQ
            pass = (color.a == ref);
        } else if (func == 3) { // LE
            pass = (color.a <= ref);
        } else if (func == 4) { // GT
            pass = (color.a > ref);
        } else if (func == 5) { // NE
            pass = (color.a != ref);
        } else if (func == 6) { // GE
            pass = (color.a >= ref);
        }
        // func==0 (None) and func==7 (True) always pass
        if (!pass) {
            discard_fragment();
        }
    }

    // Fog SECOND (applied only to surviving fragments)
    if (has_fog) {
        float fog_factor = 1.0;
        if (uniforms.fog_mode == 1) {
            // Alpha-based fog: vertex alpha IS the fog interpolation factor
            fog_factor = color.a;
        } else if (uniforms.fog_mode == 2) {
            // Linear fog -- use invW-based depth when available
            float z = (in.texcoord.z > 0.0) ? (1.0 / in.texcoord.z) : (in.position.z * uniforms.fog_max_depth);
            fog_factor = clamp((uniforms.fog_end - z) / (uniforms.fog_end - uniforms.fog_start), 0.0, 1.0);
        } else if (uniforms.fog_mode == 3) {
            // Exponential fog -- use invW-based depth when available
            float z = (in.texcoord.z > 0.0) ? (1.0 / in.texcoord.z) : (in.position.z * uniforms.fog_max_depth);
            fog_factor = clamp(exp(-uniforms.fog_density * z), 0.0, 1.0);
        } else if (uniforms.fog_mode == 4) {
            // Exponential squared fog -- use invW-based depth when available
            float z = (in.texcoord.z > 0.0) ? (1.0 / in.texcoord.z) : (in.position.z * uniforms.fog_max_depth);
            float dz = uniforms.fog_density * z;
            fog_factor = clamp(exp(-dz * dz), 0.0, 1.0);
        }
        float3 fog_color = float3(uniforms.fog_color_r, uniforms.fog_color_g, uniforms.fog_color_b);
        color.rgb = mix(fog_color, color.rgb, fog_factor);
        if (uniforms.fog_mode == 1) {
            color.a = 1.0;  // FogMode_Alpha disables vertex alpha blending
        }
    }

    return color;
}
