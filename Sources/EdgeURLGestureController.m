// SPDX-License-Identifier: MIT
//
// The trigger area on the desktop, done the way HomeBarURL does it.
//
// This dylib is loaded into SpringBoard and nowhere else. Everything it draws
// lives inside SpringBoard's own home screen window, which the display keeps
// below every app's window: the band and the wave are therefore covered by an
// app by the mere fact of the window order, and no touch of an app can ever
// reach this tweak — not in the band, not anywhere.
//
// What ended the earlier attempts, so it is not tried again: UISystemGestureManager
// (its refusals locked SpringBoard's touches), and a window of this tweak's own
// above the apps (a touch that reaches SpringBoard in the display's hit test
// cannot be handed back to another process, so the app lost it for good).
//
// The swipe itself is watched by recognizers attached to SpringBoard's own
// desktop windows: those windows already receive the desktop's touches, and the
// recognizers cancel nothing (cancelsTouchesInView = NO, and neither can prevent
// nor be prevented), so icons, page scrolling and every other gesture under the
// finger work as before.
//
// All hit testing is done in display coordinates, the screen's coordinate space.
#import "EdgeURLGestureController.h"

#import "EdgeURLIndicatorView.h"
#import "EdgeURLPanRecognizer.h"
#import "EdgeURLSettings.h"

#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <os/log.h>
#import <fcntl.h>
#import <stdarg.h>
#import <unistd.h>
#import <dlfcn.h>

// The wave goes back into the edge in this long; Android's own cancel takes a
// little less than a fifth of a second.
static const CFTimeInterval EdgeURLFadeDuration = 0.18;

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
/// SpringBoard's home screen window: what this tweak draws into, and the window
/// the display keeps below every app.
@property (nonatomic, strong) UIView *desktopView;
@property (nonatomic, strong) NSArray<UIView *> *hostWindows;
@property (nonatomic, strong) NSMutableArray<EdgeURLPanRecognizer *> *recognizers;
@property (nonatomic, strong) CADisplayLink *fadeLink;
@property (nonatomic, strong) EdgeURLSettings *settings;

@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL watchdogStarted;
@property (nonatomic, assign) BOOL loggedWindows;

@property (nonatomic, copy) NSString *bandStateKey;
@property (nonatomic, copy) NSString *gateStateKey;

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
        _hostWindows = @[];
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

// Six tenths of a second apart, and each tick schedules the next one itself: the
// desktop window is rebuilt across lock, unlock and respring, and this is what
// puts the drawing back into the new one. It only keeps the drawing in step with
// what is on screen — touches are handled by the desktop's own recognizers, so a
// late tick can never take one.
- (void)startWatchdog {
    if (self.watchdogStarted) {
        return;
    }
    self.watchdogStarted = YES;
    [self scheduleWatchdogTick];
}

