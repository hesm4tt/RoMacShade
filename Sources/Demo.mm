#import <AppKit/AppKit.h>
#import <MetalKit/MetalKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "MacShade.h"
#import "FXRuntime.h"
#import "FXChain.h"
#import "Overlay.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {
struct Field {
    const char *name;
    size_t offset;
    float minimum;
    float maximum;
};
const Field kFields[] = {
    {"Exposure", offsetof(MSSettings, exposure), -4.0f, 4.0f},
    {"Contrast", offsetof(MSSettings, contrast), 0.0f, 2.0f},
    {"Saturation", offsetof(MSSettings, saturation), 0.0f, 2.0f},
    {"Vibrance", offsetof(MSSettings, vibrance), -1.0f, 1.0f},
    {"Temperature", offsetof(MSSettings, temperature), -1.0f, 1.0f},
    {"Tint", offsetof(MSSettings, tint), -1.0f, 1.0f},
    {"Sharpen", offsetof(MSSettings, sharpen), 0.0f, 2.0f},
    {"Bloom", offsetof(MSSettings, bloom), 0.0f, 1.0f},
    {"Vignette", offsetof(MSSettings, vignette), 0.0f, 1.0f},
    {"Grain", offsetof(MSSettings, grain), 0.0f, 1.0f},
};
constexpr NSUInteger kFieldCount = sizeof(kFields) / sizeof(kFields[0]);

NSTextField *Label(NSString *text, NSRect frame, CGFloat size, NSColor *color,
                   NSFontWeight weight = NSFontWeightRegular) {
    NSTextField *label = [NSTextField labelWithString:text];
    label.frame = frame;
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    return label;
}

[[noreturn]] void Fail(NSString *message) {
    fprintf(stderr, "MacShade demo: %s\n", message.UTF8String);
    fflush(stderr);
    exit(1);
}

NSString *SceneSource() {
    return [NSString stringWithUTF8String:R"MSL(
#include <metal_stdlib>
using namespace metal;
struct VertexOut { float4 position [[position]]; float2 uv; };
struct SceneOut { float4 color [[color(0)]]; float depth [[depth(any)]]; };
vertex VertexOut sceneVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2) * 2.0 - 1.0;
    return {float4(p, 0.0, 1.0), float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5)};
}
float hash21(float2 p) { return fract(sin(dot(p,float2(127.1,311.7)))*43758.5453); }
float intersectBox(float3 ro,float3 rd,float3 lo,float3 hi,thread float3 &normal) {
    float3 t0=(lo-ro)/rd,t1=(hi-ro)/rd,tn=min(t0,t1),tf=max(t0,t1);
    float nearT=max(tn.x,max(tn.y,tn.z)),farT=min(tf.x,min(tf.y,tf.z));
    if(farT<max(nearT,0.0)) return 1e5;
    normal=nearT==tn.x ? float3(-sign(rd.x),0,0) : nearT==tn.y ? float3(0,-sign(rd.y),0) : float3(0,0,-sign(rd.z));
    return max(nearT,0.0);
}
fragment SceneOut sceneFragment(VertexOut in [[stage_in]],constant float4 &u [[buffer(0)]]) {
    const float nearPlane=1.0,farPlane=1000.0;
    float3 origin=float3(0,3.5,10.0),forward=normalize(float3(0,-0.115,-1));
    float3 right=float3(1,0,0),up=normalize(cross(right,forward));
    float2 ndc=float2(in.uv.x*2-1,1-in.uv.y*2);
    float3 ray=normalize(forward + right*ndc.x*u.y*0.466307658f + up*ndc.y*0.466307658f);
    float skyT=saturate(ray.y*1.6+0.16);
    float3 color=mix(float3(0.92,0.28,0.16),float3(0.035,0.10,0.23),skyT);
    float sun=dot(ray,normalize(float3(0.50,0.22,-1.0)));
    color+=float3(1.0,0.47,0.18)*pow(saturate(sun),180.0)*0.6;
    color=mix(color,float3(1.0,0.87,0.55),smoothstep(0.9981,0.9986,sun));
    float distance=1e5; float3 normal=float3(0,1,0); int material=-1;
    if(ray.y < -0.0001) { distance=-origin.y/ray.y; material=0; }
    for(int i=0;i<18;++i) {
        int row=i/6,col=i%6; float index=float(i);
        float3 center=float3((float(col)-2.5)*4.4,0,-float(row)*11.0-2.0);
        float height=2.5+hash21(float2(index,8))*8;
        float3 boxNormal;
        float t=intersectBox(origin,ray,center+float3(-1.35,0,-1.4),center+float3(1.35,height,1.4),boxNormal);
        if(t<distance) { distance=t; normal=boxNormal; material=i+1; }
    }
    float depth=1.0;
    if(distance<500.0) {
        float3 position=origin+ray*distance;
        if(material==0) {
            float2 grid=abs(fract(position.xz*0.4)-0.5);
            float lines=1-smoothstep(0.46,0.485,max(grid.x,grid.y));
            color=mix(float3(0.065,0.10,0.12),float3(0.018,0.028,0.042),lines);
            color+=float3(0.035,0.095,0.11)*exp(-abs(position.x-3.5)*0.5);
            color+=float3(0.1,0.029,0.012)*exp(-abs(position.x+4.0)*0.6);
        } else {
            float id=float(material);
            float3 tint=mix(float3(0.06,0.16,0.21),float3(0.27,0.12,0.10),hash21(float2(id,1)));
            color=tint*(0.6+0.4*saturate(dot(normal,normalize(float3(0.4,0.7,0.5)))));
            float face=abs(normal.z)>0.5?position.x:position.z;
            float2 windowUV=float2(face*2.3,position.y*2.1),tile=floor(windowUV),cell=fract(windowUV);
            float windows=step(0.23,cell.x)*step(cell.x,0.75)*step(0.25,cell.y)*step(cell.y,0.64)*step(0.32,hash21(tile+id*11));
            float3 light=mix(float3(0.03,0.67,1.0),float3(1.0,0.37,0.09),step(0.45,hash21(float2(id,2))));
            if(normal.y<0.5) color+=light*windows*0.8;
            float strip=1-smoothstep(0.01,0.06,abs(position.y-1.0));
            if(normal.z>0.5) color+=light*strip*0.8;
        }
        float fog=1-exp(-distance*0.009); color=mix(color,float3(0.30,0.16,0.19),fog);
        float viewZ=dot(position-origin,forward);
        depth=saturate(farPlane/(farPlane-nearPlane) - farPlane*nearPlane/((farPlane-nearPlane)*viewZ));
    }
    return {float4(color,1),depth};
}
)MSL"];
}
} // namespace

