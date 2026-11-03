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
    float4 position        [[attribute(0)]];
    float4 color           [[attribute(1)]];
    float3 normal          [[attribute(2)]];
    float3 texcoord        [[attribute(3)]];   // (s, t, q) unit 0 — q enables projective texturing
    float3 texcoord1       [[attribute(4)]];   // (s, t, q) unit 1 — for multitexture
    float4 lighting_position [[attribute(6)]]; // provoking position for flat lighting
    float3 secondary_color [[attribute(5)]];   // (r, g, b) EXT_secondary_color / GL_COLOR_SUM
};

struct GLVertexOut {
    float4 position     [[position]];
    float  point_size   [[point_size]];
    float4 color;
    float4 back_color;
    float3 eye_normal;
    float3 texcoord;    // (s, t, q) unit 0 — interpolated, then divided per-fragment
    float3 texcoord1;   // (s, t, q) unit 1 — for multitexture
    float3 secondary_color; // (r, g, b) EXT_secondary_color / GL_COLOR_SUM — added after texturing
    float3 eye_position;
    float  fog_factor;
    float  clip_dist0;  // user clip plane distances (interpolated, discard if < 0)
    float  clip_dist1;
    float  clip_dist2;
    float  clip_dist3;
    float  clip_dist4;
    float  clip_dist5;
    int    num_clip_planes; // number of active clip planes
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
    float    point_size;         // glPointSize value (default 1.0)
    int      two_side_lighting; // GL_LIGHT_MODEL_TWO_SIDE: negate normal for back-facing vertices
    // User clip planes (GL_CLIP_PLANE0-5). Equation is dot(plane, eye_pos) >= 0.
    int      num_clip_planes;   // number of enabled clip planes (0-6)
    float4   clip_planes[6];    // plane equations in eye space
};

struct GLFragmentUniforms {
    int    texenv_mode;         // 0=modulate, 1=decal, 2=blend, 3=replace
    float4 texenv_color;
    float4 fog_color;
    int    alpha_test_enabled;
    int    alpha_func;          // 0=never,1=less,2=equal,3=lequal,4=greater,5=notequal,6=gequal,7=always
    float  alpha_ref;
    int    has_texture;
    int    has_texture_3d;      // 1 = bound texture is 3D, sample from tex3d at index 1
    int    shade_model;         // 0=flat, 1=smooth
    int    color_sum_enabled;   // GL_COLOR_SUM (EXT_secondary_color): add secondary color after texturing
    int    has_texture_unit1;   // ARB_multitexture: unit 1 has a bound+enabled 2D texture (sample tex1 with texcoord1)
    int    texenv1_mode;        // unit-1 texenv mode (0=modulate,1=decal,2=blend,3=replace,4=add)
    int    force_opaque_output; // window overlay, GL blending disabled: store coverage alpha
    int    tex_format;          // primary base internal format
    int    tex1_format;
    float4 texenv1_color;       // independent unit-1 GL_TEXTURE_ENV_COLOR
    int    has_texture_1d;
    int    has_texture_unit1_1d;
    int    bitmap_mask;
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
    int    color_material;      // GL_COLOR_MATERIAL: 0=off, 1=ambient, 2=diffuse, 3=specular, 4=emission, 5=ambient+diffuse
    float  _pad1;
    float  _pad2;
};

struct GLLightingData {
    GLLight    lights[8];
    GLMaterialData material;
    float4     global_ambient;
    GLMaterialData back_material;
    int        local_viewer;
};


// ---- Vertex shader ----

