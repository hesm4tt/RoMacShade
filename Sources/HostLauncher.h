//
// Copyright (c) 2026 MacShade Authors. All Rights Reserved.
// PROPRIETARY AND CONFIDENTIAL.
// UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
//

#pragma once

#import <Foundation/Foundation.h>
#import "Obfuscate.h"

NS_ASSUME_NONNULL_BEGIN

@interface MSHostLauncher : NSObject

+ (nullable NSString *)detectRobloxApp;
+ (nullable NSString *)sha256OfFile:(NSString *)path;
+ (nullable NSString *)bundleExecutablePath:(NSString *)appPath;
+ (nullable NSDictionary *)entitlementsForApp:(NSString *)appPath error:(NSError **)error;

+ (BOOL)prepareRobloxFromSource:(NSString *)sourcePath
                    destination:(NSString *)destPath
                          error:(NSError **)error;

+ (BOOL)runRobloxWithSource:(NSString *)sourcePath
                    library:(nullable NSString *)libraryPath
                  resources:(nullable NSString *)resourcesPath
                 logHandler:(void (^)(NSString *line))logHandler
                      error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