- (void)scheduleWatchdogTick {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
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

// The desktop is on screen exactly while its own window is not covered by an app
// or by the lock screen. Drawing does not depend on this — it is inside the home
// screen window, so an app covers it whatever this says — but the trigger must
// not fire from inside an app.
- (BOOL)shouldShowInScene:(UIWindowScene *)scene {
    if (scene == nil) {
        return NO;
    }
    // The home screen window is hidden while an app is in front and while the
    // lock screen is up. Nothing else is asked: a touch from inside an app never
    // reaches these recognizers anyway, since they live on SpringBoard's windows.
    return [self homeScreenIsShowingInScene:scene];
}

- (BOOL)homeScreenIsShowingInScene:(UIWindowScene *)scene {
    UIWindow *desktop = (UIWindow *)[self desktopViewInScene:scene];
    if (desktop == nil) {
        return NO;
    }
    return !desktop.hidden && desktop.alpha > 0.01;
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

// The sensing area, and the bar that is drawn, from one place: the edge setting
// says which edges, the width setting says how wide, the region says where along
// the edge and how much of it the bar may take. Nothing else on the desktop is
// watched or drawn.
- (CGRect)sensingRectForSettings:(EdgeURLSettings *)settings left:(BOOL)left {
    return EdgeURLSensingRect([self displayBounds], left, settings.edgeWidth,
                              settings.regionTop, settings.regionHeight);
}

- (CGPoint)displayPointForViewPoint:(CGPoint)point inView:(UIView *)view {
    if (view == nil) {
        return point;
    }
    // A window that has just left its scene reports no window; these watchers sit
    // on full-screen windows whose own space is the display, so the point needs
    // no conversion then.
    if (view.window == nil) {
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

- (BOOL)displayPoint:(CGPoint)point isInSensingAreaWithSettings:(EdgeURLSettings *)settings edge:(EdgeURLEdge *)edge {
    for (NSInteger index = 0; index < 2; index++) {
        BOOL left = (index == 0);
        if (left && !settings.leftEdge) {
            continue;
        }
        if (!left && !settings.rightEdge) {
            continue;
        }
        CGRect area = [self sensingRectForSettings:settings left:left];
        if (CGRectGetWidth(area) < 1.0 || CGRectGetHeight(area) < 1.0) {
            continue;
        }
        if (CGRectContainsPoint(area, point)) {
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

#pragma mark - Host

// The home screen window, found by name in SpringBoard's own scene. It carries
// the wallpaper and the icons at a window level below every app's, which is what
// makes it the one place a desktop overlay can live without ever coming between
// an app and a touch.
- (UIView *)desktopViewInScene:(UIWindowScene *)scene {
    UIWindow *best = nil;
    for (UIWindow *window in scene.windows) {
        if (![NSStringFromClass([window class]) containsString:@"HomeScreen"]) {
            continue;
        }
        if (CGRectGetWidth(window.bounds) < 2.0 || CGRectGetHeight(window.bounds) < 2.0) {
            continue;
        }
        if (best == nil || window.windowLevel < best.windowLevel) {
            best = window;
        }
    }
    return best;
}

- (void)reconcile {
    UIWindowScene *scene = [self mainScene];
    if (scene == nil) {
        EdgeURLDebugLog(@"no window scene yet");
        return;
    }
    [self attachToDesktopInScene:scene];
    [self syncRecognizersInScene:scene];
    [self updateTriggerAreas];
    if (!self.loggedWindows) {
        self.loggedWindows = YES;
        [self logDesktopStateInScene:scene];
    }
    [self logGateStateInScene:scene];
}

- (void)attachToDesktopInScene:(UIWindowScene *)scene {
    UIView *desktop = [self desktopViewInScene:scene];
    if (desktop == nil) {
        [self.indicatorView removeFromSuperview];
        self.desktopView = nil;
        return;
    }
    if (self.desktopView != desktop) {
        [self.indicatorView removeFromSuperview];
        self.desktopView = desktop;
        EdgeURLDebugLog(@"desktop window %@ level=%.1f",
                        NSStringFromClass([desktop class]), ((UIWindow *)desktop).windowLevel);
    }
    EdgeURLIndicatorView *view = self.indicatorView;
    CGRect frame = [self frameForDesktopView:desktop];
    if (view.superview != desktop) {
        view.frame = frame;
        view.autoresizingMask = UIViewAutoresizingNone;
        [desktop addSubview:view];
        EdgeURLDebugLog(@"indicator attached frame=%@ bounds=%@",
                        NSStringFromCGRect(frame), NSStringFromCGRect(desktop.bounds));
        return;
    }
    if (!CGRectEqualToRect(view.frame, frame)) {
        view.frame = frame;
    }
    if (desktop.subviews.lastObject != view) {
        [desktop bringSubviewToFront:view];
    }
}

// The view's frame, in the desktop window's own coordinates, is the display:
// drawing then happens in display coordinates, which is what the recognizers
// report in too.
- (CGRect)frameForDesktopView:(UIView *)desktop {
    return [desktop convertRect:[self displayBounds]
             fromCoordinateSpace:[UIScreen mainScreen].coordinateSpace];
}

// One watcher per window the desktop can put a touch into. They are attached to
// SpringBoard's own windows, never to a window of ours, so a touch under the
// finger keeps going exactly where it went before; the watcher only looks at
// where it landed and cancels nothing.
- (NSArray<UIView *> *)touchHostsInScene:(UIWindowScene *)scene {
    NSMutableArray<UIView *> *hosts = [NSMutableArray array];
    for (UIWindow *window in scene.windows) {
        if (window.hidden || window.alpha <= 0.01) {
            continue;
        }
        if (CGRectGetWidth(window.bounds) < 2.0 ||
            CGRectGetHeight(window.bounds) < 2.0) {
            continue;
        }
        NSString *name = NSStringFromClass([window class]);
        if ([name containsString:@"EdgeURL"] || [name containsString:@"Keyboard"]) {
            continue;
        }
        [hosts addObject:window];
    }
    return hosts;
}

// Rebuilt only when the set of windows changed, and never in the middle of a
// swipe: the recognizer that began it has to stay where it is. Compared as a
// set, because the scene hands its windows back in whatever order it likes, and
// only the difference is touched: SpringBoard shows and hides its own windows
// constantly, and re-installing every watcher each time is wasted work.
- (void)syncRecognizersInScene:(UIWindowScene *)scene {
    if (self.active) {
        return;
    }
    NSArray<UIView *> *hosts = [self touchHostsInScene:scene];
    NSSet<UIView *> *current = [NSSet setWithArray:hosts];
    NSMutableSet<UIView *> *watched = [NSMutableSet set];
    for (EdgeURLPanRecognizer *recognizer in [self.recognizers copy]) {
        UIView *view = recognizer.view;
        if (view != nil) {
            [watched addObject:view];
        }
    }
    BOOL changed = NO;
    NSUInteger removed = 0;
    NSUInteger added = 0;
    // Watchers whose window is gone, or no longer visible.
    for (EdgeURLPanRecognizer *recognizer in [self.recognizers copy]) {
        UIView *view = recognizer.view;
        if (view != nil && [current containsObject:view]) {
            continue;
        }
        if (view != nil) {
            [view removeGestureRecognizer:recognizer];
        }
        [self.recognizers removeObject:recognizer];
        removed++;
        changed = YES;
    }
    // Windows that can put a touch into the desktop and have no watcher yet.
    for (UIView *host in hosts) {
        if ([watched containsObject:host]) {
            continue;
        }
        EdgeURLPanRecognizer *recognizer =
            [[EdgeURLPanRecognizer alloc] initWithTarget:self
                                                  action:@selector(handleEdgePan:)];
        recognizer.edgeDelegate = self;
        [host addGestureRecognizer:recognizer];
        [self.recognizers addObject:recognizer];
        added++;
        changed = YES;
    }
    self.hostWindows = hosts;
    if (changed) {
        EdgeURLDebugLog(@"watchers %lu (+%lu -%lu)",
                        (unsigned long)self.recognizers.count,
                        (unsigned long)added, (unsigned long)removed);
    }
}

- (void)detachRecognizers {
    for (EdgeURLPanRecognizer *recognizer in self.recognizers) {
        UIView *view = recognizer.view;
        if (view != nil) {
            [view removeGestureRecognizer:recognizer];
        }
    }
    [self.recognizers removeAllObjects];
    self.hostWindows = @[];
}

// TEMPORARY diagnostic: what the desktop's scene holds, so a window of another
// tweak that sits above this one can be named.
- (void)logDesktopStateInScene:(UIWindowScene *)scene {
    EdgeURLDebugLog(@"scene %@ state=%ld", NSStringFromClass([scene class]),
                    (long)scene.activationState);
    for (UIWindow *window in scene.windows) {
        EdgeURLDebugLog(@"  win %@ level=%.1f hidden=%d alpha=%.2f frame=%@",
                        NSStringFromClass([window class]), window.windowLevel,
                        window.hidden, window.alpha, NSStringFromCGRect(window.frame));
    }
}

// TEMPORARY diagnostic: the trigger must not fire from inside an app, and the
// only thing that says whether an app is in front is how SpringBoard's home
// screen window looks at that moment. Logged whenever it changes.
- (void)logGateStateInScene:(UIWindowScene *)scene {
    UIWindow *desktop = (UIWindow *)[self desktopViewInScene:scene];
    NSString *key = [NSString stringWithFormat:@"%@|%d|%.2f|%d",
                     NSStringFromClass([desktop class]), desktop.hidden, desktop.alpha,
                     [self homeScreenIsShowingInScene:scene]];
    if ([key isEqualToString:self.gateStateKey]) {
        return;
    }
    self.gateStateKey = key;
    EdgeURLDebugLog(@"gate desktop=%@ hidden=%d alpha=%.2f show=%d",
                    NSStringFromClass([desktop class]), desktop.hidden, desktop.alpha,
                    [self shouldShowInScene:scene]);
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
    // The watchers stay on SpringBoard's windows for the whole session; this is
    // what keeps them quiet while an app or the lock screen is what is on show.
    // The window a touch lands in can be gone from its scene by the time the
    // recognizer reports it — SpringBoard rebuilds them constantly — so the
    // scene falls back to the main one rather than reading as "no desktop".
    UIWindowScene *scene = recognizer.view.window.windowScene;
    if (scene == nil) {
        scene = [self mainScene];
    }
    BOOL showing = [self shouldShowInScene:scene];
    if (!showing) {
        UIWindow *desktop = (UIWindow *)[self desktopViewInScene:scene];
        EdgeURLDebugLog(@"touch down ignored: desktop=%@ hidden=%d alpha=%.2f",
                        NSStringFromClass([desktop class]), desktop.hidden, desktop.alpha);
        return NO;
    }
    CGPoint display = [self displayPointForViewPoint:point inView:recognizer.view];
    EdgeURLEdge found = EdgeURLEdgeLeft;
    if (![self displayPoint:display isInSensingAreaWithSettings:settings edge:&found]) {
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

// Progress is how far the finger has left the edge, over a distance the size of
// the gesture itself rather than the few points that open it: the panel grows
// while the finger travels, all the way to the middle of the screen.
- (CGFloat)progressForTravel:(CGFloat)travel settings:(EdgeURLSettings *)settings {
    CGFloat span = MAX(settings.threshold, 110.0);
    return MIN(1.0, MAX(0.0, travel / span));
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
        os_log(EdgeURLAnimationLog(), "panel at full size travel=%.1f threshold=%.1f",
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
        // The panel recedes first: opening straight away would take the desktop
        // away and the animation with it before it had been seen. Android's own
        // commit is shorter than this, so the wait is under a fifth of a second.
        NSURL *url = settings.URL;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(EdgeURLFadeDuration * NSEC_PER_SEC)),
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

// Geometry comes from the settings, once per change; the view itself lives in
// the desktop window, so it is there exactly as long as the desktop is.
- (BOOL)prepareIndicatorWithSettings:(EdgeURLSettings *)settings {
    UIView *desktop = self.desktopView;
    if (desktop == nil || self.indicatorView.superview != desktop) {
        return NO;
    }
    CGRect frame = [self frameForDesktopView:desktop];
    if (CGRectGetWidth(frame) < 2.0 || CGRectGetHeight(frame) < 2.0) {
        return NO;
    }
    if (!CGRectEqualToRect(self.indicatorView.frame, frame)) {
        self.indicatorView.frame = frame;
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
        return;  // A swipe is drawing its own panel over the band.
    }
    NSString *stateKey = [NSString stringWithFormat:@"%@|%d|%d|%d|%.2f|%.1f|%.1f|%.1f|%d|%.0fx%.0f",
                           settings.summary, settings.enabled, settings.leftEdge,
                           settings.rightEdge, settings.areaAlpha, settings.edgeWidth,
                           settings.regionTop, settings.regionHeight, settings.showArea,
                           CGRectGetWidth(self.indicatorView.bounds),
                           CGRectGetHeight(self.indicatorView.bounds)];
    if ([stateKey isEqualToString:self.bandStateKey]) {
        return;  // Nothing about the band changed; it is already on screen.
    }
    self.bandStateKey = stateKey;
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
    EdgeURLDebugLog(@"band shown left=%d right=%d alpha=%.2f show=%d left=%@ right=%@",
                    settings.leftEdge, settings.rightEdge, settings.areaAlpha,
                    settings.showArea,
                    NSStringFromCGRect([self sensingRectForSettings:settings left:YES]),
                    NSStringFromCGRect([self sensingRectForSettings:settings left:NO]));
}

// The panel goes back the way it came: it shrinks into the edge, and only the
// last part of that fades out. This is how Android's back gesture leaves the
// screen, and it reads as the finger pulling the panel back rather than a shape
// blinking off.
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
    // Ease out, so the panel shoots back towards the edge and settles there.
    CGFloat eased = 1.0 - pow(1.0 - t, 3.0);
    self.indicatorView.progress = self.fadeFromProgress * (1.0 - eased);
    CGFloat remaining = (t > 0.55) ? (1.0 - (t - 0.55) / 0.45) : 1.0;
    self.indicatorView.alpha = MIN(1.0, MAX(0.0, remaining));
    [self.indicatorView setNeedsDisplay];
    if (t >= 1.0) {
        [self stopFade];
        self.indicatorView.alpha = 1.0;
        self.indicatorView.progress = 0.0;
        // The panel is gone; the trigger area it covered comes back.
        self.bandStateKey = nil;
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