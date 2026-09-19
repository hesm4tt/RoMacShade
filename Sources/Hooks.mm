//
// Copyright (c) 2026 MacShade Authors. All Rights Reserved.
// PROPRIETARY AND CONFIDENTIAL.
// UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
//

#import "Obfuscate.h"
#import "MacShade.h"
#import "FXRuntime.h"
#import "DepthCapture.h"
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#include <atomic>
#include <mutex>
#include <cmath>

// CAMetalDrawable owns its texture, so the reverse association must be weak.
@interface MSWeakDrawable : NSObject
@property(nonatomic, weak) id<CAMetalDrawable> drawable;
@end
@implementation MSWeakDrawable
@end

// The texture is immutable after its producer finishes encoding. Readiness is
// updated by Metal callbacks, which may run concurrently with later submissions.
@interface MSDepthCandidate : NSObject {
@public
    std::atomic<bool> scheduled;
    std::atomic<bool> failed;
}
@property(nonatomic, strong) id<MTLTexture> depth;
@property(nonatomic, strong) id<MTLTexture> color;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic) BOOL reversed;
@property(nonatomic) uint64_t sequence;
@property(nonatomic) CFTimeInterval timestamp;
@end
@implementation MSDepthCandidate
- (instancetype)init {
    if ((self = [super init])) {
        scheduled.store(false);
        failed.store(false);
    }
    return self;
}
@end

