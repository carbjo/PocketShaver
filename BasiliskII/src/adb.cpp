/*
 *  adb.cpp - ADB emulation (mouse/keyboard)
 *
 *  Basilisk II (C) Christian Bauer
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

/*
 *  SEE ALSO
 *    Inside Macintosh: Devices, chapter 5 "ADB Manager"
 *    Technote HW 01: "ADB - The Untold Story: Space Aliens Ate My Mouse"
 */

#include <stdlib.h>

#include "sysdeps.h"
#include "cpu_emulation.h"
#include "emul_op.h"
#include "main.h"
#include "prefs.h"
#include "video.h"
#include "adb.h"
#include "math.h"

#if TARGET_OS_IPHONE
#include "utils_ios.h"
#import "MouseHapticFeedbackObjCCppHeader.h"
#import "MiscellaneousSettingsObjCCppHeader.h"
#import "RightClickObjCCppHeader.h"
#include <unistd.h>
#endif

#ifdef POWERPC_ROM
#include "thunks.h"
#endif

#define DEBUG 0
#include "debug.h"

#include <cmath>
#include <ctime>

// Global variables
static int mouse_x = 0, mouse_y = 0;							// Mouse position
static int old_mouse_x = 0, old_mouse_y = 0;
static int last_mouse_down_delta_x = 0, last_mouse_down_delta_y = 0;
static bool mouse_button[3] = {false, false, false};			// Mouse button states
static bool old_mouse_button[3] = {false, false, false};
static bool relative_mouse = false;
static bool touch_input = false;
static int screen_middle_x = 0;
static int screen_width = 0, screen_height = 0;
static bool hover_mode = false;
static int offset_x = 0;
static int offset_y = 0;
static bool mouse_down = false;
static bool hover_gesture_start_side_determination_requested = false;
static bool hover_gesture_start_was_left_side = false;
static bool is_animating = false;
static bool is_hover_gesture_dragging = false;

static uint8 key_states[16];				// Key states (Mac keycodes)
#define MATRIX(code) (key_states[code >> 3] & (1 << (~code & 7)))

// Keyboard event buffer (Mac keycodes with up/down flag)
const int KEY_BUFFER_SIZE = 16;
static uint8 key_buffer[KEY_BUFFER_SIZE];
static unsigned int key_read_ptr = 0, key_write_ptr = 0;

// O2S: Button event buffer (Mac button with up/down flag) -> avoid to loose tap on a trackpad
const int BUTTON_BUFFER_SIZE = 32;
static uint8 button_buffer[BUTTON_BUFFER_SIZE];
static unsigned int button_read_ptr = 0, button_write_ptr = 0;

static uint8 mouse_reg_3[2] = {0x63, 0x01};	// Mouse ADB register 3

static uint8 key_reg_2[2] = {0xff, 0xff};	// Keyboard ADB register 2
static uint8 key_reg_3[2] = {0x62, 0x05};	// Keyboard ADB register 3
static uint8 m_keyboard_type = 0x05;

// ADB mouse motion lock (for platforms that use separate input thread)
static B2_mutex *mouse_lock;

static time_t latest_mouse_down_time;
static time_t relative_mouse_mode_off_time;

// tolernace used to determine wheather to move mouse or not during	potential double click event
static int double_click_mouse_move_tolerance = 10;

BeginAnimationState::BeginAnimationState(int inp_x, int inp_y) {
	x = inp_x;
	y = inp_y;
}

/*
	Joystick stuff. The confusing thing here is that Thrustmaster is enumerated
	via GetADBInfo(XXX, 1-15) while other joysticks are enumerated via
	GetADBInfo(XXX, GetIndADB(i)). This is problematic for Thrustmaster
	because ADB addresses are assigned dynamically.
*/
#ifdef USE_SDL
#include "joymanager.h"
/* Have to copy this block because ether_defs.h is SheepShaver-only
* and slirp.h brings in too much */
#if __MWERKS__ && __POWERPC__
#define PRAGMA_ALIGN_SUPPORTED 1
#define PACKED__
#elif defined __GNUC__
#define PACKED__ __attribute__ ((packed))
#elif defined _MSC_VER
#define PRAGMA_PACK_SUPPORTED 1
#define PACKED__
#elif defined __sgi
#define PRAGMA_PACK_SUPPORTED 1
#define PACKED__
#else
#error "Packed attribute or pragma shall be supported"
#endif

/*
 * Gravis Firebird / MouseStick II -- ADB driver private data area.
 */
