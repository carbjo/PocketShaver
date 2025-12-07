//
//  FPSCounterObjC.h
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-11-29.
//

#import <Foundation/Foundation.h>

@class FPSCounterObjC;

#ifdef __cplusplus
extern "C"
#endif
FPSCounterObjC* _Nonnull objc_getFpsCounter(void);

NS_ASSUME_NONNULL_BEGIN

@protocol FPSCounterObjCDelegate <NSObject>

- (void)fpsCounter:(FPSCounterObjC*) counter didUpdateFramesPerSecond:(NSInteger)fps;

@end

@interface FPSCounterObjC : NSObject

@property(weak, nonatomic) id<FPSCounterObjCDelegate> delegate;

- (NSInteger)reportOneSecondAndFetchFps;

@end

NS_ASSUME_NONNULL_END
