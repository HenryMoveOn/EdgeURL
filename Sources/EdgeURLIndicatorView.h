// SPDX-License-Identifier: MIT
//
// The overlay's drawing: the Android-style edge wave that follows a finger
// along the screen edge, plus the trigger-area band and the old triangle.
// It draws in display coordinates, because that is the space the system
// gesture recognizer reports touches in.
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, EdgeURLEdge) {
    EdgeURLEdgeLeft = 0,
    EdgeURLEdgeRight = 1,
};

@interface EdgeURLIndicatorView : UIView

@property (nonatomic, assign) EdgeURLEdge edge;
/// The finger's y in display coordinates; the wave is centred on it.
@property (nonatomic, assign) CGFloat touchY;
/// 0 at the edge, 1 once the finger has travelled `threshold` points in.
@property (nonatomic, assign) CGFloat progress;
/// The trigger band's width in points (the EdgeWidth setting).
@property (nonatomic, assign) CGFloat bandWidth;
/// The trigger region, as percentages of the display height.
@property (nonatomic, assign) CGFloat regionTop;
@property (nonatomic, assign) CGFloat regionHeight;
@property (nonatomic, assign) CGFloat areaAlpha;
@property (nonatomic, assign) BOOL showArea;
/// NO draws the old triangle instead of the wave (the Animated setting).
@property (nonatomic, assign) BOOL animatedStyle;
/// YES draws only the trigger bands, on the enabled edges, and no wave: the
/// preview shown when a setting changes, so the opacity and the region can be
/// seen without a swipe.
@property (nonatomic, assign) BOOL previewMode;
@property (nonatomic, assign) BOOL leftEdgeEnabled;
@property (nonatomic, assign) BOOL rightEdgeEnabled;

@end