#define ADBGRAVISFIREBIRD_SIGNATURE  0x6D464244   /* 'mFBD' */
#ifdef PRAGMA_ALIGN_SUPPORTED
#pragma options align=mac68k
#endif
#ifdef PRAGMA_PACK_SUPPORTED
#pragma pack(2)
#endif
typedef struct ADBGRAVISFIREBIRD {
	/* 0x000 */ char   mUnknown1[0xE6];    /* 230 bytes                  */
	/* 0x0E6 */ long   mSignature;         /* 'mFBD' (0x6D464244)        */
	/* 0x0EA */ char   mUnknown2[0xDA];    /* 218 bytes                  */
	/* 0x1C4 */ short  mXIn;
		/* Absolute stick position, left/right. Signed. This is the physical
		 * stick angle, not a cursor coordinate. Descent II stores it verbatim 
		 * and works out the usable range from the player's calibration pass, 
		 * so the driver's units never have to be known. */

	/* 0x1C6 */ short  mYIn;
		/* Absolute stick position, fore/aft. Signed. Not negated by Descent II
		 * -- whichever way this grows, the calibration pass absorbs it. */

	/* 0x1C8 */ short  mUnusedAxis;
		/* Sits exactly where a third axis belongs, between Y and the throttle.
		 * Descent II skips it: it publishes no rudder channel for this device. 
		 * Most likely an axis the Firebird has and Descent 
		 * chose not to use. */

	/* 0x1CA */ short  mThrottle;
		/* Throttle / slider. Signed, read the same way as the two stick axes
		 * and, like them, left completely unscaled. */

	/* 0x1CC */ short  mUnknown3;          /* never read */

	/* 0x1CE */ long   mButtons;
		/* All 17 controls in one word, one bit each, bit N = control N in the
		 * table in section 6.5.
		 *
		 * THE BITS ARE INVERTED: a bit reading 0 means that control is 
		 * currently HELD DOWN; 1 means it is up. With nothing pressed the
		 * low 17 bits are all set, i.e. the word reads 0x0001FFFF. Pressing
		 * the trigger (bit 0) makes it 0x0001FFFE.
		 *
		 * Not 4-byte aligned -- read it with a byte-safe load or a memcpy on 
		 * architectures that care.
		 *
		 * Descent II consumes bits 0..16 and ignores 17..31. */

	/* 0x1D2 */ char   mUnknown4[0x0E];    /* 14 bytes, never touched */

	/* 0x1E0 */ char   mEmulationEnable[3];
		/* Three on/off switches controlling whether the Gravis driver
		 * keeps doing its normal desktop job -- translating this stick 
		 * into mouse pointer movement, mouse clicks and keystrokes.
		 *
		 * write 0 to all three : hands off. The driver stops generating 
		 *	events; the application reads 
		 *	mXIn / mYIn / mThrottle / mButtons
		 *	itself. Descent II does this the moment it adopts the device.
		 * write 1 to all three : normal behaviour resumes. Descent II 
		 *	does this when
		 *	the player picks a different joystick, and on quit.
		 *
		 * Descent II always writes all three together with the same value 
		 * and never reads them, so which switch covers which group 
		 * (stick / buttons / hat) is not determined here. These are the 
		 * Firebird's equivalent of mStick1_cursorCouple in
		 * the older 'Jeff' layout. */

	/* 0x1E3 */ char   mUnknown5[0x1E5];   /* 485 bytes, never touched */
} PACKED__ ADBGRAVISFIREBIRD;
typedef struct ADBTHRUSTMASTER {
	/* 0x00 */ char           roll; /* extsb, -127 (left) +127 (right) */
	/* 0x01 */ char           pitch; /* extsb, -127 (fwd/down) +127 (back)  */
	/* 0x02 */ unsigned char  thrust; /* lbz,   0 (back) 255 (fwd)    */
	/* 0x03 */ char           yaw;     /* extsb, -127 (left) +127 (right) */

	/* 0x04  ONE 16-bit storage unit, read with lhz, MSB-first: */
	union 
	{
		struct 
		{
			short rockerDown :1;   /* bit 15 -> Descent II button 15 "Rkr D" */
			short rockerUp   :1;   /* bit 14 -> 14 "Rkr U" */
			short button1    :1;   /* bit 13 -> 13 "Btn 1" */
			short button2    :1;   /* bit 12 -> 12 "Btn 2" */
			short button3    :1;   /* bit 11 -> 11 "Btn 3" */
			short button5    :1;   /* bit 10 -> 10 "Btn 5" */
			short button6    :1;   /* bit  9 ->  9 "Btn 6" */
			short button4    :1;   /* bit  8 ->  8 "Btn 4" */
			short pinkey     :1;   /* bit  7 ->  7 "Pinky" */
			short thumbLow   :1;   /* bit  6 ->  6 "Thb L" */
			short trigger    :1;   /* bit  5 ->  5 "Trig"  */
			short thumbHigh  :1;   /* bit  4 ->  4 "Thb H" */
			short hatLeft    :1;   /* bit  3 ->  3 "Hat L" */
			short hatRight   :1;   /* bit  2 ->  2 "Hat R" */
			short hatDown    :1;   /* bit  1 ->  1 "Hat D" */
			short hatUp      :1;   /* bit  0 ->  0 "Hat U" */
		} bitmasks;
		short fullvalue;
	} buttons;
		/* Bit sense is the NORMAL one here: 1 means the control is 
		 * currently held down, 0 means it is up, so an untouched stick 
		 * reads 0x0000. Descent II uses each bit directly with no inversion.
		 * This is the opposite of both Gravis devices, whose drivers publish
		 * button bits inverted (0 = held) and which Descent II therefore
		 * has to flip on the way in. */

	/* 0x06 */ char  reserveByte1;      /* never touched */
	/* 0x07 */ char  reserveByte2;      /* never touched */
	/* 0x08 */ char  version;           /* never read */
	/* 0x09 */ char  notNew;            /* never touched */
	/* 0x0A */ char  throttleAttached;  /* gates axis[3] */
	/* 0x0B */ char  rudderAttached;    /* gates axis[2] */
	/* 0x0C */ char  mouseDefeated;     /* never touched */
	/* 0x0D */                          /* 1 byte pad */
	/* 0x0E */ long  dontTouch;         /* never touched */
	/* 0x12 */ long  fini;              /* never touched */
} PACKED__ ADBTHRUSTMASTER;                   /* sizeof == 0x16 == 22 */
#ifdef PRAGMA_PACK_SUPPORTED
#pragma pack()
#endif
#ifdef PRAGMA_ALIGN_SUPPORTED
#pragma options align=reset
#endif
#define JOY_ADB_MAX 8 /* 4 * 2 == one gravis and thrustmaster for each
	real joystick */
#define JOY_ADB_FIRST 4
/* Gravis MouseStick II first appears as origADBAddr/devType 0x3/0x1
* then the GetIndADB addr for origADBAddr and 0x23 for devType. */
#define JOY_GRAVISMOUSESTICKII_ORIGADBADDR 0x3
#define JOY_GRAVISMOUSESTICKII_ORIGDEVTYPE 0x1
#define JOY_GRAVISMOUSESTICKII_DEVTYPE 0x23
#define JOY_THRUSTMASTER_VERSION 11 /* "version" member of struct */
#define JOY_THRUSTMASTER_ADBADDR 7 /* ADB address issued by Apple */
#define JOY_THRUSTMASTER_DEVTYPE 0x5F /* ADB handler ID issued by Apple */
#define JOY_THRUSTMASTER_MAXCOUNT 15 /* Max ADB database ID possible */

