// SPDX-License-Identifier: MIT
//
// The edge swipe's own recognizer. UIPanGestureRecognizer only begins after
// about ten points of movement and cannot be told to begin sooner, so the
// trigger felt heavy however the settings were set. This one begins after
// `beginDistance` (five) points of inward movement, and only for a touch that
// started on the trigger band.
#import <UIKit/UIKit.h>

#import "EdgeURLIndicatorView.h"

@class EdgeURLPanRecognizer;

@protocol EdgeURLPanRecognizerDelegate <NSObject>

/// Asked once per touch sequence, at touch-down, for a touch on this
/// recognizer's view. YES tracks it, with the edge it started on: which way is
/// inward depends on the edge. NO fails the recognizer for this sequence and
/// leaves the touch entirely to whatever is under it.
- (BOOL)panRecognizer:(EdgeURLPanRecognizer *)recognizer
    wantsTouchDownAtPointInView:(CGPoint)point
                          edge:(EdgeURLEdge *)edge;

@end

@interface EdgeURLPanRecognizer : UIGestureRecognizer

@property (nonatomic, weak) id<EdgeURLPanRecognizerDelegate> edgeDelegate;
/// How far inward the finger travels before the gesture begins, in points.
@property (nonatomic, assign) CGFloat beginDistance;
/// The edge the tracked touch started on.
@property (nonatomic, readonly) EdgeURLEdge trackedEdge;
/// The touch-down point, in the recognizer's view's coordinates. The inward
/// distance is measured from here, not from where the gesture began.
@property (nonatomic, readonly) CGPoint startPoint;

@end