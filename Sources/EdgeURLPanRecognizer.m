// SPDX-License-Identifier: MIT
//
// The state machine is small: Possible until the finger has moved `beginDistance`
// points inward, then Began, Changed on every move, Ended on lift. A touch that
// starts off the band, moves away from the edge, or turns into a vertical drag
// fails at once and is handed straight back to the view under it.
#import "EdgeURLPanRecognizer.h"

@implementation EdgeURLPanRecognizer {
    BOOL _tracking;
    CGPoint _startPoint;
}

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    self = [super initWithTarget:target action:action];
    if (self) {
        _beginDistance = 3.0;
        _trackedEdge = EdgeURLEdgeLeft;
        // The touch is never delayed or swallowed: an app, an icon or the page
        // scroller under the finger keeps working while this one watches.
        self.cancelsTouchesInView = NO;
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
    }
    return self;
}

- (CGPoint)startPoint {
    return _startPoint;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.state != UIGestureRecognizerStatePossible || _tracking) {
        return;
    }
    if ([event touchesForGestureRecognizer:self].count > 1) {
        // One finger only; a second one means this is not an edge swipe.
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
    UITouch *touch = touches.anyObject;
    if (touch == nil) {
        return;
    }
    _startPoint = [touch locationInView:self.view];
    EdgeURLEdge edge = EdgeURLEdgeLeft;
    if (![self.edgeDelegate panRecognizer:self
                     wantsTouchDownAtPointInView:_startPoint
                                           edge:&edge]) {
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
    _trackedEdge = edge;
    _tracking = YES;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_tracking) {
        return;
    }
    UITouch *touch = [event touchesForGestureRecognizer:self].anyObject;
    if (touch == nil) {
        return;
    }
    CGPoint point = [touch locationInView:self.view];
    CGFloat dx = point.x - _startPoint.x;
    CGFloat dy = point.y - _startPoint.y;
    CGFloat inward = (self.trackedEdge == EdgeURLEdgeRight) ? -dx : dx;

    if (self.state == UIGestureRecognizerStatePossible) {
        // Moving away from the edge is not this gesture, and a drag that is
        // plainly vertical belongs to the page under it. Everything else that
        // moves inward begins at once, however diagonal it is: the gesture is
        // meant to be easy to make, not fussy about its angle.
        if (inward <= -8.0) {
            [self fail];
            return;
        }
        if (fabs(dy) > 40.0 && fabs(dy) > fabs(inward) * 2.0) {
            [self fail];  // A vertical drag; let the page scroller have it.
            return;
        }
        if (inward >= self.beginDistance) {
            self.state = UIGestureRecognizerStateBegan;
        }
        return;
    }
    if (self.state == UIGestureRecognizerStateBegan ||
        self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateChanged;
    }
}

// This recognizer only watches: it must neither cancel the other recognizers
// that share the window (the page scroller's, another tweak's) nor be cancelled
// by them.
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)preventedGestureRecognizer {
    return NO;
}

- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)preventingGestureRecognizer {
    return NO;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // A quick flick can end without a move event after it: if the finger was
    // let go already far enough inward, the gesture still counts.
    if (self.state == UIGestureRecognizerStatePossible) {
        UITouch *touch = touches.anyObject;
        if (touch != nil) {
            CGPoint point = [touch locationInView:self.view];
            CGFloat dx = point.x - _startPoint.x;
            CGFloat inward = (self.trackedEdge == EdgeURLEdgeRight) ? -dx : dx;
            if (inward >= self.beginDistance) {
                self.state = UIGestureRecognizerStateBegan;
            }
        }
    }
    _tracking = NO;
    if (self.state == UIGestureRecognizerStateBegan ||
        self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateEnded;
    } else {
        self.state = UIGestureRecognizerStateFailed;
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _tracking = NO;
    if (self.state == UIGestureRecognizerStateBegan ||
        self.state == UIGestureRecognizerStateChanged) {
        self.state = UIGestureRecognizerStateCancelled;
    } else {
        self.state = UIGestureRecognizerStateFailed;
    }
}

- (void)fail {
    _tracking = NO;
    self.state = UIGestureRecognizerStateFailed;
}

- (void)reset {
    [super reset];
    _tracking = NO;
    _startPoint = CGPointZero;
}

@end