struct joy_adb_dev {
	uint8 reg_3[2]; /* [0] flags|CURRENT addr. [1] devType - handler ID. */
	uint8 orig_addr; /* origADBAddr */
	uint8 real_devtype; /* client can rewrite reg_3[1]; store real type */
	JoyManagerDevice* dev; 
	uint32 data_area; /* GetADBInfo() first param fill */
};
static joy_adb_dev joy_adb_devs[JOY_ADB_MAX];
static int joy_adb_count = 0; 
static bool joy_adb_installed = false;
static uint32 joy_adb_sib = 0; /* 8-byte ADBSetInfoBlock, allocated once */
static uint32 joy_adb_service_rt = 0; /* non-NULL */
void joy_adb_init(void)
{
	int i, idevindex;
	JoyManagerInit();
	joy_adb_count = JoyManagerNumDevices() * 2;
	if (joy_adb_count > JOY_ADB_MAX)
			joy_adb_count = JOY_ADB_MAX;
	for (i = 0, idevindex = 0; i < joy_adb_count; ++idevindex) {
		JoyManagerDevice* dev = JoyManagerOpenDevice(idevindex);
		if(dev == NULL) {
			joy_adb_count -= 2;
			continue;
		}
		joy_adb_devs[i].orig_addr = JOY_GRAVISMOUSESTICKII_ORIGADBADDR;
		joy_adb_devs[i].reg_3[0] = 0x60 | joy_adb_devs[i].orig_addr;
		joy_adb_devs[i].dev = dev;
		joy_adb_devs[i].real_devtype = JOY_GRAVISMOUSESTICKII_DEVTYPE;
		joy_adb_devs[i].reg_3[1] = JOY_GRAVISMOUSESTICKII_DEVTYPE;
		joy_adb_devs[i].data_area = 0;
		++i;
		joy_adb_devs[i].orig_addr = JOY_THRUSTMASTER_ADBADDR;
		joy_adb_devs[i].reg_3[0] = 0x60 | joy_adb_devs[i].orig_addr;
		joy_adb_devs[i].dev = dev;
		joy_adb_devs[i].real_devtype = JOY_THRUSTMASTER_DEVTYPE;
		joy_adb_devs[i].reg_3[1] = JOY_THRUSTMASTER_DEVTYPE;
		joy_adb_devs[i].data_area = 0;
		++i;
	}
}
void joy_adb_exit(void)
{
	int i, numdevs;
	numdevs = joy_adb_count; 
	joy_adb_count = 0;
	for (i = 0; i < numdevs; i += 2)
		JoyManagerCloseDevice(joy_adb_devs[i].dev);
	joy_adb_installed = false;
}
void joy_adb_reset_addr(void)
{
	int i;
	for (i = 0; i < joy_adb_count; ++i) {
		joy_adb_devs[i].reg_3[0] = 0x60 | joy_adb_devs[i].orig_addr;
	}
}
bool joy_adb_scan_done(void)
{
	M68kRegisters r;
	Execute68kTrap(0xa077, &r); /* CountADBs() */
	return (bool)(int16)r.d[0] >= 2 + joy_adb_count;
}
int joy_adb_find(uint8 adr)
{
	int i;
	for (i = 0; i < joy_adb_count; i++) { 
		if (adr == (joy_adb_devs[i].reg_3[0] & 0x0f)) {
			return i;
		}
	}
	return -1;
}
uint8 joy_adb_pack(int i, uint8 *buf)
{ /* fill up to 8 bytes of buf, return filled # of bytes */
	return 0;
}
void joy_adb_install(void)
{
	M68kRegisters r;
	int i;

	if (joy_adb_service_rt == 0) {
		r.d[0] = 2;
		Execute68kTrap(0xa71e, &r); /* NewPtrSysClear() */
		if (r.a[0] == 0) {
			joy_adb_installed = false;
			return;
		}
		joy_adb_service_rt = r.a[0];
		WriteMacInt16(joy_adb_service_rt, M68K_RTS);
	}
	if (joy_adb_sib == 0) {
		r.d[0] = 8;
		Execute68kTrap(0xa71e, &r); /* NewPtrSysClear() */
		if (r.a[0] == 0) {
			joy_adb_installed = false;
			return;
		}
		joy_adb_sib = r.a[0];
	}

	for (i = 0; i < joy_adb_count; i++) {
		if (joy_adb_devs[i].data_area == 0) {
			if(joy_adb_devs[i].real_devtype == JOY_THRUSTMASTER_DEVTYPE)
				r.d[0] = sizeof(ADBTHRUSTMASTER);
			else
				r.d[0] = sizeof(ADBGRAVISFIREBIRD);
			Execute68kTrap(0xa71e, &r); /* NewPtrSysClear() */
			if (r.a[0] == 0) {
				joy_adb_installed = false;
				return;
			}
			joy_adb_devs[i].data_area = r.a[0];
			if(joy_adb_devs[i].real_devtype == JOY_THRUSTMASTER_DEVTYPE)
				WriteMacInt8(joy_adb_devs[i].data_area +
					offsetof(ADBTHRUSTMASTER, version),
					JOY_THRUSTMASTER_VERSION);
			else
				WriteMacInt32(joy_adb_devs[i].data_area +
					offsetof(ADBGRAVISFIREBIRD, mSignature),
					ADBGRAVISFIREBIRD_SIGNATURE);
		}
		/* dbServiceRtPtr */
		WriteMacInt32(joy_adb_sib + 0, joy_adb_service_rt);     
		/* dbDataAreaAddr */
		WriteMacInt32(joy_adb_sib + 4, joy_adb_devs[i].data_area);   
		r.a[0] = joy_adb_sib;
		r.d[0] = joy_adb_devs[i].reg_3[0] & 0x0f; /* current ADB address */
		Execute68kTrap(0xa07a, &r); /* SetADBInfo() */
	}
	joy_adb_installed = true;
}
static int8 joy_adb_axis_s8(JoyManagerDevice *dev, int axis)
{
	int v = (JoyManagerAxis(dev, axis) * 127) / 32767;
	if (v > 127)
		v = 127;
	else if (v < -127)
		v = -127;
	return (int8)v;
}
static uint8 joy_adb_axis_u8(JoyManagerDevice *dev, int axis)
{
	int v = (JoyManagerAxis(dev, axis) + 32768) >> 8;
	if (v > 255)
		v = 255;
	return (uint8)v;
}
static const uint8 joy_adb_thrustmaster_button_bit[16] = {
	5, /* trigger   */ 4, /* thumbHigh */ 6, /* thumbLow */ 7, /* pinkey */
	13, 12, 11, 8, 10, 9,   /* button 1,2,3,4,5,6 */
	14, 15, /* rockerUp, rockerDown */
	0, 1, 2, 3 /* hatUp, hatDown, hatRight, hatLeft */
};
void joy_adb_update(void)
{
	int i, ibutton;
	/* JoyManagerUpdate(); -> Called from emul_op.cpp */
	for (i = 0; i < joy_adb_count; i++) {
		uint32 macval;
		int numaxes, numbuttons;
		uint32 p = joy_adb_devs[i].data_area;
		numaxes = JoyManagerNumAxes(joy_adb_devs[i].dev);
		numbuttons = JoyManagerNumButtons(joy_adb_devs[i].dev);
		if(joy_adb_devs[i].real_devtype == JOY_THRUSTMASTER_DEVTYPE) {
			macval = 0;
			if(numbuttons > 16)
				numbuttons = 16;
			for(ibutton = 0; ibutton < numbuttons; ++ibutton) {
				if(JoyManagerButton(joy_adb_devs[i].dev, ibutton)) {
					macval |= (uint16)(1u 
						<< joy_adb_thrustmaster_button_bit[ibutton]);
				}
			}
			WriteMacInt16(p + offsetof(ADBTHRUSTMASTER, buttons), 
				macval);
			if(numaxes >= 4)
				macval = 1;
			else
				macval = 0;
			WriteMacInt8(p + offsetof(ADBTHRUSTMASTER, throttleAttached), 
				macval);
			if(numaxes >= 3)
				macval = 1;
			else
				macval = 0;
			WriteMacInt8(p + offsetof(ADBTHRUSTMASTER, rudderAttached), 
				macval);
			if(numaxes >= 1) {
				macval = joy_adb_axis_s8(joy_adb_devs[i].dev, 0);
				WriteMacInt8(p + offsetof(ADBTHRUSTMASTER, roll), macval);
			}
			if(numaxes >= 2) {
				macval =  joy_adb_axis_s8(joy_adb_devs[i].dev, 1);
				WriteMacInt8(p + offsetof(ADBTHRUSTMASTER, pitch), macval);
			}
			if(numaxes >= 3) {
				macval = joy_adb_axis_s8(joy_adb_devs[i].dev, 2);
				WriteMacInt8(p + offsetof(ADBTHRUSTMASTER, yaw), macval);
			}
			if(numaxes >= 4) {
				macval = joy_adb_axis_u8(joy_adb_devs[i].dev, 3);
				WriteMacInt8(p + offsetof(ADBTHRUSTMASTER, thrust), macval);
			}
		} else {
			if(numbuttons > 17)
				numbuttons = 17;
			macval = 0x0001FFFFU; /* set all 17 to 1, i.e. not pressed */
			for(ibutton = 0; ibutton < numbuttons; ++ibutton) {
				if(JoyManagerButton(joy_adb_devs[i].dev, ibutton)) {
					macval &= ~(1u << ibutton);  /* 0 = held */
				}
			}
			WriteMacInt32(p + offsetof(ADBGRAVISFIREBIRD, mButtons), macval);
			if(numaxes >= 1) {
				macval = (uint16)JoyManagerAxis(joy_adb_devs[i].dev, 0);
				WriteMacInt16(p + offsetof(ADBGRAVISFIREBIRD, mXIn), macval);
			}
			if(numaxes >= 2) {
				macval = (uint16)JoyManagerAxis(joy_adb_devs[i].dev, 1);
				WriteMacInt16(p + offsetof(ADBGRAVISFIREBIRD, mYIn), macval);
			}
			if(numaxes >= 3) {
				macval = (uint16)JoyManagerAxis(joy_adb_devs[i].dev, 2);
				WriteMacInt16(p + offsetof(ADBGRAVISFIREBIRD, mThrottle), 
					macval);
			}
		}
	}
}
#else /* !USE_SDL */
static void joy_adb_init(void) {}
static void joy_adb_exit(void) {}
static void joy_adb_update(void) {}
static void joy_adb_install(void) {}
static void joy_adb_reset_addr(void) {}
static bool joy_adb_scan_done(void) { return false; }
static int  joy_adb_find(uint8 adr) { (void)adr; return -1; }
static bool joy_adb_installed = true;
#endif /* #ifdef USE_SDL */

