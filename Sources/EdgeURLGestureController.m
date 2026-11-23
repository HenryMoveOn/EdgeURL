// SPDX-License-Identifier: MIT
//
// Touch capture. The tweak is loaded into every app as well as SpringBoard,
// because a window of SpringBoard's cannot draw over an app without also taking
// every touch on the screen: the touch belongs to another process, and SpringBoard
// has no way to hand it back. So each process draws and watches its own screen —
// SpringBoard while the desktop is in front, an app while that app is in front —
// and a touch that is not on the sensing area never leaves the process it
// reached. What that costs is the one thing the earlier version could not do:
// the band is drawn above the app's own content, never above SpringBoard's
// system UI (status bar, Control Centre), which is a different process's scene.
//
// Inside a process, the drawing is a full-screen canvas window that never takes
// a touch, and the touching is one thin window per enabled edge, exactly the
// sensing area. No system gesture manager is asked for anything (its refusals
// are what ended SpringBoard before).
//
// All hit testing is done in display coordinates, the screen's coordinate
// space, which does not rotate with the scene.
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
// A touch this many points outside the drawn band still starts the gesture:
// the band is drawn narrow, and asking for a finger inside it exactly left the
// gesture missing more often than hitting.
static const CGFloat EdgeURLBandSlack = 14.0;

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

// SpringBoard is the one process whose "app in front" is the desktop; every other
// process the filter loads into is an app, and there the front is the app itself.
static BOOL EdgeURLIsSpringBoard(void) {
    static BOOL springBoard;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        springBoard = (objc_getClass("SpringBoard") != Nil);
    });
    return springBoard;
}

static NSString *EdgeURLGestureName(EdgeURLEdge edge) {
    return edge == EdgeURLEdgeLeft ? @"left" : @"right";
}

@interface EdgeURLGestureController () <EdgeURLPanRecognizerDelegate>

@property (nonatomic, strong) NSMutableArray<EdgeURLPanRecognizer *> *recognizers;
@property (nonatomic, strong) EdgeURLIndicatorView *indicatorView;
@property (nonatomic, strong) EdgeURLOverlayWindow *overlayWindow;
@property (nonatomic, strong) NSMutableArray<EdgeURLTouchWindow *> *edgeWindows;
@property (nonatomic, weak) UIWindow *indicatorHost;
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
        _recognizers = [NSMutableArray array];
        _edgeWindows = [NSMutableArray array];
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

// The home screen window is there from early in the launch, but SpringBoard
// builds and rebuilds its scene, so the attachment is re-checked every couple
// of seconds; it costs one array copy and changes nothing when all is well.
- (void)startWatchdog {
    if (self.watchdogStarted) {
        return;
    }
    self.watchdogStarted = YES;
    [self scheduleWatchdogTick];
}

// Each tick schedules the next one itself: going back through -startWatchdog
// stopped after the first tick, because that method refuses a watchdog it has
// already started, and the gesture then never came back after the home screen
// had been hidden once.
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
    // The trigger area stays on screen: its edges, region, width and opacity
    // come straight from the settings, so a moved slider shows at once.
    [self updateTriggerAreas];
}

#pragma mark - Attachment

// The scene that owns the display: the only one whose windows can be under the
// finger on the home screen. SpringBoard has several window scenes on the main
// screen — the System Aperture (Dynamic Island) one among them — and its own is
// the plain SBWindowScene; the auxiliary ones must be skipped, or the aperture
// window is the only one found and it never sees a touch on the home screen.
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
        NSString *className = NSStringFromClass([scene class]);
        if (EdgeURLSceneIsAuxiliary(className)) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.screen != [UIScreen mainScreen]) {
            if (fallback == nil) {
                fallback = windowScene;
            }
            continue;
        }
        // In an app the scene to draw in is the one in front, and only while it is:
        // a scene in the background has no screen to draw on.
        if (EdgeURLIsSpringBoard()) {
            return windowScene;
        }
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return windowScene;
        }
        if (fallback == nil) {
            fallback = windowScene;
        }
    }
    // An app with no scene in front draws nothing: its windows would belong to a
    // background scene, and SpringBoard owns the screen then.
    return EdgeURLIsSpringBoard() ? fallback : nil;
}

