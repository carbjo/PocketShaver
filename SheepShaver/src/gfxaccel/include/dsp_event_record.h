/*
 *  dsp_event_record.h - DSp EventRecord struct + event-kind constants
 *                        + reason-code constants.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Pure-C header. No Metal / Objective-C / Swift types — consumable from
 *  .cpp / .mm / Swift bridging header alike. Defines the on-the-wire
 *  EventRecord layout DSp apps see when they call DSpProcessEvent
 *  (sub-opcode 600); also defines the event-kind enum constants and the
 *  context-loss reason-code constant used by the bg/fg lifecycle path.
 *
 *  DSpEventRecord mirrors the classic Mac toolbox EventRecord exactly —
 *  16 bytes total. DSp apps written against the published ProcessEvent
 *  API expect this layout; we reproduce it byte-for-byte.
 *
 *  kDSpContextReason_Lost = 1 is the placeholder per DSp 1.7 PDF p.~92
 *  default; confirmable via DrawSprocketLib decompile. If the decompile
 *  reveals a different value, change the constant.
 */

#ifndef DSP_EVENT_RECORD_H
#define DSP_EVENT_RECORD_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 *  DSp EventRecord — 16 bytes.
 *
 *  Mirrors classic Mac toolbox EventRecord:
 *    Offset 0  (2)  what       — event kind (kDSpEvent_*)
 *    Offset 2  (4)  message    — event-kind-specific payload
 *    Offset 6  (4)  when       — TickCount() at event firing
 *    Offset 10 (2)  where_v    — vertical pixel position (mouse events)
 *    Offset 12 (2)  where_h    — horizontal pixel position (mouse events)
 *    Offset 14 (2)  modifiers  — modifier mask (shift / cmd / opt / ctrl)
 *
 *  Field names use long-suffix `where_v` / `where_h` per the DMC-grep-safe
 *  convention. The struct is stored in DSpContextPrivate.events_queue[];
 *  written by DSpHostBridge_EnqueueEvent; read by
 *  DSpContext_ProcessEventHandler which copies the 16 bytes to guest Mac
 *  memory at eventOutAddr via WriteMacInt16 / WriteMacInt32 (preserving
 *  Mac big-endian layout).
 */
struct DSpEventRecord {
	uint16_t  what;
	uint32_t  message;
	uint32_t  when;
	int16_t   where_v;
	int16_t   where_h;
	uint16_t  modifiers;
};
typedef struct DSpEventRecord DSpEventRecord;

/*
 *  Event kinds — DSp 1.7 PDF + Inside Macintosh: Toolbox Essentials.
 *  The classic Mac EventRecord.what enumeration; DSp uses a subset
 *  (mouseDown/Up + keyDown/Up + autoKey + osEvt). updateEvt / diskEvt /
 *  activateEvt are listed for future-proofing the ABI; we generate only
 *  mouseDown/Up + keyDown/Up + osEvt.
 */
enum {
	kDSpEvent_NullEvent      = 0,
	kDSpEvent_MouseDown      = 1,
	kDSpEvent_MouseUp        = 2,
	kDSpEvent_KeyDown        = 3,
	kDSpEvent_KeyUp          = 4,
	kDSpEvent_AutoKey        = 5,
	kDSpEvent_UpdateEvt      = 6,
	kDSpEvent_DiskEvt        = 7,
	kDSpEvent_ActivateEvt    = 8,
	kDSpEvent_OSEvt          = 15
};

/*
 *  osEvt subtype constants — encoded into the high byte of the
 *  EventRecord.message field per Inside Macintosh: Toolbox Essentials.
 *  Used when decoding guest-supplied suspend/resume osEvt records.
 *  MouseMovedMessage is
 *  emitted if mouse-move events are observed (currently observer-only —
 *  InputInteractionModel doesn't publish raw mouse moves).
 */
enum {
	kDSpOSEvt_SuspendResumeMessage = 0x01,  /* osEvt subtype 1 */
	kDSpOSEvt_MouseMovedMessage    = 0xFA   /* osEvt subtype 250 */
};

/*
 *  Bit flags within the message field for osEvt(SuspendResumeMessage):
 *    Bit 0 (resumeFlag): 1 = resume (foreground); 0 = suspend (background)
 *  This bit is set/cleared when constructing the osEvt message.
 */
enum {
	kDSpOSEvtMsg_ResumeFlag        = 0x01u
};

/*
 *  Context-loss reason codes — positive values, NOT error codes.
 *  Used as the EventRecord.message field of an osEvt enqueued ahead of
 *  the suspend osEvt when a context-loss event fires.
 *
 *  Default: 1 (per DSp 1.7 PDF p.~92 placeholder); confirmable via
 *  DrawSprocketLib decompile.
 *
 *  Guard avoids double-definition when dsp_engine.h's mirror enum has
 *  already been seen in the same translation unit. Either header may
 *  be included first; whichever wins defines the enum and sets
 *  DSP_CONTEXT_REASON_LOST_DEFINED.
 */
#ifndef DSP_CONTEXT_REASON_LOST_DEFINED
#define DSP_CONTEXT_REASON_LOST_DEFINED 1
enum {
	kDSpContextReason_Lost         = 1   /* confirmable via decompile */
};
#endif

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif /* DSP_EVENT_RECORD_H */
