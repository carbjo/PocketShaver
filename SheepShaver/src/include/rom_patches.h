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

// ROM patch space for the DII _DisposHandle keep-alive head-patch thunk. It sits
// inside CHECK_LOAD_PATCH_SPACE's reserved 0x40 region (0x2fcf00..0x2fcf3f),
// already validated by check_rom_patch_space; vCheckLoad uses only its first 12
// bytes. The stock _DisposHandle entry comes back in A1 from the EMUL_OP
// (RsrcLockDisposeOrig()). It is not stored in guest memory because runtime
// writes into the ROM patch region do not stick.
const uint32 DISPOSE_NIFT_PATCH_SPACE = 0x2fcf10;	// 68k thunk (10 bytes), after vCheckLoad's 12

// Gestalt VM spoof: _Gestalt ($A1AD) head-patch thunk in the same CHECK_LOAD
// region, after the DisposeNIFT thunk (ends 0x2fcf19). 6 bytes: EMUL_OP +
// jmp (a1) + rts. The handler points A1 at the stock _Gestalt (chain) or at the
// rts at +4 (spoof, GestaltRtsStub()). The chain path clobbers only A1.
const uint32 GESTALT_VM_PATCH_SPACE = 0x2fcf20;		// 68k thunk (6 bytes; rts at +4)

#endif
