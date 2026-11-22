// SPDX-License-Identifier: MIT
//
// Everything the overlay draws, in display coordinates. Nothing here touches
// touches: the gesture controller owns those.
#import "EdgeURLIndicatorView.h"

static CGFloat EdgeURLClamped(CGFloat value, CGFloat low, CGFloat high) {
    if (value < low) {
        return low;
    }
    if (value > high) {
        return high;
    }
    return value;
}

// The blue every part of the indicator is drawn in: the trigger area, the
// glow, the capsule and the chevron.
static UIColor *EdgeURLTint(CGFloat alpha) {
    return [[UIColor systemBlueColor] colorWithAlphaComponent:alpha];
}

// A band `width` wide flush against the named edge.
static CGRect EdgeURLEdgeRect(CGFloat screenWidth, BOOL left, CGFloat width, CGFloat y, CGFloat height) {
    CGFloat minX = left ? 0.0 : screenWidth - width;
    return CGRectMake(minX, y, width, height);
}

@implementation EdgeURLIndicatorView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.clearsContextBeforeDrawing = YES;
        self.userInteractionEnabled = NO;
        self.multipleTouchEnabled = NO;
        _edge = EdgeURLEdgeLeft;
        _touchY = 0.0;
        _progress = 0.0;
        _bandWidth = 32.0;
        _regionTop = 0.0;
        _regionHeight = 100.0;
        _areaAlpha = 0.2;
        _showArea = YES;
        _animatedStyle = YES;
    }
    return self;
}

- (void)setEdge:(EdgeURLEdge)edge {
    if (_edge == edge) {
        return;
    }
    _edge = edge;
    [self setNeedsDisplay];
}

- (void)setTouchY:(CGFloat)touchY {
    _touchY = touchY;
}

- (void)setProgress:(CGFloat)progress {
    _progress = progress;
}

- (void)setAnimatedStyle:(BOOL)animatedStyle {
    _animatedStyle = animatedStyle;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    if (width < 2.0 || height < 2.0) {
        return;
    }
    BOOL left = (self.edge == EdgeURLEdgeLeft);
    CGFloat band = EdgeURLClamped(self.bandWidth, 6.0, width * 0.5);
    CGFloat progress = EdgeURLClamped(self.progress, 0.0, 1.0);

    if (self.showArea && self.areaAlpha > 0.001) {
        if (self.previewMode) {
            // The preview shows where the trigger is, on every enabled edge,
            // and nothing else.
            if (self.leftEdgeEnabled) {
                [self drawTriggerAreaLeft:YES width:width height:height band:band];
            }
            if (self.rightEdgeEnabled) {
                [self drawTriggerAreaLeft:NO width:width height:height band:band];
            }
            return;
        }
        [self drawTriggerAreaLeft:left width:width height:height band:band];
    }

    if (self.previewMode) {
        return;
    }
    if (self.animatedStyle) {
        [self drawWaveWithWidth:width height:height left:left band:band progress:progress];
    } else {
        [self drawLegacyTriangleWithWidth:width height:height left:left band:band];
    }
}

// One fill, at exactly the opacity the slider holds: the band used to be a
// half-strength fill with a full-strength outline painted on top of it, so the
// setting never matched what was drawn.
- (void)drawTriggerAreaLeft:(BOOL)left
                      width:(CGFloat)width
                     height:(CGFloat)height
                       band:(CGFloat)band {
    CGFloat top = height * EdgeURLClamped(self.regionTop, 0.0, 100.0) / 100.0;
    CGFloat areaHeight = height * EdgeURLClamped(self.regionHeight, 0.0, 100.0) / 100.0;
    areaHeight = MIN(areaHeight, height - top);
    if (areaHeight <= 1.0) {
        return;
    }
    CGRect areaRect = EdgeURLEdgeRect(width, left, band, top, areaHeight);
    UIBezierPath *area = [UIBezierPath bezierPathWithRoundedRect:areaRect
                                                       cornerRadius:MIN(12.0, band * 0.5)];
    [EdgeURLTint(EdgeURLClamped(self.areaAlpha, 0.0, 1.0)) setFill];
    [area fill];
}

// The wave: a translucent capsule that grows inward and brightens with
// progress, with a chevron that grows the same way.
- (void)drawWaveWithWidth:(CGFloat)width
                   height:(CGFloat)height
                     left:(BOOL)left
                     band:(CGFloat)band
                 progress:(CGFloat)progress {
    CGFloat capsuleHeight = 38.0 + 70.0 * progress;
    CGFloat innerWidth = 5.0 + MAX(0.0, band * 0.7 - 5.0) * progress;
    CGFloat half = capsuleHeight * 0.5;
    CGFloat centerY = EdgeURLClamped(self.touchY, half + 6.0, height - half - 6.0);
    CGFloat top = centerY - half;

    CGRect glowRect = EdgeURLEdgeRect(width, left, innerWidth + 16.0, top - 5.0, capsuleHeight + 10.0);
    UIBezierPath *glow = [UIBezierPath bezierPathWithRoundedRect:glowRect
                                                        cornerRadius:(capsuleHeight + 10.0) * 0.5];
    [EdgeURLTint(0.05 + 0.12 * progress) setFill];
    [glow fill];

    CGRect capsuleRect = EdgeURLEdgeRect(width, left, innerWidth, top, capsuleHeight);
    UIBezierPath *capsule = [UIBezierPath bezierPathWithRoundedRect:capsuleRect
                                                           cornerRadius:innerWidth * 0.5];
    [EdgeURLTint(0.16 + 0.34 * progress) setFill];
    [capsule fill];

    CGFloat size = 4.5 + 3.5 * progress;
    CGFloat offset = MAX(innerWidth * 0.55, size + 3.0);
    CGFloat centerX = left ? offset : width - offset;
    CGFloat tip = left ? size * 0.55 : -size * 0.55;
    UIBezierPath *chevron = [UIBezierPath bezierPath];
    [chevron moveToPoint:CGPointMake(centerX - tip, centerY - size)];
    [chevron addLineToPoint:CGPointMake(centerX + tip, centerY)];
    [chevron addLineToPoint:CGPointMake(centerX - tip, centerY + size)];
    chevron.lineWidth = 2.4;
    chevron.lineCapStyle = kCGLineCapRound;
    chevron.lineJoinStyle = kCGLineJoinRound;
    [[UIColor colorWithWhite:1.0 alpha:0.5 + 0.45 * progress] setStroke];
    [chevron stroke];
}

// What 0.1.x drew, kept for Animated = NO.
- (void)drawLegacyTriangleWithWidth:(CGFloat)width
                             height:(CGFloat)height
                               left:(BOOL)left
                               band:(CGFloat)band {
    CGFloat half = MAX(8.0, band * 0.55);
    CGFloat centerY = EdgeURLClamped(self.touchY, half + 4.0, height - half - 4.0);
    UIBezierPath *triangle = [UIBezierPath bezierPath];
    [triangle moveToPoint:CGPointMake(left ? band : width - band, centerY)];
    [triangle addLineToPoint:CGPointMake(left ? 0.0 : width, centerY - half)];
    [triangle addLineToPoint:CGPointMake(left ? 0.0 : width, centerY + half)];
    [triangle closePath];
    [EdgeURLTint(0.3) setFill];
    [triangle fill];
    [EdgeURLTint(0.7) setStroke];
    triangle.lineWidth = 1.5;
    triangle.lineJoinStyle = kCGLineJoinRound;
    [triangle stroke];
}

@end
