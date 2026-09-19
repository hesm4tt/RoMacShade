#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

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

FOUNDATION_EXPORT MSSettings MSDefaultSettings(void);
FOUNDATION_EXPORT MSSettings MSNeutralSettings(void);

/// A device-specific postprocessor. Library creation happens once per instance;
/// render pipelines are cached by pixel format behind a lock. Independent
/// command buffers may use one renderer concurrently.
@interface MSRenderer : NSObject
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
FOUNDATION_EXPORT BOOL MSInstallHooks(NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT void MSSetSettings(MSSettings settings);
FOUNDATION_EXPORT MSSettings MSGetSettings(void);
FOUNDATION_EXPORT void MSSetEnabled(BOOL enabled);
FOUNDATION_EXPORT BOOL MSIsEnabled(void);
FOUNDATION_EXPORT uint64_t MSProcessedFrameCount(void);
/// Drawable frames whose command buffers completed successfully after the hook
/// encoded built-in processing. A failed buffer increments the error count once.
FOUNDATION_EXPORT uint64_t MSCompletedFrameCount(void);
FOUNDATION_EXPORT uint64_t MSGPUErrorCount(void);
/// Process-local hook observations, useful when a host presents drawables directly.
FOUNDATION_EXPORT NSDictionary<NSString *, NSNumber *> *MSHookDiagnostics(void);
/// Depth capture is restricted to stored, single-sample depth attachments paired
/// with color in the same command buffer. Default input convention is forward Z.
FOUNDATION_EXPORT void MSSetDepthReversed(BOOL reversed);
FOUNDATION_EXPORT BOOL MSIsDepthReversed(void);
FOUNDATION_EXPORT uint64_t MSDepthCaptureCount(void);
FOUNDATION_EXPORT NSString *MSLastDepthStatus(void);

NS_ASSUME_NONNULL_END
