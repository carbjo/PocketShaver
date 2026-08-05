/*
 *  joymanager.cpp - SDL-backed replacement for the classic .JoyManager driver
 *
 *  The original driver returns pointers to driver-owned Mac memory.  In
 *  particular, clients read JoySimpleData and the live values in analogue
 *  JoyElement records directly, and consume JoyEventQueue without making a
 *  Device Manager call.  The replacement therefore keeps the original guest
 *  layouts, rather than returning host-side snapshots.
 */

#include "sysdeps.h"
#include "joymanager.h"
#include "macos_util.h"
#include "xlowmem.h"

#ifdef USE_SDL
#include "my_sdl.h"
#endif

#define DEBUG 0
#include "debug.h"

enum {
	JOY_MAX_DEVICES = 8,
	JOY_MAX_AXES = 8,
	JOY_MAX_BUTTONS = 64,
	JOY_MAX_HATS = 4,
	JOY_EVENT_COUNT = 64,
	JOY_GUEST_STORAGE_SIZE = 0x4000
};

enum {
	kJoyXAxisAvailable = 0x0001,
	kJoyYAxisAvailable = 0x0002,
	kJoyRudderAvailable = 0x0004,
	kJoyThrottleAvailable = 0x0008,
	kJoyHatAvailable = 0x0100
};

enum {
	kJoyElemButton = 0,
	kJoyElemSelector = 1,
	kJoyElemAxis = 10000,
	kJoyUnknownLabel = 0x7fff,
	kJoyLabelXAxis = 0,
	kJoyLabelYAxis = 1,
	kJoyLabelThrottle = 6,
	kJoyLabelRudder = 7
};

enum {
	kJoyEvtDown = 2,
	kJoyEvtUp = 3,
	kJoyEvtPosition = 4
};

enum {
	kJoyCsStart = 1002,
	kJoyCsStop = 1003,
	kJoyCsGetSimpleData = 1004,
	kJoyCsGetCount = 1005,
	kJoyCsGetInfo = 1006,
	kJoyCsEnableDevice = 1007,
	kJoyCsGetEventQueue = 1010,
	kJoyCsGetElementName = 1016
};

enum {
	joySimpleFeatures = 0x00,
	joySimpleAxis = 0x04,
	joySimpleHat = 0x14,
	joySimpleSize = 0x16,

	joyInfoName = 0x04,
	joyInfoFeatures = 0x28,
	joyInfoElementCount = 0x32,
	joyInfoElements = 0x34,
	joyInfoSize = 0x38,

	joyElementKind = 0x00,
	joyElementLabel = 0x02,
	joyElementMin = 0x08,
	joyElementMax = 0x0c,
	joyElementValue = 0x10,
	joyElementSize = 0x14,

	joyQueueBufStart = 0x00,
	joyQueueBufEnd = 0x04,
	joyQueueReadPtr = 0x0c,
	joyQueueWriteCount = 0x12,
	joyQueueReadCount = 0x14,
	joyQueueOverflow = 0x16,
	joyQueueSize = 0x18,

	joyEventWhen = 0x00,
	joyEventDevice = 0x04,
	joyEventElement = 0x06,
	joyEventWhat = 0x08,
	joyEventValue = 0x0a,
	joyEventSize = 0x0c
};

#ifdef USE_SDL
struct JoyHostDevice {
	SDL_Joystick *joystick;
	char name[36];
	uint32 simple_addr;
	uint32 info_addr;
	uint32 elements_addr;
	int axis_count;
	int simple_axis_count;
	int button_count;
	int hat_count;
	int button_element;
	int hat_element;
	bool rudder_throttle;
	bool enabled;
	uint8 buttons[JOY_MAX_BUTTONS];
	uint8 hats[JOY_MAX_HATS];
};
#endif

static uint32 joy_storage_addr;
static uint32 joy_simple_addr;
static uint32 joy_queue_addr;
static uint32 joy_event_buf_addr;
static int joy_device_count;
static int joy_start_count;
static bool joy_prepared;

#ifdef USE_SDL
static JoyHostDevice joy_devices[JOY_MAX_DEVICES];
#endif

uint32 JoyManagerAlignFour(uint32 addr)
{
	return (addr + 3) & ~3U;
}

uint32 JoyManagerGuestStorageSize(void)
{
	return JOY_GUEST_STORAGE_SIZE;
}

