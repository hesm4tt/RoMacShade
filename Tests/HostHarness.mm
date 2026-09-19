// Standalone Metal host for exercising an externally loaded rendering extension.
// Intentionally has no project headers, linked extension, or explicit hook calls.
#import <AppKit/AppKit.h>
#import <MetalKit/MetalKit.h>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>

static const char *kShader = R"MSL(
#include <metal_stdlib>
using namespace metal;
struct VertexOut { float4 position [[position]]; float2 uv; };
vertex VertexOut sceneVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return {float4(p * 2.0 - 1.0, 0.0, 1.0), p};
}
struct FragmentOut { float4 color [[color(0)]]; float depth [[depth(any)]]; };
fragment FragmentOut sceneFragment(VertexOut in [[stage_in]], constant float4 &u [[buffer(0)]]) {
    float2 screen = (in.uv * 2.0 - 1.0) * float2(u.y, 1.0);
    float3 camera = float3(4.2, 2.5, 4.8);
    float3 forward = normalize(float3(0.0, 0.55, 0.0) - camera);
    float3 right = normalize(cross(forward, float3(0.0, 1.0, 0.0)));
    float3 up = cross(right, forward);
    float3 direction = normalize(forward + 0.55 * (screen.x * right + screen.y * up));
    float3 sky = mix(float3(0.20, 0.31, 0.43), float3(0.04, 0.09, 0.17), saturate(direction.y + 0.25));
    float distance = 1000.0;
    float3 normal = float3(0.0, 1.0, 0.0);
    float3 albedo = sky;
    if (direction.y < -0.001) {
        float ground = -camera.y / direction.y;
        if (ground > 0.0 && ground < 40.0) {
            distance = ground;
            float3 p = camera + direction * distance;
            float checker = fmod(floor(p.x) + floor(p.z), 2.0);
            albedo = mix(float3(0.16, 0.20, 0.24), float3(0.31, 0.36, 0.39), abs(checker));
            float2 grid = abs(fract(p.xz) - 0.5);
            if (max(grid.x, grid.y) > 0.48) albedo *= 0.70;
        }
    }
    for (uint i = 0; i < 3; ++i) {
        float angle = u.x * 0.35 + float(i) * 2.0943951;
        float3 center = float3(1.5 * cos(angle), 0.75 + 0.15 * sin(u.x + float(i)), 1.5 * sin(angle));
        float3 relative = camera - center;
        float b = dot(relative, direction);
        float c = dot(relative, relative) - 0.49;
        float discriminant = b * b - c;
        if (discriminant > 0.0) {
            float hit = -b - sqrt(discriminant);
            if (hit > 0.0 && hit < distance) {
                distance = hit;
                normal = normalize(camera + hit * direction - center);
                albedo = i == 0 ? float3(0.82, 0.29, 0.14) :
                    (i == 1 ? float3(0.08, 0.54, 0.58) : float3(0.69, 0.55, 0.20));
            }
        }
    }
    if (distance > 100.0) return {float4(sky, 1.0), 1.0};
    float3 light = normalize(float3(-0.4, 0.85, 0.3));
    float diffuse = max(dot(normal, light), 0.0);
    float specular = pow(max(dot(reflect(-light, normal), -direction), 0.0), 32.0);
    float3 color = albedo * (0.30 + 0.70 * diffuse) + 0.22 * specular;
    color = mix(color, sky, saturate(distance / 45.0));
    // Normalized perspective depth: near=0.1, far=50; clear/background=1.
    float viewZ = distance * dot(direction, forward);
    float depth = 50.0 / 49.9 - 5.0 / (49.9 * viewZ);
    return {float4(color, 1.0), saturate(depth)};
}
)MSL";

@interface HarnessDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, MTKViewDelegate> {
    NSWindow *_window;
    MTKView *_view;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLDepthStencilState> _depth;
    dispatch_group_t _inFlight;
    std::mutex _renderMutex;
    std::atomic<bool> _stopping;
    std::atomic<uint64_t> _submitted, _completed, _gpuErrors, _encodingErrors;
    std::atomic<uint64_t> _storedDepthFrames, _discardedDepthFrames;
    NSTimeInterval _seconds, _startedAt;
    BOOL _directPresent;
    int _result;
}
- (instancetype)initWithSeconds:(NSTimeInterval)seconds directPresent:(BOOL)directPresent;
- (void)requestFinish;
- (void)quit:(id)sender;
- (int)result;
@end

