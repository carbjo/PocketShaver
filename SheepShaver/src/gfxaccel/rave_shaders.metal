/*
 *  rave_shaders.metal - RAVE uber-shader with function constants
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  Uber-shader specialized by Metal function constants: texture, fog,
 *  alpha test and multi-texture per blend mode, with premultiply tied to
 *  the blend mode.
 */

#include <metal_stdlib>
using namespace metal;

// Function constants: texture/fog/alpha/multi-texture state and output alpha convention.
constant bool has_texture       [[function_constant(0)]];
constant bool has_fog           [[function_constant(1)]];
constant bool has_alpha_test    [[function_constant(2)]];
constant bool has_multi_texture [[function_constant(3)]];
constant bool premultiply_output [[function_constant(4)]];

struct VertexIn {
    float4 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
    float4 texcoord [[attribute(2)]];  // (uOverW, vOverW, invW, 0) for textured; (0,0,0,0) for Gouraud
    float4 diffuse  [[attribute(3)]];
    float4 specular [[attribute(4)]];
};

struct VertexOut {
    float4 position [[position]];
    float  pointSize [[point_size]];
    float4 color;
    float4 texcoord;  // pass all 4 for perspective-correct interpolation
    float4 texcoord2; // second UV pair for multi-texture (uOverW2, vOverW2, invW2, 0)
    float4 diffuse;
    float4 specular;
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
    float mipmap_bias;          // LOD bias for texture sampling
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
    // Metal validates all declared interpolants, including UVs unused by a
    // specialized fragment function. Keep disabled texture channels finite.
    VertexOut out = {};
    // RAVE gives screen-space pixel coords; convert to NDC [-1, 1].
    out.position.x = (in.position.x / viewport.width) * 2.0 - 1.0;
    out.position.y = 1.0 - (in.position.y / viewport.height) * 2.0;  // Y flipped
    out.position.z = in.position.z;  // depth [0..1]
    out.position.w = in.position.w;  // always 1.0 from the vertex converters
    out.pointSize = vertUniforms.point_width;
    out.color = in.color;
    out.diffuse = in.diffuse;
    out.specular = in.specular;
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
        // V is already flipped to Metal convention in ConvertTextureVertex.

        float4 texPix = tex.sample(samp, uv, bias(uniforms.mipmap_bias));
        // Opaque-texture guard (bit30: bound texture has no transparent texels at
        // level 0). Force opaque so mip/filter alpha cannot let the overlay clear
        // show through; vertex alpha and blend mode still give real translucency.
        if (uniforms.texture_op & 0x40000000) {
            texPix.a = 1.0;
        }
        bool sampledTransparentTexel = texPix.a <= 0.0;

        // RAVE/GL texture-env alpha: Decal takes the vertex alpha; all other ops
        // modulate texture alpha by vertex alpha.
        if (uniforms.texture_op & 4) {  // Decal
            texPix.rgb = texPix.a * texPix.rgb + (1.0 - texPix.a) * color.rgb;
            texPix.a = in.color.a;
        } else if (uniforms.texture_op & 16) {  // Blend (bit 4): GL_TEXTURE_ENV_MODE GL_BLEND
            // GL_BLEND: retain the fragment at texture=0, use env color at texture=1.
            float3 envColor = float3(uniforms.env_color_r, uniforms.env_color_g, uniforms.env_color_b);
            texPix.rgb = (1.0 - texPix.rgb) * color.rgb + texPix.rgb * envColor;
            texPix.a *= in.color.a;
        } else {
            texPix.a *= in.color.a;
        }

        // Fully transparent samples must not write depth; Bugdom draws large
        // cutout texture quads with normal Z enabled.
        if (sampledTransparentTexel && !(uniforms.texture_op & 4)) {
            discard_fragment();
        }

        if (uniforms.texture_op & 1) {  // Modulate: multiply by kd_rgb
            texPix.rgb = saturate(texPix.rgb * in.diffuse.rgb);
        }

        if (uniforms.texture_op & 2) {  // Highlight: add ks_rgb
            texPix.rgb = saturate(texPix.rgb + in.specular.rgb);
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
        // V-axis: flipped at vertex conversion time, same as primary UV.
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

    // Alpha test before fog, per RAVE spec
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

    // Fog applies to fragments that survived the alpha test (modes per RAVE.h):
    //   None(0); Alpha(1): factor = vertex alpha, then alpha = 1;
    //   Linear(2): z = 1/invW, fog = (end - z) / (end - start);
    //   Exponential(3): fog = exp(-density * z);
    //   ExponentialSquared(4): fog = exp(-(density * z)^2).
    if (has_fog) {
        float fog_factor = 1.0;
        if (uniforms.fog_mode == 1) {
            // Vertex alpha is the fog factor
            fog_factor = in.color.a;
        } else if (uniforms.fog_mode == 2) {
            // Use perspective depth: submitted z is post-projection and over-fogs QD3D menu billboards.
            float z = (in.texcoord.z > 0.0) ? (1.0 / in.texcoord.z) : (in.position.z * uniforms.fog_max_depth);
            fog_factor = clamp((uniforms.fog_end - z) / (uniforms.fog_end - uniforms.fog_start), 0.0, 1.0);
        } else if (uniforms.fog_mode == 3) {
            float z = (in.texcoord.z > 0.0) ? (1.0 / in.texcoord.z) : (in.position.z * uniforms.fog_max_depth);
            fog_factor = clamp(exp(-uniforms.fog_density * z), 0.0, 1.0);
        } else if (uniforms.fog_mode == 4) {
            float z = (in.texcoord.z > 0.0) ? (1.0 / in.texcoord.z) : (in.position.z * uniforms.fog_max_depth);
            float dz = uniforms.fog_density * z;
            fog_factor = clamp(exp(-dz * dz), 0.0, 1.0);
        }
        float3 fog_color = float3(uniforms.fog_color_r, uniforms.fog_color_g, uniforms.fog_color_b);
        color.rgb = mix(fog_color, color.rgb, fog_factor);
        if (uniforms.fog_mode == 1) {
            color.a = 1.0;  // FogMode_Alpha disables vertex alpha blending per spec
        }
    }

    if (premultiply_output) {
        color.rgb *= color.a;
    }

    return color;
}