// Compute both vertex colors before clipping/interpolation. Polygon winding,
// not the direction of an interpolated normal, selects the visible material.
static float4 gl_light_vertex(float4 vertexColor, float3 eyeNormal, float3 eyePosition,
                             constant GLMaterialData &material,
                             constant GLLightingData &lighting)
{
    // GL_COLOR_MATERIAL: the selected material term follows the vertex color.
    float4 mat_ambient  = material.ambient;
    float4 mat_diffuse  = material.diffuse;
    float4 mat_specular = material.specular;
    float4 mat_emission = material.emission;
    int cm = material.color_material;
    if (cm == 1 || cm == 5) mat_ambient  = vertexColor;
    if (cm == 2 || cm == 5) mat_diffuse  = vertexColor;
    if (cm == 3)            mat_specular = vertexColor;
    if (cm == 4)            mat_emission = vertexColor;

    // Initialize with emission + global_ambient * material.ambient
    float4 color = mat_emission + lighting.global_ambient * mat_ambient;

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
            float3 lightVec = light.position.xyz - eyePosition;
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
        float4 ambient_contrib = light.ambient * mat_ambient;

        // Diffuse contribution
        float NdotL = max(dot(eyeNormal, L), 0.0);
        float4 diffuse_contrib = NdotL * light.diffuse * mat_diffuse;

        // Specular contribution
        float4 specular_contrib = float4(0.0);
        if (NdotL > 0.0) {
            float3 V = lighting.local_viewer ? normalize(-eyePosition) : float3(0.0, 0.0, 1.0);
            float3 H = normalize(L + V);           // half vector
            float NdotH = max(dot(eyeNormal, H), 0.0);
            float spec = material.shininess == 0.0 ? 1.0 : pow(NdotH, material.shininess);
            specular_contrib = spec * light.specular * mat_specular;
        }

        color += attenuation * spotEffect *
                 (ambient_contrib + diffuse_contrib + specular_contrib);
    }

    // GL takes lit alpha from the diffuse material alpha alone; summing it
    // across terms saturates to 1 and makes lit translucency opaque.
    color.a = mat_diffuse.a;
    return clamp(color, 0.0, 1.0);
}

