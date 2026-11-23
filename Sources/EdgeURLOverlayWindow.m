#import "EdgeURLOverlayWindow.h"

// Above everything else on the desktop, including the full-screen windows other
// tweaks keep far above the normal level: this device has one at 10000011.
const UIWindowLevel EdgeURLOverlayWindowLevel = (UIWindowLevel)10000200.0;

@implementation EdgeURLOverlayWindow

- (instancetype)initWithWindowScene:(UIWindowScene *)scene {
    self = [super initWithWindowScene:scene];
    if (self) {
        self.windowLevel = EdgeURLOverlayWindowLevel;
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        // On, because the sensing views have to be reachable; the window itself
        // still answers nil for every point outside them.
        self.userInteractionEnabled = YES;
        self.sensingViews = @[];
    }
    return self;
}

- (BOOL)canBecomeKeyWindow {
    return NO;
}

- (BOOL)canBecomeFocused {
    return NO;
}

// The whole point of this window: it takes the band and nothing else. Every
// other point answers nil, so the system passes it to the window below, and the
// desktop keeps working exactly as it did.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01 || !self.userInteractionEnabled) {
        return nil;
    }
    for (UIView *view in self.sensingViews) {
        if (view.hidden || view.alpha < 0.01 || !view.userInteractionEnabled) {
            continue;
        }
        if (CGRectContainsPoint(view.frame, point)) {
            return view;
        }
    }
    return nil;
}

@end