#ifdef USE_SDL
int JoyManagerSDLNumDevices(void)
{
#if SDL_VERSION_ATLEAST(3, 0, 0)
	int count;
	SDL_JoystickID *ids;

	count = 0;
	ids = SDL_GetJoysticks(&count);
	if (ids != NULL)
		SDL_free(ids);
	return count;
#else
	return SDL_NumJoysticks();
#endif
}

SDL_Joystick *JoyManagerSDLOpenDevice(int index)
{
#if SDL_VERSION_ATLEAST(3, 0, 0)
	int count;
	SDL_JoystickID *ids;
	SDL_Joystick *joystick;

	count = 0;
	joystick = NULL;
	ids = SDL_GetJoysticks(&count);
	if (ids != NULL && index >= 0 && index < count)
		joystick = SDL_OpenJoystick(ids[index]);
	if (ids != NULL)
		SDL_free(ids);
	return joystick;
#else
	return SDL_JoystickOpen(index);
#endif
}

void JoyManagerSDLCloseDevice(SDL_Joystick *joystick)
{
	if (joystick == NULL)
		return;
#if SDL_VERSION_ATLEAST(3, 0, 0)
	SDL_CloseJoystick(joystick);
#else
	SDL_JoystickClose(joystick);
#endif
}

bool JoyManagerSDLDeviceAttached(SDL_Joystick *joystick)
{
#if SDL_VERSION_ATLEAST(3, 0, 0)
	return SDL_JoystickConnected(joystick);
#elif SDL_VERSION_ATLEAST(2, 0, 0)
	return SDL_JoystickGetAttached(joystick) != SDL_FALSE;
#else
	return joystick != NULL;
#endif
}

bool JoyManagerSDLHasRudderThrottle(SDL_Joystick *joystick)
{
#if SDL_VERSION_ATLEAST(3, 0, 0)
	return SDL_GetJoystickType(joystick) == SDL_JOYSTICK_TYPE_FLIGHT_STICK;
#elif SDL_VERSION_ATLEAST(2, 0, 6)
	return SDL_JoystickGetType(joystick) == SDL_JOYSTICK_TYPE_FLIGHT_STICK;
#else
	(void)joystick;
	return true;
#endif
}

const char *JoyManagerSDLDeviceName(SDL_Joystick *joystick, int index)
{
#if SDL_VERSION_ATLEAST(3, 0, 0)
	(void)index;
	return SDL_GetJoystickName(joystick);
#elif SDL_VERSION_ATLEAST(2, 0, 0)
	(void)index;
	return SDL_JoystickName(joystick);
#else
	(void)joystick;
	return SDL_JoystickName(index);
#endif
}

int JoyManagerSDLNumAxes(SDL_Joystick *joystick)
{
#if SDL_VERSION_ATLEAST(3, 0, 0)
	return SDL_GetNumJoystickAxes(joystick);
#else
	return SDL_JoystickNumAxes(joystick);
#endif
}

int JoyManagerSDLNumButtons(SDL_Joystick *joystick)
{
#if SDL_VERSION_ATLEAST(3, 0, 0)
	return SDL_GetNumJoystickButtons(joystick);
#else
	return SDL_JoystickNumButtons(joystick);
#endif
}

int JoyManagerSDLNumHats(SDL_Joystick *joystick)
{
#if SDL_VERSION_ATLEAST(3, 0, 0)
	return SDL_GetNumJoystickHats(joystick);
#else
	return SDL_JoystickNumHats(joystick);
#endif
}

int16 JoyManagerSDLAxis(SDL_Joystick *joystick, int axis)
{
#if SDL_VERSION_ATLEAST(3, 0, 0)
	return (int16)SDL_GetJoystickAxis(joystick, axis);
#else
	return (int16)SDL_JoystickGetAxis(joystick, axis);
#endif
}

uint8 JoyManagerSDLButton(SDL_Joystick *joystick, int button)
{
#if SDL_VERSION_ATLEAST(3, 0, 0)
	return (uint8)SDL_GetJoystickButton(joystick, button);
#else
	return SDL_JoystickGetButton(joystick, button);
#endif
}

uint8 JoyManagerSDLHat(SDL_Joystick *joystick, int hat)
{
#if SDL_VERSION_ATLEAST(3, 0, 0)
	return (uint8)SDL_GetJoystickHat(joystick, hat);
#else
	return (uint8)SDL_JoystickGetHat(joystick, hat);
#endif
}

