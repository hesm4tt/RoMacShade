#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "MacShade.h"
#import "FXChain.h"
#import "RMAssets.h"
#import "RMPackConfig.h"
#include <algorithm>
#include <cmath>

static UIColor *RMBackground(void) { return [UIColor colorWithWhite:0.085 alpha:0.97]; }
static UIColor *RMSurface(void) { return [UIColor colorWithWhite:0.16 alpha:1]; }
static UIColor *RMAccent(void) { return [UIColor colorWithRed:0.28 green:0.83 blue:0.87 alpha:1]; }
static UIFont *RMFont(CGFloat size, BOOL bold = NO) {
    return [UIFont fontWithName:bold ? @"Arial-BoldMT" : @"ArialMT" size:size] ?: [UIFont systemFontOfSize:size];
}
static UILabel *RMLabel(NSString *text, CGFloat size = 13, BOOL bold = NO) {
    UILabel *label = [UILabel new]; label.text = text; label.font = RMFont(size, bold);
    label.textColor = UIColor.whiteColor; label.numberOfLines = 0; return label;
}
static UIButton *RMButton(NSString *text, void (^action)(void)) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:text forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.titleLabel.font = RMFont(13); button.backgroundColor = RMSurface();
    button.layer.cornerRadius = 9; button.contentEdgeInsets = UIEdgeInsetsMake(8, 10, 8, 10);
    [button addAction:[UIAction actionWithHandler:^(__unused UIAction *item) { if (action) action(); }]
        forControlEvents:UIControlEventTouchUpInside]; return button;
}
static UIStackView *RMRow(NSArray<UIView *> *views) {
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis = UILayoutConstraintAxisHorizontal; stack.spacing = 8;
    stack.alignment = UIStackViewAlignmentCenter; return stack;
}
static void RMHeight(UIView *view, CGFloat height) {
    [view.heightAnchor constraintEqualToConstant:height].active = YES;
}
static NSString *RMEntryTitle(NSDictionary *entry) {
    MSFXEffect *effect = entry[@"effect"];
    return [NSString stringWithFormat:@"%@ · %@", [entry[@"url"] lastPathComponent],
        effect ? effect.activeTechnique : entry[@"technique"] ?: @""];
}

@interface RMPassthroughWindow : UIWindow
@end
@implementation RMPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self || hit == self.rootViewController.view ? nil : hit;
}
@end

@interface RMOverlay : UIViewController <UIDocumentPickerDelegate, UISearchBarDelegate, UITextFieldDelegate>
@property(nonatomic, strong) UIView *panel;
@property(nonatomic, strong) UIView *header;
@property(nonatomic, strong) UIButton *launcher;
@property(nonatomic, strong) UIButton *master;
@property(nonatomic, strong) UISegmentedControl *tabs;
@property(nonatomic, strong) UIScrollView *scroll;
@property(nonatomic, strong) UIStackView *content;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) UISearchBar *search;
@property(nonatomic, strong) NSURL *libraryRoot;
@property(nonatomic, copy) NSArray<NSDictionary *> *library;
@property(nonatomic, copy) NSArray<NSURL *> *presetURLs;
@property(nonatomic, strong) NSURL *activePresetURL;
@property(nonatomic, copy) NSArray<NSDictionary *> *entries;
@property(nonatomic, copy) NSArray<NSDictionary *> *pendingSpecs;
@property(nonatomic, copy) NSString *presetWarnings;
@property(nonatomic, copy) NSString *presetTitle;
@property(nonatomic, copy) NSString *filter;
@property(nonatomic, strong) dispatch_queue_t compilerQueue;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, weak) UIWindow *hostWindow;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger selectedEntry;
@property(nonatomic) NSUInteger compiledWidth;
@property(nonatomic) NSUInteger compiledHeight;
@property(nonatomic) CGFloat renderScale;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL selectingFolder;
@property(nonatomic) CGPoint dragOrigin;
@property(nonatomic) CGPoint launcherDragOrigin;
@property(nonatomic) BOOL launcherPositionLoaded;
@property(nonatomic) CGRect previousBounds;
- (void)reloadLibrary;
- (void)render;
- (void)compile:(NSArray<NSDictionary *> *)specs;
- (void)setMenuVisible:(BOOL)visible animated:(BOOL)animated;
- (void)toggleEffects;
@end

