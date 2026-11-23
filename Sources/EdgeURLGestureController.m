// SPDX-License-Identifier: MIT
//
// The trigger area on the desktop, done the way HomeBarURL does it.
//
// This dylib is loaded into SpringBoard and nowhere else. One window of its own
// carries both the drawing and the sensing. The drawing is a full-screen view
// that never takes a touch; the sensing is one transparent view per enabled edge,
// exactly the band's rect. The window answers -hitTest: with that view inside the
// band and with nil everywhere else, so a touch anywhere else on the desktop goes
// to the window below it, untouched.
//
// What ended the earlier attempts, so it is not tried again: UISystemGestureManager
// (its refusals locked SpringBoard's touches), and a SpringBoard window left up
// while an app was in front (the app then lost every touch, because a touch that
// reaches SpringBoard in the display's hit test cannot be handed back to another
// process). The window is hidden while anything but the desktop is on screen, so
// an app is never behind it.
//
// All hit testing is done in display coordinates, the screen's coordinate space.
#import "EdgeURLGestureController.h"

#import "EdgeURLIndicatorView.h"
#import "EdgeURLOverlayWindow.h"
#import "EdgeURLPanRecognizer.h"
#import "EdgeURLSettings.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <notify.h>
#import <os/log.h>
#import <fcntl.h>
#import <stdarg.h>
#import <unistd.h>

static const CFTimeInterval EdgeURLFadeDuration = 0.22;

// TEMPORARY diagnostic: os_log only answers live listeners, so the same lines
// also go to a file that survives the gesture.
static void EdgeURLDebugLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%.2f %@\n", CACurrentMediaTime(), message];
    const char *bytes = line.UTF8String;
    int fd = open("/var/mobile/Library/Caches/EdgeURL-debug.log", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        write(fd, bytes, strlen(bytes));
        close(fd);
    }
}

static CGFloat EdgeURLFraction(CGFloat value) {
    return MIN(1.0, MAX(0.0, value));
}

static os_log_t EdgeURLGestureLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create(APELIN_PACKAGE_ID, "gesture");
    });
    return log;
}

static os_log_t EdgeURLAnimationLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create(APELIN_PACKAGE_ID, "animation");
    });
    return log;
}

static os_log_t EdgeURLOpenLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create(APELIN_PACKAGE_ID, "open");
    });
    return log;
}

static NSString *EdgeURLChangedNotification(void) {
    return @APELIN_PACKAGE_ID "/changed";
}

static NSString *EdgeURLGestureName(EdgeURLEdge edge) {
    return edge == EdgeURLEdgeLeft ? @"left" : @"right";
}

@interface EdgeURLGestureController () <EdgeURLPanRecognizerDelegate>

@property (nonatomic, strong) EdgeURLIndicatorView *indicatorView;
@property (nonatomic, strong) EdgeURLOverlayWindow *overlayWindow;
@property (nonatomic, strong) NSArray<UIView *> *sensingViews;
@property (nonatomic, strong) NSMutableArray<EdgeURLPanRecognizer *> *recognizers;
@property (nonatomic, strong) CADisplayLink *fadeLink;
@property (nonatomic, strong) EdgeURLSettings *settings;

@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL watchdogStarted;
@property (nonatomic, assign) BOOL loggedWindows;

@property (nonatomic, assign) EdgeURLEdge activeEdge;
@property (nonatomic, assign) CGPoint touchDown;
@property (nonatomic, assign) CGPoint lastDisplayPoint;
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) BOOL brightened;

@property (nonatomic, assign) CGFloat fadeFromProgress;
@property (nonatomic, assign) CFTimeInterval fadeStartTime;

@end

@implementation EdgeURLGestureController

+ (instancetype)sharedController {
    static EdgeURLGestureController *controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        controller = [[EdgeURLGestureController alloc] init];
    });
    return controller;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sensingViews = @[];
        _recognizers = [NSMutableArray array];
        _activeEdge = EdgeURLEdgeLeft;
    }
    return self;
}

#pragma mark - Lifecycle

