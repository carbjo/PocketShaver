/*
 *  dsp_event_record.h - classic Mac EventRecord kinds and DSp reason codes.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  Pure C. Used by DSpProcessEventHandler (sub-opcode 750) to decode guest
 *  EventRecords and by the background/foreground lifecycle path.
 */

#ifndef DSP_EVENT_RECORD_H
#define DSP_EVENT_RECORD_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* EventRecord.what values (Inside Macintosh: Toolbox Essentials). The
 * sub-op 750 decoder only examines osEvt. */
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

/* osEvt subtypes, stored in the high byte of EventRecord.message. */
enum {
	kDSpOSEvt_SuspendResumeMessage = 0x01,  /* osEvt subtype 1 */
	kDSpOSEvt_MouseMovedMessage    = 0xFA   /* osEvt subtype 250 */
};

/* Suspend/resume osEvt message bit 0: 1 = resume, 0 = suspend. */
enum {
	kDSpOSEvtMsg_ResumeFlag        = 0x01u
};

/* Context-loss reason codes are positive values, not error codes. One goes
 * in the message field of an osEvt queued ahead of the suspend osEvt. The
 * value 1 follows DSp 1.7 (around p.92), unconfirmed against DrawSprocketLib.
 * dsp_engine.h mirrors this enum; the guard lets either header come first. */
#ifndef DSP_CONTEXT_REASON_LOST_DEFINED
#define DSP_CONTEXT_REASON_LOST_DEFINED 1
enum {
	kDSpContextReason_Lost         = 1
};
#endif

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif /* DSP_EVENT_RECORD_H */
