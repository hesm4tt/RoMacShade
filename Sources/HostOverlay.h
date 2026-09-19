#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Starts UI in the current AppKit process after the host has loaded MacShade.
/// Searches visible windows for an active CAMetalLayer and schedules all AppKit
/// work on the main thread. resourcesDirectory contains an optional Effects/ folder.
/// This API does not load a library into another process or install Metal hooks.
FOUNDATION_EXPORT void MSStartHostOverlay(NSString *resourcesDirectory);
/// Removes this session's views, local key monitor and timer, and disables effects.
FOUNDATION_EXPORT void MSStopHostOverlay(void);
/// Thread-safe diagnostic snapshot; contains no launch arguments or environment values.
FOUNDATION_EXPORT NSString *MSHostOverlayStatus(void);
NS_ASSUME_NONNULL_END
