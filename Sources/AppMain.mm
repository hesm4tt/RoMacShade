//
// Copyright (c) 2026 MacShade Authors. All Rights Reserved.
// PROPRIETARY AND CONFIDENTIAL.
// UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
//

#import "Obfuscate.h"
#import "HostLauncher.h"
#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <pwd.h>
#include <unistd.h>

@interface MSLogoView : NSView
@end

@implementation MSLogoView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = self.bounds;
    NSRect circleRect = NSInsetRect(bounds, 2.0, 2.0);
    NSBezierPath *circle = [NSBezierPath bezierPathWithOvalInRect:circleRect];
    
    // Frosted dark background
    [[NSColor colorWithRed:0.09 green:0.11 blue:0.15 alpha:1.0] setFill];
    [circle fill];
    
    // Vibrant cyan accent border
    [[NSColor colorWithSRGBRed:0.33 green:0.86 blue:0.76 alpha:1.0] setStroke];
    circle.lineWidth = 2.0;
    [circle stroke];
    
    // Inner glow ring
    NSBezierPath *inner = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(circleRect, 2.5, 2.5)];
    [[NSColor colorWithSRGBRed:0.33 green:0.86 blue:0.76 alpha:0.25] setStroke];
    inner.lineWidth = 1.0;
    [inner stroke];
    
    // Monogram 'M'
    NSString *m = @"M";
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:24 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.33 green:0.86 blue:0.76 alpha:1.0]
    };
    NSSize size = [m sizeWithAttributes:attrs];
    NSRect tr = NSMakeRect(
        bounds.origin.x + (bounds.size.width - size.width) * 0.5,
        bounds.origin.y + (bounds.size.height - size.height) * 0.5 - 1.0,
        size.width, size.height
    );
    [m drawInRect:tr withAttributes:attrs];
}
@end

@interface MSLauncherWindowController : NSWindowController <NSWindowDelegate> {
    NSWindow *_window;
    NSTextField *_statusLabel;
    NSTextField *_robloxPathLabel;
    NSButton *_launchButton;
    NSButton *_browseButton;
    NSProgressIndicator *_spinner;
    NSTextView *_logTextView;
    NSScrollView *_logScrollView;
    NSString *_selectedRobloxPath;
    BOOL _isLaunching;
}
@end

@implementation MSLauncherWindowController

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 540, 500);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = @"MacShade";
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    window.backgroundColor = [NSColor colorWithRed:0.07 green:0.08 blue:0.11 alpha:1.0];
    [window center];
    
    if ((self = [super initWithWindow:window])) {
        _window = window;
        _window.delegate = self;
        [self setupUI];
        [self detectRoblox];
    }
    return self;
}

