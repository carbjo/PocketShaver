/*
 *  joymanager.h - SDL-backed replacement for the classic .JoyManager driver
 */

#ifndef JOYMANAGER_H
#define JOYMANAGER_H

#include "sysdeps.h"

const uint16 JoyManagerDriverFlags = 0x4c00;

/* The guest records and event ring live in one non-relocatable system block. */
extern uint32 JoyManagerGuestStorageSize(void);
extern bool JoyManagerPrepare(void);
extern bool JoyManagerSetGuestStorage(uint32 addr, uint32 size);
extern void JoyManagerReset(void);

extern void JoyManagerVBL(void);

extern int16 JoyManagerOpen(uint32 pb, uint32 dce);
extern int16 JoyManagerControl(uint32 pb, uint32 dce);
extern int16 JoyManagerStatus(uint32 pb, uint32 dce);
extern int16 JoyManagerClose(uint32 pb, uint32 dce);

#endif
