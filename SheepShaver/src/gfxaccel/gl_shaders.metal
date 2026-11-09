/*
 *  gl_shaders.metal - OpenGL 1.2 FFP uber-shader via uniforms
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  The OpenGL 1.2 fixed-function pipeline as uniform-driven Metal shaders:
 *  transforms, per-vertex lighting (8 lights), texture environments, fog,
 *  alpha test, and flat/smooth shading.
 */

#include <metal_stdlib>
using namespace metal;


// ---- Vertex input/output ----

struct GLVertexIn {
    float4 position        [[attribute(0)]];
    float4 color           [[attribute(1)]];
    float3 normal          [[attribute(2)]];
    float4 texcoord        [[attribute(3)]];   // (s, t, q) unit 0; q enables projective texturing
    float4 texcoord1       [[attribute(4)]];   // (s, t, q) unit 1
    float stipple_distance [[attribute(17)]];
    float4 lighting_position [[attribute(6)]]; // provoking position for flat lighting
    float3 secondary_color [[attribute(5)]];   // (r, g, b) EXT_secondary_color / GL_COLOR_SUM
    float4 material0_ambient [[attribute(7)]];
    float4 material0_diffuse [[attribute(8)]];
    float4 material0_specular [[attribute(9)]];
    float4 material0_emission [[attribute(10)]];
    float material0_shininess [[attribute(11)]];
    float4 material1_ambient [[attribute(12)]];
    float4 material1_diffuse [[attribute(13)]];
    float4 material1_specular [[attribute(14)]];
    float4 material1_emission [[attribute(15)]];
    float material1_shininess [[attribute(16)]];
};

struct GLVertexOut {
    float4 position     [[position]];
    float  point_size   [[point_size]];
    float stipple_distance [[center_no_perspective]];
    float4 color;
    float4 back_color;
    float3 eye_normal;
    float4 texcoord;    // (s, t, q) unit 0; divided by q per fragment
    float4 texcoord1;   // (s, t, q) unit 1
    float3 secondary_color; // GL_COLOR_SUM term, added after texturing
    float3 eye_position;
    float  fog_factor;
    float  clip_dist0;  // user clip plane distances (interpolated, discard if < 0)
    float  clip_dist1;
    float  clip_dist2;
    float  clip_dist3;
    float  clip_dist4;
    float  clip_dist5;
    int    num_clip_planes;
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
    int      num_clip_planes;   // 0-6
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
    int    has_texture_unit1;   // unit 1 has an enabled texture
    int    texenv1_mode;        // unit-1 texenv mode (0=modulate,1=decal,2=blend,3=replace,4=add)
    int    force_opaque_output; // window overlay, GL blending disabled: store coverage alpha
    int    tex_format;          // primary base internal format
    int    tex1_format;
    float4 texenv1_color;       // independent unit-1 GL_TEXTURE_ENV_COLOR
    int    has_texture_1d;
    int    has_texture_unit1_1d;
    int    bitmap_mask;
    int    _pad9;
    int    polygon_stipple_enabled;
    int    line_stipple_enabled;
    int    line_stipple_factor;
    int    framebuffer_height;
    uint   polygon_stipple[32];
    int    has_texture_unit1_3d;
    int _raster_pad0, _raster_pad1, _raster_pad2;
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
    float  _pad0;               // 16-byte alignment
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
                             GLMaterialData material,
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

    out.point_size = uniforms.point_size;
    out.stipple_distance = in.stipple_distance;

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

    // 4. Texcoords and secondary color pass through
    out.texcoord = in.texcoord;
    out.texcoord1 = in.texcoord1;
    out.secondary_color = in.secondary_color;