// Windows that are never the home screen's own surface, even when they happen
// to be on screen: the keyboard, an alert, the recording dot, screenshot
// chrome. A recognizer there would see touches the gesture has no business in.
static BOOL EdgeURLWindowIsNoise(NSString *className) {
    return [className containsString:@"Keyboard"] ||
           [className containsString:@"AlertItem"] ||
           [className containsString:@"RecordingIndicator"] ||
           [className containsString:@"Screenshots"] ||
           [className containsString:@"TextEffects"] ||
           [className containsString:@"ReusePool"];
}

// Every visible, screen-sized window of the scene, at any level. Which window
// takes a touch is SpringBoard's business — other tweaks keep full-screen
// windows far above the normal level, and one of those can be the window under
// the finger — so the recognizer goes on all of them. It never cancels touches
// in the view it watches, and it lets every other recognizer recognise beside
// it, so sitting there changes nothing about how the screen behaves.
- (NSArray<UIWindow *> *)candidateWindowsForScene:(UIWindowScene *)scene {
    CGRect screen = [UIScreen mainScreen].bounds;
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIWindow *window in scene.windows) {
        if (window.hidden || window.alpha < 0.01) {
            continue;
        }
        if (EdgeURLWindowIsNoise(NSStringFromClass([window class]))) {
            continue;
        }
        if (window.windowLevel >= EdgeURLOverlayWindowLevel) {
            continue;  // EdgeURL's own canvas and touch windows.
        }
        CGRect bounds = window.bounds;
        if (CGRectGetWidth(bounds) < CGRectGetWidth(screen) * 0.9 ||
            CGRectGetHeight(bounds) < CGRectGetHeight(screen) * 0.9) {
            continue;
        }
        [windows addObject:window];
    }
    return windows;
}

// Where the band and the wave are drawn: the home screen's own window, which is
// shown exactly while the desktop is, and never an overlay of another tweak.
- (UIWindow *)indicatorHostForWindows:(NSArray<UIWindow *> *)windows {
    UIWindow *lowest = nil;
    for (UIWindow *window in windows) {
        if ([NSStringFromClass([window class]) containsString:@"HomeScreen"]) {
            return window;
        }
        if (lowest == nil || window.windowLevel < lowest.windowLevel) {
            lowest = window;
        }
    }
    return lowest;
}

// EdgeURL's own windows: a canvas above everything that draws, and one thin
// window per enabled edge that takes the touches landing there. Recreated when
// the scene is replaced, which happens on a respring and around lock and unlock.
- (void)updateOverlayForScene:(UIWindowScene *)scene {
    BOOL show = [self shouldShowInScene:scene];
    if (self.overlayWindow != nil && self.overlayWindow.windowScene != scene) {
        [self.indicatorView removeFromSuperview];
        self.overlayWindow.hidden = YES;
        self.overlayWindow = nil;
        for (EdgeURLTouchWindow *window in self.edgeWindows) {
            window.hidden = YES;
        }
    }
    if (self.overlayWindow == nil) {
        EdgeURLOverlayWindow *canvas = [[EdgeURLOverlayWindow alloc] initWithWindowScene:scene];
        canvas.frame = [self displayBounds];
        self.overlayWindow = canvas;
        [canvas addSubview:self.indicatorView];
        self.indicatorView.frame = canvas.bounds;
        self.indicatorView.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        canvas.hidden = !show;
        EdgeURLDebugLog(@"overlay canvas ready level=%.1f bounds=%@",
                        canvas.windowLevel, NSStringFromCGRect(canvas.bounds));
        [self updateTriggerAreas];
    } else if (self.overlayWindow.hidden != (!show)) {
        self.overlayWindow.hidden = !show;
        EdgeURLDebugLog(@"overlay canvas %@", show ? @"shown" : @"hidden");
    }
    [self updateEdgeWindowsForScene:scene shown:show];
}

