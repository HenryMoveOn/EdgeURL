// SPDX-License-Identifier: MIT
//
// The private UIKit surface EdgeURL needs: a window scene's system gesture
// manager, which hands us touches before the frontmost app sees them. The SDK
// ships no declarations for it, so only the selectors used here are declared.
#import <UIKit/UIKit.h>

@interface UISystemGestureManager : NSObject
- (void)addGestureRecognizer:(UIGestureRecognizer *)recognizer withType:(NSUInteger)type;
- (void)removeGestureRecognizer:(UIGestureRecognizer *)recognizer;
@end

@interface UIWindowScene (EdgeURLSystemGesture)
- (UISystemGestureManager *)systemGestureManager;
@end