void JoyManagerSDLUpdate(void)
{
#if SDL_VERSION_ATLEAST(3, 0, 0)
	SDL_UpdateJoysticks();
#else
	SDL_JoystickUpdate();
#endif
}

bool JoyManagerSDLInit(void)
{
	bool initialized;

	initialized = (SDL_WasInit(SDL_INIT_JOYSTICK) & SDL_INIT_JOYSTICK) != 0;
	if (!initialized) {
#if SDL_VERSION_ATLEAST(3, 0, 0)
		initialized = SDL_InitSubSystem(SDL_INIT_JOYSTICK);
#else
		initialized = SDL_InitSubSystem(SDL_INIT_JOYSTICK) == 0;
#endif
	}
	if (!initialized)
		return false;
#if SDL_VERSION_ATLEAST(3, 0, 0)
	SDL_SetJoystickEventsEnabled(false);
#else
	SDL_JoystickEventState(SDL_IGNORE);
#endif
	return true;
}
#endif

uint32 JoyManagerFeaturesForAxes(int axes, int hats)
{
	uint32 features;
	int i;

	features = 0;
	for (i = 0; i < axes && i < JOY_MAX_AXES; i++)
		features |= 1U << i;
	if (hats > 0)
		features |= kJoyHatAvailable;
	return features;
}

int JoyManagerAxisLabel(int axis, bool rudder_throttle)
{
	switch (axis) {
		case 0: return kJoyLabelXAxis;
		case 1: return kJoyLabelYAxis;
		case 2: return rudder_throttle ? kJoyLabelRudder : kJoyUnknownLabel;
		case 3: return rudder_throttle ? kJoyLabelThrottle : kJoyUnknownLabel;
	}
	return kJoyUnknownLabel;
}

int32 JoyManagerAxisNeutralValue(int axis, bool rudder_throttle)
{
	return JoyManagerAxisLabel(axis, rudder_throttle) ==
		kJoyLabelThrottle ? 8192 : 0;
}

void JoyManagerWriteElement(uint32 addr, int kind, int label,
	int32 min_value, int32 max_value, int32 value)
{
	WriteMacInt16(addr + joyElementKind, kind);
	WriteMacInt16(addr + joyElementLabel, label);
	WriteMacInt32(addr + joyElementMin, min_value);
	WriteMacInt32(addr + joyElementMax, max_value);
	WriteMacInt32(addr + joyElementValue, value);
}

#ifdef USE_SDL
void JoyManagerWriteDeviceInfo(JoyHostDevice *device)
{
	uint32 element;
	uint32 features;
	int name_len;
	int i;

	features = JoyManagerFeaturesForAxes(device->simple_axis_count,
		device->hat_count);
	name_len = (int)strlen(device->name);
	if (name_len > 35)
		name_len = 35;

	WriteMacInt8(device->info_addr + joyInfoName, name_len);
	if (name_len != 0)
		Host2Mac_memcpy(device->info_addr + joyInfoName + 1,
			device->name, name_len);
	WriteMacInt32(device->info_addr + joyInfoFeatures, features);
	WriteMacInt16(device->info_addr + joyInfoElementCount,
		device->axis_count + device->button_count + device->hat_count);
	WriteMacInt32(device->info_addr + joyInfoElements, device->elements_addr);

	element = device->elements_addr;
	for (i = 0; i < device->axis_count; i++) {
		int label;
		int32 min_value;
		int32 max_value;

		label = JoyManagerAxisLabel(i, device->rudder_throttle);
		min_value = -32768;
		max_value = 32767;
		if (label == kJoyLabelThrottle) {
			min_value = 0;
			max_value = 16384;
		}
		JoyManagerWriteElement(element, kJoyElemAxis, label,
			min_value, max_value,
			JoyManagerAxisNeutralValue(i, device->rudder_throttle));
		element += joyElementSize;
	}
	for (i = 0; i < device->button_count; i++) {
		JoyManagerWriteElement(element, kJoyElemButton,
			kJoyUnknownLabel, 0, 0, 0);
		element += joyElementSize;
	}
	for (i = 0; i < device->hat_count; i++) {
		JoyManagerWriteElement(element, kJoyElemSelector,
			kJoyUnknownLabel, 0, 8, 0);
		element += joyElementSize;
	}
}
#endif