    // 5. Lighting or pass-through color. Points/lines and one-sided polygons
    // receive identical front/back outputs, so fragment facing cannot affect them.
    GLMaterialData material0;
    material0.ambient=in.material0_ambient;
    material0.diffuse=in.material0_diffuse;
    material0.specular=in.material0_specular;
    material0.emission=in.material0_emission;
    material0.shininess=in.material0_shininess;
    material0.color_material=0;
    GLMaterialData material1;
    material1.ambient=in.material1_ambient;
    material1.diffuse=in.material1_diffuse;
    material1.specular=in.material1_specular;
    material1.emission=in.material1_emission;
    material1.shininess=in.material1_shininess;
    material1.color_material=0;
    if (uniforms.lighting_enabled) {
        out.color = gl_light_vertex(in.color, eye_normal, lighting_eye_pos,
                                   material0, lighting);
        out.back_color = uniforms.two_side_lighting
            ? gl_light_vertex(in.color, -eye_normal, lighting_eye_pos,
                              material1, lighting)
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

// Duplicate the fragment color into independent logical front/back targets.
// Their write masks and blending are selected by glDrawBuffer; depth/stencil
// execute once, including GL_FRONT_AND_BACK.
struct GLFragmentOutput { float4 front [[color(0)]]; float4 back [[color(1)]]; };

static float4 gl_shade_fragment(
    GLVertexOut in,
    constant GLFragmentUniforms &uniforms,
    texture2d<float> tex,
    texture3d<float> tex3d,
    texture2d<float> tex1,
    texture3d<float> tex1_3d,
    sampler samp,
    sampler samp1,
    bool frontFacing)
{
    if (uniforms.polygon_stipple_enabled) {
        uint x=uint(in.position.x)&31u;
        uint y=uint(uniforms.framebuffer_height-1-int(in.position.y))&31u;
        if ((uniforms.polygon_stipple[y] & (1u<<x))==0) discard_fragment();
    }
    if (uniforms.line_stipple_enabled) {
        uint bit=(uint(max(0.0f,floor(in.stipple_distance)))/uint(uniforms.line_stipple_factor))&15u;
        // Line pattern is carried separately in the last padding word.
        if ((uint(uniforms._raster_pad0)&(1u<<bit))==0) discard_fragment();
    }
    // User clip planes
    if (in.num_clip_planes > 0 && in.clip_dist0 < 0.0) discard_fragment();
    if (in.num_clip_planes > 1 && in.clip_dist1 < 0.0) discard_fragment();
    if (in.num_clip_planes > 2 && in.clip_dist2 < 0.0) discard_fragment();
    if (in.num_clip_planes > 3 && in.clip_dist3 < 0.0) discard_fragment();
    if (in.num_clip_planes > 4 && in.clip_dist4 < 0.0) discard_fragment();
    if (in.num_clip_planes > 5 && in.clip_dist5 < 0.0) discard_fragment();

    float4 color = frontFacing ? in.color : in.back_color;

    // Texture application
    if (uniforms.has_texture) {
        // Projective texturing: divide by q
        float2 uv = (in.texcoord.w != 0.0) ? in.texcoord.xy / in.texcoord.w : in.texcoord.xy;
        if (uniforms.has_texture_1d) uv.y = 0.5;
        float4 tex_color;
        if (uniforms.has_texture_3d) {
            float3 uvw = in.texcoord.w != 0.0 ? in.texcoord.xyz / in.texcoord.w : in.texcoord.xyz;
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
        float2 uv1 = (in.texcoord1.w != 0.0) ? in.texcoord1.xy / in.texcoord1.w : in.texcoord1.xy;
        if (uniforms.has_texture_unit1_1d) uv1.y = 0.5;
        float3 uvw1=in.texcoord1.w != 0.0 ? in.texcoord1.xyz/in.texcoord1.w : in.texcoord1.xyz;
        float4 texel = uniforms.has_texture_unit1_3d ? tex1_3d.sample(samp1,uvw1) : tex1.sample(samp1, uv1);
        color = gl_texture_environment(color, texel, uniforms.texenv1_mode,
                                       uniforms.texenv1_color, uniforms.tex1_format);
    }

    // Color sum (GL 1.2.1 §3.9): secondary color is added after texturing,
    // clamped, before fog.
    if (uniforms.color_sum_enabled) {
        color.rgb = saturate(color.rgb + in.secondary_color);
    }

    // Fog. fog_color.w < 0 means fog is off.
    if (uniforms.fog_color.w > -0.5) {
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

// Guest RGBA and presentation coverage are distinct render targets.
struct GLPresentationUniforms {
    uint blend_enabled, blend_src, blend_dst, blend_equation;
    uint logic_enabled, logic_op, pad0, pad1;
    float4 blend_color;
};
struct GLPresentationOutput {
    float4 front [[color(0)]];
    float4 back [[color(1)]];
    float4 presentation_front [[color(2)]];
    float4 presentation_back [[color(3)]];
};
static float4 gl_logic_color(float4 source, float4 destination, uint operation) {
    uint4 s=uint4(round(saturate(source)*255.0f));
    uint4 d=uint4(round(saturate(destination)*255.0f));
    uint4 value;
    switch(operation) {
        case 0x1500: value=uint4(0); break;
        case 0x1501: value=s&d; break;
        case 0x1502: value=s&~d; break;
        case 0x1503: value=s; break;
        case 0x1504: value=~s&d; break;
        case 0x1505: value=d; break;
        case 0x1506: value=s^d; break;
        case 0x1507: value=s|d; break;
        case 0x1508: value=~(s|d); break;
        case 0x1509: value=~(s^d); break;
        case 0x150a: value=~d; break;
        case 0x150b: value=s|~d; break;
        case 0x150c: value=~s; break;
        case 0x150d: value=~s|d; break;
        case 0x150e: value=~(s&d); break;
        case 0x150f: value=uint4(255); break;
        default: value=s; break;
    }
    return float4(value&uint4(255))/255.0f;
}
static float4 gl_blend_factor(uint factor, float4 source, float4 destination, float4 constantColor) {
    switch(factor) {
        case 0: return float4(0);
        case 1: return float4(1);
        case 0x0300: return source;
        case 0x0301: return 1.0f-source;
        case 0x0302: return float4(source.a);
        case 0x0303: return float4(1.0f-source.a);
        case 0x0304: return float4(destination.a);
        case 0x0305: return float4(1.0f-destination.a);
        case 0x0306: return destination;
        case 0x0307: return 1.0f-destination;
        case 0x0308: return float4(float3(min(source.a,1.0f-destination.a)),1);
        case 0x8001: return constantColor;
        case 0x8002: return 1.0f-constantColor;
        case 0x8003: return float4(constantColor.a);
        case 0x8004: return float4(1.0f-constantColor.a);
        default: return float4(1);
    }
}
static float4 gl_presentation_color(float4 source, float4 nativeDestination,
    float4 visibleDestination, constant GLPresentationUniforms &u) {
    source=saturate(source);
    if (u.logic_enabled) {
        if (u.logic_op==0x1505) return visibleDestination; // GL_NOOP
        return float4(gl_logic_color(source,nativeDestination,u.logic_op).rgb,1);
    }
    if (!u.blend_enabled) return float4(source.rgb,1);
    float3 sourceFactor=gl_blend_factor(u.blend_src,source,nativeDestination,u.blend_color).rgb;
    float3 destinationFactor=gl_blend_factor(u.blend_dst,source,nativeDestination,u.blend_color).rgb;
    float3 s=source.rgb*sourceFactor;
    float3 d=visibleDestination.rgb*destinationFactor;
    float3 result=s+d;
    if(u.blend_equation==0x8007) result=min(source.rgb,visibleDestination.rgb);
    else if(u.blend_equation==0x8008) result=max(source.rgb,visibleDestination.rgb);
    else if(u.blend_equation==0x800a) result=s-d;
    else if(u.blend_equation==0x800b) result=d-s;
    // Coverage follows RGB contribution weights, independently of guest alpha.
    // For channel-dependent factors use the largest weight conservatively;
    // a single compositor coverage channel cannot encode three transmittances.
    float coverage=max(sourceFactor.r,max(sourceFactor.g,sourceFactor.b)) +
        visibleDestination.a*max(destinationFactor.r,max(destinationFactor.g,destinationFactor.b));
    // Blending can darken an already covered surface, but cannot uncover it.
    // In particular DST_COLOR/ZERO and ZERO/SRC_COLOR multiply the scene;
    // their color weights must not punch translucent holes into opaque floors.
    coverage=max(visibleDestination.a,coverage);
    if(u.blend_equation==0x8007 || u.blend_equation==0x8008) coverage=1;
    return saturate(float4(result,coverage));
}
fragment GLFragmentOutput gl_fragment_main(
    GLVertexOut in [[stage_in]], constant GLFragmentUniforms &uniforms [[buffer(1)]],
    constant GLPresentationUniforms &presentation [[buffer(4)]],
    texture2d<float> tex [[texture(0)]], texture3d<float> tex3d [[texture(1)]],
    texture2d<float> tex1 [[texture(2)]], texture2d<float> front [[texture(3)]],
    texture2d<float> back [[texture(4)]], texture3d<float> tex1_3d [[texture(7)]],
    sampler samp [[sampler(0)]], sampler samp1 [[sampler(1)]], bool facing [[front_facing]]) {
    float4 color=gl_shade_fragment(in,uniforms,tex,tex3d,tex1,tex1_3d,samp,samp1,facing);
    if(presentation.logic_enabled) {
        uint2 p=uint2(in.position.xy);
        return {gl_logic_color(color,front.read(p),presentation.logic_op),
                gl_logic_color(color,back.read(p),presentation.logic_op)};
    }
    return {color,color};
}
fragment GLPresentationOutput gl_fragment_present(
    GLVertexOut in [[stage_in]], constant GLFragmentUniforms &uniforms [[buffer(1)]],
    constant GLPresentationUniforms &presentation [[buffer(4)]],
    texture2d<float> tex [[texture(0)]], texture3d<float> tex3d [[texture(1)]],
    texture2d<float> tex1 [[texture(2)]], texture2d<float> front [[texture(3)]],
    texture2d<float> back [[texture(4)]], texture2d<float> visibleFront [[texture(5)]],
    texture2d<float> visibleBack [[texture(6)]], texture3d<float> tex1_3d [[texture(7)]],
    sampler samp [[sampler(0)]], sampler samp1 [[sampler(1)]], bool facing [[front_facing]]) {
    float4 color=gl_shade_fragment(in,uniforms,tex,tex3d,tex1,tex1_3d,samp,samp1,facing);
    if(!presentation.blend_enabled && !presentation.logic_enabled)
        return {color,color,float4(color.rgb,1),float4(color.rgb,1)};
    uint2 p=uint2(in.position.xy);
    float4 nativeFront=front.read(p),nativeBack=back.read(p);
    float4 resultFront=presentation.logic_enabled?gl_logic_color(color,nativeFront,presentation.logic_op):color;
    float4 resultBack=presentation.logic_enabled?gl_logic_color(color,nativeBack,presentation.logic_op):color;
    return {resultFront,resultBack,
        gl_presentation_color(color,nativeFront,visibleFront.read(p),presentation),
        gl_presentation_color(color,nativeBack,visibleBack.read(p),presentation)};
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

fragment GLFragmentOutput gl_clear_fragment(constant float4 *values [[buffer(0)]]) {
    return {values[0], values[0]};
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

fragment GLPresentationOutput gl_clear_present_fragment(constant float4 *values [[buffer(0)]]) {
    return {values[0],values[0],values[2],values[2]};
}

// Apple GPUs read color attachments coherently in primitive order. This
// keeps destination-dependent operations in tile memory, avoiding a copy per
// primitive. Other GPUs use the snapshot variants above.
fragment GLFragmentOutput gl_fragment_main_fetch(
    GLVertexOut in [[stage_in]], constant GLFragmentUniforms &uniforms [[buffer(1)]],
    constant GLPresentationUniforms &presentation [[buffer(4)]],
    texture2d<float> tex [[texture(0)]], texture3d<float> tex3d [[texture(1)]],
    texture2d<float> tex1 [[texture(2)]], texture2d<float> front [[texture(3)]],
    texture2d<float> back [[texture(4)]], texture3d<float> tex1_3d [[texture(7)]],
    sampler samp [[sampler(0)]], sampler samp1 [[sampler(1)]], bool facing [[front_facing]],
    float4 nativeFront [[color(0)]], float4 nativeBack [[color(1)]]) {
    float4 color=gl_shade_fragment(in,uniforms,tex,tex3d,tex1,tex1_3d,samp,samp1,facing);
    if(presentation.logic_enabled) {
        return {gl_logic_color(color,nativeFront,presentation.logic_op),
                gl_logic_color(color,nativeBack,presentation.logic_op)};
    }
    return {color,color};
}
fragment GLPresentationOutput gl_fragment_present_fetch(
    GLVertexOut in [[stage_in]], constant GLFragmentUniforms &uniforms [[buffer(1)]],
    constant GLPresentationUniforms &presentation [[buffer(4)]],
    texture2d<float> tex [[texture(0)]], texture3d<float> tex3d [[texture(1)]],
    texture2d<float> tex1 [[texture(2)]], texture2d<float> front [[texture(3)]],
    texture2d<float> back [[texture(4)]], texture2d<float> visibleFront [[texture(5)]],
    texture2d<float> visibleBack [[texture(6)]], texture3d<float> tex1_3d [[texture(7)]],
    sampler samp [[sampler(0)]], sampler samp1 [[sampler(1)]], bool facing [[front_facing]],
    float4 nativeFront [[color(0)]], float4 nativeBack [[color(1)]],
    float4 priorVisibleFront [[color(2)]], float4 priorVisibleBack [[color(3)]]) {
    float4 color=gl_shade_fragment(in,uniforms,tex,tex3d,tex1,tex1_3d,samp,samp1,facing);
    if(!presentation.blend_enabled && !presentation.logic_enabled)
        return {color,color,float4(color.rgb,1),float4(color.rgb,1)};

    float4 resultFront=presentation.logic_enabled?gl_logic_color(color,nativeFront,presentation.logic_op):color;
    float4 resultBack=presentation.logic_enabled?gl_logic_color(color,nativeBack,presentation.logic_op):color;
    return {resultFront,resultBack,
        gl_presentation_color(color,nativeFront,priorVisibleFront,presentation),
        gl_presentation_color(color,nativeBack,priorVisibleBack,presentation)};
}