// Whether anything of EdgeURL's belongs on this scene at all. A window of this
// process, however transparent and however much it refuses the touch, sits above
// the whole screen: in SpringBoard that means above the app in front, and the
// touch it refuses is then lost — SpringBoard cannot hand a touch back to another
// process. So SpringBoard draws only while the desktop is the screen, and an app
// draws only while that app is.
- (BOOL)shouldShowInScene:(UIWindowScene *)scene {
    if (scene == nil) {
        return NO;
    }
    if (!EdgeURLIsSpringBoard()) {
        return scene.activationState == UISceneActivationStateForegroundActive;
    }
    // The desktop is on screen exactly while SpringBoard's home screen window is.
    // It is not while an app is in front, nor while the lock screen covers it.
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

// The sensing area, exactly: a window whose frame is the band of one edge, so a
// touch anywhere else on the screen never reaches this tweak and the app under
// it keeps working untouched.
- (void)updateEdgeWindowsForScene:(UIWindowScene *)scene shown:(BOOL)shown {
    EdgeURLSettings *settings = [self currentSettings];
    CGRect display = [self displayBounds];
    NSMutableArray<NSValue *> *strips = [NSMutableArray array];
    if (settings.enabled && shown) {
        CGFloat band = settings.edgeWidth + EdgeURLBandSlack;
        CGFloat top = CGRectGetMinY(display) +
                      CGRectGetHeight(display) * settings.regionTop / 100.0;
        CGFloat height = CGRectGetHeight(display) * settings.regionHeight / 100.0;
        if (settings.leftEdge) {
            [strips addObject:[NSValue valueWithCGRect:
                CGRectMake(CGRectGetMinX(display), top, band, height)]];
        }
        if (settings.rightEdge) {
            [strips addObject:[NSValue valueWithCGRect:
                CGRectMake(CGRectGetMaxX(display) - band, top, band, height)]];
        }
    }
    while (self.edgeWindows.count < strips.count) {
        EdgeURLTouchWindow *window = [[EdgeURLTouchWindow alloc] initWithWindowScene:scene];
        [self.edgeWindows addObject:window];
        EdgeURLDebugLog(@"touch window created level=%.1f", window.windowLevel);
    }
    for (NSUInteger index = 0; index < self.edgeWindows.count; index++) {
        EdgeURLTouchWindow *window = self.edgeWindows[index];
        if (index < strips.count) {
            CGRect strip = strips[index].CGRectValue;
            if (!CGRectEqualToRect(window.frame, strip)) {
                window.frame = strip;
                EdgeURLDebugLog(@"touch window %lu frame=%@", (unsigned long)index,
                                NSStringFromCGRect(strip));
            }
            if (window.hidden) {
                window.hidden = NO;
            }
        } else if (!window.hidden) {
            window.hidden = YES;
        }
    }
}

- (EdgeURLPanRecognizer *)recognizerOnWindow:(UIWindow *)window {
    for (EdgeURLPanRecognizer *recognizer in self.recognizers) {
        if (recognizer.view == window) {
            return recognizer;
        }
    }
    return nil;
}

// TEMPORARY diagnostic: every window SpringBoard has, without any filter, so
// the one that takes the home screen's touches can be named.
- (void)logWindowInventory {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        EdgeURLDebugLog(@"scene %@ state=%ld",
                        NSStringFromClass([scene class]), (long)scene.activationState);
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        UIWindow *key = nil;
        @try {
            key = windowScene.keyWindow;
        } @catch (NSException *exception) {
            key = nil;
        }
        EdgeURLDebugLog(@"  key window: %@", key != nil
                        ? [NSString stringWithFormat:@"%@ level=%.1f frame=%@",
                           NSStringFromClass([key class]), key.windowLevel,
                           NSStringFromCGRect(key.frame)]
                        : @"(none)");
        for (UIWindow *window in windowScene.windows) {
            EdgeURLDebugLog(@"  win %@ level=%.1f hidden=%d alpha=%.2f frame=%@",
                            NSStringFromClass([window class]), window.windowLevel,
                            window.hidden, window.alpha, NSStringFromCGRect(window.frame));
        }
    }
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        EdgeURLDebugLog(@"  app win %@ level=%.1f hidden=%d alpha=%.2f frame=%@",
                        NSStringFromClass([window class]), window.windowLevel,
                        window.hidden, window.alpha, NSStringFromCGRect(window.frame));
    }
}