void JoyManagerReset(void)
{
#ifdef USE_SDL
	int i;
#endif

#ifdef USE_SDL
	joy_prepared = false;
	for (i = 0; i < joy_device_count; i++) {
		JoyManagerSDLCloseDevice(joy_devices[i].joystick);
		joy_devices[i].joystick = NULL;
	}
	memset(joy_devices, 0, sizeof(joy_devices));
#else
	joy_prepared = false;
#endif
	joy_storage_addr = 0;
	joy_simple_addr = 0;
	joy_queue_addr = 0;
	joy_event_buf_addr = 0;
	joy_device_count = 0;
	joy_start_count = 0;
}

bool JoyManagerPrepare(void)
{
#ifdef USE_SDL
	int available;
	int i;

	JoyManagerReset();
	if (!JoyManagerSDLInit()) {
		D(bug("JoyManager: SDL joystick init failed: %s\n", SDL_GetError()));
		return false;
	}

	available = JoyManagerSDLNumDevices();
	if (available < 0)
		available = 0;
	if (available > JOY_MAX_DEVICES)
		available = JOY_MAX_DEVICES;

	for (i = 0; i < available; i++) {
		JoyHostDevice *device;
		SDL_Joystick *joystick;
		const char *name;
		int count;

		joystick = JoyManagerSDLOpenDevice(i);
		if (joystick == NULL)
			continue;

		device = &joy_devices[joy_device_count];
		memset(device, 0, sizeof(*device));
		device->joystick = joystick;
		device->rudder_throttle =
			JoyManagerSDLHasRudderThrottle(joystick);
		name = JoyManagerSDLDeviceName(joystick, i);
		if (name == NULL || name[0] == 0)
			name = "SDL Joystick";
		strncpy(device->name, name, sizeof(device->name) - 1);
		device->name[sizeof(device->name) - 1] = 0;

		count = JoyManagerSDLNumAxes(joystick);
		if (count < 0)
			count = 0;
		device->axis_count = count > JOY_MAX_AXES ? JOY_MAX_AXES : count;
		device->simple_axis_count = device->axis_count;
		/* Only a positively identified flight stick gives axes 2 and 3 the
		 * classic rudder/throttle meanings.  Other devices keep those raw
		 * axes as general JoyElements without false standard-axis labels. */
		if (!device->rudder_throttle && device->simple_axis_count > 2)
			device->simple_axis_count = 2;

		count = JoyManagerSDLNumButtons(joystick);
		if (count < 0)
			count = 0;
		device->button_count = count > JOY_MAX_BUTTONS ? JOY_MAX_BUTTONS : count;

		count = JoyManagerSDLNumHats(joystick);
		if (count < 0)
			count = 0;
		device->hat_count = count > JOY_MAX_HATS ? JOY_MAX_HATS : count;
		device->button_element = device->axis_count;
		device->hat_element = device->button_element + device->button_count;
		joy_device_count++;
	}

	joy_prepared = true;
	D(bug("JoyManager: found %d SDL joystick(s)\n", joy_device_count));
	return true;
#else
	JoyManagerReset();
	return false;
#endif
}

void JoyManagerResetQueue(void)
{
	if (joy_queue_addr == 0)
		return;

	Mac_memset(joy_event_buf_addr, 0, JOY_EVENT_COUNT * joyEventSize);
	WriteMacInt32(joy_queue_addr + joyQueueBufStart, joy_event_buf_addr);
	WriteMacInt32(joy_queue_addr + joyQueueBufEnd,
		joy_event_buf_addr + JOY_EVENT_COUNT * joyEventSize);
	WriteMacInt32(joy_queue_addr + joyQueueReadPtr, joy_event_buf_addr);
	WriteMacInt16(joy_queue_addr + joyQueueWriteCount, 0);
	WriteMacInt16(joy_queue_addr + joyQueueReadCount, 0);
	WriteMacInt8(joy_queue_addr + joyQueueOverflow, 0);
}