@interface DemoController : NSObject <NSApplicationDelegate, MTKViewDelegate, NSMenuItemValidation> {
    BOOL _smoke, _finishing, _requireFXSmoke, _loadingEffect, _resizeFailed, _requireDepthSmoke, _pendingPresetChange;
    CFAbsoluteTime _startTime;
    uint64_t _initialProcessed, _initialFXProcessed, _initialDepthCaptures;
    NSUInteger _fxGeneration, _effectWidth, _effectHeight, _selected, _requestedSelection;
    double _qualityScale;
    NSURL *_initialFXURL, *_initialPresetURL, *_currentPresetURL, *_pendingPresetURL;
    NSString *_initialTechnique, *_presetName, *_pendingName, *_pendingDetail;
    NSArray<NSDictionary *> *_entries, *_library, *_pendingSpecifications;
    NSArray<NSURL *> *_directories;
    dispatch_queue_t _compileQueue;
    std::atomic<uint32_t> _submitted, _completed, _gpuErrors;
    NSWindow *_window;
    MTKView *_metalView;
    MSOverlayController *_overlay;
    NSButton *_overlayButton;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLDepthStencilState> _depthState;
}
- (instancetype)initWithSmoke:(BOOL)smoke effectPath:(NSString *)path technique:(NSString *)technique preset:(NSString *)preset;
@end

@implementation DemoController
- (instancetype)initWithSmoke:(BOOL)smoke effectPath:(NSString *)path technique:(NSString *)technique preset:(NSString *)preset {
    if ((self = [super init])) {
        _smoke = smoke;
        _submitted = 0; _completed = 0; _gpuErrors = 0;
        _entries = @[]; _selected = NSNotFound; _requestedSelection = NSNotFound;
        _presetName = @"Custom look";
        _qualityScale = 1.0;
        _compileQueue = dispatch_queue_create("local.macshade.compile", DISPATCH_QUEUE_SERIAL);
        if (path.length) _initialFXURL = [NSURL fileURLWithPath:path.stringByStandardizingPath];
        if (preset.length) _initialPresetURL = [NSURL fileURLWithPath:preset.stringByStandardizingPath];
        _initialTechnique = [technique copy];
        _requireFXSmoke = smoke && (_initialFXURL || _initialPresetURL);
    }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSError *error = nil;
    if (!MSInstallHooks(&error)) Fail(error.localizedDescription ?: @"Could not install Metal hooks.");
    MSSetSettings(MSDefaultSettings());
    MSSetEnabled(YES);
    _initialProcessed = MSProcessedFrameCount();
    _initialFXProcessed = MSProcessedFXFrameCount();
    _initialDepthCaptures = MSDepthCaptureCount();
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) Fail(@"A Metal-capable GPU is required.");
    _queue = [device newCommandQueue];
    if (!_queue) Fail(@"Could not create the scene command queue.");
    _queue.label = @"MacShade demo scene";
    id<MTLLibrary> library = [device newLibraryWithSource:SceneSource() options:nil error:&error];
    if (!library) Fail(error.localizedDescription ?: @"Scene shader compilation failed.");
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.label = @"MacShade procedural city";
    descriptor.vertexFunction = [library newFunctionWithName:@"sceneVertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"sceneFragment"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    _pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!_pipeline) Fail(error.localizedDescription ?: @"Scene pipeline creation failed.");


    MTLDepthStencilDescriptor *depthDescriptor=[MTLDepthStencilDescriptor new];
    depthDescriptor.depthCompareFunction=MTLCompareFunctionAlways; depthDescriptor.depthWriteEnabled=YES;
    _depthState=[device newDepthStencilStateWithDescriptor:depthDescriptor];
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, _smoke ? 640 : 1220, _smoke ? 480 : 820)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                  NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    _window.title = @"MacShade";
    _window.subtitle = @"Metal preview";
    if (!_smoke) _window.minSize = NSMakeSize(960, 760);
    _window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    _window.backgroundColor = [NSColor colorWithWhite:0.055 alpha:1];
    [_window center];
    NSView *content = _window.contentView;
    _metalView = [[MTKView alloc] initWithFrame:content.bounds device:device];
    _metalView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _metalView.colorPixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    _metalView.depthStencilPixelFormat = MTLPixelFormatDepth32Float;
    _metalView.preferredFramesPerSecond = 60;
    _metalView.clearColor = MTLClearColorMake(0.02, 0.03, 0.05, 1.0);
    _metalView.delegate = self;
    [content addSubview:_metalView];
    NSTextField *sceneTitle = Label(@"AFTER THE SUN", NSMakeRect(30, 52, 400, 30), 24,
                                   NSColor.whiteColor, NSFontWeightMedium);
    [content addSubview:sceneTitle];
    [content addSubview:Label(@"Live Metal preview", NSMakeRect(32, 30, 400, 18), 12,
        [NSColor colorWithWhite:0.8 alpha:1])];

    _overlayButton = [NSButton buttonWithTitle:@"MacShade   ·   Effects  ⌘E" target:self action:@selector(toggleOverlay:)];
    _overlayButton.frame = NSMakeRect(26, content.bounds.size.height - 53, 232, 32);
    _overlayButton.autoresizingMask = NSViewMinYMargin;
    _overlayButton.bezelStyle = NSBezelStyleRounded;
    _overlayButton.contentTintColor = [NSColor colorWithRed:0.66 green:0.95 blue:0.87 alpha:1];
    [content addSubview:_overlayButton];
    _overlay = [MSOverlayController new];
    _overlay.view.frame = NSMakeRect(content.bounds.size.width - 894, 98, 864, content.bounds.size.height - 176);
    _overlay.view.autoresizingMask = NSViewMinXMargin | NSViewHeightSizable;
    [content addSubview:_overlay.view];
    [self connectOverlay];
    [self discoverEffects];
    [self refreshControls];
    [self installEffectMenus];
    [self refreshEntries];
    [_overlay setStatus:@"Ready to create your look" detail:@"Choose a shader from the library, or import a ReShade preset." busy:NO error:NO];
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer){
        (void)timer; if (self->_loadingEffect) return;
        for (MSFXEffect *effect in MSGetFXEffects()) if (effect.requiresDepth) {
            self->_window.subtitle=[NSString stringWithFormat:@"%@ · %@",self->_presetName,MSLastDepthStatus()]; break;
        }
    }];
    _startTime = CFAbsoluteTimeGetCurrent();
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    if (_smoke) {
        _overlay.view.hidden = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (!self->_finishing) {
                fprintf(stderr,"SMOKE FAIL: timeout; submitted=%u completed=%u processed=%llu FX-processed=%llu errors=%u\n",
                    self->_submitted.load(),self->_completed.load(),
                    (unsigned long long)(MSProcessedFrameCount()-self->_initialProcessed),
                    (unsigned long long)(MSProcessedFXFrameCount()-self->_initialFXProcessed),self->_gpuErrors.load());
                fflush(stderr); exit(2);
            }
        });
    }
}