- (void)start {
    [self currentSettings];
    if (self.started) {
        [self reconcile];
        return;
    }
    self.started = YES;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(sceneDidChange:)
                   name:UISceneDidActivateNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(sceneDidChange:)
                   name:UISceneWillConnectNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(sceneDidChange:)
                   name:UISceneDidDisconnectNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(sceneDidChange:)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    EdgeURLPreferencesChanged,
                                    (__bridge CFStringRef)EdgeURLChangedNotification(),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    os_log(EdgeURLGestureLog(), "started %{public}s", self.settings.summary.UTF8String);
    EdgeURLDebugLog(@"started %@", self.settings.summary);
    [self reconcile];
    [self startWatchdog];
}

- (void)dealloc {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                       (__bridge const void *)self,
                                       (__bridge CFStringRef)EdgeURLChangedNotification(),
                                       NULL);
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

static void EdgeURLPreferencesChanged(CFNotificationCenterRef center,
                                      void *observer,
                                      CFStringRef name,
                                      const void *object,
                                      CFDictionaryRef userInfo) {
    (void)center;
    (void)name;
    (void)object;
    (void)userInfo;
    EdgeURLGestureController *controller = (__bridge EdgeURLGestureController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller preferencesChanged];
    });
}

// Two seconds apart, and each tick schedules the next one itself: the desktop
// comes and goes many times a session, and this is what notices a scene that was
// replaced while nothing was posted.
- (void)startWatchdog {
    if (self.watchdogStarted) {
        return;
    }
    self.watchdogStarted = YES;
    [self scheduleWatchdogTick];
}

- (void)scheduleWatchdogTick {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf watchdogTick];
    });
}

- (void)watchdogTick {
    if (!self.active) {
        [self reconcile];
    }
    [self scheduleWatchdogTick];
}

#pragma mark - Settings

- (EdgeURLSettings *)currentSettings {
    if (self.settings == nil) {
        self.settings = [EdgeURLSettings currentSettings];
    }
    return self.settings;
}

- (void)preferencesChanged {
    self.settings = [EdgeURLSettings currentSettings];
    os_log(EdgeURLGestureLog(), "preferences reloaded %{public}s", self.settings.summary.UTF8String);
    EdgeURLDebugLog(@"prefs changed %@", self.settings.summary);
    if (!self.settings.enabled && self.active) {
        [self finishWithProgress:self.indicatorView.progress opens:NO];
    }
    [self reconcile];
}

#pragma mark - Attachment

// SpringBoard has several window scenes on the main screen — the System Aperture
// (Dynamic Island) one among them — and its own is the plain SBWindowScene; the
// auxiliary ones must be skipped.
static BOOL EdgeURLSceneIsAuxiliary(NSString *className) {
    return [className containsString:@"Aperture"] ||
           [className containsString:@"Banner"] ||
           [className containsString:@"Curtain"] ||
           [className containsString:@"Service"] ||
           [className containsString:@"StatusBar"] ||
           [className containsString:@"Keyboard"];
}

- (UIWindowScene *)mainScene {
    UIWindowScene *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]] ||
            scene.activationState == UISceneActivationStateUnattached) {
            continue;
        }
        if (EdgeURLSceneIsAuxiliary(NSStringFromClass([scene class]))) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.screen == [UIScreen mainScreen]) {
            return windowScene;
        }
        if (fallback == nil) {
            fallback = windowScene;
        }
    }
    return fallback;
}

// The trigger area belongs to the desktop, so it is on screen exactly while the
// desktop is: not while an app is in front, and not over the lock screen.
- (BOOL)shouldShowInScene:(UIWindowScene *)scene {
    if (scene == nil) {
        return NO;
    }
    if ([self coverSheetIsUpInScene:scene]) {
        return NO;
    }
    return [self homeScreenIsShowingInScene:scene];
}

