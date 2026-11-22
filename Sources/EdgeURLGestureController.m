// SPDX-License-Identifier: MIT
//
// One pan recognizer, registered with each window scene's system gesture
// manager in a slot of its own. The manager hands it touches from the whole
// display before the frontmost app, which is what lets an edge swipe work over
// another app. All positions are in display coordinates: the screen's
// coordinate space is 430 x 932 on this device and never rotates with
// SpringBoard's scene, so the band maths is the same in any orientation.
#import "EdgeURLGestureController.h"

#import "EdgeURLIndicatorView.h"
#import "EdgeURLPrivate.h"
#import "EdgeURLSettings.h"

#import <QuartzCore/QuartzCore.h>
#import <notify.h>
#import <os/log.h>
#import <fcntl.h>
#import <stdarg.h>
#import <unistd.h>

static const CFTimeInterval EdgeURLFadeDuration = 0.12;

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

@interface EdgeURLGestureController () <UIGestureRecognizerDelegate>

@property (nonatomic, strong) UIPanGestureRecognizer *recognizer;
@property (nonatomic, strong) NSHashTable<UIScene *> *attachedScenes;
@property (nonatomic, strong) UIWindow *overlayWindow;
@property (nonatomic, strong) EdgeURLIndicatorView *indicatorView;
@property (nonatomic, strong) CADisplayLink *fadeLink;
@property (nonatomic, strong) EdgeURLSettings *settings;

@property (nonatomic, assign) NSUInteger registeredGestureType;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) NSUInteger attachAttempts;

@property (nonatomic, assign) EdgeURLEdge pendingEdge;
@property (nonatomic, assign) EdgeURLEdge activeEdge;
@property (nonatomic, assign) CGPoint touchDown;
@property (nonatomic, assign) BOOL touchDownValid;
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
        _attachedScenes = [NSHashTable weakObjectsHashTable];
        _pendingEdge = EdgeURLEdgeLeft;
        _activeEdge = EdgeURLEdgeLeft;
    }
    return self;
}

#pragma mark - Lifecycle

- (void)start {
    if (self.started) {
        [self attachToConnectedScenes];
        return;
    }
    self.started = YES;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(sceneDidActivate:)
                   name:UISceneDidActivateNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(sceneWillConnect:)
                   name:UISceneWillConnectNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(sceneDidDisconnect:)
                   name:UISceneDidDisconnectNotification
                 object:nil];

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    (__bridge const void *)self,
                                    EdgeURLPreferencesChanged,
                                    (__bridge CFStringRef)EdgeURLChangedNotification(),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    EdgeURLSettings *settings = [self currentSettings];
    os_log(EdgeURLGestureLog(), "started %{public}s", settings.summary.UTF8String);
    EdgeURLDebugLog(@"started %@", settings.summary);

    [self attachToConnectedScenes];

    // The scene may connect a moment after we load; the notification above
    // covers that, and the retry below covers a scene that was already there
    // and a manager that refuses the recognizer early in the launch.
    [self scheduleAttachAttempt];
}

// Keeps asking for a scene until one takes the recognizer, for the first couple
// of minutes of the process's life: on this springboard the scene arrives well
// after the launch callbacks, and one attempt at load time was not enough.
- (void)scheduleAttachAttempt {
    if (self.attachedScenes.count > 0) {
        return;
    }
    if (self.attachAttempts >= 40) {
        os_log(EdgeURLGestureLog(), "giving up: no scene took the recognizer after %lu attempts",
               (unsigned long)self.attachAttempts);
        return;
    }
    self.attachAttempts += 1;
    [self attachToConnectedScenes];
    if (self.attachedScenes.count > 0) {
        os_log(EdgeURLGestureLog(), "attached after %lu attempt(s)", (unsigned long)self.attachAttempts);
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf scheduleAttachAttempt];
    });
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

- (void)dealloc {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                       (__bridge const void *)self,
                                       (__bridge CFStringRef)EdgeURLChangedNotification(),
                                       NULL);
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Settings

- (EdgeURLSettings *)currentSettings {
    if (self.settings == nil) {
        self.settings = [EdgeURLSettings currentSettings];
        self.registeredGestureType = self.settings.gestureType;
    }
    return self.settings;
}

