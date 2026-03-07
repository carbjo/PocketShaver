//
//  PerformanceCounterObjC.h
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-11-29.
//

#import <Foundation/Foundation.h>

@class PerformanceCounterObjC;
@class PerformanceCounterReport;

#ifdef __cplusplus
extern "C"
#endif
PerformanceCounterObjC* _Nonnull objc_getPerformanceCounter(void);

NS_ASSUME_NONNULL_BEGIN

@protocol PerformanceCounterObjCDelegate <NSObject>

- (void)fpsCounter:(PerformanceCounterObjC*) counter didUpdateFramesPerSecond:(NSInteger)fps;

@end

@interface PerformanceCounterObjC : NSObject

@property(weak, nonatomic) id<PerformanceCounterObjCDelegate> delegate;

- (PerformanceCounterReport*)reportOneSecondAndFetchReport;

@end

NS_ASSUME_NONNULL_END