- (BOOL)homeScreenIsShowingInScene:(UIWindowScene *)scene {
    for (UIWindow *window in scene.windows) {
        if (![NSStringFromClass([window class]) containsString:@"HomeScreen"]) {
            continue;
        }
        if (!window.hidden && window.alpha > 0.01) {
            return YES;
        }
    }
    // A hidden home screen window is an app in front; no home screen window at
    // all is SpringBoard still starting up. Neither is the place to draw.
    return NO;
}

// The lock screen is another window of the same scene, and the band belongs to
// the screen behind it, not over it.
- (BOOL)coverSheetIsUpInScene:(UIWindowScene *)scene {
    for (UIWindow *window in scene.windows) {
        if (![NSStringFromClass([window class]) containsString:@"CoverSheet"]) {
            continue;
        }
        if (!window.hidden && window.alpha > 0.01) {
            return YES;
        }
    }
    return NO;
}

#pragma mark - Geometry

- (CGRect)displayBounds {
    return [UIScreen mainScreen].coordinateSpace.bounds;
}

// The sensing area, and the band that is drawn, from one place: the edge setting
// says which edges, the width setting says how wide, and the region says how far
// down the edge.
- (CGRect)bandRectForSettings:(EdgeURLSettings *)settings left:(BOOL)left {
    CGRect display = [self displayBounds];
    CGFloat displayWidth = CGRectGetWidth(display);
    CGFloat displayHeight = CGRectGetHeight(display);
    if (displayWidth < 2.0 || displayHeight < 2.0) {
        return CGRectZero;
    }
    CGFloat band = MIN(MAX(settings.edgeWidth, 6.0), displayWidth * 0.5);
    CGFloat top = CGRectGetMinY(display) + displayHeight * settings.regionTop / 100.0;
    CGFloat height = displayHeight * settings.regionHeight / 100.0;
    height = MAX(1.0, MIN(height, CGRectGetMaxY(display) - top));
    CGFloat x = left ? CGRectGetMinX(display) : CGRectGetMaxX(display) - band;
    return CGRectMake(x, top, band, height);
}

- (CGPoint)displayPointForViewPoint:(CGPoint)point inView:(UIView *)view {
    if (view == nil) {
        return point;
    }
    return [view convertPoint:point toCoordinateSpace:[UIScreen mainScreen].coordinateSpace];
}

- (CGPoint)displayPointForRecognizer:(EdgeURLPanRecognizer *)recognizer {
    UIView *view = recognizer.view;
    if (view == nil) {
        return [recognizer locationInView:nil];
    }
    return [self displayPointForViewPoint:[recognizer locationInView:view] inView:view];
}

- (CGPoint)viewPointForDisplayPoint:(CGPoint)point {
    UIView *host = self.indicatorView.superview;
    if (host == nil) {
        return point;
    }
    return [host convertPoint:point fromCoordinateSpace:[UIScreen mainScreen].coordinateSpace];
}

- (BOOL)displayPoint:(CGPoint)point isInBandWithSettings:(EdgeURLSettings *)settings edge:(EdgeURLEdge *)edge {
    for (NSInteger index = 0; index < 2; index++) {
        BOOL left = (index == 0);
        if (left && !settings.leftEdge) {
            continue;
        }
        if (!left && !settings.rightEdge) {
            continue;
        }
        if (CGRectContainsPoint([self bandRectForSettings:settings left:left], point)) {
            if (edge != NULL) {
                *edge = left ? EdgeURLEdgeLeft : EdgeURLEdgeRight;
            }
            return YES;
        }
    }
    return NO;
}

// How far the finger has moved away from the edge it came from, never negative.
- (CGFloat)travelForPoint:(CGPoint)point edge:(EdgeURLEdge)edge {
    CGFloat travel = (edge == EdgeURLEdgeLeft) ? (point.x - self.touchDown.x)
                                              : (self.touchDown.x - point.x);
    return MAX(0.0, travel);
}

#pragma mark - Overlay

- (void)reconcile {
    UIWindowScene *scene = [self mainScene];
    if (scene == nil) {
        EdgeURLDebugLog(@"no window scene yet");
        return;
    }
    BOOL show = [self shouldShowInScene:scene];
    [self updateOverlayForScene:scene shown:show];
    if (!show && self.active) {
        // The desktop left the screen while a swipe was running: drop it.
        self.active = NO;
    }
    if (!self.loggedWindows) {
        self.loggedWindows = YES;
        [self logDesktopStateInScene:scene shown:show];
    }
}

