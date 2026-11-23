// SPDX-License-Identifier: MIT
//
// The sensing band as it is seen from inside an app. The desktop's copy of the
// band lives in SpringBoard's home screen window, which an app covers entirely;
// this one lives in a window of its own that covers nothing but the band's own
// rect, so it can never come between an app and a touch anywhere else.
#import <UIKit/UIKit.h>

@interface EdgeURLBandView : UIView

/// Which edge of the display the band hugs; the corners away from the edge are
/// round, the ones on it nearly square, as the desktop draws them.
@property (nonatomic, assign) BOOL leftEdge;
/// The fill's opacity, the AreaAlpha setting, as the desktop uses it.
@property (nonatomic, assign) CGFloat areaAlpha;

@end

/// A window that shows nothing but the band. Its level puts it above an app's
/// windows and below SpringBoard's status bar, and it takes no touch at all: the
/// whole window is out of hit testing, so a touch on the band reaches the app
/// under it exactly as it would with no band there.
@interface EdgeURLBandWindow : UIWindow
@end