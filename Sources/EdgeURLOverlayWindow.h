#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// SpringBoard's own windows, far above the normal level, which is how a window
// stays on screen while another app is in front: the system UI is composed over
// the app's own scene.
//
// Two of them, because drawing and touching want opposite things. The canvas is
// a full-screen window that never takes a touch — it only shows the band and the
// wave — and the touch windows are one thin window per enabled edge, exactly the
// sensing area, so a touch anywhere else on the screen never reaches this tweak
// and the app under it keeps working untouched.
extern const UIWindowLevel EdgeURLOverlayWindowLevel;

@interface EdgeURLOverlayWindow : UIWindow
@end

@interface EdgeURLTouchWindow : UIWindow
@end

NS_ASSUME_NONNULL_END