// EdgeURL's window: created once per scene, hidden whenever the desktop is not
// what the screen shows. A scene that is replaced — on a respring, and around
// lock and unlock — takes the window with it, and a new one is made here.
- (void)updateOverlayForScene:(UIWindowScene *)scene shown:(BOOL)show {
    if (self.overlayWindow != nil && self.overlayWindow.windowScene != scene) {
        [self detachRecognizers];
        self.overlayWindow.hidden = YES;
        self.overlayWindow = nil;
        EdgeURLDebugLog(@"overlay window dropped with its scene");
    }
    BOOL created = NO;
    if (self.overlayWindow == nil) {
        EdgeURLOverlayWindow *window = [[EdgeURLOverlayWindow alloc] initWithWindowScene:scene];
        window.frame = [self displayBounds];
        self.overlayWindow = window;
        self.indicatorView.frame = window.bounds;
        self.indicatorView.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        window.displayView = self.indicatorView;
        [window addSubview:self.indicatorView];
        [self createSensingViewsForWindow:window];
        window.hidden = !show;
        created = YES;
        EdgeURLDebugLog(@"overlay window ready level=%.1f bounds=%@",
                        window.windowLevel, NSStringFromCGRect(window.bounds));
    } else if (self.overlayWindow.hidden != (!show)) {
        self.overlayWindow.hidden = !show;
        EdgeURLDebugLog(@"overlay window %@", show ? @"shown" : @"hidden");
    }
    if (self.overlayWindow.frame.size.width < 2.0 ||
        self.overlayWindow.frame.size.height < 2.0) {
        self.overlayWindow.frame = [self displayBounds];
    }
    [self updateSensingViewsShown:show];
    if (created) {
        [self updateTriggerAreas];
    }
}

// One transparent view per edge, and one recognizer on each. They are made once
// and only resized afterwards, so a running touch can never lose the view it
// started on.
- (void)createSensingViewsForWindow:(EdgeURLOverlayWindow *)window {
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    for (NSInteger index = 0; index < 2; index++) {
        UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
        view.backgroundColor = [UIColor clearColor];
        view.opaque = NO;
        view.hidden = YES;
        [window addSubview:view];
        EdgeURLPanRecognizer *recognizer =
            [[EdgeURLPanRecognizer alloc] initWithTarget:self action:@selector(handleEdgePan:)];
        recognizer.edgeDelegate = self;
        [view addGestureRecognizer:recognizer];
        [self.recognizers addObject:recognizer];
        [views addObject:view];
    }
    self.sensingViews = views;
    window.sensingViews = views;
}

- (void)detachRecognizers {
    for (EdgeURLPanRecognizer *recognizer in self.recognizers) {
        UIView *view = recognizer.view;
        if (view != nil) {
            [view removeGestureRecognizer:recognizer];
        }
    }
    [self.recognizers removeAllObjects];
    self.sensingViews = @[];
}

// The sensing rects follow the settings: the same rect the band is drawn in, so
// the area that is visible and the area that answers a finger cannot disagree.
- (void)updateSensingViewsShown:(BOOL)shown {
    EdgeURLSettings *settings = [self currentSettings];
    for (NSInteger index = 0; index < (NSInteger)self.sensingViews.count; index++) {
        BOOL left = (index == 0);
        UIView *view = self.sensingViews[(NSUInteger)index];
        BOOL on = shown && settings.enabled &&
                  (left ? settings.leftEdge : settings.rightEdge);
        CGRect rect = on ? [self bandRectForSettings:settings left:left] : CGRectZero;
        if (on && !CGRectEqualToRect(view.frame, rect)) {
            view.frame = rect;
            EdgeURLDebugLog(@"sensing %@ frame=%@", left ? @"left" : @"right",
                            NSStringFromCGRect(rect));
        }
        if (view.hidden == on) {
            view.hidden = !on;
            EdgeURLDebugLog(@"sensing %@ %@", left ? @"left" : @"right",
                            on ? @"armed" : @"dormant");
        }
    }
    [self updateTriggerAreas];
}

