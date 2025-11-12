//
//  PreferencesROMValidatorObjC.h
//  SheepShaver_Xcode8
//
//  Created by Carl Björkman on 2025-08-24.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, RomType) {
	RomTypeInvalid = 0,
	RomTypeOldWorldTnt,
	RomTypeOldWorldAlchemy,
	RomTypeOldWorldZanzibar,
	RomTypeOldWorldGazelle,
	RomTypeOldWorldGossamer,
	RomTypeNewWorld
};

#ifdef __cplusplus
extern "C"
#endif
RomType validateROMType(NSString *romPath);

#ifdef __cplusplus
extern "C"
#endif
BOOL validateROM(NSString* _Nonnull romPath);

NS_ASSUME_NONNULL_END