@implementation HarnessDelegate
- (instancetype)initWithSeconds:(NSTimeInterval)seconds directPresent:(BOOL)directPresent {
    if ((self = [super init])) {
        _seconds = seconds; _result = 1; _inFlight = dispatch_group_create();
        _directPresent = directPresent;
        _stopping.store(false); _submitted.store(0); _completed.store(0);
        _gpuErrors.store(0); _encodingErrors.store(0);
        _storedDepthFrames.store(0); _discardedDepthFrames.store(0);
    }
    return self;
}
- (int)result { return _result; }
- (void)fail:(NSString *)message {
    _encodingErrors.fetch_add(1);
    fprintf(stderr, "HostHarness: %s\n", message.UTF8String);
    [self requestFinish];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    _startedAt = NSProcessInfo.processInfo.systemUptime;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { [self fail:@"No Metal device is available."]; return; }
    _queue = [device newCommandQueue];
    if (!_queue) { [self fail:@"Could not create a Metal command queue."]; return; }
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:[NSString stringWithUTF8String:kShader] options:nil error:&error];
    if (!library) { [self fail:error.localizedDescription ?: @"Could not compile the scene shader."]; return; }
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"sceneVertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"sceneFragment"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    _pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!_pipeline) { [self fail:error.localizedDescription ?: @"Could not create the scene pipeline."]; return; }
    MTLDepthStencilDescriptor *depthDescriptor = [MTLDepthStencilDescriptor new];
    depthDescriptor.depthCompareFunction = MTLCompareFunctionLessEqual;
    depthDescriptor.depthWriteEnabled = YES;
    _depth = [device newDepthStencilStateWithDescriptor:depthDescriptor];
    if (!_depth) { [self fail:@"Could not create a depth state."]; return; }

    NSMenu *menu = [NSMenu new];
    NSMenuItem *app = [NSMenuItem new]; [menu addItem:app];
    app.submenu = [[NSMenu alloc] initWithTitle:@"Host Harness"];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit Host Harness" action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = self; [app.submenu addItem:quit]; NSApp.mainMenu = menu;
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 960, 640)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    _window.title = @"Metal Host Harness";
    _window.subtitle = @"Independent color and depth rendering";
    _window.releasedWhenClosed = NO; _window.delegate = self;
    [_window center];
    _view = [[MTKView alloc] initWithFrame:_window.contentView.bounds device:device];
    _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _view.colorPixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    _view.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    _view.framebufferOnly = YES;
    _view.preferredFramesPerSecond = 60;
    _view.clearColor = MTLClearColorMake(0.04, 0.09, 0.17, 1.0);
    _view.delegate = self;
    [_window.contentView addSubview:_view];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(_seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self requestFinish];
    });
}
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)view; (void)size;
}
- (void)drawInMTKView:(MTKView *)view {
    @autoreleasepool {
        std::lock_guard<std::mutex> guard(_renderMutex);
        if (_stopping.load()) return;
        MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
        id<CAMetalDrawable> drawable = view.currentDrawable;
        if (!pass || !drawable) return;
        if (!pass.depthAttachment.texture) { [self fail:@"The view did not allocate its Depth32Float attachment."]; return; }
        id<MTLCommandBuffer> buffer = [_queue commandBuffer];
        if (!buffer) { [self fail:@"Could not allocate a command buffer."]; return; }
        const uint64_t frame = _submitted.load();
        buffer.label = @"Independent host scene";
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.depthAttachment.loadAction = MTLLoadActionClear;
        pass.depthAttachment.clearDepth = 1.0;
        BOOL storeDepth = (frame % 2) == 0;
        pass.depthAttachment.storeAction = storeDepth ? MTLStoreActionStore : MTLStoreActionDontCare;
        id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
        if (!encoder) { [self fail:@"Could not create a render encoder."]; return; }
        [encoder setRenderPipelineState:_pipeline];
        [encoder setDepthStencilState:_depth];
        float uniforms[4] = {static_cast<float>(NSProcessInfo.processInfo.systemUptime - _startedAt),
            static_cast<float>(drawable.texture.width) / static_cast<float>(drawable.texture.height), 0, 0};
        [encoder setFragmentBytes:uniforms length:sizeof(uniforms) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
        if (!_directPresent) [buffer presentDrawable:drawable];
        dispatch_group_enter(_inFlight);
        [buffer addCompletedHandler:^(id<MTLCommandBuffer> finished) {
            if (finished.status != MTLCommandBufferStatusCompleted || finished.error) {
                self->_gpuErrors.fetch_add(1);
                fprintf(stderr, "HostHarness GPU: %s\n", finished.error.localizedDescription.UTF8String ?: "command buffer did not complete successfully");
            }
            self->_completed.fetch_add(1);
            dispatch_group_leave(self->_inFlight);
        }];
        _submitted.fetch_add(1);
        if (storeDepth) _storedDepthFrames.fetch_add(1); else _discardedDepthFrames.fetch_add(1);
        [buffer commit];
        if (_directPresent) [drawable present];
    }
}
- (void)requestFinish {
    if (_stopping.exchange(true)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_view.paused = YES;
        // Drain any encode callback before taking the completion-group snapshot.
        // Dispatching also avoids taking this mutex recursively after an encode error.
        { std::lock_guard<std::mutex> guard(self->_renderMutex); }
        dispatch_group_notify(self->_inFlight, dispatch_get_main_queue(), ^{
        uint64_t submitted = self->_submitted.load(), completed = self->_completed.load();
        BOOL passed = submitted > 0 && completed == submitted && self->_gpuErrors.load() == 0 && self->_encodingErrors.load() == 0;
        self->_result = passed ? 0 : 1;
        NSDictionary *report = @{@"event": @"host-harness-finished", @"passed": @(passed),
            @"presentation": self->_directPresent ? @"drawable" : @"commandBuffer",
            @"submittedFrames": @(submitted), @"completedFrames": @(completed),
            @"gpuErrors": @(self->_gpuErrors.load()), @"encodingErrors": @(self->_encodingErrors.load()),
            @"storedDepthFrames": @(self->_storedDepthFrames.load()), @"discardedDepthFrames": @(self->_discardedDepthFrames.load()),
            @"elapsedSeconds": @(NSProcessInfo.processInfo.systemUptime - self->_startedAt)};
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingSortedKeys error:NULL];
        if (json) { fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); fflush(stdout); }
        else { self->_result = 1; fputs("HostHarness could not encode its completion report.\n", stderr); }
        [NSApp stop:nil];
        // Wake the application event loop so -run returns after a timer/dispatch callback.
        [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
            modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:YES];
        });
    });
}
- (void)quit:(id)sender { (void)sender; [self requestFinish]; }
- (void)windowWillClose:(NSNotification *)notification { (void)notification; [self requestFinish]; }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender; [self requestFinish]; return NSTerminateCancel;
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSTimeInterval seconds = 8.0;
        const BOOL directPresent = getenv("MACSHADE_TEST_DIRECT_PRESENT") && strcmp(getenv("MACSHADE_TEST_DIRECT_PRESENT"), "1") == 0;
        if (argc == 2 && strcmp(argv[1], "--help") == 0) {
            puts("Usage: HostHarness [--seconds DURATION] (0.25–300 seconds; default 8)"); return 0;
        }
        if (argc != 1) {
            char *end = nullptr; errno = 0;
            if (argc == 3 && strcmp(argv[1], "--seconds") == 0) seconds = strtod(argv[2], &end);
            if (argc != 3 || strcmp(argv[1], "--seconds") != 0 || !end || end == argv[2] || *end || errno == ERANGE ||
                !std::isfinite(seconds) || seconds < 0.25 || seconds > 300.0) {
                fputs("Usage: HostHarness [--seconds DURATION] (0.25–300 seconds; default 8)\n", stderr); return 64;
            }
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        HarnessDelegate *delegate = [[HarnessDelegate alloc] initWithSeconds:seconds directPresent:directPresent];
        NSApp.delegate = delegate;
        [NSApp run];
        return delegate.result;
    }
}
