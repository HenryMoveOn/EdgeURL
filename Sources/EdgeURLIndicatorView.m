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
// The Android back gesture's look: a capsule flush with the edge that grows
// longer and thicker as the finger moves in, a soft glow that spreads from the
// edge, and an arrow that fades in at full brightness. Two shorter, fainter
// capsules trail above and below it, which is what makes it read as a wave
// sliding along the edge rather than a bar that appears.
- (void)drawWaveWithWidth:(CGFloat)width
                   height:(CGFloat)height
                     left:(BOOL)left
                     band:(CGFloat)band
                 progress:(CGFloat)progress {
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (context == NULL) {
        return;
    }
    CGFloat depth = 6.0 + MAX(0.0, MIN(band, 46.0) - 6.0) * (0.2 + 0.8 * progress);
    CGFloat length = 46.0 + 86.0 * progress;
    CGFloat half = length * 0.5;
    CGFloat centerY = EdgeURLClamped(self.touchY, half + 14.0, height - half - 14.0);

    // Glow: a gradient from the edge inward, so the band has no visible end.
    CGFloat glowWidth = depth + 20.0 + 24.0 * progress;
    CGRect glowRect = EdgeURLEdgeRect(width, left, glowWidth, centerY - half - 18.0, length + 36.0);
    UIBezierPath *glowPath = [UIBezierPath bezierPathWithRoundedRect:glowRect
                                                            cornerRadius:glowWidth * 0.5];
    CGContextSaveGState(context);
    [glowPath addClip];
    CGFloat glowAlpha = 0.10 + 0.20 * progress;
    NSArray *glowColors = @[(id)[EdgeURLTint(glowAlpha) CGColor],
                            (id)[EdgeURLTint(0.0) CGColor]];
    CGFloat glowLocations[2] = {0.0, 1.0};
    CGGradientRef gradient = CGGradientCreateWithColors(NULL,
                                                        (__bridge CFArrayRef)glowColors,
                                                        glowLocations);
    if (gradient != NULL) {
        CGFloat startX = left ? 0.0 : width;
        CGFloat endX = left ? glowWidth : width - glowWidth;
        CGContextDrawLinearGradient(context, gradient,
                                    CGPointMake(startX, centerY),
                                    CGPointMake(endX, centerY),
                                    kCGGradientDrawsBeforeStartLocation);
        CGGradientRelease(gradient);
    }
    CGContextRestoreGState(context);

    // The wake: two shorter capsules either side of the finger, fading out.
    for (NSInteger step = 1; step <= 2; step++) {
        CGFloat distance = half * 0.55 + step * 17.0;
        CGFloat wakeLength = length * (0.62 - 0.16 * step);
        CGFloat wakeHalf = wakeLength * 0.5;
        CGFloat wakeY = centerY + (step % 2 == 0 ? -distance : distance);
        wakeY = EdgeURLClamped(wakeY, wakeHalf + 4.0, height - wakeHalf - 4.0);
        CGRect wakeRect = EdgeURLEdgeRect(width, left, depth * 0.7, wakeY - wakeHalf, wakeLength);
        UIBezierPath *wake = [UIBezierPath bezierPathWithRoundedRect:wakeRect
                                                           cornerRadius:depth * 0.35];
        [EdgeURLTint((0.06 + 0.08 * progress) / (CGFloat)step) setFill];
        [wake fill];
    }

    // The capsule itself, in three passes so its middle is the brightest.
    CGRect capsuleRect = EdgeURLEdgeRect(width, left, depth, centerY - half, length);
    UIBezierPath *capsule = [UIBezierPath bezierPathWithRoundedRect:capsuleRect
                                                          cornerRadius:depth * 0.5];
    [EdgeURLTint(0.18 + 0.30 * progress) setFill];
    [capsule fill];

    CGRect coreRect = EdgeURLEdgeRect(width, left, depth * 0.45, centerY - half + 3.0, length - 6.0);
    UIBezierPath *core = [UIBezierPath bezierPathWithRoundedRect:coreRect
                                                       cornerRadius:depth * 0.25];
    [EdgeURLTint(0.30 + 0.45 * progress) setFill];
    [core fill];

    // The arrow, pointing the way the swipe goes, once there is something to
    // act on.
    CGFloat arrowIn = EdgeURLClamped((progress - 0.2) / 0.4, 0.0, 1.0);
    if (arrowIn <= 0.001) {
        return;
    }
    CGFloat direction = left ? 1.0 : -1.0;
    CGFloat size = (4.0 + 4.0 * progress) * (0.6 + 0.4 * arrowIn);
    CGFloat centerX = left ? depth + size + 7.0 : width - depth - size - 7.0;
    UIBezierPath *arrow = [UIBezierPath bezierPath];
    [arrow moveToPoint:CGPointMake(centerX - direction * size * 0.55, centerY - size)];
    [arrow addLineToPoint:CGPointMake(centerX + direction * size * 0.55, centerY)];
    [arrow addLineToPoint:CGPointMake(centerX - direction * size * 0.55, centerY + size)];
    arrow.lineWidth = 2.2 + 1.0 * progress;
    arrow.lineCapStyle = kCGLineCapRound;
    arrow.lineJoinStyle = kCGLineJoinRound;
    [[UIColor colorWithWhite:1.0 alpha:(0.35 + 0.55 * progress) * arrowIn] setStroke];
    [arrow stroke];
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
