#import "Overlay.h"
#import <QuartzCore/QuartzCore.h>
#import <pwd.h>
#import <unistd.h>
#include <algorithm>
#include <cmath>

namespace {
NSURL *ReShadeDocumentsRoot() {
    NSString *home = NSHomeDirectory();
    struct passwd *pw = getpwuid(getuid());
    if (pw && pw->pw_dir) {
        NSString *realHome = [NSString stringWithUTF8String:pw->pw_dir];
        if (realHome.length) home = realHome;
    }
    return [[NSURL fileURLWithPath:home isDirectory:YES]
        URLByAppendingPathComponent:@"Documents/reshade roblox" isDirectory:YES];
}
NSString *URLIdentity(NSURL *url) { return url.URLByResolvingSymlinksInPath.URLByStandardizingPath.path ?: @""; }
void AddExistingDirectory(NSMutableArray<NSURL *> *result, NSMutableSet<NSString *> *seen, NSURL *url) {
    if (!url.isFileURL || result.count >= 256) return;
    BOOL directory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&directory] || !directory) return;
    NSString *key = URLIdentity(url);
    if ([seen containsObject:key]) return;
    [seen addObject:key]; [result addObject:url.URLByStandardizingPath];
}
void AddCompanionDirectories(NSMutableArray<NSURL *> *result, NSMutableSet<NSString *> *seen, NSURL *base) {
    for (NSUInteger level = 0; base && level < 3; ++level, base = base.URLByDeletingLastPathComponent) {
        for (NSString *suffix in @[@"reshade-shaders/Shaders", @"reshade-shaders/Textures", @"Shaders", @"Textures"])
            AddExistingDirectory(result, seen, [base URLByAppendingPathComponent:suffix isDirectory:YES]);
    }
}
NSDictionary *PresetItem(NSURL *url) {
    NSString *name = url.lastPathComponent.stringByDeletingPathExtension;
    NSString *parent = url.URLByDeletingLastPathComponent.lastPathComponent;
    NSString *category = [parent caseInsensitiveCompare:@"Presets"] == NSOrderedSame ? @"Built-in" : parent;
    NSString *prefix = @"Extravi's ReShade-Preset ";
    if ([name hasPrefix:prefix]) { category = @"Extravi"; name = [name substringFromIndex:prefix.length]; }
    else if ([parent caseInsensitiveCompare:@"reshade-presets"] == NSOrderedSame) category = @"Imported";
    return @{@"url": url, @"name": name, @"category": category.length ? category : @"Presets"};
}
}

NSArray<NSURL *> *MSReShadeSearchDirectories(NSArray<NSURL *> *directories, NSURL *presetURL) {
    NSMutableArray<NSURL *> *result = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
    if (presetURL) {
        AddCompanionDirectories(result, seen, presetURL.URLByDeletingLastPathComponent);
        AddExistingDirectory(result, seen, presetURL.URLByDeletingLastPathComponent);
    }
    AddCompanionDirectories(result, seen, ReShadeDocumentsRoot());
    for (NSURL *directory in directories) {
        AddExistingDirectory(result, seen, directory);
        AddCompanionDirectories(result, seen, directory);
    }
    return [result copy];
}

NSArray<NSDictionary *> *MSDiscoverPresetLibrary(NSArray<NSURL *> *resourceDirectories,
    NSArray<NSURL *> *effectDirectories, NSURL *selectedURL) {
    NSMutableArray *scan = [NSMutableArray array]; NSMutableSet *seenDirectories = [NSMutableSet set];
    AddExistingDirectory(scan, seenDirectories, [ReShadeDocumentsRoot() URLByAppendingPathComponent:@"reshade-presets" isDirectory:YES]);
    AddExistingDirectory(scan, seenDirectories, [ReShadeDocumentsRoot() URLByAppendingPathComponent:@"Presets" isDirectory:YES]);
    AddExistingDirectory(scan, seenDirectories, ReShadeDocumentsRoot());
    if (selectedURL) AddExistingDirectory(scan, seenDirectories, selectedURL.URLByDeletingLastPathComponent);
    for (NSURL *directory in effectDirectories) {
        NSURL *base = directory;
        for (NSUInteger level = 0; base && level < 3; ++level, base = base.URLByDeletingLastPathComponent) {
            for (NSString *name in @[@"reshade-presets", @"Presets"])
                AddExistingDirectory(scan, seenDirectories, [base URLByAppendingPathComponent:name isDirectory:YES]);
        }
    }
    for (NSURL *directory in resourceDirectories) AddExistingDirectory(scan, seenDirectories, directory);
    NSMutableArray *result = [NSMutableArray array]; NSMutableSet *names = [NSMutableSet set];
    void (^append)(NSURL *) = ^(NSURL *url) {
        if (result.count >= 512 || ![url.pathExtension.lowercaseString isEqual:@"ini"]) return;
        NSNumber *regular = nil; [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:NULL];
        if (!regular.boolValue || [names containsObject:url.lastPathComponent.lowercaseString]) return;
        [names addObject:url.lastPathComponent.lowercaseString]; [result addObject:PresetItem(url)];
    };
    // An explicitly imported file stays selected even if another pack has a copy.
    if (selectedURL) append(selectedURL);
    NSUInteger visited = 0;
    for (NSURL *directory in scan) {
        NSDirectoryEnumerator *iterator = [NSFileManager.defaultManager enumeratorAtURL:directory
            includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLIsSymbolicLinkKey]
            options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants errorHandler:nil];
        for (NSURL *url in iterator) {
            if (++visited > 20000 || result.count >= 512) break;
            NSNumber *link = nil; [url getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:NULL];
            if (link.boolValue) { [iterator skipDescendants]; continue; }
            append(url);
        }
        if (visited > 20000 || result.count >= 512) break;
    }
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *left = a[@"category"], *right = b[@"category"];
        if (![left isEqual:right]) {
            if ([left isEqual:@"Extravi"]) return NSOrderedAscending;
            if ([right isEqual:@"Extravi"]) return NSOrderedDescending;
            return [left localizedStandardCompare:right];
        }
        return [a[@"name"] localizedStandardCompare:b[@"name"]];
    }];
    return [result copy];
}

namespace {
NSColor *Accent() { return [NSColor colorWithSRGBRed:0.33 green:0.86 blue:0.76 alpha:1.0]; }
NSTextField *Text(NSString *text, CGFloat size, NSFontWeight weight = NSFontWeightRegular) {
    NSTextField *field = [NSTextField labelWithString:text ?: @""];
    field.font = [NSFont systemFontOfSize:size weight:weight];
    field.textColor = NSColor.labelColor;
    field.lineBreakMode = NSLineBreakByTruncatingTail;
    return field;
}
NSButton *GlassButton(NSString *title, id target, SEL action) {
    NSButton *button = [NSButton buttonWithTitle:title target:target action:action];
    button.bezelStyle = NSBezelStyleRegularSquare;
    button.bordered = NO;
    button.wantsLayer = YES;
    button.layer.cornerRadius = 8;
    if (@available(macOS 10.15, *)) button.layer.cornerCurve = kCACornerCurveContinuous;
    button.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.09].CGColor;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.18].CGColor;
    button.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    button.contentTintColor = [NSColor colorWithWhite:0.95 alpha:1.0];
    return button;
}
void StylePrimaryGlassButton(NSButton *button) {
    button.layer.backgroundColor = [NSColor colorWithSRGBRed:0.33 green:0.86 blue:0.76 alpha:0.14].CGColor;
    button.layer.borderColor = [NSColor colorWithSRGBRed:0.33 green:0.86 blue:0.76 alpha:0.38].CGColor;
    button.contentTintColor = Accent();
}
NSButton *Button(NSString *title, id target, SEL action) {
    return GlassButton(title, target, action);
}
NSScrollView *Scroller(void) {
    NSScrollView *scroll = [NSScrollView new];
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;
    scroll.borderType = NSNoBorder;
    return scroll;
}
NSString *NumberText(NSNumber *number) {
    return [NSString stringWithFormat:@"%.7g", number.doubleValue];
}
NSNumber *FirstNumber(id value) {
    if ([value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSArray.class] && [value count] && [value[0] isKindOfClass:NSNumber.class]) return value[0];
    return nil;
}
const char *kBuiltinNames[] = {"Exposure", "Contrast", "Saturation", "Vibrance", "Temperature",
                             "Tint", "Sharpen", "Bloom", "Vignette", "Grain"};
const double kBuiltinMinimum[] = {-4, 0, 0, -1, -1, -1, 0, 0, 0, 0};
const double kBuiltinMaximum[] = {4, 2, 2, 1, 1, 1, 2, 1, 1, 1};
const NSUInteger kBuiltinCount = sizeof(kBuiltinNames) / sizeof(kBuiltinNames[0]);
}

typedef NS_ENUM(NSInteger, MSOverlayDragZone) {
    MSOverlayDragZoneNone,
    MSOverlayDragZoneMove,
    MSOverlayDragZoneResizeLeft,
    MSOverlayDragZoneResizeRight,
    MSOverlayDragZoneResizeBottom,
    MSOverlayDragZoneResizeTop,
    MSOverlayDragZoneResizeBottomLeft,
    MSOverlayDragZoneResizeBottomRight,
    MSOverlayDragZoneResizeColumn
};

@interface MSOverlayFlippedView : NSView
@end
@implementation MSOverlayFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface MSOverlayRootView : MSOverlayFlippedView
@end
@implementation MSOverlayRootView
- (NSView *)hitTest:(NSPoint)point {
    NSView *hit = [super hitTest:point];
    return hit == self ? nil : hit;
}
@end

