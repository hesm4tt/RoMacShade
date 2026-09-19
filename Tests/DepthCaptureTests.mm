#import "DepthCapture.h"
#import "MacShade.h"
#import "FXRuntime.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static int checks = 0;
static void check(bool passed, const char *message) {
    ++checks;
    if (!passed) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

static id<MTLTexture> makeDepth(id<MTLDevice> device, MTLPixelFormat format,
                              NSUInteger width = 17, NSUInteger height = 11,
                              NSUInteger samples = 1, MTLStorageMode storage = MTLStorageModePrivate) {
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                      width:width height:height mipmapped:NO];
    descriptor.storageMode = storage;
    descriptor.usage = MTLTextureUsageRenderTarget;
    descriptor.sampleCount = samples;
    if (samples > 1) descriptor.textureType = MTLTextureType2DMultisample;
    return [device newTextureWithDescriptor:descriptor];
}

static id<MTLRenderPipelineState> makeSourcePipeline(id<MTLDevice> device, MTLPixelFormat format) {
    NSString *source = @R"MSL(
        #include <metal_stdlib>
        using namespace metal;
        struct VertexOut { float4 position [[position]]; float2 uv; };
        struct DepthOut { float depth [[depth(any)]]; };
        vertex VertexOut testVS(uint id [[vertex_id]]) {
            float2 uv = float2((id << 1) & 2, id & 2);
            return {float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0), uv};
        }
        fragment DepthOut testPS(VertexOut in [[stage_in]]) {
            return {0.1 + 0.6 * in.uv.x + 0.2 * in.uv.y};
        }
    )MSL";
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
    check(library != nil, "depth test shader compiles");
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"testVS"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"testPS"];
    descriptor.depthAttachmentPixelFormat = format;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!pipeline) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
    check(pipeline != nil, "depth-only render pipeline compiles");
    return pipeline;
}

static void drawDepth(id<MTLCommandBuffer> buffer, id<MTLTexture> texture,
                      id<MTLRenderPipelineState> pipeline, id<MTLDepthStencilState> depthState) {
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.depthAttachment.texture = texture;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    pass.depthAttachment.clearDepth = 1.0;
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline];
    [encoder setDepthStencilState:depthState];
    [encoder setCullMode:MTLCullModeNone];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
}

static float referenceDepth(int x, int y, int width, int height, bool depth16) {
    x = std::clamp(x, 0, width - 1); y = std::clamp(y, 0, height - 1);
    float value = 0.1f + 0.6f * (x + 0.5f) / width + 0.2f * (y + 0.5f) / height;
    return depth16 ? std::round(value * 65535.0f) / 65535.0f : value;
}

static float referenceResized(int x, int y, int outWidth, int outHeight, bool reversed, bool depth16) {
    float sourceX = (x + 0.5f) / outWidth * 17 - 0.5f;
    float sourceY = (y + 0.5f) / outHeight * 11 - 0.5f;
    int x0 = (int)std::floor(sourceX), y0 = (int)std::floor(sourceY);
    float fx = sourceX - x0, fy = sourceY - y0;
    float top = referenceDepth(x0, y0, 17, 11, depth16) * (1-fx) + referenceDepth(x0+1, y0, 17, 11, depth16) * fx;
    float bottom = referenceDepth(x0, y0+1, 17, 11, depth16) * (1-fx) + referenceDepth(x0+1, y0+1, 17, 11, depth16) * fx;
    float value = top * (1-fy) + bottom * fy;
    return reversed ? 1-value : value;
}

