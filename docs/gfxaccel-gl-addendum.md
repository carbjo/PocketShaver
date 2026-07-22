# Overview

4 games are tested with the gfxaccel GL backend: Descent II 6500, Mechwarrior II 6500, Myth II, and Diablo II. These are known issues in those games:

## Descent II 6500

- The intro movie has some opening stutter after the first frame. This is due to a QuickTime emulation bug.

-- Clarification: All mac versions of Descent and all other mac versions of Descent II use a custom mve file format for the movie, which is why they play ok. The 6500 version of Descent II still loads it from a MVL (HOG variant) file with an "intro.mve" filename, but the file is a cinepak encoded quicktime movie instead of the custom variant used by other versions of descent and is played directly with the QuickTime API with MoviesTask() waiting and such.

- There might be some minor occassional stuttering in game that is barely noticable

- You may notice there is no "suit-like" HUD interface in Descent II 6500. This is not a bug and the way the RAVE backend of Descent II renders - if you want this hud choose a non-RAVE version in the game's settings.

## MechWarrior II 6500

- There is some shimmering on ground textures mid-far from the player's POV

## Myth II

- The opening dialog only suggests 640x480

## Diablo II

- **Primary 3D path: Glide 3.0** (pref `glideaccel`, default on). **Identical model to DSpInstallHooks**:
  - Guest already has the Glide CFM extension (`3DfxGlideLib3.x` / etc. in Extensions). Host `3dfx GlideLib*.bin` files are for **offline analysis only** — never loaded into the emulator.
  - `GlideInstallHooks`: candidate `FindLibSymbol` for the library, resolve each export, 4-instruction PPC branch into native TVECTs (we **are** Glide; stock driver not run).
  - No `GetMemFragment`, no synthetic CFM connection, no Extensions install.

- RAVE: Currently unplayable due to slow/lagged framerate and frame skips once a character is chosen and is loads the main playable game

- OpenGL: Black Screen on main title

- Software: Crash on game launch

- Black screen on "Rescan Monitors" in configuration — fixed on GL by matching Metal `UpdatePalette` (ignore non-indexed) + DSp OnModeEnter NULL-buffer Resize without classic 8bpp wipe

- There are brief blue screens with artifacts after each opening movie

### GL ↔ Metal compositor parity (desktop)

Intentional GL deltas vs Metal are only where the API forces them (CPU expand vs GPU blit, shared GL context with RAVE/Glide). Behavioral contracts:

| API / path | Status |
|------------|--------|
| UpdatePalette non-indexed no-op | matched |
| OnModeEnter DSp BGRA+NULL / QD host restore | matched |
| OnModeExit clear overlay (+ GL framebuffer cache) | matched |
| Present skip classic upload for DSp | matched |
| Present classic dirty = full memcmp | matched (Metal always uploads) |
| SharedMetalDevice make-current only if needed | matched (fixed inverted `\|\|` short-circuit) |
| Deferred Present during RAVE FBO + flush on RenderEnd | GL-only (shared context) |
| Overlay dst in guest mode space | matched |
| kDMCOwnerGlide underlay upload | matched (like RAVE/GL) |