// TEMPORARY diagnostic: what the desktop's scene holds, so a window of another
// tweak that sits above this one can be named.
- (void)logDesktopStateInScene:(UIWindowScene *)scene shown:(BOOL)show {
    EdgeURLDebugLog(@"scene %@ state=%ld show=%d",
                    NSStringFromClass([scene class]), (long)scene.activationState, show);
    for (UIWindow *window in scene.windows) {
        if (window.windowLevel < 900.0 && ![NSStringFromClass([window class]) containsString:@"HomeScreen"]) {
            continue;
        }
        EdgeURLDebugLog(@"  win %@ level=%.1f hidden=%d alpha=%.2f frame=%@",
                        NSStringFromClass([window class]), window.windowLevel,
                        window.hidden, window.alpha, NSStringFromCGRect(window.frame));
        os_log(EdgeURLGestureLog(), "win %{public}@ level=%.1f hidden=%d",
               NSStringFromClass([window class]), window.windowLevel, window.hidden);
    }
}

- (void)sceneDidChange:(NSNotification *)notification {
    [self reconcile];
}

#pragma mark - EdgeURLPanRecognizerDelegate

- (BOOL)panRecognizer:(EdgeURLPanRecognizer *)recognizer
    wantsTouchDownAtPointInView:(CGPoint)point
                          edge:(EdgeURLEdge *)edge {
    EdgeURLSettings *settings = [self currentSettings];
    if (!settings.enabled || settings.URL == nil) {
        return NO;
    }
    // One swipe at a time: both edge views can hold a recognizer, and this one
    // gesture must not be run twice.
    if (self.active) {
        return NO;
    }
    CGPoint display = [self displayPointForViewPoint:point inView:recognizer.view];
    EdgeURLEdge found = EdgeURLEdgeLeft;
    if (![self displayPoint:display isInBandWithSettings:settings edge:&found]) {
        return NO;
    }
    if (edge != NULL) {
        *edge = found;
    }
    EdgeURLDebugLog(@"touch down (%.1f,%.1f) edge=%d",
                    display.x, display.y, (int)found);
    return YES;
}

#pragma mark - Swipe

- (void)handleEdgePan:(EdgeURLPanRecognizer *)recognizer {
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
            [self beginEdgePan:recognizer];
            break;
        case UIGestureRecognizerStateChanged:
            [self updateEdgePan:recognizer];
            break;
        case UIGestureRecognizerStateEnded:
            [self endEdgePan:recognizer cancelled:NO];
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self endEdgePan:recognizer cancelled:YES];
            break;
        default:
            break;
    }
}

- (void)beginEdgePan:(EdgeURLPanRecognizer *)recognizer {
    EdgeURLSettings *settings = [self currentSettings];
    self.activeEdge = recognizer.trackedEdge;
    self.touchDown = [self displayPointForViewPoint:recognizer.startPoint
                                             inView:recognizer.view];
    self.active = YES;
    self.brightened = NO;
    [self stopFade];

    if ([self prepareIndicatorWithSettings:settings]) {
        EdgeURLIndicatorView *view = self.indicatorView;
        view.previewMode = NO;
        view.edge = self.activeEdge;
        view.progress = 0.0;
        view.alpha = 1.0;
        [view setNeedsDisplay];
    }
    [self updateEdgePan:recognizer];

    os_log(EdgeURLGestureLog(), "tracking edge=%{public}s down=(%.1f,%.1f)",
           EdgeURLGestureName(self.activeEdge).UTF8String,
           self.touchDown.x, self.touchDown.y);
    EdgeURLDebugLog(@"tracking edge=%d down=(%.1f,%.1f) window=%@",
                    (int)self.activeEdge, self.touchDown.x, self.touchDown.y,
                    NSStringFromClass([recognizer.view.window class]));
}