- (void)connectOverlay {
    __weak DemoController *weak = self;
    _overlay.openEffect = ^{ [weak openEffect:nil]; };
    _overlay.addFolder = ^{ [weak addFolder:nil]; };
    _overlay.importPreset = ^{ [weak importPreset:nil]; };
    _overlay.exportPreset = ^{ [weak exportPreset:nil]; };
    _overlay.reloadEffects = ^{ [weak reloadEffect:nil]; };
    _overlay.hideOverlay = ^{ [weak toggleOverlay:nil]; };
    _overlay.chooseEffect = ^(NSURL *url){ [weak addEffectURL:url]; };
    _overlay.choosePreset = ^(NSURL *url){ [weak loadPresetURL:url]; };
    [_overlay updatePresets:[self discoveredPresets] selectedURL:nil];
    _overlay.selectEntry = ^(NSUInteger index){
        DemoController *owner = weak; if (!owner || index >= owner->_entries.count) return;
        owner->_selected = index; [owner refreshEntries];
    };
    _overlay.enableEntry = ^(NSUInteger index, BOOL enabled){
        DemoController *owner = weak; if (!owner || owner->_loadingEffect || index >= owner->_entries.count) return;
        NSMutableArray *entries = [owner->_entries mutableCopy];
        NSMutableDictionary *entry = [entries[index] mutableCopy];
        entry[@"enabled"] = @(enabled);
        [entries removeObjectAtIndex:index];
        NSUInteger dest = 0;
        for (NSDictionary *e in entries) if ([e[@"enabled"] boolValue]) dest++;
        [entries insertObject:entry atIndex:dest];
        if (enabled && !entry[@"effect"]) {
            owner->_selected = dest;
            [owner compileSpecifications:MSFXChainSpecifications(entries) name:owner->_presetName detail:@""];
            return;
        }
        owner->_entries = entries; owner->_selected = dest; [owner installChain]; [owner refreshEntries];
    };
    _overlay.moveEntry = ^(NSUInteger index, NSInteger direction){
        DemoController *owner = weak; if (!owner || owner->_loadingEffect || index >= owner->_entries.count) return;
        BOOL isActive = [owner->_entries[index][@"enabled"] boolValue];
        NSInteger destination = (NSInteger)index + direction;
        if (destination < 0 || destination >= (NSInteger)owner->_entries.count) return;
        BOOL destActive = [owner->_entries[(NSUInteger)destination][@"enabled"] boolValue];
        if (isActive != destActive) return;
        NSMutableArray *entries = [owner->_entries mutableCopy];
        [entries exchangeObjectAtIndex:index withObjectAtIndex:(NSUInteger)destination];
        owner->_entries = entries; owner->_selected = (NSUInteger)destination;
        [owner installChain]; [owner refreshEntries];
    };
    _overlay.removeEntry = ^(NSUInteger index){ [weak removeIndex:index]; };
    _overlay.selectTechnique = ^(NSString *name){
        DemoController *owner = weak; if (!owner || owner->_loadingEffect || owner->_selected >= owner->_entries.count) return;
        NSDictionary *entry = owner->_entries[owner->_selected];
        // ReShade identifies a technique by file and name, so avoid duplicate entries.
        for (NSUInteger i=0;i<owner->_entries.count;++i) {
            NSDictionary *other=owner->_entries[i]; MSFXEffect *fx=other[@"effect"];
            if(i!=owner->_selected && [other[@"url"] isEqual:entry[@"url"]] && [(fx ? fx.activeTechnique : other[@"technique"]) isEqual:name]) {
                [owner showError:@"This technique is already in the effects list." detail:@"Select its existing row to adjust it."]; return;
            }
        }
        NSError *error = nil;
        if (![entry[@"effect"] selectTechniqueNamed:name error:&error])
            [owner showError:@"Could not change technique" detail:error.localizedDescription];
        [owner refreshEntries];
    };
    _overlay.changeUniform = ^NSString *(NSString *name, NSArray<NSNumber *> *values){
        DemoController *owner = weak;
        if (!owner || owner->_loadingEffect || owner->_selected >= owner->_entries.count) return @"Wait for the effect to finish loading.";
        NSDictionary *selected = owner->_entries[owner->_selected];
        NSError *error = nil;
        if (![selected[@"effect"] setUniformNamed:name values:values error:&error]) return error.localizedDescription;
        NSMutableArray *entries = [owner->_entries mutableCopy];
        for (NSUInteger i=0;i<entries.count;++i) {
            NSDictionary *entry=entries[i];
            if (entry != selected && [entry[@"url"] isEqual:selected[@"url"]]) {
                if (entry[@"effect"]) [entry[@"effect"] setUniformNamed:name values:values error:nil];
                else {
                    NSMutableDictionary *updated=[entry mutableCopy];
                    NSMutableDictionary *stored=[entry[@"values"] ?: @{} mutableCopy]; stored[name]=values; updated[@"values"]=stored; entries[i]=updated;
                }
            }
        }
        owner->_entries=entries;
        return nil;
    };
    _overlay.toggleAll = ^(BOOL enabled){ MSSetEnabled(enabled); [weak refreshControls]; };
    _overlay.changeBuiltin = ^(NSUInteger index, double value){
        if (index >= kFieldCount) return;
        MSSettings settings = MSGetSettings();
        *reinterpret_cast<float *>(reinterpret_cast<char *>(&settings) + kFields[index].offset) = (float)value;
        MSSetSettings(settings);
    };
    _overlay.neutralBuiltin = ^{ MSSetSettings(MSNeutralSettings()); [weak refreshControls]; };
    _overlay.resetBuiltin = ^{ MSSetSettings(MSDefaultSettings()); [weak refreshControls]; };
    _overlay.cycleQuality = ^{
        DemoController *owner = weak;
        if (!owner) return;
        if (owner->_qualityScale > 0.85) owner->_qualityScale = 0.75;
        else if (owner->_qualityScale > 0.60) owner->_qualityScale = 0.50;
        else owner->_qualityScale = 1.0;
        [owner updateQualityUI];
        [owner scheduleEffectResize];
    };
    [self updateQualityUI];
}

