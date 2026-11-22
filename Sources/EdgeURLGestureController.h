// SPDX-License-Identifier: MIT
//
// The gesture side of the tweak: one pan recognizer handed to SpringBoard's
// window scene through its system gesture manager, so an edge swipe reaches us
// before the frontmost app sees it, and no window of ours ever takes a touch.
#import <UIKit/UIKit.h>

@interface EdgeURLGestureController : NSObject

+ (instancetype)sharedController;

/// Starts listening for a scene and for preference changes. Safe to call more
/// than once.
- (void)start;

@end
