# RAVE Engine — Metal Rendering Backend for PocketShaver

**Author:** Sierra Burkhart ([@sierra760](https://github.com/sierra760))

## Overview

The RAVE (Rendering Acceleration Virtual Engine) engine implements Apple's
QD3D RAVE 1.6 acceleration interface inside PocketShaver's SheepShaver
emulator. Classic Mac OS 3D applications call into RAVE expecting a
hardware-accelerated rendering backend; this engine intercepts those calls
at the PPC emulation boundary and translates them into Metal draw calls on
the host iOS/macOS GPU.

The implementation follows the RAVE DDK (Driver Development Kit) contract:
the engine registers itself with `QARegisterEngine`, responds to gestalt
queries and device checks, creates per-window draw contexts with full
TQADrawContext dispatch tables, and renders geometry through a Metal
uber-shader pipeline that supports Gouraud shading, texture mapping, fog,
alpha testing, multi-texturing, and all 16 blend modes defined by the RAVE
specification.

### Key Design Decisions

- **Uber-shader with function constants**: Rather than maintaining dozens
  of separate shader programs, a single vertex/fragment shader pair uses
  Metal function constants to produce 16 pipeline state variants at
  initialization time (texture × fog × alpha_test × multi_texture).

- **Transparent CAMetalLayer overlay**: RAVE rendering composites on top
  of SheepShaver's existing SDL video surface via a transparent
  CAMetalLayer added as a sublayer. This avoids modifying the 2D video
  pipeline while allowing proper GPU-accelerated 3D compositing.

- **PPC thunk dispatch**: All 53 RAVE method entry points share a single
  `NATIVE_OP` slot (`NATIVE_RAVE_DISPATCH`). Each TVECT writes a unique
  sub-opcode to a scratch word before triggering the native dispatch
  handler, which routes to the appropriate C++ method.

- **Context address recycling**: `SheepMem::ReserveProc` is a permanent
  bump allocator. Applications that rapidly create and destroy draw
  contexts (e.g. RAVE Bench) would exhaust the 512 KB SheepMem region.
  A free list recycles deallocated context addresses to prevent this.

---

## File Map

### RAVE Engine Sources (6 files)

| File | Lines | Purpose |
|------|------:|---------|
| `rave_engine.cpp` | ~2600 | Engine registration, gestalt, device check, texture/bitmap/color table lifecycle, RAVE manager hook installation |
| `rave_metal_renderer.mm` | ~3800 | Metal layer overlay, per-context GPU resources, render start/end/flush/sync, all draw method implementations (points, lines, triangles, meshes, bitmaps), buffer access, swap control |
| `rave_dispatch.cpp` | ~430 | Sub-opcode router: reads scratch word, dispatches to engine or draw method handler |
| `rave_draw_context.mm` | ~620 | Draw context lifecycle (DrawPrivateNew/Delete), state accessors (Set/GetFloat/Int/Ptr by tag ID) |
| `rave_thunks.cpp` | ~230 | Allocates 53 PPC-callable TVECTs in SheepMem with sub-opcode scratch word |
| `rave_shaders.metal` | ~220 | Uber vertex + fragment shader with function constants for 16 pipeline variants |

### RAVE Headers (2 files)

| File | Purpose |
|------|---------|
| `include/rave_engine.h` | Sub-opcode enums, draw/engine method tags, `RaveDrawPrivate` struct, gestalt selectors, pixel format constants, extern declarations |
| `include/rave_metal_renderer.h` | C++ callable interface for Metal renderer — no ObjC types exposed; overlay lifecycle, per-context resource management, draw method declarations |

### Shared Infrastructure Headers (3 files)

| File | Purpose |
|------|---------|
| `include/accel_logging.h` | Conditional logging macros shared across acceleration engines |
| `include/gl_engine.h` | GL engine declarations (referenced by `gfxaccel.cpp`; not part of RAVE) |
| `include/nqd_accel.h` | NQD acceleration declarations (referenced by `gfxaccel.cpp`; not part of RAVE) |

### Modified Shared Infrastructure Files (10 files)

| File | Change |
|------|--------|
| `gfxaccel.cpp` | Includes RAVE header, calls `RaveRegisterEngine()` at initialization |
| `thunks.h` | Adds `NATIVE_RAVE_DISPATCH` to the `NativeSheepOp` enum |
| `thunks.cpp` | Registers the RAVE dispatch handler for `NATIVE_RAVE_DISPATCH` |
| `sheepshaver_glue.cpp` | Adds RAVE dispatch case to the native op handler switch |
| `main.cpp` | Calls RAVE initialization/teardown at emulator startup/shutdown |
| `video.h` | Exports framebuffer geometry used by RAVE for viewport setup |
| `prefs_items.cpp` | Adds `raveaccel` preference key for user control |
| `project.pbxproj` | Build system: adds RAVE source files and Metal shader compilation |
| `PreferencesAdvancedModel.swift` | UI model for RAVE acceleration toggle |
| `PreferencesAdvancedViewController.swift` | UI view controller for RAVE preference |

---

## Key Data Structures

### RaveDrawPrivate

The central per-context structure allocated in `NativeDrawPrivateNew`. It
lives in host (native) memory and is indexed by the Mac-side
`TQADrawContext` address.

```
struct RaveDrawPrivate {
    uint32_t  drawContextAddr;      // Mac address of TQADrawContext
    int32_t   left, top, width, height;  // Viewport geometry
    uint32_t  flags;                // kQAContext_NoZBuffer, etc.
    uint32_t  deviceType;          // kQADeviceMemory or kQADeviceGDevice
    uint32_t  pixelType;           // kQAPixel_RGB16 / RGB32

    // State arrays indexed by tag ID
    float    floatState[256];
    int32_t  intState[256];
    uint32_t ptrState[256];

    // Metal rendering state (opaque in .h, defined in .mm)
    RaveMetalState *metalState;

    // Texture bindings
    RaveTexture *currentTexture;
    RaveTexture *currentMultiTexture;

    // Staging buffers for SubmitVertices → DrawTriMesh workflow
    std::vector<RaveVertex> gouraudStaging;
    std::vector<RaveTextureVertex> textureStaging;
    std::vector<RaveMultiTexParams> multiTexStaging;

    // Notice method callbacks
    uint32_t noticeCallbacks[4];
    uint32_t noticeRefCons[4];
};
```

### Sub-Opcode Dispatch Table

Draw methods use tags 0–34 directly (matching `TQADrawMethodTag`). Engine
methods use 100–117 (offset by 100 to avoid collision). The dispatch
handler in `rave_dispatch.cpp` reads the sub-opcode from the scratch word
and branches accordingly.

### RaveMetalState

Opaque struct defined in `rave_metal_renderer.mm` containing:
- `id<MTLDevice>`, `id<MTLCommandQueue>`
- Pre-built pipeline state objects (16 variants)
- Depth/stencil states for Z-buffer enabled/disabled
- Vertex descriptor for the uber-shader input layout
- Current command buffer and render encoder
- Frame synchronization semaphore

---

## Integration Points

### Engine Registration

`RaveRegisterEngine()` in `rave_engine.cpp`:
1. Uses `FindLibSymbol` to locate `QARegisterEngine` in the RAVE shared
   library (`DrawSprocketLib` / `QD3DRAVE`)
2. Allocates the `EngineGetMethod` TVECT (sub-opcode 100)
3. Calls `QARegisterEngine` with the engine's vendor ID and TVECT pointer

### RAVE Manager Hook Installation

After registration, `RaveInstallHooks()` patches the RAVE manager's
global dispatch vectors to route through the native engine:
- `QAGetFirstEngine` / `QAGetNextEngine` — engine enumeration
- `QADrawContextNew` / `QADrawContextDelete` — context lifecycle
- `QATextureNew` / `QABitmapNew` / `QAColorTableNew` — resource creation
- `QATextureDelete` / `QABitmapDelete` / `QAColorTableDelete` — cleanup
- `QATextureDetach` / `QATextureBindColorTable` / `QABitmapBindColorTable`

The hooks intercept calls, perform native-side bookkeeping, then forward
to the original RAVE manager implementation when appropriate.

### Thunk Architecture

PPC code calls RAVE methods via CFM transition vectors (TVECTs). Each
TVECT is an 8-byte header (code pointer + TOC) followed by a short PPC
sequence that:
1. Writes the method's sub-opcode to the shared scratch word
2. Executes `NATIVE_OP(NATIVE_RAVE_DISPATCH)`
3. Returns to the caller

The native dispatch handler reads the scratch word, extracts PPC register
arguments (`r3`–`r10`), and calls the appropriate C++ implementation.

### Gestalt Selectors

`NativeEngineGestalt` responds to all 18 RAVE gestalt queries:

| Selector | Response |
|----------|----------|
| `kQAGestalt_OptionalFeatures` | Reports texture compression, mipmapping, multi-texture, render-to-texture |
| `kQAGestalt_TextureMemory` | 128 MB (reports large value; host GPU manages actual allocation) |
| `kQAGestalt_FastFeatures` | All fast features enabled |
| `kQAGestalt_VendorID` | `'PS3D'` (PocketShaver 3D) |
| `kQAGestalt_EngineID` | `'RAVE'` |
| `kQAGestalt_Revision` | RAVE 1.6 revision code |
| `kQAGestalt_ASCIINameLength` | Length of engine name string |
| `kQAGestalt_ASCIIName` | `"PocketShaver Metal RAVE"` |
| `kQAGestalt_MultiTextureMax` | 2 (dual-texture support) |

---

## Metal Pipeline

### Shader Architecture

The uber-shader (`rave_shaders.metal`) uses four boolean function
constants to specialize at compile time:

```
constant bool has_texture       [[function_constant(0)]];
constant bool has_fog           [[function_constant(1)]];
constant bool has_alpha_test    [[function_constant(2)]];
constant bool has_multi_texture [[function_constant(3)]];
```

This produces 2⁴ = 16 pipeline state objects, pre-built during context
initialization. Dead code elimination ensures each variant contains only
the logic it needs.

### Vertex Format

RAVE vertices arrive as PPC big-endian data read from emulated memory.
The renderer byte-swaps and converts to the Metal vertex layout:

| Attribute | Slot | Format |
|-----------|------|--------|
| Position  | 0    | float4 (x, y, z, invW) |
| Color     | 1    | float4 (r, g, b, a) — premultiplied |
| TexCoord  | 2    | float4 (uOverW, vOverW, invW, 0) |

Perspective-correct texture interpolation divides by the interpolated
`invW` in the fragment shader.

### Blend Modes

The renderer supports all RAVE blend modes by mapping them to Metal blend
factors:

| RAVE Mode | Metal Source Factor | Metal Dest Factor |
|-----------|--------------------:|------------------:|
| PreMultiply | One | InvSourceAlpha |
| Interpolate | SourceAlpha | InvSourceAlpha |
| Premultiply + Interpolate | One | InvSourceAlpha |

The pipeline state object is selected based on the context's current
blend mode setting (`kQATag_Blend`).

### Texture Management

Textures are created via `NativeTextureNew` in `rave_engine.cpp`:
1. Reads dimensions, mip count, and pixel format from emulated memory
2. Allocates a `RaveTexture` host struct with metadata
3. Creates a Metal texture via `RaveCreateMetalTexture` (in the .mm file)
4. Uploads base level pixel data, byte-swapping from PPC format
5. For mipmapped textures, uploads each mip level individually
6. Stores the Metal texture handle as an opaque `void*` in `RaveTexture`

Supported pixel formats: `kQAPixel_RGB16`, `kQAPixel_ARGB16`,
`kQAPixel_RGB32`, `kQAPixel_ARGB32`, `kQAPixel_CL4`, `kQAPixel_CL8`.

Color-indexed formats (`CL4`, `CL8`) are expanded to ARGB32 during
upload using the bound color table.

### Depth Buffer

When `kQAContext_NoZBuffer` is not set, the renderer creates a private
`MTLTexture` with `MTLPixelFormatDepth32Float` at the viewport resolution.
Depth testing uses `MTLCompareFunctionLessEqual` by default. The
`kQATag_ZFunction` tag allows applications to change the compare function.

---

## Build Configuration

### Xcode Project

RAVE source files are added to the PocketShaver target in
`project.pbxproj`. The Metal shader file (`rave_shaders.metal`) is
compiled by Xcode's built-in Metal shader compiler as part of the
standard build process.

### Header Search Paths

The `gfxaccel/include` directory is added to the project's header search
paths so that `#include "rave_engine.h"` resolves correctly from both the
`gfxaccel/` sources and the shared infrastructure files in `src/`.

### Preference Key

The `raveaccel` boolean preference controls whether the RAVE engine
registers itself at startup. When `false`, no RAVE hooks are installed
and 3D applications fall back to software rendering.

---

## Overlay Lifecycle

The CAMetalLayer overlay is reference-counted and shared between the RAVE
and GL engines:

1. **Creation** (`RaveCreateMetalOverlay`): Finds the SDL window's
   `UIView`, creates a `CAMetalLayer` sublayer with transparent background
   and matching frame geometry.

2. **Deferred destruction** (`RaveScheduleDeferredOverlayDestroy`):
   Rather than destroying immediately when the last context is deleted,
   schedules destruction after a short delay. This prevents flicker when
   applications rapidly destroy and recreate contexts between frames.

3. **Reference counting** (`RaveOverlayRetain`/`RaveOverlayRelease`):
   Each active draw context holds a reference. The overlay is destroyed
   only when the reference count reaches zero and the deferred timer
   fires.

---

## Staging Buffer and TriMesh Workflow

RAVE supports two rendering patterns:

1. **Immediate**: `DrawTriGouraud` / `DrawTriTexture` draw a single
   triangle per call.

2. **Batched**: `SubmitVerticesGouraud` / `SubmitVerticesTexture` fill a
   staging buffer, then `DrawTriMeshGouraud` / `DrawTriMeshTexture`
   reference those vertices by index. This is the high-performance path
   used by most QD3D applications.

The staging buffer is a `std::vector` on the `RaveDrawPrivate` struct,
cleared at each `RenderStart`. `DrawTriMesh` reads triangle index arrays
from PPC memory and looks up vertices in the staging buffer.

Multi-texture parameters are submitted separately via
`SubmitMultiTextureVertex` and stored in a parallel staging vector.

---

## Buffer Access (RAVE 1.6)

`AccessDrawBuffer` / `AccessZBuffer` provide CPU readback of the GPU
render target:

1. Wait for GPU completion (`NativeSync`)
2. Read back the Metal texture contents into a temporary host buffer
3. Return a pointer to the host buffer and the row stride

`AccessDrawBufferEnd` / `AccessZBufferEnd` optionally write modified
regions back to the GPU texture (used by post-processing effects).

`ClearDrawBuffer` / `ClearZBuffer` perform sub-rectangle clears without
a full `RenderStart` cycle.

---

## Known Limitations

1. **Single-window**: The overlay assumes a single SDL window. Multiple
   simultaneous RAVE viewports are not supported.

2. **iOS only**: The overlay uses `UIView` and `CAMetalLayer` APIs.
   macOS Catalyst support is present but untested.

3. **No stencil buffer**: RAVE 1.6 does not specify stencil operations
   and the engine does not allocate a stencil attachment.

4. **Texture size limits**: Maximum texture dimensions follow the host
   GPU's Metal limits (typically 8192×8192 or 16384×16384). No explicit
   cap is enforced.

5. **SheepMem pressure**: Although context addresses are recycled,
   TVECT allocation is permanent. The 53 TVECTs consume approximately
   3 KB of the 512 KB SheepMem region.

6. **Floating-point precision**: PPC single-precision floats are
   converted to host floats. On ARM64, this is a no-op for matching
   IEEE 754 formats, but denormal handling may differ.

7. **No anti-aliasing**: The RAVE specification's `kQATag_Antialias`
   tag is accepted but does not enable MSAA. The engine always renders
   at 1× sample count.
