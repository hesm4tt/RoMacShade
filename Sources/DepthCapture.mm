//
// Copyright (c) 2026 MacShade Authors. All Rights Reserved.
// PROPRIETARY AND CONFIDENTIAL.
// UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
//

#import "DepthCapture.h"
#include <cmath>

namespace {
void SetError(NSError **error, NSInteger code, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"MacShade.DepthCapture" code:code
                                      userInfo:@{NSLocalizedDescriptionKey:message}];
}

NSString *DepthSource(void) {
    return [NSString stringWithUTF8String:R"MSL(
#include <metal_stdlib>
using namespace metal;
struct DepthVertex { float4 position [[position]]; float2 uv; };
vertex DepthVertex captureDepthVertex(uint vertexID [[vertex_id]]) {
    float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    return {float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0), uv};
}
fragment float captureDepthFragment(DepthVertex in [[stage_in]],
                                    depth2d<float> source [[texture(0)]],
                                    constant uint &reversed [[buffer(0)]]) {
    // Explicit reads avoid device-dependent filtering support for depth textures.
    // Clamp each neighbor independently, including the negative half-pixel border.
    float2 size = float2(source.get_width(), source.get_height());
    float2 pixel = in.uv * size - 0.5;
    float2 base = floor(pixel), fraction = fract(pixel);
    uint2 lo = uint2(clamp(base, float2(0.0), size - 1.0));
    uint2 hi = uint2(clamp(base + 1.0, float2(0.0), size - 1.0));
    float top = mix(source.read(uint2(lo.x, lo.y)), source.read(uint2(hi.x, lo.y)), fraction.x);
    float bottom = mix(source.read(uint2(lo.x, hi.y)), source.read(uint2(hi.x, hi.y)), fraction.x);
    float raw = mix(top, bottom, fraction.y);
    return reversed != 0 ? 1.0 - raw : raw;
}
fragment float captureDepthMSFragment(DepthVertex in [[stage_in]],
                                      depth2d_ms<float> source [[texture(0)]],
                                      constant uint &reversed [[buffer(0)]]) {
    float2 size = float2(source.get_width(), source.get_height());
    uint2 coord = uint2(clamp(in.uv * size, float2(0.0), size - 1.0));
    float raw = source.read(coord, 0);
    uint samples = source.get_num_samples();
    for (uint s = 1; s < samples; ++s) {
        float sampleVal = source.read(coord, s);
        raw = reversed != 0 ? max(raw, sampleVal) : min(raw, sampleVal);
    }
    return reversed != 0 ? 1.0 - raw : raw;
}
)MSL"];
}
}

@interface MSDepthResourceSet : NSObject
@property(nonatomic, strong) id<MTLTexture> depthCopy;
@property(nonatomic, strong) id<MTLTexture> output;
@property(nonatomic) NSUInteger sourceWidth;
@property(nonatomic) NSUInteger sourceHeight;
@property(nonatomic) NSUInteger outputWidth;
@property(nonatomic) NSUInteger outputHeight;
@property(nonatomic) NSUInteger sampleCount;
@property(nonatomic) MTLPixelFormat sourceFormat;
@property(nonatomic) MTLTextureType sourceType;
@property(nonatomic) BOOL inUse;
@end
@implementation MSDepthResourceSet
@end

@implementation MSDepthConverter {
    id<MTLDevice> _device;
    id<MTLRenderPipelineState> _singlePipeline;
    id<MTLRenderPipelineState> _msaaPipeline;
    NSMutableArray<MSDepthResourceSet *> *_resourceSets;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error {
    if (error) *error = nil;
    if (!(self = [super init])) return nil;
    if (!device) {
        SetError(error, 1, @"Depth conversion requires a Metal device.");
        return nil;
    }
    _device = device;
    _resourceSets = [NSMutableArray array];
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.fastMathEnabled = NO;
    id<MTLLibrary> library = [device newLibraryWithSource:DepthSource() options:options error:error];
    if (!library) return nil;
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.label = @"MacShade forward depth conversion";
    descriptor.vertexFunction = [library newFunctionWithName:@"captureDepthVertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"captureDepthFragment"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
    id<MTLFunction> msFunc = [library newFunctionWithName:@"captureDepthMSFragment"];
    if (!descriptor.vertexFunction || !descriptor.fragmentFunction || !msFunc) {
        SetError(error, 2, @"Metal did not expose the depth conversion entry points.");
        return nil;
    }
    _singlePipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:error];
    if (!_singlePipeline) return nil;

    descriptor.label = @"MacShade forward MSAA depth conversion";
    descriptor.fragmentFunction = msFunc;
    _msaaPipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:error];
    if (!_msaaPipeline) return nil;
    return self;
}

