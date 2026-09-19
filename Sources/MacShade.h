//
// Copyright (c) 2026 MacShade Authors. All Rights Reserved.
// PROPRIETARY AND CONFIDENTIAL.
// UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

#ifndef MACSHADE_API
#ifdef __cplusplus
#define MACSHADE_API extern "C" __attribute__((visibility("default")))
#else
#define MACSHADE_API extern __attribute__((visibility("default")))
#endif
#endif

#ifndef MACSHADE_CLASS_API
#define MACSHADE_CLASS_API __attribute__((visibility("default")))
#endif

/// Color adjustments operate on the linear RGB values returned by Metal.
/// Out-of-range values are clamped; non-finite values use their neutral value.
/// The original alpha channel is preserved. No depth texture is required.
typedef struct MSSettings {
    float exposure;    ///< Exposure in stops, -4...4; neutral 0.
    float contrast;    ///< Contrast around linear 18% gray, 0...2; neutral 1.
    float saturation;  ///< Luminance-relative saturation, 0...2; neutral 1.
    float vibrance;    ///< Preferential saturation of muted colors, -1...1; neutral 0.
    float temperature; ///< Warm/cool white-balance adjustment, -1...1; neutral 0.
    float tint;        ///< Green/magenta white-balance adjustment, -1...1; neutral 0.
    float sharpen;     ///< Four-neighbor unsharp-mask strength, 0...2; neutral 0.
    float bloom;       ///< Local highlight-spill strength, 0...1; neutral 0.
    float vignette;    ///< Corner darkening strength, 0...1; neutral 0.
    float grain;       ///< Animated grain strength, 0...1 (max 0.06 RGB); neutral 0.
} MSSettings;

MACSHADE_API MSSettings MSDefaultSettings(void);
MACSHADE_API MSSettings MSNeutralSettings(void);

/// A device-specific postprocessor. Library creation happens once per instance;
/// render pipelines are cached by pixel format behind a lock. Independent
/// command buffers may use one renderer concurrently.
MACSHADE_CLASS_API @interface MSRenderer : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                 error:(NSError * _Nullable * _Nullable)error;

/// Appends a copy and a full-screen render pass to an uncommitted command buffer.
/// Finish all other encoders first, and present/commit only after this method.
/// The host must not concurrently encode into or commit the same command buffer.
/// The texture must be a stored, non-framebufferOnly, single-sample 2D render
/// target on this device. BGRA8/RGBA8 (linear or sRGB) and RGBA16Float are supported.
/// Only mip level 0 is processed. This method never commits or waits for the GPU.
/// Each call owns separate scratch storage, retained through GPU completion even
/// with unretained-reference command buffers. YES means encoding succeeded;
/// asynchronous GPU failures remain available on commandBuffer.error.
- (BOOL)encodeCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                    texture:(id<MTLTexture>)texture
                   settings:(MSSettings)settings
                      error:(NSError * _Nullable * _Nullable)error;
@end

/// Optional integration hooks for hosts that explicitly load this library.
MACSHADE_API BOOL MSInstallHooks(NSError * _Nullable * _Nullable error);
MACSHADE_API void MSSetSettings(MSSettings settings);
MACSHADE_API MSSettings MSGetSettings(void);
MACSHADE_API void MSSetEnabled(BOOL enabled);
MACSHADE_API BOOL MSIsEnabled(void);
MACSHADE_API uint64_t MSProcessedFrameCount(void);
/// Drawable frames whose command buffers completed successfully after the hook
/// encoded built-in processing. A failed buffer increments the error count once.
MACSHADE_API uint64_t MSCompletedFrameCount(void);
MACSHADE_API uint64_t MSGPUErrorCount(void);
/// Process-local hook observations, useful when a host presents drawables directly.
MACSHADE_API NSDictionary<NSString *, NSNumber *> *MSHookDiagnostics(void);
/// Depth capture is restricted to stored, single-sample depth attachments paired
/// with color in the same command buffer. Default input convention is forward Z.
MACSHADE_API void MSSetDepthReversed(BOOL reversed);
MACSHADE_API BOOL MSIsDepthReversed(void);
MACSHADE_API uint64_t MSDepthCaptureCount(void);
MACSHADE_API NSString *MSLastDepthStatus(void);

NS_ASSUME_NONNULL_END
