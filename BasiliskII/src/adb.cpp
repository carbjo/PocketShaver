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

// tolernace used to determine wheather to move mouse or not during	potential double click event
static int double_click_mouse_move_tolerance = 10;


#define ADB_MOUSE_LOG 0
#define ADB_MOUSE_LOG_CURSOR_DEVICES 0
#define ADB_LOG_MAX 200000
#define ADB_SNAPSHOT_REGIONS 7
#define ADB_SNAPSHOT_BYTES 1024	// Firebird per-stick settings span 0x104 * sticks
#define CURSOR_LOG_BUFFER 0x2fd240 /* CURSOR_LOG_SPACE from rom_patches.cpp */

static int mouse_dx = 0, mouse_dy = 0;		// Counts a Talk 0 has yet to report
static bool mouse_host_valid = false;		// is old_mouse_* a host sample yet?

#if ADB_MOUSE_LOG
static unsigned adb_log_lines = 0;
static unsigned adb_vbl_count = 0;
static uint32 adb_snapshot_addr[ADB_SNAPSHOT_REGIONS];
static int adb_snapshot_length[ADB_SNAPSHOT_REGIONS];
static const char *adb_snapshot_name[ADB_SNAPSHOT_REGIONS];
static uint8 adb_snapshot_data[ADB_SNAPSHOT_REGIONS][ADB_SNAPSHOT_BYTES];
static bool adb_snapshot_ready = false;
static uint32 adb_firebird_area = 0;
static uint32 adb_firebird_service = 0;		// ADBS entry, to attribute MoveTo callers
#endif

BeginAnimationState::BeginAnimationState(int inp_x, int inp_y) {
	x = inp_x;
	y = inp_y;
}

#if ADB_MOUSE_LOG
#include <stdarg.h>
#include <stdio.h>

static void adb_logf(const char *fmt, ...)
{
	char body[2048], rec[2140];
	va_list ap;

	if (adb_log_lines++ >= ADB_LOG_MAX) {
		if (adb_log_lines == ADB_LOG_MAX + 1)
			fputs("[adb] --- log cap reached ---\n", stderr);
		return;
	}
	va_start(ap, fmt);
	vsnprintf(body, sizeof(body), fmt, ap);
	va_end(ap);
	snprintf(rec, sizeof(rec), "[adb %5u v%-5u] %s\n", adb_log_lines,
		adb_vbl_count, body);
	rec[sizeof(rec) - 1] = 0;
	fputs(rec, stderr);
	fflush(stderr);
#if defined(_WIN32)
	OutputDebugStringA(rec);
#endif
}

/* Build a string of every low memory value the cursor uses. */
static char *adb_lm(char *buf, int n)
{
	snprintf(buf, n,
		"MTemp=%d,%d Raw=%d,%d Mouse=%d,%d Pin=%d,%d,%d,%d "
		"New=%02x Coup=%02x Busy=%02x MBState=%02x CrsrState=%d",
		(int16)ReadMacInt16(0x828), (int16)ReadMacInt16(0x82a),
		(int16)ReadMacInt16(0x82c), (int16)ReadMacInt16(0x82e),
		(int16)ReadMacInt16(0x830), (int16)ReadMacInt16(0x832),
		(int16)ReadMacInt16(0x834), (int16)ReadMacInt16(0x836),
		(int16)ReadMacInt16(0x838), (int16)ReadMacInt16(0x83a),
		ReadMacInt8(0x8ce), ReadMacInt8(0x8cf), ReadMacInt8(0x8cd),
		ReadMacInt8(0x172), (int16)ReadMacInt16(0x8d0));
	buf[n - 1] = 0;
	return buf;
}

static char *adb_hex(char *text, int size, const uint8 *p, int length)
{
	int i, o = 0;

	for (i = 0; i < length && o < size - 3; i++)
		o += snprintf(text + o, size - o, "%02x ", p[i]);
	if (o > 0)
		o--;
	text[o] = 0;
	return text;
}

#define ALOG(...) adb_logf(__VA_ARGS__)

/* Copy watched areas of guest memory so changed bytes can be reported later. */
static void adb_snapshot_region(int i, const char *name, uint32 addr, int length)
{
	adb_snapshot_addr[i] = addr;
	if (length > ADB_SNAPSHOT_BYTES)
		length = ADB_SNAPSHOT_BYTES;
	adb_snapshot_length[i] = length;
	adb_snapshot_name[i] = name;
}

static void adb_snapshot_take(void)
{
	int i, j;

	for (i = 0; i < ADB_SNAPSHOT_REGIONS; i++)
		for (j = 0; j < adb_snapshot_length[i]; j++)
			adb_snapshot_data[i][j] = ReadMacInt8(adb_snapshot_addr[i] + j);
	adb_snapshot_ready = true;
}

/* Report changed bytes in pairs, since screen coordinates are stored that
   way and read better as numbers than as bytes. */
static int adb_snapshot_diff(const char *what)
{
	char line[1500];
	int i, j, o, runs, total = 0;

	if (!adb_snapshot_ready)
		return 0;
	for (i = 0; i < ADB_SNAPSHOT_REGIONS; i++) {
		if (!adb_snapshot_addr[i] || !adb_snapshot_length[i])
			continue;
		o = 0;
		runs = 0;
		for (j = 0; j + 1 < adb_snapshot_length[i]; j += 2) {
			int was = (adb_snapshot_data[i][j] << 8) | adb_snapshot_data[i][j + 1];
			int now = ReadMacInt16(adb_snapshot_addr[i] + j);

			if (was == now)
				continue;
			runs++;
			if (o < (int)sizeof(line) - 40)
				o += snprintf(line + o, sizeof(line) - o, "+%02x:%d>%d ",
					j, (int16)was, (int16)now);
		}
		total += runs;
		if (runs)
			ALOG("diff %-6s %-8s @%08x %2d fld  %s", what, adb_snapshot_name[i],
				adb_snapshot_addr[i], runs, line);
	}
	adb_snapshot_take();
	return total;
}

static void adb_log_hex(const char *what, uint32 addr, int length)
{
	char line[80];
	int i, j, o;

	for (i = 0; i < length; i += 32) {
		o = 0;
		for (j = 0; j < 32 && i + j < length; j++)
			o += snprintf(line + o, sizeof(line) - o, "%02x",
				ReadMacInt8(addr + i + j));
		ALOG("fb %s +%03x %s", what, i, line);
	}
}

static void adb_log_firebird(const char *why)
{
	uint32 globals, firebird_sticks;

	if (adb_firebird_area == 0 || ReadMacInt32(adb_firebird_area + 0xe6) != 0x6d464244)
		return;
	globals = ReadMacInt32(adb_firebird_area + 0x11a);
	firebird_sticks = 0;
	if (globals)
		firebird_sticks = ReadMacInt32(globals + 0xe);
	ALOG("fbdump[%s]: area=%08x globals=%08x sticks=%08x sticksEnabled=%02x "
		"ver=%04x stickEnable=%02x", why, adb_firebird_area, globals,
		firebird_sticks,
		ReadMacInt8(adb_firebird_area + 0xf8), ReadMacInt16(adb_firebird_area + 0xea),
		ReadMacInt8(adb_firebird_area + 0x1de));
	if (globals)
		adb_log_hex("globals", globals, 0x80);
	adb_log_hex("area", adb_firebird_area, 0x400);
}
#else
#define ALOG(...) do { } while (0)
#define adb_snapshot_take() do { } while (0)
#define adb_snapshot_diff(w) 0
#define adb_log_firebird(w) do { } while (0)
#endif

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
#define JOY_FIREBIRD_ORIGADBADDR      0x3
#define JOY_FIREBIRD_ORIGDEVTYPE  0x01
#define JOY_FIREBIRD_DEVTYPE      0x4E
#define JOY_FIREBIRD_CLASS        0x0A  /* R1 data[0] */
#define JOY_FIREBIRD_VERSION      0x00  /* R1 data[1] */
#if 1 /* Gravis Firebird */
#define JOY_GRAVIS_ORIGADBADDR  JOY_FIREBIRD_ORIGADBADDR
#define JOY_GRAVIS_ORIGDEVTYPE  JOY_FIREBIRD_ORIGDEVTYPE
#define JOY_GRAVIS_DEVTYPE		JOY_FIREBIRD_DEVTYPE
#define joy_adb_enable_gravis joy_adb_enable_gravis_firebird
#define joy_adb_pack_gravis joy_adb_pack_gravis_firebird
#else /* Gravis MouseStick II */
#define JOY_GRAVIS_ORIGADBADDR  JOY_GRAVISMOUSESTICKII_ORIGADBADDR
#define JOY_GRAVIS_ORIGDEVTYPE  JOY_GRAVISMOUSESTICKII_ORIGDEVTYPE
#define JOY_GRAVIS_DEVTYPE      JOY_GRAVISMOUSESTICKII_DEVTYPE
#define joy_adb_enable_gravis   joy_adb_enable_gravis_mousestick_ii
#define joy_adb_pack_gravis joy_adb_pack_gravis_mousestick_ii
#endif
#define JOY_DEVSPERDEVICE 2