- (CGFloat)progressForTravel:(CGFloat)travel settings:(EdgeURLSettings *)settings {
    CGFloat threshold = MAX(settings.threshold, 1.0);
    return MIN(1.0, MAX(0.0, travel / threshold));
}

- (void)updateEdgePan:(EdgeURLPanRecognizer *)recognizer {
    if (!self.active) {
        return;
    }
    EdgeURLSettings *settings = [self currentSettings];
    CGPoint display = [self displayPointForRecognizer:recognizer];
    self.lastDisplayPoint = display;
    CGFloat travel = [self travelForPoint:display edge:self.activeEdge];
    CGFloat progress = [self progressForTravel:travel settings:settings];

    EdgeURLIndicatorView *view = self.indicatorView;
    view.touchY = [self viewPointForDisplayPoint:display].y;
    view.progress = progress;
    [view setNeedsDisplay];

    if (progress >= 1.0 && !self.brightened) {
        self.brightened = YES;
        UIImpactFeedbackGenerator *generator =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [generator impactOccurred];
        os_log(EdgeURLAnimationLog(), "wave at full brightness travel=%.1f threshold=%.1f",
               travel, settings.threshold);
    } else if (progress < 1.0) {
        self.brightened = NO;
    }
}

- (void)endEdgePan:(EdgeURLPanRecognizer *)recognizer cancelled:(BOOL)cancelled {
    if (!self.active) {
        return;
    }
    EdgeURLSettings *settings = [self currentSettings];
    CGPoint display = [self displayPointForRecognizer:recognizer];
    if (!CGPointEqualToPoint(display, CGPointZero)) {
        self.lastDisplayPoint = display;
    }
    CGFloat travel = [self travelForPoint:self.lastDisplayPoint edge:self.activeEdge];
    CGFloat progress = [self progressForTravel:travel settings:settings];
    BOOL opens = (!cancelled && travel >= settings.minimumTravel &&
                  settings.enabled && settings.URL != nil);

    os_log(EdgeURLGestureLog(),
           "end edge=%{public}s travel=%.1f minTravel=%.1f cancelled=%d opens=%d",
           EdgeURLGestureName(self.activeEdge).UTF8String, travel,
           settings.minimumTravel, cancelled, opens);
    EdgeURLDebugLog(@"end edge=%d travel=%.1f opens=%d", (int)self.activeEdge, travel, opens);

    [self finishWithProgress:progress opens:opens];
}

- (void)finishWithProgress:(CGFloat)progress opens:(BOOL)opens {
    EdgeURLSettings *settings = [self currentSettings];
    self.active = NO;
    [self recedeFromProgress:MAX(EdgeURLFraction(progress), 0.25)];
    if (opens) {
        // The wave recedes first: opening straight away would hide the desktop,
        // and the animation with it, before it had been seen.
        NSURL *url = settings.URL;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self openURL:url];
        });
    }
}

#pragma mark - Opening

- (void)openURL:(NSURL *)url {
    if (url == nil) {
        return;
    }
    os_log(EdgeURLOpenLog(), "opening %{public}s", url.absoluteString.UTF8String);
    EdgeURLDebugLog(@"opening %@", url.absoluteString);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *application = [UIApplication sharedApplication];
        [application openURL:url
                     options:@{}
           completionHandler:^(BOOL success) {
               os_log(EdgeURLOpenLog(), "opened %{public}s success=%d",
                      url.absoluteString.UTF8String, success);
           }];
    });
}

#pragma mark - Indicator

- (EdgeURLIndicatorView *)indicatorView {
    if (_indicatorView == nil) {
        _indicatorView = [[EdgeURLIndicatorView alloc] initWithFrame:[self displayBounds]];
        _indicatorView.userInteractionEnabled = NO;
    }
    return _indicatorView;
}

