//
// Copyright (c) 2026 MacShade Authors. All Rights Reserved.
// PROPRIETARY AND CONFIDENTIAL.
// UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
//

#import "MacShade.h"
#include <algorithm>
#include <atomic>
#include <cmath>

namespace {
NSString *const MSErrorDomain = @"MacShade.Renderer";

BOOL MSFail(NSError **error, NSInteger code, NSString *message) {
    if (error) {
        *error = [NSError errorWithDomain:MSErrorDomain code:code
                                userInfo:@{NSLocalizedDescriptionKey: message}];
    }
    return NO;
}

float MSBound(float value, float low, float high, float fallback) {
    return std::isfinite(value) ? std::clamp(value, low, high) : fallback;
}

MSSettings MSSanitize(MSSettings value) {
    value.exposure = MSBound(value.exposure, -4, 4, 0);
    value.contrast = MSBound(value.contrast, 0, 2, 1);
    value.saturation = MSBound(value.saturation, 0, 2, 1);
    value.vibrance = MSBound(value.vibrance, -1, 1, 0);
    value.temperature = MSBound(value.temperature, -1, 1, 0);
    value.tint = MSBound(value.tint, -1, 1, 0);
    value.sharpen = MSBound(value.sharpen, 0, 2, 0);
    value.bloom = MSBound(value.bloom, 0, 1, 0);
    value.vignette = MSBound(value.vignette, 0, 1, 0);
    value.grain = MSBound(value.grain, 0, 1, 0);
    return value;
}

bool MSSupportedFormat(MTLPixelFormat format) {
    switch (format) {
        case MTLPixelFormatBGRA8Unorm:
        case MTLPixelFormatBGRA8Unorm_sRGB:
        case MTLPixelFormatRGBA8Unorm:
        case MTLPixelFormatRGBA8Unorm_sRGB:
        case MTLPixelFormatRGBA16Float:
            return true;
        default:
            return false;
    }
}

struct MSDrawParameters {
    MSSettings settings;
    uint32_t frameIndex;
};
static_assert(sizeof(MSSettings) == 40, "Metal settings layout must match");
static_assert(sizeof(MSDrawParameters) == 44, "Metal parameters layout must match");

// An original, fixed Metal effect chain. This is not a ReShade FX interpreter.
const char *const MSShaderSource = R"metal(
#include <metal_stdlib>
using namespace metal;

struct Settings {
    float exposure, contrast, saturation, vibrance, temperature;
    float tint, sharpen, bloom, vignette, grain;
};
struct Parameters { Settings settings; uint frameIndex; };
struct VertexOut { float4 position [[position]]; };

vertex VertexOut msFullscreen(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    VertexOut out;
    out.position = float4(positions[vertexID], 0, 1);
    return out;
}

float luminance(float3 value) { return dot(value, float3(0.2126, 0.7152, 0.0722)); }

float3 highlight(float3 value) {
    // Soft-knee extraction: neighboring bright pixels illuminate nearby pixels.
    float brightness = max(luminance(value), 0.0);
    float knee = clamp((brightness - 0.5) / 0.5, 0.0, 1.0);
    float contribution = max(brightness - 0.8, 0.0) + 0.15 * knee * knee;
    return value * (contribution / max(brightness, 0.00001));
}

uint hash(uint value) {
    value ^= value >> 16;
    value *= 0x7feb352du;
    value ^= value >> 15;
    value *= 0x846ca68bu;
    return value ^ (value >> 16);
}

fragment float4 msPostprocess(VertexOut in [[stage_in]],
                             texture2d<float> source [[texture(0)]],
                             constant Parameters &parameters [[buffer(0)]]) {
    const Settings s = parameters.settings;
    uint2 pixel = uint2(in.position.xy);
    float4 original = source.read(pixel);
    // Preserve exact neutral behavior, including HDR and negative float values.
    if (s.exposure == 0 && s.contrast == 1 && s.saturation == 1 &&
        s.vibrance == 0 && s.temperature == 0 && s.tint == 0 &&
        s.sharpen == 0 && s.bloom == 0 && s.vignette == 0 && s.grain == 0) {
        return original;
    }

    constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge,
                                  filter::linear);
    float2 size = float2(source.get_width(), source.get_height());
    float2 texel = 1.0 / size;
    float2 uv = in.position.xy * texel;
    float3 color = original.rgb;