struct joy_adb_dev {
	uint8 reg_3[2]; /* [0] flags|CURRENT addr. [1] devType - handler ID. */
	uint8 orig_addr; /* origADBAddr */
	uint8 real_devtype; /* client can rewrite reg_3[1]; store real type */
	uint8 enabled; /* Enabled via extension/control panel. Not thrustmaster */
	uint16 cmd_param; /* last R2 write, echoed on the next R2 read */
	uint16 cmd_status; /* returned when armed */
	uint8 cmd_armed; /* next R2 read is status and not echo */	  
	uint8 last_packet_len;
	uint8 last_packet[8];
	uint32 entry_base; /* ADB address for ADBInterrupt() */
	JoyManagerDevice* dev; 
};
static joy_adb_dev joy_adb_devs[JOY_ADB_MAX];
static int joy_adb_count = 0; 
void joy_adb_init(void)
{
	int i, idevindex;
	JoyManagerInit();
	joy_adb_count = JoyManagerNumDevices() * JOY_DEVSPERDEVICE;
	if (joy_adb_count > JOY_ADB_MAX)
			joy_adb_count = JOY_ADB_MAX;
	for (i = 0, idevindex = 0; i < joy_adb_count; ++idevindex) {
		JoyManagerDevice* dev = JoyManagerOpenDevice(idevindex);
		if(dev == NULL) {
			joy_adb_count -= JOY_DEVSPERDEVICE;
			continue;
		}
		joy_adb_devs[i].orig_addr = JOY_GRAVIS_ORIGADBADDR;
		joy_adb_devs[i].reg_3[0] = 0x60 | joy_adb_devs[i].orig_addr;
		joy_adb_devs[i].dev = dev;
		joy_adb_devs[i].real_devtype = JOY_GRAVIS_DEVTYPE;
		joy_adb_devs[i].reg_3[1] = JOY_GRAVIS_ORIGDEVTYPE;
		joy_adb_devs[i].enabled = false;
		joy_adb_devs[i].cmd_status = 0xff00;
		joy_adb_devs[i].cmd_param = 0;
		joy_adb_devs[i].cmd_armed = 0;
		joy_adb_devs[i].last_packet_len = 0;
		++i;
		joy_adb_devs[i].orig_addr = JOY_THRUSTMASTER_ADBADDR;
		joy_adb_devs[i].reg_3[0] = 0x60 | joy_adb_devs[i].orig_addr;
		joy_adb_devs[i].dev = dev;
		joy_adb_devs[i].real_devtype = JOY_THRUSTMASTER_DEVTYPE;
		joy_adb_devs[i].reg_3[1] = JOY_THRUSTMASTER_DEVTYPE;
		joy_adb_devs[i].enabled = true;
		joy_adb_devs[i].cmd_status = 0xff00;
		joy_adb_devs[i].cmd_param = 0;
		joy_adb_devs[i].cmd_armed = 0;
		joy_adb_devs[i].last_packet_len = 0;
		++i;
	}
}
void joy_adb_exit(void)
{
	int i, numdevs;
	numdevs = joy_adb_count; 
	joy_adb_count = 0;
	for (i = 0; i < numdevs; i += JOY_DEVSPERDEVICE)
		JoyManagerCloseDevice(joy_adb_devs[i].dev);
}
void joy_adb_reset_addr(void)
{
	int i;
	for (i = 0; i < joy_adb_count; ++i) {
		joy_adb_devs[i].reg_3[0] = 0x60 | joy_adb_devs[i].orig_addr;
		if (joy_adb_devs[i].real_devtype == JOY_THRUSTMASTER_DEVTYPE) {
			joy_adb_devs[i].reg_3[1] = JOY_THRUSTMASTER_DEVTYPE;
		} else {
			joy_adb_devs[i].reg_3[1] = JOY_GRAVIS_ORIGDEVTYPE;
			joy_adb_devs[i].enabled = false;
		}
		joy_adb_devs[i].cmd_status = 0xff00;
		joy_adb_devs[i].cmd_param = 0;
		joy_adb_devs[i].cmd_armed = 0;
		joy_adb_devs[i].last_packet_len = 0;
	}
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

/* SDL int16 -> the driver's axis units, -600..+600 */
static int16 joy_adb_axis_600(JoyManagerDevice *dev, int axis)
{
	int v;

	v = (JoyManagerAxis(dev, axis) * 600) / 32767;
	if (v > 600)
		v = 600;
	else if (v < -600)
		v = -600;
	return (int16)v;
}
/* control index -> (packet byte, bit) */
static const uint8 joy_firebird_control[17][2] = {
	  {2,2},{2,1},{2,6},{2,5},{2,7},{2,3},{2,0},{2,4},
	  {1,2},{1,1},{1,0},{1,5},{1,3},{0,0},{1,6},{1,4},{1,7}
};
#define JOY_FIREBIRD_REST 4000	/* stick values this near centre count as centred */
#define JOY_FIREBIRD_NULL 11		/* reported bytes this near 128 mean "no movement" */

static uint8 joy_firebird_axis(JoyManagerDevice *dev, int axis)
{
	int v = JoyManagerAxis(dev, axis);
	int r;

	/* Treat a stick resting slightly off centre as centred. */
	if (v > -JOY_FIREBIRD_REST && v < JOY_FIREBIRD_REST)
		return 128;
	/* Stretch what is left so pushing the stick fully still reaches the ends. */
	if (v > 0)
		v = (v - JOY_FIREBIRD_REST) * 32767 / (32767 - JOY_FIREBIRD_REST);
	else
		v = (v + JOY_FIREBIRD_REST) * 32768 / (32768 - JOY_FIREBIRD_REST);
	r = (v + 32768) >> 8;
	/* Say centred rather than send a value the driver ignores anyway. */
	if (r > 128 - JOY_FIREBIRD_NULL && r < 128 + JOY_FIREBIRD_NULL)
		return 128;
	return (uint8)r;
}
uint8 joy_adb_pack_gravis_firebird(int i, uint8 reg, uint8 *buf)
{ /* fill up to 8 bytes of buf, return filled # of bytes */
	JoyManagerDevice *dev;
	int nb, c;

	if (joy_adb_devs[i].real_devtype != JOY_FIREBIRD_DEVTYPE)
		return 0;
	dev = joy_adb_devs[i].dev;

	if (reg == 1) {
		buf[0] = JOY_FIREBIRD_CLASS; /* 0x0A, required */
		buf[1] = JOY_FIREBIRD_VERSION; /* version = 0x0A00 + this */
		buf[2] = 0; /* stored at dataArea+0x1C2 */
		return 3;
	}
	if (reg == 2) {
		uint16 v;

		if (joy_adb_devs[i].cmd_armed) {
				v = joy_adb_devs[i].cmd_status;
				joy_adb_devs[i].cmd_armed = 0;
		} else {
				v = joy_adb_devs[i].cmd_param;
		}
		buf[0] = (uint8)(v >> 8);
		buf[1] = (uint8)v;
		return 2;
	}  
	if (reg != 0)
		return 0;

	buf[0] = 0xff;
	buf[1] = 0xff;
	buf[2] = 0xff;
	nb = JoyManagerNumButtons(dev);
	for (c = 0; c < nb && c < 17; ++c) {
		if (JoyManagerButton(dev, c))
			buf[joy_firebird_control[c][0]] &= ~(1u << joy_firebird_control[c][1]);
	}
	buf[3] = joy_firebird_axis(dev, 0);   /* 0..255, 128 centred */
	buf[4] = joy_firebird_axis(dev, 1);
	buf[5] = joy_firebird_axis(dev, 2);   /* throttle, unscaled */
	buf[6] = joy_firebird_axis(dev, 3);   /* third axis */
	buf[7] = 0;
	return 8;
}
/* SDL button index -> packet bit (ADBS+0x670), active low */
static const uint8 joy_adb_gravis_pack_button_bit[5] = { 2, 0, 1, 3, 4 };
uint8 joy_adb_pack_gravis_mousestick_ii(int i, uint8 reg, uint8 *buf)
{ /* fill up to 8 bytes of buf, return filled # of bytes */
	JoyManagerDevice *dev;
	int16 x, y;
	int nb, ibutton;
	uint8 buttons;

	if (joy_adb_devs[i].real_devtype != JOY_GRAVISMOUSESTICKII_DEVTYPE)
		return 0;
	dev = joy_adb_devs[i].dev;

	if (reg == 1) {
		buf[0] = 3; /* selects variant 2 of 3 */
		return 1;
	}
	if (reg != 0)
		return 0;

	x = joy_adb_axis_600(dev, 0);
	y = joy_adb_axis_600(dev, 1);

	buttons = 0xff;
	nb = JoyManagerNumButtons(dev);
	if (nb > 5)
		nb = 5;
	for (ibutton = 0; ibutton < nb; ++ibutton) {
		if (JoyManagerButton(dev, ibutton))
			buttons &= ~(1u << joy_adb_gravis_pack_button_bit[ibutton]);
	}

	buf[0] = 0;
	buf[1] = 0;
	buf[2] = (uint8)(x >> 8);
	buf[3] = (uint8)x;
	buf[4] = (uint8)(y >> 8);
	buf[5] = (uint8)y;
	buf[6] = buttons;
	return 7;
}

static bool joy_adb_owns_cursor(void);
static bool mouse_adb_pointer_hidden(void);

/* SDL int16 -> raw device byte; the driver's four 256-entry tables at
   TM INIT+0x4788/0x4888/0x4988/0x4a88 do the centring and signing. */
static uint8 joy_thrustmaster_axis(JoyManagerDevice *dev, int axis)
{
	  return (uint8)((JoyManagerAxis(dev, axis) + 32768) >> 8);
}
/* signed axes: -128..127, centred on 0 */
static uint8 joy_thrustmaster_axis_signed(JoyManagerDevice *dev, int axis)
{
	return (uint8)(JoyManagerAxis(dev, axis) >> 8);
}
static const uint8 joy_adb_thrustmaster_button_bit[16] = {
	5, /* trigger   */ 4, /* thumbHigh */ 6, /* thumbLow */ 7, /* pinkey */
	13, 12, 11, 8, 10, 9,   /* button 1,2,3,4,5,6 */
	14, 15, /* rockerUp, rockerDown */
	0, 1, 2, 3 /* hatUp, hatDown, hatRight, hatLeft */
};
uint8 joy_adb_pack_thrustmaster(int i, uint8 reg, uint8 *buf)
{
	JoyManagerDevice *dev;
	uint16 buttons;
	int nb, c;

	if (reg != 2) /* the driver polls R2, not R0 */
		return 0;
	dev = joy_adb_devs[i].dev;

	buttons = 0;
	nb = JoyManagerNumButtons(dev);
	if (nb > 16)
			nb = 16;
	for (c = 0; c < nb; ++c) {
		if (JoyManagerButton(dev, c))
			buttons |= (uint16) 
				(1u << joy_adb_thrustmaster_button_bit[c]);
	}

	/* joy_adb_owns_cursor() - Firebird is the finder mouse controller 
	!mouse_adb_pointer_hidden() - Not in a game or app essentially */
	if (!mouse_adb_pointer_hidden() && joy_adb_owns_cursor()) {
		buf[0] = buf[1] = buf[3] = 0;	/* signed axes: 0 is centre */
		buf[2] = 128;			/* unsigned thrust */
	} else {
		buf[0] = joy_thrustmaster_axis_signed(dev, 0); /* roll */
		buf[1] = joy_thrustmaster_axis_signed(dev, 1); /* pitch */
		buf[2] = joy_thrustmaster_axis(dev, 3); /* thrust */
		buf[3] = joy_thrustmaster_axis_signed(dev, 2); /* yaw */
	}
	buf[4] = (uint8)(buttons >> 8);
	buf[5] = (uint8)buttons;
	buf[6] = 0; /* reserveByte1 - driver never reads it */
	buf[7] = 0; /* reserveByte2 - same */
	return 8;
}

uint8 joy_adb_pack(int i, uint8 reg, uint8 *buf)
{
	if (joy_adb_devs[i].real_devtype == JOY_GRAVIS_DEVTYPE)
		return joy_adb_pack_gravis(i, reg, buf);
	return joy_adb_pack_thrustmaster(i, reg, buf);
}
static void joy_adb_enable_gravis_mousestick_ii(int i)
{
	uint32 area, record;
	int n, k;

	area = ReadMacInt32(joy_adb_devs[i].entry_base + 4);
	if (area == 0 || ReadMacInt32(area) != 0x4a656666) /* 'Jeff' */
		return; /* INIT hasn't adopted it yet */

	n = (int16)ReadMacInt16(area + 0x16);
	for (k = 0; k < n; k++) {
		if (ReadMacInt8(area + 0x1a + 10 * k)
				!= (joy_adb_devs[i].reg_3[0] & 0x0f))
			continue;
		record = area + 0x2e + 0xa8 * k;
		WriteMacInt8(record + 0x0c, 1);
		joy_adb_devs[i].enabled = true;
		return;
	}
}
static void joy_adb_enable_gravis_firebird(int i)
{
	uint32 area, record;
	int n, k;

	area = ReadMacInt32(joy_adb_devs[i].entry_base + 4);
	if (area == 0 || ReadMacInt32(area + 0xe6) != 0x6d464244) /* 'mFBD' */
		return;

	n = (int16)ReadMacInt16(area + 0x110);
	for (k = 0; k < n; k++) {
		if (ReadMacInt8(area + 0x120 + 10 * k)
				!= (joy_adb_devs[i].reg_3[0] & 0x0f))
			continue;
		record = area + 0x104 * k + 0x1c0;
		WriteMacInt8(record + 0x1e, 1); /* ADBS+0x4a0 gate */
		joy_adb_devs[i].enabled = true;
		return;
	}
}
void joy_adb_op(int i, uint8 cmd, uint8 reg, uint8* data) {
	if (cmd == 2) { /* Write */
		uint16 v;
		switch(reg) {
			case 3:
				if (data[2] == 0xfe)
					joy_adb_devs[i].reg_3[0] =
						(joy_adb_devs[i].reg_3[0] & 0xf0) | (data[1] & 0x0f);
				else if (data[2] == 0x00)
					joy_adb_devs[i].reg_3[0] =
						(joy_adb_devs[i].reg_3[0] & 0xd0) | (data[1] & 0x2f);
				else if (data[2] == JOY_GRAVIS_ORIGDEVTYPE
						|| data[2] == JOY_GRAVIS_DEVTYPE
						|| data[2] == JOY_THRUSTMASTER_DEVTYPE)
					joy_adb_devs[i].reg_3[1] = data[2];
				break;
			case 1:
				v = ((uint16)data[1] << 8) | data[2];
				if (v == 0xfdfd)
					joy_adb_devs[i].cmd_armed = 1;
				else if (v == 0xfcfc)
					joy_adb_devs[i].cmd_armed = 0;
				else {
					/* a command: we accept every one of them.
						0x0505/0x0606/0x0707/0x0808 set axis ranges,
						which we don't need since the ADBS applies its
						own 4.3x-550 scaling to what we send. */
					joy_adb_devs[i].cmd_status = 0xff00;
					joy_adb_devs[i].cmd_armed = 0;
				}
				break;
			case 2:
				v = ((uint16)data[1] << 8) | data[2];
				joy_adb_devs[i].cmd_param = v;
				break;
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
			case 1: /* variant selector */
			case 2:
				data[0] = joy_adb_pack(i, reg, data + 1);
				break;
			default:
				data[0] = 0;
				break;
		}
	}
}

static void joy_adb_sync_table(uint32 adb_base)
{ /* The ADB Manager's table only learns a handler ID at (re)enumeration, but
   this conflicts with Gravis Firebird. */
	int i, k;
	uint8 adr;

	for (k = 0; k < 16; k++) {
		adr = ReadMacInt8(adb_base + 12 * k + 2);
		if (adr == 0)
			break;		/* end of the table, as the ROM scans it (0x31790) */
		if (ReadMacInt32(adb_base + 12 * k + 4) == 0)
			continue;
		i = joy_adb_find(adr);
		if (i < 0)
			continue;
		if (ReadMacInt8(adb_base + 12 * k) != joy_adb_devs[i].reg_3[1])
			WriteMacInt8(adb_base + 12 * k, joy_adb_devs[i].reg_3[1]);
#if ADB_MOUSE_LOG
		/* Watch the Firebird driver's settings for this stick, which is
		   where its control panel writes the mode the stick is in. */
		if (i >= 0 && joy_adb_devs[i].reg_3[1] == JOY_GRAVIS_DEVTYPE) {
			static uint32 firebird_sticks_watched = 0;
			uint32 firebird_area = ReadMacInt32(adb_base + 12 * k + 8);
			uint32 firebird_globals, firebird_sticks;

			if (firebird_area != 0 && ReadMacInt32(firebird_area + 0xe6) == 0x6d464244
					&& (firebird_globals = ReadMacInt32(firebird_area + 0x11a)) != 0
					&& (firebird_sticks = ReadMacInt32(firebird_globals + 0xe)) != 0
					&& firebird_sticks != firebird_sticks_watched) {
				firebird_sticks_watched = firebird_sticks;
				adb_firebird_area = firebird_area;
				adb_firebird_service = ReadMacInt32(adb_base + 12 * k + 4);
				adb_snapshot_region(5, "fbset", firebird_sticks, ADB_SNAPSHOT_BYTES);
				adb_log_firebird("found");
			}
		}
#endif
	}
}
static bool joy_adb_owns_cursor(void)
{
	int i;

	for (i = 0; i < joy_adb_count; i++) {
		if (joy_adb_devs[i].enabled
				&& joy_adb_devs[i].real_devtype != JOY_THRUSTMASTER_DEVTYPE)
			return true;
	}
	return false;
}
#else /* !USE_SDL */
static void joy_adb_init(void) {}
static void joy_adb_exit(void) {}
static void joy_adb_reset_addr(void) {}
static int  joy_adb_find(uint8 adr) { (void)adr; return -1; }
static void joy_adb_sync_table(uint32 adb_base) { (void)adb_base; }
static bool joy_adb_owns_cursor(void) { return false; }
#endif /* #ifdef USE_SDL */

/* The emulated ADB mouse: it reports movement counts when the host mouse is
   grabbed, and places the pointer at the host pointer when it is not. */

static bool mouse_adb_pending(void)
{
	return mouse_dx != 0 || mouse_dy != 0
		|| mouse_button[0] != old_mouse_button[0]
		|| mouse_button[1] != old_mouse_button[1]
		|| mouse_button[2] != old_mouse_button[2];
}

uint8 mouse_adb_pack(uint8 reg, uint8 *buf)
{ /* fill up to 8 bytes of buf, return filled # of bytes */
	int limit, bytes, dx, dy;

	if (reg == 1) { /* extended protocol identity */
		buf[0] = 'a';
		buf[1] = 'p';
		buf[2] = 'p';
		buf[3] = 'l';
		buf[4] = 300 >> 8;	/* resolution (dpi) */
		buf[5] = 300 & 0xff;
		buf[6] = 1;		/* class (mouse) */
		buf[7] = 3;		/* number of buttons */
		return 8;
	}
	if (reg == 3) {
		buf[0] = (mouse_reg_3[0] & 0xf0) | (rand() & 0x0f);
		buf[1] = mouse_reg_3[1];
		return 2;
	}
	if (reg != 0 || !mouse_adb_pending())
		return 0; /* a real mouse says nothing when it has nothing */

	/* The 100/200 dpi protocol carries seven signed bits per axis and the
	   extended one ten.  Anything past that waits for the next report --
	   truncating it wrapped the sign and threw the pointer backwards. */
	limit = 63;
	bytes = 2;
	if (mouse_reg_3[1] == 4) {
		limit = 511;
		bytes = 3;
	}
	dx = mouse_dx;
	if (dx > limit)
		dx = limit;
	else if (dx < -limit)
		dx = -limit;
	dy = mouse_dy;
	if (dy > limit)
		dy = limit;
	else if (dy < -limit)
		dy = -limit;
	mouse_dx -= dx;
	mouse_dy -= dy;

	buf[0] = (uint8)(dy & 0x7f);
	if (!mouse_button[0])
		buf[0] |= 0x80;
	buf[1] = (uint8)(dx & 0x7f);
	if (!mouse_button[1])
		buf[1] |= 0x80;
	old_mouse_button[0] = mouse_button[0];
	old_mouse_button[1] = mouse_button[1];
	old_mouse_button[2] = mouse_button[2];
	if (bytes == 2)
		return 2;
	buf[2] = (uint8)(((dy >> 3) & 0x70) | ((dx >> 7) & 0x07));
	if (mouse_button[2])
		buf[2] |= 0x08;
	else
		buf[2] |= 0x88;
	return 3;
}


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

static void adb_bases_invalidate(void);

void ADBOp(uint8 op, uint8 *data)
{
	D(bug("ADBOp op %02x, data %02x %02x %02x\n", op, data[0], data[1], data[2]));
#if ADB_MOUSE_LOG
	{
		static const char *command_name[4] = { "Reset/Flush", "?", "Listen", "Talk" };
		uint8 a = op >> 4, c = (op >> 2) & 3, g = op & 3;
		const char *who = "none";

		if (a == (mouse_reg_3[0] & 0x0f))
			who = "MOUSE";
		else if (a == (key_reg_3[0] & 0x0f))
			who = "kbd";
		else if (joy_adb_find(a) >= 0)
			who = "joy";

		ALOG("op %02x adr=%2d %s r%d -> %-5s in[%02x %02x %02x]",
			op, a, command_name[c], g, who, data[0], data[1], data[2]);
	}
#endif

	// ADB reset?
	if ((op & 0x0f) == 0) {
		mouse_reg_3[0] = 0x63;
		mouse_reg_3[1] = 0x01;
		key_reg_2[0] = 0xff;
		key_reg_2[1] = 0xff;
		key_reg_3[0] = 0x62;
		key_reg_3[1] = m_keyboard_type;
		joy_adb_reset_addr();
		adb_bases_invalidate();
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
					adb_bases_invalidate();
					ALOG("   mouse reg3 -> adr=%d handler=%d (%s protocol)",
						mouse_reg_3[0] & 0x0f, mouse_reg_3[1],
						mouse_reg_3[1] == 4 ? "extended 10-bit"
							: "100/200dpi 7-bit");
					break;
			}

		} else if (cmd == 3) {

			// Register 0 is the movement and button packet the ADB
			// Manager polls for.
			data[0] = mouse_adb_pack(reg, data + 1);
#if ADB_MOUSE_LOG
			{
				char hex[32];
				uint8 d3 = 0, d4 = 0;

				if (data[0] >= 3)
					d3 = data[3];
				if (data[0] >= 4)
					d4 = data[4];
				ALOG("   mouse Talk r%d -> %d byte(s) [%s] counts left=%d,%d",
					reg, data[0], adb_hex(hex, sizeof(hex), data + 1, data[0]),
					mouse_dx, mouse_dy);
			}
#endif

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
					adb_bases_invalidate();
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
		int i = joy_adb_find(adr);
		if (i < 0) {
			if (cmd == 3)
				data[0] = 0; /* nothing at this address */
		} else {
			joy_adb_op(i, cmd, reg, data);
#if ADB_MOUSE_LOG
			if (cmd == 3)
				ALOG("joy reply r%d out[%d: %02x %02x %02x %02x] armed=%d param=%04x status=%04x",
					reg, data[0], data[1], data[2], d3, d4,
					joy_adb_devs[i].cmd_armed, joy_adb_devs[i].cmd_param,
					joy_adb_devs[i].cmd_status);
#endif
		}
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
		// the hover offset can push past the guest edges either way -- pin the
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
	if (relative_mouse == relative)
		return;
	relative_mouse = relative;
	/* mouse_x/mouse_y change meaning across the switch -- accumulated motion
	 * one side, a position the other -- so drop everything measured against
	 * the old meaning and let the next tick re-anchor. */
	B2_lock_mutex(mouse_lock);
	mouse_x = mouse_y = 0;
	mouse_dx = mouse_dy = 0;
	B2_unlock_mutex(mouse_lock);
	mouse_host_valid = false;
	ALOG("mode: %s (screen %dx%d)", relative ? "GRABBED (relative)"
		: "ungrabbed (tablet)", screen_width, screen_height);
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
// synthesized touch motion -- which otherwise bounces the cursor onto every
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

static uint32 adb_scratch = 0; /* 10-byte ADBDataBlock */
static uint32 adb_key_base = 0;
static uint32 adb_mouse_base = 0;
static uint32 adb_bases_for = 0; /* ADBBase these were resolved against */
static bool adb_bases_valid = false;

static void adb_bases_invalidate(void)
{
	adb_bases_valid = false;
}

/* Entry N's dbServiceRtPtr sits at ADBBase + 4 + 12*N -- the same 
	assumption the hardcoded +4/+16 pair always made, just parameterised 
	and checked. */
#define ADB_ENTRY_STRIDE 12

/* Deferred-task context only: see adb_resolve_entry(). */
static void adb_alloc_scratch(void)
{
	M68kRegisters r;

	if (adb_scratch != 0)
		return;
	memset(&r, 0, sizeof(r));
	r.d[0] = 10;
	Execute68kTrap(0xa71e, &r); /* NewPtrSysClear() */
	adb_scratch = r.a[0];
}

static uint32 adb_resolve_entry(uint32 adb_base, uint8 adr)
{
	M68kRegisters r;
	uint32 svc, area, base;
	int n, i;

	/* ADBVBL pre-allocates via adb_alloc_scratch(), so in practice this is
	   already set and the on-demand path below never runs at interrupt time.
	   It stays as a fallback: resolving with no scratch returns 0, and the
	   caller then falls back to fixed table offsets that are not necessarily
	   this machine's mouse and keyboard entries. */
	memset(&r, 0, sizeof(r));

	if (adb_scratch == 0) {
		r.d[0] = 10;
		Execute68kTrap(0xa71e, &r); /* NewPtrSysClear() */
		if (r.a[0] == 0)
				return 0;
		adb_scratch = r.a[0];
	}

	r.a[0] = adb_scratch;
	r.d[0] = adr;
	Execute68kTrap(0xa079, &r); /* GetADBInfo() */
	svc = ReadMacInt32(adb_scratch + 2);
	area = ReadMacInt32(adb_scratch + 6);
	if (svc == 0)
		return 0;

	Execute68kTrap(0xa077, &r); /* CountADBs() */
	n = (int16)r.d[0];
	for (i = 1; i <= n; i++) {
		r.a[0] = adb_scratch;
		r.d[0] = i;
		Execute68kTrap(0xa078, &r); /* GetIndADB() */
		if ((uint8)r.d[0] != adr)
				continue;
		base = adb_base + 4 + ADB_ENTRY_STRIDE * (i - 1);
		if (ReadMacInt32(base) == svc
				&& ReadMacInt32(base + 4) == area)
			return base; /* stride confirmed */
		break;
	}
	return 0;
}

#if ADB_MOUSE_LOG
/* Everything the ADB Manager thinks is on the bus, next to the raw ADBBase
   table the stride-12 assumption reads. If the mouse entry we pick does not
   match its GetADBInfo service routine, our Talk 0 packets are going to some
   other device's driver and nothing downstream can work. */
static void adb_log_table(uint32 adb_base)
{
	M68kRegisters r;
	int n, i;
	memset(&r, 0, sizeof(r));

	if (adb_scratch == 0)
		return;
	Execute68kTrap(0xa077, &r); /* CountADBs() */
	n = (int16)r.d[0];
	ALOG("table: ADBBase=%08x CountADBs=%d mouse_adr=%d key_adr=%d "
		"mouse_handler=%d", adb_base, n, mouse_reg_3[0] & 0x0f,
		key_reg_3[0] & 0x0f, mouse_reg_3[1]);
	for (i = 1; i <= n && i <= 16; i++) {
		uint32 svc, area, entry;
		uint8 adr, devtype;
		const char *match = "*** STRIDE MISMATCH ***";

		r.a[0] = adb_scratch;
		r.d[0] = i;
		Execute68kTrap(0xa078, &r); /* GetIndADB() */
		adr = (uint8)r.d[0];
		devtype = ReadMacInt8(adb_scratch);
		svc = ReadMacInt32(adb_scratch + 2);
		area = ReadMacInt32(adb_scratch + 6);
		entry = adb_base + 4 + ADB_ENTRY_STRIDE * (i - 1);
		if (ReadMacInt32(entry) == svc && ReadMacInt32(entry + 4) == area)
			match = "MATCH";
		ALOG("  [%2d] adr=%2d devType=%02x svc=%08x area=%08x | "
			"entry@%08x svc=%08x area=%08x %s", i, adr, devtype,
			svc, area, entry, ReadMacInt32(entry), ReadMacInt32(entry + 4),
				match);
	}
}
#endif

static void adb_update_bases(uint32 adb_base)
{
	int i;
	adb_key_base = adb_resolve_entry(adb_base, key_reg_3[0] & 0x0f);
	if (adb_key_base == 0)
		adb_key_base = adb_base + 4; /* old behaviour */
	adb_mouse_base = adb_resolve_entry(adb_base, mouse_reg_3[0] & 0x0f);
	if (adb_mouse_base == 0)
		adb_mouse_base = adb_base + 16;
	adb_bases_for = adb_base;
	adb_bases_valid = true;
#if ADB_MOUSE_LOG
	{
		const char *mfall = "";
		const char *kfall = "";

		if (adb_mouse_base == adb_base + 16)
			mfall = " [FALLBACK +16]";
		if (adb_key_base == adb_base + 4)
			kfall = " [FALLBACK +4]";
		adb_log_table(adb_base);
		ALOG("bases: mouse=%08x%s (svc=%08x area=%08x) key=%08x%s",
			adb_mouse_base, mfall, ReadMacInt32(adb_mouse_base),
			ReadMacInt32(adb_mouse_base + 4), adb_key_base, kfall);
	}
#endif
}

/* ADBBase with the two device entries resolved.  ADBInterrupt used to run on
   whatever ADBVBL had last left in the statics -- nothing at all before the
   first VBL, and a stale entry after any re-address. */
static uint32 adb_begin(void)
{
	uint32 adb_base = ReadMacInt32(0xcf8);

	if (!adb_base || adb_base == 0xffffffff)
		return 0;
	if (!adb_bases_valid || adb_bases_for != adb_base)
		adb_update_bases(adb_base);
	return adb_base;
}

/* Hand one Talk 0 packet to the guest's mouse driver, the way the ADB
   Manager's polling does on real hardware. */

static void mouse_adb_deliver(uint32 adb_base, uint32 mouse_base, uint32 tmp_data)
{
	M68kRegisters r;
	uint8 pkt[8];
	uint8 n, i;

	if (mouse_base == 0 || ReadMacInt32(mouse_base) == 0) {
		uint32 svc = 0;

		if (mouse_base)
			svc = ReadMacInt32(mouse_base);
		ALOG("tx: SKIPPED mouse_base=%08x svc=%08x dx=%d dy=%d", mouse_base,
			svc, mouse_dx, mouse_dy);
		return;
	}

#ifdef POWERPC_ROM
	/* Send at most one movement packet until the guest has read the last
	   one, because it only has room to hold one; button presses always go. */
	static int held_ticks = 0;
	uint32 area = ReadMacInt32(mouse_base + 4);

	if (area != 0 && ReadMacInt8(area + 0x84) != 0
			&& mouse_button[0] == old_mouse_button[0]
			&& mouse_button[1] == old_mouse_button[1]
			&& mouse_button[2] == old_mouse_button[2]
			&& ++held_ticks < 30)	/* if the task stopped consuming, don't starve */
		return;
	held_ticks = 0;
#endif

	if ((n = mouse_adb_pack(0, pkt)) != 0) {
#if ADB_MOUSE_LOG
		char hex[32];
		uint8 cmd;
#endif
		WriteMacInt8(tmp_data, n);
		for (i = 0; i < n; i++)
			WriteMacInt8(tmp_data + 1 + i, pkt[i]);
		r.a[0] = tmp_data;
		r.a[1] = ReadMacInt32(mouse_base);
		r.a[2] = ReadMacInt32(mouse_base + 4);
		r.a[3] = adb_base;
		r.d[0] = (mouse_reg_3[0] << 4) | 0x0c;	// Talk 0
#if ADB_MOUSE_LOG
		cmd = (uint8)r.d[0];	/* Execute68k clobbers d0 */
#endif
		Execute68k(r.a[1], &r);
#if ADB_MOUSE_LOG
		ALOG("tx: cmd=%02x [%s] svc=%08x area=%08x left=%d,%d", cmd,
			adb_hex(hex, sizeof(hex), pkt, n),
			ReadMacInt32(mouse_base), ReadMacInt32(mouse_base + 4),
			mouse_dx, mouse_dy);
		if (adb_snapshot_diff("tx") == 0)
			ALOG("tx: changed nothing");
#endif
	}
}

/* Put the guest pointer where the host pointer is. */

static void mouse_adb_place(uint32 mouse_base, int h, int v)
{
#ifdef POWERPC_ROM
	/* Never raise CrsrNew before the mouse driver has registered its cursor
	   device.  With an empty device list the cursor task walks off a null
	   pointer and writes the position into lowmem 0x8/0xc -- boot-time
	   corruption that crashes later at a garbage pointer. */
	if (mouse_base == 0 || ReadMacInt32(mouse_base) == 0)
		return;
	{
		uint32 area = ReadMacInt32(mouse_base + 4);

		if (area == 0 || ReadMacInt32(area + 4) == 0)
			return;
	}
#endif
	/* Write the position into low memory rather than calling
	   CursorDeviceMoveTo, because the ROM applies this write later and it
	   therefore wins against a game moving the pointer at the same time. */
	WriteMacInt16(0x82a, h);
	WriteMacInt16(0x828, v);
	WriteMacInt16(0x82e, h);
	WriteMacInt16(0x82c, v);
	WriteMacInt8(0x8ce, ReadMacInt8(0x8cf));	// CrsrCouple -> CrsrNew
#ifdef POWERPC_ROM
	uint32 area;

	if (mouse_base != 0 && (area = ReadMacInt32(mouse_base + 4)) != 0) {
		/* The ROM used to discard accumulated motion after an absolute
		   position, which is patched out because games re-centring every
		   frame starved the cursor of all relative motion.  Placement still
		   needs that discard -- the counts this tick's packet carried are
		   the same motion the placement just applied, and the service
		   routine has already shown them to anyone hooking the bus -- so
		   reproduce the ROM's wipe here, scoped to our own driver record. */
		WriteMacInt32(area + 0x70, 0);
		WriteMacInt32(area + 0x74, 0);
		WriteMacInt32(area + 0x78, 0);
		WriteMacInt32(area + 0x7c, 0);
		WriteMacInt16(area + 0x80, 0xff98);
		WriteMacInt8(area + 0x84, 0);
		ALOG("place: WE WIPED mouse driver accumulators at %08x", area);
	}
#endif
#if ADB_MOUSE_LOG
	uint32 logarea = 0;

	if (mouse_base)
		logarea = ReadMacInt32(mouse_base + 4);
	ALOG("place: WE WROTE lowmem MTemp/RawMouse=%d,%d CrsrNew=%02x dev=%08x",
		v, h, ReadMacInt8(0x8ce), logarea);
	if (adb_snapshot_diff("place") == 0)
		ALOG("place: *** lowmem write CHANGED NOTHING WE WATCH ***");
#endif
}

static bool mouse_adb_pointer_hidden(void)
{
	return (int16)ReadMacInt16(0x8d0) < 0;
}

static bool mouse_adb_relative_wanted(void)
{
	static uint16 seen;
	static bool primed = false, latched = false;
	bool hidden = mouse_adb_pointer_hidden();
	bool repositioned = false;
#ifdef POWERPC_ROM
	uint32 buf = ReadMacInt32(0x2ae);		/* lowmem ROMBase */

	/* Read every tick, so that hiding the pointer does not compare against
	   an old count and act on somebody else's moves. */
	if (buf != 0) {
		uint16 total = ReadMacInt16(buf + CURSOR_LOG_BUFFER + 2);

		if (!primed) {
			primed = true;
			seen = total;
		} else if (total != seen) {
			seen = total;
			repositioned = true;
		}
	}
#endif
	if (!hidden) {
		latched = false;
		return false;
	}
	if (repositioned)
		latched = true;
	return latched;
}

/* Run one tick of the mouse: report movement, then place the pointer. */

static void mouse_adb_tick(uint32 adb_base, uint32 mouse_base, uint32 tmp_data)
{
	int host_h, host_v, last_h, last_v;
	bool grabbed, moved, relative;

	relative = mouse_adb_relative_wanted();

	B2_lock_mutex(mouse_lock);
	grabbed = relative_mouse;
	if (grabbed) {
		mouse_dx += mouse_x;
		mouse_dy += mouse_y;
		mouse_x = mouse_y = 0;
	}
	host_h = mouse_x;
	host_v = mouse_y;
	B2_unlock_mutex(mouse_lock);

	last_h = old_mouse_x;
	last_v = old_mouse_y;

	/* When placing the pointer, do not also send movement counts, or the
	   same movement is applied twice and the pointer jitters. */
	moved = !grabbed && mouse_host_valid
		&& (host_h != last_h || host_v != last_v);
	{
		/* Counts are stale when the mode that accumulated them ends, and
		   only then: zeroing them on every placing tick also zeroes counts
		   a button packet is still owed. */
		static uint8 last_mode = 0;
		uint8 now_mode = 0;

		if (grabbed)
			now_mode = 2;
		else if (relative)
			now_mode = 1;

		if (now_mode == 0 && last_mode != 0)
			mouse_dx = mouse_dy = 0;
		last_mode = now_mode;
	}
	/* No pointer on screen to place under: send motion, not a position. */
	if (!grabbed && relative && moved) {
		mouse_dx += host_h - last_h;
		mouse_dy += host_v - last_v;
	}
	if (!grabbed && !mouse_host_valid)
		moved = true;	/* first sample after a mode switch: place, do not differ */
	old_mouse_x = host_h;
	old_mouse_y = host_v;
	mouse_host_valid = true;

	/* Undelivered counts are bounded. A real mouse has a small counter and a
	   bus nobody is polling loses motion; it does not save up everything that
	   happened before the driver loaded and fire it in one burst. */
	if (mouse_dx > 2048)
		mouse_dx = 2048;
	else if (mouse_dx < -2048)
		mouse_dx = -2048;
	if (mouse_dy > 2048)
		mouse_dy = 2048;
	else if (mouse_dy < -2048)
		mouse_dy = -2048;

#if ADB_MOUSE_LOG
	const char *mode = "tablet";

	if (grabbed)
		mode = "grab";
	else if (relative)
		mode = "counts";
	if (mouse_dx || mouse_dy || moved || button_read_ptr != button_write_ptr)
		ALOG("tick: %s host=%d,%d prev=%d,%d counts=%d,%d moved=%d btn=%d%d%d",
			mode,
			host_h, host_v, last_h, last_v,
			mouse_dx, mouse_dy, moved,
			mouse_button[0], mouse_button[1], mouse_button[2]);
#endif

	/* A button edge has to reach the driver as its own packet or a click
	   inside one tick is swallowed. */
	while (button_read_ptr != button_write_ptr) {
		uint8 button = button_buffer[button_read_ptr];
		button_read_ptr = (button_read_ptr + 1) % BUTTON_BUFFER_SIZE;
		mouse_button[button & 0x3] = (button & 0x80) == 0;
		mouse_adb_deliver(adb_base, mouse_base, tmp_data);
	}
	mouse_adb_deliver(adb_base, mouse_base, tmp_data);

	if (!grabbed && moved && !relative)
		mouse_adb_place(mouse_base, host_h, host_v);
}

#if ADB_MOUSE_LOG
/* Log which cursor devices exist and which one applications are handed. */
static void adb_log_probe(uint32 adb_base)
{
	M68kRegisters r;
	uint32 dispatch, sentinel, dev, mouse_area;
	const char *path;
	int i;
	memset(&r, 0, sizeof(r));

	dev = 0;
	mouse_area = 0;
	i = 0;
	(void)dev;
	(void)mouse_area;

	r.d[0] = 0xaadb;
	Execute68kTrap(0xa746, &r);		/* GetToolTrapAddress */
	dispatch = r.a[0];
	r.d[0] = 0xaa9f;
	Execute68kTrap(0xa746, &r);
	sentinel = r.a[0];
	path = "CursorDeviceMoveTo";
	if (dispatch == sentinel)
		path = "*** LOWMEM ***";
	ALOG("probe: ADBBase=%08x CursorDeviceDispatch=%08x sentinel(AA9F)=%08x "
		"-> apps take the %s path", adb_base, dispatch, sentinel,
		path);
	ALOG("probe: JCrsrTask=%08x CrsrCouple=%02x CrsrNew=%02x screen=%dx%d",
		ReadMacInt32(0x8ee), ReadMacInt8(0x8cf), ReadMacInt8(0x8ce),
		screen_width, screen_height);

#if ADB_MOUSE_LOG_CURSOR_DEVICES && defined(POWERPC_ROM)
	mouse_area = 0;
	if (adb_mouse_base)
		mouse_area = ReadMacInt32(adb_mouse_base + 4);
	WriteMacInt32(adb_scratch, 0);
	for (i = 0; i < 8; i++) {
		static const uint8 proc_template[] = {
			0x2f, 0x08,		// move.l a0,-(sp)
			0x70, 0x0b,		// moveq #11,d0 (NextDevice)
			0xaa, 0xdb,		// CursorDeviceDispatch
			M68K_RTS >> 8, M68K_RTS & 0xff
		};
		BUILD_SHEEPSHAVER_PROCEDURE(proc);
		const char *which;

		r.a[0] = adb_scratch;
		Execute68k(proc, &r);
		dev = ReadMacInt32(adb_scratch);
		if (dev == 0)
			break;
		which = "(not the mouse)";
		if (dev == mouse_area)
			which = "== ADB MOUSE data area";
		ALOG("probe: cursor device[%d]=%08x %s | %08x %08x %08x %08x",
			i, dev,
			which,
			ReadMacInt32(dev), ReadMacInt32(dev + 4),
			ReadMacInt32(dev + 8), ReadMacInt32(dev + 12));
		if (i == 0)
			adb_snapshot_region(2, "cdev0", dev, 256);
		else if (i == 1)
			adb_snapshot_region(3, "cdev1", dev, 256);
		if (i == 0)
			/* NextDevice hands out driver records; +4 of each is the one
			   CursorDevRec they all share.  That is where MoveTo writes the
			   absolute position and raises the +0x14 flag the cursor task
			   wipes accumulated motion on, so watch the record itself. */
			adb_snapshot_region(4, "shared", ReadMacInt32(dev + 4), 64);
	}
	ALOG("probe: %d cursor device(s); ADB mouse data area=%08x", i, mouse_area);
#endif
	/* 0x800..0x8ff is the whole cursor block. 0x170 is MBState without
	   dragging in Ticks at 0x16a, which would report a change every VBL.
	   ADBBase stops short of the +0x163 scratch we write packets into. */
	adb_snapshot_region(0, "cursor", 0x800, 256);
	adb_snapshot_region(1, "mbstate", 0x170, 16);
	adb_snapshot_region(6, "adbbase", adb_base, 0x160);
	adb_snapshot_take();
	ALOG("probe: watching cursor lowmem 0x800+256, MBState 0x170+16, both "
		"driver records, the shared CursorDevRec+64, ADBBase+0x160; every "
		"changed 16-bit field is reported against tx / place / guest");
}

/* Log the low memory cursor values whenever they change. */
static void adb_log_watch(void)
{
	static uint32 last_mouse, last_raw, last_mtemp;
	uint32 m = ReadMacInt32(0x830), raw = ReadMacInt32(0x82c);
	uint32 mt = ReadMacInt32(0x828);
	char buf[192];

	if (m == last_mouse && raw == last_raw && mt == last_mtemp)
		return;
	last_mouse = m;
	last_raw = raw;
	last_mtemp = mt;
	ALOG("watch: %s", adb_lm(buf, sizeof(buf)));
}

static void adb_log_moveto(void)
{
#ifdef POWERPC_ROM
	uint32 buf = ReadMacInt32(0x2ae);	/* lowmem ROMBase */
	static uint16 seen = 0;
	static bool primed = false;
	uint16 total;

	if (buf == 0)
		return;
	buf += CURSOR_LOG_BUFFER;
	total = ReadMacInt16(buf + 2);
	if (!primed) {
		primed = true;
		seen = total;
		return;
	}
	while (seen != total) {
		uint32 e;

		seen++;
		e = buf + 8 + (seen & 31) * 8;
		{
			uint32 by = ReadMacInt32(e + 4);
			uint32 g = 0, cdm = 0;
			int off = 0;
			uint8 enx = 0xff, eny = 0xff;
			uint32 ratex = 0, ratey = 0, accx = 0, accy = 0;

			if (adb_firebird_area) {
				g = ReadMacInt32(adb_firebird_area + 0x11a);
				cdm = ReadMacInt16(adb_firebird_area + 0x10a);
			}
			if (adb_firebird_service)
				off = (int)(by - adb_firebird_service);
			if (g) {
				enx = ReadMacInt8(g + 0x22);
				eny = ReadMacInt8(g + 0x2e);
				ratex = ReadMacInt32(g + 0x26);
				ratey = ReadMacInt32(g + 0x32);
				accx = ReadMacInt32(g + 0x2a);
				accy = ReadMacInt32(g + 0x36);
			}

			/* Vertical position is stored first.  "svc" is how far the
			   caller is from the Firebird driver, which tells you whether
			   that driver made this call or something else did. */
			ALOG("moveto: v=%d h=%d by=%08x svc%+d | en=%02x,%02x "
				"rate=%08x,%08x acc=%08x,%08x cdm=%04x",
				(int16)ReadMacInt16(e), (int16)ReadMacInt16(e + 2), by,
				off, enx, eny, ratex, ratey, accx, accy, cdm);
		}
	}
#endif
}

static void adb_log_firebird_zone(void)
{
	/* Put the stick input, what the driver made of it, and where the pointer
	   ended up on one line, printed whenever any of it changes. */
	static int last[42];
	static int have_last = 0;
	int current[42], i, j;
	uint32 x, y, g, dev;

	if (adb_firebird_area == 0)
		return;
	x = adb_firebird_area + 0x1e4;
	y = adb_firebird_area + 0x1fa;
	g = ReadMacInt32(adb_firebird_area + 0x11a);
	dev = 0;
	if (adb_mouse_base != 0) {
		dev = ReadMacInt32(adb_mouse_base + 4);
		if (dev)
		dev = ReadMacInt32(dev + 4);
	}

	current[0] = current[1] = -99999;			/* raw SDL */
	current[2] = current[3] = current[4] = -1;			/* packed axes, button byte */
	for (i = 34; i < 42; i++)
		current[i] = -1;				/* delivered packet bytes */
#ifdef USE_SDL
	for (i = 0; i < joy_adb_count; i++)
		if (joy_adb_devs[i].real_devtype == JOY_GRAVIS_DEVTYPE) {
			current[0] = JoyManagerAxis(joy_adb_devs[i].dev, 0);
			current[1] = JoyManagerAxis(joy_adb_devs[i].dev, 1);
			if (joy_adb_devs[i].last_packet_len >= 5) {
				current[2] = (int)joy_adb_devs[i].last_packet[3] - 128;
				current[3] = (int)joy_adb_devs[i].last_packet[4] - 128;
				current[4] = joy_adb_devs[i].last_packet[0];
			}
			/* Log the whole packet, because any byte changing makes the
			   driver run, including axes this line used to leave out. */
			for (j = 0; j < joy_adb_devs[i].last_packet_len && j < 8; j++)
				current[34 + j] = joy_adb_devs[i].last_packet[j];
			break;
		}
#endif
	current[5] = (int16)ReadMacInt16(adb_firebird_area + 0x2e);	/* how far the driver thinks the stick is pushed */
	current[6] = (int16)ReadMacInt16(adb_firebird_area + 0x30);
	current[7] = (int16)ReadMacInt16(x + 0x12);			/* zone */
	current[8] = (int16)ReadMacInt16(y + 0x12);
	current[9] = (int16)ReadMacInt16(x + 0x10);			/* remembered pos */
	current[10] = (int16)ReadMacInt16(y + 0x10);
	current[11] = current[12] = current[13] = current[14] = -1;	/* VBL count, enables */
	current[15] = current[16] = 0;				/* rates */
	current[17] = current[18] = current[19] = -1;		/* device pos, MoveTo flag */
	if (g) {
		current[11] = (int)ReadMacInt32(g + 0x1e);
		current[12] = ReadMacInt8(g + 0x1b);
		current[13] = ReadMacInt8(g + 0x22);
		current[14] = ReadMacInt8(g + 0x2e);
		current[15] = (int)ReadMacInt32(g + 0x26);
		current[16] = (int)ReadMacInt32(g + 0x32);
	}
	if (dev) {
		current[17] = (int16)ReadMacInt16(dev + 0xc);
		current[18] = (int16)ReadMacInt16(dev + 0x8);
		current[19] = ReadMacInt8(dev + 0x14);
	}
	current[20] = (int)ReadMacInt32(0x828);			/* MTemp */
	current[21] = (int)ReadMacInt32(0x82c);			/* RawMouse */
	current[22] = (int)ReadMacInt32(0x830);			/* Mouse */
	current[23] = (ReadMacInt8(0x8ce) << 16) | (ReadMacInt8(0x8cf) << 8)
		| ReadMacInt8(0x8cd);				/* New/Coup/Busy */

	/* The five settings per axis that decide how the driver moves the
	   pointer, which nothing else in this line reports. */
	for (i = 0; i < 2; i++) {
		uint32 s = x;

		if (i)
			s = y;

		current[24 + i * 5] = (int16)ReadMacInt16(s + 0x08);	/* null zone */
		current[25 + i * 5] = (int16)ReadMacInt16(s + 0x0a);	/* fine zone */
		current[26 + i * 5] = (int)ReadMacInt32(s + 0x04);	/* 16.16 scale */
		current[27 + i * 5] = (int16)ReadMacInt16(s + 0x0e);	/* speed % */
		current[28 + i * 5] = ReadMacInt8(s + 0x14);	/* 0 = rate mode */
	}

	if (have_last) {
		for (i = 0; i < 42; i++)
			if (current[i] != last[i])
				break;
		if (i == 42)
			return;
	}
	have_last = 1;
	for (i = 0; i < 42; i++)
		last[i] = current[i];

	ALOG("fbz: sdl=%d,%d pack=%d,%d btn=%02x | drv d=%d,%d zone=%d,%d "
		"pos=%d,%d | vbl=%d on=%02x en=%02x,%02x rate=%08x,%08x | "
		"dev=%d,%d f=%02x | MT=%d,%d Raw=%d,%d Mouse=%d,%d NCB=%06x | "
		"setX[nz=%d fz=%d k=%08x sp=%d rate=%d] "
		"setY[nz=%d fz=%d k=%08x sp=%d rate=%d] | "
		"pkt=%d %d %d %d %d %d %d %d",
		current[0], current[1], current[2], current[3], current[4],
		current[5], current[6], current[7], current[8], current[9], current[10],
		current[11], current[12], current[13], current[14], current[15], current[16],
		current[17], current[18], current[19],
		(int16)(current[20] >> 16), (int16)current[20],
		(int16)(current[21] >> 16), (int16)current[21],
		(int16)(current[22] >> 16), (int16)current[22], current[23],
		current[24], current[25], current[26], current[27], current[28] == 0,
		current[29], current[30], current[31], current[32], current[33] == 0,
		current[34], current[35], current[36], current[37], current[38], current[39], current[40], current[41]);
}

/* Log one joystick poll: the raw input, the packet built from it, and
   whether that packet was sent to the driver. */
#ifdef USE_SDL
static void adb_log_joy(int i, uint8 reg, const uint8 *pkt, int n, bool unchanged)
{
	char axis_text[256], button_text[80], hex[32];
	JoyManagerDevice *dev = joy_adb_devs[i].dev;
	const char *verdict = "DELIVER";
	int axis_count, button_count, hat_count, c, o;

	if (unchanged)
		verdict = "skip";

	axis_count = button_count = hat_count = 0;
	if (dev) {
		axis_count = JoyManagerNumAxes(dev);
		button_count = JoyManagerNumButtons(dev);
		hat_count = JoyManagerNumHats(dev);
	}
	for (c = 0, o = 0; c < axis_count && o < (int)sizeof(axis_text) - 12; c++) {
		const char *separator = ",";

		if (c == 0)
			separator = "";
		o += snprintf(axis_text + o, sizeof(axis_text) - o, "%s%d", separator,
			(int)JoyManagerAxis(dev, c));
	}
	for (c = 0; c < hat_count && o < (int)sizeof(axis_text) - 12; c++)
		o += snprintf(axis_text + o, sizeof(axis_text) - o, " h%d=%02x", c,
			JoyManagerHat(dev, c));
	axis_text[o] = 0;
	for (c = 0, o = 0; c < button_count && o < (int)sizeof(button_text) - 2; c++)
		if (JoyManagerButton(dev, c))
			button_text[o++] = '1';
		else
			button_text[o++] = '0';
	button_text[o] = 0;

	ALOG("joy[%d]: %s adr=%2d type=%02x/%02x en=%d owns=%d hid=%d r%d "
		"| axes(%d)=%s button_text(%d)=%s | pkt[%s] | entry=%08x svc=%08x area=%08x",
		i, verdict,
		joy_adb_devs[i].reg_3[0] & 0x0f, joy_adb_devs[i].reg_3[1],
		joy_adb_devs[i].real_devtype, joy_adb_devs[i].enabled,
		joy_adb_owns_cursor(), mouse_adb_pointer_hidden(), reg, axis_count, axis_text, button_count, button_text,
		adb_hex(hex, sizeof(hex), pkt, n),
		joy_adb_devs[i].entry_base,
		ReadMacInt32(joy_adb_devs[i].entry_base),
		ReadMacInt32(joy_adb_devs[i].entry_base + 4));
}
#endif

static void adb_log_firebird_poll(void)
{
	static uint32 last_sum = 0;
	static unsigned settle_at = 0, last_beat = 0;
	uint32 sum = 0;
	int i;

	if (adb_firebird_area == 0)
		return;
	for (i = 0; i < 0x400; i += 2)
		sum = sum * 31u + ReadMacInt16(adb_firebird_area + i);
	/* Include the driver's globals, or changes there are never noticed. */
	{
		uint32 g = ReadMacInt32(adb_firebird_area + 0x11a);

		for (i = 0; g != 0 && i < 0x80; i += 2)
			sum = sum * 31u + ReadMacInt16(g + i);
	}
	if (sum != last_sum) {
		last_sum = sum;
		settle_at = adb_vbl_count + 3;	/* let a multi-tick write finish */
		return;
	}
	if (settle_at != 0 && adb_vbl_count >= settle_at) {
		settle_at = 0;
		last_beat = adb_vbl_count;
		adb_log_firebird("changed");
	} else if (adb_vbl_count - last_beat >= 900) {
		last_beat = adb_vbl_count;
		adb_log_firebird("beat");
	}
}

#endif

void ADBVBL(void)
{
	M68kRegisters r;
	uint32 adb_base, tmp_data;
	int i;

	adb_alloc_scratch();	/* deferred-task context: safe to call NewPtr here */
	adb_base = adb_begin();
	if (adb_base == 0)
		return;
	tmp_data = adb_scratch;
	joy_adb_sync_table(adb_base);

#if ADB_MOUSE_LOG
	{
		static bool probed = false;
		if (!probed && adb_mouse_base != 0 && ReadMacInt32(adb_mouse_base) != 0) {
			probed = true;
			adb_log_probe(adb_base);
		}
		adb_log_watch();
		adb_log_moveto();
		adb_log_firebird_zone();
		adb_log_firebird_poll();
		adb_snapshot_diff("guest");
		if ((adb_vbl_count % 180) == 0) {
			char hb[192];
			ALOG("beat: %s", adb_lm(hb, sizeof(hb)));
			const char *grab = "tablet";

			if (relative_mouse)
				grab = "GRABBED";
			ALOG("beat: counts=%d,%d host=%d,%d %s handler=%d adr=%d",
				mouse_dx, mouse_dy, mouse_x, mouse_y,
						grab,
				mouse_reg_3[1], mouse_reg_3[0] & 0x0f);
		}
	}
	adb_vbl_count++;
#endif

	/* The ADB Manager polls on a timer, not when the host happens to move a
	   pointer, and the mouse needs that heartbeat: it is how the guest gets
	   the cursor back once it stops moving the thing itself. */
	mouse_adb_tick(adb_base, adb_mouse_base, tmp_data);

	#if defined(USE_SDL)
	for (i = 0; i < joy_adb_count; i++) {
		uint8 pkt[8];
		uint8 n, j, reg, cmdlow;

		/* 1. has any driver claimed this device's table entry yet? */
		if (joy_adb_devs[i].entry_base == 0)
			joy_adb_devs[i].entry_base = adb_resolve_entry(adb_base,
				joy_adb_devs[i].reg_3[0] & 0x0f);
		if (joy_adb_devs[i].entry_base == 0)
				continue;

		/* 2. Gravis only: has its INIT adopted the device and have we
			switched on the driver's cursor stage? */
		if (!joy_adb_devs[i].enabled) {
			joy_adb_enable_gravis(i);
			if (!joy_adb_devs[i].enabled)
				continue;
		}

		/* 3. which register does this device's driver poll? */
		if (joy_adb_devs[i].real_devtype == JOY_THRUSTMASTER_DEVTYPE) {
			reg = 2;
			cmdlow = 0x0e;

			D(bug("ThrustMaster area %08x: %08x %08x %08x\n",
				ReadMacInt32(joy_adb_devs[i].entry_base + 4),
				ReadMacInt32(ReadMacInt32(joy_adb_devs[i].entry_base + 4)),
				ReadMacInt32(ReadMacInt32(joy_adb_devs[i].entry_base + 4) + 4),
				ReadMacInt32(ReadMacInt32(joy_adb_devs[i].entry_base + 4) 
					+ 8)));
		} else {
			reg = 0;
			cmdlow = 0x0c;
		}

		n = joy_adb_pack(i, reg, pkt);
		if (n == 0)
			continue;

		/* 4. real devices report on change, not on a timer */
		{
			bool unchanged = n == joy_adb_devs[i].last_packet_len
				&& memcmp(pkt, joy_adb_devs[i].last_packet, n) == 0;
#if ADB_MOUSE_LOG
			adb_log_joy(i, reg, pkt, n, unchanged);
#endif
			if (unchanged)
				continue;
		}
		memcpy(joy_adb_devs[i].last_packet, pkt, n);
		joy_adb_devs[i].last_packet_len = n;

		WriteMacInt8(tmp_data, n);
		for (j = 0; j < n; j++)
			WriteMacInt8(tmp_data + 1 + j, pkt[j]);

		r.a[0] = tmp_data;
		r.a[1] = ReadMacInt32(joy_adb_devs[i].entry_base);
		r.a[2] = ReadMacInt32(joy_adb_devs[i].entry_base + 4);
		r.a[3] = adb_base;
		r.d[0] = (joy_adb_devs[i].reg_3[0] << 4) | cmdlow; /* Talk reg */
		Execute68k(r.a[1], &r);
	}
	#endif /* #if defined(USE_SDL) */
}

void ADBInterrupt(void)
{
	M68kRegisters r;

	// Return if ADB is not initialized
	uint32 adb_base = adb_begin();
	if (adb_base == 0)
		return;
	uint32 tmp_data = adb_base + 0x163;	// Temporary storage for faked ADB data

	uint32 key_base = adb_key_base;

	mouse_adb_tick(adb_base, adb_mouse_base, tmp_data);

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
