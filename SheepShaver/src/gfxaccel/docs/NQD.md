# NQD Engine — Metal Compute Acceleration for 2D Blitting

**Author:** Sierra Burkhart ([@sierra760](https://github.com/sierra760))

## Overview

The NQD (Not QuickDraw) engine accelerates SheepShaver's 2D drawing
operations using Metal compute shaders. When the emulated Mac OS
performs screen blitting, rectangle fills, or pixel inversions through
the NQD acceleration interface, this engine dispatches those operations
to the GPU instead of executing them on the CPU.

The key insight is that Mac RAM is already a contiguous host memory
region. By wrapping it as a shared `MTLBuffer`, the GPU can read and
write emulated framebuffer memory directly — no copy-in/copy-out
required. The compute shaders operate on byte offsets within this
shared buffer, performing the same pixel transformations that the CPU
blit loops would, but parallelized across GPU threads.

### Key Design Decisions

- **Shared MTLBuffer over Mac RAM**: Rather than copying framebuffer
  regions to GPU-private memory, the entire Mac RAM region is wrapped
  as a `MTLBuffer` with `MTLResourceStorageModeShared`. Source and
  destination addresses are passed as byte offsets. This eliminates
  all data transfer overhead for operations where source and destination
  are both in emulated RAM.

- **Compute shaders, not render pipeline**: 2D blitting is a data
  transformation problem, not a rendering problem. Compute shaders
  map naturally to the row×column parallelism of rectangular blit
  operations and avoid the overhead of configuring a render pass with
  vertex/fragment shaders, render targets, and viewport state.

- **Full QuickDraw transfer mode coverage**: The compute kernels
  implement all QuickDraw transfer modes: 8 Boolean modes (srcCopy,
  srcOr, srcXor, srcBic, notSrcCopy, notSrcOr, notSrcXor, notSrcBic),
  8 arithmetic modes (blend, addPin, addOver, subPin, transparent,
  addMax, subOver, addMin), and the hilite mode (selection highlighting).
  This ensures visual correctness for all classic Mac OS drawing.

- **Pattern fill support**: FillRect operations support both solid
  fills and 8×8 pattern fills. Pattern data is passed to the compute
  shader as uniforms, with per-pixel pattern lookup based on the
  destination coordinate modulo 8.

- **Mask-gated blitting**: Boolean transfer modes support optional mask
  buffers for operations like text rendering and icon compositing.
  The mask buffer is uploaded as a separate `MTLBuffer` and sampled
  per-pixel in the compute kernel.

---

## File Map

### NQD Engine Sources (2 files)

| File | Lines | Purpose |
|------|------:|---------|
| `nqd_metal_renderer.mm` | ~1090 | Metal device/queue/pipeline setup, RAM buffer wrapping, bitblt/fillrect/invrect dispatch, mask buffer management |
| `nqd_shaders.metal` | ~660 | Compute kernels for bitblt (all 17 transfer modes), fillrect (solid + pattern), and invrect |

### NQD Header (1 file)

| File | Purpose |
|------|---------|
| `include/nqd_accel.h` | C-callable interface: `NQDMetalInit()`, `NQDMetalBitBlt()`, `NQDMetalFillRect()`, `NQDMetalInvertRect()`, `NQDMetalCleanup()`, `nqd_metal_available` flag |

### Shared Infrastructure (used, not owned by NQD)

| File | Relationship |
|------|-------------|
| `include/accel_logging.h` | Conditional logging macros |
| `BasiliskII/src/SDL/video_sdl2.cpp` | Calls `NQDMetalCleanup()` in `VideoExit()`, exports `sdl_renderer` for coordinate mapping |
| `gfxaccel.cpp` | Calls `NQDMetalInit()` at initialization |

---

## Metal Compute Pipeline

### Initialization

`NQDMetalInit()` performs one-time setup:
1. Creates a `MTLDevice` and `MTLCommandQueue`
2. Loads the Metal shader library and creates compute pipeline states
   for the bitblt and fillrect kernels
3. Wraps the emulated Mac RAM as a shared `MTLBuffer` using
   `newBufferWithBytesNoCopy:length:options:deallocator:` — this gives
   the GPU direct access to the emulator's memory without copying
4. Sets `nqd_metal_available = true` to signal that acceleration is
   ready

### Bitblt Dispatch

`NQDMetalBitBlt()` handles rectangular pixel transfers:

1. Validates that source and destination addresses fall within the
   Metal-mapped RAM buffer
2. Computes byte offsets from the RAM base for source and destination
3. Fills a `NQDBitbltUniforms` struct with row bytes, dimensions,
   transfer mode, pixel depth, foreground/background pen colors, and
   hilite color
4. If a mask is present (for masked blits), allocates a temporary
   `MTLBuffer` and copies the mask data
5. Creates a compute command encoder, sets the pipeline state, binds
   the RAM buffer and uniforms, and dispatches a 2D threadgroup grid
   covering the blit rectangle
6. Commits the command buffer and optionally waits for completion

The threadgroup size is `(16, 16, 1)` — each thread processes one pixel.
The grid dimensions are `ceil(width_pixels / 16) × ceil(height / 16)`.

### FillRect Dispatch

`NQDMetalFillRect()` fills a rectangle with a solid color or pattern:

1. Validates the destination address
2. Fills a `NQDFillRectUniforms` struct with the fill color (converted
   to the target pixel depth), row bytes, dimensions, and transfer mode
3. For pattern fills, copies the 8×8 pattern data into a pattern buffer
4. Dispatches the fillrect compute kernel

### InvertRect Dispatch

`NQDMetalInvertRect()` inverts all pixels in a rectangle by XORing with
an all-ones mask. Uses the bitblt kernel with `notSrcCopy` transfer mode
where source equals destination.

### Cleanup

`NQDMetalCleanup()` releases all Metal resources:
- Pipeline states (ARC releases)
- Command queue
- RAM buffer (created with `noCopy`, so the underlying RAM is not freed)
- Device reference

Called from `VideoExit()` in `video_sdl2.cpp` during emulator shutdown.

---

## Compute Shader Architecture

### Bitblt Kernel (`nqd_bitblt`)

The kernel dispatches on `transfer_mode` to select the correct pixel
operation:

| Mode | Value | Operation |
|------|------:|-----------|
| srcCopy | 0 | `dst = src` |
| srcOr | 1 | `dst = dst \| src` |
| srcXor | 2 | `dst = dst ^ src` |
| srcBic | 3 | `dst = dst & ~src` |
| notSrcCopy | 4 | `dst = ~src` |
| notSrcOr | 5 | `dst = dst \| ~src` |
| notSrcXor | 6 | `dst = dst ^ ~src` |
| notSrcBic | 7 | `dst = dst & src` |
| blend | 32 | `dst = (src * weight + dst * (1 - weight))` |
| addPin | 33 | `dst = min(dst + src, max_val)` |
| addOver | 34 | `dst = (dst + src) & max_val` (wrapping) |
| subPin | 35 | `dst = max(dst - src, 0)` |
| transparent | 36 | `if (src != bg) dst = src` |
| addMax | 37 | `dst = max(dst, src)` |
| subOver | 38 | `dst = (dst - src) & max_val` (wrapping) |
| addMin | 39 | `dst = min(dst, src)` |
| hilite | 50 | Selection highlight swap |

Each mode operates at the pixel granularity determined by `pixel_size`
(1, 2, or 4 bytes). Arithmetic modes decompose pixels into channels
for per-component operations.

When `mask_enabled` is set, the kernel reads a mask byte per pixel and
applies the blit only where the mask is non-zero. This supports text
rendering and shaped transfers.

### FillRect Kernel (`nqd_fillrect`)

Simpler than bitblt: each thread writes the fill color to one pixel
position. For pattern fills, the color is looked up from an 8×8 pattern
buffer indexed by `(x % 8, y % 8)`.

Transfer mode support in fillrect mirrors bitblt: Boolean modes apply
the fill color with the specified logical operation against the existing
destination pixel.

### Packed Pixel Support

For pixel depths less than 8 bits (1, 2, or 4 bpp), the kernels handle
sub-byte pixel packing. The `bits_per_pixel` uniform tells the shader
how many pixels are packed into each byte, and bitwise masking ensures
only the target pixel within a byte is modified.

---

## Performance Characteristics

The primary performance benefit comes from eliminating CPU time spent
in blit loops. For a typical 640×480 full-screen blit at 32bpp:

- **CPU path**: ~1.2M pixel reads + writes, sequential
- **GPU path**: ~1.2M pixel reads + writes, parallelized across ~300K
  threads at 16×16 threadgroups

The shared buffer approach means zero copy overhead — the GPU operates
directly on the emulator's RAM. The main latency cost is command buffer
encoding and GPU scheduling, which is amortized across large blits.

Small operations (< 64 pixels) may be faster on CPU due to Metal
dispatch overhead. The caller in `gfxaccel.cpp` applies a size threshold
before routing to the Metal path.

---

## Known Limitations

1. **Shared memory coherence**: `MTLResourceStorageModeShared` provides
   coherent CPU/GPU access on Apple Silicon, but the emulator must not
   read destination pixels on CPU while a compute dispatch is in flight.
   In practice, SheepShaver's single-threaded emulation loop ensures
   sequential access.

2. **No VRAM acceleration**: Only operations where both source and
   destination fall within the Metal-mapped Mac RAM region are
   accelerated. Operations targeting memory outside this region (if any)
   fall back to CPU.

3. **Mask buffer allocation**: Each masked blit allocates a temporary
   `MTLBuffer` for the mask data. Frequent small masked blits (e.g.,
   rapid text drawing) incur allocation overhead. A pool allocator
   would improve this.

4. **Synchronous completion**: `NQDMetalBitBlt` waits for GPU completion
   before returning to ensure the destination pixels are visible to
   subsequent CPU reads. Asynchronous dispatch with fence-based
   synchronization would allow pipelining.

5. **8×8 pattern only**: Pattern fills support only the standard
   QuickDraw 8×8 pattern size. Larger pattern tiles are not handled.

6. **No clipping region support**: Operations are dispatched as full
   rectangles. Complex clipping regions (non-rectangular) are not
   decomposed — the caller is expected to provide pre-clipped rectangles.
