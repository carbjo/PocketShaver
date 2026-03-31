//
//  MiscellaneousSettingsObjC.h
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-26.
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C"
#endif
void cpp_setRelativeMouseMode(BOOL isOn);

#ifdef __cplusplus
extern "C"
#endif
void cpp_setRelativeMouseModeAutomatic();

#ifdef __cplusplus
extern "C"
#endif
void cpp_updateFrameRateHz();