@implementation RMOverlay
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = UIColor.clearColor;
    self.entries = @[]; self.library = @[]; self.presetURLs = @[];
    self.presetTitle = @"Custom"; self.filter = @"";
    NSNumber *savedRenderScale = [NSUserDefaults.standardUserDefaults objectForKey:@"RoMacShadeRenderScale"];
    CGFloat savedScale = savedRenderScale ? savedRenderScale.doubleValue : 0.75;
    self.renderScale = std::isfinite(savedScale) ? MIN(1.0, MAX(0.5, savedScale)) : 0.75;
    self.compilerQueue = dispatch_queue_create("app.romacshade.ios.compiler", DISPATCH_QUEUE_SERIAL);
    self.panel = [UIView new]; self.panel.backgroundColor = RMBackground();
    self.panel.layer.cornerRadius = 18; self.panel.layer.borderWidth = 1;
    self.panel.layer.borderColor = [UIColor colorWithWhite:0.32 alpha:1].CGColor;
    self.panel.layer.shadowColor = UIColor.blackColor.CGColor; self.panel.layer.shadowOpacity = 0.32;
    self.panel.layer.shadowRadius = 22; self.panel.layer.shadowOffset = CGSizeMake(0, 10);
    self.panel.clipsToBounds = YES; [self.view addSubview:self.panel];
    self.header = [UIView new]; self.header.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
    [self.panel addSubview:self.header];
    UILabel *title = RMLabel(@"RoMacShade", 18, YES); title.textColor = RMAccent(); title.tag = 101;
    [self.header addSubview:title];
    UIPanGestureRecognizer *panelPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)];
    panelPan.cancelsTouchesInView = NO; [title addGestureRecognizer:panelPan]; title.userInteractionEnabled = YES;
    UIButton *close = RMButton(@"×", ^{ [self setMenuVisible:NO animated:YES]; [self.view endEditing:YES]; });
    close.tag = 102; [self.header addSubview:close];
    self.master = RMButton(@"FX ON", ^{ [self toggleEffects]; }); self.master.tag = 103;
    self.master.layer.cornerRadius = 13; [self.header addSubview:self.master];
    self.tabs = [[UISegmentedControl alloc] initWithItems:@[@"Effects", @"Presets", @"Settings", @"Stats", @"About"]];
    [self.tabs setTitleTextAttributes:@{NSFontAttributeName:RMFont(11)} forState:UIControlStateNormal];
    self.tabs.selectedSegmentIndex = 0; self.tabs.selectedSegmentTintColor = RMAccent();
    [self.tabs addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
    [self.panel addSubview:self.tabs];
    self.search = [UISearchBar new]; self.search.placeholder = @"Search effects";
    self.search.delegate = self; self.search.searchBarStyle = UISearchBarStyleMinimal;
    self.search.searchTextField.font = RMFont(13); self.search.searchTextField.textColor = UIColor.whiteColor;
    [self.panel addSubview:self.search];
    self.scroll = [UIScrollView new]; self.scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.panel addSubview:self.scroll];
    self.content = [[UIStackView alloc] initWithArrangedSubviews:@[]]; self.content.axis = UILayoutConstraintAxisVertical;
    self.content.spacing = 8; self.content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scroll addSubview:self.content];
    [NSLayoutConstraint activateConstraints:@[
        [self.content.topAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.topAnchor constant:8],
        [self.content.bottomAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.bottomAnchor constant:-8],
        [self.content.leadingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.leadingAnchor constant:10],
        [self.content.trailingAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.trailingAnchor constant:-10],
        [self.content.widthAnchor constraintEqualToAnchor:self.scroll.frameLayoutGuide.widthAnchor constant:-20]]];
    self.status = RMLabel(@"Installing bundled library…", 11); self.status.numberOfLines = 2;
    self.status.textColor = [UIColor colorWithWhite:0.72 alpha:1]; [self.panel addSubview:self.status];
    self.launcher = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.launcher setTitle:@"R" forState:UIControlStateNormal];
    [self.launcher setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.launcher.titleLabel.font = RMFont(25, YES); self.launcher.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.96];
    self.launcher.layer.cornerRadius = 18; self.launcher.layer.borderWidth = 1.5;
    self.launcher.layer.borderColor = RMAccent().CGColor; self.launcher.layer.shadowColor = UIColor.blackColor.CGColor;
    self.launcher.layer.shadowOpacity = 0.35; self.launcher.layer.shadowRadius = 10;
    self.launcher.layer.shadowOffset = CGSizeMake(0, 4); self.launcher.accessibilityLabel = @"Open RoMacShade menu";
    UIView *indicator = [UIView new]; indicator.tag = 104; indicator.userInteractionEnabled = NO;
    indicator.backgroundColor = RMAccent(); indicator.layer.cornerRadius = 4;
    indicator.layer.borderWidth = 1; indicator.layer.borderColor = RMBackground().CGColor;
    [self.launcher addSubview:indicator];
    UIPanGestureRecognizer *launcherPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragLauncher:)];
    launcherPan.minimumNumberOfTouches = 1; launcherPan.maximumNumberOfTouches = 1;
    launcherPan.cancelsTouchesInView = YES; [self.launcher addGestureRecognizer:launcherPan];
    UITapGestureRecognizer *launcherTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleMenu:)];
    [self.launcher addGestureRecognizer:launcherTap];
    [self.view addSubview:self.launcher];
    self.panel.hidden = YES;
    NSError *failure = nil;
    MSSetSettings(MSNeutralSettings());
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    MSSetEnabled([defaults objectForKey:@"RoMacShadeEnabled"] ? [defaults boolForKey:@"RoMacShadeEnabled"] : YES);
    MSSetDepthReversed([defaults objectForKey:@"RoMacShadeReversedDepth"] ? [defaults boolForKey:@"RoMacShadeReversedDepth"] : YES);
    [self updateMasterButton];
    if (!MSInstallHooks(&failure)) self.status.text = failure.localizedDescription;
    [self render];
    dispatch_async(self.compilerQueue, ^{
        NSError *error = nil; NSURL *root = RMInstallPack(RMBundledPack(), &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!root) { self.status.text = error.localizedDescription; return; }
            self.libraryRoot = root; [self reloadLibrary]; [self render];
            NSURL *session = [RMUserLibrary().URLByDeletingLastPathComponent URLByAppendingPathComponent:@"Session.ini"];
            if ([NSFileManager.defaultManager fileExistsAtPath:session.path]) [self loadPreset:session];
            else self.status.text = @"Bundled library ready. Enter a 3D experience, then pick an effect or preset.";
        });
    });
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(tick) userInfo:nil repeats:YES];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews]; CGRect safe = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    CGFloat width = MIN(540, MAX(250, safe.size.width - 24));
    CGFloat height = MIN(700, MAX(260, safe.size.height - 100));
    if (!CGRectEqualToRect(self.previousBounds, self.view.bounds)) {
        CGPoint panelOrigin = self.panel.frame.origin;
        if (CGRectIsEmpty(self.panel.frame)) panelOrigin = CGPointMake(CGRectGetMinX(safe) + 12,
            CGRectGetMinY(safe) + MAX(12, (safe.size.height - height) * 0.5));
        panelOrigin.x = MIN(MAX(CGRectGetMinX(safe), panelOrigin.x), CGRectGetMaxX(safe) - width);
        panelOrigin.y = MIN(MAX(CGRectGetMinY(safe), panelOrigin.y), CGRectGetMaxY(safe) - height);
        self.panel.frame = CGRectMake(panelOrigin.x, panelOrigin.y, width, height);
        self.previousBounds = self.view.bounds;
    }
    CGFloat w = self.panel.bounds.size.width, h = self.panel.bounds.size.height;
    self.header.frame = CGRectMake(0, 0, w, 48);
    [self.header viewWithTag:101].frame = CGRectMake(14, 5, MAX(92, w - 156), 38);
    [self.header viewWithTag:103].frame = CGRectMake(w - 126, 7, 78, 34);
    [self.header viewWithTag:102].frame = CGRectMake(w - 42, 7, 34, 34);
    self.tabs.frame = CGRectMake(10, 55, w - 20, 34);
    BOOL home = self.tabs.selectedSegmentIndex == 0; self.search.hidden = !home;
    self.search.frame = CGRectMake(4, 91, w - 8, 42);
    CGFloat top = home ? 133 : 96;
    self.scroll.frame = CGRectMake(0, top, w, MAX(40, h - top - 50));
    self.status.frame = CGRectMake(12, h - 46, w - 24, 40);
    if (!self.launcherPositionLoaded) {
        NSString *savedPosition = [NSUserDefaults.standardUserDefaults stringForKey:@"RoMacShadeLauncherOrigin"];
        self.launcher.frame = savedPosition.length ? CGRectMake(CGPointFromString(savedPosition).x,
            CGPointFromString(savedPosition).y, 54, 54) : CGRectMake(CGRectGetMaxX(safe) - 66, CGRectGetMaxY(safe) - 72, 54, 54);
        self.launcherPositionLoaded = YES;
    }
    CGRect launcherFrame = self.launcher.frame;
    launcherFrame.origin.x = MIN(MAX(CGRectGetMinX(safe), launcherFrame.origin.x), CGRectGetMaxX(safe) - 54);
    launcherFrame.origin.y = MIN(MAX(CGRectGetMinY(safe), launcherFrame.origin.y), CGRectGetMaxY(safe) - 54);
    launcherFrame.size = CGSizeMake(54, 54); self.launcher.frame = launcherFrame;
    self.launcher.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.launcher.bounds cornerRadius:18].CGPath;
    self.launcher.layer.cornerCurve = kCACornerCurveContinuous;
    [self.launcher viewWithTag:104].frame = CGRectMake(39, 39, 9, 9);
}
- (void)drag:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) self.dragOrigin = self.panel.frame.origin;
    CGPoint delta = [gesture translationInView:self.view]; CGRect frame = self.panel.frame;
    CGRect safe = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    frame.origin.x = MIN(MAX(CGRectGetMinX(safe), self.dragOrigin.x + delta.x), CGRectGetMaxX(safe) - frame.size.width);
    frame.origin.y = MIN(MAX(CGRectGetMinY(safe), self.dragOrigin.y + delta.y), CGRectGetMaxY(safe) - frame.size.height);
    self.panel.frame = frame;
}
- (void)dragLauncher:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) self.launcherDragOrigin = self.launcher.frame.origin;
    CGPoint delta = [gesture translationInView:self.view]; CGRect frame = self.launcher.frame;
    CGRect safe = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    frame.origin.x = MIN(MAX(CGRectGetMinX(safe), self.launcherDragOrigin.x + delta.x), CGRectGetMaxX(safe) - frame.size.width);
    frame.origin.y = MIN(MAX(CGRectGetMinY(safe), self.launcherDragOrigin.y + delta.y), CGRectGetMaxY(safe) - frame.size.height);
    self.launcher.frame = frame;
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled)
        [NSUserDefaults.standardUserDefaults setObject:NSStringFromCGPoint(frame.origin) forKey:@"RoMacShadeLauncherOrigin"];
}
- (void)toggleMenu:(__unused UITapGestureRecognizer *)gesture { [self setMenuVisible:self.panel.hidden animated:YES]; }
- (void)setMenuVisible:(BOOL)visible animated:(BOOL)animated {
    if (visible) {
        self.panel.hidden = NO; self.panel.alpha = 0; self.panel.transform = CGAffineTransformMakeScale(0.97, 0.97);
    }
    void (^changes)(void) = ^{
        self.panel.alpha = visible ? 1 : 0;
        self.panel.transform = visible ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.97, 0.97);
        self.launcher.layer.borderColor = (visible ? UIColor.whiteColor : RMAccent()).CGColor;
    };
    void (^completion)(BOOL) = ^(BOOL finished) { (void)finished; self.panel.hidden = !visible; };
    if (animated) [UIView animateWithDuration:0.18 animations:changes completion:completion];
    else { changes(); completion(YES); }
}
- (void)toggleEffects {
    MSSetEnabled(!MSIsEnabled()); [self updateMasterButton];
    [NSUserDefaults.standardUserDefaults setBool:MSIsEnabled() forKey:@"RoMacShadeEnabled"];
}
- (void)updateMasterButton {
    BOOL enabled = MSIsEnabled(); [self.master setTitle:enabled ? @"FX ON" : @"FX OFF" forState:UIControlStateNormal];
    [self.master setTitleColor:enabled ? UIColor.blackColor : UIColor.whiteColor forState:UIControlStateNormal];
    self.master.backgroundColor = enabled ? RMAccent() : RMSurface();
    [self.launcher viewWithTag:104].backgroundColor = enabled ? RMAccent() : [UIColor colorWithWhite:0.48 alpha:1];
}
- (void)tabChanged { [self.view endEditing:YES]; [self render]; [self.view setNeedsLayout]; }
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    (void)searchBar; self.filter = searchText; [self render];
}
- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar { (void)searchBar; [self.view.window makeKeyWindow]; }
- (void)searchBarTextDidEndEditing:(UISearchBar *)searchBar { (void)searchBar; [self.hostWindow makeKeyWindow]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; }
- (void)add:(UIView *)view { [self.content addArrangedSubview:view]; }
- (void)presentMenu:(UIAlertController *)menu anchor:(UIView *)anchor {
    if (self.presentedViewController) return;
    menu.popoverPresentationController.sourceView = anchor ?: self.panel;
    menu.popoverPresentationController.sourceRect = (anchor ?: self.panel).bounds;
    [self.view.window makeKeyWindow]; [self presentViewController:menu animated:YES completion:nil];
}
- (void)message:(NSString *)text { self.status.text = text; }
- (NSArray<NSURL *> *)includeDirectories {
    NSMutableArray *roots = [NSMutableArray arrayWithObject:RMUserLibrary()];
    if (self.libraryRoot) [roots addObject:self.libraryRoot];
    NSMutableOrderedSet *directories = [NSMutableOrderedSet orderedSet];
    for (NSURL *root in roots) {
        [directories addObject:[root URLByAppendingPathComponent:@"Shaders"]];
        NSDirectoryEnumerator *iterator = [NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:nil
            options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
        for (NSURL *url in iterator) if ([url.pathExtension.lowercaseString isEqual:@"fxh"])
            [directories addObject:url.URLByDeletingLastPathComponent];
    }
    return directories.array;
}
- (void)reloadLibrary {
    NSMutableArray *roots = [NSMutableArray arrayWithObject:RMUserLibrary()];
    if (self.libraryRoot) [roots addObject:self.libraryRoot];
    // Imported shaders take priority over the bundled copy. INI references use
    // basenames, so presenting both copies would make preset resolution ambiguous.
    NSMutableArray *library = [NSMutableArray array]; NSMutableSet *names = [NSMutableSet set];
    for (NSDictionary *item in MSFXLibrary(roots)) {
        NSString *name = [item[@"url"] lastPathComponent].lowercaseString;
        if ([names containsObject:name]) continue;
        [names addObject:name]; [library addObject:item];
    }
    self.library = library;
    NSMutableArray *presets = [NSMutableArray array];
    for (NSURL *root in roots) {
        NSDirectoryEnumerator *iterator = [NSFileManager.defaultManager enumeratorAtURL:root includingPropertiesForKeys:nil
            options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
        for (NSURL *url in iterator) if ([url.pathExtension.lowercaseString isEqual:@"ini"]) [presets addObject:url];
    }
    [presets sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent]; }];
    self.presetURLs = presets;
}
- (void)render {
    for (UIView *view in self.content.arrangedSubviews) { [self.content removeArrangedSubview:view]; [view removeFromSuperview]; }
    switch (self.tabs.selectedSegmentIndex) {
        case 0: [self renderHome]; break;
        case 1: [self renderPresets]; break;
        case 2: [self renderSettings]; break;
        case 3: [self renderStats]; break;
        default: [self renderAbout]; break;
    }
}
- (void)renderHome {
    [self add:RMLabel(@"EFFECTS", 11, YES)];
    [self add:RMLabel([NSString stringWithFormat:@"%@ · %lu shaders available", self.presetTitle,
        (unsigned long)self.library.count], 12)];
    [self add:RMRow(@[RMButton(@"Import .fx", ^{ [self importFiles:NO]; }),
        RMButton(@"Import shader folder", ^{ [self importFiles:YES]; })])];
    NSMutableSet *active = [NSMutableSet set];
    for (NSDictionary *entry in self.entries) if ([entry[@"enabled"] boolValue]) [active addObject:[entry[@"url"] path]];
    for (NSDictionary *item in self.library) {
        NSURL *url = item[@"url"];
        if (self.filter.length && [url.lastPathComponent rangeOfString:self.filter options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        BOOL on = [active containsObject:url.path];
        UILabel *name = RMLabel(url.lastPathComponent, 12); name.lineBreakMode = NSLineBreakByTruncatingMiddle;
        UISwitch *toggle = [UISwitch new]; toggle.onTintColor = RMAccent(); toggle.on = on; toggle.enabled = !self.busy;
        [toggle addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { [self toggleURL:url]; }]
            forControlEvents:UIControlEventValueChanged];
        UIView *row = [UIView new]; row.backgroundColor = RMSurface(); row.layer.cornerRadius = 9;
        UIStackView *line = RMRow(@[name, toggle]); line.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:line]; [NSLayoutConstraint activateConstraints:@[
            [line.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12],
            [line.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-10],
            [line.topAnchor constraintEqualToAnchor:row.topAnchor constant:4],
            [line.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-4]]];
        RMHeight(row, 48); [self add:row];
    }
    if (!self.library.count) [self add:RMLabel(@"The effect library is being prepared. You can also import a shader folder.")];
}
- (BOOL)isBundledPreset:(NSURL *)url {
    NSString *root = self.libraryRoot.path.stringByStandardizingPath;
    NSString *candidate = url.path.stringByStandardizingPath;
    return root.length && [candidate hasPrefix:[root stringByAppendingString:@"/"]];
}
- (BOOL)isExtraviPreset:(NSURL *)url {
    if (![self isBundledPreset:url]) return NO;
    for (NSString *part in url.path.pathComponents) if ([part caseInsensitiveCompare:@"Extravi"] == NSOrderedSame) return YES;
    return NO;
}
- (NSString *)presetDisplayName:(NSURL *)url {
    NSString *name = url.lastPathComponent.stringByDeletingPathExtension;
    NSString *prefix = @"Extravi's ReShade-Preset ";
    if ([name hasPrefix:prefix]) name = [name substringFromIndex:prefix.length];
    return name;
}
- (void)addPresetRow:(NSURL *)url {
    BOOL selected = [self.activePresetURL.path isEqualToString:url.path];
    NSString *mark = selected ? @"✓  " : @"○  ";
    UIButton *row = RMButton([mark stringByAppendingString:[self presetDisplayName:url]], ^{ [self loadPreset:url]; });
    row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    row.titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    if (selected) { [row setTitleColor:RMAccent() forState:UIControlStateNormal]; row.layer.borderWidth = 1; row.layer.borderColor = RMAccent().CGColor; }
    row.enabled = !self.busy; [self add:row];
}
- (void)renderPresets {
    [self add:RMLabel(@"PRESETS", 11, YES)];
    [self add:RMLabel(@"Choose a ReShade preset to apply it. Imported presets appear alongside the bundled Extravi collection.", 12)];
    [self add:RMRow(@[RMButton(@"Import .ini", ^{ [self importFiles:NO]; }),
        RMButton(@"Save current", ^{ [self savePreset]; })])];
    UIButton *clear = RMButton(@"Clear effects", ^{
        self.presetTitle = @"Custom"; self.activePresetURL = nil; self.presetWarnings = nil; [self compile:@[]];
    });
    clear.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft; [self add:clear];

    NSMutableArray<NSURL *> *extravi = [NSMutableArray array], *samples = [NSMutableArray array], *personal = [NSMutableArray array];
    for (NSURL *url in self.presetURLs) {
        NSMutableArray<NSURL *> *target = [self isExtraviPreset:url] ? extravi : ([self isBundledPreset:url] ? samples : personal);
        [target addObject:url];
    }
    if (extravi.count) {
        UILabel *heading = RMLabel([NSString stringWithFormat:@"EXTRAVI PRESETS · %lu", (unsigned long)extravi.count], 11, YES);
        heading.textColor = RMAccent(); [self add:heading];
        for (NSURL *url in extravi) [self addPresetRow:url];
    }
    if (samples.count) {
        UILabel *heading = RMLabel([NSString stringWithFormat:@"ROMACSHADE SAMPLES · %lu", (unsigned long)samples.count], 11, YES);
        heading.textColor = RMAccent(); [self add:heading];
        for (NSURL *url in samples) [self addPresetRow:url];
    }
    UILabel *personalHeading = RMLabel([NSString stringWithFormat:@"MY PRESETS · %lu", (unsigned long)personal.count], 11, YES);
    personalHeading.textColor = RMAccent(); [self add:personalHeading];
    if (!personal.count) [self add:RMLabel(@"Imported and saved .ini files will appear here.", 12)];
    for (NSURL *url in personal) [self addPresetRow:url];
}
- (void)loadPreset:(NSURL *)url {
    NSError *error = nil; MSFXPreset *preset = [MSFXPreset presetWithURL:url error:&error];
    NSMutableArray *warnings = [NSMutableArray array];
    NSArray *specs = preset ? MSFXPresetSpecifications(preset, url, self.library, warnings, &error) : nil;
    if (!specs) { [self message:error.localizedDescription]; return; }
    self.activePresetURL = url;
    self.presetTitle = [url.lastPathComponent isEqual:@"Session.ini"] ? @"Last session" : [self presetDisplayName:url];
    self.presetWarnings = [warnings componentsJoinedByString:@"\n"];
    [self compile:specs];
}
- (void)toggleURL:(NSURL *)url {
    NSMutableArray *specs = [self.pendingSpecs ?: MSFXChainSpecifications(self.entries) mutableCopy]; BOOL removed = NO;
    for (NSInteger i = (NSInteger)specs.count - 1; i >= 0; --i)
        if ([specs[(NSUInteger)i][@"url"] isEqual:url]) { [specs removeObjectAtIndex:(NSUInteger)i]; removed = YES; }
    if (!removed) [specs addObject:@{@"url":url, @"enabled":@YES, @"technique":@"", @"values":@{}, @"strictValues":@NO}];
    self.presetTitle = @"Custom"; self.activePresetURL = nil; self.presetWarnings = nil; [self compile:specs];
}
- (void)compile:(NSArray<NSDictionary *> *)specs {
    const NSUInteger generation = ++self.generation;
    self.pendingSpecs = [specs copy];
    if (!self.libraryRoot) { self.busy = NO; [self message:@"Preset queued until the bundled library is ready."]; return; }
    if (!specs.count) {
        self.busy = NO; self.pendingSpecs = nil; self.entries = @[]; MSSetFXEffects(@[]);
        [self persist]; [self render]; [self message:@"Effects cleared."]; return;
    }
    NSDictionary *diagnostics = MSHookDiagnostics();
    NSUInteger drawableWidth = [diagnostics[@"drawableWidth"] unsignedIntegerValue];
    NSUInteger drawableHeight = [diagnostics[@"drawableHeight"] unsignedIntegerValue];
    if (!drawableWidth || !drawableHeight) { self.busy = NO; [self render]; [self message:@"Preset queued. Enter a 3D experience to apply it."]; return; }
    NSUInteger width = std::max<NSUInteger>(2, ((NSUInteger)std::round((double)drawableWidth * self.renderScale)) & ~(NSUInteger)1);
    NSUInteger height = std::max<NSUInteger>(2, ((NSUInteger)std::round((double)drawableHeight * self.renderScale)) & ~(NSUInteger)1);
    self.pendingSpecs = nil;
    self.busy = YES; [self message:@"Compiling effects…"]; [self render];
    NSArray *includes = [self includeDirectories]; NSArray *snapshot = [specs copy];
    dispatch_async(self.compilerQueue, ^{
        NSError *error = nil;
        NSArray *result = MSCompileFXChain(snapshot, MTLCreateSystemDefaultDevice(), width, height, includes, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation) return;
            self.busy = NO;
            if (!result) { [self message:error.localizedDescription ?: @"Effect compilation failed. Previous effects are still active."]; [self render]; return; }
            self.entries = result; self.compiledWidth = width; self.compiledHeight = height;
            NSMutableArray *enabled = [NSMutableArray array];
            for (NSDictionary *entry in result) if ([entry[@"enabled"] boolValue] && entry[@"effect"]) [enabled addObject:entry[@"effect"]];
            MSSetFXEffects(enabled); [self persist]; [self render];
            NSString *ready = [NSString stringWithFormat:@"%lu technique(s) active · %lu × %lu", (unsigned long)enabled.count, (unsigned long)width, (unsigned long)height];
            [self message:self.presetWarnings.length ? [ready stringByAppendingFormat:@"\n%@", self.presetWarnings] : ready];
        });
    });
}
- (void)persist {
    NSError *error = nil; NSString *text = MSFXChainPresetString(self.entries, &error);
    if (text) [text writeToURL:[RMUserLibrary().URLByDeletingLastPathComponent URLByAppendingPathComponent:@"Session.ini"]
        atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
- (void)renderSettings {
    if (self.busy) { [self add:RMLabel(@"Compiling the replacement chain…")]; return; }
    UILabel *qualityHeading = RMLabel(@"EFFECT RENDER SIZE", 11, YES);
    qualityHeading.textColor = RMAccent(); [self add:qualityHeading];
    UISegmentedControl *quality = [[UISegmentedControl alloc] initWithItems:@[@"100%", @"75%", @"50%"]];
    quality.selectedSegmentIndex = self.renderScale >= 0.875 ? 0 : (self.renderScale >= 0.625 ? 1 : 2);
    [quality addTarget:self action:@selector(renderScaleChanged:) forControlEvents:UIControlEventValueChanged];
    [self add:quality];
    [self add:RMLabel(@"Lower render size can improve speed, especially with SSR. It softens the image.", 11)];
    NSMutableArray<NSDictionary *> *active = [NSMutableArray array];
    for (NSDictionary *entry in self.entries) if (entry[@"effect"]) [active addObject:entry];
    if (!active.count) { [self add:RMLabel(@"Enable an effect in Home to edit its parameters.")]; return; }
    self.selectedEntry = MIN(self.selectedEntry, active.count - 1);
    NSDictionary *entry = active[self.selectedEntry]; MSFXEffect *effect = entry[@"effect"];
    UIButton *choose = RMButton(RMEntryTitle(entry), ^{
        UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Edit effect" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSUInteger i = 0; i < active.count; ++i) [menu addAction:[UIAlertAction actionWithTitle:RMEntryTitle(active[i])
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { self.selectedEntry = i; [self render]; }]];
        [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentMenu:menu anchor:self.panel];
    }); [self add:choose];
    NSMutableArray *techniques = [NSMutableArray array];
    for (NSString *name in effect.techniqueNames) [techniques addObject:[UIAction actionWithTitle:name image:nil identifier:nil
        handler:^(__unused UIAction *action) { NSError *error = nil; if (![effect selectTechniqueNamed:name error:&error]) [self message:error.localizedDescription]; else { [self persist]; [self render]; } }]];
    UIButton *technique = RMButton([@"Technique: " stringByAppendingString:effect.activeTechnique], nil);
    technique.menu = [UIMenu menuWithTitle:@"" children:techniques]; technique.showsMenuAsPrimaryAction = YES; [self add:technique];
    NSString *category = nil;
    for (NSDictionary *uniform in effect.uniforms) {
        if ([uniform[@"source"] length]) continue;
        NSString *group = [uniform[@"uiCategory"] length] ? uniform[@"uiCategory"] : @"Parameters";
        if (![category isEqual:group]) { UILabel *heading = RMLabel(group.uppercaseString, 11, YES); heading.textColor = RMAccent(); [self add:heading]; category = group; }
        [self addUniform:uniform effect:effect];
    }
    [self add:RMButton(@"Reset effect parameters", ^{
        for (NSDictionary *uniform in effect.uniforms) if (![uniform[@"source"] length]) [effect setUniformNamed:uniform[@"name"] values:uniform[@"defaultValues"] error:nil];
        [self persist]; [self render];
    })];
}
- (void)renderScaleChanged:(UISegmentedControl *)control {
    static const CGFloat scales[] = {1.0, 0.75, 0.5};
    NSInteger index = MAX(0, MIN(control.selectedSegmentIndex, 2));
    self.renderScale = scales[index];
    [NSUserDefaults.standardUserDefaults setDouble:self.renderScale forKey:@"RoMacShadeRenderScale"];
    if (!self.entries.count) {
        [self message:[NSString stringWithFormat:@"Render size set to %ld%%. Enable an effect to apply it.", (long)std::lround(self.renderScale * 100.0)]];
        [self render];
        return;
    }
    [self compile:MSFXChainSpecifications(self.entries)];
}
- (double)annotation:(id)value component:(NSUInteger)component fallback:(double)fallback {
    if ([value isKindOfClass:NSNumber.class]) return [value doubleValue];
    if ([value isKindOfClass:NSArray.class] && [value count] > component) return [value[component] doubleValue];
    return fallback;
}
- (void)addUniform:(NSDictionary *)uniform effect:(MSFXEffect *)effect {
    NSString *name = uniform[@"name"], *label = [uniform[@"uiLabel"] length] ? uniform[@"uiLabel"] : name;
    NSArray *values = uniform[@"values"], *items = uniform[@"uiItems"];
    NSString *type = uniform[@"type"]; BOOL boolean = [type isEqual:@"bool"];
    if (boolean && values.count == 1) {
        UISwitch *toggle = [UISwitch new]; toggle.onTintColor = RMAccent(); toggle.on = [values.firstObject boolValue];
        __weak UISwitch *weakToggle = toggle;
        [toggle addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
            [effect setUniformNamed:name values:@[@(weakToggle.on)] error:nil]; [self persist];
        }] forControlEvents:UIControlEventValueChanged]; [self add:RMRow(@[RMLabel(label), toggle])]; return;
    }
    if (items.count && values.count == 1) {
        NSUInteger index = MIN([values[0] unsignedIntegerValue], items.count - 1);
        UIButton *button = RMButton(items[index], nil); NSMutableArray *actions = [NSMutableArray array];
        for (NSUInteger i = 0; i < items.count; ++i) {
            UIAction *action = [UIAction actionWithTitle:items[i] image:nil identifier:nil handler:^(__unused UIAction *item) {
                [effect setUniformNamed:name values:@[@(i)] error:nil]; [self persist]; [self render];
            }]; action.state = index == i ? UIMenuElementStateOn : UIMenuElementStateOff; [actions addObject:action];
        }
        button.menu = [UIMenu menuWithTitle:@"" children:actions]; button.showsMenuAsPrimaryAction = YES;
        [self add:RMRow(@[RMLabel(label), button])]; return;
    }
    [self add:RMLabel(label)];
    NSString *tooltip = uniform[@"uiTooltip"];
    if (tooltip.length) { UILabel *help = RMLabel(tooltip, 11); help.textColor = [UIColor colorWithWhite:0.62 alpha:1]; [self add:help]; }
    BOOL integer = ![type hasPrefix:@"float"];
    BOOL color = [uniform[@"uiType"] isEqual:@"color"];
    for (NSUInteger component = 0; component < values.count; ++component) {
        double current = [values[component] doubleValue];
        double low = [self annotation:uniform[@"uiMin"] component:component fallback:color ? 0 : MIN(0, current - MAX(1, fabs(current)))];
        double high = [self annotation:uniform[@"uiMax"] component:component fallback:color ? 1 : MAX(1, current + MAX(1, fabs(current)))];
        double step = [self annotation:uniform[@"uiStep"] component:component fallback:integer ? 1 : 0];
        if (!std::isfinite(low) || !std::isfinite(high) || high <= low) { low = 0; high = 1; }
        UISlider *slider = [UISlider new]; slider.minimumValue = (float)low; slider.maximumValue = (float)high;
        slider.value = (float)current; slider.minimumTrackTintColor = RMAccent();
        UILabel *number = RMLabel([NSString stringWithFormat:integer ? @"%.0f" : @"%.3f", current], 12);
        [number.widthAnchor constraintEqualToConstant:64].active = YES;
        NSMutableArray *views = [NSMutableArray array];
        if (values.count > 1) { NSArray *names = color ? @[@"R", @"G", @"B", @"A"] : @[@"x", @"y", @"z", @"w"];
            UILabel *prefix = RMLabel(component < names.count ? names[component] : [NSString stringWithFormat:@"%lu", (unsigned long)component], 12);
            [prefix.widthAnchor constraintEqualToConstant:18].active = YES; [views addObject:prefix]; }
        [views addObjectsFromArray:@[slider, number]]; UIStackView *row = RMRow(views); RMHeight(row, 30); [self add:row];
        __weak UISlider *weakSlider = slider;
        [slider addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
            double value = weakSlider.value; if (step > 0 && std::isfinite(step)) value = low + round((value - low) / step) * step;
            if (integer) value = round(value); value = MIN(high, MAX(low, value));
            NSMutableArray *latest = nil;
            for (NSDictionary *info in effect.uniforms) if ([info[@"name"] isEqual:name]) { latest = [info[@"values"] mutableCopy]; break; }
            if (latest.count <= component) return; latest[component] = @(value);
            NSError *error = nil;
            if (![effect setUniformNamed:name values:latest error:&error]) [self message:error.localizedDescription];
            number.text = [NSString stringWithFormat:integer ? @"%.0f" : @"%.3f", value];
        }] forControlEvents:UIControlEventValueChanged];
        [slider addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { [self persist]; }]
            forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    }
}
- (void)renderStats {
    NSDictionary *stats = MSHookDiagnostics();
    [self add:RMLabel([NSString stringWithFormat:@"Drawable: %@ × %@\nAcquired frames: %@\nProcessed frames: %llu\nCompleted frames: %llu\nFX frames: %llu\nGPU errors: %llu\nDepth captures: %llu\n\n%@",
        stats[@"drawableWidth"], stats[@"drawableHeight"], stats[@"acquiredDrawables"],
        (unsigned long long)MSProcessedFrameCount(), (unsigned long long)MSCompletedFrameCount(),
        (unsigned long long)MSProcessedFXFrameCount(), (unsigned long long)MSGPUErrorCount(),
        (unsigned long long)MSDepthCaptureCount(), MSLastDepthStatus()])];
    UISwitch *reverse = [UISwitch new]; reverse.on = MSIsDepthReversed(); reverse.onTintColor = RMAccent();
    __weak UISwitch *weakReverse = reverse;
    [reverse addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        MSSetDepthReversed(weakReverse.on); [NSUserDefaults.standardUserDefaults setBool:weakReverse.on forKey:@"RoMacShadeReversedDepth"];
    }] forControlEvents:UIControlEventValueChanged];
    [self add:RMRow(@[RMLabel(@"Reversed depth (Roblox)"), reverse])];
}
- (void)renderAbout {
    [self add:RMLabel(@"RoMacShade", 24, YES)];
    [self add:RMLabel(@"Metal effects for iOS and iPadOS.\n\nArial menu with local .fx compilation and ReShade .ini presets. The bundled library works offline; no Maxey downloader or external file host is used.")];
    [self add:RMLabel(@"Effect authors retain their copyrights and source notices. qUINT: Pascal Gilcher / Marty McFly. Extravi presets: Extravi. ReShadeFX: crosire. SPIRV-Cross: Khronos and contributors.", 12)];
    [self add:RMButton(@"Open effect library on GitHub", ^{ [UIApplication.sharedApplication openURL:[NSURL URLWithString:RM_EFFECT_REPOSITORY] options:@{} completionHandler:nil]; })];
    [self add:RMButton(@"Restore library from project release", ^{
        [self message:@"Downloading the RoMacShade release pack…"];
        RMDownloadProjectPack([NSURL URLWithString:RM_EFFECT_PACK_URL], RM_PACK_SHA256,
            ^(NSURL *root, NSError *error) {
                if (!root) { [self message:error.localizedDescription]; return; }
                self.libraryRoot = root; [self reloadLibrary]; [self render]; [self message:@"Project release library installed."];
            });
    })];
}
- (void)tick {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSDictionary *stats = MSHookDiagnostics(); NSUInteger w = [stats[@"drawableWidth"] unsignedIntegerValue], h = [stats[@"drawableHeight"] unsignedIntegerValue];
    if (self.pendingSpecs && self.libraryRoot && w && h && !self.busy) [self compile:self.pendingSpecs];
    else if (self.entries.count && w && h && !self.busy && (w != self.compiledWidth || h != self.compiledHeight))
        [self compile:MSFXChainSpecifications(self.entries)];
    if (self.view.window.isKeyWindow && !self.presentedViewController && !self.search.searchTextField.isFirstResponder)
        [self.hostWindow makeKeyWindow];
    if (!self.panel.hidden && self.tabs.selectedSegmentIndex == 3) [self render];
}
- (void)importFiles:(BOOL)folder {
    self.selectingFolder = folder;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:folder ? @[UTTypeFolder] : @[UTTypeItem] asCopy:NO];
    picker.delegate = self; picker.allowsMultipleSelection = !folder; [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)URLs {
    (void)controller; BOOL folder = self.selectingFolder;
    dispatch_async(self.compilerQueue, ^{
        NSError *error = nil; NSURL *preset = nil;
        for (NSURL *url in URLs) {
            BOOL scoped = [url startAccessingSecurityScopedResource];
            NSURL *destination = nil;
            if (folder) destination = [RMUserLibrary() URLByAppendingPathComponent:[@"Imports/" stringByAppendingString:NSUUID.UUID.UUIDString]];
            else if ([url.pathExtension.lowercaseString isEqual:@"ini"]) {
                if (![MSFXPreset presetWithURL:url error:&error]) { if (scoped) [url stopAccessingSecurityScopedResource]; break; }
                destination = [[RMUserLibrary() URLByAppendingPathComponent:@"Presets"] URLByAppendingPathComponent:url.lastPathComponent];
            } else if ([@[@"fx", @"fxh"] containsObject:url.pathExtension.lowercaseString])
                destination = [[RMUserLibrary() URLByAppendingPathComponent:@"Shaders"] URLByAppendingPathComponent:url.lastPathComponent];
            if (destination) {
                [NSFileManager.defaultManager createDirectoryAtURL:destination.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error];
                if ([NSFileManager.defaultManager fileExistsAtPath:destination.path]) {
                    if ([url.pathExtension.lowercaseString isEqual:@"ini"]) {
                        destination = [destination.URLByDeletingLastPathComponent URLByAppendingPathComponent:
                            [NSString stringWithFormat:@"%@-%@.ini", url.lastPathComponent.stringByDeletingPathExtension,
                                [NSUUID.UUID.UUIDString substringToIndex:8]]];
                        [NSFileManager.defaultManager copyItemAtURL:url toURL:destination error:&error];
                    } else {
                        NSURL *stage = [destination.URLByDeletingLastPathComponent URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
                        if ([NSFileManager.defaultManager copyItemAtURL:url toURL:stage error:&error])
                            [NSFileManager.defaultManager replaceItemAtURL:destination withItemAtURL:stage backupItemName:nil options:0 resultingItemURL:nil error:&error];
                        [NSFileManager.defaultManager removeItemAtURL:stage error:nil];
                    }
                } else [NSFileManager.defaultManager copyItemAtURL:url toURL:destination error:&error];
                if ([destination.pathExtension.lowercaseString isEqual:@"ini"]) preset = destination;
            } else error = [NSError errorWithDomain:@"RoMacShade.Import" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Select .ini, .fx, .fxh files, or use Import folder for a complete shader library."}];
            if (scoped) [url stopAccessingSecurityScopedResource]; if (error) break;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.hostWindow makeKeyWindow];
            [self reloadLibrary]; [self render];
            if (error) [self message:error.localizedDescription];
            else if (preset) [self loadPreset:preset]; else [self message:@"Imported shader files. They are now available in Home."];
        });
    });
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller; [self.hostWindow makeKeyWindow];
}
- (void)savePreset {
    UIAlertController *dialog = [UIAlertController alertControllerWithTitle:@"Save preset" message:@"Creates a standard ReShade .ini in your local preset library." preferredStyle:UIAlertControllerStyleAlert];
    [dialog addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Preset name"; field.font = RMFont(14); }];
    [dialog addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *name = [dialog.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length || name.length > 64 || [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\:\n\r"]].location != NSNotFound || [name hasPrefix:@"."]) { [self message:@"Choose a preset name of 1–64 characters without slashes."]; return; }
        NSError *error = nil; NSString *text = MSFXChainPresetString(self.entries, &error);
        NSURL *url = [[RMUserLibrary() URLByAppendingPathComponent:@"Presets"] URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"ini"]];
        [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
            withIntermediateDirectories:YES attributes:nil error:&error];
        if (!text || ![text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&error]) { [self message:error.localizedDescription]; return; }
        self.activePresetURL = url; self.presetTitle = name; [self reloadLibrary]; [self render]; [self message:@"Preset saved."];
    }]];
    [dialog addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentMenu:dialog anchor:self.panel];
}
@end

