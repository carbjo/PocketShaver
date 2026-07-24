/*
 *  dsp_display_id_policy.h - DrawSprocket DisplayID helpers.
 *
 *  (C) 2026 Sierra Burkhart (sierra760)
 */

#ifndef DSP_DISPLAY_ID_POLICY_H
#define DSP_DISPLAY_ID_POLICY_H

#include <stdint.h>

/* The Display-Manager id of the single backing screen as the GUEST OS knows
 * it. Apps hand this id back to the Display Manager
 * (DMGetGDeviceByDisplayID) to recover the GDevice a DSp context lives on,
 * so DSpContext_GetDisplayID must report an id the guest DM can actually
 * resolve — NOT one of the per-mode ids below (those mirror the video
 * driver's APPLE_* display-MODE ids, a different namespace). 0x100 is the id
 * real titles pass INTO DSp for this screen (The Sims and 4x4 Evolution both
 * send displayID=256 to DSpFindBestContextOnDisplayID), i.e. the value the
 * guest DM vended to them. Reporting a mode id here instead sends the app's
 * DM lookup into the weeds: Quake II spins forever re-running
 * UserSelectContext -> GetDisplayID -> Release when the id doesn't map. */
enum {
	kDSpGuestDMMainDisplayID = 0x100
};

enum {
	kDSpDisplayID640x480   = 0x81,
	kDSpDisplayIDW640x480  = 0x82,
	kDSpDisplayID800x600   = 0x83,
	kDSpDisplayIDW800x600  = 0x84,
	kDSpDisplayID1024x768  = 0x85,
	kDSpDisplayID1152x768  = 0x86,
	kDSpDisplayID1152x900  = 0x87,
	kDSpDisplayID1280x1024 = 0x88,
	kDSpDisplayID1600x1200 = 0x89,
	kDSpDisplayIDCustom    = 0x8a
};

static inline uint32_t DSpDisplayIDForMode(uint32_t width, uint32_t height)
{
	if (width == 640 && height == 480) return kDSpDisplayID640x480;
	if (width == 800 && height == 600) return kDSpDisplayID800x600;
	if (width == 1024 && height == 768) return kDSpDisplayID1024x768;
	if (width == 1152 && height == 768) return kDSpDisplayID1152x768;
	if (width == 1152 && height == 900) return kDSpDisplayID1152x900;
	if (width == 1280 && height == 1024) return kDSpDisplayID1280x1024;
	if (width == 1600 && height == 1200) return kDSpDisplayID1600x1200;
	return kDSpDisplayIDCustom;
}

static inline bool DSpAcceptsSingleDisplayID(uint32_t display_id)
{
	(void)display_id;
	return true;
}

#endif /* DSP_DISPLAY_ID_POLICY_H */
