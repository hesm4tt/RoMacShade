//
// Copyright (c) 2026 MacShade Authors. All Rights Reserved.
// PROPRIETARY AND CONFIDENTIAL.
// UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
//

#pragma once
#import <AppKit/AppKit.h>
#import "Obfuscate.h"
#import "FXRuntime.h"

NS_ASSUME_NONNULL_BEGIN
/// Existing ReShade shader/texture directories, ordered with a preset's companion
/// installation first. Also discovers the user's Documents/reshade roblox pack.
FOUNDATION_EXPORT NSArray<NSURL *> *MSReShadeSearchDirectories(NSArray<NSURL *> *directories, NSURL * _Nullable presetURL);
/// Bounded preset discovery shared by the demo and an embedded host. User files
/// take precedence over bundled copies with the same filename.
FOUNDATION_EXPORT NSArray<NSDictionary *> *MSDiscoverPresetLibrary(NSArray<NSURL *> *resourceDirectories,
    NSArray<NSURL *> *effectDirectories, NSURL * _Nullable selectedURL);
/// Native controls composed above a Metal view. Host owns effect loading and state.
@interface MSOverlayController : NSViewController
@property(nonatomic, copy, nullable) void (^openEffect)(void);
@property(nonatomic, copy, nullable) void (^addFolder)(void);
@property(nonatomic, copy, nullable) void (^importPreset)(void);
@property(nonatomic, copy, nullable) void (^exportPreset)(void);
@property(nonatomic, copy, nullable) void (^reloadEffects)(void);
@property(nonatomic, copy, nullable) void (^hideOverlay)(void);
@property(nonatomic, copy, nullable) void (^chooseEffect)(NSURL *url);
@property(nonatomic, copy, nullable) void (^selectEntry)(NSUInteger index);
@property(nonatomic, copy, nullable) void (^enableEntry)(NSUInteger index, BOOL enabled);
@property(nonatomic, copy, nullable) void (^moveEntry)(NSUInteger index, NSInteger direction);
@property(nonatomic, copy, nullable) void (^removeEntry)(NSUInteger index);
@property(nonatomic, copy, nullable) void (^selectTechnique)(NSString *name);
@property(nonatomic, copy, nullable) NSString * _Nullable (^changeUniform)(NSString *name, NSArray<NSNumber *> *values);
@property(nonatomic, copy, nullable) void (^toggleAll)(BOOL enabled);
@property(nonatomic, copy, nullable) void (^changeBuiltin)(NSUInteger index, double value);
@property(nonatomic, copy, nullable) void (^neutralBuiltin)(void);
@property(nonatomic, copy, nullable) void (^resetBuiltin)(void);
@property(nonatomic, copy, nullable) void (^choosePreset)(NSURL *presetURL);
@property(nonatomic, copy, nullable) void (^cycleQuality)(void);
- (void)setQualityLabel:(NSString *)label;
/// library: dictionaries with url (NSURL), name and subtitle (NSString).
/// entries: dictionaries with url, effect (MSFXEffect), enabled (NSNumber).
/// Disabled entries may have technique/values instead of a compiled effect.
- (void)updateLibrary:(NSArray<NSDictionary *> *)library;
- (void)updatePresets:(NSArray<NSDictionary *> *)presets selectedURL:(nullable NSURL *)selected;
- (void)updateEntries:(NSArray<NSDictionary *> *)entries selectedIndex:(NSUInteger)index;
- (void)updateBuiltinValues:(NSArray<NSNumber *> *)values enabled:(BOOL)enabled;
- (void)setStatus:(NSString *)message detail:(NSString *)detail busy:(BOOL)busy error:(BOOL)error;
- (void)setPresetName:(NSString *)name;
@end
NS_ASSUME_NONNULL_END
