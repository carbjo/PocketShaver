/*
 *  joymanager.h - SDL-backed replacement for the classic .JoyManager driver
 */

#ifndef JOYMANAGER_H
#define JOYMANAGER_H

#include "sysdeps.h"

const uint16 JoyManagerDriverFlags = 0x4c00;

/* high level API for client JoyManagerXXX() */
extern uint32 JoyManagerGuestStorageSize(void);
extern bool JoyManagerPrepare(void);
extern bool JoyManagerSetGuestStorage(uint32 addr, uint32 size);
extern void JoyManagerReset(void);
extern void JoyManagerVBL(void);
extern int16 JoyManagerOpen(uint32 pb, uint32 dce);
extern int16 JoyManagerControl(uint32 pb, uint32 dce);
extern int16 JoyManagerStatus(uint32 pb, uint32 dce);
extern int16 JoyManagerClose(uint32 pb, uint32 dce);

/* low level API, typically for ADB joysticks */
typedef struct _SDL_Joystick JoyManagerDevice;
JoyManagerDevice *JoyManagerOpenDevice(int index);
void JoyManagerCloseDevice(JoyManagerDevice *joystick);
int JoyManagerNumDevices(void);
int JoyManagerNumButtons(JoyManagerDevice *joystick);
int JoyManagerNumAxes(JoyManagerDevice *joystick);
int JoyManagerNumHats(JoyManagerDevice *joystick);
bool JoyManagerInit(void);
int JoyManagerAxisLabel(int axis, bool rudder_throttle);
bool JoyManagerHasRudderThrottle(JoyManagerDevice *joystick);
bool JoyManagerDeviceAttached(JoyManagerDevice *joystick);
const char *JoyManagerDeviceName(JoyManagerDevice *joystick,
	int index);
int16 JoyManagerAxis(JoyManagerDevice *joystick, int axis);
uint8 JoyManagerButton(JoyManagerDevice *joystick, int button);
uint8 JoyManagerHat(JoyManagerDevice *joystick, int hat);
void JoyManagerUpdate(void);
/* 	if (up && right) return 5;
	if (up && left) return 6;
	if (down && right) return 7;
	if (down && left) return 8;
	if (up) return 1;
	if (down) return 2;
	if (right) return 3;
	if (left) return 4; */
int JoyManagerHatPosition(uint8 hat);
#endif