@interface MSGlassGripView : NSView
@property (nonatomic, assign) BOOL isLeftCorner;
@end
@implementation MSGlassGripView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    for (int i = 0; i < 3; ++i) {
        CGFloat d = 4.0 + i * 4.0;
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:1.0 alpha:0.35].CGColor);
        CGContextSetLineWidth(ctx, 1.0);
        if (_isLeftCorner) {
            CGContextMoveToPoint(ctx, d, h - 2);
            CGContextAddLineToPoint(ctx, 2, h - d);
        } else {
            CGContextMoveToPoint(ctx, w - d, h - 2);
            CGContextAddLineToPoint(ctx, w - 2, h - d);
        }
        CGContextStrokePath(ctx);
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:0.0 alpha:0.28].CGColor);
        if (_isLeftCorner) {
            CGContextMoveToPoint(ctx, d + 1, h - 2);
            CGContextAddLineToPoint(ctx, 2, h - d + 1);
        } else {
            CGContextMoveToPoint(ctx, w - d + 1, h - 2);
            CGContextAddLineToPoint(ctx, w - 2, h - d + 1);
        }
        CGContextStrokePath(ctx);
    }
}
@end

@interface MSGlassSeparator : NSView
@property (nonatomic, assign) BOOL vertical;
@end
@implementation MSGlassSeparator
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;
    if (_vertical) {
        CGContextSetFillColorWithColor(ctx, [NSColor colorWithWhite:1.0 alpha:0.15].CGColor);
        CGContextFillRect(ctx, CGRectMake(0, 0, 1, self.bounds.size.height));
        CGContextSetFillColorWithColor(ctx, [NSColor colorWithWhite:0.0 alpha:0.30].CGColor);
        CGContextFillRect(ctx, CGRectMake(1, 0, 1, self.bounds.size.height));
    } else {
        CGContextSetFillColorWithColor(ctx, [NSColor colorWithWhite:1.0 alpha:0.15].CGColor);
        CGContextFillRect(ctx, CGRectMake(0, 0, self.bounds.size.width, 1));
        CGContextSetFillColorWithColor(ctx, [NSColor colorWithWhite:0.0 alpha:0.30].CGColor);
        CGContextFillRect(ctx, CGRectMake(0, 1, self.bounds.size.width, 1));
    }
}
@end

@class MSOverlayController;

@interface MSOverlayCanvasView : MSOverlayFlippedView
@property (nonatomic, weak) MSOverlayController *controller;
@end

@interface MSOverlayController () <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate> {
    NSVisualEffectView *_card;
    MSOverlayCanvasView *_canvas;
    NSTextField *_brand;
    NSTextField *_preset;
    NSPopUpButton *_presetPopup;
    NSArray<NSDictionary *> *_presetItems;
    NSURL *_selectedPresetURL;
    NSView *_accent;
    MSGlassSeparator *_headerLine;
    MSGlassSeparator *_columnLine;
    MSGlassSeparator *_footerLine;
    MSGlassGripView *_gripBottomRight;
    MSGlassGripView *_gripBottomLeft;
    NSButton *_allEnabled;
    NSButton *_qualityButton;
    NSButton *_importButton;
    NSButton *_saveButton;
    NSButton *_hideButton;
    NSSegmentedControl *_listMode;
    NSSearchField *_search;
    NSScrollView *_listScroll;
    NSTableView *_table;
    NSTextField *_listEmpty;
    NSButton *_openButton;
    NSButton *_folderButton;
    NSButton *_upButton;
    NSButton *_downButton;
    NSButton *_removeButton;
    NSButton *_reloadButton;
    NSSegmentedControl *_inspectorMode;
    MSOverlayFlippedView *_effectPane;
    NSTextField *_effectTitle;
    NSTextField *_effectSubtitle;
    NSTextField *_techniqueLabel;
    NSPopUpButton *_techniques;
    NSScrollView *_parameterScroll;
    MSOverlayFlippedView *_parameterDocument;
    NSScrollView *_builtinScroll;
    MSOverlayFlippedView *_builtinDocument;
    NSMutableArray<NSSlider *> *_builtinSliders;
    NSMutableArray<NSTextField *> *_builtinInputs;
    NSProgressIndicator *_spinner;
    NSTextField *_status;
    NSTextField *_statusDetail;
    NSArray<NSDictionary *> *_library;
    NSArray<NSDictionary *> *_entries;
    NSArray<NSNumber *> *_visibleIndices;
    NSArray<NSNumber *> *_builtinValues;
    NSMutableArray<NSDictionary *> *_parameterRows;
    MSFXEffect *_inspectedEffect;
    NSURL *_inspectedURL;
    NSUInteger _selectedIndex;
    CGFloat _columnWidth;
    MSOverlayDragZone _dragZone;
    NSPoint _dragStartMouseScreen;
    NSRect _dragStartFrame;
    CGFloat _dragStartColumnWidth;
    BOOL _reloadingRows;
    BOOL _busy;
    BOOL _editingUniform;
    BOOL _buildingInspector;
}
- (CGFloat)columnSplitterX;
- (BOOL)isDragging;
- (void)startDragWithZone:(MSOverlayDragZone)zone event:(NSEvent *)event;
- (void)updateDragWithEvent:(NSEvent *)event;
- (void)endDrag;
@end

@implementation MSOverlayCanvasView

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    if (!ctx) return;
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    const CGFloat components[] = {
        1.0, 1.0, 1.0, 0.10,
        1.0, 1.0, 1.0, 0.02,
        0.05, 0.05, 0.05, 0.18,
        0.01, 0.01, 0.01, 0.38
    };
    const CGFloat locations[] = {0.0, 0.18, 0.65, 1.0};
    CGGradientRef grad = CGGradientCreateWithColorComponents(space, components, locations, 4);
    CGColorSpaceRelease(space);
    if (grad) {
        CGContextDrawLinearGradient(ctx, grad, CGPointMake(0, 0), CGPointMake(0, h), 0);
        CGGradientRelease(grad);
    }
    
    CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithWhite:1.0 alpha:0.32].CGColor);
    CGContextSetLineWidth(ctx, 1.0);
    CGContextMoveToPoint(ctx, 20, 1);
    CGContextAddLineToPoint(ctx, w - 20, 1);
    CGContextStrokePath(ctx);
}

- (MSOverlayDragZone)dragZoneForPoint:(NSPoint)pt {
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    if (pt.x >= w - 24 && pt.y >= h - 24) return MSOverlayDragZoneResizeBottomRight;
    if (pt.x <= 24 && pt.y >= h - 24) return MSOverlayDragZoneResizeBottomLeft;
    CGFloat colX = [self.controller columnSplitterX];
    if (std::abs(pt.x - colX) <= 6 && pt.y >= 85 && pt.y <= h - 60) return MSOverlayDragZoneResizeColumn;
    if (pt.x <= 6) return MSOverlayDragZoneResizeLeft;
    if (pt.x >= w - 6) return MSOverlayDragZoneResizeRight;
    if (pt.y >= h - 6) return MSOverlayDragZoneResizeBottom;
    if (pt.y <= 6) return MSOverlayDragZoneResizeTop;
    if (pt.y < 75) return MSOverlayDragZoneMove;
    return MSOverlayDragZoneNone;
}

- (void)resetCursorRects {
    [super resetCursorRects];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    if (w < 20 || h < 20) return;
    [self addCursorRect:NSMakeRect(w - 24, h - 24, 24, 24) cursor:[NSCursor crosshairCursor]];
    [self addCursorRect:NSMakeRect(0, h - 24, 24, 24) cursor:[NSCursor crosshairCursor]];
    CGFloat colX = [self.controller columnSplitterX];
    [self addCursorRect:NSMakeRect(colX - 4, 85, 8, MAX(10, h - 145)) cursor:[NSCursor resizeLeftRightCursor]];
    [self addCursorRect:NSMakeRect(0, 0, 6, h) cursor:[NSCursor resizeLeftRightCursor]];
    [self addCursorRect:NSMakeRect(w - 6, 0, 6, h) cursor:[NSCursor resizeLeftRightCursor]];
    [self addCursorRect:NSMakeRect(0, h - 6, w, 6) cursor:[NSCursor resizeUpDownCursor]];
    [self addCursorRect:NSMakeRect(0, 0, w, 6) cursor:[NSCursor resizeUpDownCursor]];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    MSOverlayDragZone zone = [self dragZoneForPoint:pt];
    if (zone != MSOverlayDragZoneNone) {
        [self.controller startDragWithZone:zone event:event];
    } else {
        [super mouseDown:event];
    }
}

- (void)mouseDragged:(NSEvent *)event {
    if ([self.controller isDragging]) {
        [self.controller updateDragWithEvent:event];
    } else {
        [super mouseDragged:event];
    }
}

- (void)mouseUp:(NSEvent *)event {
    if ([self.controller isDragging]) {
        [self.controller endDrag];
    } else {
        [super mouseUp:event];
    }
}

@end

