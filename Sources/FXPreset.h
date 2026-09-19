//
// Copyright (c) 2026 MacShade Authors. All Rights Reserved.
// PROPRIETARY AND CONFIDENTIAL.
// UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
//

#import <Foundation/Foundation.h>
#import "Obfuscate.h"

NS_ASSUME_NONNULL_BEGIN

/// A bounded, data-only subset of the standard ReShade preset INI format.
/// Each entry contains technique (NSString), file (basename, or "" for a legacy
/// unqualified reference), and enabled (NSNumber). Entries preserve execution order.
@interface MSFXPreset : NSObject
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *entries;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, NSDictionary<NSString *, NSArray<NSNumber *> *> *> *uniformValues;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *definitions;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *effectDefinitions;
@property(nonatomic, copy, readonly) NSArray<NSString *> *warnings;
+ (nullable instancetype)presetWithURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;
+ (nullable instancetype)presetWithString:(NSString *)text error:(NSError * _Nullable * _Nullable)error;
+ (nullable NSString *)stringWithEntries:(NSArray<NSDictionary *> *)entries
                          uniformValues:(NSDictionary<NSString *, NSDictionary<NSString *, NSArray<NSNumber *> *> *> *)uniformValues
                            definitions:(NSDictionary<NSString *, NSString *> *)definitions
                      effectDefinitions:(NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *)effectDefinitions
                                  error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