/*
 *  Initialize ADB emulation
 */

void ADBInit(void)
{
	mouse_lock = B2_create_mutex();
	m_keyboard_type = (uint8)PrefsFindInt32("keyboardtype");
	key_reg_3[1] = m_keyboard_type;
	joy_adb_init();
}


/*
 *  Exit ADB emulation
 */

void ADBExit(void)
{
	if (mouse_lock) {
		B2_delete_mutex(mouse_lock);
		mouse_lock = NULL;
	}
	joy_adb_exit();
}


/*
 *  ADBOp() replacement
 */

void ADBOp(uint8 op, uint8 *data)
{
	D(bug("ADBOp op %02x, data %02x %02x %02x\n", op, data[0], data[1], data[2]));

	// ADB reset?
	if ((op & 0x0f) == 0) {
		mouse_reg_3[0] = 0x63;
		mouse_reg_3[1] = 0x01;
		key_reg_2[0] = 0xff;
		key_reg_2[1] = 0xff;
		key_reg_3[0] = 0x62;
		key_reg_3[1] = m_keyboard_type;
		joy_adb_reset_addr();
		joy_adb_installed = false;
		return;
	}

	// Cut op into fields
	uint8 adr = op >> 4;
	uint8 cmd = (op >> 2) & 3;
	uint8 reg = op & 3;

	// Check which device was addressed and act accordingly
	if (adr == (mouse_reg_3[0] & 0x0f)) {

		// Mouse
		if (cmd == 2) {

			// Listen
			switch (reg) {
				case 3:		// Address/HandlerID
					if (data[2] == 0xfe)			// Change address
						mouse_reg_3[0] = (mouse_reg_3[0] & 0xf0) | (data[1] & 0x0f);
					else if (data[2] == 1 || data[2] == 2 || data[2] == 4)	// Change device handler ID
						mouse_reg_3[1] = data[2];
					else if (data[2] == 0x00)		// Change address and enable bit
						mouse_reg_3[0] = (mouse_reg_3[0] & 0xd0) | (data[1] & 0x2f);
					break;
			}

		} else if (cmd == 3) {

			// Talk
			switch (reg) {
				case 1:		// Extended mouse protocol
					data[0] = 8;
					data[1] = 'a';				// Identifier
					data[2] = 'p';
					data[3] = 'p';
					data[4] = 'l';
					data[5] = 300 >> 8;			// Resolution (dpi)
					data[6] = 300 & 0xff;
					data[7] = 1;				// Class (mouse)
					data[8] = 3;				// Number of buttons
					break;
				case 3:		// Address/HandlerID
					data[0] = 2;
					data[1] = (mouse_reg_3[0] & 0xf0) | (rand() & 0x0f);
					data[2] = mouse_reg_3[1];
					break;
				default:
					data[0] = 0;
					break;
			}

			if (reg == 2) {
				// Relative position device registered in this video mode.
				// See 5-12 in Inside Macintosh: Devices, chapter 5 "ADB Manager".
			#if TARGET_OS_IPHONE
				report_relative_mouse_capability(); // video_sdl2
				objc_reportRelativeMouseModeCapability(); // Obj-C layer
			#endif
			}
		}
		D(bug(" mouse reg 3 %02x%02x\n", mouse_reg_3[0], mouse_reg_3[1]));

	} else if (adr == (key_reg_3[0] & 0x0f)) {

		// Keyboard
		if (cmd == 2) {

			// Listen
			switch (reg) {
				case 2:		// LEDs/Modifiers
					key_reg_2[0] = data[1];
					key_reg_2[1] = data[2];
					break;
				case 3:		// Address/HandlerID
					if (data[2] == 0xfe)			// Change address
							key_reg_3[0] = (key_reg_3[0] & 0xf0) | (data[1] & 0x0f);
					else if (data[2] == 0x00)		// Change address and enable bit
						key_reg_3[0] = (key_reg_3[0] & 0xd0) | (data[1] & 0x2f);
					break;
			}

		} else if (cmd == 3) {

			// Talk
			switch (reg) {
				case 2: {	// LEDs/Modifiers
					uint8 reg2hi = 0xff;
					uint8 reg2lo = key_reg_2[1] | 0xf8;
					if (MATRIX(0x6b))	// Scroll Lock
						reg2lo &= ~0x40;
					if (MATRIX(0x47))	// Num Lock
						reg2lo &= ~0x80;
					if (MATRIX(0x37))	// Command
						reg2hi &= ~0x01;
					if (MATRIX(0x3a))	// Option
						reg2hi &= ~0x02;
					if (MATRIX(0x38))	// Shift
						reg2hi &= ~0x04;
					if (MATRIX(0x36))	// Control
						reg2hi &= ~0x08;
					if (MATRIX(0x39))	// Caps Lock
						reg2hi &= ~0x20;
					if (MATRIX(0x75))	// Delete
						reg2hi &= ~0x40;
					data[0] = 2;
					data[1] = reg2hi;
					data[2] = reg2lo;
					break;
				}
				case 3:		// Address/HandlerID
					data[0] = 2;
					data[1] = (key_reg_3[0] & 0xf0) | (rand() & 0x0f);
					data[2] = key_reg_3[1];
					break;
				default:
					data[0] = 0;
					break;
			}
		}
		D(bug(" keyboard reg 3 %02x%02x\n", key_reg_3[0], key_reg_3[1]));

	} else {
		#ifdef USE_SDL 
		int i = joy_adb_find(adr);

		if (i < 0) {
		#endif /* #ifdef USE_SDL */
			if (cmd == 3)
				data[0] = 0; /* nothing at this address */
		#ifdef USE_SDL
		} else if (cmd == 2) { /* Write */
			if (reg == 3) {
				if (data[2] == 0xfe)
					joy_adb_devs[i].reg_3[0] =
						(joy_adb_devs[i].reg_3[0] & 0xf0) | (data[1] & 0x0f);
				else if (data[2] == 0x00)
					joy_adb_devs[i].reg_3[0] =
						(joy_adb_devs[i].reg_3[0] & 0xd0) | (data[1] & 0x2f);
				else if (data[2] == JOY_GRAVISMOUSESTICKII_ORIGDEVTYPE
						|| data[2] == JOY_GRAVISMOUSESTICKII_DEVTYPE
						|| data[2] == JOY_THRUSTMASTER_DEVTYPE)
					joy_adb_devs[i].reg_3[1] = data[2];
			}
		} else if (cmd == 3) { /* Read */
			switch (reg) {
				case 3: /* direct read */                
					data[0] = 2;
					data[1] = (joy_adb_devs[i].reg_3[0] 
						& 0xf0) | (rand() & 0x0f);
					data[2] = joy_adb_devs[i].reg_3[1];
					break;
				case 0: /* poll */
					data[0] = joy_adb_pack(i, data + 1);
					break;
				default:
					data[0] = 0;
					break;
			}
		}
		#endif /* #ifdef USE_SDL */
	}
}