@implementation MSOverlayController
- (void)loadView {
    self.view = [[MSOverlayRootView alloc] initWithFrame:NSMakeRect(0, 0, 860, 640)];
    _library = _library ?: @[];
    _entries = _entries ?: @[];
    _visibleIndices = @[];
    _parameterRows = [NSMutableArray array];
    _builtinSliders = [NSMutableArray array];
    _builtinInputs = [NSMutableArray array];
    _selectedIndex = NSNotFound;
    _columnWidth = 260.0;
    _dragZone = MSOverlayDragZoneNone;
    
    _card = [NSVisualEffectView new];
    _card.material = NSVisualEffectMaterialFullScreenUI;
    _card.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    _card.state = NSVisualEffectStateActive;
    _card.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    _card.wantsLayer = YES;
    _card.layer.cornerRadius = 20;
    if (@available(macOS 10.15, *)) _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.layer.borderWidth = 1.0;
    _card.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.22].CGColor;
    _card.layer.masksToBounds = NO;
    _card.layer.shadowColor = [NSColor blackColor].CGColor;
    _card.layer.shadowOpacity = 0.65;
    _card.layer.shadowRadius = 32.0;
    _card.layer.shadowOffset = CGSizeMake(0, -10);
    [self.view addSubview:_card];
    
    _canvas = [MSOverlayCanvasView new];
    _canvas.controller = self;
    _canvas.wantsLayer = YES;
    _canvas.layer.cornerRadius = 20;
    if (@available(macOS 10.15, *)) _canvas.layer.cornerCurve = kCACornerCurveContinuous;
    _canvas.layer.masksToBounds = YES;
    [_card addSubview:_canvas];
    
    _accent = [NSView new];
    _accent.wantsLayer = YES;
    _accent.layer.backgroundColor = Accent().CGColor;
    _accent.layer.cornerRadius = 3.5;
    _accent.layer.shadowColor = Accent().CGColor;
    _accent.layer.shadowOpacity = 0.95;
    _accent.layer.shadowRadius = 8;
    _accent.layer.shadowOffset = CGSizeZero;
    [_canvas addSubview:_accent];
    
    _brand = Text(@"MacShade", 22, NSFontWeightSemibold);
    [_canvas addSubview:_brand];
    _preset = Text(@"Untitled preset", 11);
    _preset.textColor = NSColor.secondaryLabelColor;
    [_canvas addSubview:_preset];
    
    _presetPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(36, 42, 220, 24) pullsDown:NO];
    _presetPopup.bezelStyle = NSBezelStyleRegularSquare;
    _presetPopup.bordered = NO;
    _presetPopup.wantsLayer = YES;
    _presetPopup.layer.cornerRadius = 6.0;
    if (@available(macOS 10.15, *)) _presetPopup.layer.cornerCurve = kCACornerCurveContinuous;
    _presetPopup.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.10].CGColor;
    _presetPopup.layer.borderWidth = 1.0;
    _presetPopup.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.20].CGColor;
    _presetPopup.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    _presetPopup.target = self;
    _presetPopup.action = @selector(presetPopupAction:);
    _presetPopup.toolTip = @"Select a ReShade preset";
    [_canvas addSubview:_presetPopup];
    
    _allEnabled = [NSButton checkboxWithTitle:@"Effects on" target:self action:@selector(toggleAllAction:)];
    _allEnabled.state = NSControlStateValueOn;
    _allEnabled.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    _allEnabled.contentTintColor = Accent();
    [_canvas addSubview:_allEnabled];

    _qualityButton = Button(@"100% (FQ)", self, @selector(qualityAction:));
    _qualityButton.toolTip = @"Rendering resolution quality for shader pipeline (100%/FQ -> 75% -> 50%)\nLower resolution dramatically increases framerates on less powerful Macs.";
    StylePrimaryGlassButton(_qualityButton);
    [_canvas addSubview:_qualityButton];
    
    _importButton = Button(@"Import preset", self, @selector(importAction:));
    _importButton.toolTip = @"Import a ReShade .ini preset";
    StylePrimaryGlassButton(_importButton);
    [_canvas addSubview:_importButton];
    
    _saveButton = Button(@"Save preset", self, @selector(saveAction:));
    StylePrimaryGlassButton(_saveButton);
    [_canvas addSubview:_saveButton];
    
    _hideButton = Button(@"Hide", self, @selector(hideAction:));
    _hideButton.toolTip = @"Hide the controls and return to the scene";
    [_canvas addSubview:_hideButton];
    
    _headerLine = [MSGlassSeparator new]; _headerLine.vertical = NO; [_canvas addSubview:_headerLine];
    _columnLine = [MSGlassSeparator new]; _columnLine.vertical = YES; [_canvas addSubview:_columnLine];
    _footerLine = [MSGlassSeparator new]; _footerLine.vertical = NO; [_canvas addSubview:_footerLine];
    
    _gripBottomRight = [MSGlassGripView new]; _gripBottomRight.isLeftCorner = NO; [_canvas addSubview:_gripBottomRight];
    _gripBottomLeft = [MSGlassGripView new]; _gripBottomLeft.isLeftCorner = YES; [_canvas addSubview:_gripBottomLeft];

    _listMode = [NSSegmentedControl segmentedControlWithLabels:@[@"Library", @"Effects"]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(listModeAction:)];
    _listMode.selectedSegment = 0;
    _listMode.segmentStyle = NSSegmentStyleTexturedRounded;
    [_canvas addSubview:_listMode];
    
    _search = [NSSearchField new];
    _search.placeholderString = @"Search effects";
    _search.delegate = self;
    _search.sendsSearchStringImmediately = YES;
    _search.accessibilityLabel = @"Search effect library";
    _search.wantsLayer = YES;
    _search.layer.cornerRadius = 8;
    if (@available(macOS 10.15, *)) _search.layer.cornerCurve = kCACornerCurveContinuous;
    _search.layer.backgroundColor = [NSColor colorWithWhite:1.0 alpha:0.06].CGColor;
    _search.layer.borderWidth = 1.0;
    _search.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.14].CGColor;
    [_canvas addSubview:_search];
    
    _listScroll = Scroller();
    _table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 236, 320)];
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"effect"];
    column.width = 236;
    column.resizingMask = NSTableColumnAutoresizingMask;
    [_table addTableColumn:column];
    _table.headerView = nil;
    _table.backgroundColor = NSColor.clearColor;
    _table.rowHeight = 62;
    _table.intercellSpacing = NSMakeSize(0, 3);
    _table.style = NSTableViewStylePlain;
    _table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    _table.dataSource = self;
    _table.delegate = self;
    _table.target = self;
    _table.doubleAction = @selector(doubleClickEffect:);
    _table.accessibilityLabel = @"Effects";
    _listScroll.documentView = _table;
    [_canvas addSubview:_listScroll];
    
    _listEmpty = Text(@"Your effect library starts here.\nOpen an .fx file or add a folder.", 12);
    _listEmpty.maximumNumberOfLines = 3;
    _listEmpty.lineBreakMode = NSLineBreakByWordWrapping;
    _listEmpty.textColor = NSColor.secondaryLabelColor;
    [_canvas addSubview:_listEmpty];
    
    _openButton = Button(@"Open .fx…", self, @selector(openAction:));
    _folderButton = Button(@"Add folder…", self, @selector(folderAction:));
    _upButton = Button(@"↑", self, @selector(moveUpAction:));
    _upButton.accessibilityLabel = @"Move selected effect earlier";
    _downButton = Button(@"↓", self, @selector(moveDownAction:));
    _downButton.accessibilityLabel = @"Move selected effect later";
    _removeButton = Button(@"Remove", self, @selector(removeAction:));
    _reloadButton = Button(@"Reload", self, @selector(reloadAction:));
    for (NSButton *button in @[_openButton, _folderButton, _upButton, _downButton, _removeButton, _reloadButton])
        [_canvas addSubview:button];

    _inspectorMode = [NSSegmentedControl segmentedControlWithLabels:@[@"Effect controls", @"Built-in look"]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(inspectorModeAction:)];
    _inspectorMode.selectedSegment = 0;
    _inspectorMode.segmentStyle = NSSegmentStyleTexturedRounded;
    [_canvas addSubview:_inspectorMode];
    
    _effectPane = [MSOverlayFlippedView new];
    [_canvas addSubview:_effectPane];
    _effectTitle = Text(@"Make the scene yours", 19, NSFontWeightSemibold);
    [_effectPane addSubview:_effectTitle];
    _effectSubtitle = Text(@"Add an effect from your library to get started.", 11);
    _effectSubtitle.textColor = NSColor.secondaryLabelColor;
    [_effectPane addSubview:_effectSubtitle];
    _techniqueLabel = Text(@"Technique", 11, NSFontWeightMedium);
    _techniqueLabel.textColor = NSColor.secondaryLabelColor;
    [_effectPane addSubview:_techniqueLabel];
    _techniques = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _techniques.target = self;
    _techniques.action = @selector(techniqueAction:);
    _techniques.accessibilityLabel = @"Active technique";
    [_effectPane addSubview:_techniques];
    
    _parameterScroll = Scroller();
    _parameterDocument = [MSOverlayFlippedView new];
    _parameterDocument.autoresizingMask = NSViewWidthSizable;
    _parameterScroll.documentView = _parameterDocument;
    [_effectPane addSubview:_parameterScroll];
    
    _builtinScroll = Scroller();
    _builtinDocument = [MSOverlayFlippedView new];
    _builtinDocument.autoresizingMask = NSViewWidthSizable;
    _builtinScroll.documentView = _builtinDocument;
    [_canvas addSubview:_builtinScroll];

    _spinner = [NSProgressIndicator new];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.displayedWhenStopped = NO;
    [_canvas addSubview:_spinner];
    _status = Text(@"Ready to shape your scene", 12, NSFontWeightMedium);
    [_canvas addSubview:_status];
    _statusDetail = Text(@"All changes preview live. Save a preset to keep your look.", 11);
    _statusDetail.textColor = NSColor.secondaryLabelColor;
    [_canvas addSubview:_statusDetail];
    
    [self layoutOverlay];
    [self buildBuiltinControls];
    [self rebuildInspector];
    [self reloadRows];
    [self inspectorModeAction:nil];
}

