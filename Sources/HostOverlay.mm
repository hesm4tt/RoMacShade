//
// Copyright (c) 2026 MacShade Authors. All Rights Reserved.
// PROPRIETARY AND CONFIDENTIAL.
// UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
//

#import "HostOverlay.h"
#import "Overlay.h"
#import "FXChain.h"
#import "MacShade.h"
#import <QuartzCore/CAMetalLayer.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <mutex>

namespace {
std::mutex &StatusLock() { static std::mutex lock; return lock; }
NSString *__strong &StatusText() { static NSString *text=@"Not started"; return text; }
void SetHostStatus(NSString *text) {
    std::lock_guard<std::mutex> lock(StatusLock());StatusText()=[text copy];
}
constexpr size_t kOffsets[] = {
    offsetof(MSSettings,exposure),offsetof(MSSettings,contrast),offsetof(MSSettings,saturation),
    offsetof(MSSettings,vibrance),offsetof(MSSettings,temperature),offsetof(MSSettings,tint),
    offsetof(MSSettings,sharpen),offsetof(MSSettings,bloom),offsetof(MSSettings,vignette),offsetof(MSSettings,grain)
};
CAMetalLayer *FindLayer(CALayer *layer) {
    if(!layer||layer.hidden)return nil;
    CAMetalLayer *best=nil;
    if([layer isKindOfClass:CAMetalLayer.class]) {
        CAMetalLayer *metal=(CAMetalLayer *)layer;
        if(metal.device&&metal.drawableSize.width>0&&metal.drawableSize.height>0)best=metal;
    }
    for(CALayer *child in layer.sublayers) {
        CAMetalLayer *candidate=FindLayer(child);
        if(candidate&&(!best||candidate.drawableSize.width*candidate.drawableSize.height>best.drawableSize.width*best.drawableSize.height))best=candidate;
    }
    return best;
}
CAMetalLayer *FindViewLayer(NSView *view) {
    if(!view||view.hidden)return nil;
    CAMetalLayer *best=FindLayer(view.layer);
    for(NSView *child in view.subviews) {
        CAMetalLayer *candidate=FindViewLayer(child);
        if(candidate&&(!best||candidate.drawableSize.width*candidate.drawableSize.height>best.drawableSize.width*best.drawableSize.height))best=candidate;
    }
    return best;
}
NSString *Technique(NSDictionary *entry) {
    MSFXEffect *effect=entry[@"effect"];return effect?effect.activeTechnique:entry[@"technique"]?:@"";
}
}

/// Empty areas of the container must not intercept the host's mouse input.
@interface MSHostOverlayContainer : NSView
@end
@implementation MSHostOverlayContainer
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point {
    NSView *hit=[super hitTest:point];return hit==self?nil:hit;
}
@end

/// Sleek floating circular toggle button that can be dragged across the host game window.
@interface MSDraggableCircleButton : NSView {
    BOOL _isDragging;
    BOOL _mouseInside;
    NSPoint _startWindowPoint;
    NSPoint _lastWindowPoint;
    NSTrackingArea *_trackingArea;
}
@property(nonatomic, assign) BOOL isOpen;
@property(nonatomic, copy, nullable) void (^onClick)(void);
@property(nonatomic, copy, nullable) void (^onDragDelta)(CGFloat dx, CGFloat dy);
@end

@implementation MSDraggableCircleButton
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES;
        self.layer.masksToBounds = NO;
        self.layer.shadowColor = [NSColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.55;
        self.layer.shadowOffset = CGSizeMake(0, -2);
        self.layer.shadowRadius = 8.0;
        self.toolTip = @"RoMacShade (⌘E) · Drag anywhere to reposition";
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)setIsOpen:(BOOL)isOpen {
    if (_isOpen != isOpen) {
        _isOpen = isOpen;
        [self setNeedsDisplay:YES];
    }
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) [self removeTrackingArea:_trackingArea];
    _trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways
        owner:self userInfo:nil];
    [self addTrackingArea:_trackingArea];
}
- (void)mouseEntered:(NSEvent *)event {
    (void)event;
    _mouseInside = YES;
    [self setNeedsDisplay:YES];
}
- (void)mouseExited:(NSEvent *)event {
    (void)event;
    _mouseInside = NO;
    [self setNeedsDisplay:YES];
}
- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}
- (NSView *)hitTest:(NSPoint)point {
    NSPoint local = [self convertPoint:point fromView:self.superview];
    CGFloat cx = self.bounds.size.width * 0.5;
    CGFloat cy = self.bounds.size.height * 0.5;
    CGFloat dist = std::hypot(local.x - cx, local.y - cy);
    return dist <= cx ? self : nil;
}
- (void)mouseDown:(NSEvent *)event {
    _startWindowPoint = event.locationInWindow;
    _lastWindowPoint = event.locationInWindow;
    _isDragging = NO;
}
- (void)mouseDragged:(NSEvent *)event {
    NSView *content = self.window.contentView;
    if (!content) return;
    NSPoint pStart = [content convertPoint:_startWindowPoint fromView:nil];
    NSPoint pCur = [content convertPoint:event.locationInWindow fromView:nil];
    if (std::hypot(pCur.x - pStart.x, pCur.y - pStart.y) > 3.5) {
        _isDragging = YES;
    }
    if (_isDragging && self.onDragDelta) {
        NSPoint pPrev = [content convertPoint:_lastWindowPoint fromView:nil];
        self.onDragDelta(pCur.x - pPrev.x, pCur.y - pPrev.y);
    }
    _lastWindowPoint = event.locationInWindow;
}
- (void)mouseUp:(NSEvent *)event {
    (void)event;
    if (!_isDragging) {
        if (self.onClick) self.onClick();
    }
    _isDragging = NO;
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = self.bounds;
    NSRect circleRect = NSInsetRect(bounds, 2.0, 2.0);
    NSBezierPath *circlePath = [NSBezierPath bezierPathWithOvalInRect:circleRect];

    CGFloat bgAlpha = _mouseInside ? 0.94 : 0.84;
    [[NSColor colorWithRed:0.08 green:0.09 blue:0.13 alpha:bgAlpha] setFill];
    [circlePath fill];

    CGFloat borderAlpha = _mouseInside ? 1.0 : 0.75;
    [[NSColor colorWithSRGBRed:0.33 green:0.86 blue:0.76 alpha:borderAlpha] setStroke];
    circlePath.lineWidth = 1.5;
    [circlePath stroke];

    NSBezierPath *innerRing = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(circleRect, 1.5, 1.5)];
    [[NSColor colorWithSRGBRed:0.33 green:0.86 blue:0.76 alpha:_mouseInside ? 0.22 : 0.10] setStroke];
    innerRing.lineWidth = 1.0;
    [innerRing stroke];

    NSString *symbol = _isOpen ? @"✕" : @"R";
    NSFont *font = _isOpen ? [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold]
                           : [NSFont systemFontOfSize:18 weight:NSFontWeightBold];
    NSColor *color = [NSColor colorWithSRGBRed:0.33 green:0.86 blue:0.76 alpha:1.0];

    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentCenter;
    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: style
    };

    NSSize textSize = [symbol sizeWithAttributes:attrs];
    NSRect textRect = NSMakeRect(
        bounds.origin.x + (bounds.size.width - textSize.width) * 0.5,
        bounds.origin.y + (bounds.size.height - textSize.height) * 0.5 - 0.5,
        textSize.width,
        textSize.height
    );
    [symbol drawInRect:textRect withAttributes:attrs];
}
@end