- (void)setupUI {
    NSView *content = _window.contentView;
    const CGFloat W = 540;
    
    // Logo Badge
    MSLogoView *logo = [[MSLogoView alloc] initWithFrame:NSMakeRect((W - 56) * 0.5, 414, 56, 56)];
    logo.wantsLayer = YES;
    logo.layer.shadowColor = [NSColor blackColor].CGColor;
    logo.layer.shadowOpacity = 0.5;
    logo.layer.shadowRadius = 8.0;
    logo.layer.shadowOffset = CGSizeMake(0, -2);
    [content addSubview:logo];
    
    // Title
    NSTextField *title = [NSTextField labelWithString:@"MacShade"];
    title.frame = NSMakeRect(0, 376, W, 30);
    title.alignment = NSTextAlignmentCenter;
    title.font = [NSFont systemFontOfSize:22 weight:NSFontWeightBold];
    title.textColor = [NSColor whiteColor];
    [content addSubview:title];
    
    // Subtitle / Version tag
    NSTextField *sub = [NSTextField labelWithString:@"v0.0.1  ·  ReShade & FX Shaders on macOS Metal"];
    sub.frame = NSMakeRect(0, 354, W, 18);
    sub.alignment = NSTextAlignmentCenter;
    sub.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    sub.textColor = [NSColor colorWithSRGBRed:0.33 green:0.86 blue:0.76 alpha:0.9];
    [content addSubview:sub];
    
    // Roblox Detection Box
    NSBox *card = [[NSBox alloc] initWithFrame:NSMakeRect(30, 276, W - 60, 64)];
    card.boxType = NSBoxCustom;
    card.fillColor = [NSColor colorWithWhite:1.0 alpha:0.05];
    card.borderColor = [NSColor colorWithWhite:1.0 alpha:0.12];
    card.borderWidth = 1.0;
    card.cornerRadius = 10.0;
    
    _robloxPathLabel = [NSTextField labelWithString:@"Detecting Roblox…"];
    _robloxPathLabel.frame = NSMakeRect(16, 20, W - 60 - 120, 24);
    _robloxPathLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    _robloxPathLabel.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
    [card addSubview:_robloxPathLabel];
    
    _browseButton = [NSButton buttonWithTitle:@"Browse…" target:self action:@selector(browseRoblox:)];
    _browseButton.frame = NSMakeRect(W - 60 - 96, 18, 80, 28);
    _browseButton.bezelStyle = NSBezelStyleRounded;
    _browseButton.font = [NSFont systemFontOfSize:11];
    [card addSubview:_browseButton];
    
    [content addSubview:card];
    
    // Launch Button
    _launchButton = [NSButton buttonWithTitle:@"Launch Roblox with MacShade" target:self action:@selector(launchAction:)];
    _launchButton.frame = NSMakeRect((W - 320) * 0.5, 216, 320, 44);
    _launchButton.bezelStyle = NSBezelStyleRegularSquare;
    _launchButton.bordered = NO;
    _launchButton.wantsLayer = YES;
    _launchButton.layer.cornerRadius = 10.0;
    _launchButton.layer.backgroundColor = [NSColor colorWithSRGBRed:0.15 green:0.62 blue:0.54 alpha:1.0].CGColor;
    _launchButton.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    _launchButton.contentTintColor = [NSColor whiteColor];
    [content addSubview:_launchButton];
    
    // Spinner
    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect((W - 20) * 0.5, 228, 20, 20)];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.hidden = YES;
    [content addSubview:_spinner];
    
    // Status text
    _statusLabel = [NSTextField labelWithString:@"Ready. Press Command-E in-game to toggle effects."];
    _statusLabel.frame = NSMakeRect(30, 188, W - 60, 20);
    _statusLabel.alignment = NSTextAlignmentCenter;
    _statusLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    _statusLabel.textColor = [NSColor colorWithWhite:0.65 alpha:1.0];
    [content addSubview:_statusLabel];
    
    // Log View (collapsible console)
    _logScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(30, 68, W - 60, 110)];
    _logScrollView.borderType = NSLineBorder;
    _logScrollView.wantsLayer = YES;
    _logScrollView.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.1].CGColor;
    _logScrollView.layer.cornerRadius = 8.0;
    _logScrollView.hasVerticalScroller = YES;
    
    _logTextView = [[NSTextView alloc] initWithFrame:_logScrollView.contentView.bounds];
    _logTextView.editable = NO;
    _logTextView.backgroundColor = [NSColor colorWithRed:0.04 green:0.05 blue:0.07 alpha:0.95];
    _logTextView.textColor = [NSColor colorWithWhite:0.75 alpha:1.0];
    _logTextView.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular];
    _logTextView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _logScrollView.documentView = _logTextView;
    [content addSubview:_logScrollView];
    
    // Footer Utilities Bar
    NSButton *shadersBtn = [NSButton buttonWithTitle:@"Shaders" target:self action:@selector(openShaders:)];
    shadersBtn.frame = NSMakeRect(30, 22, 95, 30);
    shadersBtn.bezelStyle = NSBezelStyleRounded;
    shadersBtn.font = [NSFont systemFontOfSize:11];
    [content addSubview:shadersBtn];
    
    NSButton *presetsBtn = [NSButton buttonWithTitle:@"Presets" target:self action:@selector(openPresets:)];
    presetsBtn.frame = NSMakeRect(135, 22, 95, 30);
    presetsBtn.bezelStyle = NSBezelStyleRounded;
    presetsBtn.font = [NSFont systemFontOfSize:11];
    [content addSubview:presetsBtn];
    
    NSButton *previewBtn = [NSButton buttonWithTitle:@"Shader Preview" target:self action:@selector(openPreview:)];
    previewBtn.frame = NSMakeRect(240, 22, 125, 30);
    previewBtn.bezelStyle = NSBezelStyleRounded;
    previewBtn.font = [NSFont systemFontOfSize:11];
    [content addSubview:previewBtn];
    
    NSButton *logsBtn = [NSButton buttonWithTitle:@"Logs" target:self action:@selector(openLogs:)];
    logsBtn.frame = NSMakeRect(W - 30 - 80, 22, 80, 30);
    logsBtn.bezelStyle = NSBezelStyleRounded;
    logsBtn.font = [NSFont systemFontOfSize:11];
    [content addSubview:logsBtn];
}