// These hooks are experimental. Install once, before the host starts rendering.
// Only the observed default-device command-buffer class is hooked. No private
// class names, byte patches, or modification of another process are used.
namespace {
struct State {
    std::mutex settingsLock;
    MSSettings settings = MSDefaultSettings();
    std::atomic<bool> enabled{true};
    std::atomic<uint64_t> frames{0};
    std::atomic<uint64_t> completedFrames{0};
    std::atomic<uint64_t> gpuErrors{0};
    std::atomic<uint64_t> acquiredDrawables{0};
    std::atomic<uint64_t> committedBuffers{0};
    std::atomic<uint64_t> renderTargetMatches{0};
    std::atomic<uint64_t> fxFrames{0};
    std::atomic<uint64_t> depthFrames{0};
    std::atomic<bool> depthReversed{false};
    NSString *__strong depthStatus = @"Waiting for a compatible scene depth buffer";
    NSArray<MSFXEffect *> *__strong effects = @[];
};
State &state() { static State s; return s; }
char pendingKey;
char processingKey;
char depthCandidatesKey;
char encoderDepthKey;
char captureInProgressKey;
char drawableTextureKey;

std::mutex &globalDepthLock() { static std::mutex lock; return lock; }
constexpr size_t kGlobalDepthCapacity = 32;
MSDepthCandidate *__strong globalDepthRing[kGlobalDepthCapacity] = {};
uint64_t globalDepthSequence = 0;
size_t globalDepthWriteIndex = 0;

static std::atomic<NSUInteger> gObservedDrawableWidth{0};
static std::atomic<NSUInteger> gObservedDrawableHeight{0};
static void setObservedDrawableSize(NSUInteger w, NSUInteger h) {
    if (w && h) {
        gObservedDrawableWidth.store(w, std::memory_order_relaxed);
        gObservedDrawableHeight.store(h, std::memory_order_relaxed);
    }
}

// Publish only after the original commit has enqueued its producer. Publishing at
// endEncoding exposes an uninitialized texture if another buffer commits first.
void publishGlobalDepth(id<MTLCommandBuffer> buffer) {
    NSArray<MSDepthCandidate *> *candidates;
    @synchronized(buffer) { candidates = [objc_getAssociatedObject(buffer, &depthCandidatesKey) copy]; }
    if (!candidates.count) return;
    std::lock_guard<std::mutex> lock(globalDepthLock());
    const uint64_t sequence = ++globalDepthSequence;
    const CFTimeInterval now = CACurrentMediaTime();
    for (MSDepthCandidate *candidate in candidates) {
        candidate.sequence = sequence;
        candidate.timestamp = now;
        globalDepthRing[globalDepthWriteIndex++ % kGlobalDepthCapacity] = candidate;
    }
}

bool plausibleDepth(id<MTLTexture> depth, NSUInteger width, NSUInteger height) {
    return depth.width >= 128 && depth.height >= 128 &&
           (depth.width != depth.height || width == height);
}
bool matchingDepthAspect(id<MTLTexture> depth, NSUInteger width, NSUInteger height) {
    if (!width || !height) return false;
    const double ratio = (double(depth.width) * height) / (double(depth.height) * width);
    return std::abs(ratio - 1.0) < 0.05;
}
id<MTLTexture> bestGlobalDepth(id<MTLCommandBuffer> consumer, NSUInteger width, NSUInteger height) {
    std::lock_guard<std::mutex> lock(globalDepthLock());
    id<MTLTexture> best = nil;
    uint64_t bestSeq = 0;
    double bestArea = 0;
    bool bestAspect = false;
    const CFTimeInterval now = CACurrentMediaTime();
    for (MSDepthCandidate *entry : globalDepthRing) {
        if (!entry || entry->failed.load() ||
            entry.depth.device != consumer.device || entry.reversed != MSIsDepthReversed()) continue;
        if (entry.queue != consumer.commandQueue && !entry->scheduled.load()) continue;
        if (now - entry.timestamp > 2.0 || !plausibleDepth(entry.depth, width, height)) continue;
        // An explicitly pre-enqueued consumer might precede this producer on the
        // queue, even if committed later. A scheduled producer is already ahead.
        if (consumer.status != MTLCommandBufferStatusNotEnqueued && !entry->scheduled.load()) continue;
        const double area = double(entry.depth.width) * double(entry.depth.height);
        const bool aspect = matchingDepthAspect(entry.depth, width, height);
        if (entry.sequence > bestSeq || (entry.sequence == bestSeq &&
            ((aspect && !bestAspect) || (aspect == bestAspect && area >= bestArea)))) {
            bestArea = area;
            bestSeq = entry.sequence;
            bestAspect = aspect;
            best = entry.depth;
        }
    }
    return best;
}

void remember(id buffer, id drawable) {
    if (!drawable || ![drawable conformsToProtocol:@protocol(CAMetalDrawable)]) return;
    @synchronized(buffer) {
        NSMutableArray *pending = objc_getAssociatedObject(buffer, &pendingKey);
        if (!pending) {
            pending = [NSMutableArray array];
            objc_setAssociatedObject(buffer, &pendingKey, pending, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if ([pending indexOfObjectIdenticalTo:drawable] == NSNotFound) [pending addObject:drawable];
    }
}

void reportOnce(NSError *error) {
    static NSMutableSet<NSString *> *reported;
    static dispatch_once_t token;
    dispatch_once(&token, ^{ reported = [NSMutableSet set]; });
    NSString *message = error.localizedDescription ?: @"Unknown rendering error";
    @synchronized(reported) {
        if (![reported containsObject:message]) {
            [reported addObject:message];
            NSLog(@"MacShade: skipping effect: %@", message);
        }
    }
}

MSRenderer *rendererForDevice(id<MTLDevice> device, NSError **error) {
    static NSMapTable *renderers;
    static dispatch_once_t token;
    dispatch_once(&token, ^{ renderers = [NSMapTable strongToStrongObjectsMapTable]; });
    @synchronized(renderers) {
        MSRenderer *renderer = [renderers objectForKey:device];
        if (!renderer) {
            renderer = [[MSRenderer alloc] initWithDevice:device error:error];
            if (renderer) [renderers setObject:renderer forKey:device];
        }
        return renderer;
    }
}

void depthStatus(NSString *message) {
    std::lock_guard<std::mutex> lock(state().settingsLock); state().depthStatus = message;
}
MSDepthConverter *converterForDevice(id<MTLDevice> device, NSError **error) {
    static NSMapTable *converters;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ converters = [NSMapTable strongToStrongObjectsMapTable]; });
    @synchronized(converters) {
        MSDepthConverter *converter = [converters objectForKey:device];
        if (!converter) {
            converter = [[MSDepthConverter alloc] initWithDevice:device error:error];
            if (converter) [converters setObject:converter forKey:device];
        }
        return converter;
    }
}
void captureDepth(NSDictionary *record) {
    id<MTLCommandBuffer> buffer = record[@"buffer"];
    id<MTLTexture> source = record[@"source"];
    if (!buffer || !source) return;
    objc_setAssociatedObject(buffer,&captureInProgressKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSError *error = nil;
    MSDepthConverter *converter = converterForDevice(buffer.device,&error);
    const BOOL reversed = MSIsDepthReversed();
    id<MTLTexture> snapshot = [converter encodeCommandBuffer:buffer depthTexture:source
        outputWidth:source.width outputHeight:source.height reversed:reversed
        nearPlane:1.0 farPlane:1000.0 error:&error];
    objc_setAssociatedObject(buffer,&captureInProgressKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!snapshot) { depthStatus(error.localizedDescription ?: @"Could not capture scene depth"); return; }
    @synchronized(buffer) {
        NSMutableArray *candidates = objc_getAssociatedObject(buffer,&depthCandidatesKey);
        if (!candidates) {
            candidates = [NSMutableArray array];
            objc_setAssociatedObject(buffer,&depthCandidatesKey,candidates,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (candidates.count == 8) [candidates removeObjectAtIndex:0];
        MSDepthCandidate *entry = [MSDepthCandidate new];
        entry.depth = snapshot; entry.color = record[@"color"];
        entry.queue = buffer.commandQueue; entry.reversed = reversed;
        [candidates addObject:entry];
        [buffer addScheduledHandler:^(id<MTLCommandBuffer> scheduledBuffer) {
            (void)scheduledBuffer;
            entry->scheduled.store(true);
        }];
        [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            if (completed.status != MTLCommandBufferStatusCompleted) entry->failed.store(true);
        }];
    }
    state().depthFrames.fetch_add(1,std::memory_order_relaxed);
}
id<MTLTexture> depthForDrawable(id<MTLCommandBuffer> buffer, id<MTLTexture> drawable) {
    NSArray *candidates;
    @synchronized(buffer) { candidates = [objc_getAssociatedObject(buffer,&depthCandidatesKey) copy]; }
    id<MTLTexture> best = nil; double bestScore = 0; bool bestAspect = false, exactColor = false;
    for (MSDepthCandidate *candidate in candidates) {
        id<MTLTexture> depth = candidate.depth, color = candidate.color;
        if (candidate.reversed != MSIsDepthReversed()) continue;
        if (color && color == drawable) { best = depth; exactColor = true; continue; }
        if (exactColor || !plausibleDepth(depth, drawable.width, drawable.height)) continue;
        const bool aspect = matchingDepthAspect(depth, drawable.width, drawable.height);
        const double score = double(depth.width)*double(depth.height);
        if ((aspect && !bestAspect) || (aspect == bestAspect && score >= bestScore)) {
            bestScore=score; bestAspect=aspect; best=depth;
        }
    }
    // Fall back only to previously submitted producers on this command queue.
    if (!best) best = bestGlobalDepth(buffer, drawable.width, drawable.height);
    if (best) depthStatus([NSString stringWithFormat:@"Depth captured · %lu × %lu · %@ input",
        (unsigned long)best.width,(unsigned long)best.height,MSIsDepthReversed() ? @"reversed" : @"forward"]);
    else depthStatus(@"Waiting for scene depth");
    return best;
}
} // namespace

static const char *const kScaleMSL = R"metal(
#include <metal_stdlib>
using namespace metal;
struct ScaleV { float4 pos [[position]]; float2 uv; };
vertex ScaleV scaleVS(uint i [[vertex_id]]) {
    float2 p = float2((i << 1) & 2, i & 2) * 2.0 - 1.0;
    return { float4(p, 0.0, 1.0), p * float2(0.5, -0.5) + 0.5 };
}
fragment float4 scalePS(ScaleV in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
    return tex.sample(s, in.uv);
}
)metal";

@interface MSScaleHelper : NSObject {
    id<MTLDevice> _device;
    id<MTLLibrary> _library;
    id<MTLSamplerState> _sampler;
    NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *_pipelines;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (void)scaleCommandBuffer:(id<MTLCommandBuffer>)buffer
                    source:(id<MTLTexture>)source
               destination:(id<MTLTexture>)destination;
@end

@implementation MSScaleHelper
- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if ((self = [super init])) {
        _device = device;
        _pipelines = [NSMutableDictionary dictionary];
        NSError *error = nil;
        _library = [_device newLibraryWithSource:@(kScaleMSL) options:nil error:&error];
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = MTLSamplerMinMagFilterLinear;
        sd.magFilter = MTLSamplerMinMagFilterLinear;
        sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.rAddressMode = MTLSamplerAddressModeClampToEdge;
        _sampler = [_device newSamplerStateWithDescriptor:sd];
    }
    return self;
}
- (id<MTLRenderPipelineState>)pipelineForFormat:(MTLPixelFormat)format {
    @synchronized(_pipelines) {
        id<MTLRenderPipelineState> pipeline = _pipelines[@(format)];
        if (pipeline) return pipeline;
        if (!_library) return nil;
        MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
        desc.vertexFunction = [_library newFunctionWithName:@"scaleVS"];
        desc.fragmentFunction = [_library newFunctionWithName:@"scalePS"];
        desc.colorAttachments[0].pixelFormat = format;
        NSError *error = nil;
        pipeline = [_device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (pipeline) _pipelines[@(format)] = pipeline;
        return pipeline;
    }
}
- (void)scaleCommandBuffer:(id<MTLCommandBuffer>)buffer
                    source:(id<MTLTexture>)source
               destination:(id<MTLTexture>)destination {
    id<MTLRenderPipelineState> pipeline = [self pipelineForFormat:destination.pixelFormat];
    if (!pipeline || !_sampler) return;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = destination;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentTexture:source atIndex:0];
    [encoder setFragmentSamplerState:_sampler atIndex:0];
    [encoder setCullMode:MTLCullModeNone];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
}
@end

static MSScaleHelper *scaleHelperForDevice(id<MTLDevice> device) {
    static NSMapTable *helpers;
    static dispatch_once_t token;
    dispatch_once(&token, ^{ helpers = [NSMapTable strongToStrongObjectsMapTable]; });
    @synchronized(helpers) {
        MSScaleHelper *helper = [helpers objectForKey:device];
        if (!helper) {
            helper = [[MSScaleHelper alloc] initWithDevice:device];
            if (helper) [helpers setObject:helper forKey:device];
        }
        return helper;
    }
}

namespace {
void process(id<MTLCommandBuffer> buffer) {
    state().committedBuffers.fetch_add(1, std::memory_order_relaxed);
    NSArray *pending;
    @synchronized(buffer) {
        if (objc_getAssociatedObject(buffer, &processingKey)) return;
        objc_setAssociatedObject(buffer, &processingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pending = [objc_getAssociatedObject(buffer, &pendingKey) copy];
        objc_setAssociatedObject(buffer, &pendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!MSIsEnabled() || pending.count == 0) return;
    MSSettings settings = MSGetSettings();
    NSArray<MSFXEffect *> *effects = MSGetFXEffects();
    static const CFTimeInterval started = CACurrentMediaTime();
    uint64_t encodedFrames = 0;
    for (id<CAMetalDrawable> drawable in pending) {
        NSError *error = nil;
        MSRenderer *renderer = rendererForDevice(buffer.device, &error);
        if (renderer && [renderer encodeCommandBuffer:buffer texture:drawable.texture settings:settings error:&error]) {
            state().frames.fetch_add(1, std::memory_order_relaxed);
            ++encodedFrames;
        } else {
            reportOnce(error);
        }
        if (effects.count > 0) {
            const double seconds = CACurrentMediaTime()-started;
            BOOL succeeded = NO;
            BOOL needsDepth = NO;
            for (MSFXEffect *effect in effects) if (effect.requiresDepth) needsDepth=YES;
            id<MTLTexture> depth = needsDepth ? depthForDrawable(buffer,drawable.texture) : nil;

            const NSUInteger effW = effects[0].width;
            const NSUInteger effH = effects[0].height;
            const BOOL isScaled = (effW > 0 && effH > 0 && (effW != drawable.texture.width || effH != drawable.texture.height));
            id<MTLTexture> targetTexture = drawable.texture;
            id<MTLTexture> scaledTexture = nil;
            if (isScaled) {
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:drawable.texture.pixelFormat
                                                                                              width:effW
                                                                                             height:effH
                                                                                          mipmapped:NO];
                td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
                td.storageMode = MTLStorageModePrivate;
                scaledTexture = [buffer.device newTextureWithDescriptor:td];
                if (scaledTexture) {
                    MSScaleHelper *scaler = scaleHelperForDevice(buffer.device);
                    [scaler scaleCommandBuffer:buffer source:drawable.texture destination:scaledTexture];
                    targetTexture = scaledTexture;
                    [buffer addCompletedHandler:^(id<MTLCommandBuffer>){ (void)scaledTexture; }];
                }
            }

            for (MSFXEffect *effect in effects) {
                if (effect.requiresDepth && !depth) {
                    continue;
                }
                error = nil;
                if (![effect encodeCommandBuffer:buffer texture:targetTexture depthTexture:depth time:seconds error:&error]) {
                    reportOnce(error);
                    continue;
                }
                succeeded = YES;
            }
            if (succeeded) {
                state().fxFrames.fetch_add(1, std::memory_order_relaxed);
                if (isScaled && scaledTexture) {
                    MSScaleHelper *scaler = scaleHelperForDevice(buffer.device);
                    [scaler scaleCommandBuffer:buffer source:scaledTexture destination:drawable.texture];
                }
            }
        }
    }
    if (encodedFrames) {
        [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            if (completed.status == MTLCommandBufferStatusCompleted) {
                state().completedFrames.fetch_add(encodedFrames, std::memory_order_relaxed);
            } else {
                state().gpuErrors.fetch_add(1, std::memory_order_relaxed);
                reportOnce(completed.error);
            }
        }];
    }
}

// Adding an override first avoids mutating a superclass when a selector is inherited.
void replace(Class cls, SEL selector, IMP imp) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!class_addMethod(cls, selector, imp, method_getTypeEncoding(method))) {
        class_replaceMethod(cls, selector, imp, method_getTypeEncoding(method));
    }
}