// The view is hosted in EdgeURL's own window, so it lives exactly as long as the
// desktop is on show. Geometry comes from the settings, once.
- (BOOL)prepareIndicatorWithSettings:(EdgeURLSettings *)settings {
    if (self.overlayWindow == nil || self.indicatorView.superview == nil) {
        return NO;
    }
    CGRect bounds = self.overlayWindow.bounds;
    if (CGRectGetWidth(bounds) < 2.0 || CGRectGetHeight(bounds) < 2.0) {
        return NO;
    }
    if (!CGRectEqualToRect(self.indicatorView.frame, bounds)) {
        self.indicatorView.frame = bounds;
    }
    EdgeURLIndicatorView *view = self.indicatorView;
    view.bandWidth = settings.edgeWidth;
    view.regionTop = settings.regionTop;
    view.regionHeight = settings.regionHeight;
    view.areaAlpha = settings.areaAlpha;
    view.showArea = settings.showArea;
    view.animatedStyle = settings.animated;
    view.leftEdgeEnabled = settings.leftEdge;
    view.rightEdgeEnabled = settings.rightEdge;
    return YES;
}

// The trigger area, drawn on every enabled edge and left there: no timer, no
// fade. It is the same rect a swipe is sensed in, so the setting and the gesture
// cannot disagree about where the edge is.
- (void)updateTriggerAreas {
    EdgeURLSettings *settings = [self currentSettings];
    if (![self prepareIndicatorWithSettings:settings]) {
        return;
    }
    if (self.active) {
        return;  // A swipe is drawing its own wave over the band.
    }
    [self stopFade];
    EdgeURLIndicatorView *view = self.indicatorView;
    view.previewMode = YES;
    view.edge = settings.leftEdge ? EdgeURLEdgeLeft : EdgeURLEdgeRight;
    view.progress = 0.0;
    view.alpha = 1.0;
    [view setNeedsDisplay];

    os_log(EdgeURLAnimationLog(),
           "trigger areas shown left=%d right=%d alpha=%.2f width=%.1f top=%.1f height=%.1f",
           settings.leftEdge, settings.rightEdge, settings.areaAlpha,
           settings.edgeWidth, settings.regionTop, settings.regionHeight);
    EdgeURLDebugLog(@"band shown left=%d right=%d alpha=%.2f show=%d hidden=%d",
                    settings.leftEdge, settings.rightEdge, settings.areaAlpha,
                    settings.showArea, self.overlayWindow.hidden);
}

// The wave goes back the way it came: the capsule shrinks into the edge, and
// only the last part of that fades out. This is how Android's back gesture
// leaves the screen, and it reads as the finger pulling the wave back rather
// than a bar blinking off.
- (void)recedeFromProgress:(CGFloat)progress {
    if (self.indicatorView.superview == nil) {
        return;
    }
    self.fadeFromProgress = MIN(1.0, MAX(0.0, progress));
    self.fadeStartTime = CACurrentMediaTime();
    [self stopFade];
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(stepRecede:)];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.fadeLink = link;
}

- (void)stepRecede:(CADisplayLink *)link {
    CFTimeInterval elapsed = CACurrentMediaTime() - self.fadeStartTime;
    CGFloat unit = EdgeURLFadeDuration > 0.0 ? (CGFloat)(elapsed / EdgeURLFadeDuration) : 1.0;
    CGFloat t = MIN(1.0, MAX(0.0, unit));
    // Ease out, so the wave shoots back towards the edge and settles there.
    CGFloat eased = 1.0 - pow(1.0 - t, 3.0);
    self.indicatorView.progress = self.fadeFromProgress * (1.0 - eased);
    CGFloat remaining = (t > 0.55) ? (1.0 - (t - 0.55) / 0.45) : 1.0;
    self.indicatorView.alpha = MIN(1.0, MAX(0.0, remaining));
    [self.indicatorView setNeedsDisplay];
    if (t >= 1.0) {
        [self stopFade];
        self.indicatorView.alpha = 1.0;
        self.indicatorView.progress = 0.0;
        // The wave is gone; the trigger area it covered comes back.
        [self updateTriggerAreas];
    }
}

- (void)stopFade {
    if (self.fadeLink != nil) {
        [self.fadeLink invalidate];
        self.fadeLink = nil;
    }
}

@end