bool JoyManagerSetGuestStorage(uint32 addr, uint32 size)
{
#ifdef USE_SDL
	uint32 cursor;
	uint32 end;
	int i;

	if (!joy_prepared || addr == 0 || size < JOY_GUEST_STORAGE_SIZE)
		return false;

	joy_storage_addr = addr;
	Mac_memset(addr, 0, size);
	cursor = addr;
	end = addr + size;

	joy_simple_addr = cursor;
	cursor = JoyManagerAlignFour(cursor + joySimpleSize);
	joy_queue_addr = cursor;
	cursor = JoyManagerAlignFour(cursor + joyQueueSize);
	joy_event_buf_addr = cursor;
	cursor = JoyManagerAlignFour(cursor + JOY_EVENT_COUNT * joyEventSize);

	for (i = 0; i < joy_device_count; i++) {
		JoyHostDevice *device;
		uint32 element_bytes;
		uint32 simple_addr;
		uint32 info_addr;
		uint32 elements_addr;
		uint32 next_cursor;

		device = &joy_devices[i];
		element_bytes = (device->axis_count + device->button_count +
			device->hat_count) * joyElementSize;
		simple_addr = cursor;
		info_addr = JoyManagerAlignFour(simple_addr + joySimpleSize);
		elements_addr = JoyManagerAlignFour(info_addr + joyInfoSize);
		next_cursor = JoyManagerAlignFour(elements_addr + element_bytes);
		if (next_cursor > end) {
			JoyManagerReset();
			return false;
		}
		device->simple_addr = simple_addr;
		device->info_addr = info_addr;
		device->elements_addr = elements_addr;
		cursor = next_cursor;
		JoyManagerWriteDeviceInfo(device);
	}

	JoyManagerResetQueue();
	return true;
#else
	(void)addr;
	(void)size;
	return false;
#endif
}

#ifdef USE_SDL
int JoyManagerSDLHatPosition(uint8 hat)
{
	bool up;
	bool down;
	bool right;
	bool left;

	up = (hat & SDL_HAT_UP) != 0;
	down = (hat & SDL_HAT_DOWN) != 0;
	right = (hat & SDL_HAT_RIGHT) != 0;
	left = (hat & SDL_HAT_LEFT) != 0;
	if (up && right) return 5;
	if (up && left) return 6;
	if (down && right) return 7;
	if (down && left) return 8;
	if (up) return 1;
	if (down) return 2;
	if (right) return 3;
	if (left) return 4;
	return 0;
}

void JoyManagerPutEvent(int device_index, int element_index, int what, int value)
{
	uint16 write_count;
	uint16 read_count;
	uint16 pending;
	uint32 event_addr;

	if (joy_queue_addr == 0)
		return;
	write_count = ReadMacInt16(joy_queue_addr + joyQueueWriteCount);
	read_count = ReadMacInt16(joy_queue_addr + joyQueueReadCount);
	pending = (uint16)(write_count - read_count);
	if (pending >= JOY_EVENT_COUNT) {
		WriteMacInt8(joy_queue_addr + joyQueueOverflow, 1);
		return;
	}

	event_addr = joy_event_buf_addr + (write_count % JOY_EVENT_COUNT) * joyEventSize;
	WriteMacInt32(event_addr + joyEventWhen, ReadMacInt32(0x016a));
	WriteMacInt16(event_addr + joyEventDevice, device_index + 1);
	WriteMacInt16(event_addr + joyEventElement, element_index);
	WriteMacInt16(event_addr + joyEventWhat, what);
	WriteMacInt16(event_addr + joyEventValue, value);
	WriteMacInt16(joy_queue_addr + joyQueueWriteCount, write_count + 1);
}

void JoyManagerApplyButtonState(int device_index, int button,
	uint8 value)
{
	JoyHostDevice *device;

	if (device_index < 0 || device_index >= joy_device_count)
		return;
	device = &joy_devices[device_index];
	if (!device->enabled || button < 0 || button >= device->button_count)
		return;
	value = value != 0;
	if (value == device->buttons[button])
		return;
	JoyManagerPutEvent(device_index, device->button_element + button,
		value ? kJoyEvtDown : kJoyEvtUp, 0);
	device->buttons[button] = value;
}

void JoyManagerApplyHatState(int device_index, int hat, uint8 value)
{
	JoyHostDevice *device;

	if (device_index < 0 || device_index >= joy_device_count)
		return;
	device = &joy_devices[device_index];
	if (!device->enabled || hat < 0 || hat >= device->hat_count)
		return;
	if (value == device->hats[hat])
		return;
	JoyManagerPutEvent(device_index, device->hat_element + hat,
		kJoyEvtPosition, JoyManagerSDLHatPosition(value));
	device->hats[hat] = value;
}

void JoyManagerSnapshotDevice(JoyHostDevice *device)
{
	int i;

	if (!JoyManagerSDLDeviceAttached(device->joystick)) {
		memset(device->buttons, 0, sizeof(device->buttons));
		memset(device->hats, 0, sizeof(device->hats));
		return;
	}
	for (i = 0; i < device->button_count; i++)
		device->buttons[i] = JoyManagerSDLButton(device->joystick, i);
	for (i = 0; i < device->hat_count; i++)
		device->hats[i] = JoyManagerSDLHat(device->joystick, i);
}