static BOOL isDepthPixelFormat(MTLPixelFormat format) {
    return format == MTLPixelFormatDepth32Float ||
           format == MTLPixelFormatDepth16Unorm ||
           format == MTLPixelFormatDepth32Float_Stencil8 ||
           format == MTLPixelFormatDepth24Unorm_Stencil8;
}

static BOOL isRobloxHost(void) {
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (bundleID && [bundleID.lowercaseString containsString:@"roblox"]) return YES;
    NSString *processName = NSProcessInfo.processInfo.processName;
    if (processName && [processName.lowercaseString containsString:@"roblox"]) return YES;
    return NO;
}

static void hookDeviceClass(Class devCls) {
    if (!devCls) return;
    static NSMutableSet *hookedClasses;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ hookedClasses = [NSMutableSet set]; });
    @synchronized(hookedClasses) {
        NSString *name = NSStringFromClass(devCls);
        if ([hookedClasses containsObject:name]) return;
        SEL sel = @selector(newTextureWithDescriptor:);
        Method method = class_getInstanceMethod(devCls, sel);
        if (method) {
            IMP original = class_getMethodImplementation(devCls, sel);
            replace(devCls, sel, imp_implementationWithBlock(^id(id receiver, MTLTextureDescriptor *desc){
                if (desc && isDepthPixelFormat(desc.pixelFormat)) {
                    if (desc.storageMode == MTLStorageModeMemoryless) {
                        desc.storageMode = MTLStorageModePrivate;
                    }
                    desc.usage |= MTLTextureUsageShaderRead;
                }
                return ((id(*)(id, SEL, id))original)(receiver, sel, desc);
            }));
        }
        SEL selIOSurface = @selector(newTextureWithDescriptor:iosurface:plane:);
        Method methodIOSurface = class_getInstanceMethod(devCls, selIOSurface);
        if (methodIOSurface) {
            IMP originalIOSurface = class_getMethodImplementation(devCls, selIOSurface);
            replace(devCls, selIOSurface, imp_implementationWithBlock(^id(id receiver, MTLTextureDescriptor *desc, void *ioSurface, NSUInteger plane){
                if (desc && isDepthPixelFormat(desc.pixelFormat)) {
                    if (desc.storageMode == MTLStorageModeMemoryless) {
                        desc.storageMode = MTLStorageModePrivate;
                    }
                    desc.usage |= MTLTextureUsageShaderRead;
                }
                return ((id(*)(id, SEL, id, void *, NSUInteger))originalIOSurface)(receiver, selIOSurface, desc, ioSurface, plane);
            }));
        }
        [hookedClasses addObject:name];
    }
}