int main(void) { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    check(device != nil, "Metal device available");
    NSError *error = nil;
    MSDepthConverter *converter = [[MSDepthConverter alloc] initWithDevice:device error:&error];
    if (!converter) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
    check(converter != nil, "depth converter shader and pipeline compile");
    id<MTLCommandQueue> queue = [device newCommandQueue];
    MTLDepthStencilDescriptor *depthDescriptor = [MTLDepthStencilDescriptor new];
    depthDescriptor.depthCompareFunction = MTLCompareFunctionAlways;
    depthDescriptor.depthWriteEnabled = YES;
    id<MTLDepthStencilState> depthState = [device newDepthStencilStateWithDescriptor:depthDescriptor];
    for (MTLPixelFormat format : {MTLPixelFormatDepth32Float, MTLPixelFormatDepth16Unorm}) {
        id<MTLTexture> source = makeDepth(device, format);
        check(source != nil, "stored depth attachment allocates");
        id<MTLRenderPipelineState> pipeline = makeSourcePipeline(device, format);
        for (int variant = 0; variant < 3; ++variant) {
            bool reversed = variant == 2;
            NSUInteger width = variant == 0 ? 17 : 32, height = variant == 0 ? 11 : 20;
            id<MTLCommandBuffer> buffer = reversed ? [queue commandBufferWithUnretainedReferences] : [queue commandBuffer];
            if (reversed) [buffer enqueue];
            drawDepth(buffer, source, pipeline, depthState);
            id<MTLTexture> converted;
            @autoreleasepool {
                error = nil;
                converted = [converter encodeCommandBuffer:buffer depthTexture:source outputWidth:width outputHeight:height
                                                  reversed:reversed nearPlane:0.1 farPlane:1000 error:&error];
            }
            if (!converted) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            check(converted != nil && converted.pixelFormat == MTLPixelFormatR32Float, "conversion returns a real R32Float texture");
            NSUInteger bytesPerRow = ((width * sizeof(float) + 255) / 256) * 256;
            id<MTLBuffer> readback = [device newBufferWithLength:bytesPerRow * height options:MTLResourceStorageModeShared];
            id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
            [blit copyFromTexture:converted sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                      sourceSize:MTLSizeMake(width,height,1) toBuffer:readback destinationOffset:0
             destinationBytesPerRow:bytesPerRow destinationBytesPerImage:bytesPerRow * height];
            [blit endEncoding];
            [buffer commit]; [buffer waitUntilCompleted];
            if (buffer.error) fprintf(stderr, "%s\n", buffer.error.localizedDescription.UTF8String);
            check(buffer.status == MTLCommandBufferStatusCompleted, "depth GPU copy and conversion complete");
            float maximumError = 0;
            bool finite = true;
            for (NSUInteger y = 0; y < height; ++y) for (NSUInteger x = 0; x < width; ++x) {
                float actual; std::memcpy(&actual, (uint8_t *)readback.contents + y * bytesPerRow + x * sizeof(float), sizeof(float));
                finite = finite && std::isfinite(actual);
                float expected = referenceResized((int)x,(int)y,(int)width,(int)height,reversed,format == MTLPixelFormatDepth16Unorm);
                maximumError = std::max(maximumError, std::abs(actual - expected));
            }
            check(finite, "converted depth is finite");
            check(maximumError < 0.00004f, "depth values, orientation, bilinear borders and reversal match CPU reference");
        }
    }
    id<MTLTexture> source = makeDepth(device, MTLPixelFormatDepth32Float);
    auto rejected = [&](id<MTLTexture> texture, NSUInteger width, double nearPlane, double farPlane) {
        NSError *failure = nil;
        id<MTLTexture> result = [converter encodeCommandBuffer:[queue commandBuffer] depthTexture:texture
            outputWidth:width outputHeight:20 reversed:NO nearPlane:nearPlane farPlane:farPlane error:&failure];
        return result == nil && failure.localizedDescription.length > 0;
    };
    check(rejected(source,0,0.1,1000), "zero output dimension rejected");
    check(rejected(source,32,0,1000), "invalid near plane rejected");
    check(rejected(source,32,0.1,INFINITY), "infinite projection rejected rather than guessed");
    id<MTLTexture> color = makeDepth(device, MTLPixelFormatR32Float);
    check(rejected(color,32,0.1,1000), "color texture cannot masquerade as depth input");
    id<MTLTexture> packed = makeDepth(device, MTLPixelFormatDepth32Float_Stencil8);
    if (packed) {
        // Packed depth/stencil should now be accepted and the depth aspect extracted.
        id<MTLRenderPipelineState> packedPipeline = nil;
        {
            NSString *packedSource = @R"MSL(
                #include <metal_stdlib>
                using namespace metal;
                struct VertexOut { float4 position [[position]]; float2 uv; };
                struct DepthOut { float depth [[depth(any)]]; };
                vertex VertexOut testVS(uint id [[vertex_id]]) {
                    float2 uv = float2((id << 1) & 2, id & 2);
                    return {float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0), uv};
                }
                fragment DepthOut testPS(VertexOut in [[stage_in]]) {
                    return {0.1 + 0.6 * in.uv.x + 0.2 * in.uv.y};
                }
            )MSL";
            id<MTLLibrary> packedLib = [device newLibraryWithSource:packedSource options:nil error:&error];
            check(packedLib != nil, "packed depth test shader compiles");
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
            pd.vertexFunction = [packedLib newFunctionWithName:@"testVS"];
            pd.fragmentFunction = [packedLib newFunctionWithName:@"testPS"];
            pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            pd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            packedPipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error];
            check(packedPipeline != nil, "packed depth-stencil render pipeline compiles");
        }
        // Render depth into the packed texture.
        id<MTLCommandBuffer> packedBuffer = [queue commandBuffer];
        drawDepth(packedBuffer, packed, packedPipeline, depthState);
        // Convert the packed depth.
        error = nil;
        id<MTLTexture> packedConverted = [converter encodeCommandBuffer:packedBuffer depthTexture:packed
            outputWidth:32 outputHeight:20 reversed:NO nearPlane:0.1 farPlane:1000 error:&error];
        if (!packedConverted) fprintf(stderr, "packed conversion: %s\n", error.localizedDescription.UTF8String);
        check(packedConverted != nil && packedConverted.pixelFormat == MTLPixelFormatR32Float,
              "packed depth/stencil accepted and converted to R32Float");
        // Readback and verify values.
        NSUInteger packedBytesPerRow = ((32 * sizeof(float) + 255) / 256) * 256;
        id<MTLBuffer> packedReadback = [device newBufferWithLength:packedBytesPerRow * 20 options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> packedBlit = [packedBuffer blitCommandEncoder];
        [packedBlit copyFromTexture:packedConverted sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                  sourceSize:MTLSizeMake(32,20,1) toBuffer:packedReadback destinationOffset:0
         destinationBytesPerRow:packedBytesPerRow destinationBytesPerImage:packedBytesPerRow * 20];
        [packedBlit endEncoding];
        [packedBuffer commit]; [packedBuffer waitUntilCompleted];
        check(packedBuffer.status == MTLCommandBufferStatusCompleted, "packed depth conversion completes on GPU");
        float packedMaxError = 0;
        for (NSUInteger y = 0; y < 20; ++y) for (NSUInteger x = 0; x < 32; ++x) {
            float actual; std::memcpy(&actual, (uint8_t *)packedReadback.contents + y * packedBytesPerRow + x * sizeof(float), sizeof(float));
            float expected = referenceResized((int)x,(int)y,32,20,false,false);
            packedMaxError = std::max(packedMaxError, std::abs(actual - expected));
        }
        check(packedMaxError < 0.00004f, "packed depth/stencil conversion values match CPU reference");
    }
    if ([device supportsTextureSampleCount:4]) {
        id<MTLTexture> multisample = makeDepth(device, MTLPixelFormatDepth32Float, 17, 11, 4);
        check(multisample != nil, "4x multisample depth attachment allocates");

        id<MTLLibrary> msLib = [device newLibraryWithSource:@R"MSL(
            #include <metal_stdlib>
            using namespace metal;
            struct VertexOut { float4 position [[position]]; float2 uv; };
            struct DepthOut { float depth [[depth(any)]]; };
            vertex VertexOut testVS(uint id [[vertex_id]]) {
                float2 uv = float2((id << 1) & 2, id & 2);
                return {float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0), uv};
            }
            fragment DepthOut testPS(VertexOut in [[stage_in]]) {
                return {0.1 + 0.6 * in.uv.x + 0.2 * in.uv.y};
            }
        )MSL" options:nil error:&error];
        check(msLib != nil, "multisample test library compiles");
        MTLRenderPipelineDescriptor *msPipeDesc = [MTLRenderPipelineDescriptor new];
        msPipeDesc.vertexFunction = [msLib newFunctionWithName:@"testVS"];
        msPipeDesc.fragmentFunction = [msLib newFunctionWithName:@"testPS"];
        msPipeDesc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        msPipeDesc.rasterSampleCount = 4;
        id<MTLRenderPipelineState> msPipe = [device newRenderPipelineStateWithDescriptor:msPipeDesc error:&error];
        check(msPipe != nil, "4x multisample depth pipeline compiles");

        id<MTLCommandBuffer> msBuf = [queue commandBuffer];
        drawDepth(msBuf, multisample, msPipe, depthState);

        error = nil;
        id<MTLTexture> msConverted = [converter encodeCommandBuffer:msBuf depthTexture:multisample
                                                       outputWidth:32 outputHeight:20
                                                          reversed:NO nearPlane:0.1 farPlane:1000 error:&error];
        if (!msConverted) fprintf(stderr, "MSAA conversion error: %s\n", error.localizedDescription.UTF8String);
        check(msConverted != nil && msConverted.pixelFormat == MTLPixelFormatR32Float, "4x multisample depth converted to R32Float");

        NSUInteger msBytesPerRow = ((32 * sizeof(float) + 255) / 256) * 256;
        id<MTLBuffer> msReadback = [device newBufferWithLength:msBytesPerRow * 20 options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> msBlit = [msBuf blitCommandEncoder];
        [msBlit copyFromTexture:msConverted sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                     sourceSize:MTLSizeMake(32, 20, 1) toBuffer:msReadback destinationOffset:0
         destinationBytesPerRow:msBytesPerRow destinationBytesPerImage:msBytesPerRow * 20];
        [msBlit endEncoding];
        [msBuf commit];
        [msBuf waitUntilCompleted];
        check(msBuf.status == MTLCommandBufferStatusCompleted, "MSAA depth conversion completes on GPU");

        float msMaxError = 0;
        for (NSUInteger y = 0; y < 20; ++y) for (NSUInteger x = 0; x < 32; ++x) {
            float actual; std::memcpy(&actual, (uint8_t *)msReadback.contents + y * msBytesPerRow + x * sizeof(float), sizeof(float));
            float expected = referenceResized((int)x, (int)y, 32, 20, false, false);
            msMaxError = std::max(msMaxError, std::abs(actual - expected));
        }
        check(msMaxError < 0.05f, "MSAA depth conversion values approximate CPU reference");
    }
    if ([device supportsFamily:MTLGPUFamilyApple1]) {
        id<MTLTexture> memoryless = makeDepth(device,MTLPixelFormatDepth32Float,17,11,1,MTLStorageModeMemoryless);
        check(rejected(memoryless,32,0.1,1000), "memoryless depth rejected before encoding");
    }
    id<MTLCommandBuffer> committed = [queue commandBuffer]; [committed commit]; [committed waitUntilCompleted];
    error = nil;
    check([converter encodeCommandBuffer:committed depthTexture:source outputWidth:32 outputHeight:20
                               reversed:NO nearPlane:0.1 farPlane:1000 error:&error] == nil && error != nil,
          "committed command buffer rejected");
    NSError *hookError = nil;
    check(MSInstallHooks(&hookError), "hooks install on device");
    if ([device supportsFamily:MTLGPUFamilyApple1]) {
        MTLTextureDescriptor *memDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                          width:17 height:11 mipmapped:NO];
        memDesc.storageMode = MTLStorageModeMemoryless;
        memDesc.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> promoted = [device newTextureWithDescriptor:memDesc];
        check(promoted != nil, "promoted texture allocates");
        check(promoted.storageMode == MTLStorageModePrivate, "memoryless depth descriptor promoted to MTLStorageModePrivate");
        check((promoted.usage & MTLTextureUsageShaderRead) != 0, "promoted depth descriptor includes MTLTextureUsageShaderRead");

        id<MTLRenderPipelineState> pipeline = makeSourcePipeline(device, MTLPixelFormatDepth32Float);
        id<MTLCommandBuffer> promotedBuffer = [queue commandBuffer];
        drawDepth(promotedBuffer, promoted, pipeline, depthState);
        error = nil;
        id<MTLTexture> convertedPromoted = [converter encodeCommandBuffer:promotedBuffer depthTexture:promoted
                                                              outputWidth:32 outputHeight:20 reversed:NO
                                                                nearPlane:0.1 farPlane:1000 error:&error];
        check(convertedPromoted != nil, "promoted depth texture converted without error");
        [promotedBuffer commit]; [promotedBuffer waitUntilCompleted];
        check(promotedBuffer.status == MTLCommandBufferStatusCompleted, "promoted depth conversion completes on GPU");
    }

    // Verify Roblox DRS scenario: square shadow maps are ignored, but non-square
    // scene depth passes (e.g. 896x384) are captured continuously.
    NSURL *depthFXURL = [NSURL fileURLWithPath:@"Effects/DepthView.fx"];
    if ([NSFileManager.defaultManager fileExistsAtPath:depthFXURL.path]) {
        MSFXEffect *depthFX = [[MSFXEffect alloc] initWithURL:depthFXURL device:device width:1920 height:1080 error:&error];
        check(depthFX != nil && depthFX.requiresDepth, "DepthView FX compiles and requires depth");
        MSSetFXEffects(@[depthFX]);
        MSSetEnabled(YES);
        uint64_t beforeCaptures = MSDepthCaptureCount();

        id<MTLCommandBuffer> drsBuffer = [queue commandBuffer];

        // 1. Square shadow map (e.g. 2080x2080 or 256x256 Depth16Unorm).
        id<MTLTexture> shadowDepth = makeDepth(device, MTLPixelFormatDepth16Unorm, 256, 256);
        MTLRenderPassDescriptor *shadowDesc = [MTLRenderPassDescriptor renderPassDescriptor];
        shadowDesc.depthAttachment.texture = shadowDepth;
        shadowDesc.depthAttachment.loadAction = MTLLoadActionClear;
        shadowDesc.depthAttachment.storeAction = MTLStoreActionDontCare;
        id<MTLRenderCommandEncoder> shadowEncoder = [drsBuffer renderCommandEncoderWithDescriptor:shadowDesc];
        [shadowEncoder endEncoding];
        check(MSDepthCaptureCount() == beforeCaptures, "square shadow depth pass is ignored as candidate");

        // 2. Non-square scene depth pass (896x384 Depth32Float).
        id<MTLTexture> sceneDepth = makeDepth(device, MTLPixelFormatDepth32Float, 896, 384);
        id<MTLTexture> sceneColor = [device newTextureWithDescriptor:[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:896 height:384 mipmapped:NO]];
        MTLRenderPassDescriptor *sceneDesc = [MTLRenderPassDescriptor renderPassDescriptor];
        sceneDesc.depthAttachment.texture = sceneDepth;
        sceneDesc.depthAttachment.loadAction = MTLLoadActionClear;
        sceneDesc.depthAttachment.storeAction = MTLStoreActionDontCare;
        sceneDesc.colorAttachments[0].texture = sceneColor;
        id<MTLRenderCommandEncoder> sceneEncoder = [drsBuffer renderCommandEncoderWithDescriptor:sceneDesc];
        [sceneEncoder endEncoding];
        check(MSDepthCaptureCount() == beforeCaptures + 1, "non-square DRS scene depth (896x384) is captured as candidate");

        // 3. 4x MSAA scene depth pass (1710x979 Depth32Float, sampleCount=4).
        if ([device supportsTextureSampleCount:4]) {
            id<MTLTexture> msaaDepth = makeDepth(device, MTLPixelFormatDepth32Float, 1710, 979, 4);
            MTLRenderPassDescriptor *msaaDesc = [MTLRenderPassDescriptor renderPassDescriptor];
            msaaDesc.depthAttachment.texture = msaaDepth;
            msaaDesc.depthAttachment.loadAction = MTLLoadActionClear;
            msaaDesc.depthAttachment.storeAction = MTLStoreActionDontCare;
            id<MTLRenderCommandEncoder> msaaEncoder = [drsBuffer renderCommandEncoderWithDescriptor:msaaDesc];
            [msaaEncoder endEncoding];
            check(MSDepthCaptureCount() == beforeCaptures + 2, "4x MSAA scene depth (1710x979) is captured as candidate");
        }

        [drsBuffer commit]; [drsBuffer waitUntilCompleted];
        check(drsBuffer.status == MTLCommandBufferStatusCompleted, "DRS depth capture buffer completes cleanly");

        // 4. Cross-buffer global depth propagation:
        // drsBuffer committed and published its candidates to globalDepthRing.
        // Now create a separate consumer command buffer with NO depth passes.
        id<MTLCommandBuffer> consumerBuffer = [queue commandBuffer];
        id<MTLTexture> colorDrawable = [device newTextureWithDescriptor:[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:896 height:384 mipmapped:NO]];
        // The consumer buffer has no local candidates; bestGlobalDepth retrieves drsBuffer's published depth.
        MSSetFXEffects(@[depthFX]);
        MTLRenderPassDescriptor *consumerDesc = [MTLRenderPassDescriptor renderPassDescriptor];
        consumerDesc.colorAttachments[0].texture = colorDrawable;
        consumerDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
        id<MTLRenderCommandEncoder> consumerEncoder = [consumerBuffer renderCommandEncoderWithDescriptor:consumerDesc];
        [consumerEncoder endEncoding];
        [consumerBuffer commit]; [consumerBuffer waitUntilCompleted];
        check(consumerBuffer.status == MTLCommandBufferStatusCompleted, "consumer buffer completes with global depth propagation");

        MSSetFXEffects(@[]);
    }
    printf("PASS: %d depth GPU checks on %s\n", checks, device.name.UTF8String);
    return 0;
}}
