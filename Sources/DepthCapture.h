//
// Copyright (c) 2026 MacShade Authors. All Rights Reserved.
// PROPRIETARY AND CONFIDENTIAL.
// UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
//

#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "Obfuscate.h"

#ifndef MACSHADE_CLASS_API
#define MACSHADE_CLASS_API __attribute__((visibility("default")))
#endif

NS_ASSUME_NONNULL_BEGIN

/// Copies and normalizes a finite-perspective Metal depth attachment for ReShade.
/// This helper does not discover scene depth or infer the camera projection.
MACSHADE_CLASS_API @interface MSDepthConverter : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                 error:(NSError * _Nullable * _Nullable)error;

/// Appends a depth copy and fullscreen conversion to an uncommitted buffer.
/// End the source render encoder first and preserve its depth with StoreActionStore.
/// Source formats: Depth32Float, Depth16Unorm, Depth32Float_Stencil8 (single or multisample 2D).
/// Returns a private R32Float texture with shader-read/render-target usage.
/// Output coordinates keep the source orientation; resizing uses clamped bilinear
/// interpolation at pixel centers. Values use forward depth (near=0, far=1).
/// For a finite reversed projection, conversion is 1 - raw; otherwise it is raw.
/// nearPlane/farPlane validate the caller's finite projection; they do not rescale
/// depth. Infinite reversed-Z needs a separately specified projection conversion
/// and must not be passed as though it were finite reversed depth.
/// All encoded resources survive GPU completion, including on unretained buffers.
- (nullable id<MTLTexture>)encodeCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                                depthTexture:(id<MTLTexture>)depthTexture
                                 outputWidth:(NSUInteger)outputWidth
                                outputHeight:(NSUInteger)outputHeight
                                    reversed:(BOOL)reversed
                                   nearPlane:(double)nearPlane
                                    farPlane:(double)farPlane
                                       error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
