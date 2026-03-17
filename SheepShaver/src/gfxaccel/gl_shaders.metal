/*
 *  gl_shaders.metal - OpenGL 1.2 FFP uber-shader via uniforms
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  Implements the full OpenGL 1.2 fixed-function pipeline as a pair of
 *  Metal vertex/fragment shaders controlled by uniform buffers:
 *    - MVP + modelview + normal matrix transforms
 *    - Per-vertex Phong lighting for up to 8 lights
 *    - 4 texture environment modes (modulate, decal, blend, replace)
 *    - 3 fog modes (linear, exp, exp2)
 *    - Alpha test with all 8 comparison functions
 *    - Flat/smooth shading support
 */

#include <metal_stdlib>
using namespace metal;


// ---- Vertex input/output ----

struct GLVertexIn {
    float4 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
    float3 normal   [[attribute(2)]];
    float2 texcoord [[attribute(3)]];
};

struct GLVertexOut {
    float4 position     [[position]];
    float4 color;
    float3 eye_normal;
    float2 texcoord;
    float3 eye_position;
    float  fog_factor;
};


// ---- Uniform buffers ----

struct GLVertexUniforms {
    float4x4 mvp_matrix;
    float4x4 modelview_matrix;
    float3x3 normal_matrix;
    int      lighting_enabled;
    int      normalize_enabled;
    int      num_active_lights;
    int      fog_enabled;
    int      fog_mode;          // 0=none, 1=linear, 2=exp, 3=exp2
    float    fog_start;
    float    fog_end;
    float    fog_density;
};

struct GLFragmentUniforms {
    int    texenv_mode;         // 0=modulate, 1=decal, 2=blend, 3=replace
    float4 texenv_color;
    float4 fog_color;
    int    alpha_test_enabled;
    int    alpha_func;          // 0=never,1=less,2=equal,3=lequal,4=greater,5=notequal,6=gequal,7=always
    float  alpha_ref;
    int    has_texture;
    int    shade_model;         // 0=flat, 1=smooth
};

struct GLLight {
    float4 ambient;
    float4 diffuse;
    float4 specular;
    float4 position;            // eye-space (transformed at glLight time)
    float3 spot_direction;
    float  spot_exponent;
    float  spot_cutoff;         // cos(cutoff) for comparison, or -1.0 if 180 degrees
    float  constant_atten;
    float  linear_atten;
    float  quadratic_atten;
    int    enabled;
    float  _pad0;               // padding to align to 16 bytes
    float  _pad1;
    float  _pad2;
};

struct GLMaterialData {
    float4 ambient;
    float4 diffuse;
    float4 specular;
    float4 emission;
    float  shininess;
    float  _pad0;
    float  _pad1;
    float  _pad2;
};

struct GLLightingData {
    GLLight    lights[8];
    GLMaterialData material;
    float4     global_ambient;
};


// ---- Vertex shader ----

vertex GLVertexOut gl_vertex_main(
    GLVertexIn in [[stage_in]],
    constant GLVertexUniforms &uniforms [[buffer(1)]],
    constant GLLightingData &lighting [[buffer(2)]])
{
    GLVertexOut out;

    // 1. Transform position
    out.position = uniforms.mvp_matrix * in.position;

    // Remap depth from GL NDC [-1,+1] to Metal NDC [0,+1].
    // OpenGL's clip-space Z range is [-w, +w], mapping to NDC z in [-1, +1].
    // Metal expects NDC z in [0, +1].  Standard GL viewport transform:
    //   depth = 0.5 * ndc_z + 0.5
    // Applied in clip space (before perspective divide):
    //   out.z = 0.5 * clip.z + 0.5 * clip.w
    out.position.z = out.position.z * 0.5 + out.position.w * 0.5;

    // 2. Eye-space position (for fog distance and lighting)
    float4 eye_pos = uniforms.modelview_matrix * in.position;
    out.eye_position = eye_pos.xyz;

    // 3. Transform and optionally normalize the normal
    float3 eye_normal = uniforms.normal_matrix * in.normal;
    if (uniforms.normalize_enabled) {
        float len = length(eye_normal);
        if (len > 0.0) eye_normal /= len;
    }
    out.eye_normal = eye_normal;

    // 4. Pass through texcoord
    out.texcoord = in.texcoord;

    // 5. Lighting or pass-through color
    if (uniforms.lighting_enabled) {
        // Initialize with emission + global_ambient * material.ambient
        float4 color = lighting.material.emission +
                       lighting.global_ambient * lighting.material.ambient;

        for (int i = 0; i < 8; i++) {
            if (lighting.lights[i].enabled == 0) continue;

            constant GLLight &light = lighting.lights[i];

            // Light direction and attenuation
            float3 L;
            float attenuation = 1.0;
            if (light.position.w == 0.0) {
                // Directional light
                L = normalize(light.position.xyz);
            } else {
                // Positional light
                float3 lightVec = light.position.xyz - eye_pos.xyz;
                float dist = length(lightVec);
                L = lightVec / max(dist, 0.0001);
                attenuation = 1.0 / (light.constant_atten +
                                     light.linear_atten * dist +
                                     light.quadratic_atten * dist * dist);
            }

            // Spotlight effect
            float spotEffect = 1.0;
            if (light.spot_cutoff >= 0.0) {
                // spot_cutoff stores cos(cutoff angle)
                float spotCos = dot(-L, normalize(light.spot_direction));
                if (spotCos < light.spot_cutoff) {
                    spotEffect = 0.0;
                } else {
                    spotEffect = pow(spotCos, light.spot_exponent);
                }
            }

            // Ambient contribution
            float4 ambient_contrib = light.ambient * lighting.material.ambient;

            // Diffuse contribution
            float NdotL = max(dot(eye_normal, L), 0.0);
            float4 diffuse_contrib = NdotL * light.diffuse * lighting.material.diffuse;

            // Specular contribution
            float4 specular_contrib = float4(0.0);
            if (NdotL > 0.0 && lighting.material.shininess > 0.0) {
                float3 V = normalize(-eye_pos.xyz);   // view direction (eye at origin)
                float3 H = normalize(L + V);           // half vector
                float NdotH = max(dot(eye_normal, H), 0.0);
                float spec = pow(NdotH, lighting.material.shininess);
                specular_contrib = spec * light.specular * lighting.material.specular;
            }

            color += attenuation * spotEffect *
                     (ambient_contrib + diffuse_contrib + specular_contrib);
        }

        out.color = clamp(color, 0.0, 1.0);
    } else {
        out.color = in.color;
    }

    // 6. Fog factor computation
    if (uniforms.fog_enabled) {
        float dist = abs(eye_pos.z);
        float fog_factor = 1.0;
        if (uniforms.fog_mode == 1) {
            // Linear
            fog_factor = (uniforms.fog_end - dist) / (uniforms.fog_end - uniforms.fog_start);
        } else if (uniforms.fog_mode == 2) {
            // Exp
            fog_factor = exp(-uniforms.fog_density * dist);
        } else if (uniforms.fog_mode == 3) {
            // Exp2
            float dz = uniforms.fog_density * dist;
            fog_factor = exp(-dz * dz);
        }
        out.fog_factor = clamp(fog_factor, 0.0, 1.0);
    } else {
        out.fog_factor = 1.0;
    }

    return out;
}