- (void)reconcile {
    UIWindowScene *scene = [self mainScene];
    if (scene == nil) {
        EdgeURLDebugLog(@"no window scene yet");
        return;
    }
    [self updateOverlayForScene:scene];
    BOOL show = [self shouldShowInScene:scene];
    if (!show && self.active) {
        // This process stopped being the screen while a swipe was running: drop
        // it, the URL is not opened from a screen the user cannot see.
        self.active = NO;
    }
    NSArray<UIWindow *> *windows = show ? [self candidateWindowsForScene:scene]
                                        : @[];

    // Where the gesture may be seen: the process's own windows plus the sensing
    // area of any edge window. Both are empty unless this process is the screen —
    // a recognizer left on a window of SpringBoard's would take edge touches meant
    // for the app in front, and open the URL from a screen the band is not on.
    NSMutableArray<UIWindow *> *recognitionWindows = [NSMutableArray arrayWithArray:windows];
    for (EdgeURLTouchWindow *window in self.edgeWindows) {
        if (!window.hidden) {
            [recognitionWindows addObject:window];
        }
    }

    EdgeURLDebugLog(@"reconcile scene=%@ candidates=%lu",
                    NSStringFromClass([scene class]), (unsigned long)windows.count);

    if (!self.loggedWindows) {
        self.loggedWindows = YES;
        [self logWindowInventory];
        for (UIWindow *window in windows) {
            EdgeURLDebugLog(@"window %@ level=%.1f hidden=%d frame=%@",
                            NSStringFromClass([window class]), window.windowLevel,
                            window.hidden, NSStringFromCGRect(window.frame));
            os_log(EdgeURLGestureLog(), "window %{public}@ level=%.1f frame=%{public}s",
                   NSStringFromClass([window class]), window.windowLevel,
                   NSStringFromCGRect(window.frame).UTF8String);
        }
    }

    for (EdgeURLPanRecognizer *recognizer in [self.recognizers copy]) {
        UIView *view = recognizer.view;
        BOOL stillCandidate = NO;
        for (UIWindow *window in recognitionWindows) {
            if ((UIView *)window == view) {
                stillCandidate = YES;
                break;
            }
        }
        if (view != nil && stillCandidate) {
            continue;
        }
        if (view != nil) {
            [view removeGestureRecognizer:recognizer];
        }
        [self.recognizers removeObject:recognizer];
        EdgeURLDebugLog(@"recognizer detached from %@",
                        view != nil ? NSStringFromClass([view class]) : @"(nil)");
    }

    for (UIWindow *window in recognitionWindows) {
        if ([self recognizerOnWindow:window] != nil) {
            continue;
        }
        EdgeURLPanRecognizer *recognizer =
            [[EdgeURLPanRecognizer alloc] initWithTarget:self action:@selector(handleEdgePan:)];
        recognizer.edgeDelegate = self;
        [window addGestureRecognizer:recognizer];
        [self.recognizers addObject:recognizer];
        EdgeURLDebugLog(@"recognizer attached to %@ level=%.1f",
                        NSStringFromClass([window class]), window.windowLevel);
        os_log(EdgeURLGestureLog(), "attached to %{public}@ level=%.1f",
               NSStringFromClass([window class]), window.windowLevel);
    }

    // The band and the wave are drawn on EdgeURL's own canvas window of this
    // process; the process's own windows are only the fallback, for a case where
    // that window could not be made.
    UIWindow *host = self.overlayWindow;
    if (host == nil) {
        host = [self indicatorHostForWindows:windows];
    }
    if (host != nil && (host != self.indicatorHost ||
                        self.indicatorView.superview != host)) {
        [self.indicatorView removeFromSuperview];
        self.indicatorHost = host;
        self.indicatorView.frame = host.bounds;
        self.indicatorView.autoresizingMask =
            UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [host addSubview:self.indicatorView];
        EdgeURLDebugLog(@"indicator hosted in %@ bounds=%@",
                        NSStringFromClass([host class]), NSStringFromCGRect(host.bounds));
        [self updateTriggerAreas];
    } else if (host != nil) {
        self.indicatorView.frame = host.bounds;
    }
}