    if (s.sharpen > 0) {
        float3 north = source.sample(linearClamp, uv + float2(0, -texel.y)).rgb;
        float3 south = source.sample(linearClamp, uv + float2(0, texel.y)).rgb;
        float3 west = source.sample(linearClamp, uv + float2(-texel.x, 0)).rgb;
        float3 east = source.sample(linearClamp, uv + float2(texel.x, 0)).rgb;
        float3 blurred = (north + south + west + east) * 0.25;
        color = max(color + (color - blurred) * s.sharpen, 0.0);
    }

    if (s.bloom > 0) {
        const float2 directions[8] = {
            float2(1, 0), float2(-1, 0), float2(0, 1), float2(0, -1),
            float2(0.7071, 0.7071), float2(-0.7071, 0.7071),
            float2(0.7071, -0.7071), float2(-0.7071, -0.7071)
        };
        // Use two radii, with the radius scaling gently with resolution.
        float radiusScale = max(1.0, min(size.x, size.y) / 1080.0);
        float3 bloom = highlight(original.rgb) * 0.12;
        for (uint index = 0; index < 8; ++index) {
            float2 offset = directions[index] * texel * radiusScale;
            bloom += highlight(source.sample(linearClamp, uv + offset * 3.0).rgb) * 0.07;
            bloom += highlight(source.sample(linearClamp, uv + offset * 8.0).rgb) * 0.04;
        }
        color += bloom * s.bloom;
    }

    color *= exp2(s.exposure);
    color *= exp2(float3(0.20 * s.temperature + 0.08 * s.tint,
                         -0.16 * s.tint,
                         -0.20 * s.temperature + 0.08 * s.tint));
    color = (color - 0.18) * s.contrast + 0.18;
    float luma = luminance(color);
    color = mix(float3(luma), color, s.saturation);
    float high = max(max(color.r, color.g), color.b);
    float low = min(min(color.r, color.g), color.b);
    float colorfulness = clamp((high - low) / max(abs(high), 0.00001), 0.0, 1.0);
    color = mix(float3(luminance(color)), color,
                1.0 + s.vibrance * (1.0 - colorfulness));

    if (s.vignette > 0) {
        float2 centered = (uv - 0.5) * 2.0;
        float darkness = smoothstep(0.25, 1.45, dot(centered, centered));
        color *= 1.0 - darkness * s.vignette * 0.75;
    }
    if (s.grain > 0) {
        uint noise = hash(pixel.x + pixel.y * 65537u + parameters.frameIndex * 104729u);
        float grain = (float(noise & 0xffffu) / 65535.0 - 0.5) * 0.12;
        color += grain * s.grain;
    }
    // Float render targets keep HDR headroom; UNorm targets clamp on write.
    return float4(color, original.a);
}
)metal";
} // namespace

MSSettings MSNeutralSettings(void) {
    return MSSettings{0, 1, 1, 0, 0, 0, 0, 0, 0, 0};
}

MSSettings MSDefaultSettings(void) {
    return MSSettings{0.08f, 1.04f, 1.03f, 0.08f, 0.01f, 0,
                      0.18f, 0.12f, 0.10f, 0};
}