- (void)updateQualityUI {
    NSString *label = @"100% (FQ)";
    if (_qualityScale < 0.60) label = @"50%";
    else if (_qualityScale < 0.85) label = @"75%";
    [_overlay setQualityLabel:label];
}

- (void)discoverEffects {
    NSMutableArray<NSURL *> *directories = [NSMutableArray array];
    NSURL *bundled = [NSBundle.mainBundle URLForResource:@"Effects" withExtension:nil];
    if (bundled) [directories addObject:bundled];
    else {
        NSURL *executable = NSBundle.mainBundle.executableURL;
        NSURL *local = [[executable.URLByDeletingLastPathComponent URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"Effects"];
        if ([NSFileManager.defaultManager fileExistsAtPath:local.path]) [directories addObject:local];
    }
    for (NSString *path in [NSUserDefaults.standardUserDefaults arrayForKey:@"MacShadeEffectFolders"] ?: @[]) {
        NSURL *url = [NSURL fileURLWithPath:path];
        if ([NSFileManager.defaultManager fileExistsAtPath:url.path] && ![directories containsObject:url]) [directories addObject:url];
    }
    _directories = MSReShadeSearchDirectories(directories, nil);
    _library = MSFXLibrary(_directories);
    [_overlay updateLibrary:_library];
    [_overlay updatePresets:[self discoveredPresets] selectedURL:_currentPresetURL];
}

- (NSArray<NSURL *> *)includeDirectories {
    NSMutableArray *directories = [_directories mutableCopy];
    for (NSDictionary *item in _library) {
        NSURL *directory = [item[@"url"] URLByDeletingLastPathComponent];
        if (![directories containsObject:directory]) [directories addObject:directory];
    }
    return directories;
}

- (void)refreshControls {
    MSSettings settings = MSGetSettings();
    NSMutableArray *values = [NSMutableArray array];
    for (NSUInteger i=0;i<kFieldCount;++i)
        [values addObject:@(*reinterpret_cast<float *>(reinterpret_cast<char *>(&settings)+kFields[i].offset))];
    [_overlay updateBuiltinValues:values enabled:MSIsEnabled()];
}
- (NSArray<NSDictionary *> *)discoveredPresets {
    NSURL *bundled = [NSBundle.mainBundle URLForResource:@"Presets" withExtension:nil];
    if (!bundled) {
        NSURL *executable = NSBundle.mainBundle.executableURL;
        bundled = [[executable.URLByDeletingLastPathComponent URLByDeletingLastPathComponent]
            URLByAppendingPathComponent:@"Presets" isDirectory:YES];
    }
    return MSDiscoverPresetLibrary(bundled ? @[bundled] : @[], _directories, _currentPresetURL);
}
- (void)refreshEntries {
    if (_selected >= _entries.count) _selected = _entries.count ? _entries.count-1 : NSNotFound;
    [_overlay updateEntries:_entries selectedIndex:_selected];
    [_overlay setPresetName:_presetName];
    [_overlay updatePresets:[self discoveredPresets] selectedURL:_currentPresetURL];
    _window.subtitle = [NSString stringWithFormat:@"%@ · %lu effect%@ · Metal preview",_presetName,
        (unsigned long)_entries.count,_entries.count==1 ? @"" : @"s"];
}
- (void)installChain {
    if (_resizeFailed) { MSSetFXEffects(@[]); return; }
    NSMutableArray *effects = [NSMutableArray array];
    for (NSDictionary *entry in _entries) if ([entry[@"enabled"] boolValue]) [effects addObject:entry[@"effect"]];
    MSSetFXEffects(effects);
    if (_smoke) for (MSFXEffect *effect in effects) if (effect.requiresDepth) _requireDepthSmoke=YES;
}
- (void)showError:(NSString *)message detail:(NSString *)detail {
    if (_smoke) Fail([NSString stringWithFormat:@"%@: %@",message,detail]);
    _overlay.view.hidden = NO;
    [_overlay setStatus:message detail:detail ?: @"" busy:NO error:YES];
    fprintf(stderr,"MacShade: %s: %s\n",message.UTF8String,detail.UTF8String);
}
- (void)compileSpecifications:(NSArray<NSDictionary *> *)specifications name:(NSString *)name detail:(NSString *)detail {
    NSUInteger fullW = (NSUInteger)_metalView.drawableSize.width, fullH = (NSUInteger)_metalView.drawableSize.height;
    if (!fullW || !fullH) { [self showError:@"Preview is not ready" detail:@"Try again when the window is visible."]; return; }
    NSUInteger width = std::max<NSUInteger>(2, ((NSUInteger)std::round(fullW * _qualityScale)) & ~1);
    NSUInteger height = std::max<NSUInteger>(2, ((NSUInteger)std::round(fullH * _qualityScale)) & ~1);
    NSUInteger generation = ++_fxGeneration;
    _pendingSpecifications = specifications;
    _pendingName = name; _pendingDetail = detail;
    _loadingEffect = YES;
    [_overlay setStatus:@"Preparing your look…" detail:@"Compiling effects for this window. Your previous look stays selected until the replacement is ready." busy:YES error:NO];
    id<MTLDevice> device = _metalView.device;
    NSArray *directories = [self includeDirectories];
    NSURL *presetToInstall = _pendingPresetChange ? _pendingPresetURL : _currentPresetURL;
    dispatch_async(_compileQueue, ^{
        @autoreleasepool {
            NSError *error = nil;
            NSArray *compiled = MSCompileFXChain(specifications,device,width,height,directories,&error);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_fxGeneration) return;
                self->_loadingEffect = NO;
                NSUInteger curScaledW = std::max<NSUInteger>(2, ((NSUInteger)std::round((NSUInteger)self->_metalView.drawableSize.width * self->_qualityScale)) & ~1);
                NSUInteger curScaledH = std::max<NSUInteger>(2, ((NSUInteger)std::round((NSUInteger)self->_metalView.drawableSize.height * self->_qualityScale)) & ~1);
                if (width != curScaledW || height != curScaledH) {
                    [self compileSpecifications:specifications name:name detail:detail]; return;
                }
                self->_pendingSpecifications = nil;
                if (!compiled) {
                    self->_pendingPresetChange=NO; self->_pendingPresetURL=nil;
                    // Preserve current controls and values. A resized previous chain
                    // must be recompiled before it can render at the new dimensions.
                    if (self->_effectWidth != width || self->_effectHeight != height) { self->_resizeFailed=YES; MSSetFXEffects(@[]); }
                    self->_pendingName=nil; self->_pendingDetail=nil; self->_requestedSelection=NSNotFound;
                    [self refreshEntries];
                    [self showError:@"Could not load this look" detail:error.localizedDescription];
                    return;
                }
                self->_resizeFailed=NO; self->_pendingName=nil; self->_pendingDetail=nil;
                self->_entries = compiled; self->_effectWidth = width; self->_effectHeight = height;
                self->_currentPresetURL=presetToInstall; self->_pendingPresetChange=NO; self->_pendingPresetURL=nil;
                self->_presetName = name;
                if (self->_requestedSelection != NSNotFound) self->_selected=self->_requestedSelection;
                self->_requestedSelection=NSNotFound;
                [self installChain]; [self refreshEntries];
                [self->_overlay setStatus:@"Look ready" detail:detail.length ? detail : @"Changes apply live. Use ⌘E to hide the overlay and ⌘B to compare." busy:NO error:NO];
            });
        }
    });
}
- (void)scheduleEffectResize {
    if (!_entries.count && !_pendingSpecifications.count) return;
    NSArray *specifications = _pendingSpecifications ?: MSFXChainSpecifications(_entries);
    NSString *name = _pendingSpecifications ? _pendingName ?: _presetName : _presetName;
    NSString *detail = _pendingDetail ?: @"";
    _pendingSpecifications = specifications;
    _loadingEffect = YES;
    NSUInteger generation = ++_fxGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        if (generation == self->_fxGeneration) [self compileSpecifications:specifications name:name detail:detail];
    });
}
- (void)addEffectURL:(NSURL *)url {
    if (_loadingEffect) return;
    for (NSUInteger i=0;i<_entries.count;++i) if ([_entries[i][@"url"] isEqual:url]) {
        _selected=i; [self refreshEntries]; return;
    }
    NSMutableArray *specifications = [MSFXChainSpecifications(_entries) mutableCopy];
    NSUInteger insertIndex = 0;
    for (NSDictionary *spec in specifications) if ([spec[@"enabled"] boolValue]) insertIndex++;
    [specifications insertObject:@{@"url":url,@"enabled":@YES,@"values":@{},@"definitions":@{}} atIndex:insertIndex];
    _pendingPresetChange=YES; _pendingPresetURL=nil;
    _requestedSelection = insertIndex;
    [self compileSpecifications:specifications name:@"Custom look" detail:@""];
}
- (void)removeIndex:(NSUInteger)index {
    if (_loadingEffect || index >= _entries.count) return;
    NSMutableArray *entries = [_entries mutableCopy]; [entries removeObjectAtIndex:index]; _entries = entries;
    [self installChain]; [self refreshEntries];
    [_overlay setStatus:@"Effect removed" detail:@"The rest of your look is unchanged." busy:NO error:NO];
}
- (void)openEffect:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"Add a ReShade effect"; panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"fx"] ?: UTTypeData];
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response){
        if (response == NSModalResponseOK && panel.URL) [self addEffectURL:panel.URL];
    }];
}
- (void)addFolder:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"Add an effects folder"; panel.canChooseFiles = NO; panel.canChooseDirectories = YES;
    panel.message = @"Choose a folder containing .fx shaders and their companion include files.";
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response){
        if (response != NSModalResponseOK || !panel.URL) return;
        NSMutableArray *paths = [[NSUserDefaults.standardUserDefaults arrayForKey:@"MacShadeEffectFolders"] ?: @[] mutableCopy];
        if (![paths containsObject:panel.URL.path]) [paths addObject:panel.URL.path];
        [NSUserDefaults.standardUserDefaults setObject:paths forKey:@"MacShadeEffectFolders"];
        [self discoverEffects];
        [self->_overlay setStatus:@"Effects folder added" detail:@"The library is ready. Import your preset again if it was missing shaders." busy:NO error:NO];
    }];
}
- (void)loadPresetURL:(NSURL *)url {
    if (_loadingEffect) return;
    NSError *error = nil;
    MSFXPreset *preset = [MSFXPreset presetWithURL:url error:&error];
    if (!preset) { [self showError:@"Could not read this preset" detail:error.localizedDescription]; return; }
    NSArray *companions = MSReShadeSearchDirectories(@[],url);
    NSMutableArray *directories = [_directories mutableCopy];
    for (NSURL *directory in companions) if (![directories containsObject:directory]) [directories addObject:directory];
    _directories = MSReShadeSearchDirectories(directories,url);
    _library = MSFXLibrary(_directories); [_overlay updateLibrary:_library];
    NSMutableArray *warnings = [preset.warnings mutableCopy];
    NSArray *localLibrary = MSFXLibrary(companions);
    // Adjacent shaders take precedence, so a self-contained preset folder works.
    NSMutableArray *library = [localLibrary mutableCopy];
    NSMutableSet *localNames = [NSMutableSet set];
    for (NSDictionary *item in localLibrary) [localNames addObject:[item[@"url"] lastPathComponent].lowercaseString];
    for (NSDictionary *item in _library) if (![localNames containsObject:[item[@"url"] lastPathComponent].lowercaseString]) [library addObject:item];
    for (NSDictionary *entry in _entries) {
        NSURL *known=entry[@"url"]; BOOL present=NO;
        for (NSDictionary *item in library) if ([item[@"url"] isEqual:known]) { present=YES; break; }
        if (!present) [library addObject:@{@"url":known,@"name":known.lastPathComponent,@"subtitle":@"Loaded effect"}];
    }
    NSArray *specifications = MSFXPresetSpecifications(preset,url,library,warnings,&error);
    if (!specifications) { [self showError:@"Preset needs attention" detail:error.localizedDescription]; return; }
    NSMutableArray *activeSpecs = [NSMutableArray array], *inactiveSpecs = [NSMutableArray array];
    for (NSDictionary *spec in specifications) {
        if ([spec[@"enabled"] boolValue]) [activeSpecs addObject:spec];
        else [inactiveSpecs addObject:spec];
    }
    NSMutableArray *orderedSpecs = [activeSpecs mutableCopy];
    [orderedSpecs addObjectsFromArray:inactiveSpecs];
    specifications = orderedSpecs;
    _pendingPresetChange=YES; _pendingPresetURL=url;
    _requestedSelection = specifications.count ? 0 : NSNotFound;
    if (_smoke) {
        // Startup is synchronous so the first smoke frame includes the whole preset.
        NSArray *entries = MSCompileFXChain(specifications,_metalView.device,(NSUInteger)_metalView.drawableSize.width,
            (NSUInteger)_metalView.drawableSize.height,[self includeDirectories],&error);
        if (!entries) Fail(error.localizedDescription);
        _entries = entries; _effectWidth = (NSUInteger)_metalView.drawableSize.width; _effectHeight = (NSUInteger)_metalView.drawableSize.height;
        _currentPresetURL=url; _pendingPresetChange=NO; _pendingPresetURL=nil;
        _presetName = url.lastPathComponent.stringByDeletingPathExtension;
        [self installChain]; [self refreshEntries];
        _requireFXSmoke = MSGetFXEffects().count > 0;
    } else [self compileSpecifications:specifications name:url.lastPathComponent.stringByDeletingPathExtension
        detail:warnings.count ? [warnings componentsJoinedByString:@"\n"] : @"Preset imported. Built-in grading remains separate; choose Neutral in Look for the preset alone."];
}
- (void)importPreset:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel]; panel.title = @"Import a ReShade preset";
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"ini"] ?: UTTypeData];
    panel.message = @"A preset stores shader names and settings. Add its shader folder to the library if needed.";
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response){
        if (response == NSModalResponseOK && panel.URL) [self loadPresetURL:panel.URL];
    }];
}
- (void)exportPreset:(id)sender {
    (void)sender;
    NSError *error = nil;
    NSString *text = MSFXChainPresetString(_entries,&error);
    if (!text) { [self showError:@"Could not save this preset" detail:error.localizedDescription]; return; }
    NSSavePanel *panel = [NSSavePanel savePanel]; panel.title = @"Save ReShade preset";
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"ini"] ?: UTTypeData];
    panel.nameFieldStringValue = [_presetName stringByAppendingPathExtension:@"ini"];
    panel.identifier = @"MacShadePresetSave";
    panel.directoryURL = [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];
    panel.canCreateDirectories = YES;
    panel.message = @"Saves effect order, enabled states and shader parameters. Built-in Look adjustments are separate.";
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response){
        if (response != NSModalResponseOK || !panel.URL) return;
        NSError *failure = nil;
        if (![text writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&failure]) {
            [self showError:@"Could not save this preset" detail:failure.localizedDescription]; return;
        }
        self->_presetName = panel.URL.lastPathComponent.stringByDeletingPathExtension;
        self->_currentPresetURL = panel.URL;
        [self refreshEntries];
        [self->_overlay setStatus:@"Preset saved" detail:panel.URL.lastPathComponent busy:NO error:NO];
    }];
}
- (void)reloadEffect:(id)sender {
    (void)sender;
    if (!_loadingEffect && _entries.count) [self compileSpecifications:MSFXChainSpecifications(_entries) name:_presetName detail:@"Shaders reloaded; compatible settings preserved."];
}
- (void)toggleOverlay:(id)sender { (void)sender; _overlay.view.hidden = !_overlay.view.hidden; }
- (void)toggleDepthConvention:(id)sender { (void)sender; MSSetDepthReversed(!MSIsDepthReversed()); }
- (void)toggleComparison:(id)sender { (void)sender; MSSetEnabled(!MSIsEnabled()); [self refreshControls]; }
- (void)installEffectMenus {
    NSMenuItem *file = [[NSMenuItem alloc] initWithTitle:@"File" action:NULL keyEquivalent:@""];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"File"]; file.submenu=menu; [NSApp.mainMenu addItem:file];
    NSArray *titles = @[@"Add Effect…",@"Add Effects Folder…",@"Import Preset…",@"Save Preset…",@"Reload Effects",@"Show / Hide Overlay",@"Toggle Effects",@"Reversed Depth Input"];
    const SEL actions[] = {@selector(openEffect:),@selector(addFolder:),@selector(importPreset:),@selector(exportPreset:),@selector(reloadEffect:),@selector(toggleOverlay:),@selector(toggleComparison:),@selector(toggleDepthConvention:)};
    NSArray *keys = @[@"o",@"",@"O",@"s",@"r",@"e",@"b",@""];
    for (NSUInteger i=0;i<titles.count;++i) {
        NSMenuItem *item = [menu addItemWithTitle:titles[i] action:actions[i] keyEquivalent:keys[i]]; item.target=self;
        if (i==2) item.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    }
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(toggleDepthConvention:)) { item.state=MSIsDepthReversed()?NSControlStateValueOn:NSControlStateValueOff; return YES; }
    if (item.action == @selector(reloadEffect:)) return _entries.count && !_loadingEffect;
    if (item.action == @selector(toggleOverlay:) || item.action == @selector(toggleComparison:)) return YES;
    return !_loadingEffect;
}
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)view;
    if (size.width < 1 || size.height < 1 || (!_entries.count && !_loadingEffect)) return;
    dispatch_async(dispatch_get_main_queue(),^{ if (self->_entries.count || self->_loadingEffect) [self scheduleEffectResize]; });
}