- (void)viewDidLayout { [super viewDidLayout]; [self layoutOverlay]; }

- (CGFloat)columnSplitterX {
    return _columnLine ? NSMidX(_columnLine.frame) : (_columnWidth + 20.0);
}

- (BOOL)isDragging {
    return _dragZone != MSOverlayDragZoneNone;
}

- (void)startDragWithZone:(MSOverlayDragZone)zone event:(NSEvent *)event {
    _dragZone = zone;
    _dragStartMouseScreen = [event.window convertPointToScreen:event.locationInWindow];
    _dragStartFrame = self.view.frame;
    _dragStartColumnWidth = _columnWidth;
}

- (void)updateDragWithEvent:(NSEvent *)event {
    if (_dragZone == MSOverlayDragZoneNone) return;
    NSPoint currentScreen = [event.window convertPointToScreen:event.locationInWindow];
    CGFloat screenDx = currentScreen.x - _dragStartMouseScreen.x;
    CGFloat screenDy = currentScreen.y - _dragStartMouseScreen.y;
    
    if (_dragZone == MSOverlayDragZoneResizeColumn) {
        CGFloat maxCol = std::min((CGFloat)self.view.bounds.size.width - 240.0, (CGFloat)440.0);
        _columnWidth = std::clamp(_dragStartColumnWidth + screenDx, (CGFloat)180.0, maxCol);
        [self layoutOverlay];
        return;
    }
    
    NSView *superview = self.view.superview;
    if (!superview) return;
    BOOL superFlipped = superview.isFlipped;
    
    NSRect frame = _dragStartFrame;
    CGFloat minW = 500.0, maxW = MAX(minW, superview.bounds.size.width - 20.0);
    CGFloat minH = 360.0, maxH = MAX(minH, superview.bounds.size.height - 20.0);
    
    switch (_dragZone) {
        case MSOverlayDragZoneMove:
            frame.origin.x = _dragStartFrame.origin.x + screenDx;
            frame.origin.y = superFlipped ? (_dragStartFrame.origin.y - screenDy) : (_dragStartFrame.origin.y + screenDy);
            break;
        case MSOverlayDragZoneResizeRight:
            frame.size.width = std::clamp(_dragStartFrame.size.width + screenDx, minW, maxW);
            break;
        case MSOverlayDragZoneResizeLeft: {
            CGFloat targetW = std::clamp(_dragStartFrame.size.width - screenDx, minW, maxW);
            CGFloat actualDx = _dragStartFrame.size.width - targetW;
            frame.size.width = targetW;
            frame.origin.x = _dragStartFrame.origin.x + actualDx;
            break;
        }
        case MSOverlayDragZoneResizeBottom:
            if (superFlipped) {
                frame.size.height = std::clamp(_dragStartFrame.size.height - screenDy, minH, maxH);
            } else {
                CGFloat targetH = std::clamp(_dragStartFrame.size.height - screenDy, minH, maxH);
                CGFloat actualDy = _dragStartFrame.size.height - targetH;
                frame.size.height = targetH;
                frame.origin.y = _dragStartFrame.origin.y + actualDy;
            }
            break;
        case MSOverlayDragZoneResizeTop:
            if (superFlipped) {
                CGFloat targetH = std::clamp(_dragStartFrame.size.height + screenDy, minH, maxH);
                CGFloat actualDy = _dragStartFrame.size.height - targetH;
                frame.size.height = targetH;
                frame.origin.y = _dragStartFrame.origin.y - actualDy;
            } else {
                frame.size.height = std::clamp(_dragStartFrame.size.height + screenDy, minH, maxH);
            }
            break;
        case MSOverlayDragZoneResizeBottomRight:
            frame.size.width = std::clamp(_dragStartFrame.size.width + screenDx, minW, maxW);
            if (superFlipped) {
                frame.size.height = std::clamp(_dragStartFrame.size.height - screenDy, minH, maxH);
            } else {
                CGFloat targetH = std::clamp(_dragStartFrame.size.height - screenDy, minH, maxH);
                CGFloat actualDy = _dragStartFrame.size.height - targetH;
                frame.size.height = targetH;
                frame.origin.y = _dragStartFrame.origin.y + actualDy;
            }
            break;
        case MSOverlayDragZoneResizeBottomLeft: {
            CGFloat targetW = std::clamp(_dragStartFrame.size.width - screenDx, minW, maxW);
            CGFloat actualDx = _dragStartFrame.size.width - targetW;
            frame.size.width = targetW;
            frame.origin.x = _dragStartFrame.origin.x + actualDx;
            if (superFlipped) {
                frame.size.height = std::clamp(_dragStartFrame.size.height - screenDy, minH, maxH);
            } else {
                CGFloat targetH = std::clamp(_dragStartFrame.size.height - screenDy, minH, maxH);
                CGFloat actualDy = _dragStartFrame.size.height - targetH;
                frame.size.height = targetH;
                frame.origin.y = _dragStartFrame.origin.y + actualDy;
            }
            break;
        }
        default:
            break;
    }
    
    if (superview.bounds.size.width > frame.size.width) {
        frame.origin.x = std::clamp(frame.origin.x, (CGFloat)10.0, (CGFloat)(superview.bounds.size.width - frame.size.width - 10.0));
    }
    if (superview.bounds.size.height > frame.size.height) {
        frame.origin.y = std::clamp(frame.origin.y, (CGFloat)10.0, (CGFloat)(superview.bounds.size.height - frame.size.height - 10.0));
    }
    
    self.view.frame = frame;
    [self layoutOverlay];
}

- (void)endDrag {
    _dragZone = MSOverlayDragZoneNone;
}

- (void)layoutOverlay {
    _card.frame = NSInsetRect(self.view.bounds, 12, 12);
    _canvas.frame = _card.bounds;
    CGFloat w = _canvas.bounds.size.width, h = _canvas.bounds.size.height;
    if (w < 200 || h < 200) return;
    
    CGFloat colW = std::clamp(_columnWidth, (CGFloat)180.0, (CGFloat)std::min(w - 240.0, 440.0));
    CGFloat rightX = colW + 36.0;
    CGFloat rightW = MAX(240.0, w - rightX - 20.0);
    
    // Header layout: right-to-left
    CGFloat btnY = 18;
    CGFloat rx = w - 20;
    
    _hideButton.frame = NSMakeRect(rx - 60, btnY, 60, 28);
    rx -= 68;
    
    _saveButton.frame = NSMakeRect(rx - 96, btnY, 96, 28);
    _saveButton.title = w < 640 ? @"Save" : @"Save preset";
    rx -= 104;
    
    _importButton.frame = NSMakeRect(rx - 104, btnY, 104, 28);
    _importButton.title = w < 640 ? @"Import" : @"Import preset";
    rx -= 112;

    _qualityButton.frame = NSMakeRect(rx - 92, btnY, 92, 28);
    rx -= 100;
    
    _allEnabled.frame = NSMakeRect(rx - 96, btnY + 2, 96, 24);
    _allEnabled.title = w < 640 ? (_allEnabled.state == NSControlStateValueOn ? @"On" : @"Off")
                                : (_allEnabled.state == NSControlStateValueOn ? @"Effects on" : @"Effects off");
    rx -= 104;
    
    // Brand & preset
    _accent.frame = NSMakeRect(20, 26, 7, 7);
    CGFloat brandMaxW = MAX(100.0, rx - 36);
    _brand.frame = NSMakeRect(36, 14, MIN(160.0, brandMaxW), 26);
    CGFloat popupW = MIN(260.0, MAX(140.0, rx - 48));
    _presetPopup.frame = NSMakeRect(36, 42, popupW, 25);
    _preset.frame = NSMakeRect(36 + popupW + 8, 46, MAX(0.0, rx - (36 + popupW + 8)), 18);
    _preset.hidden = YES;
    
    // Separators
    _headerLine.frame = NSMakeRect(20, 78, w - 40, 2);
    _columnLine.frame = NSMakeRect(colW + 18, 92, 2, MAX(100, h - 165));
    _footerLine.frame = NSMakeRect(20, h - 66, w - 40, 2);
    
    // Left column
    _listMode.frame = NSMakeRect(20, 92, colW - 4, 28);
    _search.frame = NSMakeRect(20, 128, colW - 4, 26);
    _listScroll.frame = NSMakeRect(16, 162, colW + 4, MAX(80, h - 276));
    if (_table.tableColumns.count) _table.tableColumns[0].width = _listScroll.contentSize.width;
    _table.frame = NSMakeRect(0, 0, _listScroll.contentSize.width, MAX(_listScroll.contentSize.height, _visibleIndices.count * 65.0));
    _listEmpty.frame = NSMakeRect(28, 180, colW - 20, 72);
    
    CGFloat bY = h - 105;
    CGFloat halfW = (colW - 8) / 2.0;
    _openButton.frame = NSMakeRect(18, bY, halfW, 28);
    _folderButton.frame = NSMakeRect(18 + halfW + 4, bY, halfW, 28);
    
    CGFloat unit = (colW - 12) / 4.0;
    _upButton.frame = NSMakeRect(18, bY, unit, 28);
    _downButton.frame = NSMakeRect(18 + unit + 4, bY, unit, 28);
    _removeButton.frame = NSMakeRect(18 + (unit + 4) * 2, bY, unit + 2, 28);
    _reloadButton.frame = NSMakeRect(18 + (unit + 4) * 3 + 2, bY, unit + 2, 28);
    
    // Right column
    _inspectorMode.frame = NSMakeRect(rightX, 92, rightW, 28);
    NSRect body = NSMakeRect(rightX, 132, rightW, MAX(180, h - 208));
    _effectPane.frame = body;
    _effectTitle.frame = NSMakeRect(0, 0, rightW, 25);
    _effectSubtitle.frame = NSMakeRect(0, 28, rightW, 18);
    _techniqueLabel.frame = NSMakeRect(0, 58, 70, 18);
    _techniques.frame = NSMakeRect(74, 52, MAX(120, rightW - 74), 28);
    _parameterScroll.frame = NSMakeRect(0, 90, rightW, MAX(60, body.size.height - 90));
    _parameterDocument.frame = NSMakeRect(0, 0, _parameterScroll.contentSize.width,
        MAX(_parameterDocument.frame.size.height, _parameterScroll.contentSize.height));
    _builtinScroll.frame = body;
    _builtinDocument.frame = NSMakeRect(0, 0, _builtinScroll.contentSize.width, MAX(820, body.size.height));
    
    // Bottom status bar & resize grips
    _spinner.frame = NSMakeRect(30, h - 46, 16, 16);
    _status.frame = NSMakeRect(54, h - 54, MAX(100, w - 100), 20);
    _statusDetail.frame = NSMakeRect(54, h - 33, MAX(100, w - 100), 18);
    
    _gripBottomRight.frame = NSMakeRect(w - 22, h - 22, 18, 18);
    _gripBottomLeft.frame = NSMakeRect(4, h - 22, 18, 18);
}