int getXOffset(int x) {
	if (!touch_input) {
		return 0;
	}
	if (hover_gesture_start_was_left_side) {
		return offset_x;
	}

	return -offset_x;
}

int getYOffset()
{
	if (!touch_input) {
		return 0;
	}
	return offset_y;
}


/*
 *  Mouse was moved (x/y are absolute or relative, depending on ADBSetRelMouseMode())
 */

void ADBMouseMoved(int x, int y)
{
	if (is_animating) {
		return;
	}

	B2_lock_mutex(mouse_lock);
	if (relative_mouse) {
		mouse_x += x; mouse_y += y;
		last_mouse_down_delta_x += x; last_mouse_down_delta_y += y;
	} else {
		if (touch_input &&
			!mouse_down &&
			!hover_mode &&
			abs(mouse_x - x) <= double_click_mouse_move_tolerance &&
			abs(mouse_y - y) <= double_click_mouse_move_tolerance) {
			time_t now;
			time(&now);
			if (difftime(now, latest_mouse_down_time) < 1) {
				// Avoid very small mouse movements with touch input, since they are
				// usually unintentional and prevents proper double-click functionality
				B2_unlock_mutex(mouse_lock);
				return;
			}
		}

		bool wasLargeHorizontalJump = abs(x + getXOffset(x) - mouse_x) > 240;

		if (hover_gesture_start_side_determination_requested || wasLargeHorizontalJump) {
			if (hover_gesture_start_side_determination_requested) {
				hover_gesture_start_side_determination_requested = false;
			}

			hover_gesture_start_was_left_side = (x < screen_middle_x);
		}

		mouse_x = x + getXOffset(x); mouse_y = y + getYOffset();

		// The incoming point is unclamped (the hover steering forwarder keeps
		// feeding positions while the finger travels the letterbox bars) and
		// the hover offset can push past the guest edges either way — pin the
		// final cursor position to the screen, not the finger position.
		if (screen_width > 0 && screen_height > 0) {
			if (mouse_x < 0) mouse_x = 0;
			else if (mouse_x >= screen_width) mouse_x = screen_width - 1;
			if (mouse_y < 0) mouse_y = 0;
			else if (mouse_y >= screen_height) mouse_y = screen_height - 1;
		}
	}
	B2_unlock_mutex(mouse_lock);
	SetInterruptFlag(INTFLAG_ADB);
	TriggerInterrupt();
}