- (void)drawInMTKView:(MTKView *)view {
    @autoreleasepool {
        if (_loadingEffect && (!_entries.count || _effectWidth != (NSUInteger)view.drawableSize.width || _effectHeight != (NSUInteger)view.drawableSize.height)) return;
        if (_smoke && _submitted.load() >= 12) {
            view.paused = YES;
            return;
        }
        MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
        id<CAMetalDrawable> drawable = view.currentDrawable;
        if (!pass || !drawable) return;
        if (_initialFXURL) {
            NSError *error = nil;
            MSFXEffect *effect = [[MSFXEffect alloc] initWithURL:_initialFXURL device:view.device
                width:drawable.texture.width height:drawable.texture.height error:&error];
            if (!effect) Fail(error.localizedDescription ?: @"Could not load the requested FX effect.");
            if (_initialTechnique.length && ![effect selectTechniqueNamed:_initialTechnique error:&error]) {
                Fail(error.localizedDescription ?: @"The requested FX technique was not found.");
            }
            _entries = @[@{@"url":_initialFXURL,@"effect":effect,@"enabled":@YES,@"definitions":@{}}];
            _selected=0; _effectWidth=drawable.texture.width; _effectHeight=drawable.texture.height;
            [self installChain]; [self refreshEntries];
            [_overlay setStatus:@"Look ready" detail:@"Adjust the effect live. Use ⌘E to hide the overlay and ⌘B to compare." busy:NO error:NO];
            _initialFXURL = nil;
        }
        if (_initialPresetURL) {
            NSURL *url=_initialPresetURL; _initialPresetURL=nil; [self loadPresetURL:url];
            if (_loadingEffect) return;
        }
        if (!_resizeFailed && _entries.count && (_effectWidth != drawable.texture.width || _effectHeight != drawable.texture.height)) {
            if (!_loadingEffect) [self scheduleEffectResize];
            return;
        }
        id<MTLCommandBuffer> buffer = [_queue commandBuffer];
        if (!buffer) return;
        uint32_t frame = _submitted.fetch_add(1);
        buffer.label = [NSString stringWithFormat:@"MacShade scene frame %u", frame];
        if (_smoke) {
            // These requests deliberately precede the scene encoder. The hook must wait until commit.
            switch (frame % 3) {
                case 0: [buffer presentDrawable:drawable]; break;
                case 1: [buffer presentDrawable:drawable atTime:CACurrentMediaTime()]; break;
                default: [buffer presentDrawable:drawable afterMinimumDuration:1.0 / 60.0]; break;
            }
        }
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.depthAttachment.loadAction=MTLLoadActionClear;
        pass.depthAttachment.clearDepth=1.0;
        // The capture hook must preserve this attachment before its tile data is discarded.
        pass.depthAttachment.storeAction=MTLStoreActionDontCare;
        id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
        if (!encoder) Fail(@"Could not create the scene encoder.");
        encoder.label = @"Procedural skyline";
        [encoder setRenderPipelineState:_pipeline];
        [encoder setDepthStencilState:_depthState];
        float height = (float)drawable.texture.height;
        float uniforms[4] = {(float)(CFAbsoluteTimeGetCurrent() - _startTime),
            (float)drawable.texture.width / height, (float)drawable.texture.width, height};
        [encoder setFragmentBytes:uniforms length:sizeof(uniforms) atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
        if (!_smoke) [buffer presentDrawable:drawable];
        if (_smoke) {
            [buffer addCompletedHandler:^(id<MTLCommandBuffer> finished) {
                if (finished.status == MTLCommandBufferStatusError || finished.error) {
                    self->_gpuErrors.fetch_add(1);
                    fprintf(stderr, "SMOKE GPU error: %s\n", finished.error.description.UTF8String);
                }
                uint32_t done = self->_completed.fetch_add(1) + 1;
                if (done >= 12) dispatch_async(dispatch_get_main_queue(), ^{
                    if (self->_finishing) return;
                    self->_finishing = YES;
                    self->_metalView.paused = YES;
                    uint64_t processed = MSProcessedFrameCount() - self->_initialProcessed;
                    uint64_t processedFX = MSProcessedFXFrameCount() - self->_initialFXProcessed;
                    uint64_t captures=MSDepthCaptureCount()-self->_initialDepthCaptures;
                    BOOL passed = self->_gpuErrors.load() == 0 && processed >= 12 &&
                                  (!self->_requireFXSmoke || processedFX >= 12) && (!self->_requireDepthSmoke || captures >= 12);
                    fprintf(passed ? stdout : stderr,
                        "SMOKE %s: completed=%u processed=%llu FX-processed=%llu depth-captures=%llu GPU-errors=%u; all 3 presentation variants before encoding\n",
                        passed ? "PASS" : "FAIL", self->_completed.load(),
                        (unsigned long long)processed, (unsigned long long)processedFX, (unsigned long long)captures, self->_gpuErrors.load());
                    fflush(stdout);
                    fflush(stderr);
                    exit(passed ? 0 : 3);
                });
            }];
        }
        [buffer commit];
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL smoke = NO;
        NSString *effectPath = nil;
        NSString *technique = nil;
        NSString *presetPath = nil;
        for (int i = 1; i < argc; ++i) {
            if (strcmp(argv[i], "--smoke") == 0) {
                smoke = YES;
            } else if (strcmp(argv[i], "--fx") == 0) {
                if (++i >= argc) Fail(@"--fx requires a file path.");
                effectPath = [NSString stringWithUTF8String:argv[i]];
            } else if (strcmp(argv[i], "--preset") == 0) {
                if (++i >= argc) Fail(@"--preset requires a file path.");
                presetPath = [NSString stringWithUTF8String:argv[i]];
            } else if (strcmp(argv[i], "--technique") == 0) {
                if (++i >= argc) Fail(@"--technique requires a technique name.");
                technique = [NSString stringWithUTF8String:argv[i]];
            } else if (strcmp(argv[i], "--help") == 0) {
                printf("Usage: MacShadeDemo [--smoke] [--fx PATH] [--technique NAME] [--preset PATH]\n");
                return 0;
            }
        }
        if (presetPath.length && effectPath.length) Fail(@"Choose --preset or --fx, not both.");
        if (technique.length && !effectPath.length) Fail(@"--technique requires --fx PATH.");
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSMenu *mainMenu = [NSMenu new];
        NSMenuItem *appMenuItem = [NSMenuItem new];
        [mainMenu addItem:appMenuItem];
        NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"MacShade"];
        [appMenu addItemWithTitle:@"Quit MacShade" action:@selector(terminate:) keyEquivalent:@"q"];
        appMenuItem.submenu = appMenu;
        app.mainMenu = mainMenu;
        DemoController *controller = [[DemoController alloc] initWithSmoke:smoke effectPath:effectPath technique:technique preset:presetPath];
        app.delegate = controller;
        [app run];
    }
    return 0;
}
