//
// Copyright (c) 2026 MacShade Authors. All Rights Reserved.
// PROPRIETARY AND CONFIDENTIAL.
// UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
//

#pragma once
#import <Foundation/Foundation.h>
#import "Obfuscate.h"

#ifndef MACSHADE_API
#ifdef __cplusplus
#define MACSHADE_API extern "C" __attribute__((visibility("default")))
#else
#define MACSHADE_API extern __attribute__((visibility("default")))
#endif
#endif

NS_ASSUME_NONNULL_BEGIN
/// Starts UI in the current AppKit process after the host has loaded MacShade.
/// Searches visible windows for an active CAMetalLayer and schedules all AppKit
/// work on the main thread. resourcesDirectory contains an optional Effects/ folder.
/// This API does not load a library into another process or install Metal hooks.
MACSHADE_API void MSStartHostOverlay(NSString *resourcesDirectory);
/// Removes this session's views, local key monitor and timer, and disables effects.
MACSHADE_API void MSStopHostOverlay(void);
/// Thread-safe diagnostic snapshot; contains no launch arguments or environment values.
MACSHADE_API NSString *MSHostOverlayStatus(void);
NS_ASSUME_NONNULL_END
