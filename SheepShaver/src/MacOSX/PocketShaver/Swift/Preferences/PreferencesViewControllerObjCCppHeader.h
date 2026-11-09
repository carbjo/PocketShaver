//
//  PreferencesViewControllerObjCCppHeader.h
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

void objc_displayPreferencesStartup(void);
void objc_displayPreferencesDuringEmulationOnMain(void);

// Catalyst: resize the emulation window to the guest resolution on a mode change.
// No-op in full screen or off Catalyst.
void objc_resize_catalyst_window_for_guest(int guest_w, int guest_h);