- (void)updateLibrary:(NSArray<NSDictionary *> *)library {
    (void)self.view;
    _library = [library copy];
    [self reloadRows];
}

- (void)updateEntries:(NSArray<NSDictionary *> *)entries selectedIndex:(NSUInteger)index {
    (void)self.view;
    _entries = [entries copy];
    _selectedIndex = index < entries.count ? index : NSNotFound;
    NSUInteger activeCount = 0;
    for (NSDictionary *e in entries) if ([e[@"enabled"] boolValue]) activeCount++;
    if (activeCount == entries.count) {
        [_listMode setLabel:[NSString stringWithFormat:@"Effects (%lu)", (unsigned long)entries.count] forSegment:1];
    } else {
        [_listMode setLabel:[NSString stringWithFormat:@"Effects (%lu/%lu)", (unsigned long)activeCount, (unsigned long)entries.count] forSegment:1];
    }
    [self reloadRows];
    MSFXEffect *effect = _selectedIndex == NSNotFound ? nil : _entries[_selectedIndex][@"effect"];
    NSURL *url = _selectedIndex == NSNotFound ? nil : _entries[_selectedIndex][@"url"];
    if (effect != _inspectedEffect || (url != _inspectedURL && ![url isEqual:_inspectedURL])) {
        _inspectedEffect = effect;
        _inspectedURL = url;
        [self rebuildInspector];
    } else if (effect) {
        [_techniques selectItemWithTitle:effect.activeTechnique];
        if (!_editingUniform) [self refreshParameterValues];
    } else if (url) {
        [self rebuildInspector];
    }
    [self updateInteractions];
}

- (void)reloadRows {
    NSString *query = [_search.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL inEffectsTab = _listMode.selectedSegment == 1;
    NSArray *source = inEffectsTab ? _entries : _library;
    NSMutableArray *indices = [NSMutableArray array];
    if (inEffectsTab) {
        NSMutableArray *activeIndices = [NSMutableArray array];
        NSMutableArray *inactiveIndices = [NSMutableArray array];
        for (NSUInteger i = 0; i < source.count; ++i) {
            NSDictionary *entry = source[i];
            NSURL *url = entry[@"url"];
            NSString *name = entry[@"name"] ?: url.lastPathComponent ?: @"Effect";
            NSString *detail = [entry[@"effect"] activeTechnique] ?: entry[@"technique"] ?: @"Not yet enabled";
            if (!query.length || [name localizedCaseInsensitiveContainsString:query] ||
                [detail localizedCaseInsensitiveContainsString:query]) {
                if ([entry[@"enabled"] boolValue]) {
                    [activeIndices addObject:@(i)];
                } else {
                    [inactiveIndices addObject:@(i)];
                }
            }
        }
        [indices addObjectsFromArray:activeIndices];
        [indices addObjectsFromArray:inactiveIndices];
    } else {
        for (NSUInteger i = 0; i < source.count; ++i) {
            NSDictionary *entry = source[i];
            NSURL *url = entry[@"url"];
            NSString *name = entry[@"name"] ?: url.lastPathComponent ?: @"Effect";
            NSString *detail = entry[@"subtitle"] ?: @"";
            if (!query.length || [name localizedCaseInsensitiveContainsString:query] ||
                [detail localizedCaseInsensitiveContainsString:query]) [indices addObject:@(i)];
        }
    }
    _visibleIndices = indices;
    _reloadingRows = YES;
    [_table reloadData];
    if (inEffectsTab && _selectedIndex != NSNotFound) {
        NSUInteger row = [_visibleIndices indexOfObject:@(_selectedIndex)];
        if (row != NSNotFound) [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        else [_table deselectAll:nil];
    }
    _reloadingRows = NO;
    _listEmpty.hidden = indices.count > 0;
    _listEmpty.stringValue = query.length ? @"No matching effects.\nTry a different search." : inEffectsTab
        ? @"No effects selected.\nAdd an effect from the Library tab."
        : @"Your effect library starts here.\nOpen an .fx file or add a folder.";
    [self updateInteractions];
    [self layoutOverlay];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { (void)tableView; return (NSInteger)_visibleIndices.count; }
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    (void)tableColumn;
    NSUInteger index = _visibleIndices[(NSUInteger)row].unsignedIntegerValue;
    BOOL inEffectsTab = _listMode.selectedSegment == 1;
    NSDictionary *entry = (inEffectsTab ? _entries : _library)[index];
    NSURL *url = entry[@"url"];
    CGFloat width = tableView.tableColumns[0].width;
    NSTableCellView *cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, width, 62)];
    NSString *name = entry[@"name"] ?: url.lastPathComponent ?: @"Effect";
    BOOL isEnabled = inEffectsTab && [entry[@"enabled"] boolValue];
    if (inEffectsTab) {
        if (isEnabled) {
            NSUInteger activeRank = 0;
            for (NSUInteger i = 0; i < index; ++i) {
                if ([_entries[i][@"enabled"] boolValue]) ++activeRank;
            }
            name = [NSString stringWithFormat:@"%02lu  %@", (unsigned long)activeRank + 1, name];
        } else {
            name = [NSString stringWithFormat:@"--  %@", name];
        }
    }
    NSTextField *title = Text(name, 12, NSFontWeightMedium);
    title.frame = NSMakeRect(9, 31, width - 47, 20);
    title.autoresizingMask = NSViewWidthSizable;
    title.toolTip = url.path;
    if (inEffectsTab && !isEnabled) {
        title.textColor = NSColor.secondaryLabelColor;
    }
    [cell addSubview:title]; cell.textField = title;
    NSString *detail = inEffectsTab ? ([entry[@"effect"] activeTechnique] ?: entry[@"technique"] ?: @"Not yet enabled") : (entry[@"subtitle"] ?: @"ReShade effect");
    NSTextField *subtitle = Text(detail, 10);
    subtitle.textColor = (inEffectsTab && !isEnabled) ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor;
    subtitle.frame = NSMakeRect(9, 10, width - 47, 16);
    subtitle.autoresizingMask = NSViewWidthSizable;
    [cell addSubview:subtitle];
    NSButton *action;
    if (inEffectsTab) {
        action = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleEntryAction:)];
        action.state = isEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        action.accessibilityLabel = [NSString stringWithFormat:@"Enable %@", url.lastPathComponent];
        action.contentTintColor = Accent();
        action.frame = NSMakeRect(width - 30, 19, 24, 24);
    } else {
        action = Button(@"+", self, @selector(addLibraryAction:));
        action.frame = NSMakeRect(width - 37, 16, 31, 30);
        action.contentTintColor = Accent();
        action.accessibilityLabel = [NSString stringWithFormat:@"Add %@", name];
        action.toolTip = @"Add this effect to the end of the chain";
    }
    action.autoresizingMask = NSViewMinXMargin;
    action.tag = (NSInteger)index;
    action.enabled = !_busy;
    [cell addSubview:action];
    return cell;
}
- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    if (_reloadingRows || _busy || _listMode.selectedSegment != 1 || _table.selectedRow < 0) return;
    NSUInteger index = _visibleIndices[(NSUInteger)_table.selectedRow].unsignedIntegerValue;
    if (self.selectEntry) self.selectEntry(index);
}

