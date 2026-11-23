// SPDX-License-Identifier: MIT
//
// Everything the overlay draws, in display coordinates. Nothing here touches
// touches: the gesture controller owns those. The view is hosted inside
// SpringBoard's home screen window, which sits below every app's window, so it
// cannot cover an app or take a touch from one.
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

// The blue the trigger area is drawn in.
static UIColor *EdgeURLTint(CGFloat alpha) {
    return [[UIColor systemBlueColor] colorWithAlphaComponent:alpha];
}

#pragma mark - The sensing area

// The rest panel itself is 11 by 44 points; a finger needs more than that, so
// the area it is sensed in is as tall as the configured region gives it, within
// these bounds, and centred on the region's own middle. That is the whole of the
// screen a swipe is taken from: everywhere else is left alone and undrawn.
static const CGFloat EdgeURLSensingMinLength = 56.0;
static const CGFloat EdgeURLSensingMaxLength = 96.0;

CGRect EdgeURLSensingRect(CGRect display,
                          BOOL left,
                          CGFloat bandWidth,
                          CGFloat regionTopPercent,
                          CGFloat regionHeightPercent) {
    CGFloat displayWidth = CGRectGetWidth(display);
    CGFloat displayHeight = CGRectGetHeight(display);
    if (displayWidth < 2.0 || displayHeight < 2.0) {
        return CGRectZero;
    }
    CGFloat band = EdgeURLClamped(bandWidth, 16.0, displayWidth * 0.5);
    CGFloat top = CGRectGetMinY(display) +
                  displayHeight * EdgeURLClamped(regionTopPercent, 0.0, 100.0) / 100.0;
    CGFloat region = displayHeight * EdgeURLClamped(regionHeightPercent, 0.0, 100.0) / 100.0;
    region = MAX(1.0, MIN(region, CGRectGetMaxY(display) - top));
    CGFloat length = MIN(EdgeURLClamped(region, EdgeURLSensingMinLength,
                                        EdgeURLSensingMaxLength),
                         displayHeight);
    CGFloat centerY = top + region * 0.5;
    CGFloat minY = EdgeURLClamped(centerY - length * 0.5,
                                  CGRectGetMinY(display),
                                  CGRectGetMaxY(display) - length);
    CGFloat minX = left ? CGRectGetMinX(display) : CGRectGetMaxX(display) - band;
    return CGRectMake(minX, minY, band, length);
}

#pragma mark - Android's easing

// One coordinate of a cubic Bézier from (0,0) to (1,1), as Android's
// PathInterpolator is built: the two control points are given, the curve is
// sampled by its x.
static CGFloat EdgeURLBezierCoordinate(CGFloat t, CGFloat a, CGFloat b) {
    CGFloat u = 1.0 - t;
    return 3.0 * u * u * t * a + 3.0 * u * t * t * b + t * t * t;
}

static CGFloat EdgeURLBezierSlope(CGFloat t, CGFloat a, CGFloat b) {
    CGFloat u = 1.0 - t;
    return 3.0 * u * u * a + 6.0 * u * t * (b - a) + 3.0 * t * t * (1.0 - b);
}

// The y of the curve at the given x. This is androidx's PathInterpolator, to the
// point: the same curves Android's edge panel uses, not a guessed ease.
static CGFloat EdgeURLPathInterpolator(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2, CGFloat x) {
    if (x <= 0.0) {
        return 0.0;
    }
    if (x >= 1.0) {
        return 1.0;
    }
    CGFloat t = x;
    for (NSInteger step = 0; step < 8; step++) {
        CGFloat slope = EdgeURLBezierSlope(t, x1, x2);
        if (fabs(slope) < 1e-5) {
            break;
        }
        CGFloat error = EdgeURLBezierCoordinate(t, x1, x2) - x;
        t = EdgeURLClamped(t - error / slope, 0.0, 1.0);
    }
    return EdgeURLBezierCoordinate(t, y1, y2);
}

// A rounded rectangle whose two corners on the edge side are nearly square and
// whose two corners away from it are round: the shape Android's back panel has.
static UIBezierPath *EdgeURLPanelPath(CGRect rect, CGFloat nearRadius, CGFloat farRadius, BOOL left) {
    CGFloat minX = CGRectGetMinX(rect);
    CGFloat maxX = CGRectGetMaxX(rect);
    CGFloat minY = CGRectGetMinY(rect);
    CGFloat maxY = CGRectGetMaxY(rect);
    CGFloat limit = MIN(CGRectGetWidth(rect), CGRectGetHeight(rect)) * 0.5;
    CGFloat near = MIN(MAX(0.0, nearRadius), limit);
    CGFloat far = MIN(MAX(0.0, farRadius), limit);
    CGFloat topLeft = left ? near : far;
    CGFloat topRight = left ? far : near;
    CGFloat bottomRight = topRight;
    CGFloat bottomLeft = topLeft;

    CGMutablePathRef path = CGPathCreateMutable();
    CGPathMoveToPoint(path, NULL, minX + topLeft, minY);
    CGPathAddArcToPoint(path, NULL, maxX, minY, maxX, maxY, topRight);
    CGPathAddArcToPoint(path, NULL, maxX, maxY, minX, maxY, bottomRight);
    CGPathAddArcToPoint(path, NULL, minX, maxY, minX, minY, bottomLeft);
    CGPathAddArcToPoint(path, NULL, minX, minY, maxX, minY, topLeft);
    CGPathCloseSubpath(path);
    UIBezierPath *result = [UIBezierPath bezierPathWithCGPath:path];
    CGPathRelease(path);
    return result;
}

#pragma mark - Sizes, in points, from Android's edge panel

