//
//  PocketShaver-Bridging-Header.h
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

#import "PreferencesROMValidatorObjC.h"
#import "PrefsObjC.h"
#import "DiskCreation.h"
#import "MiscellaneousSettingsObjC.h"
#import "PerformanceCounterObjC.h"
#import "ADBObjC.h"
#import "MouseHapticFeedbackObjC.h"
#import "BonjourManagerObjC.h"
#import "ImpHFSExtractor.h"

// Memory-warning C shim + PSO archive C API +
// background/foreground lifecycle handlers.
// MemoryWarningObserver.swift calls gfxaccel_handle_memory_warning();
// BackgroundLifecycleObserver.swift calls gfxaccel_handle_background_enter()
// and gfxaccel_handle_foreground_enter().
// These headers expose the extern "C" functions to Swift.
#import "gfxaccel_resources.h"
#import "gfxaccel_resources_heap.h"
#import "pso_archive.h"

// DSp <-> iOS host bridge.
// DSpIdleTimerService.swift calls DSpHostBridge_GetActiveFullscreen() on
// willEnterForegroundNotification to decide whether to re-assert
// UIApplication.shared.isIdleTimerDisabled. dsp_host_bridge.h also exposes
// DSpHostBridge_OnBackground / OnForeground /
// EnqueueEvent / EnqueueEventToActiveContexts — DSpEventService.swift
// consumes all four entries. Header is pure-C with
// extern "C" guards; ../gfxaccel/include is already on HEADER_SEARCH_PATHS
// for this target.
#import "dsp_host_bridge.h"

// DSp EventRecord layout + event-kind enum constants (kDSpEvent_MouseDown /
// MouseUp / KeyDown / KeyUp) + context-loss reason codes. DSpEventService
// .forwardInputEventToDSp uses the kDSpEvent_* constants to translate
// DSpInputEvent.kind into the EventRecord.what field before calling
// DSpHostBridge_EnqueueEventToActiveContexts. Header is pure-C with
// extern "C" guards.
#import "dsp_event_record.h"