- (void)updateInteractions {
    BOOL inEffectsTab = _listMode.selectedSegment == 1;
    BOOL selected = _selectedIndex < _entries.count;
    _openButton.hidden = inEffectsTab; _folderButton.hidden = inEffectsTab;
    for (NSButton *button in @[_upButton, _downButton, _removeButton, _reloadButton]) button.hidden = !inEffectsTab;
    _openButton.enabled = !_busy; _folderButton.enabled = !_busy;
    _importButton.enabled = !_busy; _saveButton.enabled = !_busy;
    _qualityButton.enabled = !_busy;
    _presetPopup.enabled = !_busy;

    BOOL canMoveUp = NO;
    BOOL canMoveDown = NO;
    if (selected && !_busy) {
        BOOL isEntryActive = [_entries[_selectedIndex][@"enabled"] boolValue];
        if (isEntryActive) {
            canMoveUp = _selectedIndex > 0;
            canMoveDown = (_selectedIndex + 1 < _entries.count) && [_entries[_selectedIndex + 1][@"enabled"] boolValue];
        } else {
            canMoveUp = (_selectedIndex > 0) && ![_entries[_selectedIndex - 1][@"enabled"] boolValue];
            canMoveDown = _selectedIndex + 1 < _entries.count;
        }
    }
    _upButton.enabled = canMoveUp;
    _downButton.enabled = canMoveDown;
    _removeButton.enabled = selected && !_busy;
    _reloadButton.enabled = _entries.count > 0 && !_busy;
    _techniques.enabled = _inspectedEffect != nil && !_busy;
    _search.placeholderString = inEffectsTab ? @"Search selected effects" : @"Search effects";
    _search.accessibilityLabel = inEffectsTab ? @"Search selected effects" : @"Search effect library";
}

- (void)rebuildInspector {
    _buildingInspector = YES;
    for (NSView *view in [_parameterDocument.subviews copy]) [view removeFromSuperview];
    [_parameterRows removeAllObjects];
    [_techniques removeAllItems];
    _techniques.hidden = !_inspectedEffect; _techniqueLabel.hidden = !_inspectedEffect;
    CGFloat width = MAX(280, _parameterScroll.contentSize.width - 12);
    if (!_inspectedEffect) {
        NSDictionary *entry = _selectedIndex < _entries.count ? _entries[_selectedIndex] : nil;
        NSURL *url = entry[@"url"];
        _effectTitle.stringValue = url.lastPathComponent ?: @"Make the scene yours";
        _effectSubtitle.stringValue = entry
            ? [NSString stringWithFormat:@"Disabled · %@", entry[@"technique"] ?: @"Not yet compiled"]
            : @"Add an effect from your library to get started.";
        NSTextField *empty = Text(entry ? @"Enable this effect to adjust its parameters" : @"Your controls will appear here", 16, NSFontWeightMedium);
        empty.frame = NSMakeRect(0, 24, width, 24); empty.autoresizingMask = NSViewWidthSizable;
        [_parameterDocument addSubview:empty];
        NSTextField *detail = Text(entry
            ? @"This effect is saved in your preset but has not been compiled. Enable it here or in the Effects tab to load its controls."
            : @"Build an ordered chain of .fx effects, then adjust each look live. Use Import preset to load a ReShade .ini file.", 12);
        detail.textColor = NSColor.secondaryLabelColor; detail.maximumNumberOfLines = 4;
        detail.lineBreakMode = NSLineBreakByWordWrapping;
        detail.frame = NSMakeRect(0, 63, width, 76); detail.autoresizingMask = NSViewWidthSizable;
        [_parameterDocument addSubview:detail];
        NSButton *open = Button(entry ? @"Enable effect" : @"Open an effect…", self,
                                entry ? @selector(enableSelectedAction:) : @selector(openAction:));
        open.frame = NSMakeRect(-4, 155, 154, 32); [_parameterDocument addSubview:open];
        _parameterDocument.frame = NSMakeRect(0, 0, width + 12, MAX(220, _parameterScroll.contentSize.height));
        _buildingInspector = NO;
        return;
    }
    NSURL *url = _entries[_selectedIndex][@"url"];
    _effectTitle.stringValue = url.lastPathComponent ?: @"Effect controls";
    _effectTitle.toolTip = url.path;
    _effectSubtitle.stringValue = @"Adjust live · use Reset to restore an individual parameter";
    [_techniques addItemsWithTitles:_inspectedEffect.techniqueNames];
    [_techniques selectItemWithTitle:_inspectedEffect.activeTechnique];
    CGFloat y = 0;
    for (NSDictionary *metadata in _inspectedEffect.uniforms) {
        NSString *name = metadata[@"name"];
        NSString *label = [metadata[@"uiLabel"] length] ? metadata[@"uiLabel"] : name;
        NSString *source = metadata[@"source"] ?: @"";
        NSString *type = metadata[@"type"] ?: @"float";
        NSUInteger components = [metadata[@"components"] unsignedIntegerValue];
        NSArray<NSNumber *> *values = metadata[@"values"];
        BOOL dynamic = source.length > 0;
        NSArray *items = metadata[@"uiItems"];
        if (![items isKindOfClass:NSArray.class]) items = @[];
        NSNumber *minimum = FirstNumber(metadata[@"uiMin"]), *maximum = FirstNumber(metadata[@"uiMax"]);
        BOOL range = components == 1 && minimum && maximum && std::isfinite(minimum.doubleValue) &&
                     std::isfinite(maximum.doubleValue) && minimum.doubleValue < maximum.doubleValue;
        BOOL boolean = components == 1 && [type hasPrefix:@"bool"];
        NSString *uiType = [metadata[@"uiType"] lowercaseString] ?: @"";
        BOOL choice = components == 1 && items.count && ([uiType isEqualToString:@"combo"] || [uiType isEqualToString:@"radio"]);
        CGFloat rowHeight = dynamic ? 74 : 84;
        NSView *row = [[MSOverlayFlippedView alloc] initWithFrame:NSMakeRect(0, y, width, rowHeight)];
        row.autoresizingMask = NSViewWidthSizable;
        NSTextField *title = Text(label, 12, NSFontWeightMedium);
        title.frame = NSMakeRect(0, 0, width - 61, 20); title.autoresizingMask = NSViewWidthSizable;
        title.toolTip = [metadata[@"uiTooltip"] length] ? metadata[@"uiTooltip"] : name;
        [row addSubview:title];
        NSUInteger index = _parameterRows.count;
        NSMutableDictionary *controls = [NSMutableDictionary dictionaryWithDictionary:@{@"metadata":metadata}];
        if (dynamic) {
            NSTextField *automatic = Text([NSString stringWithFormat:@"Automatic · %@ source", source], 11);
            automatic.textColor = NSColor.secondaryLabelColor;
            automatic.frame = NSMakeRect(0, 29, width, 21); automatic.autoresizingMask = NSViewWidthSizable;
            automatic.toolTip = @"This parameter is supplied by the renderer and cannot be changed manually.";
            [row addSubview:automatic];
        } else {
            NSButton *reset = Button(@"Reset", self, @selector(resetUniformAction:));
            reset.controlSize = NSControlSizeSmall; reset.font = [NSFont systemFontOfSize:10];
            reset.frame = NSMakeRect(width - 58, -3, 61, 25); reset.autoresizingMask = NSViewMinXMargin;
            reset.tag = (NSInteger)index; reset.enabled = [metadata[@"defaultValues"] count] == components;
            reset.accessibilityLabel = [@"Reset " stringByAppendingString:label];
            [row addSubview:reset];
            if (boolean) {
                NSButton *checkbox = [NSButton checkboxWithTitle:@"Enabled" target:self action:@selector(boolUniformAction:)];
                checkbox.frame = NSMakeRect(0, 31, width, 24); checkbox.autoresizingMask = NSViewWidthSizable;
                checkbox.state = [values.firstObject boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
                checkbox.tag = (NSInteger)index; checkbox.contentTintColor = Accent(); checkbox.accessibilityLabel = label;
                [row addSubview:checkbox]; controls[@"checkbox"] = checkbox;
            } else if (choice) {
                NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(-2, 28, width + 4, 30) pullsDown:NO];
                popup.autoresizingMask = NSViewWidthSizable; [popup addItemsWithTitles:items];
                NSInteger choiceIndex = [values.firstObject integerValue];
                if (choiceIndex >= 0 && choiceIndex < (NSInteger)items.count) [popup selectItemAtIndex:choiceIndex];
                popup.target = self; popup.action = @selector(choiceUniformAction:); popup.tag = (NSInteger)index;
                popup.accessibilityLabel = label; [row addSubview:popup]; controls[@"popup"] = popup;
            } else if (range) {
                NSSlider *slider = [NSSlider sliderWithValue:[values.firstObject doubleValue]
                    minValue:minimum.doubleValue maxValue:maximum.doubleValue target:self action:@selector(sliderUniformAction:)];
                slider.frame = NSMakeRect(-2, 33, width - 91, 22); slider.autoresizingMask = NSViewWidthSizable;
                slider.continuous = YES; slider.tag = (NSInteger)index; slider.accessibilityLabel = label;
                [row addSubview:slider]; controls[@"slider"] = slider;
                NSTextField *input = [self numericInput:values.firstObject row:index label:label];
                input.frame = NSMakeRect(width - 81, 31, 81, 24); input.autoresizingMask = NSViewMinXMargin;
                [row addSubview:input]; controls[@"inputs"] = @[input];
            } else {
                NSMutableArray<NSTextField *> *inputs = [NSMutableArray array];
                for (NSUInteger c = 0; c < components; ++c) {
                    NSString *componentLabel = components > 1 ? [NSString stringWithFormat:@"%@ component %lu", label, (unsigned long)c + 1] : label;
                    NSTextField *input = [self numericInput:c < values.count ? values[c] : @0 row:index label:componentLabel];
                    if (components > 1) input.placeholderString = [NSString stringWithFormat:@"%lu", (unsigned long)c + 1];
                    [inputs addObject:input];
                }
                NSStackView *stack = [NSStackView stackViewWithViews:inputs];
                stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
                stack.distribution = NSStackViewDistributionFillEqually; stack.spacing = 7;
                stack.frame = NSMakeRect(0, 31, width, 25); stack.autoresizingMask = NSViewWidthSizable;
                [row addSubview:stack]; controls[@"inputs"] = inputs;
            }
        }
        NSBox *line = [NSBox new]; line.boxType = NSBoxSeparator;
        line.frame = NSMakeRect(0, rowHeight - 10, width, 1); line.autoresizingMask = NSViewWidthSizable;
        [row addSubview:line]; [_parameterDocument addSubview:row];
        [_parameterRows addObject:controls]; y += rowHeight;
    }
    if (_parameterRows.count == 0) {
        NSTextField *empty = Text(@"This effect has no adjustable parameters.", 12);
        empty.textColor = NSColor.secondaryLabelColor; empty.frame = NSMakeRect(0, 18, width, 42);
        empty.autoresizingMask = NSViewWidthSizable; [_parameterDocument addSubview:empty]; y = 78;
    }
    _parameterDocument.frame = NSMakeRect(0, 0, width + 12, MAX(y + 8, _parameterScroll.contentSize.height));
    [_parameterScroll.contentView scrollToPoint:NSZeroPoint];
    _buildingInspector = NO;
}