static RMPassthroughWindow *RMWindow;
static void RMAttachWindows(void) {
    UIWindow *host = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows)
            if (candidate.isKeyWindow && ![candidate isKindOfClass:RMPassthroughWindow.class]) host = candidate;
        if (host) break;
    }
    // The supplied Roblox IPA uses the legacy UIApplication window lifecycle.
    // A scene-only attachment would never display its menu.
    if (!host) for (UIWindow *candidate in UIApplication.sharedApplication.windows)
        if (candidate.isKeyWindow && ![candidate isKindOfClass:RMPassthroughWindow.class]) { host = candidate; break; }
    if (!host) return;
    if (!RMWindow) {
        RMWindow = host.windowScene ? [[RMPassthroughWindow alloc] initWithWindowScene:host.windowScene]
                                   : [[RMPassthroughWindow alloc] initWithFrame:host.bounds];
        RMOverlay *overlay = [RMOverlay new]; overlay.hostWindow = host;
        RMWindow.rootViewController = overlay; RMWindow.windowLevel = UIWindowLevelAlert + 1;
        RMWindow.hidden = NO;
    } else {
        RMOverlay *overlay = (RMOverlay *)RMWindow.rootViewController;
        // One menu owns the process-wide effect chain, even across iPad scenes.
        if (RMWindow.windowScene != host.windowScene && !overlay.presentedViewController) {
            RMWindow.windowScene = host.windowScene; overlay.previousBounds = CGRectZero;
            [overlay.view setNeedsLayout];
        }
        overlay.hostWindow = host;
    }
}

__attribute__((constructor)) static void RMStart(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSError *error = nil;
        if (!MSInstallHooks(&error)) NSLog(@"RoMacShade: %@", error.localizedDescription);
        [NSNotificationCenter.defaultCenter addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) { RMAttachWindows(); }];
        [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) { RMAttachWindows(); }];
        [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *note) { RMAttachWindows(); }];
        RMAttachWindows();
    });
}