vertex GLVertexOut gl_vertex_main(
    GLVertexIn in [[stage_in]],
    constant GLVertexUniforms &uniforms [[buffer(1)]],
    constant GLLightingData &lighting [[buffer(2)]])
{
    GLVertexOut out;

    // 1. Transform position
    out.position = uniforms.mvp_matrix * in.position;

    // Remap depth from GL NDC [-1,+1] to Metal NDC [0,+1].
    out.position.z = out.position.z * 0.5 + out.position.w * 0.5;

    // Point size for GL_POINTS primitives
    out.point_size = uniforms.point_size;

    // 2. Eye-space position (for fog distance and lighting)
    float4 eye_pos = uniforms.modelview_matrix * in.position;
    out.eye_position = eye_pos.xyz;
    float3 lighting_eye_pos = (uniforms.modelview_matrix * in.lighting_position).xyz;

    // 3. Transform and optionally normalize the normal
    float3 eye_normal = uniforms.normal_matrix * in.normal;
    if (uniforms.normalize_enabled) {
        float len = length(eye_normal);
        if (len > 0.0) eye_normal /= len;
    }
    out.eye_normal = eye_normal;

    // 4. Pass through texcoords (s, t, q) for projective texturing
    out.texcoord = in.texcoord;
    out.texcoord1 = in.texcoord1;
    // Pass through the secondary color (added after texturing, gated on GL_COLOR_SUM)
    out.secondary_color = in.secondary_color;

    // 5. Lighting or pass-through color. Points/lines and one-sided polygons
    // receive identical front/back outputs, so fragment facing cannot affect them.
    if (uniforms.lighting_enabled) {
        out.color = gl_light_vertex(in.color, eye_normal, lighting_eye_pos,
                                   lighting.material, lighting);
        out.back_color = uniforms.two_side_lighting
            ? gl_light_vertex(in.color, -eye_normal, lighting_eye_pos,
                              lighting.back_material, lighting)
            : out.color;
    } else {
        out.color = in.color;
        out.back_color = in.color;
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

    // 7. User clip plane distances (dot(plane, eye_pos) for each enabled plane)
    out.num_clip_planes = uniforms.num_clip_planes;
    out.clip_dist0 = (uniforms.num_clip_planes > 0) ? dot(uniforms.clip_planes[0], eye_pos) : 1.0;
    out.clip_dist1 = (uniforms.num_clip_planes > 1) ? dot(uniforms.clip_planes[1], eye_pos) : 1.0;
    out.clip_dist2 = (uniforms.num_clip_planes > 2) ? dot(uniforms.clip_planes[2], eye_pos) : 1.0;
    out.clip_dist3 = (uniforms.num_clip_planes > 3) ? dot(uniforms.clip_planes[3], eye_pos) : 1.0;
    out.clip_dist4 = (uniforms.num_clip_planes > 4) ? dot(uniforms.clip_planes[4], eye_pos) : 1.0;
    out.clip_dist5 = (uniforms.num_clip_planes > 5) ? dot(uniforms.clip_planes[5], eye_pos) : 1.0;

    return out;
}


// The texture's base internal format controls which fragment components each
// environment operation replaces. Storage swizzles alone cannot express these
// rules (for example, an ALPHA texture must leave primary RGB unchanged).
static float4 gl_texture_environment(float4 color, float4 texel, int mode,
                                      float4 environment, int baseFormat)
{
    const bool alphaOnly = baseFormat == 0x1906;
    const bool intensity = baseFormat == 0x8049;
    const bool hasAlpha = alphaOnly || intensity || baseFormat == 0x190a ||
                          baseFormat == 0x1908 || baseFormat == 0;
    if (mode == 0) { // MODULATE
        if (!alphaOnly) color.rgb *= texel.rgb;
        if (hasAlpha) color.a *= texel.a;
    } else if (mode == 1) { // DECAL (defined for RGB and RGBA)
        if (!alphaOnly) color.rgb = hasAlpha ? mix(color.rgb, texel.rgb, texel.a) : texel.rgb;
    } else if (mode == 2) { // BLEND
        if (!alphaOnly) color.rgb = mix(color.rgb, environment.rgb, texel.rgb);
        if (intensity) color.a = mix(color.a, environment.a, texel.a);
        else if (hasAlpha) color.a *= texel.a;
    } else if (mode == 3) { // REPLACE
        if (!alphaOnly) color.rgb = texel.rgb;
        if (hasAlpha) color.a = texel.a;
    } else if (mode == 4) { // ADD
        if (!alphaOnly) color.rgb = saturate(color.rgb + texel.rgb);
        if (intensity) color.a = saturate(color.a + texel.a);
        else if (hasAlpha) color.a *= texel.a;
    }
    return color;
}

// ---- Fragment shader ----

fragment float4 gl_fragment_main(
    GLVertexOut in [[stage_in]],
    constant GLFragmentUniforms &uniforms [[buffer(1)]],
    texture2d<float> tex [[texture(0)]],
    texture3d<float> tex3d [[texture(1)]],
    texture2d<float> tex1 [[texture(2)]],
    sampler samp [[sampler(0)]],
    sampler samp1 [[sampler(1)]],
    bool frontFacing [[front_facing]])
{
    // User clip planes: discard if any clip distance is negative
    if (in.num_clip_planes > 0 && in.clip_dist0 < 0.0) discard_fragment();
    if (in.num_clip_planes > 1 && in.clip_dist1 < 0.0) discard_fragment();
    if (in.num_clip_planes > 2 && in.clip_dist2 < 0.0) discard_fragment();
    if (in.num_clip_planes > 3 && in.clip_dist3 < 0.0) discard_fragment();
    if (in.num_clip_planes > 4 && in.clip_dist4 < 0.0) discard_fragment();
    if (in.num_clip_planes > 5 && in.clip_dist5 < 0.0) discard_fragment();

    float4 color = frontFacing ? in.color : in.back_color;

    // Texture application
    if (uniforms.has_texture) {
        // Projective texturing: divide s,t by q for perspective-correct mapping
        float2 uv = (in.texcoord.z != 0.0) ? in.texcoord.xy / in.texcoord.z : in.texcoord.xy;
        if (uniforms.has_texture_1d) uv.y = 0.5;
        float4 tex_color;
        if (uniforms.has_texture_3d) {
            float3 uvw = float3(uv, in.texcoord1.x);  // use unit 1's s as the r (depth) coordinate
            tex_color = tex3d.sample(samp, uvw);
        } else {
            tex_color = tex.sample(samp, uv);
        }

        if (uniforms.bitmap_mask) {
            // A zero bitmap bit generates no fragment, even with blending or
            // alpha testing disabled. Coverage is independent of raster alpha.
            if (tex_color.a < 0.5) discard_fragment();
        } else {
            color = gl_texture_environment(color, tex_color, uniforms.texenv_mode,
                                           uniforms.texenv_color, uniforms.tex_format);
        }
    }

    if (uniforms.has_texture_unit1) {
        float2 uv1 = (in.texcoord1.z != 0.0) ? in.texcoord1.xy / in.texcoord1.z : in.texcoord1.xy;
        if (uniforms.has_texture_unit1_1d) uv1.y = 0.5;
        float4 texel = tex1.sample(samp1, uv1);
        color = gl_texture_environment(color, texel, uniforms.texenv1_mode,
                                       uniforms.texenv1_color, uniforms.tex1_format);
    }

    // Color sum (GL_COLOR_SUM / EXT_secondary_color): per OpenGL 1.2.1 §3.9 the
    // secondary (specular) color is added AFTER texturing and clamped, before fog.
    if (uniforms.color_sum_enabled) {
        color.rgb = saturate(color.rgb + in.secondary_color);
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

    if (uniforms.force_opaque_output) {
        color.a = 1.0;
    }

    return color;
}

// Clear draws bypass the ordinary GL pipeline: only scissor and attachment
// write masks apply. values[0] is color, values[1].x is window-space depth.
struct GLClearVertexOut {
    float4 position [[position]];
};

vertex GLClearVertexOut gl_clear_vertex(uint vertexID [[vertex_id]],
                                       constant float4 *values [[buffer(0)]]) {
    const float2 positions[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    return {float4(positions[vertexID], values[1].x, 1)};
}

fragment float4 gl_clear_fragment(constant float4 *values [[buffer(0)]]) {
    return values[0];
}

// Framebuffer-to-texture transfer. OpenGL texture row zero is the bottom
// framebuffer row. Reads/writes use logical RGBA even for BGRA8 storage.
struct GLCopyTextureUniforms {
    uint source_x, source_bottom, width, height;
    float4 scale, bias;
    uint base_internal_format;
};
kernel void gl_copy_texture_region(texture2d<float, access::read> source [[texture(0)]],
                                   texture2d<float, access::write> destination [[texture(1)]],
                                   constant GLCopyTextureUniforms &u [[buffer(0)]],
                                   uint2 p [[thread_position_in_grid]]) {
    if (p.x >= u.width || p.y >= u.height) return;
    float4 color = source.read(uint2(u.source_x + p.x, u.source_bottom - p.y));
    color = clamp(color * u.scale + u.bias, 0.0f, 1.0f);
    if (u.base_internal_format == 0x1906) color.rgb = float3(1.0);
    else if (u.base_internal_format == 0x1909 || u.base_internal_format == 0x190a || u.base_internal_format == 0x8049) {
        color.rgb = float3(color.r);
        if (u.base_internal_format == 0x8049) color.a = color.r;
        else if (u.base_internal_format == 0x1909) color.a = 1.0;
    } else if (u.base_internal_format == 0x1907) color.a = 1.0;
    destination.write(color, p);
}