- (NSTextField *)numericInput:(NSNumber *)value row:(NSUInteger)index label:(NSString *)label {
    NSTextField *input = [NSTextField new];
    input.stringValue = NumberText(value ?: @0);
    input.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    input.alignment = NSTextAlignmentRight;
    input.tag = (NSInteger)index; input.target = self; input.action = @selector(numericUniformAction:); input.delegate = self;
    input.accessibilityLabel = label;
    input.toolTip = @"Enter a number, then press Return or leave the field to apply it.";
    return input;
}

- (void)refreshParameterValues {
    if (_editingUniform || !_inspectedEffect) return;
    NSArray *uniforms = _inspectedEffect.uniforms;
    for (NSDictionary *row in _parameterRows) {
        NSString *name = row[@"metadata"][@"name"];
        for (NSDictionary *uniform in uniforms) if ([uniform[@"name"] isEqual:name]) {
            [self displayValues:uniform[@"values"] forRow:row]; break;
        }
    }
}
- (void)displayValues:(NSArray<NSNumber *> *)values forRow:(NSDictionary *)row {
    NSArray<NSTextField *> *inputs = row[@"inputs"];
    for (NSUInteger i = 0; i < inputs.count && i < values.count; ++i)
        if (!inputs[i].currentEditor) inputs[i].stringValue = NumberText(values[i]);
    NSSlider *slider = row[@"slider"]; if (slider && values.count) slider.doubleValue = values[0].doubleValue;
    NSButton *checkbox = row[@"checkbox"]; if (checkbox && values.count) checkbox.state = values[0].boolValue ? NSControlStateValueOn : NSControlStateValueOff;
    NSPopUpButton *popup = row[@"popup"];
    if (popup && values.count && values[0].integerValue >= 0 && values[0].integerValue < popup.numberOfItems)
        [popup selectItemAtIndex:values[0].integerValue];
}

- (void)applyUniformRow:(NSUInteger)index values:(NSArray<NSNumber *> *)values {
    if (_busy || index >= _parameterRows.count || _selectedIndex >= _entries.count ||
        _entries[_selectedIndex][@"effect"] != _inspectedEffect) return;
    NSDictionary *row = _parameterRows[index]; NSString *name = row[@"metadata"][@"name"];
    _editingUniform = YES;
    NSString *error = self.changeUniform ? self.changeUniform(name, values) : @"This control is not connected to an effect.";
    _editingUniform = NO;
    if (error.length) {
        [self setStatus:@"Could not apply this value" detail:[NSString stringWithFormat:@"%@: %@", name, error] busy:NO error:YES];
        return;
    }
    [self displayValues:values forRow:row];
    // An editor keeps focus while Return is pressed, so update its text explicitly.
    NSArray<NSTextField *> *inputs = row[@"inputs"];
    for (NSUInteger i = 0; i < inputs.count && i < values.count; ++i) inputs[i].stringValue = NumberText(values[i]);
    [self setStatus:@"Look updated" detail:[NSString stringWithFormat:@"%@ · changes apply to the next frame", name] busy:NO error:NO];
}
- (void)sliderUniformAction:(NSSlider *)slider {
    NSUInteger index = (NSUInteger)slider.tag;
    NSDictionary *metadata = _parameterRows[index][@"metadata"];
    double value = slider.doubleValue; NSNumber *step = FirstNumber(metadata[@"uiStep"]);
    if (step && std::isfinite(step.doubleValue) && step.doubleValue > 0)
        value = slider.minValue + std::round((value - slider.minValue) / step.doubleValue) * step.doubleValue;
    if ([metadata[@"type"] hasPrefix:@"int"] || [metadata[@"type"] hasPrefix:@"uint"]) value = std::round(value);
    value = std::clamp(value, slider.minValue, slider.maxValue); slider.doubleValue = value;
    [self applyUniformRow:index values:@[@(value)]];
}
- (void)boolUniformAction:(NSButton *)button { [self applyUniformRow:(NSUInteger)button.tag values:@[@(button.state == NSControlStateValueOn)]]; }
- (void)choiceUniformAction:(NSPopUpButton *)popup { [self applyUniformRow:(NSUInteger)popup.tag values:@[@(popup.indexOfSelectedItem)]]; }
- (void)resetUniformAction:(NSButton *)button {
    NSUInteger index = (NSUInteger)button.tag;
    if (index < _parameterRows.count) [self applyUniformRow:index values:_parameterRows[index][@"metadata"][@"defaultValues"]];
}
- (BOOL)parseNumber:(NSTextField *)input result:(double *)value {
    NSString *text = [input.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSScanner *scanner = [NSScanner scannerWithString:text];
    scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    if (!text.length || ![scanner scanDouble:value] || !scanner.isAtEnd || !std::isfinite(*value)) {
        [self setStatus:@"Enter a finite number" detail:@"Use a decimal point, such as 0.5. The current effect value has not changed." busy:NO error:YES];
        return NO;
    }
    return YES;
}
- (void)numericUniformAction:(NSTextField *)input {
    if (_buildingInspector) return;
    NSUInteger index = (NSUInteger)input.tag; if (index >= _parameterRows.count) return;
    NSDictionary *row = _parameterRows[index]; NSString *type = row[@"metadata"][@"type"];
    if (![row[@"inputs"] containsObject:input]) return;
    NSMutableArray *values = [NSMutableArray array];
    for (NSTextField *component in row[@"inputs"]) {
        double value; if (![self parseNumber:component result:&value]) return;
        if (([type hasPrefix:@"int"] || [type hasPrefix:@"uint"]) && std::trunc(value) != value) {
            [self setStatus:@"This parameter needs whole numbers" detail:@"Use values such as 0, 1 or 2. The current effect value has not changed." busy:NO error:YES]; return;
        }
        if ([type hasPrefix:@"bool"] && value != 0 && value != 1) {
            [self setStatus:@"Use 0 or 1 for boolean values" detail:@"0 turns a component off; 1 turns it on." busy:NO error:YES]; return;
        }
        [values addObject:@(value)];
    }
    [self applyUniformRow:index values:values];
}

- (void)buildBuiltinControls {
    CGFloat width = MAX(280, _builtinScroll.contentSize.width - 12);
    NSTextField *title = Text(@"The finishing touches", 19, NSFontWeightSemibold);
    title.frame = NSMakeRect(0, 0, width, 25); title.autoresizingMask = NSViewWidthSizable; [_builtinDocument addSubview:title];
    NSTextField *intro = Text(@"Color, detail and atmosphere — alongside your effect chain.", 11);
    intro.textColor = NSColor.secondaryLabelColor; intro.frame = NSMakeRect(0, 31, width, 20);
    intro.autoresizingMask = NSViewWidthSizable; [_builtinDocument addSubview:intro];
    NSButton *neutral = Button(@"Neutral", self, @selector(neutralAction:));
    neutral.frame = NSMakeRect(-4, 61, 109, 30); [_builtinDocument addSubview:neutral];
    NSButton *reset = Button(@"Reset look", self, @selector(resetBuiltinAction:));
    reset.frame = NSMakeRect(105, 61, 113, 30); [_builtinDocument addSubview:reset];
    for (NSUInteger i = 0; i < kBuiltinCount; ++i) {
        CGFloat y = 112 + i * 70;
        NSTextField *name = Text([NSString stringWithUTF8String:kBuiltinNames[i]], 12, NSFontWeightMedium);
        name.frame = NSMakeRect(0, y, width, 20); name.autoresizingMask = NSViewWidthSizable; [_builtinDocument addSubview:name];
        NSSlider *slider = [NSSlider sliderWithValue:0 minValue:kBuiltinMinimum[i] maxValue:kBuiltinMaximum[i]
            target:self action:@selector(builtinSliderAction:)];
        slider.frame = NSMakeRect(-2, y + 29, width - 90, 22); slider.autoresizingMask = NSViewWidthSizable;
        slider.tag = (NSInteger)i; slider.continuous = YES; slider.accessibilityLabel = name.stringValue;
        [_builtinDocument addSubview:slider]; [_builtinSliders addObject:slider];
        NSTextField *input = [self numericInput:@0 row:i label:[name.stringValue stringByAppendingString:@" value"]];
        input.action = @selector(builtinNumericAction:); input.identifier = @"builtin";
        input.frame = NSMakeRect(width - 81, y + 27, 81, 24); input.autoresizingMask = NSViewMinXMargin;
        [_builtinDocument addSubview:input]; [_builtinInputs addObject:input];
    }
}
- (void)updateBuiltinValues:(NSArray<NSNumber *> *)values enabled:(BOOL)enabled {
    (void)self.view; _builtinValues = [values copy];
    _allEnabled.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    _allEnabled.title = enabled ? @"Effects on" : @"Effects off";
    for (NSUInteger i = 0; i < std::min(values.count, _builtinSliders.count); ++i) {
        _builtinSliders[i].doubleValue = values[i].doubleValue;
        if (!_builtinInputs[i].currentEditor) _builtinInputs[i].stringValue = NumberText(values[i]);
    }
}
- (void)builtinSliderAction:(NSSlider *)slider {
    NSUInteger index = (NSUInteger)slider.tag;
    if (index >= kBuiltinCount) return;
    _builtinInputs[index].stringValue = NumberText(@(slider.doubleValue));
    if (self.changeBuiltin) self.changeBuiltin(index, slider.doubleValue);
}
- (void)builtinNumericAction:(NSTextField *)input {
    NSUInteger index = (NSUInteger)input.tag; if (index >= kBuiltinCount) return;
    double value; if (![self parseNumber:input result:&value]) return;
    if (value < kBuiltinMinimum[index] || value > kBuiltinMaximum[index]) {
        [self setStatus:@"Value outside the control range"
            detail:[NSString stringWithFormat:@"%@ accepts %.2g to %.2g.", [NSString stringWithUTF8String:kBuiltinNames[index]],
                    kBuiltinMinimum[index], kBuiltinMaximum[index]] busy:NO error:YES]; return;
    }
    _builtinSliders[index].doubleValue = value;
    if (self.changeBuiltin) self.changeBuiltin(index, value);
}

- (void)setStatus:(NSString *)message detail:(NSString *)detail busy:(BOOL)busy error:(BOOL)error {
    (void)self.view; BOOL busyChanged = _busy != busy; _busy = busy;
    _status.stringValue = message ?: @""; _statusDetail.stringValue = detail ?: @"";
    _statusDetail.toolTip = detail;
    _status.textColor = error ? NSColor.systemRedColor : (busy ? NSColor.labelColor : Accent());
    if (busy) [_spinner startAnimation:nil]; else [_spinner stopAnimation:nil];
    [self updateInteractions];
    if (busyChanged) [self reloadRows];
}
- (void)updatePresets:(NSArray<NSDictionary *> *)presets selectedURL:(nullable NSURL *)selected {
    (void)self.view;
    _presetItems = [presets copy];
    _selectedPresetURL = selected;
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    NSMenuItem *placeholder = [[NSMenuItem alloc] initWithTitle:_preset.stringValue.length ? _preset.stringValue : @"Choose a preset…"
        action:nil keyEquivalent:@""];
    placeholder.enabled = NO;
    [menu addItem:placeholder];
    [menu addItem:[NSMenuItem separatorItem]];
    
    NSString *currentCategory = nil;
    NSMenuItem *itemToSelect = nil;
    for (NSDictionary *dict in presets) {
        NSString *cat = dict[@"category"] ?: @"Presets";
        if (![cat isEqualToString:currentCategory]) {
            if (currentCategory != nil) [menu addItem:[NSMenuItem separatorItem]];
            currentCategory = cat;
            NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"— %@ —", cat]
                                                            action:nil keyEquivalent:@""];
            header.enabled = NO;
            [menu addItem:header];
        }
        NSString *name = dict[@"name"] ?: @"Preset";
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:name action:@selector(presetPopupAction:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = dict[@"url"];
        item.toolTip = [dict[@"url"] path];
        [menu addItem:item];

        if (selected && [URLIdentity(dict[@"url"]) isEqual:URLIdentity(selected)]) {
            itemToSelect = item;
        }
    }
    
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *importItem = [[NSMenuItem alloc] initWithTitle:@"Import Preset from File…"
                                                        action:@selector(presetPopupAction:) keyEquivalent:@""];
    importItem.target = self;
    importItem.representedObject = @"__import__";
    [menu addItem:importItem];
    
    _presetPopup.menu = menu;
    
    [_presetPopup selectItem:itemToSelect ?: placeholder];
    _presetPopup.accessibilityLabel = @"ReShade preset";
    _presetPopup.toolTip = selected.path ?: [NSString stringWithFormat:@"Choose from %lu presets", (unsigned long)presets.count];
    [self updateInteractions];
}