- (void)preferencesChanged {
    EdgeURLSettings *settings = [EdgeURLSettings currentSettings];
    BOOL typeChanged = (settings.gestureType != self.registeredGestureType);
    self.settings = settings;
    os_log(EdgeURLGestureLog(), "preferences reloaded %{public}s", settings.summary.UTF8String);
    EdgeURLDebugLog(@"prefs changed %@", settings.summary);
    if (!settings.enabled && self.active) {
        [self finishWithProgress:self.indicatorView.progress opens:NO];
    }
    if (typeChanged) {
        self.registeredGestureType = settings.gestureType;
        [self reattach];
    }
    if (self.attachedScenes.count == 0) {
        [self attachToConnectedScenes];
    }
    // The trigger area stays on screen: its edges, region, width and opacity
    // are read straight from the settings, so every move of a slider shows at
    // once and a wrong region or a faint band is visible without a swipe.
    [self updateTriggerAreas];
}

#pragma mark - Scene attachment

// SpringBoard keeps more window scenes than its own: the System Aperture one
// (the Dynamic Island), banner and service scenes. They are UIWindowScenes, yet
// some do not answer -systemGestureManager at all, and a message sent there
// raises an unrecognized selector that ends the process. So every scene is
// judged first and only the main display scene, which owns the screen's
// gesture manager, may take the recognizer. Nothing is sent to a scene that
// has not answered respondsToSelector: for the exact selector.
static BOOL EdgeURLSceneNameIsAuxiliary(NSString *className) {
    return [className containsString:@"Aperture"] ||
           [className containsString:@"Banner"] ||
           [className containsString:@"Service"] ||
           [className containsString:@"StatusBar"];
}

static BOOL EdgeURLSceneNameIsMainDisplay(NSString *className) {
    return [className containsString:@"MainDisplayWindowScene"] ||
           [className containsString:@"SBWindowScene"];
}

// The manager of a scene that may have one, or nil. Every check comes before
// the message it guards.
- (UISystemGestureManager *)gestureManagerForScene:(UIWindowScene *)scene {
    if (scene == nil || ![scene isKindOfClass:[UIWindowScene class]]) {
        return nil;
    }
    NSString *className = NSStringFromClass([scene class]);
    if (EdgeURLSceneNameIsAuxiliary(className)) {
        return nil;
    }
    if (![scene respondsToSelector:@selector(systemGestureManager)]) {
        return nil;
    }
    UISystemGestureManager *manager = [scene systemGestureManager];
    if (manager == nil || ![manager respondsToSelector:@selector(addGestureRecognizer:withType:)]) {
        return nil;
    }
    return manager;
}

// The scenes that own a system gesture manager and could take the recognizer,
// the main display scene first.
- (NSArray<UIWindowScene *> *)eligibleScenes {
    NSMutableArray<UIWindowScene *> *preferred = [NSMutableArray array];
    NSMutableArray<UIWindowScene *> *rest = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateUnattached) {
            continue;
        }
        if ([self gestureManagerForScene:windowScene] == nil) {
            EdgeURLDebugLog(@"no manager for %@", NSStringFromClass([scene class]));
            continue;
        }
        if (EdgeURLSceneNameIsMainDisplay(NSStringFromClass([scene class]))) {
            [preferred addObject:windowScene];
        } else {
            [rest addObject:windowScene];
        }
    }
    return [preferred arrayByAddingObjectsFromArray:rest];
}

// One manager is enough, and more than one is not allowed: the same recognizer
// handed to a second manager is refused, and the manager raises an exception
// rather than answering NO, which would end SpringBoard. So the first scene
// that takes it wins, and the managers report every touch on the display.
- (void)attachToConnectedScenes {
    NSArray<UIWindowScene *> *scenes = [self eligibleScenes];
    os_log(EdgeURLGestureLog(), "attach attempt %lu: %lu eligible scene(s)",
           (unsigned long)self.attachAttempts, (unsigned long)scenes.count);
    if (self.attachedScenes.count > 0) {
        return;
    }
    for (UIWindowScene *scene in scenes) {
        if ([self attachToScene:scene]) {
            break;
        }
    }
    [self updateTriggerAreas];
}

