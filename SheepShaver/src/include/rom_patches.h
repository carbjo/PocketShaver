/*
 *  rom_patches.h - ROM patches
 *
 *  SheepShaver (C) 1997-2008 Christian Bauer and Marc Hellwig
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#ifndef ROM_PATCHES_H
#define ROM_PATCHES_H

// ROM types
enum {
	ROMTYPE_TNT,
	ROMTYPE_ALCHEMY,
	ROMTYPE_ZANZIBAR,
	ROMTYPE_GAZELLE,
	ROMTYPE_GOSSAMER,
	ROMTYPE_NEWWORLD
};
extern int ROMType;

extern bool DecodeROM(uint8 *data, uint32 size);
extern bool PatchROM(void);
extern void InstallDrivers(void);

extern void AddSifter(uint32 type, int16 id);
extern bool FindSifter(uint32 type, int16 id);

extern uint32 find_rom_data(uint32 start, uint32 end, const uint8 *data, uint32 data_len);
extern uint32 find_rom_powerpc_branch(uint32 start, uint32 end, uint32 target);
extern uint32 rom_powerpc_branch_target(uint32 addr);
extern uint32 find_rom_resource(uint32 s_type, int16 s_id = 4711, bool cont = false);

// Shared ROM patch-space address for the DII _DisposHandle keep-alive head-patch
// thunk.  Placed INSIDE CHECK_LOAD_PATCH_SPACE's already-reserved 0x40 region
// (0x2fcf00..0x2fcf3f): the vCheckLoad thunk only uses its first 12 bytes, and that
// whole region is already validated free by check_rom_patch_space(CHECK_LOAD, 0x40)
// -- so no separate guard or free-space guess is needed.  The thunk receives the
// stock _DisposHandle entry from the EMUL_OP in register A1 (a host-side C++ global,
// RsrcLockDisposeOrig()); no guest-memory "original" pointer is stored because a
// runtime WriteMacInt32 into the ROM patch region does not stick.
const uint32 DISPOSE_NIFT_PATCH_SPACE = 0x2fcf10;	// 68k thunk (10 bytes), after vCheckLoad's 12

#endif