- (MSDepthResourceSet *)acquireResourcesForSource:(id<MTLTexture>)source
                                      outputWidth:(NSUInteger)width
                                     outputHeight:(NSUInteger)height
                                            error:(NSError **)error {
    @synchronized(self) {
        MSDepthResourceSet *slot = nil;
        for (MSDepthResourceSet *candidate in _resourceSets) {
            BOOL matches = candidate.sourceWidth == source.width && candidate.sourceHeight == source.height &&
                candidate.sampleCount == source.sampleCount && candidate.sourceFormat == source.pixelFormat &&
                candidate.sourceType == source.textureType;
            if (!candidate.inUse && matches) { slot = candidate; break; }
        }

        BOOL isNewSlot = NO;
        if (!slot) {
            for (MSDepthResourceSet *candidate in _resourceSets) {
                if (!candidate.inUse) { slot = candidate; break; }
            }
        }
        if (!slot && _resourceSets.count < 3) {
            slot = [MSDepthResourceSet new];
            [_resourceSets addObject:slot];
            isNewSlot = YES;
        }
        if (!slot) {
            SetError(error, 14, @"Depth buffers are still in flight; skipping depth capture for this frame.");
            return nil;
        }

        BOOL matches = slot.sourceWidth == source.width && slot.sourceHeight == source.height &&
            slot.sampleCount == source.sampleCount && slot.sourceFormat == source.pixelFormat &&
            slot.sourceType == source.textureType;
        if (!matches) {
            MTLTextureDescriptor *copyDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:source.pixelFormat
                                                                                                  width:source.width height:source.height mipmapped:NO];
            if (source.sampleCount > 1) {
                copyDescriptor.textureType = MTLTextureType2DMultisample;
                copyDescriptor.sampleCount = source.sampleCount;
            }
            copyDescriptor.storageMode = MTLStorageModePrivate;
            copyDescriptor.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> depthCopy = [_device newTextureWithDescriptor:copyDescriptor];

            if (!depthCopy) {
                if (isNewSlot) [_resourceSets removeObjectIdenticalTo:slot];
                SetError(error, 11, @"Metal could not allocate the depth copy texture.");
                return nil;
            }
            depthCopy.label = @"MacShade stored depth snapshot";
            slot.depthCopy = depthCopy;
            slot.sourceWidth = source.width;
            slot.sourceHeight = source.height;
            slot.sampleCount = source.sampleCount;
            slot.sourceFormat = source.pixelFormat;
            slot.sourceType = source.textureType;
        }
        // Each normalized output is an immutable depth snapshot referenced by
        // candidate records for up to two seconds. Reuse would let a later
        // capture overwrite depth while another command buffer still samples it.
        MTLTextureDescriptor *outputDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                                                width:width height:height mipmapped:NO];
        outputDescriptor.storageMode = MTLStorageModePrivate;
        outputDescriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        id<MTLTexture> output = [_device newTextureWithDescriptor:outputDescriptor];
        if (!output) {
            if (isNewSlot) [_resourceSets removeObject:slot];
            SetError(error, 11, @"Metal could not allocate the normalized depth snapshot.");
            return nil;
        }
        output.label = @"MacShade forward ReShade depth";
        slot.output = output;
        slot.outputWidth = width;
        slot.outputHeight = height;
        slot.inUse = YES;
        return slot;
    }
}

- (void)releaseResources:(MSDepthResourceSet *)resources {
    @synchronized(self) {
        resources.inUse = NO;
        resources.output = nil;
        resources.outputWidth = 0;
        resources.outputHeight = 0;
    }
}

