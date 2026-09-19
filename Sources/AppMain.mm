//
// Copyright (c) 2026 MacShade Authors. All Rights Reserved.
// PROPRIETARY AND CONFIDENTIAL.
// UNAUTHORIZED COPYING, REVERSE ENGINEERING, REBRANDING, OR DISTRIBUTION IS STRICTLY PROHIBITED.
//

#import "Obfuscate.h"
#import "HostLauncher.h"
#import "HardwareLock.h"
#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <pwd.h>
#include <unistd.h>

@interface MSLogoView : NSView {
    NSImage *_logoImage;
}
@end

@implementation MSLogoView
- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 14.0;
        self.layer.masksToBounds = YES;
        
        NSString *resPath = [[NSBundle mainBundle] pathForResource:@"RoMacShadeLogo" ofType:@"png"];
        if (!resPath) {
            NSString *bundleDir = [[NSBundle mainBundle] bundlePath];
            resPath = [[bundleDir stringByAppendingPathComponent:@"Contents/Resources"] stringByAppendingPathComponent:@"RoMacShadeLogo.png"];
            if (![NSFileManager.defaultManager fileExistsAtPath:resPath]) {
                resPath = [[bundleDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Resources/RoMacShadeLogo.png"];
            }
        }
        if (resPath && [NSFileManager.defaultManager fileExistsAtPath:resPath]) {
            _logoImage = [[NSImage alloc] initWithContentsOfFile:resPath];
        }
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = self.bounds;
    if (_logoImage) {
        [_logoImage drawInRect:bounds fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:nil];
    } else {
        NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:14 yRadius:14];
        [[NSColor colorWithRed:0.09 green:0.11 blue:0.15 alpha:1.0] setFill];
        [clip fill];
        [[NSColor colorWithSRGBRed:0.33 green:0.86 blue:0.76 alpha:1.0] setStroke];
        clip.lineWidth = 1.5;
        [clip stroke];
        
        NSString *r = @"R";
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:26 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.33 green:0.86 blue:0.76 alpha:1.0]
        };
        NSSize size = [r sizeWithAttributes:attrs];
        NSRect tr = NSMakeRect((bounds.size.width - size.width) * 0.5, (bounds.size.height - size.height) * 0.5 - 1.0, size.width, size.height);
        [r drawInRect:tr withAttributes:attrs];
    }
}
@end

@interface MSLicenseCardView : NSView
@end

@implementation MSLicenseCardView
- (instancetype)initWithFrame:(NSRect)frameRect {
    if ((self = [super initWithFrame:frameRect])) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 10.0;
        self.layer.borderWidth = 1.0;
        self.layer.masksToBounds = YES;
    }
    return self;
}
@end

@interface MSLauncherWindowController : NSWindowController <NSWindowDelegate> {
    NSWindow *_window;
    MSLicenseCardView *_licenseBox;
    NSTextField *_licenseStatusHeader;
    NSTextField *_hwidDisplayLabel;
    NSButton *_copyHWIDBtn;
    NSTextField *_licenseKeyField;
    NSButton *_activateBtn;
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
    NSRect frame = NSMakeRect(0, 0, 540, 580);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    window.title = @"RoMacShade";
    window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    window.backgroundColor = [NSColor colorWithRed:0.07 green:0.08 blue:0.11 alpha:1.0];
    [window center];
    
    if ((self = [super initWithWindow:window])) {
        _window = window;
        _window.delegate = self;
        [self setupUI];
        [self updateLicenseUI];
        [self detectRoblox];
    }
    return self;
}

