//
//  MonitorResolutionsObjC.h
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-18.
//

#ifdef __cplusplus
#import <vector>
#endif

#ifdef __cplusplus
extern "C"
#endif
struct MonitorResolution {
	int width;
	int height;
	int index;

	MonitorResolution(int, int, int);
};


std::vector<MonitorResolution> objc_getAllMonitorResolutions(void);