- (void)sceneDidChange:(NSNotification *)notification {
    [self reconcile];
}

#pragma mark - Geometry

- (CGRect)displayBounds {
    return [UIScreen mainScreen].coordinateSpace.bounds;
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
    CGRect display = [self displayBounds];
    CGFloat width = CGRectGetWidth(display);
    CGFloat height = CGRectGetHeight(display);
    if (width < 2.0 || height < 2.0) {
        return NO;
    }
    CGFloat band = settings.edgeWidth + EdgeURLBandSlack;
    BOOL onLeft = NO;
    if (settings.leftEdge && point.x <= band) {
        onLeft = YES;
    } else if (settings.rightEdge && point.x >= width - band) {
        onLeft = NO;
    } else {
        return NO;
    }
    CGFloat top = height * settings.regionTop / 100.0;
    CGFloat bottom = top + height * settings.regionHeight / 100.0;
    if (point.y < top || point.y > bottom) {
        return NO;
    }
    if (edge != NULL) {
        *edge = onLeft ? EdgeURLEdgeLeft : EdgeURLEdgeRight;
    }
    return YES;
}

// How far the finger has moved away from the edge it came from, never
// negative.
- (CGFloat)travelForPoint:(CGPoint)point edge:(EdgeURLEdge)edge {
    CGFloat travel = (edge == EdgeURLEdgeLeft) ? (point.x - self.touchDown.x)
                                              : (self.touchDown.x - point.x);
    return MAX(0.0, travel);
}

#pragma mark - EdgeURLPanRecognizerDelegate

- (BOOL)panRecognizer:(EdgeURLPanRecognizer *)recognizer
    wantsTouchDownAtPointInView:(CGPoint)point
                          edge:(EdgeURLEdge *)edge {
    EdgeURLSettings *settings = [self currentSettings];
    if (!settings.enabled || settings.URL == nil) {
        return NO;
    }
    // One swipe at a time: the touch window and the view under it can both hold a
    // recognizer, and this one gesture must not be run twice.
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
    EdgeURLDebugLog(@"touch down (%.1f,%.1f) edge=%d window=%@",
                    display.x, display.y, (int)found,
                    NSStringFromClass([recognizer.view class]));
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
                    NSStringFromClass([recognizer.view class]));
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
        // The wave recedes first: opening straight away would hide the home
        // screen, and the animation with it, before it had been seen.
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

// The view is hosted in the home screen window, so it lives exactly as long as
// that screen is on show. Geometry comes from the settings, once.
- (BOOL)prepareIndicatorWithSettings:(EdgeURLSettings *)settings {
    UIView *host = self.indicatorView.superview;
    if (host == nil) {
        return NO;
    }
    CGRect bounds = host.bounds;
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
// fade. It is the same band a swipe shows, so the setting and the gesture
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
    EdgeURLDebugLog(@"band shown left=%d right=%d alpha=%.2f host=%@",
                    settings.leftEdge, settings.rightEdge, settings.areaAlpha,
                    NSStringFromClass([view.superview class]));
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
    self.indicatorView.alpha = MAX(0.0, remaining);
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