@interface MSHostSession : NSObject {
    NSString *_resourcesDirectory,*_presetName,*_pendingName,*_pendingDetail;
    NSArray<NSDictionary *> *_entries,*_library,*_pendingSpecifications;
    NSMutableArray<NSURL *> *_directories,*_securityURLs;
    NSURL *_startupEffect,*_startupPreset,*_currentPresetURL,*_pendingPresetURL;
    __weak NSWindow *_window;
    __weak NSView *_content;
    __weak NSResponder *_hostResponder;
    __weak CAMetalLayer *_metalLayer;
    id<MTLDevice> _compiledDevice;
    MSOverlayController *_overlay;
    MSHostOverlayContainer *_container;
    MSDraggableCircleButton *_toggleButton;
    NSButton *_depthToggle;
    NSPoint _buttonOrigin;
    BOOL _hasButtonOrigin;
    double _qualityScale;
    NSSavePanel *_activePanel;
    NSTimer *_timer;
    id _keyMonitor;
    dispatch_queue_t _compileQueue;
    std::atomic<uint64_t> _generation;
    NSUInteger _selected,_requestedSelection,_effectWidth,_effectHeight,_observedWidth,_observedHeight;
    __weak id<MTLDevice> _observedDevice;
    BOOL _stopped,_loading,_suspended,_startupHandled,_depthUnavailable,_pendingPresetChange;
    CFTimeInterval _lastLog;
}
- (instancetype)initWithResourcesDirectory:(NSString *)directory;
- (void)start;
- (void)stop;
@end