- (id<MTLTexture>)encodeCommandBuffer:(id<MTLCommandBuffer>)buffer
                        depthTexture:(id<MTLTexture>)source
                         outputWidth:(NSUInteger)width
                        outputHeight:(NSUInteger)height
                            reversed:(BOOL)reversed
                           nearPlane:(double)nearPlane
                            farPlane:(double)farPlane
                               error:(NSError **)error {
    if (error) *error = nil;
    if (!buffer || !source || buffer.device != _device || source.device != _device) {
        SetError(error, 3, @"Depth texture and command buffer must belong to the converter's Metal device.");
        return nil;
    }
    if (buffer.status >= MTLCommandBufferStatusCommitted) {
        SetError(error, 4, @"Capture depth before committing the command buffer, after ending the source render encoder.");
        return nil;
    }
    if (!width || !height || width > 16384 || height > 16384) {
        SetError(error, 5, @"Depth output dimensions must be between 1 and 16384 pixels.");
        return nil;
    }
    if (!std::isfinite(nearPlane) || !std::isfinite(farPlane) || nearPlane <= 0 || farPlane <= nearPlane) {
        SetError(error, 6, @"Specify a finite perspective projection with 0 < nearPlane < farPlane. Infinite reversed-Z is not inferred.");
        return nil;
    }
    if (source.storageMode == MTLStorageModeMemoryless) {
        SetError(error, 7, @"Memoryless depth cannot be copied after its render pass. Use a stored depth attachment with StoreActionStore.");
        return nil;
    }
    if (source.sampleCount < 1) {
        SetError(error, 8, @"Depth texture must have at least 1 sample.");
        return nil;
    }
    BOOL isSingleSample = (source.sampleCount == 1 && source.textureType == MTLTextureType2D);
    BOOL isMultisample = (source.sampleCount > 1 && source.textureType == MTLTextureType2DMultisample);
    if ((!isSingleSample && !isMultisample) || source.arrayLength != 1 || source.mipmapLevelCount != 1 || source.framebufferOnly) {
        SetError(error, 9, @"Depth capture needs a non-framebuffer-only 2D or 2DMultisample texture with one slice and one mip level.");
        return nil;
    }
    if (source.pixelFormat != MTLPixelFormatDepth32Float && source.pixelFormat != MTLPixelFormatDepth16Unorm && source.pixelFormat != MTLPixelFormatDepth32Float_Stencil8) {
        SetError(error, 10, @"Use Depth32Float, Depth16Unorm, or Depth32Float_Stencil8.");
        return nil;
    }

    MSDepthResourceSet *resources = [self acquireResourcesForSource:source outputWidth:width outputHeight:height error:error];
    if (!resources) return nil;
    id<MTLTexture> depthCopy = resources.depthCopy;
    id<MTLTexture> output = resources.output;
    id<MTLRenderPipelineState> activePipeline = (source.sampleCount > 1) ? _msaaPipeline : _singlePipeline;
    // Install the keepalive before encoding any work, including failure paths.
    NSArray *keepalive = @[self, source, resources, depthCopy, output, activePipeline];
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        (void)completed;
        (void)keepalive.count;
        [self releaseResources:resources];
    }];
    id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
    if (!blit) {
        SetError(error, 12, @"Could not begin the depth copy. End the host render encoder before requesting depth capture.");
        return nil;
    }
    blit.label = @"MacShade copy scene depth";
    [blit copyFromTexture:source sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
              sourceSize:MTLSizeMake(source.width, source.height, 1) toTexture:depthCopy
        destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = output;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        SetError(error, 13, @"Metal could not create the depth conversion render encoder.");
        return nil;
    }
    encoder.label = @"MacShade normalize finite-perspective depth";
    [encoder setRenderPipelineState:activePipeline];
    [encoder setCullMode:MTLCullModeNone];
    [encoder setViewport:(MTLViewport){0, 0, (double)width, (double)height, 0, 1}];
    [encoder setFragmentTexture:depthCopy atIndex:0];
    uint32_t inverse = reversed ? 1 : 0;
    [encoder setFragmentBytes:&inverse length:sizeof(inverse) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    return output;
}
@end