- (UIPanGestureRecognizer *)makeRecognizerIfNeeded {
    if (self.recognizer == nil) {
        UIPanGestureRecognizer *recognizer =
            [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        recognizer.delegate = self;
        recognizer.maximumNumberOfTouches = 1;
        recognizer.cancelsTouchesInView = NO;
        recognizer.delaysTouchesEnded = NO;
        self.recognizer = recognizer;
    }
    return self.recognizer;
}

- (BOOL)attachToScene:(UIWindowScene *)scene {
    if (scene == nil || [self.attachedScenes containsObject:scene]) {
        return NO;
    }
    UISystemGestureManager *manager = [self gestureManagerForScene:scene];
    if (manager == nil) {
        return NO;
    }
    UIPanGestureRecognizer *recognizer = [self makeRecognizerIfNeeded];
    NSUInteger type = [self currentSettings].gestureType;
    @try {
        [manager addGestureRecognizer:recognizer withType:type];
    } @catch (NSException *exception) {
        // The refusal carries the one thing worth knowing about the slot: the
        // manager's own reason.
        os_log(EdgeURLGestureLog(), "refused %{public}@ type=%lu: %{public}@",
               NSStringFromClass([scene class]), (unsigned long)type, exception.reason);
        EdgeURLDebugLog(@"refused %@ type=%lu: %@", NSStringFromClass([scene class]),
                        (unsigned long)type, exception.reason);
        return NO;
    }
    [self.attachedScenes addObject:scene];
    EdgeURLDebugLog(@"attached %@ type=%lu display=%@",
                    NSStringFromClass([scene class]), (unsigned long)type,
                    NSStringFromCGRect([UIScreen mainScreen].coordinateSpace.bounds));
    os_log(EdgeURLGestureLog(),
           "attached scene %{public}@ type=%lu display=%{public}@",
           NSStringFromClass([scene class]), (unsigned long)type,
           NSStringFromCGRect([UIScreen mainScreen].coordinateSpace.bounds));
    return YES;
}

- (void)reattach {
    NSArray<UIScene *> *scenes = self.attachedScenes.allObjects;
    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UISystemGestureManager *manager = [self gestureManagerForScene:(UIWindowScene *)scene];
        if ([manager respondsToSelector:@selector(removeGestureRecognizer:)]) {
            [manager removeGestureRecognizer:self.recognizer];
        }
        [self.attachedScenes removeObject:scene];
    }
    os_log(EdgeURLGestureLog(), "re-attaching with type=%lu", (unsigned long)self.registeredGestureType);
    [self attachToConnectedScenes];
}

- (void)sceneDidActivate:(NSNotification *)notification {
    id scene = notification.object;
    if ([scene isKindOfClass:[UIWindowScene class]]) {
        [self attachToScene:(UIWindowScene *)scene];
    }
}

- (void)sceneWillConnect:(NSNotification *)notification {
    [self sceneDidActivate:notification];
}

- (void)sceneDidDisconnect:(NSNotification *)notification {
    id scene = notification.object;
    if ([scene isKindOfClass:[UIScene class]]) {
        [self.attachedScenes removeObject:(UIScene *)scene];
    }
}

#pragma mark - Geometry

- (CGRect)displayBounds {
    return [UIScreen mainScreen].coordinateSpace.bounds;
}

- (UIWindowScene *)activeScene {
    UIWindowScene *eligible = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]] ||
            scene.activationState == UISceneActivationStateUnattached) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if ([self gestureManagerForScene:windowScene] == nil) {
            continue;
        }
        if (EdgeURLSceneNameIsMainDisplay(NSStringFromClass([scene class]))) {
            return windowScene;
        }
        if (eligible == nil) {
            eligible = windowScene;
        }
    }
    return eligible;
}

// A recognizer the system gesture manager owns has no view, so the touch
// arrives in window coordinates; one with a view converts through it.
- (CGPoint)displayPointForGesture:(UIGestureRecognizer *)recognizer {
    UIView *view = recognizer.view;
    UIView *window = view.window ?: view;
    if (window != nil) {
        CGPoint point = [recognizer locationInView:window];
        return [window convertPoint:point toCoordinateSpace:[UIScreen mainScreen].coordinateSpace];
    }
    return [recognizer locationInView:nil];
}

