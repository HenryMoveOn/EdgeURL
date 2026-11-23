// SPDX-License-Identifier: MIT
//
// The gesture side of the tweak: edge swipe recognizers on SpringBoard's own
// home screen windows, and the wave drawn as a non-interactive subview of that
// window. Only SpringBoard is injected, so the gesture belongs to the home
// screen and never reaches into an app.
#import <UIKit/UIKit.h>

@interface EdgeURLGestureController : NSObject

+ (instancetype)sharedController;

/// Starts listening for a scene and for preference changes. Safe to call more
/// than once.
- (void)start;

@end