@implementation MSHostSession
- (instancetype)initWithResourcesDirectory:(NSString *)directory {
    if((self=[super init])) {
        _resourcesDirectory=[directory copy];_presetName=@"Custom look";
        _entries=@[];_library=@[];_directories=[NSMutableArray array];_securityURLs=[NSMutableArray array];
        _selected=NSNotFound;_requestedSelection=NSNotFound;_generation.store(0);
        _compileQueue=dispatch_queue_create("local.macshade.host.compile",DISPATCH_QUEUE_SERIAL);
        double scale = [NSUserDefaults.standardUserDefaults doubleForKey:@"MacShadeQualityScale"];
        if (scale < 0.25 || scale > 1.0) scale = 1.0;
        _qualityScale = scale;
        if ([NSUserDefaults.standardUserDefaults objectForKey:@"MacShadeButtonX"] != nil) {
            _buttonOrigin = NSMakePoint(
                [NSUserDefaults.standardUserDefaults doubleForKey:@"MacShadeButtonX"],
                [NSUserDefaults.standardUserDefaults doubleForKey:@"MacShadeButtonY"]
            );
            _hasButtonOrigin = YES;
        }
        NSDictionary *environment=NSProcessInfo.processInfo.environment;
        NSString *effect=environment[@"MACSHADE_EFFECT"],*preset=environment[@"MACSHADE_PRESET"];
        if(effect.length)_startupEffect=[NSURL fileURLWithPath:effect.stringByStandardizingPath];
        if(preset.length){
            _startupPreset=[NSURL fileURLWithPath:preset.stringByStandardizingPath];
        }
    }
    return self;
}
- (void)start {
    MSSetSettings(MSNeutralSettings());MSSetEnabled(YES);MSSetFXEffects(@[]);
    if(_resourcesDirectory.length) {
        NSURL *effects=[[NSURL fileURLWithPath:_resourcesDirectory isDirectory:YES] URLByAppendingPathComponent:@"Effects" isDirectory:YES];
        BOOL directory=NO;
        if([NSFileManager.defaultManager fileExistsAtPath:effects.path isDirectory:&directory]&&directory)[_directories addObject:effects];
    }
    _directories=[MSReShadeSearchDirectories(_directories,nil) mutableCopy];
    _overlay=[MSOverlayController new];(void)_overlay.view;[self connectOverlay];[self refreshLibrary];
    __weak MSHostSession *weak=self;
    _keyMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        MSHostSession *owner=weak;
        if(!owner||owner->_stopped||!owner->_window||event.window!=owner->_window||owner->_window.attachedSheet)return event;
        NSEventModifierFlags modifiers=event.modifierFlags&NSEventModifierFlagDeviceIndependentFlagsMask;
        if((modifiers&~NSEventModifierFlagCapsLock)!=NSEventModifierFlagCommand)return event;
        NSString *key=event.charactersIgnoringModifiers.lowercaseString;
        if([key isEqualToString:@"e"]){if(!event.isARepeat)[owner toggleOverlay:nil];return nil;}
        if([key isEqualToString:@"b"]){if(!event.isARepeat){MSSetEnabled(!MSIsEnabled());[owner refreshControls];}return nil;}
        return event;
    }];
    _timer=[NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer){(void)timer;[weak tick];}];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    SetHostStatus(@"Loaded; waiting for a visible Metal window");NSLog(@"MacShade host: UI loaded; waiting for Metal window");
    [self tick];
}
- (void)stop {
    if(_stopped)return;_stopped=YES;++_generation;
    [_timer invalidate];_timer=nil;
    if(_keyMonitor){[NSEvent removeMonitor:_keyMonitor];_keyMonitor=nil;}
    if(_activePanel){[_activePanel.sheetParent endSheet:_activePanel returnCode:NSModalResponseCancel];[_activePanel orderOut:nil];_activePanel=nil;}
    [_container removeFromSuperview];_container=nil;_toggleButton=nil;_depthToggle=nil;
    [_overlay.view removeFromSuperview];
    _window=nil;_content=nil;_metalLayer=nil;_overlay=nil;
    for(NSURL *url in _securityURLs)[url stopAccessingSecurityScopedResource];[_securityURLs removeAllObjects];
    MSSetFXEffects(@[]);MSSetEnabled(NO);SetHostStatus(@"Stopped");NSLog(@"MacShade host: UI stopped");
}
- (void)accessURL:(NSURL *)url {
    if(![_securityURLs containsObject:url]&&[url startAccessingSecurityScopedResource])[_securityURLs addObject:url];
}
- (void)detach {
    ++_generation;_loading=NO;_suspended=YES;MSSetFXEffects(@[]);
    if(_activePanel){[_activePanel.sheetParent endSheet:_activePanel returnCode:NSModalResponseCancel];[_activePanel orderOut:nil];_activePanel=nil;}
    [_container removeFromSuperview];_container=nil;_toggleButton=nil;_depthToggle=nil;
    [_overlay.view removeFromSuperview];
    _window=nil;_content=nil;_metalLayer=nil;_observedDevice=nil;_observedWidth=0;_observedHeight=0;
    SetHostStatus(@"Waiting for a visible Metal window");
}
- (void)attachWindow:(NSWindow *)window layer:(CAMetalLayer *)layer {
    _window=window;_content=window.contentView;_metalLayer=layer;
    _hostResponder=window.firstResponder;
    NSView *parent=_content;
    _container=[[MSHostOverlayContainer alloc]initWithFrame:NSZeroRect];
    _container.wantsLayer=YES;_container.layer.masksToBounds=NO;
    _container.identifier=@"MacShadeHostOverlay";
    _container.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [parent addSubview:_container positioned:NSWindowAbove relativeTo:nil];
    _depthToggle=[NSButton checkboxWithTitle:@"Reversed depth input" target:self action:@selector(toggleDepth:)];
    _depthToggle.font=[NSFont systemFontOfSize:11];
    _depthToggle.toolTip=@"Enable when the host stores near surfaces as 1 and far surfaces as 0.";
    [_container addSubview:_depthToggle];
    _overlay.view.hidden=YES;
    [_container addSubview:_overlay.view];
    _toggleButton=[[MSDraggableCircleButton alloc]initWithFrame:NSMakeRect(0,0,44,44)];
    __weak MSHostSession *weak=self;
    _toggleButton.onClick=^{MSHostSession *owner=weak;if(owner)[owner toggleOverlay:nil];};
    _toggleButton.onDragDelta=^(CGFloat dx,CGFloat dy){
        MSHostSession *owner=weak;
        if(!owner||!owner->_content)return;
        owner->_buttonOrigin.x+=dx;
        owner->_buttonOrigin.y+=dy;
        const CGFloat kBtnSize=44.0,margin=10.0;
        CGFloat minX=margin,maxX=MAX(margin,owner->_content.bounds.size.width-kBtnSize-margin);
        CGFloat minY=margin,maxY=MAX(margin,owner->_content.bounds.size.height-kBtnSize-margin);
        owner->_buttonOrigin.x=std::clamp((CGFloat)owner->_buttonOrigin.x,minX,maxX);
        owner->_buttonOrigin.y=std::clamp((CGFloat)owner->_buttonOrigin.y,minY,maxY);
        [owner layoutHostViews];
        [NSUserDefaults.standardUserDefaults setDouble:owner->_buttonOrigin.x forKey:@"MacShadeButtonX"];
        [NSUserDefaults.standardUserDefaults setDouble:owner->_buttonOrigin.y forKey:@"MacShadeButtonY"];
    };
    [_container addSubview:_toggleButton positioned:NSWindowAbove relativeTo:nil];
    [self updateQualityUI];
    [self layoutHostViews];[self refreshEntries];[self refreshControls];
    [_overlay setStatus:@"RoMacShade is ready" detail:@"Open an effect or import a preset. ⌘E shows controls; ⌘B toggles effects." busy:NO error:NO];
    SetHostStatus(@"Attached to Metal window");
    NSLog(@"MacShade host: attached window=%ld size=%lux%lu",(long)window.windowNumber,
        (unsigned long)layer.drawableSize.width,(unsigned long)layer.drawableSize.height);
}
- (void)layoutHostViews {
    NSView *content=_content,*parent=_container.superview;if(!content||!parent)return;
    NSRect contentBounds=content.bounds;
    const CGFloat kBtnSize=44.0,margin=10.0;
    CGFloat minX=margin,maxX=MAX(margin,contentBounds.size.width-kBtnSize-margin);
    CGFloat minY=margin,maxY=MAX(margin,contentBounds.size.height-kBtnSize-margin);
    if(!_hasButtonOrigin) {
        _hasButtonOrigin=YES;
        _buttonOrigin.x=maxX;
        _buttonOrigin.y=content.flipped?margin:maxY;
    }
    _buttonOrigin.x=std::clamp((CGFloat)_buttonOrigin.x,minX,maxX);
    _buttonOrigin.y=std::clamp((CGFloat)_buttonOrigin.y,minY,maxY);

    if(_overlay.view.hidden) {
        _container.frame=NSMakeRect(std::round(_buttonOrigin.x),std::round(_buttonOrigin.y),kBtnSize,kBtnSize);
        _toggleButton.frame=NSMakeRect(0,0,kBtnSize,kBtnSize);
        _depthToggle.hidden=YES;
    } else {
        _container.frame=contentBounds;
        NSPoint originInContainer=[content convertPoint:_buttonOrigin toView:_container];
        _toggleButton.frame=NSMakeRect(std::round(originInContainer.x),std::round(originInContainer.y),kBtnSize,kBtnSize);
        const CGFloat width=MAX(1,_container.bounds.size.width),height=MAX(1,_container.bounds.size.height);
        _depthToggle.frame=NSMakeRect(20,10,MIN(190,MAX(1,width-40)),28);
        _depthToggle.hidden=width<310;
        NSRect ov=_overlay.view.frame;
        if (ov.size.width<500||ov.size.height<360) {
            CGFloat w=MIN(860.0,width-40.0);
            CGFloat h=MIN(640.0,height-60.0);
            ov=NSMakeRect(MAX(20.0,width-w-20.0),48.0,MAX(500.0,w),MAX(360.0,h));
        } else {
            ov.size.width=MIN(ov.size.width,width-20.0);
            ov.size.height=MIN(ov.size.height,height-58.0);
            ov.origin.x=std::clamp(ov.origin.x,(CGFloat)10.0,(CGFloat)MAX(10.0,width-ov.size.width-10.0));
            ov.origin.y=std::clamp(ov.origin.y,(CGFloat)48.0,(CGFloat)MAX(48.0,height-ov.size.height-10.0));
        }
        _overlay.view.frame=ov;
    }
    [_overlay.view layoutSubtreeIfNeeded];
}
- (void)tick {
    if(_stopped)return;
    if(_window&&(!_window.visible||_window.miniaturized||_window.contentView!=_content||!_container.superview))[self detach];
    if(!_window) {
        for(NSWindow *window in NSApp.orderedWindows) {
            if(!window.visible||window.miniaturized||!window.contentView)continue;
            CAMetalLayer *layer=FindViewLayer(window.contentView);
            if(layer){[self attachWindow:window layer:layer];break;}
        }
    }
    if(!_window)return;
    CAMetalLayer *current=FindViewLayer(_content);
    if(!current){[self detach];return;}
    if(current&&current!=_metalLayer){_metalLayer=current;_observedWidth=0;_observedDevice=nil;}
    [self layoutHostViews];
    NSUInteger width=(NSUInteger)_metalLayer.drawableSize.width,height=(NSUInteger)_metalLayer.drawableSize.height;
    id<MTLDevice> device=_metalLayer.device;
    if(!width||!height||!device){_suspended=YES;_observedWidth=0;_observedHeight=0;MSSetFXEffects(@[]);return;}
    _depthToggle.state=MSIsDepthReversed()?NSControlStateValueOn:NSControlStateValueOff;
    if(width!=_observedWidth||height!=_observedHeight||device!=_observedDevice) {
        _observedWidth=width;_observedHeight=height;_observedDevice=device;
        if(_entries.count||_pendingSpecifications.count)[self scheduleResize];
    }
    if(!_startupHandled) {
        _startupHandled=YES;
        if(_startupPreset)[self loadPreset:_startupPreset];else if(_startupEffect)[self addEffect:_startupEffect];
    }
    BOOL needsDepth=NO;
    for(MSFXEffect *effect in MSGetFXEffects())if(effect.requiresDepth){needsDepth=YES;break;}
    BOOL depthUnavailable=needsDepth&&[MSLastDepthStatus() hasPrefix:@"No matching depth"];
    if(!_loading&&depthUnavailable!=_depthUnavailable) {
        _depthUnavailable=depthUnavailable;
        if(depthUnavailable)[_overlay setStatus:@"Waiting for scene depth" detail:@"This frame has no matching depth input. Depth effects are skipped; color effects placed before them can still run." busy:NO error:YES];
        else [_overlay setStatus:@"Look ready" detail:@"Changes apply live. ⌘E hides controls; ⌘B compares." busy:NO error:NO];
    }
    if(CACurrentMediaTime()-_lastLog>=10) {
        _lastLog=CACurrentMediaTime();
        NSString *summary=[NSString stringWithFormat:@"Attached; processed=%llu FX=%llu depth=%llu %@",
            (unsigned long long)MSProcessedFrameCount(),(unsigned long long)MSProcessedFXFrameCount(),
            (unsigned long long)MSDepthCaptureCount(),_loading?@"compiling":MSIsEnabled()?@"enabled":@"disabled"];
        SetHostStatus(summary);NSLog(@"MacShade host: %@",summary);
    }
}
- (void)toggleOverlay:(id)sender {
    (void)sender;
    if(_overlay.view.hidden) {
        NSResponder *responder=_window.firstResponder;
        if(responder&&(![responder isKindOfClass:NSView.class]||![(NSView *)responder isDescendantOf:_container]))_hostResponder=responder;
        _overlay.view.hidden=NO;
        _toggleButton.isOpen=YES;
        [self refreshEntries];[self refreshControls];
    } else {
        _overlay.view.hidden=YES;
        _toggleButton.isOpen=NO;
        if(_hostResponder&&(![_hostResponder isKindOfClass:NSView.class]||[(NSView *)_hostResponder window]==_window))[_window makeFirstResponder:_hostResponder];
    }
    [self layoutHostViews];
}
- (void)toggleDepth:(id)sender {
    (void)sender;MSSetDepthReversed(_depthToggle.state==NSControlStateValueOn);
}
- (void)refreshLibrary {
    _directories=[MSReShadeSearchDirectories(_directories,nil) mutableCopy];
    _library=MSFXLibrary(_directories);[_overlay updateLibrary:_library];
    [_overlay updatePresets:[self discoveredPresets] selectedURL:_currentPresetURL];
}
- (NSArray<NSURL *> *)includeDirectories {
    NSMutableArray *result=[_directories mutableCopy];
    for(NSDictionary *item in _library) {NSURL *directory=[item[@"url"] URLByDeletingLastPathComponent];if(![result containsObject:directory])[result addObject:directory];}
    for(NSDictionary *entry in _entries) {NSURL *directory=[entry[@"url"] URLByDeletingLastPathComponent];if(directory&&![result containsObject:directory])[result addObject:directory];}
    return [result copy];
}
- (void)refreshControls {
    MSSettings settings=MSGetSettings();NSMutableArray *values=[NSMutableArray array];
    for(size_t offset:kOffsets)[values addObject:@(*reinterpret_cast<const float *>(reinterpret_cast<const char *>(&settings)+offset))];
    [_overlay updateBuiltinValues:values enabled:MSIsEnabled()];
    _depthToggle.state=MSIsDepthReversed()?NSControlStateValueOn:NSControlStateValueOff;
}
- (NSArray<NSDictionary *> *)discoveredPresets {
    NSArray *resources = _resourcesDirectory.length ? @[[[NSURL fileURLWithPath:_resourcesDirectory isDirectory:YES]
        URLByAppendingPathComponent:@"Presets" isDirectory:YES]] : @[];
    return MSDiscoverPresetLibrary(resources, _directories, _currentPresetURL);
}
- (void)refreshEntries {
    if(_selected>=_entries.count)_selected=_entries.count?_entries.count-1:NSNotFound;
    [_overlay updateEntries:_entries selectedIndex:_selected];
    [_overlay updatePresets:[self discoveredPresets] selectedURL:_currentPresetURL];
    [_overlay setPresetName:_presetName];
}
- (void)installChain {
    if(_suspended){MSSetFXEffects(@[]);return;}
    NSMutableArray *effects=[NSMutableArray array];
    for(NSDictionary *entry in _entries)if([entry[@"enabled"] boolValue]&&entry[@"effect"])[effects addObject:entry[@"effect"]];
    MSSetFXEffects(effects);
}
- (void)showError:(NSString *)message detail:(NSString *)detail {
    _overlay.view.hidden=NO;[_overlay setStatus:message detail:detail?:@"" busy:NO error:YES];
    SetHostStatus(message);
    if (detail.length) {
        NSLog(@"MacShade host: %@: %@", message, detail);
    } else {
        NSLog(@"MacShade host: %@", message);
    }
}
- (void)compileSpecifications:(NSArray<NSDictionary *> *)specifications name:(NSString *)name detail:(NSString *)detail {
    if(_stopped)return;
    NSUInteger fullW=(NSUInteger)_metalLayer.drawableSize.width,fullH=(NSUInteger)_metalLayer.drawableSize.height;
    id<MTLDevice> device=_metalLayer.device;
    _pendingSpecifications=[specifications copy];_pendingName=[name copy];_pendingDetail=[detail copy];
    if(!_window||!device||!fullW||!fullH){_loading=NO;[self showError:@"Waiting for the host renderer" detail:@"The effect will load when its Metal window is ready."];return;}
    NSUInteger width=std::max<NSUInteger>(2,((NSUInteger)std::round(fullW * _qualityScale)) & ~1);
    NSUInteger height=std::max<NSUInteger>(2,((NSUInteger)std::round(fullH * _qualityScale)) & ~1);
    if(_effectWidth!=width||_effectHeight!=height||_compiledDevice!=device){_suspended=YES;MSSetFXEffects(@[]);}
    const uint64_t generation=++_generation;_loading=YES;
    NSArray *snapshot=_pendingSpecifications,*directories=[self includeDirectories];
    NSURL *presetToInstall=_pendingPresetChange?_pendingPresetURL:_currentPresetURL;
    [_overlay setStatus:@"Preparing your look…" detail:@"The replacement becomes active after every effect compiles." busy:YES error:NO];
    __weak MSHostSession *weak=self;
    dispatch_async(_compileQueue,^{@autoreleasepool {
        MSHostSession *owner=weak;if(!owner||owner->_generation.load()!=generation)return;
        NSError *error=nil;NSArray *compiled=MSCompileFXChain(snapshot,device,width,height,directories,&error);
        dispatch_async(dispatch_get_main_queue(),^{
            MSHostSession *session=weak;if(!session||session->_stopped||session->_generation.load()!=generation)return;
            session->_loading=NO;
            if(!session->_window)return;
            NSUInteger curScaledW=std::max<NSUInteger>(2,((NSUInteger)std::round((NSUInteger)session->_metalLayer.drawableSize.width * session->_qualityScale)) & ~1);
            NSUInteger curScaledH=std::max<NSUInteger>(2,((NSUInteger)std::round((NSUInteger)session->_metalLayer.drawableSize.height * session->_qualityScale)) & ~1);
            if(width!=curScaledW||height!=curScaledH||device!=session->_metalLayer.device) {
                [session scheduleResize];return;
            }
            session->_pendingSpecifications=nil;session->_pendingName=nil;session->_pendingDetail=nil;
            if(!compiled) {
                session->_pendingPresetChange=NO;session->_pendingPresetURL=nil;
                session->_requestedSelection=NSNotFound;
                [session installChain];[session refreshEntries];
                [session showError:@"Could not load this look" detail:error.localizedDescription];return;
            }
            session->_entries=compiled;session->_effectWidth=width;session->_effectHeight=height;session->_compiledDevice=device;
            session->_currentPresetURL=presetToInstall;session->_pendingPresetChange=NO;session->_pendingPresetURL=nil;
            session->_presetName=name?:@"Custom look";session->_suspended=NO;
            if(session->_requestedSelection!=NSNotFound)session->_selected=session->_requestedSelection;
            session->_requestedSelection=NSNotFound;
            [session installChain];[session refreshEntries];
            [session->_overlay setStatus:@"Look ready" detail:detail.length?detail:@"Changes apply live. ⌘E hides controls; ⌘B compares." busy:NO error:NO];
            SetHostStatus(@"Effects compiled and active");NSLog(@"MacShade host: compiled chain entries=%lu",(unsigned long)compiled.count);
        });
    }});
}
- (void)scheduleResize {
    if(_stopped)return;
    NSArray *specifications=_pendingSpecifications?:MSFXChainSpecifications(_entries);
    NSString *name=_pendingName?:_presetName,*detail=_pendingDetail?:@"";
    _pendingSpecifications=specifications;_pendingName=name;_pendingDetail=detail;
    _suspended=YES;_loading=YES;MSSetFXEffects(@[]);const uint64_t generation=++_generation;
    [_overlay setStatus:@"Updating for the window size…" detail:@"Your effect order and settings are preserved." busy:YES error:NO];
    __weak MSHostSession *weak=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        MSHostSession *owner=weak;if(owner&&!owner->_stopped&&owner->_generation.load()==generation)
            [owner compileSpecifications:specifications name:name detail:detail];
    });
}
- (void)addEffect:(NSURL *)url {
    if(_stopped||_loading)return;[self accessURL:url];
    for(NSUInteger i=0;i<_entries.count;++i)if([_entries[i][@"url"] isEqual:url]){_selected=i;[self refreshEntries];return;}
    NSMutableArray *specifications=[MSFXChainSpecifications(_entries) mutableCopy];
    NSUInteger insertIndex=0;
    for(NSDictionary *spec in specifications)if([spec[@"enabled"] boolValue])insertIndex++;
    [specifications insertObject:@{@"url":url,@"enabled":@YES,@"values":@{},@"definitions":@{}} atIndex:insertIndex];
    _pendingPresetChange=YES;_pendingPresetURL=nil;
    _requestedSelection=insertIndex;[self compileSpecifications:specifications name:@"Custom look" detail:@""];
}
- (void)openEffect {
    if(_loading||!_window||_activePanel)return;
    NSOpenPanel *panel=[NSOpenPanel openPanel];panel.title=@"Add a ReShade effect";
    panel.allowedContentTypes=@[[UTType typeWithFilenameExtension:@"fx"]?:UTTypeData];
    __weak MSHostSession *weak=self;
    _activePanel=panel;
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response){MSHostSession *owner=weak;if(!owner)return;owner->_activePanel=nil;if(response==NSModalResponseOK&&panel.URL)[owner addEffect:panel.URL];}];
}
- (void)addFolder {
    if(_loading||!_window||_activePanel)return;
    NSOpenPanel *panel=[NSOpenPanel openPanel];panel.title=@"Add an effects folder";panel.canChooseFiles=NO;panel.canChooseDirectories=YES;
    __weak MSHostSession *weak=self;
    _activePanel=panel;
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response){
        MSHostSession *owner=weak;if(!owner)return;owner->_activePanel=nil;if(owner->_stopped||response!=NSModalResponseOK||!panel.URL)return;
        [owner accessURL:panel.URL];if(![owner->_directories containsObject:panel.URL])[owner->_directories addObject:panel.URL];
        [owner refreshLibrary];[owner->_overlay setStatus:@"Effects folder added" detail:@"Choose a shader or import its preset." busy:NO error:NO];
    }];
}
- (void)loadPreset:(NSURL *)url {
    if(_loading||_stopped)return;[self accessURL:url];
    NSError *error=nil;MSFXPreset *preset=[MSFXPreset presetWithURL:url error:&error];
    if(!preset){[self showError:@"Could not read this preset" detail:error.localizedDescription];return;}
    NSArray *companions=MSReShadeSearchDirectories(@[],url);
    for(NSURL *directory in companions)if(![_directories containsObject:directory])[_directories addObject:directory];
    [self refreshLibrary];
    NSMutableArray *warnings=[preset.warnings mutableCopy];NSArray *adjacent=MSFXLibrary(companions);
    NSMutableArray *library=[adjacent mutableCopy];NSMutableSet *names=[NSMutableSet set];
    for(NSDictionary *item in adjacent)[names addObject:[item[@"url"] lastPathComponent].lowercaseString];
    for(NSDictionary *item in _library)if(![names containsObject:[item[@"url"] lastPathComponent].lowercaseString])[library addObject:item];
    for(NSDictionary *entry in _entries) {
        NSURL *known=entry[@"url"];BOOL present=NO;
        for(NSDictionary *item in library)if([item[@"url"] isEqual:known]){present=YES;break;}
        if(!present&&known)[library addObject:@{@"url":known,@"name":known.lastPathComponent,@"subtitle":@"Loaded effect"}];
    }
    NSArray *specifications=MSFXPresetSpecifications(preset,url,library,warnings,&error);
    if(!specifications){[self showError:@"Preset needs attention" detail:error.localizedDescription];return;}
    NSMutableArray *activeSpecs=[NSMutableArray array],*inactiveSpecs=[NSMutableArray array];
    for(NSDictionary *spec in specifications) {
        if([spec[@"enabled"] boolValue])[activeSpecs addObject:spec];
        else [inactiveSpecs addObject:spec];
    }
    NSMutableArray *orderedSpecs=[activeSpecs mutableCopy];
    [orderedSpecs addObjectsFromArray:inactiveSpecs];
    specifications=orderedSpecs;
    _pendingPresetChange=YES;_pendingPresetURL=url;
    _requestedSelection=specifications.count?0:NSNotFound;
    [self compileSpecifications:specifications name:url.lastPathComponent.stringByDeletingPathExtension detail:[warnings componentsJoinedByString:@"\n"]];
}
- (void)importPreset {
    if(_loading||!_window||_activePanel)return;
    NSOpenPanel *panel=[NSOpenPanel openPanel];panel.title=@"Import a ReShade preset";
    panel.allowedContentTypes=@[[UTType typeWithFilenameExtension:@"ini"]?:UTTypeData];
    __weak MSHostSession *weak=self;
    _activePanel=panel;
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response){MSHostSession *owner=weak;if(!owner)return;owner->_activePanel=nil;if(response==NSModalResponseOK&&panel.URL)[owner loadPreset:panel.URL];}];
}
- (void)exportPreset {
    if(_loading||!_window||_activePanel)return;
    NSError *error=nil;NSString *text=MSFXChainPresetString(_entries,&error);
    if(!text){[self showError:@"Could not save this preset" detail:error.localizedDescription];return;}
    NSSavePanel *panel=[NSSavePanel savePanel];panel.title=@"Save ReShade preset";
    panel.allowedContentTypes=@[[UTType typeWithFilenameExtension:@"ini"]?:UTTypeData];panel.nameFieldStringValue=[_presetName stringByAppendingPathExtension:@"ini"];
    panel.identifier=@"MacShadeHostPresetSave";
    panel.directoryURL=[NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];panel.canCreateDirectories=YES;
    panel.message=@"Saves shader order and parameters. Built-in Look adjustments are separate.";
    __weak MSHostSession *weak=self;
    _activePanel=panel;
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response){
        MSHostSession *owner=weak;if(!owner)return;owner->_activePanel=nil;if(owner->_stopped||response!=NSModalResponseOK||!panel.URL)return;
        [owner accessURL:panel.URL];NSError *failure=nil;
        if(![text writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&failure]){[owner showError:@"Could not save this preset" detail:failure.localizedDescription];return;}
        owner->_presetName=panel.URL.lastPathComponent.stringByDeletingPathExtension;
        owner->_currentPresetURL=panel.URL;
        [owner refreshEntries];
        [owner->_overlay setStatus:@"Preset saved" detail:panel.URL.lastPathComponent busy:NO error:NO];
    }];
}
- (void)connectOverlay {
    __weak MSHostSession *weak=self;
    _overlay.openEffect=^{[weak openEffect];};_overlay.addFolder=^{[weak addFolder];};
    _overlay.importPreset=^{[weak importPreset];};_overlay.exportPreset=^{[weak exportPreset];};
    _overlay.hideOverlay=^{[weak toggleOverlay:nil];};_overlay.chooseEffect=^(NSURL *url){[weak addEffect:url];};
    _overlay.choosePreset=^(NSURL *presetURL){[weak loadPreset:presetURL];};
    [_overlay updatePresets:[self discoveredPresets] selectedURL:_currentPresetURL];
    _overlay.reloadEffects=^{MSHostSession *owner=weak;if(owner&&!owner->_loading)[owner compileSpecifications:MSFXChainSpecifications(owner->_entries) name:owner->_presetName detail:@"Compatible settings preserved."];};
    _overlay.selectEntry=^(NSUInteger index){MSHostSession *owner=weak;if(owner&&index<owner->_entries.count){owner->_selected=index;[owner refreshEntries];}};
    _overlay.enableEntry=^(NSUInteger index,BOOL enabled){
        MSHostSession *owner=weak;if(!owner||owner->_loading||index>=owner->_entries.count)return;
        NSMutableArray *entries=[owner->_entries mutableCopy];
        NSMutableDictionary *entry=[entries[index] mutableCopy];
        entry[@"enabled"]=@(enabled);
        [entries removeObjectAtIndex:index];
        NSUInteger dest=0;
        for(NSDictionary *e in entries)if([e[@"enabled"] boolValue])dest++;
        [entries insertObject:entry atIndex:dest];
        if(enabled&&!entry[@"effect"]){
            owner->_selected=dest;
            [owner compileSpecifications:MSFXChainSpecifications(entries) name:owner->_presetName detail:@""];
            return;
        }
        owner->_entries=entries;owner->_selected=dest;[owner installChain];[owner refreshEntries];
    };
    _overlay.moveEntry=^(NSUInteger index,NSInteger direction){
        MSHostSession *owner=weak;if(!owner||owner->_loading||index>=owner->_entries.count)return;
        BOOL isActive=[owner->_entries[index][@"enabled"] boolValue];
        NSInteger destination=(NSInteger)index+direction;
        if(destination<0||destination>=(NSInteger)owner->_entries.count)return;
        BOOL destActive=[owner->_entries[(NSUInteger)destination][@"enabled"] boolValue];
        if(isActive!=destActive)return;
        NSMutableArray *entries=[owner->_entries mutableCopy];
        [entries exchangeObjectAtIndex:index withObjectAtIndex:(NSUInteger)destination];
        owner->_entries=entries;owner->_selected=(NSUInteger)destination;[owner installChain];[owner refreshEntries];
    };
    _overlay.removeEntry=^(NSUInteger index){
        MSHostSession *owner=weak;if(!owner||owner->_loading||index>=owner->_entries.count)return;
        NSMutableArray *entries=[owner->_entries mutableCopy];[entries removeObjectAtIndex:index];owner->_entries=entries;[owner installChain];[owner refreshEntries];
    };
    _overlay.selectTechnique=^(NSString *name){
        MSHostSession *owner=weak;if(!owner||owner->_loading||owner->_selected>=owner->_entries.count)return;
        NSDictionary *entry=owner->_entries[owner->_selected];
        for(NSUInteger i=0;i<owner->_entries.count;++i)if(i!=owner->_selected&&[owner->_entries[i][@"url"] isEqual:entry[@"url"]]&&[Technique(owner->_entries[i]) isEqual:name]) {
            [owner showError:@"This technique is already listed" detail:@"Select its existing row to adjust it."];return;
        }
        MSFXEffect *effect=entry[@"effect"];if(!effect)return;
        NSError *error=nil;if(![effect selectTechniqueNamed:name error:&error])[owner showError:@"Could not change technique" detail:error.localizedDescription];
        [owner refreshEntries];
    };
    _overlay.changeUniform=^NSString *(NSString *name,NSArray<NSNumber *> *values){
        MSHostSession *owner=weak;if(!owner||owner->_loading||owner->_selected>=owner->_entries.count)return @"Wait for the effect to finish loading.";
        NSDictionary *selected=owner->_entries[owner->_selected];MSFXEffect *effect=selected[@"effect"];
        if(!effect)return @"Enable this effect before editing its controls.";
        NSError *error=nil;if(![effect setUniformNamed:name values:values error:&error])return error.localizedDescription?:@"Could not update this parameter.";
        NSMutableArray *entries=[owner->_entries mutableCopy];
        for(NSUInteger i=0;i<entries.count;++i)if(i!=owner->_selected&&[entries[i][@"url"] isEqual:selected[@"url"]]) {
            MSFXEffect *other=entries[i][@"effect"];
            if(other)[other setUniformNamed:name values:values error:nil];
            else {NSMutableDictionary *entry=[entries[i] mutableCopy],*stored=[entry[@"values"]?:@{} mutableCopy];stored[name]=[values copy];entry[@"values"]=[stored copy];entries[i]=entry;}
        }
        owner->_entries=entries;return nil;
    };
    _overlay.toggleAll=^(BOOL enabled){MSSetEnabled(enabled);[weak refreshControls];};
    _overlay.changeBuiltin=^(NSUInteger index,double value){
        if(index>=sizeof(kOffsets)/sizeof(kOffsets[0])||!std::isfinite(value))return;
        MSSettings settings=MSGetSettings();*reinterpret_cast<float *>(reinterpret_cast<char *>(&settings)+kOffsets[index])=(float)value;MSSetSettings(settings);
    };
    _overlay.neutralBuiltin=^{MSSetSettings(MSNeutralSettings());[weak refreshControls];};
    _overlay.resetBuiltin=^{MSSetSettings(MSDefaultSettings());[weak refreshControls];};
    _overlay.cycleQuality=^{
        MSHostSession *owner=weak;if(!owner)return;
        if(owner->_qualityScale>0.85)owner->_qualityScale=0.75;
        else if(owner->_qualityScale>0.60)owner->_qualityScale=0.50;
        else owner->_qualityScale=1.0;
        [NSUserDefaults.standardUserDefaults setDouble:owner->_qualityScale forKey:@"MacShadeQualityScale"];
        [owner updateQualityUI];
        [owner scheduleResize];
    };
    [self updateQualityUI];
}
- (void)updateQualityUI {
    NSString *label=@"100% (FQ)";
    if(_qualityScale<0.60)label=@"50%";
    else if(_qualityScale<0.85)label=@"75%";
    [_overlay setQualityLabel:label];
}
@end

namespace { MSHostSession *__strong gHostSession; }
void MSStartHostOverlay(NSString *resourcesDirectory) {
    NSString *directory=[resourcesDirectory copy]?:@"";
    dispatch_async(dispatch_get_main_queue(),^{[gHostSession stop];gHostSession=[[MSHostSession alloc]initWithResourcesDirectory:directory];[gHostSession start];});
}
void MSStopHostOverlay(void) {
    dispatch_async(dispatch_get_main_queue(),^{[gHostSession stop];gHostSession=nil;SetHostStatus(@"Stopped");});
}
NSString *MSHostOverlayStatus(void) {
    std::lock_guard<std::mutex> lock(StatusLock());return StatusText();
}