- (CGPoint)displayPointForTouch:(UITouch *)touch {
    UIView *window = touch.window;
    if (window != nil) {
        CGPoint point = [touch locationInView:window];
        return [window convertPoint:point toCoordinateSpace:[UIScreen mainScreen].coordinateSpace];
    }
    return [touch locationInView:nil];
}

- (CGPoint)displayTranslationForGesture:(UIPanGestureRecognizer *)recognizer {
    UIView *view = recognizer.view;
    if (view != nil) {
        CGPoint translation = [recognizer translationInView:view];
        CGFloat scaleX = view.window != nil ? view.window.transform.a : 1.0;
        CGFloat scaleY = view.window != nil ? view.window.transform.d : 1.0;
        return CGPointMake(translation.x * (scaleX != 0.0 ? scaleX : 1.0),
                           translation.y * (scaleY != 0.0 ? scaleY : 1.0));
    }
    return [recognizer translationInView:nil];
}

- (BOOL)displayPoint:(CGPoint)point isInBandWithSettings:(EdgeURLSettings *)settings edge:(EdgeURLEdge *)edge {
    CGRect display = [self displayBounds];
    CGFloat width = CGRectGetWidth(display);
    CGFloat height = CGRectGetHeight(display);
    if (width < 2.0 || height < 2.0) {
        return NO;
    }
    BOOL leftSide = NO;
    if (point.x <= settings.edgeWidth && settings.leftEdge) {
        leftSide = YES;
    } else if (point.x >= width - settings.edgeWidth && settings.rightEdge) {
        leftSide = NO;
    } else {
        return NO;
    }
    CGFloat top = height * settings.regionTop / 100.0;
    CGFloat bottom = top + height * settings.regionHeight / 100.0;
    if (point.y < top || point.y > bottom) {
        return NO;
    }
    if (edge != NULL) {
        *edge = leftSide ? EdgeURLEdgeLeft : EdgeURLEdgeRight;
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

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch {
    if (recognizer != self.recognizer) {
        return YES;
    }
    // Record the touch-down point before any drift, which is what the band
    // test wants. Every touch is accepted here; gestureRecognizerShouldBegin:
    // is the one and only gate, so a touch outside the band is left alone.
    CGPoint point = [self displayPointForTouch:touch];
    self.touchDown = point;
    self.touchDownValid = YES;
    EdgeURLDebugLog(@"touch down (%.1f,%.1f)", point.x, point.y);

    EdgeURLSettings *settings = [self currentSettings];
    EdgeURLEdge edge = EdgeURLEdgeLeft;
    if (settings.enabled && [self displayPoint:point isInBandWithSettings:settings edge:&edge]) {
        self.pendingEdge = edge;
    }
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (recognizer != self.recognizer) {
        return YES;
    }
    EdgeURLSettings *settings = [self currentSettings];
    if (!settings.enabled || settings.URL == nil) {
        return NO;
    }

    // The touch-down point again, this time derived from the location and the
    // translation, in case shouldReceiveTouch was never asked.
    CGPoint location = [self displayPointForGesture:recognizer];
    CGPoint translation = [self displayTranslationForGesture:(UIPanGestureRecognizer *)recognizer];
    CGPoint derived = CGPointMake(location.x - translation.x, location.y - translation.y);
    if (!self.touchDownValid) {
        self.touchDown = derived;
    }

    EdgeURLEdge edge = EdgeURLEdgeLeft;
    if (![self displayPoint:self.touchDown isInBandWithSettings:settings edge:&edge]) {
        os_log(EdgeURLGestureLog(),
               "not in band down=(%.1f,%.1f) derived=(%.1f,%.1f) display=%{public}@",
               self.touchDown.x, self.touchDown.y, derived.x, derived.y,
               NSStringFromCGRect([self displayBounds]));
        EdgeURLDebugLog(@"shouldBegin NO: down (%.1f,%.1f) derived (%.1f,%.1f) display %@",
                        self.touchDown.x, self.touchDown.y, derived.x, derived.y,
                        NSStringFromCGRect([self displayBounds]));
        return NO;
    }
    self.pendingEdge = edge;
    EdgeURLDebugLog(@"shouldBegin YES edge=%d down (%.1f,%.1f)",
                    (int)edge, self.touchDown.x, self.touchDown.y);
    os_log(EdgeURLGestureLog(),
           "should begin edge=%{public}s down=(%.1f,%.1f) derived=(%.1f,%.1f) display=%{public}@ band=%.1f",
           EdgeURLGestureName(edge).UTF8String,
           self.touchDown.x, self.touchDown.y, derived.x, derived.y,
           NSStringFromCGRect([self displayBounds]), settings.edgeWidth);
    return YES;
}

#pragma mark - Pan

- (void)handlePan:(UIPanGestureRecognizer *)recognizer {
    switch (recognizer.state) {
        case UIGestureRecognizerStateBegan:
            [self beginWithPan:recognizer];
            break;
        case UIGestureRecognizerStateChanged:
            [self updateWithPan:recognizer];
            break;
        case UIGestureRecognizerStateEnded:
            [self endWithPan:recognizer cancelled:NO];
            break;
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            [self endWithPan:recognizer cancelled:YES];
            break;
        default:
            break;
    }
}

- (void)beginWithPan:(UIPanGestureRecognizer *)recognizer {
    EdgeURLSettings *settings = [self currentSettings];
    self.activeEdge = self.pendingEdge;
    self.active = YES;
    self.brightened = NO;
    self.touchDownValid = NO;
    [self stopFade];

    [self showOverlayWithSettings:settings];
    [self updateWithPan:recognizer];

    os_log(EdgeURLGestureLog(), "tracking edge=%{public}s down=(%.1f,%.1f)",
           EdgeURLGestureName(self.activeEdge).UTF8String, self.touchDown.x, self.touchDown.y);
    EdgeURLDebugLog(@"tracking edge=%d", (int)self.activeEdge);
}

- (CGFloat)progressForTravel:(CGFloat)travel settings:(EdgeURLSettings *)settings {
    CGFloat threshold = MAX(settings.threshold, 1.0);
    return MIN(1.0, MAX(0.0, travel / threshold));
}

- (void)updateWithPan:(UIPanGestureRecognizer *)recognizer {
    if (!self.active) {
        return;
    }
    EdgeURLSettings *settings = [self currentSettings];
    CGPoint location = [self displayPointForGesture:recognizer];
    CGFloat travel = [self travelForPoint:location edge:self.activeEdge];
    CGFloat progress = [self progressForTravel:travel settings:settings];

    EdgeURLIndicatorView *view = self.indicatorView;
    view.touchY = location.y;
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

- (void)endWithPan:(UIPanGestureRecognizer *)recognizer cancelled:(BOOL)cancelled {
    if (!self.active) {
        return;
    }
    EdgeURLSettings *settings = [self currentSettings];
    CGPoint location = [self displayPointForGesture:recognizer];
    CGFloat travel = [self travelForPoint:location edge:self.activeEdge];
    CGFloat progress = [self progressForTravel:travel settings:settings];
    BOOL opens = (!cancelled && travel >= settings.minimumTravel && settings.URL != nil);

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
    [self fadeOutFromProgress:MAX(EdgeURLFraction(progress), 0.25)];
    if (opens) {
        [self openURL:settings.URL];
    }
}

#pragma mark - Opening

- (void)openURL:(NSURL *)url {
    if (url == nil) {
        return;
    }
    os_log(EdgeURLOpenLog(), "opening %{public}s", url.absoluteString.UTF8String);
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

#pragma mark - Overlay

- (EdgeURLIndicatorView *)indicatorView {
    if (_indicatorView == nil) {
        _indicatorView = [[EdgeURLIndicatorView alloc] initWithFrame:[self displayBounds]];
    }
    return _indicatorView;
}

- (void)showOverlayWithSettings:(EdgeURLSettings *)settings {
    if (![self prepareOverlayWithSettings:settings]) {
        return;
    }
    EdgeURLIndicatorView *view = self.indicatorView;
    view.previewMode = NO;
    view.edge = self.activeEdge;
    view.progress = 0.0;
    view.alpha = 1.0;
    self.overlayWindow.hidden = NO;
    [view setNeedsDisplay];
    os_log(EdgeURLAnimationLog(), "overlay shown display=%{public}@ edge=%{public}s style=%{public}s",
           NSStringFromCGRect([self displayBounds]), EdgeURLGestureName(self.activeEdge).UTF8String,
           settings.animated ? "wave" : "triangle");
}

// The overlay window, and the view holding the settings' geometry. Answers NO
// when there is nowhere to draw: no scene, or a display of no size.
- (BOOL)prepareOverlayWithSettings:(EdgeURLSettings *)settings {
    CGRect display = [self displayBounds];
    if (CGRectGetWidth(display) < 2.0 || CGRectGetHeight(display) < 2.0) {
        EdgeURLDebugLog(@"no display for the overlay: %@", NSStringFromCGRect(display));
        return NO;
    }
    if (self.overlayWindow == nil) {
        UIWindowScene *scene = [self activeScene];
        if (scene == nil) {
            os_log(EdgeURLAnimationLog(), "no scene for the overlay");
            return NO;
        }
        UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
        window.backgroundColor = [UIColor clearColor];
        window.windowLevel = UIWindowLevelAlert + 1;
        // Nothing in the overlay ever takes a touch.
        window.userInteractionEnabled = NO;
        UIViewController *host = [[UIViewController alloc] init];
        host.view = self.indicatorView;
        window.rootViewController = host;
        window.hidden = YES;
        self.overlayWindow = window;
    }
    self.overlayWindow.frame = display;

    EdgeURLIndicatorView *view = self.indicatorView;
    view.frame = self.overlayWindow.bounds;
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
    BOOL wanted = settings.enabled && settings.showArea && settings.areaAlpha > 0.001 &&
                  (settings.leftEdge || settings.rightEdge);
    if (!wanted) {
        [self hideTriggerAreas];
        return;
    }
    if (![self prepareOverlayWithSettings:settings]) {
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
    self.overlayWindow.hidden = NO;
    [view setNeedsDisplay];

    os_log(EdgeURLAnimationLog(), "trigger areas shown left=%d right=%d alpha=%.2f width=%.1f top=%.1f height=%.1f",
           settings.leftEdge, settings.rightEdge, settings.areaAlpha,
           settings.edgeWidth, settings.regionTop, settings.regionHeight);
    EdgeURLDebugLog(@"band shown left=%d right=%d alpha=%.2f window=%@ hidden=%d alpha=%.2f view=%@",
                    settings.leftEdge, settings.rightEdge, settings.areaAlpha,
                    self.overlayWindow, self.overlayWindow.hidden, view.alpha, view);
}

- (void)hideTriggerAreas {
    if (self.overlayWindow.hidden) {
        return;
    }
    [self stopFade];
    self.indicatorView.previewMode = NO;
    self.indicatorView.alpha = 1.0;
    self.overlayWindow.hidden = YES;
    os_log(EdgeURLAnimationLog(), "trigger areas hidden");
}

- (void)fadeOutFromProgress:(CGFloat)progress {
    if (self.overlayWindow == nil || self.overlayWindow.hidden) {
        return;
    }
    self.fadeFromProgress = MIN(1.0, MAX(0.0, progress));
    self.fadeStartTime = CACurrentMediaTime();
    [self stopFade];
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:self selector:@selector(stepFade:)];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.fadeLink = link;
}

- (void)stepFade:(CADisplayLink *)link {
    CFTimeInterval elapsed = CACurrentMediaTime() - self.fadeStartTime;
    CGFloat unit = EdgeURLFadeDuration > 0.0 ? (CGFloat)(elapsed / EdgeURLFadeDuration) : 1.0;
    CGFloat t = MIN(1.0, MAX(0.0, unit));
    // Ease out, so the wave finishes growing as it fades.
    CGFloat eased = 1.0 - pow(1.0 - t, 3.0);
    self.indicatorView.progress = self.fadeFromProgress + (1.0 - self.fadeFromProgress) * eased;
    self.indicatorView.alpha = 1.0 - eased;
    [self.indicatorView setNeedsDisplay];
    if (t >= 1.0) {
        [self stopFade];
        self.indicatorView.alpha = 1.0;
        self.indicatorView.progress = 0.0;
        self.overlayWindow.hidden = YES;
        // The wave is done; the trigger area it covered comes back.
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
