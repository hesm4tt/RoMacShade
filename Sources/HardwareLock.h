//
// Copyright (c) 2026 MacShade Authors. All Rights Reserved.
// PROPRIETARY AND CONFIDENTIAL.
// UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
//

#pragma once

#import <Foundation/Foundation.h>
#import "Obfuscate.h"

NS_ASSUME_NONNULL_BEGIN

#ifndef MACSHADE_CLASS_API
#define MACSHADE_CLASS_API __attribute__((visibility("default")))
#endif

MACSHADE_CLASS_API @interface MSHardwareLock : NSObject

/// Returns the persistent Hardware ID (HWID) for this physical Mac: MS-XXXX-XXXX-XXXX-XXXX
+ (NSString *)currentHWID;

/// Checks if this Mac has a valid, cryptographically verified license matching its HWID.
+ (BOOL)isLicensed;

/// Activates this copy with the provided license key. Returns YES on success.
+ (BOOL)activateWithKey:(NSString *)licenseKey error:(NSError * _Nullable * _Nullable)error;

/// Returns current license metadata (HWID, activation date), or nil if unlicensed.
+ (nullable NSDictionary *)licenseInfo;

/// Generates expected key for a given HWID (internal calculation).
+ (NSString *)generateKeyForHWID:(NSString *)hwid;

/// Full path to the license storage file (~/Library/Application Support/MacShade/License.dat).
+ (NSString *)licenseFilePath;

@end

NS_ASSUME_NONNULL_END