int32 JoyManagerAxisValue(JoyHostDevice *device, int axis)
{
	int32 value;

	value = JoyManagerSDLAxis(device->joystick, axis);
	switch (JoyManagerAxisLabel(axis, device->rudder_throttle)) {
		case kJoyLabelThrottle:
			value = (value + 32770) >> 2;
			break;
		case kJoyLabelYAxis:
			value = -value; /* API reports up as positive */
			break;
	}
	return value;
}

bool JoyManagerWriteDeviceState(JoyHostDevice *device)
{
	bool active;
	uint32 features;
	int i;

	active = device->enabled &&
		JoyManagerSDLDeviceAttached(device->joystick);
	Mac_memset(device->simple_addr, 0, joySimpleSize);
	features = active ?
		JoyManagerFeaturesForAxes(device->simple_axis_count,
			device->hat_count) : 0;
	WriteMacInt32(device->simple_addr + joySimpleFeatures, features);

	for (i = 0; i < device->axis_count; i++) {
		int32 value;

		value = active ? JoyManagerAxisValue(device, i) :
			JoyManagerAxisNeutralValue(i, device->rudder_throttle);
		if (active && i < device->simple_axis_count)
			WriteMacInt16(device->simple_addr + joySimpleAxis + i * 2,
				value);
		WriteMacInt32(device->elements_addr + i * joyElementSize +
			joyElementValue, value);
	}
	if (active && device->hat_count > 0)
		WriteMacInt16(device->simple_addr + joySimpleHat,
			JoyManagerSDLHatPosition(JoyManagerSDLHat(device->joystick, 0)));
	return active;
}

bool JoyManagerWriteElementName(uint32 addr, int device_index,
	int element_index)
{
	JoyHostDevice *device;
	char name[32];
	int axis;
	int button;
	int hat;

	if (addr == 0 || device_index < 1 || device_index > joy_device_count)
		return false;
	device = &joy_devices[device_index - 1];
	if (element_index < 0 || element_index >= device->axis_count +
		device->button_count + device->hat_count)
		return false;

	axis = element_index;
	button = element_index - device->button_element;
	hat = element_index - device->hat_element;
	if (axis < device->axis_count) {
		switch (JoyManagerAxisLabel(axis, device->rudder_throttle)) {
			case kJoyLabelXAxis: strcpy(name, "X Axis"); break;
			case kJoyLabelYAxis: strcpy(name, "Y Axis"); break;
			case kJoyLabelRudder: strcpy(name, "Rudder"); break;
			case kJoyLabelThrottle: strcpy(name, "Throttle"); break;
			default: sprintf(name, "Axis %d", axis + 1); break;
		}
	} else if (button >= 0 && button < device->button_count) {
		sprintf(name, "Button %d", button + 1);
	} else {
		sprintf(name, "Hat %d", hat + 1);
	}
	Host2Mac_memcpy(addr, name, strlen(name) + 1);
	return true;
}

void JoyManagerUpdateState(void)
{
	JoyHostDevice *shared_device;
	JoyHostDevice *fallback_device;
	int i;

	if (joy_simple_addr == 0)
		return;

	shared_device = NULL;
	fallback_device = NULL;
	for (i = 0; i < joy_device_count; i++) {
		JoyHostDevice *device;

		device = &joy_devices[i];
		if (!JoyManagerWriteDeviceState(device))
			continue;
		if (fallback_device == NULL)
			fallback_device = device;
		if (shared_device == NULL && device->simple_axis_count > 0)
			shared_device = device;
	}

	if (shared_device == NULL)
		shared_device = fallback_device;
	Mac_memset(joy_simple_addr, 0, joySimpleSize);
	if (shared_device != NULL)
		Mac2Mac_memcpy(joy_simple_addr, shared_device->simple_addr,
			joySimpleSize);
}
#endif

void JoyManagerVBL(void)
{
#ifdef USE_SDL
	int i;

	if (!joy_prepared || joy_storage_addr == 0)
		return;
	JoyManagerSDLUpdate();
	JoyManagerUpdateState();
	if (joy_start_count == 0)
		return;

	for (i = 0; i < joy_device_count; i++) {
		JoyHostDevice *device;
		bool attached;
		int j;

		device = &joy_devices[i];
		if (!device->enabled)
			continue;
		attached = JoyManagerSDLDeviceAttached(device->joystick);
		for (j = 0; j < device->button_count; j++) {
			uint8 value;

			value = attached ? JoyManagerSDLButton(device->joystick, j) : 0;
			JoyManagerApplyButtonState(i, j, value);
		}
		for (j = 0; j < device->hat_count; j++) {
			uint8 value;

			value = attached ? JoyManagerSDLHat(device->joystick, j) : 0;
			JoyManagerApplyHatState(i, j, value);
		}
	}
#endif
}