- (void)appendLog:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAttributedString *line = [[NSAttributedString alloc] initWithString:[message stringByAppendingString:@"\n"]
            attributes:@{
                NSFontAttributeName: [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular],
                NSForegroundColorAttributeName: [NSColor colorWithWhite:0.8 alpha:1.0]
            }];
        [self->_logTextView.textStorage appendAttributedString:line];
        [self->_logTextView scrollRangeToVisible:NSMakeRange(self->_logTextView.string.length, 0)];
    });
}

- (void)detectRoblox {
    NSString *detected = [MSHostLauncher detectRobloxApp];
    if (detected.length) {
        _selectedRobloxPath = detected;
        _robloxPathLabel.stringValue = [NSString stringWithFormat:@"🟢  %@", detected];
        [self appendLog:[NSString stringWithFormat:@"Detected Roblox at %@", detected]];
    } else {
        _robloxPathLabel.stringValue = @"🟡  Roblox not found in /Applications";
        [self appendLog:@"Roblox not found at default location. Click 'Browse' to select Roblox.app."];
    }
}

- (void)browseRoblox:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"Select Roblox Application";
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"app"] ?: UTTypeApplication];
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            self->_selectedRobloxPath = panel.URL.path;
            self->_robloxPathLabel.stringValue = [NSString stringWithFormat:@"🟢  %@", self->_selectedRobloxPath];
            [self appendLog:[NSString stringWithFormat:@"Selected Roblox at %@", self->_selectedRobloxPath]];
        }
    }];
}

- (void)launchAction:(id)sender {
    (void)sender;
    if (_isLaunching) return;
    if (!_selectedRobloxPath.length || ![NSFileManager.defaultManager fileExistsAtPath:_selectedRobloxPath]) {
        [self detectRoblox];
        if (!_selectedRobloxPath.length) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"Roblox Not Found";
            alert.informativeText = @"Please install Roblox or click 'Browse' to locate Roblox.app.";
            [alert runModal];
            return;
        }
    }
    
    _isLaunching = YES;
    _launchButton.enabled = NO;
    _launchButton.title = @"";
    _spinner.hidden = NO;
    [_spinner startAnimation:nil];
    _statusLabel.stringValue = @"Preparing isolated host and injecting Metal hooks…";
    _statusLabel.textColor = [NSColor colorWithSRGBRed:0.33 green:0.86 blue:0.76 alpha:1.0];
    
    [self appendLog:@"--- Starting MacShade Launch ---"];
    [self appendLog:[NSString stringWithFormat:@"Target: %@", _selectedRobloxPath]];
    
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *launchError = nil;
        BOOL ok = [MSHostLauncher runRobloxWithSource:self->_selectedRobloxPath
                                              library:nil
                                            resources:nil
                                           logHandler:^(NSString *line) {
            [self appendLog:line];
        } error:&launchError];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishLaunchWithSuccess:ok message:ok ?
                @"Roblox is running! Press Command-E or tap the 'M' button in-game to toggle effects." :
                [NSString stringWithFormat:@"Launch failed: %@", launchError.localizedDescription ?: @"Unknown error"]];
        });
    });
}

