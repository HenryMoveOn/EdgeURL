// SPDX-License-Identifier: MIT
#import "EdgeURLBandView.h"

#import "EdgeURLIndicatorView.h"

@implementation EdgeURLBandView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.clearsContextBeforeDrawing = YES;
        self.userInteractionEnabled = NO;
        self.multipleTouchEnabled = NO;
        _areaAlpha = 0.27;
    }
    return self;
}

- (void)setLeftEdge:(BOOL)leftEdge {
    if (_leftEdge == leftEdge) {
        return;
    }
    _leftEdge = leftEdge;
    [self setNeedsDisplay];
}

- (void)setAreaAlpha:(CGFloat)areaAlpha {
    if (_areaAlpha == areaAlpha) {
        return;
    }
    _areaAlpha = areaAlpha;
    [self setNeedsDisplay];
}

// The same shape and the same tint the desktop's band is drawn with, so the two
// look like one thing when an app takes the desktop's place.
- (void)drawRect:(CGRect)rect {
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    if (width < 1.0 || height < 1.0) {
        return;
    }
    CGFloat alpha = MIN(1.0, MAX(0.0, self.areaAlpha));
    if (alpha <= 0.001) {
        return;
    }
    CGFloat far = MIN(width * 0.5, 11.0);
    UIBezierPath *path = EdgeURLPanelPath(self.bounds, 3.0, far, self.leftEdge);
    [[[UIColor systemBlueColor] colorWithAlphaComponent:alpha] setFill];
    [path fill];
}

@end

@implementation EdgeURLBandWindow
@end