- (void)setupUI {
    NSView *content = _window.contentView;
    const CGFloat W = 540;
    
    // Logo Badge
    MSLogoView *logo = [[MSLogoView alloc] initWithFrame:NSMakeRect((W - 64) * 0.5, 486, 64, 64)];
    logo.wantsLayer = YES;
    logo.layer.shadowColor = [NSColor blackColor].CGColor;
    logo.layer.shadowOpacity = 0.5;
    logo.layer.shadowRadius = 8.0;
    logo.layer.shadowOffset = CGSizeMake(0, -2);
    [content addSubview:logo];
    
    // Title
    NSTextField *title = [NSTextField labelWithString:@"RoMacShade"];
    title.frame = NSMakeRect(0, 452, W, 30);
    title.alignment = NSTextAlignmentCenter;
    title.font = [NSFont systemFontOfSize:22 weight:NSFontWeightBold];
    title.textColor = [NSColor whiteColor];
    [content addSubview:title];
    
    // Subtitle / Version tag
    NSTextField *sub = [NSTextField labelWithString:@"v0.0.1  ·  Next-Gen Shaders & ReShade for Roblox on macOS Metal"];
    sub.frame = NSMakeRect(0, 430, W, 18);
    sub.alignment = NSTextAlignmentCenter;
    sub.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    sub.textColor = [NSColor colorWithSRGBRed:0.33 green:0.86 blue:0.76 alpha:0.9];
    [content addSubview:sub];
    
    // Hardware License Card
    _licenseBox = [[MSLicenseCardView alloc] initWithFrame:NSMakeRect(30, 338, W - 60, 86)];
    [content addSubview:_licenseBox];
    
    const CGFloat boxW = W - 60;
    
    // Status header inside card
    _licenseStatusHeader = [NSTextField labelWithString:@""];
    _licenseStatusHeader.frame = NSMakeRect(14, 58, boxW - 28, 20);
    _licenseStatusHeader.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold];
    [_licenseBox addSubview:_licenseStatusHeader];
    
    // HWID display label (selectable with mouse cursor)
    _hwidDisplayLabel = [NSTextField labelWithString:@""];
    _hwidDisplayLabel.frame = NSMakeRect(14, 32, boxW - 28 - 105, 22);
    _hwidDisplayLabel.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightSemibold];
    _hwidDisplayLabel.selectable = YES;
    [_licenseBox addSubview:_hwidDisplayLabel];
    
    // Copy HWID button
    _copyHWIDBtn = [NSButton buttonWithTitle:@"Copy HWID" target:self action:@selector(copyHWIDAction:)];
    _copyHWIDBtn.frame = NSMakeRect(boxW - 14 - 100, 30, 100, 26);
    _copyHWIDBtn.bezelStyle = NSBezelStyleRounded;
    _copyHWIDBtn.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    [_licenseBox addSubview:_copyHWIDBtn];
    
    // License Key textfield
    _licenseKeyField = [NSTextField textFieldWithString:@""];
    _licenseKeyField.frame = NSMakeRect(14, 8, boxW - 28 - 105, 22);
    _licenseKeyField.placeholderString = @"Paste License Key (KEY-XXXX-XXXX-XXXX-XXXX)";
    _licenseKeyField.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _licenseKeyField.target = self;
    _licenseKeyField.action = @selector(activateAction:);
    [_licenseBox addSubview:_licenseKeyField];
    
    // Activate button
    _activateBtn = [NSButton buttonWithTitle:@"Activate" target:self action:@selector(activateAction:)];
    _activateBtn.frame = NSMakeRect(boxW - 14 - 100, 6, 100, 26);
    _activateBtn.bezelStyle = NSBezelStyleRounded;
    _activateBtn.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    [_licenseBox addSubview:_activateBtn];
    
    // Roblox Detection Box
    NSBox *card = [[NSBox alloc] initWithFrame:NSMakeRect(30, 264, W - 60, 64)];
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
    _launchButton = [NSButton buttonWithTitle:@"Launch Roblox with RoMacShade" target:self action:@selector(launchAction:)];
    _launchButton.frame = NSMakeRect((W - 320) * 0.5, 210, 320, 44);
    _launchButton.bezelStyle = NSBezelStyleRegularSquare;
    _launchButton.bordered = NO;
    _launchButton.wantsLayer = YES;
    _launchButton.layer.cornerRadius = 10.0;
    _launchButton.layer.backgroundColor = [NSColor colorWithSRGBRed:0.15 green:0.62 blue:0.54 alpha:1.0].CGColor;
    _launchButton.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    _launchButton.contentTintColor = [NSColor whiteColor];
    [content addSubview:_launchButton];
    
    // Spinner
    _spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect((W - 20) * 0.5, 222, 20, 20)];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall;
    _spinner.hidden = YES;
    [content addSubview:_spinner];
    
    // Status text
    _statusLabel = [NSTextField labelWithString:@"Ready. Press Command-E in-game to toggle effects."];
    _statusLabel.frame = NSMakeRect(30, 182, W - 60, 20);
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