void observeDepthEncoder(id<MTLRenderCommandEncoder> encoder) {
    if (!encoder) return;
    static NSMutableSet *classes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ classes=[NSMutableSet set]; });
    @synchronized(classes) {
        Class cls=object_getClass(encoder); NSString *name=NSStringFromClass(cls);
        if([classes containsObject:name]) return;
        SEL end=@selector(endEncoding); IMP original=class_getMethodImplementation(cls,end);
        replace(cls,end,imp_implementationWithBlock(^(id receiver){
            NSDictionary *record=objc_getAssociatedObject(receiver,&encoderDepthKey);
            objc_setAssociatedObject(receiver,&encoderDepthKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ((void(*)(id,SEL))original)(receiver,end);
            if(record) captureDepth(record);
        }));
        [classes addObject:name];
    }
}

BOOL install(NSError **error) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> buffer = [queue commandBuffer];
    Class cls = object_getClass(buffer);
    Class layerClass = [CAMetalLayer class];
    SEL plain = @selector(presentDrawable:);
    SEL timed = @selector(presentDrawable:atTime:);
    SEL duration = @selector(presentDrawable:afterMinimumDuration:);
    SEL commit = @selector(commit);
    SEL next = @selector(nextDrawable);
    SEL render = @selector(renderCommandEncoderWithDescriptor:);
    if (!buffer || !class_getInstanceMethod(cls, plain) ||
        !class_getInstanceMethod(cls, timed) || !class_getInstanceMethod(cls, duration) ||
        !class_getInstanceMethod(cls, commit) || !class_getInstanceMethod(cls,render) || !class_getInstanceMethod(layerClass, next)) {
        if (error) *error = [NSError errorWithDomain:@"MacShade.Hooks" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"No compatible default-device Metal command buffer was found."
        }];
        return NO;
    }
    // Resolve every original before mutation. A wrapper may delegate to another
    // present variant; remember() deduplicates that drawable by identity.
    IMP originalPlain = class_getMethodImplementation(cls, plain);
    IMP originalTimed = class_getMethodImplementation(cls, timed);
    IMP originalDuration = class_getMethodImplementation(cls, duration);
    IMP originalCommit = class_getMethodImplementation(cls, commit);
    IMP originalNext = class_getMethodImplementation(layerClass, next);
    IMP originalRender = class_getMethodImplementation(cls,render);
    replace(cls,render,imp_implementationWithBlock(^id(id receiver, MTLRenderPassDescriptor *descriptor){
        // Some hosts call present on CAMetalDrawable itself. Associate its color
        // writer with this buffer while encoding is still open, so processing
        // runs at commit before the host presents it through either API.
        if (!objc_getAssociatedObject(receiver, &processingKey)) {
            for (NSUInteger i = 0; i < 8; ++i) {
                MSWeakDrawable *reference = objc_getAssociatedObject(descriptor.colorAttachments[i].texture, &drawableTextureKey);
                id<CAMetalDrawable> drawable = reference.drawable;
                if (drawable) {
                    remember(receiver, drawable);
                    state().renderTargetMatches.fetch_add(1, std::memory_order_relaxed);
                }
            }
        }
        BOOL needsDepth=NO;
        if (MSIsEnabled() && !objc_getAssociatedObject(receiver,&processingKey) && !objc_getAssociatedObject(receiver,&captureInProgressKey))
            for (MSFXEffect *effect in MSGetFXEffects()) if (effect.requiresDepth) { needsDepth=YES; break; }
        id<MTLTexture> depth=descriptor.depthAttachment.texture, color=descriptor.colorAttachments[0].texture;
        NSUInteger dw = gObservedDrawableWidth.load(std::memory_order_relaxed);
        NSUInteger dh = gObservedDrawableHeight.load(std::memory_order_relaxed);
        BOOL isSquare = depth && (depth.width == depth.height);
        BOOL plausibleCandidate = YES;
        if (depth) {
            if (isSquare && (dw != dh || dw == 0)) plausibleCandidate = NO;
        }
        BOOL candidate=needsDepth && depth && plausibleCandidate &&
            (depth.textureType==MTLTextureType2D || depth.textureType==MTLTextureType2DMultisample) &&
            depth.sampleCount>=1 && depth.storageMode!=MTLStorageModeMemoryless &&
            isDepthPixelFormat(depth.pixelFormat) &&
            depth.width>=128 && depth.height>=128 &&
            descriptor.depthAttachment.level==0 && descriptor.depthAttachment.slice==0;
        static CFTimeInterval lastLog=0;
        if (needsDepth && depth && (CACurrentMediaTime() - lastLog > 5.0)) {
            lastLog = CACurrentMediaTime();
            NSLog(@"MacShade: depth pass eval: %lux%lu format=%lu storage=%lu samples=%lu candidate=%d color=%lux%lu",
                  (unsigned long)depth.width, (unsigned long)depth.height,
                  (unsigned long)depth.pixelFormat, (unsigned long)depth.storageMode,
                  (unsigned long)depth.sampleCount, candidate,
                  (unsigned long)color.width, (unsigned long)color.height);
        }
        MTLRenderPassDescriptor *actual=descriptor;
        if(candidate) {
            actual=[descriptor copy];
            if (actual.depthAttachment.resolveTexture != nil) {
                actual.depthAttachment.storeAction = MTLStoreActionStoreAndMultisampleResolve;
            } else {
                actual.depthAttachment.storeAction = MTLStoreActionStore;
            }
        }
        id<MTLRenderCommandEncoder> encoder=((id(*)(id,SEL,id))originalRender)(receiver,render,actual);
        if(candidate && encoder) {
            observeDepthEncoder(encoder);
            NSMutableDictionary *record = [NSMutableDictionary dictionaryWithCapacity:3];
            record[@"buffer"] = receiver;
            record[@"source"] = depth;
            if (color) record[@"color"] = color;
            objc_setAssociatedObject(encoder,&encoderDepthKey,record,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return encoder;
    }));
    replace(cls, plain, imp_implementationWithBlock(^(id receiver, id drawable) {
        remember(receiver, drawable);
        ((void (*)(id, SEL, id))originalPlain)(receiver, plain, drawable);
    }));
    replace(cls, timed, imp_implementationWithBlock(^(id receiver, id drawable, double time) {
        remember(receiver, drawable);
        ((void (*)(id, SEL, id, double))originalTimed)(receiver, timed, drawable, time);
    }));
    replace(cls, duration, imp_implementationWithBlock(^(id receiver, id drawable, double time) {
        remember(receiver, drawable);
        ((void (*)(id, SEL, id, double))originalDuration)(receiver, duration, drawable, time);
    }));
    replace(cls, commit, imp_implementationWithBlock(^(id receiver) {
        @autoreleasepool { process(receiver); }
        ((void (*)(id, SEL))originalCommit)(receiver, commit);
        publishGlobalDepth(receiver);
    }));
    replace(layerClass, next, imp_implementationWithBlock(^id(id receiver) {
        // Must happen before allocation, not after acquiring a drawable.
        ((CAMetalLayer *)receiver).framebufferOnly = NO;
        id<CAMetalDrawable> drawable = ((id (*)(id, SEL))originalNext)(receiver, next);
        if (drawable) {
            MSWeakDrawable *reference = [MSWeakDrawable new]; reference.drawable = drawable;
            objc_setAssociatedObject(drawable.texture, &drawableTextureKey, reference, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            state().acquiredDrawables.fetch_add(1, std::memory_order_relaxed);
            setObservedDrawableSize(drawable.texture.width, drawable.texture.height);
        }
        return drawable;
    }));
    hookDeviceClass(object_getClass(device));
    for (id<MTLDevice> d in MTLCopyAllDevices()) {
        hookDeviceClass(object_getClass(d));
    }
    if (isRobloxHost()) {
        state().depthReversed.store(true, std::memory_order_relaxed);
        NSLog(@"MacShade: detected Roblox host, defaulting reversed depth input to YES");
    }
    NSLog(@"MacShade: installed experimental hooks for %@ (%@)", NSStringFromClass(cls), device.name);
    return YES;
}
}

BOOL MSInstallHooks(NSError **error) {
    static dispatch_once_t token;
    static BOOL result;
    static NSError *failure;
    dispatch_once(&token, ^{
        NSError *localError = nil;
        result = install(&localError);
        failure = localError;
    });
    if (!result && error) *error = failure;
    return result;
}
void MSSetSettings(MSSettings settings) {
    std::lock_guard<std::mutex> lock(state().settingsLock);
    state().settings = settings;
}
MSSettings MSGetSettings(void) {
    std::lock_guard<std::mutex> lock(state().settingsLock);
    return state().settings;
}
void MSSetEnabled(BOOL enabled) { state().enabled.store(enabled, std::memory_order_relaxed); }
BOOL MSIsEnabled(void) { return state().enabled.load(std::memory_order_relaxed); }
uint64_t MSProcessedFrameCount(void) { return state().frames.load(std::memory_order_relaxed); }
uint64_t MSCompletedFrameCount(void) { return state().completedFrames.load(std::memory_order_relaxed); }
uint64_t MSGPUErrorCount(void) { return state().gpuErrors.load(std::memory_order_relaxed); }
NSDictionary<NSString *, NSNumber *> *MSHookDiagnostics(void) {
    return @{@"acquiredDrawables": @(state().acquiredDrawables.load(std::memory_order_relaxed)),
             @"committedBuffers": @(state().committedBuffers.load(std::memory_order_relaxed)),
             @"renderTargetMatches": @(state().renderTargetMatches.load(std::memory_order_relaxed))};
}
void MSSetFXEffect(MSFXEffect *effect) {
    MSSetFXEffects(effect ? @[effect] : @[]);
}
MSFXEffect *MSGetFXEffect(void) {
    return MSGetFXEffects().firstObject;
}
void MSSetFXEffects(NSArray<MSFXEffect *> *effects) {
    NSArray<MSFXEffect *> *snapshot = [effects copy] ?: @[];
    std::lock_guard<std::mutex> lock(state().settingsLock);
    state().effects = snapshot;
}
NSArray<MSFXEffect *> *MSGetFXEffects(void) {
    std::lock_guard<std::mutex> lock(state().settingsLock);
    return state().effects;
}
uint64_t MSProcessedFXFrameCount(void) { return state().fxFrames.load(std::memory_order_relaxed); }
void MSSetDepthReversed(BOOL reversed) { state().depthReversed.store(reversed,std::memory_order_relaxed); }
BOOL MSIsDepthReversed(void) { return state().depthReversed.load(std::memory_order_relaxed); }
uint64_t MSDepthCaptureCount(void) { return state().depthFrames.load(std::memory_order_relaxed); }
NSString *MSLastDepthStatus(void) { std::lock_guard<std::mutex> lock(state().settingsLock); return state().depthStatus; }

// Explicit opt-in for a host that permits this dylib to load. Deferred to avoid
// doing Metal runtime initialization inside dyld's image initialization lock.
__attribute__((constructor)) static void autoload(void) {
    const char *value = getenv("MACSHADE_AUTOLOAD");
    if (value && strcmp(value, "1") == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *error = nil;
            if (!MSInstallHooks(&error)) reportOnce(error);
        });
    }
}