// Android sizes the panel from dimens in dp; a dp and a point are near enough
// the same length that the numbers carry over as they are.
static const CGFloat EdgeURLPanelNearRadius = 4.0;    // square-ish, on the edge
static const CGFloat EdgeURLPanelFarRadius = 20.0;    // round, away from it
static const CGFloat EdgeURLPanelMinInward = 11.0;    // resting width, into the screen
static const CGFloat EdgeURLPanelMaxInward = 30.0;    // stretched width
static const CGFloat EdgeURLPanelMinLength = 44.0;    // resting length, along the edge
static const CGFloat EdgeURLPanelMaxLength = 64.0;    // stretched length
static const CGFloat EdgeURLArrowArm = 5.5;           // half the chevron's extent
static const CGFloat EdgeURLArrowStroke = 2.4;

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

    if (self.previewMode) {
        // At rest, and while a setting is being tried: the sensing area on every
        // enabled edge, and nothing else on the screen.
        if (!self.showArea || self.areaAlpha <= 0.001) {
            return;
        }
        if (self.leftEdgeEnabled) {
            [self drawSensingAreaLeft:YES width:width height:height band:band];
        }
        if (self.rightEdgeEnabled) {
            [self drawSensingAreaLeft:NO width:width height:height band:band];
        }
        return;
    }
    if (self.animatedStyle) {
        [self drawPanelWithWidth:width height:height left:left progress:progress];
    } else {
        [self drawLegacyTriangleWithWidth:width height:height left:left band:band];
    }
}

// One fill, at exactly the opacity the slider holds, over the rect a swipe is
// taken from: the only thing drawn on the desktop when nothing is happening, so
// the rest of the screen stays exactly as it was.
- (void)drawSensingAreaLeft:(BOOL)left
                      width:(CGFloat)width
                     height:(CGFloat)height
                       band:(CGFloat)band {
    CGRect areaRect = EdgeURLSensingRect(CGRectMake(0.0, 0.0, width, height), left, band,
                                         self.regionTop, self.regionHeight);
    if (CGRectGetWidth(areaRect) < 1.0 || CGRectGetHeight(areaRect) < 1.0) {
        return;
    }
    CGFloat far = MIN(CGRectGetWidth(areaRect) * 0.5, 11.0);
    UIBezierPath *area = EdgeURLPanelPath(areaRect, 3.0, far, left);
    [EdgeURLTint(EdgeURLClamped(self.areaAlpha, 0.0, 1.0)) setFill];
    [area fill];
}

// Android's back gesture panel, drawn as Android draws it: a translucent panel
// hugging the edge — almost square where it meets the edge, round on the side
// away from it — that widens and lengthens as the finger leaves the edge, with a
// chevron inside pointing the way the swipe goes. The panel comes in with the
// gesture at rest and its chevron fades in once the swipe has plainly started,
// which is the step Android's own panel has.
- (void)drawPanelWithWidth:(CGFloat)width
                    height:(CGFloat)height
                      left:(BOOL)left
                  progress:(CGFloat)progress {
    CGFloat p = EdgeURLClamped(progress, 0.0, 1.0);
    // Android's own width interpolator: it overshoots early, so the panel reads
    // as pulled out of the edge rather than scaled up.
    CGFloat eased = EdgeURLPathInterpolator(0.7, -0.24, 0.48, 1.21, p);

    CGFloat inward = EdgeURLPanelMinInward + (EdgeURLPanelMaxInward - EdgeURLPanelMinInward) * eased;
    inward = MIN(inward, width * 0.5);
    CGFloat length = EdgeURLPanelMinLength + (EdgeURLPanelMaxLength - EdgeURLPanelMinLength) * eased;
    length = MAX(20.0, MIN(length, height - 12.0));
    CGFloat centerY = EdgeURLClamped(self.touchY, length * 0.5 + 6.0, height - length * 0.5 - 6.0);

    CGRect panel = CGRectMake(left ? 0.0 : width - inward,
                              centerY - length * 0.5,
                              inward, length);
    UIBezierPath *panelPath = EdgeURLPanelPath(panel, EdgeURLPanelNearRadius,
                                               EdgeURLPanelFarRadius, left);
    // The panel and the chevron both follow the system's appearance, as they do
    // in Android: light-on-dark in the dark, dark-on-light in the light.
    UIColor *ink = [UIColor labelColor];
    [[ink colorWithAlphaComponent:0.13 + 0.06 * p] setFill];
    [panelPath fill];

    // The chevron: Android shows it from 16.5% of the way in, and not before, so
    // a stray touch never flashes an arrow.
    CGFloat arrowIn = EdgeURLClamped((p - 0.10) / 0.12, 0.0, 1.0);
    if (arrowIn <= 0.001) {
        return;
    }
    CGFloat scale = 0.86 + 0.20 * eased;
    CGFloat arm = EdgeURLArrowArm * scale;
    CGFloat tip = inward * 0.60 + 1.0;
    CGFloat base = MAX(0.5, tip - arm * 1.05);
    CGFloat direction = left ? 1.0 : -1.0;
    CGPoint tipPoint = CGPointMake(left ? tip : width - tip, centerY);
    CGPoint baseTop = CGPointMake(left ? base : width - base, centerY - arm);
    CGPoint baseBottom = CGPointMake(left ? base : width - base, centerY + arm);

    UIBezierPath *chevron = [UIBezierPath bezierPath];
    [chevron moveToPoint:baseTop];
    [chevron addLineToPoint:tipPoint];
    [chevron addLineToPoint:baseBottom];
    (void)direction;
    chevron.lineWidth = EdgeURLArrowStroke * scale;
    chevron.lineCapStyle = kCGLineCapRound;
    chevron.lineJoinStyle = kCGLineJoinRound;
    [[ink colorWithAlphaComponent:0.90 * arrowIn] setStroke];
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