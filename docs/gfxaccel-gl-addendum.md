# Overview

4 games are tested with the gfxaccel GL backend: Descent II 6500, Mechwarrior II 6500, Myth II, and Diablo II. These are known issues in those games:

## Descent II 6500

- The intro movie has some opening stutter after the first frame. This is due to a QuickTime emulation bug.

-- Clarification: All mac versions of Descent and all other mac versions of Descent II use a custom mve file format for the movie, which is why they play ok. The 6500 version of Descent II still loads it from a MVL (HOG variant) file with an "intro.mve" filename, but the file is a cinepak encoded quicktime movie instead of the custom variant used by other versions of descent and is played directly with the QuickTime API with MoviesTask() waiting and such.

- You may notice there is no "suit-like" HUD interface in Descent II 6500. This is not a bug and the way the RAVE backend of Descent II renders - if you want this hud choose a non-RAVE version in the game's settings.

## MechWarrior II 6500

- There is some shimmering on ground textures mid-far from the player's POV

## Myth II

- The opening dialog only suggests 640x480

## Diablo II

- For Glide (Diablo II is Glide 3.0) you need the Glide extensions (`3DfxGlideLib3.x` et al) in extensions from something like "3dfx Voodoo 5", and you need to manually install them from the CD. 

- There might be blue screens and/or artifacts in between opening movies

- Rare crashes when doing Rescan Monitors or switching between full screen and windowed when re-running the game