void ADBMouseClick(int button) {
	button_buffer[button_write_ptr] = button;
	button_write_ptr = (button_write_ptr + 1) % BUTTON_BUFFER_SIZE;
	SetInterruptFlag(INTFLAG_ADB);
	TriggerInterrupt();

	Delay_usec(20000);

	button_buffer[button_write_ptr] = button | 0x80;
	button_write_ptr = (button_write_ptr + 1) % BUTTON_BUFFER_SIZE;
	SetInterruptFlag(INTFLAG_ADB);
	TriggerInterrupt();
}

void ADBWriteMouseDown(int button) {
	// O2S: Add button to buffer
	button_buffer[button_write_ptr] = button;
	button_write_ptr = (button_write_ptr + 1) % BUTTON_BUFFER_SIZE;

	// O2S: mouse_button[button] = true;
	SetInterruptFlag(INTFLAG_ADB);
	TriggerInterrupt();
}



/*
 *  Mouse button pressed
 */

void ADBMouseDown(int button)
{
	if (is_hover_gesture_dragging) {
		return;
	}

	if (button != 0) {
		return;
	}

	if (touch_input && hover_mode) {
		hover_gesture_start_side_determination_requested = true;
		return;
	}

	#if TARGET_OS_IPHONE
	if (!relative_mouse || objc_getRelativeMouseTapToClick())
		objc_mousedownHapticFeedback();
	#endif

	if (touch_input)
		Delay_usec(20000); // To eliminate the simultanious "move mouse and click" race condition

	if (touch_input && relative_mouse) {
		last_mouse_down_delta_x = last_mouse_down_delta_y = 0;
	} else {
		ADBWriteMouseDown(button);
	}

	mouse_down = true;

	time(&latest_mouse_down_time);
}

void ADBWriteMouseUp(int button) {
	// O2S: Add button to buffer
	button_buffer[button_write_ptr] = button | 0x80;
	button_write_ptr = (button_write_ptr + 1) % BUTTON_BUFFER_SIZE;

	// O2S: mouse_button[button] = false;
	SetInterruptFlag(INTFLAG_ADB);
	TriggerInterrupt();

	mouse_down = false;
}


/*
 *  Mouse button released
 */

void ADBMouseUp(int button)
{
	if (is_hover_gesture_dragging) {
		return;
	}

	#if TARGET_OS_IPHONE
	if (button != 0) {
		objc_performRightClick();
		return;
	}
	#endif

	if (touch_input)
		Delay_usec(20000); // To eliminate the simultanious "move mouse and click" race condition

	#if TARGET_OS_IPHONE
	if (touch_input && relative_mouse) {
		time_t now;
		time(&now);

		if (last_mouse_down_delta_x < double_click_mouse_move_tolerance &&
			last_mouse_down_delta_y < double_click_mouse_move_tolerance &&
			difftime(now, latest_mouse_down_time) < 1) {
			if (objc_getRelativeMouseTapToClick()) {
				ADBMouseClick(button);
			} else {
				ADBWriteMouseUp(button);
			}

		}

	} else
	#endif
	{
		ADBWriteMouseUp(button);
	}

	mouse_down = false;
}

void ADBConfigure(int new_screen_width, int new_screen_height, int new_double_click_mouse_move_tolerance) {
	screen_width = new_screen_width;
	screen_height = new_screen_height;
	screen_middle_x = new_screen_width / 2;
	double_click_mouse_move_tolerance = new_double_click_mouse_move_tolerance;
}

/*
 *  Set mouse mode (absolute or relative)
 */

void ADBSetRelMouseMode(bool relative)
{
	if (relative_mouse != relative) {
		relative_mouse = relative;
		/* Relative mode accumulates from zero. Absolute: keep mouse_* and
		 * old_mouse_* equal so ADBInterrupt does not MoveTo until the next
		 * real ADBMouseMoved (avoids a spurious MoveTo(0,0) then jump). */
		mouse_x = mouse_y = 0;
		old_mouse_x = old_mouse_y = 0;
	}
	if (!relative)
		time(&relative_mouse_mode_off_time);
}

void ADBSetTouchInput(bool is_on) {
	touch_input = is_on;
}

bool ADBGetTouchInput(void) {
	return touch_input;
}

void ADBEnableHoverModeWith(int offset_x_inp, int offset_y_inp) {
	hover_mode = true;
	offset_x = offset_x_inp;
	offset_y = offset_y_inp;

	if (mouse_down) {
		ADBMouseUp(0);
	}
}

void ADBDisableHoverMode() {
	hover_mode = false;
	offset_x = 0;
	offset_y = 0;
}

bool ADBHoversOnMouseDown() {
	if (!touch_input) {
		return false;
	}
	return (relative_mouse || hover_mode);
}

// True when the absolute-mode hover cursor (two-finger steering) owns the guest
// pointer on iOS. In this state the app forwards ONLY the steering finger's
// position (VideoMapWindowPointToGuestAndMove) and video_sdl2 ignores SDL's own
// synthesized touch motion — which otherwise bounces the cursor onto every
// active finger, the "hop around the middle". hover_mode is only ever set in
// absolute mode (relative mode disables it), so this is the two-finger-steering
// state specifically.
bool ADBIsHoverModeActive(void) {
	return touch_input && hover_mode && !relative_mouse;
}

