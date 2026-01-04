//
//  MouseHapticFeedbackObjC.h
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-09-26.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C"
#endif
void objc_mousedownHapticFeedback(void);

#ifdef __cplusplus
extern "C"
#endif
NSDate *objc_getLatestMouseDownHapticFeedbackTimestamp();

NS_ASSUME_NONNULL_END