// ---- Fragment shader ----

fragment float4 gl_fragment_main(
    GLVertexOut in [[stage_in]],
    constant GLFragmentUniforms &uniforms [[buffer(1)]],
    texture2d<float> tex [[texture(0)]],
    sampler samp [[sampler(0)]])
{
    float4 color = in.color;

    // Texture application
    if (uniforms.has_texture) {
        float4 tex_color = tex.sample(samp, in.texcoord);

        if (uniforms.texenv_mode == 0) {
            // GL_MODULATE: Cf = Ct * Cf
            color = float4(color.rgb * tex_color.rgb, color.a * tex_color.a);
        } else if (uniforms.texenv_mode == 1) {
            // GL_DECAL: Cf.rgb = mix(Cf.rgb, Ct.rgb, Ct.a), Cf.a unchanged
            color.rgb = mix(color.rgb, tex_color.rgb, tex_color.a);
        } else if (uniforms.texenv_mode == 2) {
            // GL_BLEND: Cf.rgb = mix(Cf.rgb, Cc.rgb, Ct.rgb), Cf.a = Cf.a * Ct.a
            color.rgb = mix(color.rgb, uniforms.texenv_color.rgb, tex_color.rgb);
            color.a *= tex_color.a;
        } else if (uniforms.texenv_mode == 3) {
            // GL_REPLACE: Cf = Ct
            color = tex_color;
        } else if (uniforms.texenv_mode == 4) {
            // GL_ADD: Cf.rgb = Cf.rgb + Ct.rgb, Cf.a = Cf.a * Ct.a
            color.rgb = clamp(color.rgb + tex_color.rgb, 0.0, 1.0);
            color.a *= tex_color.a;
        }
    }

    // Fog application
    if (uniforms.fog_color.w > -0.5) {
        // Use fog_color.w as a sentinel: >= 0 means fog is active
        // (We always compute fog_factor in vertex shader, check fog_color validity here)
        color.rgb = mix(uniforms.fog_color.rgb, color.rgb, in.fog_factor);
    }

    // Alpha test
    if (uniforms.alpha_test_enabled) {
        bool pass = true;
        float ref = uniforms.alpha_ref;
        if (uniforms.alpha_func == 0) {         // GL_NEVER
            pass = false;
        } else if (uniforms.alpha_func == 1) {  // GL_LESS
            pass = (color.a < ref);
        } else if (uniforms.alpha_func == 2) {  // GL_EQUAL
            pass = (color.a == ref);
        } else if (uniforms.alpha_func == 3) {  // GL_LEQUAL
            pass = (color.a <= ref);
        } else if (uniforms.alpha_func == 4) {  // GL_GREATER
            pass = (color.a > ref);
        } else if (uniforms.alpha_func == 5) {  // GL_NOTEQUAL
            pass = (color.a != ref);
        } else if (uniforms.alpha_func == 6) {  // GL_GEQUAL
            pass = (color.a >= ref);
        }
        // alpha_func == 7: GL_ALWAYS -> pass = true (default)
        if (!pass) {
            discard_fragment();
        }
    }

    return color;
}