- (void)updateLicenseUI {
    BOOL licensed = [MSHardwareLock isLicensed];
    NSString *hwid = [MSHardwareLock currentHWID];
    const CGFloat boxW = 540 - 60;
    
    _hwidDisplayLabel.stringValue = [NSString stringWithFormat:@"HWID: %@", hwid];
    
    if (licensed) {
        _licenseBox.layer.borderColor = [NSColor colorWithSRGBRed:0.2 green:0.75 blue:0.5 alpha:0.45].CGColor;
        _licenseBox.layer.backgroundColor = [NSColor colorWithSRGBRed:0.08 green:0.24 blue:0.16 alpha:0.35].CGColor;
        
        _licenseStatusHeader.stringValue = @"🟢  RoMacShade Activated  ·  Locked to this Mac";
        _licenseStatusHeader.textColor = [NSColor colorWithSRGBRed:0.33 green:0.86 blue:0.76 alpha:1.0];
        _licenseStatusHeader.frame = NSMakeRect(14, 48, boxW - 28, 22);
        
        _hwidDisplayLabel.textColor = [NSColor colorWithWhite:0.85 alpha:1.0];
        _hwidDisplayLabel.frame = NSMakeRect(14, 18, boxW - 28 - 105, 22);
        
        _copyHWIDBtn.frame = NSMakeRect(boxW - 14 - 100, 16, 100, 26);
        _copyHWIDBtn.hidden = NO;
        
        _licenseKeyField.hidden = YES;
        _activateBtn.hidden = YES;
        
        _launchButton.enabled = YES;
        _launchButton.layer.backgroundColor = [NSColor colorWithSRGBRed:0.15 green:0.62 blue:0.54 alpha:1.0].CGColor;
        _statusLabel.stringValue = @"Ready. Press Command-E or tap the 'R' button in-game to toggle effects.";
        _statusLabel.textColor = [NSColor colorWithWhite:0.65 alpha:1.0];
    } else {
        _licenseBox.layer.borderColor = [NSColor colorWithSRGBRed:0.95 green:0.65 blue:0.25 alpha:0.55].CGColor;
        _licenseBox.layer.backgroundColor = [NSColor colorWithSRGBRed:0.32 green:0.18 blue:0.06 alpha:0.35].CGColor;
        
        _licenseStatusHeader.stringValue = @"🟡  Activation Required  ·  Locked to this Mac";
        _licenseStatusHeader.textColor = [NSColor colorWithSRGBRed:0.98 green:0.75 blue:0.3 alpha:1.0];
        _licenseStatusHeader.frame = NSMakeRect(14, 58, boxW - 28, 20);
        
        _hwidDisplayLabel.textColor = [NSColor colorWithSRGBRed:1.0 green:0.88 blue:0.55 alpha:1.0];
        _hwidDisplayLabel.frame = NSMakeRect(14, 32, boxW - 28 - 105, 22);
        
        _copyHWIDBtn.frame = NSMakeRect(boxW - 14 - 100, 30, 100, 26);
        _copyHWIDBtn.hidden = NO;
        
        _licenseKeyField.frame = NSMakeRect(14, 8, boxW - 28 - 105, 22);
        _licenseKeyField.hidden = NO;
        
        _activateBtn.frame = NSMakeRect(boxW - 14 - 100, 6, 100, 26);
        _activateBtn.hidden = NO;
        
        _launchButton.enabled = NO;
        _launchButton.layer.backgroundColor = [NSColor colorWithWhite:0.2 alpha:1.0].CGColor;
        _statusLabel.stringValue = @"Copy your HWID above and enter your license key to unlock.";
        _statusLabel.textColor = [NSColor colorWithSRGBRed:0.98 green:0.75 blue:0.3 alpha:1.0];
    }
}

- (void)copyHWIDAction:(id)sender {
    NSString *hwid = [MSHardwareLock currentHWID];
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:hwid forType:NSPasteboardTypeString];
    
    if ([sender isKindOfClass:[NSButton class]]) {
        NSButton *btn = (NSButton *)sender;
        btn.title = @"Copied!";
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            btn.title = @"Copy HWID";
        });
    }
    [self appendLog:[NSString stringWithFormat:@"Copied Hardware ID to clipboard: %@", hwid]];
}

- (void)activateAction:(id)sender {
    (void)sender;
    NSString *key = _licenseKeyField.stringValue;
    NSError *error = nil;
    BOOL ok = [MSHardwareLock activateWithKey:key error:&error];
    if (ok) {
        [self appendLog:@"✅ License activated successfully! This copy is now bound to this Mac."];
        [self updateLicenseUI];
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"RoMacShade Activated";
        alert.informativeText = @"Your license has been verified and bound to this Mac's Hardware ID. Enjoy RoMacShade!";
        [alert runModal];
    } else {
        [self appendLog:[NSString stringWithFormat:@"❌ Activation failed: %@", error.localizedDescription]];
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Activation Failed";
        alert.informativeText = error.localizedDescription ?: @"The entered license key does not match this computer's Hardware ID.";
        [alert runModal];
    }
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
    if (![MSHardwareLock isLicensed]) {
        [self updateLicenseUI];
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Activation Required";
        alert.informativeText = @"This copy of RoMacShade is locked to hardware. Please enter a valid license key for this Mac.";
        [alert runModal];
        return;
    }
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
    
    [self appendLog:@"--- Starting RoMacShade Launch ---"];
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
                @"Roblox is running! Press Command-E or tap the 'R' button in-game to toggle effects." :
                [NSString stringWithFormat:@"Launch failed: %@", launchError.localizedDescription ?: @"Unknown error"]];
        });
    });
}

- (void)finishLaunchWithSuccess:(BOOL)success message:(NSString *)msg {
    _isLaunching = NO;
    _launchButton.enabled = YES;
    _launchButton.title = @"Launch Roblox with RoMacShade";
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
        [appMenu addItemWithTitle:@"About RoMacShade" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
        [appMenu addItem:[NSMenuItem separatorItem]];
        [appMenu addItemWithTitle:@"Hide RoMacShade" action:@selector(hide:) keyEquivalent:@"h"];
        [appMenu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
        [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
        [appMenu addItem:[NSMenuItem separatorItem]];
        [appMenu addItemWithTitle:@"Quit RoMacShade" action:@selector(terminate:) keyEquivalent:@"q"];
        [appMenuItem setSubmenu:appMenu];
        
        MSLauncherWindowController *controller = [[MSLauncherWindowController alloc] init];
        [controller showWindow:nil];
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