bool JoyManagerWriteOutWord(uint32 pb, int value)
{
	uint32 result;

	result = ReadMacInt32(pb + csParam);
	if (result == 0)
		return false;
	WriteMacInt16(result, value);
	return true;
}

bool JoyManagerWriteOutPtr(uint32 pb, uint32 value)
{
	uint32 result;

	result = ReadMacInt32(pb + csParam);
	if (result == 0)
		return false;
	WriteMacInt32(result, value);
	return true;
}

int16 JoyManagerOpen(uint32 pb, uint32 dce)
{
	(void)pb;
	if (!joy_prepared || joy_storage_addr == 0)
		return openErr;
	WriteMacInt32(dce + dCtlPosition, 0);
	return noErr;
}

int16 JoyManagerControl(uint32 pb, uint32 dce)
{
	int16 code;

	(void)dce;
	code = (int16)ReadMacInt16(pb + csCode);
	D(bug("JoyManagerControl %d\n", code));
	switch (code) {
		case kJoyCsStart:
#ifdef USE_SDL
			JoyManagerSDLUpdate();
#endif
			if (joy_start_count == 0) {
				JoyManagerResetQueue();
#ifdef USE_SDL
				{
					int i;
					for (i = 0; i < joy_device_count; i++)
						JoyManagerSnapshotDevice(&joy_devices[i]);
				}
#endif
			}
			if (joy_start_count < 0x7fff)
				joy_start_count++;
#ifdef USE_SDL
			JoyManagerUpdateState();
#endif
			return noErr;

		case kJoyCsStop:
			if (joy_start_count > 0)
				joy_start_count--;
			return JoyManagerWriteOutWord(pb, joy_start_count) ? noErr : paramErr;

		case kJoyCsGetSimpleData:
			return JoyManagerWriteOutPtr(pb, joy_simple_addr) ? noErr : paramErr;

		case kJoyCsGetCount:
			return JoyManagerWriteOutWord(pb, joy_device_count) ? noErr : paramErr;

		case kJoyCsGetInfo: {
			int index;
			uint32 info;

			index = (int16)ReadMacInt16(pb + csParam + 4);
			info = 0;
#ifdef USE_SDL
			if (index >= 1 && index <= joy_device_count)
				info = joy_devices[index - 1].info_addr;
#endif
			return JoyManagerWriteOutPtr(pb, info) ? noErr : paramErr;
		}

		case kJoyCsEnableDevice: {
			int index;
			bool enable;
			int result;

			index = (int16)ReadMacInt16(pb + csParam + 4);
			enable = ReadMacInt8(pb + csParam + 6) != 0;
			result = noErr;
#ifdef USE_SDL
			JoyManagerSDLUpdate();
			if (index == 0) {
				int i;
				for (i = 0; i < joy_device_count; i++) {
					joy_devices[i].enabled = enable;
					JoyManagerSnapshotDevice(&joy_devices[i]);
				}
			} else if (index >= 1 && index <= joy_device_count) {
				joy_devices[index - 1].enabled = enable;
				JoyManagerSnapshotDevice(&joy_devices[index - 1]);
			} else {
				result = paramErr;
			}
#else
			if (index != 0)
				result = paramErr;
#endif
#ifdef USE_SDL
			JoyManagerUpdateState();
#endif
			return JoyManagerWriteOutWord(pb, result) ? noErr : paramErr;
		}

		case kJoyCsGetEventQueue:
			return JoyManagerWriteOutPtr(pb, joy_queue_addr) ? noErr : paramErr;

		case kJoyCsGetElementName: {
			int device_index;
			int element_index;
			uint32 name_addr;
			uint32 auxiliary_addr;
			int result;

			device_index = (int16)ReadMacInt16(pb + csParam + 4);
			element_index = (int16)ReadMacInt16(pb + csParam + 6);
			name_addr = ReadMacInt32(pb + csParam + 8);
			auxiliary_addr = ReadMacInt32(pb + csParam + 12);
			result = noErr;
#ifdef USE_SDL
			if (!JoyManagerWriteElementName(name_addr, device_index,
				element_index))
				result = paramErr;
#else
			result = paramErr;
#endif
			if (auxiliary_addr != 0)
				WriteMacInt32(auxiliary_addr, 0);
			return JoyManagerWriteOutWord(pb, result) ? noErr : paramErr;
		}
	}
	return controlErr;
}

