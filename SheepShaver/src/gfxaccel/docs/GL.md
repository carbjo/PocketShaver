# GL Engine — Metal Rendering Backend for OpenGL 1.2

**Author:** Sierra Burkhart ([@sierra760](https://github.com/sierra760))

## Overview

The GL engine implements Apple's OpenGL 1.2 fixed-function pipeline (FFP)
inside PocketShaver's SheepShaver emulator. Classic Mac OS games that use
OpenGL — typically via Apple's AGL (Apple GL) platform bindings — call
into the system's `OpenGLLibrary`, `OpenGLEngine`, and `agl` shared
libraries expecting hardware-accelerated rendering. This engine intercepts
those calls at the PPC emulation boundary and translates them into Metal
draw calls on the host iOS GPU.

The implementation covers the full GL 1.2.1 core specification plus
commonly used extensions (ARB_multitexture, ARB_texture_compression with
S3TC/DXT decompression, EXT_secondary_color, EXT_blend_color), the AGL
platform layer (context creation, pixel format selection, drawable
management), GLU utility functions (perspective, lookAt, quadrics, NURBS,
tessellation), and GLUT windowing primitives.

### Key Design Decisions

- **FindLibSymbol hook interception**: Rather than patching individual
  function pointers, the engine hooks `FindLibSymbol` calls for
  `OpenGLLibrary`, `OpenGLEngine`, `OpenGLUtility`, `agl`, and `glut`.
  When the guest OS or a game looks up a GL function by name, the hook
  returns a native TVECT instead of the original. This means only
  functions actually looked up by the running application consume thunk
  resources.

- **GLIFunctionDispatch slot ordering**: The ~336 core GL sub-opcodes
  follow the exact field order of Apple's `gliDispatch.h` struct. This
  makes dispatch-table patching trivial: the sub-opcode *is* the struct
  field index.

- **Uniform-driven uber-shader**: Instead of function constants (as used
  by RAVE), the GL shader uses uniform buffers to control all pipeline
  state at draw time. This avoids pipeline recompilation when state
  changes — important because GL applications change blend/depth/fog
  state far more frequently than RAVE contexts.

- **Shared CAMetalLayer overlay**: The GL engine reuses RAVE's transparent
  CAMetalLayer overlay and reference-counting infrastructure. A single
  overlay handles both RAVE and GL contexts simultaneously.

- **Immediate mode to Metal**: `glBegin`/`glEnd` pairs accumulate vertices
  into a per-frame ring buffer (4 MB, triple-buffered). Quads, polygons,
  and triangle fans are converted to triangle lists on the CPU before
  submission to Metal.

---

## File Map

### GL Engine Sources (6 files)

| File | Lines | Purpose |
|------|------:|---------|
| `gl_engine.cpp` | ~5300 | AGL platform bindings, GLContext lifecycle, FindLibSymbol hook installation, texture management |
| `gl_dispatch.cpp` | ~2560 | Sub-opcode router: reads scratch word, extracts GPR/FPR arguments, dispatches to handler |
| `gl_state.cpp` | ~5190 | Full GL 1.2 state machine: matrix stacks, enable/disable, lighting, fog, texenv, pixel store, attrib stacks |
| `gl_metal_renderer.mm` | ~3100 | Metal pipeline cache, vertex ring buffer, immediate-mode rendering, uniform upload, frame lifecycle |
| `gl_thunks.cpp` | ~390 | Allocates ~643 PPC-callable TVECTs in SheepMem with sub-opcode scratch word |
| `gl_shaders.metal` | ~280 | Uber vertex + fragment shader with uniform-controlled FFP: MVP, lighting, texenv, fog, alpha test |

### GL Header (1 file)

| File | Purpose |
|------|---------|
| `include/gl_engine.h` | Sub-opcode enums (~916 entries), `GLContext` struct, `GLTextureObject`, `GLMetalState` forward declaration, function signature table, all extern declarations |

### Shared Infrastructure (used, not owned by GL)

| File | Relationship |
|------|-------------|
| `include/accel_logging.h` | Conditional logging macros |
| `include/rave_metal_renderer.h` | Shared overlay lifecycle (`RaveCreateMetalOverlay`, `RaveOverlayRetain`/`Release`) |
| `gfxaccel.cpp` | Calls `GLInstallHooks()` at initialization |
| `thunks.h` / `thunks.cpp` | Registers `NATIVE_OPENGL_DISPATCH` handler |
| `sheepshaver_glue.cpp` | Routes `NATIVE_OPENGL_DISPATCH` to GL dispatch |

---

## Key Data Structures

### GLContext

The central per-context structure allocated in `NativeAGLCreateContext`.
Each AGL context maps to one `GLContext` in host memory.

```
struct GLContext {
    // Identity
    uint32_t    contextAddr;            // Mac-side opaque handle

    // Viewport and scissor
    int32_t     viewport[4];            // x, y, width, height
    int32_t     scissor[4];

    // Matrix stacks (column-major 4x4)
    float       modelview[16];
    float       projection[16];
    float       texture_matrix[16];
    std::vector<float> mv_stack;        // push/pop storage
    std::vector<float> proj_stack;
    std::vector<float> tex_stack;

    // Depth/blend/alpha/stencil state
    uint32_t    depth_func;
    bool        depth_mask;
    uint32_t    blend_src, blend_dst;
    uint32_t    alpha_func;
    float       alpha_ref;

    // Lighting (8 lights)
    GLLight     lights[8];
    GLMaterial  front_material, back_material;
    float       light_model_ambient[4];

    // Texture units (multitexture)
    GLTextureUnit tex_units[8];
    int         active_texture;
    std::unordered_map<uint32_t, GLTextureObject> texture_objects;

    // Immediate mode vertex submission
    std::vector<GLVertex> immediate_vertices;
    uint32_t    current_primitive;       // GL_TRIANGLES, GL_QUADS, etc.

    // Metal state (opaque, defined in gl_metal_renderer.mm)
    GLMetalState *metal;
};
```

### Sub-Opcode Dispatch Ranges

| Range | Count | API Layer |
|-------|------:|-----------|
| 0–335 | 336 | Core GL (GLIFunctionDispatch field order) |
| 400–503 | 104 | GL Extensions (ARB_multitexture, texture_compression, etc.) |
| 600–632 | 33 | AGL (Apple GL platform) |
| 700–753 | 54 | GLU (utility library) |
| 800–915 | 116 | GLUT (windowing toolkit) |

The dispatch handler in `gl_dispatch.cpp` reads the sub-opcode from the
scratch word and uses the function signature table to determine which
PPC registers contain float vs. integer arguments.

### GLMetalState

Opaque struct defined in `gl_metal_renderer.mm` containing:
- `id<MTLDevice>`, `id<MTLCommandQueue>`
- Pipeline state cache (`std::unordered_map<uint64_t, id<MTLRenderPipelineState>>`)
- Depth/stencil state cache
- Triple-buffered vertex ring buffer (4 MB per frame)
- Current command buffer and render encoder
- Uniform staging buffers for MVP, lighting, fog, texenv

---

## Integration Points

### FindLibSymbol Hook Installation

`GLInstallHooks()` in `gl_engine.cpp`:
1. Uses `FindLibSymbol` to locate all GL/AGL/GLU/GLUT function TVECTs
   in the guest OS shared libraries
2. Records original TVECTs for potential chain-through
3. Patches the CFM transition vectors to point to native thunks
4. Supports both `OpenGLLibrary` (GL core) and `OpenGLEngine` (dispatch
   table) naming conventions

The installation is split into two phases:
- **Symbol lookup**: All `FindLibSymbol` calls execute first (to avoid
  re-entrancy issues with CFM fragment loading)
- **TVECT patching**: After all symbols are cached, TVECTs are patched
  in a single pass

### AGL Context Lifecycle

1. **aglChoosePixelFormat**: Returns a dummy pixel format handle (Metal
   handles all format selection internally)
2. **aglCreateContext**: Allocates a `GLContext`, initializes GL 1.2
   default state, creates Metal resources via `GLMetalInit`
3. **aglSetDrawable**: Associates the context with the emulated display;
   creates or retains the shared `CAMetalLayer` overlay
4. **aglSetCurrentContext**: Makes a context current (stores in global
   `gl_current_context`)
5. **aglSwapBuffers**: Commits the Metal command buffer and presents
   the drawable
6. **aglDestroyContext**: Releases Metal resources via `GLMetalRelease`,
   decrements overlay refcount

### Thunk Architecture

Identical to RAVE: each of the ~643 TVECTs writes a method-specific
sub-opcode to a shared scratch word, then executes
`NATIVE_OP(NATIVE_OPENGL_DISPATCH)`. The dispatch handler reads the
scratch word and routes to the appropriate handler function.

A function signature table (`gl_func_signatures[]`) tells the dispatcher
which arguments are floats/doubles (read from FPR registers) vs.
integers/pointers (read from GPR registers). Functions with more than 8
arguments use PPC stack access for overflow arguments.

---

## Metal Pipeline

### Shader Architecture

The GL uber-shader (`gl_shaders.metal`) uses uniform buffers rather than
function constants to control all FFP behavior:

**Vertex shader** (`gl_vertex`):
- Transforms position by MVP matrix
- Transforms normals by normal matrix (inverse-transpose of modelview)
- Computes per-vertex Phong lighting for up to 8 lights
- Passes texture coordinates and fog depth to fragment stage

**Fragment shader** (`gl_fragment`):
- Applies texture environment mode (modulate, decal, blend, replace)
- Computes fog factor (linear, exp, exp²) and blends with fog color
- Performs alpha test against reference value
- Supports flat shading via `[[flat]]` interpolation qualifier

### Vertex Submission

GL immediate mode (`glBegin`/`glEnd`) accumulates vertices into a
staging vector on the `GLContext`. At `glEnd`, the vertices are:
1. Converted from quads/polygons/fans to triangle lists (CPU-side)
2. Uploaded to a Metal vertex buffer from the ring buffer
3. Drawn with the current pipeline state

Vertex arrays (`glDrawArrays`, `glDrawElements`) read vertex data
directly from emulated PPC memory, byte-swap, and upload in bulk.

### Pipeline State Cache

Metal render pipeline states are keyed by a 64-bit hash combining:
- Blend enabled, source factor, destination factor
- Depth write mask
- Color write mask (RGBA channels)
- Texture presence flag

Pipeline states are created on-demand and cached in an
`unordered_map<uint64_t, id<MTLRenderPipelineState>>`. Depth test
function and stencil state are set via `MTLDepthStencilState` objects,
cached separately.

### Texture Management

Textures are created via `glTexImage2D` and friends:
1. Pixel data is read from PPC memory with appropriate byte-swapping
2. Converted to BGRA8 regardless of source format (RGB, RGBA, luminance,
   indexed, compressed DXT1/DXT3/DXT5)
3. Uploaded to a `MTLTexture` via `replaceRegion`
4. Mipmaps generated via `generateMipmapsForTexture:` when present

The engine supports all GL 1.2 pixel formats including:
- `GL_RGBA`, `GL_RGB`, `GL_BGRA`, `GL_LUMINANCE`, `GL_ALPHA`
- `GL_LUMINANCE_ALPHA`, `GL_UNSIGNED_SHORT_5_6_5`, `GL_UNSIGNED_SHORT_1_5_5_5_REV`
- S3TC compressed formats (DXT1, DXT3, DXT5 — decompressed on CPU)
- 3D textures via `glTexImage3D` (EXT_texture3D)

---

## State Management

The GL 1.2 state machine is implemented in `gl_state.cpp` (~5190 lines):

### Matrix Operations

Full column-major 4×4 matrix math with per-mode stacks:
- Modelview stack (32 deep), projection stack (2 deep), texture stack
- `glPushMatrix`/`glPopMatrix`, `glLoadIdentity`, `glMultMatrixf`
- `glRotatef`, `glTranslatef`, `glScalef`, `glFrustum`, `glOrtho`
- Normal matrix computed as inverse-transpose of upper-left 3×3 of
  modelview (for correct lighting with non-uniform scaling)

### Lighting

8 independent light sources with:
- Ambient, diffuse, specular, position (directional or positional)
- Spot direction, cutoff, exponent
- Constant/linear/quadratic attenuation
- Per-vertex Phong computation in the vertex shader

### Fog

Three modes: `GL_LINEAR`, `GL_EXP`, `GL_EXP2`
- Fog color, start, end, density configured via `glFogf`/`glFogfv`
- Computed per-fragment from eye-space depth

### Attribute Stacks

`glPushAttrib`/`glPopAttrib` save and restore state groups by bitmask
(depth, blend, polygon, lighting, fog, scissor, viewport, color buffer,
stencil, texture, enable flags).

---

## GLU and GLUT Support

### GLU (54 functions)

- Projection helpers: `gluPerspective`, `gluLookAt`, `gluOrtho2D`
- `gluPickMatrix`, `gluProject`, `gluUnProject`
- Quadric objects: `gluSphere`, `gluCylinder`, `gluDisk`, `gluPartialDisk`
- NURBS and tessellation (CPU-side state management)

### GLUT (116 functions)

- Display management: `glutInit`, `glutCreateWindow`, `glutMainLoop`
  (mapped to emulator's existing display)
- Callback registration: display, reshape, keyboard, mouse, idle, timer
- Geometric primitives: teapot, sphere, cube, cone, torus, icosahedron,
  tetrahedron, octahedron, dodecahedron (rendered via immediate mode GL)
- Font rendering: bitmap and stroke fonts

---

## Known Limitations

1. **No programmable shaders**: Only the GL 1.2 fixed-function pipeline
   is implemented. GLSL shaders (`GL_ARB_shader_objects`) are not
   supported. Classic Mac OS games universally use FFP.

2. **Single context**: The engine supports one active GL context at a
   time. AGL multi-context rendering is not supported.

3. **No framebuffer readback**: `glReadPixels`, `glCopyPixels`, and
   `glCopyTexImage2D` require GPU→CPU readback from the Metal drawable,
   which is not implemented. Logged as known limitations.

4. **Imaging subset**: Color tables, convolution filters, histogram, and
   minmax operations store state but do not affect the Metal rendering
   pipeline. They exist for API compatibility with games that query
   capabilities.

5. **No stencil buffer**: Stencil state is tracked but no stencil
   attachment is allocated on the Metal render pass. Games using stencil
   shadows will not render correctly.

6. **Display lists**: `glNewList`/`glEndList`/`glCallList` record
   commands into a CPU-side replay buffer. They provide correctness but
   not the performance benefit of GPU-side command caching.

7. **Accumulation buffer**: Implemented via CPU-side float buffer with
   readback/writeback. Correct but slow for multi-pass effects.

8. **Line width**: Metal on iOS constrains line width to 1.0 pixel.
   `glLineWidth` values greater than 1.0 are accepted but not honored.
