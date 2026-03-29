# PocketShaver

A fork of [SheepShaver](https://github.com/kanjitalk755/macemu) that brings Mac OS 9 emulation to iOS and iPad with Metal GPU acceleration, native Swift UI, LAN networking, and full touchscreen gamepad support.

PocketShaver extends the SheepShaver PowerPC emulation core with three Metal-accelerated graphics engines, a customizable on-screen gamepad, Bonjour peer-to-peer networking, and a modern preferences system that adapts to the running platform. The upstream BasiliskII (68k) and desktop SheepShaver targets are preserved alongside the iOS-specific additions.

## Features

### Metal GPU Acceleration

PocketShaver implements three graphics acceleration engines, all targeting Metal:

- **NQD (Native QuickDraw)** -- 2D acceleration via Metal compute shaders. Wraps emulated Mac RAM as a shared `MTLBuffer` for zero-copy GPU access. Covers all 16 QuickDraw transfer modes, pattern fills, and mask-gated blitting for text/icon rendering. Includes a CPU fast-path for small operations where Metal dispatch overhead would dominate.
- **RAVE (Rendering Acceleration Virtual Engine)** -- QuickDraw 3D acceleration implementing the full RAVE 1.6 API (53 PPC-callable methods). Supports Gouraud shading, texture mapping, fog, alpha testing, multi-texturing, mipmaps, 16 blend modes, and z-sorted transparency. Renders to a `CAMetalLayer` overlay composited on top of the 2D framebuffer.
- **OpenGL 1.2** -- Fixed-function pipeline with 643 PPC-callable entry points covering core GL, ARB extensions (multitexture, S3TC/DXT compression), AGL, GLU, and GLUT. Includes full matrix stacks, 8-light Phong lighting, fog, texture environments, and pipeline state caching.

A unified **Metal compositor** handles 2D/3D compositing, supporting all Mac OS video depths (1/2/4/8/16/32-bit), palette updates for indexed color modes, and VBL-synced frame pacing.

### On-Screen Gamepad

A fully customizable virtual gamepad overlay for touchscreen play:

- Per-button assignment to keyboard keys, mouse clicks, or joystick types (mouse, WASD, arrows, 8-way)
- Configurable button grid layout with left/right sides and four corner positions
- Multiple saved configurations with drag-to-reorder management
- Visibility options: both orientations, portrait-only, or landscape-only
- In-game editing mode for remapping buttons without leaving the emulator
- Example layouts included (arcade, FPS, RPG)

The gamepad is automatically hidden when running as "Designed for iPad" on macOS, where physical input devices are available.

### Touch Input

- **Two-finger steering** -- alternative multi-touch input with configurable second-finger click and swipe behavior
- **Relative mouse mode** -- manual, automatic, or always-on, with tap-to-click and hover offset options
- **Right-click** -- configurable via Control or Command key
- **Soft keyboard** -- iOS keyboard bridged to emulated Mac input with configurable screen offset (top, middle, bottom)
- **Haptic feedback** -- independent toggles for gestures, mouse clicks, and key presses

### Bonjour LAN Networking

Peer-to-peer networking between devices over local network:

- **Host mode** -- provides router functionality, shows connected clients
- **Client mode** -- discovers hosts via Bonjour, auto-join with persistent device tracking
- Device naming and renaming within the LAN
- Automatic reconnection after app suspension
- Alternative Slirp networking also available

### Preferences

A tabbed preferences interface with five sections:

| Tab | Contents |
|---|---|
| **General** | ROM picker, disk management (create/import/delete), audio toggle, input options, haptic feedback, hints |
| **Graphics** | Monitor resolutions, rendering filter (nearest/bilinear), frame rate (60/75/120 Hz), gamma ramp, NQD/RAVE/GL acceleration toggles |
| **Gamepad** | Configuration list, layout editor, reordering, example templates |
| **Network** | Slirp vs. Bonjour selection, host/client role, peer browsing, device naming |
| **Advanced** | RAM setting, performance metrics (FPS counter), UI options (landscape lock, always-on display), relative mouse settings, bootstrap/ROM info |

The UI adapts to the platform -- on "Designed for iPad" on macOS, the Gamepad tab is hidden and touch-specific hints are suppressed.

### Disk and ROM Management

- Create new virtual disks with configurable size
- Import external disk images
- Install and validate Mac OS ROM files with version detection
- Boot disk selection and CD boot support

### Performance Monitoring

- Optional FPS counter overlay
- Network transfer rate display
- Rendered in the in-game overlay without interrupting emulation

## Platform Support

| Platform | Status |
|---|---|
| iOS (iPhone/iPad) | Primary target -- full touch, gamepad, and GPU acceleration |
| "Designed for iPad" on macOS | Supported -- gamepad hidden, keyboard/mouse passthrough |

## Building

PocketShaver is built as an Xcode project:

```
SheepShaver/src/MacOSX/PocketShaver.xcodeproj
```

### BasiliskII

The repository also contains BasiliskII, a 68k Mac emulator. See the platform-specific build instructions below.

#### macOS

Requires SDL 2.0.14+ from https://www.libsdl.org, plus GMP and MPFR:

```sh
# GMP (https://gmplib.org)
tar xf gmp-6.2.1.tar.xz && cd gmp-6.2.1
./configure --disable-shared && make && make check && sudo make install

# MPFR (https://www.mpfr.org)
tar xf mpfr-4.2.0.tar.xz && cd mpfr-4.2.0
./configure --disable-shared && make && make check && sudo make install
```

On Intel Mac, cross-build for arm64:
```sh
CFLAGS="-arch arm64" CXXFLAGS="$CFLAGS" ./configure -host=aarch64-apple-darwin --disable-shared
```

```sh
cd BasiliskII/src/MacOSX
xcodebuild build -project BasiliskII.xcodeproj -configuration Release
```

#### Linux

```sh
cd BasiliskII/src/Unix
./autogen.sh && make
```

ARM64: install GMP and MPFR first.

#### MinGW32/MSYS2

```sh
pacman -S base-devel mingw-w64-i686-toolchain autoconf automake mingw-w64-i686-SDL2
cd BasiliskII/src/Windows
../Unix/autogen.sh && make
```

### SheepShaver (Desktop)

#### macOS

```sh
cd SheepShaver/src/MacOSX
xcodebuild build -project SheepShaver_Xcode8.xcodeproj -configuration Release
```

#### Linux

```sh
cd SheepShaver/src/Unix
./autogen.sh && make
```

#### MinGW32/MSYS2

```sh
cd SheepShaver && make links
cd src/Windows
../Unix/autogen.sh && make
```

## Upstream

Forked from [kanjitalk755/macemu](https://github.com/kanjitalk755/macemu) (SheepShaver / BasiliskII).
