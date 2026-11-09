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
#import "ClipboardSharing.h"

// gfxaccel C APIs used by the Swift lifecycle observers.
#import "gfxaccel_resources.h"
#import "gfxaccel_resources_heap.h"
#import "pso_archive.h"

// DSp host bridge, used by DSpIdleTimerService.swift.
#import "dsp_host_bridge.h"
