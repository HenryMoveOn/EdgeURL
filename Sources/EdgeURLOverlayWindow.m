#import "EdgeURLOverlayWindow.h"

// Chosen to sit above the things other tweaks keep up here: this device has a
// full-screen SGPanelWindow at 10000011 that took the key window on the desk-
// top. Anything at or above this level belongs to EdgeURL.
const UIWindowLevel EdgeURLOverlayWindowLevel = (UIWindowLevel)10000200.0;

@implementation EdgeURLOverlayWindow

- (instancetype)initWithWindowScene:(UIWindowScene *)scene {
    self = [super initWithWindowScene:scene];
    if (self) {
        self.windowLevel = EdgeURLOverlayWindowLevel;
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        // The canvas is drawn on and never touched: a window with its user
        // interaction off is skipped by the system when it hands out touches,
        // so nothing under it loses one.
        self.userInteractionEnabled = NO;
    }
    return self;
}

- (BOOL)canBecomeKeyWindow {
    return NO;
}

- (BOOL)canBecomeFocused {
    return NO;
}

// Belt and braces: no point of the canvas is ever the target of a touch.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil;
}

@end

@implementation EdgeURLTouchWindow

- (instancetype)initWithWindowScene:(UIWindowScene *)scene {
    self = [super initWithWindowScene:scene];
    if (self) {
        // Just above the canvas, so the sensing area is taken before anything
        // drawn there and before any window of another tweak.
        self.windowLevel = EdgeURLOverlayWindowLevel + 1.0;
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
    }
    return self;
}

- (BOOL)canBecomeKeyWindow {
    return NO;
}

- (BOOL)canBecomeFocused {
    return NO;
}

@end