- (void)presetPopupAction:(id)sender {
    NSMenuItem *selected = nil;
    if ([sender isKindOfClass:NSMenuItem.class]) {
        selected = (NSMenuItem *)sender;
    } else if ([sender respondsToSelector:@selector(selectedItem)]) {
        selected = [(NSPopUpButton *)sender selectedItem];
    }
    if (!selected || _busy) return;
    id choice = selected.representedObject;
    if ([choice isEqual:@"__import__"]) {
        [self updatePresets:_presetItems selectedURL:_selectedPresetURL];
        if (self.importPreset) self.importPreset();
    } else if ([choice isKindOfClass:NSURL.class]) {
        _preset.stringValue = selected.title ?: @"Custom look";
        _selectedPresetURL = (NSURL *)choice;
        [self updatePresets:_presetItems selectedURL:_selectedPresetURL];
        if (self.choosePreset) self.choosePreset(choice);
    }
}

- (void)setPresetName:(NSString *)name {
    (void)self.view;
    NSString *title = name.length ? name : @"Untitled preset";
    _preset.stringValue = title;
    _preset.toolTip = title;
    // setTitle: on a popup may alter a real menu item's label. Only update the
    // dedicated placeholder; URL identity selects real presets in updatePresets.
    NSMenuItem *placeholder = _presetPopup.menu.itemArray.firstObject;
    if (!placeholder.representedObject && !placeholder.action) placeholder.title = title;
    _presetPopup.toolTip = _selectedPresetURL.path ?: [NSString stringWithFormat:@"Active look: %@", title];
}
- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == _search) [self reloadRows];
}
- (void)controlTextDidEndEditing:(NSNotification *)notification {
    if (notification.object == _search) return;
    NSTextField *input = notification.object;
    if ([input.identifier isEqualToString:@"builtin"]) [self builtinNumericAction:input];
    else [self numericUniformAction:input];
}
- (void)listModeAction:(id)sender { (void)sender; _search.stringValue = @""; [self reloadRows]; }
- (void)inspectorModeAction:(id)sender {
    (void)sender; BOOL builtin = _inspectorMode.selectedSegment == 1;
    _effectPane.hidden = builtin; _builtinScroll.hidden = !builtin;
}
- (void)openAction:(id)sender { (void)sender; if (!_busy && self.openEffect) self.openEffect(); }
- (void)folderAction:(id)sender { (void)sender; if (!_busy && self.addFolder) self.addFolder(); }
- (void)importAction:(id)sender { (void)sender; if (!_busy && self.importPreset) self.importPreset(); }
- (void)saveAction:(id)sender { (void)sender; if (!_busy && self.exportPreset) self.exportPreset(); }
- (void)qualityAction:(id)sender { (void)sender; if (!_busy && self.cycleQuality) self.cycleQuality(); }
- (void)setQualityLabel:(NSString *)label { _qualityButton.title = label ?: @"100% (FQ)"; }
- (void)hideAction:(id)sender { (void)sender; if (self.hideOverlay) self.hideOverlay(); }
- (void)reloadAction:(id)sender { (void)sender; if (!_busy && self.reloadEffects) self.reloadEffects(); }
- (void)neutralAction:(id)sender { (void)sender; if (self.neutralBuiltin) self.neutralBuiltin(); }
- (void)resetBuiltinAction:(id)sender { (void)sender; if (self.resetBuiltin) self.resetBuiltin(); }
- (void)toggleAllAction:(NSButton *)button {
    BOOL enabled = button.state == NSControlStateValueOn;
    button.title = enabled ? @"Effects on" : @"Effects off";
    if (self.toggleAll) self.toggleAll(enabled);
}
- (void)addLibraryAction:(NSButton *)button {
    NSUInteger index = (NSUInteger)button.tag;
    if (!_busy && index < _library.count && self.chooseEffect) self.chooseEffect(_library[index][@"url"]);
}
- (void)doubleClickEffect:(id)sender {
    (void)sender; if (_busy || _listMode.selectedSegment != 0 || _table.clickedRow < 0) return;
    NSUInteger index = _visibleIndices[(NSUInteger)_table.clickedRow].unsignedIntegerValue;
    if (self.chooseEffect) self.chooseEffect(_library[index][@"url"]);
}
- (void)toggleEntryAction:(NSButton *)button {
    NSUInteger index = (NSUInteger)button.tag;
    if (!_busy && index < _entries.count && self.enableEntry) self.enableEntry(index, button.state == NSControlStateValueOn);
}
- (void)enableSelectedAction:(id)sender {
    (void)sender;
    if (!_busy && _selectedIndex < _entries.count && self.enableEntry) self.enableEntry(_selectedIndex, YES);
}
- (void)moveUpAction:(id)sender { (void)sender; if (!_busy && _selectedIndex < _entries.count && self.moveEntry) self.moveEntry(_selectedIndex, -1); }
- (void)moveDownAction:(id)sender { (void)sender; if (!_busy && _selectedIndex < _entries.count && self.moveEntry) self.moveEntry(_selectedIndex, 1); }
- (void)removeAction:(id)sender { (void)sender; if (!_busy && _selectedIndex < _entries.count && self.removeEntry) self.removeEntry(_selectedIndex); }
- (void)techniqueAction:(NSPopUpButton *)popup {
    if (!_busy && popup.titleOfSelectedItem.length && self.selectTechnique) self.selectTechnique(popup.titleOfSelectedItem);
}
@end
