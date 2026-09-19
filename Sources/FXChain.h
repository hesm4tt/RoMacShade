//
// Copyright (c) 2026 MacShade Authors. All Rights Reserved.
// PROPRIETARY AND CONFIDENTIAL.
// UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
//

#pragma once
#import "FXRuntime.h"
#import "FXPreset.h"
NS_ASSUME_NONNULL_BEGIN

/// Serializable source/technique/value snapshots, independent of Metal objects.
FOUNDATION_EXPORT NSArray<NSDictionary *> *MSFXChainSpecifications(NSArray<NSDictionary *> *entries);
/// Does not install anything. Returns a completely compiled replacement or nil.
FOUNDATION_EXPORT NSArray<NSDictionary *> * _Nullable MSCompileFXChain(
    NSArray<NSDictionary *> *specifications, id<MTLDevice> device,
    NSUInteger width, NSUInteger height, NSArray<NSURL *> *includeDirectories, NSError **error);
/// Catalog all FX files below explicitly selected roots, in root priority order.
FOUNDATION_EXPORT NSArray<NSDictionary *> *MSFXLibrary(NSArray<NSURL *> *directories);
/// Resolve preset references against the preset directory and selected library.
FOUNDATION_EXPORT NSArray<NSDictionary *> * _Nullable MSFXPresetSpecifications(
    MSFXPreset *preset, NSURL *presetURL, NSArray<NSDictionary *> *library,
    NSMutableArray<NSString *> *warnings, NSError **error);
/// Build a standard ReShade INI from live chain values. Built-in grading is separate.
FOUNDATION_EXPORT NSString * _Nullable MSFXChainPresetString(NSArray<NSDictionary *> *entries, NSError **error);
NS_ASSUME_NONNULL_END