- (void)finishLaunchWithSuccess:(BOOL)success message:(NSString *)msg {
    _isLaunching = NO;
    _launchButton.enabled = YES;
    _launchButton.title = @"Launch Roblox with MacShade";
    [_spinner stopAnimation:nil];
    _spinner.hidden = YES;
    _statusLabel.stringValue = msg;
    _statusLabel.textColor = success ?
        [NSColor colorWithSRGBRed:0.33 green:0.86 blue:0.76 alpha:1.0] :
        [NSColor colorWithSRGBRed:1.0 green:0.45 blue:0.45 alpha:1.0];
}

- (NSString *)userShadersDirectory {
    struct passwd *pw = getpwuid(getuid());
    const char *home = pw ? pw->pw_dir : getenv("HOME");
    NSString *base = home ? [NSString stringWithUTF8String:home] : NSHomeDirectory();
    NSString *pack = [base stringByAppendingPathComponent:@"Documents/reshade roblox"];
    if ([NSFileManager.defaultManager fileExistsAtPath:pack]) return pack;
    NSString *bundled = [[NSBundle.mainBundle resourcePath] stringByAppendingPathComponent:@"Effects"];
    if ([NSFileManager.defaultManager fileExistsAtPath:bundled]) return bundled;
    return pack;
}

- (void)openShaders:(id)sender {
    (void)sender;
    NSString *dir = [self userShadersDirectory];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:dir]];
}

- (void)openPresets:(id)sender {
    (void)sender;
    NSString *shaders = [self userShadersDirectory];
    NSString *presets = [shaders stringByAppendingPathComponent:@"reshade-presets"];
    if (![NSFileManager.defaultManager fileExistsAtPath:presets]) {
        presets = [shaders stringByAppendingPathComponent:@"Presets"];
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:presets]) {
        presets = [[NSBundle.mainBundle resourcePath] stringByAppendingPathComponent:@"Presets"];
    }
    [NSFileManager.defaultManager createDirectoryAtPath:presets withIntermediateDirectories:YES attributes:nil error:nil];
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:presets]];
}

- (void)openPreview:(id)sender {
    (void)sender;
    NSString *demoPath = [[NSBundle.mainBundle bundlePath] stringByAppendingPathComponent:@"Contents/MacOS/MacShadeDemo"];
    if (![NSFileManager.defaultManager fileExistsAtPath:demoPath]) {
        demoPath = [[NSBundle.mainBundle.bundlePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"MacShadeDemo.app"];
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:demoPath]) {
        [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:demoPath]];
    } else {
        [self appendLog:@"Standalone shader preview not found in bundle."];
    }
}

- (void)openLogs:(id)sender {
    (void)sender;
    NSString *logDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/MacShade"];
    [NSFileManager.defaultManager createDirectoryAtPath:logDir withIntermediateDirectories:YES attributes:nil error:nil];
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:logDir]];
}

@end

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        
        // Main Menu
        NSMenu *menubar = [NSMenu new];
        NSMenuItem *appMenuItem = [NSMenuItem new];
        [menubar addItem:appMenuItem];
        [app setMainMenu:menubar];
        
        NSMenu *appMenu = [NSMenu new];
        [appMenu addItemWithTitle:@"About MacShade" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
        [appMenu addItem:[NSMenuItem separatorItem]];
        [appMenu addItemWithTitle:@"Hide MacShade" action:@selector(hide:) keyEquivalent:@"h"];
        [appMenu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
        [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
        [appMenu addItem:[NSMenuItem separatorItem]];
        [appMenu addItemWithTitle:@"Quit MacShade" action:@selector(terminate:) keyEquivalent:@"q"];
        [appMenuItem setSubmenu:appMenu];
        
        MSLauncherWindowController *controller = [[MSLauncherWindowController alloc] init];
        [controller showWindow:nil];
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