// True while the guest reads the mouse as relative deltas. Absolute-position
// forwarders (the Catalyst hover/drag window-point bypass) must no-op in this
// state: ADBMouseMoved() would add their absolute coordinates as deltas.
bool ADBIsRelativeMouseMode(void) {
	return relative_mouse;
}

bool ADBHoverGestureStartWasLeftSide() {
	return hover_gesture_start_was_left_side;
}

/*
 *  Key pressed ("code" is the Mac key code)
 */

void ADBKeyDown(int code)
{
	// Add keycode to buffer
	key_buffer[key_write_ptr] = code;
	key_write_ptr = (key_write_ptr + 1) % KEY_BUFFER_SIZE;

	// Set key in matrix
	key_states[code >> 3] |= (1 << (~code & 7));

	// Trigger interrupt
	SetInterruptFlag(INTFLAG_ADB);
	TriggerInterrupt();
}


/*
 *  Key released ("code" is the Mac key code)
 */

void ADBKeyUp(int code)
{
	// Add keycode to buffer
	key_buffer[key_write_ptr] = code | 0x80;	// Key-up flag
	key_write_ptr = (key_write_ptr + 1) % KEY_BUFFER_SIZE;

	// Clear key in matrix
	key_states[code >> 3] &= ~(1 << (~code & 7));

	// Trigger interrupt
	SetInterruptFlag(INTFLAG_ADB);
	TriggerInterrupt();
}

BeginAnimationState ADBStartAnimation() {
	is_animating = true;
	return BeginAnimationState(mouse_x, mouse_y);
}

void ADBAnimateMove(int x, int y) {
	if (!is_animating) {
		return;
	}

	B2_lock_mutex(mouse_lock);

	mouse_x = x;
	mouse_y = y;

	B2_unlock_mutex(mouse_lock);
	SetInterruptFlag(INTFLAG_ADB);
	TriggerInterrupt();
}

void ADBEndAnimation() {
	is_animating = false;
}

void ADBSetHoverGestureDragging(bool is_on) {
	is_hover_gesture_dragging = is_on;
}

/*
 *  ADB interrupt function (executed as part of 60Hz interrupt)
 */