@implementation MSRenderer {
    id<MTLDevice> _device;
    id<MTLLibrary> _library;
    id<MTLFunction> _vertexFunction;
    id<MTLFunction> _fragmentFunction;
    NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *_pipelines;
    std::atomic<uint32_t> _frameIndex;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device error:(NSError **)error {
    if (error) *error = nil;
    self = [super init];
    if (!self) return nil;
    if (!device) {
        MSFail(error, 1, @"A Metal device is required.");
        return nil;
    }
    _device = device;
    _frameIndex.store(0, std::memory_order_relaxed);
    _pipelines = [NSMutableDictionary dictionary];
    MTLCompileOptions *options = [[MTLCompileOptions alloc] init];
    options.fastMathEnabled = NO;
    _library = [device newLibraryWithSource:[NSString stringWithUTF8String:MSShaderSource]
                                   options:options error:error];
    if (!_library) return nil;
    _vertexFunction = [_library newFunctionWithName:@"msFullscreen"];
    _fragmentFunction = [_library newFunctionWithName:@"msPostprocess"];
    if (!_vertexFunction || !_fragmentFunction) {
        MSFail(error, 2, @"The built-in Metal shader functions could not be loaded.");
        return nil;
    }
    return self;
}

- (id<MTLRenderPipelineState>)pipelineForFormat:(MTLPixelFormat)format error:(NSError **)error {
    // Pipeline creation is expensive; both lookup and insertion share one lock.
    @synchronized (_pipelines) {
        NSNumber *key = @(format);
        id<MTLRenderPipelineState> existing = _pipelines[key];
        if (existing) return existing;
        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.label = @"MacShade postprocess";
        descriptor.vertexFunction = _vertexFunction;
        descriptor.fragmentFunction = _fragmentFunction;
        descriptor.colorAttachments[0].pixelFormat = format;
        descriptor.colorAttachments[0].blendingEnabled = NO;
        id<MTLRenderPipelineState> pipeline = [_device newRenderPipelineStateWithDescriptor:descriptor error:error];
        if (pipeline) _pipelines[key] = pipeline;
        return pipeline;
    }
}

- (BOOL)encodeCommandBuffer:(id<MTLCommandBuffer>)commandBuffer
                    texture:(id<MTLTexture>)texture
                   settings:(MSSettings)settings
                      error:(NSError **)error {
    if (error) *error = nil;
    if (!commandBuffer || !texture) {
        return MSFail(error, 3, @"A command buffer and destination texture are required.");
    }
    if (commandBuffer.device != _device || texture.device != _device) {
        return MSFail(error, 4, @"The renderer, command buffer, and texture must use the same Metal device.");
    }
    if (commandBuffer.status >= MTLCommandBufferStatusCommitted) {
        return MSFail(error, 5, @"The command buffer has already been committed and cannot accept more work.");
    }
    if (texture.framebufferOnly) {
        return MSFail(error, 6, @"The texture is framebuffer-only. Set CAMetalLayer.framebufferOnly = NO before acquiring drawables.");
    }
    if (texture.textureType != MTLTextureType2D || texture.sampleCount != 1 ||
        texture.depth != 1 || texture.arrayLength != 1) {
        return MSFail(error, 7, @"Only single-sample, non-array 2D textures are supported. Resolve multisampling first.");
    }
    if (texture.storageMode == MTLStorageModeMemoryless) {
        return MSFail(error, 8, @"A memoryless texture cannot be copied; provide a stored color texture.");
    }
    if (!MSSupportedFormat(texture.pixelFormat)) {
        return MSFail(error, 9, @"Supported formats are BGRA8Unorm, BGRA8Unorm_sRGB, RGBA8Unorm, RGBA8Unorm_sRGB, and RGBA16Float.");
    }
    if (texture.usage != MTLTextureUsageUnknown && !(texture.usage & MTLTextureUsageRenderTarget)) {
        return MSFail(error, 10, @"The destination texture must permit render-target usage.");
    }
    if (texture.width == 0 || texture.height == 0) {
        return MSFail(error, 11, @"The destination texture must have nonzero dimensions.");
    }

    id<MTLRenderPipelineState> pipeline = [self pipelineForFormat:texture.pixelFormat error:error];
    if (!pipeline) return NO;
    MTLTextureDescriptor *copyDescriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:texture.pixelFormat
        width:texture.width height:texture.height mipmapped:NO];
    copyDescriptor.storageMode = MTLStorageModePrivate;
    copyDescriptor.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> source = [_device newTextureWithDescriptor:copyDescriptor];
    if (!source) {
        return MSFail(error, 12, @"Metal could not allocate the per-frame source texture.");
    }
    source.label = @"MacShade immutable frame copy";

    // Keep every encoded resource alive even for commandBufferWithUnretainedReferences.
    // A distinct copy for each call also permits several frames to be in flight.
    NSArray *heldResources = @[source, texture, pipeline];
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        (void)completed;
        (void)heldResources.count;
    }];

    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    if (!blit) return MSFail(error, 13, @"Metal could not create the frame-copy encoder.");
    blit.label = @"MacShade copy source";
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
              sourceSize:MTLSizeMake(texture.width, texture.height, 1)
               toTexture:source destinationSlice:0 destinationLevel:0
       destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) return MSFail(error, 14, @"Metal could not create the postprocess render encoder.");
    encoder.label = @"MacShade effect chain";
    [encoder setRenderPipelineState:pipeline];
    [encoder setCullMode:MTLCullModeNone];
    [encoder setViewport:MTLViewport{0, 0, double(texture.width), double(texture.height), 0, 1}];
    [encoder setFragmentTexture:source atIndex:0];
    const MSDrawParameters parameters = {MSSanitize(settings), _frameIndex.fetch_add(1, std::memory_order_relaxed)};
    [encoder setFragmentBytes:&parameters length:sizeof(parameters) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    return YES;
}
@end
