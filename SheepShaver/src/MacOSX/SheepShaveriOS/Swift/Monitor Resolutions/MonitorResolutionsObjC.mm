//
//  MonitorResolutionsObjC.swift
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-07-18.
//

#import "MonitorResolutionsObjC.h"
#import <UIKit/UIKit.h>
#import "SheepShaveriOS-Swift.h"

MonitorResolution::MonitorResolution(int inp_width, int inp_height, int inp_index) {
	width = inp_width;
	height = inp_height;
	index = inp_index;
}

std::vector<MonitorResolution> objc_getAllMonitorResolutions(void) {
	NSArray<MonitorResolutionElement *> * monitorResolutions = [MonitorResolutions getAllMonitorResolutions];

	std::vector<MonitorResolution> outputResolutions = std::vector<MonitorResolution>();

	for (MonitorResolutionElement * resolution in monitorResolutions) {
		outputResolutions.push_back(
									MonitorResolution(
													  (int)resolution.width,
													  (int)resolution.height,
													  (int)resolution.index
													  )
									);
	}

	return outputResolutions;
}