void ADBInterrupt(void)
{
	M68kRegisters r;

	// Return if ADB is not initialized
	uint32 adb_base = ReadMacInt32(0xcf8);
	if (!adb_base || adb_base == 0xffffffff)
		return;
	uint32 tmp_data = adb_base + 0x163;	// Temporary storage for faked ADB data
	
	// Update Joystick state
	if (!joy_adb_installed && joy_adb_scan_done())
		joy_adb_install();
	if(joy_adb_installed)
		joy_adb_update();
	  
	// Get mouse state
	B2_lock_mutex(mouse_lock);
	int mx = mouse_x;
	int my = mouse_y;
	if (relative_mouse)
		mouse_x = mouse_y = 0;
	B2_unlock_mutex(mouse_lock);

	uint32 key_base = adb_base + 4;
	uint32 mouse_base = adb_base + 16;

	bool relate_mouse_mode_off_safeguard = false;
	if (mx == 0 &&
		my == 0) {
		time_t now;
		time(&now);
		if (difftime(now, relative_mouse_mode_off_time) < 0.5) {
			relate_mouse_mode_off_safeguard = true;
		}
	}

	if (relative_mouse || relate_mouse_mode_off_safeguard) {
		while (mx != 0 || my != 0 || button_read_ptr != button_write_ptr) {
			if (button_read_ptr != button_write_ptr) {
				// Read button event
				uint8 button = button_buffer[button_read_ptr];
				button_read_ptr = (button_read_ptr + 1) % BUTTON_BUFFER_SIZE;
				mouse_button[button & 0x3] = (button & 0x80) ? false : true;
			}
			// Call mouse ADB handler
			if (mouse_reg_3[1] == 4) {
				// Extended mouse protocol
				WriteMacInt8(tmp_data, 3);
				WriteMacInt8(tmp_data + 1, (my & 0x7f) | (mouse_button[0] ? 0 : 0x80));
				WriteMacInt8(tmp_data + 2, (mx & 0x7f) | (mouse_button[1] ? 0 : 0x80));
				WriteMacInt8(tmp_data + 3, ((my >> 3) & 0x70) | ((mx >> 7) & 0x07) | (mouse_button[2] ? 0x08 : 0x88));
			} else {
				// 100/200 dpi mode
				WriteMacInt8(tmp_data, 2);
				WriteMacInt8(tmp_data + 1, (my & 0x7f) | (mouse_button[0] ? 0 : 0x80));
				WriteMacInt8(tmp_data + 2, (mx & 0x7f) | (mouse_button[1] ? 0 : 0x80));
			}
			r.a[0] = tmp_data;
			r.a[1] = ReadMacInt32(mouse_base);
			r.a[2] = ReadMacInt32(mouse_base + 4);
			r.a[3] = adb_base;
			r.d[0] = (mouse_reg_3[0] << 4) | 0x0c;    // Talk 0

			Execute68k(r.a[1], &r);

			old_mouse_button[0] = mouse_button[0];
			old_mouse_button[1] = mouse_button[1];
			old_mouse_button[2] = mouse_button[2];
			mx = 0;
			my = 0;
		}

	} else {
		/*
		 * Absolute mouse (host pointer free — Finder, menus, ungrabbed games).
		 *
		 * Two Mac APIs touch the pointer, and they are not interchangeable:
		 *
		 *   - CursorDevice MoveTo: sets an absolute position. GetMouse / QD
		 *     use this. InputSprocket does not; it only samples ADB.
		 *   - ADB mouse Talk-0 relative packets: what a real mouse sends.
		 *     ISp (Quake 3, UT, …) reads these for look axes. Without them,
		 *     ungrabbed ISp titles get no motion.
		 *
		 * Grabbed / relative mode (Ctrl-F5, init_grab) never enters this
		 * branch: SDL relative deltas are turned into ADB packets only, and
		 * the host cursor is hidden/confined by SDL_SetRelativeMouseMode.
		 * That is the natural path for FPS-style ISp.
		 *
		 * Ungrabbed absolute mode must feed both consumers. Do ADB relative
		 * first (ISp + one driver step), then MoveTo to the host sample so
		 * the frame ends on the correct absolute position. Doing MoveTo
		 * first and ADB second made the cursor race (motion applied twice).
		 * Doing MoveTo alone fixed Finder but starved ISp (cursor/look
		 * "vanished" in Q3 unless grabbed).
		 *
		 * ADBSetRelMouseMode keeps mouse_* and old_mouse_* equal on a mode
		 * switch so this block is a no-op until the next ADBMouseMoved.
		 */
		if (mx != old_mouse_x || my != old_mouse_y) {
#ifdef POWERPC_ROM
			int dx = mx - old_mouse_x;
			int dy = my - old_mouse_y;
			if (dx > 255) dx = 255;
			else if (dx < -255) dx = -255;
			if (dy > 255) dy = 255;
			else if (dy < -255) dy = -255;
			if (dx != 0 || dy != 0) {
				if (mouse_reg_3[1] == 4) {
					WriteMacInt8(tmp_data, 3);
					WriteMacInt8(tmp_data + 1, (dy & 0x7f) | (mouse_button[0] ? 0 : 0x80));
					WriteMacInt8(tmp_data + 2, (dx & 0x7f) | (mouse_button[1] ? 0 : 0x80));
					WriteMacInt8(tmp_data + 3, ((dy >> 3) & 0x70) | ((dx >> 7) & 0x07) | (mouse_button[2] ? 0x08 : 0x88));
				} else {
					WriteMacInt8(tmp_data, 2);
					WriteMacInt8(tmp_data + 1, (dy & 0x7f) | (mouse_button[0] ? 0 : 0x80));
					WriteMacInt8(tmp_data + 2, (dx & 0x7f) | (mouse_button[1] ? 0 : 0x80));
				}
				r.a[0] = tmp_data;
				r.a[1] = ReadMacInt32(mouse_base);
				r.a[2] = ReadMacInt32(mouse_base + 4);
				r.a[3] = adb_base;
				r.d[0] = (mouse_reg_3[0] << 4) | 0x0c;	// Talk 0
				Execute68k(r.a[1], &r);
			}

			static const uint8 proc_template[] = {
				0x2f, 0x08,		// move.l a0,-(sp)
				0x2f, 0x00,		// move.l d0,-(sp)
				0x2f, 0x01,		// move.l d1,-(sp)
				0x70, 0x01,		// moveq #1,d0 (MoveTo)
				0xaa, 0xdb,		// CursorDeviceDispatch
				M68K_RTS >> 8, M68K_RTS & 0xff
			};
			BUILD_SHEEPSHAVER_PROCEDURE(proc);
			r.a[0] = ReadMacInt32(mouse_base + 4);
			r.d[0] = mx;
			r.d[1] = my;
			Execute68k(proc, &r);
#else
			WriteMacInt16(0x82a, mx);
			WriteMacInt16(0x828, my);
			WriteMacInt16(0x82e, mx);
			WriteMacInt16(0x82c, my);
			WriteMacInt8(0x8ce, ReadMacInt8(0x8cf));	// CrsrCouple -> CrsrNew
#endif
			old_mouse_x = mx;
			old_mouse_y = my;
		}

		// O2S: Process accumulated button events
		while (button_read_ptr != button_write_ptr) {
			// Read button event
			uint8 button = button_buffer[button_read_ptr];
			button_read_ptr = (button_read_ptr + 1) % BUTTON_BUFFER_SIZE;
			mouse_button[button & 0x3] = (button & 0x80) ? false : true;

			if (mouse_button[0] != old_mouse_button[0] || mouse_button[1] != old_mouse_button[1] || mouse_button[2] != old_mouse_button[2]) {
				uint32 mouse_base = adb_base + 16;

				// Call mouse ADB handler
				if (mouse_reg_3[1] == 4) {
					// Extended mouse protocol
					WriteMacInt8(tmp_data, 3);
					WriteMacInt8(tmp_data + 1, mouse_button[0] ? 0 : 0x80);
					WriteMacInt8(tmp_data + 2, mouse_button[1] ? 0 : 0x80);
					WriteMacInt8(tmp_data + 3, mouse_button[2] ? 0x08 : 0x88);
				} else {
					// 100/200 dpi mode
					WriteMacInt8(tmp_data, 2);
					WriteMacInt8(tmp_data + 1, mouse_button[0] ? 0 : 0x80);
					WriteMacInt8(tmp_data + 2, mouse_button[1] ? 0 : 0x80);
				}
				r.a[0] = tmp_data;
				r.a[1] = ReadMacInt32(mouse_base);
				r.a[2] = ReadMacInt32(mouse_base + 4);
				r.a[3] = adb_base;
				r.d[0] = (mouse_reg_3[0] << 4) | 0x0c;    // Talk 0

				Execute68k(r.a[1], &r);

				old_mouse_button[0] = mouse_button[0];
				old_mouse_button[1] = mouse_button[1];
				old_mouse_button[2] = mouse_button[2];
			}
		}

	}

	// Process accumulated keyboard events
	while (key_read_ptr != key_write_ptr) {

		// Read keyboard event
		uint8 mac_code = key_buffer[key_read_ptr];
		key_read_ptr = (key_read_ptr + 1) % KEY_BUFFER_SIZE;

		// Call keyboard ADB handler
		WriteMacInt8(tmp_data, 2);
		WriteMacInt8(tmp_data + 1, mac_code);
		WriteMacInt8(tmp_data + 2, mac_code == 0x7f ? 0x7f : 0xff);	// Power key is special
		r.a[0] = tmp_data;
		r.a[1] = ReadMacInt32(key_base);
		r.a[2] = ReadMacInt32(key_base + 4);
		r.a[3] = adb_base;
		r.d[0] = (key_reg_3[0] << 4) | 0x0c;	// Talk 0
		Execute68k(r.a[1], &r);
	}

	// Clear temporary data
	WriteMacInt32(tmp_data, 0);
	WriteMacInt32(tmp_data + 4, 0);
}