int16 JoyManagerStatus(uint32 pb, uint32 dce)
{
	(void)pb;
	(void)dce;
	return statusErr;
}

int16 JoyManagerClose(uint32 pb, uint32 dce)
{
#ifdef USE_SDL
	int i;
#endif

	(void)pb;
	(void)dce;
	joy_start_count = 0;
#ifdef USE_SDL
	for (i = 0; i < joy_device_count; i++)
		joy_devices[i].enabled = false;
	JoyManagerUpdateState();
#else
	if (joy_simple_addr != 0)
		Mac_memset(joy_simple_addr, 0, joySimpleSize);
#endif
	JoyManagerResetQueue();
	return noErr;
}

#ifdef USE_SDL
JoyManagerDevice *JoyManagerOpenDevice(int index)
{
	return JoyManagerSDLOpenDevice(index);
}
void JoyManagerCloseDevice(JoyManagerDevice *joystick)
{
	JoyManagerSDLCloseDevice(joystick);
}
int JoyManagerNumDevices(void)
{
	return JoyManagerSDLNumDevices();
}
int JoyManagerNumButtons(JoyManagerDevice *joystick)
{
	return JoyManagerSDLNumButtons(joystick);
}
int JoyManagerNumAxes(JoyManagerDevice *joystick)
{
	return JoyManagerSDLNumAxes(joystick);
}
int JoyManagerNumHats(JoyManagerDevice *joystick)
{
	return JoyManagerSDLNumHats(joystick);
}
bool JoyManagerInit(void)
{
	return JoyManagerSDLInit();
}
bool JoyManagerHasRudderThrottle(JoyManagerDevice *joystick)
{
	return JoyManagerSDLHasRudderThrottle(joystick);
}
bool JoyManagerDeviceAttached(JoyManagerDevice *joystick)
{
	return JoyManagerSDLDeviceAttached(joystick);
}
const char *JoyManagerDeviceName(JoyManagerDevice *joystick,
	int index)
{
	return JoyManagerSDLDeviceName(joystick, index);
}
int16 JoyManagerAxis(JoyManagerDevice *joystick, int axis)
{
	return JoyManagerSDLAxis(joystick, axis);
}
uint8 JoyManagerButton(JoyManagerDevice *joystick, int button)
{
	return JoyManagerSDLButton(joystick, button);
}
uint8 JoyManagerHat(JoyManagerDevice *joystick, int hat)
{
	return JoyManagerSDLHat(joystick, hat);
}
void JoyManagerUpdate(void)
{
	JoyManagerSDLUpdate();
}
int JoyManagerHatPosition(uint8 hat)
{
	return JoyManagerSDLHatPosition(hat);
}
#else
JoyManagerDevice *JoyManagerOpenDevice(int index)
{
	return NULL;
}
void JoyManagerCloseDevice(JoyManagerDevice *joystick)
{
}
int JoyManagerNumDevices(void)
{
	return 0;
}
int JoyManagerNumButtons(JoyManagerDevice *joystick)
{
	return 0;
}
int JoyManagerNumAxes(JoyManagerDevice *joystick)
{
	return 0;
}
int JoyManagerNumHats(JoyManagerDevice *joystick)
{
	return 0;
}
bool JoyManagerInit(void)
{
	return false;
}
bool JoyManagerHasRudderThrottle(JoyManagerDevice *joystick)
{
	return false;
}
bool JoyManagerDeviceAttached(JoyManagerDevice *joystick)
{
	return false;
}
const char *JoyManagerDeviceName(JoyManagerDevice *joystick,
	int index)
{
	return NULL;
}
int16 JoyManagerAxis(JoyManagerDevice *joystick, int axis)
{
	return 0;
}
uint8 JoyManagerButton(JoyManagerDevice *joystick, int button)
{
	return 0;
}
uint8 JoyManagerHat(JoyManagerDevice *joystick, int hat)
{
	return 0;
}
void JoyManagerUpdate(void)
{
}
int JoyManagerHatPosition(uint8 hat)
{
	return 0;
}
#endif /* #ifdef USE_SDL */